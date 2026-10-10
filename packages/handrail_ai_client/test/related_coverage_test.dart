import 'dart:async';
import 'dart:convert';

import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'display_session_test.dart' show Fixture;
import 'assistant_controller_test.dart' as account;

class CoverageFixture extends Fixture {
  bool advancePage = true;
  bool advanceContextOnly = false;
  bool partialChanges = false;
  bool pendingApprovals = false;
  String? failOperation;
  http.Response? failure;
  int get contextReads => requests.where((r) {
        final input = r['input'] as Map?;
        return r['operation'] == 'page' &&
            (input?['view'] as Map?)?['type'] == 'context';
      }).length;

  @override
  Future<http.Response> handle(http.Request request) async {
    final body = request.body.isEmpty ? null : jsonDecode(request.body) as Map;
    if (advancePage &&
        body?['operation'] == 'page' &&
        (!advanceContextOnly || (body?['input'] as Map?)?['view'] != null)) {
      advancePage = false;
      revision = 7;
    }
    final response = await super.handle(request);
    if (pendingApprovals && request.url.path.endsWith('/capabilities')) {
      final result = jsonDecode(response.body) as Map;
      ((result['value'] as Map)['displayHistory'] as Map)['pendingApprovals'] =
          true;
      return http.Response(jsonEncode(result), response.statusCode,
          headers: response.headers);
    }
    if (body?['operation'] == failOperation && failure != null) {
      final result = failure!;
      failure = null;
      return result;
    }
    if (partialChanges && body?['operation'] == 'changes') {
      final result = jsonDecode(response.body) as Map;
      (result['value'] as Map)['nextCursor'] = 'remaining';
      return http.Response(jsonEncode(result), response.statusCode,
          headers: response.headers);
    }
    return response;
  }
}

