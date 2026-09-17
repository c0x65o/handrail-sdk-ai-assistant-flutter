# Paged display history client (local work)

The Dart client now recognizes the negotiated `displayHistory` v1 gateway
capability and exposes `displayHistoryPage`, `displayHistoryChanges`, and `displayHistoryContent` on
`HandrailAiClient`. These are display APIs, distinct from canonical snapshots.
When `displayHistory.control` is also advertised, `HandrailConversationSession`
and `HandrailAssistantController` use scalar controls, a bounded message window,
and a separate bounded page of related activity. They do not pull canonical
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
when rows are prepended or their heights change. It renders the controller's
bounded window with exact row layout. It does not build the full transcript.
The default renderer reuses SDK Markdown/copy/message styling; protected
attachments use `attachmentBuilder`. Domain formatting can use `messageBuilder`.
`deferredBuilder` supplies the explicit full-content action for oversized records;
the default notice never silently truncates or automatically downloads them.

Foreground polling, loading/preparing/empty/error/retry states, jump-to-latest,
selection cancellation, and scope changes belong to the widget. The optional
`HandrailDisplayPositionStore` persists message anchors; the default memory cache
retains at most 32 chats. A failed preference read does not block messages.
`onVisibleLatest` reports an observed revision so the account controller can
acknowledge exactly what was displayed. It must not acknowledge unseen pages.

Widget tests cover one-page selection, retained-row bounds, prepend and delayed
layout anchoring, account changes during pending requests, explicit oversized
content, retries, persisted anchors, narrow layout and doubled text size. These
are Flutter widget tests, not device frame-time or memory benchmarks. Related-state
paging and oversized-content actions still need the complete end-to-end audit;
the separate related page currently replaces the previous activity page.

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
gateway's request-byte limit. The session passes all of its at-most-90 retained
messages; a stale activity page cannot replace a newer window's activity.
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
