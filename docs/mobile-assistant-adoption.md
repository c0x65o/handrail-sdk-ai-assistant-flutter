# Shared mobile assistant adoption

Use one account controller and one draft controller per authenticated account/API
realm. Retain both when a sheet closes, and dispose them when that account ends.
The optional workspace supplies responsive history, the canonical transcript,
Send/Stop, approval settings, pending approval decisions, uploads and authenticated dictation by default.
The host supplies protected transport, encrypted pending storage, business
request construction and branding.

## Current public adoption — September 14, turn 35

Mills, Spartan/Aegis and Hitcents/Cents main mobile checkouts now normally install
both packages from public Flutter commit
`50fe566d73f68b2beacc2a874dc9a038363b1509`, with matching locks and actual public
Git-cache roots (client 0.1.8/widgets 0.1.1). The shared deletion, approval-decision,
workspace, protected-file and voice APIs described here are included. No local
alias or edited installed package is needed. See [approval decisions](approval-decisions.md)
and [conversation deletion](conversation-deletion.md) for safety contracts.

Mills' reviewed shared workspace/controller source is now in main, preserving
financial review, files, dictation and voice adapters. Full analysis, 312 selected
tests and the release web build pass. Aegis passes full analysis, 179 selected
assistant/shell/presentation cases and the release web build. Cents passes full
analysis, release web build and 96 selected tests, including its visual gate at
0.12282185395988604 against the unchanged 0.123000 bound. Its six active goldens
are installed-SDK captures; the bundled test-font Greek-glyph limitation remains.
Passing that aggregate threshold is not pixel parity or live qualification.

The Flutter test gateway normally installs public JS
`15a3806c2595a3f93a87a768ad13293113f41b58`; full client analysis and all 138 client
cases pass, including real HTTP deletion/restart, approval recovery and protected
attachment ownership/expiry. This public revision contains the removed-version
receipt correction. A newer JS terminal-approval response fix remains unpublished;
Aegis's unchanged installed server assertion still exposes that regression.

Realtime voice has a [shared surface](realtime-voice-surface.md) for status,
identity choices, mute/playback, Stop/Back, uncertain-end retry and backgrounding.
`HandrailWebRtcVoiceSession<T>` owns capture, peer/data-channel setup, playback
and teardown. Mills supplies trusted speaker context, financial review and its
authenticated SDP/end gateway. Local tests do not establish actual provider/audio
or native-device execution. Development Mobile Preview access was denied for
all three projects as outside this Dev Chat's saved scope; no app failure was
reproduced by those attempts. Authorized live qualification, deployment and
approved production cleanup remain open.

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

// Place in a bounded view. No host history, send or dictation loop is needed.
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

Protected host services can be supplied without replacing chat orchestration.
`HandrailComposerController.forAssistant(..., attachmentProvider: provider)`
uses the explicitly configured service's current limits, uploader and release
callback even when the SDK gateway does not mount its default upload route.
The provider must recheck account/conversation authorization; host limits can
further restrict it. `maximumImageBytes` can be smaller than the PDF/document
limit. Release destroys retained local operation state, not remote business files.

Use `binding.withServices(transcriberFor: ..., downloaderFor: ...)` for protected
host routes. The structural adapter forwards SDK ownership, catalog, approvals,
admission and Stop unchanged. The workspace's `attachmentPicker` accepts a native
source menu; the SDK rejects results belonging to a replaced draft/account.
`copyText` supplies a platform clipboard operation while the SDK owns Copied,
accessible failure feedback, retries and stale completion protection. These
hooks are included in the public Flutter baseline above.

Use `approvalTitle` on the workspace (or `titleFor` on
`HandrailApprovalDecisionsView`) to supply business action names. This changes
only the heading; complete-review checks, trusted permission, proposal version,
saved-decision recovery and the Approve/Reject controls remain SDK-owned. Mills
uses it for labels such as deleting a manual education fund. The display hook
is included in the public Flutter baseline above.

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

For native editing, the combined workspace forwards `contextMenuBuilder` and
`onPasteImage` to its standard composer. `onVoiceBusyChanged` lets a host gate a
separate live-call surface while dictation is active. These hooks keep shared
draft, keyboard, Send and focus behavior; an alternate text-input widget is not
needed just to support an iOS edit menu.

A custom authenticated storage protocol can supply `uploaderForConversation`
to `HandrailComposerController`, or `uploaderFor` through the workspace binding.
The SDK generates one upload key per selection and retains it on Stop/retry.
Bind `onUploadReleased` on the controller/factory to the adapter's local release
method when it retains an upload intent, bytes or phase receipt. The callback
runs once per selection after removal, replacement, verified admission,
conversation discard or account disposal. Stop cancels observation/transport
without releasing the selection; a subsequent retry uses the same key. Release
is local cleanup, never authorization to delete remote files. Also dispose the
adapter at account teardown. Do not replace an uncertain upload with a new
storage identity or promote a locally stopped operation to confirmed success.

