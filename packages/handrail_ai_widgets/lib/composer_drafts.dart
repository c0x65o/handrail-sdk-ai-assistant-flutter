import 'dart:async';
import 'dart:math';
import 'attachments.dart';
import 'package:flutter/foundation.dart';
import 'draft_controller.dart';
import 'workspace_binding.dart';

/// Account-scoped drafts and file selections, retained independently per chat.
/// Hosts supply attachment validation/upload and the authenticated send adapter.
/// Dispose this workspace when the authenticated account changes.
class HandrailComposerDrafts<TAttachment> extends ChangeNotifier
    implements HandrailAttachmentDrafts {
  HandrailComposerDrafts(
      {this.fileForAttachment,
      this.attachmentForFile,
      this.limitsForConversation,
      this.uploaderForConversation,
      this.filePicker});
  final HandrailAttachmentFile Function(TAttachment)? fileForAttachment;
  final TAttachment Function(HandrailAttachmentFile)? attachmentForFile;
  final HandrailAttachmentLimits? Function(String?)? limitsForConversation;
  final HandrailAttachmentUploader? Function(String?)? uploaderForConversation;
  final Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)?
      filePicker;
  HandrailAttachmentLimits? get attachmentLimits =>
      limitsForConversation?.call(_selectedId);
  @override
  bool get attachmentsEnabled =>
      !_disposed &&
      _selectedId != null &&
      attachmentLimits != null &&
      uploaderForConversation?.call(_selectedId) != null &&
      fileForAttachment != null &&
      attachmentForFile != null;
  @override
  bool get pickingAttachments => _selected.picking;
  @override
  bool get uploadingAttachments => _selected.uploading;
  @override
  String? get attachmentError => _selected.attachmentError;
  @override
  List<HandrailAttachmentSelection> get attachmentSelections => [
        if (fileForAttachment != null)
          for (final file in _selected.files)
            HandrailAttachmentSelection(
                id: file,
                filename: fileForAttachment!(file.value).displayName,
                byteSize: fileForAttachment!(file.value).byteSize,
                status: file.status,
                error: file.error?.message),
      ];
  final _drafts = <String?, _ConversationDraft<TAttachment>>{};
  String? _selectedId;
  bool _disposed = false;

  String? get selectedId => _selectedId;
  _ConversationDraft<TAttachment> get _selected =>
      _drafts.putIfAbsent(_selectedId, () {
        final draft = _ConversationDraft<TAttachment>();
        draft.controller.addListener(_changed);
        return draft;
      });
  HandrailDraftController get controller => _selected.controller;
  List<TAttachment> get attachments =>
      List.unmodifiable(_selected.files.map((file) => file.value));
  bool get isSubmitting => controller.isSubmitting;
  Set<String> get draftConversationIds => Set.unmodifiable({
        for (final entry in _drafts.entries)
          if (entry.key != null && entry.value.hasDraft) entry.key!,
      });
  bool get hasOtherDrafts => _drafts.entries
      .any((entry) => entry.key != _selectedId && entry.value.hasDraft);
  bool get hasDrafts => _drafts.values.any((draft) => draft.hasDraft);

  /// Includes work in drafts that are not currently selected.
  bool get isWorking => _drafts.values.any((draft) =>
      draft.picking || draft.uploading || draft.controller.isSubmitting);

  void select(String? conversationId, {bool adoptUnassignedDraft = false}) {
    if (_disposed || _selectedId == conversationId) return;
    if (adoptUnassignedDraft &&
        _selectedId == null &&
        conversationId != null &&
        !_drafts.containsKey(conversationId)) {
      final initial = _drafts.remove(null);
      if (initial != null) _drafts[conversationId] = initial;
    }
    _selectedId = conversationId;
    _changed();
  }

  void discard(String? conversationId) {
    if (_disposed) return;
    final draft = _drafts.remove(conversationId);
    if (draft != null) {
      _cancelDraft(draft);
      draft.controller.dispose();
    }
    _changed();
  }

  /// Clears unsent account content and invalidates all admission callbacks.
  void clear() {
    if (_disposed) return;
    for (final draft in _drafts.values) {
      _cancelDraft(draft);
      draft.controller.dispose();
    }
    _drafts.clear();
    _changed();
  }

  void addAttachments(Iterable<TAttachment> values) {
    if (_disposed) return;
    final selected = values.toList();
    if (fileForAttachment != null)
      attachmentLimits
          ?.validate([...attachments, ...selected].map(fileForAttachment!));
    _selected.files.addAll(selected.map(_DraftFile.new));
    _selected.attachmentError = null;
    _changed();
  }

  void removeAttachmentAt(int index) {
    if (_disposed || index < 0 || index >= _selected.files.length) return;
    _selected.files.removeAt(index).cancel();
    _selected.attachmentError = null;
    _changed();
  }

  @override
  void removeAttachment(Object id) {
    final index = _selected.files.indexWhere((file) => identical(file, id));
    if (index >= 0) removeAttachmentAt(index);
  }

  @override
  void addPickedAttachments(Iterable<HandrailAttachmentFile> files) {
    if (!attachmentsEnabled || isSubmitting) return;
    try {
      addAttachments(files.map(attachmentForFile!));
    } catch (error) {
      _selected.attachmentError = _safeAttachmentError(error).message;
      _changed();
    }
  }

  @override
  Future<void> pickAttachments() async {
    if (!attachmentsEnabled || isSubmitting || pickingAttachments) return;
    final draft = _selected, limits = attachmentLimits!;
    draft.picking = true;
    draft.attachmentError = null;
    _changed();
    try {
      final files = await (filePicker ?? pickHandrailAttachments)(limits);
      if (_disposed || !identical(draft, _selected) || isSubmitting) return;
      addPickedAttachments(files);
    } catch (error) {
      if (!_disposed && identical(draft, _selected))
        draft.attachmentError = _safeAttachmentError(error).message;
    } finally {
      draft.picking = false;
      _changed();
    }
  }

  @override
  void cancelUploads() {
    _cancelDraft(_selected);
  }

  void _cancelDraft(_ConversationDraft<TAttachment> draft) {
    for (final file in {...draft.files, ...?draft.pendingFiles}) {
      file.cancel();
    }
  }

  /// Uploads a host-rendered selection through the same retained queue.
  /// Reuse the immutable selection objects on retry; discard this conversation
  /// after admission. Replacing a selection creates a new upload identity.
  Future<List<Map<String, Object?>>> prepareAttachments(
      List<TAttachment> values,
      {void Function(double)? onProgress}) async {
    if (_disposed) throw const HandrailAttachmentException('cancelled');
    final draft = _selected;
    if (draft.uploading || draft.controller.isSubmitting) {
      throw const HandrailAttachmentException('upload_in_progress');
    }
    final remaining = List.of(draft.files);
    final selected = <_DraftFile<TAttachment>>[];
    for (final value in values) {
      final index =
          remaining.indexWhere((file) => identical(file.value, value));
      selected.add(index < 0 ? _DraftFile(value) : remaining.removeAt(index));
    }
    for (final file in remaining) {
      file.cancel();
    }
    draft.files
      ..clear()
      ..addAll(selected);
    return _upload(draft, selected, uploaderForConversation?.call(_selectedId),
        attachmentLimits,
        onProgress: onProgress);
  }

  /// Retains each upload identity/reference until durable message admission.
  /// Text and approval/route metadata may be captured by the host at activation.
  Future<TResult?> submitWithAttachments<TResult>(
      Future<TResult> Function(String text,
              List<Map<String, Object?>> references, VoidCallback accepted)
          send) async {
    if (_disposed || isSubmitting || pickingAttachments) return null;
    final draft = _selected;
    final files = draft.pendingFiles = List.of(draft.files);
    final upload = uploaderForConversation?.call(_selectedId);
    final limits = attachmentLimits;
    return _run(
        draft,
        (token) => draft.controller.submit((text, accepted) async {
              final references = await _upload(draft, files, upload, limits);
              if (_disposed || !_drafts.containsValue(draft))
                throw const HandrailAttachmentException('cancelled');
              return send(text, references,
                  () => _acceptFiles(draft, files, token, accepted));
            }));
  }

  Future<List<Map<String, Object?>>> _upload(
      _ConversationDraft<TAttachment> draft,
      List<_DraftFile<TAttachment>> files,
      HandrailAttachmentUploader? upload,
      HandrailAttachmentLimits? limits,
      {void Function(double)? onProgress}) async {
    if (files.isEmpty) return const [];
    draft.uploading = true;
    draft.attachmentError = null;
    _changed();
    try {
      if (upload == null || limits == null || fileForAttachment == null)
        throw const HandrailAttachmentException('unsupported_file');
      limits.validate(files.map((file) => fileForAttachment!(file.value)));
      final references = <Map<String, Object?>>[];
      for (final file in files) {
        if (_disposed ||
            !_drafts.containsValue(draft) ||
            !draft.files.contains(file))
          throw const HandrailAttachmentException('cancelled');
        if (file.reference == null) {
          if (file.error != null && !file.retryable) throw file.error!;
          final data = fileForAttachment!(file.value);
          final abort = file.abort = Completer<void>();
          file.status = HandrailAttachmentStatus.uploading;
          file.error = null;
          _changed();
          try {
            final result = await Future.any([
              upload(
                  bytes: data.bytes,
                  filename: data.displayName,
                  mediaType: data.mediaType,
                  idempotencyKey: file.uploadKey,
                  cancellation: abort.future),
              abort.future.then<
                      ({
                        Map<String, Object?>? reference,
                        String? errorCode,
                        bool retryable
                      })>(
                  (_) => throw const HandrailAttachmentException('cancelled')),
            ]);
            if (abort.isCompleted ||
                _disposed ||
                !_drafts.containsValue(draft) ||
                !draft.files.contains(file))
              throw const HandrailAttachmentException('cancelled');
            if (result.reference == null) {
              file.retryable = result.retryable;
              throw HandrailAttachmentException(
                  _safeUploadCode(result.errorCode));
            }
            final value = result.reference!;
            if (value['media_type'] != data.mediaType ||
                value['byte_size'] != data.byteSize ||
                value['attachment_id'] is! String ||
                value['content_ref'] is! String) {
              file.retryable = false;
              throw const HandrailAttachmentException(
                  'invalid_upload_response');
            }
            file.reference = Map.unmodifiable(value);
            file.status = HandrailAttachmentStatus.ready;
          } catch (error) {
            file.error = _safeAttachmentError(error);
            if (file.error!.code == 'cancelled') file.retryable = true;
            file.status = HandrailAttachmentStatus.failed;
            throw file.error!;
          } finally {
            if (identical(file.abort, abort)) file.abort = null;
            _changed();
          }
        }
        references.add(file.reference!);
        onProgress?.call(references.length / files.length);
      }
      return List.unmodifiable(references);
    } catch (error) {
      final failure = _safeAttachmentError(error);
      draft.attachmentError = failure.message;
      throw failure;
    } finally {
      draft.uploading = false;
      _changed();
    }
  }

  Future<TResult?> submit<TResult>(
      Future<TResult> Function(
              String text, List<TAttachment> attachments, VoidCallback accepted)
          send) async {
    if (_disposed || isSubmitting) return null;
    final draft = _selected;
    final files = draft.pendingFiles = List.of(draft.files);
    return _run(
        draft,
        (token) => draft.controller.submit((text, accepted) => send(
            text,
            List.unmodifiable(files.map((file) => file.value)),
            () => _acceptFiles(draft, files, token, accepted))));
  }

  Future<TResult?> retry<TResult>(
      Future<TResult> Function(VoidCallback accepted) send) async {
    if (_disposed || isSubmitting) return null;
    final draft = _selected;
    final files = draft.pendingFiles;
    return _run(
        draft,
        (token) => draft.controller.retry((accepted) =>
            send(() => _acceptFiles(draft, files, token, accepted))));
  }

  /// Bind to a shared client controller's beforePendingRecovery hook. This does
  /// not select the recovering conversation or adopt the currently visible draft.
  VoidCallback capturePendingAcceptance(String conversationId) {
    final draft = _drafts[conversationId];
    if (_disposed || draft == null) return () {};
    final files = draft.pendingFiles;
    final accepted = draft.controller.capturePendingAcceptance();
    return () {
      if (_disposed ||
          !_drafts.containsValue(draft) ||
          !identical(draft.pendingFiles, files)) return;
      accepted();
      draft.pendingFiles = null;
      if (files != null) {
        for (final file in files) {
          file.cancel();
        }
        draft.files.removeWhere(files.contains);
      }
      draft.attachmentError = null;
      _changed();
    };
  }

  Future<TResult?> _run<TResult>(_ConversationDraft<TAttachment> draft,
      Future<TResult?> Function(Object token) operation) async {
    final token = draft.activeSubmission = Object();
    try {
      return await operation(token);
    } finally {
      if (identical(draft.activeSubmission, token))
        draft.activeSubmission = null;
    }
  }

  void _acceptFiles(
      _ConversationDraft<TAttachment> draft,
      List<_DraftFile<TAttachment>>? files,
      Object token,
      VoidCallback accepted) {
    if (_disposed ||
        !_drafts.containsValue(draft) ||
        !identical(draft.activeSubmission, token)) return;
    accepted();
    if (files != null && identical(draft.pendingFiles, files)) {
      draft.pendingFiles = null;
      // Remove exact selections. A removed/re-added identical file is a new
      // selection and must survive, just like an identical later text edit.
      for (final file in files) {
        file.cancel();
      }
      draft.files.removeWhere(files.contains);
      draft.attachmentError = null;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final draft in _drafts.values) {
      _cancelDraft(draft);
      draft.controller.dispose();
    }
    _drafts.clear();
    super.dispose();
  }
}

