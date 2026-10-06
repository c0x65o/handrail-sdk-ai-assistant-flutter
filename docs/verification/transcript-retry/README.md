# Explicit Flutter transcript Retry

Baseline: `handrail_ai_client` 0.1.39 at
`af9f4acceee003bbbbafca6ec2a95f3f55fab8f6`; widgets 0.1.1.
This baseline does **not** contain the fix. Versioning, commit and push belong to
Handrail's post-agent release step; the worker leaves source uncommitted.

## Reproduction and change

The public `HandrailAssistantWorkspace` rendered the actual transcript Retry
button, but `HandrailAssistantController.transcriptBinding.retry` only called
`openConversation`. Version 0.1.39 deliberately made opening observation-only.
Consequently a saved nonterminal start remained pending after an explicit click.

Before changing source, the widget test failed in both bounded-history and
full-snapshot modes: expected a second admission using the saved identity, got
only the original admission. [Before log](before.log) preserves those failures.
That first run was interrupted after the two assertions because its test cleanup
did not finish; cleanup was corrected in the final fixture.

The binding now observes and reconciles first, then uses the existing pending
retry contract. It captures the selected conversation/generation and saved
submission, coalesces overlapping actions, and rechecks the exact journal after
the session's authorized preflight, immediately before admission. Navigation,
reentry, disposal and journal replacement during those reads prevent replay.
Once admission is dispatched, the existing contract finishes that exact operation
across navigation. Public headless retry APIs retain their signatures.

Opening, reload and automatic observation still never replay the uncertain
submission. Exact terminal proof settles it without a resend. A click recovering
a blocked read/auth/history error only observes; a still-pending message needs a
separate explicit Retry after reads recover. No pending intent means observation
only, including recovery of an empty catalog without creating a conversation.

## Verification

`tool/transcript_retry_test.dart` exercises the real public Flutter workspace,
transcript, composer, controller and session. Only HTTP/storage boundaries are
synthetic; no provider credentials or real effects are used.

- Final explicit Retry suite: **43 passed**, [log](after.log). Covers lost start
  acknowledgement before/after the simulated effect, exact admission/start
  identity, one message/effect, repeated-button and binding deduplication, cold
  reload without resend, newer text/files, terminal denial and enabled follow-up,
  selection/reentry/disposal/replacement races during observation and retry
  preflight, blocked auth/history/storage, foreign active work, archived state,
  invalid exact-turn controls, and read-only catalog recovery.
- Shared recovery/reentry/history/scroll suite: **115 passed** before adding the
  two extra accepted-start cases; the final 43-case Retry suite then passed.
  Existing terminal-pending reconciliation and phone scroll tests are unchanged.
- Full client suite: **269 passed, 3 skipped**. The skips explicitly require local
  JS/PostgreSQL qualification and were not enabled. This run uses the normally
  installed, locked JS gateway with a deterministic provider. Three old gateway
  tests initially failed because they expected reopening to resend; they now
  assert no resend on open and recover via the public transcript Retry binding.
- Full widget suite: **263 passed**. Client `dart analyze --fatal-infos` and widget
  `flutter analyze --no-pub --fatal-infos`: **no issues**. Shared widget tests also
  compile both local packages. Runner syntax and `git diff --check` passed.

Run serially, with one test worker:

```sh
make analyze
make test
node tool/check-shared-widgets.mjs "$FLUTTER_ROOT"
```

For this worker's prepared read-only Flutter SDK, the cached Dart/Flutter tool
entrypoints and `FLUTTER_ALREADY_LOCKED=true` were used. Nonfatal iOS artifact
stamp warnings are unrelated to these offscreen tests. The shared runner uses
temporary compiler package maps and changes no installed pins or lockfiles.

## Consumer qualification after publication

1. Obtain the full published **fix SHA and version from Handrail's release step**.
   Pin both `packages/handrail_ai_client` and `packages/handrail_ai_widgets` to that
   same 40-character SHA from
   `https://github.com/c0x65o/handrail-sdk-ai-assistant-flutter.git`. Use the normal
   Flutter install/build pipeline and commit the matching `pubspec.lock`. Verify
   both lock entries' `resolved-ref`; do not use the baseline above, a branch/tag,
   path override, archive or registry package. No JS upgrade is needed here.
2. Mills' owner should rerun the original lost-ack/retry test reported at
   `c4cd6bf1` through the installed shared transcript button. Assert that reload
   alone sends nothing, then a double-click produces one retry with identical
   admission/start bodies, one user message and one provider effect. Verify
   newer drafts/files, blocked-read recovery, navigation/account disposal, and
   terminal denial followed by an enabled follow-up without replay.
3. Run the consumer's focused recovery, reentry and scroll tests and type analysis
   with that installed pin. Record the full consumer SHA, both resolved SDK SHAs,
   package version and command results as new qualification evidence.

The request reports historical external Git-package qualification `840eda0c`
passing for 0.1.39 while missing this binding. That owner-supplied evidence and
the prior [terminal-pending evidence](../terminal-pending/README.md) remain
historical; neither establishes acceptance of this fix. The actual installed
Mills/Preview qualification has not been rerun here. No Mills, Preview or JS
source, deployment, access, configuration, security policy or queue state was
changed. **Mills Ship hold remains unchanged; Avery is out of scope.**
