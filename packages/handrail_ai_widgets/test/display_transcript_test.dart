import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

Map<String, Object?> row(int id, {bool deferred = false}) => {
  'id': 'message-$id',
  'kind': 'message',
  'revision': id,
  'bytes': 200,
  'deferred': deferred,
  'value': deferred
      ? null
      : {
          'message_id': 'message-$id',
          'role': 'assistant',
          'attachments': [],
          'content': [
            {'type': 'text', 'text': 'Message $id'},
          ],
        },
};

class Fixture {
  final changes = StreamController<Object?>.broadcast(sync: true);
  final reads = <(String?, Map<String, Object?>?)>[];
  String? id;
  int start = 21,
      end = 40,
      version = 1,
      olderReads = 0,
      latestReads = 0,
      refreshes = 0,
      retries = 0;
  String? error;
  String status = 'ready';
  Future<void> Function(String?)? onSelect;
  bool hasOlder = true, hasNewer = false, deferred = false;
  bool retryable = true;
  HandrailMessageTextReader? textReader;
  final heights = <int, double>{};
  HandrailDisplayTranscriptBinding get binding => (
    scope: this,
    changes: changes.stream,
    read: () => {
      'conversationId': id,
      'status': status,
      'generation': 0,
      'revision': 100,
      'version': version,
      'hasOlder': hasOlder,
      'hasNewer': hasNewer,
      'loading': null,
      'error': error,
      'retryable': retryable,
      if (textReader != null) 'readMessageText': textReader,
      'change': 'changes',
      'records': id == null
          ? <Map<String, Object?>>[]
          : [
              for (var i = start; i <= end; i++)
                row(i, deferred: deferred && i == end),
            ],
    },
    select: (next, anchor) async {
      reads.add((next, anchor));
      id = next;
      if (next != null) {
        start = 21;
        end = 40;
        hasNewer = false;
      }
      if (onSelect != null) await onSelect!(next);
      publish();
    },
    older: () async {
      olderReads++;
      start -= 10;
      version++;
      if (end - start + 1 > 40) {
        end = start + 39;
        hasNewer = true;
      }
      publish();
    },
    newer: () async {
      end += 10;
      start = end - 39;
      publish();
    },
    latest: () async {
      latestReads++;
      start = 21;
      end = 40;
      hasNewer = false;
      publish();
    },
    refresh: () async {
      refreshes++;
    },
    retry: () async {
      retries++;
      error = null;
      publish();
    },
  );
  void publish() => changes.add(null);
}

