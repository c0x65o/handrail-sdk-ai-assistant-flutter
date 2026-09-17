part of '../handrail_ai_client.dart';

String _approvalHash(Object? value) => crypto.sha256
    .convert(utf8.encode(jsonEncode(_approvalCanonical(value))))
    .toString();
Object? _approvalCanonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _approvalCanonical(value[key])};
  }
  if (value is List) return value.map(_approvalCanonical).toList();
  return value;
}

/// Immutable canonical proposal. Display arguments never become execution input.
class HandrailApprovalProposal {
  HandrailApprovalProposal(this.conversationId, Map<String, Object?> value)
      : json = _immutableJson(value) as Map<String, Object?> {
    for (final key in ['proposal_id', 'turn_id', 'tool_call_id', 'tool_name']) {
      final field = json[key];
      if (field is! String || field.isEmpty || field.length > 256)
        throw const FormatException('Invalid approval identity');
    }
    if (conversationId.isEmpty ||
        conversationId.length > 256 ||
        json['proposal_version'] is! int ||
        version < 1 ||
        version >= 9007199254740991 ||
        (json['expires_at'] != null && (json['expires_at'] is! String ||
          DateTime.tryParse(json['expires_at'] as String) == null)) ||
        !const [
          'pending',
          'confirmed',
          'rejected',
          'expired',
          'executing',
          'executed',
          'failed'
        ].contains(status) ||
        json['reviewed_arguments'] is! Map ||
        json['group_id'] != null && json['group_id'] is! String) {
      throw const FormatException('Invalid approval proposal');
    }
    final args = reviewedArguments;
    if (!(args['type'] == 'redacted_json' && args['value'] is Map ||
        args['type'] == 'opaque_reference' &&
            args['argument_ref'] is String &&
            (args['argument_ref'] as String).isNotEmpty)) {
      throw const FormatException('Invalid approval review');
    }
  }
  final String conversationId;
  final Map<String, Object?> json;
  String get id => json['proposal_id'] as String;
  int get version => json['proposal_version'] as int;
  String get status => json['status'] as String;
  bool get expired => status == 'expired';
  Map<String, Object?> get reviewedArguments =>
      Map<String, Object?>.from(json['reviewed_arguments'] as Map);
  String get binding => _approvalHash({
        'conversationId': conversationId,
        for (final key in [
          'proposal_id',
          'proposal_version',
          'group_id',
          'turn_id',
          'tool_call_id',
          'tool_name',
          'expires_at',
          'reviewed_arguments'
        ])
          key: json[key]
      });
}

/// A trusted host may resolve an opaque review only after validating its full
/// identity/reference. Incomplete or truncated reviews cannot be confirmed.
class HandrailApprovalReview {
  HandrailApprovalReview.forProposal(HandrailApprovalProposal proposal,
      {required Map<String, Object?> arguments, required this.complete})
      : binding = proposal.binding,
        arguments = _immutableJson(arguments) as Map<String, Object?> {
    if (jsonEncode(arguments).length > 65536)
      throw const FormatException('Approval review exceeds the display limit');
  }
  final String binding;
  final Map<String, Object?> arguments;
  final bool complete;
}

/// Durable confirmed intent contains hashes and identity only, never arguments.
class HandrailApprovalDecisionRequest {
  HandrailApprovalDecisionRequest.fromJson(Map<String, Object?> value)
      : json = Map.unmodifiable(value) {
    if (value.length != 7 ||
        value['expectedVersion'] is! int ||
        (value['expectedVersion'] as int) < 1 ||
        (value['expectedVersion'] as int) >= 9007199254740991 ||
        !const ['confirmed', 'rejected'].contains(value['status']))
      throw const FormatException('Invalid saved approval decision');
    for (final key in [
      'conversationId',
      'proposalId',
      'idempotencyKey',
      'idempotencyFingerprint',
      'binding'
    ]) {
      final field = value[key];
      if (field is! String ||
          field.isEmpty ||
          field.length > 256 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(field))
        throw const FormatException('Invalid saved approval identity');
    }
  }
  final Map<String, Object?> json;
  String get conversationId => json['conversationId'] as String;
  String get proposalId => json['proposalId'] as String;
  String get key => jsonEncode([conversationId, proposalId]);
  Map<String, Object?> toJson() => json;
  Map<String, Object?> get wire => {...json}..remove('binding');
  bool _same(HandrailApprovalDecisionRequest other) =>
      _approvalHash(json) == _approvalHash(other.json);
}

