import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
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
