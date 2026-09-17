import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

const records = <Map<String, Object?>>[
  {'kind': 'tool', 'id': 'call', 'revision': 4},
  {'kind': 'approval', 'id': 'proposal', 'revision': 4},
];

Widget surface(HandrailRecordTextReader reader) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: HandrailDeferredRecords(
        conversationId: 'chat',
        generation: 0,
        records: records,
        reader: reader,
        onRefresh: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'reads one bounded detail section on demand without enabling approval',
    (tester) async {
      final calls = <(String, int)>[];
      final text = 'x' * 8192;
      Future<Map<String, Object?>> read(
        String chat,
        String kind,
        String id,
        int generation,
        int revision,
        int offset,
        Future<void> cancellation,
      ) async {
        calls.add((kind, offset));
        return {
          'encoding': 'plain-text',
          'revision': revision,
          'text': offset == 0 ? text : 'last <script>literal</script>',
          'nextOffset': offset == 0 ? 8192 : null,
        };
      }

      await tester.pumpWidget(surface(read));
      expect(calls, isEmpty);
      await tester.tap(find.text('Read details').first);
      await tester.pumpAndSettle();
      expect(calls, [('tool', 0)]);
      await tester.ensureVisible(find.text('Next part'));
      await tester.tap(find.text('Next part'));
      await tester.pumpAndSettle();
      expect(find.text(text), findsNothing);
      expect(find.text('last <script>literal</script>'), findsOneWidget);
      await tester.ensureVisible(find.text('Read details'));
      await tester.tap(find.text('Read details'));
      await tester.pumpAndSettle();
      expect(calls.last, ('approval', 0));
      expect(find.text('Close details'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope replacement cancels held detail reads with identical record IDs',
    (tester) async {
      final held = Completer<Map<String, Object?>>();
      var cancelled = false;
      Future<Map<String, Object?>> read(
        String chat,
        String kind,
        String id,
        int generation,
        int revision,
        int offset,
        Future<void> cancellation,
      ) {
        cancellation.then((_) => cancelled = true);
        return held.future;
      }

      await tester.pumpWidget(surface(read));
      await tester.tap(find.text('Read details').first);
      await tester.pump();
      await tester.pumpWidget(
        surface(
          (chat, kind, id, generation, revision, offset, cancellation) async =>
              {},
        ),
      );
      await tester.pump();
      expect(cancelled, isTrue);
      held.complete({
        'encoding': 'plain-text',
        'revision': 4,
        'text': 'old account',
        'nextOffset': null,
      });
      await tester.pumpAndSettle();
      expect(find.text('old account'), findsNothing);
      expect(find.text('Read details'), findsNWidgets(2));
    },
  );
}
