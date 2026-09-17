import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response ok(Object? value) =>
    http.Response(jsonEncode({'ok': true, 'value': value}), 200);

class Fixture {
  final requests = <Map<String, Object?>>[];
  final turns = <String, Map<String, Object?>>{};
  int revision = 100, generation = 0;
  bool preparing = false, denied = false;
  String? active, latest;
  Future<void>? holdControl;
  Future<void>? holdRelatedPage;
  List<Map<String, Object?>> related = [];
  String? relatedCursor;
  late final HandrailAiClient client = HandrailAiClient(
      baseUri: Uri.parse('https://test.invalid/ai'),
      httpClient: MockClient(handle));
  late final session = HandrailConversationSession(
      client: client, conversationId: 'chat', pollingInterval: null);
  void turn(String id, String status) {
    turns[id] = {
      'turnId': id,
      'revision': ++revision,
      'status': status,
      'remoteMayStillBeRunning':
          ['queued', 'running', 'waiting_for_tool_result'].contains(status),
      'error': null
    };
    active = turns[id]!['remoteMayStillBeRunning'] == true ? id : null;
    latest = id;
  }

  Map<String, Object?> record(int id) => {
        'kind': 'message',
        'id': 'message-$id',
        'turnId': latest,
        'revision': revision,
        'bytes': 220,
        'deferred': false,
        'value': {
          'message_id': 'message-$id',
          'turn_id': latest,
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Message $id at $revision'}
          ],
          'attachments': []
        }
      };
  Map<String, Object?> header() => {
        'schemaVersion': 1,
        'conversationId': 'chat',
        'status': preparing ? 'preparing' : 'ready',
        'generation': generation,
        'revision': revision,
        'canonicalRevision': revision,
        'activeTurnId': active
      };
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'activity': false,
        'authoritativeCancellation': true,
        'displayHistory': {
          'version': 1,
          'maximumPageSize': 50,
          'maximumPageBytes': 262144,
          'control': true
        }
      });
    final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
    requests.add({'path': request.url.path, ...body});
    if (denied)
      return http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'forbidden',
              'message': 'Access revoked',
              'retryable': false
            }
          }),
          403);
    final input = body['input'] as Map? ?? const {};
    if (request.url.path.endsWith('/conversations/history')) {
      switch (body['operation']) {
        case 'control':
          await holdControl;
          return ok({
            ...header(),
            'activeTurn': preparing ? null : turns[active],
            'latestTurn': preparing ? null : turns[latest],
            'requestedTurn': preparing ? null : turns[input['turnId']]
          });
        case 'page':
          if (input['view'] != null) {
            final response = {
              ...header(),
              'records': List.of(related),
              'nextCursor': relatedCursor
            };
            if (input['cursor'] != null) await holdRelatedPage;
            return ok(response);
          }
          final anchor = input['anchor'] as Map?;
          final end = anchor == null
              ? 100
              : int.parse((anchor['messageId'] as String).split('-').last);
          final older = anchor == null || anchor['direction'] == 'older';
          return ok({
            ...header(),
            'records': preparing
                ? []
                : [
                    for (var i = older ? end - 30 : end + 1;
                        i < (older ? end : end + 31);
                        i++)
                      record(i)
                  ],
            'nextCursor': 'more'
          });
        case 'changes':
          return ok({
            ...header(),
            'throughRevision': revision,
            'records':
                (input['afterRevision'] as int) < revision ? [record(99)] : [],
            'nextCursor': null
          });
      }
    }
    if (request.url.path.endsWith('/synchronization')) {
      expect(body['operation'], 'append_mutations',
          reason: 'Opening/refreshing must never pull a canonical snapshot');
      final mutations = (input['mutations'] as List).cast<Map>();
      final events = mutations
          .expand((mutation) => mutation['events'] as List)
          .cast<Map>();
      final start = events.singleWhere(
          (event) => (event['payload'] as Map)['type'] == 'turn.started');
      turn((start['payload'] as Map)['turn_id'] as String, 'queued');
      return ok({
        'status': 'mutations',
        'acknowledgements': [
          for (final mutation in mutations)
            {'mutationId': mutation['mutationId'], 'status': 'accepted'}
        ]
      });
    }
    if (request.url.path.endsWith('/turns/start')) {
      final id = body['conversationTurnId'] as String;
      turn(id, 'running');
      return http.Response(
          'event: started\ndata: ${jsonEncode({
                'conversationId': 'chat',
                'turnId': id,
                'mutationId': body['mutationId']
              })}\n\n',
          200);
    }
    if (request.url.path.endsWith('/turns/cancel')) {
      turn(body['turnId'] as String, 'cancelled');
      return ok({'status': 'cancellation_requested'});
    }
    throw StateError('Unexpected route ${request.url.path}');
  }

  Future<void> dispose() async {
    await session.dispose();
    client.close();
  }
}

