import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'display_transcript_test.dart' as paged;

void main() {
  for (final pause in [50.0, 700.0]) {
    testWidgets('reopens a tall saved message at a $pause pixel pause', (
      tester,
    ) async {
      var fixture = paged.Fixture()..id = 'chat';
      final positions = paged.MemoryPositions();
      fixture.heights.addAll({36: 1100, 39: 1300});
      addTearDown(fixture.changes.close);
      Widget view() => paged.surface(
        fixture,
        'chat',
        positions: positions,
        manageSelection: false,
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent - pause);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      final saved = positions.saved['chat']!;
      final anchor = find.byKey(ValueKey(saved.messageId));
      final before = tester.getTopLeft(anchor).dy;
      expect(saved.following, isFalse);
      expect(saved.offset, closeTo(before, .1));
      await tester.pumpWidget(const SizedBox());
      if (pause == 50) {
        // Browser reload: new binding and widget, only durable storage survives.
        final previous = fixture;
        fixture = paged.Fixture()..id = 'chat';
        fixture.heights.addAll(previous.heights);
        addTearDown(fixture.changes.close);
      }
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(before, .1));
      await tester.pumpWidget(const SizedBox());
      expect(positions.saved['chat']!.messageId, saved.messageId);
      expect(positions.saved['chat']!.offset, closeTo(saved.offset, .1));
    });
  }

  testWidgets('keeps a clamped anchor through asynchronous body sizing', (
    tester,
  ) async {
    final fixture = paged.Fixture()..id = 'chat';
    addTearDown(fixture.changes.close);
    final height = ValueNotifier(80.0);
    addTearDown(height.dispose);
    final positions = paged.MemoryPositions();
    positions.saved['chat'] = const HandrailDisplayPosition(
      messageId: 'message-40',
      generation: 0,
      offset: -900,
      following: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 500,
          child: HandrailDisplayTranscript(
            binding: fixture.binding,
            conversationId: 'chat',
            positionStore: positions,
            manageSelection: false,
            pollInterval: null,
            messageBuilder: (_, record) => ValueListenableBuilder<double>(
              valueListenable: height,
              builder: (_, size, _) => SizedBox(
                key: ValueKey(record['id'] as String),
                height: record['id'] == 'message-40' ? size : 80,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // No display-window change or timer: only a descendant's layout changes.
    height.value = 1800;
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('message-40'))).dy,
      closeTo(-900, .1),
    );
    // An explicit Jump cancels restoration, even if the body grows again.
    await tester.tap(find.text('Jump to latest'));
    await tester.pumpAndSettle();
    height.value = 2100;
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    expect(scroll.position.extentAfter, lessThan(.1));
    await tester.pumpWidget(const SizedBox());
    expect(positions.saved['chat']!.following, isTrue);
  });

  testWidgets('restores an older page then keeps its anchor through eviction', (
    tester,
  ) async {
    final fixture = paged.Fixture();
    addTearDown(fixture.changes.close);
    fixture.heights[5] = 950;
    fixture.onSelect = (id) async {
      if (id == null) return;
      fixture.start = 1;
      fixture.end = 20;
      fixture.hasNewer = true;
    };
    final positions = paged.MemoryPositions();
    positions.saved['chat'] = const HandrailDisplayPosition(
      messageId: 'message-5',
      generation: 0,
      offset: -625,
      following: false,
    );
    await tester.pumpWidget(
      paged.surface(fixture, 'chat', positions: positions),
    );
    await tester.pumpAndSettle();
    expect(fixture.reads.last.$2, {'messageId': 'message-5', 'generation': 0});
    final anchor = find.byKey(const ValueKey('message-5'));
    expect(tester.getTopLeft(anchor).dy, closeTo(-625, .1));
    for (var page = 0; page < 3; page++) {
      await fixture.binding.older();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(-625, .1));
    }
    expect(fixture.end - fixture.start + 1, 40);
    expect(fixture.latestReads, 0);
    await tester.pumpWidget(const SizedBox());
    expect(positions.saved['chat']!.messageId, 'message-5');
    expect(positions.saved['chat']!.offset, -625);
  });

  for (final switchAccount in [false, true]) {
    testWidgets(
      'late position read is fenced after ${switchAccount ? 'account switch' : 'disposal'}',
      (tester) async {
        final old = paged.Fixture(), next = paged.Fixture();
        addTearDown(old.changes.close);
        addTearDown(next.changes.close);
        final pending = Completer<Map<String, Object?>?>();
        final writes = <String>[];
        final store = HandrailDisplayPositionStore.callbacks(
          read: (_) => pending.future,
          write: (id, _) async {
            writes.add(id);
          },
        );
        await tester.pumpWidget(paged.surface(old, 'chat', positions: store));
        await tester.pump();
        await tester.pumpWidget(
          switchAccount ? paged.surface(next, 'chat') : const SizedBox(),
        );
        await tester.pumpAndSettle();
        pending.complete({
          'messageId': 'message-25',
          'generation': 0,
          'offset': -700.0,
          'following': false,
        });
        await tester.pumpAndSettle();
        expect(old.reads.where((call) => call.$1 != null), isEmpty);
        expect(writes, isEmpty);
        expect(find.text('Jump to latest'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancelled selection cannot overwrite either account position', (
    tester,
  ) async {
    final old = paged.Fixture(), next = paged.Fixture()..id = 'chat';
    addTearDown(old.changes.close);
    addTearDown(next.changes.close);
    final pending = Completer<void>();
    old.onSelect = (id) => id == null ? Future.value() : pending.future;
    final oldPositions = paged.MemoryPositions(),
        nextPositions = paged.MemoryPositions();
    oldPositions.saved['chat'] = const HandrailDisplayPosition(
      messageId: 'message-39',
      generation: 0,
      offset: -900,
      following: false,
    );
    nextPositions.saved['chat'] = const HandrailDisplayPosition(
      messageId: 'message-24',
      generation: 0,
      offset: -15,
      following: false,
    );
    await tester.pumpWidget(
      paged.surface(old, 'chat', positions: oldPositions),
    );
    await tester.pump();
    await tester.pumpWidget(
      paged.surface(
        next,
        'chat',
        positions: nextPositions,
        manageSelection: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(old.reads.last.$1, isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('message-24'))).dy,
      closeTo(-15, .1),
    );
    await tester.pumpWidget(const SizedBox());
    expect(oldPositions.saved['chat']!.offset, -900);
    expect(nextPositions.saved['chat']!.offset, -15);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a new generation invalidates the restored position on first load',
    (tester) async {
      final fixture = paged.Fixture();
      addTearDown(fixture.changes.close);
      final positions = paged.MemoryPositions();
      positions.saved['chat'] = const HandrailDisplayPosition(
        messageId: 'message-24',
        generation: 9,
        offset: -500,
        following: false,
      );
      await tester.pumpWidget(
        paged.surface(fixture, 'chat', positions: positions),
      );
      await tester.pumpAndSettle();
      expect(find.text('Jump to latest'), findsNothing);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      expect(scroll.position.extentAfter, lessThan(.1));
      await tester.pumpWidget(const SizedBox());
      expect(positions.saved['chat']!.generation, 0);
      expect(positions.saved['chat']!.following, isTrue);
    },
  );
}
