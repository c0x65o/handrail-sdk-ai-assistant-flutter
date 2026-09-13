import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'assistant_workspace_test.dart' as workspace;

Widget surface(workspace.Fixture fixture,
        HandrailAssistantCloseController controller, VoidCallback onClose,
        {bool confirm = true, bool block = true, bool businessBusy = false}) =>
    MaterialApp(
        home: Scaffold(
            body: HandrailAssistantCloseGuard(
      binding: fixture.binding,
      drafts: fixture.drafts,
      controller: controller,
      onClose: onClose,
      confirmDraftDiscard: confirm,
      blockWhileWorking: block,
      businessBusy: businessBusy,
      child: HandrailAssistantWorkspace(
          binding: fixture.binding, drafts: fixture.drafts),
    )));

void main() {
  testWidgets(
      'default close retains drafts and does not cancel work or close twice',
      (tester) async {
    final fixture = workspace.Fixture(),
        controller = HandrailAssistantCloseController();
    addTearDown(fixture.dispose);
    fixture.drafts.controller.text = 'Keep this';
    fixture.state['workingAnywhere'] = true;
    var closed = 0;
    await tester.pumpWidget(surface(fixture, controller, () => closed++,
        confirm: false, block: false));
    expect(await controller.requestClose(), isTrue);
    expect(await controller.requestClose(), isFalse);
    expect(closed, 1);
    expect(fixture.drafts.controller.text, 'Keep this');
    expect(fixture.stops, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(await controller.requestClose(), isFalse);
  });

  testWidgets(
      'explicit discard includes other chats, while Keep preserves them',
      (tester) async {
    final fixture = workspace.Fixture(),
        controller = HandrailAssistantCloseController();
    addTearDown(fixture.dispose);
    fixture.drafts.select('other');
    fixture.drafts.controller.text = 'Other draft';
    fixture.drafts.select('one');
    var closed = 0;
    await tester.pumpWidget(surface(fixture, controller, () => closed++));
    var pending = controller.requestClose();
    await tester.pumpAndSettle();
    expect(await controller.requestClose(), isFalse);
    await tester.tap(find.byKey(const ValueKey('handrail-keep-editing')));
    await tester.pumpAndSettle();
    expect(await pending, isFalse);
    expect(fixture.drafts.hasOtherDrafts, isTrue);
    pending = controller.requestClose();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('handrail-discard-draft')));
    await tester.pumpAndSettle();
    expect(await pending, isTrue);
    expect(closed, 1);
    expect(fixture.drafts.hasDrafts, isFalse);
    expect(fixture.stops, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      'background work and changing business gates prevent stale Discard',
      (tester) async {
    final fixture = workspace.Fixture(),
        controller = HandrailAssistantCloseController();
    addTearDown(fixture.dispose);
    fixture.drafts.controller.text = 'Keep';
    fixture.state['workingAnywhere'] = true;
    var closed = 0;
    await tester.pumpWidget(surface(fixture, controller, () => closed++));
    final pending = controller.requestClose();
    await tester.pumpAndSettle();
    expect(find.text('Assistant is still working'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-discard-draft')), findsNothing);
    fixture.state['workingAnywhere'] = false;
    fixture.publish();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('handrail-discard-draft')), findsOneWidget);
    await tester.pumpWidget(
        surface(fixture, controller, () => closed++, businessBusy: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('handrail-discard-draft')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('handrail-keep-editing')));
    await tester.pumpAndSettle();
    expect(await pending, isFalse);
    expect(closed, 0);
    expect(fixture.drafts.controller.text, 'Keep');
    expect(fixture.stops, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('account replacement removes only its own covered confirmation',
      (tester) async {
    final old = workspace.Fixture(), current = workspace.Fixture();
    final controller = HandrailAssistantCloseController();
    addTearDown(old.dispose);
    addTearDown(current.dispose);
    old.drafts.controller.text = 'Private old draft';
    current.drafts.controller.text = 'New account draft';
    var closed = 0;
    await tester.pumpWidget(surface(old, controller, () => closed++));
    final pending = controller.requestClose();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AlertDialog)))
        .push<void>(MaterialPageRoute(
      builder: (_) => const Scaffold(body: Text('Unrelated route')),
    ));
    await tester.pumpAndSettle();
    await tester.pumpWidget(surface(current, controller, () => closed++));
    await tester.pumpAndSettle();
    expect(await pending, isFalse);
    expect(find.text('Unrelated route'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('handrail-close-decision'),
            skipOffstage: false),
        findsNothing);
    expect(current.drafts.controller.text, 'New account draft');
    expect(closed, 0);
    expect(current.stops, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('system Back uses the same explicit draft decision',
      (tester) async {
    final fixture = workspace.Fixture(),
        controller = HandrailAssistantCloseController();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push<void>(MaterialPageRoute(
                          builder: (context) => Scaffold(
                                  body: HandrailAssistantCloseGuard(
                                binding: fixture.binding,
                                drafts: fixture.drafts,
                                controller: controller,
                                confirmDraftDiscard: true,
                                onClose: () => Navigator.of(context).pop(),
                                child: HandrailAssistantWorkspace(
                                    binding: fixture.binding,
                                    drafts: fixture.drafts),
                              )))),
                  child: const Text('Open'),
                )))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    fixture.drafts.controller.text = 'Unsent';
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard draft?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('handrail-discard-draft')));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(fixture.drafts.hasDrafts, isFalse);
    expect(fixture.stops, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
