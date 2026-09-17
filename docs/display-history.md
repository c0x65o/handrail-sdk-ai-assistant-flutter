# Paged display history client (local work)

The Dart client now recognizes the negotiated `displayHistory` v1 gateway
capability and exposes `displayHistoryPage`, `displayHistoryChanges`, and `displayHistoryContent` on
`HandrailAiClient`. These are display APIs, distinct from canonical snapshots.
When `displayHistory.control` is also advertised, `HandrailConversationSession`
and `HandrailAssistantController` use scalar controls, a bounded message window,
and a separate bounded window of related activity. They do not pull canonical
snapshots or replay the saved SSE log to open/refresh a chat. Legacy servers
retain the existing synchronization path.

`HandrailDisplayWindow` now provides the bounded presentation controller:
`select`, `loadOlder`, `loadNewer`, `jumpToLatest`, `refresh`, `retry`, `changes`
and `dispose`. Defaults are 30 messages / 64 KiB per page and 90 retained messages
/ 256 KiB serialized content. Those bytes exclude Dart object overhead. Own it
with an authenticated client, dispose it on logout, and use a new instance for
the next account. Display cancellation does not stop provider execution.

`HandrailDisplayAnchor(messageId: ..., generation: ..., newer: true,
inclusive: true)` restores a saved message with one indexed request. Older/newer
navigation evicts records from the opposite edge and can reload them by anchor;
it does not accumulate the entire transcript. Only one changes page is read per
refresh and the watermark advances after the last page. Transient errors retain
the window; clear/access revocation evicts it. UI state can persist anchors and
drafts separately. The standard session follows new messages unless the display
window is reading older history. `setFollowingLatest(false)` also lets a custom
surface pause following without fetching an older page.

Validation: client analysis with fatal infos; 13 display-client/window tests,
including transport cancellation, late responses, row/byte bounds, directional
navigation, anchor restoration, changes-watermark semantics and access revocation.

## Flutter display surface

`HandrailDisplayHistoryCapability.control` separately negotiates small execution
controls. `client.displayHistoryControl(conversationId: ..., capability: ...,
turnId: ...)` returns `HandrailDisplayControl`, with active/latest/requested turn
summaries and the display/canonical revision. It does not transfer complete turn
records, retries, message IDs or model context. The requested turn is optional;
its identity is checked when provided. Missing, future or contradictory summaries
are rejected. The protected request supports cancellation and a 30-second default
deadline and limits response bytes before decoding. `preparing` controls cannot
be used to infer an idle conversation. Old gateways do not opt in. These controls
are used for send admission verification, requested-turn completion waits,
cancellation, and background observation in the standard session.

`session.document` is now a `HandrailConversationView`. Its `isPartial` flag is
true for `HandrailConversationDisplayView` and false for legacy canonical
`HandrailConversationDocument`. A display view is presentation data, not a
checkpoint or provider input. It contains loaded messages, scalar latest/active
turns, related tools/approvals/citations and explicit deferred-record metadata.
An empty display revision is zero on the wire but maps to canonical `null` for
the first admission; display paging never supplies model context.

The standard `HandrailConversationTranscript(binding: controller.transcriptBinding)`
uses the bounded widget with existing branding, Markdown, copy, citation routing,
attachment builders, business tool results and status/error controls. The account
session owns polling and selection, so mounting the widget does not repeat the
initial request. Legacy aggregate `contentBuilder` formatting still requires
pagination integration; the default renderer uses the new path.

Switching chats cancels obsolete display reads and releases the hidden window.
Running turns keep scalar observation and execution; they are not stopped.
Idle sessions use a four-entry cache (`maximumCachedSessions`, range 1–32).
Active/pending operations can temporarily exceed that count, with no hidden
transcript pages. Disposal clears display/control references and closes waits.

`HandrailKeyValuePendingTurnStore` also implements
`HandrailConversationPositionStore`. The standard controller/widget automatically
use it to persist message/generation/pixel anchors in a 32-chat journal under the
existing encrypted API/account namespace. Writes are serialized across adapter
instances and debounced by the widget. Custom stores can implement that interface
or pass a widget `HandrailDisplayPositionStore`. Storage errors do not hide the
conversation or share positions with another account.

## Durable composer drafts

`HandrailKeyValuePendingTurnStore` additionally implements
`HandrailConversationDraftStore`. `HandrailAssistantController.uiBinding` exposes
its account-owned callbacks, and `HandrailComposerController.forAssistant`
automatically uses them. A custom encrypted store may implement the interface or
be supplied as `draftStore`. The widget and client packages remain independent;
the binding carries typed read/write callbacks. No app route is needed.

