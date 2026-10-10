import 'dart:io';

import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

import 'presend_fixture.dart';

// The existing real gateway fixture owns a disposable PGlite database. The
// interleaving appends synthetic messages before the message page, never changes
// a gateway reply, and never admits or starts a provider turn.
void main() {
  final server = PresendServer();
  setUpAll(server.start);
  tearDownAll(server.close);
  test(
    'real projection coverage overtakes control and survives fresh changes',
    () async {
      final f = PresendFixture(server, 'related-coverage');
      final evidence = Platform.environment['HANDRAIL_RELATED_EVIDENCE']!;
      addTearDown(() async {
        await server.command('trace-auth', {'denied': false});
        await f.close(evidence);
      });
      await f.open();
      await server.command('history-seed', {
        'conversationId': f.id,
        'count': 2,
        'text': 'Synthetic initial history',
      });
      var advanced = false;
      f.trace.beforeRequest = (row) async {
        final request = row['request'] as Map;
        if (!advanced &&
            request['operation'] == 'page' &&
            (request['input'] as Map)['view'] == null) {
          advanced = true;
          await server.command('history-seed', {
            'conversationId': f.id,
            'count': 5,
            'text': 'Synthetic concurrent history',
          });
        }
      };
      int contextReads() => f.trace.rows.where((row) {
        final request = row['request'] as Map?;
        final input = request?['input'] as Map?;
        return request?['operation'] == 'page' &&
            (input?['view'] as Map?)?['type'] == 'context';
      }).length;
      await f.controller.session!.refresh();
      expect(advanced, isTrue);
      expect(f.controller.document!.revision, 2);
      expect(f.controller.session!.displayWindow!.state.revision, 7);
      expect(contextReads(), 1);
      final before = f.trace.rows.length;
      await f.controller.session!.refresh();
      expect(f.controller.document!.revision, 7);
      expect(contextReads(), 1);
      expect(
        f.trace.rows
            .skip(before)
            .where((r) => r['event'] == 'http')
            .map((r) => (r['request'] as Map)['operation']),
        ['control', 'changes'],
      );
      expect(f.controller.document!.messages, hasLength(7));
      // Revocation still reaches the real gateway's authorization boundary.
      await server.command('trace-auth', {'denied': true});
      await expectLater(
        f.controller.session!.refresh(),
        throwsA(
          isA<HandrailGatewayException>().having(
            (e) => e.statusCode,
            'status',
            403,
          ),
        ),
      );
      expect(f.controller.document, isNull);
      final stats = await server.command('stats');
      for (final key in ['invocations', 'starts', 'resumes', 'admissions']) {
        expect(stats[key], 0);
      }
      f.trace.mark('qualified', {
        'contextReads': contextReads(),
        'stats': stats,
      });
    },
  );
}
