import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

HandrailRealtimeActivityPage page(
        {bool details = false,
        String conversation = 'conversation',
        HandrailRealtimeCallStatus status = HandrailRealtimeCallStatus.active,
        int completed = 0,
        List<HandrailRealtimeToolActivity> tools = const [],
        String? next,
        bool? unread,
        HandrailRealtimeActivityReadToken? readToken}) =>
    HandrailRealtimeActivityPage(
        call: HandrailRealtimeCall(
            callId: 'voice', conversationId: conversation, status: status),
        counts: HandrailRealtimeToolCounts(
            total: 2, running: 2 - completed, completed: completed, failed: 0),
        tools: details ? tools : null,
        nextToolCallId: next,
        unread: unread,
        readToken: readToken);
const first = HandrailRealtimeToolActivity(
    toolCallId: 'first',
    name: 'read_products',
    status: HandrailRealtimeToolStatus.running);
const second = HandrailRealtimeToolActivity(
    toolCallId: 'second',
    name: 'update_product',
    status: HandrailRealtimeToolStatus.running);

HandrailRealtimeActivityReadToken token(int completed) =>
    HandrailRealtimeActivityReadToken(
        callId: 'voice',
        scopeBinding: 'a' * 64,
        callVersion: 7,
        total: 2,
        completed: completed,
        failed: 0);

