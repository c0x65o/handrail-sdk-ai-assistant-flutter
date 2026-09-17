part of '../handrail_ai_client.dart';

/// Storage must be encrypted and scoped to the authenticated account. Operations
/// on one conversation must be atomic across all writers sharing that storage.
abstract interface class HandrailPendingTurnStore {
  Future<HandrailTurnSubmission?> load(String conversationId);
  Future<void> retain(HandrailTurnSubmission submission);
  Future<void> acknowledge(HandrailTurnSubmission submission);
}

/// Adapter for a native host's encrypted key-value store. Serializes writers in
/// this Dart isolate, including separate adapter instances using the same scope.
/// Hosts with multiple processes/isolates must implement the atomic store above
/// through their database instead. Namespace must include API realm and account.
class HandrailKeyValuePendingTurnStore
    implements
        HandrailPendingTurnStore,
        HandrailConversationDraftStore,
        HandrailConversationPositionStore,
        HandrailConversationDeletionStore,
        HandrailApprovalDecisionStore {
  final String namespace;
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;
  final Future<void> Function(String key) delete;
  static final Map<String, Future<void>> _locks = {};
  HandrailKeyValuePendingTurnStore(
      {required this.namespace,
      required this.read,
      required this.write,
      required this.delete}) {
    if (namespace.isEmpty)
      throw ArgumentError('An account namespace is required');
  }
  String _key(String conversationId) =>
      'handrail.pending.v1.${base64Url.encode(utf8.encode(jsonEncode([
            namespace,
            conversationId
          ])))}';
  String get _draftKey =>
      'handrail.drafts.v1.${base64Url.encode(utf8.encode(namespace))}';
  Future<Map<String, Map<String, Object?>>> _readDrafts(String key) async {
    final raw = await read(key);
    if (raw == null) return {};
    if (raw.length > 4 * 1024 * 1024) {
      throw const FormatException('Invalid draft journal');
    }
    final rows = _object(jsonDecode(raw));
    if (rows.length > 32) throw const FormatException('Invalid draft journal');
    final result = <String, Map<String, Object?>>{};
    var bytes = 0;
    for (final entry in rows.entries) {
      if (!_historyId(entry.key))
        throw const FormatException('Invalid draft identity');
      final value = _draftRecord(_object(entry.value));
      bytes += utf8.encode(value['text'] as String).length;
      result[entry.key] = value;
    }
    if (bytes > 512 * 1024)
      throw const FormatException('Invalid draft journal');
    return result;
  }

  @override
  Future<Map<String, Object?>?> readDraft(String conversationId) =>
      _exclusiveKey(
          _draftKey, (key) async => (await _readDrafts(key))[conversationId]);
  @override
  Future<Map<String, Object?>?> writeDraft(
      String conversationId, String text, String? expectedVersion) {
    if (!_historyId(conversationId) || utf8.encode(text).length > 65536) {
      throw ArgumentError('Invalid draft identity or text exceeds 64 KiB');
    }
    return _exclusiveKey(_draftKey, (key) async {
      final rows = await _readDrafts(key);
      if (rows[conversationId]?['version'] != expectedVersion) {
        throw const HandrailGatewayException('draft_conflict',
            'A saved draft changed elsewhere. Your text remains in this editor.');
      }
      if (text.isEmpty) {
        rows.remove(conversationId);
        if (rows.isEmpty) {
          await delete(key);
        } else {
          await write(key, jsonEncode(rows));
        }
        return null;
      }
      final record =
          _draftRecord({'version': _assistantIdentity(), 'text': text});
      rows[conversationId] = record;
      final bytes = rows.values.fold<int>(
          0, (sum, row) => sum + utf8.encode(row['text'] as String).length);
      if (rows.length > 32 || bytes > 512 * 1024) {
        throw const HandrailGatewayException('draft_storage_full',
            'Local draft storage is full. Send or clear an existing draft and retry.');
      }
      await write(key, jsonEncode(rows));
      return record;
    });
  }

  @override
  Future<Map<String, Object?>?> readPosition(String conversationId) =>
      _exclusiveKey(_positionKey, (key) async {
        final value = (await _readPositions(key))[conversationId];
        return value == null ? null : _displayPosition(_object(value));
      });
  @override
  Future<void> writePosition(
      String conversationId, Map<String, Object?> position) {
    if (!_historyId(conversationId))
      throw ArgumentError('Invalid conversation identity');
    final normalized = _displayPosition(position);
    return _exclusiveKey(_positionKey, (key) async {
      final values = await _readPositions(key);
      values.remove(conversationId);
      values[conversationId] = normalized;
      while (values.length > 32) {
        values.remove(values.keys.first);
      }
      await write(key, jsonEncode(values));
    });
  }

  Future<T> _exclusive<T>(
          String conversationId, Future<T> Function(String key) action) =>
      _exclusiveKey(_key(conversationId), action);
  Future<T> _exclusiveKey<T>(
      String key, Future<T> Function(String key) action) async {
    final previous = _locks[key];
    final released = Completer<void>();
    _locks[key] = released.future;
    try {
      await previous;
      return await action(key);
    } finally {
      if (identical(_locks[key], released.future)) _locks.remove(key);
      released.complete();
    }
  }

  HandrailTurnSubmission? _decode(String conversationId, String? value) {
    if (value == null) return null;
    final submission =
        HandrailTurnSubmission.fromJson(_object(jsonDecode(value)));
    if (submission.conversationId != conversationId)
      throw const FormatException(
          'Pending message belongs to another conversation');
    return submission;
  }

  @override
  Future<HandrailTurnSubmission?> load(String conversationId) => _exclusive(
      conversationId, (key) async => _decode(conversationId, await read(key)));
  @override
  Future<void> retain(HandrailTurnSubmission submission) =>
      _exclusive(submission.conversationId, (key) async {
        final previous = _decode(submission.conversationId, await read(key));
        final value = jsonEncode(submission.toJson());
        if (previous != null) {
          if (jsonEncode(previous.toJson()) == value) return;
          throw const HandrailGatewayException('pending_send_exists',
              'Resolve the saved message before sending another message.');
        }
        await write(key, value);
      });
  @override
  Future<void> acknowledge(HandrailTurnSubmission submission) =>
      _exclusive(submission.conversationId, (key) async {
        final previous = _decode(submission.conversationId, await read(key));
        if (previous != null &&
            jsonEncode(previous.toJson()) == jsonEncode(submission.toJson()))
          await delete(key);
      });

  String get _deletionKey =>
      'handrail.deletions.v1.${base64Url.encode(utf8.encode(namespace))}';
  Future<List<HandrailConversationDeletionRequest>> _readDeletions(
      String key) async {
    final raw = await read(key);
    if (raw == null) return [];
    if (raw.length > 1000000)
      throw const FormatException('Invalid pending deletion journal');
    final value = _object(jsonDecode(raw));
    if (value['version'] != 1 ||
        value['requests'] is! List ||
        (value['requests'] as List).length > 100) {
      throw const FormatException('Invalid pending deletion journal');
    }
    final requests = (value['requests'] as List)
        .map((item) =>
            HandrailConversationDeletionRequest.fromJson(_object(item)))
        .toList();
    if (requests.map((request) => request.conversationId).toSet().length !=
        requests.length) {
      throw const FormatException('Duplicate pending deletion identity');
    }
    return requests;
  }

  Future<void> _writeDeletions(
      String key, List<HandrailConversationDeletionRequest> requests) async {
    if (requests.isEmpty)
      await delete(key);
    else
      await write(
          key,
          jsonEncode({
            'version': 1,
            'requests': requests.map((value) => value.toJson()).toList()
          }));
  }

  @override
  Future<List<HandrailConversationDeletionRequest>> loadDeletions() =>
      _exclusiveKey(_deletionKey,
          (key) async => List.unmodifiable(await _readDeletions(key)));
  @override
  Future<void> retainDeletion(HandrailConversationDeletionRequest request) =>
      _exclusiveKey(_deletionKey, (key) async {
        final requests = await _readDeletions(key);
        for (final current in requests) {
          if (current.conversationId != request.conversationId) continue;
          if (current._same(request)) return;
          throw const HandrailGatewayException('pending_deletion_exists',
              'Resolve the saved deletion before deleting another version.');
        }
        if (requests.length >= 100)
          throw const HandrailGatewayException('deletion_queue_full',
              'Resolve pending conversation deletions before deleting more conversations.');
        await _writeDeletions(key, [...requests, request]);
      });
  @override
  Future<void> acknowledgeDeletion(
          HandrailConversationDeletionRequest request) =>
      _exclusiveKey(_deletionKey, (key) async {
        final requests = await _readDeletions(key);
        final retained =
            requests.where((current) => !current._same(request)).toList();
        if (retained.length != requests.length)
          await _writeDeletions(key, retained);
      });
  String get _approvalKey =>
      'handrail.approvals.v1.${base64Url.encode(utf8.encode(namespace))}';
  Future<List<HandrailApprovalDecisionRequest>> _readApprovalDecisions(
      String key) async {
    final raw = await read(key);
    if (raw == null) return [];
    if (raw.length > 1000000)
      throw const FormatException('Invalid approval journal');
    final value = _object(jsonDecode(raw));
    if (value['version'] != 1 ||
        value['requests'] is! List ||
        (value['requests'] as List).length > 100)
      throw const FormatException('Invalid approval journal');
    final requests = (value['requests'] as List)
        .map((item) => HandrailApprovalDecisionRequest.fromJson(_object(item)))
        .toList();
    if (requests.map((r) => r.key).toSet().length != requests.length)
      throw const FormatException('Duplicate approval decision identity');
    return requests;
  }

  Future<void> _writeApprovalDecisions(
      String key, List<HandrailApprovalDecisionRequest> requests) async {
    if (requests.isEmpty)
      await delete(key);
    else
      await write(
          key,
          jsonEncode({
            'version': 1,
            'requests': requests.map((r) => r.toJson()).toList()
          }));
  }

  @override
  Future<List<HandrailApprovalDecisionRequest>> loadApprovalDecisions() =>
      _exclusiveKey(_approvalKey,
          (key) async => List.unmodifiable(await _readApprovalDecisions(key)));
  @override
  Future<void> retainApprovalDecision(
          HandrailApprovalDecisionRequest request) =>
      _exclusiveKey(_approvalKey, (key) async {
        final requests = await _readApprovalDecisions(key);
        for (final previous in requests) {
          if (previous.key != request.key) continue;
          if (previous._same(request)) return;
          throw const HandrailGatewayException('pending_approval_exists',
              'Check the saved decision before making a different choice.');
        }
        if (requests.length >= 100)
          throw const HandrailGatewayException('approval_queue_full',
              'Resolve saved decisions before approving more changes.');
        await _writeApprovalDecisions(key, [...requests, request]);
      });
  @override
  Future<void> acknowledgeApprovalDecision(
          HandrailApprovalDecisionRequest request) =>
      _exclusiveKey(_approvalKey, (key) async {
        final requests = await _readApprovalDecisions(key);
        final retained = requests.where((r) => !r._same(request)).toList();
        if (retained.length != requests.length)
          await _writeApprovalDecisions(key, retained);
      });
}
