part of '../handrail_ai_client.dart';

typedef HandrailRequestAuthorization = FutureOr<Map<String, String>> Function(
    Uri uri);
typedef HandrailResponseAuthorization = FutureOr<void> Function(
    Uri uri, int statusCode, Map<String, String> headers);

/// Encapsulates a host's cookie/token boundary without exporting credentials to
/// conversation state. All requests stay under one configured gateway path;
/// redirects are never followed with authenticated headers.
class HandrailProtectedHttpClient extends http.BaseClient {
  final Uri baseUri;
  final http.Client _delegate;
  final HandrailRequestAuthorization authorize;
  final HandrailResponseAuthorization? receive;
  bool _closed = false;

  HandrailProtectedHttpClient(
      {required this.baseUri,
      required this.authorize,
      this.receive,
      http.Client? httpClient})
      : _delegate = httpClient ?? platform_http.createClient() {
    if (baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        baseUri.path.isEmpty ||
        baseUri.path == '/' ||
        baseUri.pathSegments.any((part) => part == '.' || part == '..') ||
        (baseUri.hasScheme &&
            !const ['https', 'http'].contains(baseUri.scheme))) {
      throw ArgumentError(
          'A gateway URL without credentials, query or fragment is required');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Protected HTTP client is closed');
    final root = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
    final uri = request.url;
    if (uri.scheme != baseUri.scheme ||
        uri.authority != baseUri.authority ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !uri.path.startsWith('$root/') ||
        uri.pathSegments.any((part) =>
            part == '.' ||
            part == '..' ||
            part.contains('/') ||
            part.contains('\\'))) {
      throw const HandrailGatewayException('invalid_gateway_url',
          'The request is outside the configured assistant gateway.');
    }
    final credentials = await authorize(uri);
    if (_closed) throw StateError('Protected HTTP client is closed');
    request.followRedirects = false;
    request.headers.addAll(credentials);
    final response = await _delegate.send(request);
    try {
      if (_closed) throw StateError('Protected HTTP client is closed');
      await receive?.call(
          uri, response.statusCode, Map.unmodifiable(response.headers));
    } catch (_) {
      // If session capture fails, do not leak an unconsumed SSE/socket resource.
      await response.stream.listen((_) {}).cancel();
      throw const HandrailGatewayException('session_update_failed',
          'The authenticated session could not be updated.',
          retryable: true);
    }
    return response;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _delegate.close();
  }
}
