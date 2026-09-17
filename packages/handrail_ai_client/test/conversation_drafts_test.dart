import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

void main() {
  final values = <String, String>{};
  HandrailKeyValuePendingTurnStore store(String account) =>
      HandrailKeyValuePendingTurnStore(
          namespace: 'api:$account',
          read: (key) async => values[key],
          write: (key, value) async {
            values[key] = value;
          },
          delete: (key) async {
            values.remove(key);
          });
  setUp(values.clear);

  test(
      'reloads account-scoped drafts and refuses stale writes or clears across adapters',
      () async {
    final a = store('a'), b = store('b');
    final saved = await a.writeDraft('chat', 'saved question', null);
    expect(await store('a').readDraft('chat'), saved);
    expect(await b.readDraft('chat'), isNull);
    final results = await Future.wait(['first', 'second'].map((text) async {
      try {
        await store('a').writeDraft('chat', text, saved!['version'] as String);
        return true;
      } on HandrailGatewayException catch (error) {
        expect(error.code, 'draft_conflict');
        return false;
      }
    }));
    expect(results.where((value) => value), hasLength(1));
    await expectLater(
        a.writeDraft('chat', '', saved!['version'] as String),
        throwsA(isA<HandrailGatewayException>()
            .having((error) => error.code, 'code', 'draft_conflict')));
    final latest = await a.readDraft('chat');
    await a.writeDraft('chat', '', latest!['version'] as String);
    expect(await a.readDraft('chat'), isNull);
  });

  test('bounds UTF-8 bytes and count without evicting unsent drafts', () async {
    final a = store('a');
    expect(
        () => a.writeDraft('large', '😀' * 20000, null), throwsArgumentError);
    for (var i = 0; i < 32; i++) {
      await a.writeDraft('c$i', 'kept', null);
    }
    await expectLater(
        a.writeDraft('overflow', 'new', null),
        throwsA(isA<HandrailGatewayException>()
            .having((error) => error.code, 'code', 'draft_storage_full')));
    expect((await a.readDraft('c0'))!['text'], 'kept');
    values.clear();
    for (var i = 0; i < 8; i++) {
      await a.writeDraft('c$i', 'x' * 65536, null);
    }
    await expectLater(a.writeDraft('extra', 'x', null),
        throwsA(isA<HandrailGatewayException>()));
    expect((await a.readDraft('c0'))!['text'], hasLength(65536));
  });

  test('rejects malformed storage without replacing it', () async {
    final a = store('a');
    await a.writeDraft('chat', 'kept', null);
    final key = values.keys.single;
    values[key] = '{"chat":{"version":1,"text":"invalid"}}';
    await expectLater(a.readDraft('chat'), throwsFormatException);
    await expectLater(
        a.writeDraft('chat', 'replacement', null), throwsFormatException);
    expect(values[key], contains('invalid'));
  });
}
