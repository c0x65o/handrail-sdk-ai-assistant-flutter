import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';

class Fixture {
  final metadata = <String, String>{}, blobs = <String, List<int>>{};
  int blobReads = 0, blobWrites = 0;
  Future<void> Function(String, String)? beforeWrite, afterWrite;
  Future<void> Function(String)? beforeDeleteBlob;
  bool failBlobWrite = false;
  HandrailKeyValueAttachmentDraftStore store([String scope = 'account:api']) =>
      HandrailKeyValueAttachmentDraftStore(
          namespace: scope,
          read: (key) async => metadata[key],
          write: (key, value) async {
            await beforeWrite?.call(key, value);
            metadata[key] = value;
            await afterWrite?.call(key, value);
          },
          delete: (key) async {
            metadata.remove(key);
          },
          readBytes: (key) async {
            blobReads++;
            return blobs[key];
          },
          writeBytes: (key, value) async {
            blobWrites++;
            blobs[key] = List.of(value);
            if (failBlobWrite) throw StateError('Lost binary acknowledgement');
          },
          deleteBytes: (key) async {
            await beforeDeleteBlob?.call(key);
            blobs.remove(key);
          });
}

Map<String, Object?> file(String id, [List<int>? bytes]) => {
      'id': id,
      'filename': '$id.png',
      'mediaType': 'image/png',
      'byteSize': bytes?.length ?? 3,
      'bytes': bytes ?? [1, 2, 3],
    };
List<Map<String, Object?>> files(Map<String, Object?>? row) =>
    (row?['files'] as List? ?? []).cast<Map<String, Object?>>();
String? version(Map<String, Object?>? row) => row?['version'] as String?;
Map<String, Object?> ready(Map<String, Object?> file) => {
      ...file,
      'reference': {
        'attachment_id': 'att_${file['id']}',
        'content_ref': 'ref_${file['id']}',
        'media_type': file['mediaType'],
        'byte_size': file['byteSize'],
        'filename': file['filename']
      }
    };

