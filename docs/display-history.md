# Paged display history client (local work)

The Dart client now recognizes the negotiated `displayHistory` v1 gateway
capability and exposes `displayHistoryPage`, `displayHistoryChanges`, and `displayHistoryContent` on
`HandrailAiClient`. These are display APIs, distinct from canonical snapshots.
The existing `HandrailConversationSession` and widgets still use their current
synchronization path; their adoption is the next implementation step.

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
drafts separately. Session/widget adoption is still pending.

Validation: client analysis with fatal infos; 12 display-client/window tests,
including transport cancellation, late responses, row/byte bounds, directional
navigation, anchor restoration, changes-watermark semantics and access revocation.

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
cancelled authentication and response byte limits. Session/widget integration,
upward-scroll anchoring, bounded caches and device rendering remain outstanding.
