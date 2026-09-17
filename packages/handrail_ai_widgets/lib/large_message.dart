import 'dart:async';
import 'package:flutter/material.dart';

/// Structural callback supplied by the account-owned display window.
typedef HandrailMessageTextReader =
    Future<Map<String, Object?>> Function(
      String conversationId,
      String id,
      int generation,
      int revision,
      int offset,
      Future<void> cancellation,
    );

/// Explicit text-only reading surface for a deferred message. Owns one bounded
/// section; the transcript permits only one expanded reader at a time.
class HandrailLargeMessage extends StatefulWidget {
  const HandrailLargeMessage({
    super.key,
    required this.conversationId,
    required this.id,
    required this.generation,
    required this.revision,
    required this.reader,
    required this.expanded,
    required this.onOpen,
    required this.onClose,
    required this.onRefresh,
  });
  final String conversationId, id;
  final int generation, revision;
  final HandrailMessageTextReader reader;
  final bool expanded;
  final VoidCallback onOpen, onClose, onRefresh;
  @override
  State<HandrailLargeMessage> createState() => _LargeMessageState();
}

class _LargeMessageState extends State<HandrailLargeMessage> {
  Completer<void>? _cancellation;
  int _offset = 0;
  int? _next;
  String _text = '';
  String? _error;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    if (widget.expanded) unawaited(_load(0));
  }

  @override
  void didUpdateWidget(HandrailLargeMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.id != widget.id ||
        oldWidget.generation != widget.generation ||
        oldWidget.revision != widget.revision ||
        oldWidget.reader != widget.reader ||
        oldWidget.expanded != widget.expanded) {
      _cancel();
      _text = '';
      _offset = 0;
      _next = null;
      _error = null;
      if (widget.expanded) unawaited(_load(0));
    }
  }

  void _cancel() {
    if (_cancellation?.isCompleted == false) _cancellation!.complete();
    _cancellation = null;
    _loading = false;
  }

  Future<void> _load(int offset) async {
    _cancel();
    final cancellation = _cancellation = Completer<void>();
    setState(() {
      _offset = offset;
      _text = '';
      _next = null;
      _error = null;
      _loading = true;
    });
    try {
      final value = await widget.reader(
        widget.conversationId,
        widget.id,
        widget.generation,
        widget.revision,
        offset,
        cancellation.future,
      );
      if (!mounted ||
          !identical(cancellation, _cancellation) ||
          cancellation.isCompleted)
        return;
      final code = value['errorCode'];
      if (code != null) {
        _error = const {'content_changed', 'stale_cursor'}.contains(code)
            ? 'changed'
            : const {
                'forbidden',
                'permission_denied',
                'unauthenticated',
                'not_found',
                'cancelled',
              }.contains(code)
            ? 'denied'
            : 'unavailable';
      } else {
        final text = value['text'], next = value['nextOffset'];
        if (value['encoding'] != 'plain-text' ||
            value['revision'] != widget.revision ||
            text is! String ||
            text.runes.length > 8192 ||
            next != null &&
                (next is! int ||
                    text.runes.length != 8192 ||
                    next != offset + text.runes.length)) {
          throw const FormatException('Invalid message text section');
        }
        _text = text;
        _next = next as int?;
      }
    } catch (_) {
      if (!mounted ||
          !identical(cancellation, _cancellation) ||
          cancellation.isCompleted)
        return;
      _error = 'unavailable';
    } finally {
      if (mounted &&
          identical(cancellation, _cancellation) &&
          !cancellation.isCompleted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _cancel();
    _text = '';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded)
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Large message.'),
          TextButton(
            onPressed: widget.onOpen,
            child: const Text('Read message'),
          ),
        ],
      );
    return Semantics(
      container: true,
      label: 'Large message text',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Message text — part ${_offset ~/ 8192 + 1}'),
              TextButton(
                onPressed: widget.onClose,
                child: const Text('Close message'),
              ),
            ],
          ),
          if (_loading)
            const Text('Loading message…')
          else if (_error != null)
            Semantics(
              liveRegion: true,
              child: Column(
                children: [
                  Text(
                    _error == 'changed'
                        ? 'This message changed. Reload it to read the latest version.'
                        : _error == 'denied'
                        ? 'This message is no longer available.'
                        : 'This part could not be loaded.',
                  ),
                  if (_error == 'unavailable')
                    TextButton(
                      onPressed: () => unawaited(_load(_offset)),
                      child: const Text('Retry reading'),
                    ),
                  if (_error == 'changed')
                    TextButton(
                      onPressed: () {
                        widget.onClose();
                        widget.onRefresh();
                      },
                      child: const Text('Reload message'),
                    ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .5,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _text.isEmpty ? 'This message has no text.' : _text,
                ),
              ),
            ),
          Wrap(
            children: [
              TextButton(
                onPressed: _loading || _offset == 0 || _error == 'denied'
                    ? null
                    : () =>
                          unawaited(_load((_offset - 8192).clamp(0, _offset))),
                child: const Text('Previous part'),
              ),
              TextButton(
                onPressed: _loading || _next == null || _error != null
                    ? null
                    : () => unawaited(_load(_next!)),
                child: const Text('Next part'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
