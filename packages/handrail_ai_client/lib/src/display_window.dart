part of '../handrail_ai_client.dart';

enum HandrailDisplayWindowOperation { initial, older, newer, latest, changes }

/// Immutable presentation window, never a canonical snapshot or provider input.
class HandrailDisplayWindowState {
  final String? conversationId;
  final String status;
  final int generation, revision, version, retainedBytes;
  final String? activeTurnId;
  final List<HandrailDisplayRecord> records;
  final bool hasOlder, hasNewer;
  final HandrailDisplayWindowOperation? loading, failedOperation;
  final HandrailDisplayWindowOperation change;
  final Object? error;
  const HandrailDisplayWindowState._(
      {this.conversationId,
      this.status = 'empty',
      this.generation = 0,
      this.revision = 0,
      this.version = 0,
      this.retainedBytes = 0,
      this.activeTurnId,
      this.records = const [],
      this.hasOlder = false,
      this.hasNewer = false,
      this.loading,
      this.failedOperation,
      this.change = HandrailDisplayWindowOperation.initial,
      this.error});
}

/// One selected conversation, one in-flight read, bounded rows and retained bytes.
/// Own this with the authenticated client and dispose it when the account changes.
/// Message anchors allow navigation back into discarded pages without replaying
/// history. A cancelled selection cannot publish into the replacement account/chat.
class HandrailDisplayWindow {
  final HandrailAiClient client;
  final HandrailDisplayHistoryCapability capability;
  final int pageSize, pageBytes, maximumMessages, maximumBytes;
  final _changes =
      StreamController<HandrailDisplayWindowState>.broadcast(sync: true);
  HandrailDisplayWindowState _state = const HandrailDisplayWindowState._();
  Completer<void> _selection = Completer<void>();
  Future<void>? _pending;
  String? _conversationId, _activeTurnId, _changesCursor;
  String _status = 'empty';
  int _generation = 0,
      _revision = 0,
      _version = 0,
      _retainedBytes = 0,
      _changesAfter = 0;
  List<HandrailDisplayRecord> _records = const [];
  bool _hasOlder = false, _hasNewer = false, _disposed = false;
  bool _followingLatest = true;
  bool get followingLatest => _followingLatest;
  void setFollowingLatest(bool value) {
    _followingLatest = value;
  }

  HandrailDisplayWindowOperation? _loading, _failedOperation;
  HandrailDisplayWindowOperation _change =
      HandrailDisplayWindowOperation.initial;
  Object? _error;
  HandrailDisplayAnchor? _initialAnchor;

  HandrailDisplayWindow(
      {required this.client,
      required this.capability,
      this.pageSize = 30,
      this.pageBytes = 65536,
      this.maximumMessages = 90,
      this.maximumBytes = 262144}) {
    if (pageSize < 1 ||
        pageSize > capability.maximumPageSize ||
        pageBytes < 8192 ||
        pageBytes > capability.maximumPageBytes ||
        maximumMessages < pageSize * 2 ||
        maximumMessages > 1000 ||
        maximumBytes < pageBytes * 2 ||
        maximumBytes > 8388608) {
      throw ArgumentError('Invalid display window bounds.');
    }
  }
  HandrailDisplayWindowState get state => _state;
  Stream<HandrailDisplayWindowState> get changes => _changes.stream;

  /// Structural binding for the Flutter display widget; no Flutter dependency.
  /// The widget owns selection/scrolling, while this controller owns network
  /// cancellation, generation checks, and the hard row/byte limits.
  ({
    Object scope,
    Stream<Object?> changes,
    Map<String, Object?> Function() read,
    Future<void> Function(String?, Map<String, Object?>?) select,
    Future<void> Function() older,
    Future<void> Function() newer,
    Future<void> Function() latest,
    Future<void> Function() refresh,
    Future<void> Function() retry,
  }) get uiBinding => (
        scope: this,
        changes: changes,
        read: () => Map.unmodifiable({
              'conversationId': state.conversationId,
              'status': state.status,
              'generation': state.generation,
              'revision': state.revision,
              'version': state.version,
              'activeTurnId': state.activeTurnId,
              'setFollowingLatest': setFollowingLatest,
              'records': List.unmodifiable(state.records
                  .map((record) => Map<String, Object?>.unmodifiable({
                        'kind': record.kind,
                        'id': record.id,
                        'revision': record.revision,
                        'turnId': record.turnId,
                        'bytes': record.bytes,
                        'deferred': record.deferred,
                        'value': record.value,
                      }))),
              'hasOlder': state.hasOlder,
              'hasNewer': state.hasNewer,
              'loading': state.loading?.name,
              'change': state.change.name,
              'retryable': state.error is HandrailGatewayException
                  ? (state.error as HandrailGatewayException).retryable
                  : true,
              'error': state.error is HandrailGatewayException
                  ? (state.error as HandrailGatewayException).message
                  : state.error == null
                      ? null
                      : 'Conversation history could not be loaded.',
            }),
        select: (id, anchor) => select(id,
            anchor: anchor == null
                ? null
                : HandrailDisplayAnchor(
                    messageId: anchor['messageId'] as String,
                    generation: anchor['generation'] as int,
                    newer: true,
                    inclusive: true)),
        older: loadOlder,
        newer: loadNewer,
        latest: jumpToLatest,
        refresh: refresh,
        retry: retry,
      );
  void _publish() {
    _state = HandrailDisplayWindowState._(
        conversationId: _conversationId,
        status: _status,
        generation: _generation,
        revision: _revision,
        version: _version,
        retainedBytes: _retainedBytes,
        activeTurnId: _activeTurnId,
        records: _records,
        hasOlder: _hasOlder,
        hasNewer: _hasNewer,
        loading: _loading,
        failedOperation: _failedOperation,
        change: _change,
        error: _error);
    if (!_changes.isClosed) _changes.add(_state);
  }

