import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Structural binding to the protected client; no client/widgets dependency.
typedef HandrailAttachmentUploader = Future<
        ({Map<String, Object?>? reference, String? errorCode, bool retryable})>
    Function({
  required List<int> bytes,
  required String filename,
  required String mediaType,
  required String idempotencyKey,
  required Future<void> cancellation,
});

/// An explicitly configured host file service. Its limits describe that service,
/// independently of whether the SDK gateway mounts its default upload route.
/// Authentication and current conversation authorization remain host obligations.
typedef HandrailAttachmentProvider = ({
  HandrailAttachmentLimits? Function(String?) limitsFor,
  HandrailAttachmentUploader? Function(String?) uploaderFor,
  void Function(String idempotencyKey) release,
});

class HandrailAttachmentFile {
  HandrailAttachmentFile(
      {required this.fileName,
      required this.mediaType,
      required List<int> bytes})
      : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final String fileName, mediaType;
  final Uint8List bytes;
  int get byteSize => bytes.length;
  String get displayName {
    final name = fileName
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_')
        .trim();
    final safe =
        name.isEmpty || name == '.' || name == '..' ? 'attachment' : name;
    return safe.length <= 180 ? safe : safe.substring(0, 180);
  }

  @override
  String toString() => 'HandrailAttachmentFile(redacted)';
}

const handrailAttachmentMediaTypes = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'tsv': 'text/tab-separated-values',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xls': 'application/vnd.ms-excel',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'doc': 'application/msword',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'ppt': 'application/vnd.ms-powerpoint',
  'json': 'application/json',
  'md': 'text/markdown',
};

class HandrailAttachmentLimits {
  HandrailAttachmentLimits(
      {required Iterable<String> acceptedMediaTypes,
      required this.maximumFiles,
      required this.maximumBytesPerFile,
      this.maximumTotalBytes = 20 * 1024 * 1024,
      int? maximumImageBytes,
      int? maximumDocumentFiles,
      int? maximumDocumentBytes})
      : acceptedMediaTypes = Set.unmodifiable(acceptedMediaTypes),
        maximumImageBytes = maximumImageBytes ?? maximumBytesPerFile,
        maximumDocumentFiles = maximumDocumentFiles ?? maximumFiles,
        maximumDocumentBytes = maximumDocumentBytes ?? maximumBytesPerFile {
    if (this.acceptedMediaTypes.isEmpty ||
        maximumFiles < 1 ||
        maximumFiles > 100 ||
        maximumBytesPerFile < 1 ||
        maximumBytesPerFile > 50 * 1024 * 1024 ||
        maximumTotalBytes < 1 ||
        maximumTotalBytes > 100 * 1024 * 1024 ||
        this.maximumImageBytes < 0 ||
        this.maximumDocumentFiles < 0 ||
        this.maximumDocumentBytes < 0)
      throw ArgumentError('Invalid attachment limits.');
  }
  final Set<String> acceptedMediaTypes;
  final int maximumFiles,
      maximumBytesPerFile,
      maximumTotalBytes,
      maximumImageBytes,
      maximumDocumentFiles,
      maximumDocumentBytes;
  int maximumBytesFor(String type) => type.startsWith('image/')
      ? math.min(maximumImageBytes, maximumBytesPerFile)
      : maximumDocumentBytes < maximumBytesPerFile
          ? maximumDocumentBytes
          : maximumBytesPerFile;
  List<String> get extensions => handrailAttachmentMediaTypes.entries
      .where((entry) => acceptedMediaTypes.contains(entry.value))
      .map((entry) => entry.key)
      .toList();

  /// Restricts negotiated limits with host business settings. Never expands them.
  HandrailAttachmentLimits? intersect(HandrailAttachmentLimits other) {
    final types = acceptedMediaTypes.intersection(other.acceptedMediaTypes);
    if (types.isEmpty) return null;
    return HandrailAttachmentLimits(
      acceptedMediaTypes: types,
      maximumFiles: math.min(maximumFiles, other.maximumFiles),
      maximumBytesPerFile:
          math.min(maximumBytesPerFile, other.maximumBytesPerFile),
      maximumTotalBytes: math.min(maximumTotalBytes, other.maximumTotalBytes),
      maximumImageBytes: math.min(maximumImageBytes, other.maximumImageBytes),
      maximumDocumentFiles:
          math.min(maximumDocumentFiles, other.maximumDocumentFiles),
      maximumDocumentBytes:
          math.min(maximumDocumentBytes, other.maximumDocumentBytes),
    );
  }

