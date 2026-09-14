import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'voice_playback.dart';

VoicePlayback createVoicePlayback() => _NativeVoicePlayback();

final class _NativeVoicePlayback implements VoicePlayback {
  @override
  Future<bool> attach(MediaStreamTrack track) => play();

  @override
  Future<bool> play() async {
    try {
      await Helper.setSpeakerphoneOnButPreferBluetooth();
      return true;
    } on Object {
      return false;
    }
  }

  // Native WebRTC renders audio directly. The session disables remote tracks
  // before awaiting close; it owns their teardown.
  @override
  void stop() {}
}
