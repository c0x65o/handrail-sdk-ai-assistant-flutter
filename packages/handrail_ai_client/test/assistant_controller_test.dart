import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, Object?> descriptor(String id,
        {String lifecycle = 'active', int version = 1}) =>
    {
      'conversationId': id,
      'title': 'New conversation',
      'lifecycle': lifecycle,
      'version': version,
      'createdAt': '2026-09-01T00:00:00Z',
      'updatedAt': '2026-09-01T00:00:00Z'
    };
http.Response ok(Object? value) =>
    http.Response(jsonEncode({'ok': true, 'value': value}), 200);

class Fixture {
  final rows = <String, Map<String, Object?>>{
    'one': descriptor('one'),
    'two': descriptor('two')
  };
  final requests = <http.Request>[],
      creations = <String, Map<String, Object?>>{};
  bool failList = false, loseCreate = false, loseArchive = false;
  bool titleGeneration = false;
  bool displayHistory = false;
  final activeTurns = <String, String>{};
  final heldControls = <String, Completer<void>>{};
  List<Map<String, Object?>> messages = [];
  Future<http.Response?> Function(http.Request, Map)? before;
  final storage = <String, String>{};
  late final pending = HandrailKeyValuePendingTurnStore(
      namespace: 'test-account',
      read: (key) async => storage[key],
      write: (key, value) async {
        storage[key] = value;
      },
      delete: (key) async {
        storage.remove(key);
      });
  late final client = HandrailAiClient(
      baseUri: Uri.parse('https://example.test/api/assistant'),
      httpClient: MockClient(handle));
  HandrailAssistantController controller(
          {bool autoCreate = true, bool threads = true}) =>
      HandrailAssistantController(
          client: client,
          pendingStore: pending,
          pollingInterval: null,
          threads: threads,
          autoCreate: autoCreate);
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(request.body) as Map;
    final override = await before?.call(request, body);
    if (override != null) return override;
    final path = request.url.path;
    if (path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'authoritativeCancellation': true,
        if (displayHistory)
          'displayHistory': {
            'version': 1,
            'control': true,
            'maximumPageSize': 50,
            'maximumPageBytes': 262144
          },
        'resources': {'titleGeneration': titleGeneration}
      });
    if (path.endsWith('/conversations/list')) {
      if (failList) return http.Response('unavailable', 503);
      return ok({
        'items': rows.values
            .where((row) => row['lifecycle'] == body['lifecycle'])
            .toList(),
        'hasMore': false,
        'nextCursor': null,
        'order': body['order']
      });
    }
    if (path.endsWith('/conversations/get'))
      return ok({'descriptor': rows[body['conversationId']]});
    if (path.endsWith('/conversations/history')) {
      final input = body['input'] as Map,
          id = input['conversationId'] as String;
      final turn = activeTurns[id];
      final header = {
        'schemaVersion': 1,
        'conversationId': id,
        'status': 'ready',
        'generation': 0,
        'revision': 1,
        'canonicalRevision': 1,
        'activeTurnId': turn
      };
      if (body['operation'] == 'control') {
        await heldControls[id]?.future;
        final control = turn == null
            ? null
            : {
                'turnId': turn,
                'revision': 1,
                'status': 'running',
                'remoteMayStillBeRunning': true,
                'error': null
              };
        return ok({
          ...header,
          'activeTurn': control,
          'latestTurn': control,
          'requestedTurn': null
        });
      }
      return ok({
        ...header,
        'nextCursor': null,
        'throughRevision': 1,
        'records': body['operation'] == 'changes' || input['view'] != null
            ? []
            : [
                for (var i = 0; i < 30; i++)
                  {
                    'kind': 'message',
                    'id': '$id-$i',
                    'revision': 1,
                    'bytes': 120,
                    'deferred': false,
                    'value': {
                      'message_id': '$id-$i',
                      'role': 'assistant',
                      'content': [
                        {'type': 'text', 'text': '$id message $i'}
                      ],
                      'attachments': []
                    }
                  }
              ]
      });
    }
    if (path.endsWith('/conversations/create')) {
      final row = creations.putIfAbsent(body['idempotencyKey'] as String, () {
        final value = {
          ...descriptor('new-${creations.length}'),
          if (body['metadata'] != null) 'metadata': body['metadata']
        };
        rows[value['conversationId'] as String] = value;
        return value;
      });
      if (loseCreate) {
        loseCreate = false;
        return http.Response('lost', 503);
      }
      return ok({'descriptor': row, 'status': 'created'});
    }
    if (path.endsWith('/conversations/archive') ||
        path.endsWith('/conversations/restore')) {
      final id = body['conversationId'] as String;
      final archived = path.endsWith('/archive');
      rows[id] = {
        ...rows[id]!,
        'version': (rows[id]!['version'] as int) + 1,
        'lifecycle': archived ? 'archived' : 'active'
      };
      if (loseArchive) {
        loseArchive = false;
        return http.Response('lost', 503);
      }
      return ok({
        'descriptor': rows[id],
        'status': archived ? 'archived' : 'restored'
      });
    }
    if (path.endsWith('/synchronization')) {
      final input = body['input'] as Map,
          id = input['conversationId'] as String;
      if (body['operation'] == 'read_since')
        return ok({'status': 'snapshot_required'});
      return ok({
        'status': 'snapshot',
        'snapshot': {
          'conversationId': id,
          'revision': null,
          'state': {
            'conversation_id': id,
            'revision': null,
            'active_turn_id': null,
            'messages': messages,
            'turns': [],
            'tool_calls': [],
            'approval_proposals': [],
            'citations': [],
            'attachments': [],
            'replay_error': null
          }
        }
      });
    }
    throw StateError('Unexpected fixture path: $path');
  }
}

