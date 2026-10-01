// Local source qualification with both SDK packages in the package map.
// Only HTTP is simulated; session, window, binding, widget and Material styling
// are real. This is a Flutter widget test, not native/device acceptance.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class Fixture {
  Fixture() {
    session = HandrailConversationSession(
      client: client,
      conversationId: 'chat',
      pollingInterval: null,
    );
  }
  late final HandrailConversationSession session;
  late final client = HandrailAiClient(
    baseUri: Uri.parse('https://fixture.invalid/ai'),
    httpClient: MockClient(handle),
  );
  Completer<void>? pageGate;
  Completer<http.Response>? held;
  int pages = 0, polls = 0;
  Map<String, Object?> header() => {
    'schemaVersion': 1,
    'conversationId': 'chat',
    'status': 'ready',
    'generation': 0,
    'revision': 100,
    'canonicalRevision': 100,
    'activeTurnId': null,
  };
  Map<String, Object?> row(int id) => {
    'kind': 'message',
    'id': 'm$id',
    'revision': id,
    'turnId': null,
    'bytes': 200,
    'deferred': false,
    'value': {
      'message_id': 'm$id',
      'role': 'assistant',
      'attachments': [],
      'content': [
        {'type': 'text', 'text': 'Message $id'},
      ],
    },
  };
  http.Response ok(Object value) => http.Response(
    jsonEncode({'ok': true, 'value': value}),
    200,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'activity': false,
        'authoritativeCancellation': false,
        'displayHistory': {
          'version': 1,
          'control': true,
          'maximumPageSize': 50,
          'maximumPageBytes': 262144,
        },
      });
    final body = jsonDecode(request.body) as Map, input = body['input'] as Map;
    switch (body['operation']) {
      case 'control':
        return ok({
          ...header(),
          'activeTurn': null,
          'latestTurn': null,
          'requestedTurn': null,
        });
      case 'page':
        if (input['view'] != null)
          return ok({...header(), 'records': [], 'nextCursor': null});
        pages++;
        await pageGate?.future;
        final anchor = input['anchor'] as Map?;
        final end = anchor == null
            ? 101
            : int.parse((anchor['messageId'] as String).substring(1));
        return ok({
          ...header(),
          'records': [for (var id = end - 30; id < end; id++) row(id)],
          'nextCursor': 'older',
        });
      case 'changes':
        polls++;
        held = Completer<http.Response>();
        return held!.future;
      default:
        throw StateError('Unexpected synthetic HTTP operation');
    }
  }

  void release() {
    held!.complete(
      ok({
        ...header(),
        'records': [],
        'nextCursor': null,
        'throughRevision': 100,
      }),
    );
    held = null;
  }
}

void main() {
  for (final sessionRefresh in [true, false]) {
    testWidgets(
      'Jump stays enabled during ${sessionRefresh ? 'session refresh' : 'widget polling'} and serializes navigation',
      (tester) async {
        final f = Fixture();
        await tester.runAsync(f.session.initialize);
        final window = f.session.displayWindow!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 390,
                height: 500,
                child: HandrailDisplayTranscript(
                  binding: window.uiBinding,
                  conversationId: 'chat',
                  manageSelection: false,
                  pollInterval: sessionRefresh
                      ? null
                      : const Duration(milliseconds: 150),
                  messageBuilder: (_, row) =>
                      SizedBox(height: 100, child: Text(row['id'] as String)),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final scroll = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent - 180);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        FilledButton jump() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Jump to latest'),
        );
        final colors = <Color?>[];
        Color? renderedColor() => tester
            .widget<Material>(
              find.descendant(
                of: find.widgetWithText(FilledButton, 'Jump to latest'),
                matching: find.byType(Material),
              ),
            )
            .color;
        for (var cycle = 0; cycle < 3; cycle++) {
          if (sessionRefresh) {
            unawaited(f.session.refresh());
          } else {
            await tester.pump(const Duration(milliseconds: 160));
          }
          await tester.pump();
          expect(window.state.loading, HandrailDisplayWindowOperation.changes);
          for (var frame = 0; frame < 5; frame++) {
            expect(jump().enabled, isTrue);
            colors.add(renderedColor());
            await tester.pump(const Duration(milliseconds: 16));
          }
          if (cycle < 2) {
            f.release();
            await tester.pump();
            await tester.pump();
            expect(jump().enabled, isTrue);
            colors.add(renderedColor());
          }
        }
        expect(colors.toSet().length, 1);
        expect(colors.first, isNotNull);
        expect(f.polls, 3);
        final reads = f.pages;
        f.pageGate = Completer<void>();
        await tester.tap(find.text('Jump to latest'));
        await tester.pump();
        expect(
          find.widgetWithText(FilledButton, 'Jump to latest'),
          findsNothing,
        );
        expect(f.pages, reads, reason: 'Latest must wait for synchronization');
        f.release();
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(f.pages, reads + 1);
        expect(window.state.loading, HandrailDisplayWindowOperation.latest);
        expect(
          find.widgetWithText(FilledButton, 'Jump to latest'),
          findsNothing,
        );
        f.pageGate!.complete();
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          scroll.position.maxScrollExtent - scroll.offset,
          lessThanOrEqualTo(2),
        );
        expect(find.text('Jump to latest'), findsNothing);
        expect(window.followingLatest, isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await f.session.dispose();
          f.client.close();
        });
        expect(tester.takeException(), isNull);
      },
    );
  }
}
