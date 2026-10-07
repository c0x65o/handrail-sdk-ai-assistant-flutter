// The original test uses an exact FilledButton runtime-type finder. Flutter
// 3.38.1's tonalIcon factory returns a FilledButton subclass; 3.41.7 returns the
// base class. Qualify identical assertions using a subtype-aware finder, without
// changing the preserved original fixture or any production behavior.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const [runtime] = process.argv.slice(2);
if (!['minimum', 'current'].includes(runtime)) throw Error('Expected minimum|current');
const original = readFileSync(join(root, 'tool/display_polling_test.dart'), 'utf8');
const pattern = /find\.widgetWithText\(\s*FilledButton,\s*'Jump to latest',?\s*\)/g;
const matches = [...original.matchAll(pattern)].length;
if (matches !== 5) throw Error(`Unexpected finder count: ${matches}`);
const adapted = original.replace(pattern,
  "find.ancestor(of: find.text('Jump to latest'), matching: find.byWidgetPredicate((widget) => widget is FilledButton))");
const temp = mkdtempSync(join(root, '.dart_tool/widget-compatibility-polling-'));
const test = join(temp, 'display_polling_supported_test.dart');
writeFileSync(test, adapted);
const sha = value => createHash('sha256').update(value).digest('hex');
writeFileSync(join(evidence, `${runtime}-polling-adapter.json`), JSON.stringify({original: 'tool/display_polling_test.dart',
  originalSha256: sha(original), adaptedSha256: sha(adapted), replacements: matches, test}, null, 2) + '\n');
const result = spawnSync(process.execPath, [join(evidence, 'run-check.mjs'), runtime, 'test', `${runtime}-polling-supported`, test],
  {cwd: root, stdio: 'inherit', timeout: 245000});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
