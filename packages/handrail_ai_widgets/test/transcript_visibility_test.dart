import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

import 'conversation_transcript_test.dart' as snapshot;
import 'display_transcript_test.dart' as paged;

// Reuse the existing UI binding fixtures. These counters observe widget calls,
// not persistence, gateway authorization, or native device behavior.
void main() {
  for (final implementation in [
    'snapshot',
    'display',
    'conversation display',
  ]) {
    for (final hiddenBy in ['ticker', 'ancestor', 'background', 'route']) {
      testWidgets('$implementation visibility: $hiddenBy', (tester) async {
        final conversation = snapshot.Fixture();
        final window = paged.Fixture()
          ..id = 'one'
          ..start = 1
          ..end = 1
          ..hasOlder = false;
        addTearDown(conversation.changes.close);
        addTearDown(window.changes.close);
        final enabled = ValueNotifier(true), ancestor = ValueNotifier(true);
        addTearDown(enabled.dispose);
        addTearDown(ancestor.dispose);
        var revision = 1, acknowledgements = 0;
        final original = window.binding;
        final HandrailDisplayTranscriptBinding display = (
          scope: original.scope,
          changes: original.changes,
          read: () => {...original.read(), 'revision': revision},
          select: original.select,
          older: original.older,
          newer: original.newer,
          latest: original.latest,
          refresh: original.refresh,
          retry: original.retry,
        );
        if (implementation == 'conversation display') {
          conversation.display = display;
        }
        int reads() =>
            implementation == 'display' ? acknowledgements : conversation.reads;
        void publish() {
          conversation.document['revision'] = revision;
          window.publish();
          conversation.publish();
        }

        final Widget transcript = implementation == 'display'
            ? HandrailDisplayTranscript(
                binding: display,
                conversationId: 'one',
                manageSelection: false,
                pollInterval: const Duration(milliseconds: 250),
                onVisibleLatest: (_, _) => acknowledgements++,
              )
            : HandrailConversationTranscript(binding: conversation.binding);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: ancestor,
                child: ValueListenableBuilder<bool>(
                  valueListenable: enabled,
                  // The identical child requires a real inherited dependency to
                  // respond to ticker changes; no fixture publication wakes it.
                  child: transcript,
                  builder: (_, value, child) =>
                      TickerMode(enabled: value, child: child!),
                ),
                builder: (_, value, child) =>
                    TickerMode(enabled: value, child: child!),
              ),
            ),
          ),
        );
        await paged.settle(tester);
        expect(reads(), 1, reason: 'Enabled visible tail is acknowledged');
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        final state = tester.state(find.byWidget(transcript));

        switch (hiddenBy) {
          case 'ticker':
            enabled.value = false;
          case 'ancestor':
            ancestor.value = false;
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          case 'route':
            unawaited(
              navigator.push<void>(
                PageRouteBuilder<void>(
                  opaque: false,
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) =>
                      const Center(child: Text('Covered')),
                ),
              ),
            );
        }
        await paged.settle(tester);
        revision++;
        publish();
        await paged.settle(tester);
        final before = window.refreshes;
        await tester.pump(const Duration(seconds: 2));
        await paged.settle(tester);
        expect(reads(), 1, reason: 'Hidden updates must not be marked read');
        expect(window.refreshes, before, reason: 'No hidden polling');
        expect(conversation.retries, 0);

        if (hiddenBy == 'ancestor') {
          // An enabled child cannot override a disabled ancestor.
          enabled.value = false;
          await paged.settle(tester);
          enabled.value = true;
          await paged.settle(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(reads(), 1);
          expect(window.refreshes, before);
        }
        switch (hiddenBy) {
          case 'ticker':
            enabled.value = true;
          case 'ancestor':
            ancestor.value = true;
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          case 'route':
            navigator.pop();
        }
        await paged.settle(tester);
        expect(tester.state(find.byWidget(transcript)), same(state));
        expect(
          reads(),
          2,
          reason: 'Return acknowledges latest without a new event or timer',
        );
        await tester.pump(const Duration(milliseconds: 250));
        await paged.settle(tester);
        expect(
          window.refreshes,
          before + (implementation == 'display' ? 1 : 0),
          reason:
              'Display refresh resumes by the next unchanged poll interval; '
              'conversation transcripts leave polling to the controller',
        );
        expect(reads(), 2, reason: 'No duplicate read acknowledgement');
        await tester.pumpWidget(const SizedBox());
        final disposed = window.refreshes;
        await tester.pump(const Duration(seconds: 2));
        expect(window.refreshes, disposed);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