class _ConversationDraft<T> {
  final controller = HandrailDraftController();
  final files = <_DraftFile<T>>[];
  List<_DraftFile<T>>? pendingFiles;
  Object? activeSubmission;
  bool picking = false, uploading = false;
  String? attachmentError;
  bool get hasDraft => controller.text.isNotEmpty || files.isNotEmpty;
}

class _DraftFile<T> {
  _DraftFile(this.value);
  final T value;
  final String uploadKey =
      'upload-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  Map<String, Object?>? reference;
  HandrailAttachmentStatus status = HandrailAttachmentStatus.selected;
  HandrailAttachmentException? error;
  bool retryable = true;
  Completer<void>? abort;
  void cancel() {
    if (abort?.isCompleted == false) abort!.complete();
  }
}

String _safeUploadCode(String? code) => const {
      'cancelled',
      'unauthenticated',
      'forbidden',
      'attachment_too_large',
      'invalid_attachment',
      'upload_conflict',
      'invalid_upload_response',
      'upload_unavailable',
      'upload_timeout',
      'rate_limited'
    }.contains(code)
        ? code!
        : 'upload_unavailable';
HandrailAttachmentException _safeAttachmentError(Object error) =>
    error is HandrailAttachmentException
        ? error
        : const HandrailAttachmentException('upload_unavailable');

