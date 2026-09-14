import 'dart:async';
import 'dart:convert';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'assistant_controller_test.dart' show Fixture, ok;

class Deletions extends Fixture {
  final deletes = <Map<String, Object?>>[],
      receipts = <String, Map<String, Object?>>{};
  bool loseReply = false, supported = true, conflict = false;
  Map<String, Object?> changedReceipt = {};
  final entered = Completer<void>();
  Completer<void>? held;
  @override
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/capabilities'))
      return ok({
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'authoritativeCancellation': true,
        'resources': {
          'conversations': {
            'permanentDelete': {'supported': supported},
            'archive': {'supported': true},
            'restore': {'supported': true}
          }
        }
      });
    if (!request.url.path.endsWith('/conversations/permanent-delete'))
      return super.handle(request);
    requests.add(request);
    final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
    deletes.add(body);
    expect(
        (await pending.loadDeletions())
            .any((entry) => entry.idempotencyKey == body['idempotencyKey']),
        isTrue);
    if (!entered.isCompleted) entered.complete();
    await held?.future;
    if (conflict)
      return http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'version_conflict',
              'message': 'The conversation changed.',
              'retryable': false
            }
          }),
          409);
    final retained = receipts.putIfAbsent(
        body['idempotencyKey'] as String, () => Map.of(body));
    expect(body, retained);
    rows.remove(body['conversationId']);
    if (loseReply) {
      loseReply = false;
      return http.Response('lost acknowledgement', 503);
    }
    return ok({
      'operation': 'permanent_delete',
      'status': 'idempotent',
      'conversationId': body['conversationId'],
      'deletedVersion': body['expectedVersion'],
      ...changedReceipt
    });
  }
}

