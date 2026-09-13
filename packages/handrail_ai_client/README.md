# handrail_ai_client

Flutter/Dart headless client for the application-hosted Handrail AI wire protocol. It negotiates PDF/document, attachment, cancellation, presence, activity, synchronization, and resource capabilities; creates/lists/loads/renames/archives/restores threads; starts, resumes, and cancels SSE turns; uploads attachments; reviews approvals; generates titles; reads/marks and live-streams typed cross-device launcher activity; and publishes/subscribes to typing presence. `HandrailConversationState.apply` provides immutable typed state for text, tools, approvals, citations, attachments, and turn status.

The package has no Flutter widget dependency. Use the optional sibling `handrail_ai_widgets` package for shared presentation, or build custom Material/Cupertino views from the same state. Authentication remains application-owned through `protectedHeaders`; provider credentials, server executors, actor/company context, and attachment bytes never enter durable client state.

The TypeScript SDK supplies React presentation, while the sibling widgets package supplies Flutter presentation. Browser `Blob` upload becomes `List<int>` multipart upload. Gateway protocol, resume checkpoints, terminal outcomes, approvals, activity, presence, and concurrent-workspace semantics remain aligned.

## Account-owned assistant and history

`HandrailAssistantController(client: client, pendingStore: accountStore)` owns
catalog paging, active/archived views, selection, conversation sessions, pending
send recovery, versioned archive/restore and stable cancellation identities.
Retain it across closing a sheet; dispose it on logout/account changes. Host
code supplies authenticated transport, encrypted storage, business request
construction and feature settings. `clientId`, `newConversationTitle`,
`autoCreate`, `pageSize` and `pollingInterval` configure the common behavior.

The controller owns one account observation loop. Each cycle coalesces the
global activity read, then refreshes selected, running or pending open sessions.
An idle unselected transcript does not run its own timer or repeatedly fetch
account activity. Remote running activity brings an already-open session back
into observation. `refreshObservations()` performs the same cycle manually;
`pollingInterval: null` disables its timer. Activity failures retain prior unread
evidence in `activityError` without changing send authorization or hiding a valid
catalog. Account disposal stops the loop and ignores late replies.

The optional `HandrailConversationHistory(binding: assistant.historyBinding)`
consumes its standard history presentation directly. Hosts do not need a catalog
loop or history action callbacks. `setHistoryView`, `setUnreadOnly`,
`refreshHistory(more: true)`, `openConversation` and `clearSelection` also support
custom branding. Clearing a selection preserves sessions and background work.
Unread filtering/counts cover loaded catalog pages, including unopened chats
with authenticated remote activity; loading older pages expands that set.

`HandrailConversationTranscript(binding: assistant.transcriptBinding)` consumes
canonical messages, activity, pending/error state and recovery directly. The
binding exposes loaded empty catalogs as empty views, not ongoing loading.
The optional UI acknowledges a terminal reply only when the actual transcript
end is visible on the current foreground route; repository loading must not
mark it read. The controller's `markRead` also checks that remote activity
belongs to the observed terminal turn. Standard message/citation/Copy and domain
formatting adapters are documented in the widgets package.

`newConversation(metadata: ..., onReady: ...)` retains the original creation
request until shared hydration and optional business presentation succeed.
Retry reuses it even when the response or presentation fails. `ensureSession`
reuses an initialized session; `openConversation` explicitly refreshes canonical
metadata/state and recovers only the account's retained submission. Bind
`beforePendingRecovery` to the composer workspace's
`capturePendingAcceptance(id)` to clear its original draft when a lost send is
acknowledged on reopening. Newer edits and other conversations remain intact.

Configure `newConversationMetadata: () => {'route': currentRoute}` on the account
controller when New should capture host context. It runs only when creating a
new request, and the resulting JSON is frozen with that request's identity.
Retries do not resample later route changes. Explicit `newConversation(metadata:
...)` takes precedence, including an empty map. `workingAnywhere` reports pending
submissions, catalog/selection mutations and local or remote running work across
the account, including conversations that are not selected. It is a presentation
signal for optional close policies, not an authorization grant.

