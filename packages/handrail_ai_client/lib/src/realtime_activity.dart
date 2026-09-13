part of '../handrail_ai_client.dart';

enum HandrailRealtimeToolStatus { running, completed, failed }

class HandrailRealtimeToolActivity {
  final String toolCallId;
  final String name;
  final HandrailRealtimeToolStatus status;
  const HandrailRealtimeToolActivity(
      {required this.toolCallId, required this.name, required this.status});
  factory HandrailRealtimeToolActivity.fromJson(Object? value) {
    if (value is! Map ||
        value['toolCallId'] is! String ||
        value['name'] is! String ||
        (value['toolCallId'] as String).isEmpty ||
        (value['name'] as String).isEmpty) {
      throw const FormatException('Invalid voice tool activity.');
    }
    final statuses = HandrailRealtimeToolStatus.values
        .where((status) => status.name == value['status']);
    if (statuses.length != 1) {
      throw const FormatException('Invalid voice tool status.');
    }
    return HandrailRealtimeToolActivity(
        toolCallId: value['toolCallId'] as String,
        name: value['name'] as String,
        status: statuses.single);
  }
}

class HandrailRealtimeToolCounts {
  final int total, running, completed, failed;
  const HandrailRealtimeToolCounts(
      {required this.total,
      required this.running,
      required this.completed,
      required this.failed});
  factory HandrailRealtimeToolCounts.fromJson(Object? value) {
    if (value is! Map ||
        ['total', 'running', 'completed', 'failed']
            .any((key) => value[key] is! int || (value[key] as int) < 0) ||
        value['total'] !=
            (value['running'] as int) +
                (value['completed'] as int) +
                (value['failed'] as int)) {
      throw const FormatException('Invalid voice tool counts.');
    }
    return HandrailRealtimeToolCounts(
        total: value['total'] as int,
        running: value['running'] as int,
        completed: value['completed'] as int,
        failed: value['failed'] as int);
  }
}

class HandrailRealtimeActivityReadToken {
  final String callId, scopeBinding;
  final int callVersion, total, completed, failed;
  const HandrailRealtimeActivityReadToken(
      {required this.callId,
      required this.scopeBinding,
      required this.callVersion,
      required this.total,
      required this.completed,
      required this.failed});
  factory HandrailRealtimeActivityReadToken.fromJson(Object? value) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['callId'] is! String ||
        (value['callId'] as String).isEmpty ||
        value['scopeBinding'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['scopeBinding'] as String) ||
        ['callVersion', 'total', 'completed', 'failed']
            .any((key) => value[key] is! int || (value[key] as int) < 0) ||
        value['callVersion'] == 0 ||
        (value['completed'] as int) + (value['failed'] as int) >
            (value['total'] as int)) {
      throw const FormatException('Invalid voice activity read token.');
    }
    return HandrailRealtimeActivityReadToken(
        callId: value['callId'] as String,
        scopeBinding: value['scopeBinding'] as String,
        callVersion: value['callVersion'] as int,
        total: value['total'] as int,
        completed: value['completed'] as int,
        failed: value['failed'] as int);
  }
  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'callId': callId,
        'scopeBinding': scopeBinding,
        'callVersion': callVersion,
        'total': total,
        'completed': completed,
        'failed': failed
      };
}

class HandrailRealtimeActivityPage {
  final HandrailRealtimeCall call;
  final HandrailRealtimeToolCounts counts;
  final List<HandrailRealtimeToolActivity>? tools;
  final String? nextToolCallId;
  final bool? unread;
  final HandrailRealtimeActivityReadToken? readToken;
  HandrailRealtimeActivityPage(
      {required this.call,
      required this.counts,
      Iterable<HandrailRealtimeToolActivity>? tools,
      this.nextToolCallId,
      this.unread,
      this.readToken})
      : tools = tools == null ? null : List.unmodifiable(tools);
  factory HandrailRealtimeActivityPage.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid voice activity.');
    final details = value.containsKey('tools');
    if (details &&
            (value['tools'] is! List || !value.containsKey('nextToolCallId')) ||
        !details && value.containsKey('nextToolCallId') ||
        value['nextToolCallId'] != null &&
            (value['nextToolCallId'] is! String ||
                (value['nextToolCallId'] as String).isEmpty)) {
      throw const FormatException('Invalid voice activity detail page.');
    }
    if (value.containsKey('unread') && value['unread'] is! bool ||
        value.containsKey('readToken') != value.containsKey('unread')) {
      throw const FormatException('Invalid voice read state.');
    }
    final counts = HandrailRealtimeToolCounts.fromJson(value['summary']);
    final token = value['readToken'] == null
        ? null
        : HandrailRealtimeActivityReadToken.fromJson(value['readToken']);
    if (token != null &&
            (token.callId != value['callId'] ||
                value['status'] != 'ended' ||
                token.total != counts.total ||
                token.completed != counts.completed ||
                token.failed != counts.failed) ||
        value['unread'] == true && token == null) {
      throw const FormatException('Voice read token does not match its call.');
    }
    return HandrailRealtimeActivityPage(
        unread: value['unread'] as bool?,
        readToken: token,
        call: HandrailRealtimeCall.fromJson(value),
        counts: counts,
        tools: details
            ? (value['tools'] as List)
                .map(HandrailRealtimeToolActivity.fromJson)
            : null,
        nextToolCallId: value['nextToolCallId'] as String?);
  }
}

