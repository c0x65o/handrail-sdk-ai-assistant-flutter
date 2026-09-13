import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'attachment_preview.dart';
import 'attachments.dart';
import 'workspace_binding.dart';

typedef HandrailAttachmentSaver = Future<void> Function(
    HandrailAttachmentFile file);

/// Default platform save dialog. No app-specific HTTP or filesystem adapter is needed.
Future<void> handrailSaveAttachment(HandrailAttachmentFile file) async {
  final bytes = Uint8List.fromList(file.bytes);
  try {
    await FilePicker.saveFile(
        fileName: file.displayName,
        bytes: bytes,
        mimeType: file.mediaType,
        dialogTitle: 'Save attachment');
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// Shared saved metadata presentation with protected reads and a platform save action.
class HandrailSavedAttachment extends StatelessWidget {
  const HandrailSavedAttachment(
      {super.key,
      required this.attachment,
      required this.scope,
      required this.downloader,
      required this.maximumBytes,
      this.saveAttachment});
  final Map<String, Object?> attachment;
  final Object scope;
  final HandrailWorkspaceDownloader downloader;
  final int maximumBytes;
  final HandrailAttachmentSaver? saveAttachment;

  @override
  Widget build(BuildContext context) {
    final id = attachment['attachment_id'], type = attachment['media_type'];
    final filename = attachment['filename'];
    final name =
        filename is String && filename.isNotEmpty ? filename : 'Attachment';
    final size = attachment['size_bytes'] ?? attachment['byte_size'];
    if (id is! String ||
        id.isEmpty ||
        type is! String ||
        type.isEmpty ||
        size != null && (size is! int || size < 1 || size > maximumBytes))
      return Text(name);
    return HandrailAttachmentPreview(
      attachmentId: id,
      label: name,
      mediaType: type,
      scope: scope,
      maximumBytes: maximumBytes,
      presentation: HandrailAttachmentPresentation.inline,
      expectedByteSize: size as int?,
      openLabel: 'Download $name',
      loadBytesWithCancellation: (cancellation) async {
        final result = await downloader(
            attachmentId: id,
            mediaType: type,
            byteSize: size,
            cancellation: cancellation);
        final bytes = result.bytes;
        if (bytes == null)
          throw const HandrailAttachmentException('download_unavailable');
        return Uint8List.fromList(bytes);
      },
      onOpenBytes: (bytes) => (saveAttachment ?? handrailSaveAttachment)(
          HandrailAttachmentFile(
              fileName: name, mediaType: type, bytes: bytes)),
    );
  }
}
