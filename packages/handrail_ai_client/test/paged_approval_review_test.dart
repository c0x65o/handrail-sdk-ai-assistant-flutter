import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'assistant_controller_test.dart' show Fixture;

http.Response ok(Object? value) =>
    http.Response(jsonEncode({'ok': true, 'value': value}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  late Fixture f;
  late HandrailAssistantController c;
  Map view() => c.approvals.presentation['pagedReview'] as Map;
  late List<Map> reviews, decisions;
  final binding = 'a' * 64, proposalBinding = 'b' * 64;
  bool changed = false, lostReceipt = false;
  int revision = 10;
  Completer<void>? held;
  setUp(() async {
    f = Fixture()..displayHistory = true;
    reviews = [];
    decisions = [];
    changed = false;
    lostReceipt = false;
    revision = 10;
    held = null;
    f.before = (request, body) async {
      if (request.url.path.endsWith('/capabilities'))
        return ok({
          'protocolVersion': applicationGatewayProtocolVersion,
          'synchronization': true,
          'resources': {'approvals': true},
          'displayHistory': {
            'version': 1,
            'control': true,
            'pendingApprovals': true,
            'approvalReview': true,
            'maximumPageSize': 50,
            'maximumPageBytes': 262144
          },
        });
      if (request.url.path.endsWith('/conversations/history')) {
        final input = body['input'] as Map;
        final header = {
          'schemaVersion': 1,
          'conversationId': input['conversationId'],
          'status': 'ready',
          'generation': 0,
          'revision': revision,
          'canonicalRevision': revision,
          'activeTurnId': null
        };
        if (body['operation'] == 'control')
          return ok({
            ...header,
            'activeTurn': null,
            'latestTurn': null,
            'requestedTurn': null,
            'hasPendingApprovals': true
          });
        if (body['operation'] == 'approval_review') {
          reviews.add(input);
          await held?.future;
          final offset = input['offset'] as int;
          return ok({
            ...header,
            'proposalId': input['proposalId'],
            'review': {
              'binding': changed ? 'c' * 64 : binding,
              'proposalBinding': proposalBinding,
              'proposalVersion': 1,
              'groupId': 'one',
              'turnId': 'turn',
              'toolCallId': 'tool',
              'toolName': 'send',
              'argumentReference': 'args-sha256-$binding',
              'text': offset == 0 ? '🙂' * 8192 : 'last',
              'offset': offset,
              'nextOffset': offset == 0 ? 8192 : null,
            }
          });
        }
        final inbox = (input['view'] as Map?)?['type'] == 'pending_approvals';
        return ok({
          ...header,
          'records': inbox
              ? [
                  {
                    'kind': 'approval',
                    'id': 'proposal',
                    'turnId': 'turn',
                    'revision': 2,
                    'bytes': 2000000,
                    'deferred': true,
                    'value': null
                  }
                ]
              : [],
          'nextCursor': null,
          if (body['operation'] == 'changes') 'throughRevision': revision
        });
      }
      if (request.url.path.endsWith('/approvals/transition-display')) {
        decisions.add(body);
        expect(await f.pending.loadApprovalDecisions(), hasLength(1));
        if (lostReceipt) {
          lostReceipt = false;
          throw StateError('lost response');
        }
        return ok({
          'schemaVersion': 1,
          'conversationId': body['conversationId'],
          'proposalId': body['proposalId'],
          'proposalVersion': 2,
          'status': body['status'],
          'proposalBinding': proposalBinding
        });
      }
      return null;
    };
    c = f.controller(autoCreate: false);
    await c.initialize();
    await c.approvals.openPendingApprovals();
    c.approvals.selectPendingApproval('proposal');
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
      if (view()['status'] == 'ready') break;
    }
  });
  tearDown(() async {
    held?.complete();
    await c.dispose();
    f.client.close();
  });
  test(
      'reviews deferred arguments in bounded sections and durably retries the identical decision',
      () async {
    expect(view()['status'], 'ready');
    expect((view()['section'] as Map)['text'], '🙂' * 8192);
    await (view()['decide'] as Future<void> Function(bool))(true);
    expect(decisions, isEmpty);
    await (view()['next'] as Future<void> Function())();
    expect((view()['section'] as Map)['text'], 'last');
    expect(reviews.last['binding'], binding);
    (view()['acknowledge'] as void Function(bool))(true);
    revision++;
    await c.session!.refresh();
    expect(view()['acknowledged'], true);
    expect(reviews, hasLength(2));
    lostReceipt = true;
    await (view()['decide'] as Future<void> Function(bool))(true);
    expect(view()['error'], 'decision');
    expect(await f.pending.loadApprovalDecisions(), hasLength(1));
    final reads = reviews.length;
    await (view()['decide'] as Future<void> Function(bool))(true);
    expect(decisions, hasLength(2));
    expect(decisions.first, decisions.last);
    expect(reviews, hasLength(reads));
    expect(view()['status'], 'decided');
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
    expect(c.document!.state['messages'], isEmpty);
    expect(f.requests.any((r) => r.url.path.endsWith('/approvals/transition')),
        false);
  });
  test(
      'compact decision intent resumes after controller restart without saved arguments',
      () async {
    lostReceipt = true;
    await (view()['decide'] as Future<void> Function(bool))(false);
    final saved = await f.pending.loadApprovalDecisions();
    expect(saved, hasLength(1));
    expect(saved.single.json['display'], true);
    expect(jsonEncode(saved.single.json), isNot(contains('🙂')));
    await c.dispose();
    c = f.controller(autoCreate: false);
    await c.initialize();
    expect(decisions, hasLength(2));
    expect(decisions.first, decisions.last);
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
  });
  test('changed preflight cannot save a decision', () async {
    changed = true;
    await (view()['decide'] as Future<void> Function(bool))(false);
    expect(view()['status'], 'error');
    expect(view()['section'], isNull);
    expect(decisions, isEmpty);
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
  });
  test(
      'switching chats cancels a held verification without persisting or sending its intent',
      () async {
    held = Completer<void>();
    final deciding = (view()['decide'] as Future<void> Function(bool))(false);
    await Future<void>.delayed(Duration.zero);
    await c.openConversation('two');
    await deciding;
    expect(c.approvals.presentation['pagedReview'], isNull);
    expect(decisions, isEmpty);
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
  });
}
