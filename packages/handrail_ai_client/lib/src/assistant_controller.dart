part of '../handrail_ai_client.dart';

enum HandrailHistoryView { active, archived }

/// Canonical catalog metadata. Presentation labels never determine permissions.
class HandrailConversationDescriptor {
  HandrailConversationDescriptor.fromJson(Map<String, Object?> value)
      : json = _immutableJson(value) as Map<String, Object?> {
    if (id.isEmpty ||
        id.length > 256 ||
        version < 1 ||
        !const ['active', 'archived'].contains(lifecycle) ||
        json['title'] != null && json['title'] is! String) {
      throw const FormatException('Invalid conversation descriptor');
    }
  }
  final Map<String, Object?> json;
  String get id => json['conversationId'] as String;
  int get version => json['version'] as int;
  String get lifecycle => json['lifecycle'] as String;
  String? get title => json['title'] as String?;
  DateTime? get updatedAt =>
      DateTime.tryParse(json['updatedAt'] as String? ?? '');
  Map<String, Object?> get metadata => json['metadata'] is Map
      ? Map<String, Object?>.unmodifiable(json['metadata'] as Map)
      : const {};
}

/// Account-owned catalog, selection, sessions and submission recovery.
/// Hosts supply authentication, pending storage, request construction and branding.
/// Closing a view does not dispose this controller or cancel server work.
class HandrailAssistantController {
  HandrailAssistantController(
      {required this.client,
      required this.pendingStore,
      this.clientId = 'handrail-mobile',
      this.newConversationTitle = 'New conversation',
      this.autoCreate = true,
      this.pageSize = 50,
      this.pollingInterval = const Duration(seconds: 1),
      String Function()? createId,
      this.beforePendingRecovery})
      : _createId = createId ?? _assistantIdentity {
    if (pageSize < 1 || pageSize > 100)
      throw ArgumentError.value(pageSize, 'pageSize');
    _workspaceSubscription = workspace.changes.listen((_) => _publish());
  }
  final HandrailAiClient client;
  final HandrailPendingTurnStore pendingStore;
  final String clientId, newConversationTitle;
  final bool autoCreate;
  final int pageSize;
  final Duration? pollingInterval;
  final String Function() _createId;

  /// Capture a draft's original acceptance callback before recovering saved intent.
  final void Function()? Function(String conversationId)? beforePendingRecovery;
  final workspace = HandrailConversationWorkspace();
  final _sessions = <String, HandrailConversationSession>{};
  final _sessionSubscriptions =
      <StreamSubscription<HandrailConversationSession>>[];
  late final StreamSubscription<HandrailConversationWorkspaceSnapshot>
      _workspaceSubscription;
  final _changes =
      StreamController<HandrailAssistantController>.broadcast(sync: true);
  final _descriptors = <String, HandrailConversationDescriptor>{};
  final _pending = <String>{}, _sending = <String>{}, _stopping = <String>{};
  final _operationErrors = <String, HandrailGatewayException>{};
  final _cancelKeys = <String, String>{};
  final _lifecycleRequests = <String, Map<String, Object?>>{};
  final _lifecycleOperations = <String, Future<void>>{};
  final _lifecycleDirections = <String, bool>{};
  List<HandrailConversationDescriptor> _history = const [];
  HandrailHistoryView _view = HandrailHistoryView.active;
  String? _selectedId, _nextCursor;
  final _seenCursors = <String>{};
  bool _unreadOnly = false,
      _disposed = false,
      _loadedHistory = false,
      _initialCreateAttempted = false;
  int _historyGeneration = 0, _selectionGeneration = 0;
  Future<void>? _initializing, _listing, _creating;
  Map<String, Object?>? _createRequest;
  HandrailConversationDescriptor? _createdDescriptor;
  bool _selecting = false;
  HandrailGatewayException? _historyError, _selectionError;

