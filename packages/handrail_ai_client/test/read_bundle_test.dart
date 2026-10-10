import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'display_session_test.dart' as existing;

// HTTP boundary fixture; all response validation/window merging is real SDK code.
class BundleFixture extends existing.Fixture {
  final dispatches = <String>[];
  void Function(List<Map<String, Object?>>)? transform;
  Future<void>? holdBundle;
  int? fail;
  bool deriveContext = false, wrongContext = false;
  @override
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/capabilities')) {
      final response = await super.handle(request);
      final json = jsonDecode(response.body) as Map;
      (json['value']['displayHistory'] as Map)['readBundle'] = true;
      return http.Response(jsonEncode(json), 200);
    }
    final body = jsonDecode(request.body) as Map;
    dispatches.add(body['operation'] as String? ?? request.url.path);
    if (body['operation'] != 'bundle') return super.handle(request);
    if (fail != null)
      return http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': fail == 401
                  ? 'unauthenticated'
                  : fail == 403
                      ? 'forbidden'
                      : fail == 429
                          ? 'rate_limited'
                          : 'unavailable',
              'retryable': fail! >= 429,
              'message': 'Synthetic failure',
            }
          }),
          fail!,
          headers: {if (fail == 429) 'retry-after': '1'});
    final results = <Map<String, Object?>>[];
    for (final read in body['input']['reads'] as List) {
      final child = http.Request('POST', request.url)..body = jsonEncode(read);
      final response = await super.handle(child);
      if (response.statusCode != 200) return response;
      results.add(
          Map<String, Object?>.from(jsonDecode(response.body)['value'] as Map));
    }
    transform?.call(results);
    await holdBundle;
    Map<String, Object?>? related;
    if (deriveContext && body['input']['contextFromPage'] == 1) {
      final page = results[1];
      final input = {
        'conversationId': 'chat',
        'limit': 30,
        'maximumBytes': 65536,
        'view': {
          'type': 'context',
          'messageIds': (page['records'] as List)
              .map((r) => r['id'])
              .toList()
              .reversed
              .toList()
        }
      };
      final response = await super.handle(http.Request('POST', request.url)
        ..body = jsonEncode({'operation': 'page', 'input': input}));
      related = {
        'input': {
          ...input,
          if (wrongContext) 'conversationId': 'another-account'
        },
        'value': jsonDecode(response.body)['value']
      };
    }
    return existing
        .ok({'results': results, if (related != null) 'related': related});
  }
}

