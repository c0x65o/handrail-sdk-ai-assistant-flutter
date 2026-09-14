import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owned platform-channel fixture: real WebRTC Dart implementation, no device or
/// network. It records capture/control/teardown and emits explicit native events.
class NativeVoicePlatform {
  static const method = MethodChannel('FlutterWebRTC.Method');
  static const peer = EventChannel(
    'FlutterWebRTC/peerConnectionEventvoice-peer',
  );
  static const data = EventChannel(
    'FlutterWebRTC/dataChannelEventvoice-peercontrol',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MockStreamHandlerEventSink peerEvents;
  late MockStreamHandlerEventSink dataEvents;
  final calls = <MethodCall>[];
  bool startedEvent = true;
  bool microphoneEnabled = true;
  String answer = '';
  void install() {
    messenger.setMockStreamHandler(
      peer,
      MockStreamHandler.inline(onListen: (_, events) => peerEvents = events),
    );
    messenger.setMockStreamHandler(
      data,
      MockStreamHandler.inline(onListen: (_, events) => dataEvents = events),
    );
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return null;
        case 'createPeerConnection':
          return {'peerConnectionId': 'voice-peer'};
        case 'getUserMedia':
          return {
            'streamId': 'microphone',
            'audioTracks': [
              {
                'id': 'microphone-track',
                'label': 'microphone',
                'kind': 'audio',
                'enabled': true,
              },
            ],
            'videoTracks': [],
          };
        case 'addTrack':
          return {
            'senderId': 'sender',
            'track': <String, Object?>{},
            'rtpParameters': {
              'encodings': [],
              'headerExtensions': [],
              'codecs': [],
              'rtcp': {'cname': 'fixture', 'reducedSize': false},
            },
            'ownsTrack': false,
          };
        case 'createDataChannel':
          return {'id': 0, 'flutterId': 'control'};
        case 'createOffer':
        case 'getLocalDescription':
          return {'sdp': 'v=0\r\nfixture offer', 'type': 'offer'};
        case 'setLocalDescription':
          peerEvents.success({
            'event': 'iceGatheringState',
            'state': 'complete',
          });
          return null;
        case 'setRemoteDescription':
          answer =
              ((call.arguments as Map)['description'] as Map)['sdp'] as String;
          if (startedEvent)
            control({
              'type': 'session.started',
              'session': {'id': 'provider-session'},
            });
          return null;
        case 'mediaStreamTrackSetEnable':
          if ((call.arguments as Map)['trackId'] == 'microphone-track')
            microphoneEnabled = (call.arguments as Map)['enabled'] as bool;
          return null;
        case 'dataChannelClose':
        case 'trackDispose':
        case 'streamDispose':
        case 'peerConnectionClose':
        case 'peerConnectionDispose':
        case 'enableSpeakerphoneButPreferBluetooth':
          return null;
        default:
          throw StateError('Unexpected platform operation: ${call.method}');
      }
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(peer, null);
      messenger.setMockStreamHandler(data, null);
    });
  }

  void control(Map<String, Object?> event) => dataEvents.success({
    'event': 'dataChannelReceiveMessage',
    'id': 0,
    'type': 'text',
    'data': jsonEncode(event),
  });
  int count(String method) =>
      calls.where((call) => call.method == method).length;
}
