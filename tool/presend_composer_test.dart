// Public packaged composer -> UI binding -> controller -> session -> real HTTP
// gateway/Postgres adapter. All conversation content and credentials are synthetic.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'presend_fixture.dart';

void main() {
  testWidgets('public composer records the same sequential pre-send pair', (
    tester,
  ) async {
    // Use the isolated loopback gateway instead of flutter_test's HTTP 400 mock.
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() {
      HttpOverrides.global = previousHttp;
    });
    final server = PresendServer();
    await tester.runAsync(server.start);
    final f = PresendFixture(server, 'normal-composer');
    final drafts = HandrailComposerController.forAssistant(
      f.controller.uiBinding,
    );
    var closed = false;
    Future<void> close() async {
      if (closed) return;
      closed = true;
      drafts.dispose();
      var done = false;
      final closing = f
          .close('../../docs/qa/presend-2026-10-06')
          .whenComplete(() => done = true);
      for (var i = 0; !done && i < 200; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await closing;
      await tester.runAsync(server.close);
    }

    addTearDown(close);
    await tester.runAsync(f.open);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HandrailAssistantWorkspace<void>(
            binding: f.controller.uiBinding,
            drafts: drafts,
            inputKey: const ValueKey('draft'),
            sendKey: const ValueKey('send'),
            showVoice: false,
            showAttachments: false,
            threads: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('draft')),
      'Synthetic composer request',
    );
    await tester.pumpAndSettle();
    // Alternate fake UI microtasks with real socket progress, including the
    // draft flush captured before the tap. No custom send adapter is installed.
    await f.runTrace(() => tester.tap(find.byKey(const ValueKey('send'))));
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (f.trace.rows.any((r) => r['path'] == '/api/ai/turns/start') &&
          !drafts.isSubmitting &&
          !f.controller.session!.isSubmitting)
        break;
    }
    await tester.pump();
    final admission = f.trace.admissions.single;
    final reads = f.trace.reads
        .where((r) => (r['id'] as int) < (admission['id'] as int))
        .toList();
    expect(reads.map((r) => (r['request'] as Map)['operation']), [
      'control',
      'changes',
      'control',
      'changes',
    ]);
    expect(reads[0]['request'], reads[2]['request']);
    expect(reads[1]['request'], reads[3]['request']);
    expect(reads[0]['response'], reads[2]['response']);
    expect(reads[1]['response'], reads[3]['response']);
    expect(reads[1]['endUs'] as int, lessThan(reads[2]['startUs'] as int));
    expect(reads[0]['stack'].toString(), contains('_sendFromUi'));
    expect(reads[0]['caller'], 'prepareTurn');
    expect(reads[2]['caller'], '_submitTurn');
    expect(await tester.runAsync(() => f.store.load(f.id)), isNull);
    expect(tester.takeException(), isNull);
    final stats = await tester.runAsync(() => server.command('stats'));
    expect(stats!['invocations'], 1);
    expect(stats['admissions'], 1);
    expect(f.controller.error, isNull);
    f.trace.mark('stats', stats);
    f.trace.mark('controller-result', {
      'error': f.controller.error?.code,
      'latestTurn': f.controller.document?.latestTurn,
    });
    await tester.pumpWidget(const SizedBox());
    await close();
  });
}
