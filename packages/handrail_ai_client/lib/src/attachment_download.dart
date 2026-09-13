part of '../handrail_ai_client.dart';

/// Negotiated independently of whether the account can upload new files.
class HandrailAttachmentDownloadCapability {
  const HandrailAttachmentDownloadCapability._(this.maximumBytes, this.url);
  final int maximumBytes;
  final String? url;
  factory HandrailAttachmentDownloadCapability.fromJson(
      Map<String, Object?> json) {
    final bytes = json['maximumBytes'], url = json['url'];
    if (bytes is! int ||
        bytes < 1 ||
        bytes > 50 * 1024 * 1024 ||
        url != null && (url is! String || url.isEmpty || url.length > 2048)) {
      throw const FormatException('Invalid attachment download capability.');
    }
    return HandrailAttachmentDownloadCapability._(bytes, url as String?);
  }

  Uri resolveEndpoint(Uri baseUri) {
    final root = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
    final endpoint =
        baseUri.replace(path: '$root/').resolve(url ?? 'attachments/content');
    if (endpoint.scheme != baseUri.scheme ||
        endpoint.authority != baseUri.authority ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        !endpoint.path.startsWith('$root/') ||
        endpoint.pathSegments.any((part) =>
            part == '.' ||
            part == '..' ||
            part.contains('/') ||
            part.contains('\\'))) {
      throw const HandrailGatewayException('invalid_gateway_url',
          'The attachment endpoint is outside the assistant gateway.');
    }
    return endpoint;
  }
}

typedef HandrailAttachmentDownloadResult = ({
  List<int>? bytes,
  String? errorCode,
  bool retryable
});
typedef HandrailAttachmentDownloader = Future<HandrailAttachmentDownloadResult>
    Function({
  required String attachmentId,
  required String mediaType,
  int? byteSize,
  required Future<void> cancellation,
});

bool _validSavedAttachmentId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,255}$').hasMatch(value);

extension HandrailClientAttachmentDownloads on HandrailAiClient {
  HandrailAttachmentDownloader attachmentDownloader(
          {required String conversationId,
          required HandrailAttachmentDownloadCapability capability}) =>
      (
          {required attachmentId,
          required mediaType,
          byteSize,
          required cancellation}) async {
        try {
          return (
            bytes: await downloadAttachment(
                conversationId: conversationId,
                attachmentId: attachmentId,
                mediaType: mediaType,
                byteSize: byteSize,
                cancellation: cancellation,
                capability: capability),
            errorCode: null,
            retryable: false
          );
        } on HandrailGatewayException catch (error) {
          return (
            bytes: null,
            errorCode: error.code,
            retryable: error.retryable
          );
        } catch (_) {
          return (
            bytes: null,
            errorCode: 'download_unavailable',
            retryable: true
          );
        }
      };

  /// Reads retained bytes through the protected gateway without changing expiry.
  Future<Uint8List> downloadAttachment(
      {required String conversationId,
      required String attachmentId,
      required String mediaType,
      required HandrailAttachmentDownloadCapability capability,
      int? byteSize,
      Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    if (!_validSavedAttachmentId(conversationId) ||
        !_validSavedAttachmentId(attachmentId) ||
        !RegExp(r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$')
            .hasMatch(mediaType) ||
        timeout <= Duration.zero ||
        byteSize != null &&
            (byteSize < 1 || byteSize > capability.maximumBytes)) {
      throw _downloadFailure('invalid_attachment');
    }
    final endpoint = capability.resolveEndpoint(baseUri);
    final uri = endpoint.replace(queryParameters: {
      ...endpoint.queryParameters,
      'conversationId': conversationId,
      'attachmentId': attachmentId
    });
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
          abort.future.then<T>((_) => throw _downloadFailure(
              expired ? 'download_timeout' : 'cancelled'))
        ]);
    final started = DateTime.now();
    _diagnose('/attachments/content', 'started');
    Future<Uint8List> execute() async {
      final headers = await cancellable(_headers());
      if (abort.isCompleted) throw _downloadFailure('cancelled');
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({...headers, 'accept': mediaType});
      final response = await _http.send(request);
      if (abort.isCompleted) {
        unawaited(response.stream.listen((_) {}).cancel());
        throw _downloadFailure(expired ? 'download_timeout' : 'cancelled');
      }
      final stream = StreamIterator<List<int>>(response.stream);
      try {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _downloadFailure(switch (response.statusCode) {
            401 => 'unauthenticated',
            403 => 'forbidden',
            404 || 410 => 'attachment_expired',
            429 => 'rate_limited',
            >= 500 => 'download_unavailable',
            _ => 'invalid_download_response',
          });
        }
        final declared = response.headers['content-length'];
        final length = declared == null ? null : int.tryParse(declared);
        if (response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                mediaType ||
            declared != null &&
                (length == null ||
                    length < 1 ||
                    length > capability.maximumBytes ||
                    byteSize != null && length != byteSize)) {
          throw _downloadFailure('invalid_download_response');
        }
        final body = BytesBuilder(copy: false);
        while (await cancellable(stream.moveNext())) {
          if (abort.isCompleted) throw _downloadFailure('cancelled');
          if (body.length + stream.current.length > capability.maximumBytes ||
              byteSize != null &&
                  body.length + stream.current.length > byteSize) {
            throw _downloadFailure('invalid_download_response');
          }
          body.add(stream.current);
        }
        if (abort.isCompleted) throw _downloadFailure('cancelled');
        if (body.length == 0 ||
            byteSize != null && body.length != byteSize ||
            length != null && body.length != length) {
          throw _downloadFailure('invalid_download_response');
        }
        return body.takeBytes();
      } finally {
        unawaited(stream.cancel());
      }
    }

    try {
      final bytes = await cancellable(execute());
      _diagnose('/attachments/content', 'succeeded', started: started);
      return bytes;
    } catch (error) {
      final failure = error is HandrailGatewayException
          ? error
          : _downloadFailure(abort.isCompleted
              ? expired
                  ? 'download_timeout'
                  : 'cancelled'
              : 'download_unavailable');
      _diagnose('/attachments/content', 'failed',
          started: started, code: failure.code, retryable: failure.retryable);
      throw failure;
    } finally {
      deadline.cancel();
    }
  }
}

HandrailGatewayException _downloadFailure(String code) =>
    HandrailGatewayException(
        code,
        switch (code) {
          'cancelled' => 'File download cancelled.',
          'attachment_expired' => 'This attachment is no longer available.',
          'unauthenticated' => 'Sign in again before downloading a file.',
          'forbidden' => 'This account cannot download this file.',
          _ => 'The attachment could not be loaded. Try again.',
        },
        retryable: const {
          'download_timeout',
          'download_unavailable',
          'rate_limited'
        }.contains(code));
