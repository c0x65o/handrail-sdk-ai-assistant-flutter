// Real Flutter controller/session/composer; only HTTP and encrypted storage
// boundaries are simulated. Canonical failed data follows rejectUnstartedTurn.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'reentrant_assistant_test.dart' as phone;

class TerminalFixture extends phone.Fixture {
  TerminalFixture({this.bounded = true, this.scope = 'terminal-test'});
  final String scope;
  final bool bounded;
  @override
  bool get running => super.running || status == 'waiting_for_tool_result';
  Future<void> closeHeadless() async {
    await assistant.dispose();
    client.close();
  }

  bool denyStart = true, loseStartReply = false;
  bool failRead = false, failDelete = false, failCleanup = false;
  int deletes = 0, cleanups = 0, providerEffects = 0;
  bool loseDeleteReply = false, failReadAfterDelete = false;
  Future<http.Response?> Function(http.Request, Map)? intercept;
  Future<void> Function()? beforeCleanup;
  @override
  late final store = HandrailKeyValuePendingTurnStore(
    namespace: scope,
    read: (key) async {
      if (failRead && key.startsWith('handrail.pending.'))
        throw StateError('Storage unavailable');
      return storage[key];
    },
    write: (key, value) async {
      storage[key] = value;
    },
    delete: (key) async {
      if (key.startsWith('handrail.pending.')) {
        deletes++;
        if (failDelete) throw StateError('Storage unavailable');
      }
      storage.remove(key);
      if (key.startsWith('handrail.pending.')) {
        if (failReadAfterDelete) failRead = true;
        if (loseDeleteReply) throw StateError('Deleted, reply lost');
      }
    },
  );
  late final files = HandrailKeyValueAttachmentDraftStore(
    namespace: scope,
    read: (key) async => storage[key],
    write: (key, value) async {
      storage[key] = value;
    },
    delete: (key) async {
      storage.remove(key);
    },
  );
  @override
  HandrailAssistantController controller() => HandrailAssistantController(
    client: client,
    pendingStore: store,
    attachmentDraftStore: files,
    autoCreate: false,
    pollingInterval: null,
    reconcileAcceptedDraft: (id, origin) async {
      cleanups++;
      await beforeCleanup?.call();
      if (failCleanup) throw StateError('Cleanup unavailable');
      final text = await store.readDraft(id);
      if (text != null && text['version'] == origin['textVersion']) {
        await store.writeDraft(id, '', text['version'] as String);
      }
      await files.discardAcceptedFiles(
        id,
        (origin['fileIds'] as List? ?? []).cast<String>(),
      );
    },
  );

