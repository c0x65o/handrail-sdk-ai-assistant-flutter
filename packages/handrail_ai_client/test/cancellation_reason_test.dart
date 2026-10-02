import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

HandrailStreamFrame frame(String type, int sequence,
        {String turn = 'turn', String? reason}) =>
    HandrailStreamFrame('event', '$turn:$sequence', {
      'turnId': turn,
      'event': {
        'type': type,
        'sequence': sequence,
        if (reason != null) 'reason': reason
      },
    });

void main() {
  for (final pair in {
    'explicit_stop': 'user',
    'deadline_exceeded': 'timeout',
    'policy_revoked': 'superseded',
    'runtime_shutdown': 'runtime_shutdown',
  }.entries) {
    test('${pair.key} survives stream replay and canonical reload', () {
      final started = const HandrailConversationState(conversationId: 'chat')
          .apply(frame('response.started', 0));
      final terminal = frame('response.cancelled', 1, reason: pair.key);
      final stopped = started.apply(terminal);
      expect(stopped.status, HandrailTurnStatus.cancelled);
      expect(stopped.cancellationReason, pair.value);
      expect(stopped.observationConnected, isFalse);
      expect(identical(stopped.apply(terminal), stopped), isTrue);
      expect(identical(stopped.apply(frame('response.completed', 2)), stopped),
          isTrue);
      expect(identical(stopped.apply(frame('response.text.delta', 3)), stopped),
          isTrue);
      final document = HandrailConversationDocument.fromSnapshot('chat', {
        'conversationId': 'chat',
        'revision': 2,
        'state': {
          'conversation_id': 'chat',
          'revision': 2,
          'active_turn_id': null,
          'turns': [
            {
              'turn_id': 'turn',
              'status': 'cancelled',
              'cancellation_reason': pair.value,
              'remote_may_still_be_running': false
            }
          ],
          'messages': [],
        },
      });
      expect(document.runtimeState.cancellationReason, pair.value);
      expect(document.runtimeState.status, HandrailTurnStatus.cancelled);
      final next = document.runtimeState
          .apply(frame('response.started', 0, turn: 'next'));
      expect(next.cancellationReason, isNull);
      expect(next.status, HandrailTurnStatus.running);
      expect(identical(next.apply(terminal), next), isTrue);
      expect(next.apply(frame('response.completed', 1, turn: 'next')).status,
          HandrailTurnStatus.completed);
    });
  }
  for (final reason in ['user', 'timeout', 'superseded', 'runtime_shutdown']) {
    test('bounded controls preserve $reason and reject unknown values', () {
      final value = <String, Object?>{'turnId': 'turn', 'status': 'cancelled', 'revision': 2,
        'remoteMayStillBeRunning': false, 'error': null, 'cancellationReason': reason};
      expect(HandrailDisplayTurnControl.fromJson(value).cancellationReason, reason);
      expect(() => HandrailDisplayTurnControl.fromJson({...value, 'cancellationReason': 'unknown'}), throwsFormatException);
    });
  }
  for (final remoteTurn in ['turn', null]) test('coarse completed activity $remoteTurn cannot relabel a known user Stop', () async {
    final workspace = HandrailConversationWorkspace();
    workspace.open(const HandrailConversationState(conversationId: 'chat', turnId: 'turn',
      status: HandrailTurnStatus.cancelled, cancellationReason: 'user'));
    workspace.replaceRemoteActivity([HandrailConversationActivityRecord.fromJson({
      'conversationId': 'chat', 'turnId': remoteTurn, 'turnStatus': 'completed', 'unread': true,
    })]);
    final state = workspace.snapshot.conversations.single.state;
    expect(state.status, HandrailTurnStatus.cancelled);
    expect(state.cancellationReason, 'user');
    await workspace.dispose();
  });
  test('unknown cancellation is rejected instead of relabelled', () {
    expect(
        () => const HandrailConversationState(conversationId: 'chat')
            .apply(frame('response.cancelled', 1, reason: 'unknown')),
        throwsFormatException);
  });
}
