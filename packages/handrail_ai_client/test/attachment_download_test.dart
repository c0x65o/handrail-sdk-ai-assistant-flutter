import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final base = Uri.parse('https://erp.test/api/assistant');
final capability =
    HandrailAttachmentDownloadCapability.fromJson({'maximumBytes': 8});
Matcher failure(String code) => throwsA(
    isA<HandrailGatewayException>().having((e) => e.code, 'code', code));
Future<List<int>> read(HandrailAiClient client,
        {Future<void>? cancellation,
        Duration timeout = const Duration(seconds: 3)}) =>
    client.downloadAttachment(
        conversationId: 'saved',
        attachmentId: 'att_file',
        mediaType: 'application/pdf',
        byteSize: 3,
        capability: capability,
        cancellation: cancellation,
        timeout: timeout);

void main() {
  test(
      'negotiates protected saved reads independently of upload and keeps old gateways compatible',
      () async {
    expect(
        HandrailGatewayCapabilities.fromJson({}).attachmentDownloads, isNull);
    final caps = HandrailGatewayCapabilities.fromJson({
      'attachments': false,
      'attachmentDownloads': {'maximumBytes': 8}
    });
    expect(caps.attachments, isNull);
    expect(caps.attachmentDownloads!.maximumBytes, 8);
    final diagnostics = <Map<String, Object?>>[], requests = <http.Request>[];
    final client = HandrailAiClient(
        baseUri: base,
        diagnostics: diagnostics.add,
        protectedHeaders: () => {'authorization': 'Bearer private-fixture'},
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response.bytes([1, 2, 3], 200,
              headers: {
                'content-type': 'application/pdf',
                'content-length': '3'
              });
        }));
    addTearDown(client.close);
    expect(await read(client), [1, 2, 3]);
    expect(await read(client), [1, 2, 3]);
    for (final request in requests) {
      expect(request.url.toString(),
          'https://erp.test/api/assistant/attachments/content?conversationId=saved&attachmentId=att_file');
      expect(request.method, 'GET');
      expect(request.followRedirects, isFalse);
      expect(request.headers['authorization'], 'Bearer private-fixture');
    }
    expect(diagnostics.toString(), isNot(contains('private-fixture')));
    expect(diagnostics.toString(), isNot(contains('att_file')));
  });

  test('rejects capability escapes before requesting authentication', () async {
    var authenticated = 0;
    final client = HandrailAiClient(
        baseUri: base,
        protectedHeaders: () {
          authenticated++;
          return {};
        });
    addTearDown(client.close);
    for (final url in [
      'https://other.test/file',
      '../file',
      '/other/file',
      'https://secret@erp.test/api/assistant/file',
      'attachments/content#fragment'
    ]) {
      await expectLater(
          client.downloadAttachment(
              conversationId: 'saved',
              attachmentId: 'att_file',
              mediaType: 'application/pdf',
              capability: HandrailAttachmentDownloadCapability.fromJson(
                  {'maximumBytes': 8, 'url': url})),
          failure('invalid_gateway_url'));
    }
    expect(authenticated, 0);
  });

  test('rejects wrong MIME, changed size, oversized and empty bodies',
      () async {
    for (final response in [
      http.Response.bytes([1, 2, 3], 200,
          headers: {'content-type': 'text/html'}),
      http.Response.bytes([1, 2], 200,
          headers: {'content-type': 'application/pdf'}),
      http.Response.bytes([1, 2, 3, 4], 200,
          headers: {'content-type': 'application/pdf'}),
      http.Response.bytes([], 200,
          headers: {'content-type': 'application/pdf'}),
    ]) {
      final client = HandrailAiClient(
          baseUri: base, httpClient: MockClient((_) async => response));
      try {
        await expectLater(read(client), failure('invalid_download_response'));
      } finally {
        client.close();
      }
    }
  });

  test('bounds a streaming body and releases observation', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
        onListen: null,
        onCancel: () {
          cancelled = true;
        });
    final client = HandrailAiClient(
        baseUri: base, httpClient: StreamClient(stream.stream));
    addTearDown(client.close);
    final expectation =
        expectLater(read(client), failure('invalid_download_response'));
    stream.add(List.filled(9, 1));
    await expectation;
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    await stream.close();
  });

  for (final phase in ['authentication', 'fetch', 'body']) {
    test('cancels during $phase and excludes late bytes', () async {
      final cancel = Completer<void>(),
          release = Completer<void>(),
          entered = Completer<void>();
      var bodyCancelled = false, requests = 0;
      final body = StreamController<List<int>>(onCancel: () {
        bodyCancelled = true;
      });
      final transport = CallbackClient((request) async {
        requests++;
        if (phase != 'authentication') entered.complete();
        if (phase == 'fetch') await release.future;
        return http.StreamedResponse(body.stream, 200,
            headers: {'content-type': 'application/pdf'});
      });
      final client = HandrailAiClient(
          baseUri: base,
          httpClient: transport,
          protectedHeaders: () async {
            if (phase == 'authentication') {
              entered.complete();
              await release.future;
            }
            return {};
          });
      addTearDown(client.close);
      final pending = read(client, cancellation: cancel.future);
      await entered.future;
      final expectation = expectLater(pending, failure('cancelled'));
      cancel.complete();
      await expectation;
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(requests, phase == 'authentication' ? 0 : 1);
      if (phase != 'authentication') expect(bodyCancelled, isTrue);
      // An unused single-subscription controller has no close listener to await.
      unawaited(body.close());
    });
  }

  test('bounds stalled reads with a deadline', () async {
    final stream = StreamController<List<int>>();
    final client = HandrailAiClient(
        baseUri: base, httpClient: StreamClient(stream.stream));
    addTearDown(client.close);
    await expectLater(read(client, timeout: const Duration(milliseconds: 20)),
        failure('download_timeout'));
    await stream.close();
  });

  test('maps expired and denied reads without exposing server payloads',
      () async {
    for (final status in [401, 403, 404, 410, 429, 503]) {
      final client = HandrailAiClient(
          baseUri: base,
          httpClient: MockClient(
              (_) async => http.Response('PRIVATE STORAGE ERROR', status)));
      try {
        final result = await client.attachmentDownloader(
                conversationId: 'saved', capability: capability)(
            attachmentId: 'att_file',
            mediaType: 'application/pdf',
            cancellation: Completer<void>().future);
        expect(result.bytes, isNull);
        expect(result.errorCode, isNot(contains('PRIVATE')));
        expect(result.retryable, status == 429 || status == 503);
        if (status == 404 || status == 410)
          expect(result.errorCode, 'attachment_expired');
      } finally {
        client.close();
      }
    }
  });
}

class CallbackClient extends http.BaseClient {
  CallbackClient(this.callback);
  final Future<http.StreamedResponse> Function(http.BaseRequest) callback;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      callback(request);
}

class StreamClient extends CallbackClient {
  StreamClient(Stream<List<int>> stream)
      : super((_) async => http.StreamedResponse(stream, 200,
            headers: {'content-type': 'application/pdf'}));
}
