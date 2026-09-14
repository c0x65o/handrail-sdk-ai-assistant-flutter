import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;

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
    this.enableImageZoom = false,
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
        assert(!enableImageZoom || onOpen == null && onOpenBytes == null),
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

  /// Built-in, account-scoped image viewer; use without host open callbacks.
  final bool enableImageZoom;
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

class _AttachmentPreviewState extends State<HandrailAttachmentPreview>
    with WidgetsBindingObserver {
  Uint8List? _bytes;
  bool _failed = false, _loading = false, _opening = false, _openFailed = false;
  int _generation = 0;
  bool _inactive = false;
  DialogRoute<void>? _previewRoute;
  NavigatorState? _previewNavigator;
  Uint8List? _previewBytes;
  Completer<void> _cancellation = Completer<void>();
  bool get _isImage => widget.mediaType.startsWith('image/');
  bool get _canOpen =>
      widget.onOpenBytes != null ||
      widget.onOpen != null ||
      widget.enableImageZoom && _isImage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(HandrailAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId ||
        oldWidget.scope != widget.scope ||
        oldWidget.mediaType != widget.mediaType ||
        oldWidget.enableImageZoom != widget.enableImageZoom ||
        oldWidget.maximumBytes != widget.maximumBytes ||
        oldWidget.expectedByteSize != widget.expectedByteSize) {
      _invalidate();
      _cancellation = Completer<void>();
      _release();
      _failed = _loading = _opening = _openFailed = false;
      unawaited(_load());
    }
  }

  bool _current(int generation) =>
      mounted && !_inactive && generation == _generation;
  void _invalidate() {
    _generation++;
    _closePreview();
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
    if (!_isImage || _loading || _inactive) return;
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
    if (!_canOpen || _opening || _inactive) return;
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
      if (openBytes != null || widget.enableImageZoom && _isImage) {
        final bytes = await (cancellableLoad?.call(cancellation) ?? load!());
        if (!_current(generation) || ModalRoute.of(context)?.isCurrent == false)
          return;
        copy = _copyChecked(bytes);
        if (widget.enableImageZoom && _isImage) {
          await _showImage(copy);
        } else {
          await openBytes!(copy);
        }
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (const [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached
    ].contains(state)) {
      if (_inactive) return;
      _inactive = true;
      _invalidate();
      setState(() {
        _release();
        _loading = _opening = false;
      });
    } else if (state == AppLifecycleState.resumed && _inactive) {
      setState(() => _inactive = false);
      _cancellation = Completer<void>();
      unawaited(_load());
    }
  }

  Future<void> _showImage(Uint8List bytes) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final label = widget.label;
    final route = DialogRoute<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
                child: Scaffold(
              appBar: AppBar(
                  title:
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  leading: IconButton(
                      tooltip: 'Close image preview',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close))),
              body: Center(
                  child: InteractiveViewer(
                      minScale: .8,
                      maxScale: 5,
                      boundaryMargin: const EdgeInsets.all(40),
                      child: Image.memory(bytes,
                          semanticLabel: 'Enlarged image $label',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              const Text('Image unavailable')))),
            )));
    setState(() {
      _previewRoute = route;
      _previewNavigator = navigator;
      _previewBytes = bytes;
    });
    try {
      await navigator.push(route);
    } finally {
      // Evict decoded pixels as well as clearing our borrowed encoded copy.
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
      bytes.fillRange(0, bytes.length, 0);
      if (identical(_previewRoute, route)) {
        _previewRoute = null;
        _previewNavigator = null;
        _previewBytes = null;
      }
    }
  }

  void _closePreview() {
    final route = _previewRoute, navigator = _previewNavigator;
    final bytes = _previewBytes;
    _previewRoute = null;
    _previewNavigator = null;
    _previewBytes = null;
    if (bytes != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
      bytes.fillRange(0, bytes.length, 0);
    }
    if (route == null || navigator == null) return;
    void remove() {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    }

    // Backgrounding disables frames. Remove immediately outside build so this
    // route cannot survive until the first frame of a resumed/replaced account.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  Widget get _openIcon => _opening && _previewRoute == null
      ? const SizedBox.square(
          dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
      : Icon(widget.mediaType == 'application/pdf'
          ? Icons.picture_as_pdf_outlined
          : Icons.open_in_new);

  @override
  Widget build(BuildContext context) {
    if (_inactive) return const SizedBox.shrink();
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
