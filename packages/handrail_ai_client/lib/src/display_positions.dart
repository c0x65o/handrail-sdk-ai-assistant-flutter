part of '../handrail_ai_client.dart';

/// Account/API-scoped scroll anchors. No transcript content or attachments.
abstract interface class HandrailConversationPositionStore {
  Future<Map<String, Object?>?> readPosition(String conversationId);
  Future<void> writePosition(
      String conversationId, Map<String, Object?> position);
}

Map<String, Object?> _displayPosition(Map<String, Object?> value) {
  final id = value['messageId'],
      generation = value['generation'],
      offset = value['offset'];
  if (!_historyId(id) ||
      generation is! int ||
      generation < 0 ||
      generation > 9007199254740991 ||
      offset is! num ||
      !offset.isFinite ||
      offset.abs() > 100000000 ||
      value['following'] is! bool) {
    throw const FormatException('Invalid conversation scroll position');
  }
  return Map.unmodifiable({
    'messageId': id,
    'generation': generation,
    'offset': offset.toDouble(),
    'following': value['following']
  });
}

extension _HandrailPositionJournal on HandrailKeyValuePendingTurnStore {
  String get _positionKey =>
      'handrail.positions.v1.${base64Url.encode(utf8.encode(namespace))}';
  Future<Map<String, Object?>> _readPositions(String key) async {
    final raw = await read(key);
    if (raw == null) return {};
    if (raw.length > 131072)
      throw const FormatException('Invalid scroll position journal');
    final decoded = _object(jsonDecode(raw));
    if (decoded.length > 32)
      throw const FormatException('Invalid scroll position journal');
    return {
      for (final entry in decoded.entries)
        entry.key: _displayPosition(_object(entry.value))
    };
  }
}
