part of '../handrail_ai_client.dart';

/// An immutable admission and start request. Persist [toJson] before submitting
/// and reuse the same value after an uncertain response, including app restarts.
/// Contains user content; hosts must store it within the authenticated account.
class HandrailTurnSubmission {
  final Map<String, Object?> _json;
  HandrailTurnSubmission._(Map<String, Object?> value)
      : _json = _immutableJson(value) as Map<String, Object?>;

  factory HandrailTurnSubmission.fromJson(Map<String, Object?> value) {
    if (value['version'] != 1 ||
        value['admission'] is! Map ||
        value['start'] is! Map) {
      throw const FormatException('Invalid saved turn submission');
    }
    final submission = HandrailTurnSubmission._(value);
    final start = submission._start;
    if (submission._admission['conversationId'] != start['conversationId'] ||
        start['conversationId'] is! String ||
        start['conversationTurnId'] is! String ||
        start['mutationId'] is! String ||
        start['idempotencyKey'] is! String ||
        start['request'] is! Map ||
        submission._admission['mutations'] is! List) {
      throw const FormatException('Invalid saved turn submission');
    }
    return submission;
  }

  Map<String, Object?> toJson() => _json;
  Map<String, Object?> get _start => _object(_json['start']);
  Map<String, Object?> get _admission => _object(_json['admission']);
  String get conversationId => _start['conversationId'] as String;
  String get turnId => _start['conversationTurnId'] as String;
}

HandrailTurnSubmission _prepareSubmission({
  required String conversationId,
  required int? revision,
  required String operationId,
  required String clientId,
  required Map<String, Object?> request,
}) {
  if (operationId.isEmpty || operationId.length > 128 || clientId.isEmpty) {
    throw ArgumentError('A unique operation ID and client ID are required');
  }
  // Clone before any asynchronous work so caller edits cannot alter a retry.
  final wire = _immutableJson(request) as Map<String, Object?>;
  final messages = _records(wire['messages']);
  if (wire['protocol_version'] != 'handrail.ai-runtime.v1' ||
      wire['continuation_of'] != null ||
      messages.isEmpty ||
      messages.last['role'] != 'user') {
    throw ArgumentError('A new turn requires a final user message');
  }
  final content = _records(messages.last['content']);
  if (content.isEmpty ||
      content.any((part) =>
          !const ['text', 'image', 'document'].contains(part['type']))) {
    throw ArgumentError('Unsupported user message content');
  }
  final textContent = content.where((part) => part['type'] == 'text').toList();
  if (textContent.isEmpty) textContent.add({'type': 'text', 'text': ''});
  final messageId = 'message_$operationId', turnId = 'turn_$operationId';
  final payloads = <Map<String, Object?>>[
    {
      'type': 'message.created',
      'message_id': messageId,
      'role': 'user',
      'content': textContent
    },
    ...content.where((part) => part['type'] != 'text').map((part) {
      final attachment = _object(part['attachment']);
      return <String, Object?>{
        'type': 'message.attachment_referenced',
        'message_id': messageId,
        'attachment': {
          'kind': part['type'],
          'attachment_id': attachment['attachment_id'],
          'media_type': attachment['media_type'],
          'size_bytes': attachment['byte_size'],
          if (attachment['filename'] != null)
            'filename': attachment['filename'],
        }
      };
    }),
    {
      'type': 'turn.started',
      'turn_id': turnId,
      'input_message_ids': [messageId]
    },
  ];
  final now = DateTime.now().toUtc().toIso8601String();
  final mutations = <Map<String, Object?>>[];
  for (var index = 0; index < payloads.length; index++) {
    final mutationId = 'mutation_${operationId}_$index';
    final runtime = payloads[index]['type'] == 'turn.started';
    mutations.add({
      'mutationId': mutationId,
      'events': [
        {
          'version': 1,
          'event_id': 'event_${operationId}_$index',
          'conversation_id': conversationId,
          'revision': (revision ?? 0) + index + 1,
          'occurred_at': now,
          'mutation_id': mutationId,
          'actor': {'type': runtime ? 'assistant' : 'user'},
          'source': runtime
              ? {'type': 'runtime'}
              : {'type': 'client', 'client_id': clientId},
          'payload': payloads[index],
        }
      ]
    });
  }
  return HandrailTurnSubmission._({
    'version': 1,
    'admission': {
      'conversationId': conversationId,
      'expectedRevision': revision,
      'mutations': mutations
    },
    'start': {
      'conversationId': conversationId,
      'conversationTurnId': turnId,
      'mutationId': 'mutation_${operationId}_0',
      'idempotencyKey': 'start_$operationId',
      'request': wire
    },
  });
}