The journal retains at most 32 nonempty text drafts, 64 KiB UTF-8 each and 512 KiB
total per account/API namespace. A full journal rejects a write without evicting
another draft. Revision comparisons serialize separate adapters in one Dart
isolate; multi-isolate/process hosts must supply a transactional store. The
existing pending-send and position journals keep their own identities and bounds.

Restoration never replaces newer typing. Admission clears only the submitted
edit, even when the user switches chats or types identical text again. Writes
coalesce with a 250 ms debounce; the workspace flushes on backgrounding, scope
changes and view closure. Save failures remain visible with retry and explicit
saved-draft replacement. Saved idle editors are evicted above eight cached
drafts; uploads, ambiguous sends and failed saves retain recoverable local work.
Dispose the composer on account change and `await drafts.closed` before closing
its encrypted storage. Ordinary disposal preserves saved drafts; `discard(id)`
clears that chat's saved text, including confirmed-deletion handling. A reopening
editor waits for the old clear to finish. No asynchronous store can guarantee a
last keystroke survives abrupt process termination before its write completes.

Draft persistence covers text. File bytes/previews remain in memory; uploaded
references for an admitted or uncertain send use the separate pending journal.
Reload recovery for an unsent file selection remains an explicit follow-up.

`HandrailDisplayTranscript` accepts `window.uiBinding`, with no package dependency
between the client and widget libraries. The same authenticated window must be
retained across selections and disposed when its account is discarded.

```dart
final window = HandrailDisplayWindow(
  client: client,
  capability: capabilities.displayHistory!,
);
// Retain window in the account owner; do not construct it in build().
HandrailDisplayTranscript(
  binding: window.uiBinding,
  conversationId: selectedConversationId,
  positionStore: accountPositionStore, // optional durable, account-scoped storage
);
```

The widget loads one selected page, uses upward/downward scrolling or accessible
buttons to request adjacent pages, and preserves a message ID plus pixel offset
when rows are prepended or their heights change. It mounts message bodies within
the viewport and one viewport of overscan on each side, retaining measured-height
placeholders for other rows. Unmeasured rows start at 240 logical pixels; layout
measurements and message anchors correct the estimate. Width changes invalidate
heights, and row eviction/account changes discard measurements. Each rendered
message remains complete; text is not sliced for virtualization.
The default renderer reuses SDK Markdown/copy/message styling; protected
attachments use `attachmentBuilder`. Domain formatting can use `messageBuilder`.
`deferredBuilder` can override oversized records. With separately negotiated
`messageText` support, the default offers the bounded text reader described below;
older servers retain an explicit notice and no automatic full-content download.

Foreground polling, loading/preparing/empty/error/retry states, jump-to-latest,
selection cancellation, and scope changes belong to the widget. The optional
`HandrailDisplayPositionStore` persists message anchors; the default memory cache
retains at most 32 chats. A failed preference read does not block messages.
`onVisibleLatest` reports an observed revision so the account controller can
acknowledge exactly what was displayed. It must not acknowledge unseen pages.

Widget tests cover one-page selection, retained-row bounds, prepend and delayed
layout anchoring, account changes during pending requests, explicit oversized
content, retries, persisted anchors, narrow layout and doubled text size. These
are Flutter widget tests, not device frame-time or memory benchmarks. Related-state discovery and oversized metadata still need the complete end-to-end
audit. Explicit activity pages now merge into a separate 90-record / 256 KiB
window. The changes feed updates retained records, and eviction exposes Show
latest activity instead of silently replacing each page. Permission errors clear
all presentation and publish a nonretryable error.

```dart
final capabilities = await client.capabilities();
final history = capabilities.displayHistory;
if (history != null) {
  final page = await client.displayHistoryPage(
    conversationId: conversationId,
    capability: history,
    cancellation: selectionCancelled,
  );
  // Render page.records oldest-first. Only request page.nextCursor on demand.
}
```

The default page request is at most 30 records within 64 KiB. Related progress
uses `view: {'type': 'turn', 'turnId': turnId}`. Message citations use
`view: {'type': 'citations', 'messageId': messageId}`. Both page separately.
`view: {'type': 'context', 'messageIds': [...], 'turnId': activeOrLatestTurnId}`
returns related turn/tool/approval/budget/citation records and citation sources
for a retained window. It accepts at most 100 message references, within the
gateway's request-byte limit. The session groups its at-most-90 retained
message IDs into <=2 KiB context views. Only the first group loads initially; later
groups/pages load on demand within the same activity budget. A stale page cannot
replace a newer window's activity. Completed polling reads release their
cancellation handles instead of attaching listeners for the account lifetime.
`preparing` means that the server is backfilling its saved display index; it must
not be rendered as an empty conversation. A clear changes `generation` and
invalidates old pages/cursors. Record identity plus revision supports merging
later updates without duplicating messages.

