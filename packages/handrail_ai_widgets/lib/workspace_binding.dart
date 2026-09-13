import 'dart:async';

/// Matches HandrailAssistantController.uiBinding without a package dependency.
typedef HandrailWorkspaceUploader
    = Future<({Map<String, Object?>? reference, String? errorCode, bool retryable})> Function(
        {required List<int> bytes,
        required String filename,
        required String mediaType,
        required String idempotencyKey,
        required Future<void> cancellation});
typedef HandrailWorkspaceTranscriber
    = Future<({String? text, String? errorCode, bool retryable})> Function(
        {required List<int> bytes,
        required String mediaType,
        required Duration duration,
        required String idempotencyKey,
        required Future<void> cancellation});
typedef HandrailWorkspaceBinding = ({
  Object scope,
  Stream<Object?> changes,
  Future<void> Function() initialize,
  Map<String, Object?> Function() read,
  ({
    Object scope,
    Stream<Object?> changes,
    Map<String, Object?> Function() read,
    Future<void> Function() create,
    Future<void> Function(String) open,
    Future<void> Function(String) archive,
    Future<void> Function(String) restore,
    Future<void> Function(String) view,
    void Function(bool) unread,
    Future<void> Function() loadMore,
    Future<void> Function() refresh
  }) history,
  ({
    Object scope,
    Stream<Object?> changes,
    Map<String, Object?> Function() read,
    Future<void> Function() retry,
    Future<void> Function() markRead
  }) transcript,
  Map<String, Object?> Function(String?) capabilitiesFor,
  HandrailWorkspaceUploader? Function(String?) uploaderFor,
  HandrailWorkspaceTranscriber? Function(String?) transcriberFor,
  HandrailWorkspaceDownloader? Function(String?) downloaderFor,
  Future<bool> Function(
      {required String conversationId,
      required Map<String, Object?> request,
      required void Function() onAccepted}) send,
  Future<void> Function(String conversationId) stop,
});

typedef HandrailWorkspaceDownloader
    = Future<({List<int>? bytes, String? errorCode, bool retryable})> Function({
  required String attachmentId,
  required String mediaType,
  int? byteSize,
  required Future<void> cancellation,
});