  void _clear() {
    _generation = 0;
    _revision = 0;
    _retainedBytes = 0;
    _activeTurnId = null;
    _records = const [];
    _hasOlder = false;
    _hasNewer = false;
    _error = null;
    _loading = null;
    _failedOperation = null;
    _changesCursor = null;
    _changesAfter = 0;
    _change = HandrailDisplayWindowOperation.initial;
    _version++;
  }

  bool _current(Completer<void> selection) =>
      !_disposed && identical(selection, _selection) && !selection.isCompleted;

  Future<void> select(String? conversationId, {HandrailDisplayAnchor? anchor}) {
    if (_disposed)
      return Future.error(StateError('Display window is disposed.'));
    if (conversationId != null && !_historyId(conversationId))
      return Future.error(ArgumentError('Invalid conversation.'));
    if (!_selection.isCompleted) _selection.complete();
    _selection = Completer<void>();
    _pending = null;
    _initialAnchor = anchor;
    _followingLatest = anchor == null;
    _clear();
    _conversationId = conversationId;
    _status = conversationId == null ? 'empty' : 'loading';
    _publish();
    return conversationId == null
        ? Future.value()
        : _read(HandrailDisplayWindowOperation.initial);
  }

  Future<void> loadOlder() {
    _followingLatest = false;
    return _hasOlder
        ? _read(HandrailDisplayWindowOperation.older)
        : Future.value();
  }

  Future<void> loadNewer() =>
      _hasNewer ? _read(HandrailDisplayWindowOperation.newer) : Future.value();
  Future<void> jumpToLatest() {
    _followingLatest = true;
    return _read(HandrailDisplayWindowOperation.latest);
  }

  Future<void> refresh() => _read(_status == 'ready'
      ? HandrailDisplayWindowOperation.changes
      : HandrailDisplayWindowOperation.initial);
  Future<void> retry() => _read(_failedOperation ??
      (_status == 'ready'
          ? HandrailDisplayWindowOperation.changes
          : HandrailDisplayWindowOperation.initial));