void main() {
  BundleFixture fixture() {
    final f = BundleFixture();
    addTearDown(() async {
      await f.session.dispose();
      f.client.close();
    });
    return f;
  }

  test(
      'fresh complete refresh bundles control/changes/context; explicit reads remain fresh',
      () async {
    final f = fixture();
    await f.session.initialize();
    expect(f.dispatches,
        ['bundle', 'page']); // context IDs depend on initial messages
    f.dispatches.clear();
    await f.session.refresh();
    expect(f.dispatches, ['bundle']);
    expect(f.session.document!.messages, hasLength(30));
    await f.session.displayWindow!.refresh();
    expect(f.dispatches, ['bundle', 'changes']);
  });
  test('revision or generation races discard the envelope and read normally',
      () async {
    final f = fixture();
    await f.session.initialize();
    for (final generation in [false, true]) {
      f.dispatches.clear();
      f.transform = (values) {
        if (generation) f.generation++;
        f.revision++;
        values.last['revision'] = f.revision;
      };
      await f.session.refresh();
      expect(f.dispatches.first, 'bundle');
      expect(f.dispatches, contains('control'));
      expect(f.session.document!.revision, f.revision);
    }
  });
  test(
      'partial and deferred context keeps its continuation; no full-coverage shortcut',
      () async {
    final f = fixture();
    f.relatedCursor = 'more';
    f.related = [
      {
        'kind': 'tool',
        'id': 'large',
        'turnId': null,
        'revision': 100,
        'bytes': 100000,
        'deferred': true,
        'value': null
      }
    ];
    await f.session.initialize();
    await f.session.refresh();
    expect(f.session.hasMoreRelated, isTrue);
    expect(f.session.document!.state['deferred_records'], isNotEmpty);
    f.dispatches.clear();
    await f.session.loadMoreRelated();
    expect(f.dispatches, ['page']);
  });
  for (final status in [401, 403, 429, 500]) {
    test('bundle $status is not successful coverage and retry reaches HTTP',
        () async {
      final f = fixture();
      await f.session.initialize();
      f.fail = status;
      await expectLater(f.session.refresh(), throwsA(anything));
      if (status == 401 || status == 403) expect(f.session.document, isNull);
      f.fail = null;
      // 429 retry belongs to existing Retry-After tests; do not wait out a budget here.
      if (status != 429) {
        f.dispatches.clear();
        await f.session.refresh();
        expect(f.dispatches.first, 'bundle');
        expect(f.session.document, isNotNull);
      }
    });
  }
  test(
      'disposal while bundle is in flight cannot publish or leak to a replacement account',
      () async {
    final old = fixture();
    await old.session.initialize();
    final gate = Completer<void>();
    old.holdBundle = gate.future;
    final refresh = old.session.refresh();
    await Future<void>.delayed(Duration.zero);
    await old.session.dispose();
    final replacement = fixture();
    replacement.messagePrefix = 'other-account';
    await replacement.session.initialize();
    gate.complete();
    await refresh;
    expect(old.session.document, isNull);
    expect(replacement.session.document!.messages.first['message_id'],
        startsWith('other-account'));
  });
  test(
      'concurrent exact-turn observers coalesce and display notifications do not amplify controls',
      () async {
    final f = fixture();
    f.turn('observed', 'running');
    await f.session.initialize();
    f.requests.clear();
    final one = f.session.waitForTurn('observed');
    final two = f.session.waitForTurn('observed');
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 70; i++) {
      await f.session.displayWindow!.refresh();
    }
    expect(
        f.requests.where((r) =>
            r['operation'] == 'control' &&
            (r['input'] as Map)['turnId'] == 'observed'),
        hasLength(1));
    f.turn('observed', 'completed');
    await f.session.refresh();
    expect((await one)['status'], 'completed');
    expect((await two)['status'], 'completed');
  });

  test(
      'initial context is derived from its bundled messages and cannot forge coverage',
      () async {
    final f = fixture()..deriveContext = true;
    await f.session.initialize();
    expect(f.dispatches, ['bundle']);
    expect(f.session.document!.messages, hasLength(30));
    final forged = fixture()
      ..deriveContext = true
      ..wrongContext = true;
    await expectLater(forged.session.initialize(), throwsA(anything));
    expect(forged.session.document, isNull);
  });
  test('navigation while a bundle is in flight invalidates its intent witness',
      () async {
    final f = fixture();
    await f.session.initialize();
    final gate = Completer<void>();
    f.holdBundle = gate.future;
    f.dispatches.clear();
    final refresh = f.session.refresh();
    await Future<void>.delayed(Duration.zero);
    await f.session.displayWindow!.loadOlder();
    expect(f.session.displayWindow!.state.records, hasLength(60));
    gate.complete();
    await refresh;
    expect(f.dispatches, contains('control'));
    expect(f.session.document!.messages, hasLength(60));
    expect(f.session.displayWindow!.followingLatest, isFalse);
  });
  test('denied exact-turn observation evicts the authorized display', () async {
    final f = fixture()..turn('observed', 'running');
    await f.session.initialize();
    f.denied = true;
    await expectLater(f.session.waitForTurn('observed'), throwsA(anything));
    expect(f.session.document, isNull);
    expect(f.session.displayWindow!.state.records, isEmpty);
  });
}
