import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

enum HandrailRealtimeVoicePhase {
  idle,
  connecting,
  listening,
  speaking,
  failed,
  ending,
  endUnconfirmed,
  ended,
}

@immutable
final class HandrailRealtimeVoiceState {
  const HandrailRealtimeVoiceState({
    required this.phase,
    this.isMuted = false,
    this.playbackBlocked = false,
    this.message,
  });

  const HandrailRealtimeVoiceState.idle()
      : phase = HandrailRealtimeVoicePhase.idle,
        isMuted = false,
        playbackBlocked = false,
        message = null;

  final HandrailRealtimeVoicePhase phase;
  final bool isMuted;
  final bool playbackBlocked;
  final String? message;
}

/// A trusted native media adapter. The caller owns and disposes the session.
///
/// [stop] must disable local capture/playback before its first asynchronous wait,
/// cancel pending startup, and retain the same remote call identity on retries.
/// Only a durable host acknowledgement may set `ended`; a disconnected peer or
/// unknown result must remain `endUnconfirmed`. Concurrent stops must join the
/// same operation. Disposal must also stop capture and cancel late startup.
abstract interface class HandrailRealtimeVoiceSession<T> {
  ValueListenable<HandrailRealtimeVoiceState> get state;
  Future<void> start({required String conversationId, required T context});
  Future<void> toggleMuted();
  Future<void> retryPlayback();
  Future<void> stop();
  Future<void> dispose();
}

@immutable
final class HandrailRealtimeVoiceStartOption<T> {
  const HandrailRealtimeVoiceStartOption({
    required this.label,
    required this.context,
    this.key,
  });

  final String label;
  final T context;
  final Key? key;
}

/// Standard voice controls with host identity choices and business review slots.
///
/// Branding comes from Theme. Content slots cannot replace Stop, playback,
/// microphone or uncertain-end recovery controls. [beforeStart] can refresh saved
/// calls/permissions; late results are discarded after close/background or scope
/// replacement. The host must also enforce authorization at media admission.
/// Backgrounding stops the session and keeps its final/uncertain status visible;
/// returning to the app never starts the microphone automatically.
/// Temporary focus loss (including a microphone permission dialog) is not
/// backgrounding. Hidden, paused and detached states stop the session.
class HandrailRealtimeVoiceSurface<T> extends StatefulWidget {
  const HandrailRealtimeVoiceSurface({
    super.key,
    required this.session,
    required this.conversationId,
    required this.startOptions,
    this.title = 'Voice',
    this.idleLabel = 'Ready for voice',
    this.canStart = true,
    this.beforeStart,
    this.onStarting,
    this.onClosingChanged,
    this.introduction,
    this.contentBuilder,
    this.scrollController,
    this.viewportKey,
  });

  final HandrailRealtimeVoiceSession<T> session;
  final String conversationId;
  final List<HandrailRealtimeVoiceStartOption<T>> startOptions;
  final String title;
  final String idleLabel;
  final bool canStart;
  final Future<bool> Function(T context)? beforeStart;
  final void Function(T context)? onStarting;
  final ValueChanged<bool>? onClosingChanged;
  final Widget? introduction;
  final Widget Function(BuildContext, HandrailRealtimeVoiceState, bool closing)?
      contentBuilder;
  final ScrollController? scrollController;
  final Key? viewportKey;

  @override
  State<HandrailRealtimeVoiceSurface<T>> createState() =>
      _HandrailRealtimeVoiceSurfaceState<T>();
}

