import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final base = Uri.parse('https://erp.test/prefix/api/assistant');
Map<String, Object?> reference() => {
      'attachment_id': 'att_test.1',
      'content_ref': 'ref_test.1',
      'media_type': 'application/pdf',
      'byte_size': 4,
      'filename': 'invoice.pdf'
    };
http.Response success() =>
    http.Response(jsonEncode({'ok': true, 'value': reference()}), 200);
Future<Map<String, Object?>> upload(HandrailAiClient client,
        {Future<void>? cancellation,
        Duration timeout = const Duration(seconds: 5),
        String filename = 'invoice.pdf'}) =>
    client.uploadAttachment(
        bytes: [37, 80, 68, 70],
        filename: filename,
        mediaType: 'application/pdf',
        kind: 'document',
        idempotencyKey: 'file:one',
        cancellation: cancellation,
        timeout: timeout);
Matcher failure(String code) => throwsA(
    isA<HandrailGatewayException>().having((e) => e.code, 'code', code));
void main() {
  test(
      'uploads through protected account HTTP with stable identity and redacted diagnostics',
      () async {
    final requests = <http.Request>[], diagnostics = <Map<String, Object?>>[];
    var active = true;
    final transport = HandrailProtectedHttpClient(
        baseUri: base,
        authorize: (_) {
          if (!active) throw StateError('Account changed');
          return {'authorization': 'Bearer fixture'};
        },
        httpClient: MockClient((request) async {
          requests.add(request);
          return success();
        }));
    final client = HandrailAiClient(
        baseUri: base, httpClient: transport, diagnostics: diagnostics.add);
    addTearDown(client.close);
    expect((await upload(client))['value'], reference());
    expect((await upload(client))['value'], reference());
    for (final request in requests) {
      expect(request.url.path, '/prefix/api/assistant/attachments');
      expect(request.headers['authorization'], 'Bearer fixture');
      expect(request.followRedirects, isFalse);
      expect(request.body, contains('file:one'));
      expect(request.body, contains('content-type: application/pdf'));
      expect(request.body, contains('%PDF'));
    }
    expect(jsonEncode(diagnostics), isNot(contains('invoice.pdf')));
    expect(jsonEncode(diagnostics), isNot(contains('Bearer fixture')));
    active = false;
    await expectLater(upload(client), throwsA(isA<HandrailGatewayException>()));
    expect(requests, hasLength(2));
  });
  test(
      'cancellation settles even when transport ignores abort; late result is excluded',
      () async {
    final response = Completer<http.Response>(),
        sent = Completer<void>(),
        cancel = Completer<void>();
    final client = HandrailAiClient(
        baseUri: base,
        httpClient: MockClient((request) {
          expect(request.body, contains('%PDF'));
          sent.complete();
          return response.future;
        }));
    addTearDown(client.close);
    final result = upload(client, cancellation: cancel.future);
    await sent.future;
    final expectation = expectLater(result, failure('cancelled'));
    cancel.complete();
    await expectation;
    response.complete(success());
    await Future<void>.delayed(Duration.zero);
  });
  test('rejects unsafe input before sending', () async {
    var requests = 0;
    final client = HandrailAiClient(
        baseUri: base,
        httpClient: MockClient((_) async {
          requests++;
          return success();
        }));
    addTearDown(client.close);
    for (final name in ['../invoice.pdf', 'secret\n.pdf', '']) {
      await expectLater(
          upload(client, filename: name), failure('invalid_attachment'));
    }
    expect(requests, 0);
  });
  test(
      'bounds response and rejects malformed, mismatched, or extra reference fields',
      () async {
    for (final body in [
      '{',
      'x' * 33000,
      jsonEncode({
        'ok': true,
        'value': {...reference(), 'byte_size': 1}
      }),
      jsonEncode({
        'ok': true,
        'value': {...reference(), 'url': 'https://foreign.test'}
      }),
      jsonEncode({
        'ok': true,
        'value': {...reference(), 'content_ref': 'https://foreign.test'}
      })
    ]) {
      final client = HandrailAiClient(
          baseUri: base,
          httpClient: MockClient((_) async => http.Response(body, 200)));
      try {
        await expectLater(upload(client), failure('invalid_upload_response'));
      } finally {
        client.close();
      }
    }
  });
  test('uploader binding preserves safe retry policy without server text',
      () async {
    for (final status in [403, 409, 413, 429, 503]) {
      final client = HandrailAiClient(
          baseUri: base,
          httpClient: MockClient(
              (_) async => http.Response('private provider error', status)));
      try {
        final result = await client.attachmentUploader()(
            bytes: [1],
            filename: 'one.pdf',
            mediaType: 'application/pdf',
            idempotencyKey: 'one',
            cancellation: Completer<void>().future);
        expect(result.reference, isNull);
        expect(result.retryable, status == 429 || status == 503);
        expect(result.errorCode, isNot(contains('private')));
      } finally {
        client.close();
      }
    }
  });
  test('stalled response times out and releases stream observation', () async {
    var stopped = false;
    final stream = StreamController<List<int>>(onCancel: () => stopped = true);
    final client = HandrailAiClient(
        baseUri: base, httpClient: _StreamClient(stream.stream));
    addTearDown(client.close);
    await expectLater(upload(client, timeout: const Duration(milliseconds: 20)),
        failure('upload_timeout'));
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isTrue);
    await stream.close();
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);
  final Stream<List<int>> stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    return http.StreamedResponse(stream, 200);
  }
}