  Stream<HandrailAssistantController> get changes => _changes.stream;
  HandrailHistoryView get historyView => _view;
  bool get unreadOnly => _unreadOnly;
  bool get loadingHistory => _listing != null;
  bool get hasMoreHistory => _nextCursor != null;
  List<HandrailConversationDescriptor> get history => _history;
  String? get selectedId => _selectedId;
  HandrailConversationSession? get session => _sessions[_selectedId];
  HandrailConversationSession? sessionFor(String? id) => _sessions[id];
  HandrailConversationDocument? get document => session?.document;
  HandrailConversationDescriptor? get selectedDescriptor =>
      _descriptors[_selectedId];
  bool get archived => selectedDescriptor?.lifecycle == 'archived';
  bool get running => document?.activeTurnId != null;
  bool get canSend =>
      !busy &&
      !running &&
      !hasPendingMessage &&
      document != null &&
      !archived &&
      _selectionError == null;
  bool get hasPendingMessage => _pending.contains(_selectedId);
  bool get stopping => _stopping.contains(_selectedId);
  bool get busy =>
      _selecting ||
      _creating != null ||
      _sending.contains(_selectedId) ||
      _lifecycleOperations.containsKey(_selectedId);
  HandrailGatewayException? get historyError => _historyError;
  HandrailGatewayException? get error =>
      _selectionError ?? _operationErrors[_selectedId];
  bool isUnread(String id) =>
      workspace.snapshot.conversations
          .any((entry) => entry.state.conversationId == id && entry.unread) ||
      workspace.remoteActivityFor(id)?.unread == true;
  int get unreadCount => _history.where((row) => isUnread(row.id)).length;
  List<HandrailConversationDescriptor> get visibleHistory => List.unmodifiable(
      _history.where((row) => !_unreadOnly || isUnread(row.id)));
  String previewFor(String id) {
    final messages =
        _sessions[id]?.document?.messages ?? const <Map<String, Object?>>[];
    for (final message in messages.reversed) {
      final text = _records(message['content'])
          .where((part) => part['type'] == 'text')
          .map((part) => part['text'] as String? ?? '')
          .join(' ')
          .trim();
      if (text.isNotEmpty)
        return text.length > 240 ? '${text.substring(0, 239)}…' : text;
    }
    return workspace.remoteActivityFor(id)?.summary ??
        (_descriptors[id]?.metadata['preview'] as String? ?? '');
  }

  /// Structural optional-UI binding: no Flutter dependency in the client package.
  ({
    Object scope,
    Stream<Object?> changes,
    Map<String, Object?> Function() read,
    Future<void> Function() create,
    Future<void> Function(String) open,
    Future<void> Function(String) archive,
    Future<void> Function(String) restore,
    Future<void> Function(String) view,
    void Function(bool) unread,
    Future<void> Function() loadMore,
    Future<void> Function() refresh
  }) get historyBinding => (
        scope: this,
        changes: changes,
        read: () => historyPresentation,
        create: () => newConversation(),
        open: openConversation,
        archive: archive,
        restore: restore,
        view: (name) => setHistoryView(HandrailHistoryView.values.byName(name)),
        unread: setUnreadOnly,
        loadMore: () => refreshHistory(more: true),
        refresh: refreshHistory
      );
  Map<String, Object?> get historyPresentation => {
        'view': historyView.name,
        'unreadOnly': unreadOnly,
        'unreadCount': unreadCount,
        'selectedId': selectedId,
        'selectedTitle': selectedDescriptor?.title ?? newConversationTitle,
        'busy': busy,
        'loading': loadingHistory,
        'hasMore': hasMoreHistory,
        'error': historyError?.message ?? error?.message,
        'rows': [
          for (final row in visibleHistory)
            {
              'id': row.id,
              'title': row.title ?? newConversationTitle,
              'preview': previewFor(row.id),
              'lifecycle': row.lifecycle,
              'updatedAt': row.json['updatedAt'],
              'unread': isUnread(row.id),
              'running': sessionFor(row.id)?.document?.activeTurnId != null ||
                  const [
                    HandrailTurnStatus.running,
                    HandrailTurnStatus.waitingForTool
                  ].contains(workspace.remoteActivityFor(row.id)?.status),
            }
        ],
      };

