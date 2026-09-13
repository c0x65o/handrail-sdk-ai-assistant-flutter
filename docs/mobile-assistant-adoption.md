# Shared mobile assistant adoption

Use one account controller and one draft controller per authenticated account/API
realm. Retain both when a sheet closes, and dispose them when that account ends.
The optional workspace supplies responsive history, the canonical transcript,
Send/Stop, approval settings, uploads and authenticated dictation by default.
The host supplies protected transport, encrypted pending storage, business
request construction and branding.

```dart
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

// Construct after authenticated client and accountStore are available.
late final HandrailComposerController drafts;
final assistant = HandrailAssistantController(
  client: client,
  pendingStore: accountStore,
  clientId: 'my-project-mobile',
  beforePendingRecovery: (id) => drafts.capturePendingAcceptance(id),
);
drafts = HandrailComposerController.forAssistant(assistant.uiBinding);

// Place in a bounded view. No host history, send or microphone loop is needed.
HandrailAssistantWorkspace(
  binding: assistant.uiBinding,
  drafts: drafts,
);
```

The widget initializes the account controller. The draft factory binds selected
conversation and negotiated upload capabilities without an app-owned listener.
The packages remain independent; `uiBinding` is a structural Dart record. The
workspace uses a history picker on phones and a sidebar at 720 logical pixels.
It includes Markdown, Copy, citations, activity, errors/recovery, archive/restore,
unread filtering, previews and default request construction. The UI binding
supplies verified admission, cancellation and initial-title presentation. A title
failure never changes the result of an accepted send.

For business context, snapshot an immutable route/account value at activation:

```dart
HandrailAssistantWorkspace<MyRoute>(
  binding: assistant.uiBinding,
  drafts: drafts,
  captureContext: () => currentRoute,
  buildRequest: (submission) => businessRequest(
    submission.text,
    submission.context!,
    submission.attachments,
  ),
  placeholder: 'Ask my assistant…',
  maxPromptLength: 2000,
  transcriptStyle: const HandrailTranscriptStyle(assistantLabel: 'My assistant'),
  onOpenLink: openAuthorizedAppDestination,
  toolResultBuilder: renderBusinessResult,
);
```

The SDK captures the business value, builder and approval preference before
upload. After upload it stamps the captured approval metadata into the request;
the server still enforces authorized policy. Hiding approval controls does not
alter preference or permissions. `showVoice`, `showAttachments`, `showArchived`,
`showUnread`, `showToolActivity` and `showPromptCounter` are explicit UI settings.
`initialApprovalMode` defaults to required review. Domain formatting uses the
result/attachment renderers, transcript style, composer style and context header.

A send stays bound to its original conversation during navigation; later drafts
and files remain separate. Admission clears only the original edit revision and
exact file selections. Completion, failure and Stop do not restore old text.
The next draft stays editable. Stop is available during upload and pending
admission, and a stopping indicator remains until canonical cancellation settles.
The SDK's pending recovery callback preserves retained-request draft identity.
Approval sheets close on account/conversation changes; adding attachment rows
does not recreate the editor or microphone controls.

Retain `assistant` and `drafts` outside the view. At account teardown, dispose
`drafts`, await `assistant.dispose()`, then close the host-owned transport. Closing
the view alone must not cancel server work or discard drafts. Keep keyboard
insets/outer route sizing in the application's surrounding layout; the workspace
accepts `composerPadding` for that formatting.

For an existing custom business shell, `HandrailConversationHistory`,
`HandrailConversationTranscript` and `HandrailComposer` remain supported
individually. Their lower-level APIs are documented in the package READMEs.

| Feature | Shared SDK ownership | Host ownership |
| --- | --- | --- |
| Catalog/history | Paging, selection, archive/restore, stable retries, remote unread/preview state, picker/sidebar | Theme, labels, visibility flags |
| Sending | Immutable pending journal, admission, retry, draft revision and file identity, canonical cancellation | Domain request, authenticated storage and transport, prompt bounds |
| Voice/files | Capture, negotiated limits, protected upload/transcription, insertion, cancellation, retry | Permissions/platform setup, authenticated gateway and business limits |
| Approval | Preference control and per-request metadata; shared gateway policy mechanisms | Authorized server policy, business review validation and tools |
| Transcript | Bubbles, Markdown, citations, Copy, activity/errors, scroll/read lifecycle, protected saved-file controls and account isolation | Theme, authorized navigation, domain result formatting; optional legacy file adapter |
| Closing | Optional draft confirmation, duplicate activation, account-wide work and owned-route cleanup | Navigation callback, branding, discard/work flags and business readiness |

Cents and Spartan mobile now use the combined workspace and account controller.
Spartan supplies its domain review/result cards through `transcriptTrailing`,
business readiness through `submissionEnabled`, and compact/expanded editor
presentation through `composerMaxLines`, `allowExpandedEditor` and
`maxInputLength`. New retains drafts in other conversations. Its route context
uses `newConversationMetadata` on the client controller; the callback is sampled
once and frozen with the creation request, so retries retain the original route.
`session.waitForTurn` remains available for business operations that require
terminal observation without changing selection or cancelling remote work.

The standard transcript now owns message bubbles, Markdown, safe citations,
Copy, tool activity, recovery notices, scroll position and read acknowledgement.
New replies follow the end only while the user is already there. Covered routes,
background views and offscreen replies do not acknowledge unread activity.
Use `toolResultBuilder` for domain cards. The combined workspace negotiates
protected saved-file previews and Download controls automatically through
`attachmentDownloads`, independently of upload visibility. `attachmentBuilder`
overrides this for existing domain file endpoints; `saveAttachment` optionally
customizes the native save dialog. A gateway without download capability keeps
the filename fallback. The reader preserves the server's retention and account/
conversation checks; it does not extend expired files or create public URLs.
`contentBuilder` is an explicit formatting override for existing domain
projections: it replaces the standard content while keeping shared scrolling,
account/conversation isolation and visible read handling. It is not needed for
minimal adoption. `HandrailTranscriptMessage` provides the same message behavior
inside such a projection.

Cents and Spartan retain their business requests, routes, branding and result
renderers. Spartan's bespoke conversation controller, upload/send wrappers and
history/composer shell are removed. It selects shared close confirmation through
`HandrailAssistantCloseGuard` with `confirmDraftDiscard` and `blockWhileWorking`;
ordinary account-retained views do not need these flags. Both the branded Close
button and system Back then use shared account-safe confirmation. Closing never
cancels remote work. Business file bounds use the draft factory's
`attachmentLimits` intersection with negotiated gateway limits.

Mills' existing screen and protected-operation integration remains compatible;
its household history reconciliation and business authorization must survive
further adoption. This candidate does not establish complete mobile or deployed
parity across all consumers.

Current qualification uses temporary test-only package resolution against local
SDK source. Application manifests and locks retain their existing committed
HTTPS Git pins. Consumer adoption needs a reviewed public full SHA from this
Flutter repository and matching normal Flutter resolution/build. No local-path,
workspace, tarball or registry substitution belongs in consumer dependencies.
Local widget/gateway tests do not establish OS microphone, Mobile Preview or
production parity.
