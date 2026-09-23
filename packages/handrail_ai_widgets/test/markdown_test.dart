import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  testWidgets(
    'formatted paragraphs and table cells share one selectable region',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            clipboard = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailMarkdown(
              data:
                  '**First paragraph**\n\nSecond paragraph.\n\n| Name | Value |\n| --- | --- |\n| Cash | 42 |',
              selectable: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      final area = tester.state<SelectionAreaState>(find.byType(SelectionArea));
      area.selectableRegion.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      area.selectableRegion.contextMenuButtonItems
          .firstWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(clipboard, contains('First paragraph'));
      expect(clipboard, contains('Second paragraph.'));
      expect(clipboard, contains('Cash'));
      expect(clipboard, contains('42'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final selectable in [false, true]) {
    testWidgets('user text honors bubble foreground, selectable=$selectable', (
      tester,
    ) async {
      const foreground = Color(0xfff7f0e9);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: HandrailMarkdown(
              data: '**Literal user text**',
              isUserMessage: true,
              selectable: selectable,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(color: foreground, fontSize: 12.5),
              ),
            ),
          ),
        ),
      );
      final style = selectable
          ? tester.widget<SelectableText>(find.byType(SelectableText)).style
          : tester.widget<Text>(find.text('**Literal user text**')).style;
      expect(style?.color, foreground);
      expect(style?.fontSize, 12.5);
    });
  }
  final fixtures =
      (jsonDecode(File('test/fixtures/markdown.json').readAsStringSync())
              as List)
          .cast<Map<String, dynamic>>();

  Widget host(String text, {bool selectable = false, bool user = false}) =>
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: HandrailMarkdown(
                data: text,
                selectable: selectable,
                isUserMessage: user,
              ),
            ),
          ),
        ),
      );

  for (final selectable in [false, true]) {
    for (final fixture in fixtures.where((f) => f.containsKey('headers'))) {
      testWidgets(
        '${fixture['id']} selectable=$selectable preserves cells on a narrow screen',
        (tester) async {
          await tester.pumpWidget(
            host(fixture['markdown'] as String, selectable: selectable),
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(Table), findsOneWidget);
          expect(
            find.byType(SelectionArea),
            selectable ? findsOneWidget : findsNothing,
          );
          for (final text in [
            ...fixture['headers'] as List,
            ...fixture['cells'] as List,
          ]) {
            expect(find.text(text as String, findRichText: true), findsWidgets);
          }
          final scroll = find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          );
          expect(scroll, findsOneWidget);
          expect(tester.getSize(scroll).width, lessThanOrEqualTo(280));
          final table = tester.widget<Table>(find.byType(Table));
          expect(table.defaultColumnWidth, isA<IntrinsicColumnWidth>());
          final headers = fixture['headers'] as List;
          final alignments = fixture['alignments'] as List;
          for (var column = 0; column < headers.length; column++) {
            final expected = {
              'left': TextAlign.left,
              'center': TextAlign.center,
              'right': TextAlign.right,
            }[alignments[column]];
            final renderedAlignments = tester
                .widgetList<RichText>(find.byType(RichText))
                .where((w) => w.text.toPlainText() == headers[column])
                .map((w) => w.textAlign);
            expect(
              renderedAlignments,
              contains(expected),
              reason: 'alignment of ${headers[column]}',
            );
          }
        },
      );
    }
  }

  testWidgets('streamed table prefixes remain renderable', (tester) async {
    final text = fixtures.first['markdown'] as String;
    for (var length = 0; length <= text.length; length++) {
      await tester.pumpWidget(host(text.substring(0, length)));
      expect(tester.takeException(), isNull, reason: 'prefix $length');
    }
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('user messages remain selectable literal text', (tester) async {
    final text = fixtures.first['markdown'] as String;
    await tester.pumpWidget(host(text, selectable: true, user: true));
    expect(find.byType(Table), findsNothing);
    expect(find.text(text), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('unsafe links and inline images cannot trigger host navigation', (
    tester,
  ) async {
    final visited = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HandrailMarkdown(
            data:
                '${fixtures.last['markdown']}\n\n![private](https://example.com/image.png)',
            onTapLink: (text, href, title) => visited.add(href),
          ),
        ),
      ),
    );
    await tester.tapOnText(find.textRange.ofSubstring('Unsafe'));
    expect(visited, isEmpty);
    expect(find.byType(Image), findsNothing);
  });
}
