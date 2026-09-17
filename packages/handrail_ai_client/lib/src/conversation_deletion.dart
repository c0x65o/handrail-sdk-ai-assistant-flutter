part of '../handrail_ai_client.dart';

/// The exact reviewed mutation. Retain before dispatch and replay unchanged.
/// Contains identity/version only; never stores a transcript or credentials.
class HandrailConversationDeletionRequest {
  HandrailConversationDeletionRequest(
      {required this.conversationId,
      required this.expectedVersion,
      required this.idempotencyKey}) {
    if (conversationId.isEmpty ||
        conversationId.length > 256 ||
        expectedVersion < 1 ||
        expectedVersion > 9007199254740991 ||
        idempotencyKey.isEmpty ||
        idempotencyKey.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(conversationId + idempotencyKey)) {
      throw const FormatException('Invalid conversation deletion request');
    }
  }
  factory HandrailConversationDeletionRequest.fromJson(
      Map<String, Object?> json) {
    if (json.length != 3 ||
        json['conversationId'] is! String ||
        json['expectedVersion'] is! int ||
        json['idempotencyKey'] is! String) {
      throw const FormatException('Invalid conversation deletion request');
    }
    return HandrailConversationDeletionRequest(
        conversationId: json['conversationId'] as String,
        expectedVersion: json['expectedVersion'] as int,
        idempotencyKey: json['idempotencyKey'] as String);
  }
  final String conversationId, idempotencyKey;
  final int expectedVersion;
  Map<String, Object?> toJson() => Map.unmodifiable({
        'conversationId': conversationId,
        'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey
      });
  bool _same(HandrailConversationDeletionRequest other) =>
      conversationId == other.conversationId &&
      expectedVersion == other.expectedVersion &&
      idempotencyKey == other.idempotencyKey;
}

/// Account/realm-scoped storage, atomic across all writers sharing it.
/// Retain confirmed user intent before dispatch; remove only after a verified
/// receipt and local cleanup, or a definitive server rejection.
abstract interface class HandrailConversationDeletionStore {
  Future<List<HandrailConversationDeletionRequest>> loadDeletions();
  Future<void> retainDeletion(HandrailConversationDeletionRequest request);
  Future<void> acknowledgeDeletion(HandrailConversationDeletionRequest request);
}

extension HandrailVerifiedConversationDeletion on HandrailAiClient {
  Future<void> deleteReviewedConversation(
      HandrailConversationDeletionRequest request) async {
    final result =
        _value(await permanentlyDeleteConversation(request.toJson()));
    if (result['operation'] != 'permanent_delete' ||
        !const ['deleted', 'idempotent'].contains(result['status']) ||
        result['conversationId'] != request.conversationId ||
        result['deletedVersion'] != request.expectedVersion) {
      throw const FormatException(
          'Conversation deletion could not be verified');
    }
  }
}

extension HandrailAssistantDeletion on HandrailAssistantController {
  HandrailConversationDeletionStore? get _deletionJournal =>
      deletionStore ??
      (pendingStore is HandrailConversationDeletionStore
          ? pendingStore as HandrailConversationDeletionStore
          : null);
  Set<String> get deletedConversationIds => Set.unmodifiable(_deletedIds);
  bool isDeleting(String id) => _deletionOperations.containsKey(id);
  bool hasPendingDeletion(String id) => _deletions.containsKey(id);

  /// Call only for the ID/version actually reviewed by the user. The SDK never
  /// retries a newer version under that confirmation. Backend authorization,
  /// voice/active-work gates and durable deletion fences remain authoritative.
  Future<void> permanentlyDelete(String id, int expectedVersion) {
    _assertActive();
    if (!canManageConversations)
      return Future.error(_conversationManagementDenied);
    if (_deletionJournal == null)
      return Future.error(const HandrailGatewayException(
          'deletion_storage_unavailable',
          'Conversation deletion requires durable account storage.',
          retryable: false));
    final previous = _deletions[id];
    if (previous != null && previous.expectedVersion != expectedVersion) {
      return Future.error(const HandrailGatewayException(
          'pending_deletion_exists',
          'Confirm the previous deletion result before deleting another version.'));
    }
    if (_deletionOperations[id] != null) return _deletionOperations[id]!;
    if (_deletedIds.contains(id) && previous == null) return Future.value();
    if (approvals.pendingFor(id) ||
        _sending.contains(id) ||
        _creating != null && _createdDescriptor?.id == id ||
        _lifecycleRequests.containsKey(id) ||
        _lifecycleOperations.containsKey(id) ||
        _sessions[id]?.document?.activeTurnId != null) {
      return Future.error(const HandrailGatewayException('conversation_busy',
          'Wait for this conversation’s current work to finish before deleting it.'));
    }
    final request = previous ??
        HandrailConversationDeletionRequest(
            conversationId: id,
            expectedVersion: expectedVersion,
            idempotencyKey: _createId());
    _deletions[id] = request;
    return _executeDeletion(request, checkCapability: previous == null);
  }

