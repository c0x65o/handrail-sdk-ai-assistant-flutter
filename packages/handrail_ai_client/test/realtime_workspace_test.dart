import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

HandrailRealtimeWorkspaceCall call(
  String conversation,
  String id, {
  HandrailRealtimeCallStatus status = HandrailRealtimeCallStatus.active,
  int completed = 0,
  bool unread = false,
}) =>
    HandrailRealtimeWorkspaceCall(
      call: HandrailRealtimeCall(
          conversationId: conversation, callId: id, status: status),
      counts: HandrailRealtimeToolCounts(
          total: 1, running: 1 - completed, completed: completed, failed: 0),
      unread: unread,
    );

void main() {
  test('parses only valid public workspace records', () {
    final data = {
      'calls': [
        {
          'conversationId': 'one',
          'callId': 'voice',
          'status': 'ended',
          'counts': {'total': 1, 'running': 0, 'completed': 1, 'failed': 0},
          'unread': true,
          'providerCallRef': 'private'
        }
      ],
      'next': null
    };
    final page = HandrailRealtimeWorkspacePage.fromJson(data);
    expect(page.calls.single.unread, isTrue);
    expect(() => HandrailRealtimeWorkspacePage.fromJson({'calls': []}),
        throwsFormatException);
    expect(
        () => HandrailRealtimeWorkspaceCall.fromJson({
              'conversationId': 'one',
              'callId': 'voice',
              'status': 'active',
              'counts': {'total': 0, 'running': 0, 'completed': 0, 'failed': 0},
              'unread': true
            }),
        throwsFormatException);
    expect(
        () => HandrailRealtimeWorkspaceCursor.fromJson(
            {'conversationId': 'one', 'callId': ''}),
        throwsFormatException);
  });
  test(
      'discovers independent paged calls and retained unread without acknowledging them',
      () async {
    var ended = false, seen = false;
    final requests = <String?>[];
    final monitor =
        HandrailRealtimeWorkspaceMonitor(readPage: (ids, after) async {
      expect(ids, ['one', 'two']);
      requests.add(after?.callId);
      final first = call('one', 'voice',
          status: ended
              ? HandrailRealtimeCallStatus.ended
              : HandrailRealtimeCallStatus.active,
          unread: ended && !seen);
      return after == null
          ? HandrailRealtimeWorkspacePage(calls: [first], next: first.cursor)
          : HandrailRealtimeWorkspacePage(calls: [
              call('two', 'voice', status: HandrailRealtimeCallStatus.uncertain)
            ]);
    });
    addTearDown(monitor.dispose);
    await monitor.setConversations(['two', 'one']);
    expect(requests, [null, 'voice']);
    expect(monitor.state.forConversation('one').activeCalls, 1);
    expect(monitor.state.forConversation('two').unconfirmedCalls, 1);
    expect(monitor.state.forConversation('two').unresolvedTools, 1);
    ended = true;
    await monitor.refresh();
    expect(monitor.state.forConversation('one').activeCalls, 0);
    expect(monitor.state.forConversation('one').unreadCalls, 1);
    await monitor.refresh();
    expect(monitor.state.forConversation('one').unreadCalls, 1);
    seen = true;
    await monitor.refresh();
    expect(monitor.state.forConversation('one').unreadCalls, 0);
  });
  test(
      'retains all evidence on failures, foreign calls, missing pages and lifecycle regression',
      () async {
    var mode = 'valid';
    final saved = call('one', 'voice',
        status: HandrailRealtimeCallStatus.ended, completed: 1, unread: true);
    final monitor = HandrailRealtimeWorkspaceMonitor(
        maxPages: 1,
        readPage: (ids, after) async {
          if (mode == 'error') throw StateError('Private server error');
          return HandrailRealtimeWorkspacePage(
              calls: switch (mode) {
                'missing' => [],
                'foreign' => [call('outside', 'voice')],
                'regressed' => [call('one', 'voice')],
                'duplicate' => [saved, saved],
                _ => [saved],
              },
              next: mode == 'truncated' ? saved.cursor : null);
        });
    addTearDown(monitor.dispose);
    await monitor.setConversations(['one']);
    for (final failure in [
      'error',
      'missing',
      'foreign',
      'regressed',
      'duplicate',
      'truncated'
    ]) {
      mode = failure;
      await monitor.refresh();
      expect(
          monitor.state.error, 'Could not refresh voice activity. Retrying…');
      expect(monitor.state.calls.single, saved);
      expect(monitor.state.forConversation('one').unreadCalls, 1);
    }
  });
  test('joins reads and drops late replies after scope changes or disposal',
      () async {
    Completer<HandrailRealtimeWorkspacePage>? pending;
    final requests = <List<String>>[];
    final monitor =
        HandrailRealtimeWorkspaceMonitor(readPage: (ids, after) async {
      requests.add(ids);
      return pending?.future ??
          HandrailRealtimeWorkspacePage(calls: [call(ids.single, 'voice')]);
    });
    await monitor.setConversations(['one']);
    pending = Completer();
    final old = monitor.refresh();
    expect(identical(old, monitor.refresh()), isTrue);
    await Future<void>.delayed(Duration.zero);
    final changed = monitor.setConversations(['two']);
    expect(monitor.state.calls, isEmpty);
    final response = pending;
    pending = null;
    response
        .complete(HandrailRealtimeWorkspacePage(calls: [call('one', 'voice')]));
    await changed;
    expect(monitor.state.calls.single.call.conversationId, 'two');
    expect(requests, [
      ['one'],
      ['one'],
      ['two']
    ]);
    pending = Completer();
    final last = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    await monitor.dispose();
    final saved = monitor.state;
    pending.complete(HandrailRealtimeWorkspacePage(calls: []));
    await last;
    expect(identical(saved, monitor.state), isTrue);
  });
  test(
      'chunks large catalogs and stops on repeated cursors without publishing partial state',
      () async {
    final requests = <int>[];
    var repeated = false;
    final monitor =
        HandrailRealtimeWorkspaceMonitor(readPage: (ids, after) async {
      requests.add(ids.length);
      final value = call(ids.first, 'voice');
      return HandrailRealtimeWorkspacePage(
          calls: [value], next: repeated ? value.cursor : null);
    });
    addTearDown(monitor.dispose);
    await monitor
        .setConversations(List.generate(101, (index) => 'conversation-$index'));
    expect(requests, [100, 1]);
    expect(monitor.state.calls, hasLength(2));
    repeated = true;
    await monitor.refresh();
    expect(monitor.state.error, isNotNull);
    expect(monitor.state.calls, hasLength(2));
    await monitor.setConversations([]);
    expect(monitor.state.calls, isEmpty);
    expect(monitor.state.synchronized, isTrue);
  });
}
