import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'support/native_voice_platform.dart';

const conversation = '11111111-1111-4111-8111-111111111111';

class _Gateway implements HandrailRealtimeVoiceGateway<String> {
  final bootstraps = <HandrailRealtimeVoiceBootstrap<String>>[];
  final endings = <(String, String)>[];
  Completer<String>? bootstrap;
  Completer<bool>? ending;
  Object? failure;
  bool confirmed = true;
  @override
  Future<String> exchangeSdp(
    HandrailRealtimeVoiceBootstrap<String> request,
  ) async {
    bootstraps.add(request);
    if (failure case final error?) throw error;
    return bootstrap == null
        ? 'v=0\r\nfixture answer'
        : await bootstrap!.future;
  }

  @override
  Future<bool> endCall({
    required String conversationId,
    required String callId,
  }) async {
    endings.add((conversationId, callId));
    return ending == null ? confirmed : await ending!.future;
  }
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Expected voice fixture state did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'media startup binds identity; muted Stop waits for exact call end and retries without new admission',
    () async {
      final platform = NativeVoicePlatform()..install();
      final gateway = _Gateway();
      final session = HandrailWebRtcVoiceSession(gateway: gateway);
      await session.start(
        conversationId: conversation,
        context: 'shared-speaker',
      );
      expect(session.state.value.phase, HandrailRealtimeVoicePhase.listening);
      final request = gateway.bootstraps.single;
      expect(request.context, 'shared-speaker');
      expect(request.conversationId, conversation);
      expect(
        request.callId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(request.offerSdp, 'v=0\r\nfixture offer');
      expect(platform.answer, 'v=0\r\nfixture answer');
      await session.toggleMuted();
      await _until(() => !platform.microphoneEnabled);
      expect(session.state.value.isMuted, isTrue);
      await session.toggleMuted();
      await _until(() => platform.microphoneEnabled);
      gateway.ending = Completer<bool>();
      final ending = session.stop();
      expect(identical(ending, session.stop()), isTrue);
      await _until(() => !platform.microphoneEnabled);
      expect(platform.count('peerConnectionClose'), 0);
      expect(gateway.endings, [(conversation, request.callId)]);
      gateway.ending!.complete(false);
      await ending;
      expect(
        session.state.value.phase,
        HandrailRealtimeVoicePhase.endUnconfirmed,
      );
      expect(platform.count('peerConnectionClose'), 1);
      await session.start(
        conversationId: conversation,
        context: 'different-speaker',
      );
      expect(gateway.bootstraps, hasLength(1));
      gateway.ending = null;
      await session.stop();
      expect(session.state.value.phase, HandrailRealtimeVoicePhase.ended);
      expect(gateway.endings, [
        (conversation, request.callId),
        (conversation, request.callId),
      ]);
      await session.dispose();
      expect(gateway.endings, hasLength(2));
    },
  );

  test(
    'late SDP after cancelled admission never reconnects and uses the retained call identity for end',
    () async {
      final platform = NativeVoicePlatform()..install();
      final gateway = _Gateway()
        ..bootstrap = Completer<String>()
        ..confirmed = false;
      final session = HandrailWebRtcVoiceSession(gateway: gateway);
      final starting = session.start(
        conversationId: conversation,
        context: 'self',
      );
      await _until(() => gateway.bootstraps.isNotEmpty);
      final request = gateway.bootstraps.single;
      await session.stop();
      expect(request.cancellation.isCancelled, isTrue);
      expect(
        session.state.value.phase,
        HandrailRealtimeVoicePhase.endUnconfirmed,
      );
      gateway.bootstrap!.complete('v=0\r\nlate answer');
      await starting;
      expect(platform.count('setRemoteDescription'), 0);
      expect(platform.microphoneEnabled, isFalse);
      expect(gateway.endings.single, (conversation, request.callId));
      gateway.confirmed = true;
      await session.dispose();
    },
  );

  test(
    'provider close is not a durable end receipt and unrelated identities are ignored',
    () async {
      final platform = NativeVoicePlatform()..install();
      final gateway = _Gateway()..confirmed = false;
      final session = HandrailWebRtcVoiceSession(gateway: gateway);
      await session.start(conversationId: conversation, context: 'self');
      platform.control({
        'type': 'session.closed',
        'session': {'id': 'unrelated'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(gateway.endings, isEmpty);
      platform.control({
        'type': 'session.closed',
        'session': {'id': 'provider-session'},
      });
      await _until(
        () =>
            session.state.value.phase ==
            HandrailRealtimeVoicePhase.endUnconfirmed,
      );
      expect(gateway.endings, hasLength(1));
      expect(gateway.bootstraps, hasLength(1));
      expect(platform.microphoneEnabled, isFalse);
      gateway.confirmed = true;
      await session.dispose();
    },
  );

  test(
    'bootstrap failure preserves uncertainty without replay or private error text',
    () async {
      final platform = NativeVoicePlatform()..install();
      final gateway = _Gateway()
        ..failure = StateError('PRIVATE_PROVIDER_FAILURE')
        ..confirmed = false;
      final session = HandrailWebRtcVoiceSession(gateway: gateway);
      await session.start(conversationId: conversation, context: 'self');
      expect(
        session.state.value.phase,
        HandrailRealtimeVoicePhase.endUnconfirmed,
      );
      expect(
        session.state.value.message,
        isNot(contains('PRIVATE_PROVIDER_FAILURE')),
      );
      expect(gateway.endings.single.$2, gateway.bootstraps.single.callId);
      expect(platform.microphoneEnabled, isFalse);
      expect(platform.count('setRemoteDescription'), 0);
      await session.start(conversationId: conversation, context: 'self');
      expect(gateway.bootstraps, hasLength(1));
      gateway.confirmed = true;
      await session.dispose();
    },
  );

  test('changed provider session cannot replace the admitted call', () async {
    final platform = NativeVoicePlatform()..install();
    final gateway = _Gateway();
    final session = HandrailWebRtcVoiceSession(gateway: gateway);
    await session.start(conversationId: conversation, context: 'self');
    platform.control({
      'type': 'session.started',
      'session': {'id': 'replacement'},
    });
    await _until(
      () => session.state.value.phase == HandrailRealtimeVoicePhase.ended,
    );
    expect(gateway.bootstraps, hasLength(1));
    expect(gateway.endings.single.$2, gateway.bootstraps.single.callId);
    expect(platform.microphoneEnabled, isFalse);
    await session.dispose();
  });
}
