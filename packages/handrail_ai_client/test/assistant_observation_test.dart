import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'assistant_controller_test.dart' as fixture;

void main() {
  test(
      'one account cycle coalesces activity and skips idle unselected sessions',
      () async {
    final wire = fixture.Fixture();
    final controller = wire.controller();
    addTearDown(controller.dispose);
    addTearDown(wire.client.close);
    var activityReads = 0;
    List<Map<String, Object?>> activity = [];
    Completer<http.Response?>? held;
    wire.before = (request, body) async {
      if (request.url.path.endsWith('/capabilities'))
        return fixture.ok({
          'protocolVersion': applicationGatewayProtocolVersion,
          'synchronization': true,
          'activity': true,
        });
      if (request.url.path.endsWith('/activity')) {
        activityReads++;
        if (held != null) return held.future;
        return fixture.ok(activity);
      }
      return null;
    };
    await controller.initialize();
    await controller.openConversation('two');
    expect(controller.sessionFor('one')!.pollingInterval, isNull);
    expect(controller.sessionFor('two')!.synchronizeActivity, isFalse);
    final initialActivity = activityReads;
    final firstRequest = wire.requests.length;
    held = Completer<http.Response?>();
    final first = controller.refreshObservations();
    expect(controller.refreshObservations(), same(first));
    final directActivity = controller.refreshActivity();
    held.complete(fixture.ok(activity));
    await first;
    await directActivity;
    held = null;
    expect(activityReads, initialActivity + 1);
    Set<String> polledIds(int after) => wire.requests
        .skip(after)
        .where((request) => request.url.path.endsWith('/synchronization'))
        .map((request) => (jsonDecode(request.body)['input']
            as Map)['conversationId'] as String)
        .toSet();
    expect(polledIds(firstRequest), {'two'});
    expect(controller.workingAnywhere, isFalse);

    activity = [
      HandrailConversationActivityRecord(
        conversationId: 'one',
        turnId: 'remote-turn',
        turnRevision: 1,
        status: HandrailTurnStatus.running,
        unread: false,
      ).toJson()
    ];
    final remoteStarted = wire.requests.length;
    await controller.refreshObservations();
    expect(polledIds(remoteStarted), {'one', 'two'});
    expect(activityReads, initialActivity + 2);
    expect(controller.selectedId, 'two');
    expect(controller.workingAnywhere, isTrue);
    activity = [
      HandrailConversationActivityRecord(
        conversationId: 'unopened',
        turnId: 'unopened-turn',
        turnRevision: 1,
        status: HandrailTurnStatus.running,
        unread: false,
      ).toJson()
    ];
    await controller.refreshObservations();
    expect(controller.sessionFor('unopened'), isNull);
    expect(controller.workingAnywhere, isTrue);
    activity = [];
    await controller.refreshObservations();
    expect(controller.workingAnywhere, isFalse);
  });

  test(
      'failed activity retains unread evidence and late disposal replies stay discarded',
      () async {
    final wire = fixture.Fixture(), controller = wire.controller();
    addTearDown(controller.dispose);
    addTearDown(wire.client.close);
    final saved = HandrailConversationActivityRecord(
      conversationId: 'two',
      turnId: 'saved-turn',
      turnRevision: 1,
      status: HandrailTurnStatus.completed,
      unread: true,
    );
    var fail = false;
    Completer<http.Response?>? held;
    wire.before = (request, body) async {
      if (request.url.path.endsWith('/capabilities'))
        return fixture.ok({
          'protocolVersion': applicationGatewayProtocolVersion,
          'synchronization': true,
          'activity': true,
        });
      if (request.url.path.endsWith('/activity')) {
        if (held != null) return held.future;
        return fail
            ? http.Response('unavailable', 503)
            : fixture.ok([saved.toJson()]);
      }
      return null;
    };
    await controller.initialize();
    expect(controller.isUnread('two'), isTrue);
    fail = true;
    await controller.refreshObservations();
    expect(controller.activityError, isNotNull);
    expect(controller.isUnread('two'), isTrue);
    expect(controller.canSend, isTrue);
    fail = false;
    await controller.refreshActivity();
    expect(controller.activityError, isNull);

    var changes = 0;
    final subscription = controller.changes.listen((_) => changes++);
    addTearDown(subscription.cancel);
    held = Completer<http.Response?>();
    final late = controller.refreshObservations();
    // Ensure the request entered the HTTP adapter before closing the account.
    await Future<void>.delayed(Duration.zero);
    await controller.dispose();
    final atClose = changes;
    held.complete(fixture.ok([]));
    await late;
    expect(changes, atClose);
  });
}
