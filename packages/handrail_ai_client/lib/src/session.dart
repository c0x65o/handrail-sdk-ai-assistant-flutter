part of '../handrail_ai_client.dart';

Map<String, Object?> _object(Object? value) =>
    Map<String, Object?>.from(value as Map);
List<Map<String, Object?>> _records(Object? value) =>
    List.unmodifiable((value as List? ?? const [])
        .map((item) => Map<String, Object?>.unmodifiable(_object(item))));

/// The server's canonical transcript and state, independent of any SSE observer.
class HandrailConversationDocument extends HandrailConversationView {
  final String conversationId;
  final int? revision;
  final Map<String, Object?> state;
  final List<Map<String, Object?>> messages;
  final List<Map<String, Object?>> turns;
  const HandrailConversationDocument._(this.conversationId, this.revision,
      this.state, this.messages, this.turns);

  factory HandrailConversationDocument.fromSnapshot(
      String conversationId, Map<String, Object?> snapshot) {
    final state =
        _immutableJson(_object(snapshot['state'])) as Map<String, Object?>;
    if (snapshot['conversationId'] != conversationId ||
        state['conversation_id'] != conversationId ||
        state['replay_error'] != null ||
        snapshot['revision'] != state['revision']) {
      throw const HandrailGatewayException('invalid_snapshot',
          'The saved conversation could not be synchronized.');
    }
    final activeTurn = state['active_turn_id'];
    final turns = _records(state['turns']);
    if (activeTurn != null &&
        turns
                .where((turn) =>
                    turn['turn_id'] == activeTurn &&
                    turn['remote_may_still_be_running'] == true &&
                    const ['queued', 'running', 'waiting_for_tool_result']
                        .contains(turn['status']))
                .length !=
            1) {
      throw const HandrailGatewayException('invalid_snapshot',
          'The saved running conversation could not be synchronized.');
    }
    return HandrailConversationDocument._(
        conversationId,
        snapshot['revision'] as int?,
        Map.unmodifiable(state),
        _records(state['messages']),
        _records(state['turns']));
  }

  @override
  bool get isPartial => false;
}

/// Read-only presentation contract. A view may contain a bounded window; it is
/// never valid input to canonical synchronization or model context construction.
abstract class HandrailConversationView {
  const HandrailConversationView();
  String get conversationId;
  int? get revision;
  Map<String, Object?> get state;
  List<Map<String, Object?>> get messages;
  List<Map<String, Object?>> get turns;
  bool get isPartial;
  Map<String, Object?>? get latestTurn => turns.isEmpty ? null : turns.last;
  String? get activeTurnId {
    final id = state['active_turn_id'] as String?;
    if (id == null) return null;
    final active = turns.where((turn) => turn['turn_id'] == id);
    if (active.isEmpty || active.single['remote_may_still_be_running'] != true)
      return null;
    return id;
  }

  HandrailConversationState get runtimeState {
    final turn = activeTurnId == null
        ? latestTurn
        : turns.firstWhere((turn) => turn['turn_id'] == activeTurnId);
    final turnId = turn?['turn_id'] as String?;
    final outputIds =
        (turn?['output_message_ids'] as List? ?? const []).toSet();
    final output = messages.where((message) =>
        message['role'] == 'assistant' &&
        (message['turn_id'] == turnId ||
            outputIds.contains(message['message_id'])));
    final status = switch (turn?['status']) {
      'queued' || 'running' => HandrailTurnStatus.running,
      'waiting_for_tool_result' => HandrailTurnStatus.waitingForTool,
      'waiting_for_approval' => HandrailTurnStatus.waitingForApproval,
      'completed' => HandrailTurnStatus.completed,
      'cancelled' => HandrailTurnStatus.cancelled,
      'failed' => HandrailTurnStatus.failed,
      _ => HandrailTurnStatus.idle,
    };
    return HandrailConversationState(
        conversationId: conversationId,
        turnId: turnId,
        status: status,
        text: output
            .expand((message) => _records(message['content']))
            .where((part) => part['type'] == 'text')
            .map((part) => part['text'] as String)
            .join(),
        supersededTurnIds: Set.unmodifiable(turns
            .map((turn) => turn['turn_id'] as String)
            .where((id) => id != turnId)),
        toolCalls: _records(state['tool_calls'])
            .where((tool) => tool['turn_id'] == turnId)
            .toList(growable: false),
        approvals: _records(state['approval_proposals']),
        citations: _records(state['citations']),
        attachments: _records(state['attachments']));
  }
}

/// Shared reload/reconnect orchestration. Observation never creates another run.
/// Hosts own authentication and rendering; this session owns serialized recovery.
class HandrailConversationSession {
  final HandrailAiClient client;
  final String conversationId;
  final HandrailConversationWorkspace workspace;
  final Duration? pollingInterval;
  final bool synchronizeActivity;

