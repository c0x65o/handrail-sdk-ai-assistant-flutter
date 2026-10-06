# Flutter assistant reentrant observation repair

Source base: `737f71ccba45c9201247d3a16fcc5f460859c6dc`.
This addresses the SDK path reported in Mills production 1.0.291 build 3557107,
incident `ceae5bf3-53f2-4dc1-ad64-508f97662120` (2026-10-06). The failed phone
handoff remains failed; local SDK qualification does not establish iOS acceptance.

## Cause and change

`HandrailRealtimeWorkspaceMonitor` used a synchronous broadcast. During its
loading notification, `HandrailAssistantController._publish` can discover a
descriptor recorded since the last publication and call `setConversations`.
That method changes the generation/scope/state and immediately adds another
event to the same broadcast. Dart throws **Cannot fire new event. Controller is
already firing an event**. The scope refresh is then abandoned after the state
change; the controller has already cached the new scope identity. Disposing the
monitor from a listener also failed because `close` cannot reenter that broadcast.

The monitor now uses Dart's asynchronous broadcast queue. Every immutable
snapshot is delivered in order to each subscribed listener; there is no
debounce, dropped-event flag or StateError catch. State and generation updates
remain immediate. Existing serialized reads, scope validation, stale-response
fences, retained evidence and disposal guards remain in place. The controller's
scope-identity comment is updated to describe the scheduling behavior.

Runtime changes are confined to `handrail_ai_client` (base version 0.1.36).
`handrail_ai_widgets` (base version 0.1.1) is exercised with the edited client
through the existing temporary package-map qualification tool; its runtime
source and both package lockfiles are unchanged. No JS source, Mills code,
dependency pin, deployment or native configuration changed.

## Reproduction and verification

Before the fix, all three new Dart regressions fail with the broadcast StateError:

- `realtime_workspace_test.dart`: listener-driven scope changes and listener
  disposal. The scope test checks the complete ordered state sequence across
  two listeners, including fencing the old response.
- `assistant_voice_history_test.dart`: real controller initialization,
  descriptor acquisition, overlapping monitor refresh, selection and text
  observation. The stack includes `_emit → setConversations →
  _setVoiceConversations → _publish → monitor listener → refresh`.

`tool/reentrant_assistant_test.dart` uses real Flutter Material widgets, account
controller, monitor, session, display window, composer and transcript. Only HTTP
and storage are simulated. Restoring the old broadcast also fails this widget
test with the same stack and leaves the new conversation out of the read scope.
With the fix, its two tests cover:

- Rapid monitor/controller updates, thirty retained multiline messages at
  390 × 844, keyboard insets and paused-reader Jump to latest.
- Delayed admission, immediate sending/sent feedback, draft cleanup, eight
  canonical streaming updates and replacement of the local echo by message ID.
- Stop, surface close/reopen without cancellation, and reload with a fresh
  account controller while preserving canonical history and cancellation.
- Failed preflight retains the last good transcript and editable draft, sends
  no mutation/start, removes the unaccepted echo and recovers on reopen.

This refresh/send audit did not justify a second production-code change. The
synthetic tests make no real messages, model calls, voice operations or effects.
The new widget tests are included in the default shared-package check.

Commands (run sequentially with one test worker):

```sh
cd packages/handrail_ai_client
"$DART_SDK/bin/dart" analyze --fatal-infos
"$DART_SDK/bin/dart" test --concurrency=1 test/realtime_workspace_test.dart test/assistant_voice_history_test.dart test/assistant_controller_test.dart test/session_test.dart test/display_session_test.dart
cd ../..
FLUTTER_ALREADY_LOCKED=true node tool/check-shared-widgets.mjs "$FLUTTER_ROOT"
FLUTTER_ALREADY_LOCKED=true node tool/check-shared-widgets.mjs "$FLUTTER_ROOT" packages/handrail_ai_widgets/test/streaming_render_test.dart packages/handrail_ai_widgets/test/settled_transcript_regression_test.dart packages/handrail_ai_widgets/test/display_position_restoration_test.dart packages/handrail_ai_widgets/test/near_bottom_refresh_test.dart packages/handrail_ai_widgets/test/assistant_close_guard_test.dart
```

Final results: client analysis **no issues**; focused client tests **79 passed**;
shared controller/widget tests **15 passed**; existing rendering, restoration,
scroll and close-guard widget regressions **20 passed**. Changed Dart files pass
`dart format --output=none --set-exit-if-changed`; `node --check` on the runner
and `git diff --check` pass. A mistakenly root-scoped analysis was stopped and
replaced by the completed package-scoped analysis above; no full CI was run.

The prepared Flutter snapshot runs directly through the installed Dart runtime,
as documented for this workspace. Nonfatal read-only `libimobiledevice` and
`libusbmuxd` stamp warnings do not prevent offscreen Flutter tests; no permissions
or shared toolchain files were changed. Local before/after logs are under the
ignored `.dart_tool/reentrant-*.log` paths.

## Release boundary

Source changes are intentionally uncommitted. Handrail's post-agent step owns
versioning, commit and push; a new published full SHA is pending its receipt.
The base SHA above does **not** contain this repair. The parent workflow owns
Mills adoption using the resulting public HTTPS Git full SHA and matching
lockfile, then a qualified TestFlight release. Physical iPhone behavior, native
keyboard/scroll feel, performance and owner phone handoff remain unverified.
No device pass or production acceptance is claimed; Avery is outside this task.