void main() {
  test(
      'related state covers the retained window and ignores an obsolete activity page',
      () async {
    final f = Fixture()..turn('active', 'running');
    addTearDown(f.dispose);
    Map<String, Object?> tool(String name) => {
          'kind': 'tool',
          'id': name,
          'revision': f.revision,
          'bytes': 120,
          'turnId': 'active',
          'deferred': false,
          'value': {
            'tool_call_id': name,
            'turn_id': 'active',
            'name': name,
            'status': 'completed'
          }
        };
    f.related = [tool('original')];
    f.relatedCursor = 'page-two';
    await f.session.initialize();
    await f.session.displayWindow!.loadOlder();
    await f.session.displayWindow!.loadOlder();
    await f.session.refresh();
    final view = (f.requests.lastWhere((r) =>
        r['operation'] == 'page' &&
        (r['input'] as Map)['view'] != null)['input'] as Map)['view'] as Map;
    expect(view['messageIds'],
        f.session.displayWindow!.state.records.map((r) => r.id).toList());
    expect((view['messageIds'] as List).length, 90);
    final hold = Completer<void>();
    f.holdRelatedPage = hold.future;
    final more = f.session.loadMoreRelated();
    await Future<void>.delayed(Duration.zero);
    f.turn('active', 'completed');
    f.related = [tool('current')];
    f.relatedCursor = null;
    await f.session.refresh();
    hold.complete();
    await more;
    expect((f.session.document!.state['tool_calls'] as List).single['name'],
        'current');
    expect(f.session.hasMoreRelated, false);
    await f.session.dispose();
    expect(f.session.document, null);
    expect(f.session.displayWindow!.state.records, isEmpty);
  });

  test(
      'standard session selects one bounded page and refreshes live text without snapshots or event replay',
      () async {
    final f = Fixture()..turn('active', 'running');
    addTearDown(f.dispose);
    await f.session.initialize();
    expect(f.session.document, isA<HandrailConversationDisplayView>());
    expect(f.session.document!.isPartial, true);
    expect(f.session.document!.messages, hasLength(30));
    expect(f.session.document!.state.containsKey('processed_event_ids'), false);
    expect(f.session.document!.state.containsKey('replay_error'), false);
    expect(f.session.document!.activeTurnId, 'active');
    expect(f.session.observationConnected, false);
    expect(
        f.requests.where((r) =>
            r['operation'] == 'page' && (r['input'] as Map)['view'] == null),
        hasLength(1));
    await f.session.displayWindow!.loadOlder();
    expect(f.session.document!.messages, hasLength(60));
    await f.session.displayWindow!.loadOlder();
    await f.session.displayWindow!.loadOlder();
    expect(f.session.document!.messages.length, lessThanOrEqualTo(90));
    f.turn('active', 'completed');
    await f.session.refresh();
    expect(f.session.document!.activeTurnId, null);
    expect(
        f.session.document!.runtimeState.status, HandrailTurnStatus.completed);
    expect(f.requests.every((r) => r['path'] == '/ai/conversations/history'),
        true);
  });

  test(
      'uses requested-turn controls for old completion and never restarts an admitted terminal turn',
      () async {
    final f = Fixture()
      ..turn('old', 'completed')
      ..turn('new', 'running');
    addTearDown(f.dispose);
    await f.session.initialize();
    expect((await f.session.waitForTurn('old'))['status'], 'completed');
    await f.session.requestCancellation(
        mutationId: 'cancel-old',
        idempotencyKey: 'cancel-old',
        expectedTurnId: 'old');
    expect(f.requests.any((r) => r['path'] == '/ai/turns/cancel'), false);
    await f.session.requestCancellation(
        mutationId: 'cancel-new',
        idempotencyKey: 'cancel-new',
        expectedTurnId: 'new');
    expect(f.session.document!.activeTurnId, null);
    expect(f.session.document!.latestTurn!['status'], 'cancelled');
  });

  test('preparing blocks sends and revoked access evicts all visible content',
      () async {
    final f = Fixture()..preparing = true;
    addTearDown(f.dispose);
    await expectLater(
        f.session.initialize(),
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'history_preparing')));
    expect(f.session.document, null);
    f.preparing = false;
    await f.session.refresh();
    expect(f.session.document!.messages, isNotEmpty);
    f.denied = true;
    await expectLater(
        f.session.refresh(), throwsA(isA<HandrailGatewayException>()));
    expect(f.session.document, null);
    expect(f.session.displayWindow!.state.records, isEmpty);
  });

  test(
      'disposal cancels a stalled bounded read and late completion cannot republish',
      () async {
    final f = Fixture(), hold = Completer<void>();
    addTearDown(f.dispose);
    f.holdControl = hold.future;
    final pending = f.session.initialize();
    while (f.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await f.session.dispose();
    await pending.timeout(const Duration(seconds: 1));
    hold.complete();
    await Future<void>.delayed(Duration.zero);
    expect(f.session.document, null);
  });

  test(
      'sends through canonical admission and verifies the exact turn without loading the log',
      () async {
    final f = Fixture();
    addTearDown(f.dispose);
    await f.session.initialize();
    final submission = await f.session
        .prepareTurn(operationId: 'op', clientId: 'client', request: {
      'protocol_version': 'handrail.ai-runtime.v1',
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Hello'}
          ]
        }
      ],
      'tools': [],
      'tool_results': [],
      'continuation_of': null,
      'generation': {},
      'correlation_hints': {}
    });
    var accepted = 0;
    await f.session.submitTurn(submission, onAccepted: (_) {
      accepted++;
    });
    expect(accepted, 1);
    expect(
        f.requests.where((r) => r['path'] == '/ai/turns/start'), hasLength(1));
    expect(
        f.requests
            .where((r) => r['path'] == '/ai/synchronization')
            .every((r) => r['operation'] == 'append_mutations'),
        true);
    expect(
        f.requests.any((r) =>
            r['operation'] == 'control' &&
            (r['input'] as Map)['turnId'] == submission.turnId),
        true);
  });
}