  void _assertActive() {
    if (_disposed) throw StateError('Assistant account is closed');
  }

  void _publish() {
    if (!_disposed) _changes.add(this);
  }

  Future<void> initialize() {
    _assertActive();
    if (_loadedHistory && document != null) return Future.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    try {
      await refreshHistory();
      _assertActive();
      if (_createRequest != null) {
        await newConversation();
        return;
      }
      final id = _selectedId ?? _history.firstOrNull?.id;
      if (id != null) {
        await openConversation(id);
      } else if (autoCreate &&
          !_initialCreateAttempted &&
          _view == HandrailHistoryView.active) {
        _initialCreateAttempted = true;
        await newConversation();
      }
    } catch (cause) {
      if (!_disposed) {
        _selectionError = _assistantFailure(cause, 'initialization_failed',
            'The assistant could not be loaded. Retry to reconnect.');
        _publish();
      }
      rethrow;
    }
  }

  Future<void> refreshHistory({bool more = false}) {
    _assertActive();
    if (_listing != null) return _listing!;
    if (more && _nextCursor == null) return Future.value();
    final generation = _historyGeneration,
        view = _view,
        cursor = more ? _nextCursor : null;
    late final Future<void> operation;
    operation = (() async {
      try {
        final response = await client.listConversations({
          'lifecycle': view.name,
          'pageSize': pageSize,
          'order': {'field': 'updated_at', 'direction': 'desc'},
          if (cursor != null) 'cursor': cursor
        });
        _assertActive();
        if (generation != _historyGeneration) return;
        final value = _object(response['value']);
        final rows = _records(value['items'])
            .map(HandrailConversationDescriptor.fromJson)
            .toList();
        final next = value['nextCursor'];
        if (rows.any((row) => row.lifecycle != view.name) ||
            rows.map((row) => row.id).toSet().length != rows.length ||
            value['hasMore'] is! bool ||
            value['hasMore'] == true &&
                (next is! String ||
                    next.isEmpty ||
                    next == cursor ||
                    more && _seenCursors.contains(next))) {
          throw const FormatException('Invalid conversation page');
        }
        final merged = <String, HandrailConversationDescriptor>{
          if (more)
            for (final row in _history) row.id: row
        };
        for (final row in rows) {
          final previous = _descriptors[row.id];
          final current = previous != null && previous.version > row.version
              ? previous
              : row;
          _rememberDescriptor(current);
          if (current.lifecycle == view.name) {
            merged[row.id] = current;
          } else {
            merged.remove(row.id);
          }
        }
        _history = List.unmodifiable(merged.values);
        _nextCursor = value['hasMore'] == true ? next as String : null;
        if (!more) _seenCursors.clear();
        if (_nextCursor != null) _seenCursors.add(_nextCursor!);
        _loadedHistory = true;
        _historyError = null;
      } catch (cause) {
        if (!_disposed && generation == _historyGeneration) {
          _historyError = _assistantFailure(cause, 'history_unavailable',
              'Conversation history could not be loaded. Retry history.');
        }
        rethrow;
      } finally {
        if (identical(_listing, operation)) _listing = null;
        _publish();
      }
    })();
    _listing = operation;
    _publish();
    return operation;
  }

  void _invalidateHistoryRead() {
    _historyGeneration++;
    _listing = null;
  }

  Future<void> setHistoryView(HandrailHistoryView view) async {
    _assertActive();
    if (view == _view) return;
    _view = view;
    _historyGeneration++;
    _listing = null;
    _history = const [];
    _nextCursor = null;
    _seenCursors.clear();
    _historyError = null;
    _publish();
    await refreshHistory();
  }

  void setUnreadOnly(bool value) {
    _assertActive();
    _unreadOnly = value;
    _publish();
  }