void main() {
  test('read tokens must match the displayed call and counts', () {
    final value = {
      'callId': 'voice',
      'conversationId': 'conversation',
      'status': 'ended',
      'unread': true,
      'readToken': token(1).toJson(),
      'summary': {'total': 2, 'running': 1, 'completed': 1, 'failed': 0}
    };
    expect(HandrailRealtimeActivityPage.fromJson(value).readToken?.toJson(),
        token(1).toJson());
    expect(
        () => HandrailRealtimeActivityPage.fromJson(
            {...value, 'readToken': token(2).toJson()}),
        throwsFormatException);
    expect(
        () => HandrailRealtimeActivityPage.fromJson(
            {...value, 'status': 'active'}),
        throwsFormatException);
    expect(
        () => HandrailRealtimeActivityPage.fromJson(
            {...value, 'readToken': null}),
        throwsFormatException);
  });

  test(
      'acknowledges the displayed token without optimistically clearing newer outcomes',
      () async {
    var completed = 0, seen = -1;
    Completer<void>? pending = Completer();
    final acknowledgements = <int>[];
    final monitor = HandrailRealtimeActivityMonitor(
        conversationId: 'conversation',
        callId: 'voice',
        readPage: (details, _) async => page(
            details: details,
            completed: completed,
            unread: seen < completed,
            readToken: token(completed),
            status: HandrailRealtimeCallStatus.ended),
        acknowledgeRead: (receipt) async {
          acknowledgements.add(receipt.completed);
          await pending?.future;
          seen = receipt.completed;
        });
    addTearDown(monitor.dispose);
    await monitor.refresh();
    final old = monitor.markRead(monitor.state.readToken!);
    expect(identical(old, monitor.markRead(monitor.state.readToken!)), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(monitor.state.unread, isTrue);
    completed = 1;
    await monitor.refresh();
    pending.complete();
    await old;
    expect(monitor.state.counts?.completed, 1);
    expect(monitor.state.unread, isTrue);
    pending = null;
    expect(await monitor.markRead(monitor.state.readToken!), isTrue);
    expect(monitor.state.unread, isFalse);
    expect(acknowledgements, [0, 1]);
  });

  test(
      'queues a different displayed token behind an acknowledgement already in flight',
      () async {
    var completed = 0, seen = -1;
    final pending = Completer<void>();
    final acknowledgements = <int>[];
    final monitor = HandrailRealtimeActivityMonitor(
        conversationId: 'conversation',
        callId: 'voice',
        readPage: (_, __) async => page(
            completed: completed,
            unread: seen < completed,
            readToken: token(completed),
            status: HandrailRealtimeCallStatus.ended),
        acknowledgeRead: (receipt) async {
          acknowledgements.add(receipt.completed);
          if (receipt.completed == 0) await pending.future;
          seen = receipt.completed;
        });
    addTearDown(monitor.dispose);
    await monitor.refresh();
    final first = monitor.markRead(monitor.state.readToken!);
    await Future<void>.delayed(Duration.zero);
    completed = 1;
    await monitor.refresh();
    final second = monitor.markRead(monitor.state.readToken!);
    expect(identical(first, second), isFalse);
    pending.complete();
    await Future.wait([first, second]);
    expect(acknowledgements, [0, 1]);
    expect(monitor.state.unread, isFalse);
  });

  test(
      'failed or disposed read acknowledgements retain evidence and never trigger a new request',
      () async {
    var fail = true;
    Completer<void>? pending;
    var requests = 0;
    final monitor = HandrailRealtimeActivityMonitor(
        conversationId: 'conversation',
        callId: 'voice',
        readPage: (_, __) async => page(
            unread: true,
            readToken: token(0),
            status: HandrailRealtimeCallStatus.ended),
        acknowledgeRead: (_) async {
          requests++;
          if (fail) throw StateError('private receipt error');
          await pending?.future;
        });
    await monitor.refresh();
    expect(await monitor.markRead(monitor.state.readToken!), isFalse);
    expect(monitor.state.unread, isTrue);
    expect(monitor.state.readError, isNot(contains('private')));
    expect(monitor.state.readError, isNotNull);
    fail = false;
    pending = Completer();
    await monitor.refresh();
    final last = monitor.markRead(monitor.state.readToken!);
    await Future<void>.delayed(Duration.zero);
    await monitor.dispose();
    final state = monitor.state;
    pending.complete();
    expect(await last, isFalse);
    expect(identical(state, monitor.state), isTrue);
    expect(requests, 2);
  });

  test('parses counts and optional details without accepting malformed state',
      () {
    final value = {
      'callId': 'voice',
      'conversationId': 'conversation',
      'status': 'active',
      'summary': {'total': 2, 'running': 1, 'completed': 1, 'failed': 0}
    };
    expect(HandrailRealtimeActivityPage.fromJson(value).tools, isNull);
    expect(
        () => HandrailRealtimeActivityPage.fromJson({
              ...value,
              'summary': {'total': 2, 'running': 2, 'completed': 1, 'failed': 0}
            }),
        throwsFormatException);
    expect(() => HandrailRealtimeActivityPage.fromJson({...value, 'tools': []}),
        throwsFormatException);
    expect(
        () =>
            HandrailRealtimeActivityPage.fromJson({...value, 'status': 'idle'}),
        throwsFormatException);
  });
  test(
      'retains evidence on failed, foreign or regressed reads and marks ended tools unresolved',
      () async {
    var mode = 'active';
    final monitor = HandrailRealtimeActivityMonitor(
        conversationId: 'conversation',
        callId: 'voice',
        readPage: (_, __) async {
          if (mode == 'failed') throw StateError('private provider details');
          return page(
              conversation: mode == 'foreign' ? 'other' : 'conversation',
              completed: mode == 'regressed' ? 0 : 1,
              status: mode == 'ended'
                  ? HandrailRealtimeCallStatus.ended
                  : HandrailRealtimeCallStatus.active);
        });
    addTearDown(monitor.dispose);
    await monitor.refresh();
    expect(monitor.state.counts?.completed, 1);
    for (final failure in ['failed', 'foreign', 'regressed']) {
      mode = failure;
      await monitor.refresh();
      expect(monitor.state.counts?.completed, 1);
      expect(monitor.state.error, isNot(contains('private')));
      expect(monitor.state.error, isNotNull);
      expect(monitor.state.hasUnresolvedTools, isTrue);
    }
    mode = 'ended';
    await monitor.refresh();
    expect(monitor.state.hasUnresolvedTools, isTrue);
    mode = 'active';
    await monitor.refresh();
    expect(monitor.state.call?.status, HandrailRealtimeCallStatus.ended);
  });
  test('older lifecycle responses cannot clear a displayed voice unread token',
      () async {
    var ended = true;
    final monitor = HandrailRealtimeActivityMonitor(
      conversationId: 'conversation',
      callId: 'voice',
      readPage: (details, after) async => page(
        status: ended
            ? HandrailRealtimeCallStatus.ended
            : HandrailRealtimeCallStatus.active,
        unread: ended,
        readToken: ended ? token(1) : null,
      ),
    );
    addTearDown(monitor.dispose);
    await monitor.refresh();
    expect(monitor.state.unread, isTrue);
    ended = false;
    await monitor.refresh();
    expect(monitor.state.unread, isTrue);
    expect(monitor.state.readToken?.callVersion, 7);
    expect(monitor.state.call?.status, HandrailRealtimeCallStatus.ended);
    expect(monitor.state.error, isNotNull);
  });
  test('details are opt-in, bounded, paged and retained across polling',
      () async {
    final requests = <(bool, String?)>[];
    var cycle = false;
    final monitor = HandrailRealtimeActivityMonitor(
        conversationId: 'conversation',
        callId: 'voice',
        maxPages: 2,
        readPage: (details, after) async {
          requests.add((details, after));
          if (!details) return page();
          return after == null
              ? page(details: true, tools: [first], next: 'first')
              : page(
                  details: true, tools: [second], next: cycle ? 'first' : null);
        });
    addTearDown(monitor.dispose);
    await monitor.refresh();
    expect(requests, [(false, null)]);
    await monitor.setDetails(true);
    expect(monitor.state.tools, [first]);
    expect(monitor.state.hasMore, isTrue);
    await monitor.loadMore();
    expect(monitor.state.tools, [first, second]);
    expect(monitor.state.hasMore, isFalse);
    await monitor.refresh();
    expect(monitor.state.tools, [first, second]);
    cycle = true;
    await monitor.refresh();
    expect(monitor.state.error, isNotNull);
    expect(monitor.state.tools, [first, second]);
    await monitor.setDetails(false);
    expect(monitor.state.tools, isEmpty);
    expect(requests.last, (false, null));
  });
  test(
      'joins concurrent reads and ignores late details after hiding or disposal',
      () async {
    Completer<HandrailRealtimeActivityPage>? pending;
    var reads = 0;
    final monitor = HandrailRealtimeActivityMonitor(
        conversationId: 'conversation',
        callId: 'voice',
        readPage: (details, _) async {
          reads++;
          return pending?.future ?? page(details: details, tools: [first]);
        });
    await monitor.setDetails(true);
    pending = Completer();
    final read = monitor.refresh();
    expect(identical(read, monitor.refresh()), isTrue);
    await Future<void>.delayed(Duration.zero);
    final hide = monitor.setDetails(false);
    expect(monitor.state.tools, isEmpty);
    final response = pending;
    pending = null;
    response.complete(page(details: true, tools: [first]));
    await hide;
    expect(monitor.state.details, isFalse);
    expect(monitor.state.tools, isEmpty);
    expect(reads, 3);
    pending = Completer();
    final last = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    await monitor.dispose();
    final snapshot = monitor.state;
    pending.complete(page(completed: 2));
    await last;
    expect(identical(snapshot, monitor.state), isTrue);
  });
}
