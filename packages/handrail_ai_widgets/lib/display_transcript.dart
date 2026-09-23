import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'conversation_transcript.dart';
import 'large_message.dart';

/// Matches HandrailDisplayWindow.uiBinding without a dependency on the client.
typedef HandrailDisplayTranscriptBinding = ({
  Object scope,
  Stream<Object?> changes,
  Map<String, Object?> Function() read,
  Future<void> Function(String?, Map<String, Object?>?) select,
  Future<void> Function() older,
  Future<void> Function() newer,
  Future<void> Function() latest,
  Future<void> Function() refresh,
  Future<void> Function() retry,
});

/// Stable message identity and pixel offset, independent of evicted pages.
class HandrailDisplayPosition {
  final String messageId;
  final int generation;
  final double offset;
  final bool following;
  const HandrailDisplayPosition({
    required this.messageId,
    required this.generation,
    required this.offset,
    required this.following,
  });
}

/// Optional durable account-scoped storage. Implementations must not share
/// positions between accounts. The widget's default memory cache holds 32 chats.
abstract interface class HandrailDisplayPositionStore {
  factory HandrailDisplayPositionStore.callbacks({
    required Future<Map<String, Object?>?> Function(String) read,
    required Future<void> Function(String, Map<String, Object?>) write,
  }) = _CallbackDisplayPositionStore;
  Future<HandrailDisplayPosition?> read(String conversationId);
  Future<void> write(String conversationId, HandrailDisplayPosition position);
}

class _CallbackDisplayPositionStore implements HandrailDisplayPositionStore {
  _CallbackDisplayPositionStore({
    required Future<Map<String, Object?>?> Function(String) read,
    required Future<void> Function(String, Map<String, Object?>) write,
  }) : _read = read,
       _write = write;
  final Future<Map<String, Object?>?> Function(String) _read;
  final Future<void> Function(String, Map<String, Object?>) _write;
  @override
  Future<HandrailDisplayPosition?> read(String id) async {
    final value = await _read(id);
    if (value == null) return null;
    final message = value['messageId'],
        generation = value['generation'],
        offset = value['offset'];
    if (message is! String ||
        message.isEmpty ||
        message.length > 512 ||
        generation is! int ||
        generation < 0 ||
        offset is! num ||
        !offset.isFinite ||
        offset.abs() > 100000000 ||
        value['following'] is! bool)
      return null;
    return HandrailDisplayPosition(
      messageId: message,
      generation: generation,
      offset: offset.toDouble(),
      following: value['following'] as bool,
    );
  }

  @override
  Future<void> write(String id, HandrailDisplayPosition value) => _write(id, {
    'messageId': value.messageId,
    'generation': value.generation,
    'offset': value.offset,
    'following': value.following,
  });
}

/// A bounded display window, explicitly separate from the canonical transcript.
/// Only the selected page is loaded. Older/newer pages require scrolling or a
/// button; following live output replaces the tail in one bounded request.
/// Only viewport-adjacent message bodies are mounted. Measured placeholders
/// preserve scroll extent and message anchors when older pages are evicted.
class HandrailDisplayTranscript extends StatefulWidget {
  const HandrailDisplayTranscript({
    super.key,
    required this.binding,
    required this.conversationId,
    this.positionStore,
    this.manageSelection = true,
    this.loadEarlierActivity,
    this.trailing = const [],
    this.style = const HandrailTranscriptStyle(),
    this.messageBuilder,
    this.deferredBuilder,
    this.attachmentBuilder,
    this.onOpenLink,
    this.onVisibleLatest,
    this.canMarkRead = true,
    this.pollInterval = const Duration(seconds: 1),
    this.padding = const EdgeInsets.all(16),
  });
  final HandrailDisplayTranscriptBinding binding;
  final String? conversationId;
  final HandrailDisplayPositionStore? positionStore;

  /// False when an account-owned session already manages selection and cleanup.
  final bool manageSelection;

  /// Loads one bounded page of related activity at the history edge.
  final Future<void> Function()? loadEarlierActivity;
  final List<Widget> trailing;
  final HandrailTranscriptStyle style;
  final Widget Function(BuildContext, Map<String, Object?>)? messageBuilder;
  final Widget Function(BuildContext, Map<String, Object?>)? deferredBuilder;
  final Widget? Function(BuildContext, Map<String, Object?>)? attachmentBuilder;
  final ValueChanged<String>? onOpenLink;

  /// Called only when the latest loaded page is visible in the foreground.
  /// Hosts should use the revision to make read acknowledgements idempotent.
  final void Function(String conversationId, int revision)? onVisibleLatest;
  final bool canMarkRead;
  final Duration? pollInterval;
  final EdgeInsets padding;
  @override
  State<HandrailDisplayTranscript> createState() => _DisplayTranscriptState();
}

