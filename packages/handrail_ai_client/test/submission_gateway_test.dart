import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

Map<String, Object?> request(String text) => {
      'protocol_version': 'handrail.ai-runtime.v1',
      'continuation_of': null,
      'messages': [
        {
          'role': 'user',
          'content': <Map<String, Object?>>[
            {'type': 'text', 'text': text}
          ]
        }
      ],
      'tools': [],
      'tool_results': [],
      'generation': {'max_output_tokens': 100, 'temperature': 0},
      'correlation_hints': {},
    };

/// Pauses before the real HTTP admission reaches the Node SDK gateway.
class _AdmissionGate extends http.BaseClient {
  final delegate = http.Client();
  final admissionEntered = Completer<void>(),
      releaseAdmission = Completer<void>();
  final cancellations = <Map<String, Object?>>[];
  bool failCancelOnce = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      final body = request.body.isEmpty
          ? <String, Object?>{}
          : jsonDecode(request.body) as Map<String, Object?>;
      if (request.url.path.endsWith('/synchronization') &&
          body['operation'] == 'append_mutations' &&
          !admissionEntered.isCompleted) {
        admissionEntered.complete();
        await releaseAdmission.future;
      }
      if (request.url.path.endsWith('/turns/cancel')) {
        cancellations.add(body);
        if (failCancelOnce) {
          failCancelOnce = false;
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 503);
        }
      }
    }
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

