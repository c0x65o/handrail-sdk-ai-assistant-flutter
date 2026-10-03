// Source qualification: run with a temporary package map containing both local
// SDK packages. Only HTTP/storage are test boundaries; the account controller,
// session, display window, workspace, composer and transcript are real.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class Fixture {
  final storage = <String, String>{};
  final operations = <String>[];
  final pages = <Completer<void>>[];
  bool preparing = false, holdPages = false;
  int revision = 100;
  int historyCount = 2;
  bool holdHistory = false, deferredHistory = false, denyHistory = false;
  final historyReads = <Map>[];
  final historyGates = <Completer<void>>[];
  late final store = HandrailKeyValuePendingTurnStore(
    namespace: 'restoration-test',
    read: (key) async => storage[key],
    write: (key, value) async {
      storage[key] = value;
    },
    delete: (key) async {
      storage.remove(key);
    },
  );
  late final client = HandrailAiClient(
    baseUri: Uri.parse('https://fixture.invalid/ai'),
    httpClient: MockClient(handle),
  );
  late final assistant = HandrailAssistantController(
    client: client,
    pendingStore: store,
    autoCreate: false,
    pollingInterval: const Duration(seconds: 5),
  );
  late final drafts = HandrailComposerController.forAssistant(
    assistant.uiBinding,
  );
  Map<String, Object?> header(String id) => {
    'schemaVersion': 1,
    'conversationId': id,
    'status': preparing ? 'preparing' : 'ready',
    'generation': 0,
    'revision': revision,
    'canonicalRevision': revision,
    'activeTurnId': null,
  };
  Map<String, Object?> descriptor(String id) => {
    'conversationId': id,
    'title': id,
    'lifecycle': 'active',
    'version': 1,
    'createdAt': '2026-09-01T00:00:00Z',
    'updatedAt': '2026-09-01T00:00:00Z',
  };
  Map<String, Object?> message(int n) => {
    'kind': 'message',
    'id': 'm$n',
    'revision': revision,
    'turnId': 'turn',
    'bytes': 200,
    'deferred': false,
    'value': {
      'message_id': 'm$n',
      'role': 'assistant',
      'turn_id': 'turn',
      'attachments': [],
      'content': [
        {'type': 'text', 'text': 'Saved message $n'},
      ],
    },
  };
  Map<String, Object?> proposal(String status) => {
    'kind': 'approval',
    'id': status,
    'revision': revision,
    'turnId': 'turn',
    'bytes': 500,
    'deferred': false,
    'value': {
      'proposal_id': status,
      'proposal_version': 1,
      'turn_id': 'turn',
      'tool_call_id': 'tool-$status',
      'tool_name': 'Change $status',
      'status': status,
      'reviewed_arguments': {
        'type': 'redacted_json',
        'value': {'notes': 'Exact $status detail'},
      },
    },
  };
  http.Response ok(Object value) => http.Response(
    jsonEncode({'ok': true, 'value': value}),
    200,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'activity': false,
        'resources': {'approvals': true},
        'displayHistory': {
          'version': 1,
          'control': true,
          'approvalHistory': true,
          'recordText': true,
          'maximumPageSize': 50,
          'maximumPageBytes': 262144,
        },
      });
    final body = jsonDecode(request.body) as Map;
    final operation = body['operation'] as String? ?? request.url.path;
    operations.add(operation);
    if (request.url.path.endsWith('/conversations/list'))
      return ok({
        'items': [descriptor('chat'), descriptor('other')],
        'hasMore': false,
        'nextCursor': null,
        'order': body['order'],
      });
    if (request.url.path.endsWith('/conversations/get'))
      return ok({'descriptor': descriptor(body['conversationId'] as String)});
    final input = body['input'] as Map? ?? {};
    final id = input['conversationId'] as String? ?? 'chat';
    switch (operation) {
      case 'control':
        return ok({
          ...header(id),
          'activeTurn': null,
          'latestTurn': null,
          'requestedTurn': null,
        });
      case 'page':
        if (input['view'] != null) {
          final view = input['view'] as Map;
          final historical = view['type'] == 'approval_history';
          final ids = view['messageIds'] as List? ?? [];
          if (historical) {
            historyReads.add(input);
            if (denyHistory)
              return http.Response(
                jsonEncode({
                  'ok': false,
                  'error': {
                    'code': 'forbidden',
                    'message': 'History access revoked',
                    'retryable': false,
                  },
                }),
                403,
              );
            final gate = Completer<void>();
            historyGates.add(gate);
            final end = input['cursor'] == null
                ? historyCount
                : int.parse(input['cursor'] as String);
            final start = (end - 30).clamp(0, historyCount);
            final result = ok({
              ...header(id),
              'records': [
                for (var n = start; n < end; n++)
                  if (historyCount == 2)
                    deferredHistory && n == 0
                        ? {
                            ...proposal('executed'),
                            'value': null,
                            'deferred': true,
                            'bytes': 40000,
                          }
                        : proposal(n == 0 ? 'executed' : 'rejected')
                  else
                    {
                      ...proposal(n.isEven ? 'executed' : 'rejected'),
                      'id': '$id-action-$n',
                      'value': {
                        ...proposal(n.isEven ? 'executed' : 'rejected')['value']
                            as Map,
                        'proposal_id': '$id-action-$n',
                      },
                    },
              ],
              'nextCursor': start > 0 ? '$start' : null,
            });
            if (holdHistory) await gate.future;
            return result;
          }
          return ok({
            ...header(id),
            'records': [
              for (final status in [
                if (historical || ids.contains('m70')) ...[
                  'executed',
                  'rejected',
                ],
                if (!historical) ...['pending', 'failed'],
              ])
                proposal(status),
            ],
            'nextCursor': null,
          });
        }
        final gate = Completer<void>();
        pages.add(gate);
        // Capture before the wait to also test obsolete late response fencing.
        final anchor = input['anchor'] as Map?;
        final at = anchor == null
            ? 70
            : int.parse((anchor['messageId'] as String).substring(1));
        final older = anchor?['direction'] == 'older';
        final start = older ? (at - 30).clamp(0, 99) : at;
        final end = older ? at : (start + 30).clamp(0, 100);
        final response = ok({
          ...header(id),
          'records': [for (var n = start; n < end; n++) message(n)],
          'nextCursor': (anchor == null || older && start > 0) ? 'older' : null,
        });
        if (holdPages) await gate.future;
        return response;
      case 'content':
        return ok({
          'encoding': 'plain-text',
          'text': 'Executed: Exact large saved detail',
          'revision': revision,
          'nextOffset': null,
        });
      case 'changes':
        return ok({
          ...header(id),
          'records': [],
          'nextCursor': null,
          'throughRevision': revision,
        });
      default:
        throw StateError(
          'Unexpected operation $operation: no mutations allowed',
        );
    }
  }

  Widget surface() => MaterialApp(
    home: Scaffold(
      body: HandrailAssistantWorkspace<void>(
        binding: assistant.uiBinding,
        drafts: drafts,
        inputKey: const ValueKey('draft'),
        sendKey: const ValueKey('send'),
        showVoice: false,
        showAttachments: false,
        threads: false,
      ),
    ),
  );
  Future<void> dispose() async {
    drafts.dispose();
    await assistant.dispose();
    client.close();
    for (final gate in [...pages, ...historyGates]) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var n = 0; n < 12; n++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  for (final pause in [50.0, 700.0]) {
    testWidgets(
      'workspace preserves saved message and approval geometry at $pause pause',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var f = Fixture();
        addTearDown(() => f.dispose());
        await tester.pumpWidget(f.surface());
        await frames(tester);
        final transcript = find.byType(HandrailDisplayTranscript);
        final scroll = tester
            .widget<SingleChildScrollView>(
              find
                  .descendant(
                    of: transcript,
                    matching: find.byType(SingleChildScrollView),
                  )
                  .first,
            )
            .controller!;
        f.drafts.controller.text = 'Retain my draft';
        scroll.jumpTo(scroll.position.maxScrollExtent - pause);
        await frames(tester);
        await tester.pump(const Duration(milliseconds: 600));
        final saved = (await f.store.readPosition('chat'))!;
        final before = tester.getTopLeft(find.text('Change pending')).dy;
        final failedBefore = tester.getTopLeft(find.text('Change failed')).dy;
        final anchorMessage = find.byWidgetPredicate(
          (w) =>
              w is HandrailTranscriptMessage &&
              w.message['message_id'] == saved['messageId'],
        );
        final anchorBefore = tester.getTopLeft(anchorMessage).dy;
        expect(saved['following'], isFalse);
        for (var repetition = 0; repetition < 2; repetition++) {
          await tester.pumpWidget(const SizedBox());
          if (pause == 50) {
            // A reload recreates the account controller as well as the view.
            final storage = Map<String, String>.of(f.storage);
            await tester.runAsync(f.dispose);
            f = Fixture()
              ..storage.addAll(storage)
              ..holdPages = true;
          }
          final readiness = <bool>[];
          final readinessSubscription = f.assistant.changes.listen((_) {
            if (readiness.isEmpty || readiness.last != f.assistant.canSend)
              readiness.add(f.assistant.canSend);
          });
          await tester.pumpWidget(f.surface());
          await frames(tester);
          // Cold hydration: saved-window selection replaces an in-flight tail.
          for (var n = 0; n < 4; n++) {
            for (final gate in f.pages) {
              if (!gate.isCompleted) gate.complete();
            }
            await frames(tester);
          }
          f.holdPages = false;
          expect(
            tester.getTopLeft(find.text('Change pending')).dy,
            closeTo(before, .1),
            reason:
                'Cold restore items: ${f.assistant.approvals.presentation["items"]}; saved: $saved',
          );
          expect(
            tester.getTopLeft(find.text('Change failed')).dy,
            closeTo(failedBefore, .1),
          );
          expect(
            tester.getTopLeft(anchorMessage).dy,
            closeTo(anchorBefore, .1),
          );
          expect(f.assistant.canSend, isTrue);
          expect(f.drafts.controller.text, 'Retain my draft');
          final items = f.assistant.approvals.presentation['items'] as List;
          expect(
            items.map((p) => p['status']),
            containsAll(['pending', 'failed', 'executed', 'rejected']),
          );
          expect(
            items.singleWhere((p) => p['status'] == 'pending')['canReject'],
            isTrue,
          );
          expect(find.text('Action history (2)'), findsOneWidget);
          // Quiet time cannot silently replace the paused position.
          await tester.pump(const Duration(seconds: 62));
          await frames(tester);
          expect(
            tester.getTopLeft(find.text('Change failed')).dy,
            closeTo(failedBefore, .1),
          );
          expect(
            tester.getTopLeft(anchorMessage).dy,
            closeTo(anchorBefore, .1),
          );
          expect(
            tester.getTopLeft(find.text('Change pending')).dy,
            closeTo(before, .1),
          );
          expect(
            readiness.skipWhile((ready) => !ready).every((ready) => ready),
            isTrue,
            reason:
                'Composer must not pulse disabled after becoming ready: $readiness',
          );
          await tester.runAsync(readinessSubscription.cancel);
          await tester.pumpWidget(const SizedBox());
          final after = (await f.store.readPosition('chat'))!;
          expect(after['messageId'], saved['messageId']);
          expect(after['offset'], closeTo(saved['offset'] as num, .1));
          expect(after['following'], isFalse);
        }
        await tester.runAsync(f.dispose);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'saved window supplies predecessor context for a positive anchor offset',
    (tester) async {
      final f = Fixture()..holdPages = true;
      addTearDown(f.dispose);
      await f.store.writePosition('chat', {
        'messageId': 'm40',
        'generation': 0,
        'offset': 140.0,
        'following': false,
      });
      await tester.pumpWidget(f.surface());
      await frames(tester);
      for (var n = 0; n < 4; n++) {
        for (final gate in f.pages) {
          if (!gate.isCompleted) gate.complete();
        }
        await frames(tester);
      }
      f.holdPages = false;
      final viewport = find
          .descendant(
            of: find.byType(HandrailDisplayTranscript),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      final message = find.byWidgetPredicate(
        (w) =>
            w is HandrailTranscriptMessage && w.message['message_id'] == 'm40',
      );
      expect(
        tester.getTopLeft(message).dy - tester.getTopLeft(viewport).dy,
        closeTo(140, .1),
      );
      expect(
        f.assistant.session!.displayWindow!.state.records.length,
        lessThanOrEqualTo(60),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.dispose);
    },
  );

  testWidgets(
    'bounded action pages survive transcript eviction and cancel on account disposal',
    (tester) async {
      final f = Fixture()..historyCount = 65;
      addTearDown(f.dispose);
      await tester.pumpWidget(f.surface());
      await frames(tester);
      List<Map> items() =>
          (f.assistant.approvals.presentation['items'] as List).cast<Map>();
      expect(items(), hasLength(32));
      expect(f.historyReads, hasLength(1));
      final window = f.assistant.session!.displayWindow!;
      await window.select(
        'chat',
        anchor: const HandrailDisplayAnchor(
          messageId: 'm10',
          generation: 0,
          newer: true,
          inclusive: true,
        ),
      );
      await frames(tester);
      expect(
        items().where((p) => p['proposal_id'] == 'chat-action-64'),
        hasLength(1),
      );
      expect(window.state.records.any((r) => r.id == 'm70'), isFalse);
      await Future.wait([
        f.assistant.session!.loadApprovalHistory(older: true),
        f.assistant.session!.loadApprovalHistory(older: true),
      ]);
      await frames(tester);
      expect(items(), hasLength(32));
      expect(items().any((p) => p['proposal_id'] == 'chat-action-64'), isFalse);
      expect(items().any((p) => p['proposal_id'] == 'chat-action-5'), isTrue);
      expect(
        items().singleWhere((p) => p['status'] == 'pending')['canReject'],
        isTrue,
      );
      final old = items().firstWhere((p) => p['status'] == 'executed');
      await f.assistant.approvals.review(old['proposal_id'] as String, 1);
      expect(
        items().singleWhere(
          (p) => p['proposal_id'] == old['proposal_id'],
        )['arguments'],
        {'notes': 'Exact executed detail'},
      );
      expect(
        items()
            .where((p) => p['status'] == 'executed')
            .every((p) => p['canConfirm'] == false && p['canReject'] == false),
        isTrue,
      );
      await f.assistant.session!.loadApprovalHistory(older: true);
      await frames(tester);
      expect(items(), hasLength(7));
      expect(f.historyReads, hasLength(3));
      f.holdHistory = true;
      final latePage = f.assistant.session!.loadApprovalHistory();
      final observed = latePage.then((_) {}, onError: (Object _) {});
      await frames(tester);
      final switching = f.assistant.openConversation('other');
      await frames(tester);
      f.holdHistory = false;
      for (final gate in f.historyGates) {
        if (!gate.isCompleted) gate.complete();
      }
      await observed;
      await switching;
      await frames(tester);
      expect(
        items().any(
          (p) => (p['proposal_id'] as String).startsWith('chat-action'),
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.dispose);
      final replacement = Fixture()..historyCount = 3;
      addTearDown(replacement.dispose);
      await tester.pumpWidget(replacement.surface());
      await frames(tester);
      expect(
        replacement.assistant.approvals.presentation['items'],
        hasLength(5),
      );
      replacement.holdHistory = true;
      final cancelled = replacement.assistant.session!
          .loadApprovalHistory()
          .then((_) {}, onError: (Object _) {});
      await frames(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(replacement.dispose);
      await cancelled;
      expect(replacement.assistant.document, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deferred settled details remain inside history and revocation removes them',
    (tester) async {
      final f = Fixture()..deferredHistory = true;
      addTearDown(f.dispose);
      await tester.pumpWidget(f.surface());
      await frames(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HandrailApprovalDecisionsView(
                binding: f.assistant.approvals.uiBinding,
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      expect(find.text('Action history (2)'), findsOneWidget);
      expect(f.operations.where((op) => op == 'content'), isEmpty);
      await tester.tap(find.text('Action history (2)'));
      await frames(tester);
      final read = find.text('Read details');
      await tester.ensureVisible(read);
      await tester.tap(read);
      await frames(tester);
      expect(find.text('Executed: Exact large saved detail'), findsOneWidget);
      expect(f.operations.where((op) => op == 'content'), hasLength(1));
      f.denyHistory = true;
      await expectLater(
        f.assistant.session!.loadApprovalHistory(),
        throwsA(isA<HandrailGatewayException>()),
      );
      await frames(tester);
      expect(f.assistant.document, isNull);
      expect(f.assistant.approvals.presentation['items'], isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.dispose);
    },
  );

  testWidgets(
    'saved-position reload joins its replacement read and retains an unsent draft',
    (tester) async {
      final f = Fixture()..holdPages = true;
      addTearDown(f.dispose);
      await f.store.writePosition('chat', {
        'messageId': 'm10',
        'generation': 0,
        'offset': -12.0,
        'following': false,
      });
      await f.store.writeDraft('chat', 'Please decline this change', null);
      await tester.pumpWidget(f.surface());
      await frames(tester);
      expect(
        f.pages,
        hasLength(2),
        reason:
            'Real transcript restored a saved anchor during initial loading',
      );
      expect(f.assistant.busy, isTrue);
      f.pages[1].complete();
      await frames(tester);
      f.holdPages = false;
      for (final gate in f.pages.skip(1)) {
        if (!gate.isCompleted) gate.complete();
      }
      await frames(tester);
      expect(f.assistant.canSend, isTrue);
      expect(f.assistant.error, isNull);
      expect(find.text('Preparing saved conversation…'), findsNothing);
      expect(f.drafts.controller.text, 'Please decline this change');
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('draft'))).enabled,
        isTrue,
      );
      expect(
        f.assistant.session!.displayWindow!.state.records.map((r) => r.id),
        contains('m10'),
      );
      expect(f.assistant.session!.displayWindow!.followingLatest, isFalse);
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(HandrailDisplayTranscript),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final position = scroll.pixels;
      f.pages[0].complete();
      await frames(tester);
      expect(
        f.assistant.session!.displayWindow!.state.records.map((r) => r.id),
        contains('m10'),
      );
      expect(scroll.pixels, closeTo(position, 0.1));
      expect(f.assistant.canSend, isTrue);
      f.holdPages = false;
      await tester.tap(find.text('Jump to latest'));
      await frames(tester);
      expect(find.text('Jump to latest'), findsNothing);
      expect(f.drafts.controller.text, 'Please decline this change');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.dispose);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preparing becomes ready by account polling with draft and inspectable actions intact',
    (tester) async {
      final f = Fixture()..preparing = true;
      addTearDown(f.dispose);
      f.drafts.controller.text = 'Keep my unsent comment';
      await tester.pumpWidget(f.surface());
      await frames(tester);
      expect(f.assistant.canSend, isFalse);
      expect(find.text('Preparing saved conversation…'), findsWidgets);
      f.preparing = false;
      // Session budgets use wall time; let the unchanged five-second budget
      // elapse, then advance the account timer in the widget clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5100)),
      );
      await tester.pump(const Duration(seconds: 10));
      await frames(tester);
      expect(f.assistant.canSend, isTrue);
      expect(f.assistant.error, isNull);
      expect(find.text('Preparing saved conversation…'), findsNothing);
      expect(f.drafts.controller.text, 'Keep my unsent comment');
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'Typed after restoration',
      );
      await frames(tester);
      final items = f.assistant.approvals.presentation['items'] as List;
      expect(
        items.map((p) => p['status']),
        containsAll(['pending', 'failed', 'executed', 'rejected']),
      );
      expect(
        items.singleWhere((p) => p['status'] == 'pending')['canReject'],
        isTrue,
      );
      expect(find.text('Reject'), findsWidgets);
      expect(find.text('Action history (2)'), findsOneWidget);
      // Mount just the real approval view to inspect off-screen history without
      // the transcript's viewport culling changing the test's scroll target.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HandrailApprovalDecisionsView(
                binding: f.assistant.approvals.uiBinding,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Action history (2)'));
      await frames(tester);
      expect(find.text('Executed'), findsOneWidget);
      expect(find.text('Rejected'), findsOneWidget);
      for (final status in ['executed', 'rejected']) {
        final card = find.ancestor(
          of: find.text(status == 'executed' ? 'Executed' : 'Rejected'),
          matching: find.byType(Card),
        );
        final details = find.descendant(
          of: card,
          matching: find.text('View details'),
        );
        await tester.ensureVisible(details);
        await tester.tap(details);
        await frames(tester);
        expect(find.text('Exact $status detail'), findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.text('Approve')),
          findsNothing,
        );
        expect(
          find.descendant(of: card, matching: find.text('Reject')),
          findsNothing,
        );
      }

      final proposals =
          f.assistant.document!.state['approval_proposals'] as List;
      expect(
        (proposals.singleWhere((p) => p['status'] == 'executed')
            as Map)['reviewed_arguments'],
        {
          'type': 'redacted_json',
          'value': {'notes': 'Exact executed detail'},
        },
      );
      // Reopen the real workspace; no resend and no loss of the locally typed draft.
      await tester.pumpWidget(f.surface());
      await frames(tester);
      expect(f.drafts.controller.text, 'Typed after restoration');
      expect(f.assistant.canSend, isTrue);
      expect(
        f.operations.where(
          (op) => !{
            'control',
            'page',
            'changes',
            '/ai/conversations/list',
            '/ai/conversations/get',
          }.contains(op),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.dispose);
      expect(tester.takeException(), isNull);
    },
  );
}
