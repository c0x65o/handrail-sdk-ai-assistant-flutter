import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

class StreamingFixture {
  final changes = StreamController<Object?>.broadcast(sync: true);
  final displayChanges = StreamController<Object?>.broadcast(sync: true);
  int revision = 1;
  bool running = true;
  String answer =
      '## Results\n\n${List.generate(25, (i) => 'Paragraph $i: **Important detail** with a [source](https://example.invalid/$i). ' * 3).join('\n\n')}\n\n'
      '| Account | Amount |\n| --- | ---: |\n${List.generate(30, (i) => '| Account $i | $i |').join('\n')}\n\nCurrent answer';
  Map<String, Object?> message(int i) => {
    'message_id': 'm$i',
    'turn_id': i == 30 ? 'current' : 'previous',
    'role': 'assistant',
    'attachments': <Object?>[],
    'content': [
      {
        'type': 'text',
        'text': i == 30 ? answer : 'Earlier answer $i. **Saved detail.**',
      },
    ],
  };
  HandrailDisplayTranscriptBinding get display => (
    scope: this,
    changes: displayChanges.stream,
    read: () => {
      'conversationId': 'chat',
      'status': 'ready',
      'generation': 0,
      'revision': revision,
      'version': revision,
      'hasOlder': false,
      'hasNewer': false,
      'loading': null,
      'change': 'changes',
      'records': [
        for (var i = 1; i <= 30; i++)
          {
            'id': 'm$i',
            'kind': 'message',
            'revision': i == 30 ? revision : 1,
            'deferred': false,
            'bytes': 1000,
            'value': message(i),
          },
      ],
    },
    select: (_, __) async {},
    older: () async {},
    newer: () async {},
    latest: () async {},
    refresh: () async {},
    retry: () async {},
  );
  HandrailTranscriptUiBinding get binding => (
    scope: this,
    changes: changes.stream,
    read: () => {
      'conversationId': 'chat',
      'running': running,
      'displayWindow': display,
      'document': {
        'revision': revision,
        'messages': [for (var i = 1; i <= 30; i++) message(i)],
        'turns': [
          {
            'turn_id': 'current',
            'status': running ? 'running' : 'completed',
            'output_message_ids': ['m30'],
          },
        ],
        'tool_calls': [
          for (var i = 0; i < 10; i++)
            {
              'tool_call_id': 't$i',
              'turn_id': 'current',
              'name': 'Lookup $i',
              'result': {'is_error': i == 0},
            },
        ],
      },
    },
    retry: () async {},
    markRead: () async {},
  );
  void update() {
    displayChanges.add(null);
    changes.add(null);
  }

  Future<void> close() async {
    await changes.close();
    await displayChanges.close();
  }
}

void main() {
  testWidgets('streaming long answer render workload without network latency', (
    tester,
  ) async {
    final fixture = StreamingFixture();
    addTearDown(fixture.close);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HandrailConversationTranscript(binding: fixture.binding),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Working…'), findsNothing);
    expect(
      tester.getTopLeft(find.text('10 tools called · 1 failed')).dy,
      lessThan(
        tester.getTopLeft(find.byType(HandrailTranscriptMessage).last).dy,
      ),
    );
    expect(
      find.byType(EditableText),
      findsNothing,
      reason: 'Growing answers must not recreate one editor per paragraph/cell',
    );
    final counts = <String, int>{};
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final widget = element.widget;
      if (widget is HandrailMarkdown || widget is SelectableText) {
        final type = widget.runtimeType.toString();
        counts[type] = (counts[type] ?? 0) + 1;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final samples = <double>[];
    for (var i = 0; i < 30; i++) {
      fixture.answer += ' more text';
      fixture.revision++;
      final watch = Stopwatch()..start();
      fixture.update();
      await tester.pumpAndSettle();
      samples.add(watch.elapsedMicroseconds / 1000);
    }
    final streamingBuilds = Map<String, int>.of(counts);
    counts.clear();
    for (var i = 0; i < 10; i++) {
      fixture.update();
      await tester.pumpAndSettle();
    }
    final repeatedBuilds = Map<String, int>.of(counts);
    debugOnRebuildDirtyWidget = null;
    samples.sort();
    final report = {
      'scenario':
          '30 growing Markdown updates, then 10 unchanged activity notifications',
      'network': 'none; in-memory bindings',
      'answerCharacters': fixture.answer.length,
      'updateP50Ms': samples[15],
      'updateP95Ms': samples[28],
      'streamingRebuilds': streamingBuilds,
      'unchangedRebuilds': repeatedBuilds,
      'mountedSelectableTextWidgets': find
          .byType(SelectableText)
          .evaluate()
          .length,
      'processRssBytes': ProcessInfo.currentRss,
      'limitations':
          'Debug offscreen Flutter renderer; timings and total process RSS include test framework and VM, not native-device or provider latency.',
    };
    final output = Platform.environment['HANDRAIL_STREAMING_RENDER_REPORT'];
    if (output != null)
      File(output).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    // ignore: avoid_print
    print(jsonEncode(report));
    expect(tester.takeException(), isNull);
    fixture.running = false;
    fixture.update();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Current answer', findRichText: true),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
