import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'assistant_controller_test.dart' show Fixture, ok;

class Approvals extends Fixture {
  Map<String, Object?> proposal = {
    'proposal_id': 'p',
    'proposal_version': 1,
    'group_id': 'group',
    'turn_id': 'turn',
    'tool_call_id': 'tool',
    'tool_name': 'update_invoice',
    'status': 'pending',
    'expires_at': '2099-01-01T00:00:00.000Z',
    'reviewed_arguments': {
      'type': 'redacted_json',
      'value': {'amount': 42}
    },
  };
  final decisions = <Map<String, Object?>>[];
  final receipts = <String, Map<String, Object?>>{};
  Map<String, Object?> corrupt = {};
  bool loseReply = false, conflict = false, enabled = true;
  @override
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'authoritativeCancellation': true,
        'resources': {'approvals': enabled},
      });
    if (request.url.path.endsWith('/approvals/transition')) {
      final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
      decisions.add(body);
      expect(await pending.loadApprovalDecisions(), hasLength(1));
      if (conflict)
        return http.Response(
            jsonEncode({
              'ok': false,
              'error': {
                'code': 'version_conflict',
                'message': 'Changed',
                'retryable': false,
              }
            }),
            409);
      final receipt =
          receipts.putIfAbsent(body['idempotencyKey'] as String, () {
        proposal = {
          ...proposal,
          'proposal_version': (body['expectedVersion'] as int) + 1,
          'status': body['status']
        };
        return Map.of(proposal);
      });
      if (loseReply) {
        loseReply = false;
        return http.Response('lost', 503);
      }
      return ok({...receipt, ...corrupt});
    }
    final response = await super.handle(request);
    if (request.url.path.endsWith('/synchronization')) {
      final body = jsonDecode(response.body) as Map;
      final snapshot = (body['value'] as Map)['snapshot'];
      if (snapshot is Map)
        (snapshot['state'] as Map)['approval_proposals'] =
            snapshot['conversationId'] == 'one' ? [proposal] : [];
      return http.Response(jsonEncode(body), 200);
    }
    return response;
  }
}

Map<String, Object?> item(HandrailAssistantController c) =>
    (c.approvals.presentation['items'] as List).first as Map<String, Object?>;
Future<void> approve(HandrailAssistantController c) async {
  await c.approvals.review('p', 1);
  await c.approvals.decide('p', 1, item(c)['binding'] as String, true);
}

