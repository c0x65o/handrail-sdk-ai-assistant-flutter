// Reuse the producer's unchanged instrumentation, with an isolated SDK map and
// a new evidence destination. This is the diagnostic's required runner.
import { existsSync, readFileSync, writeFileSync, mkdtempSync, cpSync, mkdirSync, symlinkSync, openSync, closeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const [runtime, label = `${runtime}-composer`] = process.argv.slice(2);
if (!['minimum', 'current'].includes(runtime)) throw Error('Expected minimum|current');
if (existsSync(join(evidence, `${label}.log`)) || existsSync(join(evidence, `${label}.json`))) throw Error('Choose a new label; existing evidence is immutable');
const sdk = runtime === 'minimum' ? join(root, '.dart_tool/presend-review-flutter-supported/flutter') : '/opt/handrail/.handrail/flutter-sdk';
const resolver = runtime === 'minimum' ? join(root, '.dart_tool/presend-review-min-package') : join(root, 'packages/handrail_ai_widgets');
const temp = mkdtempSync(join(root, '.dart_tool/widget-compatibility-composer-'));
const widgets = join(temp, 'packages/handrail_ai_widgets');
mkdirSync(join(widgets, '.dart_tool'), {recursive: true});
cpSync(join(root, 'packages/handrail_ai_widgets/lib'), join(widgets, 'lib'), {recursive: true});
cpSync(join(root, 'packages/handrail_ai_widgets/pubspec.yaml'), join(widgets, 'pubspec.yaml'));
cpSync(join(resolver, 'pubspec.lock'), join(widgets, 'pubspec.lock'));
cpSync(join(resolver, '.dart_tool/package_graph.json'), join(widgets, '.dart_tool/package_graph.json'));
mkdirSync(join(temp, 'tool'));
symlinkSync(join(root, 'tool/gateway'), join(temp, 'tool/gateway'));
const configFile = join(resolver, '.dart_tool/package_config.json');
const config = JSON.parse(readFileSync(configFile));
for (const p of config.packages) p.rootUri = new URL(p.rootUri, pathToFileURL(configFile)).href;
config.packages.find(p => p.name === 'handrail_ai_widgets').rootUri = pathToFileURL(widgets + '/').href;
for (const name of ['flutter', 'flutter_test', 'sky_engine']) {
  if (!config.packages.find(p => p.name === name).rootUri.startsWith(pathToFileURL(sdk + '/').href)) throw Error(`Mixed SDK: ${name}`);
}
const packages = join(temp, 'package_config.json');
writeFileSync(packages, JSON.stringify(config));
writeFileSync(join(widgets, '.dart_tool/package_config.json'), JSON.stringify(config));
let source = readFileSync(join(root, 'tool/run-presend-trace.mjs'), 'utf8');
const replacements = [
  ["const directory = join(root, mode === 'composer' ? 'packages/handrail_ai_widgets' : 'packages/handrail_ai_client');", `const directory = ${JSON.stringify(widgets)};`],
  ["cpSync(join(directory, '.dart_tool/package_graph.json'), join(temp, '.dart_tool/package_graph.json'));", `cpSync(${JSON.stringify(join(resolver, '.dart_tool/package_graph.json'))}, join(temp, '.dart_tool/package_graph.json'));`],
  ["const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');", `const root = ${JSON.stringify(root)};`],
  ["const configFile = (mode !== 'composer' && process.env.HANDRAIL_PRESEND_CLIENT_CONFIG) || join(directory, '.dart_tool/package_config.json');", `const configFile = ${JSON.stringify(packages)};`],
];
for (const [from, to] of replacements) {
  if (source.split(from).length !== 2) throw Error('Producer runner anchor changed');
  source = source.replace(from, to);
}
const runner = join(temp, 'run-presend-trace.mjs');
writeFileSync(runner, source);
const env = { ...process.env, FLUTTER_ROOT: sdk, FLUTTER_ALREADY_LOCKED: 'true', CI: 'true',
  HANDRAIL_TEST_JS_SDK_DIST: resolve(root, '../handrail-sdk-ai-assistant-js/dist'),
  HANDRAIL_PRESEND_EVIDENCE: join(evidence, label) };
if (runtime === 'minimum') env.PUB_CACHE = join(root, '.dart_tool/presend-review-pub-cache');
const start = Date.now();
const log = openSync(join(evidence, `${label}.log`), 'wx');
const result = spawnSync(process.execPath, [runner, sdk, 'composer'], {cwd: root, env,
  stdio: ['ignore', log, log], timeout: 240000});
closeSync(log);
writeFileSync(join(evidence, `${label}.json`), JSON.stringify({runtime, sdk, temp, elapsedMs: Date.now() - start,
  status: result.status, signal: result.signal, error: result.error?.message ?? null}, null, 2) + '\n');
console.log(JSON.stringify({label, status: result.status, seconds: (Date.now() - start) / 1000}));
process.exitCode = result.status ?? 1;
