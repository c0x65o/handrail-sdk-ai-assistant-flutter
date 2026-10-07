// Tests private production state through disposable compiler instrumentation.
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../packages/handrail_ai_client/test/display_session_test.dart'
    show Fixture;

class ProofFixture extends Fixture {
  bool partial = false, deferred = false;
  @override
  Future<http.Response> handle(http.Request request) async {
    final response = await super.handle(request);
    final body = jsonDecode(response.body) as Map;
    final value = body['value'];
    if (value is Map && value['records'] is List) {
      if (revision == 0) value['records'] = [];
      if (request.body.contains('"operation":"changes"')) {
        if (partial) value['nextCursor'] = 'remaining-changes';
        if (deferred)
          value['records'] = [
            {...record(99), 'value': null, 'deferred': true},
          ];
      }
    }
    return http.Response(
      jsonEncode(body),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  final captureFailures = [
    'closed activation',
    'disposed',
    'inactive',
    'document missing',
    'document revision',
    'error',
    'refresh error',
    'scheduled refresh',
    'stream refresh',
    'display loading',
    'related loading',
    'approval loading',
    'related pagination',
    'related trim',
    'window disposed',
    'window selection',
    'window conversation',
    'window preparing',
    'window generation',
    'window revision',
    'watermark',
    'cursor',
    'unconsumed',
    'initial page',
    'pending',
    'queued latest',
    'read request',
    'content request',
    'loading',
    'failed',
    'window error',
    'newer',
    'scrolled',
    'deferred',
  ];
  final staleFailures = [
    'reuse',
    'session',
    'client',
    'activation',
    'refresh',
    'observation',
    'display read',
    'related epoch',
    'related version',
    'approval epoch',
    'prepared revision',
    'window observation',
    'window replaced',
    'control replaced',
    'window version',
    'workspace selection',
    'fresh conversation',
    'fresh generation',
    'fresh canonical',
    'fresh projection',
    'fresh preparing',
    'fresh active',
  ];
  Future<ProofFixture> fixture({int revision = 100}) async {
    final f = ProofFixture()..revision = revision;
    addTearDown(() async {
      await f.session.dispose();
      f.client.close();
    });
    await f.session.initialize();
    expect(
      presendPrivateState(f.session)['capturable'],
      false,
      reason: 'An initial page is not a consumed preparation changes read',
    );
    await f.session.refresh();
    expect(presendPrivateState(f.session)['capturable'], true);
    return f;
  }

  for (final partial in [true, false]) {
    test(
      '${partial ? "partial" : "deferred"} response is not consumption proof',
      () async {
        final f = await fixture();
        f.revision++;
        f.partial = partial;
        f.deferred = !partial;
        await f.session.refresh();
        expect(presendPrivateState(f.session)['capturable'], false);
        expect(presendPrivateState(f.session)['consumedChanges'], false);
        if (partial)
          expect(
            presendPrivateState(f.session)['changesCursor'],
            'remaining-changes',
          );
      },
    );
  }
  test('null prepared revision is never coerced to zero', () async {
    final f = await fixture(revision: 0);
    expect(presendPrivateProof(f.session, 'prepared revision'), false);
  });
  for (final revision in [0, 100]) {
    test(
      'consumed witness succeeds once at canonical head $revision',
      () async {
        final f = await fixture(revision: revision);
        expect(f.session.document!.revision, revision == 0 ? null : revision);
        expect(presendPrivateProof(f.session, 'none'), true);
      },
    );
  }
  for (final mutation in [...captureFailures, ...staleFailures]) {
    test('one-use predicate rejects $mutation', () async {
      final f = await fixture();
      expect(presendPrivateProof(f.session, mutation), false);
    });
  }
  for (final mutation in captureFailures) {
    test('capture rejects $mutation', () async {
      final f = await fixture();
      expect(presendPrivateProof(f.session, mutation, atCapture: true), false);
    });
  }
}
