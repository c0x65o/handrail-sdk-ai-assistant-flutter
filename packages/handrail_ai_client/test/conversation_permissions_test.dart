import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'conversation_deletion_test.dart' show Deletions;

final denied = isA<HandrailGatewayException>()
    .having((error) => error.code, 'code', 'conversation_management_forbidden');

class GateJournal implements HandrailConversationDeletionStore {
  GateJournal(this.delegate, this.afterSave);
  final HandrailConversationDeletionStore delegate;
  final void Function() afterSave;
  @override
  Future<List<HandrailConversationDeletionRequest>> loadDeletions() =>
      delegate.loadDeletions();
  @override
  Future<void> acknowledgeDeletion(
          HandrailConversationDeletionRequest request) =>
      delegate.acknowledgeDeletion(request);
  @override
  Future<void> retainDeletion(
      HandrailConversationDeletionRequest request) async {
    await delegate.retainDeletion(request);
    afterSave();
  }
}

void main() {
  for (final empty in [false, true]) {
    test(
        'read-only catalog loads without automatic creation or writes (empty $empty)',
        () async {
      final fixture = Deletions();
      if (empty) fixture.rows.clear();
      final controller = HandrailAssistantController(
          client: fixture.client,
          pendingStore: fixture.pending,
          pollingInterval: null,
          allowConversationManagement: () => false);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.historyError, isNull);
      expect(controller.error, isNull);
      expect(controller.historyPresentation['canCreate'], isFalse);
      expect(controller.historyPresentation['catalogActions'], {
        'archive': false,
        'restore': false,
        'permanentDelete': false,
      });
      expect(controller.document != null, !empty);
      for (final action in [
        controller.newConversation,
        () => controller.archive('one'),
        () => controller.restore('one'),
        () => controller.permanentlyDelete('one', 1)
      ]) {
        await expectLater(action(), throwsA(denied));
      }
      expect(fixture.creations, isEmpty);
      expect(fixture.deletes, isEmpty);
      expect(await fixture.pending.loadDeletions(), isEmpty);
      expect(
          fixture.requests.where((r) =>
              RegExp(r'/(create|archive|restore|permanent-delete)$')
                  .hasMatch(r.url.path)),
          isEmpty);
    });
  }

  test('metadata sampling cannot dispatch creation after permission changes',
      () async {
    final fixture = Deletions();
    var allowed = true;
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        allowConversationManagement: () => allowed,
        newConversationMetadata: () {
          allowed = false;
          return {'context': 'Reports'};
        });
    addTearDown(controller.dispose);
    await expectLater(controller.newConversation(), throwsA(denied));
    expect(fixture.requests, isEmpty);
    expect(fixture.creations, isEmpty);
  });

  test('archive rechecks permission after reading its target descriptor',
      () async {
    final fixture = Deletions();
    var allowed = true;
    fixture.before = (request, body) async {
      if (request.url.path.endsWith('/conversations/get')) allowed = false;
      return null;
    };
    final controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        allowConversationManagement: () => allowed);
    addTearDown(controller.dispose);
    await expectLater(controller.archive('one'), throwsA(denied));
    expect(fixture.rows['one']!['lifecycle'], 'active');
    expect(
        fixture.requests.any((r) => r.url.path.endsWith('/archive')), isFalse);
  });

  test(
      'revocation during deletion journaling prevents dispatch and preserves exact recovery intent',
      () async {
    final fixture = Deletions();
    var allowed = true;
    var controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        deletionStore: GateJournal(fixture.pending, () => allowed = false),
        allowConversationManagement: () => allowed);
    addTearDown(() => controller.dispose());
    await controller.initialize();
    await expectLater(controller.permanentlyDelete('one', 1), throwsA(denied));
    final saved = (await fixture.pending.loadDeletions()).single;
    expect(fixture.deletes, isEmpty);
    await controller.dispose();
    controller = HandrailAssistantController(
        client: fixture.client,
        pendingStore: fixture.pending,
        pollingInterval: null,
        allowConversationManagement: () => allowed);
    await controller.initialize();
    expect(controller.document!.conversationId, 'two');
    expect(controller.hasPendingDeletion('one'), isTrue);
    expect(fixture.deletes, isEmpty);
    expect((await fixture.pending.loadDeletions()).single.toJson(),
        saved.toJson());
    allowed = true;
    await controller.initialize();
    expect(fixture.deletes.single, saved.toJson());
    expect(controller.deletedConversationIds, contains('one'));
    expect(await fixture.pending.loadDeletions(), isEmpty);
  });
}
