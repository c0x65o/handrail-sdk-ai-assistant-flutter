import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

class Reviews {
  final changes = StreamController<Object?>.broadcast();
  final calls = <Object?>[];
  String conversation = 'one';
  Future<void>? held;
  final proposal = <String, Object?>{
    'proposal_id': 'p',
    'proposal_version': 4,
    'binding': 'review-four',
    'tool_name': 'Change invoice',
    'group_id': 'group',
    'status': 'pending',
    'canReview': true,
    'canConfirm': false,
    'canReject': true,
  };
  HandrailApprovalBinding get binding => (
        scope: this,
        changes: changes.stream,
        read: () => {
              'conversationId': conversation,
              'items': [proposal]
            },
        review: (id, version) async {
          calls.add(['review', id, version]);
          await held;
          proposal.addAll({
            'reviewed': true,
            'complete': true,
            'canConfirm': true,
            'arguments': {'amount': 42}
          });
          changes.add(null);
        },
        decide: (id, version, binding, confirm) async {
          calls.add(['decide', id, version, binding, confirm]);
          await held;
          proposal.addAll({
            'pendingDecision': true,
            'canConfirm': false,
            'canReject': false
          });
          changes.add(null);
        },
        retry: (id) async {
          calls.add(['retry', id]);
        },
      );
}

void main() {
  testWidgets(
      'review is visible before approval and dispatch uses exact binding',
      (tester) async {
    final f = Reviews();
    addTearDown(f.changes.close);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: HandrailApprovalDecisionsView(binding: f.binding))));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Approve'))
            .onPressed,
        isNull);
    await tester.tap(find.text('Review change'));
    await tester.pumpAndSettle();
    expect(find.text('Amount'), findsOneWidget);
    expect(find.byType(HandrailStructuredDetails), findsOneWidget);
    expect(find.textContaining('42'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(f.calls, [
      ['review', 'p', 4],
      ['decide', 'p', 4, 'review-four', true]
    ]);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    await tester.tap(find.text('Check saved decision'));
    await tester.pumpAndSettle();
    expect(f.calls.last, ['retry', 'p']);
  });
  testWidgets('custom business rendering does not enable an incomplete review',
      (tester) async {
    final f = Reviews();
    addTearDown(f.changes.close);
    f.proposal.addAll({
      'reviewed': true,
      'complete': false,
      'arguments': {'amount': 42}
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HandrailApprovalDecisionsView(
                binding: f.binding,
                reviewBuilder: (_, item) => Text(
                    'Invoice amount: ${(item['arguments'] as Map)['amount']}')))));
    expect(find.text('Invoice amount: 42'), findsOneWidget);
    expect(find.textContaining('incomplete'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Approve'))
            .onPressed,
        isNull);
  });
  testWidgets('late account failure cannot appear in the next account',
      (tester) async {
    final old = Reviews(), next = Reviews();
    addTearDown(old.changes.close);
    addTearDown(next.changes.close);
    final held = Completer<void>();
    old.held = held.future;
    Widget view(Reviews f) => MaterialApp(
        home:
            Scaffold(body: HandrailApprovalDecisionsView(binding: f.binding)));
    await tester.pumpWidget(view(old));
    await tester.tap(find.text('Review change'));
    await tester.pump();
    await tester.pumpWidget(view(next));
    held.completeError(StateError('old account'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be updated'), findsNothing);
    expect(next.calls, isEmpty);
  });
  testWidgets(
      'approved pending execution is distinct from executed and expired',
      (tester) async {
    final f = Reviews();
    addTearDown(f.changes.close);
    f.proposal['status'] = 'confirmed';
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: HandrailApprovalDecisionsView(binding: f.binding))));
    expect(find.text('Approved · awaiting execution'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    f.proposal.addAll({'status': 'pending', 'expired': true});
    f.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
  });
}
