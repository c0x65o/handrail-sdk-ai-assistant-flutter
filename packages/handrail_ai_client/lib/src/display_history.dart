part of '../handrail_ai_client.dart';

/// Display pages are deliberately distinct from canonical audit snapshots.
class HandrailDisplayHistoryCapability {
  final int maximumPageSize;
  final int maximumPageBytes;
  final bool control;
  final bool messageText;
  final bool pendingApprovals;
  const HandrailDisplayHistoryCapability._(this.maximumPageSize,
      this.maximumPageBytes, this.control, this.messageText, this.pendingApprovals);
  factory HandrailDisplayHistoryCapability.fromJson(
      Map<String, Object?> value) {
    final size = value['maximumPageSize'], bytes = value['maximumPageBytes'];
    if (value['version'] != 1 ||
        value['control'] != null && value['control'] is! bool ||
        value['messageText'] != null && value['messageText'] is! bool ||
        value['pendingApprovals'] != null && value['pendingApprovals'] is! bool ||
        size is! int ||
        size < 1 ||
        size > 50 ||
        bytes is! int ||
        bytes < 8192 ||
        bytes > 262144) {
      throw const FormatException('Invalid display history capability.');
    }
    return HandrailDisplayHistoryCapability._(
        size, bytes, value['control'] == true, value['messageText'] == true, value['pendingApprovals'] == true);
  }
}

class HandrailDisplayRecord {
  static const kinds = {
    'message',
    'turn',
    'tool',
    'approval',
    'citation',
    'source',
    'budget'
  };
  final String kind;
  final String id;
  final String? turnId;
  final int revision;
  final int bytes;
  final bool deferred;
  final bool deleted;
  final Map<String, Object?>? value;
  const HandrailDisplayRecord._(this.kind, this.id, this.turnId, this.revision,
      this.bytes, this.deferred, this.deleted, this.value);
  factory HandrailDisplayRecord.fromJson(Map<String, Object?> json) {
    final kind = json['kind'],
        id = json['id'],
        turn = json['turnId'],
        revision = json['revision'],
        bytes = json['bytes'],
        deferred = json['deferred'],
        deleted = json['deleted'] == true,
        value = json['value'];
    if (!kinds.contains(kind) ||
        !_historyId(id) ||
        turn != null && !_historyId(turn) ||
        revision is! int ||
        revision < 1 ||
        bytes is! int ||
        bytes < 0 ||
        deferred is! bool ||
        (deleted
            ? deferred || value != null
            : deferred
                ? value != null
                : value is! Map)) {
      throw const FormatException('Invalid display history record.');
    }
    return HandrailDisplayRecord._(
        kind as String,
        id as String,
        turn as String?,
        revision,
        bytes,
        deferred,
        deleted,
        value == null
            ? null
            : _immutableJson(_object(value)) as Map<String, Object?>);
  }
}

class HandrailDisplayPage {
  final String conversationId;
  final bool preparing;
  final int generation;
  final int revision;
  final int canonicalRevision;
  final String? activeTurnId;
  final List<HandrailDisplayRecord> records;
  final String? nextCursor;
  const HandrailDisplayPage._(
      this.conversationId,
      this.preparing,
      this.generation,
      this.revision,
      this.canonicalRevision,
      this.activeTurnId,
      this.records,
      this.nextCursor);
  factory HandrailDisplayPage.fromJson(Map<String, Object?> json) =>
      _parse(json);
  static HandrailDisplayPage _parse(Map<String, Object?> json,
      {bool allowDeleted = false}) {
    final id = json['conversationId'],
        status = json['status'],
        generation = json['generation'],
        revision = json['revision'],
        canonical = json['canonicalRevision'],
        active = json['activeTurnId'],
        raw = json['records'],
        cursor = json['nextCursor'];
    if (json['schemaVersion'] != 1 ||
        !_historyId(id) ||
        !const {'ready', 'preparing'}.contains(status) ||
        generation is! int ||
        generation < 0 ||
        revision is! int ||
        revision < generation ||
        canonical is! int ||
        canonical < revision ||
        status == 'ready' && revision != canonical ||
        active != null && !_historyId(active) ||
        raw is! List ||
        raw.length > 50 ||
        status == 'preparing' && raw.isNotEmpty ||
        cursor != null &&
            (cursor is! String || cursor.isEmpty || cursor.length > 4096)) {
      throw const FormatException('Invalid display history page.');
    }
    final records = raw
        .map((item) => HandrailDisplayRecord.fromJson(_object(item)))
        .toList();
    final identities = <String>{};
    if (records.any((record) =>
        record.revision > revision ||
        record.deleted && !allowDeleted ||
        !identities.add(jsonEncode([record.kind, record.id])))) {
      throw const FormatException(
          'Duplicate or future display history record.');
    }
    return HandrailDisplayPage._(
        id as String,
        status == 'preparing',
        generation,
        revision,
        canonical,
        active as String?,
        List.unmodifiable(records),
        cursor as String?);
  }
}

