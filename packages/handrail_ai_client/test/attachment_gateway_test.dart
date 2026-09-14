import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  final candidate = Platform.environment['HANDRAIL_TEST_JS_SDK_DIST'];
  test(
      'JS gateway: UI binding uploads to the original conversation, admits the file, downloads and preserves ownership/expiry',
      () async {
    final server = await Process.start('node', [
      '../../tool/gateway/attachments.mjs'
    ], environment: {
      if (candidate != null) 'HANDRAIL_TEST_JS_SDK_DIST': candidate,
    });
    final errors = StringBuffer();
    server.stderr.transform(utf8.decoder).listen(errors.write);
    final origin = Uri.parse(await server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10)));
    final clients = <HandrailAiClient>[],
        controllers = <HandrailAssistantController>[];
    addTearDown(() async {
      for (final controller in controllers) await controller.dispose();
      for (final client in clients) client.close();
      server.kill();
      await server.exitCode.timeout(const Duration(seconds: 10));
    });
    HandrailAiClient client(String user) {
      final value = HandrailAiClient(
          baseUri: origin.resolve('/api/ai'),
          protectedHeaders: () => {'x-fixture-user': user});
      clients.add(value);
      return value;
    }

    HandrailAssistantController controller(HandrailAiClient client) {
      final storage = <String, String>{};
      final result = HandrailAssistantController(
          client: client,
          pollingInterval: null,
          pendingStore: HandrailKeyValuePendingTurnStore(
              namespace: 'fixture',
              read: (key) async => storage[key],
              write: (key, value) async {
                storage[key] = value;
              },
              delete: (key) async {
                storage.remove(key);
              }));
      controllers.add(result);
      return result;
    }

    final alice = client('alice'),
        bob = client('bob'),
        assistant = controller(alice);
    await assistant.initialize();
    final original = assistant.selectedId!;
    final upload = assistant.uiBinding.uploaderFor(original)!,
        download = assistant.uiBinding.downloaderFor(original)!;
    await assistant.uiBinding.history.create();
    expect(assistant.selectedId, isNot(original));
    final cancellation = Completer<void>().future;
    final result = await upload(
        bytes: [37, 80, 68, 70],
        filename: 'report.pdf',
        mediaType: 'application/pdf',
        idempotencyKey: 'file-one',
        cancellation: cancellation);
    expect(result.errorCode, isNull, reason: errors.toString());
    final reference = result.reference!;
    expect(reference['content_ref'], startsWith('ref_'));
    final accepted = Completer<void>();
    expect(
        await assistant.uiBinding.send(
            conversationId: original,
            onAccepted: accepted.complete,
            request: {
              'protocol_version': 'handrail.ai-runtime.v1',
              'continuation_of': null,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': 'Read this'},
                    {'type': 'document', 'attachment': reference}
                  ]
                }
              ],
              'tools': [],
              'tool_results': [],
              'generation': {'max_output_tokens': 100, 'temperature': 0},
              'correlation_hints': {},
            }),
        isTrue,
        reason: errors.toString());
    await accepted.future;
    for (var attempt = 0; attempt < 100; attempt++) {
      await assistant.sessionFor(original)!.refresh();
      if (assistant.sessionFor(original)!.document!.runtimeState.status ==
          HandrailTurnStatus.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(assistant.sessionFor(original)!.document!.runtimeState.status,
        HandrailTurnStatus.completed,
        reason: errors.toString());
    expect(assistant.selectedId, isNot(original));
    final fileId = reference['attachment_id']! as String;
    Future<HandrailAttachmentDownloadResult> read(
            HandrailAttachmentDownloader load) =>
        load(
            attachmentId: fileId,
            mediaType: 'application/pdf',
            byteSize: 4,
            cancellation: cancellation);
    expect((await read(download)).bytes, [37, 80, 68, 70]);
    expect(
        (await read(assistant.uiBinding.downloaderFor(assistant.selectedId)!))
            .errorCode,
        'attachment_expired');
    final bobCaps = await bob.capabilities();
    expect(
        (await read(bob.attachmentDownloader(
                conversationId: original,
                capability: bobCaps.attachmentDownloads!)))
            .errorCode,
        'attachment_expired');
    await assistant.openConversation(original);
    expect(jsonEncode(assistant.document!.messages), contains(fileId));
    await http.post(origin.resolve('/test/expire'));
    expect((await read(download)).errorCode, 'attachment_expired');
  });
}