  Future<HandrailConversationSession> ensureSession(String id) async {
    _assertActive();
    final value = _sessions.putIfAbsent(id, () {
      final session = HandrailConversationSession(
          client: client,
          conversationId: id,
          workspace: workspace,
          pollingInterval: pollingInterval);
      _sessionSubscriptions.add(session.changes.listen((_) => _publish()));
      return session;
    });
    await value.initialize();
    _assertActive();
    return value;
  }

  Future<HandrailConversationDescriptor> getDescriptor(String id) async {
    _assertActive();
    final value = HandrailConversationDescriptor.fromJson(_object(
        _object((await client.getConversation(id))['value'])['descriptor']));
    _assertActive();
    if (value.id != id)
      throw const FormatException('Conversation identity mismatch');
    final previous = _descriptors[id];
    final current =
        previous != null && previous.version > value.version ? previous : value;
    _rememberDescriptor(current);
    return current;
  }

  void _rememberDescriptor(HandrailConversationDescriptor row) {
    _descriptors[row.id] = row;
    _history = List.unmodifiable([
      for (final existing in _history)
        if (existing.id != row.id)
          existing
        else if (row.lifecycle == _view.name)
          row
    ]);
    final request = _lifecycleRequests[row.id],
        direction = _lifecycleDirections[row.id];
    if (request != null &&
        direction != null &&
        row.version > (request['expectedVersion'] as int) &&
        row.lifecycle == (direction ? 'archived' : 'active')) {
      _lifecycleRequests.remove(row.id);
      if (!_lifecycleOperations.containsKey(row.id))
        _lifecycleDirections.remove(row.id);
    }
  }

  Future<void> openConversation(String id) async {
    _assertActive();
    final generation = ++_selectionGeneration;
    _selectedId = id;
    _selecting = true;
    _selectionError = null;
    workspace.select(id);
    _publish();
    try {
      await getDescriptor(id);
      final alreadyOpen = _sessions.containsKey(id);
      final session = await ensureSession(id);
      if (alreadyOpen) await session.refresh();
      _pending.add(id);
      final saved = await pendingStore.load(id);
      _assertActive();
      if (saved != null) {
        _pending.add(id);
        final accepted = beforePendingRecovery?.call(id);
        await session.retryPendingMessage(pendingStore,
            onAccepted: (_) => accepted?.call());
        _assertActive();
        _pending.remove(id);
      } else {
        _pending.remove(id);
      }
      _operationErrors.remove(id);
    } catch (cause) {
      if (!_disposed && generation == _selectionGeneration)
        _selectionError = _assistantFailure(cause, 'selection_unavailable',
            'This conversation could not be loaded. Retry to reconnect.');
      rethrow;
    } finally {
      if (!_disposed && generation == _selectionGeneration) {
        workspace.select(id);
        _selecting = false;
        _publish();
      }
    }
  }

  Future<void> newConversation({Map<String, Object?> metadata = const {}}) {
    _assertActive();
    if (_creating != null) return _creating!;
    _createRequest ??= _immutableJson({
      'idempotencyKey': _createId(),
      'title': newConversationTitle,
      if (metadata.isNotEmpty) 'metadata': metadata
    }) as Map<String, Object?>;
    late final Future<void> operation;
    operation = (() async {
      try {
        _selectionError = null;
        if (_createdDescriptor == null) {
          final result = await client.createConversation(_createRequest!);
          _assertActive();
          _createdDescriptor = HandrailConversationDescriptor.fromJson(
              _object(_object(result['value'])['descriptor']));
        }
        final row = _createdDescriptor!;
        _descriptors[row.id] = row;
        _invalidateHistoryRead();
        await openConversation(row.id);
        _assertActive();
        if (_view != HandrailHistoryView.active)
          await setHistoryView(HandrailHistoryView.active);
        else
          await refreshHistory();
        _assertActive();
        _createRequest = null;
        _createdDescriptor = null;
      } catch (cause) {
        if (!_disposed)
          _selectionError = _assistantFailure(cause, 'creation_unavailable',
              'New conversation could not be confirmed. Retry New to check its saved status.');
        rethrow;
      } finally {
        if (identical(_creating, operation)) _creating = null;
        _publish();
      }
    })();
    _creating = operation;
    _publish();
    return operation;
  }