class HandrailRealtimeActivityState {
  final HandrailRealtimeCall? call;
  final HandrailRealtimeToolCounts? counts;
  final List<HandrailRealtimeToolActivity> tools;
  final bool details, loading, hasMore;
  final String? error;
  final String? readError;
  final bool? unread;
  final HandrailRealtimeActivityReadToken? readToken;
  HandrailRealtimeActivityState(
      {this.call,
      this.counts,
      Iterable<HandrailRealtimeToolActivity> tools = const [],
      this.details = false,
      this.loading = false,
      this.hasMore = false,
      this.error,
      this.readError,
      this.unread,
      this.readToken})
      : tools = List.unmodifiable(tools);
  bool get hasUnresolvedTools =>
      counts != null &&
      counts!.running > 0 &&
      (error != null || call?.status != HandrailRealtimeCallStatus.active);
}

/// One authenticated call's display state. Transport owns authorization; this
/// monitor owns serialized polling, bounded detail pagination and disposal.
/// Failure never erases saved counts or establishes that unfinished tools ended.
class HandrailRealtimeActivityMonitor {
  final String conversationId, callId;
  final Future<HandrailRealtimeActivityPage> Function(
      bool details, String? afterToolCallId) readPage;
  final Future<void> Function(HandrailRealtimeActivityReadToken token)?
      acknowledgeRead;
  final Duration pollInterval;
  final int maxPages;
  final _changes =
      StreamController<HandrailRealtimeActivityState>.broadcast(sync: true);
  HandrailRealtimeActivityState _state = HandrailRealtimeActivityState();
  Future<void>? _reading;
  Future<bool>? _marking;
  String? _markingToken;
  String? _acknowledgedToken;
  Timer? _poll;
  bool _disposed = false;
  int _generation = 0, _pageBudget = 1;
  HandrailRealtimeActivityMonitor(
      {required this.conversationId,
      required this.callId,
      required this.readPage,
      this.acknowledgeRead,
      this.pollInterval = const Duration(seconds: 3),
      this.maxPages = 100}) {
    if (conversationId.isEmpty ||
        callId.isEmpty ||
        maxPages < 1 ||
        maxPages > 100 ||
        pollInterval < const Duration(milliseconds: 250)) {
      throw ArgumentError('Invalid voice activity observation bounds.');
    }
  }
  HandrailRealtimeActivityState get state => _state;
  Stream<HandrailRealtimeActivityState> get changes => _changes.stream;
  void _emit(HandrailRealtimeActivityState state) {
    if (_disposed) return;
    _state = state;
    _changes.add(state);
  }

