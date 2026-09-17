import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  test(
    'replayed origin removes only its exact saved revision after recreation',
    () async {
      Map<String, Object?>? saved;
      var sequence = 0;
      HandrailDraftController owner() => HandrailDraftController(
        readDraft: () async => saved,
        writeDraft: (text, version) async {
          if (version != saved?['version']) throw StateError('conflict');
          return saved = text.isEmpty
              ? null
              : {'version': '${++sequence}', 'text': text};
        },
      );
      final first = owner();
      await first.flushDraft();
      first.text = 'sent';
      final version = (await first.captureVersion(first.draftEdit))!;
      first.dispose();
      await first.closed;
      final next = owner();
      addTearDown(() async {
        next.dispose();
        await next.closed;
      });
      await next.flushDraft();
      await next.reconcileAcceptedVersion(version);
      expect(saved, isNull);
      expect(next.text, isEmpty);
      next.text = 'sent';
      await next.flushDraft();
      await next.reconcileAcceptedVersion(version);
      expect(saved!['text'], 'sent');
      expect(next.text, 'sent');
      expect(saved!['version'], isNot(version));
    },
  );

  test(
    'origin capture does not identify a newer edit written while it waits',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var writes = 0;
      final draft = HandrailDraftController(
        readDraft: () async => null,
        writeDraft: (text, version) async {
          if (writes++ == 0) {
            entered.complete();
            await release.future;
          }
          return {'version': '$writes', 'text': text};
        },
      );
      addTearDown(() async {
        draft.dispose();
        await draft.closed;
      });
      await draft.flushDraft();
      draft.text = 'same';
      final captured = draft.captureVersion(draft.draftEdit);
      await entered.future;
      draft.text = 'other';
      draft.text = 'same';
      release.complete();
      expect(await captured, isNull);
      expect(draft.text, 'same');
    },
  );

  test(
    'typing during cleanup survives immediate owner disposal and flush',
    () async {
      Map<String, Object?>? saved = {'version': 'sent-v', 'text': 'sent'};
      final entered = Completer<void>(), release = Completer<void>();
      final draft = HandrailDraftController(
        readDraft: () async => saved,
        writeDraft: (text, version) async {
          if (text.isEmpty) {
            entered.complete();
            await release.future;
          }
          if (version != saved?['version']) throw StateError('conflict');
          return saved = text.isEmpty
              ? null
              : {'version': 'next-v', 'text': text};
        },
      );
      await draft.flushDraft();
      final cleaning = draft.reconcileAcceptedVersion('sent-v');
      await entered.future;
      draft.text = 'new';
      draft.dispose();
      release.complete();
      await cleaning;
      await draft.closed;
      expect(saved, {'version': 'next-v', 'text': 'new'});
    },
  );

  test(
    'cleanup preserves another writer without rebasing over unseen text',
    () async {
      Map<String, Object?>? saved = {'version': 'sent-v', 'text': 'sent'};
      final draft = HandrailDraftController(
        readDraft: () async => saved,
        writeDraft: (text, version) async {
          if (version != saved?['version']) throw StateError('conflict');
          return saved = text.isEmpty
              ? null
              : {'version': 'write-v', 'text': text};
        },
      );
      addTearDown(() async {
        draft.dispose();
        await draft.closed;
      });
      await draft.flushDraft();
      saved = {'version': 'new-v', 'text': 'remote'};
      await draft.reconcileAcceptedVersion('sent-v');
      expect(draft.text, isEmpty);
      expect(saved!['text'], 'remote');
      expect(draft.draftStorageError, contains('another view'));
      draft.text = 'local';
      await expectLater(draft.flushDraft(), throwsStateError);
      expect(saved!['text'], 'remote');
      await draft.reloadSavedDraft();
      expect(draft.text, 'remote');
    },
  );

  test(
    'typing during restoration wins and admission preserves later edits',
    () async {
      final reading = Completer<Map<String, Object?>?>();
      var saved = <String, Object?>{
        'version': 'old',
        'text': 'saved before reload',
      };
      final draft = HandrailDraftController(
        readDraft: () => reading.future,
        writeDraft: (text, version) async {
          expect(version, saved['version']);
          saved = {'version': '$version-next', 'text': text};
          return saved;
        },
      );
      addTearDown(() async {
        draft.dispose();
        await draft.closed;
      });
      expect(draft.restoringDraft, isTrue);
      draft.text = 'typed early';
      expect(await draft.submit((_, __) async => 'blocked'), isNull);
      reading.complete(saved);
      await draft.flushDraft();
      expect(draft.text, 'typed early');
      expect(saved['text'], 'typed early');
      final sending = Completer<void>();
      late void Function() accepted;
      final result = draft.submit((text, callback) {
        accepted = callback;
        return sending.future;
      });
      draft.text = 'next question';
      accepted();
      sending.complete();
      await result;
      await draft.flushDraft();
      expect(saved['text'], 'next question');
      await draft.submit((_, admitted) async {
        admitted();
      });
      await draft.flushDraft();
      expect(saved['text'], '');
    },
  );

  test(
    'coalesces slow writes and flushes before disposing account text',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      String? saved;
      var writes = 0;
      final draft = HandrailDraftController(
        readDraft: () async => null,
        writeDraft: (text, version) async {
          if (writes++ == 0) {
            entered.complete();
            await release.future;
          }
          saved = text;
          return {'version': '$writes', 'text': text};
        },
      );
      draft.text = 'first';
      final flushing = draft.flushDraft();
      await entered.future;
      draft.text = 'last';
      draft.dispose();
      release.complete();
      await flushing;
      await draft.closed;
      expect(saved, 'last');
      expect(writes, 2);
      expect(draft.text, '');
    },
  );

  test(
    'storage conflict retains the editor until an explicit reload',
    () async {
      var saved = <String, Object?>{'version': '1', 'text': 'original'};
      final draft = HandrailDraftController(
        readDraft: () async => saved,
        writeDraft: (text, version) async {
          if (version != saved['version']) throw StateError('conflict');
          return saved = {'version': '3', 'text': text};
        },
      );
      addTearDown(() async {
        draft.dispose();
        await draft.closed;
      });
      await draft.flushDraft();
      expect(draft.text, 'original');
      saved = {'version': '2', 'text': 'another writer'};
      draft.text = 'my draft';
      await expectLater(draft.flushDraft(), throwsStateError);
      expect(draft.text, 'my draft');
      expect(draft.draftStorageError, isNotNull);
      await draft.reloadSavedDraft();
      expect(draft.text, 'another writer');
      draft.text = 'new edit';
      await draft.flushDraft();
      expect(saved['text'], 'new edit');
    },
  );

  for (final edit in [null, '', 'later', 'original']) {
    test(
      'retry reconciles the original revision with later draft $edit',
      () async {
        final draft = HandrailDraftController(text: 'original');
        addTearDown(draft.dispose);
        await expectLater(
          draft.submit((_, __) async {
            throw StateError('Admission response lost');
          }),
          throwsStateError,
        );
        if (edit != null) {
          draft.text = 'intermediate';
          draft.text = edit;
        }
        await draft.retry((accepted) async {
          accepted();
        });
        expect(draft.text, edit ?? '');
      },
    );
  }

  test(
    'retry without this draft submission identity cannot clear text',
    () async {
      final draft = HandrailDraftController(text: 'restored draft');
      addTearDown(draft.dispose);
      await draft.retry((accepted) async => accepted());
      expect(draft.text, 'restored draft');
    },
  );

  for (final outcome in ['completed', 'failed', 'cancelled']) {
    test(
      'acceptance clears only the submitted revision after $outcome',
      () async {
        final changes = <String>[];
        final draft = HandrailDraftController(
          text: 'hello',
          onDraftChanged: changes.add,
        );
        addTearDown(draft.dispose);
        final result = Completer<String>();
        late void Function() accepted;
        final sending = draft.submit((text, callback) {
          expect(text, 'hello');
          accepted = callback;
          return result.future;
        });
        expect(draft.text, 'hello');
        expect(draft.isSubmitting, isTrue);
        expect(await draft.submit((_, __) async => 'duplicate'), isNull);
        accepted();
        expect(draft.text, isEmpty);
        draft.text = 'hello';
        accepted();
        expect(draft.text, 'hello');
        if (outcome == 'failed') {
          final failure = expectLater(sending, throwsStateError);
          result.completeError(StateError('Response failed'));
          await failure;
        } else {
          result.complete(outcome);
          expect(await sending, outcome);
        }
        expect(draft.text, 'hello');
        expect(draft.isSubmitting, isFalse);
        expect(changes, ['', 'hello']);
      },
    );
  }

  test(
    'keeps edits before admission, including a return to identical text',
    () async {
      final draft = HandrailDraftController(text: 'hello');
      addTearDown(draft.dispose);
      final result = Completer<void>();
      late void Function() accepted;
      final sending = draft.submit((_, callback) {
        accepted = callback;
        return result.future;
      });
      draft.text = 'edited';
      draft.text = 'hello';
      accepted();
      expect(draft.text, 'hello');
      result.complete();
      await sending;
      expect(draft.text, 'hello');
    },
  );

  test('ignores old callbacks after scope reset or disposal', () async {
    final draft = HandrailDraftController(text: 'old');
    final old = Completer<void>();
    late void Function() accepted;
    final sending = draft.submit((_, callback) {
      accepted = callback;
      return old.future;
    });
    draft.reset(text: 'new account');
    accepted();
    expect(draft.text, 'new account');
    expect(draft.isSubmitting, isFalse);
    draft.dispose();
    accepted();
    old.complete();
    await sending;
  });

  test('retains a deliberate empty draft after an admitted failure', () async {
    final draft = HandrailDraftController(text: 'hello');
    addTearDown(draft.dispose);
    final sending = draft.submit((_, accepted) async {
      accepted();
      draft.text = 'next';
      draft.clear();
      throw StateError('Failed');
    });
    await expectLater(sending, throwsStateError);
    expect(draft.text, isEmpty);
  });
}
