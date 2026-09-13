import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('attachment file parts preserve the declared supported media type', () async {
    final client = HandrailAiClient(
      baseUri: Uri.parse('https://app.example/api/ai'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/ai/attachments');
        expect(request.headers['content-type'], startsWith('multipart/form-data'));
        expect(request.body, contains('content-type: application/pdf'));
        expect(request.body, contains('name="file"; filename="invoice.pdf"'));
        expect(request.body, contains('%PDF-test'));
        return http.Response(jsonEncode({'ok': true, 'value': {
          'attachment_id': 'att_invoice',
          'content_ref': 'ref_invoice',
          'media_type': 'application/pdf',
          'byte_size': utf8.encode('%PDF-test').length,
          'filename': 'invoice.pdf',
        }}), 200);
      }),
    );
    await client.uploadAttachment(bytes: utf8.encode('%PDF-test'),
        filename: 'invoice.pdf', mediaType: 'application/pdf',
        kind: 'document', idempotencyKey: 'upload-1');
    client.close();
  });

  test(
    'reduces typed cross-platform turn state and calls thread resources',
    () async {
      final client = HandrailAiClient(
        baseUri: Uri.parse('https://app.example/api/ai'),
        httpClient: MockClient((request) async {
          expect(request.url.path, endsWith('/conversations/create'));
          return http.Response(
            jsonEncode({
              'ok': true,
              'value': {
                'operation': 'create',
                'status': 'created',
                'descriptor': {'conversationId': 'c1'},
              },
            }),
            200,
          );
        }),
      );
      expect(
        await client.createConversation({'idempotencyKey': 'create-1'}),
        containsPair('value', isA<Map>()),
      );
      final running = const HandrailConversationState(conversationId: 'c1')
          .apply(
            const HandrailStreamFrame('event', null, {
              'event': {'type': 'response.started'},
            }),
          )
          .apply(
            const HandrailStreamFrame('event', null, {
              'event': {'type': 'response.text.delta', 'delta': 'Hello'},
            }),
          );
      expect(running.status, HandrailTurnStatus.running);
      expect(running.text, 'Hello');
      client.close();
    },
  );

  test('negotiates capabilities and parses SSE frames', () async {
    final client = HandrailAiClient(
      baseUri: Uri.parse('https://app.example/api/ai'),
      protectedHeaders: () => {'authorization': 'Bearer app'},
      httpClient: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer app');
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'value': {
                'protocolVersion': applicationGatewayProtocolVersion,
                'authoritativeCancellation': true,
                'attachments': false,
                'presence': true,
                'synchronization': true,
              },
            }),
            200,
          );
        }
        return http.Response(
          'event: event\nid: cursor-1\ndata: {"type":"event","event":{"type":"response.text.delta","delta":"Hi"},"checkpoint":{"lastAppliedCursor":"cursor-1"}}\n\n'
          'event: terminal\ndata: {"type":"terminal","result":{"status":"completed","checkpoint":{"lastAppliedCursor":"cursor-1"}}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    expect((await client.capabilities()).presence, isTrue);
    final frames = await client.startTurn({'conversationId': 'c1'}).toList();
    expect(frames.map((frame) => frame.type), ['event', 'terminal']);
    expect(frames.first.id, 'cursor-1');
    client.close();
  });

  test(
    'terminal frames preserve server status while disconnection only ends observation',
    () {
      HandrailTurnStatus reduce(String status) =>
          const HandrailConversationState(conversationId: 'c1')
              .apply(
                HandrailStreamFrame('terminal', null, {
                  'type': 'terminal',
                  'result': {'status': status},
                }),
              )
              .status;
      expect(reduce('completed'), HandrailTurnStatus.completed);
      expect(reduce('cancelled'), HandrailTurnStatus.cancelled);
      expect(reduce('failed'), HandrailTurnStatus.failed);
      expect(reduce('disconnected'), HandrailTurnStatus.idle);
      final running = const HandrailConversationState(
              conversationId: 'c1',
              status: HandrailTurnStatus.running,
              observationConnected: true)
          .apply(const HandrailStreamFrame('terminal', null, {
        'result': {'status': 'disconnected'}
      }));
      expect(running.status, HandrailTurnStatus.running);
      expect(running.observationConnected, isFalse);
    },
  );

  test(
    'workspace keeps background conversations running and marks completion unread',
    () async {
      final workspace = HandrailConversationWorkspace();
      workspace.open(const HandrailConversationState(conversationId: 'first'));
      workspace.apply(
        'first',
        const HandrailStreamFrame('event', null, {
          'event': {'type': 'response.started'},
        }),
      );
      workspace.open(const HandrailConversationState(conversationId: 'second'));
      workspace.apply(
        'second',
        const HandrailStreamFrame('event', null, {
          'event': {'type': 'response.started'},
        }),
      );
      workspace.apply(
        'first',
        const HandrailStreamFrame('terminal', null, {
          'result': {'status': 'completed'},
        }),
      );

      expect(workspace.snapshot.runningCount, 1);
      expect(workspace.snapshot.unreadCount, 1);
      workspace.select('first');
      expect(workspace.snapshot.unreadCount, 0);
      workspace.replaceRemoteActivity([
        const HandrailConversationActivityRecord(
          conversationId: 'remote-running',
          status: HandrailTurnStatus.running,
          unread: false,
        ),
        const HandrailConversationActivityRecord(
          conversationId: 'remote-done',
          status: HandrailTurnStatus.completed,
          unread: true,
        ),
      ]);
      expect(workspace.snapshot.runningCount, 2);
      expect(workspace.snapshot.unreadCount, 1);
      workspace.markRemoteRead('remote-done');
      expect(workspace.snapshot.unreadCount, 0);
      await workspace.dispose();
    },
  );

  test('reports safe gateway diagnostics for resource failures', () async {
    final diagnostics = <Map<String, Object?>>[];
    final client = HandrailAiClient(
      baseUri: Uri.parse('https://app.example/api/ai'),
      diagnostics: diagnostics.add,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'upstream_unavailable',
              'message': 'Try later',
              'retryable': true,
            },
          }),
          503,
        ),
      ),
    );

    await expectLater(
      client.permanentlyDeleteConversation({'conversationId': 'c1'}),
      throwsA(isA<HandrailGatewayException>()),
    );
    expect(diagnostics.map((event) => event['phase']), ['started', 'failed']);
    expect(diagnostics.last, containsPair('code', 'upstream_unavailable'));
    expect(diagnostics.last, containsPair('retryable', true));
    client.close();
  });

  test('replay deduplicates text and old turns cannot overwrite a new turn',
      () {
    HandrailStreamFrame event(String turn, int sequence, String type,
            [String? delta]) =>
        HandrailStreamFrame('event', '$turn:$sequence', {
          'event': {
            'type': type,
            'request_id': turn,
            'sequence': sequence,
            if (delta != null) 'delta': delta,
          }
        });
    var state = const HandrailConversationState(conversationId: 'c1')
        .apply(event('first', 0, 'response.started'))
        .apply(event('first', 1, 'response.text.delta', 'Hello'));
    state = state.apply(event('first', 1, 'response.text.delta', 'Hello'));
    expect(state.text, 'Hello');
    state = state.apply(event('first', 2, 'response.completed'));
    expect(
        state
            .apply(
                const HandrailStreamFrame('started', null, {'turnId': 'first'}))
            .status,
        HandrailTurnStatus.completed);
    expect(state.apply(event('first', 3, 'response.text.delta', 'Late')).text,
        'Hello');
    state = state.apply(event('second', 0, 'response.started'));
    expect(state.text, isEmpty);
    state = state.apply(event('first', 0, 'response.started'));
    expect(state.turnId, 'second');
    expect(state.status, HandrailTurnStatus.running);
  });

  test(
      'server completion and read state override stale open state, rejecting older activity',
      () async {
    final workspace = HandrailConversationWorkspace();
    workspace.open(const HandrailConversationState(
        conversationId: 'c1',
        turnId: 'turn1',
        turnRevision: 3,
        status: HandrailTurnStatus.running));
    final at = DateTime.utc(2026, 9, 4);
    HandrailConversationActivityRecord record(
            {bool unread = true,
            int revision = 3,
            String turn = 'turn1',
            HandrailTurnStatus status = HandrailTurnStatus.completed}) =>
        HandrailConversationActivityRecord(
            conversationId: 'c1',
            turnId: turn,
            turnRevision: revision,
            status: status,
            unread: unread,
            summary: 'Validating monthly totals',
            progress: const HandrailConversationActivityProgress(
                completed: 2, total: 3, unit: 'tools'),
            updatedAt: at);
    workspace.replaceRemoteActivity([record()]);
    expect(workspace.snapshot.runningCount, 0);
    expect(workspace.snapshot.conversations.single.summary,
        'Validating monthly totals');
    expect(workspace.snapshot.conversations.single.progress?.completed, 2);
    expect(workspace.snapshot.unreadCount, 1);
    expect(workspace.snapshot.conversations.single.state.status,
        HandrailTurnStatus.completed);
    workspace.markRemoteRead('c1');
    workspace.replaceRemoteActivity([record()]);
    expect(workspace.snapshot.unreadCount, 0);
    workspace.replaceRemoteActivity([
      record(
          turn: 'turn2',
          revision: 8,
          status: HandrailTurnStatus.running,
          unread: false)
    ]);
    workspace.replaceRemoteActivity([record()]);
    expect(workspace.snapshot.runningCount, 1);
    expect(workspace.snapshot.conversations.single.state.turnId, 'turn2');
    expect(() => workspace.replaceRemoteActivity([record(), record()]),
        throwsArgumentError);
    expect(workspace.snapshot.runningCount, 1);
    await workspace.dispose();
  });

  test('stale same-turn activity cannot revive canonical completion', () async {
    final workspace = HandrailConversationWorkspace();
    workspace.open(const HandrailConversationState(
        conversationId: 'c1',
        turnId: 'turn1',
        turnRevision: 3,
        status: HandrailTurnStatus.completed));
    workspace.replaceRemoteActivity([
      const HandrailConversationActivityRecord(
          conversationId: 'c1',
          turnId: 'turn1',
          turnRevision: 3,
          status: HandrailTurnStatus.running,
          unread: false)
    ]);
    expect(workspace.snapshot.runningCount, 0);
    await workspace.dispose();
  });

  test(
      'truncated turn streams report disconnected with the last durable checkpoint',
      () async {
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://app.example/api/ai'),
        httpClient: MockClient((_) async => http.Response(
            'event: event\nid: turn:0\ndata: {"event":{"type":"response.started"},"checkpoint":{"lastAppliedCursor":"turn:0"}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'})));
    final frames = await client.startTurn({'conversationId': 'c1'}).toList();
    expect(frames.last.data['result'], {
      'status': 'disconnected',
      'checkpoint': {'lastAppliedCursor': 'turn:0'}
    });
    final state = frames.fold(
        const HandrailConversationState(conversationId: 'c1'),
        (state, frame) => state.apply(frame));
    expect(state.status, HandrailTurnStatus.running);
    expect(state.observationConnected, isFalse);
    client.close();
  });

  test('loads typed cross-device activity records', () async {
    final client = HandrailAiClient(
      baseUri: Uri.parse('https://app.example/api/ai'),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'ok': true,
            'value': [
              {
                'conversationId': 'remote-1',
                'turnStatus': 'completed',
                'unread': true,
                'updatedAt': '2026-01-01T00:00:00.000Z',
                'summary': 'Validating the monthly P&L',
                'progress': {'completed': 3, 'total': 4, 'unit': 'steps'},
              },
            ],
          }),
          200,
        ),
      ),
    );
    final activity = await client.listActivity();
    expect(activity.single.conversationId, 'remote-1');
    expect(activity.single.status, HandrailTurnStatus.completed);
    expect(activity.single.unread, isTrue);
    expect(activity.single.summary, 'Validating the monthly P&L');
    expect(activity.single.progress?.completed, 3);
    expect(activity.single.progress?.total, 4);
    expect(activity.single.progress?.unit, 'steps');
    client.close();
  });

  test('streams typed cross-device activity records', () async {
    final client = HandrailAiClient(
      baseUri: Uri.parse('https://app.example/api/ai'),
      httpClient: MockClient(
        (_) async => http.Response(
          'event: activity\ndata: {"record":{"conversationId":"remote-live","turnStatus":"running","unread":false}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    final activity = await client.activity().single;
    expect(activity.conversationId, 'remote-live');
    expect(activity.status, HandrailTurnStatus.running);
    expect(activity.unread, isFalse);
    client.close();
  });
}
