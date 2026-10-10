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

  Future<T> _displayRead<T>(Future<T> Function(Future<void>) read,
      {bool count = true}) async {
    if (_disposed) throw StateError('Conversation session is disposed');
    if (count) _displayReadGeneration++;
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
    if (!capability.readBundle)
      return _refreshDisplayReads(preparation: preparation);
    final activation = _displayActivation, intent = _preparationGeneration;
    final window = _displayWindow;
    final windowIntent = window?._observationGeneration;
    final tailFromChanges = _displayActive &&
        preparation == null &&
        window != null &&
        window._pending == null &&
        window.state.status == 'ready' &&
        window.followingLatest &&
        window._changesCursor == null &&
        window.maximumMessages == 90 &&
        utf8
                .encode(
                    jsonEncode(window.state.records.map((r) => r.id).toList()))
                .length <=
            4096;
    final reads = <Map<String, Object?>>[
      {
        'operation': 'control',
        'input': {'conversationId': conversationId}
      },
      if (_displayActive && (window == null || window._pending == null))
        if (window == null || window.state.conversationId == null)
          {
            'operation': 'page',
            'input': {
              'conversationId': conversationId,
              'limit': 30,
              'maximumBytes': 65536
            }
          }
        else if (window.state.status == 'ready' && preparation == null)
          {
            'operation': 'changes',
            'input': {
              'conversationId': conversationId,
              'generation': window._generation,
              'afterRevision': window._changesAfter,
              'limit': window.pageSize,
              'maximumBytes': window.pageBytes,
              if (window._changesCursor != null) 'cursor': window._changesCursor
            }
          },
      if (_displayActive && supportsApprovalHistory)
        {
          'operation': 'page',
          'input': {
            'conversationId': conversationId,
            'limit': 30,
            'maximumBytes': 65536,
            'view': {'type': 'approval_history'},
            if (_approvalHistoryCursor != null) 'cursor': _approvalHistoryCursor
          }
        },
      if (_displayActive && _relatedGroups.isNotEmpty && !tailFromChanges)
        {
          'operation': 'page',
          'input': {
            'conversationId': conversationId,
            'limit': 30,
            'maximumBytes': 65536,
            'view': _relatedGroups.first
          }
        },
    ];
    final contextFromPage = reads.length <= 3 &&
        reads.length > 1 &&
        reads[1]['operation'] == 'page' &&
        (_object(reads[1]['input']))['view'] == null;
    final response = await _displayRead(
        (cancel) => client._displayRequest(
            'bundle',
            {
              'conversationId': conversationId,
              'reads': reads,
              if (contextFromPage) 'contextFromPage': 1,
              if (tailFromChanges)
                'tailFromChanges':
                    window.state.records.map((r) => r.id).toList()
            },
            5 * (capability.maximumPageBytes + 1024),
            cancel,
            const Duration(seconds: 30)),
        count: false);
    if (_disposed || activation.isCompleted) return;
    final raw = response['results'];
    if (raw is! List || raw.length != reads.length) {
      throw const FormatException('Invalid history bundle response.');
    }
    final values = raw.map((value) => _object(value)).toList();
    final head = values.first;
    HandrailDisplayPage? tail;
    if (response['tail'] != null) {
      if (!tailFromChanges)
        throw const FormatException('Unexpected bundled tail.');
      final entry = _object(response['tail']);
      final expected = {
        'conversationId': conversationId,
        'limit': window.pageSize,
        'maximumBytes': window.pageBytes
      };
      if (_bundleKey(entry['input']) != _bundleKey(expected))
        throw const FormatException('Invalid bundled tail request.');
      tail = HandrailDisplayPage.fromJson(_object(entry['value']));
      reads.add({'operation': 'page', 'input': expected});
      values.add(_object(entry['value']));
    }
    if (response['related'] != null) {
      if (!contextFromPage && !tailFromChanges)
        throw const FormatException('Unexpected bundled context.');
      final control = HandrailDisplayControl.fromJson(head);
      final page = tail ??
          (contextFromPage ? HandrailDisplayPage.fromJson(values[1]) : null);
      final removed = tailFromChanges
          ? HandrailDisplayChanges.fromJson(values[1])
              .page
              .records
              .where((r) => r.kind == 'message' && r.deleted)
              .map((r) => r.id)
              .toSet()
          : <String>{};
      final ids = page?.records.map((r) => r.id).toList() ??
          window!.state.records
              .where((r) => !removed.contains(r.id))
              .map((r) => r.id)
              .toList();
      final groups = _relatedViews(
          ids, (control.activeTurn ?? control.latestTurn)?.turnId);
      final related = _object(response['related']);
      final expected = {
        'conversationId': conversationId,
        'limit': 30,
        'maximumBytes': 65536,
        if (groups.isNotEmpty) 'view': groups.first
      };
      if (groups.isEmpty ||
          _bundleKey(related['input']) != _bundleKey(expected)) {
        throw const FormatException(
            'Bundled context does not cover the requested messages.');
      }
      reads.add({'operation': 'page', 'input': expected});
      values.add(_object(related['value']));
    }
    // Independent store reads can straddle a write. Such a bundle is not a
    // coherent witness; fall back to ordinary reads, preserving all guards.
    final coherent = identical(window, _displayWindow) &&
        windowIntent == window?._observationGeneration &&
        values.every((value) =>
            value['status'] == 'ready' &&
            value['conversationId'] == conversationId &&
            value['generation'] == head['generation'] &&
            value['revision'] == head['revision']);
    final bundle = _DisplayReadBundle(
        client,
        reads,
        values.map<Map<String, Object?>?>((v) => coherent ? v : null).toList(),
        () =>
            !_disposed &&
            !activation.isCompleted &&
            intent == _preparationGeneration &&
            (_control == null ||
                (_control!.generation == head['generation'] &&
                    _control!.revision <= (head['revision'] as int))) &&
            (_displayWindow == null ||
                _displayWindow!.state.revision <= (head['revision'] as int)));
    try {
      await _refreshDisplayReads(preparation: preparation, bundle: bundle);
    } finally {
      bundle.open = false;
    }
  }

  Future<void> _refreshDisplayReads(
      {_PreparedChanges? preparation, _DisplayReadBundle? bundle}) async {
    // Spend the previous merge receipt even if control/changes fail. A receipt
    // never replaces either authorized read or survives an uncertain refresh.
    final coverage = _relatedCoverage;
    _relatedCoverage = null;
    _relatedChangesEmpty = false;
    HandrailDisplayPage? mergedRelated;
    final capability = _capabilities!.displayHistory!;
    final activation = _displayActivation;
    late HandrailDisplayControl control;
    try {
      control = await _displayRead((cancellation) =>
          client._displayHistoryControl(
              bundle: bundle,
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
          onChanges: (page) {
            _relatedChangesEmpty = page.records.isEmpty;
            _mergeRelated(page.records, 'changes');
          });
      window._onExternalRead = () {
        _preparationGeneration++;
      };
      _displaySubscription = window.changes.listen((_) {
        if (_disposed) return;
        _publishDisplay();
        _publish();
        _scheduleDisplayRefresh();
      });
    }
    if (window.state.conversationId == null ||
        previous?.generation != control.generation) {
      await window._select(conversationId, bundle: bundle);
    } else if (!reuseChanges) {
      await window._refresh(bundle: bundle);
    }
    await window._settleSelection(conversationId);
    if (_disposed || activation.isCompleted) return;
    // Follow the tail even for an account session without an attached widget.
    // Reading older messages disables this; incoming work then sets hasNewer.
    if (window.state.hasNewer &&
        window.followingLatest &&
        window.state.error == null) {
      await window._jumpToLatest(bundle: bundle);
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
      await _readApprovalHistory(_approvalHistoryCursor, bundle: bundle);
      if (_disposed || activation.isCompleted) return;
    }
    final turn = control.activeTurn ?? control.latestTurn;
    if (coverage?.consume(this, control) == true) {
      _relatedRevision = control.revision;
    }
    if (turn?.turnId != _relatedTurnId ||
        control.revision != _relatedRevision ||
        _relatedWindowVersion != window.state.version ||
        previous?.generation != control.generation) {
      _relatedTurnId = turn?.turnId;
      _relatedRevision = null;
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
          mergedRelated = await _readRelated(latest: true, bundle: bundle);
          if (mergedRelated != null) _relatedRevision = control.revision;
        } catch (_) {
          _relatedRevision = null;
          rethrow;
        }
      } else {
        _relatedRevision = control.revision;
      }
    }
    if (_disposed || activation.isCompleted) return;
    _publishDisplay();
    if (mergedRelated != null) {
      _relatedCoverage = _RelatedCoverage.capture(this, mergedRelated);
    }
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

  Future<HandrailDisplayPage?> _readRelated(
      {bool latest = false, _DisplayReadBundle? bundle}) async {
    _relatedCoverage = null;
    final generation = _control?.generation, epoch = _relatedEpoch;
    final window = _displayWindow;
    final selection = window?._selection, version = window?._version;
    final windowRevision = _displayWindow?.state.revision;
    final group = latest
        ? 0
        : _relatedCursor != null
            ? _relatedGroup
            : _relatedGroup + 1;
    if (group >= _relatedGroups.length) return null;
    final activation = _displayActivation;
    late HandrailDisplayPage page;
    try {
      page = await _displayRead((cancellation) => client._displayHistoryPage(
          bundle: bundle,
          conversationId: conversationId,
          capability: _capabilities!.displayHistory!,
          view: _relatedGroups[group],
          cursor: latest ? null : _relatedCursor,
          cancellation: cancellation));
    } catch (_) {
      if (_disposed ||
          activation.isCompleted ||
          epoch != _relatedEpoch ||
          !identical(_displayWindow, window) ||
          !identical(window?._selection, selection) ||
          window?._version != version ||
          _displayWindow?.state.revision != windowRevision ||
          _control?.generation != generation) return null;
      rethrow;
    }
    if (_disposed ||
        activation.isCompleted ||
        epoch != _relatedEpoch ||
        !identical(_displayWindow, window) ||
        !identical(window?._selection, selection) ||
        window?._version != version ||
        _displayWindow?.state.revision != windowRevision ||
        _control?.generation != generation) return null;
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
    return page;
  }
}

