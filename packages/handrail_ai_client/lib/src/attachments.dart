part of '../handrail_ai_client.dart';

/// Optional UI upload result. The UI depends only on this structural record.
typedef HandrailAttachmentUploadResult = ({
  Map<String, Object?>? reference,
  String? errorCode,
  bool retryable,
});

extension HandrailClientAttachments on HandrailAiClient {
  /// Binds file intake to the same authenticated gateway as the conversation.
  Future<HandrailAttachmentUploadResult> Function({
    required List<int> bytes,
    required String filename,
    required String mediaType,
    required String idempotencyKey,
    required Future<void> cancellation,
  }) attachmentUploader(
          {int maximumBytes = 20 * 1024 * 1024, String? conversationId}) =>
      (
          {required bytes,
          required filename,
          required mediaType,
          required idempotencyKey,
          required cancellation}) async {
        try {
          final result = await uploadAttachment(
              bytes: bytes,
              filename: filename,
              mediaType: mediaType,
              kind: mediaType.startsWith('image/') ? 'image' : 'document',
              idempotencyKey: idempotencyKey,
              conversationId: conversationId,
              cancellation: cancellation,
              maximumBytes: maximumBytes);
          return (
            reference:
                Map<String, Object?>.unmodifiable(result['value']! as Map),
            errorCode: null,
            retryable: false
          );
        } on HandrailGatewayException catch (error) {
          return (
            reference: null,
            errorCode: error.code,
            retryable: error.retryable
          );
        } catch (_) {
          return (
            reference: null,
            errorCode: 'upload_unavailable',
            retryable: true
          );
        }
      };

  Future<Map<String, Object?>> _uploadAttachment({
    required List<int> bytes,
    required String filename,
    required String mediaType,
    required String kind,
    required String idempotencyKey,
    String? conversationId,
    Future<void>? cancellation,
    int maximumBytes = 20 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (bytes.isEmpty ||
        bytes.length > maximumBytes ||
        maximumBytes < 1 ||
        maximumBytes > 50 * 1024 * 1024 ||
        bytes.any((byte) => byte < 0 || byte > 255) ||
        filename.isEmpty ||
        filename.length > 255 ||
        filename == '.' ||
        filename == '..' ||
        RegExp(r'[\x00-\x1f\x7f/\\]').hasMatch(filename) ||
        !RegExp(r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$')
            .hasMatch(mediaType) ||
        kind != (mediaType.startsWith('image/') ? 'image' : 'document') ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$')
            .hasMatch(idempotencyKey) ||
        timeout <= Duration.zero ||
        conversationId != null && !_validSavedAttachmentId(conversationId)) {
      throw _attachmentFailure('invalid_attachment');
    }
    final captured = Uint8List.fromList(bytes);
    final abort = Completer<void>();
    var expired = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(cancellation?.then((_) => cancel(), onError: (_) => cancel()));
    final deadline = Timer(timeout, () {
      expired = true;
      cancel();
    });
    Future<T> cancellable<T>(Future<T> work) => Future.any([
          work,
          abort.future.then<T>((_) => throw _attachmentFailure(
              expired ? 'upload_timeout' : 'cancelled'))
        ]);
    final started = DateTime.now();
    _diagnose('/attachments', 'started');
    Future<Map<String, Object?>> execute() async {
      try {
        final headers = await cancellable(_headers());
        if (abort.isCompleted) throw _attachmentFailure('cancelled');
        final request = http.AbortableMultipartRequest(
            'POST', _uri('/attachments'), abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..fields.addAll({
            'kind': kind,
            'mediaType': mediaType,
            'idempotencyKey': idempotencyKey,
            if (conversationId != null) 'conversationId': conversationId,
          })
          ..files.add(http.MultipartFile.fromBytes('file', captured,
              filename: filename,
              contentType: http.MediaType.parse(mediaType)));
        final response = await _http.send(request);
        if (abort.isCompleted) {
          await response.stream.listen((_) {}).cancel();
          throw _attachmentFailure(expired ? 'upload_timeout' : 'cancelled');
        }
        final body = BytesBuilder(copy: false);
        final stream = StreamIterator<List<int>>(response.stream);
        try {
          while (await cancellable(stream.moveNext())) {
            if (body.length + stream.current.length > 32 * 1024)
              throw _attachmentFailure('invalid_upload_response');
            body.add(stream.current);
          }
        } finally {
          await stream.cancel();
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _attachmentFailure(switch (response.statusCode) {
            401 => 'unauthenticated',
            403 => 'forbidden',
            409 => 'upload_conflict',
            413 => 'attachment_too_large',
            415 || 422 => 'invalid_attachment',
            429 => 'rate_limited',
            >= 500 => 'upload_unavailable',
            _ => 'invalid_upload_response',
          });
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(body.takeBytes()));
        } on FormatException {
          throw _attachmentFailure('invalid_upload_response');
        }
        if (decoded is! Map ||
            decoded['ok'] != true ||
            decoded['value'] is! Map)
          throw _attachmentFailure('invalid_upload_response');
        final reference = Map<String, Object?>.from(decoded['value'] as Map);
        if (!_validAttachmentReference(
            reference, filename, mediaType, captured.length))
          throw _attachmentFailure('invalid_upload_response');
        return {
          'ok': true,
          'value': Map<String, Object?>.unmodifiable(reference)
        };
      } finally {
        captured.fillRange(0, captured.length, 0);
      }
    }

    try {
      final result = await cancellable(execute());
      _diagnose('/attachments', 'succeeded', started: started);
      return result;
    } catch (error) {
      final failure = error is HandrailGatewayException
          ? error
          : _attachmentFailure(abort.isCompleted
              ? expired
                  ? 'upload_timeout'
                  : 'cancelled'
              : 'upload_unavailable');
      _diagnose('/attachments', 'failed',
          started: started, code: failure.code, retryable: failure.retryable);
      throw failure;
    } finally {
      deadline.cancel();
    }
  }
}

bool _validAttachmentReference(
    Map<String, Object?> value, String filename, String mediaType, int size) {
  final id = value['attachment_id'], ref = value['content_ref'];
  return value.keys.every(const {
        'attachment_id',
        'content_ref',
        'media_type',
        'byte_size',
        'filename'
      }.contains) &&
      id is String &&
      RegExp(r'^att_[A-Za-z0-9][A-Za-z0-9._-]{0,251}$').hasMatch(id) &&
      ref is String &&
      RegExp(r'^ref_[A-Za-z0-9][A-Za-z0-9._-]{0,251}$').hasMatch(ref) &&
      value['media_type'] == mediaType &&
      value['byte_size'] == size &&
      value['filename'] == filename;
}

HandrailGatewayException _attachmentFailure(String code) =>
    HandrailGatewayException(
        code,
        switch (code) {
          'cancelled' => 'File upload cancelled.',
          'unauthenticated' => 'Sign in again before uploading a file.',
          'forbidden' => 'This account cannot upload this file.',
          'attachment_too_large' => 'This file exceeds the upload limit.',
          'invalid_attachment' =>
            'Choose a supported file within the upload limits.',
          'upload_conflict' => 'The saved upload does not match this file.',
          'invalid_upload_response' =>
            'The uploaded file could not be verified.',
          _ => 'The file upload could not be confirmed. Retry the same upload.',
        },
        retryable: const {
          'upload_timeout',
          'upload_unavailable',
          'rate_limited'
        }.contains(code));
