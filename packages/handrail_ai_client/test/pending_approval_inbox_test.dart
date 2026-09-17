import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'assistant_controller_test.dart' show Fixture, ok;

void main() {
  late Fixture f;
  late HandrailAssistantController c;
  late Map<String, Object?> proposal;
  int revision = 100;
  Future<void>? hold;
  bool deferTool = false;
  Map<String, Object?> record(
          String kind, String id, Map<String, Object?> value) =>
      {
        'kind': kind,
        'id': id,
        'turnId': 'old-turn',
        'revision': 2,
        'bytes': 500,
        'deferred': kind == 'tool' && deferTool,
        'value': kind == 'tool' && deferTool ? null : value,
      };
  setUp(() async {
    f = Fixture()..displayHistory = true;
    revision = 100;
    hold = null;
    deferTool = false;
    proposal = {
      'proposal_id': 'old',
      'proposal_version': 1,
      'group_id': 'one',
      'turn_id': 'old-turn',
      'tool_call_id': 'old-tool',
      'tool_name': 'save_invoice',
      'status': 'pending',
      'expires_at': null,
      'reviewed_arguments': {
        'type': 'opaque_reference',
        'argument_ref':
            'args-sha256-${sha256.convert(utf8.encode('{"amount":42}'))}'
      },
    };
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
            'hasPendingApprovals': proposal['status'] == 'pending'
          });
        final view = input['view'] as Map?;
        if (view?['type'] == 'pending_approvals') {
          final records = proposal['status'] == 'pending'
              ? [record('approval', 'old', proposal)]
              : [];
          await hold;
          return ok({
            ...header,
            'records': input['cursor'] == null ? records : [],
            'nextCursor': input['cursor'] == null ? 'older' : null
          });
        }
        if (view?['type'] == 'approval')
          return ok({
            ...header,
            'records': [
              record('approval', 'old', proposal),
              record('tool', 'old-tool', {
                'tool_call_id': 'old-tool',
                'turn_id': 'old-turn',
                'name': 'save_invoice',
                'arguments': {'amount': 42}
              })
            ],
            'nextCursor': null
          });
        return ok({
          ...header,
          'records': [],
          'nextCursor': null,
          if (body['operation'] == 'changes') 'throughRevision': revision
        });
      }
      if (request.url.path.endsWith('/approvals/transition')) {
        expect(await f.pending.loadApprovalDecisions(), hasLength(1));
        proposal = {
          ...proposal,
          'proposal_version': 2,
          'status': body['status']
        };
        revision++;
        return ok(proposal);
      }
      return null;
    };
    c = f.controller(autoCreate: false);
    await c.initialize();
  });
  tearDown(() async {
    await c.dispose();
    f.client.close();
  });
  List<Map> views() => f.requests
      .where((r) => r.url.path.endsWith('/conversations/history'))
      .map((r) => jsonDecode(r.body) as Map)
      .map((r) => (r['input'] as Map)['view'])
      .whereType<Map>()
      .toList();

  test(
      'old approval discovery and bound review use the durable decision path without transcript hydration',
      () async {
    expect(c.approvals.presentation['pendingApprovalsAvailable'], true);
    expect(views().where((v) => v['type'] == 'pending_approvals'), isEmpty);
    await c.approvals.openPendingApprovals();
    expect(c.approvals.presentation['inboxItems'], hasLength(1));
    c.approvals.selectPendingApproval('old');
    var item = (c.approvals.presentation['items'] as List).single as Map;
    expect(item['inboxOnly'], true);
    expect(item['canConfirm'], false);
    await c.approvals.review('old', 1);
    item = (c.approvals.presentation['items'] as List).single as Map;
    expect(item['arguments'], {'amount': 42});
    expect(item['canConfirm'], true);
    expect(views().where((v) => v['type'] == 'approval'), hasLength(1));
    await c.approvals.decide('old', 1, item['binding'] as String, true);
    expect(await f.pending.loadApprovalDecisions(), isEmpty);
    expect(proposal['status'], 'confirmed');
    expect(c.document!.state['messages'], isEmpty);
    expect(
        f.requests.any((r) =>
            r.url.path.endsWith('/synchronization') ||
            r.url.path.endsWith('/approvals/list-group')),
        false);
  });
  test(
      'page replacement and close cancel held reads and clear inbox across chat selection',
      () async {
    await c.approvals.openPendingApprovals();
    await c.approvals.openPendingApprovals(cursor: 'older');
    expect(c.approvals.presentation['inboxItems'], isEmpty);
    expect(c.approvals.presentation['inboxHasNewer'], true);
    final gate = Completer<void>();
    hold = gate.future;
    final pending = c.approvals.openPendingApprovals();
    await Future<void>.delayed(Duration.zero);
    c.approvals.closePendingApprovals();
    await pending;
    expect(c.approvals.presentation['inboxOpen'], false);
    gate.complete();
    hold = null;
    await c.approvals.openPendingApprovals();
    await c.openConversation('two');
    expect(c.approvals.presentation['inboxOpen'], false);
    expect(c.approvals.presentation['inboxItems'], isEmpty);
  });
  test('deferred tool details cannot authorize confirmation', () async {
    await c.approvals.openPendingApprovals();
    c.approvals.selectPendingApproval('old');
    deferTool = true;
    await expectLater(
        c.approvals.review('old', 1), throwsA(isA<HandrailGatewayException>()));
    expect(
        ((c.approvals.presentation['items'] as List).single
            as Map)['canConfirm'],
        false);
  });
}