void main() {
  test(
      'persists immutable source once and restores only the selected account/chat',
      () async {
    final f = Fixture(), store = f.store();
    final original =
        await store.writeAttachmentDraft('one', [file('selected')], null);
    expect(files(original).single.containsKey('bytes'), false);
    expect(f.blobWrites, 1);
    expect(f.blobReads, 0);
    final saved = await store.writeAttachmentDraft(
        'one', [ready(files(original).single)], version(original));
    expect(f.blobWrites, 1);
    expect(f.blobReads, 0);
    await store.writeAttachmentDraft('two', [file('other')], null);
    expect(await f.store('other-account').readAttachmentDraft('one'), isNull);
    final restored = await f.store().readAttachmentDraft('one');
    expect(f.blobReads, 1);
    expect(version(restored), version(saved));
    expect(files(restored).single['bytes'], [1, 2, 3]);
    expect(
        files(restored).single['reference'], files(saved).single['reference']);
    expect(() => (files(restored).single['bytes'] as List<int>)[0] = 0,
        throwsUnsupportedError);
  });

  test(
      'captures new caller bytes before the first asynchronous storage operation',
      () async {
    final f = Fixture(),
        entered = Completer<void>(),
        release = Completer<void>();
    f.beforeWrite = (_, __) async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final source = Uint8List.fromList([1, 2, 3]);
    final saving =
        f.store().writeAttachmentDraft('one', [file('selected', source)], null);
    await entered.future;
    source[0] = 9;
    release.complete();
    await saving;
    expect(files(await f.store().readAttachmentDraft('one')).single['bytes'],
        [1, 2, 3]);
  });

  test(
      'binary acknowledgement loss retains old rows and journals staged-source cleanup',
      () async {
    final f = Fixture(), store = f.store();
    final old = await store.writeAttachmentDraft('one', [file('old')], null);
    f.failBlobWrite = true;
    await expectLater(
        store.writeAttachmentDraft(
            'one', [...files(old), file('new')], version(old)),
        throwsStateError);
    expect(f.blobs,
        hasLength(2)); // The failed write may still have reached storage.
    f.failBlobWrite = false;
    final restored = await f.store().readAttachmentDraft('one');
    expect(version(restored), version(old));
    expect(files(restored).single['id'], 'old');
    expect(f.blobs, hasLength(1));
  });

  for (final afterCommit in [false, true]) {
    test(
        'uncertain manifest commit recovers authoritative state: landed=$afterCommit',
        () async {
      final f = Fixture(), store = f.store();
      final old = await store.writeAttachmentDraft('one', [file('old')], null);
      Future<void> failCommit(String key, String json) async {
        if (!key.endsWith('.manifest')) return;
        final rows = (jsonDecode(json) as Map)['rows'] as Map;
        if (((rows['one'] as Map?)?['files'] as List? ?? [])
            .any((f) => (f as Map)['id'] == 'new')) {
          throw StateError('Commit acknowledgement lost');
        }
      }

      if (afterCommit)
        f.afterWrite = failCommit;
      else
        f.beforeWrite = failCommit;
      await expectLater(
          store.writeAttachmentDraft('one', [file('new')], version(old)),
          throwsStateError);
      f.afterWrite = f.beforeWrite = null;
      final recovered = await f.store().readAttachmentDraft('one');
      expect(files(recovered).single['id'], afterCommit ? 'new' : 'old');
      expect(f.blobs, hasLength(1));
      if (afterCommit) {
        await expectLater(
            store.writeAttachmentDraft('one', [file('other')], version(old)),
            throwsA(isA<HandrailGatewayException>()
                .having((e) => e.code, 'code', 'attachment_draft_conflict')));
      }
    });
  }

  test(
      'cleanup failure remains durable and retry never hydrates deleted sources',
      () async {
    final f = Fixture(), store = f.store();
    final old = await store.writeAttachmentDraft(
        'one', [file('old'), file('newer')], null);
    f.beforeDeleteBlob =
        (_) async => throw StateError('Disk temporarily unavailable');
    await expectLater(
        store.discardAcceptedFiles('one', ['old']), throwsStateError);
    expect(f.blobReads, 0);
    expect(f.blobs, hasLength(2));
    f.beforeDeleteBlob = null;
    final repeated = await f.store().discardAcceptedFiles('one', ['old']);
    expect(repeated['version'], isNot(version(old)));
    expect(f.blobReads, 0);
    expect(f.blobs, hasLength(1));
    expect(files(await store.readAttachmentDraft('one')).single['id'], 'newer');
  });

  test(
      'separate same-scope writers conflict and exact cleanup preserves other scopes',
      () async {
    final f = Fixture();
    final first = await f
        .store()
        .writeAttachmentDraft('one', [file('sent'), file('new')], null);
    await f.store('other').writeAttachmentDraft('one', [file('sent')], null);
    final a = f.store().writeAttachmentDraft(
        'one', [ready(files(first).first), files(first).last], version(first));
    final b = expectLater(
        f.store().writeAttachmentDraft('one', [], version(first)),
        throwsA(isA<HandrailGatewayException>()));
    await a;
    await b;
    final result = await f.store().discardAcceptedFiles('one', ['sent']);
    expect(result['version'], isNotNull);
    expect(f.blobReads, 0);
    expect(
        files(await f.store().readAttachmentDraft('one')).single['id'], 'new');
    expect(
        files(await f.store('other').readAttachmentDraft('one')).single['id'],
        'sent');
  });

  test(
      'confirmed deletion fences old writers even when source cleanup initially fails',
      () async {
    final f = Fixture(), stale = f.store();
    final original =
        await stale.writeAttachmentDraft('one', [file('saved')], null);
    f.beforeDeleteBlob = (_) async => throw StateError('Device offline');
    await expectLater(f.store().eraseConversation('one'), throwsStateError);
    f.beforeDeleteBlob = null;
    await f.store().eraseConversation('one');
    expect(await stale.readAttachmentDraft('one'), isNull);
    expect(f.blobs, isEmpty);
    await expectLater(stale.writeAttachmentDraft('one', files(original), null),
        throwsStateError);
    expect(f.blobs, isEmpty);
  });

  test('caps files and conversations without reading bodies or evicting work',
      () async {
    final f = Fixture(), store = f.store();
    final saved = await store.writeAttachmentDraft(
        'one', List.generate(64, (i) => file('file-$i', [1])), null);
    await expectLater(
        store.writeAttachmentDraft(
            'two',
            [
              file('extra', [1])
            ],
            null),
        throwsA(isA<HandrailGatewayException>()));
    expect(f.blobReads, 0);
    expect(f.blobWrites, 64);
    expect(files(saved), hasLength(64));
    final g = Fixture();
    for (var i = 0; i < 32; i++) {
      await g.store().writeAttachmentDraft(
          'chat-$i',
          [
            file('file', [1])
          ],
          null);
    }
    await expectLater(
        g.store().writeAttachmentDraft(
            'overflow',
            [
              file('file', [1])
            ],
            null),
        throwsA(isA<HandrailGatewayException>()));
    expect(g.blobs, hasLength(32));
    expect(g.blobReads, 0);
  });

  test('checks source integrity and refuses cleanup keys outside the account',
      () async {
    final f = Fixture(), store = f.store();
    await store.writeAttachmentDraft('one', [file('saved')], null);
    f.blobs[f.blobs.keys.single] = [9, 9, 9];
    await expectLater(store.readAttachmentDraft('one'), throwsFormatException);
    final key = f.metadata.keys.single,
        manifest = jsonDecode(f.metadata.values.single) as Map;
    manifest['garbage'] = [
      {'key': 'another-account.blob', 'bytes': 3}
    ];
    f.metadata[key] = jsonEncode(manifest);
    await expectLater(
        store.discardAcceptedFiles('one', ['saved']), throwsFormatException);
    expect(f.blobs, hasLength(1));
  });

  test(
      'key-value fallback persists separated bytes with identical cleanup semantics',
      () async {
    final data = <String, String>{};
    HandrailKeyValueAttachmentDraftStore store() =>
        HandrailKeyValueAttachmentDraftStore(
            namespace: 'native-encrypted-kv',
            read: (key) async => data[key],
            write: (key, value) async {
              data[key] = value;
            },
            delete: (key) async {
              data.remove(key);
            });
    await store().writeAttachmentDraft('one', [file('saved')], null);
    expect(data, hasLength(2));
    expect(files(await store().readAttachmentDraft('one')).single['bytes'],
        [1, 2, 3]);
    await store().discardAcceptedFiles('one', ['saved']);
    expect(data, hasLength(1));
    expect(await store().readAttachmentDraft('one'), isNull);
  });
}
