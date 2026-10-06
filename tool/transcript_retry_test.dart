// Public workspace -> transcript Retry -> account controller -> real session.
// Only the HTTP/storage boundaries are simulated; no consumer source is changed.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'reentrant_assistant_test.dart' as phone;
import 'terminal_pending_test.dart';

class RetryFixture extends TerminalFixture {
  RetryFixture({super.bounded, this.startAccepted = false}) {
    denyStart = false;
    intercept = (request, body) async {
      if (body['operation'] == 'append_mutations') {
        admissionBodies.add(Map.of(body['input'] as Map));
        // Model the gateway's duplicate receipt without another message/effect.
        if (admissionBodies.length > 1 &&
            jsonEncode(admissionBodies.first) ==
                jsonEncode(admissionBodies.last)) {
          admissions++;
          return ok({
            'status': 'mutations',
            'acknowledgements': [
              for (final m in (body['input'] as Map)['mutations'] as List)
                {'mutationId': (m as Map)['mutationId'], 'status': 'duplicate'},
            ],
          });
        }
      }
      if (request.url.path.endsWith('/turns/start')) {
        startBodies.add(Map.of(body));
        savedStart = Map<String, Object?>.from(body);
        if (startBodies.length == 1) {
          starts++;
          // Lose the acknowledgement either before or after the start effect.
          if (startAccepted) {
            status = 'running';
            revision++;
            providerEffects++;
          }
          return http.Response('', 200);
        }
        if (startAccepted &&
            jsonEncode(body) == jsonEncode(startBodies.first)) {
          starts++;
          return http.Response(
            'event: started\ndata: ${jsonEncode({'conversationId': 'chat', 'turnId': turnId, 'mutationId': body['mutationId']})}\n\n',
            200,
          );
        }
      }
      return null;
    };
  }
  final bool startAccepted;
  final admissionBodies = <Map>[], startBodies = <Map>[];
}