  void startPolling() {
    if (_disposed || _poll != null) return;
    _poll = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> setDetails(bool details) async {
    if (_disposed || details == _state.details) return;
    _generation++;
    _pageBudget = 1;
    _emit(HandrailRealtimeActivityState(
        call: _state.call,
        counts: _state.counts,
        unread: _state.unread,
        readToken: _state.readToken,
        readError: _state.readError,
        details: details,
        error: _state.error));
    await _reading;
    if (!_disposed) await refresh();
  }

  Future<void> loadMore() async {
    if (_disposed ||
        !_state.details ||
        !_state.hasMore ||
        _pageBudget >= maxPages ||
        _reading != null) {
      return;
    }
    _pageBudget++;
    await refresh();
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_reading != null) return _reading!;
    final generation = _generation;
    final operation = Future<void>.microtask(() async {
      final before = _state;
      _emit(HandrailRealtimeActivityState(
          call: before.call,
          counts: before.counts,
          unread: before.unread,
          readToken: before.readToken,
          readError: before.readError,
          tools: before.tools,
          details: before.details,
          loading: true,
          hasMore: before.hasMore,
          error: before.error));
      try {
        final tools = <String, HandrailRealtimeToolActivity>{};
        final cursors = <String>{};
        String? after;
        HandrailRealtimeActivityPage? latest;
        for (var pageNumber = 0;
            pageNumber < (before.details ? _pageBudget : 1);
            pageNumber++) {
          final page = await readPage(before.details, after);
          if (_disposed || generation != _generation) return;
          if (page.call.callId != callId ||
              page.call.conversationId != conversationId ||
              before.details != (page.tools != null) ||
              (page.tools?.length ?? 0) > 100) {
            throw const FormatException(
                'Voice activity response does not match this call.');
          }
          latest = page;
          for (final tool
              in page.tools ?? const <HandrailRealtimeToolActivity>[]) {
            if (tools.containsKey(tool.toolCallId)) {
              throw const FormatException('Repeated voice tool identity.');
            }
            tools[tool.toolCallId] = tool;
          }
          after = page.nextToolCallId;
          if (after == null) break;
          if (!cursors.add(after)) {
            throw const FormatException(
                'Voice activity cursor did not advance.');
          }
        }
        final counts = latest!.counts;
        final previous = before.counts;
        if (previous != null &&
            (counts.total < previous.total ||
                counts.completed < previous.completed ||
                counts.failed < previous.failed)) {
          throw const FormatException('Voice activity counts regressed.');
        }
        for (final old in before.tools) {
          final next = tools[old.toolCallId];
          if (next != null &&
              (old.name != next.name ||
                  old.status != HandrailRealtimeToolStatus.running &&
                      old.status != next.status)) {
            throw const FormatException('Voice tool outcome regressed.');
          }
        }
        final previousToken = before.readToken;
        final nextToken = latest.readToken;
        if (before.call != null &&
                HandrailRealtimeCallMonitor._progress(before.call!.status) >
                    HandrailRealtimeCallMonitor._progress(latest.call.status) ||
            previousToken != null &&
                (nextToken == null ||
                    nextToken.scopeBinding != previousToken.scopeBinding ||
                    nextToken.callVersion < previousToken.callVersion)) {
          throw const FormatException('Voice activity lifecycle regressed.');
        }
        final call = latest.call;
        _emit(HandrailRealtimeActivityState(
            call: call,
            counts: counts,
            unread: latest.unread ?? before.unread,
            readToken: latest.readToken,
            tools: tools.values,
            details: before.details,
            hasMore: after != null && _pageBudget < maxPages));
      } catch (_) {
        if (_disposed || generation != _generation) return;
        _emit(HandrailRealtimeActivityState(
            call: before.call,
            counts: before.counts,
            unread: before.unread,
            readToken: before.readToken,
            readError: before.readError,
            tools: before.tools,
            details: before.details,
            hasMore: before.hasMore,
            error: 'Could not refresh saved voice activity. Retrying…'));
      }
    });
    _reading = operation.whenComplete(() {
      _reading = null;
    });
    return _reading!;
  }

  /// Call after this token's activity has actually been displayed. No optimistic
  /// clearing: authoritative refresh decides whether newer outcomes remain unread.
  Future<bool> markRead(HandrailRealtimeActivityReadToken token) {
    if (_disposed || acknowledgeRead == null) return Future.value(false);
    final known = _state.readToken;
    if (known == null ||
        token.callId != callId ||
        token.scopeBinding != known.scopeBinding ||
        token.callVersion > known.callVersion ||
        token.total > known.total ||
        token.completed > known.completed ||
        token.failed > known.failed) {
      return Future.error(
          ArgumentError('A displayed voice read token is required.'));
    }
    final key = jsonEncode(token.toJson());
    if (_acknowledgedToken == key) return Future.value(true);
    if (_marking != null) {
      return _markingToken == key
          ? _marking!
          : _marking!.then((_) => markRead(token));
    }
    final operation = Future<bool>.microtask(() async {
      if (_disposed) return false;
      try {
        await acknowledgeRead!(token);
        if (_disposed) return false;
        _acknowledgedToken = key;
        await _reading;
        if (_disposed) return false;
        await refresh();
        return true;
      } catch (_) {
        if (_disposed) return false;
        _emit(HandrailRealtimeActivityState(
            call: _state.call,
            counts: _state.counts,
            tools: _state.tools,
            details: _state.details,
            loading: _state.loading,
            hasMore: _state.hasMore,
            error: _state.error,
            unread: _state.unread,
            readToken: _state.readToken,
            readError: 'Could not mark saved voice activity read. Retrying…'));
        return false;
      }
    });
    _markingToken = key;
    _marking = operation.whenComplete(() {
      _marking = null;
      _markingToken = null;
    });
    return _marking!;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _poll?.cancel();
    await _changes.close();
  }
}
