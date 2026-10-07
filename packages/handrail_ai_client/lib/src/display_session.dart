part of '../handrail_ai_client.dart';

List<Map<String, Object?>> _relatedViews(
    List<String> messageIds, String? turnId) {
  final groups = <Map<String, Object?>>[];
  var ids = <String>[], turn = turnId;
  Map<String, Object?> view() => {
        'type': 'context',
        'messageIds': List.of(ids),
        if (turn != null) 'turnId': turn
      };
  for (final id in messageIds.reversed) {
    ids.add(id);
    if (utf8.encode(jsonEncode(view())).length > 2048) {
      ids.removeLast();
      groups.add(view());
      ids = [id];
      turn = null;
    }
  }
  if (ids.isNotEmpty || turn != null) groups.add(view());
  return groups;
}

Map<String, Object?> _controlTurn(HandrailDisplayTurnControl turn) =>
    Map.unmodifiable({
      'turn_id': turn.turnId,
      'status': turn.status,
      'remote_may_still_be_running': turn.remoteMayStillBeRunning,
      'cancellation_reason': turn.cancellationReason,
      'error': turn.error,
    });

bool _resolvedCitation(
        HandrailDisplayRecord record, List<HandrailDisplayRecord> related) =>
    record.value != null &&
    related.any((source) =>
        source.kind == 'source' &&
        !source.deleted &&
        source.value != null &&
        source.value!['source_id'] == record.value!['source_id']);

/// Explicit partial presentation document. It has no audit IDs, replay marker,
/// or checkpoint shape and cannot be parsed as a canonical snapshot.
class HandrailConversationDisplayView extends HandrailConversationView {
  final HandrailDisplayControl control;
  final HandrailDisplayWindowState window;
  @override
  final Map<String, Object?> state;
  HandrailConversationDisplayView._(
      this.control, this.window, List<HandrailDisplayRecord> related,
      {required bool hasMoreRelated,
      required int presentationVersion,
      Set<String> historicalApprovalIds = const {}})
      : state = Map.unmodifiable({
          'conversation_id': control.conversationId,
          'revision': control.revision,
          'active_turn_id': control.activeTurnId,
          'display_history': Map.unmodifiable({
            'partial': true,
            'version': presentationVersion,
            'generation': window.generation,
            'hasOlder': window.hasOlder,
            'hasNewer': window.hasNewer,
            'hasMoreRelated': hasMoreRelated,
            'unresolvedCitationCount': related
                .where((record) =>
                    record.kind == 'citation' &&
                    !record.deleted &&
                    !_resolvedCitation(record, related))
                .length
          }),
          'messages': List.unmodifiable(window.records
              .where((r) => r.value != null)
              .map((r) => Map<String, Object?>.unmodifiable(
                  {...r.value!, if (r.turnId != null) 'turn_id': r.turnId}))),
          'turns': List.unmodifiable([
            if (control.activeTurn != null &&
                control.activeTurn!.turnId != control.latestTurn?.turnId)
              _controlTurn(control.activeTurn!),
            if (control.latestTurn != null) _controlTurn(control.latestTurn!),
          ]),
          for (final entry in {
            'tool': 'tool_calls',
            'approval': 'approval_proposals',
            'citation': 'citations',
            'source': 'citation_sources',
            'budget': 'tool_loop_budget_exhaustions'
          }.entries)
            entry.value: List.unmodifiable(related
                .where((r) =>
                    r.kind == entry.key &&
                    r.value != null &&
                    (r.kind != 'citation' || _resolvedCitation(r, related)))
                .map((r) => r.value!)),
          'deferred_records': List.unmodifiable([...window.records, ...related]
              .where((r) =>
                  r.deferred &&
                  !(r.kind == 'approval' &&
                      historicalApprovalIds.contains(r.id)))
              .map((r) => Map.unmodifiable({
                    'kind': r.kind,
                    'id': r.id,
                    'revision': r.revision,
                    'bytes': r.bytes
                  }))),
        });
  @override
  String get conversationId => control.conversationId;
  @override
  // Canonical admission uses null for an empty log; the display wire uses zero.
  int? get revision =>
      control.canonicalRevision == 0 ? null : control.canonicalRevision;
  @override
  bool get isPartial => true;
  @override
  List<Map<String, Object?>> get messages =>
      (state['messages'] as List).cast<Map<String, Object?>>();
  @override
  List<Map<String, Object?>> get turns =>
      (state['turns'] as List).cast<Map<String, Object?>>();
}

