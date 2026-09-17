part of '../handrail_ai_client.dart';

/// One verified section, never an assembled argument object. Display binding
/// pins projection revisions; proposalBinding pins durable decision identity.
class HandrailApprovalDisplayReview {
  final String conversationId, proposalId;
  final int generation;
  final Map<String, Object?>? section;
  bool get preparing => section == null;
  HandrailApprovalDisplayReview._(
      this.conversationId, this.proposalId, this.generation, this.section);
  factory HandrailApprovalDisplayReview.fromJson(Map<String, Object?> value,
      {required String conversationId,
      required String proposalId,
      required int generation,
      int offset = 0,
      String? binding}) {
    bool hash(Object? value) =>
        value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
    if (value['schemaVersion'] != 1 ||
        value['conversationId'] != conversationId ||
        value['proposalId'] != proposalId ||
        value['generation'] != generation) {
      throw const FormatException('Invalid approval review response');
    }
    if (value['status'] == 'preparing' && value['review'] == null) {
      return HandrailApprovalDisplayReview._(
          conversationId, proposalId, generation, null);
    }
    final r = value['review'];
    if (value['status'] != 'ready' || r is! Map)
      throw const FormatException('Invalid approval review response');
    final text = r['text'],
        next = r['nextOffset'],
        version = r['proposalVersion'];
    if (!hash(r['binding']) ||
        !hash(r['proposalBinding']) ||
        binding != null && binding != r['binding'] ||
        version is! int ||
        version < 1 ||
        version >= 9007199254740991 ||
        !_historyId(r['turnId']) ||
        !_historyId(r['toolCallId']) ||
        !_historyId(r['toolName']) ||
        r['groupId'] != null && !_historyId(r['groupId']) ||
        r['argumentReference'] is! String ||
        !RegExp(r'^args-sha256-[a-f0-9]{64}$')
            .hasMatch(r['argumentReference'] as String) ||
        text is! String ||
        text.length > 16384 ||
        text.runes.length > 8192 ||
        r['offset'] != offset ||
        next != null && (text.runes.length != 8192 || next != offset + 8192)) {
      throw const FormatException('Invalid approval review section');
    }
    return HandrailApprovalDisplayReview._(
        conversationId,
        proposalId,
        generation,
        Map<String, Object?>.unmodifiable(Map<String, Object?>.from(r)));
  }
}

