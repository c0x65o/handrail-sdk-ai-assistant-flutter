import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'approval_decisions_test.dart' show Reviews;

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('bounded approval sections and acknowledgement on $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = Reviews();
      addTearDown(f.changes.close);
      final base = f.binding;
      var offset = 0, acknowledged = false, decisions = 0;
      Map<String, Object?> read() => {
        'conversationId': 'chat',
        'pendingApprovalsAvailable': true,
        'inboxOpen': true,
        'inboxSelected': 'p',
        'inboxItems': [
          {'id': 'p', 'title': 'Action', 'deferred': true},
        ],
        'closeInbox': () {},
        'selectInbox': (String _) {},
        'pagedReadOnly': false,
        'pagedReview': {
          'status': decisions > 0 ? 'decided' : 'ready',
          'offset': offset,
          'complete': offset > 0,
          'acknowledged': acknowledged,
          'decision': true,
          'section': {
            'toolName': 'Send action',
            'binding': 'binding',
            'offset': offset,
            'text': offset == 0
                ? '🙂' * 8192
                : '<script>literal last section</script>',
            'nextOffset': offset == 0 ? 8192 : null,
          },
          'next': () async {
            offset = 8192;
            f.changes.add(null);
          },
          'previous': () async {
            offset = 0;
            f.changes.add(null);
          },
          'acknowledge': (bool value) {
            acknowledged = value;
            f.changes.add(null);
          },
          'decide': (bool confirm) async {
            expect(acknowledged, true);
            expect(confirm, true);
            decisions++;
            f.changes.add(null);
          },
        },
      };
      final binding = (
        scope: base.scope,
        changes: base.changes,
        read: read,
        review: base.review,
        decide: base.decide,
        retry: base.retry,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HandrailPendingApprovalInbox(binding: binding)),
        ),
      );
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText))
            .data!
            .runes
            .length,
        8192,
      );
      var approve = find.widgetWithText(FilledButton, 'Approve');
      expect(tester.widget<FilledButton>(approve).onPressed, isNull);
      await tester.ensureVisible(find.text('Next part'));
      await tester.tap(find.text('Next part'));
      await tester.pumpAndSettle();
      expect(
        find.text('<script>literal last section</script>'),
        findsOneWidget,
      );
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data!.length,
        lessThan(100),
      );
      expect(tester.widget<FilledButton>(approve).onPressed, isNull);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(find.text('Approval saved.'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(tester.takeException(), isNull);
      expect(decisions, 1);
    });
  }

  testWidgets(
    'pending entry point pages and shows only the selected review on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = Reviews();
      addTearDown(f.changes.close);
      var open = false, older = false;
      String? selected;
      f.proposal['inboxOnly'] = true;
      final base = f.binding;
      final binding = (
        scope: base.scope,
        changes: base.changes,
        review: base.review,
        decide: base.decide,
        retry: base.retry,
        read: () => <String, Object?>{
          ...base.read(),
          'pendingApprovalsAvailable': true,
          'inboxOpen': open,
          'inboxSelected': selected,
          'inboxItems': open
              ? [
                  {
                    'id': 'p',
                    'title': older ? 'Older change' : 'Recent change',
                    'deferred': false,
                  },
                ]
              : [],
          'inboxHasMore': !older,
          'inboxHasNewer': older,
          'openInbox': () async {
            open = true;
            older = false;
            selected = null;
            f.changes.add(null);
          },
          'olderInbox': () async {
            older = true;
            selected = null;
            f.changes.add(null);
          },
          'closeInbox': () {
            open = false;
            selected = null;
            f.changes.add(null);
          },
          'selectInbox': (String id) {
            selected = id;
            f.changes.add(null);
          },
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                HandrailPendingApprovalInbox(binding: binding),
                Expanded(
                  child: SingleChildScrollView(
                    child: HandrailApprovalDecisionsView(binding: binding),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Review change'), findsNothing);
      await tester.tap(find.text('Review pending approvals'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Older pending approvals'));
      await tester.pumpAndSettle();
      expect(find.text('Review Recent change'), findsNothing);
      await tester.tap(find.text('Review Older change'));
      await tester.pumpAndSettle();
      expect(find.text('Review change'), findsOneWidget);
      final approve = find.widgetWithText(FilledButton, 'Approve');
      expect(tester.widget<FilledButton>(approve).onPressed, isNull);
      await tester.ensureVisible(find.text('Review change'));
      await tester.tap(find.text('Review change'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(approve).onPressed, isNotNull);
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(f.calls.last, ['decide', 'p', 4, 'review-four', true]);
      await tester.ensureVisible(find.text('Close pending approvals'));
      await tester.tap(find.text('Close pending approvals'));
      await tester.pumpAndSettle();
      expect(find.text('Review Older change'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
