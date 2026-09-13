import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

HandrailRealtimeCall call(String id,
        [HandrailRealtimeCallStatus status = HandrailRealtimeCallStatus.active,
        String conversation = 'one']) =>
    HandrailRealtimeCall(
        callId: id, conversationId: conversation, status: status);
HandrailRealtimeCallPage page(List<HandrailRealtimeCall> calls,
        [String? after]) =>
    HandrailRealtimeCallPage(calls: calls, nextCallId: after);

void main() {
  test(
      'restores all pages and retains unfinished evidence after failed, partial or omitted reads',
      () async {
    var mode = 'ready';
    final cursors = <String?>[];
    final monitor = HandrailRealtimeCallMonitor(
        conversationId: 'one',
        maxPages: 2,
        readPage: (after) async {
          cursors.add(after);
          if (mode == 'offline') throw StateError('private transport details');
          if (mode == 'empty') return page([]);
          if (mode == 'loop') return page([call('a')], 'a');
          if (after == null) return page([call('a')], 'a');
          return page([call('b', HandrailRealtimeCallStatus.uncertain)]);
        },
        requestEnd: (id) async => call(id, HandrailRealtimeCallStatus.ended));
    addTearDown(monitor.dispose);
    expect(monitor.state.canStartCall, isFalse);
    await monitor.refresh();
    expect(cursors, [null, 'a']);
    expect(monitor.state.unfinished.map((call) => call.callId), ['a', 'b']);
    for (final failure in ['offline', 'loop', 'empty']) {
      mode = failure;
      await monitor.refresh();
      expect(monitor.state.unfinished, hasLength(2));
      expect(monitor.state.canStartCall, isFalse);
      if (failure != 'empty')
        expect(monitor.state.error, isNot(contains('private')));
    }
  });

  test(
      'serializes reads and ends, rejects stale reads and preserves confirmed terminal evidence',
      () async {
    Completer<HandrailRealtimeCallPage>? delayedRead;
    Completer<HandrailRealtimeCall>? delayedEnd;
    var reads = 0, ends = 0;
    final monitor = HandrailRealtimeCallMonitor(
        conversationId: 'one',
        readPage: (_) async {
          reads++;
          return delayedRead == null ? page([call('a')]) : delayedRead.future;
        },
        requestEnd: (_) async {
          ends++;
          return delayedEnd!.future;
        });
    addTearDown(monitor.dispose);
    await monitor.refresh();
    delayedRead = Completer();
    final first = monitor.refresh(), second = monitor.refresh();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(reads, 2);
    delayedEnd = Completer();
    final endOne = monitor.end('a'), endTwo = monitor.end('a');
    expect(identical(endOne, endTwo), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(ends, 1);
    delayedEnd.complete(call('a', HandrailRealtimeCallStatus.ended));
    await endOne;
    delayedRead.complete(page([call('a')]));
    await first;
    expect(monitor.state.calls.single.status, HandrailRealtimeCallStatus.ended);
    delayedRead = null;
    await monitor.refresh();
    expect(monitor.state.calls.single.status, HandrailRealtimeCallStatus.ended);
    expect(monitor.state.canStartCall, isTrue);
    await monitor.end('a');
    expect(ends, 1);
  });

  test(
      'keeps accepted and failed termination uncertain and rejects a foreign acknowledgement',
      () async {
    var result = 'accepted';
    final monitor = HandrailRealtimeCallMonitor(
        conversationId: 'one',
        readPage: (_) async => page([call('a')]),
        requestEnd: (id) async {
          if (result == 'failed') throw StateError('private provider error');
          return call(
              id,
              result == 'accepted'
                  ? HandrailRealtimeCallStatus.ending
                  : HandrailRealtimeCallStatus.ended,
              result == 'foreign' ? 'two' : 'one');
        });
    addTearDown(monitor.dispose);
    await monitor.refresh();
    await monitor.end('a');
    expect(monitor.state.unfinished.single.status,
        HandrailRealtimeCallStatus.ending);
    await monitor.refresh();
    expect(monitor.state.unfinished.single.status,
        HandrailRealtimeCallStatus.ending);
    for (final invalid in ['failed', 'foreign']) {
      result = invalid;
      await monitor.end('a');
      expect(
          monitor.state.calls.single.status, HandrailRealtimeCallStatus.ending);
      expect(monitor.state.canStartCall, isFalse);
      expect(monitor.state.error, isNot(contains('private')));
    }
    result = 'ended';
    await monitor.end('a');
    await monitor.refresh();
    expect(monitor.state.canStartCall, isTrue);
  });

  test('polling never overlaps a stalled read and stops on disposal', () async {
    final pending = Completer<HandrailRealtimeCallPage>();
    var reads = 0;
    final monitor = HandrailRealtimeCallMonitor(
        conversationId: 'one',
        pollInterval: const Duration(milliseconds: 250),
        readPage: (_) {
          reads++;
          return pending.future;
        },
        requestEnd: (id) async => call(id, HandrailRealtimeCallStatus.ended));
    monitor.startPolling();
    monitor.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(reads, 1);
    await monitor.dispose();
    pending.complete(page([]));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(reads, 1);
  });

  test(
      'isolates conversation monitors and discards late responses after disposal',
      () async {
    final pending = Completer<HandrailRealtimeCallPage>();
    final one = HandrailRealtimeCallMonitor(
        conversationId: 'one',
        readPage: (_) => pending.future,
        requestEnd: (id) async => call(id, HandrailRealtimeCallStatus.ended));
    final two = HandrailRealtimeCallMonitor(
        conversationId: 'two',
        readPage: (_) async => page([call('foreign')]),
        requestEnd: (id) async => call(id, HandrailRealtimeCallStatus.ended));
    addTearDown(two.dispose);
    final events = <HandrailRealtimeCallState>[];
    one.changes.listen(events.add);
    final read = one.refresh();
    await Future<void>.delayed(Duration.zero);
    await one.dispose();
    final count = events.length;
    pending.complete(page([call('a')]));
    await read;
    expect(events, hasLength(count));
    await two.refresh();
    expect(two.state.canStartCall, isFalse);
    expect(two.state.calls, isEmpty);
  });
}
