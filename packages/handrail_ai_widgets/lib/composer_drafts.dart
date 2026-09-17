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
  HandrailComposerDrafts({
    this.fileForAttachment,
    this.attachmentForFile,
    this.limitsForConversation,
    this.uploaderForConversation,
    this.filePicker,
    this.readDraft,
    this.writeDraft,
    this.onUploadReleased,
  });
  final Future<Map<String, Object?>?> Function(String conversationId)?
  readDraft;
  final Future<Map<String, Object?>?> Function(
    String conversationId,
    String text,
    String? version,
  )?
  writeDraft;
  final HandrailAttachmentFile Function(TAttachment)? fileForAttachment;
  final TAttachment Function(HandrailAttachmentFile)? attachmentForFile;
  final HandrailAttachmentLimits? Function(String?)? limitsForConversation;
  final HandrailAttachmentUploader? Function(String?)? uploaderForConversation;
  final Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)?
  filePicker;

  /// Releases a host upload's retained local state after removal, admission or
  /// account disposal. Stop retains the identity for retry and does not release
  /// it. This callback must not delete remote business or attachment objects.
  final void Function(String idempotencyKey)? onUploadReleased;
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
          error: file.error?.message,
        ),
  ];
  final _drafts = <String?, _ConversationDraft<TAttachment>>{};
  final _closing = <String?, Future<void>>{};
  String? _selectedId;
  bool _disposed = false;

  String? get selectedId => _selectedId;
  _ConversationDraft<TAttachment> get _selected =>
      _drafts.putIfAbsent(_selectedId, () => _createDraft(_selectedId));
  _ConversationDraft<TAttachment> _createDraft(String? id) {
    final previous = _closing[id];
    final controller = HandrailDraftController(
      readDraft: id == null || readDraft == null
          ? null
          : () async {
              await previous;
              return readDraft!(id);
            },
      writeDraft: id == null || writeDraft == null
          ? null
          : (text, version) => writeDraft!(id, text, version),
    );
    controller.addListener(_changed);
    return _ConversationDraft<TAttachment>(controller);
  }

  void _closeDraft(
    String? id,
    _ConversationDraft<TAttachment> draft, {
    bool discard = false,
  }) {
    draft.controller.removeListener(_changed);
    _releaseDraft(draft);
    if (discard) draft.controller.reset();
    draft.controller.dispose();
    final closing = draft.controller.closed;
    _closing[id] = closing;
    unawaited(
      closing.whenComplete(() {
        if (identical(_closing[id], closing)) _closing.remove(id);
      }),
    );
  }

  /// Await before the host closes its encrypted account storage. Ordinary
  /// disposal preserves persisted drafts; explicit discard removes one.
  Future<void> get closed => Future.wait(_closing.values).then((_) {});
  Future<void> flushDrafts() async {
    await Future.wait(
      _drafts.values.map((draft) => draft.controller.flushDraft()),
    );
    await closed;
  }

  HandrailDraftController get controller => _selected.controller;
  List<TAttachment> get attachments =>
      List.unmodifiable(_selected.files.map((file) => file.value));
  bool get isSubmitting => controller.isSubmitting;
  Set<String> get draftConversationIds => Set.unmodifiable({
    for (final entry in _drafts.entries)
      if (entry.key != null && entry.value.hasDraft) entry.key!,
  });
  bool get hasOtherDrafts => _drafts.entries.any(
    (entry) => entry.key != _selectedId && entry.value.hasDraft,
  );
  bool get hasDrafts => _drafts.values.any((draft) => draft.hasDraft);

  /// Includes work in drafts that are not currently selected.
  bool get isWorking => _drafts.values.any(
    (draft) =>
        draft.picking || draft.uploading || draft.controller.isSubmitting,
  );

  void select(String? conversationId, {bool adoptUnassignedDraft = false}) {
    if (_disposed || _selectedId == conversationId) return;
    if (adoptUnassignedDraft &&
        _selectedId == null &&
        conversationId != null &&
        !_drafts.containsKey(conversationId)) {
      final initial = _drafts.remove(null);
      if (initial != null) {
        if (readDraft != null && writeDraft != null) {
          final assigned = _createDraft(conversationId);
          assigned.controller.reset(text: initial.controller.text);
          assigned.files.addAll(initial.files);
          initial.files.clear();
          _closeDraft(null, initial);
          _drafts[conversationId] = assigned;
        } else {
          _drafts[conversationId] = initial;
        }
      }
    }
    _selectedId = conversationId;
    _drafts.putIfAbsent(conversationId, () => _createDraft(conversationId));
    _trimDrafts();
    _changed();
  }

  void discard(String? conversationId) {
    if (_disposed) return;
    final draft =
        _drafts.remove(conversationId) ??
        (conversationId != null && readDraft != null
            ? _createDraft(conversationId)
            : null);
    if (draft != null) {
      _closeDraft(conversationId, draft, discard: true);
    }
    _changed();
  }

  /// Clears unsent account content and invalidates all admission callbacks.
  void clear() {
    if (_disposed) return;
    for (final entry in _drafts.entries) {
      _closeDraft(entry.key, entry.value, discard: true);
    }
    _drafts.clear();
    _changed();
  }

  void addAttachments(Iterable<TAttachment> values) {
    if (_disposed) return;
    final selected = values.toList();
    if (fileForAttachment != null)
      attachmentLimits?.validate(
        [...attachments, ...selected].map(fileForAttachment!),
      );
    _selected.files.addAll(selected.map(_DraftFile.new));
    _selected.attachmentError = null;
    _changed();
  }

  void removeAttachmentAt(int index) {
    if (_disposed || index < 0 || index >= _selected.files.length) return;
    _releaseFile(_selected.files.removeAt(index));
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
  Future<void> pickAttachments() =>
      pickAttachmentsUsing(filePicker ?? pickHandrailAttachments);

  /// A view may supply a native source menu without owning selection state or
  /// admitting a late picker result into another conversation/account.
  Future<void> pickAttachmentsUsing(
    Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)
    picker,
  ) async {
    if (!attachmentsEnabled || isSubmitting || pickingAttachments) return;
    final draft = _selected, limits = attachmentLimits!;
    draft.picking = true;
    draft.attachmentError = null;
    _changed();
    try {
      final files = await picker(limits);
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

  void _releaseFile(_DraftFile<TAttachment> file) {
    file.cancel();
    if (file.released) return;
    file.released = true;
    try {
      onUploadReleased?.call(file.uploadKey);
    } catch (_) {
      // Local cleanup failures cannot undo durable admission or prevent the
      // remaining files from being released. The account also owns disposal.
    }
  }

  void _releaseDraft(_ConversationDraft<TAttachment> draft) {
    for (final file in {...draft.files, ...?draft.pendingFiles}) {
      _releaseFile(file);
    }
  }

  /// Uploads a host-rendered selection through the same retained queue.
  /// Reuse the immutable selection objects on retry; discard this conversation
  /// after admission. Replacing a selection creates a new upload identity.
  Future<List<Map<String, Object?>>> prepareAttachments(
    List<TAttachment> values, {
    void Function(double)? onProgress,
  }) async {
    if (_disposed) throw const HandrailAttachmentException('cancelled');
    final draft = _selected;
    if (draft.uploading || draft.controller.isSubmitting) {
      throw const HandrailAttachmentException('upload_in_progress');
    }
    final remaining = List.of(draft.files);
    final selected = <_DraftFile<TAttachment>>[];
    for (final value in values) {
      final index = remaining.indexWhere(
        (file) => identical(file.value, value),
      );
      selected.add(index < 0 ? _DraftFile(value) : remaining.removeAt(index));
    }
    for (final file in remaining) {
      _releaseFile(file);
    }
    draft.files
      ..clear()
      ..addAll(selected);
    return _upload(
      draft,
      selected,
      uploaderForConversation?.call(_selectedId),
      attachmentLimits,
      onProgress: onProgress,
    );
  }

  /// Retains each upload identity/reference until durable message admission.
  /// Text and approval/route metadata may be captured by the host at activation.
  Future<TResult?> submitWithAttachments<TResult>(
    Future<TResult> Function(
      String text,
      List<Map<String, Object?>> references,
      VoidCallback accepted,
    )
    send,
  ) async {
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
        return send(
          text,
          references,
          () => _acceptFiles(draft, files, token, accepted),
        );
      }),
    );
  }

  Future<List<Map<String, Object?>>> _upload(
    _ConversationDraft<TAttachment> draft,
    List<_DraftFile<TAttachment>> files,
    HandrailAttachmentUploader? upload,
    HandrailAttachmentLimits? limits, {
    void Function(double)? onProgress,
  }) async {
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
                cancellation: abort.future,
              ),
              abort.future.then<
                ({
                  Map<String, Object?>? reference,
                  String? errorCode,
                  bool retryable,
                })
              >((_) => throw const HandrailAttachmentException('cancelled')),
            ]);
            if (abort.isCompleted ||
                _disposed ||
                !_drafts.containsValue(draft) ||
                !draft.files.contains(file))
              throw const HandrailAttachmentException('cancelled');
            if (result.reference == null) {
              file.retryable = result.retryable;
              throw HandrailAttachmentException(
                _safeUploadCode(result.errorCode),
              );
            }
            final value = result.reference!;
            if (value['media_type'] != data.mediaType ||
                value['byte_size'] != data.byteSize ||
                value['attachment_id'] is! String ||
                value['content_ref'] is! String) {
              file.retryable = false;
              throw const HandrailAttachmentException(
                'invalid_upload_response',
              );
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
      String text,
      List<TAttachment> attachments,
      VoidCallback accepted,
    )
    send,
  ) async {
    if (_disposed || isSubmitting) return null;
    final draft = _selected;
    final files = draft.pendingFiles = List.of(draft.files);
    return _run(
      draft,
      (token) => draft.controller.submit(
        (text, accepted) => send(
          text,
          List.unmodifiable(files.map((file) => file.value)),
          () => _acceptFiles(draft, files, token, accepted),
        ),
      ),
    );
  }

  Future<TResult?> retry<TResult>(
    Future<TResult> Function(VoidCallback accepted) send,
  ) async {
    if (_disposed || isSubmitting) return null;
    final draft = _selected;
    final files = draft.pendingFiles;
    return _run(
      draft,
      (token) => draft.controller.retry(
        (accepted) => send(() => _acceptFiles(draft, files, token, accepted)),
      ),
    );
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
          !identical(draft.pendingFiles, files))
        return;
      accepted();
      draft.pendingFiles = null;
      if (files != null) {
        for (final file in files) {
          _releaseFile(file);
        }
        draft.files.removeWhere(files.contains);
      }
      draft.attachmentError = null;
      _changed();
    };
  }

  Future<TResult?> _run<TResult>(
    _ConversationDraft<TAttachment> draft,
    Future<TResult?> Function(Object token) operation,
  ) async {
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
    VoidCallback accepted,
  ) {
    if (_disposed ||
        !_drafts.containsValue(draft) ||
        !identical(draft.activeSubmission, token))
      return;
    accepted();
    if (files != null && identical(draft.pendingFiles, files)) {
      draft.pendingFiles = null;
      // Remove exact selections. A removed/re-added identical file is a new
      // selection and must survive, just like an identical later text edit.
      for (final file in files) {
        _releaseFile(file);
      }
      draft.files.removeWhere(files.contains);
      draft.attachmentError = null;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) {
      _trimDrafts();
      notifyListeners();
    }
  }

  void _trimDrafts() {
    // Only safely persisted idle text may be evicted. Ambiguous admissions,
    // uploads, and failed saves retain the user's recoverable local work.
    for (final entry in _drafts.entries.toList()) {
      if (_drafts.length <= 8) break;
      final draft = entry.value;
      if (entry.key == _selectedId ||
          draft.picking ||
          draft.uploading ||
          draft.controller.isSubmitting ||
          draft.controller.hasPendingSubmission ||
          draft.files.isNotEmpty ||
          draft.pendingFiles != null ||
          !draft.controller.draftIsDurable)
        continue;
      _drafts.remove(entry.key);
      _closeDraft(entry.key, draft);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _drafts.entries) {
      _closeDraft(entry.key, entry.value);
    }
    _drafts.clear();
    super.dispose();
  }
}

