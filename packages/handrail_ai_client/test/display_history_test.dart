import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final capability = HandrailDisplayHistoryCapability.fromJson({
  'version': 1,
  'maximumPageSize': 50,
  'maximumPageBytes': 262144,
});
final base = Uri.parse('https://erp.test/api/assistant');
Map<String, Object?> page({String id = 'chat'}) => {
      'schemaVersion': 1,
      'status': 'ready',
      'conversationId': id,
      'generation': 0,
      'revision': 800,
      'canonicalRevision': 800,
      'activeTurnId': 'turn',
      'records': [
        {
          'kind': 'message',
          'id': 'reply',
          'turnId': 'turn',
          'revision': 800,
          'bytes': 80000,
          'deferred': true,
          'value': null
        }
      ],
      'nextCursor': 'opaque',
    };

void main() {
  test(
      'reads bounded changes with tombstones and preserves the paging watermark',
      () async {
    final requests = <Map<String, Object?>>[];
    final value = {
      ...page(),
      'throughRevision': 800,
      'records': [
        {
          'kind': 'citation',
          'id': 'removed',
          'turnId': null,
          'revision': 800,
          'bytes': 2,
          'deferred': false,
          'deleted': true,
          'value': null,
        }
      ]
    };
    final client = HandrailAiClient(
        baseUri: base,
        httpClient: MockClient((request) async {
          requests
              .add(Map<String, Object?>.from(jsonDecode(request.body) as Map));
          return http.Response(jsonEncode({'ok': true, 'value': value}), 200);
        }));
    addTearDown(client.close);
    final changed = await client.displayHistoryChanges(
        conversationId: 'chat',
        capability: capability,
        generation: 0,
        afterRevision: 799);
    expect(changed.page.records.single.deleted, isTrue);
    expect(changed.throughRevision, 800);
    expect(changed.page.nextCursor, 'opaque');
    expect(requests, hasLength(1));
    expect(requests.single['operation'], 'changes');
    expect(() => HandrailDisplayPage.fromJson(value), throwsFormatException);
    expect(
        () =>
            HandrailDisplayChanges.fromJson({...value, 'throughRevision': 799}),
        throwsFormatException);
    await expectLater(
        client.displayHistoryChanges(
            conversationId: 'chat',
            capability: capability,
            generation: 0,
            afterRevision: 800),
        throwsFormatException);
  });

  test(
      'negotiates display history without treating a partial page as a canonical snapshot',
      () {
    expect(HandrailGatewayCapabilities.fromJson({}).displayHistory, isNull);
    final caps = HandrailGatewayCapabilities.fromJson({
      'synchronization': false,
      'displayHistory': {
        'version': 1,
        'maximumPageSize': 50,
        'maximumPageBytes': 262144
      }
    });
    expect(caps.displayHistory!.maximumPageBytes, 262144);
    expect(caps.synchronization, isFalse);
    final loaded = HandrailDisplayPage.fromJson(page());
    expect(loaded.records.single.deferred, isTrue);
    expect(loaded.records.single.value, isNull);
    expect(loaded.revision, 800);
    expect(
        () => HandrailDisplayPage.fromJson({...page(), 'status': 'preparing'}),
        throwsFormatException);
    expect(
        () =>
            HandrailDisplayPage.fromJson({...page(), 'canonicalRevision': 799}),
        throwsFormatException);
    expect(
        () => HandrailDisplayPage.fromJson({
              ...page(),
              'records': [
                ...(page()['records'] as List),
                ...(page()['records'] as List)
              ]
            }),
        throwsFormatException);
  });

  test('uses protected requests and keeps paging explicit', () async {
    final requests = <http.Request>[];
    final client = HandrailAiClient(
        baseUri: base,
        protectedHeaders: () => {'authorization': 'Bearer fixture'},
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode({'ok': true, 'value': page()}), 200);
        }));
    addTearDown(client.close);
    final first = await client.displayHistoryPage(
        conversationId: 'chat', capability: capability);
    expect(requests, hasLength(1)); // no eager follow-up of nextCursor
    await client.displayHistoryPage(
        conversationId: 'chat',
        capability: capability,
        cursor: first.nextCursor);
    expect(requests, hasLength(2));
    expect(requests.first.url.toString(),
        'https://erp.test/api/assistant/conversations/history');
    expect(requests.first.followRedirects, isFalse);
    expect(requests.first.headers['authorization'], 'Bearer fixture');
    expect(jsonDecode(requests.last.body), {
      'operation': 'page',
      'input': {
        'conversationId': 'chat',
        'limit': 30,
        'maximumBytes': 65536,
        'cursor': 'opaque'
      }
    });
  });

  test(
      'preserves explicit clear/content conflicts and rejects wrong-account response identities',
      () async {
    var attempt = 0;
    final client = HandrailAiClient(
        baseUri: base,
        httpClient: MockClient((_) async {
          if (attempt++ == 0)
            return http.Response(
                jsonEncode({
                  'ok': false,
                  'error': {
                    'code': 'conflict',
                    'message': 'History was cleared',
                    'retryable': false
                  },
                  'resourceError': {
                    'domain': 'display_history',
                    'code': 'stale_cursor'
                  }
                }),
                409);
          return http.Response(
              jsonEncode({'ok': true, 'value': page(id: 'another-chat')}), 200);
        }));
    addTearDown(client.close);
    await expectLater(
        client.displayHistoryPage(
            conversationId: 'chat', capability: capability),
        throwsA(isA<HandrailGatewayException>()
            .having((error) => error.code, 'code', 'stale_cursor')));
    await expectLater(
        client.displayHistoryPage(
            conversationId: 'chat', capability: capability),
        throwsFormatException);
  });

  test('reads Unicode content using server offsets and rejects mixed revisions',
      () async {
    var attempt = 0;
    final client = HandrailAiClient(
        baseUri: base,
        httpClient: MockClient((request) async {
          final input = (jsonDecode(request.body) as Map)['input'] as Map;
          expect(input['offset'], attempt == 0 ? 0 : 2);
          return http.Response(
              jsonEncode({
                'ok': true,
                'value': {
                  'encoding': 'json-text',
                  'text': '🙂a',
                  'revision': attempt++ == 0 ? 800 : 801,
                  'nextOffset': 2
                }
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(client.close);
    final first = await client.displayHistoryContent(
        conversationId: 'chat', generation: 0, kind: 'message', id: 'reply');
    expect(first.nextOffset, 2);
    expect(first.text.length, 3);
    await expectLater(
        client.displayHistoryContent(
            conversationId: 'chat',
            generation: 0,
            kind: 'message',
            id: 'reply',
            revision: first.revision,
            offset: first.nextOffset!),
        throwsFormatException);
  });

  test(
      'cancels an obsolete selection while credentials are pending without issuing a request',
      () async {
    final headers = Completer<Map<String, String>>(),
        cancel = Completer<void>();
    var calls = 0;
    final client = HandrailAiClient(
        baseUri: base,
        protectedHeaders: () => headers.future,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    final pending = client.displayHistoryPage(
        conversationId: 'chat',
        capability: capability,
        cancellation: cancel.future);
    final expectation = expectLater(
        pending,
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'cancelled')));
    cancel.complete();
    await expectation;
    headers.complete({});
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
  });

  test('rejects oversized responses before parsing content', () async {
    final client = HandrailAiClient(
        baseUri: base,
        httpClient: MockClient((_) async => http.Response('a' * 66561, 200)));
    addTearDown(client.close);
    await expectLater(
        client.displayHistoryPage(
            conversationId: 'chat', capability: capability),
        throwsFormatException);
  });
}
