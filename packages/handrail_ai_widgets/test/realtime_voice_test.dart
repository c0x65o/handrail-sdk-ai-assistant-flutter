import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

class _Session implements HandrailRealtimeVoiceSession<String> {
  @override
  final ValueNotifier<HandrailRealtimeVoiceState> state =
      ValueNotifier(const HandrailRealtimeVoiceState.idle());
  final starts = <(String, String)>[];
  int stops = 0;
  int mutes = 0;
  int playback = 0;
  bool confirmEnd = true;
  bool throwStop = false;
  bool throwStart = false;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  int generation = 0;

  @override
  Future<void> start(
      {required String conversationId, required String context}) async {
    final captured = ++generation;
    starts.add((conversationId, context));
    if (throwStart) throw StateError('PRIVATE_START');
    state.value = const HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.connecting);
    await startGate?.future;
    if (captured != generation) return;
    state.value = const HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.listening);
  }

  @override
  Future<void> stop() async {
    generation++;
    stops++;
    state.value = const HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.ending, isMuted: true);
    await stopGate?.future;
    if (throwStop) throw StateError('PRIVATE_STOP');
    state.value = HandrailRealtimeVoiceState(
        phase: confirmEnd
            ? HandrailRealtimeVoicePhase.ended
            : HandrailRealtimeVoicePhase.endUnconfirmed,
        isMuted: true);
  }

  @override
  Future<void> retryPlayback() async {
    playback++;
    state.value = HandrailRealtimeVoiceState(
        phase: state.value.phase, isMuted: state.value.isMuted);
  }

  @override
  Future<void> toggleMuted() async {
    mutes++;
    state.value = HandrailRealtimeVoiceState(
        phase: state.value.phase,
        isMuted: !state.value.isMuted,
        playbackBlocked: state.value.playbackBlocked);
  }

  @override
  Future<void> dispose() async {
    await stop();
    state.dispose();
  }
}

