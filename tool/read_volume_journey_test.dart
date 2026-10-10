// Real public widgets/controller/client -> loopback gateway -> disposable PGlite.
// No owner conversations, credentials or provider services are used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'presend_fixture.dart';

class BudgetRecordingClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final Completer<void> exhausted;
  BudgetRecordingClient(this.exhausted);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request);
    if (response.statusCode == 429 && !exhausted.isCompleted) {
      exhausted.completeError(
        StateError('Unchanged 120/60s gateway budget exhausted'),
      );
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void main() {
  for (final width in [390.0, 1440.0].where(
    (w) =>
        Platform.environment['HANDRAIL_READ_VOLUME_WIDTH'] == null ||
        w.toInt().toString() ==
            Platform.environment['HANDRAIL_READ_VOLUME_WIDTH'],
  )) {
    testWidgets(
      'complete request budget journey at $width',
      (tester) async {
        final previous = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previous);
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final server = PresendServer();
        await tester.runAsync(server.start);
        print("read-volume gateway ${server.origin}");
        final legacy =
            Platform.environment['HANDRAIL_READ_VOLUME_LEGACY'] == '1';
        final evidence = Platform.environment['HANDRAIL_READ_VOLUME_EVIDENCE']!;
        final storage = <String, String>{};
        final store = HandrailKeyValuePendingTurnStore(
          namespace: 'volume-$width',
          read: (key) async => storage[key],
          write: (key, value) async {
            storage[key] = value;
          },
          delete: (key) async {
            storage.remove(key);
          },
        );
        late HandrailAiClient api;
        late HandrailAssistantController controller;
        late HandrailComposerController drafts;
        String phase = 'new', loss = '';
        final phases = <String>[];
        final exhausted = Completer<void>();
        Future<void> account() async {
          api = HandrailAiClient(
            httpClient: BudgetRecordingClient(exhausted),
            baseUri: server.origin.resolve('/api/ai'),
            protectedHeaders: () => {
              'x-test-phase': phase,
              if (legacy) 'x-test-legacy-history': '1',
              if (loss.isNotEmpty) 'x-test-lose-response': loss,
            },
          );
          controller = HandrailAssistantController(
            client: api,
            pendingStore: store,
            autoCreate: false,
            pollingInterval: null,
            voicePollingInterval: null,
          );
          drafts = HandrailComposerController.forAssistant(
            controller.uiBinding,
          );
        }

        Future<void> mount() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: HandrailAssistantWorkspace<void>(
                  binding: controller.uiBinding,
                  drafts: drafts,
                  inputKey: const ValueKey('input'),
                  sendKey: const ValueKey('send'),
                  showVoice: false,
                  showAttachments: false,
                  threads: false,
                ),
              ),
            ),
          );
          await tester.pump();
        }

        Future<void> until(bool Function() predicate) async {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (!predicate()) {
            if (DateTime.now().isAfter(deadline))
              throw StateError(
                'Timed out in $phase: ${controller.error?.code}',
              );
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          await tester.pump();
          expect(tester.takeException(), isNull);
        }

        Future<void> action(String name, Future<void> Function() run) async {
          phase = name;
          // Kept in native test output alongside per-dispatch gateway evidence.
          print('read-volume ${width.toInt()} $name');
          await Future.any([run(), exhausted.future]);
          expect(controller.error, isNull, reason: phase);
          phases.add(name);
          print('read-volume ${width.toInt()} completed $name');
        }

        Future<void> settleLocal(Future<void> operation) async {
          var done = false;
          final closing = operation.whenComplete(() => done = true);
          await until(() => done);
          await closing;
        }

        Future<void> reload(String selected) async {
          await tester.pumpWidget(const SizedBox());
          await settleLocal(drafts.flushDrafts());
          drafts.dispose();
          await settleLocal(controller.dispose());
          api.close();
          await tester.runAsync(account);
          await tester.runAsync(() => controller.openConversation(selected));
          await mount();
        }

        Future<String> sendUi(String text) async {
          await until(
            () => !drafts.controller.restoringDraft && !drafts.isSubmitting,
          );
          await tester.enterText(find.byKey(const ValueKey('input')), text);
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('send')));
          await until(
            () =>
                controller.document?.activeTurnId != null &&
                !controller.session!.isSubmitting &&
                !drafts.isSubmitting,
          );
          return controller.document!.activeTurnId!;
        }

        Future<void> finish(String conversation, String turn) async {
          await tester.runAsync(() => server.command('finish'));
          await tester.runAsync(
            () => server.command('settled', {
              'conversationId': conversation,
              'turnId': turn,
            }),
          );
          await settleLocal(controller.session!.refresh());
          expect(controller.document!.latestTurn?['status'], 'completed');
          await tester.pump();
        }

        var ready = false;
        addTearDown(() async {
          final volume = await tester.runAsync(() => server.command('volume'));
          Directory(evidence).createSync(recursive: true);
          File(
            '$evidence/${legacy ? 'legacy' : 'bundle'}-${width.toInt()}.json',
          ).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'phases': phases,
              'width': width,
              'legacy': legacy,
              'volume': volume,
            }),
          );
          await tester.runAsync(() => server.command('finish'));
          if (ready) {
            await settleLocal(drafts.flushDrafts());
            drafts.dispose();
            await settleLocal(controller.dispose());
            api.close();
          }
          await tester.runAsync(server.close);
        });
        await tester.runAsync(account);
        ready = true;
        await action('new', () async {
          await tester.runAsync(controller.newConversation);
          await mount();
        });
        final old = controller.selectedId!;
        await action('ordinary-70-delta', () async {
          final turn = await sendUi('First ordinary turn');
          await finish(old, turn);
          expect(controller.document!.runtimeState.text, contains('delta69'));
          expect(controller.document!.messages, hasLength(2));
        });
        await action('ordinary-second', () async {
          final turn = await sendUi('Second ordinary turn');
          await finish(old, turn);
          expect(controller.document!.messages, hasLength(4));
        });
        await action('navigation-return', () async {
          await tester.enterText(
            find.byKey(const ValueKey('input')),
            'retained draft',
          );
          await settleLocal(drafts.flushDrafts());
          await tester.pumpWidget(const SizedBox());
          controller.clearSelection();
          await tester.runAsync(() => controller.openConversation(old));
          await mount();
          await until(() => drafts.controller.text == 'retained draft');
        });
        await action('reload-one', () async {
          await reload(old);
          await until(() => drafts.controller.text == 'retained draft');
          expect(controller.document!.messages, hasLength(4));
        });
        phase = 'lost-start-ack';
        loss = 'volume-$width:start';
        await tester.runAsync(() async {
          await expectLater(
            controller.sendMessage(
              traceRequest(),
              operationId: 'uncertain-$width',
            ),
            throwsA(anything),
          );
        });
        final retained = await tester.runAsync(() => store.load(old));
        expect(retained, isNotNull);
        final identity = jsonEncode(retained!.toJson());
        phases.add(phase);
        await action('reload-retained-intent', () async {
          await reload(old);
          expect(controller.hasPendingMessage, isTrue);
          expect(
            jsonEncode(
              (await tester.runAsync(() => store.load(old)))!.toJson(),
            ),
            identity,
          );
        });
        await action('exact-once-retry', () async {
          final before = await tester.runAsync(() => server.command('stats'));
          await tester.runAsync(controller.retryPendingMessage);
          final after = await tester.runAsync(() => server.command('stats'));
          expect(after!['invocations'], before!['invocations']);
          expect(await tester.runAsync(() => store.load(old)), isNull);
          await finish(old, retained.turnId);
        });
        loss = '';
        await action('reload-two', () => reload(old));
        await action('held-stop', () async {
          final turn = await sendUi('Hold this response');
          expect(controller.document!.activeTurnId, turn);
          await tester.runAsync(
            () => controller.requestCancellation().timeout(
              const Duration(seconds: 15),
            ),
          );
          try {
            await until(
              () => controller.document?.latestTurn?['status'] == 'cancelled',
            );
          } catch (_) {
            final detail = await tester.runAsync(
              () => server.command('inspect-turn', {
                'conversationId': old,
                'turnId': turn,
              }),
            );
            Directory(evidence).createSync(recursive: true);
            File(
              '$evidence/stop-${width.toInt()}.json',
            ).writeAsStringSync(jsonEncode(detail));
            rethrow;
          }
          await tester.runAsync(
            () => server.command('settled', {
              'conversationId': old,
              'turnId': turn,
              'status': 'cancelled',
            }),
          );
          await settleLocal(controller.session!.refresh());
          expect(controller.document!.latestTurn?['status'], 'cancelled');
          await tester.runAsync(() => server.command('finish'));
        });
        late String fresh;
        await action('new-one-admission', () async {
          await tester.runAsync(controller.newConversation);
          fresh = controller.selectedId!;
          expect(fresh, isNot(old));
          await until(() => drafts.controller.text.isEmpty);
          final before = await tester.runAsync(() => server.command('stats'));
          final turn = await sendUi('New conversation turn');
          await finish(fresh, turn);
          final after = await tester.runAsync(() => server.command('stats'));
          expect(after!['admissions'], before!['admissions'] + 1);
          expect(after['invocations'], before['invocations'] + 1);
        });
        await action('reload-three-reopen-both', () async {
          await reload(fresh);
          expect(controller.document!.messages, hasLength(2));
          await tester.runAsync(() => controller.openConversation(old));
          expect(controller.document!.messages.length, greaterThanOrEqualTo(7));
          await tester.runAsync(() => controller.openConversation(fresh));
          expect(controller.document!.messages, hasLength(2));
        });
        await action('diagnostic-lists', () async {
          final diagnosticApi = HandrailAiClient(
            baseUri: server.origin.resolve('/api/ai'),
            protectedHeaders: () => {
              'x-test-phase': phase,
              'x-test-diagnostic': '1',
            },
          );
          for (var i = 0; i < 3; i++) {
            await tester.runAsync(
              () => diagnosticApi.listConversations({
                'lifecycle': 'active',
                'pageSize': 50,
                'order': {'field': 'updated_at', 'direction': 'desc'},
              }),
            );
          }
          diagnosticApi.close();
        });
        await tester.pumpWidget(const SizedBox());
        await settleLocal(drafts.flushDrafts());
        drafts.dispose();
        await settleLocal(controller.dispose());
        api.close();
        ready = false;
        await tester.pump();
        final volume = await tester.runAsync(() => server.command('volume'));
        expect(volume!['maximumRolling60s'], lessThanOrEqualTo(120));
        expect(
          (volume['dispatches'] as List).where((r) => r['status'] == 429),
          isEmpty,
        );
        expect(volume['maximumHistoryConcurrency'], 1);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