abstract interface class HandrailApprovalDecisionStore {
  Future<List<HandrailApprovalDecisionRequest>> loadApprovalDecisions();
  Future<void> retainApprovalDecision(HandrailApprovalDecisionRequest request);
  Future<void> acknowledgeApprovalDecision(
      HandrailApprovalDecisionRequest request);
}

typedef HandrailApprovalUiBinding = ({
  Object scope,
  Stream<Object?> changes,
  Map<String, Object?> Function() read,
  Future<void> Function(String proposalId, int version) review,
  Future<void> Function(
      String proposalId, int version, String binding, bool confirm) decide,
  Future<void> Function(String proposalId) retry,
});

/// Account-owned review, exact-version decisions and restart recovery.
class HandrailApprovalDecisions {
  HandrailApprovalDecisions._(this._owner);
  final HandrailAssistantController _owner;
  HandrailDisplayPage? _inbox;
  String? _inboxContext, _inboxCursor, _inboxSelected, _inboxError;
  int? _inboxSelection;
  bool _inboxOpen = false;
  Completer<void>? _inboxRequest;
  String get _currentInboxContext => jsonEncode([_owner._selectionGeneration,
    _owner.session?._control?.generation, _owner.session?._control?.revision]);
  bool get _inboxCurrent => _inboxContext == _currentInboxContext;

  /// One inbox page is retained only while explicitly open for this selection.
  Future<void> openPendingApprovals({String? cursor}) async {
    _owner._assertActive();
    final session = _owner.session;
    if (session == null || !session.supportsPendingApprovals) return;
    _cancelInboxRead();
    final request = Completer<void>(); _inboxRequest = request;
    _reviews.clear();
    _inboxOpen = true; _inbox = null; _inboxError = null; _inboxSelected = null;
    _inboxContext = _currentInboxContext; _inboxSelection = _owner._selectionGeneration; _inboxCursor = cursor;
    _owner._publish();
    try {
      final page = await session.readApprovals(cursor: cursor, cancellation: request.future);
      if (!request.isCompleted && _inboxCurrent) _inbox = page;
    } catch (_) {
      if (!request.isCompleted && _inboxCurrent) _inboxError = 'Pending approvals could not be loaded. Try again.';
    } finally {
      if (identical(_inboxRequest, request)) {
        _cancelInboxRead();
        _owner._publish();
      }
    }
  }
  void _cancelInboxRead() { final request = _inboxRequest; _inboxRequest = null;
    if (request != null && !request.isCompleted) request.complete(); }
  void closePendingApprovals() {
    _cancelInboxRead(); _reviews.clear(); _inboxOpen = false; _inbox = null; _inboxSelected = null; _inboxError = null;
    _owner._publish();
  }
  void selectPendingApproval(String id) {
    if (!_inboxCurrent || !_inboxOpen || _inbox == null || !_inbox!.records.any((r) => r.kind == 'approval' && r.id == id)) return;
    if (_inboxSelected != id) _reviews.clear();
    _inboxSelected = id; _owner._publish();
  }
  void _disposeInbox() { _cancelInboxRead(); _inbox = null; _reviews.clear(); _errors.clear(); }
  void _syncInbox() {
    if (!_inboxOpen || _inboxCurrent) return;
    _cancelInboxRead(); _reviews.clear(); _inbox = null; _inboxSelected = null;
    if (_inboxSelection != _owner._selectionGeneration) { _inboxOpen = false; return; }
    _inboxContext = _currentInboxContext;
    // Reads never block control publication. A changed generation restarts the
    // bounded first page; no opaque cursor from before a clear is reused.
    scheduleMicrotask(() { if (!_owner._disposed && _inboxOpen && _inboxCurrent) unawaited(openPendingApprovals()); });
  }

