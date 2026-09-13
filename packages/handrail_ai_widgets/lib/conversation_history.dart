import 'dart:async';
import 'package:flutter/material.dart';

/// Matches the headless client's historyBinding without a package dependency.
typedef HandrailHistoryUiBinding = ({
  Object scope,
  Stream<Object?> changes,
  Map<String, Object?> Function() read,
  Future<void> Function() create,
  Future<void> Function(String) open,
  Future<void> Function(String) archive,
  Future<void> Function(String) restore,
  Future<void> Function(String) view,
  void Function(bool) unread,
  Future<void> Function() loadMore,
  Future<void> Function() refresh
});

/// Standard mobile history picker or an expanded sidebar inside a bounded area.
/// The authenticated controller owns data, lifecycle writes and retry identity.
class HandrailConversationHistory extends StatefulWidget {
  const HandrailConversationHistory(
      {super.key,
      required this.binding,
      this.compact = true,
      this.showArchived = true,
      this.showUnread = true,
      this.title = 'Conversations',
      this.newLabel = 'New chat',
      this.newButtonKey});
  final HandrailHistoryUiBinding binding;
  final bool compact, showArchived, showUnread;
  final String title, newLabel;
  final Key? newButtonKey;
  @override
  State<HandrailConversationHistory> createState() => _HistoryState();
}

class _HistoryState extends State<HandrailConversationHistory> {
  BuildContext? _sheetContext;
  bool _opening = false;
  void _closeOldScope() {
    final context = _sheetContext;
    _sheetContext = null;
    if (context == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted && ModalRoute.of(context)?.isCurrent == true)
        Navigator.of(context).pop();
    });
  }

  @override
  void didUpdateWidget(HandrailConversationHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding.scope, widget.binding.scope))
      _closeOldScope();
  }

  @override
  void dispose() {
    _closeOldScope();
    super.dispose();
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    final config = widget;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (context) {
            _sheetContext = context;
            return FractionallySizedBox(
                heightFactor: .85,
                child: _HistorySurface(
                    config: config,
                    close: () {
                      if (context.mounted) Navigator.of(context).pop();
                    }));
          });
    } finally {
      _opening = false;
      _sheetContext = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.compact) return _HistorySurface(config: widget);
    return StreamBuilder<Object?>(
        stream: widget.binding.changes,
        builder: (context, _) {
          final state = widget.binding.read(),
              busy = widget.binding.read()['busy'] == true;
          return LayoutBuilder(builder: (context, constraints) {
            final compactNew = constraints.maxWidth /
                    (MediaQuery.textScalerOf(context).scale(16) / 16) <
                360;
            Future<void> create() async {
              try {
                await widget.binding.create();
              } catch (_) {
                if (mounted) unawaited(_open());
              }
            }

            return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(children: [
                  Expanded(
                      child: OutlinedButton.icon(
                          key: const ValueKey('handrail-open-history'),
                          onPressed: _open,
                          icon: const Icon(Icons.forum_outlined, size: 18),
                          label: Text(
                              state['selectedTitle'] as String? ?? widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis))),
                  const SizedBox(width: 8),
                  if (compactNew)
                    IconButton.outlined(
                        key: widget.newButtonKey,
                        tooltip: widget.newLabel,
                        onPressed: busy ? null : create,
                        icon: const Icon(Icons.add))
                  else
                    OutlinedButton.icon(
                        key: widget.newButtonKey,
                        onPressed: busy ? null : create,
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(widget.newLabel)),
                ]));
          });
        });
  }
}

class _HistorySurface extends StatefulWidget {
  const _HistorySurface({required this.config, this.close});
  final HandrailConversationHistory config;
  final VoidCallback? close;
  @override
  State<_HistorySurface> createState() => _HistorySurfaceState();
}

