# Handrail optional assistant UI

Use `HandrailAssistantWorkspace(binding: assistant.uiBinding, drafts: drafts)`
for the common assistant experience. Create account-retained drafts with
`HandrailComposerController.forAssistant(assistant.uiBinding)` and forward
pending recovery acceptance as shown in [minimal mobile adoption](../../docs/mobile-assistant-adoption.md).
The workspace owns responsive history, transcript, send/stop wiring, approval
settings, uploads and authenticated voice defaults. Business request construction,
route context, branding and result renderers remain host options.

`maxPromptLength` gates sending while retaining an editable draft. Optional
`maxInputLength` also hard-limits the standard and expanded editor; it must not
exceed the prompt bound. `composerMaxLines`, `allowExpandedEditor` and
`expandedEditorTitle` configure the shared editor without replacing it.
`transcriptTrailing`, `emptyBuilder` and `citationLink` supply domain formatting.
`submissionEnabled` adds a business readiness gate to SDK send eligibility; it
does not enable archived or otherwise ineligible requests. Control visibility
and readiness do not replace server authorization.

Ordinary account-retained workspaces preserve drafts when their view closes.
Hosts that require discard confirmation can wrap the surface in
`HandrailAssistantCloseGuard`, supplying its binding, drafts,
`HandrailAssistantCloseController`, `onClose` navigation and child. Enable
`confirmDraftDiscard` and/or `blockWhileWorking` explicitly. The controller's
`requestClose()` connects branded buttons or authorized navigation to the same
policy as system Back. `businessBusy` adds domain-operation readiness and
`assistantLabel` supplies branding. The SDK owns the confirmation, duplicate
activation gate, account-scoped route cleanup and draft cleanup. Work detection
includes other conversations and file intake. Closing never requests server
cancellation; Stop is a separate action. Keep the guard and its controller
scoped to the same account as the workspace.

The composer scopes its approval sheet to the active account/conversation.
Standalone `HandrailApprovalBadge` consumers should supply `scope` explicitly;
changing that scope or disabling the control closes the old sheet and prevents
its callbacks from changing later settings. Control visibility never grants
server permissions.

`HandrailComposer` places the multiline draft above a toolbar with Add and an optional shield on the left, and dictation and a green Send arrow on the right. Padding is 8 logical pixels, draft inset 4 pixels, corner radius 16 pixels, minimum draft height 26 pixels, and controls 40 pixels with smaller icons. The draft starts at one line and grows with its content.

Pass the shared composer controller, an authenticated SDK session adapter, and current availability. The default attachment controls use the SDK picker and upload queue. The SDK session owns admission, synchronization and the pending-message journal; hosts supply authentication and storage bindings. `input` and `voiceControls` let existing authenticated text/paste/transcription implementations share the layout. Dictation appends to the draft and never sends it. The combined workspace negotiates protected transcription and hides the microphone when unavailable. The standalone composer supports device speech recognition as an explicit lower-level fallback; platform availability and microphone/speech permissions apply.

`decoration`, `inputTextStyle`, and `sendButtonStyle` customize the stock composer for host branding and dark themes. Unspecified properties retain the standard defaults. Custom input widgets retain their own typography. Set `showAttachmentControl: false` when the authenticated gateway does not offer uploads; this hides the toolbar control without changing upload policy.

Use `contextMenuBuilder` for a native platform context-menu adapter while keeping
the standard editor, keyboard handling and Send focus behavior. An app does not
need to replace the whole `input` just to customize its native Paste menu.

`showApprovalControl` only changes visibility. Default `approvalMode` is required. Wire `onApprovalModeChanged` to the per-message preference and include `handrailApprovalMetadata(mode)` in the retained gateway ChatRequest metadata. The server must validate and resolve this preference before executing tools, while enforcing account permissions. Never implement automatic mode by confirming old proposal cards in the client. Changes to the preference apply to the next submitted request; retained retries preserve their original preference.

Image paste uses `attachmentDrafts` when shared uploads are enabled; `onPasteImage` is an optional host override. The default editor includes a Paste image context action and Control/Command+V handling with normal text fallback. All pasted bytes go through the same negotiated attachment validation and authenticated upload queue. Prefer the default input. A custom `input` must receive the same `focusNode` as the composer, and remains responsible for its platform input actions.

Add NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription on iOS. On Android declare RECORD_AUDIO and query android.speech.RecognitionService. See the speech_to_text and pasteboard package documentation for supported platforms. Pasteboard's FileProvider, if configured, should expose only the application cache required by the integration.


## Shared message Markdown

