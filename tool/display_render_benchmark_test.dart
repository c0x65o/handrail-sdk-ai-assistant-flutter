// Run with check-consumer-contract.mjs --test and an existing consumer package
// map containing both SDK packages. This qualifies local source, not an install.
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Only the test process's own loopback VM service; never prints its private URI.
class _LocalVmHttp extends HttpOverrides {}

Future<Map<String, Object?>> memorySample() async {
  final service = await developer.Service.getInfo();
  final base = service.serverUri;
  if (base == null || !['127.0.0.1', 'localhost', '::1'].contains(base.host)) {
    throw StateError('Run this benchmark with HANDRAIL_TEST_VM_SERVICE=1');
  }
  return HttpOverrides.runWithHttpOverrides(() async {
    final client = HttpClient();
    try {
      final uri = base
          .resolve('getAllocationProfile')
          .replace(
            queryParameters: {
              'isolateId': developer.Service.getIsolateId(Isolate.current)!,
              'gc': 'true',
            },
          );
      final response = await (await client.getUrl(uri)).close();
      final data =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      if (data['error'] != null)
        throw StateError('Local VM memory sampling failed');
      final result = data['result'] as Map;
      final classes = (result['members'] as List).cast<Map>().toList()
        ..sort(
          (a, b) =>
              (b['bytesCurrent'] as int).compareTo(a['bytesCurrent'] as int),
        );
      return {
        'rssBytes': ProcessInfo.currentRss,
        'memoryUsage': result['memoryUsage'],
        'largestClasses': classes
            .take(8)
            .map(
              (entry) => {
                'class': (entry['class'] as Map)['name'],
                'bytes': entry['bytesCurrent'],
                'instances': entry['instancesCurrent'],
              },
            )
            .toList(),
      };
    } finally {
      client.close(force: true);
    }
  }, _LocalVmHttp());
}