Future<void> _show(
  WidgetTester tester,
  _Session session, {
  Future<bool> Function(String)? beforeStart,
  ValueNotifier<bool>? allowed,
  ValueNotifier<String>? scope,
  double width = 402,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.orange, brightness: brightness)),
    home: Builder(
        builder: (context) => Scaffold(
                body: TextButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                            body: MediaQuery(
                                data: MediaQuery.of(context).copyWith(
                                    textScaler: TextScaler.linear(scale)),
                                child: ListenableBuilder(
                                  listenable: Listenable.merge([
                                    if (allowed != null) allowed,
                                    if (scope != null) scope
                                  ]),
                                  builder: (context, _) =>
                                      HandrailRealtimeVoiceSurface<String>(
                                    session: session,
                                    conversationId:
                                        scope?.value ?? 'saved-conversation',
                                    canStart: allowed?.value ?? true,
                                    beforeStart: beforeStart,
                                    title: 'Branded voice',
                                    idleLabel: 'Who will speak?',
                                    startOptions: const [
                                      HandrailRealtimeVoiceStartOption(
                                          key: ValueKey('self'),
                                          label: 'Just me',
                                          context: 'trusted-self'),
                                      HandrailRealtimeVoiceStartOption(
                                          key: ValueKey('shared'),
                                          label: 'Shared device',
                                          context: 'uncertain-speaker'),
                                    ],
                                    contentBuilder: (_, voice, closing) =>
                                        const Text(
                                            'Host financial review stays here'),
                                  ),
                                )),
                          ))),
              child: const Text('Open voice'),
            ))),
  ));
  await tester.tap(find.text('Open voice'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'branding and business content retain all core controls at small widths',
      (tester) async {
    final session = _Session();
    await _show(tester, session,
        width: 320, scale: 1.5, brightness: Brightness.dark);
    final semantics = tester.ensureSemantics();
    await _tap(tester, 'shared');
    expect(session.starts, [('saved-conversation', 'uncertain-speaker')]);
    expect(find.text('Host financial review stays here'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    final status = tester
        .getSemantics(find.byKey(const ValueKey('handrail-realtime-status')));
    expect(status.flagsCollection.isLiveRegion, isTrue);
    await _tap(tester, 'handrail-realtime-mute');
    expect(session.mutes, 1);
    expect(find.text('Microphone muted'), findsOneWidget);
    session.state.value = const HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.listening, playbackBlocked: true);
    await tester.pumpAndSettle();
    await _tap(tester, 'handrail-realtime-playback');
    expect(session.playback, 1);
    expect(find.text('Enable voice playback'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await _tap(tester, 'handrail-realtime-end');
    expect(find.text('Open voice'), findsOneWidget);
    expect(session.stops, 1);
  });

  testWidgets(
      'close fences delayed permission/history preparation before capture',
      (tester) async {
    final gate = Completer<bool>();
    final session = _Session();
    int checks = 0;
    await _show(tester, session, beforeStart: (_) {
      checks++;
      return gate.future;
    });
    await _tap(tester, 'self');
    await _tap(tester, 'shared');
    expect(checks, 1);
    await _tap(tester, 'handrail-realtime-close');
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(session.starts, isEmpty);
    expect(session.stops, 1);
    expect(find.text('Open voice'), findsOneWidget);
  });

  testWidgets('permission revocation and failed preflight do not admit a call',
      (tester) async {
    final gate = Completer<bool>();
    final allowed = ValueNotifier(true);
    final session = _Session();
    await _show(tester, session,
        allowed: allowed, beforeStart: (_) => gate.future);
    await _tap(tester, 'self');
    allowed.value = false;
    await tester.pump();
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(session.starts, isEmpty);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('self')))
            .onPressed,
        isNull);
    allowed.dispose();
  });

  testWidgets('scope replacement discards delayed preflight and resets choice',
      (tester) async {
    final gate = Completer<bool>();
    final scope = ValueNotifier('old-scope');
    final session = _Session();
    await _show(tester, session, scope: scope, beforeStart: (_) => gate.future);
    await _tap(tester, 'self');
    scope.value = 'new-scope';
    await tester.pumpAndSettle();
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(session.starts, isEmpty);
    expect(session.stops, 1);
    scope.dispose();
  });

  testWidgets('uncertain end stays visible and retries the same session',
      (tester) async {
    final session = _Session()..confirmEnd = false;
    await _show(tester, session);
    await _tap(tester, 'self');
    await _tap(tester, 'handrail-realtime-end');
    expect(find.text('End not confirmed'), findsOneWidget);
    expect(session.starts, hasLength(1));
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('handrail-realtime-mute')))
            .onPressed,
        isNull);
    expect(find.byKey(const ValueKey('handrail-realtime-leave-unconfirmed')),
        findsOneWidget);
    session.confirmEnd = true;
    await _tap(tester, 'handrail-realtime-retry-end');
    expect(session.stops, 2);
    expect(session.starts, hasLength(1));
    expect(find.text('Open voice'), findsOneWidget);
  });

  testWidgets('explicit leave never changes an unconfirmed remote outcome',
      (tester) async {
    final session = _Session()..confirmEnd = false;
    await _show(tester, session);
    await _tap(tester, 'self');
    await _tap(tester, 'handrail-realtime-close');
    await _tap(tester, 'handrail-realtime-leave-unconfirmed');
    expect(
        session.state.value.phase, HandrailRealtimeVoicePhase.endUnconfirmed);
    expect(session.stops, 1);
    expect(find.text('Open voice'), findsOneWidget);
  });

  testWidgets(
      'Back during connecting cancels startup and cannot later resume capture',
      (tester) async {
    final session = _Session()..startGate = Completer<void>();
    await _show(tester, session);
    await _tap(tester, 'self');
    expect(find.text('Connecting…'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    session.startGate!.complete();
    await tester.pumpAndSettle();
    expect(session.state.value.phase, HandrailRealtimeVoicePhase.ended);
    expect(session.stops, 1);
    expect(find.text('Open voice'), findsOneWidget);
  });

  testWidgets('preflight uses refreshed eligibility after a loading frame',
      (tester) async {
    final gate = Completer<bool>();
    final allowed = ValueNotifier(true);
    addTearDown(allowed.dispose);
    final session = _Session();
    await _show(tester, session, allowed: allowed, beforeStart: (_) async {
      allowed.value = false;
      final result = await gate.future;
      allowed.value = result;
      return result;
    });
    await _tap(tester, 'self');
    expect(session.starts, isEmpty);
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(session.starts, [('saved-conversation', 'trusted-self')]);
    expect(session.state.value.phase, HandrailRealtimeVoicePhase.listening);
  });

  testWidgets('microphone permission dialog does not cancel live startup',
      (tester) async {
    final session = _Session()..startGate = Completer<void>();
    await _show(tester, session);
    await _tap(tester, 'self');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(session.stops, 0);
    expect(session.state.value.phase, HandrailRealtimeVoicePhase.connecting);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    session.startGate!.complete();
    await tester.pumpAndSettle();
    expect(session.starts, hasLength(1));
    expect(session.state.value.phase, HandrailRealtimeVoicePhase.listening);
  });

  testWidgets('background stops immediately; resumed view never auto-starts',
      (tester) async {
    final gate = Completer<bool>();
    final session = _Session();
    await _show(tester, session, beforeStart: (_) => gate.future);
    await _tap(tester, 'self');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(session.stops, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(session.stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    gate.complete(true);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(session.starts, isEmpty);
    expect(find.text('Voice ended'), findsOneWidget);
    expect(find.text('Branded voice'), findsOneWidget);
  });

  testWidgets(
      'stop errors stay bounded and duplicate end clicks cannot overlap',
      (tester) async {
    final gate = Completer<void>();
    final session = _Session()
      ..stopGate = gate
      ..throwStop = true;
    await _show(tester, session);
    await _tap(tester, 'self');
    await _tap(tester, 'handrail-realtime-end');
    await _tap(tester, 'handrail-realtime-end');
    expect(session.stops, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('PRIVATE_STOP'), findsNothing);
    expect(find.text('Could not confirm the call ended. Retry ending it.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-realtime-leave-unconfirmed')),
        findsNothing);
    session.throwStop = false;
    await _tap(tester, 'handrail-realtime-retry-end');
    expect(session.stops, 2);
    expect(find.text('Open voice'), findsOneWidget);
  });

  testWidgets('safe startup failure retries the captured host speaker context',
      (tester) async {
    final session = _Session();
    await _show(tester, session);
    await _tap(tester, 'shared');
    session.state.value = const HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.failed);
    await tester.pumpAndSettle();
    await _tap(tester, 'handrail-realtime-retry');
    expect(session.starts, [
      ('saved-conversation', 'uncertain-speaker'),
      ('saved-conversation', 'uncertain-speaker'),
    ]);
  });

  testWidgets(
      'backgrounding an active call retains its unconfirmed end after resume',
      (tester) async {
    final session = _Session()..confirmEnd = false;
    await _show(tester, session);
    await _tap(tester, 'self');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(session.stops, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(session.stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(session.stops, 1);
    expect(session.starts, hasLength(1));
    expect(find.text('End not confirmed'), findsOneWidget);
    expect(find.byKey(const ValueKey('handrail-realtime-retry-end')),
        findsOneWidget);
  });

  testWidgets(
      'preflight exceptions are recoverable without raw error disclosure',
      (tester) async {
    final session = _Session();
    bool fail = true;
    await _show(tester, session, beforeStart: (_) async {
      if (fail) throw StateError('PRIVATE_PREFLIGHT');
      return true;
    });
    await _tap(tester, 'self');
    expect(find.text('Voice could not start. Check access and retry.'),
        findsOneWidget);
    expect(find.textContaining('PRIVATE_PREFLIGHT'), findsNothing);
    expect(session.starts, isEmpty);
    fail = false;
    await _tap(tester, 'shared');
    expect(session.starts.single.$2, 'uncertain-speaker');
  });
}
