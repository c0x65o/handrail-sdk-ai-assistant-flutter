// Real Flutter workspace + account controller + monitor + bounded session.
// Only HTTP and storage are simulated; no provider or voice operations occur.
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
  final requests = <String>[];
  final voiceScopes = <List<String>>[];
  final messages = <Map<String, Object?>>[];
  int revision = 100, admissions = 0, starts = 0, cancellations = 0;
  String? turnId;
  String status = 'completed';
  bool offline = false;
  Completer<void>? admissionGate;
  late final store = HandrailKeyValuePendingTurnStore(
    namespace: 'reentrant-test',
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
  late HandrailAssistantController assistant = controller();
  late HandrailComposerController drafts =
      HandrailComposerController.forAssistant(assistant.uiBinding);

  HandrailAssistantController controller() => HandrailAssistantController(
    client: client,
    pendingStore: store,
    autoCreate: false,
    pollingInterval: null,
    voicePollingInterval: null,
    readVoiceWorkspace: (ids, _) async {
      voiceScopes.add(List.of(ids));
      return HandrailRealtimeWorkspacePage(calls: []);
    },
  );
  Map<String, Object?> descriptor(String id) => {
    'conversationId': id,
    'title': id,
    'version': 1,
    'lifecycle': 'active',
  };
  Map<String, Object?> header(String id) => {
    'schemaVersion': 1,
    'conversationId': id,
    'status': 'ready',
    'generation': 0,
    'revision': revision,
    'canonicalRevision': revision,
    'activeTurnId': running ? turnId : null,
  };
  bool get running => status == 'queued' || status == 'running';
  Map<String, Object?>? get turn => turnId == null
      ? null
      : {
          'turnId': turnId,
          'revision': revision,
          'status': status,
          'remoteMayStillBeRunning': running,
          'error': null,
        };
  Map<String, Object?> record(
    String id,
    String text, {
    String role = 'assistant',
  }) => {
    'kind': 'message',
    'id': id,
    'revision': revision,
    'turnId': turnId,
    'bytes': 1000,
    'deferred': false,
    'value': {
      'message_id': id,
      'turn_id': turnId,
      'role': role,
      'attachments': [],
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };
  List<Map<String, Object?>> get page => [
    for (var n = messages.length; n < 30; n++)
      record(
        'saved-$n',
        'Saved message $n. **Retained history.**\n\n'
            '${'A synthetic history paragraph. ' * 8}',
      ),
    ...messages,
  ];
  http.Response ok(Object value) => http.Response(
    jsonEncode({'ok': true, 'value': value}),
    200,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    requests.add(path);
    if (path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'activity': false,
        'authoritativeCancellation': true,
        'displayHistory': {
          'version': 1,
          'control': true,
          'maximumPageSize': 50,
          'maximumPageBytes': 262144,
        },
      });
    final body = jsonDecode(request.body) as Map;
    if (path.endsWith('/conversations/list'))
      return ok({
        'items': [descriptor('chat')],
        'hasMore': false,
        'nextCursor': null,
        'order': body['order'],
      });
    if (path.endsWith('/conversations/get'))
      return ok({'descriptor': descriptor(body['conversationId'] as String)});
    final input = body['input'] as Map? ?? {};
    final id = input['conversationId'] as String? ?? 'chat';
    if (path.endsWith('/conversations/history')) {
      if (offline) return http.Response('offline', 503);
      switch (body['operation']) {
        case 'control':
          return ok({
            ...header(id),
            'activeTurn': running ? turn : null,
            'latestTurn': turn,
            'requestedTurn': input['turnId'] == turnId ? turn : null,
          });
        case 'page':
          return ok({
            ...header(id),
            'records': input['view'] == null ? page : [],
            'nextCursor': null,
          });
        case 'changes':
          return ok({
            ...header(id),
            'records': messages
                .where(
                  (m) =>
                      (m['revision'] as int) > (input['afterRevision'] as int),
                )
                .toList(),
            'nextCursor': null,
            'throughRevision': revision,
          });
      }
    }
    if (path.endsWith('/synchronization') &&
        body['operation'] == 'append_mutations') {
      admissions++;
      await admissionGate?.future;
      final mutations = (input['mutations'] as List).cast<Map>();
      final events = mutations.expand((m) => m['events'] as List).cast<Map>();
      turnId =
          (events.singleWhere(
                    (e) => (e['payload'] as Map)['type'] == 'turn.started',
                  )['payload']
                  as Map)['turn_id']
              as String;
      status = 'queued';
      revision++;
      return ok({
        'status': 'mutations',
        'acknowledgements': [
          for (final m in mutations)
            {'mutationId': m['mutationId'], 'status': 'accepted'},
        ],
      });
    }
    if (path.endsWith('/turns/start')) {
      starts++;
      status = 'running';
      revision++;
      return http.Response(
        'event: started\ndata: ${jsonEncode({'conversationId': 'chat', 'turnId': turnId, 'mutationId': body['mutationId']})}\n\n',
        200,
      );
    }
    if (path.endsWith('/turns/cancel')) {
      cancellations++;
      expect(body['turnId'], turnId);
      status = 'cancelled';
      revision++;
      return ok({'status': 'cancellation_requested'});
    }
    throw StateError('Unexpected synthetic request: $path');
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
  Future<void> reload() async {
    drafts.dispose();
    await assistant.dispose();
    assistant = controller();
    drafts = HandrailComposerController.forAssistant(assistant.uiBinding);
  }

  Future<void> dispose() async {
    drafts.dispose();
    await assistant.dispose();
    client.close();
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var n = 0; n < 15; n++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> settle(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  operation.then(
    (_) {
      done = true;
    },
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  for (var n = 0; n < 20 && !done; n++) {
    await frames(tester);
    // Stream cancellation can complete outside the widget clock. Flush both
    // queues while retaining a bounded assertion on controller completion.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(done, isTrue, reason: 'Controller operation must finish');
  expect(failure, isNull);
}

void main() {
  testWidgets(
    'rapid controller/monitor updates retain the mobile send lifecycle',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final f = Fixture();
      addTearDown(() => tester.runAsync(f.dispose));
      await tester.pumpWidget(f.surface());
      await frames(tester);
      expect(f.assistant.canSend, isTrue);
      expect(f.assistant.document!.messages, hasLength(30));

      // A descriptor can arrive between text publications. The next monitor
      // loading event reconciles its scope from inside the controller listener.
      await f.assistant.getDescriptor('other');
      await f.assistant.voiceWorkspace!.refresh();
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(f.voiceScopes.last, ['chat', 'other']);
      for (var i = 0; i < 8; i++) {
        f.assistant.setUnreadOnly(i.isEven);
        unawaited(f.assistant.refreshObservations());
      }
      await frames(tester);
      expect(f.assistant.error, isNull);

      final transcript = find.byType(HandrailDisplayTranscript);
      ScrollPosition scroll() => tester
          .state<ScrollableState>(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      scroll().jumpTo(scroll().maxScrollExtent - 700);
      await frames(tester);
      expect(find.text('Jump to latest'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await frames(tester);
      expect(find.text('Jump to latest'), findsOneWidget);
      await tester.tap(find.text('Jump to latest'));
      await frames(tester);
      expect(scroll().extentAfter, lessThanOrEqualTo(2));
      tester.view.resetViewInsets();
      await frames(tester);

      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'Synthetic request',
      );
      await frames(tester);
      f.admissionGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('send')));
      await frames(tester);
      expect(f.admissions, 1);
      expect(f.assistant.submitting, isTrue);
      expect(
        f.assistant.session!.outgoingMessage?['delivery_status'],
        'sending',
      );
      final echo = Map<String, Object?>.from(
        f.assistant.session!.outgoingMessage!,
      );
      f.admissionGate!.complete();
      await frames(tester);
      expect(f.starts, 1);
      expect(f.assistant.session!.outgoingMessage?['delivery_status'], 'sent');
      expect(f.assistant.hasPendingMessage, isFalse);
      expect(f.assistant.error, isNull);
      expect(f.assistant.canStop, isTrue);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('draft')))
            .controller!
            .text,
        isEmpty,
      );

      // Canonical projection catches up to the accepted echo; text updates must
      // neither duplicate it nor make voice observation restart for each delta.
      final voiceReads = f.voiceScopes.length;
      f.revision++;
      f.messages.add(
        f.record(
          echo['message_id'] as String,
          'Synthetic request',
          role: 'user',
        ),
      );
      for (var n = 0; n < 8; n++) {
        f.revision++;
        final answer = f.record(
          'answer',
          'Streaming answer $n\n\n${'**Details**. ' * (n + 1)}',
        );
        if (f.messages.length == 1) {
          f.messages.add(answer);
        } else {
          f.messages[1] = answer;
        }
        await settle(tester, f.assistant.session!.refresh());
        await frames(tester);
        expect(f.assistant.error, isNull);
      }
      expect(f.voiceScopes, hasLength(voiceReads));
      expect(f.assistant.session!.outgoingMessage, isNull);
      expect(
        f.assistant.document!.messages.where(
          (m) => m['message_id'] == echo['message_id'],
        ),
        hasLength(1),
      );
      expect(
        find.textContaining('Streaming answer 7', findRichText: true),
        findsOneWidget,
      );

      // Closing the SDK surface keeps account-owned work alive; reopening and
      // a fresh controller reload recover the same canonical transcript.
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(f.assistant.running, isTrue);
      await tester.pumpWidget(f.surface());
      await frames(tester);
      expect(f.assistant.canStop, isTrue);
      await tester.tap(find.byTooltip('Stop response'));
      await frames(tester);
      expect(f.cancellations, 1);
      expect(f.assistant.running, isFalse);
      expect(f.assistant.canSend, isTrue);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, f.reload());
      await tester.pumpWidget(f.surface());
      await frames(tester);
      expect(f.assistant.document!.latestTurn!['status'], 'cancelled');
      expect(
        find.textContaining('Streaming answer 7', findRichText: true),
        findsOneWidget,
      );
      expect(f.admissions, 1);
      expect(f.starts, 1);
      expect(f.requests.any((path) => path.contains('realtime')), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed preflight retains last good history and makes no admission',
    (tester) async {
      final f = Fixture();
      addTearDown(() => tester.runAsync(f.dispose));
      await tester.pumpWidget(f.surface());
      await frames(tester);
      final before = f.assistant.document!.messages;
      f.offline = true;
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'Retain this draft',
      );
      await frames(tester);
      await tester.tap(find.byKey(const ValueKey('send')));
      await frames(tester);
      expect(f.admissions, 0);
      expect(f.starts, 0);
      expect(f.assistant.document!.messages, before);
      expect(f.assistant.error, isNotNull);
      expect(f.assistant.session!.outgoingMessage, isNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('draft')))
            .controller!
            .text,
        'Retain this draft',
      );
      f.offline = false;
      await settle(tester, f.assistant.openConversation('chat'));
      await frames(tester);
      expect(f.assistant.canSend, isTrue);
      expect(f.assistant.error, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
