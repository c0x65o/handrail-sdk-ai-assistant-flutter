part of '../handrail_ai_client.dart';

class HandrailRealtimeWorkspaceCursor {
  final String conversationId, callId;
  const HandrailRealtimeWorkspaceCursor(
      {required this.conversationId, required this.callId});
  factory HandrailRealtimeWorkspaceCursor.fromJson(Object? value) {
    if (value is! Map ||
        value['conversationId'] is! String ||
        value['callId'] is! String ||
        (value['conversationId'] as String).isEmpty ||
        (value['callId'] as String).isEmpty) {
      throw const FormatException('Invalid voice workspace cursor.');
    }
    return HandrailRealtimeWorkspaceCursor(
        conversationId: value['conversationId'] as String,
        callId: value['callId'] as String);
  }
  String get _key => jsonEncode([conversationId, callId]);
}

class HandrailRealtimeWorkspaceCall {
  final HandrailRealtimeCall call;
  final HandrailRealtimeToolCounts counts;
  final bool unread;
  const HandrailRealtimeWorkspaceCall(
      {required this.call, required this.counts, required this.unread});
  factory HandrailRealtimeWorkspaceCall.fromJson(Object? value) {
    if (value is! Map || value['unread'] is! bool) {
      throw const FormatException('Invalid voice workspace activity.');
    }
    final call = HandrailRealtimeCall.fromJson(value);
    if (value['unread'] == true &&
        call.status != HandrailRealtimeCallStatus.ended) {
      throw const FormatException(
          'Unfinished voice calls cannot have completion receipts.');
    }
    return HandrailRealtimeWorkspaceCall(
        call: call,
        counts: HandrailRealtimeToolCounts.fromJson(value['counts']),
        unread: value['unread'] as bool);
  }
  HandrailRealtimeWorkspaceCursor get cursor => HandrailRealtimeWorkspaceCursor(
      conversationId: call.conversationId, callId: call.callId);
}

class HandrailRealtimeWorkspacePage {
  final List<HandrailRealtimeWorkspaceCall> calls;
  final HandrailRealtimeWorkspaceCursor? next;
  HandrailRealtimeWorkspacePage(
      {required Iterable<HandrailRealtimeWorkspaceCall> calls, this.next})
      : calls = List.unmodifiable(calls);
  factory HandrailRealtimeWorkspacePage.fromJson(Object? value) {
    if (value is! Map ||
        value['calls'] is! List ||
        !value.containsKey('next')) {
      throw const FormatException('Invalid voice workspace page.');
    }
    return HandrailRealtimeWorkspacePage(
        calls: (value['calls'] as List)
            .map(HandrailRealtimeWorkspaceCall.fromJson),
        next: value['next'] == null
            ? null
            : HandrailRealtimeWorkspaceCursor.fromJson(value['next']));
  }
}

/// Independent from the text turn: selecting a thread never acknowledges voice.
class HandrailRealtimeConversationSummary {
  final int activeCalls, unconfirmedCalls, unreadCalls, unresolvedTools;
  const HandrailRealtimeConversationSummary(
      {this.activeCalls = 0,
      this.unconfirmedCalls = 0,
      this.unreadCalls = 0,
      this.unresolvedTools = 0});
}

class HandrailRealtimeWorkspaceState {
  final List<HandrailRealtimeWorkspaceCall> calls;
  final bool loading, synchronized;
  final String? error;
  HandrailRealtimeWorkspaceState(
      {Iterable<HandrailRealtimeWorkspaceCall> calls = const [],
      this.loading = false,
      this.synchronized = false,
      this.error})
      : calls = List.unmodifiable(calls);
  HandrailRealtimeConversationSummary forConversation(String id) {
    var active = 0, unconfirmed = 0, unread = 0, unresolved = 0;
    for (final value
        in calls.where((value) => value.call.conversationId == id)) {
      final status = value.call.status;
      final running = const [
        HandrailRealtimeCallStatus.admitted,
        HandrailRealtimeCallStatus.starting,
        HandrailRealtimeCallStatus.active
      ].contains(status);
      if (running) active++;
      if (status == HandrailRealtimeCallStatus.ending ||
          status == HandrailRealtimeCallStatus.uncertain) {
        unconfirmed++;
      }
      if (value.unread) unread++;
      if (!running) unresolved += value.counts.running;
    }
    return HandrailRealtimeConversationSummary(
        activeCalls: active,
        unconfirmedCalls: unconfirmed,
        unreadCalls: unread,
        unresolvedTools: unresolved);
  }
}

