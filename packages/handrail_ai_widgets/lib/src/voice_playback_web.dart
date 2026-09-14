import 'dart:js_interop';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

import 'voice_playback.dart';

VoicePlayback createVoicePlayback() => _WebVoicePlayback();

final class _WebVoicePlayback implements VoicePlayback {
  final web.HTMLAudioElement _audio = web.HTMLAudioElement();
  final web.MediaStream _stream = web.MediaStream();
  bool _stopped = false;

  @override
  Future<bool> attach(MediaStreamTrack track) async {
    if (_stopped) return false;
    final nativeTrack = (track as MediaStreamTrackWeb).jsTrack;
    if (!_stream.getTracks().toDart.any((item) => item.id == nativeTrack.id)) {
      _stream.addTrack(nativeTrack);
    }
    _audio.srcObject = _stream;
    _audio.setAttribute('aria-hidden', 'true');
    _audio.style.display = 'none';
    if (!_audio.isConnected) web.document.body?.append(_audio);
    return play();
  }

  @override
  Future<bool> play() async {
    if (_stopped) return false;
    try {
      await _audio.play().toDart;
      return !_stopped;
    } on Object {
      return false;
    }
  }

  @override
  void stop() {
    _stopped = true;
    _audio.pause();
    _audio.srcObject = null;
    _audio.remove();
  }
}
