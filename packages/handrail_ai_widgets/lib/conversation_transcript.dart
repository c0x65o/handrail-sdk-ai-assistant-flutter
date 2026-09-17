import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'markdown.dart';
import 'display_transcript.dart';

/// Matches the account controller without coupling the two SDK packages.
typedef HandrailTranscriptUiBinding = ({
  Object scope,
  Stream<Object?> changes,
  Map<String, Object?> Function() read,
  Future<void> Function() retry,
  Future<void> Function() markRead,
});

/// Host branding for the standard bubbles; behavior remains in the SDK.
class HandrailTranscriptStyle {
  const HandrailTranscriptStyle({
    this.userBackground,
    this.userForeground,
    this.assistantBackground,
    this.assistantForeground,
    this.textStyle,
    this.maximumMessageWidth = 760,
    this.assistantAvatar,
    this.showAuthor = false,
    this.userLabel = 'You',
    this.assistantLabel = 'Assistant',
    this.systemLabel = 'System',
    this.toolLabel = 'Tool result',
  });
  final Color? userBackground,
      userForeground,
      assistantBackground,
      assistantForeground;
  final TextStyle? textStyle;
  final double maximumMessageWidth;
  final Widget? assistantAvatar;

  /// Show normal chat author labels. System/tool labels remain visible so
  /// operational messages cannot be mistaken for an assistant answer.
  final bool showAuthor;
  final String userLabel, assistantLabel, systemLabel, toolLabel;
}

/// Standard transcript, scrolling, read acknowledgement and error recovery.
/// Domain renderers add business results; hosts supply safe application routing.
class HandrailConversationTranscript extends StatefulWidget {
  const HandrailConversationTranscript({
    super.key,
    required this.binding,
    this.style = const HandrailTranscriptStyle(),
    this.onOpenLink,
    this.allowMessageLinks = true,
    this.copyText,
    this.citationLink,
    this.attachmentBuilder,
    this.toolResultBuilder,
    this.contentBuilder,
    this.positionStore,
    this.trailing = const [],
    this.emptyBuilder,
    this.showCopy = true,
    this.showCitations = true,
    this.showToolActivity = true,
    this.loadingLabel = 'Loading conversation',
    this.workingLabel = 'Working…',
    this.failureLabel = 'The request could not be completed.',
    this.errorLabel,
    this.errorKey,
    this.retryKey,
    this.padding = const EdgeInsets.all(16),
  });
  final HandrailTranscriptUiBinding binding;
  final HandrailTranscriptStyle style;
  final ValueChanged<String>? onOpenLink;

  /// Host navigation policy for raw message links, independent of citations.
  final bool allowMessageLinks;
  final Future<void> Function(String)? copyText;
  final String? Function(Map<String, Object?> source)? citationLink;
  final Widget? Function(BuildContext context, Map<String, Object?> attachment)?
  attachmentBuilder;
  final Widget? Function(BuildContext context, Map<String, Object?> toolCall)?
  toolResultBuilder;

  /// Optional full formatting for an existing domain transcript projection.
  /// Scrolling, account isolation and visible read acknowledgement stay shared.
  /// Omit this to get the standard messages, actions, activity and recovery UI.
  final List<Widget> Function(
    BuildContext context,
    Map<String, Object?> document,
  )?
  contentBuilder;
  final List<Widget> trailing;

  /// Defaults to the account controller's durable position store when supplied.
  final HandrailDisplayPositionStore? positionStore;
  final WidgetBuilder? emptyBuilder;
  final bool showCopy, showCitations, showToolActivity;
  final String loadingLabel, workingLabel, failureLabel;
  final String? errorLabel;
  final Key? errorKey, retryKey;
  final EdgeInsetsGeometry padding;
  @override
  State<HandrailConversationTranscript> createState() => _TranscriptState();
}