  static HandrailAttachmentLimits? fromCapabilities(
      Map<String, Object?>? attachments, Map<String, Object?>? documents,
      {int maximumTotalBytes = 20 * 1024 * 1024}) {
    if (attachments == null) return null;
    final types = attachments['acceptedMediaTypes'],
        count = attachments['maximumFiles'],
        bytes = attachments['maximumBytesPerFile'];
    if (types is! List || count is! int || bytes is! int) return null;
    final documentTypes = documents?['supported_mime_types'];
    final allowed = handrailAttachmentMediaTypes.values
        .where((type) =>
            types.any((candidate) =>
                candidate == type ||
                candidate == 'image/*' && type.startsWith('image/')) &&
            (type.startsWith('image/') ||
                documentTypes is List && documentTypes.contains(type)))
        .toSet();
    if (allowed.isEmpty) return null;
    try {
      return HandrailAttachmentLimits(
          acceptedMediaTypes: allowed,
          maximumFiles: count,
          maximumBytesPerFile: bytes,
          maximumTotalBytes: maximumTotalBytes,
          maximumDocumentFiles: documents?['max_document_count'] as int? ?? 0,
          maximumDocumentBytes: documents?['max_document_bytes'] as int? ?? 0);
    } catch (_) {
      return null;
    }
  }

  void validate(Iterable<HandrailAttachmentFile> files) {
    final selected = files.toList();
    if (selected.length > maximumFiles ||
        selected.where((file) => !file.mediaType.startsWith('image/')).length >
            maximumDocumentFiles) {
      throw const HandrailAttachmentException('too_many_files');
    }
    var total = 0;
    for (final file in selected) {
      if (!acceptedMediaTypes.contains(file.mediaType) &&
          file.mediaType == 'application/msword') {
        throw const HandrailAttachmentException('legacy_word_unsupported');
      }
      if (!acceptedMediaTypes.contains(file.mediaType) || file.byteSize == 0)
        throw const HandrailAttachmentException('unsupported_file');
      if (file.byteSize > maximumBytesFor(file.mediaType))
        throw const HandrailAttachmentException('file_too_large');
      total += file.byteSize;
    }
    if (total > maximumTotalBytes)
      throw const HandrailAttachmentException('selection_too_large');
  }
}

class HandrailAttachmentException implements Exception {
  const HandrailAttachmentException(this.code);
  final String code;
  String get message => switch (code) {
        'legacy_word_unsupported' =>
          'Legacy Word (.doc) files are not supported. Save the file as .docx or PDF and attach it again.',
        'too_many_files' => 'Choose fewer files for this message.',
        'file_too_large' ||
        'attachment_too_large' =>
          'This file exceeds the upload limit.',
        'selection_too_large' =>
          'The selected files exceed the total upload limit.',
        'draft_attachment_capacity' =>
          'Files in drafts and active sends have reached the device limit. Finish a send or remove unsent files before adding more.',
        'upload_capacity' =>
          'Other file uploads are still finishing. Wait a moment, then retry.',
        'unsupported_file' ||
        'invalid_attachment' =>
          'Choose a supported, nonempty file.',
        'cancelled' =>
          'File upload cancelled. Send again to retry the same files.',
        'unauthenticated' => 'Sign in again before uploading a file.',
        'forbidden' => 'Your account cannot upload this file.',
        'upload_conflict' =>
          'This upload does not match its saved file. Remove it and select the file again.',
        'invalid_upload_response' =>
          'The uploaded file could not be verified. Remove it and select the file again.',
        _ => 'The file could not be uploaded. Send again to retry.',
      };
  @override
  String toString() => 'HandrailAttachmentException($code)';
}

enum HandrailAttachmentStatus { selected, uploading, ready, failed }

class HandrailAttachmentSelection {
  const HandrailAttachmentSelection(
      {required this.id,
      required this.filename,
      required this.byteSize,
      required this.status,
      this.error});
  final Object id;
  final String filename;
  final int byteSize;
  final HandrailAttachmentStatus status;
  final String? error;
}

abstract interface class HandrailAttachmentDrafts implements Listenable {
  List<HandrailAttachmentSelection> get attachmentSelections;
  bool get pickingAttachments;
  bool get uploadingAttachments;
  bool get attachmentsEnabled;
  String? get attachmentError;
  Future<void> pickAttachments();
  void addPickedAttachments(Iterable<HandrailAttachmentFile> files);
  void removeAttachment(Object id);
  void cancelUploads();
}

Future<List<HandrailAttachmentFile>> pickHandrailAttachments(
    HandrailAttachmentLimits limits) async {
  final picked = await FilePicker.pickFiles(
      type: FileType.custom, allowedExtensions: limits.extensions);
  if (picked.length > limits.maximumFiles)
    throw const HandrailAttachmentException('too_many_files');
  final result = <HandrailAttachmentFile>[];
  var total = 0;
  for (final file in picked) {
    final type = handrailAttachmentMediaTypes[file.extension?.toLowerCase()];
    if (type == null || !limits.acceptedMediaTypes.contains(type))
      throw const HandrailAttachmentException('unsupported_file');
    if (await file.length() > limits.maximumBytesFor(type))
      throw const HandrailAttachmentException('file_too_large');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > limits.maximumBytesFor(type))
        throw const HandrailAttachmentException('file_too_large');
      total += chunk.length;
      if (total > limits.maximumTotalBytes)
        throw const HandrailAttachmentException('selection_too_large');
      bytes.add(chunk);
    }
    result.add(HandrailAttachmentFile(
        fileName: file.name, mediaType: type, bytes: bytes.takeBytes()));
  }
  limits.validate(result);
  return result;
}