void main() {
  late Approvals f;
  late HandrailAssistantController c;
  setUp(() async {
    f = Approvals();
    c = f.controller(autoCreate: false);
    await c.initialize();
  });
  tearDown(() async {
    await c.dispose();
    f.client.close();
  });
  test('review gates confirmation and exact receipt is not execution',
      () async {
    expect(item(c)['canConfirm'], false);
    await expectLater(
        () async =>
            c.approvals.decide('p', 1, item(c)['binding'] as String, true),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.decisions, isEmpty);
    await approve(c);
    expect(
        f.decisions.single.keys,
        unorderedEquals([
          'conversationId',
          'proposalId',
          'expectedVersion',
          'status',
          'idempotencyKey',
          'idempotencyFingerprint'
        ]));
    expect(item(c)['status'], 'confirmed');
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
    expect(f.storage.values.join(), isNot(contains('amount')));
  });
  test(
      'lost reply retains exact decision across restart; opposite choice blocked',
      () async {
    f.loseReply = true;
    await expectLater(approve(c), throwsA(isA<HandrailGatewayException>()));
    final saved = await f.pending.loadApprovalDecisions();
    expect(saved, hasLength(1));
    expect(f.storage.values.join(), isNot(contains('amount')));
    await expectLater(
        () async =>
            c.approvals.decide('p', 1, item(c)['binding'] as String, false),
        throwsA(isA<HandrailGatewayException>()));
    await c.dispose();
    c = f.controller(autoCreate: false);
    await c.initialize();
    expect(f.decisions, hasLength(2));
    expect(f.decisions[0], f.decisions[1]);
    expect(f.receipts, hasLength(1));
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
    expect(item(c)['status'], 'confirmed');
  });
  test('version conflict discards review, never silently retries new version',
      () async {
    f.conflict = true;
    await expectLater(approve(c), throwsA(isA<HandrailGatewayException>()));
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
    expect(item(c)['canConfirm'], false);
    expect(f.decisions, hasLength(1));
  });
  test('mismatched receipt remains uncertain and blocks conversation deletion',
      () async {
    f.corrupt = {'tool_name': 'different_tool'};
    await expectLater(approve(c), throwsFormatException);
    expect(await f.pending.loadApprovalDecisions(), hasLength(1));
    expect(c.approvals.pendingFor('one'), true);
    await expectLater(c.permanentlyDelete('one', 1),
        throwsA(isA<HandrailGatewayException>()));
    await c.openConversation('two');
    expect(c.canSend, true);
  });
  test('opaque arguments require trusted complete host review', () async {
    f.proposal = {
      ...f.proposal,
      'reviewed_arguments': {
        'type': 'opaque_reference',
        'argument_ref': 'args-sha256-reference'
      }
    };
    await c.session!.refresh();
    await expectLater(
        c.approvals.review('p', 1), throwsA(isA<HandrailGatewayException>()));
    expect(item(c)['canConfirm'], false);
    expect(f.decisions, isEmpty);
    await c.dispose();
    c = HandrailAssistantController(
        client: f.client,
        pendingStore: f.pending,
        pollingInterval: null,
        loadApprovalReview: (p) async => HandrailApprovalReview.forProposal(p,
            arguments: {'amount': 42}, complete: false));
    await c.initialize();
    await c.approvals.review('p', 1);
    expect(item(c)['complete'], false);
    expect(item(c)['canConfirm'], false);
  });
  test('late review cannot cross selection or sign out', () async {
    await c.dispose();
    final entered = Completer<void>(), release = Completer<void>();
    c = HandrailAssistantController(
        client: f.client,
        pendingStore: f.pending,
        pollingInterval: null,
        loadApprovalReview: (p) async {
          entered.complete();
          await release.future;
          return HandrailApprovalReview.forProposal(p,
              arguments: {'amount': 42}, complete: true);
        });
    await c.initialize();
    final reviewing = c.approvals.review('p', 1);
    await entered.future;
    await c.openConversation('two');
    release.complete();
    await expectLater(reviewing, throwsA(isA<HandrailGatewayException>()));
    await c.openConversation('one');
    expect(item(c)['canConfirm'], false);
  });
  test('changed arguments invalidate a cached review even at the same version',
      () async {
    await c.approvals.review('p', 1);
    final binding = item(c)['binding'] as String;
    f.proposal = {
      ...f.proposal,
      'reviewed_arguments': {
        'type': 'redacted_json',
        'value': {'amount': 100}
      }
    };
    await c.session!.refresh();
    expect(item(c)['canConfirm'], false);
    await expectLater(() async => c.approvals.decide('p', 1, binding, true),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.decisions, isEmpty);
  });
  test('domain permission veto cannot be overridden by complete review',
      () async {
    await c.dispose();
    c = HandrailAssistantController(
        client: f.client,
        pendingStore: f.pending,
        pollingInterval: null,
        canDecideApproval: (_, confirm) => !confirm);
    await c.initialize();
    await c.approvals.review('p', 1);
    expect(item(c)['canConfirm'], false);
    expect(item(c)['canReject'], true);
    await expectLater(
        () async =>
            c.approvals.decide('p', 1, item(c)['binding'] as String, true),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.decisions, isEmpty);
  });
  test('failed durable write prevents dispatch', () async {
    await c.dispose();
    final store = HandrailKeyValuePendingTurnStore(
        namespace: 'broken',
        read: (_) async => null,
        write: (_, __) async => throw StateError('disk'),
        delete: (_) async {});
    c = HandrailAssistantController(
        client: f.client, pendingStore: store, pollingInterval: null);
    await c.initialize();
    await expectLater(approve(c), throwsStateError);
    expect(f.decisions, isEmpty);
  });
  test(
      'two stores sharing an account atomically reject opposite saved decisions',
      () async {
    f.loseReply = true;
    await expectLater(approve(c), throwsA(isA<HandrailGatewayException>()));
    final saved = (await f.pending.loadApprovalDecisions()).single;
    final other = HandrailKeyValuePendingTurnStore(
        namespace: f.pending.namespace,
        read: f.pending.read,
        write: f.pending.write,
        delete: f.pending.delete);
    final opposite = HandrailApprovalDecisionRequest.fromJson(
        {...saved.json, 'status': 'rejected'});
    await expectLater(other.retainApprovalDecision(opposite),
        throwsA(isA<HandrailGatewayException>()));
    await other.acknowledgeApprovalDecision(opposite);
    expect(await other.loadApprovalDecisions(), hasLength(1));
    final isolated = HandrailKeyValuePendingTurnStore(
        namespace: 'other-account',
        read: f.pending.read,
        write: f.pending.write,
        delete: f.pending.delete);
    expect(await isolated.loadApprovalDecisions(), isEmpty);
  });
  test('concurrent controller adopts the original durable choice before retry',
      () async {
    final other = f.controller(autoCreate: false);
    addTearDown(other.dispose);
    await other.initialize();
    f.loseReply = true;
    await expectLater(approve(c), throwsA(isA<HandrailGatewayException>()));
    await expectLater(
        () async => other.approvals
            .decide('p', 1, item(other)['binding'] as String, false),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.decisions, hasLength(1));
    await other.approvals.retry('p');
    expect(f.decisions, hasLength(2));
    expect(f.decisions.first, f.decisions.last);
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
  });
  test(
      'sign out while saving intent prevents dispatch; saved choice resumes only in that account',
      () async {
    await c.dispose();
    final entered = Completer<void>(), release = Completer<void>();
    final store = HandrailKeyValuePendingTurnStore(
        namespace: f.pending.namespace,
        read: f.pending.read,
        delete: f.pending.delete,
        write: (key, value) async {
          await f.pending.write(key, value);
          entered.complete();
          await release.future;
        });
    c = HandrailAssistantController(
        client: f.client, pendingStore: store, pollingInterval: null);
    await c.initialize();
    final operation = approve(c);
    await entered.future;
    await c.dispose();
    release.complete();
    await expectLater(operation, throwsStateError);
    expect(f.decisions, isEmpty);
    c = f.controller(autoCreate: false);
    await c.initialize();
    expect(f.decisions, hasLength(1));
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
  });
  test('pending approvals have no deadline, including older timestamped proposals', () async {
    for (final expiry in [null, '2000-01-01T00:00:00.000Z']) {
      f.proposal = {...f.proposal, 'expires_at': expiry};
      await c.session!.refresh();
      await c.approvals.review('p', 1);
      expect(item(c)['canConfirm'], true);
      expect(item(c)['canReject'], true);
      expect(item(c)['expired'], false);
    }
  });
  test('historical expired or unavailable approval capability never dispatches', () async {
    f.proposal = {...f.proposal, 'status': 'expired', 'expires_at': '2000-01-01T00:00:00.000Z'};
    await c.session!.refresh();
    expect(item(c)['canConfirm'], false);
    expect(item(c)['canReject'], false);
    await expectLater(
        c.approvals.review('p', 1), throwsA(isA<HandrailGatewayException>()));
    expect(f.decisions, isEmpty);
    await c.dispose();
    f.enabled = false;
    f.proposal = {...f.proposal, 'status': 'pending', 'expires_at': null};
    c = f.controller(autoCreate: false);
    await c.initialize();
    expect(item(c)['canReview'], false);
    await expectLater(
        () async =>
            c.approvals.decide('p', 1, item(c)['binding'] as String, false),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.decisions, isEmpty);
  });
}
