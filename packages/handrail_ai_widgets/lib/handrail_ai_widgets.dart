import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'approval_mode.dart';
import 'audio_recorder.dart';
import 'transcription_control.dart';
import 'attachments.dart';

export 'realtime_voice.dart';
export 'caption_blocks.dart';
export 'realtime_voice_gateway.dart';
export 'webrtc_voice_session.dart';
export 'approval_mode.dart';
export 'approval_decisions.dart';
export 'structured_details.dart';
export 'draft_controller.dart';
export 'composer_drafts.dart';
export 'conversation_history.dart';
export 'conversation_transcript.dart';
export 'display_transcript.dart';
export 'large_message.dart';
export 'deferred_records.dart';
export 'workspace_binding.dart';
export 'assistant_workspace.dart';
export 'assistant_close_guard.dart';
export 'audio_recorder.dart';
export 'transcription_control.dart';
export 'markdown.dart';
export 'attachment_preview.dart';
export 'saved_attachments.dart';
export 'attachments.dart';

class HandrailClipboardImage {
  const HandrailClipboardImage(this.bytes, this.mediaType, this.filename);
  final Uint8List bytes;
  final String mediaType;
  final String filename;
  static Future<HandrailClipboardImage?> read() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) return null;
    if (bytes.length > 20 * 1024 * 1024)
      throw StateError('Clipboard image is too large. Choose a smaller image.');
    final type =
        bytes.length >= 8 &&
            bytes[0] == 137 &&
            bytes[1] == 80 &&
            bytes[2] == 78 &&
            bytes[3] == 71
        ? ('image/png', 'png')
        : bytes.length >= 3 &&
              bytes[0] == 255 &&
              bytes[1] == 216 &&
              bytes[2] == 255
        ? ('image/jpeg', 'jpg')
        : bytes.length >= 12 &&
              String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
              String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP'
        ? ('image/webp', 'webp')
        : bytes.length >= 6 &&
              String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF'
        ? ('image/gif', 'gif')
        : null;
    if (type == null)
      throw StateError('This clipboard image format is not supported.');
    return HandrailClipboardImage(bytes, type.$1, 'pasted-image.${type.$2}');
  }
}

class HandrailApprovalBadge extends StatefulWidget {
  const HandrailApprovalBadge({
    super.key,
    this.mode = HandrailApprovalMode.required,
    this.onChanged,
    this.onApply,
    this.enabled = true,
    this.scope,
  });
  final HandrailApprovalMode mode;
  final ValueChanged<HandrailApprovalMode>? onChanged;
  final Future<void> Function(HandrailApprovalMode)? onApply;
  final bool enabled;
  final Object? scope;
  @override
  State<HandrailApprovalBadge> createState() => _ApprovalBadgeState();
}

class _ApprovalBadgeState extends State<HandrailApprovalBadge> {
  Route<dynamic>? _route;
  int _generation = 0;
  bool _opening = false;

  void _close() {
    _generation++;
    _opening = false;
    final route = _route;
    _route = null;
    if (route != null)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
  }

