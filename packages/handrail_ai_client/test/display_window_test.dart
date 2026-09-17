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
Map<String, Object?> record(int id, {int? revision, int textSize = 0}) => {
      'kind': 'message',
      'id': 'message-$id',
      'revision': revision ?? id,
      'turnId': null,
      'bytes': textSize + 200,
      'deferred': false,
      'value': {
        'message_id': 'message-$id',
        'role': 'user',
        'attachments': [],
        'created_at': null,
        'attribution': null,
        'content': [
          {
            'type': 'text',
            'text': textSize > 0 ? 'a' * textSize : 'Message $id'
          }
        ],
      },
    };
Map<String, Object?> page(String id, List<Map<String, Object?>> records,
        {String? cursor}) =>
    {
      'schemaVersion': 1,
      'status': 'ready',
      'conversationId': id,
      'generation': 0,
      'revision': 100,
      'canonicalRevision': 100,
      'activeTurnId': null,
      'records': records,
      'nextCursor': cursor,
    };
http.Response response(Map<String, Object?> value) =>
    http.Response(jsonEncode({'ok': true, 'value': value}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

class Fixture {
  final requests = <Map<String, Object?>>[];
  final int textSize;
  final changes = <Map<String, Object?>>[];
  String? fail;
  late final HandrailAiClient client;
  late final HandrailDisplayWindow window;
  Fixture({this.textSize = 0}) {
    client = HandrailAiClient(
        baseUri: Uri.parse('https://test.invalid/assistant'),
        httpClient: MockClient((request) async {
          final body =
              Map<String, Object?>.from(jsonDecode(request.body) as Map);
          requests.add(body);
          if (fail != null) {
            final code = fail!;
            fail = null;
            return http.Response(
                jsonEncode({
                  'ok': false,
                  'error': {
                    'code': code,
                    'message': 'fixture',
                    'retryable': code == 'unavailable'
                  }
                }),
                403);
          }
          final input = Map<String, Object?>.from(body['input'] as Map);
          final id = input['conversationId'] as String;
          if (body['operation'] == 'changes')
            return response(changes.isNotEmpty
                ? changes.removeAt(0)
                : {...page(id, []), 'throughRevision': 100});
          final anchor = input['anchor'] as Map?;
          final edge = anchor == null
              ? 21
              : int.parse((anchor['messageId'] as String).split('-').last);
          final count = input['limit'] as int,
              newer = anchor?['direction'] == 'newer';
          final start = newer
              ? edge + (anchor?['inclusive'] == true ? 0 : 1)
              : (edge - count).clamp(1, 21);
          final end = newer ? (start + count - 1).clamp(0, 20) : edge - 1;
          return response(page(
              id,
              [
                for (var i = start; i <= end; i++) record(i, textSize: textSize)
              ],
              cursor: (newer ? end < 20 : start > 1) ? 'more' : null));
        }));
    window = HandrailDisplayWindow(
        client: client,
        capability: capability,
        pageSize: 3,
        pageBytes: 8192,
        maximumMessages: textSize > 0 ? 30 : 6,
        maximumBytes: 16384);
  }
  List<String> get ids =>
      window.state.records.map((record) => record.id).toList(growable: false);
  Future<void> dispose() async {
    await window.dispose();
    client.close();
  }
}

void main() {
  test('message text reads cancel on replacement, selection and disposal',
      () async {
    final requested = <Completer<void>>[
      for (var i = 0; i < 3; i++) Completer<void>()
    ];
    final pending = <Completer<http.Response>>[
      for (var i = 0; i < 3; i++) Completer<http.Response>()
    ];
    var index = 0;
    final client = HandrailAiClient(
      baseUri: Uri.parse('https://test.invalid/assistant'),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final input = body['input'] as Map;
        if (body['operation'] == 'content') {
          final current = index++;
          requested[current].complete();
          return pending[current].future;
        }
        return response(page(input['conversationId'] as String, [record(1)]));
      }),
    );
    final window = HandrailDisplayWindow(
        client: client,
        capability: HandrailDisplayHistoryCapability.fromJson({
          'version': 1,
          'maximumPageSize': 50,
          'maximumPageBytes': 262144,
          'messageText': true,
        }));
    addTearDown(() async {
      await window.dispose();
      client.close();
    });
    await window.select('first');
    final read = window.uiBinding.read()['readMessageText']
        as Future<Map<String, Object?>> Function(
            String, String, int, int, int, Future<void>);
    final cancellation = Completer<void>();
    final first = read('first', 'message-1', 0, 1, 0, cancellation.future);
    await requested[0].future;
    final second = read('first', 'message-1', 0, 1, 8192, cancellation.future);
    await requested[1].future;
    expect((await first)['errorCode'], 'cancelled');
    await window.select('second');
    expect((await second)['errorCode'], 'cancelled');
    final third = read('second', 'message-1', 0, 1, 0, cancellation.future);
    await requested[2].future;
    await window.dispose();
    expect((await third)['errorCode'], 'cancelled');
    cancellation.complete();
    for (final request in pending) {
      request.complete(response({
        'encoding': 'plain-text',
        'text': 'late',
        'revision': 1,
        'nextOffset': null
      }));
    }
    await Future<void>.delayed(Duration.zero);
    expect(window.state.records, isEmpty);
  });

  test(
      'widget binding preserves anchor navigation, errors and selection cancellation',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    final binding = fixture.window.uiBinding;
    await binding.select('chat', {'messageId': 'message-5', 'generation': 0});
    final state = binding.read();
    expect((state['records'] as List).map((record) => (record as Map)['id']),
        ['message-5', 'message-6', 'message-7']);
    expect(state['hasNewer'], isTrue);
    expect(() => (state['records'] as List).clear(), throwsUnsupportedError);
    fixture.fail = 'forbidden';
    await binding.refresh();
    expect(binding.read()['records'], isEmpty);
    expect(binding.read()['error'], 'fixture');
    await binding.select(null, null);
    expect(binding.read()['conversationId'], isNull);
    expect(binding.read()['records'], isEmpty);
  });

  test(
      'bounds retained messages, loads both directions, coalesces reads and restores an anchor',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    final window = fixture.window;
    await window.select('chat');
    expect(fixture.ids, ['message-18', 'message-19', 'message-20']);
    await Future.wait(
        [window.loadOlder(), window.loadOlder(), window.loadOlder()]);
    expect(fixture.requests, hasLength(2));
    expect(fixture.ids, hasLength(6));
    await window.loadOlder();
    expect(fixture.ids, [for (var i = 12; i <= 17; i++) 'message-$i']);
    expect(window.state.hasNewer, isTrue);
    await window.loadNewer();
    expect(fixture.ids, [for (var i = 15; i <= 20; i++) 'message-$i']);
    await window.jumpToLatest();
    expect(fixture.ids, ['message-18', 'message-19', 'message-20']);
    await window.select('chat',
        anchor: const HandrailDisplayAnchor(
            messageId: 'message-5',
            generation: 0,
            newer: true,
            inclusive: true));
    expect(fixture.ids, ['message-5', 'message-6', 'message-7']);
    expect((fixture.requests.last['input'] as Map)['anchor'], {
      'messageId': 'message-5',
      'generation': 0,
      'direction': 'newer',
      'inclusive': true
    });
  });

  test('bounds bytes independently of the message-count limit', () async {
    final fixture = Fixture(textSize: 2000);
    addTearDown(fixture.dispose);
    await fixture.window.select('chat');
    for (var i = 0; i < 6; i++) {
      await fixture.window.loadOlder();
      expect(fixture.window.state.retainedBytes, lessThanOrEqualTo(16384));
      expect(fixture.ids.length, lessThan(9));
    }
  });

  test(
      'advances changes watermark only after the final page without disturbing the reading window',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    await fixture.window.select('chat');
    fixture.changes.addAll([
      {
        ...page('chat', [record(19, revision: 101)], cursor: 'next'),
        'revision': 103,
        'canonicalRevision': 103,
        'throughRevision': 103
      },
      {
        ...page('chat', [record(21, revision: 102)]),
        'revision': 103,
        'canonicalRevision': 103,
        'throughRevision': 103
      },
      {
        ...page('chat', []),
        'revision': 103,
        'canonicalRevision': 103,
        'throughRevision': 103
      },
    ]);
    await fixture.window.refresh();
    await fixture.window.refresh();
    await fixture.window.refresh();
    expect(
        fixture.requests
            .skip(1)
            .map((request) => (request['input'] as Map)['afterRevision'])
            .toList(),
        [100, 100, 103]);
    expect(fixture.ids, ['message-18', 'message-19', 'message-20']);
    expect(fixture.window.state.records[1].revision, 101);
    expect(fixture.window.state.hasNewer, isTrue);
  });

  test(
      'preserves a failed page for retry but evicts text after access revocation',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    await fixture.window.select('chat');
    fixture.fail = 'unavailable';
    await fixture.window.loadOlder();
    expect(fixture.ids, hasLength(3));
    expect(fixture.window.state.failedOperation,
        HandrailDisplayWindowOperation.older);
    await fixture.window.retry();
    expect(fixture.ids, hasLength(6));
    fixture.fail = 'forbidden';
    await fixture.window.refresh();
    expect(fixture.ids, isEmpty);
    expect(fixture.window.state.status, 'error');
  });

  test('switches while a transport is stalled and ignores its late completion',
      () async {
    final pending = Completer<http.Response>(), requested = Completer<void>();
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://test.invalid/assistant'),
        httpClient: MockClient((request) async {
          final id = ((jsonDecode(request.body) as Map)['input']
              as Map)['conversationId'] as String;
          if (id == 'slow') {
            requested.complete();
            return pending.future;
          }
          return response(page(id, [record(2)]));
        }));
    final window =
        HandrailDisplayWindow(client: client, capability: capability);
    addTearDown(() async {
      await window.dispose();
      client.close();
    });
    final slow = window.select('slow');
    await requested.future;
    await window.select('fast');
    await slow;
    pending.complete(response(page('slow', [record(1)])));
    await Future<void>.delayed(Duration.zero);
    expect(window.state.conversationId, 'fast');
    expect(window.state.records.single.id, 'message-2');
    await window.dispose();
    expect(window.state.records, isEmpty);
  });
}