/// Serialized, bounded observation of host-authorized voice activity. Whole-page
/// failures retain evidence. No provider operations, text-state edits or read acks.
class HandrailRealtimeWorkspaceMonitor {
  final Future<HandrailRealtimeWorkspacePage> Function(
          List<String> conversationIds, HandrailRealtimeWorkspaceCursor? after)
      readPage;
  final Duration pollingInterval;
  final int maxPages;
  final _changes =
      StreamController<HandrailRealtimeWorkspaceState>.broadcast(sync: true);
  HandrailRealtimeWorkspaceState _state = HandrailRealtimeWorkspaceState();
  List<String> _ids = const [];
  Future<void>? _reading;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  HandrailRealtimeWorkspaceMonitor(
      {required this.readPage,
      this.pollingInterval = const Duration(seconds: 3),
      this.maxPages = 100}) {
    if (pollingInterval < const Duration(milliseconds: 250) ||
        maxPages < 1 ||
        maxPages > 1000) {
      throw ArgumentError('Invalid voice workspace polling limits.');
    }
  }
  HandrailRealtimeWorkspaceState get state => _state;
  Stream<HandrailRealtimeWorkspaceState> get changes => _changes.stream;
  void _emit(HandrailRealtimeWorkspaceState state) {
    if (_disposed) return;
    _state = state;
    _changes.add(state);
  }

  Future<void> setConversations(Iterable<String> ids) async {
    if (_disposed) return;
    final next = ids.toSet().toList()..sort();
    if (next.length > 10000 ||
        next.any((id) => id.isEmpty || id.length > 512)) {
      throw ArgumentError('Invalid voice workspace conversations.');
    }
    if (jsonEncode(next) == jsonEncode(_ids)) return refresh();
    _generation++;
    _ids = List.unmodifiable(next);
    _emit(HandrailRealtimeWorkspaceState(
        calls: _state.calls
            .where((call) => next.contains(call.call.conversationId)),
        synchronized: next.isEmpty));
    await _reading;
    if (!_disposed) await refresh();
  }

  void startPolling() {
    if (_disposed || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(pollingInterval, (_) => unawaited(refresh()));
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_reading != null) return _reading!;
    final generation = _generation, ids = _ids;
    final operation = Future<void>.microtask(() async {
      if (_disposed || generation != _generation) return;
      final before = _state;
      _emit(HandrailRealtimeWorkspaceState(
          calls: before.calls,
          loading: true,
          synchronized: before.synchronized,
          error: before.error));
      try {
        final calls = <String, HandrailRealtimeWorkspaceCall>{};
        var pages = 0;
        for (var offset = 0; offset < ids.length; offset += 100) {
          final chunk = List<String>.unmodifiable(ids.skip(offset).take(100));
          HandrailRealtimeWorkspaceCursor? after;
          final cursors = <String>{};
          do {
            if (++pages > maxPages) {
              throw const FormatException(
                  'Voice workspace page limit reached.');
            }
            final page = await readPage(chunk, after);
            if (_disposed || generation != _generation) return;
            if (page.calls.length > 50) {
              throw const FormatException('Voice workspace page is too large.');
            }
            for (final value in page.calls) {
              if (!chunk.contains(value.call.conversationId) ||
                  calls.containsKey(value.cursor._key)) {
                throw const FormatException(
                    'Foreign or repeated voice workspace call.');
              }
              calls[value.cursor._key] = value;
            }
            after = page.next;
            if (after != null &&
                (page.calls.isEmpty ||
                    after._key != page.calls.last.cursor._key ||
                    !cursors.add(after._key))) {
              throw const FormatException(
                  'Voice workspace cursor did not advance.');
            }
          } while (after != null);
        }
        for (final old in before.calls) {
          final next = calls[old.cursor._key];
          if (next == null ||
              next.counts.total < old.counts.total ||
              next.counts.completed < old.counts.completed ||
              next.counts.failed < old.counts.failed ||
              HandrailRealtimeCallMonitor._progress(next.call.status) <
                  HandrailRealtimeCallMonitor._progress(old.call.status)) {
            throw const FormatException(
                'Saved voice workspace evidence regressed.');
          }
        }
        _emit(HandrailRealtimeWorkspaceState(
            calls: calls.values, synchronized: true));
      } catch (_) {
        if (!_disposed && generation == _generation) {
          _emit(HandrailRealtimeWorkspaceState(
              calls: before.calls,
              synchronized: before.synchronized,
              error: 'Could not refresh voice activity. Retrying…'));
        }
      }
    });
    _reading = operation.whenComplete(() => _reading = null);
    return _reading!;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    await _changes.close();
  }
}