extension HandrailApprovalDisplayClient on HandrailAiClient {
  Future<HandrailApprovalDisplayReview> displayApprovalReview(
      {required String conversationId,
      required String proposalId,
      required int generation,
      String? binding,
      int offset = 0,
      Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    if (!_historyId(conversationId) ||
        !_historyId(proposalId) ||
        generation < 0 ||
        offset < 0 ||
        offset > 2147483646 ||
        binding != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(binding) ||
        offset > 0 && binding == null) {
      throw ArgumentError('Invalid approval review request');
    }
    final value = await _displayRequest(
        'approval_review',
        {
          'conversationId': conversationId,
          'proposalId': proposalId,
          'generation': generation,
          'offset': offset,
          if (binding != null) 'binding': binding,
        },
        65536,
        cancellation,
        timeout);
    return HandrailApprovalDisplayReview.fromJson(value,
        conversationId: conversationId,
        proposalId: proposalId,
        generation: generation,
        offset: offset,
        binding: binding);
  }

  /// Bounded receipt; the existing store still authorizes and versions decisions.
  /// Retry the identical durable intent if cancellation loses the response.
  Future<Map<String, Object?>> displayApprovalDecision(
      Map<String, Object?> input,
      {Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    final version = input['expectedVersion'],
        binding = input['proposalBinding'];
    if (!_historyId(input['conversationId']) ||
        !_historyId(input['proposalId']) ||
        version is! int ||
        version < 1 ||
        version >= 9007199254740991 ||
        !const ['confirmed', 'rejected'].contains(input['status']) ||
        binding is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(binding)) {
      throw ArgumentError('Invalid approval decision request');
    }
    final value = await _displayRequest(
        'approval_decision', input, 8192, cancellation, timeout);
    if (value['schemaVersion'] != 1 ||
        value['conversationId'] != input['conversationId'] ||
        value['proposalId'] != input['proposalId'] ||
        value['proposalVersion'] != version + 1 ||
        value['status'] != input['status'] ||
        value['proposalBinding'] != binding) {
      throw const FormatException('Invalid approval decision receipt');
    }
    return Map.unmodifiable(value);
  }
}

/// Selected-action lifetime, one section and one contiguous review watermark.
/// The owner persists decisions separately; sections never enter device storage.
class _PagedApprovalReview {
  _PagedApprovalReview(this.read, this.commit, this.changed);
  final Future<HandrailApprovalDisplayReview> Function(
      int, String?, Future<void>) read;
  final Future<void> Function(Map<String, Object?>, bool) commit;
  final void Function() changed;
  final _closed = Completer<void>();
  Future<void>? _pending;
  Map<String, Object?>? section;
  String? binding, error;
  int offset = 0, through = 0;
  String status = 'idle';
  bool complete = false, acknowledged = false;
  bool? decision;
  Map<String, Object?>? _intentSection;
  bool get disposed => _closed.isCompleted;
  void publish() {
    if (!disposed) changed();
  }

  Future<void> _run(Future<void> Function() work) {
    if (disposed) return Future.value();
    if (_pending != null) return _pending!;
    late Future<void> operation;
    operation = Future<void>.microtask(() async {
      if (!disposed) await work();
    }).whenComplete(() {
      if (identical(_pending, operation)) _pending = null;
    });
    return _pending = operation;
  }

  Future<HandrailApprovalDisplayReview> _read() async {
    final result = await read(offset, binding, _closed.future);
    if (disposed) throw StateError('Review closed');
    return result;
  }

  void fail(Object cause) {
    final code = cause is HandrailGatewayException ? cause.code : null;
    error = const ['content_changed', 'stale_cursor'].contains(code)
        ? 'changed'
        : const [
            'forbidden',
            'permission_denied',
            'unauthenticated',
            'not_found',
            'cancelled'
          ].contains(code)
            ? 'denied'
            : 'unavailable';
    section = null;
    acknowledged = false;
    status = 'error';
    publish();
  }

  Future<void> load([int? requestedOffset]) => _run(() async {
        final next = requestedOffset ?? offset;
        if (_intentSection != null ||
            status == 'decided' ||
            next < 0 ||
            next > through ||
            next % 8192 != 0) return;
        offset = next;
        section = null;
        status = 'loading';
        error = null;
        publish();
        try {
          final result = await _read();
          if (result.preparing) {
            status = 'preparing';
            acknowledged = false;
            publish();
            return;
          }
          section = result.section;
          binding ??= section!['binding'] as String;
          final next = section!['nextOffset'] as int?;
          if (offset == through) through = next ?? offset;
          complete = complete || next == null;
          status = 'ready';
          publish();
        } catch (cause) {
          fail(cause);
        }
      });
  void acknowledge(bool value) {
    if (status == 'ready' && complete && _intentSection == null) {
      acknowledged = value;
      publish();
    }
  }

  Future<void> decide(bool confirm) => _run(() async {
        if (status == 'decided' || decision != null && decision != confirm)
          return;
        if (_intentSection == null) {
          if (status != 'ready' ||
              section == null ||
              confirm && (!complete || !acknowledged)) return;
          status = 'deciding';
          error = null;
          publish();
          try {
            final current = await _read();
            if (current.preparing) {
              section = null;
              status = 'preparing';
              acknowledged = false;
              publish();
              return;
            }
            // Capture only identity metadata for retries, never the section text.
            _intentSection =
                Map.unmodifiable({...current.section!}..remove('text'));
            decision = confirm;
          } catch (cause) {
            fail(cause);
            return;
          }
        }
        status = 'deciding';
        error = null;
        publish();
        try {
          if (disposed) return;
          await commit(_intentSection!, confirm);
          section = null;
          acknowledged = false;
          status = 'decided';
          publish();
        } catch (_) {
          section = null;
          status = 'error';
          error = 'decision';
          publish();
        }
      });
  Map<String, Object?> get presentation => {
        'status': status,
        'section': section,
        'offset': offset,
        'complete': complete,
        'acknowledged': acknowledged,
        'error': error,
        'decision': decision,
        'load': () => load(),
        'previous': () => load(max(0, offset - 8192)),
        'next': () => section?['nextOffset'] is int
            ? load(section!['nextOffset'] as int)
            : Future<void>.value(),
        'acknowledge': acknowledge,
        'decide': decide,
      };
  void dispose() {
    if (!_closed.isCompleted) _closed.complete();
    section = null;
    _intentSection = null;
    acknowledged = false;
  }
}
