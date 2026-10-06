// Real SDK workspace/controller/window, synthetic bounded HTTP history.
// Reconstructed from the reported behavior; the Mills fixture is unavailable.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'reentrant_assistant_test.dart' as phone;

void main() {
  setUpAll(() async {
    // Use the prepared SDK font for readable, real Flutter screenshot evidence.
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final font = FontLoader('PhoneEvidence')
        ..addFont(
          File(
            '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await icons.load();
    }
  });
  for (final pause in [150.0, 700.0]) {
    testWidgets(
      'keyboard dismissal reconciles latest at a $pause pixel pause',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final f = phone.Fixture();
        addTearDown(() => tester.runAsync(f.dispose));
        final boundary = GlobalKey();
        Widget surface() => RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'PhoneEvidence'),
            home: (f.surface() as MaterialApp).home,
          ),
        );
        final trace = <Map<String, Object?>>[];
        final evidence = Platform.environment['HANDRAIL_PHONE_EVIDENCE'];
        Future<void> screenshot(String name) async {
          if (evidence == null) return;
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$evidence/$pause-$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.pumpWidget(surface());
        await phone.frames(tester);
        final transcript = find.byType(HandrailDisplayTranscript);
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(of: transcript, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        final editor = find.byKey(const ValueKey('draft'));
        final jump = find.widgetWithText(FilledButton, 'Jump to latest');
        final semantics = tester.ensureSemantics();
        try {
          Finder? readerAnchor;
          double? readerY;
          Future<void> audit(
            String stage,
            bool visible, {
            bool retainAnchor = false,
          }) async {
            Rect? buttonRect;
            Color? buttonColor;
            for (var frame = 0; frame < 12; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(
                jump,
                visible ? findsOneWidget : findsNothing,
                reason: '$stage frame $frame',
              );
              if (retainAnchor)
                expect(
                  tester.getTopLeft(readerAnchor!).dy,
                  closeTo(readerY!, .1),
                );
              if (visible) {
                expect(tester.widget<FilledButton>(jump).onPressed, isNotNull);
                final node = tester.getSemantics(jump);
                expect(node.label, contains('Jump to latest'));
                expect(node.hasFlag(ui.SemanticsFlag.isButton), isTrue);
                final rect = tester.getRect(jump);
                final color = tester
                    .widget<Material>(
                      find
                          .descendant(of: jump, matching: find.byType(Material))
                          .first,
                    )
                    .color;
                if (frame > 0) {
                  expect(rect, buttonRect);
                  expect(color, buttonColor);
                }
                buttonRect = rect;
                buttonColor = color;
              }
              trace.add({
                'stage': stage,
                'frame': frame,
                'jump': visible,
                'pixels': scroll.pixels,
                'extentAfter': scroll.extentAfter,
                'viewport': scroll.viewportDimension,
                'following':
                    f.assistant.session!.displayWindow!.followingLatest,
              });
            }
          }

          await tester.showKeyboard(editor);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await phone.frames(tester);
          expect(scroll.extentAfter, lessThanOrEqualTo(2));
          await audit('keyboard-open', false);
          await screenshot('keyboard-open');
          await tester.drag(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
            Offset(0, pause),
          );
          await phone.frames(tester);
          expect(scroll.extentAfter, greaterThan(2));
          if (pause < 300) expect(scroll.extentAfter, lessThan(300));
          expect(find.text('Jump to latest'), findsOneWidget);
          expect(f.assistant.session!.displayWindow!.followingLatest, isFalse);
          // Virtualized bodies can change absolute pixels when measured. Verify
          // the same visible message/intra-message coordinate, not placeholder size.
          final top = tester.getTopLeft(transcript).dy;
          final message =
              find
                      .byType(HandrailTranscriptMessage)
                      .evaluate()
                      .firstWhere(
                        (element) =>
                            tester
                                .getRect(find.byWidget(element.widget))
                                .bottom >
                            top,
                      )
                      .widget
                  as HandrailTranscriptMessage;
          readerAnchor = find.byWidgetPredicate(
            (widget) =>
                widget is HandrailTranscriptMessage &&
                widget.message['message_id'] == message.message['message_id'],
          );
          readerY = tester.getTopLeft(readerAnchor).dy;
          await audit('scrolled-up', true, retainAnchor: true);
          await screenshot('scrolled-up');
          expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
          tester.view.resetViewInsets();
          // Inspect every rendered resize frame. A single visible -> hidden change
          // is allowed after layout; hide/show oscillation is never allowed.
          var hidden = false;
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            final visible = jump.evaluate().isNotEmpty;
            if (hidden) expect(visible, isFalse);
            if (!visible) hidden = true;
            trace.add({
              'stage': 'dismiss-resize',
              'frame': frame,
              'jump': visible,
              'extentAfter': scroll.extentAfter,
              'viewport': scroll.viewportDimension,
            });
          }
          final atBottom = pause < 300;
          if (atBottom) {
            expect(scroll.extentAfter, lessThanOrEqualTo(2));
          } else {
            expect(tester.getTopLeft(readerAnchor).dy, closeTo(readerY, .1));
            expect(scroll.extentAfter, greaterThan(2));
          }
          await audit('keyboard-closed', !atBottom);
          await screenshot(
            atBottom ? 'keyboard-closed-bottom' : 'keyboard-closed-history',
          );
          expect(f.assistant.session!.displayWindow!.followingLatest, atBottom);
          expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
          f.turnId = 'synthetic-stream';
          f.status = 'running';
          for (var delta = 0; delta < 4; delta++) {
            f.revision++;
            f.messages
              ..clear()
              ..add(
                f.record(
                  'answer',
                  'Streaming update $delta.\n\n${'Synthetic content. ' * (delta + 1)}',
                ),
              );
            final operation = f.assistant.session!.refresh();
            await audit('stream-$delta', !atBottom, retainAnchor: !atBottom);
            await phone.settle(tester, operation);
            if (atBottom) expect(scroll.extentAfter, lessThanOrEqualTo(2));
          }
          expect(f.assistant.running, isTrue);
          await screenshot('streaming');
          for (var refresh = 0; refresh < 3; refresh++) {
            final operation = f.assistant.session!.refresh();
            await audit('refresh-$refresh', !atBottom, retainAnchor: !atBottom);
            await phone.settle(tester, operation);
          }
          // Reopen the keyboard, then remount the workspace with retained storage.
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await phone.frames(tester);
          await audit('keyboard-reopened', !atBottom, retainAnchor: !atBottom);
          await tester.pumpWidget(const SizedBox());
          await phone.frames(tester);
          await tester.pumpWidget(surface());
          await phone.frames(tester);
          expect(jump, atBottom ? findsNothing : findsOneWidget);
          expect(f.assistant.session!.displayWindow!.followingLatest, atBottom);
          expect(tester.takeException(), isNull);
          expect(f.admissions, 0);
          expect(f.starts, 0);
          if (evidence != null) {
            await tester.runAsync(
              () => File('$evidence/$pause-frames.json').writeAsString(
                const JsonEncoder.withIndent('  ').convert(trace),
              ),
            );
          }
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
