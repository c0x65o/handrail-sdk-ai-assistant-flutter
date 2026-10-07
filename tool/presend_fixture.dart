// Synthetic-only HTTP recorder. Never attach this body/stack recorder to a host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;

Map<String, Object?> traceRequest() => {
  'protocol_version': 'handrail.ai-runtime.v1',
  'continuation_of': null,
  'tools': [],
  'tool_results': [],
  'generation': {'max_output_tokens': 100, 'temperature': 0},
  'correlation_hints': {},
  'messages': [
    {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Synthetic send'},
      ],
    },
  ],
};

class PresendServer {
  late Process process;
  late Uri origin;
  final errors = StringBuffer();
  Future<void> start() async {
    if (Platform.environment['HANDRAIL_TEST_JS_SDK_DIST'] == null) {
      throw StateError(
        'Set HANDRAIL_TEST_JS_SDK_DIST to the reviewed JS dist (PGlite required).',
      );
    }
    process = await Process.start(
      'node',
      ['../../tool/gateway/gateway.mjs'],
      environment: {'HANDRAIL_TEST_PRESEND_TRACE': '1'},
    );
    process.stderr.transform(utf8.decoder).listen(errors.write);
    origin = Uri.parse(
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20)),
    );
  }

  Future<Map<String, dynamic>> command(
    String path, [
    Object body = const {},
  ]) async {
    final response = await http.post(
      origin.resolve('/test/$path'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200)
      throw StateError('Fixture command failed: $path');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> close() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 20));
    if (errors.isNotEmpty) throw StateError(errors.toString());
  }
}

class PresendTrace extends http.BaseClient {
  PresendTrace(this.label);
  final String label;
  final delegate = http.Client();
  final clock = Stopwatch()..start();
  final rows = <Map<String, Object?>>[];
  final inFlight = <int>{};
  String phase = 'open';
  HandrailConversationSession? Function()? session;
  Future<void> Function(Map<String, Object?>)? beforeRequest;
  Completer<void>? holdControl;
  bool snapshotFallback = false;
  final controlEntered = Completer<void>();
  int nextId = 0;
  void mark(String event, [Map<String, Object?> data = const {}]) => rows.add({
    'session': label,
    'event': event,
    'us': clock.elapsedMicroseconds,
    'phase': phase,
    ...data,
  });
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host != '127.0.0.1') {
      throw StateError('Trace fixture permits loopback HTTP only');
    }
    final body = request is http.Request && request.body.isNotEmpty
        ? jsonDecode(request.body) as Map<String, dynamic>
        : <String, dynamic>{};
    final refresh = Zone.current[#presendRefresh] as Map<String, Object?>?;
    final stack = refresh?['stack'] as String? ?? StackTrace.current.toString();
    final id = ++nextId;
    final current = session?.call();
    final row = <String, Object?>{
      'event': 'http',
      'session': label,
      'id': id,
      'phase': phase,
      'startUs': clock.elapsedMicroseconds,
      'inFlightAtStart': inFlight.toList(),
      'path': request.url.path,
      'request': body,
      'localCanonicalRevision': current?.document?.revision,
      'submitting': current?.isSubmitting,
      'refreshContext': refresh,
      'caller': stack.contains('prepareTurn')
          ? 'prepareTurn'
          : stack.contains('_submitTurn')
          ? '_submitTurn'
          : 'other (see stack)',
      'stack': stack,
    };
    rows.add(row);
    inFlight.add(id);
    try {
      await beforeRequest?.call(row);
      if (body['operation'] == 'control' && holdControl != null) {
        if (!controlEntered.isCompleted) controlEntered.complete();
        await holdControl!.future;
      }
      final response = await delegate.send(request);
      row['status'] = response.statusCode;
      // Do not buffer SSE: headers acknowledge transport; the stream remains live.
      if (response.headers['content-type']?.contains('text/event-stream') ==
          true) {
        row['headersUs'] = clock.elapsedMicroseconds;
        return response;
      }
      var bytes = await response.stream.toBytes();
      if (snapshotFallback && request.url.path.endsWith('/capabilities')) {
        final envelope = jsonDecode(utf8.decode(bytes)) as Map;
        (envelope['value'] as Map).remove('displayHistory');
        bytes = utf8.encode(jsonEncode(envelope));
      }
      if (bytes.isNotEmpty) {
        final envelope = jsonDecode(utf8.decode(bytes)) as Map;
        final value = envelope['value'];
        if (value is Map) {
          row['response'] = {
            for (final key in [
              'status',
              'revision',
              'canonicalRevision',
              'generation',
              'throughRevision',
              'nextCursor',
              'activeTurnId',
              'acknowledgements',
              'latestTurn',
              'requestedTurn',
            ])
              if (value.containsKey(key)) key: value[key],
            if (value['records'] is List)
              'recordCount': (value['records'] as List).length,
          };
        }
        if (envelope['error'] is Map)
          row['errorCode'] = (envelope['error'] as Map)['code'];
      }
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
        request: response.request,
      );
    } catch (error) {
      row['transportErrorType'] = error.runtimeType.toString();
      rethrow;
    } finally {
      row['endUs'] = clock.elapsedMicroseconds;
      inFlight.remove(id);
    }
  }

  List<Map<String, Object?>> get reads => rows
      .where(
        (r) =>
            r['event'] == 'http' &&
            r['phase'] == 'send' &&
            ['control', 'changes'].contains((r['request'] as Map)['operation']),
      )
      .toList();
  List<Map<String, Object?>> get admissions => rows
      .where(
        (r) =>
            r['event'] == 'http' &&
            (r['request'] as Map)['operation'] == 'append_mutations',
      )
      .toList();
  void save(String directory) {
    Directory(directory).createSync(recursive: true);
    File(
      '$directory/$label.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rows));
  }

  @override
  void close() => delegate.close();
}

