part of '../handrail_ai_client.dart';

/// Structural account binding consumed by the optional Flutter workspace.
/// Keeping this record structural leaves the headless client Flutter-independent.
typedef HandrailUiUploader
    = Future<({Map<String, Object?>? reference, String? errorCode, bool retryable})> Function(
        {required List<int> bytes,
        required String filename,
        required String mediaType,
        required String idempotencyKey,
        required Future<void> cancellation});
typedef HandrailUiTranscriber
    = Future<({String? text, String? errorCode, bool retryable})> Function(
        {required List<int> bytes,
        required String mediaType,
        required Duration duration,
        required String idempotencyKey,
        required Future<void> cancellation});
typedef HandrailAssistantUiBinding = ({
  Object scope,
  Stream<Object?> changes,
  HandrailApprovalUiBinding approvals,
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
    Future<void> Function(String, int) delete,
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
  HandrailUiUploader? Function(String?) uploaderFor,
  HandrailUiTranscriber? Function(String?) transcriberFor,
  HandrailAttachmentDownloader? Function(String?) downloaderFor,
  Future<bool> Function(
      {required String conversationId,
      required Map<String, Object?> request,
      required void Function() onAccepted}) send,
  Future<void> Function(String conversationId) stop,
});

extension HandrailAssistantOptionalUi on HandrailAssistantController {
  HandrailAssistantUiBinding get uiBinding => (
        scope: this,
        changes: changes,
        initialize: initialize,
        approvals: approvals.uiBinding,
        history: historyBinding,
        transcript: transcriptBinding,
        read: () => {
              if (_draftStorage case final storage?)
                'draftStorage': {
                  'read': storage.readDraft,
                  'write': storage.writeDraft,
                },
              'conversationId': selectedId,
              'enabled': document != null &&
                  !archived &&
                  !hasPendingDeletion(selectedId!),
              'deletedConversationIds': deletedConversationIds.toList(),
              'canSend': canSend,
              'running': running,
              'submitting': submitting,
              'canStop': canStop,
              'stopping': stopping,
              'workingAnywhere': workingAnywhere,
              'error': error?.message,
            },
        capabilitiesFor: (id) => {
              'attachments': sessionFor(id)?.capabilities?.attachments,
              'documentInput': sessionFor(id)?.capabilities?.documentInput,
              'attachmentDownloadMaximumBytes': sessionFor(id)
                  ?.capabilities
                  ?.attachmentDownloads
                  ?.maximumBytes,
              'transcriptionMaximumBytes':
                  sessionFor(id)?.capabilities?.transcription?.maximumBytes,
              'transcriptionMaximumDurationSeconds': sessionFor(id)
                  ?.capabilities
                  ?.transcription
                  ?.maximumDurationSeconds,
            },
        uploaderFor: (id) {
          final capabilities = sessionFor(id)?.capabilities?.attachments;
          if (id == null || capabilities == null || hasPendingDeletion(id))
            return null;
          return client.attachmentUploader(
              conversationId: id,
              maximumBytes: capabilities['maximumBytesPerFile'] as int? ??
                  20 * 1024 * 1024);
        },
        downloaderFor: (id) {
          final capability = sessionFor(id)?.capabilities?.attachmentDownloads;
          if (id == null || capability == null) return null;
          return client.attachmentDownloader(
              conversationId: id, capability: capability);
        },
        transcriberFor: (id) {
          final capability = sessionFor(id)?.capabilities?.transcription;
          if (id == null ||
              hasPendingDeletion(id) ||
              capability == null ||
              capability.formats['audio/wav'] != 'wav' ||
              capability.maximumBytes < 46 ||
              capability.maximumDurationSeconds < .001) return null;
          return client.transcriptionForConversation(id,
              capability: capability);
        },
        send: (
            {required conversationId,
            required request,
            required onAccepted}) async {
          final operation = _createId();
          final submitted = await sendMessage(request,
              conversationId: conversationId,
              operationId: operation,
              onAccepted: (_) => onAccepted());
          if (submitted == null) return false;
          // Catalog presentation must never turn verified admission into a failure.
          try {
            await sessionFor(conversationId)?.refresh();
            final messages = _records(request['messages']);
            final last = messages.lastWhere(
                (message) => message['role'] == 'user',
                orElse: () => const {});
            final parts = _records(last['content']);
            final text = parts
                .where((part) => part['type'] == 'text')
                .map((part) => part['text'] as String? ?? '')
                .join(' ')
                .trim();
            final files = parts.where((part) => part['attachment'] is Map).map(
                (part) =>
                    (part['attachment'] as Map)['filename'] as String? ??
                    'Attachment');
            await setInitialTitle(conversationId,
                text.isNotEmpty ? text : files.join(', '), operation);
          } catch (_) {}
          return true;
        },
        stop: (id) => requestCancellation(conversationId: id),
      );
}
