// Source qualification on the official Flutter 3.38.1 + Dart 3.10.0 SDK.
// Dependency resolution is isolated; repository manifests/locks stay unchanged.
import { readFileSync, writeFileSync, cpSync, mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const sdk = join(root, '.dart_tool/presend-review-flutter-supported/flutter');
const directory = join(root, '.dart_tool/presend-review-min-package');
const client = join(root, '.dart_tool/presend-review-min-client');
const mode = process.argv[2];
if (!['analyze-client', 'analyze-widgets', 'test'].includes(mode)) throw Error('Expected analyze-client, analyze-widgets or test');
cpSync(join(root, 'packages/handrail_ai_widgets/lib'), join(directory, 'lib'), { recursive: true });
cpSync(join(root, 'packages/handrail_ai_client/lib'), join(client, 'lib'), { recursive: true });
cpSync(join(root, 'packages/handrail_ai_client/pubspec.yaml'), join(client, 'pubspec.yaml'));
const configFile = join(directory, '.dart_tool/package_config.json');
const config = JSON.parse(readFileSync(configFile));
for (const p of config.packages) p.rootUri = new URL(p.rootUri, pathToFileURL(configFile)).href;
config.packages = config.packages.filter(p => p.name !== 'handrail_ai_client');
config.packages.push({ name: 'handrail_ai_client', rootUri: pathToFileURL(client + '/').href, packageUri: 'lib/', languageVersion: '3.4' });
config.packages.find(p => p.name === 'handrail_ai_widgets').rootUri = pathToFileURL(directory + '/').href;
if (!config.packages.find(p => p.name === 'flutter').rootUri.startsWith(pathToFileURL(sdk).href)) throw Error('Mixed Flutter root');
writeFileSync(configFile, JSON.stringify(config));
mkdirSync(join(client, '.dart_tool'), { recursive: true });
writeFileSync(join(client, '.dart_tool/package_config.json'), JSON.stringify(config));
cpSync(join(directory, 'pubspec.lock'), join(evidence, 'minimum-supported.lock'));
const env = { ...process.env, FLUTTER_ROOT: sdk, FLUTTER_ALREADY_LOCKED: 'true',
  PUB_CACHE: join(root, '.dart_tool/presend-review-pub-cache'), CI: 'true',
  HANDRAIL_TEST_JS_SDK_DIST: resolve(root, '../handrail-sdk-ai-assistant-js/dist'),
  HANDRAIL_PRESEND_EVIDENCE: join(evidence, 'minimum-composer') };
const args = mode.startsWith('analyze') ? ['analyze', '--fatal-infos', 'lib'] : [
  join(sdk, 'bin/cache/flutter_tools.snapshot'), '--no-version-check', '--suppress-analytics',
  '--packages', configFile, 'test', '--no-pub', '--concurrency=1', '--reporter=expanded',
  // The diagnostic composer test needs run-presend-trace instrumentation;
  // these package/shared regressions use uninstrumented source.
  ...['tool/terminal_pending_test.dart', 'tool/transcript_retry_test.dart',
    'packages/handrail_ai_widgets/test/draft_controller_test.dart',
    'packages/handrail_ai_widgets/test/composer_drafts_test.dart',
    'packages/handrail_ai_widgets/test/assistant_workspace_test.dart'].map(p => join(root, p))];
const result = spawnSync(join(sdk, 'bin/cache/dart-sdk/bin/dart'), args,
  { cwd: mode === 'analyze-client' ? client : directory, env, stdio: 'inherit', timeout: 240000 });
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
