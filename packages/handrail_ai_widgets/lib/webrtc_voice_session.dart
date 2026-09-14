import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'realtime_voice.dart';
import 'realtime_voice_gateway.dart';

import 'src/voice_playback.dart';

/// WebRTC lifecycle for an authenticated, server-owned Handrail voice call.
///
/// The gateway supplies trusted admission/end receipts. Provider credentials and
/// business tools remain server-side; this SDK owns capture, playback, stable
/// call identity, cancellation, media events and teardown.
class HandrailWebRtcVoiceSession<T> implements HandrailRealtimeVoiceSession<T> {
  HandrailWebRtcVoiceSession({required this.gateway});

  final HandrailRealtimeVoiceGateway<T> gateway;

  final ValueNotifier<HandrailRealtimeVoiceState> _state =
      ValueNotifier<HandrailRealtimeVoiceState>(
    const HandrailRealtimeVoiceState.idle(),
  );

  HandrailRealtimeVoiceCancellation? _bootstrapCancellation;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _events;
  MediaStream? _localStream;
  int _generation = 0;
  bool _starting = false;
  bool _stopping = false;
  Future<void>? _stopOperation;
  Future<void>? _disposeOperation;
  bool _disposed = false;
  String? _sdkCallKey;
  String? _sdkConversationId;
  bool _sdkCallDispatched = false;
  bool _remoteEnded = false;
  String? _providerSessionId;
  Completer<void>? _startedEvent;
  final List<MediaStreamTrack> _remoteTracks = [];
  VoicePlayback? _playback;

  @override
  ValueListenable<HandrailRealtimeVoiceState> get state => _state;

