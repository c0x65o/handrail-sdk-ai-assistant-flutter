import 'dart:convert';
import 'dart:io';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = jsonDecode(
      File('../../test/fixtures/documents/manifest.json')
          .readAsStringSync()) as List;
  for (final fixture in fixtures.cast<Map<String, dynamic>>()) {
    test(
        'preserves ${fixture['filename']} bytes and emits canonical saved references',
        () async {
      final bytes = File('../../test/fixtures/documents/${fixture['filename']}')
          .readAsBytesSync();
      final uploaded = Map<String, Object?>.from(fixture['uploaded'] as Map);
      final base = Uri.parse('https://fixture.test/ai');
      final client = HandrailAiClient(
          baseUri: base,
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/attachments')) {
              expect(request.bodyBytes.length, greaterThan(bytes.length));
              // Multipart framing surrounds the original contiguous binary file.
              var found = false;
              for (var offset = 0;
                  offset <= request.bodyBytes.length - bytes.length;
                  offset++) {
                if (request.bodyBytes[offset] == bytes.first &&
                    base64Encode(request.bodyBytes
                            .sublist(offset, offset + bytes.length)) ==
                        base64Encode(bytes)) {
                  found = true;
                  break;
                }
              }
              expect(found, isTrue);
              return http.Response(
                  jsonEncode({'ok': true, 'value': uploaded}), 200);
            }
            if (request.url.path.endsWith('/capabilities')) {
              return http.Response(
                  jsonEncode({
                    'ok': true,
                    'value': {
                      'protocolVersion': applicationGatewayProtocolVersion,
                      'synchronization': true,
                      'activity': false,
                    }
                  }),
                  200);
            }
            expect(request.url.path, endsWith('/synchronization'));
            return http.Response(
                jsonEncode({
                  'ok': true,
                  'value': {
                    'status': 'snapshot',
                    'snapshot': {
                      'conversationId': 'fixture',
                      'revision': null,
                      'state': {
                        'conversation_id': 'fixture',
                        'revision': null,
                        'active_turn_id': null,
                        'messages': [],
                        'turns': [],
                        'tool_calls': [],
                        'approval_proposals': [],
                        'citations': [],
                        'attachments': [],
                        'replay_error': null,
                      }
                    }
                  }
                }),
                200);
          }));
      final session = HandrailConversationSession(
          client: client, conversationId: 'fixture', pollingInterval: null);
      try {
        final result = await client.uploadAttachment(
            bytes: bytes,
            filename: fixture['filename'] as String,
            mediaType: uploaded['media_type'] as String,
            kind: (fixture['saved'] as Map)['kind'] as String,
            conversationId: 'fixture',
            idempotencyKey: 'fixture-file');
        expect(result['value'], uploaded);
        final prepared = await session.prepareTurn(
            operationId: 'fixture-turn',
            clientId: 'flutter-fixture',
            request: {
              'protocol_version': 'handrail.ai-runtime.v1',
              'continuation_of': null,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': 'Read this fixture'},
                    {
                      'type': (fixture['saved'] as Map)['kind'],
                      'attachment': result['value']
                    },
                  ]
                }
              ],
              'tools': [],
              'tool_results': [],
              'generation': {'max_output_tokens': 100, 'temperature': 0},
              'correlation_hints': {},
            });
        // Serialize/reopen the actual prepared submission, as account-scoped retry storage does.
        final reopened = HandrailTurnSubmission.fromJson(
            jsonDecode(jsonEncode(prepared.toJson())) as Map<String, dynamic>);
        final mutations =
            (reopened.toJson()['admission'] as Map)['mutations'] as List;
        final payload =
            ((mutations[1] as Map)['events'] as List).single['payload'] as Map;
        expect(payload['attachment'], fixture['saved']);
        expect(
            (payload['attachment'] as Map).containsKey('content_ref'), isFalse);
      } finally {
        await session.dispose();
        client.close();
      }
    });
  }
}