class Fixture {
  Fixture(this.messages);
  final int messages;
  final requests = <Map<String, Object?>>[];
  final storage = <String, String>{};
  late final pending = HandrailKeyValuePendingTurnStore(
    namespace: 'synthetic-$messages',
    read: (key) async => storage[key],
    write: (key, value) async {
      storage[key] = value;
    },
    delete: (key) async {
      storage.remove(key);
    },
  );
  late final client = HandrailAiClient(
    baseUri: Uri.parse('https://fixture.invalid/assistant'),
    httpClient: MockClient(handle),
  );
  late final controller = HandrailAssistantController(
    client: client,
    pendingStore: pending,
    pageSize: 5,
    pollingInterval: null,
    autoCreate: false,
  );
  Map<String, Object?> descriptor(int index) => {
    'conversationId': 'chat-$messages-$index',
    'title': 'Chat $index',
    'lifecycle': 'active',
    'version': 1,
    'createdAt': '2026-09-01T00:00:00Z',
    'updatedAt': '2026-09-01T00:00:00Z',
    'metadata': <String, Object?>{},
  };
  Map<String, Object?> record(int index, String conversation) => {
    'kind': 'message',
    'id': 'message-$index',
    'turnId': null,
    'revision': index * 100,
    'bytes': 600,
    'deferred': false,
    'value': {
      'message_id': 'message-$index',
      'role': index.isEven ? 'assistant' : 'user',
      'attachments': [],
      'content': [
        {
          'type': 'text',
          'text':
              '$conversation: message $index\n\n**Formatted answer** and [safe link](https://example.invalid/reference).\n\n'
              '```dart\nfinal answer = 42;\n```\n\n${'Variable height message content. ' * (index % 4 + 1)}',
        },
      ],
    },
  };
  Future<http.Response> handle(http.Request request) async {
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(request.body) as Map;
    final input = body['input'] as Map? ?? body;
    Object? value;
    final path = request.url.path;
    if (path.endsWith('/capabilities')) {
      value = {
        'protocolVersion': applicationGatewayProtocolVersion,
        'synchronization': true,
        'activity': false,
        'authoritativeCancellation': false,
        'displayHistory': {
          'version': 1,
          'control': true,
          'maximumPageSize': 50,
          'maximumPageBytes': 262144,
        },
        'resources': {'titleGeneration': false},
      };
    } else if (path.endsWith('/conversations/list')) {
      expect(
        input['cursor'],
        isNull,
        reason: 'No automatic catalog page traversal',
      );
      value = {
        'items': [for (var i = 0; i < 5; i++) descriptor(i)],
        'hasMore': true,
        'nextCursor': 'more',
        'order': body['order'],
      };
    } else if (path.endsWith('/conversations/get')) {
      value = {
        'descriptor': descriptor(
          int.parse((input['conversationId'] as String).split('-').last),
        ),
      };
    } else if (path.endsWith('/conversations/history')) {
      final id = input['conversationId'] as String;
      final header = <String, Object?>{
        'schemaVersion': 1,
        'status': 'ready',
        'conversationId': id,
        'generation': 0,
        'revision': messages * 100,
        'canonicalRevision': messages * 100,
        'activeTurnId': null,
      };
      if (body['operation'] == 'control') {
        value = {
          ...header,
          'activeTurn': null,
          'latestTurn': null,
          'requestedTurn': null,
        };
      } else if (body['operation'] == 'changes') {
        value = {
          ...header,
          'records': [],
          'nextCursor': null,
          'throughRevision': messages * 100,
        };
      } else if (body['operation'] == 'page') {
        if (input['view'] != null) {
          value = {...header, 'records': [], 'nextCursor': null};
        } else {
          final anchor = input['anchor'] as Map?;
          final edge = anchor == null
              ? messages + 1
              : int.parse((anchor['messageId'] as String).split('-').last);
          final newer = anchor?['direction'] == 'newer',
              limit = input['limit'] as int;
          final start = newer
              ? edge + (anchor?['inclusive'] == true ? 0 : 1)
              : (edge - limit).clamp(1, messages);
          final end = newer ? (start + limit - 1).clamp(1, messages) : edge - 1;
          value = {
            ...header,
            'records': [for (var i = start; i <= end; i++) record(i, id)],
            'nextCursor': (newer ? end < messages : start > 1) ? 'more' : null,
          };
        }
      } else {
        throw StateError('Unexpected history operation');
      }
    } else {
      throw StateError('Unexpected full-history endpoint: $path');
    }
    final json = jsonEncode({'ok': true, 'value': value});
    requests.add({
      'path': path,
      'operation': body['operation'],
      'view': input['view'],
      'bytes': utf8.encode(json).length,
    });
    return http.Response(
      json,
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<void> dispose() async {
    await controller.dispose();
    client.close();
  }
}

void main() {
  testWidgets('bounded standard Flutter controller and transcript render benchmark', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reports = <Map<String, Object?>>[];
    for (final messages in [200, 1000]) {
      final fixture = Fixture(messages), controller = fixture.controller;
      final rssBefore = ProcessInfo.currentRss;
      try {
        await tester.runAsync(controller.initialize);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HandrailConversationTranscript(
                binding: controller.transcriptBinding,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final initialMemory = await tester.runAsync(memorySample);
        expect(controller.document!.messages.length, 30);
        expect(
          fixture.requests.where(
            (r) => (r['path'] as String).endsWith('/conversations/list'),
          ),
          hasLength(1),
        );
        expect(
          fixture.requests.where(
            (r) => r['operation'] == 'page' && r['view'] == null,
          ),
          hasLength(1),
        );
        final samples = <double>[];
        for (var i = 1; i <= 12; i++) {
          final watch = Stopwatch()..start();
          await tester.runAsync(
            () => controller.openConversation('chat-$messages-$i'),
          );
          await tester.pumpAndSettle();
          watch.stop();
          samples.add(watch.elapsedMicroseconds / 1000);
          expect(controller.document!.messages.length, 30);
          expect(
            find.byType(HandrailTranscriptMessage).evaluate().length,
            inInclusiveRange(1, 30),
          );
          expect(
            controller.workspace.snapshot.conversations.length,
            lessThanOrEqualTo(4),
          );
          for (final thread in controller.workspace.snapshot.conversations) {
            if (thread.state.conversationId != controller.selectedId) {
              expect(
                controller
                        .sessionFor(thread.state.conversationId)
                        ?.document
                        ?.messages ??
                    [],
                isEmpty,
              );
            }
          }
        }
        // Leave follow mode as a reader does before requesting older pages.
        final scroll = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
            .controller!;
        scroll.jumpTo(240);
        await tester.pumpAndSettle();
        for (var page = 0; page < 4; page++) {
          await tester.runAsync(
            () => controller.session!.displayWindow!.loadOlder(),
          );
          await tester.pumpAndSettle();
          expect(controller.document!.messages.length, lessThanOrEqualTo(90));
          expect(
            find.byType(HandrailTranscriptMessage).evaluate().length,
            lessThanOrEqualTo(90),
          );
        }
        expect(controller.document!.messages.length, 90);
        expect(
          find.byType(HandrailTranscriptMessage).evaluate().length,
          lessThan(20),
        );
        final retainedMemory = (await tester.runAsync(memorySample))!;
        final rssAfter = ProcessInfo.currentRss;
        final wireBytes = fixture.requests
            .map((r) => r['bytes'] as int)
            .reduce((a, b) => a > b ? a : b);
        samples.sort();
        expect(
          samples.last,
          lessThan(1000),
          reason: 'Local offscreen selection smoke budget',
        );
        expect(
          rssAfter - (initialMemory!['rssBytes'] as int),
          lessThan(128 * 1024 * 1024),
          reason: 'Bounded fixture RSS growth',
        );
        expect(
          ((retainedMemory['memoryUsage'] as Map)['heapUsage'] as int) -
              ((initialMemory['memoryUsage'] as Map)['heapUsage'] as int),
          lessThan(96 * 1024 * 1024),
          reason: 'Warm isolate heap growth after requested GC',
        );
        expect(wireBytes, lessThanOrEqualTo(65536));
        expect(
          fixture.requests.where(
            (r) => (r['path'] as String).endsWith('/conversations/list'),
          ),
          hasLength(1),
        );
        reports.add({
          'sourceMessages': messages,
          'equivalentStreamingEvents': messages * 100,
          'samples': samples.length,
          'selectionAndPumpP50Ms': samples[5],
          'selectionAndPumpP95Ms': samples.last,
          'retainedMessagesAfterScrolling':
              controller.document!.messages.length,
          'mountedMessageWidgets': find
              .byType(HandrailTranscriptMessage)
              .evaluate()
              .length,
          'cachedSessions': controller.workspace.snapshot.conversations.length,
          'initialMemoryAfterGc': initialMemory,
          'retainedMemoryAfterGc': retainedMemory,
          'maximumSerializedResponseBytes': wireBytes,
          'processRssBeforeBytes': rssBefore,
          'processRssAfterBytes': rssAfter,
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
      }
    }
    final report = {
      'engine': 'Flutter test offscreen renderer',
      'viewport': {'width': 390, 'height': 844},
      'metrics': reports,
      'budgets': {
        'selectionAndPumpMaximumMs': 1000,
        'processRssGrowthBytes': 128 * 1024 * 1024,
        'warmIsolateHeapGrowthBytes': 96 * 1024 * 1024,
        'maximumSerializedResponseBytes': 65536,
        'retainedMessages': 90,
        'cachedSessions': 4,
      },
      'limitations': [
        'Mock HTTP transport, actual SDK account controller/window and standard transcript widgets.',
        'Stopwatch measures host selection plus offscreen pumps; this is not native-device frame timing or production latency.',
        'Process RSS includes the Dart VM, Flutter engine and test harness; warm growth is reported separately from cold startup. VM allocation profiles request GC and report isolate heap separately.',
        'No provider, upload, voice, or production account data is used.',
      ],
    };
    print('HANDRAIL_FLUTTER_DISPLAY_BENCHMARK ${jsonEncode(report)}');
    final output = Platform.environment['HANDRAIL_FLUTTER_DISPLAY_REPORT'];
    if (output != null)
      await tester.runAsync(
        () => File(output).writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        ),
      );
  });
}
