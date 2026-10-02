import 'dart:async';

import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'approval_decisions_test.dart' show Approvals, item;

class DelayedApprovals extends Approvals {
  final entered = Completer<void>(), release = Completer<void>();
  bool failRefresh = false;

  @override
  Future<http.Response> handle(http.Request request) async {
    if (decisions.isNotEmpty && request.url.path.endsWith('/synchronization')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      if (failRefresh) return http.Response('unavailable', 503);
    }
    return super.handle(request);
  }
}

void main() {
  for (final conflict in [false, true]) {
    test(
        '${conflict ? 'conflicted' : 'acknowledged'} binding stays retired through failed refresh',
        () async {
      final f = DelayedApprovals()..conflict = conflict;
      final c = f.controller(autoCreate: false);
      addTearDown(c.dispose);
      addTearDown(f.client.close);
      await c.initialize();
      await c.approvals.review('p', 1);
      final binding = item(c)['binding'] as String;
      f.failRefresh = true;
      final operation = c.approvals.decide('p', 1, binding, true);
      final completed = conflict
          ? expectLater(operation, throwsA(isA<HandrailGatewayException>()))
          : operation;
      await f.entered.future;
      expect(item(c)['canReview'], false);
      expect(item(c)['canConfirm'], false);
      expect(item(c)['canReject'], false);
      f.release.complete();
      await completed;
      expect(c.session!.error, isNotNull);
      expect(await f.pending.loadApprovalDecisions(), isEmpty);
      expect(item(c)['pendingDecision'], false);
      expect(item(c)['canReview'], false);
      expect(item(c)['canConfirm'], false);
      expect(item(c)['canReject'], false);
      await expectLater(
          c.approvals.review('p', 1), throwsA(isA<HandrailGatewayException>()));
      await expectLater(() async => c.approvals.decide('p', 1, binding, false),
          throwsA(isA<HandrailGatewayException>()));
      expect(f.decisions, hasLength(1));
      // A later canonical version releases only that new binding for inspection.
      f.proposal = {...f.proposal, 'proposal_version': 4, 'status': 'executed'};
      f.failRefresh = false;
      await c.session!.refresh();
      await c.approvals.review('p', 4);
      expect(item(c)['error'], isNull);
      expect(item(c)['reviewed'], true);
      expect(item(c)['canConfirm'], false);
    });
  }

  test('review finishing during rejection cannot outlive its decided binding',
      () async {
    final f = DelayedApprovals();
    final entered = Completer<void>(), release = Completer<void>();
    final c = HandrailAssistantController(
      client: f.client,
      pendingStore: f.pending,
      pollingInterval: null,
      loadApprovalReview: (p) async {
        entered.complete();
        await release.future;
        throw const HandrailGatewayException(
            'review_unavailable', 'Unavailable',
            statusCode: 409);
      },
    );
    addTearDown(c.dispose);
    addTearDown(f.client.close);
    await c.initialize();
    final review = expectLater(
        c.approvals.review('p', 1), throwsA(isA<HandrailGatewayException>()));
    await entered.future;
    final decision =
        c.approvals.decide('p', 1, item(c)['binding'] as String, false);
    await f.entered.future;
    release.complete();
    await review;
    expect(item(c)['proposal_version'], 1);
    expect(item(c)['error'], isNull);
    expect(item(c)['canReview'], false);
    f.release.complete();
    await decision;
    expect(item(c)['status'], 'rejected');
    expect(item(c)['error'], isNull);
    expect(f.decisions, hasLength(1));
  });

  for (final changed in [false, true]) {
    test(
        'late review failure is bound to the ${changed ? 'old' : 'current'} proposal',
        () async {
      final f = Approvals();
      final entered = Completer<void>(), release = Completer<void>();
      final c = HandrailAssistantController(
        client: f.client,
        pendingStore: f.pending,
        pollingInterval: null,
        loadApprovalReview: (p) async {
          entered.complete();
          await release.future;
          throw const HandrailGatewayException(
              'review_unavailable', 'Unavailable',
              statusCode: 409);
        },
      );
      addTearDown(c.dispose);
      addTearDown(f.client.close);
      await c.initialize();
      final result = expectLater(
          c.approvals.review('p', 1), throwsA(isA<HandrailGatewayException>()));
      await entered.future;
      if (changed) {
        f.proposal = {
          ...f.proposal,
          'proposal_version': 4,
          'status': 'executed'
        };
        await c.session!.refresh();
      }
      release.complete();
      await result;
      expect(item(c)['error'], changed ? isNull : contains('Retry review'));
      expect(item(c)['canReview'], true);
      expect(item(c)['canConfirm'], false);
    });
  }
}