  @override
  void didUpdateWidget(HandrailApprovalBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope || oldWidget.enabled && !widget.enabled)
      _close();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    final generation = ++_generation;
    var selected = widget.mode;
    var saving = false;
    String? error;
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) {
          _route = ModalRoute.of(context);
          if (!mounted || generation != _generation) {
            _close();
            return const SizedBox();
          }
          return SafeArea(
            child: StatefulBuilder(
              builder: (context, update) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-approve changes'),
                      value: selected == HandrailApprovalMode.automatic,
                      onChanged:
                          saving || !widget.enabled || widget.onChanged == null
                          ? null
                          : (value) async {
                              if (!mounted ||
                                  generation != _generation ||
                                  !widget.enabled)
                                return;
                              final next = value
                                  ? HandrailApprovalMode.automatic
                                  : HandrailApprovalMode.required;
                              update(() {
                                saving = true;
                                error = null;
                              });
                              try {
                                await widget.onApply?.call(next);
                                if (!mounted || generation != _generation)
                                  return;
                                selected = next;
                                widget.onChanged?.call(next);
                              } catch (_) {
                                if (!mounted || generation != _generation)
                                  return;
                                error =
                                    'Approval setting could not be updated. Try again.';
                              }
                              if (mounted && generation == _generation)
                                update(() {
                                  saving = false;
                                });
                            },
                    ),
                    Text(
                      selected == HandrailApprovalMode.automatic
                          ? 'Add, edit, and delete without asking each time, within your account permissions.'
                          : 'Review and approve additions, edits, and deletions before they run.',
                    ),
                    if (saving) const Text('Updating approval setting…'),
                    if (error != null) Text(error!),
                    const SizedBox(height: 12),
                    Text(
                      widget.onChanged == null
                          ? 'Approval settings are managed by this application.'
                          : widget.onApply != null
                          ? 'Applies immediately to this request and future messages. Turning it on approves pending changes for this request. Turning it off asks before later changes; work already approved or started continues.'
                          : 'Applies to your next message. Changes already running keep their original setting.',
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } finally {
      if (generation == _generation) {
        _opening = false;
        _route = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Approval settings',
    style: const ButtonStyle(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
    ),
    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    color: widget.mode == HandrailApprovalMode.automatic
        ? const Color(0xff202124)
        : const Color(0xff999999),
    icon: Icon(
      widget.mode == HandrailApprovalMode.automatic
          ? Icons.shield
          : Icons.shield_outlined,
      size: 18,
    ),
    onPressed: _open,
  );
}

class _PasteImageIntent extends Intent {
  const _PasteImageIntent();
}

/// Shared two-row composer. Bind SDK draft/session lifecycles and host authorization adapters.
class HandrailComposer extends StatefulWidget {
  const HandrailComposer({
    super.key,
    required this.controller,
    this.focusNode,
    this.sendOnEnter = true,
    this.maxLines = 6,
    this.allowExpand = false,
    this.expandedEditorTitle = 'Edit message',
    this.expandKey,
    this.expandedInputKey,
    this.input,
    this.contextMenuBuilder,
    this.decoration,
    this.inputTextStyle,
    this.sendButtonStyle,
    this.showAttachmentControl = true,
    this.onChanged,
    this.placeholder = 'Message…',
    this.maxLength,
    this.onAttach,
    this.attachmentDrafts,
    this.attachKey,
    this.inputKey,
    this.sendKey,
    this.onSend,
    this.onStop,
    this.canSend = false,
    this.enabled = true,
    this.sending = false,
    this.stopping = false,
    this.approvalMode = HandrailApprovalMode.required,
    this.onApprovalModeChanged,
    this.onApprovalModeApply,
    this.showApprovalControl = true,
    this.voiceControls,
    this.transcribeAudio,
    this.transcriptionScope,
    this.transcriptionMaximumDuration = maxHandrailVoiceRecordingDuration,
    this.transcriptionMaximumBytes = 25 * 1024 * 1024,
    this.transcriptionMaxDraftLength,
    this.audioRecorderFactory,
    this.transcriptionButtonKey,
    this.transcriptionButtonStyle,
    this.onPasteImage,
    this.onVoiceBusyChanged,
  });
  final TextEditingController controller;

  /// Also pass this to a custom [input] to retain shared Send focus behavior.
  final FocusNode? focusNode;
  final bool sendOnEnter;
  final int maxLines;
  final bool allowExpand;
  final String expandedEditorTitle;
  final Key? expandKey, expandedInputKey;
  final Widget? input;

  /// Platform context-menu adapter for the standard editor. Sending, keyboard
  /// handling and focus remain shared when a host customizes this menu.
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  /// Host branding for the shared composer, without replacing its behavior.
  final BoxDecoration? decoration;
  final TextStyle? inputTextStyle;
  final ButtonStyle? sendButtonStyle;

  /// Hide attachments when the authenticated gateway does not offer uploads.
  final bool showAttachmentControl;
  final ValueChanged<String>? onChanged;
  final String placeholder;
  final int? maxLength;
  final Key? attachKey, inputKey, sendKey;
  final VoidCallback? onAttach, onSend, onStop;
  final HandrailAttachmentDrafts? attachmentDrafts;
  final bool canSend, enabled, sending, stopping, showApprovalControl;
  final HandrailApprovalMode approvalMode;
  final ValueChanged<HandrailApprovalMode>? onApprovalModeChanged;
  final Future<void> Function(HandrailApprovalMode)? onApprovalModeApply;
  final List<Widget>? voiceControls;
  final HandrailAudioTranscriber? transcribeAudio;
  final Object? transcriptionScope;
  final Duration transcriptionMaximumDuration;
  final int transcriptionMaximumBytes;
  final int? transcriptionMaxDraftLength;
  final HandrailAudioRecorder Function()? audioRecorderFactory;
  final Key? transcriptionButtonKey;
  final ButtonStyle? transcriptionButtonStyle;
  final FutureOr<void> Function(HandrailClipboardImage)? onPasteImage;
  final ValueChanged<bool>? onVoiceBusyChanged;
  @override
  State<HandrailComposer> createState() => _HandrailComposerState();
}

class _HandrailComposerState extends State<HandrailComposer> {
  bool _dictating = false;
  String? _transcriptionError;
  final _ownedFocus = FocusNode(debugLabel: 'Handrail composer');
  FocusNode get _inputFocus => widget.focusNode ?? _ownedFocus;
  Route<void>? _editorRoute;

  void _closeEditor() {
    final route = _editorRoute;
    _editorRoute = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.attachmentDrafts?.addListener(_filesChanged);
  }

  void _filesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(HandrailComposer oldWidget) {
    if (!identical(oldWidget.attachmentDrafts, widget.attachmentDrafts)) {
      oldWidget.attachmentDrafts?.removeListener(_filesChanged);
      widget.attachmentDrafts?.addListener(_filesChanged);
    }
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.transcriptionScope != widget.transcriptionScope ||
        (oldWidget.transcribeAudio == null) !=
            (widget.transcribeAudio == null) ||
        oldWidget.voiceControls == null && widget.voiceControls != null ||
        oldWidget.enabled && !widget.enabled) {
      _dictating = false;
      _transcriptionError = null;
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.enabled && !widget.enabled)
      _closeEditor();
  }

  Future<void> _editDraft() async {
    if (!widget.enabled || _editorRoute != null) return;
    _inputFocus.unfocus();
    final current = widget;
    final route = _editorRoute = MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(current.expandedEditorTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: current.expandedInputKey,
              controller: current.controller,
              autofocus: true,
              expands: true,
              minLines: null,
              maxLines: null,
              maxLength: current.maxLength,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textAlignVertical: TextAlignVertical.top,
              onChanged: current.onChanged,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: current.placeholder,
              ),
            ),
          ),
        ),
      ),
    );
    await Navigator.of(context).push(route);
    if (identical(_editorRoute, route)) _editorRoute = null;
  }

  void _send() {
    if (!widget.enabled ||
        !widget.canSend ||
        widget.sending ||
        _dictating ||
        widget.attachmentDrafts?.pickingAttachments == true ||
        widget.attachmentDrafts?.uploadingAttachments == true ||
        widget.onSend == null)
      return;
    _inputFocus.requestFocus();
    widget.onSend!();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (!widget.sendOnEnter ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        (!widget.controller.value.composing.isCollapsed &&
            widget.controller.value.composing.isValid))
      return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      if (widget.enabled &&
          (event is KeyDownEvent || event is KeyRepeatEvent)) {
        final value = widget.controller.value;
        final start = value.selection.isValid
            ? value.selection.start
            : value.text.length;
        final end = value.selection.isValid
            ? value.selection.end
            : value.text.length;
        final text = value.text.replaceRange(start, end, '\n');
        if (widget.maxLength == null || text.length <= widget.maxLength!) {
          widget.controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: start + 1),
          );
          widget.onChanged?.call(text);
        }
      }
    } else if (event is KeyDownEvent) {
      _send();
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _closeEditor();
    widget.attachmentDrafts?.removeListener(_filesChanged);
    _ownedFocus.dispose();
    super.dispose();
  }

  Future<void> _paste({bool textFallback = false}) async {
    if (!widget.enabled) return;
    final controller = widget.controller;
    try {
      HandrailClipboardImage? image;
      try {
        if (!widget.sending && widget.showAttachmentControl)
          image = await HandrailClipboardImage.read();
      } catch (_) {
        if (!textFallback) rethrow;
      }
      if (!mounted ||
          !widget.enabled ||
          !identical(controller, widget.controller))
        return;
      if (image != null && !widget.sending) {
        if (widget.onPasteImage != null) {
          await widget.onPasteImage!(image);
        } else {
          widget.attachmentDrafts?.addPickedAttachments([
            HandrailAttachmentFile(
              fileName: image.filename,
              mediaType: image.mediaType,
              bytes: image.bytes,
            ),
          ]);
        }
        return;
      }
      if (textFallback) {
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (!mounted ||
            !widget.enabled ||
            !identical(controller, widget.controller) ||
            text == null)
          return;
        final value = widget.controller.value;
        final start = value.selection.isValid
            ? value.selection.start
            : value.text.length;
        final end = value.selection.isValid
            ? value.selection.end
            : value.text.length;
        final updated = value.text.replaceRange(start, end, text);
        if (widget.maxLength != null && updated.length > widget.maxLength!) {
          throw StateError('Pasted text exceeds the message limit.');
        }
        widget.controller.value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: start + text.length),
        );
        widget.onChanged?.call(updated);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No image on the clipboard.')),
        );
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The clipboard image could not be pasted. Try adding it as a file.',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget input =
        widget.input ??
        TextField(
          key: widget.inputKey,
          controller: widget.controller,
          focusNode: _inputFocus,
          enabled: widget.enabled,
          minLines: 1,
          maxLines: widget.maxLines,
          maxLength: widget.maxLength,
          keyboardType: TextInputType.multiline,
          textInputAction: widget.sendOnEnter
              ? TextInputAction.send
              : TextInputAction.newline,
          onEditingComplete: () {},
          onSubmitted: widget.sendOnEnter ? (_) => _send() : null,
          textCapitalization: TextCapitalization.sentences,
          style:
              widget.inputTextStyle ??
              theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontSize: 15,
                height: 1.4,
              ),
          decoration: InputDecoration(
            hintText: widget.placeholder,
            suffixIcon: widget.allowExpand
                ? IconButton(
                    key: widget.expandKey,
                    tooltip: 'Edit full message',
                    onPressed: widget.enabled ? _editDraft : null,
                    icon: const Icon(Icons.open_in_full),
                  )
                : null,
            counterText: '',
            filled: false,
            fillColor: Colors.transparent,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            // A host form theme may impose a fixed height or width. The
            // shared editor grows with its text inside the composer instead.
            constraints: const BoxConstraints(),
            isCollapsed: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 2,
            ),
          ),
          onChanged: widget.onChanged,
          contextMenuBuilder:
              widget.contextMenuBuilder ??
              (context, editable) => AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editable.contextMenuAnchors,
                buttonItems: [
                  ...editable.contextMenuButtonItems,
                  if (widget.onPasteImage != null ||
                      widget.attachmentDrafts?.attachmentsEnabled == true)
                    ContextMenuButtonItem(
                      label: 'Paste image',
                      onPressed: () {
                        ContextMenuController.removeAny();
                        unawaited(_paste());
                      },
                    ),
                ],
              ),
        );
    input = Focus(onKeyEvent: _key, child: input);
    if (widget.onPasteImage != null ||
        widget.attachmentDrafts?.attachmentsEnabled == true) {
      input = Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyV, control: true):
              _PasteImageIntent(),
          SingleActivator(LogicalKeyboardKey.keyV, meta: true):
              _PasteImageIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _PasteImageIntent: CallbackAction<_PasteImageIntent>(
              onInvoke: (_) {
                unawaited(_paste(textFallback: true));
                return null;
              },
            ),
          },
          child: input,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration:
          widget.decoration ??
          BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x08000000),
                blurRadius: 18,
                offset: Offset(0, 4),
              ),
            ],
          ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.attachmentDrafts case final files?) ...[
            if (files.attachmentSelections.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final file in files.attachmentSelections)
                        Row(
                          children: [
                            if (file.status ==
                                HandrailAttachmentStatus.uploading)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                file.filename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove ${file.filename}',
                              onPressed: widget.sending
                                  ? null
                                  : () => files.removeAttachment(file.id),
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            if (files.attachmentError case final error?)
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
          ConstrainedBox(
            key: const ValueKey('handrail-composer-editor'),
            constraints: const BoxConstraints(minHeight: 26),
            child: input,
          ),
          const SizedBox(height: 4),
          Row(
            key: const ValueKey('handrail-composer-toolbar'),
            children: [
              if (widget.showAttachmentControl &&
                  (widget.attachmentDrafts?.attachmentsEnabled ?? true))
                IconButton(
                  key: widget.attachKey,
                  tooltip: 'Add files and images',
                  style: const ButtonStyle(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
                    backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                  ),
                  onPressed:
                      widget.enabled &&
                          !widget.sending &&
                          !_dictating &&
                          widget.attachmentDrafts?.pickingAttachments != true
                      ? widget.onAttach ??
                            (widget.attachmentDrafts == null
                                ? null
                                : () => unawaited(
                                    widget.attachmentDrafts!.pickAttachments(),
                                  ))
                      : null,
                  icon: const Icon(Icons.add_rounded, size: 22),
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                ),
              if (widget.showApprovalControl)
                HandrailApprovalBadge(
                  scope: (widget.controller, widget.transcriptionScope),
                  mode: widget.approvalMode,
                  onChanged: widget.onApprovalModeChanged,
                  onApply: widget.onApprovalModeApply,
                  enabled: widget.enabled,
                ),
              const Spacer(),
              ...?widget.voiceControls,
              if (widget.voiceControls == null &&
                  widget.transcribeAudio != null)
                HandrailTranscriptionControl(
                  controller: widget.controller,
                  transcribe: widget.transcribeAudio!,
                  scope: widget.transcriptionScope,
                  enabled: widget.enabled && !widget.sending,
                  maximumDuration: widget.transcriptionMaximumDuration,
                  maximumBytes: widget.transcriptionMaximumBytes,
                  maxDraftLength:
                      widget.transcriptionMaxDraftLength ?? widget.maxLength,
                  recorderFactory: widget.audioRecorderFactory,
                  buttonKey: widget.transcriptionButtonKey,
                  buttonStyle: widget.transcriptionButtonStyle,
                  onChanged: widget.onChanged,
                  onErrorChanged: (error) {
                    if (_transcriptionError != error) {
                      setState(() => _transcriptionError = error);
                    }
                  },
                  onBusyChanged: (busy) {
                    setState(() => _dictating = busy);
                    widget.onVoiceBusyChanged?.call(busy);
                  },
                ),
              if (widget.voiceControls == null &&
                  widget.transcribeAudio == null)
                HandrailDictationButton(
                  controller: widget.controller,
                  enabled: widget.enabled && !widget.sending,
                  onChanged: widget.onChanged,
                  onBusyChanged: (busy) {
                    setState(() => _dictating = busy);
                    widget.onVoiceBusyChanged?.call(busy);
                  },
                ),
              const SizedBox(width: 4),
              IconButton.filled(
                key: widget.sendKey,
                tooltip: widget.stopping
                    ? 'Stopping response…'
                    : widget.onStop != null && widget.sending
                    ? 'Stop response'
                    : 'Send message',
                style: (widget.sendButtonStyle ?? const ButtonStyle()).merge(
                  IconButton.styleFrom(
                    fixedSize: const Size.square(40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const CircleBorder(),
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                  ),
                ),
                onPressed: widget.stopping
                    ? null
                    : widget.sending && widget.onStop != null
                    ? widget.onStop
                    : widget.enabled &&
                          widget.canSend &&
                          !widget.sending &&
                          !_dictating &&
                          widget.attachmentDrafts?.pickingAttachments != true &&
                          widget.attachmentDrafts?.uploadingAttachments != true
                    ? _send
                    : null,
                icon: widget.stopping
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        widget.sending && widget.onStop != null
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                        size: 20,
                      ),
              ),
            ],
          ),
          if (_transcriptionError case final error?)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Device speech recognition; microphone permission is requested only on tap.
class HandrailDictationButton extends StatefulWidget {
  const HandrailDictationButton({
    super.key,
    required this.controller,
    this.enabled = true,
    this.onChanged,
    this.onBusyChanged,
  });
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<HandrailDictationButton> createState() =>
      _HandrailDictationButtonState();
}

class _HandrailDictationButtonState extends State<HandrailDictationButton> {
  final _speech = SpeechToText();
  bool _busy = false;
  int _generation = 0;
  void _setBusy(bool value) {
    if (mounted && _busy != value) {
      setState(() => _busy = value);
      widget.onBusyChanged?.call(value);
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_speech.cancel());
    super.dispose();
  }

  @override
  void didUpdateWidget(HandrailDictationButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller) ||
        !widget.enabled && oldWidget.enabled) {
      _generation++;
      unawaited(_speech.cancel());
      if (_busy) {
        _busy = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onBusyChanged?.call(false);
        });
      }
    }
  }

  Future<void> _start() async {
    if (!widget.enabled || _busy) return;
    final generation = ++_generation;
    _setBusy(true);
    try {
      final ready = await _speech.initialize(
        onStatus: (status) {
          if (generation == _generation && status == 'done') _setBusy(false);
        },
        onError: (_) {
          if (generation != _generation) return;
          _setBusy(false);
          _notice();
        },
      );
      if (!mounted || generation != _generation) return;
      if (!ready) {
        _setBusy(false);
        _notice();
        return;
      }
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 60),
          partialResults: false,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
        onResult: (result) {
          if (!mounted || generation != _generation || !result.finalResult)
            return;
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          final text = [
            widget.controller.text.trimRight(),
            words,
          ].where((part) => part.isNotEmpty).join(' ');
          widget.controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
          widget.onChanged?.call(text);
        },
      );
    } catch (_) {
      _setBusy(false);
      _notice();
    }
  }

  void _notice() {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Voice input is unavailable. Check microphone and speech permissions, or use keyboard dictation.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _busy ? 'Stop dictation' : 'Dictate a message',
    style: const ButtonStyle(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
    ),
    onPressed: _busy
        ? () async {
            try {
              await _speech.stop();
            } catch (_) {
              _notice();
            } finally {
              _setBusy(false);
            }
          }
        : widget.enabled
        ? _start
        : null,
    color: _busy ? Colors.red : const Color(0xff202124),
    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    icon: Icon(
      _busy ? Icons.stop_circle_outlined : Icons.mic_none_rounded,
      size: 20,
    ),
  );
}