  Future<void> _executeDeletion(HandrailConversationDeletionRequest request,
      {bool checkCapability = false}) {
    final id = request.conversationId;
    final existing = _deletionOperations[id];
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = Future<void>.microtask(() async {
      try {
        _requireConversationManagement();
        final journal = _deletionJournal!;
        if (checkCapability) {
          final capabilities = await _getActivityCapabilities();
          _assertActive();
          if (!_supportsCatalogAction(capabilities, 'permanentDelete')) {
            _deletions.remove(id);
            throw const HandrailGatewayException('unsupported',
                'This assistant does not support permanent conversation deletion.',
                retryable: false);
          }
        }
        // Persist before dispatch. A saved replay must check its receipt even
        // if the current capability advertisement no longer offers new deletes.
        _requireConversationManagement();
        await journal.retainDeletion(request);
        _requireConversationManagement();
        try {
          await client.deleteReviewedConversation(request);
        } on HandrailGatewayException catch (error) {
          if (error.code == 'version_conflict') {
            await journal.acknowledgeDeletion(request);
            _assertActive();
            _deletions.remove(id);
            _invalidateHistoryRead();
            try {
              await refreshHistory();
            } catch (_) {/* Keep the read error visible. */}
          }
          rethrow;
        }
        _assertActive();
        await _forgetDeletedConversation(id);
        _assertActive();
        final saved = await pendingStore.load(id);
        _assertActive();
        if (saved != null) await pendingStore.acknowledge(saved);
        await journal.acknowledgeDeletion(request);
        _assertActive();
        _deletions.remove(id);
        _operationErrors.remove(id);
        _pending.remove(id);
      } catch (cause) {
        if (!_disposed)
          _operationErrors[id] = _assistantFailure(
              cause,
              'deletion_unconfirmed',
              'Deletion could not be confirmed. Retry the same deletion to check its saved result.');
        rethrow;
      } finally {
        if (identical(_deletionOperations[id], operation))
          _deletionOperations.remove(id);
        _publish();
      }
    });
    _deletionOperations[id] = operation;
    _publish();
    return operation;
  }

  /// Resumes only previously confirmed, persisted intent, before opening chats
  /// or recovering saved sends. No new deletion is inferred from missing history.
  Future<void> resumePendingDeletions() async {
    _assertActive();
    final saved = await _deletionJournal?.loadDeletions() ??
        const <HandrailConversationDeletionRequest>[];
    _assertActive();
    for (final request in saved) {
      final existing = _deletions[request.conversationId];
      if (existing != null && !existing._same(request)) {
        throw const HandrailGatewayException('pending_deletion_exists',
            'A different conversation deletion is already pending.');
      }
      _deletions[request.conversationId] = request;
      try {
        await _executeDeletion(request);
      } catch (_) {
        // A pending deletion blocks that identity, not other conversations.
        // Its journal and visible per-request error remain available for retry.
      }
      _assertActive();
    }
  }

  Future<void> _forgetDeletedConversation(String id) async {
    _deletedIds.add(id);
    _invalidateHistoryRead();
    _descriptors.remove(id);
    _history = List.unmodifiable(_history.where((row) => row.id != id));
    if (_createdDescriptor?.id == id) {
      _createdDescriptor = null;
      _createRequest = null;
    }
    if (_selectedId == id) {
      _selectionGeneration++;
      _selectedId = null;
      _selecting = false;
      _selectionError = null;
    }
    final closing = _sessions.remove(id)?._forgetAfterDeletion();
    await _sessionSubscriptions.remove(id)?.cancel();
    workspace.forget(id);
    _publish();
    await closing;
  }

  void _assertConversationUsable(String id) {
    _assertActive();
    if (_deletedIds.contains(id) || _deletions.containsKey(id)) {
      throw HandrailGatewayException(
          _deletedIds.contains(id) ? 'not_found' : 'deletion_pending',
          _deletedIds.contains(id)
              ? 'This conversation was deleted.'
              : 'Confirm this conversation’s deletion result before continuing.',
          retryable: !_deletedIds.contains(id));
    }
  }
}

bool _supportsCatalogAction(
    HandrailGatewayCapabilities? capabilities, String action) {
  final catalog = capabilities?.resources['conversations'];
  return catalog is Map &&
      catalog[action] is Map &&
      (catalog[action] as Map)['supported'] == true;
}