class _HandrailRealtimeVoiceSurfaceState<T>
    extends State<HandrailRealtimeVoiceSurface<T>> with WidgetsBindingObserver {
  bool _starting = false;
  bool _closing = false;
  bool _allowClose = false;
  bool _controlBusy = false;
  bool _foreground = true;
  int _generation = 0;
  String? _error;
  HandrailRealtimeVoiceStartOption<T>? _lastOption;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = !_isBackground(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didUpdateWidget(covariant HandrailRealtimeVoiceSurface<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        oldWidget.conversationId != widget.conversationId) {
      _generation++;
      _starting = _closing = _allowClose = _controlBusy = false;
      _lastOption = null;
      _error = null;
      // This surface cannot carry an active microphone into another scope.
      unawaited(oldWidget.session.stop().catchError((Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = !_isBackground(state);
    if (wasForeground && !_foreground) {
      unawaited(_close(leave: false));
    } else if (mounted) {
      setState(() {});
    }
  }

  bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    // Caller disposal owns resource cleanup; invalidate all delayed UI work.
    super.dispose();
  }

  Future<void> _start(HandrailRealtimeVoiceStartOption<T> option) async {
    if (_starting || _closing || !_foreground || !widget.canStart) return;
    final phase = widget.session.state.value.phase;
    if (phase != HandrailRealtimeVoicePhase.idle &&
        phase != HandrailRealtimeVoicePhase.failed) return;
    final generation = ++_generation;
    setState(() {
      _starting = true;
      _error = null;
      _lastOption = option;
    });
    bool current() => mounted && generation == _generation;
    try {
      if (await widget.beforeStart?.call(option.context) == false) return;
      // Preflight can update the host's canStart input. Read it only after the
      // parent has rendered that result, not from its previous loading frame.
      await WidgetsBinding.instance.endOfFrame;
      if (!current() || _closing || !_foreground || !widget.canStart) return;
      final phase = widget.session.state.value.phase;
      if (phase != HandrailRealtimeVoicePhase.idle &&
          phase != HandrailRealtimeVoicePhase.failed) return;
      widget.onStarting?.call(option.context);
      if (!current() || _closing || !_foreground || !widget.canStart) return;
      await widget.session.start(
        conversationId: widget.conversationId,
        context: option.context,
      );
    } on Object {
      if (current()) {
        setState(
            () => _error = 'Voice could not start. Check access and retry.');
      }
    } finally {
      if (current()) setState(() => _starting = false);
    }
  }

  Future<void> _close({bool leave = true}) async {
    if (_closing || _allowClose) return;
    final generation = ++_generation;
    setState(() {
      _closing = true;
      _starting = false;
      _controlBusy = false;
      _error = null;
    });
    widget.onClosingChanged?.call(true);
    try {
      await widget.session.stop();
      if (!mounted || generation != _generation) return;
      if (widget.session.state.value.phase ==
          HandrailRealtimeVoicePhase.ended) {
        if (leave) await _leave();
      } else {
        setState(() => _error = 'The server has not confirmed the call ended.');
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(() =>
            _error = 'Could not confirm the call ended. Retry ending it.');
      }
    } finally {
      if (mounted && generation == _generation && !_allowClose) {
        setState(() => _closing = false);
        widget.onClosingChanged?.call(false);
      }
    }
  }

  Future<void> _leave() async {
    setState(() => _allowClose = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _control(Future<void> Function() action) async {
    if (_controlBusy || _closing || !_foreground) return;
    final generation = _generation;
    setState(() => _controlBusy = true);
    try {
      await action();
    } on Object {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Voice control failed. Try again.');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _controlBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope<Object?>(
      canPop: _allowClose,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ValueListenableBuilder<HandrailRealtimeVoiceState>(
            valueListenable: widget.session.state,
            builder: (context, voice, _) {
              final idle = voice.phase == HandrailRealtimeVoicePhase.idle;
              final failed = voice.phase == HandrailRealtimeVoicePhase.failed;
              final active =
                  voice.phase == HandrailRealtimeVoicePhase.listening ||
                      voice.phase == HandrailRealtimeVoicePhase.speaking;
              final uncertain =
                  voice.phase == HandrailRealtimeVoicePhase.endUnconfirmed;
              final label = switch (voice.phase) {
                HandrailRealtimeVoicePhase.idle =>
                  _starting ? 'Preparing voice…' : widget.idleLabel,
                HandrailRealtimeVoicePhase.connecting => 'Connecting…',
                HandrailRealtimeVoicePhase.listening =>
                  voice.isMuted ? 'Microphone muted' : 'Listening',
                HandrailRealtimeVoicePhase.speaking => 'Speaking',
                HandrailRealtimeVoicePhase.failed => 'Voice is unavailable',
                HandrailRealtimeVoicePhase.ending => 'Ending voice…',
                HandrailRealtimeVoicePhase.endUnconfirmed =>
                  'End not confirmed',
                HandrailRealtimeVoicePhase.ended => 'Voice ended',
              };
              final canStart =
                  widget.canStart && !_starting && !_closing && _foreground;
              final canControl =
                  active && !_closing && !_controlBusy && _foreground;
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                  child: Row(children: [
                    IconButton.filledTonal(
                      key: const ValueKey('handrail-realtime-close'),
                      tooltip: 'Close realtime voice',
                      onPressed: _closing ? null : () => _close(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                    Expanded(
                        child: Text(widget.title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleLarge)),
                    const SizedBox(width: 48),
                  ]),
                ),
                Expanded(
                    child: SingleChildScrollView(
                  key: widget.viewportKey,
                  controller: widget.scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: failed
                              ? colors.errorContainer
                              : colors.primaryContainer),
                      child: Padding(
                          padding: const EdgeInsets.all(42),
                          child: Icon(
                            voice.phase == HandrailRealtimeVoicePhase.connecting
                                ? Icons.more_horiz_rounded
                                : Icons.graphic_eq_rounded,
                            color: failed
                                ? colors.onErrorContainer
                                : colors.onPrimaryContainer,
                            size: 72,
                          )),
                    ),
                    const SizedBox(height: 24),
                    Semantics(
                        liveRegion: true,
                        child: Text(label,
                            key: const ValueKey('handrail-realtime-status'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall)),
                    if (voice.message case final message?)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(message, textAlign: TextAlign.center)),
                    if (_error case final error?)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                              liveRegion: true,
                              child: Text(error,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: colors.error)))),
                    if (widget.contentBuilder case final builder?)
                      builder(context, voice, _closing),
                    if (idle) ...[
                      if (widget.introduction case final introduction?)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: introduction),
                      for (final option in widget.startOptions)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: FilledButton(
                                key: option.key,
                                onPressed:
                                    canStart ? () => _start(option) : null,
                                child: Text(option.label))),
                    ],
                    if (uncertain || (_error != null && !idle && !failed))
                      FilledButton(
                          key: const ValueKey('handrail-realtime-retry-end'),
                          onPressed: _closing ? null : () => _close(),
                          child: const Text('Retry ending call')),
                    if (uncertain)
                      TextButton(
                          key: const ValueKey(
                              'handrail-realtime-leave-unconfirmed'),
                          onPressed: _closing ? null : _leave,
                          child:
                              const Text('Close view — end still unconfirmed')),
                    if (voice.playbackBlocked && active)
                      TextButton.icon(
                          key: const ValueKey('handrail-realtime-playback'),
                          onPressed: canControl
                              ? () => _control(widget.session.retryPlayback)
                              : null,
                          icon: const Icon(Icons.volume_up_rounded),
                          label: const Text('Enable voice playback')),
                    if (failed && _lastOption != null)
                      FilledButton(
                          key: const ValueKey('handrail-realtime-retry'),
                          onPressed:
                              canStart ? () => _start(_lastOption!) : null,
                          child: const Text('Try again')),
                  ]),
                )),
                Padding(
                    padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton.filledTonal(
                              key: const ValueKey('handrail-realtime-mute'),
                              tooltip: voice.isMuted
                                  ? 'Unmute microphone'
                                  : 'Mute microphone',
                              onPressed: canControl
                                  ? () => _control(widget.session.toggleMuted)
                                  : null,
                              style: IconButton.styleFrom(
                                  fixedSize: const Size.square(62)),
                              icon: Icon(voice.isMuted
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_rounded)),
                          const SizedBox(width: 22),
                          IconButton.filled(
                              key: const ValueKey('handrail-realtime-end'),
                              tooltip: 'End voice chat',
                              onPressed: _closing ? null : () => _close(),
                              style: IconButton.styleFrom(
                                  fixedSize: const Size.square(62),
                                  foregroundColor: colors.onError,
                                  backgroundColor: colors.error),
                              icon: const Icon(Icons.call_end_rounded)),
                        ])),
              ]);
            },
          ),
        ),
      ),
    );
  }
}
