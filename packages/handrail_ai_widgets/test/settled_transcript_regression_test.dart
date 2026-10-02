import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'conversation_transcript_test.dart' as full;
import 'display_transcript_test.dart' as paged;

void main() {
  testWidgets(
    'settled vehicle, review and invoice actions collapse without executing',
    (tester) async {
      final changes = StreamController<Object?>.broadcast();
      addTearDown(changes.close);
      var scope = Object();
      var conversation = 'one';
      var calls = 0;
      final items = <Map<String, Object?>>[
        for (final name in [
          'Review proposed change',
          'Update a vehicle or boat',
          'Send invoice',
        ])
          {
            'proposal_id': name,
            'proposal_version': 1,
            'tool_name': name,
            'status': 'executed',
          },
      ];
      Widget view() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HandrailApprovalDecisionsView(
              binding: (
                scope: scope,
                changes: changes.stream,
                read: () => {'conversationId': conversation, 'items': items},
                review: (_, _) async {
                  calls++;
                },
                decide: (_, _, _, _) async {
                  calls++;
                },
                retry: (_) async {
                  calls++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(view());
      expect(find.byType(Card), findsNothing);
      expect(find.text('Action history (3)'), findsOneWidget);
      await tester.tap(find.text('Action history (3)'));
      await tester.pumpAndSettle();
      expect(find.text('Executed'), findsNWidgets(3));
      conversation = 'two';
      changes.add(null);
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
      scope = Object();
      await tester.pumpWidget(view());
      expect(find.byType(Card), findsNothing);
      for (final status in [
        'rejected',
        'expired',
        'finished',
        'completed',
        'executed',
      ]) {
        items[0]['status'] = status;
        changes.add(null);
        changes.add(null);
        await tester.pumpAndSettle();
        expect(find.byType(Card), findsNothing);
      }
      for (final status in [
        'pending',
        'confirmed',
        'executing',
        'failed',
        'unknown',
      ]) {
        items[0].addAll({
          'status': status,
          'canConfirm': false,
          'canReject': false,
        });
        changes.add(null);
        await tester.pumpAndSettle();
        expect(find.byType(Card), findsOneWidget);
      }
      for (final unresolved in ['pendingDecision', 'busy']) {
        items[0].addAll({'status': 'executed', unresolved: true});
        changes.add(null);
        await tester.pump();
        expect(find.byType(Card), findsOneWidget);
        items[0].remove(unresolved);
      }
      // Read-only inspection must not reactivate a settled action.
      items[0]['reviewing'] = true;
      changes.add(null);
      await tester.pump();
      expect(find.byType(Card), findsNothing);
      items[0].remove('reviewing');
      items[0]['error'] = 'Check the saved outcome';
      changes.add(null);
      await tester.pump();
      expect(find.text('Check the saved outcome'), findsOneWidget);
      items[0].remove('error');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(view());
      expect(find.byType(Card), findsNothing);
      expect(items, hasLength(3));
      expect(calls, 0);
    },
  );
  for (final paginated in [false, true]) {
    testWidgets(
      '${paginated ? 'paged' : 'full'} jump stays steady across near-tail movement, streaming and keyboard layout',
      (tester) async {
        final jump = paginated
            ? find.text('Jump to latest')
            : find.byTooltip('Jump to latest');
        final f = full.Fixture();
        final p = paged.Fixture()..hasOlder = false;
        addTearDown(f.changes.close);
        addTearDown(p.changes.close);
        f.document['messages'] = [
          for (var i = 0; i < 25; i++) full.message('$i', 'Message $i'),
        ];
        Widget view() => paginated ? paged.surface(p, 'one') : full.surface(f);
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        expect(jump, findsNothing);
        scroll.jumpTo(scroll.maxScrollExtent - 90);
        await tester.pump();
        expect(jump, findsOneWidget);
        for (final distance in [
          73.0,
          71.0,
          65.0,
          63.0,
          70.0,
          49.0,
          47.0,
          20.0,
        ]) {
          scroll.jumpTo(scroll.maxScrollExtent - distance);
          await tester.pump();
          expect(jump, findsOneWidget);
        }
        final reads = f.reads;
        for (var frame = 0; frame < 5; frame++) {
          if (paginated) {
            p.heights[40] = 100 + frame * 15;
            p.version++;
            p.publish();
          } else {
            f.document['revision'] = frame + 2;
            f.document['messages'] = [
              ...f.document['messages'] as List,
              full.message('new-$frame', 'Streaming $frame'),
            ];
            f.publish();
          }
          await tester.pump();
          await tester.pump();
          expect(jump, findsOneWidget);
        }
        expect(f.reads, reads);
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(view());
        for (var i = 0; i < 4; i++) {
          await tester.pump();
          expect(jump, findsOneWidget);
        }
        tester.view.resetViewInsets();
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await tester.tap(jump);
        await tester.pumpAndSettle();
        expect(jump, findsNothing);
        expect(scroll.extentAfter, lessThan(2));
        // A deliberate short drag pauses even inside the old proximity threshold.
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 60));
        await tester.pumpAndSettle();
        expect(jump, findsOneWidget);
        await tester.tap(jump);
        await tester.pumpAndSettle();
        for (final bottom in [220.0, 0.0, 180.0, 0.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: bottom);
          await tester.pumpWidget(view());
          for (var i = 0; i < 4; i++) {
            await tester.pump();
            expect(jump, findsNothing);
          }
        }
      },
    );
  }
}