class HandrailDisplayChanges {
  final HandrailDisplayPage page;

  /// Advance the live watermark only when page.nextCursor is null.
  final int throughRevision;
  const HandrailDisplayChanges._(this.page, this.throughRevision);
  factory HandrailDisplayChanges.fromJson(Map<String, Object?> json) {
    final page = HandrailDisplayPage._parse(json, allowDeleted: true);
    final through = json['throughRevision'];
    if (through is! int ||
        through < page.generation ||
        through > page.revision ||
        page.records.any((record) => record.revision > through)) {
      throw const FormatException('Invalid display change watermark.');
    }
    return HandrailDisplayChanges._(page, through);
  }
}

class HandrailDisplayContentChunk {
  final String encoding;
  final String text;
  final int revision;

  /// Unicode code-point offset, not a Dart String/UTF-16 offset.
  final int? nextOffset;
  const HandrailDisplayContentChunk._(
      this.text, this.revision, this.nextOffset, this.encoding);
  factory HandrailDisplayContentChunk.fromJson(Map<String, Object?> json) {
    final text = json['text'],
        revision = json['revision'],
        next = json['nextOffset'];
    if (!const {'json-text', 'plain-text'}.contains(json['encoding']) ||
        text is! String ||
        text.runes.length > 8192 ||
        revision is! int ||
        revision < 1 ||
        next != null && (next is! int || next < 1)) {
      throw const FormatException('Invalid display history content.');
    }
    return HandrailDisplayContentChunk._(
        text, revision, next as int?, json['encoding'] as String);
  }
}

bool _historyId(Object? id) =>
    id is String &&
    id.isNotEmpty &&
    id.length <= 512 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(id);

/// A stable server-side message lookup, independent of evicted client pages.
class HandrailDisplayAnchor {
  final String messageId;
  final int generation;
  final bool newer;
  final bool inclusive;
  const HandrailDisplayAnchor(
      {required this.messageId,
      required this.generation,
      this.newer = false,
      this.inclusive = false});
  Map<String, Object?> toJson() {
    if (!_historyId(messageId) || generation < 0) {
      throw ArgumentError('Invalid display history anchor.');
    }
    return {
      'messageId': messageId,
      'generation': generation,
      'direction': newer ? 'newer' : 'older',
      'inclusive': inclusive
    };
  }
}

