import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  test(
    'a slow save retains its old text budget after editor disposal',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var firstWrite = true;
      final drafts = HandrailComposerDrafts<String>(
        maximumRetainedDraftBytes: 3,
        readDraft: (_) async => null,
        writeDraft: (_, text, version) async {
          if (firstWrite) {
            firstWrite = false;
            entered.complete();
            await release.future;
          }
          return text.isEmpty ? null : {'version': 'v1', 'text': text};
        },
      );
      addTearDown(() async {
        drafts.dispose();
        await drafts.closed;
      });
      drafts.select('one');
      drafts.controller.text = 'old';
      final saving = drafts.controller.flushDraft();
      await entered.future;
      drafts.discard('one');
      drafts.select('two');
      drafts.controller.text = 'new';
      expect(drafts.controller.text, isEmpty);
      expect(drafts.controller.draftInputError, contains('device text limit'));
      release.complete();
      await saving;
      await drafts.closed;
      drafts.controller.text = 'new';
      expect(drafts.controller.text, 'new');
    },
  );

  test(
    'text budgets preserve edits across chats, pending sends and restoration',
    () async {
      final drafts = HandrailComposerDrafts<String>(
        maximumRetainedDraftBytes: 6,
        maximumRetainedDrafts: 2,
      );
      addTearDown(drafts.dispose);
      drafts.select('one');
      drafts.controller.text = 'one';
      drafts.select('two');
      drafts.controller.text = 'two';
      drafts.controller.text = 'long';
      expect(drafts.controller.text, 'two');
      expect(drafts.controller.draftInputError, contains('device text limit'));
      drafts.select('three');
      drafts.controller.text = 'x';
      expect(drafts.controller.text, isEmpty);
      drafts.select('one');
      final response = Completer<void>();
      final sending = drafts.submit((text, files, accepted) {
        accepted();
        return response.future;
      });
      expect(drafts.controller.text, isEmpty);
      drafts.select('three');
      drafts.controller.text = 'x';
      expect(
        drafts.controller.text,
        isEmpty,
      ); // Send callback still holds "one".
      response.complete();
      await sending;
      drafts.controller.text = 'new';
      expect(drafts.controller.text, 'new');
      expect(drafts.controller.draftInputError, isNull);
      drafts.controller.text = '🦊🦊'; // Eight UTF-8 bytes, not four.
      expect(drafts.controller.text, 'new');
      drafts.controller.clear();
      expect(drafts.controller.draftInputError, isNull);
    },
  );

  test('text count is bounded even when all unsaved drafts are very small', () {
    final drafts = HandrailComposerDrafts<String>(maximumRetainedDrafts: 2);
    addTearDown(drafts.dispose);
    for (final id in ['one', 'two', 'three']) {
      drafts.select(id);
      drafts.controller.text = id;
    }
    expect(drafts.controller.text, isEmpty);
    drafts.discard('one');
    drafts.controller.text = 'three';
    expect(drafts.controller.text, 'three');
  });

  test(
    'a capacity-blocked saved draft remains in storage and can be reopened',
    () async {
      final stored = <String, Map<String, Object?>>{
        'saved': {'version': 'v1', 'text': 'saved'},
      };
      final drafts = HandrailComposerDrafts<String>(
        maximumRetainedDraftBytes: 6,
        readDraft: (id) async => stored[id],
        writeDraft: (id, text, version) async {
          if (stored[id]?['version'] != version) throw StateError('conflict');
          if (text.isEmpty) {
            stored.remove(id);
            return null;
          }
          return stored[id] = {'version': 'next', 'text': text};
        },
      );
      addTearDown(() async {
        drafts.dispose();
        await drafts.closed;
      });
      drafts.select('other');
      drafts.controller.text = 'busy';
      await drafts.controller.flushDraft();
      drafts.select('saved');
      await expectLater(drafts.controller.flushDraft(), throwsStateError);
      expect(drafts.controller.text, isEmpty);
      expect(drafts.controller.draftInputError, contains('device text limit'));
      expect(stored['saved']?['text'], 'saved');
      drafts.discard('other');
      await drafts.closed;
      await drafts.controller.reloadSavedDraft();
      expect(drafts.controller.text, 'saved');
      expect(drafts.controller.draftInputError, isNull);
      expect(stored['saved']?['text'], 'saved');
    },
  );

  test(
    'oversized paste preserves the previous draft and its send revision',
    () async {
      final drafts = HandrailComposerDrafts<String>();
      addTearDown(drafts.dispose);
      drafts.controller.text = 'ready';
      late void Function() accepted;
      final response = Completer<void>();
      final sending = drafts.submit((text, files, callback) {
        accepted = callback;
        return response.future;
      });
      drafts.controller.text = 'x' * 65537;
      expect(drafts.controller.text, 'ready');
      expect(drafts.controller.draftInputError, contains('64 KiB'));
      accepted();
      expect(drafts.controller.text, isEmpty);
      response.complete();
      await sending;
    },
  );

  test(
    'empty drafts are evicted without storage while unsaved text survives',
    () {
      final drafts = HandrailComposerDrafts<String>();
      addTearDown(drafts.dispose);
      drafts.select('unsaved');
      final unsaved = drafts.controller;
      unsaved.text = 'keep this draft';
      drafts.select('empty');
      final empty = drafts.controller;
      for (var i = 0; i < 40; i++) {
        drafts.select('chat-$i');
      }
      expect(() => empty.addListener(() {}), throwsFlutterError);
      drafts.select('unsaved');
      expect(drafts.controller, same(unsaved));
      expect(drafts.controller.text, 'keep this draft');
    },
  );

  test('file budgets span chats and reject additions atomically', () async {
    var uploads = 0;
    final drafts = HandrailComposerController(
      maximumRetainedAttachmentBytes: 6,
      limitsForConversation: (_) => _limits(),
      uploaderForConversation: (_) =>
          ({
            required bytes,
            required filename,
            required mediaType,
            required idempotencyKey,
            required cancellation,
          }) async {
            uploads++;
            return _uploaded(bytes, mediaType);
          },
    );
    addTearDown(drafts.dispose);
    drafts.select('one');
    final first = _file(3);
    drafts.addAttachments([first]);
    drafts.select('two');
    final second = _file(3);
    drafts.addAttachments([second]);
    final selection = drafts.attachmentSelections.single.id;
    await expectLater(
      drafts.prepareAttachments([_file(4)]),
      throwsA(_attachmentCode('draft_attachment_capacity')),
    );
    expect(drafts.attachments, [second]);
    expect(drafts.attachmentSelections.single.id, same(selection));
    expect(uploads, 0);
    drafts.select('three');
    drafts.addPickedAttachments([_file(1)]);
    expect(drafts.attachments, isEmpty);
    expect(drafts.attachmentError, contains('remove unsent files'));
    drafts.discard('one');
    drafts.addPickedAttachments([_file(1)]);
    expect(drafts.attachmentError, isNull);
    expect(drafts.attachments, hasLength(1));
  });

  test('opaque host selections still obey the account file-count limit', () {
    final drafts = HandrailComposerDrafts<String>(
      maximumRetainedAttachments: 2,
    );
    addTearDown(drafts.dispose);
    drafts.select('one');
    drafts.addAttachments(['a']);
    drafts.select('two');
    drafts.addAttachments(['b']);
    expect(
      () => drafts.addAttachments(['c']),
      throwsA(_attachmentCode('draft_attachment_capacity')),
    );
    expect(drafts.attachments, ['b']);
    drafts.discard('one');
    drafts.addAttachments(['c']);
    expect(drafts.attachments, ['b', 'c']);
  });

  test(
    'accepted sends retain their file budget until callbacks settle',
    () async {
      final drafts = HandrailComposerDrafts<HandrailAttachmentFile>(
        maximumRetainedAttachmentBytes: 3,
        fileForAttachment: (file) => file,
      );
      addTearDown(drafts.dispose);
      drafts.select('one');
      drafts.addAttachments([_file(3)]);
      drafts.controller.text = 'send';
      final response = Completer<void>();
      final sending = drafts.submit((_, files, accepted) {
        accepted();
        return response.future;
      });
      expect(drafts.attachments, isEmpty);
      drafts.select('two');
      expect(
        () => drafts.addAttachments([_file(1)]),
        throwsA(_attachmentCode('draft_attachment_capacity')),
      );
      response.complete();
      await sending;
      drafts.addAttachments([_file(3)]);
      expect(drafts.attachments, hasLength(1));
    },
  );

  test(
    'cancelled host transfers keep their permit and retry identity',
    () async {
      final keys = <String>[];
      final transfer = Completer<_UploadResult>();
      final drafts = HandrailComposerController(
        maximumConcurrentUploads: 1,
        limitsForConversation: (_) => _limits(),
        uploaderForConversation: (_) =>
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              keys.add(idempotencyKey);
              return keys.length == 1
                  ? transfer.future
                  : _uploaded(bytes, mediaType);
            },
      );
      addTearDown(drafts.dispose);
      drafts.select('one');
      final file = _file(3);
      final first = drafts.prepareAttachments([file]);
      final cancelled = expectLater(
        first,
        throwsA(_attachmentCode('cancelled')),
      );
      drafts.cancelUploads();
      await cancelled;
      await expectLater(
        drafts.prepareAttachments([file]),
        throwsA(_attachmentCode('upload_capacity')),
      );
      expect(keys, hasLength(1));
      transfer.complete((
        reference: null,
        errorCode: 'cancelled',
        retryable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      await drafts.prepareAttachments([file]);
      expect(keys, [keys.first, keys.first]);
    },
  );

  test(
    'removing a cancelled transfer cannot bypass the retained byte limit',
    () async {
      final transfer = Completer<_UploadResult>();
      final drafts = HandrailComposerController(
        maximumRetainedAttachmentBytes: 3,
        limitsForConversation: (_) => _limits(),
        uploaderForConversation: (_) =>
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) => transfer.future,
      );
      addTearDown(drafts.dispose);
      drafts.select('one');
      final first = drafts.prepareAttachments([_file(3)]);
      final cancelled = expectLater(
        first,
        throwsA(_attachmentCode('cancelled')),
      );
      drafts.discard('one');
      await cancelled;
      drafts.select('two');
      expect(
        () => drafts.addAttachments([_file(1)]),
        throwsA(_attachmentCode('draft_attachment_capacity')),
      );
      transfer.complete((
        reference: null,
        errorCode: 'cancelled',
        retryable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      drafts.addAttachments([_file(3)]);
      expect(drafts.attachments, hasLength(1));
    },
  );

  test(
    'selection snapshots upload bytes once and rejects invalid replacements',
    () async {
      var conversions = 0, uploads = 0;
      final value = <int>[1, 2, 3];
      final drafts = HandrailComposerDrafts<List<int>>(
        fileForAttachment: (bytes) {
          conversions++;
          return HandrailAttachmentFile(
            fileName: 'a.png',
            mediaType: 'image/png',
            bytes: bytes,
          );
        },
        limitsForConversation: (_) => _limits(maximumBytes: 3),
        uploaderForConversation: (_) =>
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              uploads++;
              expect(bytes, [1, 2, 3]);
              return _uploaded(bytes, mediaType);
            },
      );
      addTearDown(drafts.dispose);
      drafts.select('one');
      drafts.addAttachments([value]);
      value[0] = 99;
      for (var i = 0; i < 10; i++) {
        expect(drafts.attachmentSelections.single.byteSize, 3);
      }
      await drafts.prepareAttachments([value]);
      expect(conversions, 1);
      await expectLater(
        drafts.prepareAttachments([
          [1, 2, 3, 4],
        ]),
        throwsA(isA<HandrailAttachmentException>()),
      );
      expect(drafts.attachments.single, same(value));
      await drafts.prepareAttachments([value]);
      expect(conversions, 2); // Only the rejected new selection was converted.
      expect(uploads, 1); // The original acknowledged upload remains reusable.
    },
  );

  test(
    'persists separate chats across controller replacement and discards only the selected journal',
    () async {
      final stored = <String, Map<String, Object?>>{};
      var revision = 0;
      HandrailComposerDrafts<String> create() => HandrailComposerDrafts<String>(
        readDraft: (id) async => stored[id],
        writeDraft: (id, text, version) async {
          if (stored[id]?['version'] != version) throw StateError('conflict');
          if (text.isEmpty) {
            stored.remove(id);
            return null;
          }
          return stored[id] = {'version': '${++revision}', 'text': text};
        },
      );
      final first = create();
      first.select('one');
      first.controller.text = 'chat one';
      first.select('two');
      first.controller.text = 'chat two';
      first.dispose();
      await first.closed;
      final reopened = create();
      addTearDown(() async {
        reopened.dispose();
        await reopened.closed;
      });
      reopened.select('one');
      await reopened.flushDrafts();
      expect(reopened.controller.text, 'chat one');
      reopened.discard(
        'one',
      ); // Immediate reopen waits for the old draft clear.
      await reopened.controller.flushDraft();
      expect(reopened.controller.text, '');
      reopened.select('two');
      await reopened.flushDrafts();
      expect(reopened.controller.text, 'chat two');
      expect(stored.containsKey('one'), isFalse);
    },
  );

  test(
    'adopts unassigned text and releases old saved idle controllers without losing their drafts',
    () async {
      final stored = <String, Map<String, Object?>>{};
      var revision = 0;
      final drafts = HandrailComposerDrafts<String>(
        readDraft: (id) async => stored[id],
        writeDraft: (id, text, version) async {
          if (stored[id]?['version'] != version) throw StateError('conflict');
          return stored[id] = {'version': '${++revision}', 'text': text};
        },
      );
      addTearDown(() async {
        drafts.dispose();
        await drafts.closed;
      });
      drafts.controller.text = 'before conversation creation';
      drafts.select('created', adoptUnassignedDraft: true);
      await drafts.flushDrafts();
      expect(stored['created']?['text'], 'before conversation creation');
      final old = drafts.controller;
      for (var i = 0; i < 12; i++) {
        drafts.select('c$i');
        drafts.controller.text = 'draft $i';
        await drafts.flushDrafts();
      }
      expect(old.text, '');
      drafts.select('created');
      await drafts.flushDrafts();
      expect(drafts.controller.text, 'before conversation creation');
    },
  );

  test(
    'Stop retains the upload key; removal and admission release it once',
    () async {
      final keys = <String>[], released = <String>[];
      final pending =
          Completer<
            ({
              Map<String, Object?>? reference,
              String? errorCode,
              bool retryable,
            })
          >();
      var first = true;
      final drafts = HandrailComposerController(
        limitsForConversation: (_) => HandrailAttachmentLimits(
          acceptedMediaTypes: ['image/png'],
          maximumFiles: 3,
          maximumBytesPerFile: 1024,
        ),
        uploaderForConversation: (_) =>
            ({
              required bytes,
              required filename,
              required mediaType,
              required idempotencyKey,
              required cancellation,
            }) async {
              keys.add(idempotencyKey);
              if (first) {
                first = false;
                return pending.future;
              }
              return (
                reference: <String, Object?>{
                  'attachment_id': 'att_test',
                  'content_ref': 'ref_test',
                  'media_type': mediaType,
                  'byte_size': bytes.length,
                },
                errorCode: null,
                retryable: false,
              );
            },
        onUploadReleased: released.add,
      );
      addTearDown(drafts.dispose);
      drafts.select('one');
      final file = HandrailAttachmentFile(
        fileName: 'a.png',
        mediaType: 'image/png',
        bytes: [1],
      );
      final upload = drafts.prepareAttachments([file]);
      final cancelled = expectLater(
        upload,
        throwsA(isA<HandrailAttachmentException>()),
      );
      drafts.cancelUploads();
      await cancelled;
      expect(released, isEmpty);
      pending.complete((
        reference: null,
        errorCode: 'cancelled',
        retryable: true,
      ));
      await drafts.prepareAttachments([file]);
      expect(keys, [keys.first, keys.first]);
      drafts.controller.text = 'send';
      late void Function() accepted;
      final admission = Completer<void>();
      final sending = drafts.submitWithAttachments((_, __, callback) {
        accepted = callback;
        return admission.future;
      });
      await Future<void>.value();
      await Future<void>.value();
      drafts.removeAttachmentAt(0);
      expect(released, [keys.first]);
      accepted();
      expect(released, [keys.first]);
      admission.complete();
      await sending;
      drafts.dispose();
      expect(released, [keys.first]);
    },
  );

  test(
    'discard, replacement and account disposal release separate drafts',
    () async {
      final released = <String>[];
      final drafts = HandrailComposerDrafts<String>(
        onUploadReleased: released.add,
      );
      drafts.select('one');
      drafts.addAttachments(['a', 'b']);
      drafts.select('two');
      drafts.addAttachments(['c']);
      drafts.discard('one');
      expect(released.toSet(), hasLength(2));
      drafts.clear();
      expect(released.toSet(), hasLength(3));
      drafts.addAttachments(['d']);
      drafts.dispose();
      expect(released, hasLength(4));
      expect(released.toSet(), hasLength(4));
    },
  );

  test(
    'reopening a saved send acknowledges only its captured conversation draft',
    () async {
      final drafts = HandrailComposerDrafts<String>();
      addTearDown(drafts.dispose);
      drafts.select('one');
      drafts.controller.text = 'original';
      drafts.addAttachments(['first.pdf']);
      await expectLater(
        drafts.submit((_, __, accepted) async {
          throw StateError('lost reply');
        }),
        throwsStateError,
      );
      drafts.select('two');
      drafts.controller.text = 'other draft';
      final accepted = drafts.capturePendingAcceptance('one');
      drafts.select('one');
      drafts.controller.text = 'later';
      drafts.controller.text = 'original';
      drafts.removeAttachmentAt(0);
      drafts.addAttachments(['first.pdf']);
      drafts.select('two');
      accepted();
      expect(drafts.controller.text, 'other draft');
      drafts.select('one');
      expect(drafts.controller.text, 'original');
      expect(drafts.attachments, ['first.pdf']);
    },
  );

  test(
    'admission clears only submitted selections in their own chat',
    () async {
      final drafts = HandrailComposerDrafts<String>();
      addTearDown(drafts.dispose);
      drafts.select('one');
      drafts.controller.text = 'question';
      drafts.addAttachments(['same.pdf']);
      late void Function() accepted;
      final response = Completer<void>();
      final sending = drafts.submit((text, files, callback) {
        expect(text, 'question');
        expect(files, ['same.pdf']);
        accepted = callback;
        return response.future;
      });
      drafts.removeAttachmentAt(0);
      drafts.addAttachments(['same.pdf', 'later.png']);
      drafts.controller.text = 'edited';
      drafts.controller.text = 'question';
      drafts.select('two');
      drafts.controller.text = 'other chat';
      accepted();
      expect(drafts.controller.text, 'other chat');
      drafts.select('one');
      expect(drafts.controller.text, 'question');
      expect(drafts.attachments, ['same.pdf', 'later.png']);
      response.complete();
      await sending;
      expect(drafts.draftConversationIds, {'one', 'two'});
      expect(drafts.hasOtherDrafts, isTrue);
    },
  );

  test(
    'failed upload keeps text/files; retry admission clears original only',
    () async {
      final drafts = HandrailComposerDrafts<String>();
      addTearDown(drafts.dispose);
      drafts.controller.text = 'question';
      drafts.addAttachments(['first.pdf']);
      late void Function() oldAccepted;
      await expectLater(
        drafts.submit((_, __, accepted) async {
          oldAccepted = accepted;
          throw StateError('Upload failed');
        }),
        throwsStateError,
      );
      oldAccepted();
      expect(drafts.controller.text, 'question');
      expect(drafts.attachments, ['first.pdf']);
      drafts.addAttachments(['next.pdf']);
      await drafts.retry((accepted) async {
        oldAccepted();
        expect(drafts.attachments, ['first.pdf', 'next.pdf']);
        accepted();
      });
      expect(drafts.controller.text, isEmpty);
      expect(drafts.attachments, ['next.pdf']);
    },
  );

  test('discard and dispose invalidate background admission safely', () async {
    final drafts = HandrailComposerDrafts<String>();
    drafts.select('one');
    drafts.controller.text = 'question';
    final response = Completer<void>();
    late void Function() accepted;
    final sending = drafts.submit((_, __, callback) {
      accepted = callback;
      return response.future;
    });
    drafts.discard('one');
    drafts.controller.text = 'new draft';
    accepted();
    expect(drafts.controller.text, 'new draft');
    drafts.dispose();
    accepted();
    response.complete();
    await sending;
  });
}

typedef _UploadResult = ({
  Map<String, Object?>? reference,
  String? errorCode,
  bool retryable,
});

Matcher _attachmentCode(String code) => isA<HandrailAttachmentException>()
    .having((error) => error.code, 'code', code);
HandrailAttachmentLimits _limits({int maximumBytes = 1024}) =>
    HandrailAttachmentLimits(
      acceptedMediaTypes: ['image/png'],
      maximumFiles: 8,
      maximumBytesPerFile: maximumBytes,
    );
HandrailAttachmentFile _file(int size) => HandrailAttachmentFile(
  fileName: 'a.png',
  mediaType: 'image/png',
  bytes: List.filled(size, 1),
);
_UploadResult _uploaded(List<int> bytes, String mediaType) => (
  reference: <String, Object?>{
    'attachment_id': 'att_test',
    'content_ref': 'ref_test',
    'media_type': mediaType,
    'byte_size': bytes.length,
  },
  errorCode: null,
  retryable: false,
);