class PresendFixture {
  PresendFixture(this.server, String label, {String? loss})
    : trace = PresendTrace(label) {
    api = HandrailAiClient(
      baseUri: server.origin.resolve('/api/ai'),
      httpClient: trace,
      protectedHeaders: () => {
        if (loss != null) 'x-test-lose-response': '$label:$loss',
      },
    );
    trace.session = () => controller.session;
  }
  final PresendServer server;
  final PresendTrace trace;
  late HandrailAiClient api;
  late String id;
  final storage = <String, String>{};
  Future<void> Function()? afterRetain;
  late final store = HandrailKeyValuePendingTurnStore(
    namespace: trace.label,
    read: (key) async => storage[key],
    write: (key, value) async {
      storage[key] = value;
      if (key.startsWith('handrail.pending.')) {
        trace.mark('retained', {'submission': jsonDecode(value)});
        await afterRetain?.call();
      }
    },
    delete: (key) async {
      storage.remove(key);
    },
  );
  late final controller = HandrailAssistantController(
    client: api,
    pendingStore: store,
    autoCreate: false,
    pollingInterval: null,
    voicePollingInterval: null,
  );
  Future<void> open() async {
    final created = await api.createConversation({
      'idempotencyKey': trace.label,
    });
    id =
        ((created['value'] as Map)['descriptor'] as Map)['conversationId']
            as String;
    await runTrace(() => controller.openConversation(id));
    trace.mark('ready', {'conversationId': id});
    trace.phase = 'send';
  }

  Future<T> runTrace<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {#presendTrace: trace.mark});
  Future<HandrailTurnSubmission?> send() => runTrace(
    () => controller.sendMessage(
      traceRequest(),
      operationId: 'op-${trace.label}',
      onAccepted: (_) => trace.mark('accepted'),
    ),
  );
  Future<void> close(String directory) async {
    await controller.dispose();
    api.close();
    trace.save(directory);
  }
}
