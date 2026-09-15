/// A caption fragment in the order supplied by the authenticated transport.
/// Display grouping must not turn speech into an instruction or tool outcome.
class HandrailCaptionFragment {
  const HandrailCaptionFragment({
    required this.id,
    required this.speaker,
    required this.text,
  });
  final String id;
  final String speaker;
  final String text;
}

/// Consecutive caption fragments from one speaker, joined without rewriting.
class HandrailCaptionBlock {
  const HandrailCaptionBlock({
    required this.firstFragmentId,
    required this.speaker,
    required this.text,
  });
  final String firstFragmentId;
  final String speaker;
  final String text;
}

/// Makes streamed words readable while preserving exact text and delivery order.
/// A speaker change always starts a block, including overlapping/late speech.
/// [maximumBlockCharacters] bounds grouping; an individual long fragment remains
/// intact. This is presentation only, not inferred utterances or completed turns.
List<HandrailCaptionBlock> handrailCaptionBlocks(
  Iterable<HandrailCaptionFragment> fragments, {
  int maximumBlockCharacters = 2000,
}) {
  if (maximumBlockCharacters < 1) {
    throw ArgumentError.value(maximumBlockCharacters, 'maximumBlockCharacters');
  }
  final blocks = <HandrailCaptionBlock>[];
  final text = StringBuffer();
  String? firstId, speaker;
  void flush() {
    if (firstId == null) return;
    blocks.add(
      HandrailCaptionBlock(
        firstFragmentId: firstId,
        speaker: speaker!,
        text: text.toString(),
      ),
    );
    text.clear();
  }

  for (final fragment in fragments) {
    if (firstId == null ||
        speaker != fragment.speaker ||
        text.length + fragment.text.length > maximumBlockCharacters) {
      flush();
      firstId = fragment.id;
      speaker = fragment.speaker;
    }
    text.write(fragment.text);
  }
  flush();
  return List.unmodifiable(blocks);
}