Use `assistant.sendMessage(request, onAccepted: ...)` and
`assistant.retryPendingMessage(...)` with shared draft capture. `canSend` gates
readiness separately from draft editability. `requestCancellation` retains its
identity for uncertain retries; canonical server state determines completion.
`session.waitForTurn(id)` observes completed/failed/cancelled outcomes without
changing selection or starting work. Disposing the account releases waiters and
observers; it does not cancel server execution or close a host-owned HTTP client.

Use `submitting` alongside `running` for the composer Send/Stop state, and
`canStop` for control eligibility. Stop before admission queues against the
originating account/conversation; once its message is admitted, the SDK requests
authoritative cancellation before allowing provider dispatch. A failed queued
cancellation keeps the saved send recoverable and retries the same cancellation
identity before a start. Changing selection cannot redirect that Stop. The
`stopping` flag includes waiting for admission and is not terminal confirmation;
render the canonical turn outcome. File uploads use the shared draft queue's
`cancelUploads`, preserving unsent text/files.

See [minimal mobile adoption](../../docs/mobile-assistant-adoption.md).

Version 0.1.1 separates `observationConnected` from server turn status. A
`disconnected` terminal or an SSE response ending without a terminal frame does
not mean the run failed; truncated streams retain the last checkpoint for resume.
Network exceptions still propagate to the host, which should reconnect and query
server activity before deciding that work stopped. Identified/numbered replay
frames are deduplicated, and frames from superseded turns cannot revive old work.

Workspace snapshots merge authoritative activity for open conversations as well
as unopened ones. Activity `turnId`/`turnRevision` prevent earlier turns from
replacing newer work, and known canonical completion cannot be revived by stale
same-turn running activity. Entries expose the shared activity summary/progress.
After a successful server `markActivityRead`, call `markRemoteRead`; merely
selecting an open chat is not a substitute for persisting the read acknowledgement.
A stale same-version unread response cannot undo that acknowledgement.

This package is still headless. Applications must connect protected HTTP and presentation.
`HandrailConversationSession` supplies canonical loading, synchronization, and
observation recovery for an existing conversation. The optional sibling
`handrail_ai_widgets` package supplies standard presentation components; hosts
own authentication, application navigation and authorization.


`HandrailConversationSession.initialize()` negotiates capabilities, loads a
canonical snapshot, and resumes an active turn. Periodic refreshes are serialized;
`read_since` checks avoid rebuilding an unchanged snapshot, while changed or
compacted history is reloaded through the server reducer. Transient initial
failures keep polling. Reconnection never calls `startTurn` or appends a new user
message. Render `document.messages` and the projected workspace state; replayed
SSE text is used for observation/checkpoints and is not appended a second time.

The session retains the last known run when synchronization fails. Its `error`
is distinct from server run status. `requestCancellation` sends server cancellation
with the host's stable mutation/idempotency IDs and waits for subsequent canonical
state before displaying completion. `dispose` cancels this observation and timer,
not the server run or the shared HTTP client. Stream cancellation also aborts
pending HTTP headers. Standard HTTP abortion support requires http >=1.6.0 and
Dart >=3.4; custom HTTP clients should honor `AbortableRequest.abortTrigger`.

For a new turn, call `session.prepareTurn(operationId: uniqueId, clientId: clientId,
request: chatWireRequest)` once. It refreshes the conversation and refuses another
message while a turn is active. `chatWireRequest` follows `handrail.ai-runtime.v1`:
the final message is the new user input; staged image/document references belong
in that message. The application gateway still validates the request and domain
authorization. `prepareTurn` does not write to the server.

Persist the returned `HandrailTurnSubmission.toJson()` in account-scoped storage
before calling `session.submitTurn(submission)`. On an uncertain send response or
app restart, restore it with `HandrailTurnSubmission.fromJson` and submit that same
value. Do not generate a new operation ID for a retry. The SDK atomically appends
the user message, attachment references, and turn admission, then starts execution
with stable IDs. `submitTurn` completes when the server acknowledges the start;
it does not wait for the run to finish. Render canonical run state while work
continues. A completed/cancelled/failed canonical turn is never restarted by this
retry path. Clear a saved submission after successful acknowledgement; subsequent
recovery uses the server-owned turn without a pending start request. Preserve it
after a lost response. On `admission_conflict`, show the refreshed conversation
for review before preparing another submission.

