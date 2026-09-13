import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

enum HandrailAttachmentPresentation { card, inline }

/// Authenticated saved-file preview, retry and open lifecycle. The host loads
/// bytes through its protected API and supplies the platform open/share adapter.
class HandrailAttachmentPreview extends StatefulWidget {
  const HandrailAttachmentPreview({
    super.key,
    required this.attachmentId,
    required this.label,
    required this.mediaType,
    this.loadBytes,
    this.loadBytesWithCancellation,
    this.scope,
    this.onOpen,
    this.onOpenBytes,
    this.maximumBytes = 20 * 1024 * 1024,
    this.expectedByteSize,
    this.presentation = HandrailAttachmentPresentation.card,
    this.imageWidth,
    this.imageHeight = 160,
    this.imageKey,
    this.openKey,
    this.openLabel,
    this.imageSemanticsLabel,
  })  : assert(loadBytes != null || loadBytesWithCancellation != null),
        assert(maximumBytes > 0),
        assert(imageHeight > 0),
        assert(expectedByteSize == null || expectedByteSize > 0);

  /// A saved attachment identity. Use [scope] for account/conversation identity.
  final String attachmentId, label, mediaType;
  final Object? scope;
  final Future<Uint8List> Function()? loadBytes;

  /// The protected SDK loader observes this cancellation on scope replacement/disposal.
  final Future<Uint8List> Function(Future<void> cancellation)?
      loadBytesWithCancellation;

  /// Compatibility hook for hosts which own their complete open operation.
  final VoidCallback? onOpen;

  /// Opens freshly authorized bytes. They are borrowed for this callback's
  /// duration; the SDK clears its private copy after completion.
  final FutureOr<void> Function(Uint8List bytes)? onOpenBytes;
  final int maximumBytes;
  final int? expectedByteSize;
  final HandrailAttachmentPresentation presentation;
  final double? imageWidth;
  final double imageHeight;
  final Key? imageKey, openKey;
  final String? openLabel, imageSemanticsLabel;
  @override
  State<HandrailAttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<HandrailAttachmentPreview> {
  Uint8List? _bytes;
  bool _failed = false, _loading = false, _opening = false, _openFailed = false;
  int _generation = 0;
  Completer<void> _cancellation = Completer<void>();
  bool get _isImage => widget.mediaType.startsWith('image/');
  bool get _canOpen => widget.onOpenBytes != null || widget.onOpen != null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(HandrailAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId ||
        oldWidget.scope != widget.scope ||
        oldWidget.mediaType != widget.mediaType ||
        oldWidget.maximumBytes != widget.maximumBytes ||
        oldWidget.expectedByteSize != widget.expectedByteSize) {
      _invalidate();
      _cancellation = Completer<void>();
      _release();
      _failed = _loading = _opening = _openFailed = false;
      unawaited(_load());
    }
  }

  bool _current(int generation) => mounted && generation == _generation;
  void _invalidate() {
    _generation++;
    if (!_cancellation.isCompleted) _cancellation.complete();
  }

