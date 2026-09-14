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
      this.newConversationMetadata,
      this.deletionStore,
      this.approvalStore,
      this.loadApprovalReview,
      this.canDecideApproval,
      this.beforePendingRecovery,
      this.allowConversationManagement,
      Future<HandrailRealtimeWorkspacePage> Function(
              List<String>, HandrailRealtimeWorkspaceCursor?)?
          readVoiceWorkspace,
      this.voicePollingInterval = const Duration(seconds: 3)})
      : _createId = createId ?? _assistantIdentity {
    if (pageSize < 1 || pageSize > 100)
      throw ArgumentError.value(pageSize, 'pageSize');
    if (pollingInterval != null &&
        pollingInterval! < const Duration(milliseconds: 100))
      throw ArgumentError.value(pollingInterval, 'pollingInterval');
    _workspaceSubscription = workspace.changes.listen((_) => _publish());
    if (readVoiceWorkspace != null) {
      _voiceWorkspace = HandrailRealtimeWorkspaceMonitor(
          readPage: readVoiceWorkspace,
          pollingInterval: voicePollingInterval ?? const Duration(seconds: 3));
      _voiceSubscription = voiceWorkspace!.changes.listen((_) => _publish());
    }
  }

  /// Host-authorized voice observation belongs to this account, not a screen.
  /// Reading catalog/text never acknowledges calls or settles their effects.
  HandrailRealtimeWorkspaceMonitor? get voiceWorkspace => _voiceWorkspace;
  HandrailRealtimeWorkspaceMonitor? _voiceWorkspace;
  final Duration? voicePollingInterval;
  StreamSubscription<HandrailRealtimeWorkspaceState>? _voiceSubscription;
  String? _voiceIdentity;

  /// Additional live host permission gate for catalog mutations. Reads stay
  /// available; the gateway always performs authoritative authorization.
  final bool Function()? allowConversationManagement;
  bool get canManageConversations =>
      !_disposed && (allowConversationManagement?.call() ?? true);
  void _requireConversationManagement() {
    _assertActive();
    if (!canManageConversations) throw _conversationManagementDenied;
  }

  final HandrailAiClient client;
  final HandrailPendingTurnStore pendingStore;
  final HandrailConversationDeletionStore? deletionStore;
  final HandrailApprovalDecisionStore? approvalStore;

  /// Trusted host adapter must validate opaque argument references and identity.
  final Future<HandrailApprovalReview> Function(HandrailApprovalProposal)?
      loadApprovalReview;

  /// Additional domain permission gate; the gateway always reauthorizes.
  final bool Function(HandrailApprovalProposal, bool confirm)?
      canDecideApproval;
  late final approvals = HandrailApprovalDecisions._(this);
  final String clientId, newConversationTitle;
  final bool autoCreate;
  final int pageSize;
  final Duration? pollingInterval;
  final String Function() _createId;

  /// Business context sampled once for a new creation, retained across retries.
  final Map<String, Object?> Function()? newConversationMetadata;

  /// Capture a draft's original acceptance callback before recovering saved intent.
  final void Function()? Function(String conversationId)? beforePendingRecovery;
  final workspace = HandrailConversationWorkspace();
  final _sessions = <String, HandrailConversationSession>{};
  final _sessionSubscriptions =
      <StreamSubscription<HandrailConversationSession>>[];
  late final StreamSubscription<HandrailConversationWorkspaceSnapshot>
      _workspaceSubscription;
  final _changes = StreamController<HandrailAssistantController>.broadcast();
  final _descriptors = <String, HandrailConversationDescriptor>{};
  final _pending = <String>{}, _sending = <String>{}, _stopping = <String>{};
  final _operationErrors = <String, HandrailGatewayException>{};
  final _cancelKeys = <String, String>{};
  final _cancelBeforeStart = <String>{};
  final _cancelling = <String, Future<void>>{};
  final _lifecycleRequests = <String, Map<String, Object?>>{};
  final _lifecycleOperations = <String, Future<void>>{};
  final _lifecycleDirections = <String, bool>{};
  final _deletions = <String, HandrailConversationDeletionRequest>{};
  final _deletionOperations = <String, Future<void>>{};
  final _deletedIds = <String>{};
  HandrailGatewayCapabilities? _knownCatalogCapabilities;
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
  Future<void>? _readingActivity, _observing;
  Future<HandrailGatewayCapabilities>? _activityCapabilities;
  Timer? _pollTimer;
  Map<String, Object?>? _createRequest;
  HandrailConversationDescriptor? _createdDescriptor;
  bool _selecting = false;
  HandrailGatewayException? _historyError, _selectionError, _activityError;

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
      !_deletions.containsKey(_selectedId) &&
      document != null &&
      !archived &&
      _selectionError == null;
  bool get hasPendingMessage => _pending.contains(_selectedId);
  bool get stopping => _stopping.contains(_selectedId);
  bool get submitting => _sending.contains(_selectedId);
  bool get canStop =>
      !stopping &&
      (running ||
          submitting ||
          hasPendingMessage && _cancelBeforeStart.contains(_selectedId));
  bool get busy =>
      _selecting ||
      _creating != null ||
      _sending.contains(_selectedId) ||
      _lifecycleOperations.containsKey(_selectedId) ||
      _deletionOperations.containsKey(_selectedId);

  /// Account-wide work, including an unselected conversation's submission.
  bool get workingAnywhere =>
      _selecting ||
      _creating != null ||
      _sending.isNotEmpty ||
      _lifecycleOperations.isNotEmpty ||
      _deletionOperations.isNotEmpty ||
      approvals.hasPending ||
      _sessions.values.any((value) => value.document?.activeTurnId != null) ||
      workspace.snapshot.runningCount > 0;
  HandrailGatewayException? get historyError => _historyError ?? _activityError;
  HandrailGatewayException? get activityError => _activityError;
  HandrailGatewayException? get error =>
      _selectionError ?? _operationErrors[_selectedId];
  bool _isTextUnread(String id) =>
      workspace.snapshot.conversations
          .any((entry) => entry.state.conversationId == id && entry.unread) ||
      workspace.remoteActivityFor(id)?.unread == true;
  bool isUnread(String id) =>
      _isTextUnread(id) ||
      (voiceWorkspace?.state.forConversation(id).unreadCalls ?? 0) > 0;
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
    Future<void> Function(String, int) delete,
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
        delete: permanentlyDelete,
        view: (name) => setHistoryView(HandrailHistoryView.values.byName(name)),
        unread: setUnreadOnly,
        loadMore: () => refreshHistory(more: true),
        refresh: () async {
          try {
            await refreshHistory();
          } finally {
            await voiceWorkspace?.refresh();
          }
        }
      );
  Map<String, Object?> get historyPresentation => {
        'view': historyView.name,
        'unreadOnly': unreadOnly,
        'unreadCount': unreadCount,
        'selectedId': selectedId,
        'selectedTitle': selectedDescriptor?.title ?? newConversationTitle,
        'busy': busy,
        'canCreate': canManageConversations,
        'canManageConversations': canManageConversations,
        'catalogActions': {
          'archive': canManageConversations &&
              _supportsCatalogAction(_knownCatalogCapabilities, 'archive'),
          'restore': canManageConversations &&
              _supportsCatalogAction(_knownCatalogCapabilities, 'restore'),
          'permanentDelete': canManageConversations &&
              _deletionJournal != null &&
              _supportsCatalogAction(
                  _knownCatalogCapabilities, 'permanentDelete'),
        },
        'pendingDeletions': [
          for (final request in _deletions.values)
            {
              'id': request.conversationId,
              'version': request.expectedVersion,
              'busy': isDeleting(request.conversationId),
              'error': _operationErrors[request.conversationId]?.message,
            }
        ],
        'loading': loadingHistory,
        'hasMore': hasMoreHistory,
        'error': historyError?.message ?? error?.message,
        'voiceError': voiceWorkspace?.state.error,
        'voiceErrorCode': voiceWorkspace?.state.failure?.name,
        'rows': [
          for (final row in visibleHistory)
            {
              'id': row.id,
              'version': row.version,
              'deletionPending': hasPendingDeletion(row.id),
              'title': row.title ?? newConversationTitle,
              'preview': previewFor(row.id),
              'lifecycle': row.lifecycle,
              'updatedAt': row.json['updatedAt'],
              'unread': isUnread(row.id),
              'textUnread': _isTextUnread(row.id),
              if (voiceWorkspace != null) 'voice': _voicePresentation(row.id),
              'running': sessionFor(row.id)?.document?.activeTurnId != null ||
                  const [
                    HandrailTurnStatus.running,
                    HandrailTurnStatus.waitingForTool
                  ].contains(workspace.remoteActivityFor(row.id)?.status),
            }
        ],
      };

  /// Canonical transcript plus common recovery/read actions for the optional UI.
  ({
    Object scope,
    Stream<Object?> changes,
    Map<String, Object?> Function() read,
    Future<void> Function() retry,
    Future<void> Function() markRead
  }) get transcriptBinding => (
        scope: this,
        changes: changes,
        read: () => {
              'conversationId': selectedId,
              'document': document?.state,
              'loading': document == null &&
                  error == null &&
                  historyError == null &&
                  (busy || loadingHistory || !_loadedHistory),
              'busy': busy,
              'running': running,
              'submitting': submitting,
              'archived': archived,
              'pending': hasPendingMessage,
              'error': error?.message ??
                  session?.error?.message ??
                  (document == null ? historyError?.message : null),
            },
        retry: () =>
            selectedId == null ? initialize() : openConversation(selectedId!),
        markRead: markRead,
      );

  void _assertActive() {
    if (_disposed) throw StateError('Assistant account is closed');
  }

  Map<String, Object?> _voicePresentation(String id) {
    final state = voiceWorkspace!.state, summary = state.forConversation(id);
    return {
      'activeCalls': summary.activeCalls,
      'unconfirmedCalls': summary.unconfirmedCalls,
      'unreadCalls': summary.unreadCalls,
      'unresolvedTools': summary.unresolvedTools,
      'stale': !state.synchronized || state.error != null,
    };
  }

  Future<void> _setVoiceConversations(
      HandrailRealtimeWorkspaceMonitor monitor, List<String> ids) async {
    try {
      await monitor.setConversations(ids);
    } on ArgumentError {
      // The monitor publishes a stale, recoverable failure with retained
      // evidence. Catalog growth must not escape as an unhandled async error.
    }
  }

  void _publish() {
    if (_disposed) return;
    final monitor = voiceWorkspace;
    if (monitor != null) {
      final ids = _descriptors.keys
          .where((id) => !_deletedIds.contains(id))
          .toList()
        ..sort();
      final identity = jsonEncode(ids);
      if (identity != _voiceIdentity) {
        // Set before the monitor emits synchronously; text deltas must not
        // restart voice reads. Keep known archived/unselected rows observable.
        _voiceIdentity = identity;
        unawaited(_setVoiceConversations(monitor, ids));
        if (voicePollingInterval != null) monitor.startPolling();
      }
    }
    _changes.add(this);
  }

  Future<void> initialize() {
    _assertActive();
    if (_loadedHistory &&
        document != null &&
        _deletions.isEmpty &&
        !approvals.hasPending) return Future.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    try {
      await approvals.resume();
      await resumePendingDeletions();
      await refreshHistory();
      _assertActive();
      if (_createRequest != null && canManageConversations) {
        await newConversation();
        return;
      }
      final id = _selectedId != null && !hasPendingDeletion(_selectedId!)
          ? _selectedId
          : _history
              .where((row) => !hasPendingDeletion(row.id))
              .firstOrNull
              ?.id;
      if (id != null) {
        await openConversation(id);
      } else if (autoCreate &&
          canManageConversations &&
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
          if (_deletedIds.contains(row.id)) continue;
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
        _startPolling();
        if (!more) {
          try {
            await refreshActivity();
          } catch (_) {/* Keep valid catalog data. */}
        }
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
    if (_unreadOnly == value) return;
    _unreadOnly = value;
    _publish();
  }

  Future<HandrailConversationSession> ensureSession(String id) async {
    _assertConversationUsable(id);
    final existing = _sessions[id];
    if (existing?.document != null) return existing!;
    final value = _sessions.putIfAbsent(id, () {
      final session = HandrailConversationSession(
          client: client,
          conversationId: id,
          workspace: workspace,
          pollingInterval: null,
          synchronizeActivity: false);
      session._mayStart = (submission) async {
        if (!_cancelBeforeStart.remove(id)) return true;
        try {
          await _cancelTurn(id, submission.turnId);
          return false;
        } catch (_) {
          if (!_disposed) _cancelBeforeStart.add(id);
          rethrow;
        }
      };
      _sessionSubscriptions.add(session.changes.listen((_) => _publish()));
      return session;
    });
    await value.initialize();
    _assertConversationUsable(id);
    _knownCatalogCapabilities = value.capabilities ?? _knownCatalogCapabilities;
    _startPolling();
    return value;
  }

  /// Clears the visible selection without discarding drafts or stopping work.
  void clearSelection() {
    _assertActive();
    _selectionGeneration++;
    _selectedId = null;
    _selecting = false;
    _selectionError = null;
    workspace.select(null);
    _publish();
  }

  Future<HandrailConversationDescriptor> getDescriptor(String id) async {
    _assertConversationUsable(id);
    final value = HandrailConversationDescriptor.fromJson(_object(
        _object((await client.getConversation(id))['value'])['descriptor']));
    _assertConversationUsable(id);
    if (value.id != id)
      throw const FormatException('Conversation identity mismatch');
    final previous = _descriptors[id];
    final current =
        previous != null && previous.version > value.version ? previous : value;
    _rememberDescriptor(current);
    return current;
  }

  void _rememberDescriptor(HandrailConversationDescriptor row) {
    if (_deletedIds.contains(row.id)) return;
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
    _assertConversationUsable(id);
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
      _assertConversationUsable(id);
      _pending.add(id);
      final saved = await pendingStore.load(id);
      _assertConversationUsable(id);
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

  /// Retains creation identity until shared hydration and optional domain
  /// presentation finish. Retrying a failed [onReady] cannot create a duplicate.
  Future<void> newConversation(
      {Map<String, Object?>? metadata,
      Future<void> Function(String conversationId)? onReady}) {
    _assertActive();
    if (_creating != null) return _creating!;
    if (!canManageConversations)
      return Future.error(_conversationManagementDenied);
    final creationMetadata = _createRequest == null
        ? metadata ??
            newConversationMetadata?.call() ??
            const <String, Object?>{}
        : const <String, Object?>{};
    _createRequest ??= _immutableJson({
      'idempotencyKey': _createId(),
      'title': newConversationTitle,
      if (creationMetadata.isNotEmpty) 'metadata': creationMetadata
    }) as Map<String, Object?>;
    late final Future<void> operation;
    operation = Future<void>.microtask(() async {
      try {
        _selectionError = null;
        if (_createdDescriptor == null) {
          _requireConversationManagement();
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
        await onReady?.call(row.id);
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
    });
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
    _assertConversationUsable(id);
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
      if (!_pending.contains(id) && _cancelBeforeStart.remove(id))
        _stopping.remove(id);
      _publish();
    }
  }

  Future<HandrailTurnSubmission?> retryPendingMessage(
      {String? conversationId,
      void Function(HandrailTurnSubmission)? onAccepted}) async {
    _assertActive();
    final id = conversationId ?? _selectedId;
    if (id == null || _sending.contains(id)) return null;
    _assertConversationUsable(id);
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
    if (id == null || current == null || _stopping.contains(id)) return;
    if (turnId == null) {
      if (_sending.contains(id)) {
        _cancelBeforeStart.add(id);
        _stopping.add(id);
        _publish();
      }
      return;
    }
    if (_sending.contains(id)) _cancelBeforeStart.add(id);
    await _cancelTurn(id, turnId);
  }

  Future<void> _cancelTurn(String id, String turnId) {
    _assertActive();
    final identity = '$id:$turnId';
    return _cancelling[identity] ??= (() async {
      _stopping.add(id);
      _operationErrors.remove(id);
      _publish();
      try {
        final key = _cancelKeys.putIfAbsent(identity, _createId);
        await _sessions[id]!.requestCancellation(
            mutationId: 'cancel:$key',
            idempotencyKey: 'cancel:$key',
            expectedTurnId: turnId);
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
    })()
        .whenComplete(() {
      _cancelling.remove(identity);
    });
  }

  Future<void> markRead({String? conversationId}) async {
    final current = _sessions[conversationId ?? _selectedId];
    final latest = current?.document?.latestTurn;
    if (_disposed ||
        current == null ||
        current.document?.activeTurnId != null ||
        latest == null ||
        !const ['completed', 'failed', 'cancelled', 'waiting_for_approval'].contains(latest['status']))
      return;
    final observed = workspace.remoteActivityFor(current.conversationId);
    if (observed?.turnId != null && observed!.turnId != latest['turn_id'])
      return;
    await current.markRead();
  }

  void _startPolling() {
    if (_disposed || _pollTimer != null || pollingInterval == null) return;
    _pollTimer = Timer.periodic(pollingInterval!, (_) {
      unawaited(refreshObservations(refreshVoice: false));
    });
  }

  /// One account observation cycle. Active/selected sessions stay current;
  /// closed idle transcripts do not each poll the gateway or global activity.
  Future<void> refreshObservations({bool refreshVoice = true}) {
    _assertActive();
    if (refreshVoice) unawaited(voiceWorkspace?.refresh());
    return _observing ??= (() async {
      try {
        await refreshActivity();
      } catch (_) {/* Retry activity next cycle. */}
      if (_disposed) return;
      for (final entry in List.of(_sessions.entries)) {
        final id = entry.key, session = entry.value;
        final remote = workspace.remoteActivityFor(id);
        if (id != _selectedId &&
            session.document?.activeTurnId == null &&
            !_pending.contains(id) &&
            !_sending.contains(id) &&
            !const [
              HandrailTurnStatus.running,
              HandrailTurnStatus.waitingForTool
            ].contains(remote?.status)) continue;
        try {
          await session.refresh();
        } catch (_) {/* Session retains its error/state. */}
        if (_disposed) return;
      }
    })()
        .whenComplete(() {
      _observing = null;
    });
  }

  Future<HandrailGatewayCapabilities> _getActivityCapabilities() {
    for (final session in _sessions.values) {
      final known = session.capabilities;
      if (known != null) return Future.value(known);
    }
    return _activityCapabilities ??=
        client.capabilities().catchError((Object cause) {
      _activityCapabilities = null;
      throw cause;
    });
  }

  /// Coalesces the account-wide read across history, manual refresh and polling.
  /// A failed read retains prior activity and never changes send permissions.
  Future<void> refreshActivity() {
    _assertActive();
    return _readingActivity ??= (() async {
      try {
        final capability = await _getActivityCapabilities();
        if (_disposed) return;
        _knownCatalogCapabilities = capability;
        if (capability.activity) {
          final records = await client.listActivity();
          if (_disposed) return;
          workspace.replaceRemoteActivity(records);
        }
        _activityError = null;
      } catch (cause) {
        if (!_disposed)
          _activityError = _assistantFailure(cause, 'activity_unavailable',
              'Conversation activity could not be refreshed. Retry history.');
        rethrow;
      } finally {
        _publish();
      }
    })()
        .whenComplete(() {
      _readingActivity = null;
    });
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
    _requireConversationManagement();
    final result = await client.renameConversation({
      'conversationId': id,
      'expectedVersion': row.version,
      'idempotencyKey': 'title:$operationId',
      'title': normalized.length <= 80
          ? normalized
          : '${normalized.substring(0, 79)}…'
    });
    _assertActive();
    if (_deletedIds.contains(id)) return;
    _rememberDescriptor(HandrailConversationDescriptor.fromJson(
        _object(_object(result['value'])['descriptor'])));
    _invalidateHistoryRead();
    await refreshHistory();
  }

  Future<void> archive(String id) => _changeLifecycle(id, true);
  Future<void> restore(String id) => _changeLifecycle(id, false);
  Future<void> _changeLifecycle(String id, bool archive) {
    _assertConversationUsable(id);
    if (!canManageConversations)
      return Future.error(_conversationManagementDenied);
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
    operation = Future<void>.microtask(() async {
      try {
        final target = archive ? 'archived' : 'active';
        final row = _descriptors[id] ?? await getDescriptor(id);
        if (row.lifecycle == target && !_lifecycleRequests.containsKey(id))
          return;
        _requireConversationManagement();
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
    });
    _lifecycleOperations[id] = operation;
    _publish();
    return operation;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _historyGeneration++;
    _selectionGeneration++;
    // Stop the account-owned voice timer before the first asynchronous await.
    final closingVoice = voiceWorkspace?.dispose();
    final sessions =
        _sessions.values.map((session) => session.dispose()).toList();
    await _voiceSubscription?.cancel();
    await closingVoice;
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

const _conversationManagementDenied = HandrailGatewayException(
    'conversation_management_forbidden',
    'Your current access does not allow conversation changes.',
    retryable: false);
