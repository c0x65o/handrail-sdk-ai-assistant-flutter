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
  test(
      'oversized scopes fence late reads, retain evidence and recover on a valid scope',
      () async {
    final saved = [
      call('one', 'active'),
      call('two', 'unread',
          status: HandrailRealtimeCallStatus.ended, completed: 1, unread: true),
    ];
    Completer<HandrailRealtimeWorkspacePage>? pending;
    var reads = 0, visited = 0;
    final monitor = HandrailRealtimeWorkspaceMonitor(
        pollingInterval: const Duration(milliseconds: 250),
        readPage: (ids, after) {
          reads++;
          return pending?.future ??
              Future.value(HandrailRealtimeWorkspacePage(calls: saved));
        });
    addTearDown(monitor.dispose);
    await monitor.setConversations(['one', 'two']);
    pending = Completer();
    final oldRead = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    Iterable<String> oversized() sync* {
      for (var index = 0; index < 50000; index++) {
        visited++;
        yield 'conversation-$index';
      }
    }

    await expectLater(
        monitor.setConversations(oversized()), throwsArgumentError);
    expect(visited, 10001);
    expect(monitor.state.failure, HandrailRealtimeWorkspaceFailure.scopeLimit);
    expect(monitor.state.synchronized, isFalse);
    expect(monitor.state.loading, isFalse);
    expect(monitor.state.calls, saved);
    expect(monitor.state.forConversation('one').activeCalls, 1);
    expect(monitor.state.forConversation('two').unreadCalls, 1);
    final before = reads;
    monitor.startPolling();
    await monitor.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(reads, before);
    final held = pending;
    pending = null;
    held.complete(HandrailRealtimeWorkspacePage(calls: []));
    await oldRead;
    expect(monitor.state.calls, saved);
    expect(monitor.state.failure, HandrailRealtimeWorkspaceFailure.scopeLimit);
    await monitor.setConversations(['two', 'one']);
    expect(monitor.state.error, isNull);
    expect(monitor.state.failure, isNull);
    expect(monitor.state.synchronized, isTrue);
    expect(monitor.state.calls, saved);
    expect(reads, greaterThan(before));
  });

  test(
      'invalid references retain stale evidence without leaking rejected values',
      () async {
    final saved =
        call('one', 'voice', status: HandrailRealtimeCallStatus.uncertain);
    var reads = 0;
    final monitor =
        HandrailRealtimeWorkspaceMonitor(readPage: (ids, after) async {
      reads++;
      return HandrailRealtimeWorkspacePage(calls: [saved]);
    });
    addTearDown(monitor.dispose);
    for (final invalid in ['', 'private-reference-' * 40]) {
      await monitor.setConversations(['one']);
      final before = reads;
      await expectLater(
          monitor.setConversations([invalid]), throwsArgumentError);
      expect(
          monitor.state.failure, HandrailRealtimeWorkspaceFailure.invalidScope);
      expect(monitor.state.synchronized, isFalse);
      expect(monitor.state.forConversation('one').unconfirmedCalls, 1);
      expect(monitor.state.error, isNot(contains('private-reference')));
      await monitor.refresh();
      expect(reads, before);
    }
  });

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