  Future<HandrailTurnSubmission> seedPending({
    Map<String, Object?>? localDraft,
  }) async {
    await assistant.openConversation('chat');
    final saved = await assistant.session!.prepareTurn(
      operationId: 'saved',
      clientId: 'fixture',
      localDraft: localDraft,
      request: {
        'protocol_version': 'handrail.ai-runtime.v1',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Saved request'},
              if ((localDraft?['fileIds'] as List? ?? []).isNotEmpty)
                {
                  'type': 'image',
                  'attachment': {
                    'attachment_id': 'att_old',
                    'media_type': 'image/png',
                    'byte_size': 3,
                    'content_ref': 'ref_old',
                  },
                },
            ],
          },
        ],
      },
    );
    await store.retain(saved);
    savedStart = Map<String, Object?>.from(saved.toJson()['start'] as Map);
    turnId = saved.turnId;
    status = 'waiting_for_approval';
    revision++;
    messages.add(record('message_saved', 'Saved request', role: 'user'));
    assistant.clearSelection();
    await assistant.openConversation('chat');
    expect(assistant.hasPendingMessage, isTrue);
    expect(admissions, 0);
    expect(starts, 0);
    return saved;
  }

  Map<String, Object?>? savedStart;
  static const denial = {
    'code': 'forbidden',
    'message': 'Execution is not allowed.',
    'retryable': false,
    'messageTruncated': false,
  };
  @override
  Map<String, Object?>? get turn => super.turn == null
      ? null
      : {...super.turn!, 'error': status == 'failed' ? denial : null};

  @override
  Future<http.Response> handle(http.Request request) async {
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map;
    final input = body['input'] as Map? ?? {};
    final override = await intercept?.call(request, body);
    if (override != null) return override;
    if (request.url.path.endsWith('/turns/resume')) {
      requests.add(request.url.path);
      return http.Response('', 200);
    }
    if (!bounded && request.url.path.endsWith('/capabilities')) {
      final response = await super.handle(request);
      final envelope = jsonDecode(response.body) as Map;
      (envelope['value'] as Map).remove('displayHistory');
      return http.Response(jsonEncode(envelope), 200);
    }
    if (request.url.path.endsWith('/synchronization') &&
        body['operation'] != 'append_mutations') {
      requests.add(request.url.path);
      if (body['operation'] == 'read_since')
        return ok({'status': 'snapshot_required'});
      return ok({
        'status': 'snapshot',
        'snapshot': {
          'conversationId': 'chat',
          'revision': revision,
          'state': {
            'conversation_id': 'chat',
            'revision': revision,
            'active_turn_id': running ? turnId : null,
            'messages': messages.map((m) => m['value']).toList(),
            'turns': [
              if (turn != null)
                {
                  'turn_id': turnId,
                  'status': status,
                  'remote_may_still_be_running': running,
                  'input_message_ids': [
                    if (savedStart != null)
                      'message_${(savedStart!['idempotencyKey'] as String).substring(6)}',
                  ],
                  'error': status == 'failed' ? denial : null,
                },
            ],
            'tool_calls': [],
            'approval_proposals': [],
            'citations': [],
            'attachments': [],
            'replay_error': null,
          },
        },
      });
    }
    if (request.url.path.endsWith('/turns/start') && denyStart) {
      requests.add(request.url.path);
      starts++;
      savedStart = Map<String, Object?>.from(body);
      // Authorized gateway persisted a durable rejection, but the response is
      // denied/lost. Canonical synchronization reveals the terminal later.
      status = 'failed';
      revision++;
      if (loseStartReply) return http.Response('', 200);
      return http.Response(jsonEncode({'ok': false, 'error': denial}), 403);
    }
    final response = await super.handle(request);
    if (request.url.path.endsWith('/turns/start')) providerEffects++;
    if (body['operation'] == 'append_mutations') {
      final events = (input['mutations'] as List)
          .cast<Map>()
          .expand((m) => m['events'] as List)
          .cast<Map>();
      final message = events
          .map((e) => e['payload'] as Map)
          .singleWhere((e) => e['type'] == 'message.created');
      messages.add(
        record(
          message['message_id'] as String,
          ((message['content'] as List).first as Map)['text'] as String,
          role: 'user',
        ),
      );
    }
    return response;
  }
}