extension _HandrailBoundedSession on HandrailConversationSession {
  void _scheduleDisplayRefresh() {
    final window = _displayWindow?.state;
    if (_disposed ||
        !_displayActive ||
        window == null ||
        window.conversationId != conversationId ||
        window.status != 'ready' ||
        window.generation != _control?.generation ||
        window.version == _relatedWindowVersion) return;
    if (_refreshing != null) {
      // A navigation arriving during related reads must not lose its wakeup.
      _displayRefreshRequested = true;
    } else {
      _scheduleStreamRefresh();
    }
  }

  Future<T> _displayRead<T>(Future<T> Function(Future<void>) read) async {
    if (_disposed) throw StateError('Conversation session is disposed');
    _displayReadGeneration++;
    final request = Completer<void>();
    _displayRequests.add(request);
    try {
      return await read(request.future);
    } finally {
      if (!request.isCompleted) request.complete();
      _displayRequests.remove(request);
    }
  }

  Future<void> _refreshDisplay({_PreparedChanges? preparation}) async {
    final capability = _capabilities!.displayHistory!;
    final activation = _displayActivation;
    late HandrailDisplayControl control;
    try {
      control = await _displayRead((cancellation) =>
          client.displayHistoryControl(
              conversationId: conversationId,
              capability: capability,
              cancellation: cancellation));
    } catch (_) {
      if (_disposed || activation.isCompleted) return;
      rethrow;
    }
    if (_disposed || activation.isCompleted) return;
    if (control.preparing) {
      _document = null;
      throw const HandrailGatewayException(
          'history_preparing', 'Preparing saved conversation…',
          retryable: true);
    }
    if (_control != null && control.revision < _control!.revision) {
      throw const HandrailGatewayException('stale_control',
          'Saved conversation controls are temporarily behind.',
          retryable: true);
    }
    // Always authorize/read control first. The witness is spent even when its
    // predicate fails; all uncertain cases retain the ordinary window read.
    final reuseChanges = preparation?.consume(this, control) ?? false;
    final previous = _control;
    if (previous?.generation != control.generation) {
      if (previous != null) _outgoingMessage = null;
      _clearApprovalHistory();
      _relatedEpoch++;
      if (_related.isNotEmpty) _relatedVersion++;
      _related = const [];
      _relatedTruncated = false;
      _relatedViewKey = null;
      _relatedGroups = const [];
      _relatedGroup = 0;
      _relatedCursor = null;
      _relatedRevision = null;
    }
    _control = control;
    if (!_displayActive) {
      _publishDisplay();
      return;
    }
    var window = _displayWindow;
    if (window == null) {
      window = _displayWindow = HandrailDisplayWindow(
          client: client,
          capability: capability,
          onChanges: (page) => _mergeRelated(page.records, 'changes'));
      _displaySubscription = window.changes.listen((_) {
        if (_disposed) return;
        _publishDisplay();
        _publish();
        _scheduleDisplayRefresh();
      });
    }
    if (window.state.conversationId == null ||
        previous?.generation != control.generation) {
      await window.select(conversationId);
    } else if (!reuseChanges) {
      await window.refresh();
    }
    await window._settleSelection(conversationId);
    if (_disposed || activation.isCompleted) return;
    // Follow the tail even for an account session without an attached widget.
    // Reading older messages disables this; incoming work then sets hasNewer.
    if (window.state.hasNewer &&
        window.followingLatest &&
        window.state.error == null) {
      await window.jumpToLatest();
      await window._settleSelection(conversationId);
    }
    if (_disposed || activation.isCompleted) return;
    if (window.state.error != null) throw window.state.error!;
    if (window.state.conversationId != conversationId ||
        window.state.status != 'ready' ||
        window.state.generation != control.generation) {
      _document = null;
      throw const HandrailGatewayException(
          'history_preparing', 'Preparing saved conversation…',
          retryable: true);
    }
    if (supportsApprovalHistory &&
        _approvalHistory?.revision != control.revision) {
      await _readApprovalHistory(_approvalHistoryCursor);
      if (_disposed || activation.isCompleted) return;
    }
    final turn = control.activeTurn ?? control.latestTurn;
    if (turn?.turnId != _relatedTurnId ||
        control.revision != _relatedRevision ||
        _relatedWindowVersion != window.state.version ||
        previous?.generation != control.generation) {
      _relatedTurnId = turn?.turnId;
      _relatedRevision = control.revision;
      _relatedWindowVersion = window.state.version;
      _relatedEpoch++;
      _relatedMessageIds = window.state.records.map((r) => r.id).toList();
      final viewKey =
          jsonEncode([control.generation, turn?.turnId, _relatedMessageIds]);
      if (_relatedViewKey != viewKey) {
        if (_related.isNotEmpty) _relatedVersion++;
        _related = const [];
        _relatedTruncated = false;
        _relatedCursor = null;
        _relatedGroups = _relatedViews(_relatedMessageIds, turn?.turnId);
        _relatedGroup = 0;
        _relatedInitialized = false;
      }
      _relatedViewKey = viewKey;
      if (turn != null || _relatedMessageIds.isNotEmpty) {
        try {
          await _readRelated(latest: true);
        } catch (_) {
          _relatedRevision = null;
          rethrow;
        }
      }
    }
    if (_disposed || activation.isCompleted) return;
    _publishDisplay();
  }