For an existing custom business shell, `HandrailConversationHistory`,
`HandrailConversationTranscript` and `HandrailComposer` remain supported
individually. Their lower-level APIs are documented in the package READMEs.

| Feature | Shared SDK ownership | Host ownership |
| --- | --- | --- |
| Catalog/history | Paging, selection, archive/restore, stable retries, remote unread/preview state, picker/sidebar, reviewed permanent deletion and its account journal | Theme, labels, visibility flags; custom atomic deletion store when not using the shared key-value adapter |
| Sending | Immutable pending journal, admission, retry, draft revision and file identity, canonical cancellation | Domain request, authenticated storage and transport, prompt bounds |
| Voice/files | Capture, negotiated limits, protected upload/transcription, insertion, cancellation, retry | Permissions/platform setup, authenticated gateway and business limits |
| Approval | Preference control and per-request metadata; shared gateway policy mechanisms | Authorized server policy, business review validation and tools |
| Transcript | Bubbles, Markdown, citations, Copy, activity/errors, scroll/read lifecycle, protected saved-file controls and account isolation | Theme, authorized navigation, domain result formatting; optional protected host file adapter |
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

Mills' retained host integrations supply household/user ownership, protected
attachments and financial business authorization. Preserve those behaviors
during further adoption. The owner discarded old chats, and the Mills source
cleanup removed legacy history import/reconciliation and its recovery gate;
do not restore them as an adoption prerequisite. New SDK history and normal
turn recovery remain required. Installed checks do not establish complete live/native
or deployed parity across all consumers.

Current consumer qualification uses the normal committed HTTPS Git pins above,
matching locks and generated public package roots. Consumer adoption requires a
reviewed full public SHA from this Flutter repository, normal resolution/build
and application checks. No local-path, workspace, tarball or registry substitution
belongs in consumer dependencies. An explicit source-only test override remains
available for developing future unpublished changes; it is not adoption evidence.
Local widget/gateway tests do not establish OS microphone, Mobile Preview or
production parity.

The shared [deletion implementation](conversation-deletion.md) extends both
packages' structural history binding with the shared deletion action. The standard
controller/workspace composition above supplies it without another host callback.
Custom bindings must adopt that member deliberately. The shared composer removes
only the confirmed deleted conversation's draft and files; other drafts remain.
The server's permanent-delete receipt must identify the removed descriptor
version exactly. The older JS in-memory catalog returned the following version;
public JS 15a includes the correction and the normally installed gateway test
qualifies it. Do not accept either value as interchangeable.


## Shared voice history and navigation policy

Supply `readVoiceWorkspace` to `HandrailAssistantController` when a host has an
authorized voice-activity reader. The SDK constructs and disposes its account
monitor, observes known catalog conversations (including unselected/archived
rows), and removes permanently deleted IDs. It does not restart reads for every
text delta. `voicePollingInterval` defaults to three seconds; null disables its
timer for explicitly driven observation. Explicit `refreshObservations()` and
history retry also refresh voice. Hosts may call `assistant.voiceWorkspace` to
refresh after a protected call/read operation; do not maintain another monitor.

The standard history displays active calls, unconfirmed endings, unread results
and unresolved voice actions separately from text work. Unread filtering includes
voice results, but opening a transcript or marking text read never acknowledges
voice. A failed refresh retains last known evidence and shows bounded recovery;
voice state does not change text Send/Stop permissions or prove business effects
settled. The server still authorizes lifecycle changes and blocks unsafe deletion.

The monitor accepts at most 10,000 distinct conversation IDs, each at most 512
characters. Invalid or larger scopes retain all previously known call/effect
evidence, mark it stale, fence in-flight replies and suspend reads. A direct
`setConversations` caller still receives `ArgumentError`; the account controller
handles that error and publishes `voiceErrorCode` for the standard UI. The UI
selects bounded messages for `scopeLimit` and `invalidScope`, rather than showing
raw errors or claiming a temporary reconnect. Supplying a valid scope resumes
observation, including when it equals the last valid list. The SDK never silently
truncates the observed list or treats an old subset as synchronized full history.
The current source is qualified with a 10,001-row paged catalog, late replies,
polling, recovery and narrow-layout retained activity markers.

`allowMessageLinks: false` is an explicit host navigation policy on the workspace,
transcript or reusable message. It disables raw message links while preserving
validated citation controls. If `citationLink` is supplied, returning null makes
the citation inert; the SDK must not fall back to its raw locator. Mills supplies
this policy and resolves only exact protected source identities to `/home` and
`/finance/connections`. Non-assistant message text remains literal. Standard
Markdown, Copy, activity and citation presentation stay SDK-owned.

These APIs are in the public Flutter baseline above. Source-alias tests remain
separate from normal public adoption and live voice/provider qualification.


## Protected image viewers

`HandrailAttachmentPreview(enableImageZoom: true, ...)` supplies a scoped
fullscreen image viewer with zoom, close controls and accessible labels. Supply
account/conversation identity in `scope`, declared byte limits, and a protected
`loadBytesWithCancellation` adapter. This built-in viewer is an alternative to
host `onOpen`/`onOpenBytes` callbacks; the constructor rejects combining them.
It makes a fresh authorized read for activation instead of opening cached bytes.

