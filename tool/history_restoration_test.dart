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
        if (input['view'] != null)
          return ok({
            ...header(id),
            'records': [
              for (final status in [
                'executed',
                'rejected',
                'pending',
                'failed',
              ])
                proposal(status),
            ],
            'nextCursor': null,
          });
        final gate = Completer<void>();
        pages.add(gate);
        // Capture before the wait to also test obsolete late response fencing.
        final anchor = input['anchor'] as Map?;
        final start = anchor == null
            ? 70
            : int.parse((anchor['messageId'] as String).substring(1));
        final response = ok({
          ...header(id),
          'records': [for (var n = start; n < start + 30; n++) message(n)],
          'nextCursor': anchor == null ? 'older' : null,
        });
        if (holdPages) await gate.future;
        return response;
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
    for (final gate in pages) {
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
        expect(saved['following'], isFalse);
        await tester.pumpWidget(const SizedBox());
        if (pause == 50) {
          // A reload recreates the account controller as well as the view.
          final storage = Map<String, String>.of(f.storage);
          await tester.runAsync(f.dispose);
          f = Fixture()..storage.addAll(storage);
        }
        await tester.pumpWidget(f.surface());
        await frames(tester);
        expect(
          tester.getTopLeft(find.text('Change pending')).dy,
          closeTo(before, .1),
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
        await tester.pump(const Duration(seconds: 61));
        await frames(tester);
        expect(
          tester.getTopLeft(find.text('Change pending')).dy,
          closeTo(before, .1),
        );
        await tester.pumpWidget(const SizedBox());
        final after = (await f.store.readPosition('chat'))!;
        expect(after['messageId'], saved['messageId']);
        expect(after['offset'], closeTo(saved['offset'] as num, .1));
        expect(after['following'], isFalse);
        await tester.runAsync(f.dispose);
        expect(tester.takeException(), isNull);
      },
    );
  }
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
      expect(f.assistant.canSend, isTrue);
      expect(f.assistant.error, isNull);
      expect(find.text('Preparing saved conversation…'), findsNothing);
      expect(f.drafts.controller.text, 'Please decline this change');
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('draft'))).enabled,
        isTrue,
      );
      expect(f.assistant.session!.displayWindow!.state.records.first.id, 'm10');
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
      expect(f.assistant.session!.displayWindow!.state.records.first.id, 'm10');
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
      expect((proposals.first as Map)['reviewed_arguments'], {
        'type': 'redacted_json',
        'value': {'notes': 'Exact executed detail'},
      });
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