Future<HandrailTurnSubmission> loseStart(
  WidgetTester tester,
  RetryFixture f,
) async {
  await tester.pumpWidget(f.surface());
  await phone.frames(tester);
  await tester.enterText(find.byKey(const ValueKey('draft')), 'Saved request');
  await phone.frames(tester);
  await tester.tap(find.byKey(const ValueKey('send')));
  for (var n = 0; n < 20; n++) {
    await phone.frames(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    if (!f.assistant.submitting) break;
  }
  expect(f.assistant.error?.code, 'start_unconfirmed');
  expect(f.admissions, 1);
  expect(f.starts, 1);
  expect(f.providerEffects, f.startAccepted ? 1 : 0);
  final saved = (await f.store.load('chat'))!;
  expect(saved.toJson()['admission'], f.admissionBodies.single);
  expect(saved.toJson()['start'], f.startBodies.single);
  return saved;
}

Future<void> finishRetry(WidgetTester tester, RetryFixture f) async {
  for (var n = 0; n < 20; n++) {
    await phone.frames(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    if (!f.assistant.busy && find.text('Retrying…').evaluate().isEmpty) break;
  }
}

Future<void> close(WidgetTester tester, RetryFixture f) async {
  await tester.pumpWidget(const SizedBox());
  await phone.settle(tester, f.assistant.dispose());
  expect(tester.takeException(), isNull);
}

void main() {
  for (final bounded in [true, false]) {
    for (final startAccepted in [false, true]) {
      testWidgets(
        'lost start uses explicit UI Retry once; bounded=$bounded accepted=$startAccepted',
        (tester) async {
          final f = RetryFixture(
            bounded: bounded,
            startAccepted: startAccepted,
          );
          addTearDown(() => tester.runAsync(f.dispose));
          final saved = await loseStart(tester, f);
          await tester.enterText(
            find.byKey(const ValueKey('draft')),
            'Newer draft',
          );
          await phone.frames(tester);
          await f.files.writeAttachmentDraft('chat', [
            {
              'id': 'new-file',
              'filename': 'new.png',
              'mediaType': 'image/png',
              'byteSize': 3,
              'bytes': [1, 2, 3],
            },
          ], null);
          final files = await f.files.readAttachmentDraft('chat');
          // Opening, automatic observation and a cold account reload never resend.
          await phone.settle(tester, f.assistant.openConversation('chat'));
          await phone.settle(tester, f.assistant.refreshObservations());
          await tester.pumpWidget(const SizedBox());
          await phone.settle(tester, f.reload());
          await tester.pumpWidget(f.surface());
          await phone.frames(tester);
          expect(f.admissions, 1);
          expect(f.starts, 1);
          expect((await f.store.load('chat'))!.toJson(), saved.toJson());
          expect(find.text('Retry'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.tap(find.text('Retry'));
          // Account-level binding callers coalesce with the same button operation.
          final joined = f.assistant.transcriptBinding.retry();
          expect(
            identical(joined, f.assistant.transcriptBinding.retry()),
            isTrue,
          );
          await phone.settle(tester, joined);
          await finishRetry(tester, f);
          expect(f.admissions, 2);
          expect(f.starts, 2);
          expect(f.admissionBodies.last, saved.toJson()['admission']);
          expect(f.startBodies.last, saved.toJson()['start']);
          expect(f.providerEffects, 1);
          expect(await f.store.load('chat'), isNull);
          expect(f.messages, hasLength(1));
          expect(f.drafts.controller.text, 'Newer draft');
          expect(await f.files.readAttachmentDraft('chat'), files);
          expect(tester.takeException(), isNull);
          await close(tester, f);
        },
      );
    }

    testWidgets(
      'terminal denial Retry enables follow-up without replay; bounded=$bounded',
      (tester) async {
        final f = RetryFixture(bounded: bounded);
        addTearDown(() => tester.runAsync(f.dispose));
        await loseStart(tester, f);
        f.status = 'failed';
        f.revision++;
        await tester.enterText(
          find.byKey(const ValueKey('draft')),
          'Follow-up',
        );
        await phone.frames(tester);
        await tester.tap(find.text('Retry'));
        await finishRetry(tester, f);
        expect(f.admissions, 1);
        expect(f.starts, 1);
        expect(f.providerEffects, 0);
        expect(await f.store.load('chat'), isNull);
        expect(f.assistant.canSend, isTrue);
        expect(f.drafts.controller.text, 'Follow-up');
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('send')))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const ValueKey('send')));
        await finishRetry(tester, f);
        expect(f.admissions, 2);
        expect(f.starts, 2);
        expect(f.startBodies.last, isNot(f.startBodies.first));
        expect(f.providerEffects, 1);
        await close(tester, f);
      },
    );

    for (final stage in [1, 3]) {
      for (final change in ['selection', 'reentry', 'dispose', 'replacement']) {
        testWidgets(
          '$change during Retry read $stage prevents replay; bounded=$bounded',
          (tester) async {
            final f = RetryFixture(bounded: bounded);
            addTearDown(() => tester.runAsync(f.dispose));
            final saved = await loseStart(tester, f);
            final intercept = f.intercept;
            final entered = Completer<void>(), release = Completer<void>();
            var reads = 0;
            f.intercept = (request, body) async {
              if (body['operation'] ==
                      (bounded ? 'control' : 'pull_snapshot') &&
                  ++reads == stage) {
                entered.complete();
                await release.future;
              }
              return intercept!(request, body);
            };
            await tester.tap(find.text('Retry'));
            await phone.settle(tester, entered.future);
            HandrailTurnSubmission? replacement;
            Future<void>? reopening;
            if (change == 'dispose') {
              await tester.pumpWidget(const SizedBox());
              await phone.settle(tester, f.assistant.dispose());
              f.assistant = f.controller();
            } else if (change == 'replacement') {
              final value =
                  jsonDecode(jsonEncode(saved.toJson()))
                      as Map<String, dynamic>;
              // A newer pending operation must not inherit the old click.
              (value['start'] as Map)['idempotencyKey'] = 'start:newer';
              replacement = HandrailTurnSubmission.fromJson(value);
              await f.store.acknowledge(saved);
              await f.store.retain(replacement);
            } else {
              f.assistant.clearSelection();
              if (change == 'reentry') {
                reopening = f.assistant.openConversation('chat');
              }
            }
            release.complete();
            if (reopening != null) await phone.settle(tester, reopening);
            await finishRetry(tester, f);
            expect(f.admissions, 1);
            expect(f.starts, 1);
            expect(f.providerEffects, 0);
            expect(
              (await f.store.load('chat'))!.toJson(),
              (replacement ?? saved).toJson(),
            );
            await close(tester, f);
          },
        );
      }
    }

    for (final failure in [
      '401',
      '403',
      '503',
      'busy',
      'archived',
      'storage',
    ]) {
      testWidgets('Retry retains pending on $failure; bounded=$bounded', (
        tester,
      ) async {
        final f = RetryFixture(bounded: bounded);
        addTearDown(() => tester.runAsync(f.dispose));
        final saved = await loseStart(tester, f);
        final intercept = f.intercept;
        f.intercept = (request, body) async {
          if (int.tryParse(failure) case final code?) {
            if (request.url.path.endsWith('/conversations/history') ||
                body['operation'] == 'pull_snapshot')
              return http.Response('Unavailable', code);
          }
          if (failure == 'archived' &&
              request.url.path.endsWith('/conversations/get')) {
            return f.ok({
              'descriptor': {
                ...f.descriptor('chat'),
                'lifecycle': 'archived',
                'version': 2,
              },
            });
          }
          return intercept!(request, body);
        };
        if (failure == 'busy') f.turnId = 'another-active-turn';
        if (failure == 'storage') f.failRead = true;
        await tester.tap(find.text('Retry'));
        await finishRetry(tester, f);
        f.failRead = false;
        expect((await f.store.load('chat'))!.toJson(), saved.toJson());
        expect(f.admissions, 1);
        expect(f.starts, 1);
        expect(f.providerEffects, 0);
        expect(f.assistant.canSend, isFalse);
        if (int.tryParse(failure) != null) {
          f.intercept = intercept;
          // A click recovering a blocked read is observation-only. Once reads
          // work, the still-visible pending Retry is a separate explicit action.
          await tester.tap(find.text('Retry'));
          await finishRetry(tester, f);
          expect(f.admissions, 1);
          expect(f.starts, 1);
          expect(f.assistant.hasPendingMessage, isTrue);
          await tester.tap(find.text('Retry'));
          await finishRetry(tester, f);
          expect(f.admissions, 2);
          expect(f.starts, 2);
        }
        await close(tester, f);
      });
    }

    testWidgets(
      'read-only Retry without pending recovers history; bounded=$bounded',
      (tester) async {
        final f = RetryFixture(bounded: bounded);
        addTearDown(() => tester.runAsync(f.dispose));
        f.intercept = (request, body) async =>
            request.url.path.endsWith('/conversations/history') ||
                body['operation'] == 'pull_snapshot'
            ? http.Response('Offline', 503)
            : null;
        await tester.pumpWidget(f.surface());
        await phone.frames(tester);
        expect(find.text('Retry'), findsOneWidget);
        f.intercept = null;
        await tester.tap(find.text('Retry'));
        await finishRetry(tester, f);
        expect(f.assistant.canSend, isTrue);
        expect(f.admissions, 0);
        expect(f.starts, 0);
        expect(f.assistant.error, isNull);
        await close(tester, f);
      },
    );
  }

  for (final empty in [true, false]) {
    testWidgets(
      'catalog Retry observes recovered ${empty ? "empty" : "existing"} history without creating',
      (tester) async {
        final f = RetryFixture();
        addTearDown(() => tester.runAsync(f.dispose));
        f.assistant = HandrailAssistantController(
          client: f.client,
          pendingStore: f.store,
          autoCreate: true,
          pollingInterval: null,
        );
        f.intercept = (request, body) async =>
            request.url.path.endsWith('/conversations/list')
            ? http.Response('Offline', 503)
            : null;
        await tester.pumpWidget(f.surface());
        await phone.frames(tester);
        expect(f.assistant.selectedId, isNull);
        expect(find.text('Retry'), findsOneWidget);
        f.intercept = (request, body) async =>
            empty && request.url.path.endsWith('/conversations/list')
            ? f.ok({
                'items': [],
                'hasMore': false,
                'nextCursor': null,
                'order': body['order'],
              })
            : null;
        await tester.tap(find.text('Retry'));
        await finishRetry(tester, f);
        expect(f.assistant.selectedId, empty ? isNull : 'chat');
        expect(f.assistant.error, isNull);
        expect(f.assistant.historyError, isNull);
        expect(
          f.requests.where((path) => path.endsWith('/conversations/create')),
          isEmpty,
        );
        expect(f.admissions, 0);
        expect(f.starts, 0);
        await close(tester, f);
      },
    );
  }

  for (final invalid in [
    'foreign-turn',
    'foreign-conversation',
    'stale',
    'generation',
    'preparing',
  ]) {
    testWidgets('explicit Retry rejects $invalid exact-turn proof', (
      tester,
    ) async {
      final f = RetryFixture();
      addTearDown(() => tester.runAsync(f.dispose));
      final saved = await loseStart(tester, f);
      final intercept = f.intercept;
      f.intercept = (request, body) async {
        if (body['operation'] == 'control' &&
            (body['input'] as Map)['turnId'] != null) {
          return f.ok({
            ...f.header('chat'),
            if (invalid == 'foreign-conversation') 'conversationId': 'other',
            if (invalid == 'stale') 'revision': f.revision - 1,
            if (invalid == 'generation') 'generation': 1,
            if (invalid == 'preparing') 'status': 'preparing',
            'activeTurn': invalid == 'preparing' ? null : f.turn,
            'latestTurn': invalid == 'preparing' ? null : f.turn,
            'requestedTurn': invalid == 'preparing'
                ? null
                : {
                    ...f.turn!,
                    if (invalid == 'foreign-turn') 'turnId': 'other',
                  },
          });
        }
        return intercept!(request, body);
      };
      await tester.tap(find.text('Retry'));
      await finishRetry(tester, f);
      expect((await f.store.load('chat'))!.toJson(), saved.toJson());
      expect(f.admissions, 1);
      expect(f.starts, 1);
      expect(f.assistant.canSend, isFalse);
      await close(tester, f);
    });
  }
}
