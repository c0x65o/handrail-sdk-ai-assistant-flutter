part of '../handrail_ai_client.dart';

enum HandrailRealtimeCallStatus {
  admitted,
  starting,
  active,
  ending,
  ended,
  uncertain
}

/// Public server projection. Never contains a provider call reference or SDP.
class HandrailRealtimeCall {
  final String callId;
  final String conversationId;
  final HandrailRealtimeCallStatus status;
  const HandrailRealtimeCall(
      {required this.callId,
      required this.conversationId,
      required this.status});
  bool get needsTermination => status != HandrailRealtimeCallStatus.ended;
  factory HandrailRealtimeCall.fromJson(Object? value) {
    if (value is! Map ||
        value['callId'] is! String ||
        value['conversationId'] is! String ||
        (value['callId'] as String).isEmpty ||
        (value['conversationId'] as String).isEmpty) {
      throw const FormatException('Invalid realtime call identity.');
    }
    final statuses = HandrailRealtimeCallStatus.values
        .where((status) => status.name == value['status']);
    if (statuses.length != 1) {
      throw const FormatException('Invalid realtime call status.');
    }
    return HandrailRealtimeCall(
        callId: value['callId'] as String,
        conversationId: value['conversationId'] as String,
        status: statuses.single);
  }
}

class HandrailRealtimeCallPage {
  final List<HandrailRealtimeCall> calls;
  final String? nextCallId;
  HandrailRealtimeCallPage(
      {required Iterable<HandrailRealtimeCall> calls, this.nextCallId})
      : calls = List.unmodifiable(calls);
  factory HandrailRealtimeCallPage.fromJson(Object? value) {
    if (value is! Map ||
        value['calls'] is! List ||
        !value.containsKey('nextCallId') ||
        (value['nextCallId'] != null &&
            (value['nextCallId'] is! String ||
                (value['nextCallId'] as String).isEmpty))) {
      throw const FormatException('Invalid realtime call page.');
    }
    return HandrailRealtimeCallPage(
        calls: (value['calls'] as List).map(HandrailRealtimeCall.fromJson),
        nextCallId: value['nextCallId'] as String?);
  }
}

class HandrailRealtimeCallState {
  final List<HandrailRealtimeCall> calls;
  final Set<String> endingCallIds;
  final bool loading;
  final bool synchronized;

  /// Safe SDK summary. Transport errors and provider details are not exposed.
  final String? error;
  HandrailRealtimeCallState(
      {Iterable<HandrailRealtimeCall> calls = const [],
      Set<String> endingCallIds = const {},
      this.loading = false,
      this.synchronized = false,
      this.error})
      : calls = List.unmodifiable(calls),
        endingCallIds = Set.unmodifiable(endingCallIds);
  List<HandrailRealtimeCall> get unfinished =>
      List.unmodifiable(calls.where((call) => call.needsTermination));
  bool get canStartCall =>
      synchronized &&
      !loading &&
      error == null &&
      endingCallIds.isEmpty &&
      unfinished.isEmpty;
}

/// Owns observation of one authenticated conversation. Hosts supply protected
/// transport and dispose this monitor on account/conversation changes. A failed
/// or incomplete read never clears retained call state or authorizes a new call.
class HandrailRealtimeCallMonitor {
  final String conversationId;
  final Future<HandrailRealtimeCallPage> Function(String? afterCallId) readPage;
  final Future<HandrailRealtimeCall> Function(String callId) requestEnd;
  final Duration pollInterval;
  final int maxPages;
  final _changes =
      StreamController<HandrailRealtimeCallState>.broadcast(sync: true);
  final _ending = <String, Future<void>>{};
  HandrailRealtimeCallState _state = HandrailRealtimeCallState();
  Future<void>? _reading;
  Timer? _poll;
  bool _disposed = false;
  int _revision = 0;
  HandrailRealtimeCallMonitor(
      {required this.conversationId,
      required this.readPage,
      required this.requestEnd,
      this.pollInterval = const Duration(seconds: 3),
      this.maxPages = 100}) {
    if (conversationId.isEmpty ||
        pollInterval < const Duration(milliseconds: 250) ||
        maxPages < 1 ||
        maxPages > 100) {
      throw ArgumentError('Invalid realtime observation bounds.');
    }
  }
  HandrailRealtimeCallState get state => _state;
  Stream<HandrailRealtimeCallState> get changes => _changes.stream;
  void _emit(
      {Iterable<HandrailRealtimeCall>? calls,
      bool? loading,
      bool? synchronized,
      String? error}) {
    if (_disposed) return;
    _state = HandrailRealtimeCallState(
        calls: calls ?? _state.calls,
        endingCallIds: _ending.keys.toSet(),
        loading: loading ?? _state.loading,
        synchronized: synchronized ?? _state.synchronized,
        error: error);
    _changes.add(_state);
  }

