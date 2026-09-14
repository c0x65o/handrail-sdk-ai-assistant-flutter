# Shared conversation deletion qualification

## Current installed qualification — September 14, turn 35

The JS receipt correction is public in
`15a3806c2595a3f93a87a768ad13293113f41b58`; the Flutter implementation is public
at `50fe566d73f68b2beacc2a874dc9a038363b1509`. All three main mobile consumers
now normally install the Flutter revision with matching locks. Mills brought its
shared workspace/controller implementation into main, preserving domain review,
files, voice and dictation adapters. Its 312 selected tests and full analysis/build
pass; Cents passes 96 selected tests including its unchanged visual gate; Aegis
passes 179 selected cases including shell and presentation coverage.

The Flutter gateway fixture normally installs the public JS revision via npm 12.
All 138 client tests and full analysis pass with no local SDK override, including
real HTTP deletion/restart, durable approval decisions and protected attachment
ownership/expiry. The attachment gateway test now runs in the default suite
instead of being skipped without a candidate override. Its stores and provider
are deterministic fixtures; this is protocol qualification, not production SQL
retention, real provider or audio execution. Logs:
`/tmp/flutter-client-turn35-{analysis,tests}.log`.

The newer JS terminal-approval response fix remains unpublished. Actual rollout,
live/native qualification and approved production cleanup remain open.

## Historical source-candidate evidence

Earlier pending-publication and alias statements below describe historical
revisions and are superseded by the installed qualification above.

September 13–14, 2026 source candidate for goal
`06b47a97-7cd6-41b7-9040-6b88761094ce`. This document does not establish consumer
installation, rollout or physical production deletion.

The shared account controller now owns permanent deletion and a durable retry
journal. The standard history sheet/sidebar owns confirmation, negotiated action
visibility and recovery. The shared composer removes the target's unsent draft
and file selections after a verified receipt. These mechanisms replace generic
host deletion orchestration while preserving backend domain authorization and
business receipts. Mills' detached source candidate now uses the controller and
history components through explicit local SDK aliases. Its normal public-pin
installation still predates these APIs; source qualification is not installed
consumer adoption.

The journal is separate from saved send content and retains at most 100 exact
requests. Its atomic key-value implementation is account/API-realm scoped and
bounded on read. It stores no titles, prompts, audio, credentials or provider
results. Persistence failure prevents dispatch. Exact acknowledgement cannot
erase another version's intent. Unknown replies and cleanup failures retain the
request for replay. Restart resumes previously confirmed requests before send
recovery, without preventing unaffected conversations from opening. A server
version conflict removes only the rejected intent and reloads for another review.
Unavailable capabilities prevent new deletion; an already-saved receipt remains
checkable if capability advertising later changes and current host permission
allows replay. The live `allowConversationManagement` callback is rechecked
around durable-intent persistence and before mutation dispatch. Revocation keeps
the exact saved request pending, blocks its replay, and allows unrelated history
to load. Restoring permission resumes that original request. Gateway authorization
remains authoritative, including changes while an HTTP request is in flight.

Confirmed deletion removes local catalog/session/activity state and ignores
delayed reads, frames and activity for that identity. Account replacement closes
owned confirmation/history routes and excludes old action completions/errors.
The shared composer discards only the deleted conversation's draft/files. This
is not memory zeroization, removal of arbitrary host caches, or a claim that
remote file queues and business outcomes are settled. Those remain backend and
authorized rollout obligations.

## Evidence and an installed baseline defect

Full default SDK checks initially passed both analyses, 108 client tests and 96
widget tests, with the explicit cross-revision attachment fixture skipped.
Log: `/tmp/flutter-shared-deletion-full-check.log`.

Adding a real HTTP gateway deletion/restart case exposed a JS receipt mismatch.
The installed test dependency `d574ea74d675666ebd4ea27f0fa0a13bae2a13df` returns
`deletedVersion = expectedVersion + 1` from its in-memory catalog; PostgreSQL
returns the removed descriptor's version. Exact receipt checking therefore
correctly refuses that older in-memory result. The initial socket-loss assertion
also needed to expect the real HTTP client's `ClientException`; presentation
still retains the SDK's safe retry message.

JS source now documents the removed-version contract and makes its in-memory
catalog match PostgreSQL. JS typecheck/build, scoped lint and 87 catalog/deletion
tests pass. Logs: `/tmp/sdk-deleted-version-{typecheck,tests,build,lint}.log`.
The correction is still local. The default installed gateway deletion test
remains an adoption dependency, recorded in
`/tmp/flutter-shared-deletion-gateway-tests-final.log`; it is not silently skipped
or changed to accept mismatched receipts.

With `HANDRAIL_TEST_JS_SDK_DIST` explicitly pointing to the reviewed local JS
build, full sequential SDK checks pass both analyses, 110 client tests and 97
widget tests. This includes the real gateway deletion/restart case and protected
attachment integration. Log:
`/tmp/flutter-shared-deletion-candidate-full-check.log`. The fixture defaults to
its installed public Git dependency without that environment setting. A source
override is qualification only; it is not SDK installation or rollout evidence.

Public Git HEADs observed during this turn advanced externally to JS
`5a0ebe520a9e6fde0b3a792f959a7a10e0a3de50` and Flutter
`c22b5ac97b0bcabd99b2d96995a0ed85c49ec124`. They contain preceding work, not this
new Flutter deletion implementation or the in-memory receipt correction.
The goal runner performed no commits, pushes, PRs, SDK publication or deployments.
Reverify exact revisions before consumer adoption. Use public HTTPS full SHAs
and matching locks; qualify installed consumers and real authorized runtime
behavior before claiming parity. No production SQL/storage or provider/audio
execution occurred in these tests.
