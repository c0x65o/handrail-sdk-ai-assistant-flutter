import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('minimal composer inherits host colors and font ($brightness)',
        (tester) async {
      final controller = TextEditingController(text: 'Review before sending');
      addTearDown(controller.dispose);
      final colors = ColorScheme.fromSeed(
          seedColor: Colors.deepOrange, brightness: brightness);
      final theme = ThemeData(colorScheme: colors, fontFamily: 'HostFont');
      var sent = 0, attached = 0;
      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: HandrailComposer(
                  controller: controller,
                  sendKey: const ValueKey('themed-send'),
                  canSend: true,
                  onSend: () => sent++,
                  onAttach: () => attached++,
                  voiceControls: const []))));
      final input = tester.widget<TextField>(find.byType(TextField));
      expect(input.style!.color, colors.onSurface);
      expect(input.style!.fontFamily, 'HostFont');
      expect(input.decoration!.filled, isFalse);
      final shell = tester
          .widgetList<Container>(find.ancestor(
              of: find.byType(TextField), matching: find.byType(Container)))
          .firstWhere((w) => w.decoration is BoxDecoration);
      expect((shell.decoration! as BoxDecoration).color, colors.surface);
      final send =
          tester.widget<IconButton>(find.byKey(const ValueKey('themed-send')));
      expect(send.style!.backgroundColor!.resolve({}), colors.primary);
      expect(send.style!.foregroundColor!.resolve({}), colors.onPrimary);
      expect(find.byTooltip('Approval settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Add files and images'));
      expect(attached, 1);
      await tester.tap(find.byTooltip('Send message'));
      expect(sent, 1);
    });
  }
  testWidgets('host form constraints do not stretch or clip the shared editor',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sent = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            inputDecorationTheme: const InputDecorationThemeData(
                constraints: BoxConstraints.tightFor(width: 500, height: 120),
                filled: true,
                disabledBorder: OutlineInputBorder())),
        home: Scaffold(
            body: HandrailComposer(
                controller: controller,
                inputKey: const ValueKey('theme-constrained-draft'),
                onAttach: () {},
                canSend: true,
                onSend: () => sent++,
                voiceControls: [
                  IconButton(
                      onPressed: () {},
                      tooltip: 'Dictate',
                      icon: const Icon(Icons.mic_none))
                ]))));
    final field = find.byKey(const ValueKey('theme-constrained-draft'));
    final emptyHeight = tester.getSize(field).height;
    expect(emptyHeight, lessThan(48));
    for (final tooltip in [
      'Add files and images', 'Approval settings', 'Dictate', 'Send message'
    ]) {
      final control = find.byTooltip(tooltip).hitTestable();
      expect(control, findsOneWidget);
      expect(tester.getSize(control).shortestSide, greaterThanOrEqualTo(40));
    }
    await tester.enterText(field, 'first line\nsecond line\nthird line');
    await tester.pump();
    expect(tester.getSize(field).height, greaterThan(emptyHeight));
    final fieldRect = tester.getRect(field);
    final toolbarRect = tester.getRect(
        find.byKey(const ValueKey('handrail-composer-toolbar')));
    expect(fieldRect.bottom, lessThan(toolbarRect.top));
    expect(fieldRect.right, lessThanOrEqualTo(320));
    await tester.tap(find.byTooltip('Send message'));
    expect(sent, 1);
    expect(controller.text, 'first line\nsecond line\nthird line');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'expanded editor keeps the draft and closes on account scope change',
      (tester) async {
    final first = TextEditingController(text: 'first');
    final second = TextEditingController(text: 'second account');
    final selected = ValueNotifier<TextEditingController>(first);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(selected.dispose);
    var sent = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ValueListenableBuilder<TextEditingController>(
        valueListenable: selected,
        builder: (context, controller, _) => HandrailComposer(
          controller: controller,
          allowExpand: true,
          expandedInputKey: const ValueKey('expanded'),
          canSend: true,
          onSend: () => sent++,
          voiceControls: const [],
        ),
      ),
    )));
    await tester.tap(find.byTooltip('Edit full message'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('expanded')), 'first\nnext line');
    expect(first.text, 'first\nnext line');
    expect(sent, 0);
    selected.value = second;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('expanded')), findsNothing);
    expect(second.text, 'second account');
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 768.0]) {
    testWidgets('draft starts above the aligned toolbar at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller =
          TextEditingController(text: 'Can we try with the initial');
      addTearDown(controller.dispose);
      var sent = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Padding(
        padding: const EdgeInsets.all(8),
        child: HandrailComposer(
            controller: controller,
            inputKey: const ValueKey('draft'),
            attachKey: const ValueKey('add'),
            sendKey: const ValueKey('send'),
            onAttach: () {},
            canSend: true,
            onSend: () => sent++,
            voiceControls: [
              IconButton(
                  onPressed: () {},
                  tooltip: 'Dictate',
                  icon: const Icon(Icons.mic_none))
            ]),
      ))));
      final draft = tester.getRect(find.byKey(const ValueKey('draft')));
      final add = tester.getRect(find.byKey(const ValueKey('add')));
      final send = tester.getRect(find.byKey(const ValueKey('send')));
      expect(draft.bottom, lessThan(add.top));
      expect((add.center.dy - send.center.dy).abs(), lessThanOrEqualTo(2));
      expect(draft.left, lessThan(add.center.dx));
      expect(send.right, lessThan(width));
      expect(add.width, greaterThanOrEqualTo(40));
      await tester.tap(find.byKey(const ValueKey('send')));
      expect(sent, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'host theme styles the shared composer and hides unavailable attachments',
      (tester) async {
    final controller = TextEditingController(text: 'Draft');
    addTearDown(controller.dispose);
    const decoration = BoxDecoration(color: Color(0xff291918));
    const textStyle = TextStyle(color: Colors.white, fontSize: 13);
    var sent = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HandrailComposer(
      controller: controller,
      decoration: decoration,
      inputTextStyle: textStyle,
      sendButtonStyle: IconButton.styleFrom(
          backgroundColor: Colors.deepOrange,
          foregroundColor: Colors.white,
          minimumSize: const Size.square(48)),
      showAttachmentControl: false,
      showApprovalControl: false,
      voiceControls: const [],
      canSend: true,
      onSend: () => sent++,
    ))));
    expect(find.byTooltip('Add files and images'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).style, textStyle);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Container && widget.decoration == decoration),
        findsOneWidget);
    final send = tester.widget<IconButton>(find.byType(IconButton));
    expect(send.style!.backgroundColor!.resolve({}), Colors.deepOrange);
    expect(send.style!.minimumSize!.resolve({}), const Size.square(48));
    await tester.tap(find.byType(IconButton));
    expect(sent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Send focuses once, Enter sends, and a running draft stays editable',
      (tester) async {
    final controller = TextEditingController(text: 'hello');
    final inputFocus = FocusNode(), elsewhere = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(inputFocus.dispose);
    addTearDown(elsewhere.dispose);
    var sending = false, sent = 0, stopped = 0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return Column(children: [
        TextButton(
            focusNode: elsewhere,
            onPressed: () {},
            child: const Text('Elsewhere')),
        HandrailComposer(
            controller: controller,
            focusNode: inputFocus,
            canSend: true,
            sending: sending,
            voiceControls: const [],
            onSend: () {
              sent++;
              update(() => sending = true);
            },
            onStop: () => stopped++),
      ]);
    }))));
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(inputFocus.hasFocus, isTrue);
    expect(sent, 1);
    elsewhere.requestFocus();
    await tester.pump();
    update(() => sending = false);
    await tester.pump();
    expect(elsewhere.hasFocus, isTrue);
    inputFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 2);
    expect(stopped, 0);
    await tester.enterText(find.byType(TextField), 'next draft');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 2);
    expect(stopped, 0);
    expect(controller.text, 'next draft');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.text, 'next draft\n');
    expect(tester.takeException(), isNull);
  });

  testWidgets('IME composition and an explicit newline setting do not send',
      (tester) async {
    final controller = TextEditingController(text: 'composing'),
        focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var sent = 0;
    Future<void> mount(bool sendOnEnter) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: HandrailComposer(
                  controller: controller,
                  focusNode: focus,
                  sendOnEnter: sendOnEnter,
                  canSend: true,
                  voiceControls: const [],
                  onSend: () => sent++))));
      focus.requestFocus();
      await tester.pump();
    }

    await mount(true);
    controller.value = const TextEditingValue(
        text: 'composing',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 0, end: 9));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 0);
    controller.clearComposing();
    await mount(false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 0);
  });

  testWidgets('approval switch changes the next-message preference',
      (tester) async {
    var mode = HandrailApprovalMode.required;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HandrailApprovalBadge(
      mode: mode,
      onChanged: (next) => mode = next,
    ))));
    await tester.tap(find.byTooltip('Approval settings'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(mode, HandrailApprovalMode.automatic);
    expect(handrailApprovalMetadata(mode),
        {'handrail_approval_mode': 'automatic'});
  });
}
