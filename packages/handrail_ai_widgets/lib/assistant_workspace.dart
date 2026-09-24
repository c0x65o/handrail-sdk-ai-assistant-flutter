import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'handrail_ai_widgets.dart';

/// Immutable send-time values. Context should be an immutable business value.
class HandrailWorkspaceSubmission<T> {
  const HandrailWorkspaceSubmission({
    required this.text,
    required this.attachments,
    required this.context,
    required this.approvalMode,
  });
  final String text;
  final List<Map<String, Object?>> attachments;
  final T? context;
  final HandrailApprovalMode approvalMode;
  Map<String, Object?> get approvalMetadata =>
      handrailApprovalMetadata(approvalMode);
}

/// Standard responsive history, transcript, files, dictation and send controls.
/// Retain the account binding and drafts outside the view. Business request
/// construction, result formatting, branding and feature settings are optional.
class HandrailAssistantWorkspace<T> extends StatefulWidget {
  const HandrailAssistantWorkspace({
    super.key,
    required this.binding,
    required this.drafts,
    this.captureContext,
    this.buildRequest,
    this.maxPromptLength = 2000,
    this.maxInputLength,
    this.composerMaxLines = 6,
    this.allowExpandedEditor = false,
    this.expandedEditorTitle = 'Message',
    this.placeholder = 'Ask anything…',
    this.loadingLabel = 'Loading conversation',
    this.workingLabel = 'Working…',
    this.failureLabel = 'The request could not be completed.',
    this.errorLabel,
    this.initialApprovalMode = HandrailApprovalMode.required,
    this.showApprovalControl = true,
    this.showAttachments = true,
    this.showVoice = true,
    this.showArchived = true,
    this.showUnread = true,
    this.threads = true,
    this.onClearConversation,
    this.showToolActivity = true,
    this.showPromptCounter = false,
    this.submissionEnabled = true,
    this.sidebarBreakpoint = 720,
    this.focusNode,
    this.contextMenuBuilder,
    this.onPasteImage,
    this.onVoiceBusyChanged,
    this.onDraftChanged,
    this.onApprovalModeChanged,
    this.onOpenLink,
    this.allowMessageLinks = true,
    this.copyText,
    this.attachmentPicker,
    this.toolResultBuilder,
    this.approvalReviewBuilder,
    this.approvalTitle,
    this.transcriptTrailing = const [],
    this.emptyBuilder,
    this.citationLink,
    this.attachmentBuilder,
    this.saveAttachment,
    this.transcriptStyle = const HandrailTranscriptStyle(),
    this.inputTextStyle,
    this.composerDecoration,
    this.sendButtonStyle,
    this.contextHeader,
    this.composerPadding = const EdgeInsets.all(12),
    this.composerKey,
    this.sendKey,
    this.inputKey,
    this.attachKey,
    this.expandKey,
    this.expandedInputKey,
    this.historyKey,
    this.newButtonKey,
    this.transcriptKey,
    this.errorKey,
    this.audioRecorderFactory,
  }) : assert(maxPromptLength > 0),
       assert(
         maxInputLength == null ||
             maxInputLength > 0 && maxInputLength <= maxPromptLength,
       ),
       assert(composerMaxLines > 0),
       assert(sidebarBreakpoint >= 400);
  final HandrailWorkspaceBinding binding;
  final HandrailComposerController drafts;
  final T Function()? captureContext;
  final Map<String, Object?> Function(HandrailWorkspaceSubmission<T>)?
  buildRequest;
  final int maxPromptLength;
  final int? maxInputLength;
  final int composerMaxLines;
  final bool allowExpandedEditor;
  final bool threads;
  final Future<void> Function()? onClearConversation;
  final String expandedEditorTitle;
  final String placeholder;
  final String loadingLabel, workingLabel, failureLabel;
  final String? errorLabel;
  final HandrailApprovalMode initialApprovalMode;
  final bool showApprovalControl,
      showAttachments,
      showVoice,
      showArchived,
      showUnread,
      showToolActivity,
      showPromptCounter;