  Future<HandrailTurnSubmission?> sendMessage(Map<String, Object?> request,
      {String? conversationId,
      String? operationId,
      void Function(HandrailTurnSubmission)? onAccepted}) async {
    _assertActive();
    final id = conversationId ?? _selectedId;
    if (id == null || _sending.contains(id) || id == _selectedId && !canSend)
      return null;
    final current = _sessions[id];
    if (current == null ||
        current.document == null ||
        current.document?.activeTurnId != null ||
        _pending.contains(id) ||
        _descriptors[id]?.lifecycle != 'active') return null;
    _sending.add(id);
    _operationErrors.remove(id);
    _publish();
    try {
      final result = await current.sendMessage(
          operationId: operationId ?? _createId(),
          clientId: clientId,
          request: request,
          pendingStore: pendingStore,
          onAccepted: onAccepted);
      _assertActive();
      _pending.remove(id);
      return result;
    } catch (cause) {
      if (!_disposed) {
        try {
          if (await pendingStore.load(id) != null) _pending.add(id);
        } catch (_) {
          _pending.add(id);
        }
        if (!_disposed)
          _operationErrors[id] = _assistantFailure(cause, 'send_unconfirmed',
              'The message could not be acknowledged. Retry to check its saved status.');
      }
      rethrow;
    } finally {
      _sending.remove(id);
      _publish();
    }
  }

  Future<HandrailTurnSubmission?> retryPendingMessage(
      {String? conversationId,
      void Function(HandrailTurnSubmission)? onAccepted}) async {
    _assertActive();
    final id = conversationId ?? _selectedId;
    if (id == null || _sending.contains(id)) return null;
    _sending.add(id);
    _operationErrors.remove(id);
    _selectionError = null;
    _publish();
    try {
      final current = await ensureSession(id);
      final value = await current.retryPendingMessage(pendingStore,
          onAccepted: onAccepted);
      await current.refresh();
      _assertActive();
      _pending.remove(id);
      return value;
    } catch (cause) {
      if (!_disposed)
        _operationErrors[id] = _assistantFailure(cause, 'retry_unconfirmed',
            'The saved message could not be confirmed. Retry to reconnect.');
      rethrow;
    } finally {
      _sending.remove(id);
      _publish();
    }
  }

  Future<void> requestCancellation({String? conversationId}) async {
    _assertActive();
    final id = conversationId ?? _selectedId,
        current = _sessions[conversationId ?? _selectedId];
    final turnId = current?.document?.activeTurnId;
    if (id == null ||
        current == null ||
        turnId == null ||
        _stopping.contains(id)) return;
    _stopping.add(id);
    _operationErrors.remove(id);
    _publish();
    try {
      final key = _cancelKeys.putIfAbsent('$id:$turnId', _createId);
      await current.requestCancellation(
          mutationId: 'cancel:$key', idempotencyKey: 'cancel:$key');
    } catch (cause) {
      if (!_disposed)
        _operationErrors[id] = _assistantFailure(
            cause,
            'cancellation_unconfirmed',
            'Cancellation could not be confirmed. Check the conversation before retrying.');
      rethrow;
    } finally {
      _stopping.remove(id);
      _publish();
    }
  }

  Future<void> markRead({String? conversationId}) async {
    final current = _sessions[conversationId ?? _selectedId];
    final latest = current?.document?.latestTurn;
    if (_disposed ||
        current == null ||
        current.document?.activeTurnId != null ||
        latest == null ||
        !const ['completed', 'failed', 'cancelled'].contains(latest['status']))
      return;
    final observed = workspace.remoteActivityFor(current.conversationId);
    if (observed?.turnId != null && observed!.turnId != latest['turn_id'])
      return;
    await current.markRead();
  }

