import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  test('Stop retains the upload key; removal and admission release it once',
      () async {
    final keys = <String>[], released = <String>[];
    final pending = Completer<
        ({
          Map<String, Object?>? reference,
          String? errorCode,
          bool retryable
        })>();
    var first = true;
    final drafts = HandrailComposerController(
      limitsForConversation: (_) => HandrailAttachmentLimits(
          acceptedMediaTypes: ['image/png'],
          maximumFiles: 3,
          maximumBytesPerFile: 1024),
      uploaderForConversation: (_) => (
          {required bytes,
          required filename,
          required mediaType,
          required idempotencyKey,
          required cancellation}) async {
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
          retryable: false
        );
      },
      onUploadReleased: released.add,
    );
    addTearDown(drafts.dispose);
    drafts.select('one');
    final file = HandrailAttachmentFile(
        fileName: 'a.png', mediaType: 'image/png', bytes: [1]);
    final upload = drafts.prepareAttachments([file]);
    final cancelled =
        expectLater(upload, throwsA(isA<HandrailAttachmentException>()));
    drafts.cancelUploads();
    await cancelled;
    expect(released, isEmpty);
    pending
        .complete((reference: null, errorCode: 'cancelled', retryable: true));
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
  });

  test('discard, replacement and account disposal release separate drafts',
      () async {
    final released = <String>[];
    final drafts =
        HandrailComposerDrafts<String>(onUploadReleased: released.add);
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
  });

  test(
      'reopening a saved send acknowledges only its captured conversation draft',
      () async {
    final drafts = HandrailComposerDrafts<String>();
    addTearDown(drafts.dispose);
    drafts.select('one');
    drafts.controller.text = 'original';
    drafts.addAttachments(['first.pdf']);
    await expectLater(drafts.submit((_, __, accepted) async {
      throw StateError('lost reply');
    }), throwsStateError);
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
  });

  test('admission clears only submitted selections in their own chat',
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
  });

  test('failed upload keeps text/files; retry admission clears original only',
      () async {
    final drafts = HandrailComposerDrafts<String>();
    addTearDown(drafts.dispose);
    drafts.controller.text = 'question';
    drafts.addAttachments(['first.pdf']);
    late void Function() oldAccepted;
    await expectLater(drafts.submit((_, __, accepted) async {
      oldAccepted = accepted;
      throw StateError('Upload failed');
    }), throwsStateError);
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
  });

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
