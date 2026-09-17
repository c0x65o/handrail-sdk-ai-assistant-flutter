import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

void main() {
  test(
      'scroll journal survives recreation, isolates accounts and bounds concurrent writers',
      () async {
    final values = <String, String>{};
    HandrailKeyValuePendingTurnStore store(String scope) =>
        HandrailKeyValuePendingTurnStore(
            namespace: scope,
            read: (key) async => values[key],
            write: (key, value) async {
              values[key] = value;
            },
            delete: (key) async {
              values.remove(key);
            });
    final a = store('api/account-a'), secondWriter = store('api/account-a');
    Map<String, Object?> position(int id) => {
          'messageId': 'message-$id',
          'generation': 2,
          'offset': -15.5,
          'following': false
        };
    await Future.wait([
      for (var i = 0; i < 40; i++)
        (i.isEven ? a : secondWriter).writePosition('chat-$i', position(i))
    ]);
    expect(await store('api/account-a').readPosition('chat-39'), position(39));
    expect(await a.readPosition('chat-0'), null);
    expect(await store('api/account-b').readPosition('chat-39'), null);
    expect(await store('other-api/account-a').readPosition('chat-39'), null);
    expect(values.length, 1);
    expect(values.values.single.length, lessThan(8192));
    expect(
        () => a.writePosition('chat', {...position(1), 'offset': double.nan}),
        throwsFormatException);
    expect(await a.readPosition('chat'), null);
  });
}