void main() {
  for (final recover in [false, true]) {
    test(
        'definite attachment rejection keeps drafts and unlocks correction; recovery=$recover',
        () async {
      final f = Fixture()..displayHistory = true;
      final controller = f.controller(autoCreate: false);
      addTearDown(controller.dispose);
      addTearDown(f.client.close);
      var admissions = 0, accepted = 0;
      final bodies = <Object?>[];
      f.before = (request, body) async {
        if (body['operation'] == 'append_mutations') {
          admissions++;
          bodies.add(body['input']);
          if (recover && admissions == 1)
            return http.Response('lost response', 503);
          return ok({
            'status': 'rejected',
            'code': 'attachment_expired',
            'message':
                'A file upload expired before the message was saved. Select the file again.'
          });
        }
        return null;
      };
      await controller.openConversation('one');
      final draft =
          await f.pending.writeDraft('one', 'retain this draft', null);
      final request = <String, Object?>{
        'protocol_version': 'handrail.ai-runtime.v1',
        'continuation_of': null,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'retain this draft'}
            ]
          }
        ],
        'tools': [],
        'tool_results': [],
        'generation': {'max_output_tokens': 100, 'temperature': 0},
        'correlation_hints': {},
      };
      await expectLater(
          controller.sendMessage(request, operationId: 'rejected',
              onAccepted: (_) {
            accepted++;
          }),
          throwsA(isA<HandrailGatewayException>()));
      if (recover) {
        expect(controller.hasPendingMessage, isTrue);
        // Reopening performs durable retry just as a recreated client does.
        await expectLater(
            controller.openConversation('one'),
            throwsA(isA<HandrailGatewayException>()
                .having((error) => error.retryable, 'retryable', isFalse)));
        expect(bodies[1], bodies[0]);
      }
      expect(admissions, recover ? 2 : 1);
      expect(accepted, 0);
      expect(await f.pending.load('one'), isNull);
      expect(await f.pending.readDraft('one'), draft);
      expect(controller.hasPendingMessage, isFalse);
      expect(controller.canSend, isTrue);
      expect(
          f.requests
              .where((request) => request.url.path.endsWith('/turns/start')),
          isEmpty);
    });
  }
  test(
      'standard UI exposes account-owned draft persistence from the pending adapter',
      () async {
    final fixture = Fixture(), controller = Fixture();
    final assistant = fixture.controller(), other = controller.controller();
    addTearDown(assistant.dispose);
    addTearDown(other.dispose);
    final storage =
        assistant.uiBinding.read()['draftStorage'] as Map<String, Object?>;
    final read =
        storage['read'] as Future<Map<String, Object?>?> Function(String);
    final write = storage['write'] as Future<Map<String, Object?>?> Function(
        String, String, String?);
    final saved = await write('one', 'local draft', null);
    expect(await read('one'), saved);
    expect((await fixture.pending.readDraft('one'))!['text'], 'local draft');
    expect(await controller.pending.readDraft('one'), isNull);
    expect(fixture.requests, isEmpty);
  });
  test(
      'bounded account switching cancels obsolete reads, releases hidden pages and evicts idle sessions',
      () async {
    final f = Fixture()..displayHistory = true;
    final controller = f.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(f.client.close);
    final hold = f.heldControls['one'] = Completer<void>();
    final opening = controller.openConversation('one');
    while (
        !f.requests.any((r) => r.url.path.endsWith('/conversations/history'))) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.openConversation('two');
    await opening.timeout(const Duration(seconds: 1));
    expect(controller.selectedId, 'two');
    expect(controller.document!.messages, hasLength(30));
    expect(controller.sessionFor('one')?.document?.messages ?? [], isEmpty);
    hold.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.sessionFor('one')?.displayWindow?.state.records ?? [],
        isEmpty);
    f.activeTurns['two'] = 'running-two';
    await controller.session!.refresh();
    for (var i = 0; i < 7; i++) {
      final id = 'idle-$i';
      f.rows[id] = descriptor(id);
      await controller.openConversation(id);
    }
    expect(controller.sessionFor('two')!.document!.activeTurnId, 'running-two');
    expect(controller.sessionFor('two')!.document!.messages, isEmpty);
    expect(controller.sessionFor('idle-0'), null);
    expect(controller.workspace.snapshot.conversations.length,
        lessThanOrEqualTo(4));
    expect(controller.document!.messages, hasLength(30));
    final pageReads = f.requests
        .where((r) => r.url.path.endsWith('/conversations/history'))
        .map((r) => jsonDecode(r.body) as Map)
        .where((r) =>
            r['operation'] == 'page' && (r['input'] as Map)['view'] == null)
        .length;
    await controller.refreshObservations();
    final after = f.requests
        .where((r) => r.url.path.endsWith('/conversations/history'))
        .map((r) => jsonDecode(r.body) as Map)
        .where((r) =>
            r['operation'] == 'page' && (r['input'] as Map)['view'] == null)
        .length;
    expect(after, pageReads,
        reason: 'Background turns only read scalar control state');
    await controller.openConversation('two');
    expect(controller.document!.messages, hasLength(30));
    expect(
        f.requests.any((r) => r.url.path.endsWith('/synchronization')), false);
    await controller.dispose();
    expect(controller.sessionFor('two'), null);
  });

  test(
      'single conversation disables titles and clear retries retain identity and refresh context',
      () async {
    final f = Fixture()..titleGeneration = true;
    f.messages = [
      {
        'message_id': 'old',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Old context'}
        ],
        'attachments': []
      }
    ];
    final controller = f.controller(autoCreate: false, threads: false);
    final secondDevice = f.controller(autoCreate: false, threads: false);
    addTearDown(secondDevice.dispose);
    addTearDown(controller.dispose);
    addTearDown(f.client.close);
    await controller.initialize();
    await controller.openConversation('one');
    await secondDevice.initialize();
    await secondDevice.openConversation('one');
    expect(secondDevice.document!.messages, hasLength(1));
    await controller.refreshGeneratedTitle('one', 'ended-call');
    await controller.setInitialTitle(
        'one', 'Unused attachment title', 'attachment');
    expect(controller.historyPresentation['canCreate'], isFalse);
    expect(controller.historyPresentation['selectedTitle'], '');
    expect(f.requests.where((r) => r.url.path.endsWith('/titles/generate')),
        isEmpty);
    final clears = <Map>[];
    f.before = (request, body) async {
      if (!request.url.path.endsWith('/conversations/clear')) return null;
      clears.add(body);
      if (clears.length == 1) return http.Response('lost reply', 503);
      f.messages = [];
      f.rows['one'] = {...f.rows['one']!, 'version': 2};
      return ok({'descriptor': f.rows['one'], 'status': 'idempotent'});
    };
    await expectLater(controller.clearCurrentConversation(),
        throwsA(isA<HandrailGatewayException>()));
    await controller.clearCurrentConversation();
    expect(clears[0], equals(clears[1]));
    expect(controller.selectedId, 'one');
    expect(controller.selectedDescriptor!.version, 2);
    expect(controller.document!.messages, isEmpty);
    await secondDevice.sessionFor('one')!.refresh();
    expect(secondDevice.document!.messages, isEmpty);
    expect(controller.busy, isFalse);
  });
  for (final persisted in [true, false]) {
    test(
        'external activity title refresh uses server state without text turns ($persisted)',
        () async {
      final f = Fixture()..titleGeneration = true;
      f.before = (request, body) async {
        if (!request.url.path.endsWith('/titles/generate')) return null;
        expect(body['conversationId'], 'one');
        expect(body['idempotencyKey'], 'title:ended-call');
        if (persisted)
          f.rows['one'] = {
            ...f.rows['one']!,
            'title': 'Saved voice title',
            'version': 2
          };
        return ok('Returned title');
      };
      final controller = f.controller(autoCreate: false);
      addTearDown(controller.dispose);
      addTearDown(f.client.close);
      await controller.initialize();
      await controller.openConversation('one');
      f.requests.clear();
      await controller.refreshGeneratedTitle('one', 'ended-call');
      expect(controller.selectedDescriptor!.title,
          persisted ? 'Saved voice title' : 'New conversation');
      expect(
          f.requests.map((r) => r.url.pathSegments.last), ['generate', 'list']);
      expect(controller.document!.messages, isEmpty);
    });
  }
  test(
      'external activity title refresh preserves server failure without rename',
      () async {
    final f = Fixture()..titleGeneration = true;
    f.before = (request, body) async =>
        request.url.path.endsWith('/titles/generate')
            ? http.Response('unavailable', 503)
            : null;
    final controller = f.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(f.client.close);
    await controller.initialize();
    f.requests.clear();
    await expectLater(controller.refreshGeneratedTitle('one', 'ended-call'),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.requests.any((r) => r.url.path.endsWith('/conversations/rename')),
        isFalse);
  });
  test('external activity title refresh does not call unsupported servers',
      () async {
    final f = Fixture();
    final controller = f.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(f.client.close);
    await controller.initialize();
    f.requests.clear();
    await controller.refreshGeneratedTitle('one', 'ended-call');
    expect(f.requests.any((r) => r.url.path.endsWith('/titles/generate')),
        isFalse);
  });
  test(
      'external activity title refresh rechecks live permission after capability read',
      () async {
    final f = Fixture()..titleGeneration = true;
    var allowed = true;
    final controller = HandrailAssistantController(
        client: f.client,
        pendingStore: f.pending,
        pollingInterval: null,
        autoCreate: false,
        allowConversationManagement: () => allowed);
    addTearDown(controller.dispose);
    addTearDown(f.client.close);
    f.before = (request, body) async {
      if (request.url.path.endsWith('/capabilities')) allowed = false;
      return null;
    };
    await expectLater(controller.refreshGeneratedTitle('one', 'ended-call'),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.requests.any((r) => r.url.path.endsWith('/titles/generate')),
        isFalse);
  });

  test(
      'failed server title generation does not race recovery with a fallback rename',
      () async {
    final f = Fixture()
      ..titleGeneration = true
      ..messages = [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Long first message'}
          ]
        }
      ];
    f.before = (request, body) async =>
        request.url.path.endsWith('/titles/generate')
            ? http.Response('unavailable', 503)
            : null;
    final controller = f.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(f.client.close);
    await controller.initialize();
    await controller.openConversation('one');
    await expectLater(
        controller.setInitialTitle('one', 'Long first message', 'first'),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.rows['one']!['title'], 'New conversation');
    expect(
        f.requests.where((r) => r.url.path.endsWith('/conversations/rename')),
        isEmpty);
  });
  for (final generationSupported in [true, false]) {
    test(
        'initial titles support return-only and legacy servers ($generationSupported)',
        () async {
      final f = Fixture()
        ..titleGeneration = generationSupported
        ..messages = [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'First message'}
            ]
          }
        ];
      f.before = (request, body) async {
        if (request.url.path.endsWith('/titles/generate'))
          return ok('Generated title');
        if (request.url.path.endsWith('/conversations/rename')) {
          expect(body['expectedVersion'], 1);
          f.rows['one'] = {
            ...f.rows['one']!,
            'title': body['title'],
            'version': 2
          };
          return ok({'descriptor': f.rows['one'], 'status': 'updated'});
        }
        return null;
      };
      final controller = f.controller(autoCreate: false);
      addTearDown(controller.dispose);
      addTearDown(f.client.close);
      await controller.initialize();
      await controller.openConversation('one');
      await controller.setInitialTitle('one', 'First message', 'first');
      expect(controller.selectedDescriptor!.title,
          generationSupported ? 'Generated title' : 'First message');
      expect(
          f.requests.where((r) => r.url.path.endsWith('/conversations/rename')),
          hasLength(1));
    });
  }
  for (final manualRename in [false, true]) {
    test(
        'server title generation preserves saved title (manual: $manualRename)',
        () async {
      final f = Fixture()
        ..titleGeneration = true
        ..messages = [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'A long first message'}
            ]
          }
        ];
      f.before = (request, body) async {
        if (request.url.path.endsWith('/titles/generate')) {
          f.rows['one'] = {
            ...f.rows['one']!,
            'version': 2,
            'title':
                manualRename ? 'My chosen title' : 'Concise generated title'
          };
          return ok('Concise generated title');
        }
        return null;
      };
      final controller = f.controller(autoCreate: false);
      addTearDown(controller.dispose);
      addTearDown(f.client.close);
      await controller.initialize();
      await controller.openConversation('one');
      await controller.setInitialTitle(
          'one', 'A long first message', 'operation-one');
      expect(controller.selectedDescriptor!.title,
          manualRename ? 'My chosen title' : 'Concise generated title');
      expect(f.requests.where((r) => r.url.path.endsWith('/titles/generate')),
          hasLength(1));
      expect(
          f.requests.where((r) => r.url.path.endsWith('/conversations/rename')),
          isEmpty);
    });
  }

  test(
      'configured creation context is sampled once and frozen across lost replies',
      () async {
    final fixture = Fixture()..loseCreate = true;
    var context = 'Reports', samples = 0;
    final controller = HandrailAssistantController(
      client: fixture.client,
      pendingStore: fixture.pending,
      pollingInterval: null,
      newConversationMetadata: () {
        samples++;
        return {'contextLabel': context};
      },
    );
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(controller.historyBinding.create(),
        throwsA(isA<HandrailGatewayException>()));
    context = 'Customers';
    await controller.historyBinding.create();
    final requests = fixture.requests
        .where((r) => r.url.path.endsWith('/conversations/create'))
        .toList();
    expect(requests[0].body, requests[1].body);
    expect(samples, 1);
    expect(controller.selectedDescriptor!.metadata['contextLabel'], 'Reports');
    await controller.historyBinding.create();
    expect(samples, 2);
    expect(
        controller.selectedDescriptor!.metadata['contextLabel'], 'Customers');
    await controller.newConversation(metadata: const {});
    expect(samples, 2);
    expect(controller.selectedDescriptor!.metadata, isEmpty);
  });
  test('an empty loaded catalog is an empty transcript, not permanent loading',
      () async {
    final fixture = Fixture()..rows.clear();
    final controller = fixture.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    expect(controller.transcriptBinding.read()['loading'], isTrue);
    await controller.initialize();
    final state = controller.transcriptBinding.read();
    expect(state['loading'], isFalse);
    expect(state['document'], isNull);
    expect(state['error'], isNull);
    expect(fixture.creations, isEmpty);
    await controller.newConversation();
    expect(controller.transcriptBinding.read()['document'], isNotNull);
    controller.clearSelection();
    expect(controller.transcriptBinding.read()['loading'], isFalse);
  });

  test(
      'domain presentation retry retains creation and observers can update filters',
      () async {
    final fixture = Fixture(), controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    final subscription =
        controller.changes.listen((_) => controller.setUnreadOnly(true));
    addTearDown(subscription.cancel);
    await controller.initialize();
    String? readyId;
    await expectLater(controller.newConversation(onReady: (id) async {
      readyId = id;
      throw StateError('Business presentation unavailable');
    }), throwsStateError);
    await controller.newConversation(onReady: (id) async {
      expect(id, readyId);
    });
    expect(fixture.creations, hasLength(1));
    expect(controller.unreadOnly, isTrue);
    final selected = controller.session;
    final reads = fixture.requests.length;
    expect(await controller.ensureSession(readyId!), same(selected));
    expect(fixture.requests, hasLength(reads));
    controller.clearSelection();
    expect(controller.selectedId, isNull);
    expect(controller.workspace.snapshot.selectedConversationId, isNull);
    expect(controller.sessionFor(readyId), same(selected));
  });

  test(
      'initialization coalesces and a failed history read cannot create a chat',
      () async {
    final fixture = Fixture()..failList = true;
    fixture.rows.clear();
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    final first = controller.initialize();
    expect(identical(first, controller.initialize()), isTrue);
    await expectLater(first, throwsA(isA<HandrailGatewayException>()));
    expect(fixture.creations, isEmpty);
    expect(controller.historyError, isNotNull);
    fixture.failList = false;
    await controller.initialize();
    expect(fixture.creations, hasLength(1));
    expect(controller.document, isNotNull);
    await controller.initialize();
    expect(fixture.creations, hasLength(1));
  });
  test(
      'lost New response retains exact request metadata and identity across retry',
      () async {
    final fixture = Fixture()..loseCreate = true;
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(
        controller.newConversation(metadata: {'context': 'first'}),
        throwsA(isA<HandrailGatewayException>()));
    await controller.newConversation(metadata: {'context': 'changed'});
    expect(fixture.creations, hasLength(1));
    expect(controller.selectedId, 'new-0');
    final requests = fixture.requests
        .where((r) => r.url.path.endsWith('/conversations/create'))
        .toList();
    expect(requests[0].body, requests[1].body);
    expect(controller.selectedDescriptor!.metadata['context'], 'first');
  });
  test('New retry after hydration/history failure never creates another chat',
      () async {
    final fixture = Fixture(), controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    fixture.failList = true;
    await expectLater(
        controller.newConversation(), throwsA(isA<HandrailGatewayException>()));
    expect(controller.selectedId, 'new-0');
    fixture.failList = false;
    await controller.newConversation();
    expect(fixture.creations, hasLength(1));
  });
  test('a late active catalog cannot overwrite the archived view', () async {
    final fixture = Fixture();
    fixture.rows['old'] = descriptor('old', lifecycle: 'archived');
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    final waiting = Completer<http.Response?>(), started = Completer<void>();
    fixture.before = (request, body) {
      if (request.url.path.endsWith('/conversations/list') &&
          body['lifecycle'] == 'active') {
        started.complete();
        return waiting.future;
      }
      return Future.value();
    };
    final old = controller.refreshHistory();
    await started.future;
    await controller.setHistoryView(HandrailHistoryView.archived);
    waiting.complete(ok({
      'items': [descriptor('one')],
      'hasMore': false,
      'nextCursor': null
    }));
    await old;
    expect(controller.history.map((r) => r.id), ['old']);
    expect(controller.historyView, HandrailHistoryView.archived);
  });
  test(
      'selection generation excludes late selection while both sessions remain independent',
      () async {
    final fixture = Fixture(), controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    final waiting = Completer<void>(), started = Completer<void>();
    fixture.before = (request, body) async {
      if (request.url.path.endsWith('/synchronization') &&
          (body['input'] as Map)['conversationId'] == 'two') {
        if (!started.isCompleted) started.complete();
        await waiting.future;
      }
      return null;
    };
    final old = controller.openConversation('two');
    await started.future;
    await controller.openConversation('one');
    waiting.complete();
    await old;
    expect(controller.selectedId, 'one');
    expect(controller.workspace.snapshot.selectedConversationId, 'one');
    expect(controller.sessionFor('two')?.document?.conversationId, 'two');
  });
  test(
      'archive/restore use SDK state and keep an archived transcript read-only',
      () async {
    final fixture = Fixture(), controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await controller.archive('one');
    expect(controller.archived, isTrue);
    expect(controller.history.map((r) => r.id), ['two']);
    expect(await controller.sendMessage(const {}), isNull);
    await controller.setHistoryView(HandrailHistoryView.archived);
    expect(controller.history.single.id, 'one');
    await controller.restore('one');
    expect(controller.archived, isFalse);
    expect(controller.history, isEmpty);
  });
  test('lost archive response reuses its original mutation identity', () async {
    final fixture = Fixture()..loseArchive = true;
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(
        controller.archive('one'), throwsA(isA<HandrailGatewayException>()));
    await controller.archive('one');
    final writes =
        fixture.requests.where((r) => r.url.path.endsWith('/archive')).toList();
    expect(writes[0].body, writes[1].body);
    expect(controller.archived, isTrue);
  });
  test(
      'an opposite lifecycle action waits for canonical resolution of the uncertain change',
      () async {
    final fixture = Fixture()..loseArchive = true;
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(
        controller.archive('one'), throwsA(isA<HandrailGatewayException>()));
    await expectLater(
        controller.restore('one'),
        throwsA(isA<HandrailGatewayException>().having(
            (error) => error.code, 'code', 'pending_lifecycle_exists')));
    expect(fixture.requests.where((r) => r.url.path.endsWith('/restore')),
        isEmpty);
    await controller.setHistoryView(HandrailHistoryView.archived);
    await controller.restore('one');
    expect(controller.archived, isFalse);
    final writes =
        fixture.requests.where((r) => r.url.path.endsWith('/restore')).toList();
    expect(writes, hasLength(1));
  });

  test(
      'pagination handles overlap and rejects a repeated cursor while preserving visible history',
      () async {
    final fixture = Fixture(), controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    fixture.before = (request, body) async =>
        request.url.path.endsWith('/conversations/list')
            ? ok({
                'items': [descriptor('one')],
                'hasMore': true,
                'nextCursor': 'same'
              })
            : null;
    await controller.refreshHistory();
    await controller.refreshHistory();
    await expectLater(
        controller.refreshHistory(more: true), throwsFormatException);
    expect(controller.history.single.id, 'one');
    expect(controller.historyError, isNotNull);
  });
  test('unread filtering uses remote activity for unopened conversations',
      () async {
    final fixture = Fixture(), controller = fixture.controller();
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    controller.workspace.replaceRemoteActivity([
      HandrailConversationActivityRecord.fromJson({
        'conversationId': 'two',
        'turnId': 'turn',
        'turnRevision': 2,
        'turnStatus': 'completed',
        'unread': true,
        'updatedAt': '2026-09-01T00:00:00Z',
        'summary': 'Saved preview'
      })
    ]);
    controller.setUnreadOnly(true);
    expect(controller.visibleHistory.single.id, 'two');
    expect(controller.unreadCount, 1);
    expect(controller.previewFor('two'), 'Saved preview');
  });
}