// Coverage of one fully merged context view, separate from the control head
// which initiated it. Multi-group, paged, deferred and trimmed views deliberately
// remain ineligible: one group's revision cannot certify the other groups.
class _RelatedCoverage {
  final HandrailConversationSession session;
  final HandrailDisplayWindow window;
  final Completer<void> activation, selection;
  final int revision, generation, workspaceSelection, windowVersion;
  final int windowObservation, displayReads, preparation, observation;
  final int relatedEpoch, relatedVersion, approvalEpoch;
  final String? turnId;
  bool _used = false;

  _RelatedCoverage._(this.session, this.window, HandrailDisplayPage page)
      : revision = page.revision,
        generation = page.generation,
        activation = session._displayActivation,
        selection = window._selection,
        workspaceSelection = session.workspace._selectionGeneration,
        windowVersion = window._version,
        windowObservation = window._observationGeneration,
        displayReads = session._displayReadGeneration,
        preparation = session._preparationGeneration,
        observation = session._observationGeneration,
        relatedEpoch = session._relatedEpoch,
        relatedVersion = session._relatedVersion,
        approvalEpoch = session._approvalHistoryEpoch,
        turnId = session._relatedTurnId;

  static bool _settled(
          HandrailConversationSession s, HandrailDisplayWindow w) =>
      !s._disposed &&
      s._displayActive &&
      !s._displayActivation.isCompleted &&
      !s.workspace._changes.isClosed &&
      s.workspace._selectedConversationId == s.conversationId &&
      s._error == null &&
      s._refreshError == null &&
      s._streamRefreshTimer == null &&
      s._displayRequests.isEmpty &&
      s._loadingRelated == null &&
      s._loadingApprovalHistory == null &&
      !(s._approvalHistory?.records.any((r) => r.deferred) ?? false) &&
      s._relatedInitialized &&
      s._relatedGroups.length == 1 &&
      !s.hasMoreRelated &&
      !s._relatedTruncated &&
      !s._related.any((r) => r.deferred) &&
      !w._disposed &&
      identical(w.client, s.client) &&
      !w._selection.isCompleted &&
      w._conversationId == s.conversationId &&
      w._status == 'ready' &&
      w._generation == s._control?.generation &&
      w._pending == null &&
      w._queuedLatest == null &&
      w._readRequest == null &&
      w._contentRequest == null &&
      w._loading == null &&
      w._failedOperation == null &&
      w._error == null &&
      !w._hasNewer &&
      w.followingLatest &&
      !w._records.any((r) => r.deferred);

