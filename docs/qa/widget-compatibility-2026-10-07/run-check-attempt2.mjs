// Isolated source qualification. Never writes prior review evidence or SDK files.
import { cpSync, readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const [runtime, mode, label = `${runtime}-${mode}`] = process.argv.slice(2);
if (!['minimum', 'current'].includes(runtime) || !['analyze', 'test'].includes(mode)) throw Error('Expected minimum|current analyze|test [unique-label]');
const sdk = runtime === 'minimum' ? join(root, '.dart_tool/presend-review-flutter-supported/flutter') : '/opt/handrail/.handrail/flutter-sdk';
const resolver = runtime === 'minimum' ? join(root, '.dart_tool/presend-review-min-package') : join(root, 'packages/handrail_ai_widgets');
const temp = mkdtempSync(join(root, '.dart_tool/widget-compatibility-'));
const widgets = join(temp, 'widgets'), client = join(temp, 'client');
for (const [name, dest] of [['handrail_ai_widgets', widgets], ['handrail_ai_client', client]]) {
  mkdirSync(join(dest, '.dart_tool'), { recursive: true });
  cpSync(name === 'handrail_ai_widgets' && process.env.HANDRAIL_COMPAT_WIDGET_SOURCE || join(root, 'packages', name, 'lib'), join(dest, 'lib'), { recursive: true });
  cpSync(join(root, 'packages', name, 'pubspec.yaml'), join(dest, 'pubspec.yaml'));
}
cpSync(join(resolver, 'pubspec.lock'), join(widgets, 'pubspec.lock'));
cpSync(join(resolver, '.dart_tool/package_graph.json'), join(widgets, '.dart_tool/package_graph.json'));
const configFile = join(resolver, '.dart_tool/package_config.json');
const config = JSON.parse(readFileSync(configFile));
for (const p of config.packages) p.rootUri = new URL(p.rootUri, pathToFileURL(configFile)).href;
const clientConfigFile = join(root, 'packages/handrail_ai_client/.dart_tool/package_config.json');
const clientConfig = JSON.parse(readFileSync(clientConfigFile));
for (const name of ['http', 'http_parser', 'crypto']) {
  if (!config.packages.some(p => p.name === name)) {
    const p = clientConfig.packages.find(p => p.name === name);
    config.packages.push({ ...p, rootUri: new URL(p.rootUri, pathToFileURL(clientConfigFile)).href });
  }
}
config.packages = config.packages.filter(p => !['handrail_ai_client', 'handrail_ai_widgets'].includes(p.name));
config.packages.push({ name: 'handrail_ai_client', rootUri: pathToFileURL(client + '/').href, packageUri: 'lib/', languageVersion: '3.4' },
  { name: 'handrail_ai_widgets', rootUri: pathToFileURL(widgets + '/').href, packageUri: 'lib/', languageVersion: '3.10' });
for (const name of ['flutter', 'flutter_test', 'sky_engine']) {
  if (!config.packages.find(p => p.name === name).rootUri.startsWith(pathToFileURL(sdk + '/').href)) throw Error(`Mixed SDK: ${name}`);
}
const packages = join(widgets, '.dart_tool/package_config.json');
writeFileSync(packages, JSON.stringify(config));
writeFileSync(join(client, '.dart_tool/package_config.json'), JSON.stringify(config));
const requestedTests = process.argv.slice(5);
const tests = requestedTests.length ? requestedTests : [
  'packages/handrail_ai_widgets/test/transcript_visibility_test.dart',
  'packages/handrail_ai_widgets/test/conversation_transcript_test.dart',
  'packages/handrail_ai_widgets/test/display_transcript_test.dart',
  'packages/handrail_ai_widgets/test/composer_test.dart',
  'packages/handrail_ai_widgets/test/draft_controller_test.dart',
  'packages/handrail_ai_widgets/test/composer_drafts_test.dart',
  'packages/handrail_ai_widgets/test/assistant_workspace_test.dart',
  'tool/terminal_pending_test.dart', 'tool/transcript_retry_test.dart',
];
const args = mode === 'analyze' ? ['analyze', '--fatal-infos', 'lib'] : [
  join(sdk, 'bin/cache/flutter_tools.snapshot'), '--no-version-check', '--suppress-analytics',
  '--packages', packages, 'test', '--no-pub', '--concurrency=1', '--reporter=expanded',
  ...tests.map(p => join(root, p))];
const env = { ...process.env, FLUTTER_ROOT: sdk, FLUTTER_ALREADY_LOCKED: 'true', CI: 'true',
  HANDRAIL_TEST_JS_SDK_DIST: resolve(root, '../handrail-sdk-ai-assistant-js/dist') };
if (runtime === 'minimum') env.PUB_CACHE = join(root, '.dart_tool/presend-review-pub-cache');
const start = Date.now();
const result = spawnSync(join(sdk, 'bin/cache/dart-sdk/bin/dart'), args,
  { cwd: mode === 'analyze' ? widgets : join(root, 'packages/handrail_ai_widgets'), env, encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024 });
writeFileSync(join(evidence, `${label}.log`), result.stdout + result.stderr);
writeFileSync(join(evidence, `${label}.json`), JSON.stringify({runtime, mode, sdk, temp, args, elapsedMs: Date.now() - start,
  status: result.status, signal: result.signal, error: result.error?.message ?? null}, null, 2) + '\n');
console.log(JSON.stringify({ label, status: result.status, seconds: (Date.now() - start) / 1000, log: join(evidence, `${label}.log`) }));
process.exitCode = result.status ?? 1;
