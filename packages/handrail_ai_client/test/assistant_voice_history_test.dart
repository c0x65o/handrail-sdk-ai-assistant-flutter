import 'dart:async';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'assistant_controller_test.dart' show Fixture, descriptor, ok;

HandrailRealtimeWorkspaceCall call(String id,
        {bool active = false, bool uncertain = false, bool unread = false}) =>
    HandrailRealtimeWorkspaceCall(
        call: HandrailRealtimeCall(
            conversationId: id,
            callId: 'voice-$id',
            status: active
                ? HandrailRealtimeCallStatus.active
                : uncertain
                    ? HandrailRealtimeCallStatus.uncertain
                    : HandrailRealtimeCallStatus.ended),
        counts: HandrailRealtimeToolCounts(
            total: 1,
            running: active || uncertain ? 1 : 0,
            completed: active || uncertain ? 0 : 1,
            failed: 0),
        unread: unread);

Map row(HandrailAssistantController controller, String id) =>
    (controller.historyPresentation['rows'] as List)
        .cast<Map>()
        .firstWhere((value) => value['id'] == id);

void main() {
  test(
      'catalog growth beyond the voice limit reports stale activity without async failure',
      () async {
    final fixture = Fixture();
    final ids = [
      'one',
      'two',
      ...List.generate(9999, (index) => 'history-$index')
    ];
    fixture.before = (request, body) async {
      if (!request.url.path.endsWith('/conversations/list')) return null;
      final offset = int.parse(body['cursor'] as String? ?? '0');
      final size = body['pageSize'] as int;
      final page = ids.skip(offset).take(size).toList();
      final more = offset + page.length < ids.length;
      return ok({
        'items': page.map(descriptor).toList(),
        'hasMore': more,
        'nextCursor': more ? '${offset + page.length}' : null,
        'order': body['order'],
      });
    };
    var voiceReads = 0;
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pageSize: 100,
        pollingInterval: null,
        voicePollingInterval: null,
        readVoiceWorkspace: (scope, _) async {
          voiceReads++;
          return HandrailRealtimeWorkspacePage(calls: [
            if (scope.contains('one')) call('one', uncertain: true),
            if (scope.contains('two')) call('two', unread: true),
          ]);
        });
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await controller.voiceWorkspace!.refresh();
    while (controller.hasMoreHistory) {
      await controller.refreshHistory(more: true);
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.visibleHistory, hasLength(10001));
    expect(controller.historyError, isNull);
    expect(controller.historyPresentation['voiceErrorCode'], 'scopeLimit');
    expect((row(controller, 'one')['voice'] as Map)['stale'], isTrue);
    expect((row(controller, 'one')['voice'] as Map)['unconfirmedCalls'], 1);
    expect((row(controller, 'one')['voice'] as Map)['unresolvedTools'], 1);
    expect(controller.unreadCount, 1);
    expect(controller.canSend, isTrue);
    final before = voiceReads;
    await controller.voiceWorkspace!.refresh();
    expect(voiceReads, before);
  });

  test('voice unread and unfinished effects stay independent of text controls',
      () async {
    final fixture = Fixture();
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        voicePollingInterval: null,
        readVoiceWorkspace: (ids, _) async => HandrailRealtimeWorkspacePage(
                calls: [
                  for (final id in ids)
                    call(id, active: id == 'one', unread: id == 'two')
                ]));
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.voiceWorkspace!.refresh();
    expect(controller.canSend, isTrue);
    expect(controller.canStop, isFalse);
    expect(controller.running, isFalse);
    expect(row(controller, 'one')['voice'], {
      'activeCalls': 1,
      'unconfirmedCalls': 0,
      'unreadCalls': 0,
      'unresolvedTools': 0,
      'stale': false,
    });
    expect(row(controller, 'two')['textUnread'], isFalse);
    expect(controller.unreadCount, 1);
    controller.setUnreadOnly(true);
    expect(controller.visibleHistory.map((r) => r.id), ['two']);
    await controller.openConversation('two');
    await controller.markRead();
    expect(controller.unreadCount, 1);
    expect(
        controller.voiceWorkspace!.state.forConversation('two').unreadCalls, 1);
    expect(fixture.requests.where((r) => r.url.path.contains('realtime')),
        isEmpty);
  });

  test('unchanged text/catalog publishes do not restart voice observation',
      () async {
    final fixture = Fixture(), scopes = <List<String>>[];
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        voicePollingInterval: null,
        readVoiceWorkspace: (ids, _) async {
          scopes.add(List.of(ids));
          return HandrailRealtimeWorkspacePage(calls: []);
        });
    addTearDown(controller.dispose);
    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    final initialReads = scopes.length;
    await controller.refreshHistory();
    await controller.markRead();
    controller.setUnreadOnly(true);
    controller.setUnreadOnly(false);
    await Future<void>.delayed(Duration.zero);
    expect(scopes.length, initialReads);
    expect(scopes.last, ['one', 'two']);
    await controller.archive('two');
    await controller.setHistoryView(HandrailHistoryView.archived);
    expect(scopes.length, initialReads);
    await controller.newConversation();
    await Future<void>.delayed(Duration.zero);
    expect(scopes.last, ['new-0', 'one', 'two']);
  });

  test('history retry preserves offline evidence and restores current status',
      () async {
    final fixture = Fixture();
    var offline = false;
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        voicePollingInterval: null,
        readVoiceWorkspace: (ids, _) async {
          if (offline) throw StateError('private provider detail');
          return HandrailRealtimeWorkspacePage(calls: [
            for (final id in ids)
              call(id, uncertain: id == 'one', unread: id == 'two')
          ]);
        });
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.voiceWorkspace!.refresh();
    expect((row(controller, 'one')['voice'] as Map)['unresolvedTools'], 1);
    offline = true;
    await controller.historyBinding.refresh();
    expect(controller.historyPresentation['voiceError'],
        'Could not refresh voice activity. Retrying…');
    expect((row(controller, 'one')['voice'] as Map)['stale'], isTrue);
    expect(controller.unreadCount, 1);
    expect(controller.historyError, isNull);
    expect(controller.canSend, isTrue);
    offline = false;
    await controller.historyBinding.refresh();
    expect(controller.historyPresentation['voiceError'], isNull);
    expect((row(controller, 'one')['voice'] as Map)['stale'], isFalse);
  });

  test('account disposal excludes a late voice result and stops polling',
      () async {
    final fixture = Fixture(),
        held = Completer<HandrailRealtimeWorkspacePage>();
    var reads = 0;
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        voicePollingInterval: const Duration(milliseconds: 250),
        readVoiceWorkspace: (ids, _) {
          reads++;
          return held.future;
        });
    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    await controller.dispose();
    held.complete(
        HandrailRealtimeWorkspacePage(calls: [call('one', unread: true)]));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(reads, 1);
    expect(controller.voiceWorkspace!.state.calls, isEmpty);
  });
}
