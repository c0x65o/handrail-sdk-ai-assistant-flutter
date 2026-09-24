import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  testWidgets(
    'approval waits for the current-request change and keeps its mode on failure',
    (tester) async {
      var mode = HandrailApprovalMode.required;
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailApprovalBadge(
              mode: mode,
              onChanged: (next) => mode = next,
              onApply: (_) => gate.future,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Approval settings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Applies immediately'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(mode, HandrailApprovalMode.required);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      gate.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(mode, HandrailApprovalMode.required);
      expect(
        find.text('Approval setting could not be updated. Try again.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'running composer can enable automatic approval after server acceptance',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var mode = HandrailApprovalMode.required;
      var applied = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailComposer(
              controller: controller,
              sending: true,
              onSend: () {},
              voiceControls: const [],
              onApprovalModeChanged: (next) => mode = next,
              onApprovalModeApply: (_) async {
                applied = true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Approval settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(applied, isTrue);
      expect(mode, HandrailApprovalMode.automatic);
    },
  );
}
