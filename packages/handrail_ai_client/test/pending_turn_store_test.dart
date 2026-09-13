import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

HandrailTurnSubmission submission(String id) =>
    HandrailTurnSubmission.fromJson({
      'version': 1,
      'admission': {'conversationId': 'c1', 'mutations': []},
      'start': {
        'conversationId': 'c1',
        'conversationTurnId': id,
        'mutationId': id,
        'idempotencyKey': id,
        'request': {}
      }
    });
void main() {
  final values = <String, String>{};
  HandrailKeyValuePendingTurnStore store(String account) =>
      HandrailKeyValuePendingTurnStore(
          namespace: 'https://host.test/$account',
          read: (key) async => values[key],
          write: (key, value) async {
            values[key] = value;
          },
          delete: (key) async {
            values.remove(key);
          });
  setUp(values.clear);
  test(
      'restores account-scoped intent and rejects replacement until acknowledgement',
      () async {
    final original = submission('one');
    await store('alice').retain(original);
    expect(await store('bob').load('c1'), isNull);
    expect((await store('alice').load('c1'))!.turnId, 'one');
    await expectLater(store('alice').retain(submission('two')),
        throwsA(isA<HandrailGatewayException>()));
    await store('alice').acknowledge(submission('two'));
    expect((await store('alice').load('c1'))!.turnId, 'one');
    await store('alice').acknowledge(original);
    await store('alice').retain(submission('two'));
    // A late acknowledgement from the previous request cannot erase new intent.
    await store('alice').acknowledge(original);
    expect((await store('alice').load('c1'))!.turnId, 'two');
  });
  test('separate adapters sharing an account serialize overlapping writes',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    final first = HandrailKeyValuePendingTurnStore(
        namespace: 'race',
        read: (key) async => values[key],
        write: (key, value) async {
          entered.complete();
          await release.future;
          values[key] = value;
        },
        delete: (key) async {
          values.remove(key);
        });
    final second = HandrailKeyValuePendingTurnStore(
        namespace: 'race',
        read: (key) async => values[key],
        write: (key, value) async {
          values[key] = value;
        },
        delete: (key) async {
          values.remove(key);
        });
    final saved = first.retain(submission('one'));
    await entered.future;
    final rejected = expectLater(second.retain(submission('two')),
        throwsA(isA<HandrailGatewayException>()));
    release.complete();
    await saved;
    await rejected;
    expect((await second.load('c1'))!.turnId, 'one');
  });
}
