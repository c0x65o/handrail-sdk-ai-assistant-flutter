# Settled action history and transcript following

`HandrailApprovalDecisionsView` now separates active decisions from settled
history by canonical status. Executed, finished/completed, rejected and expired
items begin inside the collapsed **Action history** expansion. The original
cards, title/review formatters and canonical records remain available there.
An explicitly selected `proposalId` still renders its complete inbox card.

Pending decisions, approved-but-not-executed actions, executing actions,
failures, unknown states and pending/busy/review/error evidence remain visible.
This is presentation only: approval gates and execution contracts are unchanged.
The history expansion resets on account/conversation change and starts closed
after remount/reload. No persisted local hidden-ID list is introduced.

Both transcript implementations preserve scroll intent across streaming, layout
and keyboard changes. Scroll geometry changes and SDK anchor/tail corrections
cannot reclassify the reader as following or away. A deliberate upward movement
pauses following; scrolling down to the actual tail (two-pixel tolerance) or
choosing Jump to latest resumes it. Crossing the old near-bottom thresholds does
not blink the control. Paged transcript viewport-only metric changes now also
schedule the existing anchor/follow correction. Read acknowledgements continue
to use the existing visibility and revision guards.

See `settled-transcript-qualification.json` for regression reproduction, commands,
outputs and verification boundaries. The corresponding JS repository contains
`docs/settled-transcript-handoff.md` with both repositories' consumer installation
steps and remaining Mills native acceptance work. This is an SDK preparation;
Handrail's post-agent step still owns versions/commits/pushes, and Avery owns Mills
adoption and its existing delivery workflow. No theme or business data changes
are part of this patch.

## Saved reader position repair (request 1dcaa5bf)

Source base: `dc21bc18553492a1cbe7e29e6bd69f4b6202ffa0`. Local reproduction
confirmed that `HandrailDisplayTranscript` replaced a saved anchor with a capture
after positioning against estimated row heights. On reopen, an unmounted body
has a 240px placeholder; the saved intra-message offset can exceed that height
or the temporary scroll extent. Clamping and capturing that intermediate layout
discarded the requested offset before the real body was measured. Synthetic
50px/700px pause cases drifted by 730px/80px before the repair; these are local
measurements, not the Mills native finding's 170px/160px measurements.

`packages/handrail_ai_widgets/lib/display_transcript.dart` now mounts the paused
anchor's body and retains its message/offset across layout passes, including
asynchronous body sizing. Reader scrolling, explicit Jump, record eviction and
generation replacement still update or invalidate it. Selection-time scroll
notifications cannot replace the anchor; obsolete frame callbacks cannot clear
a new selection's scheduled work, and selection changes cancel pending saves.
No timer, polling cadence, public API, wire format, theme or approval behavior
changed. JS/React inspection found no shared contract change requiring a patch;
the Flutter placeholder/layout implementation owns this repair.

Local validation:

- `packages/handrail_ai_widgets/test/display_position_restoration_test.dart`:
  eight tests covering shallow reload with a fresh binding, deep route remount,
  delayed body growth and explicit Jump, older-page selection/prepend/eviction,
  disposal, account switching, cancelled selection and generation mismatch.
- `tool/history_restoration_test.dart`: two added real account-controller,
  display-window and workspace tests with simulated HTTP/storage. They preserve
  pending-card coordinates and saved message/offset at both pauses, drafts,
  automatic readiness, pending/failed actions and settled history, including
  61 seconds of simulated quiet time. Existing readiness and full read-only
  settled-detail tests remain in this suite.
- Full widget suite: `flutter test --no-pub --concurrency=1` — 262 passed.
- Widgets: `dart analyze --fatal-infos` — no issues.
- Shared client/widget lifecycle: `node tool/check-shared-widgets.mjs
  "$FLUTTER_ROOT"` — 10 passed (history restoration and display polling suites).
- `git diff --check` — passed. Repaired `display_transcript.dart` SHA-256:
  `ef9f3d2a421d1e7d02fcd9577a869d311ca61b0c65dbc50762231bc91d70f3cd`.

The prepared shared Flutter cache is read-only. Checks use
`FLUTTER_ALREADY_LOCKED=true` and invoke `bin/cache/flutter_tools.snapshot` via
`bin/cache/dart-sdk/bin/dart`; nonfatal iOS artifact stamp-write warnings remain.
These are local source checks, not device or deployed-app acceptance.

### Mills adoption and QA handoff

Handrail's post-agent step owns the version bump, commit and push. The final
publication receipt/full SHA is **pending that step**; the base SHA above does
not contain this repair. Avery should take the resulting published 40-character
SHA from that receipt and update both Mills Git dependencies from
`https://github.com/c0x65o/handrail-sdk-ai-assistant-flutter.git`, retaining paths
`packages/handrail_ai_client` and `packages/handrail_ai_widgets`. Refresh
`pubspec.lock` and verify each `ref` and `resolved-ref` matches that exact SHA,
with no dependency overrides. The inspected Mills manifest and lock currently
both match the base SHA; neither was changed by this source assignment.

Avery owns adoption and renewed native QA on the existing staging fixture:
task `58c716fa-f5ea-4121-8ced-5c2b5aaa6177`, profile
`ece30cb1-90a9-4e0a-925e-f0cc9ae4694f`, conversation
`1d893253-4cf6-59b8-9da9-9be4ebfece82`. Compare stable same-message/intra-message
and approval-card coordinates after a 50px paused reload and 700px route reopen,
then verify quiet Jump, explicit Jump/resize, retained drafts, automatic readiness
and inspectable settled history. Keep detail expansion state comparable; a
collapse-only height difference is outside this finding. The initial truthful
disabled-to-enabled Jump transition remains allowed. No runtime, fixture or
action mutation was performed. Installed iPhone/production delivery stays with
Mills release controller request `412cfd3d`; this repair starts no release.
