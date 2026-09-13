# Flutter SDK extraction

## Source and cause

The Dart client was introduced in the general AI SDK by commit
`bc9098dc672355290c490de6329d95b459a75cf4` on 2026-08-30. The repository later
became `handrail-sdk-ai-assistant-js`, while its Flutter subtree and npm `files`
entries remained. Flutter code was therefore stored and shipped with the JS
package despite being consumed independently through Dart Git dependencies.

This extraction starts from the public JS source commit
`d574ea74d675666ebd4ea27f0fa0a13bae2a13df` (JS SDK 0.2.33). At the owner's
request, client 0.1.2 and widgets 0.1.1 also include the concurrent attachment
work: cancellable protected uploads, validated attachment references, shared
file selection, draft attachments and composer integration. Existing Dart
package/import names remain unchanged. Generated build artifacts are excluded.
The gateway test now uses the JS package's public exports through a
full-SHA Git dependency and an npm lockfile instead of relative `dist` imports.
The Markdown fixture is retained inside the widgets package, and the MIME
upload test returns a complete reference accepted by upload validation.

The attachment stage's completed implementation and tests were synchronized
before removing the original Flutter directory from the JavaScript checkout.
All 22 Dart runtime files were verified byte-for-byte against the source tree.
The wider assistant consolidation goal is separate from this repository split.

## Consumers observed in workspace manifests and application imports

| Application | Client JS commit | Widgets JS commit |
| --- | --- | --- |
| Mills Family ERP v4 mobile | `932411cecdee486d6e12284ccb31921597e1192f` | `932411cecdee486d6e12284ccb31921597e1192f` |
| Hitcents ERP mobile | `70526d57b6b449854fa9b2127124f6d24e8cc152` | `70526d57b6b449854fa9b2127124f6d24e8cc152` |
| Spartan Cyber ERP v3 mobile | `391280a1db696ebcded1d0c3fba9a74c3084438f` | `92fbdf616defc19aac3eedf92b7e0f92195b246f` |

All three use both packages in application code. Handrail's own mobile
`pubspec.yaml` does not declare either package. This is checkout evidence as of
2026-09-12, not a claim about which revision is deployed or an exhaustive
inventory of repositories outside this host.

## Adoption boundary

After the Flutter source has been committed and pushed under release
authorization, freeze its full public SHA. For each consumer, change the Git
URL to `https://github.com/c0x65o/handrail-sdk-ai-assistant-flutter.git`, change
`flutter/handrail_ai_client` to `packages/handrail_ai_client` and
`flutter/handrail_ai_widgets` to `packages/handrail_ai_widgets`, and set the
approved Flutter SHA. Run normal Flutter dependency resolution, commit the
matching lockfile, analyze/compile the application and run its assistant tests.
Existing Dart import names need no changes.

Consumers pinned to old JS commits continue to resolve those historical trees.
Removing the current JS subtree does not migrate any application. The old
consumer pins above also predate this extraction source, so adoption includes
the intervening SDK changes and requires application qualification.

Update Handrail's attached implementation KB and SDK source metadata when
making this revision available. The historical JS implementation KB points
Flutter installs at `flutter/handrail_ai_client` in the JS repository; new
Flutter installs must use this repository and its package paths. Config > Repos
currently labels the new repository `server`; it should be classified `sdk`.

## Validation

Validated after removing the original Flutter source directory, using Flutter
3.41.7 and Dart 3.11.5:

- `make check`: both package analyses pass with fatal infos; all 66 client tests
  and 50 widget tests pass with one worker. The gateway cases run against the
  independently installed, locked JS SDK, without the old Flutter directory.
- All 22 Dart runtime source files match the finished attachment-stage source
  byte-for-byte. Only repository metadata, documentation and test fixture wiring
  differ as part of the extraction.
- The JS production TypeScript build passes. Its scoped package-contract checks
  pass for Git-install builds, every public ESM export and intended package
  contents; the package check explicitly rejects Flutter paths and Dart files.
- The broader JS package-contract suite has one pre-existing failure: the
  Spartan adapter test expects `maxTotalToolCalls = 75`, while committed adapter
  source sets `150`. That unrelated assertion was not changed by the extraction.

No consumer migration, commit, push, deployment or live KB/configuration update
was performed as part of this split. The SDK source is a local review candidate.