  Uint8List _copyChecked(Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > widget.maximumBytes ||
        widget.expectedByteSize != null &&
            bytes.length != widget.expectedByteSize) {
      throw const FormatException('Invalid attachment bytes');
    }
    return Uint8List.fromList(bytes);
  }

  Future<void> _load() async {
    if (!_isImage || _loading) return;
    final generation = _generation;
    _loading = true;
    try {
      final bytes =
          await (widget.loadBytesWithCancellation?.call(_cancellation.future) ??
              widget.loadBytes!());
      if (!_current(generation)) return;
      final copy = _copyChecked(bytes);
      setState(() {
        _release();
        _bytes = copy;
        _failed = false;
      });
    } catch (_) {
      if (_current(generation)) setState(() => _failed = true);
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    if (!_canOpen || _opening) return;
    final generation = _generation;
    final load = widget.loadBytes,
        cancellableLoad = widget.loadBytesWithCancellation,
        openBytes = widget.onOpenBytes,
        open = widget.onOpen;
    final cancellation = _cancellation.future;
    Uint8List? copy;
    setState(() {
      _opening = true;
      _openFailed = false;
    });
    try {
      if (openBytes != null) {
        final bytes = await (cancellableLoad?.call(cancellation) ?? load!());
        if (!_current(generation) || ModalRoute.of(context)?.isCurrent == false)
          return;
        copy = _copyChecked(bytes);
        await openBytes(copy);
      } else {
        open?.call();
      }
    } catch (_) {
      if (_current(generation)) setState(() => _openFailed = true);
    } finally {
      copy?.fillRange(0, copy.length, 0);
      if (_current(generation)) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _invalidate();
    _release();
    super.dispose();
  }

  void _release() {
    final bytes = _bytes;
    if (bytes != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
      bytes.fillRange(0, bytes.length, 0);
    }
    _bytes = null;
  }

  Widget _image() => Semantics(
      image: true,
      label: widget.imageSemanticsLabel,
      child: SizedBox(
          height: widget.imageHeight,
          width: widget.imageWidth ?? double.infinity,
          child: _failed
              ? _unavailable()
              : _bytes == null
                  ? const Center(
                      child: CircularProgressIndicator(
                          semanticsLabel: 'Loading image'))
                  : Image.memory(_bytes!,
                      key: widget.imageKey,
                      fit: BoxFit.contain,
                      semanticLabel: widget.imageSemanticsLabel == null
                          ? '${widget.label} preview'
                          : null,
                      errorBuilder: (_, __, ___) => _unavailable())));

  Widget get _openIcon => _opening
      ? const SizedBox.square(
          dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
      : Icon(widget.mediaType == 'application/pdf'
          ? Icons.picture_as_pdf_outlined
          : Icons.open_in_new);

  @override
  Widget build(BuildContext context) {
    final inline = widget.presentation == HandrailAttachmentPresentation.inline;
    final content = Column(mainAxisSize: MainAxisSize.min, children: [
      if (_isImage)
        if (inline && _canOpen)
          Tooltip(
              message: widget.openLabel ?? 'Open attachment',
              child: InkWell(
                  key: widget.openKey,
                  onTap: _opening ? null : () => unawaited(_open()),
                  child: Stack(alignment: Alignment.center, children: [
                    _image(),
                    if (_opening) _openIcon,
                  ])))
        else
          _image(),
      if (inline && !_isImage && _canOpen)
        OutlinedButton.icon(
            key: widget.openKey,
            style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(48, 48))),
            onPressed: _opening ? null : () => unawaited(_open()),
            icon: _openIcon,
            label: Text(widget.openLabel ?? widget.label))
      else if (!inline || !_isImage)
        ListTile(
            title: Text(widget.label),
            trailing: !_canOpen
                ? null
                : IconButton(
                    key: widget.openKey,
                    onPressed: _opening ? null : () => unawaited(_open()),
                    tooltip: widget.openLabel ?? 'Open attachment',
                    icon: _openIcon)),
      if (_openFailed)
        Semantics(
            liveRegion: true,
            child: TextButton.icon(
                onPressed: () => unawaited(_open()),
                icon: const Icon(Icons.refresh),
                label: const Text('Attachment unavailable. Try again'))),
    ]);
    return inline
        ? ClipRRect(borderRadius: BorderRadius.circular(8), child: content)
        : Card(clipBehavior: Clip.antiAlias, child: content);
  }

  Widget _unavailable() => Center(
          child: TextButton.icon(
        icon: const Icon(Icons.refresh),
        label: const Text('Preview unavailable. Try again'),
        onPressed: _loading
            ? null
            : () {
                setState(() {
                  _failed = false;
                  _release();
                });
                unawaited(_load());
              },
      ));
}