  /// Additional business gate. It never grants permissions absent in the binding.
  final bool submissionEnabled;
  final double sidebarBreakpoint;
  final FocusNode? focusNode;

  /// Platform hooks for the standard editor; shared Send and draft ownership
  /// remain in this workspace.
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final FutureOr<void> Function(HandrailClipboardImage)? onPasteImage;

  /// Lets a host coordinate a separate live-call surface with dictation.
  final ValueChanged<bool>? onVoiceBusyChanged;
  final ValueChanged<String>? onDraftChanged, onOpenLink;

  /// Explicit navigation policy; trusted citation resolution stays separate.
  final bool allowMessageLinks;
  final Future<void> Function(String)? copyText;
  final Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)?
  attachmentPicker;
  final ValueChanged<HandrailApprovalMode>? onApprovalModeChanged;
  final String? Function(Map<String, Object?>)? approvalTitle;
  final Widget? Function(BuildContext, Map<String, Object?>)? toolResultBuilder,
      attachmentBuilder;

  /// Display only: complete-review and permission gates remain in the binding.
  final Widget? Function(BuildContext, Map<String, Object?>)?
  approvalReviewBuilder;
  final HandrailAttachmentSaver? saveAttachment;
  final List<Widget> transcriptTrailing;
  final WidgetBuilder? emptyBuilder;
  final String? Function(Map<String, Object?>)? citationLink;
  final HandrailTranscriptStyle transcriptStyle;
  final TextStyle? inputTextStyle;
  final BoxDecoration? composerDecoration;
  final ButtonStyle? sendButtonStyle;
  final Widget? contextHeader;
  final EdgeInsetsGeometry composerPadding;
  final Key? composerKey,
      sendKey,
      inputKey,
      attachKey,
      expandKey,
      expandedInputKey,
      historyKey,
      newButtonKey,
      transcriptKey,
      errorKey;
  final HandrailAudioRecorder Function()? audioRecorderFactory;
  @override
  State<HandrailAssistantWorkspace<T>> createState() => _WorkspaceState<T>();
}

