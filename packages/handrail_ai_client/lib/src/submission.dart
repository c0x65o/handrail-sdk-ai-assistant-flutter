part of '../handrail_ai_client.dart';

/// An immutable admission and start request. Persist [toJson] before submitting
/// and reuse the same value after an uncertain response, including app restarts.
/// Contains user content; hosts must store it within the authenticated account.
class HandrailTurnSubmission {
  final Map<String, Object?> _json;
  HandrailTurnSubmission._(Map<String, Object?> value)
      : _json = _immutableJson(value) as Map<String, Object?>;

  factory HandrailTurnSubmission.fromJson(Map<String, Object?> value) {
    if (!const [1, 2].contains(value['version']) ||
        (value['version'] == 2) != (value['localDraft'] != null) ||
        value['admission'] is! Map ||
        value['start'] is! Map) {
      throw const FormatException('Invalid saved turn submission');
    }
    if (value['localDraft'] != null) _draftOrigin(_object(value['localDraft']));
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
    final fileIds = submission.localDraft?['fileIds'] as List? ?? const [];
    final mutations = submission._admission['mutations'] as List;
    if (fileIds.isNotEmpty && fileIds.length > mutations.length - 2) {
      throw const FormatException('Invalid local draft attachment identities');
    }
    return submission;
  }

  Map<String, Object?> toJson() => _json;
  Map<String, Object?> get _start => _object(_json['start']);
  Map<String, Object?> get _admission => _object(_json['admission']);
  String get conversationId => _start['conversationId'] as String;

  /// Device-only receipt; never part of admission, start or provider bodies.
  Map<String, Object?>? get localDraft =>
      _json['localDraft'] == null ? null : _object(_json['localDraft']);
  String get turnId => _start['conversationTurnId'] as String;

  Map<String, Object?> get _message {
    final payloads = _records(_admission['mutations'])
        .expand((mutation) => _records(mutation['events']))
        .map((event) => _object(event['payload']));
    final message =
        payloads.firstWhere((event) => event['type'] == 'message.created');
    return Map.unmodifiable({
      'message_id': message['message_id'],
      'role': 'user',
      'content': message['content'],
      'attachments': [
        for (final event in payloads)
          if (event['type'] == 'message.attachment_referenced')
            event['attachment']
      ],
    });
  }
}

HandrailTurnSubmission _prepareSubmission({
  required String conversationId,
  required int? revision,
  required String operationId,
  required String clientId,
  required Map<String, Object?> request,
  Map<String, Object?>? localDraft,
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
  return HandrailTurnSubmission.fromJson({
    'version': localDraft == null ? 1 : 2,
    if (localDraft != null) 'localDraft': _draftOrigin(localDraft),
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

/// Small immutable origin identities, not message content or authorization.
Map<String, Object?> _draftOrigin(Map<String, Object?> input) {
  final text = input['textVersion'], files = input['fileIds'];
  if (input['version'] != 1 ||
      input.keys.any((key) =>
          !const ['version', 'textVersion', 'fileIds'].contains(key)) ||
      text != null && (text is! String || text.isEmpty || text.length > 128) ||
      files != null &&
          (files is! List ||
              files.length > 64 ||
              files.any((id) =>
                  id is! String ||
                  !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$')
                      .hasMatch(id)) ||
              files.toSet().length != files.length)) {
    throw const FormatException('Invalid local draft origin');
  }
  return Map.unmodifiable({
    'version': 1,
    if (text != null) 'textVersion': text,
    if (files != null)
      'fileIds': List<String>.unmodifiable((files as List).cast<String>()),
  });
}