class _DisplayTranscriptState extends State<HandrailDisplayTranscript>
    with WidgetsBindingObserver {
  final _scroll = ScrollController(), _viewport = GlobalKey();
  final _keys = <String, GlobalKey>{};
  final _heights = <String, double>{};
  final _rendered = <String>{};
  double _renderedOffset = 0;
  double? _layoutWidth;
  final _positions = LinkedHashMap<String, HandrailDisplayPosition>();
  StreamSubscription<Object?>? _subscription;
  Timer? _poll;
  Timer? _saveTimer;
  Map<String, Object?> _state = const {};
  HandrailDisplayPosition? _anchor;
  bool _follow = true,
      _adjusting = false,
      _scheduled = false,
      _foreground = true,
      _requesting = false;
  bool _restoring = false;
  int _epoch = 0;
  String? _localError, _readIdentity;
  String? _expandedMessage;

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
    _schedule();
  }

  @override
  void didUpdateWidget(HandrailDisplayTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding.scope, widget.binding.scope) ||
        oldWidget.conversationId != widget.conversationId) {
      _save(oldWidget.conversationId, oldWidget.positionStore);
      if (!identical(oldWidget.binding.scope, widget.binding.scope)) {
        _positions.clear();
        if (oldWidget.manageSelection)
          unawaited(
            oldWidget.binding.select(null, null).catchError((Object _) {}),
          );
      }
      unawaited(_subscription?.cancel());
      _connect();
    } else if (oldWidget.pollInterval != widget.pollInterval) {
      _startPolling();
    }
    _schedule();
  }

  void _connect() {
    _expandedMessage = null;
    final epoch = ++_epoch;
    _state = const {};
    _keys.clear();
    _heights.clear();
    _rendered.clear();
    _layoutWidth = null;
    _anchor = null;
    _follow = true;
    _requesting = false;
    _scheduled = false;
    _localError = _readIdentity = null;
    _restoring = true;
    _subscription = widget.binding.changes.listen((_) {
      if (mounted && epoch == _epoch) setState(_receive);
    });
    _startPolling();
    unawaited(_select(epoch));
  }

  Future<void> _select(int epoch) async {
    final binding = widget.binding, id = widget.conversationId;
    // Cancel the previous selection before waiting for durable scroll storage.
    // A slow preference read must not keep fetching the previous account/chat.
    try {
      if (widget.manageSelection)
        await binding.select(null, null);
      else
        _receive();
    } catch (_) {
      if (mounted && epoch == _epoch) {
        _restoring = false;
        setState(
          () => _localError = 'Conversation history is unavailable. Try again.',
        );
      }
      return;
    }
    if (!mounted || epoch != _epoch) return;
    var saved = id == null ? null : _positions.remove(id);
    if (id != null && widget.positionStore != null) {
      try {
        saved = await widget.positionStore!.read(id) ?? saved;
      } catch (_) {
        /* A position failure must not hide messages. */
      }
    }
    if (!mounted || epoch != _epoch) return;
    if (!widget.manageSelection &&
        _state['status'] == 'ready' &&
        saved?.generation != _state['generation'])
      saved = null;
    _anchor = saved;
    _follow = saved?.following ?? true;
    if (widget.manageSelection ||
        saved != null &&
            !saved.following &&
            !_records.any((record) => record['id'] == saved!.messageId))
      await _request(
        () => binding.select(
          id,
          saved == null || saved.following
              ? null
              : {'messageId': saved.messageId, 'generation': saved.generation},
        ),
      );
    if (!mounted || epoch != _epoch) return;
    _restoring = false;
    final follow = widget.binding.read()['setFollowingLatest'];
    if (follow is void Function(bool)) follow(_follow);
    setState(_receive);
  }

  void _startPolling() {
    _poll?.cancel();
    final interval = widget.pollInterval;
    if (interval == null) return;
    if (interval < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(interval, 'pollInterval');
    }
    _poll = Timer.periodic(interval, (_) {
      if (_visible &&
          widget.conversationId != null &&
          (_state['error'] == null || _state['retryable'] != false)) {
        unawaited(_request(widget.binding.refresh));
      }
    });
  }

  bool get _visible =>
      mounted &&
      _foreground &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;
  bool get _busy => _requesting || _state['loading'] != null;
  List<Map<String, Object?>> get _records =>
      (_state['records'] as List? ?? const []).cast<Map<String, Object?>>();

  void _receive() {
    final next = widget.binding.read();
    if (next['conversationId'] != widget.conversationId) return;
    if (_state['generation'] != null &&
        _state['generation'] != next['generation']) {
      _anchor = null;
      _follow = true;
    }
    final replacedTail =
        next['change'] == 'latest' && next['version'] != _state['version'];
    _state = next;
    if (replacedTail) {
      _follow = true;
      _anchor = null;
    }
    final ids = _records.map((record) => record['id']).toSet();
    if (!ids.contains(_expandedMessage)) _expandedMessage = null;
    _keys.removeWhere((id, _) => !ids.contains(id));
    _heights.removeWhere((id, _) => !ids.contains(id));
    _schedule();
  }

  HandrailDisplayPosition? _capture() {
    final viewport = _viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return _anchor;
    final top = viewport.localToGlobal(Offset.zero).dy;
    for (final record in _records) {
      final id = record['id'] as String;
      final row = _keys[id]?.currentContext?.findRenderObject();
      if (row is! RenderBox || !row.hasSize) continue;
      final offset = row.localToGlobal(Offset.zero).dy - top;
      if (offset + row.size.height > 0 && offset < viewport.size.height) {
        return HandrailDisplayPosition(
          messageId: id,
          generation: _state['generation'] as int,
          offset: offset,
          following: _follow,
        );
      }
    }
    return _anchor;
  }

  void _save(String? id, HandrailDisplayPositionStore? store) {
    final position = _anchor;
    if (id == null || position == null) return;
    _positions.remove(id);
    _positions[id] = position;
    while (_positions.length > 32) {
      _positions.remove(_positions.keys.first);
    }
    if (store != null)
      unawaited(store.write(id, position).catchError((Object _) {}));
  }

  void _scrolled() {
    if (_adjusting || !_scroll.hasClients) return;
    _follow = _scroll.position.extentAfter < 64 && _state['hasNewer'] != true;
    final follow = _state['setFollowingLatest'];
    if (follow is void Function(bool)) follow(_follow);
    _anchor = _capture();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _save(widget.conversationId, widget.positionStore);
    });
    if (mounted) setState(() {});
    if (_busy || _state['error'] != null) return;
    if (_scroll.position.extentBefore < 64 &&
        (_state['hasOlder'] == true || widget.loadEarlierActivity != null)) {
      unawaited(
        _request(
          _state['hasOlder'] == true
              ? widget.binding.older
              : widget.loadEarlierActivity!,
        ),
      );
    } else if (_scroll.position.extentAfter < 64 &&
        _state['hasNewer'] == true) {
      unawaited(_request(widget.binding.newer));
    }
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    final epoch = _epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || epoch != _epoch || !_scroll.hasClients || _restoring)
        return;
      _adjusting = true;
      var measured = false;
      try {
        for (final id in _rendered) {
          final box = _keys[id]?.currentContext?.findRenderObject();
          if (box is RenderBox &&
              box.hasSize &&
              box.size.height > 0 &&
              ((_heights[id] ?? -1) - box.size.height).abs() > 0.1) {
            _heights[id] = box.size.height;
            measured = true;
          }
        }
        final viewport = _viewport.currentContext?.findRenderObject();
        final anchor = _anchor;
        final row = _keys[anchor?.messageId]?.currentContext
            ?.findRenderObject();
        if (_follow) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        } else if (anchor != null &&
            viewport is RenderBox &&
            row is RenderBox &&
            row.hasSize &&
            viewport.hasSize) {
          final shift =
              row.localToGlobal(Offset.zero).dy -
              viewport.localToGlobal(Offset.zero).dy -
              anchor.offset;
          if (shift.abs() > 0.1) {
            _scroll.jumpTo(
              (_scroll.offset + shift).clamp(
                0,
                _scroll.position.maxScrollExtent,
              ),
            );
          }
        }
      } finally {
        _adjusting = false;
      }
      // Programmatic anchor/follow movement also changes the visible body set.
      // Rebuild only when measurements or the scroll offset actually changed.
      if (measured || (_renderedOffset - _scroll.offset).abs() > 0.1) {
        setState(() {});
      }
      _anchor = _capture();
      if (_follow &&
          !_busy &&
          _state['hasNewer'] == true &&
          _state['error'] == null) {
        unawaited(_request(widget.binding.latest));
      } else if (_follow &&
          widget.canMarkRead &&
          _visible &&
          _state['hasNewer'] != true &&
          _state['status'] == 'ready' &&
          _state['loading'] == null) {
        final identity =
            '${widget.conversationId}:${_state['generation']}:${_state['revision']}';
        if (_readIdentity != identity && widget.conversationId != null) {
          _readIdentity = identity;
          widget.onVisibleLatest?.call(
            widget.conversationId!,
            _state['revision'] as int,
          );
        }
      }
    });
  }

  Future<void> _request(Future<void> Function() operation) async {
    if (_requesting) return;
    final epoch = _epoch;
    setState(() {
      _requesting = true;
      _localError = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(
          () => _localError =
              'Conversation history could not be loaded. Try again.',
        );
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() {
          _requesting = false;
          _receive();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground)
      _schedule();
    else
      _save(widget.conversationId, widget.positionStore);
  }

  @override
  void dispose() {
    _save(widget.conversationId, widget.positionStore);
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _saveTimer?.cancel();
    unawaited(_subscription?.cancel());
    if (widget.manageSelection)
      unawaited(widget.binding.select(null, null).catchError((Object _) {}));
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _state['error'] as String? ?? _localError;
    final loading = _state['status'] == 'preparing'
        ? 'Preparing saved conversation…'
        : 'Loading conversation…';
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_layoutWidth != constraints.maxWidth) {
          _layoutWidth = constraints.maxWidth;
          _heights.clear();
          _schedule();
        }
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 844.0;
        _renderedOffset = _scroll.hasClients ? _scroll.offset : 0;
        var top =
            widget.padding.vertical / 2 +
            (_state['hasOlder'] == true ? 48 : 0) +
            (widget.loadEarlierActivity != null ? 48 : 0);
        _rendered.clear();
        for (final record in _records) {
          final id = record['id'] as String, rowHeight = _heights[id] ?? 240.0;
          // One viewport of overscan on each side. A tall message is mounted
          // whole, so Markdown and accessibility never see text fragments.
          if (top + rowHeight >= _renderedOffset - height &&
              top <= _renderedOffset + height * 2)
            _rendered.add(id);
          top += rowHeight;
        }
        return Stack(
          children: [
            NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                _schedule();
                return false;
              },
              child: SingleChildScrollView(
                key: _viewport,
                controller: _scroll,
                padding: widget.padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.loadEarlierActivity case final load?)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_request(load)),
                        child: const Text('Load earlier activity'),
                      ),
                    if (_state['hasOlder'] == true)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_request(widget.binding.older)),
                        child: const Text('Load older messages'),
                      ),
                    if (_records.isEmpty && error == null)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            widget.conversationId == null
                                ? 'Select a conversation.'
                                : _state['status'] == 'ready'
                                ? 'No messages yet.'
                                : loading,
                          ),
                        ),
                      ),
                    for (final record in _records)
                      SizeChangedLayoutNotifier(
                        child: KeyedSubtree(
                          key: _keys.putIfAbsent(
                            record['id'] as String,
                            GlobalKey.new,
                          ),
                          child: !_rendered.contains(record['id'])
                              ? SizedBox(
                                  height: _heights[record['id']] ?? 240.0,
                                )
                              : record['deferred'] == true
                              ? widget.deferredBuilder?.call(context, record) ??
                                    _deferredMessage(record)
                              : widget.messageBuilder?.call(context, record) ??
                                    HandrailTranscriptMessage(
                                      message:
                                          record['value']
                                              as Map<String, Object?>,
                                      style: widget.style,
                                      onOpenLink: widget.onOpenLink,
                                      attachmentBuilder:
                                          widget.attachmentBuilder,
                                    ),
                        ),
                      ),
                    if (_state['hasNewer'] == true)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_request(widget.binding.newer)),
                        child: const Text('Load newer messages'),
                      ),
                    ...widget.trailing,
                    if (error != null)
                      HandrailTranscriptNotice(
                        message: error,
                        isError: true,
                        actionLabel: 'Retry',
                        onAction: _busy
                            ? null
                            : () => unawaited(_request(widget.binding.retry)),
                      ),
                  ],
                ),
              ),
            ),
            if (!_follow || _state['hasNewer'] == true)
              Positioned(
                right: 16,
                bottom: 12,
                child: FilledButton.tonalIcon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _follow = true;
                            _anchor = null;
                          });
                          final follow = widget.binding
                              .read()['setFollowingLatest'];
                          if (follow is void Function(bool)) follow(true);
                          unawaited(_request(widget.binding.latest));
                        },
                  icon: const Icon(Icons.arrow_downward),
                  label: const Text('Jump to latest'),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _deferredMessage(Map<String, Object?> record) {
    final reader = _state['readMessageText'];
    if (record['kind'] != 'message' ||
        reader is! HandrailMessageTextReader ||
        widget.conversationId == null) {
      return const HandrailTranscriptNotice(
        message:
            'This message is too large for the preview. Open its full content to read it.',
      );
    }
    final id = record['id'] as String;
    return HandrailLargeMessage(
      conversationId: widget.conversationId!,
      id: id,
      generation: _state['generation'] as int,
      revision: record['revision'] as int,
      reader: reader,
      expanded: _expandedMessage == id,
      onOpen: () => setState(() => _expandedMessage = id),
      onClose: () => setState(() => _expandedMessage = null),
      onRefresh: () => unawaited(_request(widget.binding.refresh)),
    );
  }
}