void main() {
  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) return;
    for (final entry in {
      'Evidence': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$root/bin/cache/artifacts/material_fonts/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  for (final bounded in [true, false]) {
    testWidgets(
      'terminal pending releases Send without replay; bounded=$bounded',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = TerminalFixture(bounded: bounded);
        addTearDown(() => tester.runAsync(f.dispose));
        final boundary = GlobalKey();
        Widget surface() => RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Evidence'),
            home: (f.surface() as MaterialApp).home,
          ),
        );
        final trace = <Map<String, Object?>>[];
        Future<void> evidence(String stage) async {
          final state = {
            'stage': stage,
            'canSend': f.assistant.canSend,
            'sendEnabled':
                !f.assistant.canStop &&
                tester
                        .widget<IconButton>(find.byKey(const ValueKey('send')))
                        .onPressed !=
                    null,
            'pending': f.assistant.hasPendingMessage,
            'running': f.assistant.running,
            'canStop': f.assistant.canStop,
            'error': f.assistant.error?.code,
            'draft': f.drafts.controller.text,
            'turn': f.assistant.document?.latestTurn,
            'admissions': f.admissions,
            'starts': f.starts,
            'cancellations': f.cancellations,
            'providerEffects': f.providerEffects,
            'savedStart': f.savedStart,
            'savedMessageIds': f.messages.map((m) => m['id']).toList(),
          };
          trace.add(state);
          final dir = Platform.environment['HANDRAIL_TERMINAL_EVIDENCE'];
          if (dir == null) return;
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$dir/$bounded-$stage.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
            await File(
              '$dir/$bounded-report.json',
            ).writeAsString(const JsonEncoder.withIndent('  ').convert(trace));
          });
        }

        await tester.pumpWidget(surface());
        await phone.frames(tester);
        await tester.enterText(
          find.byKey(const ValueKey('draft')),
          'Saved request',
        );
        await phone.frames(tester);
        await tester.tap(find.byKey(const ValueKey('send')));
        await phone.frames(tester);
        for (var n = 0; n < 20 && f.assistant.submitting; n++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await phone.frames(tester);
        }
        expect(f.assistant.submitting, isFalse);
        expect(f.assistant.error?.code, 'stream_request_failed');
        expect(f.assistant.error?.statusCode, 403);
        final pending = await f.store.load('chat');
        expect(pending, isNotNull);
        expect(pending!.toJson()['start'], f.savedStart);
        expect(f.admissions, 1);
        expect(f.starts, 1);
        expect(f.providerEffects, 0);
        await tester.enterText(
          find.byKey(const ValueKey('draft')),
          'Later follow-up',
        );
        await phone.frames(tester);
        await evidence('before-observation');
        await phone.settle(tester, f.assistant.refreshObservations());
        await phone.frames(tester);
        await evidence('after-observation');
        expect(f.assistant.document!.latestTurn!['turn_id'], pending.turnId);
        expect(f.assistant.document!.latestTurn!['status'], 'failed');
        expect(f.assistant.running, isFalse);
        expect(f.assistant.canStop, isFalse);
        expect(f.assistant.canSend, isTrue);
        final send = tester.widget<IconButton>(
          find.byKey(const ValueKey('send')),
        );
        expect(send.tooltip, 'Send message');
        expect(send.onPressed, isNotNull);
        expect(f.assistant.error, isNull);
        expect(await f.store.load('chat'), isNull);
        expect(f.drafts.controller.text, 'Later follow-up');
        for (var n = 0; n < 3; n++) {
          await phone.settle(tester, f.assistant.refreshObservations());
        }
        await tester.pumpWidget(const SizedBox());
        await phone.settle(tester, f.reload());
        await tester.pumpWidget(surface());
        await phone.frames(tester);
        expect(f.assistant.canSend, isTrue);
        expect(f.drafts.controller.text, 'Later follow-up');
        expect(f.admissions, 1);
        expect(f.starts, 1);
        f.denyStart = false;
        await tester.tap(find.byKey(const ValueKey('send')));
        await phone.frames(tester);
        expect(f.admissions, 2);
        expect(f.starts, 2);
        expect(f.providerEffects, 1);
        expect(f.cancellations, 0);
        expect(f.assistant.hasPendingMessage, isFalse);
        expect(f.drafts.controller.text, isEmpty);
        expect(
          f.messages.where(
            (m) =>
                m['id'] ==
                'message_${(f.savedStart!['idempotencyKey'] as String).substring(6)}',
          ),
          hasLength(1),
        );
        await evidence('follow-up-sent');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await phone.settle(tester, f.assistant.dispose());
      },
    );
  }
  for (final bounded in [true, false]) {
    for (final state in [
      'missing',
      'foreign',
      'queued',
      'running',
      'waiting_for_tool_result',
      'waiting_for_approval',
      '401',
      '403',
      '404',
      '503',
    ]) {
      test(
        'retains uncertain or unauthorized pending: $state bounded=$bounded',
        () async {
          final f = TerminalFixture(bounded: bounded);
          addTearDown(f.closeHeadless);
          final saved = await f.seedPending();
          f.status = 'failed';
          f.revision++;
          if (state == 'missing')
            f.turnId = null;
          else if (state == 'foreign')
            f.turnId = 'foreign-terminal';
          else if (int.tryParse(state) case final code?) {
            f.intercept = (request, body) async =>
                request.url.path.endsWith('/conversations/history') ||
                    request.url.path.endsWith('/synchronization')
                ? http.Response('Access unavailable', code)
                : null;
          } else {
            f.status = state;
          }
          await f.assistant.refreshObservations();
          expect((await f.store.load('chat'))!.toJson(), saved.toJson());
          expect(f.assistant.hasPendingMessage, isTrue);
          expect(f.assistant.canSend, isFalse);
          expect(f.deletes, 0);
          expect(f.admissions, 0);
          expect(f.starts, 0);
          expect(f.cancellations, 0);
        },
      );
    }

    test(
      'cold reopen settles exact terminal without replay; bounded=$bounded',
      () async {
        final f = TerminalFixture(bounded: bounded);
        addTearDown(f.closeHeadless);
        final saved = await f.seedPending();
        f.status = 'failed';
        f.revision++;
        await f.assistant.dispose();
        f.assistant = f.controller();
        await f.assistant.openConversation('chat');
        expect(f.assistant.canSend, isTrue);
        expect(f.assistant.error, isNull);
        expect(await f.store.load('chat'), isNull);
        expect(f.assistant.document!.latestTurn!['turn_id'], saved.turnId);
        await f.assistant.openConversation('chat');
        await f.assistant.refreshObservations();
        expect(f.deletes, 1);
        expect(f.admissions, 0);
        expect(f.starts, 0);
      },
    );

    for (final failure in ['cleanup', 'delete', 'read']) {
      test(
        'local $failure failure retains journal and later converges; bounded=$bounded',
        () async {
          final f = TerminalFixture(bounded: bounded);
          addTearDown(f.closeHeadless);
          final draft = await f.store.writeDraft('chat', 'Saved request', null);
          final saved = await f.seedPending(
            localDraft: {'version': 1, 'textVersion': draft!['version']},
          );
          f.status = 'failed';
          f.revision++;
          f.failCleanup = failure == 'cleanup';
          f.failDelete = failure == 'delete';
          f.failRead = failure == 'read';
          await f.assistant.refreshObservations();
          expect(f.assistant.canSend, isFalse);
          expect(f.assistant.hasPendingMessage, isTrue);
          expect(
            f.assistant.error?.code,
            failure == 'cleanup'
                ? 'draft_cleanup_failed'
                : 'pending_reconciliation_failed',
          );
          f.failRead = false;
          expect((await f.store.load('chat'))!.toJson(), saved.toJson());
          f.failCleanup = f.failDelete = false;
          await f.assistant.refreshObservations();
          expect(f.assistant.canSend, isTrue);
          expect(f.assistant.error, isNull);
          expect(await f.store.load('chat'), isNull);
          expect(await f.store.readDraft('chat'), isNull);
          expect(f.admissions, 0);
          expect(f.starts, 0);
        },
      );
    }

    test(
      'cleanup preserves newer text and file selections; bounded=$bounded',
      () async {
        final f = TerminalFixture(bounded: bounded);
        addTearDown(f.closeHeadless);
        // Exercise the real headless controller's exact-origin cleanup.
        f.assistant = HandrailAssistantController(
          client: f.client,
          pendingStore: f.store,
          attachmentDraftStore: f.files,
          autoCreate: false,
          pollingInterval: null,
        );

        final draft = await f.store.writeDraft('chat', 'Saved request', null);
        Map<String, Object?> file(String id) => {
          'id': id,
          'filename': '$id.png',
          'mediaType': 'image/png',
          'byteSize': 3,
          'bytes': [1, 2, 3],
        };
        final oldFiles = await f.files.writeAttachmentDraft('chat', [
          file('old'),
        ], null);
        await f.seedPending(
          localDraft: {
            'version': 1,
            'textVersion': draft!['version'],
            'fileIds': ['old'],
          },
        );
        final newer = await f.store.writeDraft(
          'chat',
          'Later follow-up',
          draft['version'] as String,
        );
        await f.files.writeAttachmentDraft('chat', [
          file('old'),
          file('new'),
        ], oldFiles!['version'] as String);
        f.status = 'failed';
        f.revision++;
        await f.assistant.refreshObservations();
        expect(f.assistant.canSend, isTrue);
        expect(await f.store.readDraft('chat'), newer);
        expect(
          ((await f.files.readAttachmentDraft('chat'))!['files'] as List).map(
            (v) => (v as Map)['id'],
          ),
          ['new'],
        );
        expect(f.messages.single['id'], 'message_saved');
        expect(f.admissions, 0);
        expect(f.starts, 0);
      },
    );

    test(
      'disposal/account replacement during terminal read cannot clean old account; bounded=$bounded',
      () async {
        final f = TerminalFixture(bounded: bounded);
        addTearDown(f.closeHeadless);
        final saved = await f.seedPending();
        f.status = 'failed';
        f.revision++;
        final entered = Completer<void>(), release = Completer<void>();
        f.intercept = (request, body) async {
          if (bounded
              ? body['operation'] == 'control' &&
                    (body['input'] as Map)['turnId'] != null
              : body['operation'] == 'pull_snapshot') {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
          return null;
        };
        final observing = f.assistant.refreshObservations();
        await entered.future;
        await f.assistant.dispose();
        final replacement = TerminalFixture(
          bounded: bounded,
          scope: 'other-account',
        );
        addTearDown(replacement.closeHeadless);
        await replacement.assistant.openConversation('chat');
        release.complete();
        await observing;
        expect((await f.store.load('chat'))!.toJson(), saved.toJson());
        expect(f.deletes, 0);
        expect(replacement.assistant.canSend, isTrue);
        expect(replacement.assistant.error, isNull);
        expect(replacement.storage, isEmpty);
      },
    );

    test(
      'newer pending replacement survives terminal cleanup; bounded=$bounded',
      () async {
        final f = TerminalFixture(bounded: bounded);
        addTearDown(f.closeHeadless);
        final saved = await f.seedPending(localDraft: {'version': 1});
        f.status = 'failed';
        f.revision++;
        final replacement = await f.assistant.session!.prepareTurn(
          operationId: 'newer',
          clientId: 'fixture',
          request: {
            'protocol_version': 'handrail.ai-runtime.v1',
            'messages': [
              {
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': 'Newer request'},
                ],
              },
            ],
          },
        );
        f.beforeCleanup = () async {
          await f.store.acknowledge(saved);
          await f.store.retain(replacement);
        };
        await f.assistant.refreshObservations();
        expect((await f.store.load('chat'))!.toJson(), replacement.toJson());
        expect(f.assistant.canSend, isFalse);
        expect(f.assistant.hasPendingMessage, isTrue);
        expect(f.admissions, 0);
        expect(f.starts, 0);
      },
    );
  }

  for (final bounded in [true, false]) {
    for (final lostReply in [true, false]) {
      test(
        'acknowledged deletion with lost ${lostReply ? "reply" : "read"} recovers; bounded=$bounded',
        () async {
          final f = TerminalFixture(bounded: bounded);
          addTearDown(f.closeHeadless);
          await f.seedPending();
          f.status = 'failed';
          f.revision++;
          f.loseDeleteReply = lostReply;
          f.failReadAfterDelete = !lostReply;
          await f.assistant.refreshObservations();
          expect(f.assistant.hasPendingMessage, isTrue);
          expect(f.assistant.canSend, isFalse);
          expect(f.assistant.error?.code, 'pending_reconciliation_failed');
          f.loseDeleteReply = f.failReadAfterDelete = f.failRead = false;
          expect(await f.store.load('chat'), isNull);
          await f.assistant.refreshObservations();
          expect(f.assistant.canSend, isTrue);
          expect(f.assistant.error, isNull);
          expect(f.deletes, 1);
          expect(f.admissions, 0);
          expect(f.starts, 0);
        },
      );
    }
    test('disposal during cleanup retains journal; bounded=$bounded', () async {
      final f = TerminalFixture(bounded: bounded);
      addTearDown(f.closeHeadless);
      final saved = await f.seedPending(localDraft: {'version': 1});
      f.status = 'failed';
      f.revision++;
      final entered = Completer<void>(), release = Completer<void>();
      f.beforeCleanup = () async {
        entered.complete();
        await release.future;
      };
      final observing = f.assistant.refreshObservations();
      await entered.future;
      await f.assistant.dispose();
      release.complete();
      await observing;
      expect((await f.store.load('chat'))!.toJson(), saved.toJson());
      expect(f.deletes, 0);
    });
    for (final failure in ['cleanup', 'delete']) {
      test(
        'reopen $failure failure recovers with observation; bounded=$bounded',
        () async {
          final f = TerminalFixture(bounded: bounded);
          addTearDown(f.closeHeadless);
          await f.seedPending(localDraft: {'version': 1});
          f.status = 'failed';
          f.revision++;
          f.failCleanup = failure == 'cleanup';
          f.failDelete = failure == 'delete';
          await expectLater(
            f.assistant.openConversation('chat'),
            throwsA(isA<HandrailGatewayException>()),
          );
          expect(
            f.assistant.error?.code,
            failure == 'cleanup'
                ? 'draft_cleanup_failed'
                : 'pending_reconciliation_failed',
          );
          expect(f.assistant.canSend, isFalse);
          f.failCleanup = f.failDelete = false;
          await f.assistant.refreshObservations();
          expect(f.assistant.canSend, isTrue);
          expect(f.assistant.error, isNull);
          expect(f.admissions, 0);
          expect(f.starts, 0);
        },
      );
    }
  }
  for (final invalid in [
    'missing',
    'foreign-turn',
    'foreign-conversation',
    'stale',
    'generation',
    'preparing',
  ]) {
    test('requested turn proof rejects $invalid control', () async {
      final f = TerminalFixture();
      addTearDown(f.closeHeadless);
      final saved = await f.seedPending();
      f.status = 'failed';
      f.revision++;
      f.intercept = (request, body) async {
        final input = body['input'] as Map? ?? {};
        if (body['operation'] != 'control' || input['turnId'] == null)
          return null;
        return f.ok({
          ...f.header('chat'),
          if (invalid == 'foreign-conversation') 'conversationId': 'other',
          if (invalid == 'stale') 'revision': f.revision - 1,
          if (invalid == 'generation') 'generation': 1,
          if (invalid == 'preparing') 'status': 'preparing',
          'activeTurn': null,
          'latestTurn': invalid == 'preparing' ? null : f.turn,
          'requestedTurn': ['missing', 'preparing'].contains(invalid)
              ? null
              : {...f.turn!, if (invalid == 'foreign-turn') 'turnId': 'other'},
        });
      };
      await f.assistant.refreshObservations();
      expect((await f.store.load('chat'))!.toJson(), saved.toJson());
      expect(f.assistant.canSend, isFalse);
      expect(f.deletes, 0);
      expect(f.admissions, 0);
      expect(f.starts, 0);
    });
  }
  test(
    'bounded exact requested turn settles even when latest is a different turn',
    () async {
      final f = TerminalFixture();
      addTearDown(f.closeHeadless);
      final saved = await f.seedPending();
      f.status = 'failed';
      f.revision++;
      f.intercept = (request, body) async {
        if (body['operation'] != 'control') return null;
        final input = body['input'] as Map;
        return f.ok({
          ...f.header('chat'),
          'activeTurn': null,
          'latestTurn': {
            ...f.turn!,
            'turnId': 'later',
            'status': 'completed',
            'error': null,
          },
          'requestedTurn': input['turnId'] == saved.turnId ? f.turn : null,
        });
      };
      await f.assistant.refreshObservations();
      expect(f.assistant.document!.latestTurn!['turn_id'], 'later');
      expect(f.assistant.canSend, isTrue);
      expect(await f.store.load('chat'), isNull);
      expect(f.admissions, 0);
      expect(f.starts, 0);
    },
  );
  for (final bounded in [true, false]) {
    test('lost start reply settles without retry; bounded=$bounded', () async {
      final f = TerminalFixture(bounded: bounded)..loseStartReply = true;
      addTearDown(f.closeHeadless);
      await f.assistant.openConversation('chat');
      await expectLater(
        f.assistant.sendMessage({
          'protocol_version': 'handrail.ai-runtime.v1',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Saved request'},
              ],
            },
          ],
        }, operationId: 'lost'),
        throwsA(
          isA<HandrailGatewayException>().having(
            (e) => e.code,
            'code',
            'start_unconfirmed',
          ),
        ),
      );
      final saved = await f.store.load('chat');
      expect(saved!.toJson()['start'], f.savedStart);
      expect(f.assistant.hasPendingMessage, isTrue);
      await f.assistant.refreshObservations();
      expect(f.assistant.canSend, isTrue);
      expect(f.assistant.error, isNull);
      expect(await f.store.load('chat'), isNull);
      expect(f.admissions, 1);
      expect(f.starts, 1);
      expect(f.providerEffects, 0);
    });
    test(
      'selection change cancels pending reconciliation; bounded=$bounded',
      () async {
        final f = TerminalFixture(bounded: bounded);
        addTearDown(f.closeHeadless);
        final saved = await f.seedPending();
        f.status = 'failed';
        f.revision++;
        final entered = Completer<void>(), release = Completer<void>();
        f.intercept = (request, body) async {
          if (bounded
              ? body['operation'] == 'control' &&
                    (body['input'] as Map)['turnId'] != null
              : body['operation'] == 'pull_snapshot') {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
          return null;
        };
        final observing = f.assistant.refreshObservations();
        await entered.future;
        f.assistant.clearSelection();
        release.complete();
        await observing;
        expect((await f.store.load('chat'))!.toJson(), saved.toJson());
        expect(f.deletes, 0);
        f.intercept = null;
        await f.assistant.openConversation('chat');
        expect(f.assistant.canSend, isTrue);
        expect(await f.store.load('chat'), isNull);
      },
    );
  }
}
