import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'presend_fixture.dart';

void main() {
  final baseline = Platform.environment['HANDRAIL_PRESEND_BASELINE'] == '1';
  final server = PresendServer();
  final evidence =
      Platform.environment['HANDRAIL_PRESEND_EVIDENCE'] ??
      '../../docs/qa/presend-witness-2026-10-07/after';
  setUpAll(server.start);
  tearDownAll(server.close);
  Future<PresendFixture> fixture(
    String name, {
    String? loss,
    bool snapshot = false,
  }) async {
    final f = PresendFixture(server, name, loss: loss);
    addTearDown(() async {
      await server.command('trace-auth', {'denied': false});
      await f.close(evidence);
      await server.command('finish');
    });
    f.trace.snapshotFallback = snapshot;
    await f.open();
    return f;
  }

  Matcher code(String value) =>
      isA<HandrailGatewayException>().having((e) => e.code, 'code', value);

  test('normal controller pre-send sequence and canonical behavior', () async {
    final f = await fixture('normal-controller');
    final before = await server.command('stats');
    final submission = (await f.send())!;
    final after = await server.command('stats');
    expect(after['invocations'], before['invocations'] + 1);
    expect(after['admissions'], before['admissions'] + 1);
    expect(
      f.trace.rows.where((r) => r['path'] == '/api/ai/turns/start'),
      hasLength(1),
    );
    expect(f.controller.document!.activeTurnId, submission.turnId);
    f.trace.mark('provider-invocation-delta', {
      'count': after['invocations'] - before['invocations'],
    });
    final admission = f.trace.admissions.single;
    final reads = f.trace.reads
        .where((r) => (r['id'] as int) < (admission['id'] as int))
        .toList();
    expect(reads.map((r) => (r['request'] as Map)['operation']), [
      'control',
      'changes',
      'control',
      if (baseline) 'changes',
    ]);
    expect(reads[0]['request'], reads[2]['request']);
    expect(reads[0]['response'], reads[2]['response']);
    expect((reads[0]['response'] as Map)['canonicalRevision'], 0);
    expect(reads[1]['endUs'] as int, lessThan(reads[2]['startUs'] as int));
    expect(reads.every((r) => (r['inFlightAtStart'] as List).isEmpty), isTrue);
    expect(reads[0]['caller'], 'prepareTurn');
    expect(reads[2]['caller'], '_submitTurn');
    expect((admission['request'] as Map)['input']['expectedRevision'], isNull);
    expect(await f.store.load(f.id), isNull);
    f.trace.phase = 'settled';
    await server.command('finish');
    for (var i = 0; i < 50; i++) {
      await f.controller.session!.refresh();
      if (f.controller.document!.latestTurn?['status'] == 'completed') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(f.controller.document!.latestTurn?['status'], 'completed');
    expect(f.controller.document!.messages.map((m) => m['role']), [
      'user',
      'assistant',
    ]);
    expect(f.controller.document!.runtimeState.text, 'Finished once');
    f.trace.mark('canonical-visible-result', {
      'revision': f.controller.document!.revision,
      'messages': f.controller.document!.messages,
      'turn': f.controller.document!.latestTurn,
    });
  });

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

  for (final action in [
    'session refresh',
    'window refresh',
    'latest',
    'scroll roundtrip',
    'selection roundtrip',
    'workspace roundtrip',
  ]) {
    test('$action during retain invalidates preparation', () async {
      final f = await fixture('intervening-${action.replaceAll(' ', '-')}');
      f.afterRetain = () async {
        final w = f.controller.session!.displayWindow!;
        switch (action) {
          case 'workspace roundtrip':
            f.controller.workspace.select(null);
            f.controller.workspace.select(f.id);
          case 'session refresh':
            await f.controller.session!.refresh();
          case 'window refresh':
            await w.refresh();
          case 'latest':
            await w.jumpToLatest();
          case 'scroll roundtrip':
            w.setFollowingLatest(false);
            w.setFollowingLatest(true);
          case 'selection roundtrip':
            await w.select(null);
            await w.select(f.id);
        }
      };
      await f.send();
      final admission = f.trace.admissions.single;
      expect(
        f.trace.reads
            .where(
              (r) =>
                  r['caller'] == '_submitTurn' &&
                  (r['id'] as int) < (admission['id'] as int),
            )
            .map((r) => (r['request'] as Map)['operation']),
        ['control', 'changes'],
      );
    });
  }

  test(
    'navigation during second authorized control invalidates witness',
    () async {
      final f = await fixture('navigation-during-control');
      var controls = 0;
      f.trace.beforeRequest = (row) async {
        if ((row['request'] as Map)['operation'] == 'control' &&
            ++controls == 2) {
          await f.controller.session!.displayWindow!.jumpToLatest();
        }
      };
      await f.send();
      final admission = f.trace.admissions.single;
      expect(
        f.trace.reads
            .where(
              (r) =>
                  r['caller'] == '_submitTurn' &&
                  (r['id'] as int) < (admission['id'] as int),
            )
            .map((r) => (r['request'] as Map)['operation']),
        ['control', 'changes'],
      );
    },
  );

  test(
    'nonempty stable window saves one request with unchanged canonical CAS',
    () async {
      final f = await fixture('nonempty-controller');
      await server.command('history-seed', {
        'conversationId': f.id,
        'count': 2,
        'text': 'Synthetic history',
      });
      await f.controller.session!.refresh();
      f.trace.rows.clear();
      final beforeMessages = jsonEncode(f.controller.document!.messages);
      f.afterRetain = () async {
        expect(jsonEncode(f.controller.document!.messages), beforeMessages);
      };
      final sent = (await f.send())!;
      final admission = f.trace.admissions.single;
      expect((admission['request'] as Map)['input']['expectedRevision'], 2);
      expect(
        f.trace.reads
            .where((r) => (r['id'] as int) < (admission['id'] as int))
            .map((r) => (r['request'] as Map)['operation']),
        ['control', 'changes', 'control', if (baseline) 'changes'],
      );
      expect(f.controller.document!.activeTurnId, sent.turnId);
    },
  );

  test('partial multi-page changes retain the second cursor read', () async {
    final f = await fixture('partial-changes');
    f.controller.session!.displayWindow!.setFollowingLatest(false);
    await server.command('history-seed', {
      'conversationId': f.id,
      'count': 65,
      'text': 'Synthetic paginated history',
    });
    await f.send();
    final admission = f.trace.admissions.single;
    final changes = f.trace.reads
        .where(
          (r) =>
              (r['request'] as Map)['operation'] == 'changes' &&
              (r['id'] as int) < (admission['id'] as int),
        )
        .toList();
    expect(changes, hasLength(2));
    expect((changes.first['response'] as Map)['nextCursor'], isNotNull);
    expect(
      (changes.last['request'] as Map)['input']['cursor'],
      (changes.first['response'] as Map)['nextCursor'],
    );
  });

  for (final restored in [false, true]) {
    test(
      '${restored ? 'reconstructed journal' : 'direct submit'} gets full read',
      () async {
        final f = await fixture(
          restored ? 'reconstructed-journal' : 'direct-submit',
        );
        await f.runTrace(() async {
          final s = f.controller.session!;
          final prepared = await s.prepareTurn(
            operationId: 'direct-${f.id}',
            clientId: 'fixture',
            request: traceRequest(),
          );
          if (restored) {
            await f.store.retain(
              HandrailTurnSubmission.fromJson(
                jsonDecode(jsonEncode(prepared.toJson())),
              ),
            );
            await s.retryPendingMessage(f.store);
          } else {
            await s.submitTurn(prepared);
          }
        });
        final admission = f.trace.admissions.single;
        expect(
          f.trace.reads
              .where((r) => (r['id'] as int) < (admission['id'] as int))
              .map((r) => (r['request'] as Map)['operation']),
          ['control', 'changes', 'control', 'changes'],
        );
      },
    );
  }

  test('account replacement disposes witness before admission', () async {
    final f = await fixture('account-replacement');
    f.afterRetain = f.controller.dispose;
    await expectLater(f.send(), throwsA(anything));
    expect(f.trace.admissions, isEmpty);
    expect(await f.store.load(f.id), isNotNull);
    final replacement = HandrailAssistantController(
      client: f.api,
      pendingStore: f.store,
      autoCreate: false,
      pollingInterval: null,
    );
    addTearDown(replacement.dispose);
    await replacement.openConversation(f.id);
    f.trace.phase = 'retry';
    await f.runTrace(() => replacement.retryPendingMessage());
    expect(
      f.trace.rows.where(
        (r) =>
            r['phase'] == 'retry' &&
            (r['request'] as Map?)?['operation'] == 'changes',
      ),
      isNotEmpty,
    );
  });

  test(
    'snapshot fallback keeps both pre-admission read_since requests',
    () async {
      final f = await fixture('snapshot-fallback', snapshot: true);
      await f.send();
      final admission = f.trace.admissions.single;
      expect(
        f.trace.rows.where(
          (r) =>
              r['phase'] == 'send' &&
              r['event'] == 'http' &&
              (r['id'] as int) < (admission['id'] as int) &&
              (r['request'] as Map)['operation'] == 'read_since',
        ),
        hasLength(2),
      );
      expect(f.trace.reads, isEmpty);
    },
  );

  for (final loss in ['admission', 'start']) {
    test('lost $loss acknowledgement retries exact saved operation', () async {
      final f = await fixture('lost-$loss', loss: loss);
      final before = await server.command('stats');
      await expectLater(f.send(), throwsA(anything));
      final saved = jsonEncode((await f.store.load(f.id))!.toJson());
      f.trace.mark('retry', {'saved': jsonDecode(saved)});
      f.trace.phase = 'retry';
      await f.runTrace(() => f.controller.retryPendingMessage());
      expect(
        f.trace.rows.where(
          (r) =>
              r['phase'] == 'retry' &&
              (r['request'] as Map?)?['operation'] == 'changes',
        ),
        isNotEmpty,
      );
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
