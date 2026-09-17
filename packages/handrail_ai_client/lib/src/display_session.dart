part of '../handrail_ai_client.dart';

Map<String, Object?> _controlTurn(HandrailDisplayTurnControl turn) =>
    Map.unmodifiable({
      'turn_id': turn.turnId,
      'status': turn.status,
      'remote_may_still_be_running': turn.remoteMayStillBeRunning,
      'error': turn.error,
    });

/// Explicit partial presentation document. It has no audit IDs, replay marker,
/// or checkpoint shape and cannot be parsed as a canonical snapshot.
class HandrailConversationDisplayView extends HandrailConversationView {
  final HandrailDisplayControl control;
  final HandrailDisplayWindowState window;
  @override
  final Map<String, Object?> state;
  HandrailConversationDisplayView._(
      this.control, this.window, List<HandrailDisplayRecord> related,
      {required bool hasMoreRelated})
      : state = Map.unmodifiable({
          'conversation_id': control.conversationId,
          'revision': control.revision,
          'active_turn_id': control.activeTurnId,
          'display_history': Map.unmodifiable({
            'partial': true,
            'generation': window.generation,
            'hasOlder': window.hasOlder,
            'hasNewer': window.hasNewer,
            'hasMoreRelated': hasMoreRelated
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
                .where((r) => r.kind == entry.key && r.value != null)
                .map((r) => r.value!)),
          'deferred_records': List.unmodifiable([...window.records, ...related]
              .where((r) => r.deferred)
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
  Future<void> _refreshDisplay() async {
    final capability = _capabilities!.displayHistory!;
    final activation = _displayActivation;
    late HandrailDisplayControl control;
    try {
      control = await client.displayHistoryControl(
          conversationId: conversationId,
          capability: capability,
          cancellation: Future.any([_lifetime.future, activation.future]));
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
    final previous = _control;
    if (previous?.generation != control.generation) {
      _relatedEpoch++;
      _related = const [];
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
      window = _displayWindow =
          HandrailDisplayWindow(client: client, capability: capability);
      _displaySubscription = window.changes.listen((_) {
        if (_disposed) return;
        _publishDisplay();
        _publish();
        if (_refreshing == null &&
            _relatedWindowVersion != _displayWindow!.state.version)
          _scheduleStreamRefresh();
      });
    }
    if (window.state.conversationId == null ||
        previous?.generation != control.generation) {
      await window.select(conversationId);
    } else {
      await window.refresh();
    }
    if (_disposed || activation.isCompleted) return;
    // Follow the tail even for an account session without an attached widget.
    // Reading older messages disables this; incoming work then sets hasNewer.
    if (window.state.hasNewer &&
        window.followingLatest &&
        window.state.error == null) {
      await window.jumpToLatest();
    }
    if (_disposed || activation.isCompleted) return;
    if (window.state.error != null) throw window.state.error!;
    if (window.state.status != 'ready' ||
        window.state.generation != control.generation) {
      _document = null;
      throw const HandrailGatewayException(
          'history_preparing', 'Preparing saved conversation…',
          retryable: true);
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
      _related = const [];
      _relatedCursor = null;
      if (turn != null || _relatedMessageIds.isNotEmpty) {
        try {
          await _readRelated();
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
    _document = HandrailConversationDisplayView._(control, window, _related,
        hasMoreRelated: _relatedCursor != null);
    workspace.open(_document!.runtimeState,
        select: _displayActive &&
            workspace.snapshot.selectedConversationId == null);
  }

  Future<void> _readRelated() async {
    final turnId = _relatedTurnId,
        generation = _control?.generation,
        epoch = _relatedEpoch;
    final activation = _displayActivation;
    late HandrailDisplayPage page;
    try {
      page = await client.displayHistoryPage(
          conversationId: conversationId,
          capability: _capabilities!.displayHistory!,
          view: {
            'type': 'context',
            'messageIds': _relatedMessageIds,
            if (turnId != null) 'turnId': turnId
          },
          cursor: _relatedCursor,
          cancellation: Future.any([_lifetime.future, activation.future]));
    } catch (_) {
      if (_disposed || activation.isCompleted || epoch != _relatedEpoch) return;
      rethrow;
    }
    if (_disposed ||
        epoch != _relatedEpoch ||
        _control?.generation != generation) return;
    if (page.preparing || page.generation != generation) {
      _relatedRevision = null;
      throw const HandrailGatewayException(
          'history_preparing', 'Preparing saved activity…',
          retryable: true);
    }
    // Keep one bounded related-state page; activity paging is explicit.
    _related = page.records;
    _relatedCursor = page.nextCursor;
  }
}