class _HistorySurfaceState extends State<_HistorySurface> {
  String? _error;
  bool _acting = false;
  Future<void> _act(Future<void> Function() action,
      {bool close = false}) async {
    if (_acting) return;
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action();
      if (mounted && close) widget.close?.call();
    } catch (_) {
      if (mounted)
        _error =
            'The conversation change could not be confirmed. Retry the same action.';
    } finally {
      if (mounted)
        setState(() {
          _acting = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Object?>(
      stream: widget.config.binding.changes,
      builder: (context, _) {
        final binding = widget.config.binding, state = binding.read();
        final busy = _acting || state['busy'] == true;
        final rows = (state['rows'] as List? ?? const []).cast<Map>();
        final view = state['view'] as String? ?? 'active';
        final error = state['error'] as String? ?? _error;
        final compactNew = MediaQuery.sizeOf(context).width /
                (MediaQuery.textScalerOf(context).scale(16) / 16) <
            360;
        return Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
                top: false,
                child: CustomScrollView(slivers: [
                  SliverToBoxAdapter(
                      child: Column(children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                        child: Row(children: [
                          Expanded(
                              child: Text(widget.config.title,
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          if (compactNew)
                            IconButton(
                                tooltip: widget.config.newLabel,
                                key: widget.config.newButtonKey,
                                onPressed: busy
                                    ? null
                                    : () => _act(binding.create, close: true),
                                icon: const Icon(Icons.add))
                          else
                            TextButton.icon(
                                key: widget.config.newButtonKey,
                                onPressed: busy
                                    ? null
                                    : () => _act(binding.create, close: true),
                                icon: const Icon(Icons.add),
                                label: Text(widget.config.newLabel)),
                          if (widget.close != null)
                            IconButton(
                                tooltip: 'Close conversations',
                                onPressed: widget.close,
                                icon: const Icon(Icons.close)),
                        ])),
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ChoiceChip(
                                  label: const Text('Active'),
                                  selected: view == 'active',
                                  onSelected: busy
                                      ? null
                                      : (_) =>
                                          _act(() => binding.view('active'))),
                              if (widget.config.showArchived)
                                ChoiceChip(
                                    label: const Text('Archived'),
                                    selected: view == 'archived',
                                    onSelected: busy
                                        ? null
                                        : (_) => _act(
                                            () => binding.view('archived'))),
                              if (widget.config.showUnread)
                                FilterChip(
                                    label: Text(
                                        'Unread (${state['unreadCount'] ?? 0})'),
                                    selected: state['unreadOnly'] == true,
                                    onSelected: busy ? null : binding.unread),
                              IconButton(
                                  tooltip: 'Refresh conversations',
                                  onPressed: busy || state['loading'] == true
                                      ? null
                                      : () => _act(binding.refresh),
                                  icon: const Icon(Icons.refresh)),
                            ])),
                    if (state['loading'] == true)
                      const LinearProgressIndicator(
                          semanticsLabel: 'Loading conversations'),
                    if (error != null)
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Semantics(
                              liveRegion: true,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(error,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error)),
                                    Align(
                                        alignment:
                                            AlignmentDirectional.centerEnd,
                                        child: TextButton(
                                            onPressed: busy
                                                ? null
                                                : () => _act(binding.refresh),
                                            child:
                                                const Text('Retry history'))),
                                  ]))),
                  ])),
                  if (rows.isEmpty)
                    SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                            child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Text(state['loading'] == true
                                    ? 'Loading conversations…'
                                    : state['unreadOnly'] == true
                                        ? (state['hasMore'] == true
                                            ? 'No unread conversations in the loaded history.'
                                            : 'No unread conversations.')
                                        : view == 'archived'
                                            ? 'No archived conversations.'
                                            : 'No conversations yet.'))))
                  else
                    SliverList.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final row = rows[index], id = row['id'] as String;
                          final archived = row['lifecycle'] == 'archived';
                          final date = DateTime.tryParse(
                              row['updatedAt'] as String? ?? '');
                          return ListTile(
                              key: ValueKey('handrail-conversation-$id'),
                              selected: state['selectedId'] == id,
                              selectedTileColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: .35),
                              onTap: busy
                                  ? null
                                  : () =>
                                      _act(() => binding.open(id), close: true),
                              leading: row['running'] == true
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : row['unread'] == true
                                      ? Icon(Icons.circle,
                                          size: 10,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary)
                                      : null,
                              title: Text(
                                  row['title'] as String? ?? 'New conversation',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontWeight: row['unread'] == true
                                          ? FontWeight.w600
                                          : null)),
                              subtitle: Text(
                                  [
                                    if ((row['preview'] as String? ?? '')
                                        .isNotEmpty)
                                      row['preview'] as String,
                                    if (date != null)
                                      MaterialLocalizations.of(context)
                                          .formatShortDate(date.toLocal())
                                  ].join('\n'),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis),
                              trailing: widget.config.showArchived
                                  ? IconButton(
                                      tooltip: archived
                                          ? 'Restore conversation'
                                          : 'Archive conversation',
                                      onPressed: busy || row['running'] == true
                                          ? null
                                          : () => _act(() => archived
                                              ? binding.restore(id)
                                              : binding.archive(id)),
                                      icon:
                                          Icon(archived ? Icons.unarchive_outlined : Icons.archive_outlined))
                                  : null);
                        }),
                  if (state['hasMore'] == true)
                    SliverToBoxAdapter(
                        child: TextButton(
                            onPressed: busy || state['loading'] == true
                                ? null
                                : () => _act(binding.loadMore),
                            child: const Text('Older conversations'))),
                ])));
      });
}