class _ConversationDraft<T> {
  _ConversationDraft(this.controller);
  final HandrailDraftController controller;
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
  bool released = false;
  Completer<void>? abort;
  void cancel() {
    if (abort?.isCompleted == false) abort!.complete();
  }
}

String _safeUploadCode(String? code) =>
    const {
      'cancelled',
      'unauthenticated',
      'forbidden',
      'attachment_too_large',
      'invalid_attachment',
      'upload_conflict',
      'invalid_upload_response',
      'upload_unavailable',
      'upload_timeout',
      'rate_limited',
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
  HandrailComposerController({
    required super.limitsForConversation,
    required super.uploaderForConversation,
    super.filePicker,
    super.readDraft,
    super.writeDraft,
    super.onUploadReleased,
  }) : super(
         fileForAttachment: (file) => file,
         attachmentForFile: (file) => file,
       );

  /// Retains account drafts and binds selection and upload negotiation to the
  /// SDK's optional UI surface. Dispose when the authenticated account ends.
  factory HandrailComposerController.forAssistant(
    HandrailWorkspaceBinding binding, {
    HandrailAttachmentLimits? attachmentLimits,
    HandrailAttachmentProvider? attachmentProvider,
    void Function(String idempotencyKey)? onUploadReleased,
    Future<List<HandrailAttachmentFile>> Function(HandrailAttachmentLimits)?
    filePicker,
  }) {
    final storage = binding.read()['draftStorage'] as Map<String, Object?>?;
    final drafts = HandrailComposerController(
      readDraft:
          storage?['read'] as Future<Map<String, Object?>?> Function(String)?,
      writeDraft:
          storage?['write']
              as Future<Map<String, Object?>?> Function(
                String,
                String,
                String?,
              )?,
      limitsForConversation: (id) {
        final capabilities = binding.capabilitiesFor(id);
        final negotiated = attachmentProvider != null
            ? attachmentProvider.limitsFor(id)
            : HandrailAttachmentLimits.fromCapabilities(
                capabilities['attachments'] as Map<String, Object?>?,
                capabilities['documentInput'] as Map<String, Object?>?,
              );
        return attachmentLimits == null
            ? negotiated
            : negotiated?.intersect(attachmentLimits);
      },
      uploaderForConversation:
          attachmentProvider?.uploaderFor ?? binding.uploaderFor,
      filePicker: filePicker,
      onUploadReleased: (key) {
        try {
          attachmentProvider?.release(key);
        } finally {
          onUploadReleased?.call(key);
        }
      },
    );
    final removed = <String>{};
    void select() {
      final state = binding.read();
      for (final id
          in (state['deletedConversationIds'] as List? ?? const [])
              .cast<String>()) {
        if (removed.add(id)) drafts.discard(id);
      }
      drafts.select(
        state['conversationId'] as String?,
        adoptUnassignedDraft: true,
      );
    }

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