  Future<void> _read(HandrailDisplayWindowOperation operation) {
    if (_disposed)
      return Future.error(StateError('Display window is disposed.'));
    if (_pending != null) return _pending!;
    final id = _conversationId, selection = _selection;
    if (id == null) return Future.value();
    return _pending = Future<void>.microtask(() async {
      if (!_current(selection)) return;
      _loading = operation;
      _error = null;
      _failedOperation = null;
      _publish();
      try {
        if (operation == HandrailDisplayWindowOperation.changes) {
          final changed = await client.displayHistoryChanges(
              conversationId: id,
              capability: capability,
              generation: _generation,
              afterRevision: _changesAfter,
              cursor: _changesCursor,
              limit: pageSize,
              maximumBytes: pageBytes,
              cancellation: selection.future);
          if (!_current(selection)) return;
          final page = changed.page;
          if (page.preparing) {
            _preparing();
            return;
          }
          if (page.nextCursor != null && page.nextCursor == _changesCursor)
            throw const FormatException('Changes cursor did not advance.');
          final updates = {
            for (final record
                in page.records.where((record) => record.kind == 'message'))
              record.id: record
          };
          final ids = _records.map((record) => record.id).toSet();
          var changedContent = false;
          final next = <HandrailDisplayRecord>[];
          for (final record in _records) {
            final update = updates[record.id];
            final value = update != null && update.revision >= record.revision
                ? update
                : record;
            if (!identical(record, value)) changedContent = true;
            if (!value.deleted) next.add(value);
          }
          final trimmed = _trim(next, older: true);
          _hasNewer = _hasNewer ||
              trimmed ||
              updates.values
                  .any((record) => !record.deleted && !ids.contains(record.id));
          _changesCursor = page.nextCursor;
          if (page.nextCursor == null) _changesAfter = changed.throughRevision;
          _revision = page.revision;
          _activeTurnId = page.activeTurnId;
          if (changedContent || trimmed) _version++;
          _change = operation;
        } else {
          final older = operation == HandrailDisplayWindowOperation.older;
          final replacement =
              operation == HandrailDisplayWindowOperation.initial ||
                  operation == HandrailDisplayWindowOperation.latest;
          final edge = _records.isEmpty
              ? null
              : older
                  ? _records.first
                  : _records.last;
          final anchor = operation == HandrailDisplayWindowOperation.initial
              ? _initialAnchor
              : replacement || edge == null
                  ? null
                  : HandrailDisplayAnchor(
                      messageId: edge.id,
                      generation: _generation,
                      newer: !older);
          final page = await client.displayHistoryPage(
              conversationId: id,
              capability: capability,
              anchor: anchor,
              limit: pageSize,
              maximumBytes: pageBytes,
              cancellation: selection.future);
          if (!_current(selection)) return;
          if (page.preparing) {
            _preparing();
            return;
          }
          if (page.records
              .any((record) => record.kind != 'message' || record.deleted))
            throw const FormatException('Invalid message page.');
          final combined = replacement
              ? page.records
              : older
                  ? [...page.records, ..._records]
                  : [..._records, ...page.records];
          final byId = <String, HandrailDisplayRecord>{};
          for (final record in combined) {
            final previous = byId[record.id];
            if (previous == null || previous.revision <= record.revision)
              byId[record.id] = record;
          }
          final trimmed =
              _trim(byId.values.toList(growable: false), older: older);
          if (replacement) {
            _hasOlder = anchor?.newer == true || page.nextCursor != null;
            _hasNewer = anchor?.newer == true
                ? page.nextCursor != null
                : anchor != null;
            _changesAfter = page.revision;
            _changesCursor = null;
          } else if (older) {
            _hasOlder = page.nextCursor != null;
          } else {
            _hasNewer = page.nextCursor != null;
          }
          if (trimmed) {
            if (older) {
              _hasNewer = true;
            } else {
              _hasOlder = true;
            }
          }
          _status = 'ready';
          _generation = page.generation;
          _revision = page.revision;
          _activeTurnId = page.activeTurnId;
          _version++;
          _change = operation;
        }
        _publish();
      } catch (cause) {
        if (!_current(selection)) return;
        final code = cause is HandrailGatewayException ? cause.code : null;
        if (const {'stale_cursor', 'not_found', 'forbidden', 'unauthenticated'}
            .contains(code)) {
          _clear();
          _initialAnchor = null;
          _status = 'error';
          _failedOperation = HandrailDisplayWindowOperation.initial;
        } else {
          _status = _records.isEmpty ? 'error' : 'ready';
          _failedOperation = operation;
        }
        _error = cause;
        _publish();
      } finally {
        if (_current(selection)) {
          _pending = null;
          _loading = null;
          _publish();
        }
      }
    });
  }

  void _preparing() {
    _initialAnchor = null;
    _changesCursor = null;
    _status = 'preparing';
    _records = const [];
    _retainedBytes = 0;
    _hasOlder = false;
    _hasNewer = false;
    _activeTurnId = null;
    _version++;
    _publish();
  }

  bool _trim(List<HandrailDisplayRecord> input, {required bool older}) {
    int size(HandrailDisplayRecord record) => utf8
        .encode(jsonEncode({
          'kind': record.kind,
          'id': record.id,
          'revision': record.revision,
          'turnId': record.turnId,
          'bytes': record.bytes,
          'value': record.value,
          'deferred': record.deferred,
        }))
        .length;
    final sizes = input.map(size).toList(growable: false);
    var bytes = sizes.fold(0, (sum, size) => sum + size),
        start = 0,
        end = input.length;
    while (end - start > maximumMessages || bytes > maximumBytes) {
      if (older) {
        bytes -= sizes[--end];
      } else {
        bytes -= sizes[start++];
      }
    }
    _records = List.unmodifiable(input.sublist(start, end));
    _retainedBytes = bytes;
    return start > 0 || end < input.length;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (!_selection.isCompleted) _selection.complete();
    _disposed = true;
    _pending = null;
    _conversationId = null;
    _status = 'empty';
    _clear();
    _publish();
    await _changes.close();
  }
}