Gateway qualification uses an actual Node HTTP server running the separately
installed JavaScript SDK with in-memory persistence and a deterministic provider.
From this repository root, run `make setup`, then `make check`. To run only the
cross-language test after setup, run
`dart test test/submission_gateway_test.dart --concurrency=1` from this package.
Tests cover lost admission/start replies, session recreation, duplicate sends,
terminal retries, attachment admission, two concurrent threads, unread/read
persistence, and rejection of changed content under a reused mutation identity.
These tests do not establish native application or live provider qualification.


`HandrailProtectedHttpClient` wraps a host-authorized HTTP connection. Pass the
fixed gateway `baseUri`, an `authorize(uri)` callback for host-owned cookies/tokens,
and optionally `receive(uri, statusCode, headers)` to capture session rotation or
handle authentication failure. It rejects requests outside that gateway before
asking for credentials, disables redirects, and preserves abortable streaming
requests. Its default browser client enables browser-managed cookies. The host
must reject old sessions and ignore late responses after logout/account changes;
Client factories can bind a session generation for this purpose.
No cookies or CSRF values enter conversation documents, pending submissions,
activity records or diagnostic events.


`session.sendMessage(..., pendingStore: store)` now performs prepare, durable
retain, submit and acknowledgement cleanup together. `retryPendingMessage(store)`
restores that exact submission. A storage failure stops admission before any
server write; an uncertain admission/start response retains the saved intent.

Use `HandrailPendingTurnStore` for a host's atomic encrypted database, or
`HandrailKeyValuePendingTurnStore` for native encrypted key-value callbacks. Its
namespace must include API realm and authenticated account (and household/company
when applicable). The key-value adapter serializes operations across adapter
instances in the same Dart isolate, refuses to overwrite a different pending
submission and compares the full submission before deleting it. Hosts sharing
storage across processes/isolates must supply database atomicity through the
interface instead. It is an adapter, not unencrypted filesystem persistence.

### Retained realtime voice calls

`HandrailRealtimeCallMonitor` is a headless, conversation-scoped observer for
server-owned voice call records. Supply authenticated `readPage(afterCallId)`
and `requestEnd(callId)` callbacks, subscribe to `changes`, then call
`startPolling()`. Dispose it when leaving that conversation/account. It never
contains provider credentials, SDP or a private provider call reference.

Use `state.unfinished` for recovery controls and `state.canStartCall` for the
presentation gate before starting a new voice session. A failed/incomplete read
retains prior evidence and cannot authorize a start. Ending/ended evidence wins
over older replies. A server acknowledgement of `ending` keeps recovery pending;
only `ended` confirms termination. The host must still authorize/admit starts on
the server; this UI gate is not an authorization boundary or a global mutex.

Polling joins in-flight reads; paging and retained records are bounded. Disposing
stops polling and discards late replies. Hosts should impose transport timeouts
and use account-scoped authenticated adapters. This observer does not re-create a
provider call, resume WebRTC, or infer termination from a missing record.


`HandrailRealtimeActivityMonitor` observes one protected voice call's saved tool
counts. Hosts supply `readPage(details, afterToolCallId)` and dispose the monitor
on account/call changes. Details are off by default; `setDetails(true)` enables
bounded pages and `loadMore()` expands the retained page window. Polling is
serialized. Failed, foreign and regressed reads preserve saved evidence and
surface a safe error. `hasUnresolvedTools` distinguishes missing outcomes from
work on a call still confirmed active. These display records do not authorize
execution and contain no tool arguments or business results.

For endpoints that support completion receipts, activity pages include `unread`
and a scope-bound `readToken`. Supply `acknowledgeRead(token)` and call
`monitor.markRead(displayedToken)` only after that snapshot is visibly rendered.
The monitor queues distinct acknowledgements, joins matching ones, and refreshes
server state after success; it never optimistically clears newer outcomes.
Failures retain unread state and expose `readError`. Hosts should retry on a later
visible refresh, not immediately in response to the error. Hidden/background
views must not acknowledge. Older endpoints without receipt fields still support
counts/details but cannot supply durable read acknowledgements.