  /// Exact local cleanup after confirmed admission, including recovered replay.
  /// A failure keeps the caller's pending journal available for retry.
  final Future<void> Function(String, Map<String, Object?>)?
      reconcileAcceptedDraft;
  final bool _ownsWorkspace;
  final StreamController<HandrailConversationSession> _changes =
      StreamController.broadcast(sync: true);
  HandrailConversationView? _document;
  final _lifetime = Completer<void>();
  Completer<void> _displayActivation = Completer<void>();
  final Set<Completer<void>> _displayRequests = {};
  bool _displayActive = true;
  HandrailDisplayControl? _control;
  HandrailDisplayWindow? _displayWindow;
  StreamSubscription<HandrailDisplayWindowState>? _displaySubscription;
  List<HandrailDisplayRecord> _related = const [];
  bool _relatedTruncated = false;
  bool _relatedInitialized = false;
  int _relatedVersion = 0, _presentationVersion = 0;
  String? _publishedDisplayStamp;
  String? _relatedViewKey;
  List<Map<String, Object?>> _relatedGroups = const [];
  int _relatedGroup = 0;
  String? _relatedTurnId, _relatedCursor;
  int? _relatedRevision;
  int? _relatedWindowVersion;
  int _relatedEpoch = 0;
  List<String> _relatedMessageIds = const [];
  Future<void>? _loadingRelated;
  HandrailGatewayException? _error;
  HandrailGatewayCapabilities? _capabilities;
  Future<void>? _refreshing;
  Future<void>? _submitting;
  String? _submittingJson;
  HandrailTurnSubmission? _admittedSubmission;
  Map<String, Object?>? _outgoingMessage;
  String _outgoingStatus = 'sending';
  // The account controller can honor Stop queued before admission, before a
  // provider start is allowed. This is internal SDK orchestration, not a host hook.
  Future<bool> Function(HandrailTurnSubmission)? _mayStart;
  final _admissionCallbacks = <void Function(HandrailTurnSubmission)>[];
  Completer<void>? _startAcknowledgement;
  StreamSubscription<HandrailStreamFrame>? _observation;
  String? _observedTurnId;
  Map<String, Object?> _checkpoint = const {
    'lastAppliedEventId': null,
    'lastAppliedCursor': null,
    'lastAppliedRevision': null,
  };
  Timer? _timer;
  Timer? _streamRefreshTimer;
  int _observationGeneration = 0;
  bool _disposed = false;

  HandrailConversationSession(
      {required this.client,
      required this.conversationId,
      HandrailConversationWorkspace? workspace,
      this.pollingInterval = const Duration(seconds: 1),
      this.synchronizeActivity = true,
      this.reconcileAcceptedDraft})
      : workspace = workspace ?? HandrailConversationWorkspace(),
        _ownsWorkspace = workspace == null {
    if (pollingInterval != null &&
        pollingInterval! < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(pollingInterval, 'pollingInterval');
    }
  }
  HandrailConversationView? get document => _document;

  /// Local delivery feedback until this exact message appears in saved history.
  /// This is presentation only and never changes the canonical admission state.
  Map<String, Object?>? get outgoingMessage {
    final message = _outgoingMessage;
    if (message == null ||
        _document == null ||
        _displayWindow?.followingLatest == false) return null;
    if (_hasSavedMessage(message['message_id'])) return null;
    return Map.unmodifiable({
      ...message,
      'delivery_status': _outgoingStatus,
    });
  }

  bool _hasSavedMessage(Object? id) =>
      (_document?.messages.any((message) => message['message_id'] == id) ??
          false) ||
      (_displayWindow?.state.records.any((record) => record.id == id) ?? false);

  /// Available only when bounded history and scalar controls are negotiated.
  HandrailDisplayWindow? get displayWindow => _displayWindow;

  /// Release presentation pages when another chat is selected. Execution and
  /// scalar turn observation remain account-owned and are not cancelled.
  void _setDisplayActive(bool active) {
    if (_disposed || active == _displayActive) return;
    _displayActive = active;
    _displayActivation.complete();
    for (final request in _displayRequests) {
      if (!request.isCompleted) request.complete();
    }
    _displayActivation = Completer<void>();
    _relatedEpoch++;
    if (_related.isNotEmpty) _relatedVersion++;
    _related = const [];
    _relatedTruncated = false;
    _relatedViewKey = null;
    _relatedGroups = const [];
    _relatedGroup = 0;
    _relatedCursor = null;
    _relatedRevision = null;
    if (!active) {
      unawaited(_displayWindow?.select(null));
      if (_control != null) {
        _publishDisplay();
        _publish();
      }
    }
  }