Widget surface(
  Fixture f,
  String? id, {
  HandrailDisplayPositionStore? positions,
  bool defaultRenderer = false,
  List<int>? visible,
  double scale = 1,
  double width = 390,
  Duration? pollInterval,
  bool manageSelection = true,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SizedBox(
      width: width,
      height: 500,
      child: HandrailDisplayTranscript(
        binding: f.binding,
        conversationId: id,
        pollInterval: pollInterval,
        positionStore: positions,
        manageSelection: manageSelection,
        onVisibleLatest: (_, revision) => visible?.add(revision),
        messageBuilder: defaultRenderer
            ? null
            : (_, record) {
                final number = int.parse(
                  (record['id'] as String).split('-').last,
                );
                return SizedBox(
                  key: ValueKey<String>(record['id'] as String),
                  height: f.heights[number] ?? 100,
                  child: Text(record['id'] as String),
                );
              },
      ),
    ),
  ),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'default transcript reads large text on demand and retains one bounded section',
    (tester) async {
      final fixture = Fixture()..deferred = true;
      final reads = <int>[];
      final first = '😀' * 8192;
      fixture.textReader =
          (conversation, id, generation, revision, offset, cancellation) async {
            expect(conversation, 'chat');
            expect(id, 'message-40');
            expect(generation, 0);
            expect(revision, 40);
            reads.add(offset);
            return {
              'encoding': 'plain-text',
              'revision': revision,
              'text': offset == 0 ? first : 'Final message part',
              'nextOffset': offset == 0 ? 8192 : null,
            };
          };
      await tester.pumpWidget(surface(fixture, 'chat', defaultRenderer: true));
      await tester.pumpAndSettle();
      expect(reads, isEmpty);
      await tester.ensureVisible(find.text('Read message'));
      await tester.tap(find.text('Read message'));
      await tester.pumpAndSettle();
      expect(find.text(first), findsOneWidget);
      expect(reads, [0]);
      await tester.ensureVisible(find.text('Next part'));
      await tester.tap(find.text('Next part'));
      await tester.pumpAndSettle();
      expect(find.text(first), findsNothing);
      expect(find.text('Final message part'), findsOneWidget);
      expect(reads, [0, 8192]);
      await tester.ensureVisible(find.text('Previous part'));
      await tester.tap(find.text('Previous part'));
      await tester.pumpAndSettle();
      expect(reads, [0, 8192, 0]);
      await tester.ensureVisible(find.text('Close message'));
      await tester.tap(find.text('Close message'));
      await tester.pumpAndSettle();
      expect(find.text(first), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await fixture.changes.close();
    },
  );

  testWidgets(
    'scope replacement aborts large text reads and cannot expose their late content',
    (tester) async {
      final fixture = Fixture()..deferred = true;
      final pending = Completer<Map<String, Object?>>();
      var cancelled = false;
      fixture.textReader = (_, __, ___, ____, _____, cancellation) {
        unawaited(
          cancellation.then((_) {
            cancelled = true;
          }),
        );
        return pending.future;
      };
      await tester.pumpWidget(surface(fixture, 'one'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Read message'));
      await tester.tap(find.text('Read message'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(surface(fixture, 'two'));
      await tester.pumpAndSettle();
      expect(cancelled, isTrue);
      pending.complete({
        'encoding': 'plain-text',
        'revision': 40,
        'text': 'private old text',
        'nextOffset': null,
      });
      await tester.pumpAndSettle();
      expect(find.text('private old text'), findsNothing);
      expect(find.text('Read message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await fixture.changes.close();
    },
  );

  testWidgets(
    'a changed large message requires explicit reload without displaying mixed revisions',
    (tester) async {
      final fixture = Fixture()..deferred = true;
      fixture.textReader = (_, __, ___, ____, _____, ______) async => {
        'errorCode': 'content_changed',
      };
      await tester.pumpWidget(surface(fixture, 'chat'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Read message'));
      await tester.tap(find.text('Read message'));
      await tester.pumpAndSettle();
      expect(find.text('Reload message'), findsOneWidget);
      expect(find.text('Retry reading'), findsNothing);
      await tester.ensureVisible(find.text('Reload message'));
      await tester.tap(find.text('Reload message'));
      await tester.pumpAndSettle();
      expect(fixture.refreshes, 1);
      expect(find.text('Read message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await fixture.changes.close();
    },
  );
  testWidgets(
    'session-owned windows restore durable anchors without another initial read',
    (tester) async {
      final f = Fixture()..id = 'chat';
      addTearDown(f.changes.close);
      final saved = <String, Map<String, Object?>>{
        'chat': {
          'messageId': 'message-24',
          'generation': 0,
          'offset': -15.0,
          'following': false,
        },
      };
      final positions = HandrailDisplayPositionStore.callbacks(
        read: (id) async => saved[id],
        write: (id, position) async {
          saved[id] = position;
        },
      );
      await tester.pumpWidget(
        surface(f, 'chat', positions: positions, manageSelection: false),
      );
      await settle(tester);
      expect(f.reads, isEmpty);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('message-24'))).dy,
        closeTo(-15, 0.1),
      );
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(scroll.offset + 200);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(saved['chat']!['messageId'], 'message-26');
      expect(saved['chat']!['following'], false);
      await tester.pumpWidget(const SizedBox());
      expect(f.reads, isEmpty);
    },
  );

  testWidgets(
    'polls transient failures only in the foreground and stops at permission errors',
    (tester) async {
      final f = Fixture();
      addTearDown(f.changes.close);
      await tester.pumpWidget(
        surface(f, 'chat', pollInterval: const Duration(milliseconds: 250)),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.refreshes, 1);
      f.error = 'Reconnecting';
      f.publish();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.refreshes, 2);
      f.retryable = false;
      f.publish();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(f.refreshes, 2);
      f.error = null;
      f.publish();
      await settle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(f.refreshes, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.refreshes, 3);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(f.refreshes, 3);
    },
  );

  testWidgets(
    'loads one selected page, anchors prepend and delayed layout, bounds rows',
    (tester) async {
      final f = Fixture();
      addTearDown(f.changes.close);
      await tester.pumpWidget(surface(f, 'chat'));
      await settle(tester);
      expect(f.reads.where((call) => call.$1 != null), hasLength(1));
      expect(f.olderReads, 0);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(240);
      await settle(tester);
      final anchor = find.byKey(const ValueKey('message-24'));
      final before = tester.getTopLeft(anchor).dy;
      await f.binding.older();
      await settle(tester);
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
      // A mounted overscan row above the first visible message grows.
      f.heights[21] = 350;
      f.publish();
      await settle(tester);
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
      await f.binding.older();
      await settle(tester);
      await f.binding.older();
      await settle(tester);
      expect(
        find
            .byWidgetPredicate(
              (widget) => widget is SizedBox && widget.key is ValueKey<String>,
            )
            .evaluate()
            .length,
        inInclusiveRange(1, 20),
      );
      expect(
        f.end - f.start + 1,
        40,
        reason: 'Records remain retained while offscreen bodies unmount',
      );
      expect(find.text('Jump to latest'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(f.reads.last.$1, isNull);
    },
  );

  testWidgets(
    'virtualized bodies keep their visible anchor through width changes and remount on navigation',
    (tester) async {
      final f = Fixture();
      addTearDown(f.changes.close);
      await tester.pumpWidget(surface(f, 'chat'));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(240);
      await tester.pumpAndSettle();
      final anchor = find.byKey(const ValueKey('message-24'));
      final before = tester.getTopLeft(anchor).dy;
      await f.binding.older();
      await tester.pumpAndSettle();
      await tester.pumpWidget(surface(f, 'chat', width: 320));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
      expect(
        find.byKey(const ValueKey('message-40')),
        findsNothing,
        reason: 'Offscreen bodies are unmounted',
      );
      await tester.tap(find.text('Jump to latest'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-40')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('message-40'))).bottom,
        closeTo(484, 0.1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'switches immediately, ignores old scope changes and cancels on unmount',
    (tester) async {
      final old = Fixture(), next = Fixture();
      addTearDown(old.changes.close);
      addTearDown(next.changes.close);
      final held = Completer<void>();
      old.onSelect = (id) => id == 'slow' ? held.future : Future.value();
      await tester.pumpWidget(surface(old, 'slow'));
      await tester.pump();
      await tester.pumpWidget(surface(next, 'fast'));
      await settle(tester);
      expect(old.reads.last.$1, isNull);
      held.complete();
      await settle(tester);
      old.id = 'slow';
      old.error = 'Old account error';
      old.publish();
      await settle(tester);
      expect(find.text('Old account error'), findsNothing);
      expect(next.id, 'fast');
      await tester.pumpWidget(const SizedBox());
      expect(next.reads.last.$1, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keeps errors retryable and deferred content explicit without auto reads',
    (tester) async {
      final f = Fixture()..deferred = true;
      addTearDown(f.changes.close);
      await tester.pumpWidget(surface(f, 'chat', defaultRenderer: true));
      await settle(tester);
      expect(find.textContaining('too large for the preview'), findsOneWidget);
      expect(f.olderReads, 0);
      f.error = 'Temporary history failure';
      f.publish();
      await settle(tester);
      expect(find.text('Temporary history failure'), findsOneWidget);
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(f.retries, 1);
      expect(find.text('Temporary history failure'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'restores account-scoped message positions and foreground latest acknowledgements',
    (tester) async {
      final f = Fixture(), positions = MemoryPositions(), visible = <int>[];
      addTearDown(f.changes.close);
      await tester.pumpWidget(
        surface(f, 'one', positions: positions, visible: visible),
      );
      await settle(tester);
      expect(visible, [100]);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(260);
      await settle(tester);
      final before = tester
          .getTopLeft(find.byKey(const ValueKey('message-24')))
          .dy;
      await tester.pumpWidget(
        surface(f, 'two', positions: positions, visible: visible),
      );
      await settle(tester);
      expect(positions.saved['one']?.following, false);
      await tester.pumpWidget(
        surface(f, 'one', positions: positions, visible: visible),
      );
      await settle(tester);
      expect(f.reads.last.$2?['messageId'], positions.saved['one']?.messageId);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('message-24'))).dy,
        closeTo(before, 0.1),
      );
      expect(visible, [100, 100]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'keeps narrow scaled text accessible and never announces hidden pages as read',
    (tester) async {
      final f = Fixture(), visible = <int>[];
      addTearDown(f.changes.close);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        surface(f, 'chat', defaultRenderer: true, visible: visible, scale: 2),
      );
      await settle(tester);
      expect(
        find.byType(HandrailTranscriptMessage).evaluate().length,
        inInclusiveRange(1, 19),
      );
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(HandrailDisplayTranscript)),
        ).scale(12),
        24,
      );
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(120);
      await settle(tester);
      f.hasNewer = true;
      f.publish();
      await settle(tester);
      expect(visible, [100]);
      expect(find.text('Jump to latest'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Jump to latest')).label,
        contains('Jump to latest'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}

class MemoryPositions implements HandrailDisplayPositionStore {
  final saved = <String, HandrailDisplayPosition>{};
  @override
  Future<HandrailDisplayPosition?> read(String id) async => saved[id];
  @override
  Future<void> write(String id, HandrailDisplayPosition position) async {
    saved[id] = position;
  }
}
