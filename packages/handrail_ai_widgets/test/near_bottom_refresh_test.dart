import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'display_transcript_test.dart' as paged;
import 'conversation_transcript_test.dart' as full;

void main() {
  testWidgets('viewport expansion keeps Jump for unloaded newer history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final f = paged.Fixture();
    addTearDown(f.changes.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: HandrailDisplayTranscript(
            binding: f.binding,
            conversationId: 'chat',
            pollInterval: null,
            messageBuilder: (_, row) =>
                SizedBox(height: 100, child: Text(row['id'] as String)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    scroll.jumpTo(scroll.maxScrollExtent - 150);
    await tester.pumpAndSettle();
    f.hasNewer = true;
    f.publish();
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(scroll.extentAfter, lessThanOrEqualTo(2));
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Jump to latest'), findsOneWidget);
    }
    expect(f.latestReads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('full transcript restores a paused conversation on return', (
    tester,
  ) async {
    final f = full.Fixture();
    addTearDown(f.changes.close);
    f.document['messages'] = [
      for (var i = 0; i < 30; i++) full.message('$i', 'Message $i'),
    ];
    await tester.pumpWidget(full.surface(f));
    await tester.pumpAndSettle();
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    scroll.jumpTo(scroll.maxScrollExtent - 50);
    await tester.pumpAndSettle();
    final saved = scroll.pixels;
    f.conversationId = 'two';
    f.publish();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(scroll.extentAfter, lessThanOrEqualTo(2));
    f.conversationId = 'one';
    f.publish();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    expect(scroll.pixels, closeTo(saved, 0.1));
    for (var poll = 0; poll < 61; poll++) {
      if (poll == 30) {
        f.document['messages'] = [
          ...f.document['messages'] as List,
          full.message('arriving', 'Arriving message'),
        ];
      }
      f.publish();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      expect(scroll.pixels, closeTo(saved, 0.1));
    }
    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();
    expect(scroll.extentAfter, lessThanOrEqualTo(2));
    expect(find.byTooltip('Jump to latest'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final distance in [50.0, 700.0]) {
    testWidgets('reader pauses $distance pixels while latest is in flight', (
      tester,
    ) async {
      final f = paged.Fixture()..hasOlder = false;
      addTearDown(f.changes.close);
      final latest = Completer<void>();
      var change = 'initial';
      String? loading;
      final original = f.binding;
      final binding = (
        scope: original.scope,
        changes: original.changes,
        read: () => {...original.read(), 'change': change, 'loading': loading},
        select: original.select,
        older: original.older,
        newer: original.newer,
        latest: () async {
          loading = 'latest';
          f.publish();
          await latest.future;
          loading = null;
          change = 'latest';
          f.version++;
          f.publish();
        },
        refresh: original.refresh,
        retry: original.retry,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 500,
              child: HandrailDisplayTranscript(
                binding: binding,
                conversationId: 'chat',
                pollInterval: null,
                messageBuilder: (_, row) =>
                    SizedBox(height: 100, child: Text(row['id'] as String)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      scroll.jumpTo(scroll.maxScrollExtent - 700);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jump to latest'));
      await tester.pumpAndSettle();
      expect(find.text('Jump to latest'), findsNothing);
      scroll.jumpTo(scroll.maxScrollExtent - distance);
      await tester.pumpAndSettle();
      expect(find.text('Jump to latest'), findsOneWidget);
      final offset = scroll.pixels;
      latest.complete();
      await tester.pumpAndSettle();
      expect(find.text('Jump to latest'), findsOneWidget);
      expect(scroll.pixels, closeTo(offset, 0.1));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