  void _publishDisplay() {
    final control = _control;
    final window = !_displayActive && control != null
        ? HandrailDisplayWindowState._(
            conversationId: conversationId,
            status: 'ready',
            generation: control.generation,
            revision: control.revision)
        : _displayWindow?.state;
    if (control == null ||
        window == null ||
        window.status != 'ready' ||
        window.generation != control.generation ||
        window.conversationId != conversationId) {
      _document = null;
      return;
    }
    final stamp =
        '${control.generation}/${control.revision}/${window.version}/$_relatedVersion/$_displayActive';
    if (_publishedDisplayStamp != stamp) {
      _publishedDisplayStamp = stamp;
      _presentationVersion++;
    }
    // Settled history has its own bounded page. Context changes must neither
    // remove it nor inflate it with duplicate observations of the same proposal.
    final activity = supportsApprovalHistory
        ? [
            ..._related.where((r) =>
                r.kind != 'approval' ||
                !const ['executed', 'rejected', 'expired']
                    .contains(r.value?['status'])),
            ...?_approvalHistory?.records,
          ]
        : _related;
    final byIdentity = <String, HandrailDisplayRecord>{};
    for (final record in activity) {
      final key = '${record.kind}/${record.id}', previous = byIdentity[key];
      if (previous == null || previous.revision < record.revision)
        byIdentity[key] = record;
    }
    _document = HandrailConversationDisplayView._(
        control, window, byIdentity.values.toList(),
        hasMoreRelated: hasMoreRelated,
        historicalApprovalIds:
            _approvalHistory?.records.map((r) => r.id).toSet() ?? const {},
        presentationVersion: _presentationVersion);
    workspace.open(_document!.runtimeState,
        select: _displayActive &&
            workspace.snapshot.selectedConversationId == null);
  }

