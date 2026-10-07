// Instrument a disposable source copy; installed packages, locks and lib stay intact.
import { cpSync, readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const [flutter, mode = 'client'] = process.argv.slice(2);
if (!flutter || !['client', 'composer', 'analyze'].includes(mode)) throw Error('Usage: node tool/run-presend-trace.mjs FLUTTER_ROOT [client|composer|analyze]');
mkdirSync(join(root, '.dart_tool'), { recursive: true });
const temp = mkdtempSync(join(root, '.dart_tool/presend-'));
try {
  const client = join(root, 'packages/handrail_ai_client');
  cpSync(join(client, 'lib'), join(temp, 'lib'), { recursive: true });
  cpSync(join(client, 'pubspec.yaml'), join(temp, 'pubspec.yaml'));
  const session = join(temp, 'lib/src/session.dart');
  let source = readFileSync(session, 'utf8');
  const replaceOnce = (from, to) => {
    if (source.split(from).length !== 2) throw Error(`Instrumentation anchor changed: ${from}`);
    source = source.replace(from, to);
  };
  replaceOnce('Future<void> refresh({bool automatic = false}) {', `Future<void> refresh({bool automatic = false}) {
    _presendMark('refresh-request', {'sessionInstance': identityHashCode(this),
      'automatic': automatic, 'inFlightRefresh': _refreshing != null,
      'inFlightSubmit': _submitting != null, 'preparingSend': _preparingSend,
      'canonicalRevision': _document?.revision, 'stack': StackTrace.current.toString()});`);
  replaceOnce('_refresh().whenComplete(() {', '_presendRefresh(this, () => _refresh()).whenComplete(() {');
  replaceOnce('_preparingSend = true;', `_presendMark('send-begin', {'sessionInstance': identityHashCode(this),
      'operationId': operationId, 'stack': StackTrace.current.toString()});
    _preparingSend = true;`);
  replaceOnce('final submitting = _submitting = _submitTurn(submission,', `_presendMark('submit-begin', {'sessionInstance': identityHashCode(this),
      'turnId': submission.turnId, 'stack': StackTrace.current.toString()});
    final submitting = _submitting = _submitTurn(submission,`);
  writeFileSync(session, source);
  const library = join(temp, 'lib/handrail_ai_client.dart');
  writeFileSync(library, readFileSync(library, 'utf8') + `
// Disposable fixture instrumentation only; no runtime source modifications.
void _presendMark(String event, Map<String, Object?> data) {
  final callback = Zone.current[#presendTrace];
  if (callback is void Function(String, Map<String, Object?>)) callback(event, data);
}
Future<void> _presendRefresh(HandrailConversationSession session, Future<void> Function() read) {
  final stack = StackTrace.current.toString();
  final reason = stack.contains('prepareTurn') ? 'prepareTurn' :
    stack.contains('_submitTurn') ? '_submitTurn' : 'other';
  final data = <String, Object?>{'sessionInstance': identityHashCode(session),
    'reason': reason, 'stack': stack, 'localCanonicalRevision': session.document?.revision,
    'inFlightSubmit': session._submitting != null, 'preparingSend': session._preparingSend};
  _presendMark('refresh-start', data);
  return runZoned(() async {
    try { await read(); }
    finally { _presendMark('refresh-end', {'sessionInstance': identityHashCode(session),
      'reason': reason, 'canonicalRevision': session.document?.revision}); }
  }, zoneValues: {#presendRefresh: data});
}
`);
  const directory = join(root, mode === 'composer' ? 'packages/handrail_ai_widgets' : 'packages/handrail_ai_client');
  const configFile = join(directory, '.dart_tool/package_config.json');
  const config = JSON.parse(readFileSync(configFile));
  const clientConfigPath = join(client, '.dart_tool/package_config.json');
  const clientConfig = JSON.parse(readFileSync(clientConfigPath));
  for (const name of ['handrail_ai_client', 'http', 'http_parser', 'crypto']) {
    if (!config.packages.some(entry => entry.name === name)) {
      const entry = clientConfig.packages.find(entry => entry.name === name);
      if (!entry) throw Error(`Missing prepared package: ${name}`);
      config.packages.push({ ...entry, rootUri: new URL(entry.rootUri, pathToFileURL(clientConfigPath)).href });
    }
  }
  for (const entry of config.packages) {
    entry.rootUri = entry.name === 'handrail_ai_client' ? pathToFileURL(temp + '/').href :
      new URL(entry.rootUri, pathToFileURL(configFile)).href;
  }
  mkdirSync(join(temp, '.dart_tool'));
  cpSync(join(directory, '.dart_tool/package_graph.json'), join(temp, '.dart_tool/package_graph.json'));
  if (mode === 'composer') cpSync(join(directory, 'pubspec.yaml'), join(temp, 'pubspec.yaml'));
  const configPath = join(temp, '.dart_tool/package_config.json');
  writeFileSync(configPath, JSON.stringify(config));
  const dart = join(resolve(flutter), 'bin/cache/dart-sdk/bin/dart');
  let args;
  if (mode === 'composer') {
    args = [join(resolve(flutter), 'bin/cache/flutter_tools.snapshot'), '--no-version-check',
      '--packages', configPath, 'test', '--no-pub', '--concurrency=1', join(root, 'tool/presend_composer_test.dart')];
  } else if (mode === 'analyze') {
    for (const file of ['presend_client_test.dart', 'presend_fixture.dart']) cpSync(join(root, 'tool', file), join(temp, file));
    args = ['analyze', '--fatal-infos', temp];
  } else {
    args = ['--packages=' + configPath, 'run', 'test', '--concurrency=1', join(root, 'tool/presend_client_test.dart'), '--reporter', 'expanded'];
  }
  const result = spawnSync(dart, args, { cwd: directory, stdio: 'inherit', timeout: 230000, killSignal: 'SIGKILL' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally { rmSync(temp, { recursive: true, force: true }); }