Live refreshes use `displayHistoryChanges` with the page's generation and the
last fully acknowledged revision. It returns a `HandrailDisplayChanges` holding
the bounded response in `page` and an insertion fence in `throughRevision`.
Only advance to that fence after all change pages are received (`nextCursor`
is null) and the response is ready. Removed records have `deleted == true`;
remove them from the cache instead of attempting to load their content. A
record updated during a multi-page catch-up is delivered by the next poll.

`deferred: true, value: null` identifies oversized content. The UI must offer an
explicit expansion/download instead of silently omitting it or automatically
loading all content. `displayHistoryContent` returns a JSON-text chunk with a
server-supplied `nextOffset`, measured in Unicode code points. Preserve the
returned record revision between chunks. `content_changed` requires restarting
the content read; chunks from different versions must never be concatenated.

When `HandrailDisplayHistoryCapability.messageText` is true, pass
`messageText: true` to `displayHistoryContent` for a message's readable text.
Its `encoding` is `plain-text`, not serialized record JSON. The default display
binding exposes this operation to `HandrailLargeMessage`: one expanded reader,
one section of at most 8,192 Unicode code points, previous/next/close controls,
retry and changed-version reload. Nonterminal sections contain exactly 8,192
code points. Selection, account teardown and newer requests cancel old reads;
late results cannot refill the current view. No large text is fetched until the
user opens it, and loaded text stays outside the transcript cache.

The text-only reader deliberately does not parse partial Markdown or assemble
attachment bytes. Normal messages keep existing formatting. Oversized attachment/
citation metadata and tool/approval expansion still need their own bounded
presentation. Database text extraction can scale with the one explicitly opened
record; list and initial-history reads do not perform that work.

Current targeted validation includes 24 transcript/widget tests, 15 Dart
history/window tests and the real local-SDK HTTP reader test. The latter verifies
Unicode section boundaries, no snapshot read, bounded response bytes and rejected
content after permanent deletion. The remaining HTTP submission scenarios passed
in the same run; the final deletion case passed after correcting its unsupported
Clear fixture assumption. These checks do not constitute a device memory profile.

Requests use the client's protected HTTP connection, disable redirects, accept a
cancellation future and impose a deadline (30 seconds by default). Responses
are byte-limited before JSON parsing. Page identity, revisions, duplicate records
and chunk offsets are validated. A cancelled display request does not cancel a
server-owned assistant turn. Discard cached pages when the account changes.

This local client is paired with the local JS SDK's new
`POST <mount>/conversations/history` route. Existing public Git dependencies and
lockfiles are unchanged. Source qualification is separate from a later approved
published-SHA upgrade. Tests cover protected requests, capability negotiation,
explicit paging, conflicts, account/conversation identity, Unicode offsets,
cancelled authentication and response byte limits. Device rendering/memory
measurements, complete feature coverage and consumer adoption remain outstanding.

The existing HTTP fixture defaults to its locked published Git SDK. To qualify
the unpublished JS source without changing dependencies, build that SDK and run:

```sh
HANDRAIL_TEST_JS_SDK_DIST=/absolute/path/to/handrail-sdk-ai-assistant-js/dist \
  dart test test/submission_gateway_test.dart --concurrency=1
```

This explicit mode uses the JS checkout's existing PGlite development dependency
and real SDK PostgreSQL stores. It is source qualification, not an application
dependency installation or adoption. The fixture also checks indexed message
pagination, actual HTTP response bytes and preservation of canonical history.

Latest local validation: 181 client tests pass with the locked published fixture
(the local-SDK-only history test is skipped), all 173 widget tests pass, and all
17 HTTP integration tests pass with the local SDK and PostgreSQL stores. Dart and
Flutter analysis with fatal infos pass. The long-history HTTP case checks 30
initial messages, a 90-message retained bound, at most 66,560 response bytes,
zero display snapshot reads, and all 201 canonical messages preserved.

Related activity qualification: 24 Dart history/window/session checks and 24
Flutter transcript cases pass, including multi-page retention, live removal,
count/byte eviction, restart UI, permission revocation and long Unicode IDs. All
18 local-SDK HTTP submission scenarios pass. These checks are sequential and
scoped; they do not establish production concurrency or device-memory budgets.

## Consumer projection compatibility

`state['display_history']['version']` is a session-local presentation version. It
changes when loaded messages or related activity change, even if canonical
`document.revision` stays the same. Unchanged polls preserve it. Domain formatters
should observe both values; neither display version nor loaded rows may be used
as a canonical admission revision or checkpoint. Mills and Spartan mobile now
observe this distinction. Spartan's partial formatter uses loaded approvals
instead of making an extra full-group request.