void main() {
  late Process server;
  late Uri origin;
  final sessions = <HandrailConversationSession>[];
  final clients = <HandrailAiClient>[];
  final errors = StringBuffer();
  var identity = 0;
  Future<Map<String, dynamic>> stats() async =>
      jsonDecode((await http.get(origin.resolve('/test/stats'))).body)
          as Map<String, dynamic>;
  Future<void> finish() async {
    await http.post(origin.resolve('/test/finish'));
  }

  HandrailAiClient client({String? loseResponse, http.Client? httpClient}) {
    final value = HandrailAiClient(
        baseUri: origin.resolve('/api/ai'),
        httpClient: httpClient,
        protectedHeaders: () =>
            {if (loseResponse != null) 'x-test-lose-response': loseResponse});
    clients.add(value);
    return value;
  }

  HandrailConversationSession session(
      HandrailAiClient client, String conversation) {
    final value = HandrailConversationSession(
        client: client, conversationId: conversation, pollingInterval: null);
    sessions.add(value);
    return value;
  }

  Future<String> conversation(HandrailAiClient client) async {
    final created = await client
        .createConversation({'idempotencyKey': 'create-${identity++}'});
    return ((created['value'] as Map)['descriptor'] as Map)['conversationId']
        as String;
  }

  Future<void> completed(HandrailConversationSession session) async {
    for (var index = 0; index < 100; index++) {
      await session.refresh();
      if (session.document!.runtimeState.status == HandrailTurnStatus.completed)
        return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    fail('Canonical completion did not arrive: ${session.error}; $errors');
  }

  setUpAll(() async {
    server = await Process.start('node', ['../../tool/gateway/gateway.mjs']);
    server.stderr.transform(utf8.decoder).listen(errors.write);
    final line = await server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    origin = Uri.parse(line);
  });
  tearDown(() async {
    for (final value in sessions) {
      await value.dispose();
    }
    sessions.clear();
    for (final value in clients) {
      value.close();
    }
    clients.clear();
    await finish();
  });
  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    expect(errors.toString(), isEmpty);
  });

  test(
      'shared assistant controller creates, sends, archives and restores through the real gateway',
      () async {
    final api = client(), storage = <String, String>{};
    final controller = HandrailAssistantController(
        client: api,
        pollingInterval: null,
        autoCreate: false,
        pendingStore: HandrailKeyValuePendingTurnStore(
            namespace: 'controller-test',
            read: (key) async => storage[key],
            write: (key, value) async {
              storage[key] = value;
            },
            delete: (key) async {
              storage.remove(key);
            }));
    addTearDown(controller.dispose);
    await controller.newConversation();
    final id = controller.selectedId!;
    expect(controller.canSend, isTrue);
    var accepted = false;
    final submission = await controller.sendMessage(
        request('Shared history question'),
        onAccepted: (_) => accepted = true);
    expect(accepted, isTrue);
    expect(storage, isEmpty);
    final outcome = controller.session!.waitForTurn(submission!.turnId);
    await finish();
    await completed(controller.session!);
    expect((await outcome)['status'], 'completed');
    expect((await controller.session!.waitForTurn(submission.turnId))['status'],
        'completed');
    final messages = controller.document!.messages;
    await controller.archive(id);
    expect(controller.archived, isTrue);
    expect(await controller.sendMessage(request('Cannot send in archive')),
        isNull);
    await controller.setHistoryView(HandrailHistoryView.archived);
    expect(controller.history.any((row) => row.id == id), isTrue);
    await controller.restore(id);
    expect(controller.archived, isFalse);
    await controller.setHistoryView(HandrailHistoryView.active);
    expect(controller.history.any((row) => row.id == id), isTrue);
    expect(controller.document!.messages, messages);
  });

  for (final failCancel in [false, true]) {
    test(
        'Stop queued before admission targets its original chat; failed cancel=$failCancel',
        () async {
      final gate = _AdmissionGate()..failCancelOnce = failCancel;
      final api = client(httpClient: gate), storage = <String, String>{};
      final controller = HandrailAssistantController(
        client: api,
        pollingInterval: null,
        pendingStore: HandrailKeyValuePendingTurnStore(
          namespace: 'stop-account',
          read: (key) async => storage[key],
          write: (key, value) async {
            storage[key] = value;
          },
          delete: (key) async {
            storage.remove(key);
          },
        ),
      );
      addTearDown(controller.dispose);
      await controller.newConversation();
      final original = controller.selectedId!;
      final before = await stats();
      var accepted = 0;
      final sending = controller.sendMessage(
          request('Stop before provider dispatch'),
          onAccepted: (_) => accepted++);
      final failed = failCancel
          ? expectLater(sending, throwsA(isA<HandrailGatewayException>()))
          : null;
      await gate.admissionEntered.future;
      expect(controller.canStop, isTrue);
      await controller.requestCancellation();
      expect(controller.stopping, isTrue);
      expect(gate.cancellations, isEmpty);
      await controller.newConversation();
      final selected = controller.selectedId!;
      expect(selected, isNot(original));
      expect(controller.stopping, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.workingAnywhere, isTrue);
      expect(controller.uiBinding.read()['workingAnywhere'], isTrue);
      gate.releaseAdmission.complete();
      if (failed != null) {
        await failed;
        expect(storage, isNotEmpty);
        await controller.retryPendingMessage(conversationId: original);
      } else {
        await sending;
      }
      expect(accepted, 1);
      expect(controller.selectedId, selected);
      expect(controller.canSend, isTrue);
      expect(controller.workingAnywhere, isFalse);
      expect(controller.sessionFor(original)!.document!.latestTurn!['status'],
          'cancelled');
      expect(storage, isEmpty);
      expect(gate.cancellations.length, failCancel ? 2 : 1);
      expect(gate.cancellations.first['conversationId'], original);
      expect(
          gate.cancellations.every((request) =>
              jsonEncode(request) == jsonEncode(gate.cancellations.first)),
          isTrue);
      final after = await stats();
      expect(after['starts'], before['starts']);
      expect(after['invocations'], before['invocations']);
    });
  }

  test(
      'closing the account settles terminal observers without cancelling server work',
      () async {
    final api = client(), id = await conversation(api), view = session(api, id);
    await view.initialize();
    final submission = await view.prepareTurn(
        operationId: 'wait-${identity++}',
        clientId: 'dart-test',
        request: request('Continue in background'));
    await view.submitTurn(submission);
    final result = expectLater(
        view.waitForTurn(submission.turnId),
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'observation_closed')));
    await view.dispose();
    await result;
    final reloaded = session(api, id);
    await reloaded.initialize();
    expect(reloaded.document!.activeTurnId, submission.turnId);
    await finish();
    await completed(reloaded);
    expect(
        (await reloaded.waitForTurn(submission.turnId))['status'], 'completed');
  });

  test(
      'file-only draft admits durable attachment metadata without an empty content violation',
      () async {
    final api = client(), id = await conversation(api), view = session(api, id);
    await view.initialize();
    final wire = request('');
    (wire['messages'] as List).single['content'] = [
      {
        'type': 'image',
        'attachment': {
          'attachment_id': 'att_fixture',
          'content_ref': 'ref_fixture',
          'media_type': 'image/png',
          'byte_size': 4,
          'filename': 'one.png'
        }
      }
    ];
    final prepared = await view.prepareTurn(
        operationId: 'file-${identity++}',
        clientId: 'dart-test',
        request: wire);
    final admitted = await api.synchronize({
      'operation': 'append_mutations',
      'input': prepared.toJson()['admission']
    });
    expect((admitted['value'] as Map)['status'], 'mutations');
    await view.refresh();
    final message = view.document!.messages.single;
    expect(message['content'], [
      {'type': 'text', 'text': ''}
    ]);
    expect((message['attachments'] as List).single['attachment_id'],
        'att_fixture');
  });

  test(
      'admission is atomic, concurrent submit deduplicates, reload resumes and completed retries never restart',
      () async {
    final api = client(), before = await stats();
    final id = await conversation(api), view = session(api, id);
    await view.initialize();
    final wire = request('Check the revenue accounts');
    final prepared = await view.prepareTurn(
        operationId: 'op-${identity++}', clientId: 'dart-test', request: wire);
    (wire['messages'] as List).clear();
    final saved = HandrailTurnSubmission.fromJson(
        jsonDecode(jsonEncode(prepared.toJson())) as Map<String, dynamic>);
    final accepted = <String>[];
    final first = view.submitTurn(saved, onAccepted: (submission) {
      expect(view.document!.activeTurnId, submission.turnId);
      expect(view.document!.messages.where((m) => m['role'] == 'user'),
          hasLength(1));
      accepted.add('first:${submission.turnId}');
      throw StateError('Presentation callback failure');
    });
    final duplicate = view.submitTurn(saved, onAccepted: (submission) {
      accepted.add('duplicate:${submission.turnId}');
    });
    expect(identical(first, duplicate), isTrue);
    await first;
    expect(accepted, ['first:${saved.turnId}', 'duplicate:${saved.turnId}']);
    expect(view.document!.activeTurnId, saved.turnId);
    expect(view.document!.messages.where((m) => m['role'] == 'user'),
        hasLength(1));
    expect((await stats())['invocations'], before['invocations'] + 1);
    await view.dispose();
    final reloaded = session(api, id);
    await reloaded.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(reloaded.workspace.snapshot.runningCount, 1);
    expect((await stats())['invocations'], before['invocations'] + 1);
    await finish();
    await completed(reloaded);
    expect(reloaded.document!.runtimeState.text, 'Finished once');
    final starts = (await stats())['starts'];
    await reloaded.submitTurn(saved);
    expect((await stats())['starts'], starts);
    expect(reloaded.document!.messages.where((m) => m['role'] == 'user'),
        hasLength(1));
  });

  test(
      'independent threads finish unread after disconnect and read acknowledgement survives reload',
      () async {
    final api = client();
    final firstId = await conversation(api), secondId = await conversation(api);
    final first = session(api, firstId), second = session(api, secondId);
    for (final view in [first, second]) {
      final pending = await view.prepareTurn(
          operationId: 'op-${identity++}',
          clientId: 'dart-test',
          request: request('Work in this thread'));
      await view.submitTurn(pending);
    }
    await first.refresh();
    expect(first.workspace.snapshot.runningCount, 2);
    await first.dispose();
    await second.dispose();
    await finish();
    final recovered = session(api, firstId);
    await completed(recovered);
    await completed(session(api, secondId));
    await recovered.refresh();
    expect(recovered.workspace.snapshot.runningCount, 0);
    final unread = recovered.workspace.snapshot.unreadCount;
    expect(unread, greaterThanOrEqualTo(2));
    await recovered.markRead();
    await recovered.dispose();
    final reloaded = session(api, firstId);
    await reloaded.initialize();
    expect(reloaded.workspace.snapshot.unreadCount, unread - 1);
  });

  test('attachment references are admitted with their message before execution',
      () async {
    final api = client(), id = await conversation(api), view = session(api, id);
    final wire = request('Read the attached invoice');
    ((wire['messages'] as List).last['content'] as List).add({
      'type': 'document',
      'attachment': {
        'attachment_id': 'att_test',
        'content_ref': 'ref_test',
        'media_type': 'application/pdf',
        'byte_size': 123,
        'filename': 'invoice.pdf'
      },
    });
    final pending = await view.prepareTurn(
        operationId: 'op-${identity++}', clientId: 'dart-test', request: wire);
    await view.submitTurn(pending);
    final message =
        view.document!.messages.singleWhere((m) => m['role'] == 'user');
    expect(message['attachments'], [
      {
        'kind': 'document',
        'attachment_id': 'att_test',
        'media_type': 'application/pdf',
        'size_bytes': 123,
        'filename': 'invoice.pdf'
      }
    ]);
    await finish();
    await completed(view);
  });

  test(
      'pending journal is saved before admission and recovered after lost start acknowledgement',
      () async {
    final api = client(loseResponse: 'journal:start'), before = await stats();
    final id = await conversation(api), view = session(api, id);
    final values = <String, String>{};
    var failStorage = true;
    final accepted = <String>[];
    final journal = HandrailKeyValuePendingTurnStore(
        namespace: 'gateway-journal',
        read: (key) async => values[key],
        write: (key, value) async {
          if (failStorage)
            throw StateError('Simulated protected storage failure');
          values[key] = value;
        },
        delete: (key) async {
          values.remove(key);
        });
    await expectLater(
        view.sendMessage(
            operationId: 'unsaved',
            clientId: 'dart-test',
            request: request('Do not send before saving'),
            pendingStore: journal,
            onAccepted: (submission) => accepted.add(submission.turnId)),
        throwsStateError);
    expect((await stats())['admissions'], before['admissions']);
    expect((await stats())['starts'], before['starts']);
    expect(accepted, isEmpty);
    failStorage = false;
    await expectLater(
        view.sendMessage(
            operationId: 'journal-${identity++}',
            clientId: 'dart-test',
            request: request('Recover the saved send'),
            pendingStore: journal,
            onAccepted: (submission) => accepted.add(submission.turnId)),
        throwsA(isA<HandrailGatewayException>()));
    final pending = await journal.load(id);
    expect(pending, isNotNull);
    expect(accepted, [pending!.turnId]);
    await view.dispose();
    final recovered = session(api, id);
    expect(
        (await recovered.retryPendingMessage(journal,
                onAccepted: (submission) => accepted.add(submission.turnId)))!
            .turnId,
        pending.turnId);
    expect(accepted, [pending.turnId, pending.turnId]);
    expect(await journal.load(id), isNull);
    expect((await stats())['invocations'], before['invocations'] + 1);
    await finish();
    await completed(recovered);
  });

  for (final loss in ['admission', 'start']) {
    test('lost $loss response reuses persisted intent after session recreation',
        () async {
      final api = client(loseResponse: loss), before = await stats();
      final id = await conversation(api), view = session(api, id);
      final pending = await view.prepareTurn(
          operationId: 'op-${identity++}',
          clientId: 'dart-test',
          request: request('Apply this once'));
      final persisted = jsonEncode(pending.toJson());
      await expectLater(view.submitTurn(pending), throwsA(anything));
      await view.dispose();
      final recovered = session(api, id);
      await recovered.submitTurn(HandrailTurnSubmission.fromJson(
          jsonDecode(persisted) as Map<String, dynamic>));
      expect((await stats())['invocations'], before['invocations'] + 1);
      expect(recovered.document!.messages.where((m) => m['role'] == 'user'),
          hasLength(1));
      await finish();
      await completed(recovered);
      expect(recovered.document!.runtimeState.text, 'Finished once');
    });
  }

  test(
      'changed payload under a reused identity is refused before a second execution',
      () async {
    final api = client(), id = await conversation(api), view = session(api, id);
    final pending = await view.prepareTurn(
        operationId: 'op-${identity++}',
        clientId: 'dart-test',
        request: request('Original'));
    await view.submitTurn(pending);
    final changed =
        jsonDecode(jsonEncode(pending.toJson())) as Map<String, dynamic>;
    changed['admission']['mutations'][0]['events'][0]['payload']['content'][0]
        ['text'] = 'Changed';
    changed['start']['request']['messages'][0]['content'][0]['text'] =
        'Changed';
    final before = await stats();
    await expectLater(view.submitTurn(HandrailTurnSubmission.fromJson(changed)),
        throwsA(isA<HandrailGatewayException>()));
    expect((await stats())['invocations'], before['invocations']);
    expect(view.document!.messages.first['content'], [
      {'type': 'text', 'text': 'Original'}
    ]);
  });
}
