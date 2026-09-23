# Flutter response rendering

The standard assistant Markdown previously enabled the Markdown package's
per-block `SelectableText` rendering. Each growing response causes that package
to parse again and build fresh keyed children. This recreated an editable-text
selection stack for every paragraph and table cell on every text update.

`HandrailMarkdown` now uses normal formatted text under one `SelectionArea` per
message. Selection and copying still work across paragraphs and table cells;
user messages remain literal, and the existing Markdown Copy action is unchanged.
The UI also places tool activity before its associated answer and drops the
standalone Working label once that request has answer content. Before any answer,
named tool progress replaces the redundant generic Working label.

The network-free reproduction is `test/streaming_render_test.dart` in the widgets
package. It renders a 390 × 844 viewport, thirty retained messages and a growing
6,933-character answer containing 25 paragraphs and a thirty-row table. It applies
thirty text updates, then ten unchanged notifications, through the normal bounded
transcript bindings. It uses no provider, HTTP transport or account data.

| Measurement | Before | After |
| --- | ---: | ---: |
| Median update plus layout | 219.0 ms | 77.5 ms |
| 95th-percentile update plus layout | 399.8 ms | 133.9 ms |
| SelectableText rebuilds during thirty updates | 2,670 | 0 |
| Mounted SelectableText widgets | 89 | 0 |
| Process RSS after the workload | 768.4 MB | 239.3 MB |

Raw captures are `streaming-render-before.json` and `streaming-render-after.json`.
These are separate debug offscreen Flutter test processes. Timings include widget
updates, layout and test pumps; RSS includes the VM, engine and test harness and
is not an isolated SDK heap or a measured memory leak. They demonstrate rendering
cost independent of transport, not native-device frame rates or production
provider/network latency.

Run from `packages/handrail_ai_widgets` with the configured Flutter toolchain:

```sh
HANDRAIL_STREAMING_RENDER_REPORT=/tmp/streaming-render.json \
  flutter test --no-pub --concurrency=1 test/streaming_render_test.dart
```

Regression coverage checks real selection/copy across formatted paragraphs and
tables, safe links, literal user text, incomplete table prefixes, transcript
scroll anchors, activity placement and progress for subsequent requests. The
Mills rendering assertion accepts both selection implementations so its existing
published SDK pin remains testable as well as the edited SDK source.

These are local source changes. No SDK dependency pin, lockfile, commit or
application release was changed. Installed apps receive them after an authorized
SDK commit/adoption and mobile rebuild.