Use `HandrailMarkdown(data: answer)` for assistant messages in custom or legacy
transcripts. CommonMark/GFM parsing (including aligned tables) is owned by this
SDK. Wide tables scroll horizontally inside the message. `selectable: true`
retains text selection; `isUserMessage: true` displays the source literally.
Links only navigate through the optional safe `onTapLink(text, href, title)` host
callback; inline images stay disabled. `styleSheet` accepts `MarkdownStyleSheet`
(re-exported by this library) for host typography/colors. Table scrolling remains
SDK-owned. See `docs/markdown-rendering.md` in the repository for the shared
React/Flutter contract and examples.

## Shared submission lifecycle

`HandrailDraftController` clears only the submitted edit revision when the SDK
session calls `onAccepted`. Keep the input `enabled` during a response and gate
`canSend` separately on authorization, prompt bounds, pending intent and active
turn state. Send restores input focus immediately; completion never restores
focus or clears a later draft. Enter sends, Shift+Enter inserts a newline, and
IME composition does not send. Set `sendOnEnter: false` for newline behavior.
The Stop control uses the supplied authoritative cancellation callback.

Use `HandrailComposerDrafts<TAttachment>` for per-conversation text and file
selections. Call `select(conversationId)` during navigation; `controller` and
`attachments` expose the selected draft. `submit` captures its exact text edit
and file selections; `retry` reconciles the retained submission without using a
new draft. Removed/re-added identical files and identical later text survive
admission. A background callback only affects its originating conversation.
`discard(id)`, `clear()` and `dispose()` invalidate old callbacks. Dispose the
workspace on account changes. Prefer `HandrailComposerController` below for complete
file intake and upload behavior; the generic controller supports existing host
attachment models without requiring another upload implementation.

```dart
// Account-owned; retain this across closing/reopening the assistant surface.
final drafts = HandrailComposerController(
  limitsForConversation: (id) => HandrailAttachmentLimits.fromCapabilities(
    assistant.sessionFor(id)?.capabilities?.attachments,
    assistant.sessionFor(id)?.capabilities?.documentInput),
  uploaderForConversation: (id) => client.attachmentUploader(conversationId: id),
);
drafts.select(assistant.selectedId);

// Listen to drafts and assistant.changes to rebuild the shared composer.
HandrailComposer(
  controller: drafts.controller,
  attachmentDrafts: drafts,
  enabled: authorized && !assistant.archived && assistant.document != null,
  canSend: authorized && assistant.canSend && !drafts.isSubmitting &&
      (drafts.controller.text.trim().isNotEmpty || drafts.attachments.isNotEmpty),
  sending: drafts.uploadingAttachments || assistant.submitting || assistant.running,
  onStop: drafts.uploadingAttachments ? drafts.cancelUploads :
      assistant.canStop ? () async {
        try { await assistant.requestCancellation(); }
        on HandrailGatewayException { /* Render assistant.error. */ }
      } : null,
  onSend: () async {
    // Capture the originating session, route and preference before any upload.
    final originId = assistant.selectedId!, route = currentRoute, mode = approvalMode;
    try {
      await drafts.submitWithAttachments((text, references, accepted) =>
        assistant.sendMessage(
          buildDomainRequest(text, references, route,
              metadata: handrailApprovalMetadata(mode)),
          conversationId: originId,
          onAccepted: (_) => accepted(),
        ));
    } on HandrailAttachmentException {
      // The shared control already displays the upload/retry guidance.
    } on HandrailGatewayException {
      // Render assistant.error and the retained-send recovery action.
    }
  },
);

// On an uncertain-send Retry action, preserve the saved request/IDs.
await drafts.retry((accepted) => assistant.retryPendingMessage(
  onAccepted: (_) => accepted(),
));
```

`allowExpand: true` adds an SDK-owned full-message editor; `maxLines` controls
the compact field and `expandedEditorTitle` supplies branding. The expanded
editor shares the draft without submitting, and closes when its controller or
authorization scope changes. `expandKey` and `expandedInputKey` support host UI
qualification without replacing the editor.

These APIs are a local consolidation candidate until included in a public,
committed SDK revision. Consumer manifests/locks must use that full HTTPS Git
SHA through normal Flutter resolution. Test-only candidate package resolution
is not an installed dependency or evidence of production/mobile parity.
Shared upload orchestration and the standard history picker are included below.
The combined workspace negotiates authenticated transcription automatically and
hides the microphone if unavailable. The lower-level composer also accepts the
SDK binding below; its device dictation remains the fallback when an app uses
that component without a transcription transport.

## Shared conversation transcript

