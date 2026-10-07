import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'presend_fixture.dart';

void main() {
  final server = PresendServer();
  const evidence = '../../docs/qa/presend-2026-10-06';
  setUpAll(server.start);
  tearDownAll(server.close);
  Future<PresendFixture> fixture(String name, {String? loss}) async {
    final f = PresendFixture(server, name, loss: loss);
    addTearDown(() async {
      await server.command('trace-auth', {'denied': false});
      await f.close(evidence);
      await server.command('finish');
    });
    await f.open();
    return f;
  }

  Matcher code(String value) =>
      isA<HandrailGatewayException>().having((e) => e.code, 'code', value);

  test(
    'normal controller has sequential identical pre-admission read pairs',
    () async {
      final f = await fixture('normal-controller');
      await f.send();
      final admission = f.trace.admissions.single;
      final reads = f.trace.reads
          .where((r) => (r['id'] as int) < (admission['id'] as int))
          .toList();
      expect(reads.map((r) => (r['request'] as Map)['operation']), [
        'control',
        'changes',
        'control',
        'changes',
      ]);
      for (var i = 0; i < 2; i++) {
        expect(reads[i]['request'], reads[i + 2]['request']);
        expect(reads[i]['response'], reads[i + 2]['response']);
        expect((reads[i]['response'] as Map)['canonicalRevision'], 0);
      }
      expect(reads[1]['endUs'] as int, lessThan(reads[2]['startUs'] as int));
      expect(
        reads.every((r) => (r['inFlightAtStart'] as List).isEmpty),
        isTrue,
      );
      expect(reads[0]['caller'], 'prepareTurn');
      expect(reads[2]['caller'], '_submitTurn');
      expect(
        (admission['request'] as Map)['input']['expectedRevision'],
        isNull,
      );
      expect(await f.store.load(f.id), isNull);
    },
  );

  test('first preparation read observes a changed canonical head', () async {
    final f = await fixture('changed-before-prepare');
    expect(f.controller.document!.revision, isNull);
    await server.command('history-seed', {
      'conversationId': f.id,
      'count': 1,
      'text': 'Synthetic older history',
    });
    await f.send();
    final admission = f.trace.admissions.single;
    expect((admission['request'] as Map)['input']['expectedRevision'], 1);
    final controls = f.trace.reads
        .where(
          (r) =>
              (r['request'] as Map)['operation'] == 'control' &&
              (r['id'] as int) < (admission['id'] as int),
        )
        .toList();
    expect(controls, hasLength(2));
    expect(controls.first['localCanonicalRevision'], isNull);
    expect((controls.first['response'] as Map)['canonicalRevision'], 1);
    expect((controls.last['response'] as Map)['canonicalRevision'], 1);
  });

  test(
    'overlapping refresh callers singleflight but submit still reads again',
    () async {
      final f = await fixture('overlap');
      f.trace.holdControl = Completer<void>();
      final one = f.runTrace(() => f.controller.session!.refresh());
      await f.trace.controlEntered.future;
      final two = f.runTrace(() => f.controller.session!.refresh());
      expect(identical(one, two), isTrue);
      final sending = f.send();
      f.trace.holdControl!.complete();
      await Future.wait([one, two, sending]);
      final admission = f.trace.admissions.single;
      expect(
        f.trace.reads.where((r) => (r['id'] as int) < (admission['id'] as int)),
        hasLength(4),
      );
    },
  );

  test(
    'remote turn during journal write is caught by second control',
    () async {
      final f = await fixture('remote-turn');
      final remote = HandrailConversationSession(
        client: f.api,
        conversationId: f.id,
        pollingInterval: null,
      );
      addTearDown(remote.dispose);
      f.afterRetain = () async {
        final submission = await remote.prepareTurn(
          operationId: 'remote',
          clientId: 'remote',
          request: traceRequest(),
        );
        await remote.submitTurn(submission);
        f.trace.mark('remote-admitted');
      };
      await expectLater(f.send(), throwsA(code('conversation_busy')));
      expect(f.trace.admissions, hasLength(1)); // Only the remote writer.
      expect(await f.store.load(f.id), isNotNull);
      expect(
        f.trace.reads.lastWhere(
          (r) => (r['request'] as Map)['operation'] == 'control',
        )['response'],
        containsPair('activeTurnId', isNotNull),
      );
    },
  );

  test(
    'remote clear during retain changes generation and rejects stale admission',
    () async {
      final f = await fixture('remote-clear');
      f.afterRetain = () async {
        await server.command('trace-clear', {'conversationId': f.id});
        f.trace.mark('remote-clear');
      };
      await expectLater(f.send(), throwsA(code('admission_conflict')));
      expect(
        (f.trace.admissions.single['request']
            as Map)['input']['expectedRevision'],
        isNull,
      );
      expect(
        f.trace.rows.where((r) => r['path'] == '/api/ai/turns/start'),
        isEmpty,
      );
      expect(await f.store.load(f.id), isNotNull);
      final controls = f.trace.reads
          .where((r) => (r['request'] as Map)['operation'] == 'control')
          .toList();
      expect((controls.first['response'] as Map)['generation'], 0);
      expect((controls.last['response'] as Map)['generation'], 1);
    },
  );

  for (final afterSecondRead in [false, true]) {
    test(
      'canonical change ${afterSecondRead ? 'after second read' : 'during retain'} preserves stale CAS',
      () async {
        final f = await fixture(
          afterSecondRead ? 'stale-cas' : 'remote-history',
        );
        Future<void> change() async {
          await server.command('history-seed', {
            'conversationId': f.id,
            'count': 1,
            'text': 'Synthetic remote history',
          });
          f.trace.mark('remote-history-appended');
        }

        if (afterSecondRead) {
          f.trace.beforeRequest = (row) async {
            if ((row['request'] as Map)['operation'] == 'append_mutations')
              await change();
          };
        } else {
          f.afterRetain = change;
        }
        await expectLater(f.send(), throwsA(code('admission_conflict')));
        expect(
          (f.trace.admissions.single['request']
              as Map)['input']['expectedRevision'],
          isNull,
        );
        expect(
          f.trace.admissions.single['response'],
          containsPair('status', 'conflict'),
        );
        expect(await f.store.load(f.id), isNotNull);
        final stats = await server.command('stats');
        f.trace.mark('stats', stats);
        expect(
          f.trace.rows.where((r) => r['path'] == '/api/ai/turns/start'),
          isEmpty,
        );
      },
    );
  }

  for (final afterSecondRead in [false, true]) {
    test(
      'auth revoked ${afterSecondRead ? 'at admission' : 'during retain'} rejects without start',
      () async {
        final f = await fixture(
          afterSecondRead ? 'auth-at-admission' : 'auth-during-retain',
        );
        Future<void> revoke() async {
          await server.command('trace-auth', {'denied': true});
          f.trace.mark('auth-revoked');
        }

        if (afterSecondRead) {
          f.trace.beforeRequest = (row) async {
            if ((row['request'] as Map)['operation'] == 'append_mutations')
              await revoke();
          };
        } else {
          f.afterRetain = revoke;
        }
        await expectLater(f.send(), throwsA(code('forbidden')));
        expect(f.trace.admissions, hasLength(afterSecondRead ? 1 : 0));
        expect(
          f.trace.rows.where((r) => r['path'] == '/api/ai/turns/start'),
          isEmpty,
        );
        expect(await f.store.load(f.id), isNotNull);
      },
    );
  }

  for (final loss in ['admission', 'start']) {
    test('lost $loss acknowledgement retries exact saved operation', () async {
      final f = await fixture('lost-$loss', loss: loss);
      final before = await server.command('stats');
      await expectLater(f.send(), throwsA(anything));
      final saved = jsonEncode((await f.store.load(f.id))!.toJson());
      f.trace.mark('retry', {'saved': jsonDecode(saved)});
      f.trace.phase = 'retry';
      await f.runTrace(() => f.controller.retryPendingMessage());
      expect(f.trace.admissions, hasLength(2));
      expect(
        f.trace.admissions[0]['request'],
        f.trace.admissions[1]['request'],
      );
      expect(await f.store.load(f.id), isNull);
      final after = await server.command('stats');
      expect(after['invocations'], before['invocations'] + 1);
      f.trace.mark('provider-invocation-delta', {
        'count': after['invocations'] - before['invocations'],
      });
      expect(
        (jsonDecode(saved) as Map)['start']['idempotencyKey'],
        'start_op-lost-$loss',
      );
    });
  }
}