  bool get supportsApprovalReview =>
      _capabilities?.displayHistory?.approvalReview == true;
  Future<HandrailApprovalDisplayReview> readApprovalReview(
      {required String proposalId,
      required int generation,
      String? binding,
      int offset = 0,
      Future<void>? cancellation}) async {
    if (_disposed ||
        !_displayActive ||
        !supportsApprovalReview ||
        generation != _control?.generation) {
      throw const HandrailGatewayException(
          'cancelled', 'Approval review is unavailable');
    }
    final activation = _displayActivation;
    final value = await _displayRead((closed) => client.displayApprovalReview(
        conversationId: conversationId,
        proposalId: proposalId,
        generation: generation,
        binding: binding,
        offset: offset,
        cancellation: Future.any([
          closed,
          activation.future,
          if (cancellation != null) cancellation
        ])));
    if (_disposed ||
        activation.isCompleted ||
        generation != _control?.generation) {
      throw const HandrailGatewayException(
          'cancelled', 'Approval review was cancelled');
    }
    return value;
  }

  bool get supportsPendingApprovals =>
      _capabilities?.displayHistory?.pendingApprovals == true;
  bool get hasPendingApprovals => _control?.hasPendingApprovals == true;

  /// Explicit bounded inbox or proposal/tool review, independent of messages.
  Future<HandrailDisplayPage> readApprovals(
      {String? proposalId, String? cursor, Future<void>? cancellation}) async {
    if (_disposed ||
        !_displayActive ||
        !supportsPendingApprovals ||
        _control == null ||
        _control!.preparing) {
      throw const HandrailGatewayException(
          'approval_inbox_unavailable', 'Pending approvals are unavailable.',
          retryable: true);
    }
    final generation = _control!.generation, activation = _displayActivation;
    final page = await _displayRead((closed) => client.displayHistoryPage(
        conversationId: conversationId,
        capability: _capabilities!.displayHistory!,
        view: proposalId == null
            ? {'type': 'pending_approvals'}
            : {'type': 'approval', 'proposalId': proposalId},
        cursor: cursor,
        limit: proposalId == null ? 30 : 2,
        maximumBytes: proposalId == null ? 65536 : 131072,
        cancellation: cancellation == null
            ? closed
            : Future.any([closed, cancellation])));
    if (_disposed || activation.isCompleted)
      throw StateError('Approval read cancelled');
    if (page.preparing ||
        page.generation != generation ||
        _control?.generation != generation ||
        page.revision < (_control?.revision ?? 0) ||
        page.revision < (_displayWindow?.state.revision ?? 0)) {
      throw const HandrailGatewayException(
          'stale_approvals', 'Approval details changed. Try again.',
          retryable: true);
    }
    return page;
  }

  bool get hasMoreRelated =>
      _relatedCursor != null || _relatedGroup + 1 < _relatedGroups.length;
  bool get relatedTruncated => _relatedTruncated;
  Future<void> showLatestRelated() async {
    if (_disposed) throw StateError('Conversation session is disposed');
    await _refreshing;
    _relatedViewKey = null;
    _relatedGroups = const [];
    _relatedGroup = 0;
    _relatedRevision = null;
    await refresh();
  }

  Future<void> loadMoreRelated() {
    if (_disposed)
      return Future.error(StateError('Conversation session is disposed'));
    if (!hasMoreRelated) return Future.value();
    return _loadingRelated ??= _readRelated().then((_) {
      if (!_disposed) {
        _error = null;
        _publishDisplay();
        _publish();
      }
    }).catchError((Object cause) async {
      if (_disposed) return;
      if (cause is HandrailGatewayException &&
          const {
            'forbidden',
            'permission_denied',
            'unauthenticated',
            'not_found'
          }.contains(cause.code)) {
        _control = null;
        _document = null;
        if (_related.isNotEmpty) _relatedVersion++;
        _related = const [];
        _relatedGroups = const [];
        _relatedGroup = 0;
        _relatedViewKey = null;
        _relatedTruncated = false;
        _relatedInitialized = false;
        _relatedCursor = null;
        _relatedEpoch++;
        _relatedRevision = null;
        await _displayWindow?.select(null);
      }
      _error = cause is HandrailGatewayException
          ? cause
          : const HandrailGatewayException('activity_unavailable',
              'Activity could not be loaded. Try again.',
              retryable: true);
      _publish();
      throw _error!;
    }).whenComplete(() {
      _loadingRelated = null;
    });
  }