`HandrailRealtimeWorkspaceMonitor` observes voice status/counts/unread across
independent conversations without changing text run or text read state. Supply
`readPage(conversationIds, after)`, call `setConversations()` with the current
authorized catalog, and start polling. It queries at most 100 conversation IDs
per request, joins refreshes, bounds total pages (100 by default), rejects foreign,
duplicate, missing or regressed saved records, and ignores late results after
scope changes/disposal. A failed or truncated refresh preserves the previous
whole snapshot and exposes a safe error. `state.forConversation(id)` separates
active calls, calls awaiting end confirmation, unread calls and unresolved tool
outcomes. Reading or selecting a conversation never acknowledges voice results.
Hosts should label cached active state as last reported when an error is present,
show the checking/error state before inferring absence, enforce authenticated
transport timeouts, and dispose/recreate the monitor on account changes.


### Submission admission notification

`sendMessage`, `retryPendingMessage` and `submitTurn` accept an optional
`onAccepted(HandrailTurnSubmission)` callback. It runs after all durable
admission acknowledgements and the canonical turn have been verified, before
starting/observing the provider response. Coalesced callers for the exact same
submission are notified too. A callback exception cannot strand admitted work.
Storage/admission failures do not clear an unsent draft, and a lost start reply
can occur after acceptance: recover the same pending submission instead of
constructing another message. Pair this notification with the Flutter widgets'
`HandrailDraftController` or `HandrailComposerDrafts`, never with a completion-time
text comparison. This callback preserves durable admission and retry semantics.


### Protected transcription

`HandrailGatewayCapabilities.transcription` describes available formats, bytes,
duration and an optional endpoint. `HandrailConversationSession.capabilities`
exposes the negotiated value after initialization. `transcribeAudio` validates
that contract, sends raw audio through the protected client, bounds the response,
and maps safe errors without provider text. The URI remains under the configured
gateway; authenticated redirects are disabled. Pass a cancellation future to stop
observation. A late response cannot be inserted after cancellation; cancellation
alone does not prove the provider never ran.

`transcribeAudioResult` returns a structural `(text, errorCode, retryable)` record.
`transcriptionForConversation(id, capability: capability)` supplies the function
expected by the optional Flutter composer. This keeps the two SDK packages
independent while removing per-host HTTP/error adapters. A retained retry must
reuse its exact recording and key; `outcome_unknown` is never retryable.

### Protected saved attachments

`HandrailGatewayCapabilities.attachmentDownloads` negotiates a bounded protected
reader independently of new uploads. `uiBinding.downloaderFor(id)` supplies the
optional workspace's default saved-file controls. Lower-level integrations can
use `attachmentDownloader(conversationId: id, capability: capability)` or
`downloadAttachment`. The reader authenticates every request, confines endpoints
to the configured gateway, refuses redirects, checks MIME and expected size,
bounds streaming reads and returns safe errors without server bodies. Its
cancellation future covers authentication, request and body reads, including
late responses. The standard timeout is 30 seconds. Retention remains a server
policy; an expired or consumed file is not silently restaged.

Uploads through the standard gateway need the originating conversation. Use
`attachmentUploader(conversationId: id)` for custom queue bindings, or the
default `uiBinding.uploaderFor(id)`, which captures that identity before a user
switches conversations. Legacy endpoints can still omit the optional argument.

The cross-repository attachment test requires an explicit local candidate build:
`HANDRAIL_TEST_JS_SDK_DIST=/absolute/path/to/handrail-sdk-ai-assistant-js/dist make check`.
It exercises real multipart upload, admission, protected download, account and
conversation isolation, and expiry against a synthetic standard JS gateway.
Without the variable this one candidate test is skipped; the existing locked
gateway fixture is unchanged. This is test-only resolution, not a dependency
installation or a substitute for a reviewed public SDK SHA and matching locks.
