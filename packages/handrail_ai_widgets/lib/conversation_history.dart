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
  Future<void> Function(String, int) delete,
  Future<void> Function(String) view,
  void Function(bool) unread,
  Future<void> Function() loadMore,
  Future<void> Function() refresh,
});

/// Standard mobile history picker or an expanded sidebar inside a bounded area.
/// The authenticated controller owns data, lifecycle writes and retry identity.
class HandrailConversationHistory extends StatefulWidget {
  const HandrailConversationHistory({
    super.key,
    required this.binding,
    this.compact = true,
    this.showArchived = true,
    this.showUnread = true,
    this.title = 'Conversations',
    this.newLabel = 'New chat',
    this.newButtonKey,
  });
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
      if (context.mounted && ModalRoute.of(context)?.isActive == true)
        Navigator.of(context).removeRoute(ModalRoute.of(context)!);
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
              isScopeCurrent: () =>
                  mounted &&
                  identical(config.binding.scope, widget.binding.scope),
              close: () {
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          );
        },
      );
    } finally {
      _opening = false;
      _sheetContext = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.compact) {
      final scope = widget.binding.scope;
      return _HistorySurface(
        config: widget,
        isScopeCurrent: () => mounted && identical(scope, widget.binding.scope),
      );
    }
    return StreamBuilder<Object?>(
      stream: widget.binding.changes,
      builder: (context, _) {
        final state = widget.binding.read(),
            busy = widget.binding.read()['busy'] == true;
        return LayoutBuilder(
          builder: (context, constraints) {
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('handrail-open-history'),
                      onPressed: _open,
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: Text(
                        state['selectedTitle'] as String? ?? widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (compactNew)
                    IconButton.outlined(
                      key: widget.newButtonKey,
                      tooltip: widget.newLabel,
                      onPressed:
                          busy || state['canCreate'] == false ? null : create,
                      icon: const Icon(Icons.add),
                    )
                  else
                    OutlinedButton.icon(
                      key: widget.newButtonKey,
                      onPressed:
                          busy || state['canCreate'] == false ? null : create,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(widget.newLabel),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _HistorySurface extends StatefulWidget {
  const _HistorySurface({
    required this.config,
    this.close,
    required this.isScopeCurrent,
  });
  final HandrailConversationHistory config;
  final VoidCallback? close;
  final bool Function() isScopeCurrent;
  @override
  State<_HistorySurface> createState() => _HistorySurfaceState();
}

class _HistorySurfaceState extends State<_HistorySurface> {
  String? _error;
  bool _acting = false;
  int _actionGeneration = 0;
  BuildContext? _confirmationContext;

  void _closeConfirmation() {
    final context = _confirmationContext;
    _confirmationContext = null;
    if (context == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted && ModalRoute.of(context)?.isActive == true)
        Navigator.of(context).removeRoute(ModalRoute.of(context)!);
    });
  }

  @override
  void didUpdateWidget(_HistorySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.config.binding.scope,
      widget.config.binding.scope,
    )) {
      _closeConfirmation();
      _actionGeneration++;
      _acting = false;
      _error = null;
    }
  }

  @override
  void dispose() {
    _closeConfirmation();
    super.dispose();
  }

  Future<void> _delete(Map row) => _act(() async {
        final binding = widget.config.binding,
            id = row['id'] as String,
            version = row['version'] as int;
        BuildContext? confirmation;
        final approved = await showDialog<bool>(
          context: context,
          builder: (context) {
            _confirmationContext = context;
            confirmation = context;
            return AlertDialog(
              title: const Text('Delete this conversation?'),
              content: Text(
                'Permanently delete “${row['title'] ?? 'Conversation'}” and its messages? This cannot be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete conversation'),
                ),
              ],
            );
          },
        );
        if (identical(_confirmationContext, confirmation))
          _confirmationContext = null;
        if (!mounted ||
            approved != true ||
            !widget.isScopeCurrent() ||
            !identical(binding.scope, widget.config.binding.scope)) return;
        final state = binding.read();
        final current = (state['rows'] as List? ?? const []).cast<Map>().where(
              (row) => row['id'] == id,
            );
        if (current.length != 1 ||
            current.single['version'] != version ||
            current.single['running'] == true ||
            current.single['deletionPending'] == true ||
            (state['catalogActions'] as Map?)?['permanentDelete'] != true) {
          _error = 'The conversation changed. Review it before deleting.';
          return;
        }
        await binding.delete(id, version);
      });

  Future<void> _act(
    Future<void> Function() action, {
    bool close = false,
  }) async {
    if (_acting || !widget.isScopeCurrent()) return;
    final scope = widget.config.binding.scope, generation = ++_actionGeneration;
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action();
      if (mounted &&
          generation == _actionGeneration &&
          identical(scope, widget.config.binding.scope) &&
          close) widget.close?.call();
    } catch (_) {
      if (mounted &&
          generation == _actionGeneration &&
          identical(scope, widget.config.binding.scope))
        _error =
            'The conversation change could not be confirmed. Retry the same action.';
    } finally {
      if (mounted &&
          generation == _actionGeneration &&
          identical(scope, widget.config.binding.scope))
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
          final catalogActions = state['catalogActions'] as Map? ?? const {};
          final pendingDeletions =
              (state['pendingDeletions'] as List? ?? const []).cast<Map>();
          final view = state['view'] as String? ?? 'active';
          final error = state['error'] as String? ?? _error;
          final compactNew = MediaQuery.sizeOf(context).width /
                  (MediaQuery.textScalerOf(context).scale(16) / 16) <
              360;
          return Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.config.title,
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              if (compactNew)
                                IconButton(
                                  tooltip: widget.config.newLabel,
                                  key: widget.config.newButtonKey,
                                  onPressed: busy || state['canCreate'] == false
                                      ? null
                                      : () => _act(binding.create, close: true),
                                  icon: const Icon(Icons.add),
                                )
                              else
                                TextButton.icon(
                                  key: widget.config.newButtonKey,
                                  onPressed: busy || state['canCreate'] == false
                                      ? null
                                      : () => _act(binding.create, close: true),
                                  icon: const Icon(Icons.add),
                                  label: Text(widget.config.newLabel),
                                ),
                              if (widget.close != null)
                                IconButton(
                                  tooltip: 'Close conversations',
                                  onPressed: widget.close,
                                  icon: const Icon(Icons.close),
                                ),
                            ],
                          ),
                        ),
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
                                    : (_) => _act(() => binding.view('active')),
                              ),
                              if (widget.config.showArchived)
                                ChoiceChip(
                                  label: const Text('Archived'),
                                  selected: view == 'archived',
                                  onSelected: busy
                                      ? null
                                      : (_) =>
                                          _act(() => binding.view('archived')),
                                ),
                              if (widget.config.showUnread)
                                FilterChip(
                                  label: Text(
                                    'Unread (${state['unreadCount'] ?? 0})',
                                  ),
                                  selected: state['unreadOnly'] == true,
                                  onSelected: busy ? null : binding.unread,
                                ),
                              IconButton(
                                tooltip: 'Refresh conversations',
                                onPressed: busy || state['loading'] == true
                                    ? null
                                    : () => _act(binding.refresh),
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ),
                        if (state['loading'] == true)
                          const LinearProgressIndicator(
                            semanticsLabel: 'Loading conversations',
                          ),
                        if (state['voiceError'] != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Semantics(
                              liveRegion: true,
                              child: Column(
                                children: [
                                  Text(switch (state['voiceErrorCode']) {
                                    'scopeLimit' =>
                                      'Voice history is too large to refresh. '
                                          'Existing activity is still shown.',
                                    'invalidScope' =>
                                      'Voice activity could not be checked for this history. '
                                          'Existing activity is still shown.',
                                    _ =>
                                      'Could not refresh voice activity. Retrying…',
                                  }),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => _act(binding.refresh),
                                    child: const Text('Retry voice activity'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Semantics(
                              liveRegion: true,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    error,
                                    style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error,
                                    ),
                                  ),
                                  Align(
                                    alignment: AlignmentDirectional.centerEnd,
                                    child: TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => _act(binding.refresh),
                                      child: const Text('Retry history'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (pendingDeletions.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          for (final pending in pendingDeletions)
                            ListTile(
                              title:
                                  const Text('Conversation deletion pending'),
                              subtitle: Text(
                                pending['error'] as String? ??
                                    'Checking the saved deletion result…',
                              ),
                              trailing: TextButton(
                                onPressed: _acting ||
                                        pending['busy'] == true ||
                                        state['canManageConversations'] == false
                                    ? null
                                    : () => _act(
                                          () => binding.delete(
                                            pending['id'] as String,
                                            pending['version'] as int,
                                          ),
                                        ),
                                child: const Text('Retry deletion'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (rows.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            state['loading'] == true
                                ? 'Loading conversations…'
                                : state['unreadOnly'] == true
                                    ? (state['hasMore'] == true
                                        ? 'No unread conversations in the loaded history.'
                                        : 'No unread conversations.')
                                    : view == 'archived'
                                        ? 'No archived conversations.'
                                        : 'No conversations yet.',
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final row = rows[index], id = row['id'] as String;
                        final archived = row['lifecycle'] == 'archived';
                        final date = DateTime.tryParse(
                          row['updatedAt'] as String? ?? '',
                        );
                        return ListTile(
                          key: ValueKey('handrail-conversation-$id'),
                          selected: state['selectedId'] == id,
                          selectedTileColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer.withValues(alpha: .35),
                          onTap: busy || row['deletionPending'] == true
                              ? null
                              : () => _act(() => binding.open(id), close: true),
                          leading: row['running'] == true
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : row['unread'] == true
                                  ? Icon(
                                      Icons.circle,
                                      size: 10,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    )
                                  : null,
                          title: Text(
                            row['title'] as String? ?? 'New conversation',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: row['unread'] == true
                                  ? FontWeight.w600
                                  : null,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if ((row['preview'] as String? ?? '').isNotEmpty)
                                Text(
                                  row['preview'] as String,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (date != null)
                                Text(
                                  MaterialLocalizations.of(
                                    context,
                                  ).formatShortDate(date.toLocal()),
                                ),
                              if (_activityLabels(row).isNotEmpty)
                                Text(_activityLabels(row).join(' · ')),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.config.showArchived &&
                                  catalogActions[
                                          archived ? 'restore' : 'archive'] ==
                                      true)
                                IconButton(
                                  tooltip: archived
                                      ? 'Restore conversation'
                                      : 'Archive conversation',
                                  onPressed: busy ||
                                          row['running'] == true ||
                                          row['deletionPending'] == true
                                      ? null
                                      : () => _act(
                                            () => archived
                                                ? binding.restore(id)
                                                : binding.archive(id),
                                          ),
                                  icon: Icon(
                                    archived
                                        ? Icons.unarchive_outlined
                                        : Icons.archive_outlined,
                                  ),
                                ),
                              if (catalogActions['permanentDelete'] == true)
                                IconButton(
                                  tooltip: 'Delete conversation',
                                  onPressed: busy ||
                                          row['running'] == true ||
                                          row['deletionPending'] == true ||
                                          row['version'] is! int
                                      ? null
                                      : () => _delete(Map.of(row)),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  if (state['hasMore'] == true)
                    SliverToBoxAdapter(
                      child: TextButton(
                        onPressed: busy || state['loading'] == true
                            ? null
                            : () => _act(binding.loadMore),
                        child: const Text('Older conversations'),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
}

// Voice has its own state and read receipts. Never reuse `running` for voice:
// the latter would disable otherwise valid text and catalog controls.
List<String> _activityLabels(Map row) {
  final voice = row['voice'] is Map ? row['voice'] as Map : const {};
  final active = voice['activeCalls'] as int? ?? 0,
      unconfirmed = voice['unconfirmedCalls'] as int? ?? 0,
      unread = voice['unreadCalls'] as int? ?? 0,
      unresolved = voice['unresolvedTools'] as int? ?? 0;
  String calls(int count) => '$count voice ${count == 1 ? 'call' : 'calls'}';
  return [
    if (row['running'] == true) 'Text assistant working',
    if (active > 0)
      '${calls(active)} ${voice['stale'] == true ? 'last reported active' : 'active'}',
    if (unconfirmed > 0) '${calls(unconfirmed)} awaiting end confirmation',
    if (unread > 0) '${calls(unread)} with unread results',
    if (unresolved > 0)
      '$unresolved voice ${unresolved == 1 ? 'action' : 'actions'} awaiting a confirmed outcome',
  ];
}
