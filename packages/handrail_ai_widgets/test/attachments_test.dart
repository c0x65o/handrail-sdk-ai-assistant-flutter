import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

HandrailAttachmentFile file(String name) => HandrailAttachmentFile(
  fileName: name,
  mediaType: 'application/pdf',
  bytes: [1, 2],
);
HandrailAttachmentLimits limits({int maximumFiles = 5}) =>
    HandrailAttachmentLimits(
      acceptedMediaTypes: ['application/pdf'],
      maximumFiles: maximumFiles,
      maximumBytesPerFile: 100,
    );
Map<String, Object?> reference(String filename) => {
  'attachment_id': 'att_test',
  'content_ref': 'ref_test',
  'media_type': 'application/pdf',
  'byte_size': 2,
  'filename': filename,
};
HandrailComposerController controller(
  HandrailAttachmentUploader uploader, {
  Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)?
  picker,
}) => HandrailComposerController(
  limitsForConversation: (_) => limits(),
  uploaderForConversation: (_) => uploader,
  filePicker: picker,
)..select('one');
void main() {
  test(
    'partial upload retry retains successful references and failed file identity until admission',
    () async {
      final calls = <String>[], keys = <String, List<String>>{};
      var failSecond = true;
      final drafts = controller(({
        required bytes,
        required filename,
        required mediaType,
        required idempotencyKey,
        required cancellation,
      }) async {
        calls.add(filename);
        keys.putIfAbsent(filename, () => []).add(idempotencyKey);
        if (filename == 'two.pdf' && failSecond)
          return (
            reference: null,
            errorCode: 'upload_unavailable',
            retryable: true,
          );
        return (
          reference: reference(filename),
          errorCode: null,
          retryable: false,
        );
      });
      addTearDown(drafts.dispose);
      drafts.controller.text = 'Review';
      drafts.addPickedAttachments([file('one.pdf'), file('two.pdf')]);
      var sends = 0;
      await expectLater(
        drafts.submitWithAttachments((text, refs, accepted) async {
          sends++;
          accepted();
        }),
        throwsA(isA<HandrailAttachmentException>()),
      );
      expect(sends, 0);
      expect(drafts.controller.text, 'Review');
      expect(drafts.attachments, hasLength(2));
      expect(drafts.attachmentSelections.map((f) => f.status), [
        HandrailAttachmentStatus.ready,
        HandrailAttachmentStatus.failed,
      ]);
      failSecond = false;
      await drafts.submitWithAttachments((text, refs, accepted) async {
        sends++;
        expect(refs, hasLength(2));
        expect(drafts.attachments, hasLength(2));
        accepted();
        expect(drafts.controller.text, isEmpty);
        expect(drafts.attachments, isEmpty);
      });
      expect(calls, ['one.pdf', 'two.pdf', 'two.pdf']);
      expect(keys['two.pdf']!.toSet(), hasLength(1));
      expect(sends, 1);
    },
  );
  test(
    'host-rendered selection uses the same queue and explicit replacement gets a new identity',
    () async {
      final keys = <String>[];
      final drafts = controller(({
        required bytes,
        required filename,
        required mediaType,
        required idempotencyKey,
        required cancellation,
      }) async {
        keys.add(idempotencyKey);
        return (
          reference: reference(filename),
          errorCode: null,
          retryable: false,
        );
      });
      addTearDown(drafts.dispose);
      final first = file('one.pdf');
      await drafts.prepareAttachments([first]);
      await drafts.prepareAttachments([first]);
      expect(keys, hasLength(1));
      await drafts.prepareAttachments([file('one.pdf')]);
      expect(keys.toSet(), hasLength(2));
      drafts.discard('one');
      expect(drafts.attachments, isEmpty);
    },
  );
  test(
    'cancellation preserves files and latest text, excludes late upload, and prevents admission',
    () async {
      final result =
          Completer<
            ({
              Map<String, Object?>? reference,
              String? errorCode,
              bool retryable,
            })
          >();
      final started = Completer<void>(), aborted = Completer<void>();
      final drafts = controller(({
        required bytes,
        required filename,
        required mediaType,
        required idempotencyKey,
        required cancellation,
      }) {
        cancellation.then((_) => aborted.complete());
        started.complete();
        return result.future;
      });
      addTearDown(drafts.dispose);
      drafts.controller.text = 'old';
      drafts.addPickedAttachments([file('one.pdf')]);
      var sends = 0;
      final sending = drafts.submitWithAttachments((
        text,
        refs,
        accepted,
      ) async {
        sends++;
        accepted();
      });
      await started.future;
      drafts.controller.text = 'new';
      final expectation = expectLater(
        sending,
        throwsA(
          isA<HandrailAttachmentException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      drafts.cancelUploads();
      await expectation;
      await aborted.future;
      result.complete((
        reference: reference('one.pdf'),
        errorCode: null,
        retryable: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(sends, 0);
      expect(drafts.controller.text, 'new');
      expect(drafts.attachments, hasLength(1));
      expect(
        drafts.attachmentSelections.single.status,
        HandrailAttachmentStatus.failed,
      );
    },
  );
  test(
    'account disposal cancels its upload and excludes its late reference',
    () async {
      final result =
          Completer<
            ({
              Map<String, Object?>? reference,
              String? errorCode,
              bool retryable,
            })
          >();
      final started = Completer<void>(), aborted = Completer<void>();
      final drafts = controller(({
        required bytes,
        required filename,
        required mediaType,
        required idempotencyKey,
        required cancellation,
      }) {
        cancellation.then((_) => aborted.complete());
        started.complete();
        return result.future;
      });
      drafts.addPickedAttachments([file('one.pdf')]);
      var sends = 0;
      final sending = drafts.submitWithAttachments((
        text,
        refs,
        accepted,
      ) async {
        sends++;
        accepted();
      });
      await started.future;
      final expectation = expectLater(
        sending,
        throwsA(
          isA<HandrailAttachmentException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      drafts.dispose();
      await expectation;
      await aborted.future;
      result.complete((
        reference: reference('one.pdf'),
        errorCode: null,
        retryable: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(sends, 0);
    },
  );

  test(
    'file-only send is eligible and late identical edits and reselections survive admission',
    () async {
      final drafts = controller(
        ({
          required bytes,
          required filename,
          required mediaType,
          required idempotencyKey,
          required cancellation,
        }) async =>
            (reference: reference(filename), errorCode: null, retryable: false),
      );
      addTearDown(drafts.dispose);
      final original = file('one.pdf');
      drafts.addPickedAttachments([original]);
      await drafts.submitWithAttachments((text, refs, accepted) async {
        expect(text, isEmpty);
        expect(refs, hasLength(1));
        drafts.removeAttachmentAt(0);
        drafts.addAttachments([original]);
        drafts.controller.text = 'later';
        drafts.controller.text = '';
        accepted();
        expect(drafts.attachments, [original]);
        drafts.controller.text = 'next draft';
      });
      expect(drafts.controller.text, 'next draft');
      expect(drafts.attachments, [original]);
    },
  );
  test(
    'late picker result cannot enter a different conversation or disposed account',
    () async {
      final picked = Completer<List<HandrailAttachmentFile>>();
      final drafts = controller(
        ({
          required bytes,
          required filename,
          required mediaType,
          required idempotencyKey,
          required cancellation,
        }) async =>
            (reference: reference(filename), errorCode: null, retryable: false),
        picker: (_) => picked.future,
      );
      final picking = drafts.pickAttachments();
      drafts.select('two');
      picked.complete([file('one.pdf')]);
      await picking;
      expect(drafts.attachments, isEmpty);
      drafts.select('one');
      expect(drafts.attachments, isEmpty);
      drafts.dispose();
    },
  );
  test(
    'unsupported capability combinations and oversized selections cannot upload',
    () async {
      expect(
        HandrailAttachmentLimits.fromCapabilities({
          'acceptedMediaTypes': ['application/pdf'],
          'maximumFiles': 5,
          'maximumBytesPerFile': 100,
        }, null),
        isNull,
      );
      final negotiated = HandrailAttachmentLimits.fromCapabilities(
        {
          'acceptedMediaTypes': ['image/*', 'application/pdf'],
          'maximumFiles': 5,
          'maximumBytesPerFile': 100,
        },
        {
          'supported_mime_types': ['application/pdf'],
          'max_document_count': 1,
          'max_document_bytes': 1,
        },
      )!;
      expect(
        () => negotiated.validate([file('one.pdf')]),
        throwsA(isA<HandrailAttachmentException>()),
      );
      expect(negotiated.acceptedMediaTypes, contains('image/png'));
    },
  );
  testWidgets(
    'minimal composer supplies bounded file list, picker, and file-only Send',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final picked = Completer<List<HandrailAttachmentFile>>();
      final drafts = controller(
        ({
          required bytes,
          required filename,
          required mediaType,
          required idempotencyKey,
          required cancellation,
        }) async =>
            (reference: reference(filename), errorCode: null, retryable: false),
        picker: (_) => picked.future,
      );
      addTearDown(drafts.dispose);
      var sends = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ListenableBuilder(
                listenable: drafts,
                builder: (context, _) => HandrailComposer(
                  sendKey: const ValueKey('send'),
                  controller: drafts.controller,
                  attachmentDrafts: drafts,
                  canSend: drafts.attachments.isNotEmpty,
                  onSend: () {
                    sends++;
                  },
                  showApprovalControl: false,
                  voiceControls: const [],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Add files and images'));
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed,
        isNull,
      );
      picked.complete(List.generate(5, (index) => file('$index.pdf')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(HandrailComposer)).height,
        lessThan(300),
      );
      await tester.tap(find.byTooltip('Send message'));
      await tester.pump();
      expect(sends, 1);
      await tester.tap(find.byTooltip('Remove 0.pdf'));
      await tester.pump();
      expect(drafts.attachments, hasLength(4));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