void main() {
  test(
      'an unresolved deletion does not block other conversations after restart',
      () async {
    final fixture = Deletions()..loseReply = true;
    var controller = fixture.controller(autoCreate: false);
    addTearDown(() => controller.dispose());
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(controller.permanentlyDelete('one', 1),
        throwsA(isA<HandrailGatewayException>()));
    await controller.dispose();
    fixture.loseReply = true;
    controller = fixture.controller(autoCreate: false);
    await controller.initialize();
    expect(controller.selectedId, 'two');
    expect(controller.canSend, isTrue);
    expect(controller.hasPendingDeletion('one'), isTrue);
    expect((controller.historyPresentation['pendingDeletions'] as List),
        hasLength(1));
    await controller.permanentlyDelete('one', 1);
    expect(controller.selectedId, 'two');
    expect(controller.canSend, isTrue);
    expect(await fixture.pending.loadDeletions(), isEmpty);
  });

  test('a failed durable-intent write prevents deletion dispatch', () async {
    final fixture = Deletions();
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        deletionStore: FailingJournal(fixture.pending),
        autoCreate: false,
        pollingInterval: null);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(controller.permanentlyDelete('one', 1), throwsStateError);
    expect(fixture.deletes, isEmpty);
    expect(fixture.rows.containsKey('one'), isTrue);
    expect(controller.document, isNotNull);
  });

  test('late catalog reads cannot resurrect deleted descriptors', () async {
    final fixture = Deletions();
    final controller = fixture.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    final entered = Completer<void>(), release = Completer<void>();
    fixture.before = (request, body) async {
      if (!request.url.path.endsWith('/conversations/list')) return null;
      final values = fixture.rows.values.toList();
      entered.complete();
      await release.future;
      return ok({
        'items': values,
        'hasMore': false,
        'nextCursor': null,
        'order': body['order']
      });
    };
    final reading = controller.refreshHistory();
    await entered.future;
    await controller.permanentlyDelete('one', 1);
    release.complete();
    await reading;
    expect(controller.history.map((row) => row.id), ['two']);
    expect(controller.selectedDescriptor, isNull);
  });

  test(
      'failed local cleanup keeps the verified deletion replayable after restart',
      () async {
    final fixture = Deletions();
    final journal = FailingJournal(fixture.pending)..failRetain = false;
    var controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        deletionStore: journal,
        autoCreate: false,
        pollingInterval: null);
    addTearDown(() => controller.dispose());
    addTearDown(fixture.client.close);
    await controller.initialize();
    journal.failAcknowledge = true;
    await expectLater(controller.permanentlyDelete('one', 1), throwsStateError);
    expect(controller.document, isNull);
    expect(controller.deletedConversationIds, {'one'});
    expect(await fixture.pending.loadDeletions(), hasLength(1));
    await controller.dispose();
    journal.failAcknowledge = false;
    controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        deletionStore: journal,
        autoCreate: false,
        pollingInterval: null);
    await controller.initialize();
    expect(fixture.deletes[0], fixture.deletes[1]);
    expect(await fixture.pending.loadDeletions(), isEmpty);
  });
  test(
      'verified deletion evicts its transcript/activity and preserves another selected session',
      () async {
    final fixture = Deletions()..held = Completer<void>();
    final controller = fixture.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    final deletedSession = controller.session!;
    final deleting = controller.permanentlyDelete('one', 1);
    await fixture.entered.future;
    expect(controller.canSend, isFalse);
    await controller.openConversation('two');
    final other = controller.session;
    fixture.held!.complete();
    await deleting;
    expect(controller.selectedId, 'two');
    expect(controller.session, same(other));
    expect(deletedSession.document, isNull);
    expect(controller.sessionFor('one'), isNull);
    expect(controller.deletedConversationIds, {'one'});
    expect(controller.history.map((row) => row.id), ['two']);
    controller.workspace.open(const HandrailConversationState(
        conversationId: 'one', text: 'old transcript'));
    controller.workspace
        .acceptRemoteActivity(HandrailConversationActivityRecord.fromJson({
      'conversationId': 'one',
      'status': 'completed',
      'unread': true,
      'summary': 'old private preview'
    }));
    expect(controller.workspace.remoteActivityFor('one'), isNull);
    expect(controller.previewFor('one'), isEmpty);
    expect(
        controller.workspace.snapshot.conversations
            .map((row) => row.state.conversationId),
        isNot(contains('one')));
    await expectLater(controller.openConversation('one'),
        throwsA(isA<HandrailGatewayException>()));
    expect(await fixture.pending.loadDeletions(), isEmpty);
  });

  test(
      'lost reply survives controller restart and replays before any history or send recovery',
      () async {
    final fixture = Deletions()..loseReply = true;
    var controller = fixture.controller(autoCreate: false);
    addTearDown(() => controller.dispose());
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(controller.permanentlyDelete('one', 1),
        throwsA(isA<HandrailGatewayException>()));
    expect(controller.sessionFor('one')!.document, isNotNull);
    final saved = (await fixture.pending.loadDeletions()).single;
    expect(
        saved.toJson().keys,
        unorderedEquals(
            ['conversationId', 'expectedVersion', 'idempotencyKey']));
    await controller.dispose();
    fixture.supported =
        false; // Existing receipts remain checkable when new deletes are disabled.
    controller = fixture.controller(autoCreate: false);
    final offset = fixture.requests.length;
    await controller.initialize();
    expect(fixture.requests[offset].url.path,
        endsWith('/conversations/permanent-delete'));
    expect(fixture.deletes, [saved.toJson(), saved.toJson()]);
    expect(controller.selectedId, 'two');
    expect(controller.deletedConversationIds, {'one'});
    expect(await fixture.pending.loadDeletions(), isEmpty);
  });

  for (final changed in [
    {'conversationId': 'two'},
    {'deletedVersion': 2},
    {'operation': 'clear'},
    {'status': 'pending'},
  ]) {
    test(
        'mismatched ${changed.keys.single} keeps transcript and exact retry intent',
        () async {
      final fixture = Deletions()..changedReceipt = changed;
      final controller = fixture.controller(autoCreate: false);
      addTearDown(controller.dispose);
      addTearDown(fixture.client.close);
      await controller.initialize();
      await expectLater(
          controller.permanentlyDelete('one', 1), throwsFormatException);
      expect(controller.document, isNotNull);
      expect(controller.deletedConversationIds, isEmpty);
      expect(await fixture.pending.loadDeletions(), hasLength(1));
      fixture.changedReceipt = {};
      await controller.permanentlyDelete('one', 1);
      expect(fixture.deletes[0], fixture.deletes[1]);
    });
  }

  test(
      'version conflict discards rejected intent; a newer version requires a new call',
      () async {
    final fixture = Deletions()..conflict = true;
    final controller = fixture.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(controller.permanentlyDelete('one', 1),
        throwsA(isA<HandrailGatewayException>()));
    expect(fixture.deletes, hasLength(1));
    expect(await fixture.pending.loadDeletions(), isEmpty);
    expect(controller.document, isNotNull);
    fixture.conflict = false;
    await controller.permanentlyDelete('one', 2);
    expect(
        fixture.deletes.map((request) => request['expectedVersion']), [1, 2]);
    expect(fixture.deletes[0]['idempotencyKey'],
        isNot(fixture.deletes[1]['idempotencyKey']));
  });

  test('unsupported deletion performs no destructive request or journal write',
      () async {
    final fixture = Deletions()..supported = false;
    final controller = fixture.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    await expectLater(controller.permanentlyDelete('one', 1),
        throwsA(isA<HandrailGatewayException>()));
    expect(fixture.deletes, isEmpty);
    expect(await fixture.pending.loadDeletions(), isEmpty);
    expect(
        (controller.historyPresentation['catalogActions']
            as Map)['permanentDelete'],
        isFalse);
  });

  test(
      'concurrent calls coalesce; changed version cannot replace uncertain intent',
      () async {
    final fixture = Deletions()..held = Completer<void>();
    final controller = fixture.controller(autoCreate: false);
    addTearDown(controller.dispose);
    addTearDown(fixture.client.close);
    await controller.initialize();
    final deleting = controller.permanentlyDelete('one', 1);
    expect(controller.permanentlyDelete('one', 1), same(deleting));
    await expectLater(controller.permanentlyDelete('one', 2),
        throwsA(isA<HandrailGatewayException>()));
    await fixture.entered.future;
    fixture.held!.complete();
    await deleting;
    expect(fixture.deletes, hasLength(1));
  });

  test(
      'deletion journal serializes adapters, isolates accounts, and acknowledges only exact requests',
      () async {
    final storage = <String, String>{};
    HandrailKeyValuePendingTurnStore journal(String namespace) =>
        HandrailKeyValuePendingTurnStore(
            namespace: namespace,
            read: (key) async => storage[key],
            write: (key, value) async {
              storage[key] = value;
            },
            delete: (key) async {
              storage.remove(key);
            });
    final first = journal('realm/account'),
        second = journal('realm/account'),
        other = journal('realm/other');
    HandrailConversationDeletionRequest request(String id, [int version = 1]) =>
        HandrailConversationDeletionRequest(
            conversationId: id,
            expectedVersion: version,
            idempotencyKey: 'delete-$id-$version');
    await Future.wait([
      first.retainDeletion(request('one')),
      second.retainDeletion(request('two'))
    ]);
    expect((await first.loadDeletions()).map((row) => row.conversationId),
        ['one', 'two']);
    expect(await other.loadDeletions(), isEmpty);
    await second.acknowledgeDeletion(request('one', 2));
    expect(await first.loadDeletions(), hasLength(2));
    await expectLater(second.retainDeletion(request('one', 2)),
        throwsA(isA<HandrailGatewayException>()));
    await first.acknowledgeDeletion(request('one'));
    await second.acknowledgeDeletion(request('two'));
    expect(storage, isEmpty);
  });
}

class FailingJournal implements HandrailConversationDeletionStore {
  FailingJournal(this.delegate);
  final HandrailConversationDeletionStore delegate;
  bool failRetain = true, failAcknowledge = false;
  @override
  Future<List<HandrailConversationDeletionRequest>> loadDeletions() =>
      delegate.loadDeletions();
  @override
  Future<void> retainDeletion(HandrailConversationDeletionRequest request) {
    if (failRetain) throw StateError('Local storage unavailable');
    return delegate.retainDeletion(request);
  }

  @override
  Future<void> acknowledgeDeletion(
      HandrailConversationDeletionRequest request) {
    if (failAcknowledge) throw StateError('Local cleanup unavailable');
    return delegate.acknowledgeDeletion(request);
  }
}