  /// Targets only the currently running or latest paused request, never older work.
  Future<void> changeApprovalMode(String mode) async {
    if (_disposed ||
        !const ['required', 'automatic'].contains(mode) ||
        _capabilities?.resources['turnApprovalMode'] != true ||
        _document == null) {
      throw StateError('Approval settings are unavailable');
    }
    final latest = _document!.latestTurn;
    final turnId = _document!.activeTurnId ??
        (latest?['status'] == 'waiting_for_approval'
            ? (latest?['turn_id'] as String?)
            : null);
    if (turnId == null) return;
    final input = <String, Object?>{
      'conversationId': conversationId,
      'turnId': turnId
    };
    final current = _value(await client.turnApprovalMode(input));
    if (_disposed) throw StateError('The account has changed');
    if (current['active'] != true) return;
    if (current['revision'] is! int)
      throw const FormatException('Invalid approval setting');
    await client.turnApprovalMode({
      ...input,
      'mode': mode,
      'expectedRevision': current['revision'],
      'mutationId': _assistantIdentity()
    });
    if (_disposed) throw StateError('The account has changed');
    unawaited(refresh().catchError((Object _) {}));
  }

  HandrailGatewayCapabilities? get capabilities => _capabilities;
  HandrailGatewayException? get error => _error;
  bool get isRefreshing => _refreshing != null;
  bool get isSubmitting => _submitting != null;
  bool get observationConnected => _observation != null;
  Stream<HandrailConversationSession> get changes => _changes.stream;

  Future<void> initialize() async {
    try {
      await refresh();
    } finally {
      if (!_disposed &&
          _timer == null &&
          pollingInterval != null &&
          (_error == null || _error!.retryable)) {
        _timer = Timer.periodic(pollingInterval!, (_) {
          refresh().catchError((Object _) {});
        });
      }
    }
  }

