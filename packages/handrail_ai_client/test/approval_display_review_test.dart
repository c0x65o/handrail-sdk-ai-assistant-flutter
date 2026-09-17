import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final binding = 'a' * 64, proposalBinding = 'b' * 64;
  Map<String, Object?> review(int offset) => {
        'schemaVersion': 1,
        'status': 'ready',
        'conversationId': 'chat',
        'generation': 0,
        'proposalId': 'proposal',
        'review': {
          'binding': binding,
          'proposalBinding': proposalBinding,
          'proposalVersion': 1,
          'groupId': 'chat',
          'turnId': 'turn',
          'toolCallId': 'tool',
          'toolName': 'send',
          'argumentReference': 'args-sha256-$binding',
          'offset': offset,
          'text': offset == 0 ? '🙂' * 8192 : 'last',
          'nextOffset': offset == 0 ? 8192 : null
        },
      };
  final decision = <String, Object?>{
    'conversationId': 'chat',
    'proposalId': 'proposal',
    'expectedVersion': 1,
    'status': 'confirmed',
    'idempotencyKey': 'choice',
    'idempotencyFingerprint': 'choice',
    'proposalBinding': proposalBinding
  };
  Map<String, Object?> receipt() => {
        'schemaVersion': 1,
        'conversationId': 'chat',
        'proposalId': 'proposal',
        'proposalVersion': 2,
        'status': 'confirmed',
        'proposalBinding': proposalBinding
      };
  test(
      'sections and compact receipts share protected bounded HTTP without argument assembly',
      () async {
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://erp.test/assistant'),
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          final value =
              request.url.path.endsWith('/approvals/transition-display')
                  ? receipt()
                  : review((body['input'] as Map)['offset'] as int);
          if (request.url.path.endsWith('/approvals/transition-display'))
            expect(body, decision);
          else
            expect(body['operation'], 'approval_review');
          return http.Response(jsonEncode({'ok': true, 'value': value}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(client.close);
    final first = await client.displayApprovalReview(
        conversationId: 'chat', proposalId: 'proposal', generation: 0);
    expect((first.section!['text'] as String).runes.length, 8192);
    final last = await client.displayApprovalReview(
        conversationId: 'chat',
        proposalId: 'proposal',
        generation: 0,
        binding: binding,
        offset: 8192);
    expect(last.section!['text'], 'last');
    expect(await client.displayApprovalDecision(decision), receipt());
    await expectLater(
        client.displayApprovalReview(
            conversationId: 'chat',
            proposalId: 'proposal',
            generation: 0,
            offset: 8192),
        throwsArgumentError);
  });
  test(
      'rejects changed identities, invalid Unicode page bounds and forged decision receipts',
      () async {
    var response = review(0);
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://erp.test'),
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({'ok': true, 'value': response}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    addTearDown(client.close);
    for (final invalid in [
      {...review(0), 'conversationId': 'other'},
      {
        ...review(0),
        'review': {...review(0)['review'] as Map, 'binding': 'c' * 64}
      },
      {
        ...review(0),
        'review': {
          ...review(0)['review'] as Map,
          'text': 'short',
          'nextOffset': 5
        }
      },
      {
        ...review(0),
        'review': {
          ...review(0)['review'] as Map,
          'text': 'x' * 8193,
          'nextOffset': null
        }
      },
    ]) {
      response = invalid;
      await expectLater(
          client.displayApprovalReview(
              conversationId: 'chat',
              proposalId: 'proposal',
              generation: 0,
              binding: binding),
          throwsFormatException);
    }
    response = {...receipt(), 'proposalVersion': 9};
    await expectLater(
        client.displayApprovalDecision(decision), throwsFormatException);
    response = {...receipt(), 'excess': 'x' * 8192};
    await expectLater(
        client.displayApprovalDecision(decision), throwsFormatException);
  });
  test('cancels a stalled approval review before receiving its body', () async {
    final gate = Completer<http.Response>(), cancel = Completer<void>();
    final client = HandrailAiClient(
        baseUri: Uri.parse('https://erp.test'),
        httpClient: MockClient((_) => gate.future));
    addTearDown(client.close);
    final read = client.displayApprovalReview(
        conversationId: 'chat',
        proposalId: 'proposal',
        generation: 0,
        cancellation: cancel.future);
    cancel.complete();
    await expectLater(read, throwsA(isA<HandrailGatewayException>()));
    gate.complete(http.Response('{}', 200));
  });
}