  final _reviews = <String, HandrailApprovalReview>{};
  final _reviewing = <String>{};
  final _errors = <String, String>{};
  final _pending = <String, HandrailApprovalDecisionRequest>{};
  final _operations = <String, Future<void>>{};
  HandrailApprovalDecisionStore? get _store =>
      _owner.approvalStore ??
      (_owner.pendingStore is HandrailApprovalDecisionStore
          ? _owner.pendingStore as HandrailApprovalDecisionStore
          : null);
  bool get hasPending => _pending.isNotEmpty;
  bool pendingFor(String id) =>
      _pending.values.any((r) => r.conversationId == id);
  String _key(String id) => jsonEncode([_owner.selectedId, id]);
  List<HandrailApprovalProposal> get _proposals {
    final id = _owner.selectedId;
    if (id == null) return [];
    final records = _records(_owner.document?.state['approval_proposals']);
    final selected = _inboxCurrent ? _inbox?.records.where((r) => r.id == _inboxSelected && r.kind == 'approval' && r.value != null).firstOrNull : null;
    final proposals = records.map((v) => HandrailApprovalProposal(id, v)).toList();
    if (selected?.value != null) {
      final candidate = HandrailApprovalProposal(id, selected!.value!);
      final index = proposals.indexWhere((p) => p.id == candidate.id);
      if (index < 0) proposals.add(candidate);
      else if (proposals[index].version < candidate.version) proposals[index] = candidate;
    }
    return proposals;
  }
  HandrailApprovalProposal _current(String id, int version) {
    _owner._assertActive();
    final proposals = _proposals.where((p) => p.id == id).toList();
    if (proposals.length != 1 ||
        proposals.single.version != version ||
        proposals.single.status != 'pending' ||
        proposals.single.expired ||
        _owner.archived ||
        _owner.hasPendingDeletion(_owner.selectedId!) ||
        _owner.session?.capabilities?.resources['approvals'] != true)
      throw const HandrailGatewayException('approval_changed',
          'This approval changed or is unavailable. Reload and review it again.');
    return proposals.single;
  }

  bool _allowed(HandrailApprovalProposal p, bool confirm) {
    try {
      return _owner.canDecideApproval?.call(p, confirm) ?? true;
    } catch (_) {
      return false;
    }
  }

  Future<HandrailApprovalReview> _readBoundReview(HandrailApprovalProposal p) async {
    final session = _owner.session;
    if (session?.supportsPendingApprovals == true) {
      final page = await session!.readApprovals(proposalId: p.id);
      final record = page.records.where((r) => r.kind == 'approval' && r.id == p.id).firstOrNull;
      if (record?.value != null && HandrailApprovalProposal(p.conversationId, record!.value!).binding == p.binding) {
        final tool = page.records.where((r) => r.kind == 'tool' && r.id == p.json['tool_call_id']).firstOrNull?.value;
        final args = tool?['arguments'];
        if (tool?['turn_id'] == p.json['turn_id'] && tool?['name'] == p.json['tool_name'] && args is Map &&
            p.reviewedArguments['argument_ref'] == 'args-sha256-${_approvalHash(args)}') {
          return HandrailApprovalReview.forProposal(p, arguments: Map<String, Object?>.from(args), complete: true);
        }
      }
    }
    throw const HandrailGatewayException('review_unavailable', 'Complete verified action details are unavailable. Reload the review.');
  }

  Future<void> review(String id, int version) async {
    final p = _current(id, version), generation = _owner._selectionGeneration;
    if (!_reviewing.add(p.binding)) return;
    _errors.remove(_key(id));
    _owner._publish();
    try {
      final loader = _owner.loadApprovalReview;
      final review = loader != null
          ? await loader(p)
          : p.reviewedArguments['type'] == 'redacted_json'
              ? HandrailApprovalReview.forProposal(p,
                  arguments: Map<String, Object?>.from(
                      p.reviewedArguments['value'] as Map),
                  complete: true)
              : await _readBoundReview(p);
      _owner._assertActive();
      if (generation != _owner._selectionGeneration ||
          _current(id, version).binding != p.binding ||
          review.binding != p.binding)
        throw const HandrailGatewayException('approval_changed',
            'The approval changed while loading. Review it again.');
      _reviews[p.binding] = review;
    } catch (_) {
      if (!_owner._disposed && generation == _owner._selectionGeneration)
        _errors[_key(id)] = 'The review could not be verified. Retry review.';
      rethrow;
    } finally {
      _reviewing.remove(p.binding);
      _owner._publish();
    }
  }

