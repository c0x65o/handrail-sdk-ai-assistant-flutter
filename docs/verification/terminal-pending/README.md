# Flutter terminal pending submission repair

Source base: Flutter `24b4547195532cd6a3b1dbb64116eda67376b933`,
`handrail_ai_client` **0.1.38**, `handrail_ai_widgets` **0.1.1**.
The unchanged JS checkout is `7ff3b9f23467ce01e578d7039c3ffa35e2f557b6`,
`@handrail/ai-assistant` **0.2.79**. These are baseline revisions, not a release
containing this repair. Handrail's post-agent step owns versioning, commit, push
and the resulting published SHA; source changes are intentionally uncommitted.

## Root cause and reproduction

A send admitted its canonical user message and turn, then received a denied or
lost start reply. `_submitRetained` kept the submission journal, and the account
controller's catch set `_pending`. Subsequent observation refreshed the failed
canonical turn but never reconciled that journal/latch. `canSend` therefore
remained false even though Running and Stop were false.

`tool/terminal_pending_test.dart` reproduced this **before editing source**, on
both bounded display controls and full snapshots. It uses the real Flutter
workspace, composer, account controller, session and key-value adapters. Only
HTTP and storage callbacks are synthetic. The fixture retains the exact admitted
message and start identity and returns the canonical failed state corresponding
to JS `rejectUnstartedTurn` (whose durable server record has
`admissionRejected: true`). No JS surrogate UI or hand-written SQL engine is used.

The Preview paths named in the request are outside this workspace and were not
read. This is a source-based reproduction of the supplied scenario, not a claim
to have rerun Preview's installed-consumer qualification. No server persistence,
Postgres, live credentials, paid model or business calls were exercised here.

## Before and after

| After canonical terminal observation | Before | After |
| --- | --- | --- |
| Exact saved turn | failed | failed |
| Running / Stop | false / false | false / false |
| Pending / Send enabled | true / false | false / true |
| Controller error | `stream_request_failed` (403) | null |
| Follow-up draft | `Later follow-up` | `Later follow-up` |
| Admissions / starts before explicit follow-up | 1 / 1 | 1 / 1 |
| Admissions / starts after one explicit follow-up | blocked | 2 / 2 |
| Synthetic provider effects / cancellations | 0 / 0 | 1 / 0 after follow-up |

The original user message remains saved once. The canonical failed outcome stays
visible after its obsolete transport error is removed. The test also refreshes
repeatedly and recreates the controller/composer before the explicit follow-up.

- Failing-before assertions: [tests.log](before/tests.log).
- Bounded screenshots: [before](before/true-after-observation.png),
  [after](after/true-after-observation.png), [follow-up](after/true-follow-up-sent.png).
- Full-snapshot screenshots: [before](before/false-after-observation.png),
  [after](after/false-after-observation.png), [follow-up](after/false-follow-up-sent.png).
- State traces: [bounded before](before/true-report.json),
  [bounded after](after/true-report.json), [full before](before/false-report.json),
  [full after](after/false-report.json).

The before trace's pre-observation `sendEnabled` measured the shared action
button while it was Stop. Compare the **after-observation** rows for Send; final
after traces distinguish Send from Stop. Images are real offscreen Flutter
renders at 390 x 844 with prepared SDK fonts, not browser, installed host,
simulator, or physical-device captures.

## Safety contract

Opening and account observation now perform read-only server reconciliation.
They use the retained conversation/turn identity, an authorized requested-turn
control (with generation/revision validation) or fresh full synchronization,
and an explicit terminal status with `remote_may_still_be_running == false`.
They never infer acceptance from the latest turn or a 401/403 alone. Opening an
uncertain submission no longer automatically replays mutations; explicit Retry
retains its existing exact-identity behavior.

Reconciliation checks account/session lifetime, selection activation, deletion
state and active conversation lifecycle across awaits. It cleans only captured
draft versions/file IDs, uses the existing atomic compare-and-delete journal
operation, then reloads before releasing the latch. A replacement journal remains
pending. Cleanup/read/delete failures remain recoverable; an in-memory exact
receipt allows revalidation after an acknowledged deletion loses its reply.

The regression suite covers missing/foreign/running/paused turns, 401/403/404/503,
missing/foreign/stale/preparing/generation-mismatched requested controls, an exact
requested turn outside the latest-turn summary, cold reopen, lost start replies,
newer text/files, pending replacement, disposal/account replacement and selection
races, cleanup/storage failure and lost local acknowledgement. Existing monitor
reentry and latest-position/scroll source was not changed.

## Checks and consumer handoff

Commands run serially with one test worker and per-command bounds below five
minutes. The prepared read-only SDK requires `FLUTTER_ALREADY_LOCKED=true` and
invocation through cached `dart`/`flutter_tools.snapshot`; nonfatal iOS artifact
stamp warnings do not indicate a device test.

```sh
export FLUTTER_ROOT=/path/to/flutter
FLUTTER_ALREADY_LOCKED=true \
  HANDRAIL_TERMINAL_EVIDENCE="$PWD/docs/verification/terminal-pending/after" \
  timeout 180 node tool/check-shared-widgets.mjs "$FLUTTER_ROOT"
```

The runner uses temporary compiler package maps for local source qualification;
it changes no dependency pins or lockfiles.

Results: [client analysis](client-analysis.log) and
[widget analysis](widget-analysis.log) **no issues**;
[focused client tests](client-tests.log) **108 passed**;
[final controller retest](client-final.log) **32 passed**;
[full widget suite](widget-tests.log) **263 passed**;
[final shared suite](shared-final.log) **74 passed**, including **57 terminal
recovery tests** plus the existing 17 reentry/scroll/history checks.
Dart formatting, runner syntax and `git diff --check` passed.
[Qualification metadata](qualification.json) records source hashes and boundaries.

After Handrail publishes the repair, the consumer owner must pin **both** Flutter
Git package paths (`packages/handrail_ai_client`, `packages/handrail_ai_widgets`)
to that same full published 40-character SHA from
`https://github.com/c0x65o/handrail-sdk-ai-assistant-flutter.git`, regenerate and
commit the matching `pubspec.lock`, and use the normal Flutter install/build.
Do not adopt this baseline SHA as the fix or use a local/path/archive override.
No JS dependency upgrade is needed for this client repair.

Preview's owner must rerun the installed denied-start/follow-up scenario and its
19 regressions with the eventual pin, including reload and account replacement.
Installed Preview/Chat acceptance, physical devices and server/PG interoperability
remain unverified here. Preview/Mills source and platform policy/access/config
were not changed. **Mills production Ship remains blocked.**