void main() {
  test('merged context7 covers the next fresh control7 and empty changes',
      () async {
    final f = CoverageFixture()..revision = 2;
    addTearDown(f.dispose);
    await f.session.initialize();
    expect(f.session.document!.revision, 2);
    expect(f.session.displayWindow!.state.revision, 7);
    expect(f.contextReads, 1);
    await f.session.refresh();
    expect(f.session.document!.revision, 7);
    expect(f.contextReads, 1);
    expect(f.requests.where((r) => r['operation'] == 'control').length, 2);
    expect(f.requests.where((r) => r['operation'] == 'changes').length, 1);
    // A later head still needs hydration; coverage is not a revision floor.
    f.revision = 8;
    f.changed = [];
    await f.session.refresh();
    expect(f.contextReads, 2);
  });

  for (final counterexample in [
    'partial context',
    'multiple groups',
    'all groups loaded',
    'deferred context',
    'partial changes',
    'nonempty identical changes',
    'same-revision window replacement',
    'workspace selection round trip',
    'navigation attempt',
    'generation',
    'turn membership',
  ]) {
    test('$counterexample still hydrates context', () async {
      final f = CoverageFixture()..revision = 2;
      addTearDown(f.dispose);
      switch (counterexample) {
        case 'partial context':
          f.relatedCursor = 'older';
        case 'multiple groups':
        case 'all groups loaded':
          f.messagePrefix = List.filled(90, 'm').join();
        case 'deferred context':
          f.related = [
            {
              'kind': 'tool',
              'id': 'tool',
              'turnId': null,
              'revision': 7,
              'bytes': 100,
              'deferred': true,
              'value': null,
            }
          ];
        case 'nonempty identical changes':
          f.advanceContextOnly = true;
          f.related = [
            {
              'kind': 'tool',
              'id': 'tool',
              'turnId': null,
              'revision': 7,
              'bytes': 100,
              'deferred': false,
              'value': {'tool_call_id': 'tool', 'status': 'completed'},
            }
          ];
      }
      await f.session.initialize();
      switch (counterexample) {
        case 'all groups loaded':
          while (f.session.hasMoreRelated) {
            await f.session.loadMoreRelated();
          }
        case 'partial changes':
          f.partialChanges = true;
        case 'nonempty identical changes':
          f.changed = List.of(f.related);
        case 'same-revision window replacement':
          await f.session.displayWindow!.select('chat');
        case 'workspace selection round trip':
          f.session.workspace.select(null);
          f.session.workspace.select('chat');
        case 'navigation attempt':
          await f.session.displayWindow!.loadNewer();
        case 'generation':
          f.generation = 1;
        case 'turn membership':
          f.turns['new-turn'] = {
            'turnId': 'new-turn',
            'revision': 7,
            'status': 'completed',
            'remoteMayStillBeRunning': false,
            'error': null,
          };
          f.latest = 'new-turn';
      }
      final before = f.contextReads;
      await f.session.refresh();
      expect(f.contextReads, before + 1);
    });
  }

  for (final operation in ['control', 'changes']) {
    for (final failure in ['401', '403', '429', '500', 'protocol']) {
      test('$operation $failure spends coverage and retains error behavior',
          () async {
        final f = CoverageFixture()..revision = 2;
        addTearDown(f.dispose);
        await f.session.initialize();
        f.failOperation = operation;
        f.failure = failure == 'protocol'
            ? http.Response('{"ok":true,"value":{}}', 200)
            : http.Response(
                jsonEncode({
                  'ok': false,
                  'error': {
                    'code': switch (failure) {
                      '401' => 'unauthenticated',
                      '403' => 'forbidden',
                      '429' => 'rate_limited',
                      _ => 'unavailable',
                    },
                    'message': 'Synthetic failure',
                    'retryable': true,
                  }
                }),
                int.parse(failure),
                headers: {'retry-after': '60'});
        await expectLater(
            f.session.refresh(), throwsA(isA<HandrailGatewayException>()));
        if (failure == '429') {
          final count = f.requests.length;
          await expectLater(
              f.session.refresh(), throwsA(isA<HandrailGatewayException>()));
          expect(f.requests.length, count,
              reason: 'Retry-After is not bypassed');
        } else {
          if (failure == '401' || failure == '403') {
            expect(f.session.document, isNull);
            expect(f.session.displayWindow!.state.records, isEmpty);
          }
          await f.session.refresh();
          expect(f.contextReads, 2);
        }
      });
    }
  }

  test('late context for a replaced same-revision window is not merged',
      () async {
    final f = CoverageFixture()..revision = 2;
    addTearDown(f.dispose);
    final hold = Completer<void>(), started = Completer<void>();
    f.holdLatestRelatedPage = hold.future;
    f.onRelatedRead = (_) {
      if (!started.isCompleted) started.complete();
    };
    f.related = [
      {
        'kind': 'tool',
        'id': 'obsolete',
        'turnId': null,
        'revision': 7,
        'bytes': 100,
        'deferred': false,
        'value': {'tool_call_id': 'obsolete', 'status': 'completed'},
      }
    ];
    final initializing = f.session.initialize();
    await started.future;
    await f.session.displayWindow!.select('chat');
    hold.complete();
    await initializing;
    expect(f.session.document!.state['tool_calls'], isEmpty);
    f.related = [];
    await f.session.refresh();
    expect(f.contextReads, 2);
  });

  test(
      'late context success after disposal cannot publish or seed another session',
      () async {
    final f = CoverageFixture()..revision = 2;
    addTearDown(f.dispose);
    final hold = Completer<void>(), started = Completer<void>();
    f.holdLatestRelatedPage = hold.future;
    f.onRelatedRead = (_) {
      if (!started.isCompleted) started.complete();
    };
    final initializing = f.session.initialize();
    await started.future;
    await f.session.dispose();
    hold.complete();
    await initializing;
    expect(f.session.document, isNull);
    final replacement = HandrailConversationSession(
        client: f.client, conversationId: 'chat', pollingInterval: null);
    addTearDown(replacement.dispose);
    await replacement.initialize();
    expect(f.contextReads, 2);
  });

  test('late context failure after replacement does not poison new selection',
      () async {
    final f = CoverageFixture()..revision = 2;
    addTearDown(f.dispose);
    final hold = Completer<void>(), started = Completer<void>();
    f.holdLatestRelatedPage = hold.future;
    f.onRelatedRead = (_) {
      if (!started.isCompleted) started.complete();
    };
    final initializing = f.session.initialize();
    await started.future;
    await f.session.displayWindow!.select('chat');
    f.failOperation = 'page';
    f.failure = http.Response(
        '{"ok":false,"error":{"code":"forbidden","message":"Old selection"}}',
        403);
    hold.complete();
    await initializing;
    expect(f.session.error, isNull);
    await f.session.refresh();
    expect(f.contextReads, 2);
  });

  test('an overlapping approval read makes context coverage ineligible',
      () async {
    final f = CoverageFixture()
      ..revision = 2
      ..pendingApprovals = true;
    addTearDown(f.dispose);
    await f.session.initialize();
    final hold = Completer<void>(), started = Completer<void>();
    f.holdLatestRelatedPage = hold.future;
    f.onRelatedRead = (_) {
      if (!started.isCompleted) started.complete();
    };
    final approval = f.session.readApprovals();
    await started.future;
    f.holdLatestRelatedPage = null;
    await f.session.refresh();
    expect(f.contextReads, 2);
    hold.complete();
    await approval;
  });

  test('failed context does not stamp the initiating control as merged',
      () async {
    final f = CoverageFixture()..revision = 2;
    addTearDown(f.dispose);
    f.onRelatedRead = (_) {
      f.failOperation = 'page';
      f.failure = http.Response('{"ok":true,"value":{}}', 200);
    };
    await expectLater(
        f.session.initialize(), throwsA(isA<HandrailGatewayException>()));
    f.onRelatedRead = null;
    await f.session.refresh();
    expect(f.contextReads, 2);
  });

  test('capability sharing stays ineligible without a policy lifetime',
      () async {
    final f = account.Fixture();
    final controller = f.controller(autoCreate: false);
    addTearDown(() async {
      await controller.dispose();
      f.client.close();
    });
    await controller.refreshActivity();
    await controller.ensureSession('one');
    await controller.ensureSession('two');
    int reads() =>
        f.requests.where((r) => r.url.path.endsWith('/capabilities')).length;
    expect(reads(), 3);
    await f.client.capabilities();
    await f.client.capabilities();
    expect(reads(), 5, reason: 'Direct public reads preserve their semantics');
  });

  test('late load-more success cannot clear a newer revocation error',
      () async {
    final f = CoverageFixture()
      ..revision = 2
      ..relatedCursor = 'older';
    addTearDown(f.dispose);
    await f.session.initialize();
    final hold = Completer<void>(), started = Completer<void>();
    f.holdRelatedPage = hold.future;
    f.onRelatedRead = (_) {
      if (!started.isCompleted) started.complete();
    };
    final more = f.session.loadMoreRelated();
    await started.future;
    f.denied = true;
    await expectLater(
        f.session.refresh(), throwsA(isA<HandrailGatewayException>()));
    hold.complete();
    await more;
    expect(f.session.document, isNull);
    expect(f.session.error?.statusCode, 403);
  });
}