  Future<void> decide(String id, int version, String binding, bool confirm) {
    final p = _current(id, version), key = _key(id);
    if (p.binding != binding ||
        !_allowed(p, confirm) ||
        confirm && _reviews[binding]?.complete != true)
      return Future.error(const HandrailGatewayException('review_required',
          'A complete current review and permission are required.'));
    final previous = _pending[key];
    final request = HandrailApprovalDecisionRequest.fromJson({
      'conversationId': p.conversationId,
      'proposalId': id,
      'expectedVersion': version,
      'status': confirm ? 'confirmed' : 'rejected',
      'binding': binding,
      'idempotencyKey': _approvalHash([binding, confirm]),
      'idempotencyFingerprint': _approvalHash([binding, confirm]),
    });
    if (previous != null && !previous._same(request))
      return Future.error(const HandrailGatewayException(
          'pending_approval_exists',
          'Check the saved decision before making a different choice.'));
    if (_store == null)
      return Future.error(const HandrailGatewayException(
          'approval_storage_unavailable',
          'Approval decisions require durable account storage.'));
    _pending[key] = request;
    return _execute(request);
  }

  Future<void> _execute(HandrailApprovalDecisionRequest request) {
    final key = request.key;
    if (_operations[key] != null) return _operations[key]!;
    late final Future<void> operation;
    operation = (() async {
      try {
        _owner._assertActive();
        await _store!.retainApprovalDecision(request);
        _owner._assertActive();
        final value =
            _value(await _owner.client.transitionApproval(request.wire));
        final proposal =
            HandrailApprovalProposal(request.conversationId, value);
        if (proposal.id != request.proposalId ||
            proposal.version != (request.json['expectedVersion'] as int) + 1 ||
            proposal.status != request.json['status'] ||
            HandrailApprovalProposal(request.conversationId, {
                  ...value,
                  'proposal_version': request.json['expectedVersion']
                }).binding !=
                request.json['binding'])
          throw const FormatException(
              'Approval decision could not be verified');
        _owner._assertActive();
        await _store!.acknowledgeApprovalDecision(request);
        _owner._assertActive();
        _pending.remove(key);
        _reviews.remove(request.json['binding']);
        _errors.remove(key);
        // Confirmation is not execution. Canonical state owns execution status.
        try {
          await _owner.sessionFor(request.conversationId)?.refresh();
        } catch (_) {/* Session exposes its read failure independently. */}
      } catch (error) {
        if (!_owner._disposed) {
          if (error is HandrailGatewayException &&
              error.code == 'pending_approval_exists') {
            // Another controller already saved a choice. Adopt its exact intent;
            // never overwrite it or strand this view on the rejected new choice.
            final saved = await _store!.loadApprovalDecisions();
            _owner._assertActive();
            for (final original in saved.where((r) => r.key == key)) {
              _pending[key] = original;
            }
            _errors[key] =
                'Another saved decision is pending. Check its result.';
          } else if (error is HandrailGatewayException &&
              const ['version_conflict', 'invalid_transition']
                  .contains(error.code)) {
            await _store!.acknowledgeApprovalDecision(request);
            _owner._assertActive();
            _pending.remove(key);
            _reviews.remove(request.json['binding']);
            _errors[key] = 'This approval changed. Reload and review it again.';
            try {
              await _owner.sessionFor(request.conversationId)?.refresh();
            } catch (_) {}
          } else {
            _errors[key] =
                'The decision is not verified. Check the saved decision before trying another choice.';
          }
        }
        rethrow;
      } finally {
        if (identical(_operations[key], operation)) _operations.remove(key);
        _owner._publish();
      }
    })();
    _operations[key] = operation;
    _owner._publish();
    return operation;
  }

