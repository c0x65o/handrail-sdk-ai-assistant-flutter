import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC/peerConnectionEventtest-peer');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'Stop and disposal join teardown; delayed microphone capture is disabled and released',
    () async {
      final captureRequested = Completer<void>();
      final capture = Completer<Map<String, Object?>>();
      final closingPeer = Completer<void>();
      final closePeer = Completer<void>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'initialize':
            return null;
          case 'createPeerConnection':
            return {'peerConnectionId': 'test-peer'};
          case 'getUserMedia':
            captureRequested.complete();
            return capture.future;
          case 'peerConnectionClose':
            closingPeer.complete();
            await closePeer.future;
            return null;
          case 'mediaStreamTrackSetEnable':
          case 'trackDispose':
          case 'streamDispose':
          case 'peerConnectionDispose':
            return null;
          default:
            fail('Unexpected platform operation: ${call.method}');
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final session = HandrailWebRtcVoiceSession<String>(
        gateway: _NeverGateway(),
      );
      final start = session.start(
        conversationId: '11111111-1111-4111-8111-111111111111',
        context: 'self',
      );
      await captureRequested.future;
      final firstStop = session.stop();
      final secondStop = session.stop();
      expect(identical(firstStop, secondStop), isTrue);
      bool disposed = false;
      final firstDispose = session.dispose();
      final secondDispose = session.dispose();
      expect(identical(firstDispose, secondDispose), isTrue);
      unawaited(firstDispose.then((_) => disposed = true));
      await closingPeer.future;
      expect(disposed, isFalse);
      closePeer.complete();
      await firstStop;
      await firstDispose;
      expect(disposed, isTrue);
      capture.complete({
        'streamId': 'late-microphone',
        'audioTracks': [
          {
            'id': 'late-track',
            'label': 'microphone',
            'kind': 'audio',
            'enabled': true,
          },
        ],
        'videoTracks': [],
      });
      await start;
      final mediaCalls = calls
          .where(
            (c) =>
                c.method.startsWith('mediaStreamTrack') ||
                c.method == 'trackDispose' ||
                c.method == 'streamDispose',
          )
          .toList();
      expect(mediaCalls.map((c) => c.method), [
        'mediaStreamTrackSetEnable',
        'trackDispose',
        'streamDispose',
      ]);
      expect(
        (mediaCalls.first.arguments as Map<Object?, Object?>)['enabled'],
        isFalse,
      );
      expect(
        calls.where((c) => c.method == 'peerConnectionClose'),
        hasLength(1),
      );
      expect(
        calls.where((c) => c.method == 'peerConnectionDispose'),
        hasLength(1),
      );
    },
  );

  test(
    'invalid conversation never requests a microphone or creates a peer',
    () async {
      int platformCalls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        platformCalls++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final session = HandrailWebRtcVoiceSession<String>(
        gateway: _NeverGateway(),
      );
      await session.start(conversationId: 'unsaved', context: 'shared');
      expect(session.state.value.phase, HandrailRealtimeVoicePhase.failed);
      expect(platformCalls, 0);
      await session.dispose();
    },
  );
}

class _NeverGateway implements HandrailRealtimeVoiceGateway<String> {
  @override
  Future<String> exchangeSdp(
    HandrailRealtimeVoiceBootstrap<String> request,
  ) async => fail('No HTTP admission should occur');
  @override
  Future<bool> endCall({
    required String conversationId,
    required String callId,
  }) async => fail('No remote end without an admitted call');
}