The SDK owns the viewer route and closes only that route on scope replacement,
disposal or backgrounding. It clears its encoded image copies and evicts their
decoded cache entries; late reads cannot reopen the previous account. Background
cleanup does not wait for another frame, and resuming reauthorizes image previews.
Normal saved-file download controls also return after resume without starting a
download automatically. Host loader buffers remain host-owned.

Mills uses this component with its existing conversation-bound protected reader,
which still checks status, MIME/signature, exact byte size, no-store and nosniff.
Its adapter forwards cancellation and current-account authentication failures.
The old host thumbnail/modal lifecycle is removed. PDF references remain Mills
metadata cards because the protected image route does not authorize PDF bytes.
These changes require future public SDK publication/adoption; local alias tests
are not provider, native-app-switcher, operating-system screenshot, or live
storage qualification.


## Live catalog permissions

`HandrailAssistantController(allowConversationManagement: callback, ...)` accepts
an additional live host permission check for creation, initial title assignment,
archive/restore and permanent deletion. Omitting it adds no client restriction;
it never grants permission denied by the authenticated gateway. Mills connects
its existing current-account admin/member `canMutate` check. Approval decisions,
text submission and protected files retain their separate policy/authorization
boundaries.

Read-only catalog access still loads/selects history and does not auto-create an
empty conversation. Standard history disables New and saved deletion retry and
hides unavailable lifecycle actions. Confirmation rechecks current action
availability. The controller also rechecks permission around target reads and
durable deletion-journal writes, so presentation alone is not the guard.

A permission change never discards saved deletion intent. Startup keeps that
identity pending while opening unaffected conversations; replay waits until host
permission permits it and uses the original ID, version and key. Canonical
responses already received still finish their local receipt cleanup. Operation
tracking is established before asynchronous work begins, including early
permission failures, so failed work cannot remain stuck as an active operation.

These hooks are in the public Flutter baseline. Mills' obsolete screen/router
attachment repository and signed-uploader injection parameters are removed from
main: the account-owned protected provider supplies uploads to SDK drafts.

## Host theme and message identity

The standard composer inherits the host's `ColorScheme.surface`, `onSurface`,
`outlineVariant`, `primary` and `onPrimary`, plus its text font. It no longer
requires a custom composer to avoid a white surface or fixed green Send button.
Explicit `decoration`, `inputTextStyle` and `sendButtonStyle` overrides still
win. Theme changes do not remove Send/Stop, approvals or attachment controls.
The standard editor excludes host `InputDecorationTheme` width/height constraints
and disabled borders: the SDK owns its single-line minimum, multiline growth and
surrounding composer border. This prevents ordinary form sizing from reserving
empty space or clipping draft text; host fonts, hint colors and branding remain.
The layout fix is included in public Flutter 50fe and now passes Cents’s installed visual gate.

The standard transcript renders user and assistant messages, leaving internal
system/tool payloads out of normal chat. Hosts using `HandrailTranscriptMessage`
for an explicitly authorized domain projection get literal non-assistant text,
accurate semantic role labels and visible system/tool labels, even with normal
chat author labels hidden. `systemLabel` and `toolLabel` can be localized;
assistant branding and its avatar apply only to assistant messages.

Mills' main checkout uses its real app theme with the standard workspace.
Source tests cover narrow Markdown tables, exact Copy and bounded clipboard
failure, native Photos/Camera/Files, late picker/account isolation, keyboard
insets and editable/send behavior. The generic read-adapter property, synthetic
chat/proposal fixtures and quick-prompt models are removed; fixture household,
calendar and finance data remain separate. See Mills mobile’s
`docs/shared-assistant-source-candidate.md` for current installed receipts and
historical source evidence. Live/native qualification remains separate.

## Mills generic wrapper retirement

Mills' main checkout now calls the shared controller/workspace directly for catalog,
creation, deletion, send/retry/Stop and draft admission. The duplicate generic
repository wrappers, JSON-chat reply models and old generic UI test runtime are
removed. Its remaining repository handles protected files/transcription,
voice/caption readers, financial review and a bounded domain projection.

A domain review read must not call the SDK's selection/recovery action or mark
text read. Mills `readConversationProjection` refreshes its protected session
without those side effects. Explicit visible chat selection and read acknowledgement
stay in the SDK workspace. The host's SDK-deletion subscription also clears cached
Mills review arguments; cleanup is not hidden in a host-only delete wrapper.

The complete retained native/route suite and actual workspace suites now pass,
with full analysis and a source release web build. The SDK gateway regression
also covers a local journal write that persists but loses acknowledgement:
no admission occurs, a different draft cannot replace it, and controller restart
recovers the same saved turn once. Its deterministic provider/local JS source
fixture is not live execution or a public installation receipt. These source
changes still need a published SDK SHA, matching consumer locks and runtime
qualification before adoption can be called complete.