Use `HandrailConversationTranscript(binding: assistant.transcriptBinding)` in an
`Expanded` or otherwise bounded area. It supplies standard user/assistant bubbles,
selectable Markdown, safe citation chips, Copy, collapsed tool activity and
retry/status notices. Tool arguments are never included in the default activity
details. `HandrailTranscriptStyle` supplies branding; `toolResultBuilder` adds
domain result cards, and `onOpenLink` remains the host's authorized navigation
adapter. Unsafe link schemes are disabled before navigation. The combined
workspace supplies protected saved-file controls from the negotiated gateway.
The standalone transcript shows filenames unless `attachmentBuilder` supplies
that binding or a legacy authorized adapter.

The SDK retains scroll position per conversation and follows new replies only
when the user is at the end. Read acknowledgement requires the actual transcript
end to be visible on the current foreground route with a terminal reply. Returning
from another screen rechecks visibility without waiting for another server event.
Retries and stateful content remain bound to their conversation/account.

An existing domain projection can supply `contentBuilder` to format the complete
contents and use `HandrailTranscriptMessage` for the shared bubbles. This explicit
override replaces default content controls; scrolling and read/account lifecycle
stay SDK-owned. New integrations should use the default content and narrower
domain result/attachment adapters.

## Shared conversation history

Use `HandrailConversationHistory(binding: assistant.historyBinding)` with the
headless SDK's account-owned `HandrailAssistantController`. The compact control
opens an SDK-owned, scrollable history sheet with New, Active/Archived, Unread,
previews, dates, running indicators, archive/restore and retry/pagination.
`compact: false` renders that same history as a bounded sidebar.
`showArchived`/`showUnread` are presentation settings; they never change server
permissions. `title`, `newButtonKey` and the inherited Material theme customize
branding without replacing controls or their lifecycle.

The sheet closes on account binding replacement or disposal. Opening it
unfocuses the draft; later catalog replies do not steal focus. At narrow widths
and enlarged text, New becomes a labelled icon and header/error controls scroll
with history. The client binding is structural, so the widgets package remains
independent of the headless package. See
[minimal mobile adoption](../../docs/mobile-assistant-adoption.md).


## Authenticated microphone input

The optional composer can bind directly to a configured gateway:

```dart
final capability = session.capabilities?.transcription;
HandrailComposer(
  controller: drafts.controller,
  transcriptionScope: (authenticatedClient, session.conversationId),
  transcribeAudio: capability == null ? null
      : authenticatedClient.transcriptionForConversation(
          session.conversationId, capability: capability),
  transcriptionMaximumBytes: capability?.maximumBytes ?? 25 * 1024 * 1024,
  transcriptionMaximumDuration: const Duration(seconds: 60), // Clamp to gateway limit.
  transcriptionMaxDraftLength: 2000,
  // Configure canSend/onSend/onStop from the SDK assistant controller as above.
);
```

Require a negotiated WAV format and clamp the capture duration to the advertised
maximum. A null transport retains the device-dictation fallback; hosts can hide
unavailable voice using `voiceControls: const []`. Control visibility does not
change server authorization. `HandrailTranscriptionControl` is also exported for
custom shells; its `transcribe` accepts the same SDK-bound function.

The shared control owns permission/capture progress, Stop/Discard, bounded PCM/WAV
capture, per-recording identity, cancellation, authenticated HTTP retry and draft
insertion. It inserts into the latest draft without sending. If the combined text
is too long, it retains the transcript for insertion after editing, without a
second provider request. Retryable transport failures retain the exact audio/key;
unknown outcomes cannot retry. Scope/controller changes, backgrounding and
unmount cancel observation and exclude late results. Audio is cleared after use.
Errors appear inline below the composer's toolbar, so Retry, Discard and Send
remain reachable even at the bottom of a narrow screen. Standalone controls
expose the safe error through `onErrorChanged` (or an accessible error tooltip
when no callback is supplied); they do not create an overlapping snackbar.
`audioRecorderFactory` is an optional platform/test adapter; the default is SDK
`HandrailPcmAudioRecorder`, consolidated from Mills' former implementation.
`transcriptionButtonKey` and `transcriptionButtonStyle` customize the standard
microphone button without replacing its lifecycle.

