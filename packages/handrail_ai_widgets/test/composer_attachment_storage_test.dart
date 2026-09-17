import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

HandrailAttachmentFile file(String name) => HandrailAttachmentFile(
  fileName: name,
  mediaType: 'text/plain',
  bytes: [1, 2, 3],
);
final limits = HandrailAttachmentLimits(
  acceptedMediaTypes: ['text/plain'],
  maximumFiles: 10,
  maximumBytesPerFile: 100,
  maximumTotalBytes: 1000,
);

// Structural host boundary: client store crash/hash/GC behavior has separate
// tests. This fixture exposes hydration, CAS, callback and write-order races.
class Files {
  final rows = <String, Map<String, Object?>>{};
  final reads = <String>[];
  final sources = <String, List<int>>{};
  int revision = 0, binaryWrites = 0, binaryReads = 0, metadataWrites = 0;
  Future<void> Function(String)? beforeRead;
  Future<void> Function(List<Map<String, Object?>>)? beforeWrite;
  Future<void> Function()? beforeDiscard;
  bool failAfterWrite = false;
  HandrailAttachmentDraftBinding get binding => (
    read: (id) async {
      reads.add(id);
      await beforeRead?.call(id);
      final row = rows[id];
      if (row == null) return null;
      return {
        'version': row['version'],
        'files': [
          for (final raw in row['files'] as List)
            {
              ...raw as Map<String, Object?>,
              'bytes': _read(raw['id'] as String),
            },
        ],
      };
    },
    write: (id, input, version) async {
      metadataWrites++;
      await beforeWrite?.call(input);
      if (rows[id]?['version'] != version)
        throw StateError('revision conflict');
      final metadata = <Map<String, Object?>>[];
      for (final value in input) {
        final key = value['id'] as String;
        if (value['bytes'] case final List<int> bytes) {
          binaryWrites++;
          sources[key] = List.of(bytes);
        }
        if (!sources.containsKey(key)) throw StateError('missing source');
        metadata.add({...value, 'sha256': '0' * 64}..remove('bytes'));
      }
      final old = rows[id]?['files'] as List? ?? [];
      final ids = metadata.map((v) => v['id']).toSet();
      for (final v in old) {
        if (!ids.contains(v['id'])) sources.remove(v['id']);
      }
      final result = metadata.isEmpty
          ? null
          : <String, Object?>{'version': 'v${++revision}', 'files': metadata};
      if (result == null) {
        rows.remove(id);
      } else {
        rows[id] = result;
      }
      if (failAfterWrite) throw StateError('lost write acknowledgement');
      return result;
    },
    discardAccepted: (id, accepted) async {
      await beforeDiscard?.call();
      final old = rows[id], before = old?['version'];
      final input = old?['files'] as List? ?? [];
      final next = input.where((v) => !accepted.contains(v['id'])).toList();
      for (final key in accepted) {
        sources.remove(key);
      }
      if (next.length != input.length) {
        if (next.isEmpty) {
          rows.remove(id);
        } else {
          rows[id] = {'version': 'v${++revision}', 'files': next};
        }
      }
      return {'previousVersion': before, 'version': rows[id]?['version']};
    },
  );
  List<int> _read(String key) {
    binaryReads++;
    return List.of(sources[key]!);
  }
}

HandrailComposerController owner(
  Files storage, {
  HandrailAttachmentUploader? upload,
  int maximumRetainedAttachments = 64,
}) => HandrailComposerController(
  attachmentStorage: storage.binding,
  maximumRetainedAttachments: maximumRetainedAttachments,
  limitsForConversation: (_) => limits,
  uploaderForConversation: (_) =>
      upload ??
      ({
        required bytes,
        required filename,
        required mediaType,
        required idempotencyKey,
        required cancellation,
      }) async => (
        reference: <String, Object?>{
          'attachment_id': idempotencyKey,
          'content_ref': 'ref-$idempotencyKey',
          'filename': filename,
          'media_type': mediaType,
          'byte_size': bytes.length,
        },
        errorCode: null,
        retryable: false,
      ),
);
Future<void> open(HandrailComposerController drafts, String id) async {
  drafts.select(id);
  await drafts.flushAttachmentDraft();
}

