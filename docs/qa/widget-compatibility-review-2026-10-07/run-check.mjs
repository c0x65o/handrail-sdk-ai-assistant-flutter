// Isolated source qualification. Never writes prior review evidence or SDK files.
import { existsSync, cpSync, readFileSync, writeFileSync, mkdirSync, mkdtempSync, symlinkSync, openSync, closeSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const [runtime, mode, label = `${runtime}-${mode}`] = process.argv.slice(2);
if (!['minimum', 'current'].includes(runtime) || !['analyze', 'test'].includes(mode)) throw Error('Expected minimum|current analyze|test [unique-label]');
if (existsSync(join(evidence, `${label}.log`)) || existsSync(join(evidence, `${label}.json`))) throw Error('Choose a new label; existing evidence is immutable');
const sdk = runtime === 'minimum' ? join(root, '.dart_tool/presend-review-flutter-supported/flutter') : '/opt/handrail/.handrail/flutter-sdk';
const resolver = runtime === 'minimum' ? join(root, '.dart_tool/presend-review-min-package') : join(root, 'packages/handrail_ai_widgets');
const temp = mkdtempSync(join(root, '.dart_tool/widget-compatibility-'));
const widgets = join(temp, 'packages/handrail_ai_widgets'), client = join(temp, 'packages/handrail_ai_client');
for (const [name, dest] of [['handrail_ai_widgets', widgets], ['handrail_ai_client', client]]) {
  mkdirSync(join(dest, '.dart_tool'), { recursive: true });
  cpSync(name === 'handrail_ai_widgets' && process.env.HANDRAIL_COMPAT_WIDGET_SOURCE || join(root, 'packages', name, 'lib'), join(dest, 'lib'), { recursive: true });
  cpSync(join(root, 'packages', name, 'pubspec.yaml'), join(dest, 'pubspec.yaml'));
}
cpSync(join(resolver, 'pubspec.lock'), join(widgets, 'pubspec.lock'));
cpSync(join(resolver, '.dart_tool/package_graph.json'), join(widgets, '.dart_tool/package_graph.json'));
mkdirSync(join(temp, 'tool'));
symlinkSync(join(root, 'tool/gateway'), join(temp, 'tool/gateway'));
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
  ...tests.map(p => resolve(root, p))];
const env = { ...process.env, FLUTTER_ROOT: sdk, FLUTTER_ALREADY_LOCKED: 'true', CI: 'true',
  HANDRAIL_TEST_JS_SDK_DIST: resolve(root, '../handrail-sdk-ai-assistant-js/dist') };
if (runtime === 'minimum') env.PUB_CACHE = join(root, '.dart_tool/presend-review-pub-cache');
const start = Date.now();
const log = openSync(join(evidence, `${label}.log`), 'wx');
writeFileSync(join(evidence, `${label}-invocation.json`), JSON.stringify({ runtime, mode, sdk, temp, args }, null, 2) + '\n');
const result = spawnSync(join(sdk, 'bin/cache/dart-sdk/bin/dart'), args,
  { cwd: widgets, env, stdio: ['ignore', log, log], timeout: 230000, killSignal: 'SIGKILL' });
closeSync(log);
writeFileSync(join(evidence, `${label}.json`), JSON.stringify({runtime, mode, sdk, temp, args, elapsedMs: Date.now() - start,
  status: result.status, signal: result.signal, error: result.error?.message ?? null}, null, 2) + '\n');
console.log(JSON.stringify({ label, status: result.status, seconds: (Date.now() - start) / 1000, log: join(evidence, `${label}.log`) }));
process.exitCode = result.status ?? 1;