  Future<void> retry(String id) {
    _owner._assertActive();
    final request = _pending[_key(id)];
    return request == null ? Future.value() : _execute(request);
  }

  Future<void> resume() async {
    if (_store == null) return;
    final saved = await _store!.loadApprovalDecisions();
    _owner._assertActive();
    for (final request in saved) _pending[request.key] = request;
    for (final request in saved) {
      try {
        await _execute(request);
      } catch (_) {
        _owner._assertActive();
      }
    }
  }

  Map<String, Object?> get presentation {
    List<HandrailApprovalProposal> proposals;
    try {
      proposals = _proposals;
    } catch (_) {
      return {
        'error':
            'Approval data could not be verified. Reload the conversation.',
        'items': <Object?>[]
      };
    }
    final ids = <String>{};
    if (proposals.any((p) => !ids.add(p.id)))
      return {
        'error': 'Duplicate approval identities. Reload the conversation.',
        'items': <Object?>[]
      };
    final items = <Map<String, Object?>>[];
    for (final p in proposals) {
      final key = _key(p.id), review = _reviews[p.binding];
      final available = p.status == 'pending' &&
          !p.expired &&
          !_owner.archived &&
          !_owner.hasPendingDeletion(p.conversationId) &&
          _owner.session?.capabilities?.resources['approvals'] == true &&
          !_pending.containsKey(key) &&
          _store != null;
      items.add({
        ...p.json,
        'inboxOnly': !_records(_owner.document?.state['approval_proposals']).any((r) => r['proposal_id'] == p.id),
        'conversationId': p.conversationId,
        'binding': p.binding,
        'expired': p.expired,
        'arguments': review?.arguments,
        'reviewed': review != null,
        'complete': review?.complete ?? false,
        'reviewing': _reviewing.contains(p.binding),
        'canReview': available && !_reviewing.contains(p.binding),
        'canConfirm':
            available && review?.complete == true && _allowed(p, true),
        'canReject': available && _allowed(p, false),
        'pendingDecision': _pending.containsKey(key),
        'busy': _operations.containsKey(key),
        'error': _errors[key] ??
            (_store == null && p.status == 'pending'
                ? 'Approval decisions require durable account storage.'
                : null),
      });
    }
    for (final r in _pending.values.where((r) =>
        r.conversationId == _owner.selectedId && !ids.contains(r.proposalId))) {
      items.add({
        'proposal_id': r.proposalId,
        'proposal_version': r.json['expectedVersion'],
        'tool_name': 'Saved decision',
        'pendingDecision': true,
        'busy': _operations.containsKey(r.key),
        'error': _errors[r.key]
      });
    }
    final retained = proposals.map((p) => p.binding).toSet();
    _reviews.removeWhere((key, _) => !retained.contains(key));
    return {'conversationId': _owner.selectedId, 'items': items,
      'pendingApprovalsAvailable': _owner.session?.supportsPendingApprovals == true && _owner.session?.hasPendingApprovals == true,
      'inboxOpen': _inboxOpen, 'inboxLoading': _inboxRequest != null, 'inboxError': _inboxError,
      'inboxSelected': _inboxSelected, 'inboxHasMore': _inbox?.nextCursor != null, 'inboxHasNewer': _inboxCursor != null,
      'inboxItems': [for (final r in _inboxCurrent ? _inbox?.records ?? <HandrailDisplayRecord>[] : <HandrailDisplayRecord>[])
        if (r.kind == 'approval') {'id': r.id, 'title': r.value?['tool_name'] ?? 'Action', 'deferred': r.deferred}],
      'openInbox': () => openPendingApprovals(), 'olderInbox': () => openPendingApprovals(cursor: _inbox?.nextCursor),
      'closeInbox': closePendingApprovals, 'selectInbox': selectPendingApproval,
    };
  }

  HandrailApprovalUiBinding get uiBinding => (
        scope: _owner,
        changes: _owner.changes,
        read: () => presentation,
        review: review,
        decide: decide,
        retry: retry,
      );
}