class _WorkspaceState<T> extends State<HandrailAssistantWorkspace<T>>
    with WidgetsBindingObserver {
  StreamSubscription<Object?>? _subscription;
  late HandrailApprovalMode _approvalMode;
  String? _localError, _lastDraft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _approvalMode = widget.initialApprovalMode;
    _bind();
  }

  void _bind() {
    _subscription = widget.binding.changes.listen((_) => _changed());
    widget.drafts.addListener(_changed);
    // Initialization/recovery failures are rendered by the canonical binding.
    unawaited(widget.binding.initialize().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.drafts.flushDrafts().catchError((Object _) {}));
    }
  }

  bool _clearing = false, _clearFailed = false;
  Future<void> _clearConversation() async {
    final scope = widget.binding.scope;
    final id = widget.binding.read()['conversationId'];
    final clear = widget.onClearConversation;
    if (_clearing || clear == null || id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: const Text('Clear this conversation and start fresh?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    bool current() =>
        mounted &&
        identical(scope, widget.binding.scope) &&
        widget.binding.read()['conversationId'] == id;
    if (confirmed != true || !current() || !widget.submissionEnabled) return;
    setState(() {
      _clearing = true;
      _clearFailed = false;
    });
    try {
      await clear();
    } catch (_) {
      if (current()) setState(() => _clearFailed = true);
    } finally {
      if (current()) setState(() => _clearing = false);
    }
  }

  void _changed() {
    if (!mounted) return;
    final text = widget.drafts.controller.text;
    if (_lastDraft != text) {
      _lastDraft = text;
      _localError = null;
      widget.onDraftChanged?.call(text);
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(HandrailAssistantWorkspace<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding.scope, widget.binding.scope) ||
        !identical(oldWidget.drafts, widget.drafts)) {
      unawaited(_subscription?.cancel());
      oldWidget.drafts.removeListener(_changed);
      unawaited(oldWidget.drafts.flushDrafts().catchError((Object _) {}));
      _approvalMode = widget.initialApprovalMode;
      _localError = null;
      _lastDraft = null;
      _clearing = _clearFailed = false;
      _bind();
    }
  }

  bool _eligible(Map<String, Object?> state) =>
      widget.submissionEnabled &&
      state['canSend'] == true &&
      !widget.drafts.isSubmitting &&
      !widget.drafts.controller.restoringDraft &&
      !widget.drafts.restoringAttachments &&
      widget.drafts.attachmentStorageError == null &&
      widget.drafts.controller.text.length <= widget.maxPromptLength &&
      (widget.drafts.controller.text.trim().isNotEmpty ||
          widget.drafts.attachments.isNotEmpty);

  Future<void> _send() async {
    final state = widget.binding.read();
    final id = state['conversationId'] as String?;
    if (id == null || !_eligible(state)) return;
    final binding = widget.binding, drafts = widget.drafts;
    final mode = _approvalMode, builder = widget.buildRequest;
    try {
      // Capture all business configuration before the first async upload.
      final context = widget.captureContext?.call();
      final draftSender =
          state['sendWithDraft'] as HandrailWorkspaceDraftSender?;
      Future<bool> send(
        String text,
        List<Map<String, Object?>> files,
        VoidCallback accepted,
        Map<String, Object?>? origin,
      ) async {
        final submission = HandrailWorkspaceSubmission<T>(
          text: text,
          attachments: List.unmodifiable(files),
          context: context,
          approvalMode: mode,
        );
        final request =
            builder?.call(submission) ?? _defaultRequest(submission);
        final metadata = request['metadata'];
        final body = {
          ...request,
          'metadata': {
            if (metadata is Map) ...Map<String, Object?>.from(metadata),
            ...submission.approvalMetadata,
          },
        };
        return draftSender != null
            ? draftSender(
                conversationId: id,
                request: body,
                localDraft: origin,
                onAccepted: accepted,
              )
            : binding.send(
                conversationId: id,
                request: body,
                onAccepted: accepted,
              );
      }

      if (draftSender != null) {
        await drafts.submitWithAttachmentsAndOrigin(send);
      } else {
        await drafts.submitWithAttachments(
          (text, files, accepted) => send(text, files, accepted, null),
        );
      }
    } on HandrailAttachmentException {
      // The shared attachment queue renders retained retry/discard guidance.
    } catch (_) {
      if (mounted &&
          identical(binding.scope, widget.binding.scope) &&
          widget.binding.read()['conversationId'] == id &&
          widget.binding.read()['error'] == null) {
        setState(
          () => _localError = 'The message could not be sent. Try again.',
        );
      }
    }
  }

  Map<String, Object?> _defaultRequest(
    HandrailWorkspaceSubmission<T> submission,
  ) => {
    'protocol_version': 'handrail.ai-runtime.v1',
    'continuation_of': null,
    'messages': [
      {
        'role': 'user',
        'content': [
          if (submission.text.trim().isNotEmpty)
            {'type': 'text', 'text': submission.text.trim()},
          for (final file in submission.attachments)
            {
              'type': (file['media_type'] as String).startsWith('image/')
                  ? 'image'
                  : 'document',
              'attachment': file,
            },
        ],
      },
    ],
    'tools': [],
    'tool_results': [],
    'generation': {'max_output_tokens': 2048, 'temperature': 0.2},
    'correlation_hints': <String, Object?>{},
    'metadata': submission.approvalMetadata,
  };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    widget.drafts.removeListener(_changed);
    unawaited(widget.drafts.flushDrafts().catchError((Object _) {}));
    // Account-owned work and drafts survive view closure.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.binding.read(), drafts = widget.drafts;
    final id = state['conversationId'] as String?;
    final capabilities = widget.binding.capabilitiesFor(id);
    final downloader = widget.binding.downloaderFor(id);
    final downloadMaximum = capabilities['attachmentDownloadMaximumBytes'];
    final transcriber = widget.showVoice
        ? widget.binding.transcriberFor(id)
        : null;
    final sending =
        state['running'] == true ||
        state['submitting'] == true ||
        drafts.uploadingAttachments;
    final tooLong = drafts.controller.text.length > widget.maxPromptLength;
    Widget history(bool compact) => HandrailConversationHistory(
      key: widget.historyKey,
      binding: widget.binding.history,
      compact: compact,
      showArchived: widget.showArchived,
      showUnread: widget.showUnread,
      newButtonKey: widget.newButtonKey,
    );
    final conversation = LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          HandrailPendingApprovalInbox(
            binding: widget.binding.approvals,
            reviewBuilder: widget.approvalReviewBuilder,
            titleFor: widget.approvalTitle,
          ),
          Expanded(
            child: HandrailConversationTranscript(
              key: widget.transcriptKey,
              binding: widget.binding.transcript,
              style: widget.transcriptStyle,
              onOpenLink: widget.onOpenLink,
              allowMessageLinks: widget.allowMessageLinks,
              copyText: widget.copyText,
              citationLink: widget.citationLink,
              trailing: [
                HandrailApprovalDecisionsView(
                  binding: widget.binding.approvals,
                  reviewBuilder: widget.approvalReviewBuilder,
                  titleFor: widget.approvalTitle,
                ),
                ...widget.transcriptTrailing,
              ],
              emptyBuilder: widget.emptyBuilder,
              attachmentBuilder:
                  widget.attachmentBuilder ??
                  (downloader != null && id != null && downloadMaximum is int
                      ? (context, attachment) => HandrailSavedAttachment(
                          attachment: attachment,
                          scope: (widget.binding.scope, id),
                          downloader: downloader,
                          maximumBytes: downloadMaximum,
                          saveAttachment: widget.saveAttachment,
                        )
                      : null),
              toolResultBuilder: widget.toolResultBuilder,
              showToolActivity: widget.showToolActivity,
              loadingLabel: widget.loadingLabel,
              workingLabel: widget.workingLabel,
              failureLabel: widget.failureLabel,
              errorLabel: widget.errorLabel,
              errorKey: widget.errorKey,
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .8),
            child: SingleChildScrollView(
              child: Padding(
                padding: widget.composerPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.contextHeader case final header?) header,
                    if (drafts.controller.draftInputError
                        case final inputError?)
                      Semantics(liveRegion: true, child: Text(inputError)),
                    if (drafts.controller.restoringDraft)
                      Semantics(
                        liveRegion: true,
                        child: const Text('Restoring draft…'),
                      ),
                    if (drafts.controller.draftStorageError
                        case final draftError?)
                      Semantics(
                        liveRegion: true,
                        child: Column(
                          children: [
                            Text(draftError),
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => unawaited(
                                    drafts.controller.flushDraft().catchError(
                                      (Object _) {},
                                    ),
                                  ),
                                  child: const Text('Retry saving draft'),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(
                                    drafts.controller
                                        .reloadSavedDraft()
                                        .catchError((Object _) {}),
                                  ),
                                  child: const Text(
                                    'Replace editor with saved draft',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (drafts.restoringAttachments)
                      Semantics(
                        liveRegion: true,
                        child: const Text('Restoring files…'),
                      ),
                    if (drafts.attachmentStorageError case final error?)
                      Semantics(
                        liveRegion: true,
                        child: Column(
                          children: [
                            Text(error),
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => unawaited(
                                    drafts.flushAttachmentDraft().catchError(
                                      (Object _) {},
                                    ),
                                  ),
                                  child: const Text('Retry saving files'),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(
                                    drafts.reloadSavedAttachments().catchError(
                                      (Object _) {},
                                    ),
                                  ),
                                  child: const Text(
                                    'Replace selections with saved files',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    HandrailComposer(
                      key: widget.composerKey,
                      controller: drafts.controller,
                      maxLength: widget.maxInputLength,
                      maxLines: widget.composerMaxLines,
                      allowExpand: widget.allowExpandedEditor,
                      expandedEditorTitle: widget.expandedEditorTitle,
                      attachKey: widget.attachKey,
                      onAttach: widget.attachmentPicker == null
                          ? null
                          : () => unawaited(
                              drafts.pickAttachmentsUsing(
                                widget.attachmentPicker!,
                              ),
                            ),
                      expandKey: widget.expandKey,
                      expandedInputKey: widget.expandedInputKey,
                      attachmentDrafts: drafts,
                      focusNode: widget.focusNode,
                      contextMenuBuilder: widget.contextMenuBuilder,
                      onPasteImage: widget.onPasteImage,
                      onVoiceBusyChanged: widget.onVoiceBusyChanged,
                      inputKey: widget.inputKey,
                      sendKey: widget.sendKey,
                      placeholder: widget.placeholder,
                      inputTextStyle: widget.inputTextStyle,
                      decoration: widget.composerDecoration,
                      sendButtonStyle: widget.sendButtonStyle,
                      approvalMode: _approvalMode,
                      onApprovalModeApply:
                          capabilities['changeApprovalMode']
                              is Future<void> Function(String)
                          ? (mode) =>
                                (capabilities['changeApprovalMode']
                                    as Future<void> Function(String))(
                                  mode == HandrailApprovalMode.automatic
                                      ? 'automatic'
                                      : 'required',
                                )
                          : null,
                      showApprovalControl: widget.showApprovalControl,
                      onApprovalModeChanged: (mode) {
                        setState(() => _approvalMode = mode);
                        widget.onApprovalModeChanged?.call(mode);
                      },
                      showAttachmentControl: widget.showAttachments,
                      voiceControls: transcriber == null ? const [] : null,
                      transcribeAudio: transcriber,
                      transcriptionScope: (widget.binding.scope, id),
                      transcriptionMaximumBytes:
                          capabilities['transcriptionMaximumBytes'] as int? ??
                          25 * 1024 * 1024,
                      transcriptionMaximumDuration: Duration(
                        milliseconds:
                            (math.min(
                                      (capabilities['transcriptionMaximumDurationSeconds']
                                              as num?) ??
                                          60,
                                      60,
                                    ) *
                                    1000)
                                .floor(),
                      ),
                      transcriptionMaxDraftLength: widget.maxPromptLength,
                      audioRecorderFactory: widget.audioRecorderFactory,
                      enabled: state['enabled'] == true,
                      canSend: _eligible(state),
                      sending: sending,
                      stopping: state['stopping'] == true,
                      onSend: () => unawaited(_send()),
                      onStop: drafts.uploadingAttachments
                          ? drafts.cancelUploads
                          : state['canStop'] == true && id != null
                          ? () {
                              unawaited(
                                widget.binding
                                    .stop(id)
                                    .catchError((Object _) {}),
                              );
                            }
                          : null,
                    ),
                    if (_localError case final error?)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (widget.showPromptCounter || tooLong)
                      Text(
                        !widget.showPromptCounter && tooLong
                            ? 'Message is too long — shorten before sending.'
                            : '${drafts.controller.text.length} / ${widget.maxPromptLength} characters${tooLong ? ' — shorten before sending' : ''}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: tooLong
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (!widget.threads)
      return Column(
        children: [
          if (widget.onClearConversation != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: sending || !widget.submissionEnabled || _clearing
                    ? null
                    : _clearConversation,
                child: Text(_clearing ? 'Clearing…' : 'Clear conversation'),
              ),
            ),
          if (_clearFailed)
            const Text(
              'The conversation could not be cleared. Finish any pending review, response or voice call, then retry.',
            ),
          Expanded(child: conversation),
        ],
      );
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= widget.sidebarBreakpoint
          ? Row(
              children: [
                SizedBox(width: 260, child: history(false)),
                const VerticalDivider(width: 1),
                Expanded(child: conversation),
              ],
            )
          : Column(
              children: [
                history(true),
                Expanded(child: conversation),
              ],
            ),
    );
  }
}