Future<void> close(HandrailComposerController drafts) async {
  drafts.dispose();
  await drafts.closed;
}

void main() {
  test(
    'Stop while saving a ready reference blocks send and reuses the saved reference',
    () async {
      final storage = Files();
      var uploads = 0;
      final drafts = owner(
        storage,
        upload:
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              uploads++;
              return (
                reference: <String, Object?>{
                  'attachment_id': 'a',
                  'content_ref': 'r',
                  'media_type': mediaType,
                  'byte_size': bytes.length,
                },
                errorCode: null,
                retryable: false,
              );
            },
      );
      await open(drafts, 'one');
      drafts.addPickedAttachments([file('one')]);
      await drafts.flushAttachmentDraft();
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeWrite = (input) async {
        if (input.single['reference'] != null && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final upload = drafts.prepareAttachments(drafts.attachments);
      final stopped = expectLater(
        upload,
        throwsA(isA<HandrailAttachmentException>()),
      );
      await entered.future;
      drafts.cancelUploads();
      release.complete();
      await stopped;
      expect(uploads, 1);
      await drafts.prepareAttachments(drafts.attachments);
      expect(uploads, 1);
      expect(storage.binaryWrites, 1);
      await close(drafts);
    },
  );

  test(
    'Stop during a pending source save prevents network upload and keeps retry identity',
    () async {
      final storage = Files();
      var uploads = 0;
      final drafts = owner(
        storage,
        upload:
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              uploads++;
              return (
                reference: <String, Object?>{
                  'attachment_id': 'a',
                  'content_ref': 'r',
                  'media_type': mediaType,
                  'byte_size': bytes.length,
                },
                errorCode: null,
                retryable: false,
              );
            },
      );
      await open(drafts, 'one');
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeWrite = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      drafts.addPickedAttachments([file('one')]);
      final uploading = drafts.prepareAttachments(drafts.attachments);
      final stopped = expectLater(
        uploading,
        throwsA(isA<HandrailAttachmentException>()),
      );
      await entered.future;
      drafts.cancelUploads();
      release.complete();
      await stopped;
      expect(uploads, 0);
      expect(drafts.attachments, hasLength(1));
      await drafts.prepareAttachments(drafts.attachments);
      expect(uploads, 1);
      expect(storage.binaryWrites, 1);
      await close(drafts);
    },
  );

  test(
    'failed explicit reload retains local selections and retries replacement without duplication',
    () async {
      final storage = Files(), drafts = owner(storage);
      await open(drafts, 'one');
      drafts.addPickedAttachments([file('one')]);
      await drafts.flushAttachmentDraft();
      storage.beforeRead = (_) async => throw StateError('temporarily locked');
      await expectLater(drafts.reloadSavedAttachments(), throwsStateError);
      expect(drafts.attachments.single.fileName, 'one');
      expect(drafts.attachmentStorageError, isNotNull);
      storage.beforeRead = null;
      await drafts.flushAttachmentDraft();
      expect(drafts.attachments.single.fileName, 'one');
      expect(drafts.attachmentStorageError, isNull);
      expect(storage.binaryWrites, 1);
      await close(drafts);
    },
  );

  test(
    'closing during a source write waits; confirmed deletion does not schedule a replacement write',
    () async {
      final storage = Files(), drafts = owner(storage);
      await open(drafts, 'one');
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeWrite = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      drafts.addPickedAttachments([file('one')]);
      await entered.future;
      drafts.dispose();
      var closed = false;
      final closing = drafts.closed.then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await closing;
      expect(storage.rows['one'], isNotNull);
      final next = owner(storage);
      await open(next, 'one');
      var writes = 0;
      storage.beforeWrite = (_) async {
        writes++;
      };
      next.discard('one', permanentlyDeleted: true);
      await next.closed;
      expect(writes, 0);
      await close(next);
    },
  );

  test(
    'restart preserves upload identity; ready files never upload or write bytes again',
    () async {
      final storage = Files(), keys = <String>[];
      final first = owner(storage);
      await open(first, 'one');
      first.addPickedAttachments([file('a.txt')]);
      await first.flushAttachmentDraft();
      final savedId = (storage.rows['one']!['files'] as List).single['id'];
      await close(first);
      final second = owner(
        storage,
        upload:
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              keys.add(idempotencyKey);
              expect(storage.sources.containsKey(idempotencyKey), isTrue);
              return (
                reference: <String, Object?>{
                  'attachment_id': 'a',
                  'content_ref': 'r',
                  'media_type': mediaType,
                  'byte_size': bytes.length,
                },
                errorCode: null,
                retryable: false,
              );
            },
      );
      await open(second, 'one');
      final result = await second.prepareAttachments(second.attachments);
      expect(keys, [savedId]);
      expect(storage.binaryWrites, 1);
      expect(result.single['attachment_id'], 'a');
      await close(second);
      final third = owner(
        storage,
        upload:
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async => throw StateError('must not upload'),
      );
      await open(third, 'one');
      expect(
        third.attachmentSelections.single.status,
        HandrailAttachmentStatus.ready,
      );
      expect(await third.prepareAttachments(third.attachments), result);
      expect(storage.binaryWrites, 1);
      expect(storage.binaryReads, 2);
      expect(storage.metadataWrites, 2);
      await close(third);
    },
  );

  test(
    'restoration is selected-chat only and a late read cannot replace another chat',
    () async {
      final storage = Files();
      final seed = owner(storage);
      for (final id in ['one', 'two', 'unopened']) {
        await open(seed, id);
        seed.addPickedAttachments([file('$id.txt')]);
        await seed.flushAttachmentDraft();
      }
      await close(seed);
      storage.reads.clear();
      storage.binaryReads = 0;
      final release = Completer<void>();
      storage.beforeRead = (id) async {
        if (id == 'one') await release.future;
      };
      final drafts = owner(storage);
      drafts.select('one');
      expect(drafts.restoringAttachments, isTrue);
      expect(drafts.attachmentsEnabled, isFalse);
      expect(() => drafts.addAttachments([file('late.txt')]), throwsStateError);
      await open(drafts, 'two');
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(drafts.selectedId, 'two');
      expect(drafts.attachments.single.fileName, 'two.txt');
      expect(storage.reads, ['one', 'two']);
      expect(storage.binaryReads, 2);
      await open(drafts, 'one');
      expect(drafts.attachments.single.fileName, 'one.txt');
      await close(drafts);
      expect(storage.reads, ['one', 'two']);
    },
  );

  test(
    'background accepted cleanup reads no sources and preserves newer files',
    () async {
      final storage = Files(), seed = owner(storage);
      await open(seed, 'one');
      seed.addPickedAttachments([file('old'), file('new')]);
      await seed.flushAttachmentDraft();
      final ids = (storage.rows['one']!['files'] as List)
          .map((v) => v['id'])
          .toList();
      await close(seed);
      storage.reads.clear();
      storage.binaryReads = 0;
      final drafts = owner(storage);
      await open(drafts, 'visible');
      await drafts.reconcileAcceptedDraft('one', {
        'version': 1,
        'fileIds': [ids.first],
      });
      await Future<void>.delayed(Duration.zero);
      await drafts.flushDrafts();
      expect(storage.reads, ['visible']);
      expect(storage.binaryReads, 0);
      expect(drafts.selectedId, 'visible');
      await open(drafts, 'one');
      expect(drafts.attachments.single.fileName, 'new');
      await close(drafts);
    },
  );

  test(
    'edits made while accepted cleanup waits are saved after the exact removal',
    () async {
      final storage = Files(), drafts = owner(storage);
      await open(drafts, 'one');
      drafts.addPickedAttachments([file('old')]);
      await drafts.flushAttachmentDraft();
      final id = (storage.rows['one']!['files'] as List).single['id'];
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeDiscard = () async {
        entered.complete();
        await release.future;
      };
      final cleanup = drafts.reconcileAcceptedDraft('one', {
        'version': 1,
        'fileIds': [id],
      });
      await entered.future;
      drafts.addPickedAttachments([file('new')]);
      release.complete();
      await cleanup;
      await drafts.flushAttachmentDraft();
      expect(drafts.attachments.single.fileName, 'new');
      expect((storage.rows['one']!['files'] as List).single['filename'], 'new');
      await close(drafts);
    },
  );

  test(
    'failed source save prevents upload and retry preserves identity',
    () async {
      final storage = Files();
      var uploads = 0;
      final drafts = owner(
        storage,
        upload:
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              uploads++;
              return (
                reference: <String, Object?>{
                  'attachment_id': 'a',
                  'content_ref': 'r',
                  'media_type': mediaType,
                  'byte_size': bytes.length,
                },
                errorCode: null,
                retryable: false,
              );
            },
      );
      await open(drafts, 'one');
      storage.beforeWrite = (_) async => throw StateError('device full');
      drafts.addPickedAttachments([file('a')]);
      await expectLater(drafts.flushAttachmentDraft(), throwsStateError);
      expect(drafts.attachmentStorageError, isNotNull);
      await expectLater(
        drafts.prepareAttachments(drafts.attachments),
        throwsStateError,
      );
      expect(uploads, 0);
      expect(drafts.attachments, hasLength(1));
      storage.beforeWrite = null;
      await drafts.flushAttachmentDraft();
      await drafts.prepareAttachments(drafts.attachments);
      expect(uploads, 1);
      expect(storage.binaryWrites, 1);
      await close(drafts);
    },
  );

  test(
    'uncertain committed save and competing editors require explicit reload',
    () async {
      final storage = Files(), first = owner(storage), second = owner(storage);
      await open(first, 'one');
      await open(second, 'one');
      storage.failAfterWrite = true;
      first.addPickedAttachments([file('first')]);
      await expectLater(first.flushAttachmentDraft(), throwsStateError);
      storage.failAfterWrite = false;
      await expectLater(first.flushAttachmentDraft(), throwsStateError);
      second.addPickedAttachments([file('second')]);
      await expectLater(second.flushAttachmentDraft(), throwsStateError);
      expect(second.attachments.single.fileName, 'second');
      expect(
        (storage.rows['one']!['files'] as List).single['filename'],
        'first',
      );
      await second.reloadSavedAttachments();
      expect(second.attachments.single.fileName, 'first');
      await first.reloadSavedAttachments();
      expect(first.attachmentStorageError, isNull);
      expect(storage.binaryWrites, 1);
      await close(first);
      await close(second);
    },
  );

  test(
    'removed selection remains budgeted until its storage callback settles',
    () async {
      final storage = Files(),
          drafts = owner(storage, maximumRetainedAttachments: 1);
      await open(drafts, 'one');
      final entered = Completer<void>(), release = Completer<void>();
      storage.beforeWrite = (input) async {
        if (input.isNotEmpty) {
          entered.complete();
          await release.future;
        }
      };
      drafts.addPickedAttachments([file('one')]);
      await entered.future;
      drafts.removeAttachmentAt(0);
      await open(drafts, 'two');
      expect(
        () => drafts.addAttachments([file('two')]),
        throwsA(isA<HandrailAttachmentException>()),
      );
      release.complete();
      await drafts.flushDrafts();
      storage.beforeWrite = null;
      drafts.addAttachments([file('two')]);
      await drafts.flushAttachmentDraft();
      expect(storage.rows.keys, ['two']);
      await close(drafts);
    },
  );

  test(
    'discard persists an empty draft; ordinary disposal and other chats survive',
    () async {
      final storage = Files(), drafts = owner(storage);
      for (final id in ['one', 'two']) {
        await open(drafts, id);
        drafts.addPickedAttachments([file(id)]);
        await drafts.flushAttachmentDraft();
      }
      drafts.discard('one');
      await drafts.closed;
      expect(storage.rows.keys, ['two']);
      await close(drafts);
      expect(storage.rows.keys, ['two']);
      final reopened = owner(storage);
      await open(reopened, 'one');
      expect(reopened.attachments, isEmpty);
      await close(reopened);
    },
  );
}
