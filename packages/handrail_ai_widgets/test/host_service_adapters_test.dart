import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'assistant_workspace_test.dart' show Fixture;

void main() {
  test('host image limits remain independent of larger PDF limits', () {
    final limits = HandrailAttachmentLimits(
      acceptedMediaTypes: ['image/png', 'application/pdf'],
      maximumFiles: 8,
      maximumBytesPerFile: 25 * 1024 * 1024,
      maximumImageBytes: 8 * 1024 * 1024,
    );
    expect(limits.maximumBytesFor('image/png'), 8 * 1024 * 1024);
    expect(limits.maximumBytesFor('application/pdf'), 25 * 1024 * 1024);
    final restricted = limits.intersect(HandrailAttachmentLimits(
      acceptedMediaTypes: ['image/png', 'application/pdf'],
      maximumFiles: 3,
      maximumBytesPerFile: 10 * 1024 * 1024,
      maximumImageBytes: 5 * 1024 * 1024,
    ))!;
    expect(restricted.maximumBytesFor('image/png'), 5 * 1024 * 1024);
    expect(restricted.maximumBytesFor('application/pdf'), 10 * 1024 * 1024);
  });

  test('explicit provider owns upload and release, and can revoke admission',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    var authorized = true;
    final released = <String>[], uploaded = <String>[];
    final provider = (
      limitsFor: (String? id) => authorized
          ? HandrailAttachmentLimits(
              acceptedMediaTypes: ['application/pdf'],
              maximumFiles: 2,
              maximumBytesPerFile: 100)
          : null,
      uploaderFor: (String? id) => authorized
          ? (
              {required List<int> bytes,
              required String filename,
              required String mediaType,
              required String idempotencyKey,
              required Future<void> cancellation}) async {
              uploaded.add(idempotencyKey);
              return (
                reference: <String, Object?>{
                  'attachment_id': 'att_pdf',
                  'content_ref': 'ref_pdf',
                  'media_type': mediaType,
                  'byte_size': bytes.length
                },
                errorCode: null,
                retryable: false
              );
            }
          : null,
      release: released.add,
    );
    // The original binding only offers images. The explicit protected host
    // service is the authority for this PDF; the default uploader cannot serve it.
    final drafts = HandrailComposerController.forAssistant(fixture.binding,
        attachmentProvider: provider);
    addTearDown(drafts.dispose);
    drafts.addPickedAttachments([
      HandrailAttachmentFile(
          fileName: 'a.pdf', mediaType: 'application/pdf', bytes: [1, 2])
    ]);
    await drafts.submitWithAttachments((_, refs, accepted) async {
      expect(refs.single['attachment_id'], 'att_pdf');
      accepted();
    });
    expect(uploaded, hasLength(1));
    expect(released, uploaded);
    authorized = false;
    expect(drafts.attachmentsEnabled, isFalse);
    drafts.addPickedAttachments([
      HandrailAttachmentFile(
          fileName: 'b.pdf', mediaType: 'application/pdf', bytes: [1])
    ]);
    expect(drafts.attachments, isEmpty);
  });

  test('native picker completion cannot populate another selected draft',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    final picked = Completer<List<HandrailAttachmentFile>>();
    final drafts = fixture.drafts;
    final picking = drafts.pickAttachmentsUsing((_) => picked.future);
    drafts.select('two');
    picked.complete([
      HandrailAttachmentFile(
          fileName: 'a.png', mediaType: 'image/png', bytes: [1])
    ]);
    await picking;
    expect(drafts.attachments, isEmpty);
    drafts.select('one');
    expect(drafts.attachments, isEmpty);
  });

  test('protected service replacement preserves SDK ownership and operations',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    final original = fixture.binding;
    final adapted = original.withServices(
        transcriberFor: (_) => null, downloaderFor: (_) => null);
    expect(adapted.scope, same(original.scope));
    expect(adapted.history, original.history);
    expect(adapted.approvals, original.approvals);
    expect(adapted.transcriberFor('one'), isNull);
    await adapted.stop('one');
    expect(fixture.stops, ['one']);
  });
}