  void _mergeRelated(List<HandrailDisplayRecord> incoming, String direction) {
    String key(HandrailDisplayRecord record) =>
        jsonEncode([record.kind, record.id]);
    final old = {for (final record in _related) key(record): record};
    final updates = {for (final record in incoming) key(record): record};
    final merged = <String, HandrailDisplayRecord>{};
    for (final record in direction == 'older'
        ? [...incoming, ..._related]
        : [..._related, ...incoming]) {
      final id = key(record), previous = old[id], update = updates[id];
      if (direction == 'changes' && previous == null) continue;
      final value = previous != null &&
              (update == null || previous.revision >= update.revision)
          ? previous
          : update ?? record;
      if (!value.deleted && value.kind != 'message') merged[id] = value;
    }
    final records = merged.values.toList();
    final sizes = records
        .map((record) =>
            utf8
                .encode(jsonEncode({
                  'kind': record.kind,
                  'id': record.id,
                  'turnId': record.turnId,
                  'revision': record.revision,
                  'bytes': record.bytes,
                  'deferred': record.deferred,
                  'value': record.value,
                }))
                .length +
            1)
        .toList();
    var bytes = sizes.fold<int>(2, (sum, size) => sum + size);
    while (records.length > 90 || bytes > 262144) {
      final index = direction == 'older' ? records.length - 1 : 0;
      records.removeAt(index);
      bytes -= sizes.removeAt(index);
      _relatedTruncated = true;
    }
    if (records.length != _related.length ||
        records
            .asMap()
            .entries
            .any((entry) => !identical(entry.value, _related[entry.key]))) {
      _related = List.unmodifiable(records);
      _relatedVersion++;
    }
  }

  Future<void> _readRelated({bool latest = false}) async {
    final generation = _control?.generation, epoch = _relatedEpoch;
    final windowRevision = _displayWindow?.state.revision;
    final group = latest
        ? 0
        : _relatedCursor != null
            ? _relatedGroup
            : _relatedGroup + 1;
    if (group >= _relatedGroups.length) return;
    final activation = _displayActivation;
    late HandrailDisplayPage page;
    try {
      page = await _displayRead((cancellation) => client.displayHistoryPage(
          conversationId: conversationId,
          capability: _capabilities!.displayHistory!,
          view: _relatedGroups[group],
          cursor: latest ? null : _relatedCursor,
          cancellation: cancellation));
    } catch (_) {
      if (_disposed || activation.isCompleted || epoch != _relatedEpoch) return;
      rethrow;
    }
    if (_disposed ||
        activation.isCompleted ||
        epoch != _relatedEpoch ||
        _displayWindow?.state.revision != windowRevision ||
        _control?.generation != generation) return;
    if (page.preparing || page.generation != generation) {
      _relatedRevision = null;
      throw const HandrailGatewayException(
          'history_preparing', 'Preparing saved activity…',
          retryable: true);
    }
    if (page.revision < (windowRevision ?? 0)) {
      throw const HandrailGatewayException(
          'stale_activity', 'Saved activity is temporarily behind. Try again.',
          retryable: true);
    }
    final initial = !_relatedInitialized;
    _mergeRelated(page.records, latest ? 'latest' : 'older');
    _relatedInitialized = true;
    if (!latest || initial) {
      _relatedCursor = page.nextCursor;
      _relatedGroup = group;
    }
  }
}

// One immediate send's local proof, never serialized or exposed to hosts. The
// account-owned session/client must be disposed on identity changes, as required
// by the existing controller contract. This grants no authorization or CAS.
class _PreparedChanges {
  final HandrailConversationSession session;
  final HandrailDisplayControl control;
  final HandrailDisplayWindow window;
  final Completer<void> activation, selection;
  final int workspaceSelection, windowVersion;
  final int preparationGeneration, displayReadGeneration, observationGeneration;
  final int windowObservation, relatedEpoch, relatedVersion, approvalEpoch;
  final int? documentRevision;
  bool _used = false;