  Future<void> refreshActivity() async {
    _assertActive();
    if ((await client.capabilities()).activity) {
      final records = await client.listActivity();
      _assertActive();
      workspace.replaceRemoteActivity(records);
    }
  }

  Future<void> setInitialTitle(
      String id, String label, String operationId) async {
    if (_sessions[id]
            ?.document
            ?.messages
            .where((message) => message['role'] == 'user')
            .length !=
        1) return;
    final row = await getDescriptor(id);
    if (row.title != null && row.title != newConversationTitle) return;
    final normalized = label.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return;
    final result = await client.renameConversation({
      'conversationId': id,
      'expectedVersion': row.version,
      'idempotencyKey': 'title:$operationId',
      'title': normalized.length <= 80
          ? normalized
          : '${normalized.substring(0, 79)}…'
    });
    _assertActive();
    _descriptors[id] = HandrailConversationDescriptor.fromJson(
        _object(_object(result['value'])['descriptor']));
    _invalidateHistoryRead();
    await refreshHistory();
  }

  Future<void> archive(String id) => _changeLifecycle(id, true);
  Future<void> restore(String id) => _changeLifecycle(id, false);
  Future<void> _changeLifecycle(String id, bool archive) {
    _assertActive();
    if (_lifecycleDirections.containsKey(id) &&
        _lifecycleDirections[id] != archive) {
      return Future.error(const HandrailGatewayException(
          'pending_lifecycle_exists',
          'Confirm the previous conversation change before starting another one. Refresh history or retry the previous action.'));
    }

    if (_descriptors[id]?.lifecycle == (archive ? 'archived' : 'active') &&
        !_lifecycleRequests.containsKey(id)) return Future.value();
    if (_lifecycleOperations[id] != null) return _lifecycleOperations[id]!;
    _lifecycleDirections[id] = archive;
    late final Future<void> operation;
    operation = (() async {
      try {
        final target = archive ? 'archived' : 'active';
        final row = _descriptors[id] ?? await getDescriptor(id);
        if (row.lifecycle == target && !_lifecycleRequests.containsKey(id))
          return;
        final request = _lifecycleRequests.putIfAbsent(
            id,
            () => {
                  'conversationId': id,
                  'expectedVersion': row.version,
                  'idempotencyKey': _createId()
                });
        final response = archive
            ? await client.archiveConversation(request)
            : await client.restoreConversation(request);
        _assertActive();
        final changed = HandrailConversationDescriptor.fromJson(
            _object(_object(response['value'])['descriptor']));
        if (changed.id != id || changed.lifecycle != target)
          throw const FormatException('Invalid lifecycle response');
        _rememberDescriptor(changed);
        _lifecycleRequests.remove(id);
        _operationErrors.remove(id);
        _invalidateHistoryRead();
        await refreshHistory();
      } catch (cause) {
        if (!_disposed)
          _operationErrors[id] = _assistantFailure(
              cause,
              'lifecycle_unconfirmed',
              'The conversation change could not be confirmed. Retry the same action.');
        rethrow;
      } finally {
        if (identical(_lifecycleOperations[id], operation))
          _lifecycleOperations.remove(id);
        if (!_lifecycleRequests.containsKey(id))
          _lifecycleDirections.remove(id);
        _publish();
      }
    })();
    _lifecycleOperations[id] = operation;
    _publish();
    return operation;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _historyGeneration++;
    _selectionGeneration++;
    final sessions =
        _sessions.values.map((session) => session.dispose()).toList();
    await _workspaceSubscription.cancel();
    for (final subscription in _sessionSubscriptions) {
      await subscription.cancel();
    }
    await Future.wait(sessions);
    await workspace.dispose();
    await _changes.close();
  }
}

String _assistantIdentity() {
  final random = Random.secure();
  return 'assistant-${List.generate(18, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

HandrailGatewayException _assistantFailure(
        Object cause, String code, String message) =>
    cause is HandrailGatewayException
        ? cause
        : HandrailGatewayException(code, message,
            retryable: cause is! FormatException && cause is! TypeError);
