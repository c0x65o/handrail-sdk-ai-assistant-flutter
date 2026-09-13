# Handrail standard composer

`HandrailComposer` places the multiline draft above a toolbar with Add and an optional shield on the left, and dictation and a green Send arrow on the right. Padding is 8 logical pixels, draft inset 4 pixels, corner radius 16 pixels, minimum draft height 26 pixels, and controls 40 pixels with smaller icons. The draft starts at one line and grows with its content.

Pass the shared composer controller, an authenticated SDK session adapter, and current availability. The default attachment controls use the SDK picker and upload queue. The SDK session owns admission, synchronization and the pending-message journal; hosts supply authentication and storage bindings. `input` and `voiceControls` let existing authenticated text/paste/transcription implementations share the layout. Dictation appends to the draft and never sends it. Default device dictation uses speech_to_text; platform availability and microphone/speech permissions apply.

`decoration`, `inputTextStyle`, and `sendButtonStyle` customize the stock composer for host branding and dark themes. Unspecified properties retain the standard defaults. Custom input widgets retain their own typography. Set `showAttachmentControl: false` when the authenticated gateway does not offer uploads; this hides the toolbar control without changing upload policy.

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
    sessions[id]?.capabilities?.attachments,
    sessions[id]?.capabilities?.documentInput),
  uploaderForConversation: (_) => client.attachmentUploader(),
);
drafts.select(session.conversationId);

// Listen to drafts and session.changes to rebuild the shared composer.
HandrailComposer(
  controller: drafts.controller,
  attachmentDrafts: drafts,
  enabled: authorized,
  canSend: authorized && !session.isSubmitting && !drafts.isSubmitting &&
      !running && !hasPendingMessage &&
      (drafts.controller.text.trim().isNotEmpty || drafts.attachments.isNotEmpty),
  sending: drafts.uploadingAttachments || running,
  onStop: drafts.uploadingAttachments ? drafts.cancelUploads : stopResponse,
  onSend: () async {
    // Capture the originating session, route and preference before any upload.
    final origin = session, route = currentRoute, mode = approvalMode;
    try {
      await drafts.submitWithAttachments((text, references, accepted) =>
        origin.sendMessage(
          operationId: createOperationId(), clientId: 'my-project-mobile',
          request: buildDomainRequest(text, references, route,
              metadata: handrailApprovalMetadata(mode)),
          pendingStore: authenticatedPendingStore,
          onAccepted: (_) => accepted(),
        ));
    } on HandrailAttachmentException {
      // The shared control already displays the upload/retry guidance.
    }
  },
);

// On an uncertain-send Retry action, preserve the saved request/IDs.
await drafts.retry((accepted) => session.retryPendingMessage(
  authenticatedPendingStore, onAccepted: (_) => accepted(),
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
Shared upload orchestration is included below. A complete Flutter
workspace/history surface remains in progress. Authenticated transcription is now available through the
negotiated SDK client binding below; device dictation is the explicit fallback
when an app has not configured a transcription transport.


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
  // Configure canSend/onSend/onStop from the SDK session as above.
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
`audioRecorderFactory` is an optional platform/test adapter; the default is SDK
`HandrailPcmAudioRecorder`, consolidated from Mills' former implementation.

Recording uses [record 6.2.1](https://pub.dev/packages/record/versions/6.2.1), the
version already used by Mills. The widgets require Dart 3.10 and Flutter 3.38, including the shared file picker.
Declare `RECORD_AUDIO` on Android and `NSMicrophoneUsageDescription` on iOS;
permission is requested when the microphone is activated. Device speech recognition
additionally needs its platform setup described above. No provider API key belongs
in the mobile app. A normal SDK dependency update must resolve the recorder plugin
and platform dependencies through Flutter; explicit candidate test configurations
do not qualify native plugin registration or live microphone behavior.

## Shared attachments

The default `HandrailComposerController` owns per-conversation selected files,
negotiated type/count/per-file/document/total limits, native picker and image-paste
intake, upload progress, cancellation, and safe inline errors. Files are bounded
while being read. The composer includes a scrollable file list with remove controls.
Its picker is [file_picker 12.1.1](https://pub.dev/packages/file_picker/versions/12.1.1),
already used by Spartan. This requires Dart 3.10/Flutter 3.38 and iOS 14 or newer;
consumer platform setup and plugin registration must be qualified during the
normal SDK revision upgrade. The default total selection bound is 20 MiB and can
be explicitly reduced through `HandrailAttachmentLimits`.

Every selected file retains an upload idempotency key. Retrying a partially failed
batch reuses successful references and the failed file's key. Removal/reselection
creates a new selection, even for identical bytes. Admission clears only the
submitted selections; later drafts survive completion/failure/cancellation.
Cancellation and disposal exclude late uploads. This queue is in memory: clearing
it or signing out releases unsent selections; admitted/uncertain requests remain
in the SDK's authenticated pending-message store. Do not auto-reselect or re-upload
files to retry a retained turn.

`client.attachmentUploader()` supplies the shared queue's structural callback.
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
