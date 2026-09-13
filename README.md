# Handrail AI Assistant SDK for Flutter

Dart clients and Flutter UI for an application-hosted Handrail AI assistant.

| Package | Responsibility |
| --- | --- |
| [handrail_ai_client](packages/handrail_ai_client/README.md) | Headless Dart gateway client, conversation sessions, durable submission recovery, protected HTTP, activity, voice-call state and transcription. |
| [handrail_ai_widgets](packages/handrail_ai_widgets/README.md) | Flutter composer, draft handling, approval controls, attachments, Markdown, recording and transcription UI. |

The packages are independent. Applications may use either or compose both. Dart
import names and public APIs are preserved by the repository extraction.

The application backend uses the separate
[JavaScript/TypeScript SDK](https://github.com/c0x65o/handrail-sdk-ai-assistant-js).
Flutter calls the application's authenticated gateway; provider credentials,
authorization, persistence and tool execution stay on that backend. Both SDKs
implement the [application gateway wire protocol](https://github.com/c0x65o/handrail-sdk-ai-assistant-js/blob/main/docs/wire-protocol.md).

## Installation

Use `https://github.com/c0x65o/handrail-sdk-ai-assistant-flutter.git` with a full
40-character published commit SHA and these Git package paths:

- `packages/handrail_ai_client`
- `packages/handrail_ai_widgets`

Resolve the latest committed revision for a new install, or use the frozen
revision supplied for an upgrade. Commit the matching `pubspec.lock`. Do not
install from a branch, tag, registry, tarball, local path or workspace override.
No packaging or publishing step is needed beyond making the reviewed Git
commit available; Flutter compiles the Dart source in the normal app build.

This extraction is currently a development change. The repository's initial
commit does not contain the packages. A consumer can switch only after a commit
containing this source is publicly available; do not invent or reuse a JS SHA
as the Flutter repository revision. See [extraction and adoption](docs/extraction.md).

## Development

The client requires Dart >=3.4; widgets require Dart >=3.10 and Flutter >=3.38.
The shared file picker requires iOS 14 or newer when targeting iOS.
Gateway integration tests additionally require Node >=20 and npm.

```sh
make setup
make check
```

Checks run serially, with one test worker per package. `make setup` installs the
test gateway's JS SDK from its locked public HTTPS Git commit; that dependency's
normal `prepare` hook compiles it. The Node fixture is test tooling only and is
not a Dart dependency. Integration tests exercise a real SDK gateway with
in-memory stores and a deterministic provider, without credentials or paid API
calls. They do not need an adjacent JavaScript checkout or its `dist` directory.

Each Dart package retains its own lockfile for reproducible SDK development.
