# Flutter latest-position repair evidence

Source base: `8197197ec8afee3b1606b35c54ff179123e5f1f1`, client **0.1.37**,
widgets **0.1.1**. This working-tree repair has no new release SHA yet.
Handrail's post-agent step owns versioning, commit and push. Client reentry
changes remain intact; no client, JS, wire, server, dependency or lock changes.

## Reproduction and repair

The Mills fixture was not available in this workspace and was not read.
`tool/phone_latest_position_test.dart` reconstructs the reported failure using
the real SDK workspace, composer, account controller, session, display window
and message renderer. It reuses the existing synthetic HTTP/storage fixture
from `tool/reentrant_assistant_test.dart`: thirty bounded multiline messages,
no private conversations, real network, model calls or business mutations.

Before the fix, the iOS-platform regression failed after a 150px upward drag
with a 300px keyboard inset: dismissal exposed the bottom (`extentAfter <= 2`),
but **Jump to latest remained visible**. See [before.log](before.log). The same
sequence passes after the repair, including `followingLatest == true` in the
real client window.

Scroll intent deliberately ignored layout changes to preserve saved anchors.
The paged transcript's post-layout correction now separately tracks viewport
height. Expansion resumes following only when the corrected position reaches
the actual tail and no newer history is unloaded. It synchronizes the window's
following state and rebuilds the affordance. Content-only height changes and
temporary placeholder clamping do not resume following. A 700px pause preserves
the same visible message/intra-message coordinate through dismissal, streaming
updates and refresh, even when newly measured virtualized bodies change the
absolute scroll offset.

## Rendered evidence

These are **offscreen Flutter-rendered 390 × 844 screenshots** on Flutter
3.41.7 / Dart 3.11.5 with `TargetPlatform.iOS`, Roboto and Material icon fonts.
The keyboard is a synthetic `viewInsets` resize; the blank lower region does
not depict an actual iOS keyboard. This is not a Mills host screenshot or a
physical iPhone/simulator pass.

| State | 150px pause, dismissal reaches bottom | 700px pause, still reading history |
| --- | --- | --- |
| Keyboard open, following | [Screenshot](150.0-keyboard-open.png) | [Screenshot](700.0-keyboard-open.png) |
| Scrolled up, keyboard open | [Screenshot](150.0-scrolled-up.png) | [Screenshot](700.0-scrolled-up.png) |
| Keyboard dismissed | [Bottom, Jump hidden](150.0-keyboard-closed-bottom.png) | [History, Jump visible](700.0-keyboard-closed-history.png) |
| Streaming updates | [Following](150.0-streaming.png) | [Position retained](700.0-streaming.png) |

[150px frame trace](150.0-frames.json) and [700px frame trace](700.0-frames.json)
record 148 individually pumped frames each. Dismissal has one visible-to-hidden
transition for the shallow pause, then stays hidden; the deep pause stays
visible throughout. Tests also assert enabled state, stable button rectangle
and Material color, button semantics, retained keyboard focus, streaming and
refresh stability, keyboard reopening and workspace remount. Unloaded newer
history has a separate widget regression and keeps Jump even at the loaded
page's bottom. Existing tests cover saved anchors, asynchronous body growth,
queued latest requests, full transcript behavior and client monitor reentry.

No visibility/color oscillation reproduced in these scenarios. **The owner's
reported flicker remains unverified and is not claimed resolved.**

## Reproduce locally

Use the prepared Flutter SDK and existing package configs; no dependency install
or override is needed. Each check is bounded to four minutes and uses one worker.
Run from the repository root unless a package directory is shown:

```sh
FLUTTER_ALREADY_LOCKED=true HANDRAIL_PHONE_EVIDENCE="$PWD/docs/verification/phone-acceptance-2026-10-06" timeout 240 node tool/check-shared-widgets.mjs "$FLUTTER_ROOT"

cd packages/handrail_ai_widgets
timeout 240 "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" analyze --fatal-infos
FLUTTER_ALREADY_LOCKED=true timeout 240 "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" --no-version-check test --no-pub --concurrency=1

cd ../handrail_ai_client
timeout 240 "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" test --concurrency=1 test/realtime_workspace_test.dart test/assistant_voice_history_test.dart test/assistant_controller_test.dart test/session_test.dart test/display_session_test.dart test/display_window_test.dart test/display_positions_test.dart
```

The prepared read-only SDK emits nonfatal iOS artifact stamp-write warnings.
No toolchain permissions or platform configuration were changed.

Results: widget analysis **no issues**; full widget suite **263 passed**;
shared controller/workspace suite **17 passed**; focused client scope
**94 passed**. Dart format, runner syntax and `git diff --check` passed.
The final focused iOS run also exercises an active streaming turn; its output
is retained in [after.log](after.log). These results qualify local source only.

## Handoff boundary

The parent must adopt the eventual published full Flutter SHA for both client
and widgets through public HTTPS Git pins and a matching lockfile, then run
independent Mills acceptance. Physical iPhone/simulator keyboard behavior,
native animation/feel, the original reported flicker and release acceptance
remain unverified. No app/platform deployment or release was initiated.
