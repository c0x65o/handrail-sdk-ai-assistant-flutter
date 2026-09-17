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
  'control': true,
});
Map<String, Object?> control() {
  final turn = {
    'turnId': 'turn',
    'revision': 100,
    'status': 'running',
    'remoteMayStillBeRunning': true,
    'error': null
  };
  return {
    'schemaVersion': 1,
    'status': 'ready',
    'conversationId': 'chat',
    'generation': 0,
    'revision': 100,
    'canonicalRevision': 100,
    'activeTurnId': 'turn',
    'activeTurn': turn,
    'latestTurn': turn,
    'requestedTurn': turn
  };
}

void main() {
  test(
      'rejects incomplete, future and contradictory controls before session use',
      () {
    for (final invalid in [
      {...control()}..remove('activeTurn'),
      {...control(), 'activeTurn': null},
      {
        ...control(),
        'activeTurn': {...(control()['activeTurn'] as Map), 'revision': 101}
      },
      {
        ...control(),
        'activeTurn': {
          ...(control()['activeTurn'] as Map),
          'status': 'completed'
        }
      },
      {...control(), 'status': 'preparing'},
    ]) {
      expect(() => HandrailDisplayControl.fromJson(invalid),
          throwsFormatException);
    }
    expect(
        HandrailDisplayControl.fromJson({
          ...control(),
          'status': 'preparing',
          'activeTurn': null,
          'latestTurn': null,
          'requestedTurn': null
        }).preparing,
        isTrue);
  });

  test(
      'reads protected scalar controls and rejects cross-conversation and turn responses',
      () async {
    var response = control();
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://test.invalid/assistant'),
        protectedHeaders: () async => {'authorization': 'Bearer fixture'},
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer fixture');
          expect(jsonDecode(request.body), {
            'operation': 'control',
            'input': {'conversationId': 'chat', 'turnId': 'turn'}
          });
          return http.Response(
              jsonEncode({'ok': true, 'value': response}), 200);
        }));
    addTearDown(client.close);
    final value = await client.displayHistoryControl(
        conversationId: 'chat', turnId: 'turn', capability: capability);
    expect(value.activeTurn?.status, 'running');
    expect(value.revision, 100);
    response = {...control(), 'conversationId': 'other'};
    await expectLater(
        client.displayHistoryControl(
            conversationId: 'chat', turnId: 'turn', capability: capability),
        throwsFormatException);
    response = {
      ...control(),
      'requestedTurn': {
        ...(control()['requestedTurn'] as Map),
        'turnId': 'other'
      }
    };
    await expectLater(
        client.displayHistoryControl(
            conversationId: 'chat', turnId: 'turn', capability: capability),
        throwsFormatException);
  });
  test(
      'old gateways do not opt in, and pending credentials can be cancelled without a request',
      () async {
    final old = HandrailDisplayHistoryCapability.fromJson(
        {'version': 1, 'maximumPageSize': 50, 'maximumPageBytes': 262144});
    final cancelled = Completer<void>(),
        credentials = Completer<Map<String, String>>();
    var calls = 0;
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://test.invalid/assistant'),
        protectedHeaders: () => credentials.future,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 500);
        }));
    addTearDown(client.close);
    await expectLater(
        client.displayHistoryControl(conversationId: 'chat', capability: old),
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'display_control_unavailable')));
    final pending = client.displayHistoryControl(
        conversationId: 'chat',
        capability: capability,
        cancellation: cancelled.future);
    cancelled.complete();
    await expectLater(pending, throwsA(isA<HandrailGatewayException>()));
    credentials.complete({});
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
  });
}