/// Complete standard draft/file queue; hosts supply negotiated limits and an authenticated uploader.
class HandrailComposerController
    extends HandrailComposerDrafts<HandrailAttachmentFile> {
  HandrailComposerController(
      {required super.limitsForConversation,
      required super.uploaderForConversation,
      super.filePicker})
      : super(
            fileForAttachment: (file) => file,
            attachmentForFile: (file) => file);

  /// Retains account drafts and binds selection and upload negotiation to the
  /// SDK's optional UI surface. Dispose when the authenticated account ends.
  factory HandrailComposerController.forAssistant(
      HandrailWorkspaceBinding binding,
      {HandrailAttachmentLimits? attachmentLimits,
      Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)?
          filePicker}) {
    final drafts = HandrailComposerController(
      limitsForConversation: (id) {
        final capabilities = binding.capabilitiesFor(id);
        final negotiated = HandrailAttachmentLimits.fromCapabilities(
            capabilities['attachments'] as Map<String, Object?>?,
            capabilities['documentInput'] as Map<String, Object?>?);
        return attachmentLimits == null
            ? negotiated
            : negotiated?.intersect(attachmentLimits);
      },
      uploaderForConversation: binding.uploaderFor,
      filePicker: filePicker,
    );
    void select() => drafts.select(binding.read()['conversationId'] as String?,
        adoptUnassignedDraft: true);
    drafts._assistantSubscription = binding.changes.listen((_) => select());
    select();
    return drafts;
  }

  StreamSubscription<Object?>? _assistantSubscription;
  @override
  void dispose() {
    unawaited(_assistantSubscription?.cancel());
    _assistantSubscription = null;
    super.dispose();
  }
}
