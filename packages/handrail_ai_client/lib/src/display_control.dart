part of '../handrail_ai_client.dart';

/// Small scalar controls. Never a checkpoint, model context, or a complete turn
/// record: message IDs, retries, tool results and attachment bytes are omitted.
class HandrailDisplayTurnControl {
  final String turnId, status;
  final int revision;
  final bool remoteMayStillBeRunning;
  final Map<String, Object?>? error;
  const HandrailDisplayTurnControl._(this.turnId, this.status, this.revision,
      this.remoteMayStillBeRunning, this.error);
  factory HandrailDisplayTurnControl.fromJson(Map<String, Object?> json) {
    final id = json['turnId'],
        status = json['status'],
        revision = json['revision'],
        remote = json['remoteMayStillBeRunning'],
        error = json['error'];
    if (!_historyId(id) ||
        !const {
          'queued',
          'running',
          'waiting_for_tool_result',
          'waiting_for_approval',
          'completed',
          'cancelled',
          'failed'
        }.contains(status) ||
        revision is! int ||
        revision < 1 ||
        remote is! bool ||
        remote !=
            const {'queued', 'running', 'waiting_for_tool_result'}
                .contains(status)) {
      throw const FormatException('Invalid display turn controls.');
    }
    Map<String, Object?>? failure;
    if (error != null) {
      if (error is! Map ||
          error['code'] is! String ||
          (error['code'] as String).runes.length > 64 ||
          error['message'] is! String ||
          (error['message'] as String).runes.length > 256 ||
          error['retryable'] is! bool ||
          error['messageTruncated'] is! bool) {
        throw const FormatException('Invalid display turn error.');
      }
      failure = Map.unmodifiable({
        for (final key in ['code', 'message', 'retryable', 'messageTruncated'])
          key: error[key]
      });
    }
    return HandrailDisplayTurnControl._(
        id as String, status as String, revision, remote, failure);
  }
}

class HandrailDisplayControl {
  final String conversationId;
  final int generation, revision, canonicalRevision;
  final bool preparing;
  final bool? hasPendingApprovals;
  final String? activeTurnId;
  final HandrailDisplayTurnControl? activeTurn, latestTurn, requestedTurn;
  const HandrailDisplayControl._(
      this.conversationId,
      this.generation,
      this.revision,
      this.canonicalRevision,
      this.preparing,
      this.activeTurnId,
      this.activeTurn,
      this.latestTurn,
      this.requestedTurn,
      this.hasPendingApprovals);
  factory HandrailDisplayControl.fromJson(Map<String, Object?> json) {
    if (!['activeTurn', 'latestTurn', 'requestedTurn']
        .every(json.containsKey)) {
      throw const FormatException('Missing display turn controls.');
    }
    final header = HandrailDisplayPage.fromJson(
        {...json, 'records': [], 'nextCursor': null});
    HandrailDisplayTurnControl? parse(Object? raw) =>
        raw == null ? null : HandrailDisplayTurnControl.fromJson(_object(raw));
    final active = parse(json['activeTurn']),
        latest = parse(json['latestTurn']),
        requested = parse(json['requestedTurn']);
    if (json['hasPendingApprovals'] != null && json['hasPendingApprovals'] is! bool ||
        header.preparing && json['hasPendingApprovals'] == true ||
        [active, latest, requested]
            .any((turn) => turn != null && turn.revision > header.revision) ||
        (header.preparing
            ? active != null || latest != null || requested != null
            : header.activeTurnId != active?.turnId ||
                active?.remoteMayStillBeRunning == false)) {
      throw const FormatException(
          'Display turn controls do not match the history head.');
    }
    return HandrailDisplayControl._(
        header.conversationId,
        header.generation,
        header.revision,
        header.canonicalRevision,
        header.preparing,
        header.activeTurnId,
        active,
        latest,
        requested, json['hasPendingApprovals'] as bool?);
  }
}

extension HandrailClientDisplayControl on HandrailAiClient {
  Future<HandrailDisplayControl> displayHistoryControl(
      {required String conversationId,
      required HandrailDisplayHistoryCapability capability,
      String? turnId,
      Future<void>? cancellation,
      Duration timeout = const Duration(seconds: 30)}) async {
    if (!capability.control)
      throw const HandrailGatewayException('display_control_unavailable',
          'This server does not support bounded turn controls.');
    if (!_historyId(conversationId) || turnId != null && !_historyId(turnId)) {
      throw ArgumentError('Invalid display control identity.');
    }
    final control = HandrailDisplayControl.fromJson(await _displayRequest(
        'control',
        {
          'conversationId': conversationId,
          if (turnId != null) 'turnId': turnId,
        },
        32768 + 1024,
        cancellation,
        timeout));
    if (control.conversationId != conversationId ||
        control.requestedTurn != null &&
            control.requestedTurn!.turnId != turnId) {
      throw const FormatException(
          'Display controls do not match their request.');
    }
    return control;
  }
}
