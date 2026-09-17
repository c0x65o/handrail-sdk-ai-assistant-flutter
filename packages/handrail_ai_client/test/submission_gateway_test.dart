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
  final requests = <Map<String, Object?>>[];
  bool failCancelOnce = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      final body = request.body.isEmpty
          ? <String, Object?>{}
          : jsonDecode(request.body) as Map<String, Object?>;
      requests.add(body);
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
      HandrailAiClient client, String conversation,
      {Future<void> Function(String, Map<String, Object?>)? cleanup}) {
    final value = HandrailConversationSession(
        client: client,
        conversationId: conversation,
        pollingInterval: null,
        reconcileAcceptedDraft: cleanup);
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
      'headless file receipt recovery uses metadata only after interrupted byte cleanup',
      () async {
    final metadata = <String, String>{}, sources = <String, List<int>>{};
    var failCleanup = true, binaryReads = 0;
    final files = HandrailKeyValueAttachmentDraftStore(
      namespace: 'headless-file-wire',
      read: (key) async => metadata[key],
      write: (key, value) async {
        metadata[key] = value;
      },
      delete: (key) async {
        metadata.remove(key);
      },
      readBytes: (key) async {
        binaryReads++;
        return sources[key];
      },
      writeBytes: (key, value) async {
        sources[key] = List.of(value);
      },
      deleteBytes: (key) async {
        if (failCleanup) throw StateError('Interrupted file cleanup');
        sources.remove(key);
      },
    );
    final pending = HandrailKeyValuePendingTurnStore(
      namespace: 'headless-file-wire',
      read: (key) async => metadata[key],
      write: (key, value) async {
        metadata[key] = value;
      },
      delete: (key) async {
        metadata.remove(key);
      },
    );
    final recorder = _AdmissionGate()..releaseAdmission.complete();
    final api = client(httpClient: recorder),
        id = await conversation(api),
        before = await stats();
    await files.writeAttachmentDraft(
        id,
        [
          for (final name in ['upload-old', 'upload-new'])
            {
              'id': name,
              'filename': '$name.csv',
              'mediaType': 'text/csv',
              'byteSize': 3,
              'bytes': [1, 2, 3],
            }
        ],
        null);
    var controller = HandrailAssistantController(
        client: api,
        pendingStore: pending,
        attachmentDraftStore: files,
        pollingInterval: null,
        autoCreate: false);
    await controller.openConversation(id);
    final input = request('Read this file');
    ((input['messages'] as List).last['content'] as List).add({
      'type': 'document',
      'attachment': {
        'attachment_id': 'att_test_file',
        'content_ref': 'ref_test_file',
        'media_type': 'text/csv',
        'byte_size': 3,
        'filename': 'upload-old.csv'
      },
    });
    await expectLater(
        controller.sendMessage(input,
            operationId: 'file-origin-${identity++}',
            localDraft: {
              'version': 1,
              'fileIds': ['upload-old']
            }),
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'draft_cleanup_failed')));
    expect(await pending.load(id), isNotNull);
    expect((await stats())['starts'], before['starts']);
    expect(binaryReads, 0);
    await controller.dispose();
    failCleanup = false;
    controller = HandrailAssistantController(
        client: api,
        pendingStore: pending,
        attachmentDraftStore: files,
        pollingInterval: null,
        autoCreate: false);
    addTearDown(controller.dispose);
    await controller.openConversation(id);
    expect(await pending.load(id), isNull);
    expect(binaryReads, 0);
    expect((await stats())['starts'], (before['starts'] as int) + 1);
    final remaining = await files.readAttachmentDraft(id);
    expect((remaining!['files'] as List).single['id'], 'upload-new');
    expect(sources, hasLength(1));
    expect(jsonEncode(recorder.requests), isNot(contains('fileIds')));
    expect(jsonEncode(recorder.requests), isNot(contains('localDraft')));
    await finish();
    await completed(controller.sessionFor(id)!);
  });

  test(
      'exact draft cleanup recovers partial device failure through the real gateway',
      () async {
    final storage = <String, String>{};
    HandrailKeyValuePendingTurnStore pending() =>
        HandrailKeyValuePendingTurnStore(
            namespace: 'draft-origin-wire',
            read: (key) async => storage[key],
            write: (key, value) async {
              storage[key] = value;
            },
            delete: (key) async {
              storage.remove(key);
            });
    final recorder = _AdmissionGate()..releaseAdmission.complete();
    final api = client(httpClient: recorder), before = await stats();
    final id = await conversation(api);
    final saved = await pending().writeDraft(id, 'identical text', null);
    final version = saved!['version'] as String;
    var controller = HandrailAssistantController(
        client: api,
        pendingStore: pending(),
        pollingInterval: null,
        autoCreate: false,
        reconcileAcceptedDraft: (conversation, origin) async {
          expect(conversation, id);
          expect(origin['textVersion'], version);
          await pending().writeDraft(id, '', version);
          throw StateError('Process lost after partial local cleanup');
        });
    await controller.openConversation(id);
    await expectLater(
        controller.sendMessage(request('identical text'),
            operationId: 'origin-${identity++}',
            localDraft: {'version': 1, 'textVersion': version}),
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'draft_cleanup_failed')));
    final original = (await pending().load(id))!.toJson();
    expect(original['version'], 2);
    expect(await pending().readDraft(id), isNull);
    expect((await stats())['starts'], before['starts']);
    await controller.dispose();
    final newer = await pending().writeDraft(id, 'identical text', null);
    controller = HandrailAssistantController(
        client: api,
        pendingStore: pending(),
        pollingInterval: null,
        autoCreate: false);
    addTearDown(() => controller.dispose());
    await controller.openConversation(id);
    expect(await pending().load(id), isNull);
    expect(await pending().readDraft(id), newer);
    expect((await stats())['starts'], (before['starts'] as int) + 1);
    final user =
        controller.document!.messages.where((m) => m['role'] == 'user').single;
    expect(jsonEncode(user), isNot(contains('textVersion')));
    expect(jsonEncode(user), isNot(contains('localDraft')));
    expect(jsonEncode((original['start'] as Map)['request']),
        isNot(contains('textVersion')));
    final admissions = recorder.requests
        .where((body) => body['operation'] == 'append_mutations')
        .toList();
    expect(admissions, hasLength(2));
    expect(admissions[0], admissions[1]);
    expect(jsonEncode(recorder.requests), isNot(contains('localDraft')));
    expect(jsonEncode(recorder.requests), isNot(contains('textVersion')));
    await finish();
    await completed(controller.sessionFor(id)!);
  });

  test('deletion replays a lost real-gateway receipt after controller restart',
      () async {
    final storage = <String, String>{};
    final pending = HandrailKeyValuePendingTurnStore(
        namespace: 'deletion-wire-test',
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
        delete: (key) async {
          storage.remove(key);
        });
    final files = HandrailKeyValueAttachmentDraftStore(
        namespace: 'deletion-wire-test',
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
        delete: (key) async {
          storage.remove(key);
        });
    final before = await stats();
    var controller = HandrailAssistantController(
        client: client(loseResponse: 'controller:delete'),
        pendingStore: pending,
        attachmentDraftStore: files,
        pollingInterval: null,
        autoCreate: false);
    addTearDown(() => controller.dispose());
    await controller.newConversation();
    final id = controller.selectedId!,
        version = controller.selectedDescriptor!.version;
    final saved = await files.writeAttachmentDraft(
        id,
        [
          {
            'id': 'selected',
            'filename': 'selected.png',
            'mediaType': 'image/png',
            'byteSize': 3,
            'bytes': [1, 2, 3],
          }
        ],
        null);
    await expectLater(controller.permanentlyDelete(id, version),
        throwsA(isA<http.ClientException>()));
    expect(await pending.loadDeletions(), hasLength(1));
    expect(controller.document, isNotNull);
    expect(await files.readAttachmentDraft(id), isNotNull);
    await controller.dispose();
    controller = HandrailAssistantController(
        client: client(loseResponse: 'controller:delete'),
        pendingStore: pending,
        attachmentDraftStore: files,
        pollingInterval: null,
        autoCreate: false);
    await controller.initialize();
    expect(controller.deletedConversationIds, contains(id));
    expect(controller.sessionFor(id), isNull);
    expect(controller.history.map((row) => row.id), isNot(contains(id)));
    expect(await pending.loadDeletions(), isEmpty);
    expect(await files.readAttachmentDraft(id), isNull);
    await expectLater(
        files.writeAttachmentDraft(
            id,
            (saved!['files'] as List).cast<Map<String, Object?>>(),
            saved['version'] as String),
        throwsStateError);
    final after = await stats();
    expect(after['deletions'], (before['deletions'] as int) + 2);
    expect(after['starts'], before['starts']);
    expect(after['invocations'], before['invocations']);
  });

  test(
      'approval lost reply recovers exact decision after execution advances through the real JS gateway',
      () async {
    final before = await stats(), storage = <String, String>{};
    final api = client(loseResponse: 'controller:approval');
    final id = await conversation(api);
    final seeded = await http.post(origin.resolve('/test/propose'),
        body: jsonEncode({'conversationId': id}));
    expect(seeded.statusCode, 200);
    final proposalId =
        (jsonDecode(seeded.body) as Map)['proposal_id'] as String;
    final pending = HandrailKeyValuePendingTurnStore(
        namespace: 'wire-approval',
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
        delete: (key) async {
          storage.remove(key);
        });
    var controller = HandrailAssistantController(
        client: api,
        pendingStore: pending,
        pollingInterval: null,
        autoCreate: false);
    addTearDown(() => controller.dispose());
    await controller.openConversation(id);
    await controller.approvals.review(proposalId, 1);
    final row =
        (controller.approvals.presentation['items'] as List).single as Map;
    await expectLater(
        controller.approvals
            .decide(proposalId, 1, row['binding'] as String, true),
        throwsA(isA<http.ClientException>()));
    final saved = (await pending.loadApprovalDecisions()).single.toJson();
    expect(
        (await http.post(origin.resolve('/test/advance-approval'),
                body: jsonEncode({'proposalId': proposalId})))
            .statusCode,
        200);
    await controller.dispose();
    controller = HandrailAssistantController(
        client: client(loseResponse: 'controller:approval'),
        pendingStore: pending,
        pollingInterval: null,
        autoCreate: false);
    await controller.initialize();
    expect(await pending.loadApprovalDecisions(), isEmpty,
        reason:
            'Exact version ${saved['expectedVersion']} must settle after execution advances.');
    final after = await stats();
    expect(after['decisions'], (before['decisions'] as int) + 2);
    expect(after['invocations'], before['invocations']);
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

  test(
      'real indexed history pages stay bounded and do not replace canonical context',
      () async {
    final api = client(), id = await conversation(api);
    Future<void> seed(int count) async {
      expect(
          (await http.post(origin.resolve('/test/history-seed'),
                  body: jsonEncode({'conversationId': id, 'count': count})))
              .statusCode,
          200);
    }

    await seed(200);
    final before = await stats(), view = session(api, id);
    await view.initialize();
    expect(view.document!.isPartial, true);
    expect(view.document!.messages.length, 30);
    expect(view.document!.messages.first['message_id'], 'history-171');
    expect(view.document!.messages.last['message_id'], 'history-200');
    await view.displayWindow!.loadOlder();
    await view.displayWindow!.loadOlder();
    expect(view.document!.messages.length, 90);
    final oldest = view.document!.messages.first['message_id'];
    await seed(1);
    await view.refresh();
    expect(view.document!.messages.first['message_id'], oldest);
    expect(view.displayWindow!.state.hasNewer, true);
    expect(view.displayWindow!.state.retainedBytes, lessThanOrEqualTo(262144));
    await view.displayWindow!.jumpToLatest();
    expect(view.document!.messages.last['message_id'], 'history-201');
    final after = await stats();
    expect(after['snapshotReads'], before['snapshotReads']);
    expect(after['displayReads'], greaterThan(before['displayReads'] as int));
    expect(after['maximumDisplayBytes'], lessThanOrEqualTo(65536 + 1024));
    final canonical = await api.synchronize({
      'operation': 'pull_snapshot',
      'input': {'conversationId': id}
    });
    expect(
        (((canonical['value'] as Map)['snapshot'] as Map)['state']
            as Map)['messages'],
        hasLength(201));
  },
      skip: Platform.environment['HANDRAIL_TEST_JS_SDK_DIST'] == null
          ? 'Requires explicit local SDK source qualification with PostgreSQL stores.'
          : false);

  test(
      'oversized review uses compact durable receipts through the real JS gateway',
      () async {
    final before = await stats(), storage = <String, String>{};
    final api = client(loseResponse: 'paged:approval'),
        id = await conversation(api);
    final seeded = await http.post(origin.resolve('/test/propose'),
        body: jsonEncode({'conversationId': id, 'large': true}));
    expect(seeded.statusCode, 200);
    final proposalId =
        (jsonDecode(seeded.body) as Map)['proposal_id'] as String;
    final pending = HandrailKeyValuePendingTurnStore(
        namespace: 'paged-wire-approval',
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
        delete: (key) async {
          storage.remove(key);
        });
    var controller = HandrailAssistantController(
        client: api,
        pendingStore: pending,
        pollingInterval: null,
        autoCreate: false);
    addTearDown(() => controller.dispose());
    await controller.openConversation(id);
    expect(controller.session!.supportsApprovalReview, true);
    await controller.approvals.openPendingApprovals();
    controller.approvals.selectPendingApproval(proposalId);
    Map view() => controller.approvals.presentation['pagedReview'] as Map;
    for (var i = 0; i < 100 && view()['status'] != 'ready'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(view()['status'], 'ready');
    var pages = 0;
    while (view()['complete'] != true) {
      expect(((view()['section'] as Map)['text'] as String).runes.length,
          lessThanOrEqualTo(8192));
      expect(pages++, lessThan(5));
      await (view()['next'] as Future<void> Function())();
    }
    (view()['acknowledge'] as void Function(bool))(true);
    await (view()['decide'] as Future<void> Function(bool))(true);
    expect(view()['error'], 'decision');
    final saved = (await pending.loadApprovalDecisions()).single;
    expect(saved.json['display'], true);
    expect(storage.values.join(), isNot(contains('😀')));
    expect(
        (await http.post(origin.resolve('/test/advance-approval'),
                body: jsonEncode({'proposalId': proposalId})))
            .statusCode,
        200);
    await controller.dispose();
    controller = HandrailAssistantController(
        client: client(loseResponse: 'paged:approval'),
        pendingStore: pending,
        pollingInterval: null,
        autoCreate: false);
    await controller.initialize();
    expect(await pending.loadApprovalDecisions(), isEmpty);
    final after = await stats();
    expect(after['decisions'], (before['decisions'] as int) + 2);
    expect(after['maximumDecisionBytes'], lessThan(1024));
    expect(after['snapshotReads'], before['snapshotReads']);
  },
      skip: Platform.environment['HANDRAIL_TEST_JS_SDK_DIST'] == null
          ? 'Requires local SDK source qualification with PostgreSQL.'
          : false);

  test(
      'large message reader uses bounded plaintext HTTP and rejects content after deletion',
      () async {
    final api = client(), id = await conversation(api), text = '😀' * 12000;
    final seeded = await http.post(origin.resolve('/test/history-seed'),
        headers: {'content-type': 'application/json; charset=utf-8'},
        body: jsonEncode({'conversationId': id, 'count': 1, 'text': text}));
    expect(seeded.statusCode, 200);
    final view = session(api, id), before = await stats();
    await view.initialize();
    expect(view.capabilities!.displayHistory!.messageText, isTrue);
    final record = view.displayWindow!.state.records.single;
    expect(record.deferred, isTrue);
    expect(record.value, isNull);
    final read = view.displayWindow!.uiBinding.read()['readMessageText']
        as Future<Map<String, Object?>> Function(
            String, String, int, int, int, Future<void>);
    final cancellation = Completer<void>().future;
    final first =
        await read(id, record.id, 0, record.revision, 0, cancellation);
    expect(first['encoding'], 'plain-text');
    expect((first['text'] as String).runes.length, 8192);
    expect(first['nextOffset'], 8192);
    final last =
        await read(id, record.id, 0, record.revision, 8192, cancellation);
    expect(last['nextOffset'], isNull);
    expect('${first['text']}${last['text']}', text);
    expect(view.capabilities!.displayHistory!.recordText, isTrue);
    final readRecord = view.displayWindow!.uiBinding.read()['readRecordText']
        as Future<Map<String, Object?>> Function(
            String, String, String, int, int, int, Future<void>);
    var serialized = '', offset = 0;
    for (;;) {
      final part = await readRecord(
          id, 'message', record.id, 0, record.revision, offset, cancellation);
      expect(part['encoding'], 'plain-text');
      expect((part['text'] as String).runes.length, lessThanOrEqualTo(8192));
      serialized += part['text'] as String;
      if (part['nextOffset'] == null) break;
      offset = part['nextOffset'] as int;
    }
    expect(serialized, contains('\n    "'));
    expect((jsonDecode(serialized) as Map)['content'], [
      {'type': 'text', 'text': text}
    ]);
    expect(view.displayWindow!.state.records.single.value, isNull);
    final after = await stats();
    expect(after['snapshotReads'], before['snapshotReads']);
    expect(after['maximumDisplayBytes'], lessThanOrEqualTo(65536 + 1024));
    await api.permanentlyDeleteConversation({
      'conversationId': id,
      'expectedVersion': 1,
      'idempotencyKey': 'delete-large-${identity++}'
    });
    final cleared =
        await read(id, record.id, 0, record.revision, 0, cancellation);
    expect(cleared['errorCode'], anyOf('stale_cursor', 'not_found'));
    expect(
        (await readRecord(id, 'message', record.id, 0, record.revision, 0,
            cancellation))['errorCode'],
        anyOf('stale_cursor', 'not_found'));
  },
      skip: Platform.environment['HANDRAIL_TEST_JS_SDK_DIST'] == null
          ? 'Requires explicit local SDK source qualification with PostgreSQL stores.'
          : false);

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
      'cancelling a completion wait leaves the server turn running and reusable',
      () async {
    final api = client(), id = await conversation(api), view = session(api, id);
    await view.initialize();
    final submission = await view.prepareTurn(
        operationId: 'wait-cancel-${identity++}',
        clientId: 'dart-test',
        request: request('Keep server work running'));
    await view.submitTurn(submission);
    final cancelled = Completer<void>();
    final outcome = expectLater(
        view.waitForTurn(submission.turnId, cancellation: cancelled.future),
        throwsA(isA<HandrailGatewayException>()
            .having((e) => e.code, 'code', 'observation_cancelled')));
    cancelled.complete();
    await outcome;
    expect(view.document!.activeTurnId, submission.turnId);
    await finish();
    await completed(view);
    expect((await view.waitForTurn(submission.turnId))['status'], 'completed');
  });

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

  test('lost local journal acknowledgement cannot replace the saved request',
      () async {
    final values = <String, String>{};
    var failAcknowledgement = false;
    final journal = HandrailKeyValuePendingTurnStore(
        namespace: 'uncertain-local-journal',
        read: (key) async => values[key],
        write: (key, value) async {
          values[key] = value;
          if (failAcknowledgement)
            throw StateError('Local acknowledgement lost');
        },
        delete: (key) async {
          values.remove(key);
        });
    var controller = HandrailAssistantController(
        client: client(), pendingStore: journal, autoCreate: false);
    try {
      await controller.newConversation();
      final id = controller.selectedId!, before = await stats();
      failAcknowledgement = true;
      final original = {
        ...request('Saved household question'),
        'metadata': {'draft_marker': 'original'},
      };
      await expectLater(controller.sendMessage(original), throwsStateError);
      final saved = (await journal.load(id))!;
      expect((saved.toJson()['start'] as Map)['request'], original);
      expect((await stats())['admissions'], before['admissions']);
      expect((await stats())['starts'], before['starts']);
      expect(controller.canSend, isFalse);
      expect(
          await controller.sendMessage(request('Different question')), isNull);
      expect((await journal.load(id))!.toJson(), saved.toJson());
      await controller.dispose();
      failAcknowledgement = false;
      controller = HandrailAssistantController(
          client: client(), pendingStore: journal, autoCreate: false);
      await controller.openConversation(id);
      expect(await journal.load(id), isNull);
      expect((await stats())['invocations'], before['invocations'] + 1);
      expect(controller.document!.activeTurnId, saved.turnId);
      await finish();
      await completed(controller.session!);
      expect(controller.document!.messages.where((m) => m['role'] == 'user'),
          hasLength(1));
    } finally {
      await controller.dispose();
    }
  });

  for (final loss in ['admission', 'start']) {
    test('lost $loss response reuses persisted intent after session recreation',
        () async {
      final api = client(loseResponse: loss), before = await stats();
      final id = await conversation(api);
      var cleanups = 0;
      Future<void> cleanup(
          String conversation, Map<String, Object?> origin) async {
        expect(conversation, id);
        expect(origin, {'version': 1, 'textVersion': 'exact'});
        cleanups++;
      }

      final view = session(api, id, cleanup: cleanup);
      final pending = await view.prepareTurn(
          operationId: 'op-${identity++}',
          clientId: 'dart-test',
          request: request('Apply this once'),
          localDraft: {'version': 1, 'textVersion': 'exact'});
      final persisted = jsonEncode(pending.toJson());
      await expectLater(view.submitTurn(pending), throwsA(anything));
      expect(cleanups, loss == 'admission' ? 0 : 1);
      await view.dispose();
      final recovered = session(api, id, cleanup: cleanup);
      await recovered.submitTurn(HandrailTurnSubmission.fromJson(
          jsonDecode(persisted) as Map<String, dynamic>));
      expect(cleanups, loss == 'admission' ? 1 : 2);
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
