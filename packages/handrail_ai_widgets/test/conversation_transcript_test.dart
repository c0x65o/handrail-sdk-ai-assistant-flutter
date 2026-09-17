import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

Map<String, Object?> message(
  String id,
  String text, {
  String role = 'assistant',
}) => {
  'message_id': id,
  'role': role,
  'content': [
    {'type': 'text', 'text': text},
  ],
  'attachments': [],
};

class Fixture {
  final changes = StreamController<Object?>.broadcast();
  final document = <String, Object?>{
    'revision': 1,
    'messages': [
      message('question', '**Literal question**', role: 'user'),
      message('answer', 'A **formatted** answer'),
    ],
    'turns': [
      {
        'turn_id': 'turn',
        'status': 'completed',
        'input_message_ids': ['question'],
        'output_message_ids': ['answer'],
      },
    ],
    'tool_calls': [],
    'citations': [],
    'citation_sources': [],
  };
  bool running = false, pending = false;
  String conversationId = 'one';
  String? error;
  Future<void> Function()? retryOperation;
  int reads = 0, retries = 0;
  HandrailDisplayTranscriptBinding? display;
  HandrailTranscriptUiBinding get binding => (
    scope: this,
    changes: changes.stream,
    read: () => {
      'conversationId': conversationId,
      'document': document,
      'running': running,
      'pending': pending,
      'displayWindow': display,
      'error': error,
    },
    retry: () async {
      retries++;
      if (retryOperation case final operation?) return operation();
      error = null;
      publish();
    },
    markRead: () async {
      reads++;
    },
  );
  void publish() => changes.add(null);
}

