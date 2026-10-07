// Bounded review harness. Uses the repository's existing disposable PostgreSQL
// pattern and locked pg driver. Never accepts a host/database URL from callers.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, cpSync, existsSync, rmSync } from 'node:fs';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { randomBytes, createHash } from 'node:crypto';
import { spawnSync, execFileSync } from 'node:child_process';
import net from 'node:net';

const evidence = dirname(fileURLToPath(import.meta.url));
const root = resolve(evidence, '../../..');
const js = resolve(root, '../handrail-sdk-ai-assistant-js');
const pg = createRequire(join(js, 'test/fixtures/agent-cancellation/package.json'))('pg');
const baseline = process.argv.includes('--baseline');
const minimumDart = process.argv.includes('--dart34');
const toolchain = minimumDart ? join(root, '.dart_tool/presend-minimum/dart-sdk/bin/dart') : '/opt/handrail/.handrail/flutter-sdk/bin/cache/dart-sdk/bin/dart';
const label = minimumDart ? 'native-dart34' : baseline ? 'native-baseline' : 'native-candidate';
const output = join(evidence, label);
mkdirSync(output, { recursive: true });
const temp = mkdtempSync(join(root, '.dart_tool/independent-review-'));
const bin = '/usr/lib/postgresql/15/bin';
const password = randomBytes(24).toString('hex');
let started = false;
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 240000, ...options });
  if (result.error || result.status !== 0) throw Error(`Review command failed: ${command} (${result.status})\n${result.stderr || ''}`);
  return result;
};
try {
  const socket = net.createServer();
  await new Promise((ok, fail) => { socket.once('error', fail); socket.listen(0, '127.0.0.1', ok); });
  const port = socket.address().port;
  await new Promise(ok => socket.close(ok));
  writeFileSync(join(temp, 'pw'), password, { mode: 0o600 });
  run(`${bin}/initdb`, ['-D', join(temp, 'data'), '-U', 'fixture_admin', '--pwfile', join(temp, 'pw'), '--auth=scram-sha-256', '--no-locale', '-E', 'UTF8']);
  run(`${bin}/pg_ctl`, ['-D', join(temp, 'data'), '-l', join(temp, 'postgres.log'), '-o', `-h 127.0.0.1 -p ${port} -c unix_socket_directories=''`, '-w', 'start']);
  started = true;
  const admin = new pg.Client({ host: '127.0.0.1', port, user: 'fixture_admin', password, database: 'postgres' });
  await admin.connect();
  try {
    await admin.query(`CREATE ROLE fixture_role LOGIN PASSWORD '${password}'`);
    await admin.query('CREATE DATABASE sdk_disposable OWNER fixture_role');
    const version = (await admin.query('SELECT version()')).rows[0];
    writeFileSync(join(output, 'database.json'), JSON.stringify({ ...version, isolated: true, role: 'fixture_role', superuser: false }, null, 2));
  } finally { await admin.end(); }

  // Replace only the fixture persistence adapter. Public JS gateway/provider,
  // production Dart source, assertions and wire protocol remain unchanged.
  let gateway = readFileSync(join(root, 'tool/gateway/gateway.mjs'), 'utf8');
  const begin = gateway.indexOf('  // Source qualification uses');
  const end = gateway.indexOf('  await persistence.persistence.migrate();', begin);
  if (begin < 0 || end < 0) throw Error('Gateway fixture anchors changed');
  gateway = gateway.slice(0, begin) + `
  const pg = createRequire(${JSON.stringify(join(js, 'test/fixtures/agent-cancellation/package.json'))})('pg');
  const { postgres } = await import(pathToFileURL(resolve(dist, 'postgres/index.js')).href);
  const pool = new pg.Pool({ connectionString: process.env.REVIEW_OWNED_POSTGRES_URL, max: 4 });
  database = { close: () => pool.end() };
  persistence = postgres(pool, { attachmentLimits: persistence.attachmentLimits });
` + gateway.slice(end);
  writeFileSync(join(output, 'gateway.mjs'), gateway);
  const gatewayPath = join(output, 'gateway.mjs');
  let fixture = readFileSync(join(root, 'tool/presend_fixture.dart'), 'utf8');
  fixture = fixture.replace("'../../tool/gateway/gateway.mjs'", JSON.stringify(gatewayPath));
  writeFileSync(join(temp, 'fixture.dart'), fixture);
  cpSync(join(evidence, 'public_review_test.dart'), join(temp, 'public_review_test.dart'));
  const configFile = join(root, minimumDart ? '.dart_tool/presend-minimum/client/.dart_tool/package_config.json' : 'packages/handrail_ai_client/.dart_tool/package_config.json');
  const config = JSON.parse(readFileSync(configFile));
  for (const entry of config.packages) entry.rootUri = new URL(entry.rootUri, pathToFileURL(configFile)).href;
  config.packages.find(p => p.name === 'handrail_ai_client').rootUri = pathToFileURL(join(root, 'packages/handrail_ai_client/')).href;
  if (baseline) {
    const sha = '5cf833d0bb9d9dd001e697947f9f3e4945b17d20';
    const prefix = 'packages/handrail_ai_client/';
    for (const path of execFileSync('git', ['ls-tree', '-r', '--name-only', sha, prefix + 'lib'], { cwd: root, encoding: 'utf8' }).trim().split('\n')) {
      const target = join(temp, 'baseline', path.slice(prefix.length));
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, execFileSync('git', ['show', `${sha}:${path}`], { cwd: root }));
    }
    config.packages.find(p => p.name === 'handrail_ai_client').rootUri = pathToFileURL(join(temp, 'baseline/')).href;
  }
  writeFileSync(join(temp, 'packages.json'), JSON.stringify(config));
  const testRoot = config.packages.find(p => p.name === 'test').rootUri.replace(/\/?$/, '/');
  const env = { ...process.env, HANDRAIL_TEST_JS_SDK_DIST: join(js, 'dist'),
    REVIEW_OWNED_POSTGRES_URL: `postgresql://fixture_role:${password}@127.0.0.1:${port}/sdk_disposable?sslmode=disable`,
    HANDRAIL_PRESEND_EVIDENCE: output, REVIEW_BASELINE: baseline ? '1' : '0' };
  for (const key of Object.keys(env)) if (key.startsWith('PG') || key === 'DATABASE_URL' || key === 'NODE_PG_FORCE_NATIVE') delete env[key];
  console.log(`${label}: fresh native PostgreSQL cluster, dedicated non-superuser role; uninstrumented Dart source; loopback gateway; fixture provider only.`);
  run(toolchain, ['--packages=' + join(temp, 'packages.json'), fileURLToPath(new URL('bin/test.dart', testRoot)),
    '--concurrency=1', '--reporter=expanded', join(temp, 'public_review_test.dart')],
    { cwd: join(root, 'packages/handrail_ai_client'), env, stdio: 'inherit' });
} catch (error) {
  console.error(String(error).replaceAll(password, '[withheld]'));
  process.exitCode = 1;
} finally {
  let stopped = true;
  if (started || existsSync(join(temp, 'data/postmaster.pid'))) {
    const result = spawnSync(`${bin}/pg_ctl`, ['-D', join(temp, 'data'), '-m', 'fast', '-w', 'stop'], { encoding: 'utf8', timeout: 20000 });
    stopped = result.status === 0;
    console.log(`Owned native PostgreSQL stopped: ${stopped}`);
    if (!stopped) process.exitCode = 1;
  }
  if (existsSync(join(temp, 'postgres.log'))) cpSync(join(temp, 'postgres.log'), join(output, 'postgres.log'));
  if (stopped) rmSync(temp, { recursive: true, force: true });
}
