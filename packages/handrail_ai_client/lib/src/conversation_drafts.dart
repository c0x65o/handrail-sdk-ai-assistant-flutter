part of '../handrail_ai_client.dart';

/// Unsent text only, encrypted and partitioned by account and API realm.
/// Implement compare/replace atomically across every writer sharing the store.
abstract interface class HandrailConversationDraftStore {
  Future<Map<String, Object?>?> readDraft(String conversationId);

  /// Empty text removes only the matching revision. A stale revision conflicts.
  Future<Map<String, Object?>?> writeDraft(
      String conversationId, String text, String? expectedVersion);
}

Map<String, Object?> _draftRecord(Map<String, Object?> value) {
  final version = value['version'], text = value['text'];
  if (version is! String ||
      version.isEmpty ||
      version.length > 128 ||
      text is! String ||
      utf8.encode(text).length > 65536) {
    throw const FormatException('Invalid saved draft');
  }
  return Map.unmodifiable({'version': version, 'text': text});
}
