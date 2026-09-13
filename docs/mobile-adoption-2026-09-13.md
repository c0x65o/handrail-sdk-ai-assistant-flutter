# Mobile adoption investigation — 2026-09-13

The five failed builds queued around 03:40 UTC all failed during Dart
compilation because application code used assistant APIs absent from the
locked SDK revisions. Removing Flutter from the current JS repository did not
cause these failures: full-SHA dependencies still resolve the historical trees.

| Application | Version / platform | Build IDs | Missing APIs |
| --- | --- | --- | --- |
| Mills | 1.0.226 / iOS | `3e5a7b62-ef03-417a-a387-da3ea2465af0` | `HandrailAudioRecorder`, recording types and duration constant |
| Cents | 1.0.255 / iOS, Android | `e9fe0b2b-54db-4d79-bf76-009898857ae8`, `31eb1f49-915c-4543-87a3-ace2062eaacf` | Draft controller, `onAccepted`, composer focus and session capabilities |
| Spartan | 0.1.52 / iOS, Android | `8c407933-10ea-4214-86f2-eb61f0af395f`, `e4a8f804-8340-447b-b805-1ba0fcbe106a` | Draft controllers, `onAccepted`, composer line limit and session capabilities |

## Local adoption candidate

The public Flutter repository HEAD verified for this migration is
`933cf303bc3acaec68ed3e31f1548d3ed87a443e`. Both packages must use
`https://github.com/c0x65o/handrail-sdk-ai-assistant-flutter.git`, that full SHA,
and `packages/handrail_ai_client` / `packages/handrail_ai_widgets` respectively.
Application import names stay unchanged.

Spartan's manifest and generated lockfile now use that revision. Normal
dependency installation succeeds. All 55 assistant tests pass with one worker.
Full analysis reports no errors, one unused-import warning and 16 informational
lints. Native store builds have not been rerun as part of this investigation.

Mills and Cents are blocked during dependency resolution. The assistant widgets
depend on `file_picker 12.1.1`, whose Windows implementation requires `win32 6`.
Their direct `package_info_plus 9` dependency and the published bug reporter's
`package_info_plus 9` / `device_info_plus 12` constraints require `win32 5`.
Dart resolves every platform's dependency graph even for an iOS or Android app.

The local bug-reporter SDK candidate widens those constraints to
`>=9.0.1 <10.2.0` and `>=12.2.0 <13.2.0`. Its lockfile selects
`package_info_plus 10.1.0` and `device_info_plus 13.1.0`, compatible with the
current Flutter 3.41.7 toolchain. This candidate needs an authorized commit and
push before either app can consume it through a public full-SHA dependency.
All 48 bug-reporter tests pass with that lockfile; analysis has no errors and
two existing unnecessary-non-null-assertion warnings. Enforced-lockfile installs
pass for both this candidate and Spartan.

The upper bounds retain the validated plugin lines. The upstream
[package-info changelog](https://pub.dev/packages/package_info_plus/changelog)
and [device-info changelog](https://pub.dev/packages/device_info_plus/changelog)
document the win32 6 transition, the lowered requirements in 10.1 / 13.1,
and the subsequent Flutter 3.44 Swift Package Manager changes.

After that revision exists, migrate both assistant packages in Mills and Cents,
pin the compatible bug-reporter revision, change their direct
`package_info_plus` requirement to `10.1.0`, and generate matching lockfiles
through normal `flutter pub get`. Analyze each app and run its assistant tests
before requesting native builds. Do not use local SDK overrides or fabricate a
lockfile while waiting for the public revision. Their manifests and lockfiles
remain at their original pins until this prerequisite is available.

No commits, pushes or deployments were performed in this investigation. Builds
already queued from earlier commits cannot include these local changes.