  _PreparedChanges._(this.session, this.control, this.window)
      : activation = session._displayActivation,
        selection = window._selection,
        workspaceSelection = session.workspace._selectionGeneration,
        windowVersion = window._version,
        preparationGeneration = session._preparationGeneration,
        displayReadGeneration = session._displayReadGeneration,
        observationGeneration = session._observationGeneration,
        windowObservation = window._observationGeneration,
        relatedEpoch = session._relatedEpoch,
        relatedVersion = session._relatedVersion,
        approvalEpoch = session._approvalHistoryEpoch,
        documentRevision = session._document!.revision;

  static bool _settled(HandrailConversationSession s, HandrailDisplayControl c,
          HandrailDisplayWindow w) =>
      !s._disposed &&
      s._displayActive &&
      !s._displayActivation.isCompleted &&
      !s.workspace._changes.isClosed &&
      s.workspace._selectedConversationId == s.conversationId &&
      s._document is HandrailConversationDisplayView &&
      s._document!.conversationId == s.conversationId &&
      s._document!.activeTurnId == null &&
      s._error == null &&
      s._refreshError == null &&
      !s._displayRefreshRequested &&
      s._streamRefreshTimer == null &&
      s._displayRequests.isEmpty &&
      s._loadingRelated == null &&
      s._loadingApprovalHistory == null &&
      !s.hasMoreRelated &&
      !s._relatedTruncated &&
      !s._related.any((record) => record.deferred) &&
      !(s._approvalHistory?.records.any((record) => record.deferred) ??
          false) &&
      !c.preparing &&
      c.activeTurnId == null &&
      c.conversationId == s.conversationId &&
      c.canonicalRevision == c.revision &&
      !w._disposed &&
      identical(w.client, s.client) &&
      !w._selection.isCompleted &&
      w._conversationId == s.conversationId &&
      w._status == 'ready' &&
      w._generation == c.generation &&
      w._revision == c.revision &&
      w._changesAfter == c.revision &&
      w._changesCursor == null &&
      w._consumedChanges &&
      w._change == HandrailDisplayWindowOperation.changes &&
      w._pending == null &&
      w._queuedLatest == null &&
      w._readRequest == null &&
      w._contentRequest == null &&
      w._loading == null &&
      w._failedOperation == null &&
      w._error == null &&
      !w._hasNewer &&
      w.followingLatest &&
      !w._records.any((record) => record.deferred);

  static _PreparedChanges? capture(HandrailConversationSession session,
      {required int? preparedRevision}) {
    final control = session._control, window = session._displayWindow;
    if (control == null ||
        window == null ||
        session._refreshing != null ||
        session._document?.revision != preparedRevision ||
        !_settled(session, control, window)) return null;
    return _PreparedChanges._(session, control, window);
  }

  bool consume(
      HandrailConversationSession current, HandrailDisplayControl fresh) {
    if (_used) return false;
    _used = true;
    return identical(current, session) &&
        identical(current._displayWindow, window) &&
        identical(current._displayActivation, activation) &&
        identical(current._control, control) &&
        identical(window._selection, selection) &&
        current.workspace._selectionGeneration == workspaceSelection &&
        window._version == windowVersion &&
        current._document?.revision == documentRevision &&
        current._preparationGeneration == preparationGeneration + 1 &&
        current._displayReadGeneration == displayReadGeneration + 1 &&
        current._observationGeneration == observationGeneration &&
        window._observationGeneration == windowObservation &&
        current._relatedEpoch == relatedEpoch &&
        current._relatedVersion == relatedVersion &&
        current._approvalHistoryEpoch == approvalEpoch &&
        _settled(current, control, window) &&
        !fresh.preparing &&
        fresh.activeTurnId == null &&
        fresh.conversationId == control.conversationId &&
        fresh.generation == control.generation &&
        fresh.canonicalRevision == control.canonicalRevision &&
        fresh.revision == control.revision;
  }
}
