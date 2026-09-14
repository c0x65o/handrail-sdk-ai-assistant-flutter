import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'voice_playback_native.dart'
    if (dart.library.js_interop) 'voice_playback_web.dart' as platform;

abstract interface class VoicePlayback {
  /// Returns false when playback needs another user gesture.
  Future<bool> attach(MediaStreamTrack track);
  Future<bool> play();
  void stop();
}

VoicePlayback createVoicePlayback() => platform.createVoicePlayback();
