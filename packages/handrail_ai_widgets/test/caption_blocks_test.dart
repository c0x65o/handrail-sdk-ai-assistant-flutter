import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  HandrailCaptionFragment fragment(String id, String speaker, String text) =>
      HandrailCaptionFragment(id: id, speaker: speaker, text: text);

  test(
    'joins streamed words without trimming, deduplication or invented spaces',
    () {
      final blocks = handrailCaptionBlocks([
        fragment('one', 'user', ' Add'),
        fragment('two', 'user', ' a '),
        fragment('three', 'user', 'field field'),
        fragment('four', 'user', '. '),
      ]);
      expect(blocks, hasLength(1));
      expect(blocks.single.firstFragmentId, 'one');
      expect(blocks.single.text, ' Add a field field. ');
    },
  );

  test('preserves overlapping speaker switches and late delivery order', () {
    final blocks = handrailCaptionBlocks([
      fragment('one', 'user', 'Please '),
      fragment('two', 'assistant', 'One moment'),
      fragment('three', 'user', 'continue'),
      fragment('late', 'assistant', ' please'),
    ]);
    expect(blocks.map((b) => (b.speaker, b.text)), [
      ('user', 'Please '),
      ('assistant', 'One moment'),
      ('user', 'continue'),
      ('assistant', ' please'),
    ]);
  });

  test(
    'new pages extend the same display block without changing its identity',
    () {
      final first = [fragment('one', 'assistant', 'Waiting')];
      final before = handrailCaptionBlocks(first).single;
      final after = handrailCaptionBlocks([
        ...first,
        fragment('two', 'assistant', ' for review.'),
      ]).single;
      expect(after.firstFragmentId, before.firstFragmentId);
      expect(before.text, 'Waiting');
      expect(after.text, 'Waiting for review.');
    },
  );

  test(
    'bounds grouping while retaining oversized fragments and empty input',
    () {
      final blocks = handrailCaptionBlocks([
        fragment('one', 'user', '123'),
        fragment('two', 'user', '45'),
        fragment('three', 'user', '6'),
        fragment('four', 'user', '1234567'),
      ], maximumBlockCharacters: 5);
      expect(blocks.map((b) => b.text), ['12345', '6', '1234567']);
      expect(() => blocks.clear(), throwsUnsupportedError);
      expect(handrailCaptionBlocks([]), isEmpty);
      expect(
        () => handrailCaptionBlocks([], maximumBlockCharacters: 0),
        throwsArgumentError,
      );
    },
  );
}
