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
class HandrailKeyValuePendingTurnStore implements HandrailPendingTurnStore {
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
  Future<T> _exclusive<T>(
      String conversationId, Future<T> Function(String key) action) async {
    final key = _key(conversationId), previous = _locks[_key(conversationId)];
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
}