class _TranscriptState extends State<HandrailConversationTranscript>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _viewportKey = GlobalKey(), _tailKey = GlobalKey();
  bool _adjustingScroll = false;
  final _positions = <String, ({double offset, bool follow})>{};
  StreamSubscription<Object?>? _subscription;
  Map<String, Object?> _state = const {};
  String? _conversationId, _readRevision;
  bool _followEnd = true,
      _scheduled = false,
      _foreground = true,
      _retrying = false;
  String? _localError;
  int _epoch = 0;
  double? _restoreOffset;
  HandrailDisplayPositionStore? _displayPositions;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _scroll.addListener(_scrolled);
    _connect();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Returning from another route or enabling this surface can make an
    // already-completed reply visible without a new server event.
    _schedule();
  }

  @override
  void didUpdateWidget(HandrailConversationTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding.scope, widget.binding.scope)) {
      unawaited(_subscription?.cancel());
      _epoch++;
      _positions.clear();
      _conversationId = null;
      _readRevision = null;
      _localError = null;
      _retrying = false;
      _followEnd = true;
      _connect();
    } else {
      _receive();
    }
  }

  void _connect() {
    _receive();
    final read = _state['readPosition'], write = _state['writePosition'];
    _displayPositions =
        read is Future<Map<String, Object?>?> Function(String) &&
            write is Future<void> Function(String, Map<String, Object?>)
        ? HandrailDisplayPositionStore.callbacks(read: read, write: write)
        : null;
    _subscription = widget.binding.changes.listen((_) {
      if (mounted) setState(_receive);
    });
  }

  void _receive() {
    final next = widget.binding.read();
    final id = next['conversationId'] as String?;
    if (id != _conversationId) {
      if (_conversationId != null && _scroll.hasClients) {
        _positions[_conversationId!] = (
          offset: _scroll.offset,
          follow: _followEnd,
        );
      }
      _epoch++;
      _conversationId = id;
      final previous = _positions[id];
      _followEnd = previous?.follow ?? true;
      _restoreOffset = previous?.offset;
      _readRevision = null;
      _localError = null;
      _retrying = false;
    }
    _state = next;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      _adjustingScroll = true;
      try {
        if (_followEnd) {
          _scroll.jumpTo(position.maxScrollExtent);
        } else if (_restoreOffset != null) {
          _scroll.jumpTo(_restoreOffset!.clamp(0, position.maxScrollExtent));
        }
      } finally {
        _adjustingScroll = false;
      }
      _restoreOffset = null;
      _markVisibleRead();
    });
  }

  void _scrolled() {
    if (!_scroll.hasClients || !mounted) return;
    final follow = _scroll.position.extentAfter < 72;
    if (!_adjustingScroll && _followEnd != follow)
      setState(() => _followEnd = follow);
    _markVisibleRead();
  }

  void _markVisibleRead() {
    if (!mounted ||
        !_foreground ||
        !_scroll.hasClients ||
        _scroll.position.extentAfter >= 72 ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false ||
        _state['running'] == true ||
        _state['pending'] == true ||
        _conversationId == null)
      return;
    final document = _map(_state['document']);
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final tail = _tailKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox ||
        tail is! RenderBox ||
        !viewport.attached ||
        !tail.attached)
      return;
    final bottom = tail.localToGlobal(Offset(0, tail.size.height)).dy;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    if (bottom < viewportTop || bottom > viewportTop + viewport.size.height + 1)
      return;
    final turns = _records(document['turns']);
    if (turns.isEmpty ||
        !const [
          'completed',
          'failed',
          'cancelled',
        ].contains(turns.last['status']))
      return;
    final revision = '$_conversationId:${document['revision']}';
    if (_readRevision == revision) return;
    _readRevision = revision;
    final epoch = _epoch;
    unawaited(
      widget.binding.markRead().catchError((Object _) {
        if (mounted && epoch == _epoch && _readRevision == revision)
          _readRevision = null;
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _schedule();
  }

  Future<void> _retry() async {
    if (_retrying || _state['busy'] == true) return;
    final scope = widget.binding.scope, epoch = _epoch;
    setState(() {
      _retrying = true;
      _localError = null;
    });
    try {
      await widget.binding.retry();
    } catch (_) {
      if (mounted &&
          identical(scope, widget.binding.scope) &&
          epoch == _epoch) {
        setState(
          () => _localError =
              'The conversation could not be refreshed. Try again.',
        );
      }
    } finally {
      if (mounted && identical(scope, widget.binding.scope) && epoch == _epoch)
        setState(() => _retrying = false);
    }
  }

  @override
  void dispose() {
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _scroll.dispose();
    super.dispose();
  }

  List<Widget> _defaultContents(
    BuildContext context, {
    bool includeMessages = true,
  }) {
    final document = _map(_state['document']);
    final messages = _records(document['messages'])
        .where(
          (message) => const ['user', 'assistant'].contains(message['role']),
        )
        .toList();
    final turns = _records(document['turns']);
    final tools = _records(document['tool_calls']);
    final sources = {
      for (final source in _records(document['citation_sources']))
        source['source_id']: source,
    };
    final citations = _records(document['citations']);
    final renderedTools = <Object?>{};
    final children = <Widget>[];
    if (messages.isEmpty && includeMessages)
      children.add(
        widget.emptyBuilder?.call(context) ??
            const Padding(
              padding: EdgeInsets.all(28),
              child: Text('No messages yet.'),
            ),
      );
    void addTool(Map<String, Object?> tool) {
      if (!renderedTools.add(tool['tool_call_id'])) return;
      final content = widget.toolResultBuilder?.call(context, tool);
      if (content != null)
        children.add(
          KeyedSubtree(
            key: ValueKey((
              widget.binding.scope,
              _conversationId,
              tool['tool_call_id'],
            )),
            child: content,
          ),
        );
    }

    for (final message
        in includeMessages ? messages : <Map<String, Object?>>[]) {
      final id = message['message_id'];
      final attachedCitations =
          citations.where((citation) {
            final target = _map(citation['target']);
            return target['type'] == 'assistant_message' &&
                target['message_id'] == id;
          }).toList()..sort(
            (a, b) => ((a['order'] as num?) ?? 0).compareTo(
              (b['order'] as num?) ?? 0,
            ),
          );
      children.add(
        HandrailTranscriptMessage(
          key: ValueKey((widget.binding.scope, _conversationId, id)),
          message: message,
          style: widget.style,
          showCopy: widget.showCopy,
          citations: widget.showCitations
              ? [
                  for (final citation in attachedCitations)
                    if (sources[citation['source_id']] case final source?)
                      source,
                ]
              : const [],
          citationLink: widget.citationLink,
          onOpenLink: widget.onOpenLink,
          allowMessageLinks: widget.allowMessageLinks,
          copyText: widget.copyText,
          attachmentBuilder: widget.attachmentBuilder,
        ),
      );
      for (final turn in turns) {
        final outputs = turn['output_message_ids'] as List? ?? const [];
        final inputs = turn['input_message_ids'] as List? ?? const [];
        if ((outputs.isNotEmpty ? outputs.last : inputs.lastOrNull) != id)
          continue;
        for (final tool in tools.where(
          (tool) => tool['turn_id'] == turn['turn_id'],
        ))
          addTool(tool);
      }
    }
    for (final tool in tools) addTool(tool);
    if (widget.trailing.isNotEmpty)
      children.add(
        KeyedSubtree(
          key: ValueKey((widget.binding.scope, _conversationId, 'trailing')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.trailing,
          ),
        ),
      );
    if (widget.showToolActivity && tools.isNotEmpty)
      children.add(
        _ToolActivity(
          key: ValueKey((widget.binding.scope, _conversationId, 'activity')),
          tools: tools,
        ),
      );
    if (_state['running'] == true || _state['submitting'] == true)
      children.add(
        Padding(
          padding: const EdgeInsets.all(12),
          child: Semantics(liveRegion: true, child: Text(widget.workingLabel)),
        ),
      );
    final error = _state['error'] as String? ?? _localError;
    if (error != null || _state['pending'] == true) {
      children.add(
        HandrailTranscriptNotice(
          key: widget.errorKey,
          message: error == null
              ? 'Checking your saved message…'
              : widget.errorLabel ?? error,
          isError: error != null,
          actionLabel: _retrying ? 'Retrying…' : 'Retry',
          actionKey: widget.retryKey,
          onAction: _state['busy'] == true || _retrying ? null : _retry,
        ),
      );
    } else if (turns.isNotEmpty && turns.last['status'] == 'failed') {
      children.add(
        HandrailTranscriptNotice(message: widget.failureLabel, isError: true),
      );
    } else if (turns.isNotEmpty && turns.last['status'] == 'cancelled') {
      children.add(
        const HandrailTranscriptNotice(message: 'Response stopped.'),
      );
    }
    if (_state['archived'] == true)
      children.add(
        const HandrailTranscriptNotice(
          message:
              'Archived conversations are read-only. Restore this conversation to continue.',
        ),
      );
    return children;
  }

  @override
  Widget build(BuildContext context) {
    final display = _state['displayWindow'];
    if (display is HandrailDisplayTranscriptBinding &&
        widget.contentBuilder == null) {
      final document = _map(_state['document']);
      final sources = {
        for (final source in _records(document['citation_sources']))
          source['source_id']: source,
      };
      return HandrailDisplayTranscript(
        binding: display,
        conversationId: _conversationId,
        positionStore: widget.positionStore ?? _displayPositions,
        manageSelection: false,
        pollInterval: null,
        padding: widget.padding.resolve(Directionality.of(context)),
        style: widget.style,
        onOpenLink: widget.onOpenLink,
        attachmentBuilder: widget.attachmentBuilder,
        canMarkRead:
            _state['running'] != true &&
            _state['pending'] != true &&
            document['revision'] == display.read()['revision'],
        onVisibleLatest: (_, revision) {
          // Read only the revision represented by the account's current view.
          if (_state['running'] == true ||
              _state['pending'] == true ||
              document['revision'] != revision)
            return;
          unawaited(widget.binding.markRead().catchError((Object _) {}));
        },
        messageBuilder: (context, record) {
          final message = _map(record['value']);
          final citations =
              _records(document['citations'])
                  .where(
                    (citation) =>
                        _map(citation['target'])['message_id'] ==
                        message['message_id'],
                  )
                  .toList()
                ..sort(
                  (a, b) => ((a['order'] as num?) ?? 0).compareTo(
                    (b['order'] as num?) ?? 0,
                  ),
                );
          return HandrailTranscriptMessage(
            message: message,
            style: widget.style,
            showCopy: widget.showCopy,
            allowMessageLinks: widget.allowMessageLinks,
            copyText: widget.copyText,
            attachmentBuilder: widget.attachmentBuilder,
            onOpenLink: widget.onOpenLink,
            citationLink: widget.citationLink,
            citations: widget.showCitations
                ? [
                    for (final citation in citations)
                      if (sources[citation['source_id']] case final source?)
                        source,
                  ]
                : const [],
          );
        },
        trailing: [
          ..._defaultContents(context, includeMessages: false),
          if (_state['hasMoreRelated'] == true &&
              _state['loadMoreRelated'] is Future<void> Function())
            TextButton(
              onPressed: () => unawaited(
                (_state['loadMoreRelated'] as Future<void> Function())()
                    .catchError((Object _) {
                      if (mounted)
                        setState(
                          () => _localError =
                              'Activity could not be loaded. Try again.',
                        );
                    }),
              ),
              child: const Text('Load earlier activity'),
            ),
        ],
      );
    }
    if (_state['loading'] == true)
      return Center(
        child: CircularProgressIndicator(semanticsLabel: widget.loadingLabel),
      );
    final formatted = widget.contentBuilder?.call(
      context,
      _map(_state['document']),
    );
    final children = <Widget>[
      if (formatted != null)
        for (var i = 0; i < formatted.length; i++)
          KeyedSubtree(
            key: ValueKey((
              widget.binding.scope,
              _conversationId,
              formatted[i].key ?? i,
            )),
            child: formatted[i],
          ),
      if (formatted == null) ..._defaultContents(context),
    ];
    children.add(SizedBox(key: _tailKey, height: 1));
    return Stack(
      key: _viewportKey,
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            if (_followEnd) _schedule();
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (event) {
              if (event is ScrollStartNotification && event.dragDetails != null)
                _adjustingScroll = false;
              return false;
            },
            child: ListView(
              controller: _scroll,
              padding: widget.padding,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: children,
            ),
          ),
        ),
        if (!_followEnd)
          PositionedDirectional(
            end: 16,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Jump to latest',
              onPressed: () {
                setState(() => _followEnd = true);
                _schedule();
              },
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }
}

/// Reusable message presentation for hosts with a custom business transcript.
class HandrailTranscriptMessage extends StatefulWidget {
  const HandrailTranscriptMessage({
    super.key,
    required this.message,
    this.style = const HandrailTranscriptStyle(),
    this.citations = const [],
    this.showCopy = true,
    this.onOpenLink,
    this.allowMessageLinks = true,
    this.copyText,
    this.citationLink,
    this.citationKey,
    this.attachmentBuilder,
  });
  final Map<String, Object?> message;
  final HandrailTranscriptStyle style;
  final List<Map<String, Object?>> citations;
  final bool showCopy;
  final ValueChanged<String>? onOpenLink;

  /// Host navigation policy for raw message links, independent of citations.
  final bool allowMessageLinks;
  final Future<void> Function(String)? copyText;
  final String? Function(Map<String, Object?> source)? citationLink;
  final Key Function(Map<String, Object?> source)? citationKey;
  final Widget? Function(BuildContext, Map<String, Object?>)? attachmentBuilder;
  @override
  State<HandrailTranscriptMessage> createState() => _MessageState();
}

class _MessageState extends State<HandrailTranscriptMessage> {
  Timer? _copiedTimer;
  bool _copied = false, _copyFailed = false;
  int _copyGeneration = 0;
  String get _text => _records(widget.message['content'])
      .where((part) => part['type'] == 'text')
      .map((part) => part['text'] as String? ?? '')
      .join();
  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(HandrailTranscriptMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message['message_id'] != widget.message['message_id']) {
      _copiedTimer?.cancel();
      _copied = false;
      _copyFailed = false;
      _copyGeneration++;
    }
  }

  Future<void> _copy() async {
    final id = widget.message['message_id'];
    final generation = ++_copyGeneration;
    _copiedTimer?.cancel();
    setState(() {
      _copied = false;
      _copyFailed = false;
    });
    try {
      if (widget.copyText case final copy?) {
        await copy(_text);
      } else {
        await Clipboard.setData(ClipboardData(text: _text));
      }
      if (!mounted ||
          widget.message['message_id'] != id ||
          generation != _copyGeneration)
        return;
      setState(() => _copied = true);
      _copiedTimer?.cancel();
      _copiedTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (!mounted ||
          widget.message['message_id'] != id ||
          generation != _copyGeneration)
        return;
      setState(() => _copyFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context),
        style = widget.style,
        user = widget.message['role'] == 'user';
    final role = widget.message['role'];
    final author = switch (role) {
      'user' => style.userLabel,
      'assistant' => style.assistantLabel,
      'system' => style.systemLabel,
      'tool' => style.toolLabel,
      _ => 'Message',
    };
    final semanticRole = switch (role) {
      'user' || 'assistant' || 'system' || 'tool' => '$role message',
      _ => 'message',
    };
    final foreground = user
        ? style.userForeground ?? theme.colorScheme.onPrimaryContainer
        : style.assistantForeground ?? theme.colorScheme.onSurface;
    final textStyle =
        (style.textStyle ?? theme.textTheme.bodyMedium ?? const TextStyle())
            .copyWith(color: foreground);
    final attachments = _records(widget.message['attachments']);
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: style.maximumMessageWidth),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: user
            ? style.userBackground ?? theme.colorScheme.primaryContainer
            : style.assistantBackground ?? theme.colorScheme.surface,
        border: user
            ? null
            : Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (style.showAuthor || (role != 'user' && role != 'assistant'))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                author,
                style: textStyle.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          HandrailMarkdown(
            data: _text,
            isUserMessage: widget.message['role'] != 'assistant',
            selectable: true,
            styleSheet: MarkdownStyleSheet(p: textStyle),
            onTapLink: (text, href, title) {
              if (widget.allowMessageLinks &&
                  handrailSafeConversationLink(href))
                widget.onOpenLink?.call(href);
            },
          ),
          for (final attachment in attachments)
            widget.attachmentBuilder?.call(context, attachment) ??
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(
                    attachment['filename'] as String? ?? 'Attachment',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          if (widget.citations.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final source in widget.citations)
                    Builder(
                      builder: (context) {
                        // A configured resolver returning null vetoes navigation.
                        // Falling back here would bypass host source validation.
                        final href = widget.citationLink != null
                            ? widget.citationLink!(source)
                            : source['locator'] as String?;
                        return ActionChip(
                          key: widget.citationKey?.call(source),
                          label: Text(
                            source['label'] as String? ?? 'Source',
                            overflow: TextOverflow.ellipsis,
                          ),
                          avatar: const Icon(Icons.link, size: 16),
                          onPressed:
                              widget.onOpenLink != null &&
                                  handrailSafeConversationLink(href)
                              ? () => widget.onOpenLink!(href!)
                              : null,
                        );
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '$author, $semanticRole.',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: user
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            if (role == 'assistant' && style.assistantAvatar != null) ...[
              style.assistantAvatar!,
              const SizedBox(width: 8),
            ],
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: style.maximumMessageWidth,
                ),
                child: Column(
                  crossAxisAlignment: user
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    bubble,
                    // Actions sit on the conversation surface,
                    // outside the content bubble. Keep full touch
                    // targets without extending the user color
                    // behind an unrelated action row.
                    if (widget.showCopy && _text.isNotEmpty)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: _copy,
                          icon: Icon(
                            _copied ? Icons.check : Icons.copy_outlined,
                            size: 15,
                          ),
                          label: Text(_copied ? 'Copied' : 'Copy'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (_copyFailed)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          'The message was not copied. Try Copy again.',
                          style: textStyle.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HandrailTranscriptNotice extends StatelessWidget {
  const HandrailTranscriptNotice({
    super.key,
    required this.message,
    this.isError = false,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });
  final String message;
  final bool isError;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            style: TextStyle(
              color: isError ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          if (actionLabel != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: actionKey,
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ToolActivity extends StatelessWidget {
  const _ToolActivity({super.key, required this.tools});
  final List<Map<String, Object?>> tools;
  @override
  Widget build(BuildContext context) {
    final failed = tools
        .where((tool) => _map(tool['result'])['is_error'] == true)
        .length;
    return ExpansionTile(
      title: Text(
        '${tools.length} ${tools.length == 1 ? 'tool called' : 'tools called'}${failed == 0 ? '' : ' · $failed failed'}',
      ),
      children: [
        for (final tool in tools)
          ListTile(
            dense: true,
            title: Text(tool['name'] as String? ?? 'Tool'),
            subtitle: Text(
              _map(tool['result'])['is_error'] == true
                  ? 'Failed'
                  : tool['result'] == null
                  ? 'Working'
                  : 'Completed',
            ),
          ),
      ],
    );
  }
}

/// Blocks executable/local URLs before handing navigation to the host router.
bool handrailSafeConversationLink(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\\]').hasMatch(value))
    return false;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.userInfo.isNotEmpty) return false;
  return !uri.hasScheme
      ? value.startsWith('/') && !value.startsWith('//')
      : const ['http', 'https'].contains(uri.scheme) && uri.host.isNotEmpty;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const {};
List<Map<String, Object?>> _records(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((value) => Map<String, Object?>.from(value))
          .toList()
    : const [];
