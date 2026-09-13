import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final base = Uri.parse('https://app.test/prefix/api/ai');
  test('rejects escaped gateway destinations before requesting credentials',
      () async {
    var authorizations = 0;
    final client = HandrailProtectedHttpClient(
        baseUri: base,
        authorize: (_) {
          authorizations++;
          return {'Cookie': 'session=test'};
        });
    for (final path in [
      'https://other.test/prefix/api/ai/capabilities',
      'http://app.test/prefix/api/ai/capabilities',
      'https://app.test/prefix/api/ai-other/capabilities',
      'https://app.test/prefix/api/ai/%2e%2e/secret',
      'https://app.test/prefix/api/ai/%2fsecret'
    ]) {
      await expectLater(client.get(Uri.parse(path)),
          throwsA(isA<HandrailGatewayException>()));
    }
    expect(authorizations, 0);
    client.close();
  });
  test(
      'keeps abort identity, disables redirects and captures session headers before returning a stream',
      () async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
        'POST', base.resolve('/prefix/api/ai/turns/start'),
        abortTrigger: abort.future);
    final delegate = RecordingClient();
    var received = false;
    final client = HandrailProtectedHttpClient(
        baseUri: base,
        httpClient: delegate,
        authorize: (_) =>
            {'Cookie': 'session=test', 'X-CSRF-Token': 'csrf-test'},
        receive: (uri, status, headers) {
          expect(headers['set-cookie'], 'session=rotated');
          received = true;
        });
    final response = await client.send(request);
    expect(identical(delegate.request, request), isTrue);
    expect(request.followRedirects, isFalse);
    expect(request.headers['Cookie'], 'session=test');
    expect(received, isTrue);
    await response.stream.drain<void>();
    client.close();
  });
  test('closed client cannot send after credentials finish loading', () async {
    final credentials = Completer<Map<String, String>>();
    var sent = false;
    final client = HandrailProtectedHttpClient(
        baseUri: base,
        authorize: (_) => credentials.future,
        httpClient: MockClient((_) async {
          sent = true;
          return http.Response('', 200);
        }));
    final request = client.get(Uri.parse('$base/capabilities'));
    client.close();
    credentials.complete({'Cookie': 'session=test'});
    await expectLater(request, throwsStateError);
    expect(sent, isFalse);
  });
}

class RecordingClient extends http.BaseClient {
  http.BaseRequest? request;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest value) async {
    request = value;
    return http.StreamedResponse(const Stream.empty(), 200,
        headers: {'set-cookie': 'session=rotated'});
  }
}