  Future<void> refresh() {
    if (_disposed)
      return Future.error(StateError('Conversation session is disposed'));
    return _refreshing ??= _refresh().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<void> _refresh() async {
    try {
      _capabilities ??= await client.capabilities();
      if (_disposed) return;
      if (!_capabilities!.synchronization)
        throw const HandrailGatewayException('synchronization_unavailable',
            'Saved conversation synchronization is unavailable.');
      if (_capabilities!.displayHistory?.control == true) {
        await _refreshDisplay();
      } else {
        var pull = _document == null;
        if (!pull) {
          final result = _value(await client.synchronize({
            'operation': 'read_since',
            'input': {
              'conversationId': conversationId,
              'afterRevision': _document!.revision,
            }
          }));
          if (_disposed) return;
          if (result['status'] == 'snapshot_required') {
            pull = true;
          } else if (result['status'] == 'events') {
            pull = (result['events'] as List).isNotEmpty ||
                result['hasMore'] == true;
          } else {
            throw _syncFailure(result);
          }
        }
        if (pull) {
          final result = _value(await client.synchronize({
            'operation': 'pull_snapshot',
            'input': {'conversationId': conversationId}
          }));
          if (_disposed) return;
          if (result['status'] != 'snapshot') throw _syncFailure(result);
          final document = HandrailConversationDocument.fromSnapshot(
              conversationId, _object(result['snapshot']));
          if (_document?.revision != null &&
              document.revision != null &&
              document.revision! < _document!.revision!) {
            throw const HandrailGatewayException('stale_snapshot',
                'Saved conversation synchronization is temporarily behind.',
                retryable: true);
          }
          _document = document;
          workspace.open(document.runtimeState,
              select: workspace.snapshot.selectedConversationId == null);
        }
      }
      await _ensureObservation();
      if (_disposed) return;
      if (synchronizeActivity && _capabilities!.activity) {
        final records = await client.listActivity();
        if (_disposed) return;
        workspace.replaceRemoteActivity(records);
      }
      if (_disposed) return;
      _error = null;
      _publish();
    } catch (cause) {
      if (_disposed) return;
      if (_displayWindow != null &&
          cause is HandrailGatewayException &&
          const {
            'forbidden',
            'permission_denied',
            'unauthenticated',
            'not_found'
          }.contains(cause.code)) {
        _control = null;
        _document = null;
        if (_related.isNotEmpty) _relatedVersion++;
        _related = const [];
        _relatedTruncated = false;
        _relatedViewKey = null;
        _relatedGroups = const [];
        _relatedGroup = 0;
        _relatedCursor = null;
        _relatedEpoch++;
        _relatedRevision = null;
        _relatedInitialized = false;
        await _displayWindow!.select(null);
      }
      _error = cause is HandrailGatewayException
          ? cause
          : const HandrailGatewayException('synchronization_failed',
              'Conversation synchronization is temporarily unavailable.',
              retryable: true);
      _publish();
      throw _error!;
    }
  }

  Future<void> _ensureObservation() async {
    // Live canonical projection + bounded changes replace replaying a saved
    // provider event log just to show a running turn. A newly submitted turn
    // still observes its start acknowledgement and streamed activity below.
    if (_capabilities?.displayHistory?.control == true) return;
    if (_submitting != null) return;
    final active = _document?.activeTurnId;
    if (active == _observedTurnId && _observation != null) return;
    final changedTurn = active != _observedTurnId;
    await _disconnectObservation();
    if (_disposed || active == null) return;
    if (changedTurn)
      _checkpoint = const {
        'lastAppliedEventId': null,
        'lastAppliedCursor': null,
        'lastAppliedRevision': null
      };
    _observedTurnId = active;
    _observe(client.resumeTurn(
        conversationId: conversationId,
        turnId: active,
        resumeFrom: _checkpoint));
  }

  void _observe(Stream<HandrailStreamFrame> stream) {
    final generation = _observationGeneration;
    _observation = stream.listen((frame) {
      if (_disposed || generation != _observationGeneration) return;
      if (frame.type == 'started' &&
          _startAcknowledgement != null &&
          !_startAcknowledgement!.isCompleted) {
        if (frame.data['turnId'] != _observedTurnId ||
            frame.data['conversationId'] != conversationId) {
          _startAcknowledgement!.completeError(const HandrailGatewayException(
              'invalid_start', 'The server acknowledged a different turn.'));
        } else {
          _startAcknowledgement!.complete();
        }
      }
      final checkpoint = frame.data['checkpoint'] ??
          (frame.data['result'] is Map
              ? (frame.data['result'] as Map)['checkpoint']
              : null);
      if (checkpoint is Map)
        _checkpoint = Map.unmodifiable(_object(checkpoint));
      _scheduleStreamRefresh();
      // Render canonical snapshots. Replayed SSE text must not be appended to
      // text already loaded from the server snapshot a second time.
    }, onError: (Object cause) {
      if (_disposed || generation != _observationGeneration) return;
      _observation = null;
      _scheduleStreamRefresh();
      _error = cause is HandrailGatewayException
          ? cause
          : const HandrailGatewayException('observation_disconnected',
              'Reconnecting to the running conversation.',
              retryable: true);
      if (_startAcknowledgement != null && !_startAcknowledgement!.isCompleted)
        _startAcknowledgement!.completeError(_error!);
      _publish();
    }, onDone: () {
      if (_disposed || generation != _observationGeneration) return;
      _observation = null;
      _scheduleStreamRefresh();
      if (_startAcknowledgement != null && !_startAcknowledgement!.isCompleted)
        _startAcknowledgement!.completeError(const HandrailGatewayException(
            'start_unconfirmed',
            'The send response was lost. Retry the saved message.',
            retryable: true));
      _publish();
    }, cancelOnError: true);
  }

  void _scheduleStreamRefresh() {
    if (_disposed ||
        _capabilities?.displayHistory?.control != true ||
        _streamRefreshTimer != null) return;
    _streamRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      _streamRefreshTimer = null;
      if (!_disposed) unawaited(refresh().catchError((Object _) {}));
    });
  }

  /// Prepare once with a globally unique operation ID. The host saves the result
  /// in account-scoped storage before calling [submitTurn]. No write occurs here.
  Future<HandrailTurnSubmission> prepareTurn({
    required String operationId,
    required String clientId,
    required Map<String, Object?> request,
    Map<String, Object?>? localDraft,
  }) async {
    final origin = localDraft == null ? null : _draftOrigin(localDraft);
    final immutableRequest = _immutableJson(request) as Map<String, Object?>;
    if (_submitting != null) throw StateError('A message is being submitted');
    await refresh();
    if (_disposed) throw StateError('Conversation session is disposed');
    if (_document == null)
      throw const HandrailGatewayException(
          'history_preparing', 'The conversation is not ready to send.',
          retryable: true);
    if (_submitting != null || _document!.activeTurnId != null)
      throw const HandrailGatewayException('conversation_busy',
          'Wait for the running turn before sending another message.');
    return _prepareSubmission(
        conversationId: conversationId,
        revision: _document!.revision,
        operationId: operationId,
        clientId: clientId,
        request: immutableRequest,
        localDraft: origin);
  }

  /// Persists intent before any admission/start write. A failed/uncertain send
  /// retains its original IDs for [retryPendingMessage], including after reload.
  Future<HandrailTurnSubmission> sendMessage(
      {required String operationId,
      required String clientId,
      required Map<String, Object?> request,
      required HandrailPendingTurnStore pendingStore,
      Map<String, Object?>? localDraft,
      void Function(HandrailTurnSubmission)? onAccepted}) async {
    final submission = await prepareTurn(
        operationId: operationId,
        clientId: clientId,
        request: request,
        localDraft: localDraft);
    await pendingStore.retain(submission);
    await _submitRetained(submission, pendingStore, onAccepted);
    return submission;
  }

  Future<HandrailTurnSubmission?> retryPendingMessage(
      HandrailPendingTurnStore pendingStore,
      {void Function(HandrailTurnSubmission)? onAccepted}) async {
    final submission = await pendingStore.load(conversationId);
    if (submission == null) return null;
    await _submitRetained(submission, pendingStore, onAccepted);
    return submission;
  }

  Future<void> _submitRetained(
      HandrailTurnSubmission submission,
      HandrailPendingTurnStore pendingStore,
      void Function(HandrailTurnSubmission)? onAccepted) async {
    try {
      await submitTurn(submission, onAccepted: onAccepted);
    } on _RejectedAdmission {
      // A definite rejection admits nothing. Keep editable drafts/files while
      // releasing the exact journal so the user can correct the request.
      await pendingStore.acknowledge(submission);
      rethrow;
    }
    await pendingStore.acknowledge(submission);
  }

  /// Acknowledges admission/start, not completion. Repeating an uncertain send
  /// requires the exact saved submission; the server deduplicates both writes.
  /// [onAccepted] runs after durable admission receipts and local draft cleanup,
  /// before refreshing history or observing the provider response. Saved history
  /// may still lag; [outgoingMessage] supplies delivery feedback until it catches
  /// up. This is a presentation notification, not execution success.
  /// Callback failures cannot strand admitted work. Coalesced callers are notified too.
  Future<void> submitTurn(HandrailTurnSubmission submission,
      {void Function(HandrailTurnSubmission)? onAccepted}) {
    if (_disposed)
      return Future.error(StateError('Conversation session is disposed'));
    if (submission.conversationId != conversationId)
      return Future.error(
          ArgumentError('Submission belongs to another conversation'));
    final json = jsonEncode(submission.toJson());
    if (_submitting != null) {
      if (_submittingJson == json) {
        _registerAdmissionCallback(onAccepted);
        return _submitting!;
      }
      return Future.error(StateError('A different message is being submitted'));
    }
    _submittingJson = json;
    final outgoing = submission._message;
    if (_outgoingMessage?['message_id'] != outgoing['message_id'] ||
        _outgoingStatus != 'sent') _outgoingStatus = 'sending';
    _outgoingMessage = outgoing;
    _admittedSubmission = null;
    _admissionCallbacks.clear();
    _registerAdmissionCallback(onAccepted);
    final submitting =
        _submitting = _submitTurn(submission).catchError((Object cause) {
      if (_disposed) throw cause;
      if (cause is _RejectedAdmission) {
        _outgoingMessage = null;
      } else if (_outgoingStatus != 'sent') {
        _outgoingStatus = 'unconfirmed';
      }
      _error = cause is HandrailGatewayException
          ? cause
          : const HandrailGatewayException('send_unconfirmed',
              'The send response was lost. Retry the saved message.',
              retryable: true);
      _publish();
      throw _error!;
    }).whenComplete(() {
      _submitting = null;
      _submittingJson = null;
      _admittedSubmission = null;
      _admissionCallbacks.clear();
      _startAcknowledgement = null;
      _publish();
    });
    _publish();
    return submitting;
  }

  void _registerAdmissionCallback(
      void Function(HandrailTurnSubmission)? callback) {
    if (callback == null) return;
    final admitted = _admittedSubmission;
    if (admitted == null) {
      _admissionCallbacks.add(callback);
    } else {
      try {
        callback(admitted);
      } catch (_) {/* Presentation does not own the turn. */}
    }
  }

  void _publishAdmission(HandrailTurnSubmission submission) {
    if (_disposed) return;
    _admittedSubmission = submission;
    _outgoingStatus = 'sent';
    final callbacks = List.of(_admissionCallbacks);
    _admissionCallbacks.clear();
    for (final callback in callbacks) {
      if (_disposed) break;
      try {
        callback(submission);
      } catch (_) {/* Keep admitted work recoverable. */}
    }
    _publish();
  }

  Future<void> _submitTurn(HandrailTurnSubmission submission) async {
    await refresh();
    if (_disposed) throw StateError('Conversation session is disposed');
    final active = _document!.activeTurnId;
    if (active != null && active != submission.turnId)
      throw const HandrailGatewayException('conversation_busy',
          'Another turn is already running in this conversation.');
    final admitted = _value(await client.synchronize({
      'operation': 'append_mutations',
      'input': submission._admission,
    }));
    if (_disposed) throw StateError('Conversation session is disposed');
    if (admitted['status'] == 'conflict') {
      await refresh();
      throw const HandrailGatewayException('admission_conflict',
          'The conversation changed before this message was sent. Review it before sending again.');
    }
    if (admitted['status'] != 'mutations') throw _syncFailure(admitted);
    final acknowledgements = _records(admitted['acknowledgements']);
    final mutations = _records(submission._admission['mutations']);
    if (acknowledgements.length != mutations.length ||
        mutations.any((mutation) =>
            acknowledgements
                .where((ack) =>
                    ack['mutationId'] == mutation['mutationId'] &&
                    const ['accepted', 'duplicate'].contains(ack['status']))
                .length !=
            1)) {
      throw const HandrailGatewayException('admission_unconfirmed',
          'The message could not be confirmed. Retry the saved message.',
          retryable: true);
    }
    _outgoingStatus = 'sent';
    _publish();
    // The exact accepted/duplicate receipts prove durable admission. Clear the
    // submitted draft before potentially slow history/activity projection reads.
    // Keep the journal until start is acknowledged so lost starts remain safe.
    if (submission.localDraft case final origin?) {
      try {
        final cleanup = reconcileAcceptedDraft;
        if (cleanup == null) throw StateError('No local draft owner');
        await cleanup(conversationId, origin);
      } catch (_) {
        throw const HandrailGatewayException('draft_cleanup_failed',
            'Your message was saved, but its local draft could not be cleared. Retry the saved message.',
            retryable: true);
      }
    }
    if (_disposed) throw StateError('Conversation session is disposed');
    _publishAdmission(submission);
    if (_disposed) throw StateError('Conversation session is disposed');
    // Bounded gateways verify the turn using a small control read. Loading
    // messages and tools must not delay starting an already admitted response.
    if (_capabilities?.displayHistory?.control != true) await refresh();
    if (_disposed) throw StateError('Conversation session is disposed');
    final confirmed = await _findTurn(submission.turnId, publishControl: true);
    final turns =
        confirmed == null ? const <Map<String, Object?>>[] : [confirmed];
    if (turns.length != 1)
      throw const HandrailGatewayException('admission_unconfirmed',
          'The saved message is not visible yet. Retry the saved message.',
          retryable: true);
    if (_mayStart != null && !await _mayStart!(submission)) return;
    if (_disposed) throw StateError('Conversation session is disposed');
    // A lost start acknowledgement can arrive after the run finished. Never
    // restart a canonical terminal turn, even if its transport record expired.
    if (const ['completed', 'cancelled', 'failed', 'waiting_for_approval']
        .contains(confirmed!['status'])) return;
    await _disconnectObservation();
    if (_disposed) throw StateError('Conversation session is disposed');
    _observedTurnId = submission.turnId;
    _checkpoint = const {
      'lastAppliedEventId': null,
      'lastAppliedCursor': null,
      'lastAppliedRevision': null
    };
    final acknowledgement = _startAcknowledgement = Completer<void>();
    _observe(client.startTurn(submission._start));
    await acknowledgement.future;
  }

  Future<Map<String, Object?>?> _findTurn(String turnId,
      {bool publishControl = false}) async {
    if (_capabilities?.displayHistory?.control == true) {
      final control = await client.displayHistoryControl(
          conversationId: conversationId,
          turnId: turnId,
          capability: _capabilities!.displayHistory!,
          cancellation: _lifetime.future);
      if (_disposed) throw StateError('Conversation session is disposed');
      if (control.preparing)
        throw const HandrailGatewayException(
            'history_preparing', 'The saved turn is being prepared.',
            retryable: true);
      if (publishControl) {
        if (_control != null &&
            (control.generation != _control!.generation ||
                control.revision < _control!.revision)) {
          throw const HandrailGatewayException('stale_control',
              'Saved conversation controls changed. Retry the saved message.',
              retryable: true);
        }
        _control = control;
        _publishDisplay();
        _publish();
      }
      return control.requestedTurn == null
          ? null
          : _controlTurn(control.requestedTurn!);
    }
    return _document?.turns
        .where((turn) => turn['turn_id'] == turnId)
        .firstOrNull;
  }

  /// Observes the canonical terminal state without starting or cancelling work.
  /// Closing the account releases waiters; a view change does not interrupt them.
  /// Failed and cancelled outcomes are returned for host-specific presentation.
  /// Stops observing on cancellation; it never requests server cancellation.
  Future<Map<String, Object?>> waitForTurn(String turnId,
      {Future<void>? cancellation}) async {
    if (_disposed) throw StateError('Conversation session is disposed');
    final done = Completer<Map<String, Object?>>();
    bool reading = false;
    Future<void> inspect() async {
      if (done.isCompleted || reading) return;
      reading = true;
      try {
        final turn = await _findTurn(turnId);
        if (done.isCompleted) return;
        if (turn != null &&
            const ['completed', 'failed', 'cancelled', 'waiting_for_approval']
                .contains(turn['status'])) {
          done.complete(turn);
        }
      } catch (cause) {
        if (_disposed && !done.isCompleted) {
          done.completeError(const HandrailGatewayException(
              'observation_closed', 'The conversation account was closed.',
              retryable: true));
        } else if (!done.isCompleted &&
            cause is HandrailGatewayException &&
            !cause.retryable) done.completeError(cause);
      } finally {
        reading = false;
      }
    }

    if (cancellation != null)
      unawaited(cancellation.then((_) {
        if (!done.isCompleted)
          done.completeError(const HandrailGatewayException(
              'observation_cancelled', 'Stopped waiting for this response.',
              retryable: true));
      }));
    final subscription = changes.listen((_) => inspect(), onDone: () {
      if (!done.isCompleted) {
        done.completeError(const HandrailGatewayException(
            'observation_closed', 'The conversation account was closed.',
            retryable: true));
      }
    });
    try {
      inspect();
      return await done.future;
    } finally {
      await subscription.cancel();
    }
  }

  /// Requests server cancellation; status changes only after server confirmation.
  Future<void> requestCancellation(
      {required String mutationId,
      required String idempotencyKey,
      String? expectedTurnId}) async {
    if (_disposed) throw StateError('Conversation session is disposed');
    if (_document == null) await refresh();
    if (_capabilities?.authoritativeCancellation != true)
      throw const HandrailGatewayException(
          'cancellation_unavailable', 'Server cancellation is unavailable.');
    final turnId = _document?.activeTurnId;
    if (expectedTurnId != null && turnId != expectedTurnId) {
      final known = await _findTurn(expectedTurnId);
      if (known != null &&
          const ['completed', 'failed', 'cancelled', 'waiting_for_approval']
              .contains(known['status'])) return;
      throw const HandrailGatewayException('cancellation_target_changed',
          'The requested turn is not visible. Refresh before retrying cancellation.',
          retryable: true);
    }
    if (turnId == null) return;
    await client.cancelTurn({
      'conversationId': conversationId,
      'turnId': turnId,
      'mutationId': mutationId,
      'idempotencyKey': idempotencyKey,
      'reason': 'user'
    });
    if (!_disposed) await refresh();
  }

  Future<void> markRead() async {
    if (_disposed) throw StateError('Conversation session is disposed');
    final observed = workspace.remoteActivityFor(conversationId);
    if (observed == null || !observed.unread) return;
    final saved =
        await client.markActivityRead(conversationId, observed: observed);
    if (_disposed) return;
    if (saved != null) workspace.acceptRemoteActivity(saved);
    _publish();
  }

  Future<void> _disconnectObservation() async {
    if (_startAcknowledgement != null && !_startAcknowledgement!.isCompleted)
      _startAcknowledgement!
          .completeError(StateError('Turn observation was closed'));
    _observationGeneration++;
    final subscription = _observation;
    _observation = null;
    await subscription?.cancel();
  }

  void _publish() {
    if (_outgoingMessage != null &&
        _hasSavedMessage(_outgoingMessage!['message_id'])) {
      _outgoingMessage = null;
    }
    if (!_disposed) _changes.add(this);
  }

  Future<void> _forgetAfterDeletion() async {
    final closing = dispose();
    _document = null;
    _outgoingMessage = null;
    _error = null;
    _submittingJson = null;
    _checkpoint = const {
      'lastAppliedEventId': null,
      'lastAppliedCursor': null,
      'lastAppliedRevision': null
    };
    await closing;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_lifetime.isCompleted) _lifetime.complete();
    if (!_displayActivation.isCompleted) _displayActivation.complete();
    for (final request in _displayRequests) {
      if (!request.isCompleted) request.complete();
    }
    _displayRequests.clear();
    _relatedEpoch++;
    _control = null;
    _document = null;
    if (_related.isNotEmpty) _relatedVersion++;
    _related = const [];
    _relatedTruncated = false;
    _relatedViewKey = null;
    _relatedGroups = const [];
    _relatedGroup = 0;
    _relatedMessageIds = const [];
    _relatedCursor = null;
    _submittingJson = null;
    await _displaySubscription?.cancel();
    await _displayWindow?.dispose();
    _admissionCallbacks.clear();
    _admittedSubmission = null;
    _outgoingMessage = null;
    _timer?.cancel();
    _streamRefreshTimer?.cancel();
    await _disconnectObservation();
    await _changes.close();
    if (_ownsWorkspace) await workspace.dispose();
  }
}

Map<String, Object?> _value(Map<String, Object?> result) =>
    _object(result['value']);

class _RejectedAdmission extends HandrailGatewayException {
  const _RejectedAdmission(String message)
      : super('synchronization_rejected', message);
}

HandrailGatewayException _syncFailure(Map<String, Object?> result) {
  if (result['status'] == 'rejected') {
    final message = result['message'];
    return _RejectedAdmission(message is String &&
            message.isNotEmpty &&
            message.length <= 500
        ? message
        : 'This message could not be saved. Review it before sending again.');
  }
  return HandrailGatewayException(
      'synchronization_${result['status'] == 'unauthorized' ? 'unauthorized' : 'unavailable'}',
      'The saved conversation is currently unavailable.',
      retryable: result['status'] != 'unauthorized');
}

Object? _immutableJson(Object? value) {
  if (value is Map)
    return Map<String, Object?>.unmodifiable(value
        .map((key, child) => MapEntry(key as String, _immutableJson(child))));
  if (value is List)
    return List<Object?>.unmodifiable(value.map(_immutableJson));
  return value;
}
