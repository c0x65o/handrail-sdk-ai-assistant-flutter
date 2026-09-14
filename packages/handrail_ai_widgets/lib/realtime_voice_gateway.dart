import 'package:flutter/foundation.dart';

/// Trusted, authenticated voice admission and durable end acknowledgement.
///
/// Implementations validate current identity/permissions, send the exact call ID
/// as the idempotency key, enforce timeouts and bind the end receipt to this
/// conversation/call. An accepted end request is not necessarily a confirmed end.
abstract interface class HandrailRealtimeVoiceGateway<T> {
  Future<String> exchangeSdp(HandrailRealtimeVoiceBootstrap<T> request);
  Future<bool> endCall(
      {required String conversationId, required String callId});
}

@immutable
final class HandrailRealtimeVoiceBootstrap<T> {
  const HandrailRealtimeVoiceBootstrap({
    required this.conversationId,
    required this.callId,
    required this.offerSdp,
    required this.context,
    required this.cancellation,
    this.timeout = const Duration(seconds: 30),
  });

  final String conversationId;
  final String callId;
  final String offerSdp;
  final T context;
  final HandrailRealtimeVoiceCancellation cancellation;
  final Duration timeout;
}

/// Synchronous cancellation bridge; remote termination still uses [endCall].
/// Cancellation of the local HTTP wait never proves that admission failed.
final class HandrailRealtimeVoiceCancellation {
  final _listeners = <VoidCallback>{};
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Returns an unlink callback; call it when the protected request settles.
  VoidCallback onCancel(VoidCallback listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<VoidCallback>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener();
      } on Object {
        // A failed host listener must not prevent the remaining media teardown.
      }
    }
  }
}

enum HandrailRealtimeVoiceFailureKind {
  unavailable,
  unsupported,
  alreadyStarted,
  authentication,
  busy,
  offline,
  timeout,
}

/// Bounded UI failure. Host/provider response bodies never become voice messages.
final class HandrailRealtimeVoiceFailure implements Exception {
  const HandrailRealtimeVoiceFailure(this.kind);
  final HandrailRealtimeVoiceFailureKind kind;

  String get message => switch (kind) {
        HandrailRealtimeVoiceFailureKind.unsupported =>
          'SDK voice is not available on this server yet.',
        HandrailRealtimeVoiceFailureKind.alreadyStarted =>
          'This voice call was already started. Close voice and check the saved conversation before starting another call.',
        HandrailRealtimeVoiceFailureKind.authentication =>
          'Sign in again to use realtime voice.',
        HandrailRealtimeVoiceFailureKind.busy =>
          'Realtime voice is busy right now. Please try again shortly.',
        HandrailRealtimeVoiceFailureKind.offline =>
          'Connect to the internet to use realtime voice.',
        HandrailRealtimeVoiceFailureKind.timeout =>
          'Realtime voice took too long to connect. Please try again.',
        HandrailRealtimeVoiceFailureKind.unavailable =>
          'Realtime voice is unavailable right now. Please try again.',
      };
}