Recording uses [record 6.2.1](https://pub.dev/packages/record/versions/6.2.1), the
version already used by Mills. The widgets require Dart 3.10 and Flutter 3.38, including the shared file picker.
Declare `RECORD_AUDIO` on Android and `NSMicrophoneUsageDescription` on iOS;
permission is requested when the microphone is activated. Device speech recognition
additionally needs its platform setup described above. No provider API key belongs
in the mobile app. A normal SDK dependency update must resolve the recorder plugin
and platform dependencies through Flutter; explicit candidate test configurations
do not qualify native plugin registration or live microphone behavior.

## Shared attachments

`HandrailAssistantWorkspace` supplies saved-file previews and Download controls
automatically when its gateway advertises `attachmentDownloads`. Its headless
`uiBinding.downloaderFor` captures the originating conversation and authenticated
client. Downloads remain available when new uploads are hidden. Older gateways
without this capability keep the filename fallback; an explicit host
`attachmentBuilder` retains precedence.

`HandrailSavedAttachment` combines the protected reader with the shared preview
lifecycle and `handrailSaveAttachment`, which uses the SDK's existing file picker
to open a native save dialog. `saveAttachment` is an optional platform override,
not required host infrastructure. Cancelling that dialog is not an error. Image
previews and each Download activation validate fresh protected bytes; account or
conversation changes and disposal cancel pending reads. Temporary private copies
are cleared after platform use. Widget tests qualify the platform callback with
a fake platform implementation, not an actual device dialog.

Saved-file UI uses `HandrailAttachmentPreview`. It owns preview loading and
retry, duplicate-open prevention, safe inline failures, scope invalidation and
private byte cleanup. `onOpenBytes` performs a fresh authorized read before
calling the platform adapter, even when an image preview is already cached:

```dart
HandrailAttachmentPreview(
  scope: (account, conversationId),
  attachmentId: attachment.id,
  label: attachment.filename,
  mediaType: attachment.mediaType,
  expectedByteSize: attachment.byteSize,
  maximumBytes: 10 * 1024 * 1024,
  loadBytes: () => loadAuthorizedBytes(conversationId, attachment),
  onOpenBytes: (bytes) => openWithNativeFileViewer(attachment, bytes),
);
```

The host/network adapter remains responsible for authorization, response MIME
validation and bounding the response read. The widget validates returned bytes
against `maximumBytes` and optional `expectedByteSize` before preview/open.
Open callbacks borrow a private copy until their future completes; copy it if
the platform needs longer ownership. The SDK never clears the loader's buffer.
Late reads cannot open files after scope changes, view disposal or navigation
away. Scope changes/disposal also evict and clear the private image preview.
These legacy callback reads are not themselves cancelled at the network layer.
Use `loadBytesWithCancellation` to propagate the widget's scope/disposal signal
to a protected reader; the default workspace does this automatically.

The default card remains compatible with existing `loadBytes`/`onOpen`
consumers. `HandrailAttachmentPresentation.inline`, dimensions, labels and keys
customize formatting without rebuilding this lifecycle. Inline non-image files
use the shared open/retry control, including PDFs and supported spreadsheets.
Pass this component from the transcript's `attachmentBuilder` when retaining
a custom protected endpoint or platform presentation.

The default `HandrailComposerController` owns per-conversation selected files,
negotiated type/count/per-file/document/total limits, native picker and image-paste
intake, upload progress, cancellation, and safe inline errors. Files are bounded
while being read. The composer includes a scrollable file list with remove controls.
Its picker is [file_picker 12.1.1](https://pub.dev/packages/file_picker/versions/12.1.1),
already used by Spartan. This requires Dart 3.10/Flutter 3.38 and iOS 14 or newer;
consumer platform setup and plugin registration must be qualified during the
normal SDK revision upgrade. The default total selection bound is 20 MiB and can
be explicitly reduced through `HandrailAttachmentLimits`.

Pass `attachmentLimits` to `HandrailComposerController.forAssistant` to intersect
host business bounds with each conversation's negotiated limits. The intersection
uses common MIME types and the smaller count/per-file/document/total bounds;
an empty MIME intersection disables intake. A host cannot widen gateway limits.
`drafts.hasDrafts` and `drafts.isWorking` include unselected conversations.

Every selected file retains an upload idempotency key. Retrying a partially failed
batch reuses successful references and the failed file's key. Removal/reselection
creates a new selection, even for identical bytes. Admission clears only the
submitted selections; later drafts survive completion/failure/cancellation.
Cancellation and disposal exclude late uploads. This queue is in memory: clearing
it or signing out releases unsent selections; admitted/uncertain requests remain
in the SDK's authenticated pending-message store. Do not auto-reselect or re-upload
files to retry a retained turn.

`client.attachmentUploader(conversationId: id)` supplies the shared queue's
structural callback with the originating conversation required by the standard
gateway. `uiBinding.uploaderFor` supplies this binding automatically.
It uses the protected gateway, disallows redirects, bounds response/time/bytes,
validates returned references, and avoids content in diagnostics. Per-file caps
can be passed to that binding; the queue separately enforces negotiated limits.
Visibility flags never grant upload or business permissions.

Existing host-rendered selections can use `HandrailComposerDrafts<T>` with
`fileForAttachment`, `limitsForConversation`, and `uploaderForConversation`.
`prepareAttachments(values, onProgress: ...)` uses the same retained queue.
Keep immutable selection objects across retry, select the originating chat before
preparation, and call `discard(originId)` only when its message is accepted.
Hosts should supply formatting and business limits, not another upload loop.
