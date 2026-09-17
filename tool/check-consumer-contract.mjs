// Qualify consumer integration sources with Flutter's frontend compiler. The
// temporary compiler package map is not an installation or dependency upgrade.
// Consumer pubspecs, Git pins, lockfiles and .dart_tool files remain untouched.
import { mkdtempSync, readFileSync, writeFileSync, rmSync, copyFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';

const [flutter, project, ...entries] = process.argv.slice(2);
const tests = entries[0] === '--test';
if (tests) entries.shift();
if (!flutter || !project || !entries.length) throw new Error(
  'Usage: node tool/check-consumer-contract.mjs FLUTTER_ROOT PROJECT_ROOT ENTRY [ENTRY ...]');
const sdkRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const projectRoot = resolve(project), flutterRoot = resolve(flutter);
const configPath = resolve(projectRoot, '.dart_tool/package_config.json');
const config = JSON.parse(readFileSync(configPath, 'utf8'));
for (const entry of config.packages) entry.rootUri = new URL(entry.rootUri, pathToFileURL(configPath)).href;
const consumerPackage = config.packages.find(entry => entry.rootUri.startsWith('file:') && resolve(fileURLToPath(entry.rootUri)) === projectRoot);
if (!consumerPackage) throw new Error('Consumer package identity is missing from its existing package configuration.');
for (const name of ['handrail_ai_client', 'handrail_ai_widgets']) {
  const root = resolve(sdkRoot, 'packages', name);
  const own = JSON.parse(readFileSync(join(root, '.dart_tool/package_config.json'), 'utf8'))
    .packages.find(entry => entry.name === name);
  if (!own || !config.packages.some(entry => entry.name === name)) throw new Error(`Missing installed package: ${name}`);
  config.packages = config.packages.map(entry => entry.name === name
    ? { ...own, rootUri: pathToFileURL(`${root}/`).href } : entry);
}
const temporary = mkdtempSync(join(tmpdir(), 'handrail-consumer-contract-'));
const started = performance.now();
try {
  mkdirSync(join(temporary, '.dart_tool'));
  const packages = join(temporary, '.dart_tool/package_config.json'), input = join(temporary, 'main.dart');
  writeFileSync(packages, JSON.stringify(config));
  if (tests) {
    copyFileSync(resolve(projectRoot, '.dart_tool/package_graph.json'), join(temporary, '.dart_tool/package_graph.json'));
    copyFileSync(resolve(projectRoot, 'pubspec.yaml'), join(temporary, 'pubspec.yaml'));
  }
  writeFileSync(input, entries.map(entry => `import '${entry.startsWith('lib/')
    ? `package:${consumerPackage.name}/${entry.slice(4)}` : pathToFileURL(resolve(projectRoot, entry)).href}';`).join('\n') + '\nvoid main() {}\n');
  const result = spawnSync(tests ? join(flutterRoot, 'bin/flutter') : join(flutterRoot, 'bin/cache/dart-sdk/bin/dartaotruntime'), tests
    ? ['--packages', packages, 'test', '--no-pub', '--concurrency=1', '--dart-define=HANDRAIL_TEST_LOCAL_SDK=true',
      ...(process.env.HANDRAIL_TEST_VM_SERVICE === '1' ? ['--enable-vmservice'] : []), ...entries] : [
    join(flutterRoot, 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'),
    '--sdk-root', join(flutterRoot, 'bin/cache/artifacts/engine/common/flutter_patched_sdk/'),
    '--target=flutter', '--packages', packages, '--output-dill', join(temporary, 'consumer.dill'),
    '--no-embed-source-text', '--no-print-incremental-dependencies', input,
  ], { cwd: projectRoot, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.stdout) process.stderr.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  process.stdout.write(`${JSON.stringify({ projectRoot, roots: entries,
    qualification: `local Flutter ${tests ? 'tests' : 'frontend source compile'}; installed Git dependencies unchanged`,
    exitCode: result.status, milliseconds: Math.round(performance.now() - started) }, null, 2)}\n`);
  if (result.status !== 0) process.exitCode = result.status ?? 1;
} finally { rmSync(temporary, { recursive: true, force: true }); }