  @override
  Future<void> start({
    required String conversationId,
    required T context,
  }) async {
    if (_disposed ||
        _disposeOperation != null ||
        _starting ||
        _stopping ||
        _peerConnection != null ||
        _sdkCallDispatched) {
      return;
    }
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(conversationId)) {
      _setState(
        const HandrailRealtimeVoiceState(
          phase: HandrailRealtimeVoicePhase.failed,
          message: 'Open a saved assistant conversation before starting voice.',
        ),
      );
      return;
    }
    final int generation = ++_generation;
    _starting = true;
    _startedEvent = Completer<void>();
    // Startup can end before the caller begins awaiting provider readiness.
    unawaited(_startedEvent!.future.catchError((Object _) {}));
    _stopping = false;
    _setState(
      const HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.connecting,
      ),
    );
    final HandrailRealtimeVoiceCancellation cancellation =
        HandrailRealtimeVoiceCancellation();
    _bootstrapCancellation = cancellation;
    try {
      final RTCPeerConnection peerConnection = await createPeerConnection(
        <String, Object?>{'sdpSemantics': 'unified-plan'},
      );
      if (!_isCurrent(generation)) {
        await peerConnection.dispose();
        return;
      }
      _peerConnection = peerConnection;
      peerConnection.onConnectionState = (state) {
        if (_isCurrent(generation)) _handleConnectionState(state);
      };
      peerConnection.onTrack = (RTCTrackEvent event) {
        if (!_isCurrent(generation)) {
          try {
            event.track.enabled = false;
          } on Object {
            // Still release the stale track below.
          }
          unawaited(event.track.stop().catchError((Object _) {}));
          return;
        }
        if (event.track.kind == 'audio') {
          _remoteTracks.add(event.track);
          event.track.enabled = true;
          _playback ??= createVoicePlayback();
          unawaited(_attachPlayback(event.track, generation));
        }
      };

      final MediaStream localStream = await navigator.mediaDevices.getUserMedia(
        <String, Object?>{
          'audio': <String, Object?>{
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        },
      );
      if (!_isCurrent(generation)) {
        await _stopStream(localStream);
        return;
      }
      _localStream = localStream;
      for (final MediaStreamTrack track in localStream.getAudioTracks()) {
        await peerConnection.addTrack(track, localStream);
      }

      final RTCDataChannel events = await peerConnection.createDataChannel(
        'oai-events',
        RTCDataChannelInit(),
      );
      if (!_isCurrent(generation)) {
        await events.close();
        return;
      }
      _events = events;
      events.onMessage = (message) {
        if (identical(_events, events)) _handleServerEvent(message);
      };
      events.onDataChannelState = (RTCDataChannelState channelState) {
        if (channelState == RTCDataChannelState.RTCDataChannelClosed &&
            _isCurrent(generation)) {
          unawaited(_fail('The voice control connection was interrupted.'));
        }
      };
      final iceComplete = Completer<void>();
      peerConnection.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !iceComplete.isCompleted) {
          iceComplete.complete();
        }
      };
      final RTCSessionDescription offer = await peerConnection.createOffer(
        <String, Object?>{'offerToReceiveAudio': true},
      );
      await peerConnection.setLocalDescription(offer);
      if (peerConnection.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await iceComplete.future.timeout(const Duration(seconds: 10));
      }
      final String? offerSdp =
          (await peerConnection.getLocalDescription())?.sdp;
      if (offerSdp == null || !_isCurrent(generation)) {
        throw const _RealtimeVoiceBootstrapFailure();
      }
      _sdkConversationId = conversationId;
      _sdkCallKey ??= _newCallKey();
      _sdkCallDispatched = true;
      final String answerSdp = await gateway.exchangeSdp(
        HandrailRealtimeVoiceBootstrap<T>(
          offerSdp: offerSdp,
          context: context,
          conversationId: conversationId,
          callId: _sdkCallKey!,
          cancellation: cancellation,
        ),
      );
      if (!_isCurrent(generation)) {
        return;
      }
      await peerConnection.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      await _startedEvent!.future.timeout(const Duration(seconds: 15));
      if (_isCurrent(generation)) _setReady();
    } on HandrailRealtimeVoiceFailure catch (error) {
      if (!_isCurrent(generation)) return;
      await _fail(error.message);
    } on Object {
      if (_isCurrent(generation)) {
        await _fail(
          'Realtime voice could not connect. Check microphone access and try again.',
        );
      }
    } finally {
      if (generation == _generation) {
        _starting = false;
        _bootstrapCancellation = null;
      }
    }
  }

  @override
  Future<void> toggleMuted() async {
    if (_disposed || _stopping) {
      return;
    }
    final MediaStream? stream = _localStream;
    if (stream == null) {
      return;
    }
    final bool muted = !_state.value.isMuted;
    for (final MediaStreamTrack track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
    _setState(
      HandrailRealtimeVoiceState(
        phase: _state.value.phase,
        isMuted: muted,
        playbackBlocked: _state.value.playbackBlocked,
        message: _state.value.message,
      ),
    );
  }

  @override
  Future<void> stop() {
    if (_disposed) return Future<void>.value();
    final running = _stopOperation;
    if (running != null) return running;
    final completion = Completer<void>();
    _stopOperation = completion.future;
    // _stop disables capture synchronously; register first so reentrant Stop,
    // backgrounding and disposal all await the same remote acknowledgement.
    unawaited(
      _stop().then(
        (_) {
          _stopOperation = null;
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          _stopOperation = null;
          _stopping = false;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  Future<void> _stop() async {
    _stopping = true;
    _starting = false;
    _generation += 1;
    _bootstrapCancellation?.cancel();
    _bootstrapCancellation = null;
    if (_sdkCallDispatched && !_remoteEnded) {
      _setState(
        const HandrailRealtimeVoiceState(
          phase: HandrailRealtimeVoicePhase.ending,
          message: 'Stopping microphone and ending the remote call…',
        ),
      );
    }
    _stopPlayback();
    // Disable microphone capture and playback immediately, but keep WebRTC and
    // its data channel alive while the trusted server drains session.closed.
    for (final track in [
      ...?_localStream?.getAudioTracks(),
      ..._remoteTracks,
    ]) {
      try {
        track.enabled = false;
      } on Object {
        /* Continue ending the session. */
      }
    }
    if (_startedEvent != null && !_startedEvent!.isCompleted) {
      _startedEvent!.completeError(const _RealtimeVoiceBootstrapFailure());
    }
    if (_sdkCallDispatched && !_remoteEnded) {
      try {
        _remoteEnded = await gateway.endCall(
          conversationId: _sdkConversationId!,
          callId: _sdkCallKey!,
        );
      } on Object {
        // Local audio is already released. An uncertain remote result remains
        // visible and uses this same call identity on the next end attempt.
      }
      await _releaseConnection();
      if (!_remoteEnded) {
        _setState(
          const HandrailRealtimeVoiceState(
            phase: HandrailRealtimeVoicePhase.endUnconfirmed,
            message:
                'Microphone stopped. The server has not confirmed the call ended. Retry ending the call.',
          ),
        );
        _stopping = false;
        return;
      }
    }
    await _releaseConnection();
    if (!_disposed) {
      _setState(
        const HandrailRealtimeVoiceState(
          phase: HandrailRealtimeVoicePhase.ended,
        ),
      );
    }
    _stopping = false;
  }

  @override
  Future<void> dispose() => _disposeOperation ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) {
      return;
    }
    await stop();
    _disposed = true;
    _state.dispose();
  }

  bool _isCurrent(int generation) =>
      !_disposed && !_stopping && generation == _generation;

  void _handleConnectionState(RTCPeerConnectionState connectionState) {
    if (_disposed || _stopping) {
      return;
    }
    switch (connectionState) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        unawaited(_fail('The realtime voice connection was interrupted.'));
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        if (_sdkCallDispatched) {
          unawaited(stop());
        } else {
          _setState(
            const HandrailRealtimeVoiceState(
              phase: HandrailRealtimeVoicePhase.ended,
            ),
          );
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        break;
    }
  }

  void _handleServerEvent(RTCDataChannelMessage message) {
    if (_disposed || message.isBinary) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(message.text);
    } on Object {
      return;
    }
    if (decoded is! Map<String, Object?> || decoded['type'] is! String) {
      return;
    }
    final String type = decoded['type']! as String;
    if (type == 'error') {
      unawaited(
        _fail('Realtime voice encountered an error. Please try again.'),
      );
      return;
    }
    if (type == 'session.started') {
      final session = decoded['session'];
      if (session is! Map<String, Object?> || session['id'] is! String) {
        unawaited(_fail('The voice session returned an invalid identity.'));
        return;
      }
      final id = session['id']! as String;
      if (_providerSessionId != null && _providerSessionId != id) {
        unawaited(_fail('The voice session changed unexpectedly.'));
        return;
      }
      _providerSessionId = id;
      if (_startedEvent != null && !_startedEvent!.isCompleted) {
        _startedEvent!.complete();
      }
      if (!_stopping) _setReady();
    } else if (type == 'session.closed') {
      final session = decoded['session'];
      if (session is! Map<String, Object?> ||
          session['id'] != _providerSessionId) {
        return;
      }
      // The host endpoint confirms durable finalization and saved call status.
      // A client event alone is not an authorization or usage receipt.
      if (!_stopping) unawaited(stop());
    }
  }

  Future<void> _attachPlayback(MediaStreamTrack track, int generation) async {
    bool played;
    try {
      played = await _playback!.attach(track);
    } on Object {
      played = false;
    }
    if (_isCurrent(generation) && !_stopping) _setPlaybackBlocked(!played);
  }

  @override
  Future<void> retryPlayback() async {
    if (_disposed || _stopping || _playback == null) return;
    final generation = _generation;
    final played = await _playback!.play();
    if (_isCurrent(generation) && !_stopping) _setPlaybackBlocked(!played);
  }

  void _setPlaybackBlocked(bool blocked) {
    _setState(
      HandrailRealtimeVoiceState(
        phase: _state.value.phase,
        isMuted: _state.value.isMuted,
        playbackBlocked: blocked,
        message: _state.value.message,
      ),
    );
  }

  void _setReady() {
    if (_providerSessionId == null || _stopping) return;
    final HandrailRealtimeVoicePhase phase = _state.value.phase;
    if (phase == HandrailRealtimeVoicePhase.connecting ||
        phase == HandrailRealtimeVoicePhase.idle) {
      _setPhase(HandrailRealtimeVoicePhase.listening);
    }
  }

  void _setPhase(HandrailRealtimeVoicePhase phase) {
    _setState(
      HandrailRealtimeVoiceState(
        phase: phase,
        isMuted: _state.value.isMuted,
        playbackBlocked: _state.value.playbackBlocked,
      ),
    );
  }

  Future<void> _fail(String message) async {
    if (_sdkCallDispatched) {
      await stop();
      if (_remoteEnded) {
        _setState(
          HandrailRealtimeVoiceState(
            phase: HandrailRealtimeVoicePhase.ended,
            message:
                '$message The call ended. Close voice to start a new call.',
          ),
        );
      }
      return;
    }
    await _releaseConnection();
    _setState(
      HandrailRealtimeVoiceState(
        phase: HandrailRealtimeVoicePhase.failed,
        message: message,
      ),
    );
  }

  void _stopPlayback() {
    try {
      _playback?.stop();
    } on Object {
      // Always disable tracks and release capture even if output teardown fails.
    }
  }

  Future<void> _releaseConnection() async {
    final RTCDataChannel? events = _events;
    final MediaStream? localStream = _localStream;
    final RTCPeerConnection? peerConnection = _peerConnection;
    _events = null;
    _localStream = null;
    _peerConnection = null;
    final remoteTracks = List<MediaStreamTrack>.of(_remoteTracks);
    _remoteTracks.clear();
    _stopPlayback();
    _playback = null;
    // Disable capture before awaiting platform channel/peer teardown.
    for (final track in [...?localStream?.getAudioTracks(), ...remoteTracks]) {
      try {
        track.enabled = false;
      } on Object {
        // Still attempt the underlying track stop below.
      }
    }
    try {
      await events?.close();
    } on Object {
      // Teardown remains best-effort and never retains provider details.
    }
    if (localStream != null) {
      await _stopStream(localStream);
    }
    for (final track in remoteTracks) {
      try {
        await track.stop();
      } on Object {
        // Continue releasing other tracks and the peer.
      }
    }
    try {
      await peerConnection?.close();
      await peerConnection?.dispose();
    } on Object {
      // Teardown remains best-effort and never retains provider details.
    }
  }

  static Future<void> _stopStream(MediaStream stream) async {
    final tracks = stream.getTracks();
    for (final track in tracks) {
      try {
        track.enabled = false;
      } on Object {
        // Still stop the underlying capture below.
      }
    }
    for (final MediaStreamTrack track in tracks) {
      try {
        await track.stop();
      } on Object {
        // Continue releasing the remaining tracks.
      }
    }
    try {
      await stream.dispose();
    } on Object {
      // Stream may already be disposed by the platform.
    }
  }

  void _setState(HandrailRealtimeVoiceState next) {
    if (!_disposed) {
      _state.value = next;
    }
  }
}

String _newCallKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final class _RealtimeVoiceBootstrapFailure implements Exception {
  const _RealtimeVoiceBootstrapFailure();
}