  static _RelatedCoverage? capture(
      HandrailConversationSession s, HandrailDisplayPage page) {
    final w = s._displayWindow, c = s._control;
    if (w == null ||
        c == null ||
        !_settled(s, w) ||
        page.preparing ||
        page.nextCursor != null ||
        page.records.any((r) => r.deferred) ||
        s._related.any((r) => r.revision > page.revision) ||
        w._changesCursor != null ||
        page.generation != c.generation ||
        page.activeTurnId != c.activeTurnId ||
        page.revision <= c.revision ||
        page.revision < w._revision) return null;
    return _RelatedCoverage._(s, w, page);
  }

  bool consume(HandrailConversationSession s, HandrailDisplayControl fresh) {
    if (_used) return false;
    _used = true;
    return identical(s, session) &&
        identical(s._displayWindow, window) &&
        identical(s._displayActivation, activation) &&
        identical(window._selection, selection) &&
        s.workspace._selectionGeneration == workspaceSelection &&
        window._version == windowVersion &&
        window._observationGeneration == windowObservation + 1 &&
        s._displayReadGeneration == displayReads + 1 &&
        s._preparationGeneration == preparation + 1 &&
        s._observationGeneration == observation &&
        s._relatedEpoch == relatedEpoch &&
        s._relatedVersion == relatedVersion &&
        s._approvalHistoryEpoch == approvalEpoch &&
        !s._displayRefreshRequested &&
        _settled(s, window) &&
        s._relatedChangesEmpty &&
        window._change == HandrailDisplayWindowOperation.changes &&
        window._consumedChanges &&
        window._changesCursor == null &&
        window._changesAfter == revision &&
        window._revision == revision &&
        !fresh.preparing &&
        fresh.conversationId == s.conversationId &&
        fresh.generation == generation &&
        fresh.revision == revision &&
        fresh.canonicalRevision == revision &&
        (fresh.activeTurn ?? fresh.latestTurn)?.turnId == turnId;
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
