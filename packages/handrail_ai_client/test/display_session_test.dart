import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response ok(Object? value) =>
    http.Response(jsonEncode({'ok': true, 'value': value}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

class Fixture {
  final requests = <Map<String, Object?>>[];
  final turns = <String, Map<String, Object?>>{};
  int revision = 100, generation = 0;
  bool preparing = false, denied = false;
  String? active, latest;
  Future<void>? holdControl;
  Future<void>? holdAdmission;
  Future<void>? holdAfterAdmission;
  bool rejectAdmission = false, omitAcknowledgements = false;
  Future<void>? holdRelatedPage;
  List<Map<String, Object?>> related = [], additionalMessages = [];
  List<Map<String, Object?>>? changed;
  String? relatedCursor;
  String messagePrefix = 'message';
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
        'id': '$messagePrefix-$id',
        'turnId': latest,
        'revision': revision,
        'bytes': 220,
        'deferred': false,
        'value': {
          'message_id': '$messagePrefix-$id',
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
                    for (var i = older
                            ? end -
                                30 +
                                (anchor == null ? additionalMessages.length : 0)
                            : end + 1;
                        i < (older ? end : end + 31);
                        i++)
                      record(i),
                    if (anchor == null) ...additionalMessages,
                  ],
            'nextCursor': 'more'
          });
        case 'changes':
          return ok({
            ...header(),
            'throughRevision': revision,
            'records': changed ??
                ((input['afterRevision'] as int) < revision
                    ? [record(99)]
                    : []),
            'nextCursor': null
          });
      }
    }
    if (request.url.path.endsWith('/synchronization')) {
      expect(body['operation'], 'append_mutations',
          reason: 'Opening/refreshing must never pull a canonical snapshot');
      await holdAdmission;
      if (rejectAdmission)
        return ok({'status': 'rejected', 'reason': 'invalid_message'});
      holdControl = holdAfterAdmission;
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
          for (final mutation in omitAcknowledgements ? <Map>[] : mutations)
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
  Map<String, Object?> request() => {
        'protocol_version': 'handrail.ai-runtime.v1',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Hello'}
            ]
          }
        ],
      };

  test(
      'acknowledges delivery before a held history refresh and replaces the local echo by identity',
      () async {
    final f = Fixture();
    addTearDown(f.dispose);
    await f.session.initialize();
    final admission = Completer<void>(), history = Completer<void>();
    f.holdAdmission = admission.future;
    f.holdAfterAdmission = history.future;
    final submission = await f.session.prepareTurn(
        operationId: 'delivery', clientId: 'client', request: request());
    final accepted = Completer<void>();
    final sending = f.session
        .submitTurn(submission, onAccepted: (_) => accepted.complete());
    expect(f.session.outgoingMessage?['delivery_status'], 'sending');
    admission.complete();
    await accepted.future.timeout(const Duration(seconds: 2));
    expect(f.session.outgoingMessage?['delivery_status'], 'sent');
    expect(f.session.isSubmitting, isTrue);
    expect(f.requests.where((r) => r['path'] == '/ai/turns/start'), isEmpty);
    history.complete();
    await sending;
    expect(f.session.document!.activeTurnId, submission.turnId);
    final admittedAt =
        f.requests.indexWhere((r) => r['operation'] == 'append_mutations');
    expect(
        f.requests.skip(admittedAt + 1).where(
            (r) => r['operation'] == 'page' || r['operation'] == 'changes'),
        isEmpty,
        reason:
            'History and tool paging must not hold an admitted turn in the queue');
    f.changed = [
      {
        ...f.record(100),
        'id': 'message_delivery',
        'value': {
          'message_id': 'message_delivery',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Hello'}
          ],
          'attachments': [],
        },
      }
    ];
    // A deferred saved row still replaces the local echo, even without its body.
    f.additionalMessages = [
      {...f.changed!.single, 'deferred': true, 'value': null}
    ];
    await f.session.refresh();
    expect(f.session.outgoingMessage, isNull);
  });

  test('clearing saved history releases an unprojected sent message', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    await f.session.initialize();
    final submission = await f.session.prepareTurn(
        operationId: 'clear-echo', clientId: 'client', request: request());
    await f.session.submitTurn(submission);
    expect(f.session.outgoingMessage?['delivery_status'], 'sent');
    f.generation++;
    f.revision++;
    f.active = f.latest = null;
    await f.session.refresh();
    expect(f.session.outgoingMessage, isNull);
  });

  for (final rejected in [false, true]) {
    test(
        'does not acknowledge ${rejected ? 'rejected' : 'uncertain'} admission',
        () async {
      final f = Fixture();
      addTearDown(f.dispose);
      await f.session.initialize();
      f.rejectAdmission = rejected;
      f.omitAcknowledgements = !rejected;
      final submission = await f.session.prepareTurn(
          operationId: 'unconfirmed', clientId: 'client', request: request());
      var accepted = false;
      await expectLater(
          f.session.submitTurn(submission, onAccepted: (_) => accepted = true),
          throwsA(isA<HandrailGatewayException>()));
      expect(accepted, isFalse);
      expect(f.session.outgoingMessage?['delivery_status'],
          rejected ? null : 'unconfirmed');
      expect(f.requests.where((r) => r['path'] == '/ai/turns/start'), isEmpty);
    });
  }

  test('presentation version changes for paging but not an unchanged poll',
      () async {
    final f = Fixture();
    addTearDown(f.dispose);
    await f.session.initialize();
    int version() =>
        (f.session.document!.state['display_history'] as Map)['version'] as int;
    final initial = version(), canonical = f.session.document!.revision;
    await f.session.refresh();
    expect(version(), initial);
    await f.session.displayWindow!.loadOlder();
    expect(version(), greaterThan(initial));
    expect(f.session.document!.revision, canonical);
  });

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
    expect(
        view['messageIds'],
        unorderedEquals(
            f.session.displayWindow!.state.records.map((r) => r.id).toList()));
    expect((view['messageIds'] as List).length, 90);
    final hold = Completer<void>();
    f.holdRelatedPage = hold.future;
    f.related = [tool('obsolete-page')];
    final more = f.session.loadMoreRelated();
    await Future<void>.delayed(Duration.zero);
    f.turn('active', 'completed');
    f.related = [tool('current')];
    f.relatedCursor = null;
    await f.session.refresh();
    hold.complete();
    await more;
    expect(
        (f.session.document!.state['tool_calls'] as List)
            .map((tool) => tool['name']),
        containsAll(['original', 'current']));
    expect(
        (f.session.document!.state['tool_calls'] as List)
            .any((tool) => tool['name'] == 'obsolete-page'),
        false);
    await f.session.dispose();
    expect(f.session.document, null);
    expect(f.session.displayWindow!.state.records, isEmpty);
  });

  test('a live removal overtakes a held activity page without resurrection',
      () async {
    final f = Fixture()..relatedCursor = 'older';
    addTearDown(f.dispose);
    final tool = <String, Object?>{
      'kind': 'tool',
      'id': 'gone',
      'revision': f.revision,
      'turnId': null,
      'bytes': 100,
      'deferred': false,
      'value': {'tool_call_id': 'gone', 'status': 'completed'}
    };
    f.related = [tool];
    await f.session.initialize();
    final hold = Completer<void>();
    f.holdRelatedPage = hold.future;
    final more = f.session.loadMoreRelated();
    await Future<void>.delayed(Duration.zero);
    f.revision++;
    f.changed = [
      {...tool, 'revision': f.revision, 'value': null, 'deleted': true}
    ];
    await f.session.displayWindow!.refresh();
    hold.complete();
    await more;
    expect(f.session.document!.state['tool_calls'], isEmpty);
  });

  test(
      'partial presentation pairs citations with retained sources across pages and removals',
      () async {
    final f = Fixture()..relatedCursor = 'source';
    addTearDown(f.dispose);
    final citation = <String, Object?>{
      'kind': 'citation',
      'id': 'c',
      'revision': f.revision,
      'turnId': null,
      'bytes': 150,
      'deferred': false,
      'value': {
        'citation_id': 'c',
        'source_id': 's',
        'order': 0,
        'target': {'type': 'assistant_message', 'message_id': 'message-99'}
      }
    };
    final source = <String, Object?>{
      'kind': 'source',
      'id': 's',
      'revision': f.revision,
      'turnId': null,
      'bytes': 100,
      'deferred': false,
      'value': {'source_id': 's', 'label': 'Source', 'type': 'record'}
    };
    int unresolved() => (f.session.document!.state['display_history']
        as Map)['unresolvedCitationCount'] as int;
    f.related = [citation];
    await f.session.initialize();
    expect(f.session.document!.state['citations'], isEmpty);
    expect(unresolved(), 1);
    f.related = [source];
    f.relatedCursor = null;
    await f.session.loadMoreRelated();
    expect(f.session.document!.state['citations'], [citation['value']]);
    expect(unresolved(), 0);
    f.revision++;
    f.changed = [
      {...source, 'revision': f.revision, 'value': null, 'deleted': true}
    ];
    await f.session.displayWindow!.refresh();
    expect(f.session.document!.state['citations'], isEmpty);
    expect(unresolved(), 1);
    expect(f.session.document!.state['citation_sources'], isEmpty);
  });

  test(
      'activity pages retain loaded records, apply live tombstones and explicitly bound memory',
      () async {
    final f = Fixture()..turn('active', 'running');
    addTearDown(f.dispose);
    Map<String, Object?> tool(int id, {int size = 0}) => {
          'kind': 'tool',
          'id': 'tool-$id',
          'revision': f.revision,
          'bytes': size + 200,
          'turnId': 'active',
          'deferred': false,
          'value': {
            'tool_call_id': 'tool-$id',
            'turn_id': 'active',
            'name': 'Tool $id',
            'status': 'completed',
            'text': 'x' * size
          },
        };
    f.related = [for (var i = 90; i < 120; i++) tool(i)];
    f.relatedCursor = 'more';
    await f.session.initialize();
    for (var page = 2; page >= 0; page--) {
      f.related = [for (var i = page * 30; i < (page + 1) * 30; i++) tool(i)];
      await f.session.loadMoreRelated();
      expect((f.session.document!.state['tool_calls'] as List).length,
          lessThanOrEqualTo(90));
    }
    expect(f.session.relatedTruncated, true);
    f.turn('active', 'running');
    f.changed = [
      {...tool(70), 'deleted': true, 'value': null}
    ];
    f.related = [for (var i = 90; i < 120; i++) tool(i)];
    await f.session.refresh();
    final tools = f.session.document!.state['tool_calls'] as List;
    expect(tools.any((tool) => tool['tool_call_id'] == 'tool-70'), false);
    expect(tools.any((tool) => tool['tool_call_id'] == 'tool-30'), true);
    f.changed = [];
    await f.session.showLatestRelated();
    expect(f.session.relatedTruncated, false);
    expect(f.session.document!.state['tool_calls'] as List, hasLength(30));
    for (var page = 0; page < 6; page++) {
      f.related = [
        tool(200 + page * 2, size: 30000),
        tool(201 + page * 2, size: 30000)
      ];
      await f.session.loadMoreRelated();
    }
    expect(
        (f.session.document!.state['tool_calls'] as List).length, lessThan(9));
    expect(
        utf8.encode(jsonEncode(f.session.document!.state['tool_calls'])).length,
        lessThanOrEqualTo(262144));
    expect(f.session.relatedTruncated, true);
  });

  test(
      'denied activity page clears all presentation and publishes a nonretryable error',
      () async {
    final f = Fixture()..relatedCursor = 'more';
    addTearDown(f.dispose);
    await f.session.initialize();
    f.denied = true;
    await expectLater(
        f.session.loadMoreRelated(), throwsA(isA<HandrailGatewayException>()));
    expect(f.session.document, null);
    expect(f.session.displayWindow!.state.records, isEmpty);
    expect(f.session.error!.code, 'forbidden');
    expect(f.session.error!.retryable, false);
  });

  test(
      'long context references remain bounded and later groups load only on demand',
      () async {
    final f = Fixture()..messagePrefix = '界' * 250;
    addTearDown(f.dispose);
    await f.session.initialize();
    List<Map> contexts() => f.requests
        .where((r) =>
            r['operation'] == 'page' &&
            ((r['input'] as Map)['view'] as Map?)?['type'] == 'context')
        .toList();
    expect(contexts(), hasLength(1));
    for (var i = 0; f.session.hasMoreRelated && i < 40; i++) {
      await f.session.loadMoreRelated();
    }
    expect(f.session.hasMoreRelated, false);
    final references = contexts()
        .expand(
            (r) => ((r['input'] as Map)['view'] as Map)['messageIds'] as List)
        .toSet();
    expect(references,
        f.session.displayWindow!.state.records.map((r) => r.id).toSet());
    for (final request in contexts()) {
      expect(utf8.encode(jsonEncode(request)).length, lessThanOrEqualTo(8192));
    }
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
