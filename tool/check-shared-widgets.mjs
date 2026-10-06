// Compile/test both local packages without changing any dependency pins or locks.
// Requires the package configs produced by make setup and a prepared Flutter SDK.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const [flutter, ...tests] = process.argv.slice(2);
if (!flutter) throw new Error('Usage: node tool/check-shared-widgets.mjs FLUTTER_ROOT [TEST ...]');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const widgets = join(root, 'packages/handrail_ai_widgets');
const config = packageConfig(widgets);
const client = packageConfig(join(root, 'packages/handrail_ai_client'));
// The widgets resolver owns Flutter/test versions; only add client runtime deps.
for (const name of ['handrail_ai_client', 'http', 'http_parser', 'crypto']) {
  if (!config.packages.some(entry => entry.name === name)) {
    const entry = client.packages.find(entry => entry.name === name);
    if (!entry) throw new Error(`Missing package ${name}; run make setup first`);
    config.packages.push(entry);
  }
}
mkdirSync(join(root, '.dart_tool'), { recursive: true });
const temporary = mkdtempSync(join(root, '.dart_tool/shared-widgets-'));
try {
  mkdirSync(join(temporary, '.dart_tool'));
  const packages = join(temporary, '.dart_tool/package_config.json');
  writeFileSync(packages, JSON.stringify(config));
  for (const path of ['pubspec.yaml', '.dart_tool/package_graph.json']) {
    writeFileSync(join(temporary, path), readFileSync(join(widgets, path)));
  }
  const result = spawnSync(join(resolve(flutter), 'bin/cache/dart-sdk/bin/dart'), [
    join(resolve(flutter), 'bin/cache/flutter_tools.snapshot'), '--no-version-check',
    '--packages', packages, 'test', '--no-pub', '--concurrency=1',
    ...(tests.length ? tests : ['tool/history_restoration_test.dart', 'tool/display_polling_test.dart', 'tool/reentrant_assistant_test.dart', 'tool/phone_latest_position_test.dart', 'tool/terminal_pending_test.dart'])
      .map(path => resolve(root, path)),
  ], { cwd: widgets, stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
function packageConfig(directory) {
  const path = join(directory, '.dart_tool/package_config.json');
  const value = JSON.parse(readFileSync(path, 'utf8'));
  for (const entry of value.packages) entry.rootUri = new URL(entry.rootUri, pathToFileURL(path)).href;
  return value;
}