extension HandrailClientDisplayHistory on HandrailAiClient {
  Future<HandrailDisplayChanges> displayHistoryChanges(
      {required String conversationId,
      required HandrailDisplayHistoryCapability capability,
      required int generation,
      required int afterRevision,
      String? cursor,
      int limit = 30,
      int maximumBytes = 65536,
      Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    if (!_historyId(conversationId) ||
        generation < 0 ||
        afterRevision < generation ||
        limit < 1 ||
        limit > capability.maximumPageSize ||
        maximumBytes < 8192 ||
        maximumBytes > capability.maximumPageBytes) {
      throw ArgumentError('Invalid display history change bounds.');
    }
    final changes = HandrailDisplayChanges.fromJson(await _displayRequest(
        'changes',
        {
          'conversationId': conversationId,
          'generation': generation,
          'afterRevision': afterRevision,
          'limit': limit,
          'maximumBytes': maximumBytes,
          if (cursor != null) 'cursor': cursor,
        },
        maximumBytes + 1024,
        cancellation,
        timeout));
    if (changes.page.conversationId != conversationId ||
        changes.page.generation != generation ||
        changes.page.records.length > limit ||
        changes.throughRevision < afterRevision ||
        changes.page.records
            .any((record) => record.revision <= afterRevision)) {
      throw const FormatException(
          'Display changes do not match their request.');
    }
    return changes;
  }

  Future<HandrailDisplayPage> displayHistoryPage(
      {required String conversationId,
      required HandrailDisplayHistoryCapability capability,
      String? cursor,
      HandrailDisplayAnchor? anchor,
      Map<String, Object?>? view,
      int limit = 30,
      int maximumBytes = 65536,
      Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    if (!_historyId(conversationId) ||
        anchor != null &&
            (cursor != null || view != null && view['type'] != 'messages') ||
        limit < 1 ||
        limit > capability.maximumPageSize ||
        maximumBytes < 8192 ||
        maximumBytes > capability.maximumPageBytes) {
      throw ArgumentError('Invalid display history page bounds.');
    }
    final page = HandrailDisplayPage.fromJson(await _displayRequest(
        'page',
        {
          'conversationId': conversationId,
          'limit': limit,
          'maximumBytes': maximumBytes,
          if (cursor != null) 'cursor': cursor,
          if (anchor != null) 'anchor': anchor.toJson(),
          if (view != null) 'view': view,
        },
        maximumBytes + 1024,
        cancellation,
        timeout));
    if (page.conversationId != conversationId ||
        page.records.length > limit ||
        anchor != null && page.generation != anchor.generation) {
      throw const FormatException(
          'Display history response does not match its request.');
    }
    return page;
  }

  Future<HandrailDisplayContentChunk> displayHistoryContent(
      {required String conversationId,
      required int generation,
      required String kind,
      required String id,
      int? revision,
      int offset = 0,
      bool messageText = false,
      Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    if (!_historyId(conversationId) ||
        !_historyId(id) ||
        !HandrailDisplayRecord.kinds.contains(kind) ||
        messageText && kind != 'message' ||
        generation < 0 ||
        offset < 0 ||
        offset > 2147483646 ||
        revision != null && revision < 1 ||
        offset > 0 && revision == null)
      throw ArgumentError('Invalid display history content request.');
    final chunk = HandrailDisplayContentChunk.fromJson(await _displayRequest(
        'content',
        {
          'conversationId': conversationId,
          'generation': generation,
          'kind': kind,
          'id': id,
          'offset': offset,
          if (messageText) 'format': 'message-text',
          if (revision != null) 'revision': revision,
        },
        65536,
        cancellation,
        timeout));
    if (chunk.encoding != (messageText ? 'plain-text' : 'json-text') ||
        revision != null && chunk.revision != revision ||
        chunk.nextOffset != null &&
            (chunk.text.isEmpty ||
                chunk.nextOffset != offset + chunk.text.runes.length ||
                messageText && chunk.text.runes.length != 8192)) {
      throw const FormatException(
          'Display history content changed while reading.');
    }
    return chunk;
  }

  Future<Map<String, Object?>> _displayRequest(
      String operation,
      Map<String, Object?> input,
      int maximumBytes,
      Future<void>? cancellation,
      Duration timeout) async {
    if (timeout <= Duration.zero)
      throw ArgumentError('A positive history timeout is required.');
    final body = jsonEncode({'operation': operation, 'input': input});
    if (utf8.encode(body).length > 8192)
      throw ArgumentError('Display history request is too large.');
    final abort = Completer<void>();
    var expired = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(cancellation?.then((_) => cancel(), onError: (_) => cancel()));
    final deadline = Timer(timeout, () {
      expired = true;
      cancel();
    });
    HandrailGatewayException cancelled() => HandrailGatewayException(
        expired ? 'history_timeout' : 'cancelled',
        expired
            ? 'History took too long to load. Try again.'
            : 'History loading cancelled.',
        retryable: expired);
    Future<T> cancellable<T>(Future<T> work) =>
        Future.any([work, abort.future.then<T>((_) => throw cancelled())]);
    Future<Map<String, Object?>> execute() async {
      final headers = await cancellable(_headers());
      if (abort.isCompleted) throw cancelled();
      final request = http.AbortableRequest(
          'POST', _uri('/conversations/history'),
          abortTrigger: abort.future)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..body = body;
      final response = await _http.send(request);
      if (abort.isCompleted) {
        unawaited(response.stream.listen((_) {}).cancel());
        throw cancelled();
      }
      final stream = StreamIterator<List<int>>(response.stream);
      try {
        final bytes = BytesBuilder(copy: false);
        while (await cancellable(stream.moveNext())) {
          if (bytes.length + stream.current.length > maximumBytes) {
            throw const FormatException(
                'Display history response exceeded its byte budget.');
          }
          bytes.add(stream.current);
        }
        final json = _object(jsonDecode(utf8.decode(bytes.takeBytes())));
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            json['ok'] != true) {
          final error = json['error'] is Map
              ? _object(json['error'])
              : const <String, Object?>{};
          final resource = json['resourceError'] is Map
              ? _object(json['resourceError'])
              : const <String, Object?>{};
          throw HandrailGatewayException(
              resource['domain'] == 'display_history' &&
                      resource['code'] is String
                  ? resource['code'] as String
                  : error['code'] as String? ?? 'history_unavailable',
              error['message'] as String? ?? 'History could not be loaded.',
              retryable: error['retryable'] == true,
              statusCode: response.statusCode);
        }
        return _object(json['value']);
      } finally {
        unawaited(stream.cancel());
      }
    }

    try {
      return await cancellable(execute());
    } finally {
      deadline.cancel();
      cancel();
    }
  }
}
