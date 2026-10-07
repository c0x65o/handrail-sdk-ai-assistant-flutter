// Independent public-API assertions. The runner supplies fixture.dart and uses
// UNINSTRUMENTED client source, the existing HTTP gateway and native PostgreSQL.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'fixture.dart';

void main() {
  final server = PresendServer();
  final baseline = Platform.environment['REVIEW_BASELINE'] == '1';
  final evidence = Platform.environment['HANDRAIL_PRESEND_EVIDENCE']!;
  setUpAll(server.start);
  tearDownAll(server.close);
  Future<void> waitForProviderEntries() async {
    for (var i = 0; i < 100; i++) {
      final stats = await server.command('stats');
      if (stats['invocations'] >= stats['starts']) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Synthetic provider did not enter after the acknowledged start');
  }
  Future<PresendFixture> open(String name, {bool snapshot = false}) async {
    final f = PresendFixture(server, 'review-$name');
    addTearDown(() async {
      await server.command('trace-auth', {'denied': false});
      await waitForProviderEntries();
      await server.command('finish');
      await f.close(evidence);
    });
    f.trace.snapshotFallback = snapshot;
    await f.open();
    return f;
  }

  List<String> beforeAdmission(PresendFixture f) {
    final id = f.trace.admissions.single['id'] as int;
    return f.trace.reads.where((r) => (r['id'] as int) < id)
        .map((r) => (r['request'] as Map)['operation'] as String).toList();
  }

  Matcher code(String value) => isA<HandrailGatewayException>()
      .having((error) => error.code, 'code', value);

  test('public controller completes once at revision 7 after asynchronous retain', () async {
    final f = await open('success');
    f.afterRetain = () => Future<void>.delayed(const Duration(milliseconds: 30));
    final before = await server.command('stats');
    final sent = (await f.send())!;
    expect(beforeAdmission(f), ['control', 'changes', 'control', if (baseline) 'changes']);
    expect((f.trace.admissions.single['request'] as Map)['input']['expectedRevision'], isNull);
    expect(f.trace.rows.where((r) => r['path'] == '/api/ai/turns/start'), hasLength(1));
    expect(await f.store.load(f.id), isNull);
    // Native SQL lets acknowledgement precede provider entry. Release only
    // after entry; /test/finish is a fixture barrier, not a durable request.
    await waitForProviderEntries();
    await server.command('finish');
    for (var attempt = 0; attempt < 60; attempt++) {
      await f.controller.session!.refresh();
      if (f.controller.document!.latestTurn?['status'] == 'completed') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final doc = f.controller.document!;
    expect(doc.revision, 7);
    expect(doc.latestTurn?['turn_id'], sent.turnId);
    expect(doc.latestTurn?['status'], 'completed');
    expect(doc.messages.map((m) => m['role']), ['user', 'assistant']);
    expect(doc.runtimeState.text, 'Finished once');
    final after = await server.command('stats');
    expect(after['invocations'], before['invocations'] + 1);
    expect(after['admissions'], before['admissions'] + 1);
    f.trace.mark('independent-result', {'revision': doc.revision,
      'messages': doc.messages, 'turn': doc.latestTurn,
      'providerInvocationDelta': after['invocations'] - before['invocations']});
  });

  test('a second public preparation during retain invalidates the send witness', () async {
    final f = await open('another-preparation');
    f.afterRetain = () async {
      await f.controller.session!.prepareTurn(operationId: 'not-submitted',
          clientId: 'independent', request: traceRequest());
    };
    await f.send();
    expect(beforeAdmission(f), ['control', 'changes', 'control', 'changes', 'control', 'changes']);
  });

  test('concurrent refresh joining the second control forces changes', () async {
    final f = await open('concurrent-second-control');
    final entered = Completer<void>(), release = Completer<void>();
    var controls = 0;
    f.trace.beforeRequest = (row) async {
      if ((row['request'] as Map)['operation'] == 'control' && ++controls == 2) {
        entered.complete();
        await release.future;
      }
    };
    final sending = f.send();
    await entered.future;
    final joined = f.controller.session!.refresh();
    release.complete();
    await Future.wait([sending, joined]);
    expect(beforeAdmission(f), ['control', 'changes', 'control', 'changes']);
  });

  test('concurrent send cannot spend another operation witness', () async {
    final f = await open('concurrent-send');
    final retained = Completer<void>(), release = Completer<void>();
    f.afterRetain = () async { retained.complete(); await release.future; };
    final sending = f.send();
    await retained.future;
    await expectLater(f.controller.session!.sendMessage(operationId: 'second',
      clientId: 'independent', request: traceRequest(), pendingStore: f.store), throwsStateError);
    release.complete();
    await sending;
    expect(f.trace.admissions, hasLength(1));
    expect(beforeAdmission(f), ['control', 'changes', 'control', if (baseline) 'changes']);
  });

  test('remote append after fresh control rejects the ORIGINAL nullable CAS', () async {
    final f = await open('stale-cas');
    f.trace.beforeRequest = (row) async {
      if ((row['request'] as Map)['operation'] == 'append_mutations') {
        await server.command('history-seed', {'conversationId': f.id, 'count': 1, 'text': 'Remote'});
      }
    };
    await expectLater(f.send(), throwsA(code('admission_conflict')));
    expect((f.trace.admissions.single['request'] as Map)['input']['expectedRevision'], isNull);
    expect(f.trace.rows.where((r) => r['path'] == '/api/ai/turns/start'), isEmpty);
    expect(await f.store.load(f.id), isNotNull);
  });

  test('authorization revoked while retaining prevents any admission', () async {
    final f = await open('revoked');
    f.afterRetain = () async { await server.command('trace-auth', {'denied': true}); };
    await expectLater(f.send(), throwsA(code('forbidden')));
    expect(f.trace.admissions, isEmpty);
    expect(await f.store.load(f.id), isNotNull);
  });

  test('dispose during second control prevents late result admission', () async {
    final f = await open('dispose-second-control');
    var controls = 0;
    f.trace.beforeRequest = (row) async {
      if ((row['request'] as Map)['operation'] == 'control' && ++controls == 2) {
        await f.controller.dispose();
      }
    };
    await expectLater(f.send(), throwsA(anything));
    expect(f.trace.admissions, isEmpty);
    expect(await f.store.load(f.id), isNotNull);
  });

  test('partial page uses the real returned cursor on second changes read', () async {
    final f = await open('partial');
    f.controller.session!.displayWindow!.setFollowingLatest(false);
    await server.command('history-seed', {'conversationId': f.id, 'count': 65, 'text': 'History'});
    await f.send();
    final changes = f.trace.reads.where((r) => (r['request'] as Map)['operation'] == 'changes').toList();
    expect(changes.length, greaterThanOrEqualTo(2));
    expect((changes.first['response'] as Map)['nextCursor'], isNotNull);
    expect((changes[1]['request'] as Map)['input']['cursor'], (changes.first['response'] as Map)['nextCursor']);
  });

  test('retained public window snapshot stays immutable and detached', () async {
    final f = await open('snapshot-ownership');
    await server.command('history-seed', {'conversationId': f.id, 'count': 2, 'text': 'History'});
    await f.controller.session!.refresh();
    final old = f.controller.session!.displayWindow!.state;
    final oldJson = jsonEncode(old.records.map((r) => r.value).toList());
    expect(() => old.records.clear(), throwsUnsupportedError);
    expect(() => old.records.first.value!['content'] = [], throwsUnsupportedError);
    f.trace.rows.clear();
    await f.send();
    expect(beforeAdmission(f), ['control', 'changes', 'control', if (baseline) 'changes']);
    expect(jsonEncode(old.records.map((r) => r.value).toList()), oldJson);
  });

  test('restored journal bypasses private optimization', () async {
    final f = await open('restored');
    final session = f.controller.session!;
    final prepared = await session.prepareTurn(operationId: 'restore', clientId: 'independent', request: traceRequest());
    await f.store.retain(HandrailTurnSubmission.fromJson(jsonDecode(jsonEncode(prepared.toJson()))));
    await session.retryPendingMessage(f.store);
    expect(beforeAdmission(f), ['control', 'changes', 'control', 'changes']);
  });

  test('snapshot fallback retains both read_since operations', () async {
    final f = await open('fallback', snapshot: true);
    await f.send();
    final admission = f.trace.admissions.single['id'] as int;
    expect(f.trace.rows.where((r) => r['event'] == 'http' && r['phase'] == 'send' &&
      (r['id'] as int) < admission && (r['request'] as Map)['operation'] == 'read_since'), hasLength(2));
  });
}