  void startPolling() {
    if (_disposed || _poll != null) return;
    _poll = Timer.periodic(pollInterval, (_) {
      unawaited(refresh());
    });
    unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    final pending = _reading;
    if (pending != null) return pending;
    final revision = _revision;
    // Assign before running callbacks, so synchronous observers cannot start a
    // second read while this one is being initialized.
    final operation = Future<void>.microtask(() async {
      _emit(loading: true, error: _state.error);
      final calls = <String, HandrailRealtimeCall>{};
      final retainedCalls = {
        for (final call in _state.calls) call.callId: call
      };
      final cursors = <String>{};
      String? after;
      try {
        for (var pageNumber = 0; pageNumber < maxPages; pageNumber++) {
          final page = await readPage(after);
          if (_disposed || revision != _revision) return;
          if (page.calls.length > 100) {
            throw const FormatException('Realtime call page is too large.');
          }
          for (final call in page.calls) {
            if (call.conversationId != conversationId ||
                call.callId.isEmpty ||
                calls.containsKey(call.callId)) {
              throw const FormatException(
                  'Realtime call page contains conflicting identities.');
            }
            final retained = retainedCalls[call.callId];
            calls[call.callId] = retained != null &&
                    _progress(retained.status) > _progress(call.status)
                ? retained
                : call;
          }
          if (page.nextCallId == null) {
            // Omission is not termination evidence (for example, a replica
            // behind the previous read or a retention change).
            for (final retained in _state.calls) {
              calls.putIfAbsent(retained.callId, () => retained);
            }
            if (calls.length > maxPages * 100) {
              throw const FormatException(
                  'Realtime recovery exceeded its retained record limit.');
            }
            _emit(calls: calls.values, synchronized: true);
            return;
          }
          if (page.nextCallId!.isEmpty ||
              !cursors.add(page.nextCallId!) ||
              page.calls.isEmpty) {
            throw const FormatException('Realtime pagination did not advance.');
          }
          after = page.nextCallId;
        }
        throw const FormatException(
            'Realtime call recovery exceeded its page limit.');
      } catch (_) {
        if (revision == _revision) {
          _emit(
              synchronized: false,
              error:
                  'Could not verify saved voice calls. Retry before starting another call.');
        }
      } finally {
        _reading = null;
        _emit(loading: false, error: _state.error);
      }
    });
    _reading = operation;
    return operation;
  }

  Future<void> end(String callId) {
    if (_disposed) return Future.value();
    final pending = _ending[callId];
    if (pending != null) return pending;
    if (!_state.calls.any((call) => call.callId == callId)) {
      throw ArgumentError(
          'Unknown realtime call. Refresh its conversation first.');
    }
    if (_state.calls.any((call) =>
        call.callId == callId &&
        call.status == HandrailRealtimeCallStatus.ended)) {
      return Future.value();
    }
    _revision++;
    final operation = Future<void>.microtask(() async {
      _emit(error: null);
      try {
        final call = await requestEnd(callId);
        if (_disposed) return;
        _revision++;
        if (call.callId != callId ||
            call.conversationId != conversationId ||
            ![
              HandrailRealtimeCallStatus.ending,
              HandrailRealtimeCallStatus.ended
            ].contains(call.status)) {
          throw const FormatException(
              'Invalid realtime termination acknowledgement.');
        }
        _emit(
            calls: _state.calls
                .map((saved) => saved.callId == callId ? call : saved));
      } catch (_) {
        _revision++;
        _emit(
            synchronized: false,
            error:
                'Voice termination is not confirmed. Retry ending the saved call.');
      } finally {
        _ending.remove(callId);
        _emit(error: _state.error);
      }
    });
    _ending[callId] = operation;
    return operation;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _poll?.cancel();
    await _changes.close();
  }

  static int _progress(HandrailRealtimeCallStatus status) => switch (status) {
        HandrailRealtimeCallStatus.admitted => 0,
        HandrailRealtimeCallStatus.starting => 1,
        HandrailRealtimeCallStatus.active => 2,
        HandrailRealtimeCallStatus.uncertain => 3,
        HandrailRealtimeCallStatus.ending => 4,
        HandrailRealtimeCallStatus.ended => 5,
      };
}