Widget surface(
  Fixture fixture, {
  Size size = const Size(720, 650),
  double scale = 1,
  ValueChanged<String>? onOpenLink,
  Widget? Function(BuildContext, Map<String, Object?>)? toolResultBuilder,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SizedBox(
      width: size.width,
      height: size.height,
      child: HandrailConversationTranscript(
        binding: fixture.binding,
        onOpenLink: onOpenLink,
        toolResultBuilder: toolResultBuilder,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'standard transcript uses bounded pages with citations, activity and no duplicate selection',
    (tester) async {
      final f = Fixture(),
          displayChanges = StreamController<Object?>.broadcast(sync: true);
      addTearDown(f.changes.close);
      addTearDown(displayChanges.close);
      var first = 21, selects = 0, older = 0, version = 1;
      Map<String, Object?> record(int i) => {
        'id': 'message-$i',
        'kind': 'message',
        'revision': 1,
        'deferred': false,
        'bytes': 120,
        'value': message('message-$i', 'Message $i'),
      };
      f.document['citation_sources'] = [
        {
          'source_id': 'source',
          'label': 'Source for this answer',
          'locator': '/source',
        },
      ];
      f.document['citations'] = [
        {
          'source_id': 'source',
          'target': {'type': 'assistant_message', 'message_id': 'message-40'},
          'order': 1,
        },
      ];
      f.document['tool_calls'] = [
        {'tool_call_id': 'tool', 'name': 'Lookup', 'status': 'completed'},
      ];
      f.running = true;
      f.display = (
        scope: displayChanges,
        changes: displayChanges.stream,
        read: () => {
          'conversationId': 'one',
          'generation': 0,
          'revision': 1,
          'status': 'ready',
          'version': version,
          'hasOlder': first > 1,
          'hasNewer': false,
          'loading': null,
          'error': null,
          'change': 'older',
          'records': [for (var i = first; i <= 40; i++) record(i)],
        },
        select: (_, __) async {
          selects++;
        },
        older: () async {
          first = 1;
          older++;
          version++;
          displayChanges.add(null);
        },
        newer: () async {},
        latest: () async {},
        refresh: () async {},
        retry: () async {},
      );
      await tester.pumpWidget(
        surface(
          f,
          toolResultBuilder: (_, tool) =>
              Text('Business result: ${tool['name']}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(selects, 0);
      expect(older, 0);
      expect(find.byType(HandrailDisplayTranscript), findsOneWidget);
      expect(find.byType(HandrailTranscriptMessage), findsNWidgets(20));
      expect(find.text('Source for this answer'), findsOneWidget);
      expect(find.text('Business result: Lookup'), findsOneWidget);
      expect(f.reads, 0);
      f.running = false;
      f.publish();
      await tester.pumpAndSettle();
      expect(
        f.reads,
        1,
        reason:
            'Completion on the same loaded revision becomes read at the visible tail',
      );
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(older, 1);
      expect(find.byType(HandrailTranscriptMessage), findsNWidgets(40));
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      expect(
        selects,
        0,
        reason: 'The account session owns selection and lifetime',
      );
    },
  );

  for (final showAuthor in [false, true]) {
    testWidgets(
      'branding preserves operational message identity ($showAuthor)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        for (final role in ['user', 'assistant', 'system', 'tool', 'unknown']) {
          final label = switch (role) {
            'user' => 'Family member',
            'assistant' => 'Mills',
            'system' => 'System',
            'tool' => 'Tool result',
            _ => 'Message',
          };
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: HandrailTranscriptMessage(
                  message: message(role, 'Saved content', role: role),
                  style: HandrailTranscriptStyle(
                    showAuthor: showAuthor,
                    userLabel: 'Family member',
                    assistantLabel: 'Mills',
                    assistantAvatar: const Icon(Icons.auto_awesome),
                  ),
                ),
              ),
            ),
          );
          expect(
            find.text(label),
            showAuthor || !['user', 'assistant'].contains(role)
                ? findsOneWidget
                : findsNothing,
          );
          expect(
            find.byIcon(Icons.auto_awesome),
            role == 'assistant' ? findsOneWidget : findsNothing,
          );
          expect(
            find.bySemanticsLabel(
              role == 'unknown'
                  ? 'Message, message.'
                  : '$label, $role message.',
            ),
            findsOneWidget,
          );
        }
        semantics.dispose();
      },
    );
  }
  for (final allow in [false, true]) {
    testWidgets(
      'message-link policy is independent of a citation resolver veto ($allow)',
      (tester) async {
        final links = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HandrailTranscriptMessage(
                message: message('answer', '[Raw message](/home)'),
                allowMessageLinks: allow,
                onOpenLink: links.add,
                citationLink: (source) =>
                    source['source_id'] == 'trusted' ? '/review' : null,
                citations: const [
                  {
                    'source_id': 'trusted',
                    'label': 'Trusted reference',
                    'locator': '/raw',
                  },
                  {
                    'source_id': 'untrusted',
                    'label': 'Rejected reference',
                    'locator': '/home',
                  },
                ],
              ),
            ),
          ),
        );
        tester
            .widget<HandrailMarkdown>(find.byType(HandrailMarkdown))
            .onTapLink!('Raw message', '/home', null);
        expect(links, allow ? ['/home'] : isEmpty);
        expect(
          tester
              .widget<ActionChip>(
                find.widgetWithText(ActionChip, 'Rejected reference'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Trusted reference'));
        expect(links.last, '/review');
        expect(links.length, allow ? 2 : 1);
      },
    );
  }
  testWidgets('user, system and tool message text stays literal', (
    tester,
  ) async {
    for (final role in ['user', 'system', 'tool']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailTranscriptMessage(
              message: message(role, '**Literal** [link](/home)', role: role),
            ),
          ),
        ),
      );
      expect(find.text('**Literal** [link](/home)'), findsOneWidget);
    }
  });

  testWidgets(
    'protected copy reports an accessible failure and retries exact visible text',
    (tester) async {
      var fail = true;
      final copied = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailTranscriptMessage(
              message: message('copy', 'A **complete** household answer'),
              copyText: (text) async {
                copied.add(text);
                if (fail) throw StateError('Private clipboard details');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(
        find.textContaining('The message was not copied.'),
        findsOneWidget,
      );
      expect(find.textContaining('Private clipboard'), findsNothing);
      expect(
        tester
            .widget<Semantics>(
              find
                  .ancestor(
                    of: find.textContaining('The message was not copied.'),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .liveRegion,
        isTrue,
      );
      fail = false;
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
      expect(find.textContaining('The message was not copied.'), findsNothing);
      expect(copied, [
        'A **complete** household answer',
        'A **complete** household answer',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('a stale copy failure cannot replace a later success', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HandrailTranscriptMessage(
            message: message('copy', 'Answer'),
            copyText: (_) {
              calls++;
              return calls == 1 ? pending.future : Future<void>.value();
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    pending.completeError(StateError('Delayed clipboard failure'));
    await tester.pump();
    expect(find.text('Copied'), findsOneWidget);
    expect(find.textContaining('The message was not copied.'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'minimal transcript supplies Markdown, safe citations, copy, results and private activity',
    (tester) async {
      final fixture = Fixture(), links = <String>[];
      addTearDown(fixture.changes.close);
      fixture.document['citation_sources'] = [
        {'source_id': 'safe', 'label': 'Ledger', 'locator': '/finance/ledger'},
        {
          'source_id': 'unsafe',
          'label': 'Blocked source',
          'locator': 'javascript:alert(1)',
        },
      ];
      fixture.document['citations'] = [
        for (final source in ['safe', 'unsafe'])
          {
            'source_id': source,
            'order': 0,
            'target': {'type': 'assistant_message', 'message_id': 'answer'},
          },
      ];
      fixture.document['tool_calls'] = [
        {
          'tool_call_id': 'result',
          'turn_id': 'turn',
          'name': 'business_result',
          'arguments': {'secret': 'private argument'},
          'result': {'is_error': true},
        },
      ];
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        surface(
          fixture,
          onOpenLink: links.add,
          toolResultBuilder: (_, tool) => const Text('Business result card'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HandrailTranscriptMessage), findsNWidgets(2));
      expect(find.text('**Literal question**'), findsOneWidget);
      expect(find.text('Business result card'), findsOneWidget);
      expect(find.text('1 tool called · 1 failed'), findsOneWidget);
      await tester.ensureVisible(find.text('Ledger'));
      await tester.tap(find.text('Ledger'));
      expect(links, ['/finance/ledger']);
      final blocked = tester.widget<ActionChip>(
        find.widgetWithText(ActionChip, 'Blocked source'),
      );
      expect(blocked.onPressed, isNull);
      await tester.ensureVisible(find.text('Copy').last);
      await tester.tap(find.text('Copy').last);
      await tester.pump();
      expect(copied, 'A **formatted** answer');
      await tester.ensureVisible(find.text('1 tool called · 1 failed'));
      await tester.tap(find.text('1 tool called · 1 failed'));
      await tester.pumpAndSettle();
      expect(find.text('business_result'), findsOneWidget);
      expect(find.textContaining('private argument'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new replies preserve a scrolled-up position and become read at the visible end',
    (tester) async {
      final fixture = Fixture();
      addTearDown(fixture.changes.close);
      fixture.document['messages'] = [
        for (var i = 0; i < 25; i++)
          message('answer-$i', 'Reply $i\nMore detail\nAnother line'),
      ];
      await tester.pumpWidget(surface(fixture, size: const Size(600, 500)));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.controller!.position.extentAfter, lessThan(1));
      expect(fixture.reads, 1);
      await tester.drag(find.byType(ListView), const Offset(0, 450));
      await tester.pumpAndSettle();
      final offset = list.controller!.offset;
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      fixture.document['revision'] = 2;
      (fixture.document['messages'] as List).add(
        message('new-answer', 'A new reply'),
      );
      fixture.publish();
      await tester.pumpAndSettle();
      expect(list.controller!.offset, closeTo(offset, 1));
      expect(fixture.reads, 1);
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();
      expect(list.controller!.position.extentAfter, lessThan(1));
      expect(fixture.reads, 2);
    },
  );

  testWidgets(
    'covered and background replies become read only when the transcript is visible',
    (tester) async {
      final fixture = Fixture()..running = true;
      addTearDown(fixture.changes.close);
      await tester.pumpWidget(surface(fixture));
      await tester.pumpAndSettle();
      expect(fixture.reads, 0);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Another screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      fixture.running = false;
      fixture.publish();
      await tester.pumpAndSettle();
      expect(fixture.reads, 0);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(fixture.reads, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      fixture.document['revision'] = 2;
      fixture.publish();
      await tester.pumpAndSettle();
      expect(fixture.reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.reads, 2);
    },
  );

  testWidgets('a prior conversation retry cannot unlock a later retry', (
    tester,
  ) async {
    final first = Completer<void>(), second = Completer<void>();
    final fixture = Fixture()
      ..error = 'Connection failed'
      ..retryOperation = () => first.future;
    addTearDown(fixture.changes.close);
    await tester.pumpWidget(surface(fixture));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(fixture.retries, 1);
    fixture.conversationId = 'two';
    fixture.retryOperation = () => second.future;
    fixture.publish();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(fixture.retries, 2);
    first.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retrying…'), findsOneWidget);
    second.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'custom domain formatting retains SDK account isolation and visible read lifecycle',
    (tester) async {
      final first = Fixture(), second = Fixture();
      addTearDown(first.changes.close);
      addTearDown(second.changes.close);
      Widget custom(Fixture fixture, String label) => MaterialApp(
        home: Scaffold(
          body: HandrailConversationTranscript(
            binding: fixture.binding,
            contentBuilder: (context, document) => [
              TextFormField(
                key: const ValueKey('business-card'),
                initialValue: label,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(custom(first, 'First account business data'));
      await tester.pumpAndSettle();
      expect(first.reads, 1);
      await tester.enterText(
        find.byType(TextFormField),
        'Unsaved first account',
      );
      await tester.pumpWidget(custom(second, 'Second account business data'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Second account business data',
      );
      expect(second.reads, 1);
      expect(find.text('Unsaved first account'), findsNothing);
    },
  );

  testWidgets(
    'account replacement clears old content and error recovery works with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = Fixture(), second = Fixture();
      addTearDown(first.changes.close);
      addTearDown(second.changes.close);
      first.error =
          'A long connection failure that must remain readable at increased text size.';
      first.pending = true;
      await tester.pumpWidget(surface(first, scale: 2));
      await tester.pumpAndSettle();
      expect(first.reads, 0);
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(first.retries, 1);
      second.document['messages'] = [
        message('new-account', 'New account content'),
      ];
      await tester.pumpWidget(surface(second, scale: 2));
      first.document['messages'] = [
        message('old-account', 'Old account secret'),
      ];
      first.publish();
      await tester.pumpAndSettle();
      expect(find.textContaining('Old account secret'), findsNothing);
      expect(find.byType(HandrailTranscriptMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