The `tool/check-consumer-contract.mjs` script qualifies real mobile entrypoints
with a temporary compiler package map; `--test` runs scoped consumer Flutter tests
against local SDK source with `--no-pub` and one worker. Existing pubspecs, pins and
locks remain unchanged. Recorded source results are in
[consumer-contract-qualification.json](consumer-contract-qualification.json).
These compiles and tests are not published-dependency adoption or device builds.

### Citation page boundaries and concurrent removals

Partial presentation exposes a citation only while its source is retained and
inline. `state['display_history']['unresolvedCitationCount']` counts loaded
citations with missing/deferred sources. The transcript shows a notice; the
existing activity paging action can bring the source into the window. Source
removal or eviction withdraws its citation, without changing canonical history or
hydrating every page. Deferred source expansion is still separate work.

A held activity page is ignored if the message changes-feed watermark advances
before it returns, even if no message text or turn control changed. A response
already behind that watermark is retryable instead of merging stale records.
Regression tests cover late-page removal and citations split across pages.
The source-qualified Hitcents mobile SDK/sheet suite also passes all 29 cases;
its assertions distinguish persisted text drafts from pending submission intents.

### Offscreen Flutter render and memory benchmark

Run `tool/display_render_benchmark_test.dart` through the existing source
qualification helper, using a consumer with both SDK packages already installed:

```sh
HANDRAIL_TEST_VM_SERVICE=1 HANDRAIL_FLUTTER_DISPLAY_REPORT=/tmp/flutter-display.json \
  node tool/check-consumer-contract.mjs /path/to/flutter /path/to/consumer --test \
  /absolute/path/to/sdk/tool/display_render_benchmark_test.dart
```

This uses a temporary compiler map, not a dependency upgrade. It exercises the
actual account controller, HTTP protocol parser, session/window and standard
transcript. The HTTP transport is mocked; no production or preview route is used.
The optional VM service flag is restricted to local testing. The benchmark samples
only its own loopback isolate, requests garbage collection, closes its local HTTP
client, and never outputs the VM service address or token.

The earlier all-row widget implementation failed the warm RSS budget: an
exploratory run grew from 335.5 to 728.5 MB RSS and 147.9 to 458.5 MB isolate heap.
Its allocation profile showed substantial list and semantics retention; the
redacted diagnostic is `display-render-before.json`. After viewport body
virtualization, the final benchmark explicitly retains ninety messages while
mounting eight message widgets, with four cached sessions. For 200/1,000 message
sources, warm heap grows from 105.7/109.4 to 179.7/175.4 MB; warm RSS growth is
106.1/99.4 MB. These totals include the debug Dart VM, Flutter engine, framework
and test harness, not just SDK data. Cold-start RSS is also recorded separately.

Twelve selections yield offscreen selection-plus-pump p95 222.3/115.8 ms, with
maximum serialized mock response sizes 13,067/13,104 bytes. The first run includes
additional JIT warming. The repeatable regression ceilings are 1 second per
selection, 128 MiB warm RSS growth, 96 MiB warm isolate heap growth, four cached
sessions, ninety retained records and 64 KiB per response. Full measurements and
class-level summaries are in `display-render-benchmark.json`. These are local
software-renderer smoke budgets, not native-device frame rates or production
latency. The 25 transcript regressions separately cover prepend/delayed-layout
anchoring, width changes, jump-to-latest remounting, large text, account changes,
narrow scaled text and read visibility.

### Pending approval discovery

`HandrailDisplayHistoryCapability.pendingApprovals` negotiates an independent
pending inbox. `HandrailDisplayControl.hasPendingApprovals` is nullable for older
servers. `HandrailConversationSession.readApprovals()` reads one pending page or
one proposal/tool review without loading messages; cancellation includes account
closure and chat selection, and responses behind current controls are rejected.

`HandrailAssistantController.approvals` exposes `openPendingApprovals`,
`selectPendingApproval`, and `closePendingApprovals`. It retains one inbox page
(30 records / 64 KiB), replaces it on paging, cancels stale requests, and refreshes
an open inbox after control revisions change. Only the selected proposal enters
the decision presentation. Opaque references can use the SDK's bounded two-record
review (128 KiB maximum), with turn/tool/name and argument-hash checks. Existing
host review callbacks and durable decision receipts remain in effect.

`HandrailAssistantWorkspace` now includes `HandrailPendingApprovalInbox` above
the scrolling transcript. Custom hosts can place that widget with
`controller.approvals.uiBinding` alongside their transcript. The existing
`HandrailApprovalDecisionsView` continues to render loaded activity approvals;
its optional `proposalId` selects an inbox review. The inbox is height-bounded on
small displays and replaces pages rather than appending all pending actions.
Oversized deferred proposal/tool details remain unavailable for confirmation;
a full structured deferred-review reader is still required before that case is
considered complete. No dependency pins or production deployments were changed.
