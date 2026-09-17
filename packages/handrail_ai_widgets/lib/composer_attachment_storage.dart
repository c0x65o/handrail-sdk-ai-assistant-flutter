part of 'composer_drafts.dart';

extension _ComposerAttachmentStorage<T> on HandrailComposerDrafts<T> {
  Future<void> _fileSerial(
    _ConversationDraft<T> draft,
    Future<void> Function() action,
  ) {
    final previous = draft.fileTask;
    final task = () async {
      await previous;
      await action();
    }();
    // The tail is only a serialization barrier. The caller owns the error.
    draft.fileTask = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  Future<void> _restoreFiles(
    _ConversationDraft<T> draft, {
    bool replace = false,
  }) {
    if (attachmentStorage == null ||
        draft.id == null ||
        draft.filesDeleted ||
        draft.filesLoaded && !replace)
      return Future.value();
    if (draft.fileLoading case final loading?) return loading;
    replace = replace || draft.fileReloadRequested;
    late final Future<void> loading;
    loading =
        _fileSerial(draft, () async {
              await draft.previousClosing;
              final row = await attachmentStorage!.read(draft.id!);
              if (draft.filesDeleted) return;
              final version = row?['version'];
              final values = row?['files'] as List? ?? const [];
              if (row != null &&
                  (version is! String ||
                      version.isEmpty ||
                      values.length > maximumRetainedAttachments)) {
                throw const FormatException('Invalid saved file draft');
              }
              final restored = <_DraftFile<T>>[];
              var bytes = 0;
              final identities = <String>{};
              for (final raw in values) {
                final value = Map<String, Object?>.from(raw as Map);
                final id = value['id'],
                    source = value['bytes'],
                    size = value['byteSize'];
                final hash = value['sha256'];
                if (id is! String ||
                    id.isEmpty ||
                    id.length > 256 ||
                    !identities.add(id) ||
                    source is! List<int> ||
                    size is! int ||
                    source.length != size ||
                    size < 1 ||
                    hash is! String ||
                    !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
                  throw const FormatException('Invalid saved file source');
                }
                bytes += size;
                if (bytes > maximumRetainedAttachmentBytes) {
                  throw const HandrailAttachmentException(
                    'draft_attachment_capacity',
                  );
                }
                final data = HandrailAttachmentFile(
                  fileName: value['filename'] as String,
                  mediaType: value['mediaType'] as String,
                  bytes: source,
                );
                final file =
                    _DraftFile<T>(attachmentForFile!(data), uploadKey: id)
                      ..data = data
                      ..sha256 = hash
                      ..persisted = true;
                if (value['reference'] case final Map reference) {
                  file.reference = Map<String, Object?>.unmodifiable(reference);
                  file.status = HandrailAttachmentStatus.ready;
                }
                restored.add(file);
              }
              // Only unassigned-draft adoption can add selections before restoration.
              // It must not silently replace a previously saved conversation's files.
              final next = [...restored, if (!replace) ...draft.files];
              _validateRetainedAttachments(draft, next);
              if (replace) {
                for (final file in draft.files) {
                  _releaseFile(file);
                }
                draft.fileEdit = draft.fileSavedEdit = 0;
              }
              draft.files
                ..clear()
                ..addAll(next);
              draft.fileVersion = version as String?;
              draft.filesLoaded = true;
              draft.fileReloadRequested = false;
              draft.fileStorageError = null;
            })
            .catchError((Object error) {
              draft.fileStorageError =
                  'Saved files could not be restored. Retry or free device storage.';
              throw error;
            })
            .whenComplete(() {
              if (identical(draft.fileLoading, loading))
                draft.fileLoading = null;
              _changed();
              if (draft.filesLoaded &&
                  draft.fileStorageError == null &&
                  draft.fileEdit != draft.fileSavedEdit)
                _scheduleFileSave(draft);
            });
    draft.fileLoading = loading;
    return loading;
  }

  void _filesChanged(_ConversationDraft<T> draft) {
    if (attachmentStorage == null || draft.id == null || draft.filesDeleted)
      return;
    draft.fileEdit++;
    _scheduleFileSave(draft);
  }

  void _scheduleFileSave(_ConversationDraft<T> draft) {
    if (draft.fileStorageError != null ||
        draft.filesDeleted ||
        draft.fileEdit == draft.fileSavedEdit)
      return;
    unawaited(_flushFiles(draft).catchError((Object _) {}));
  }

  Future<void> _flushFiles(
    _ConversationDraft<T> draft, {
    bool retry = false,
  }) async {
    if (attachmentStorage == null || draft.id == null || draft.filesDeleted)
      return;
    if (retry) draft.fileStorageError = null;
    if (draft.fileStorageError != null)
      throw StateError(draft.fileStorageError!);
    await _restoreFiles(draft);
    if (draft.fileWriting case final writing?) return writing;
    if (draft.fileEdit == draft.fileSavedEdit || draft.filesDeleted) return;
    late final Future<void> writing;
    writing =
        _fileSerial(draft, () async {
              while (draft.fileEdit != draft.fileSavedEdit &&
                  !draft.filesDeleted) {
                if (draft.fileStorageError != null)
                  throw StateError(draft.fileStorageError!);
                final edit = draft.fileEdit,
                    files = List<_DraftFile<T>>.of(draft.files);
                final input = [
                  for (final file in files)
                    {
                      'id': file.uploadKey,
                      'filename': _fileData(file).displayName,
                      'mediaType': _fileData(file).mediaType,
                      'byteSize': _fileData(file).byteSize,
                      if (file.sha256 != null) 'sha256': file.sha256,
                      if (!file.persisted) 'bytes': _fileData(file).bytes,
                      if (file.reference != null) 'reference': file.reference,
                    },
                ];
                // Removed/closed selections still count while the storage callback holds
                // their captured bytes. A slow host must not bypass the account budget.
                _operations.add(files);
                try {
                  final reply = await attachmentStorage!.write(
                    draft.id!,
                    input,
                    draft.fileVersion,
                  );
                  final version = reply?['version'];
                  final metadata = reply?['files'] as List? ?? const [];
                  if (files.isEmpty
                      ? reply != null
                      : version is! String ||
                            version.isEmpty ||
                            metadata.length != files.length) {
                    throw const FormatException('Invalid saved file receipt');
                  }
                  for (var i = 0; i < files.length; i++) {
                    final saved = metadata[i] as Map, hash = saved['sha256'];
                    if (saved['id'] != files[i].uploadKey ||
                        hash is! String ||
                        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
                        files[i].sha256 != null && files[i].sha256 != hash) {
                      throw const FormatException(
                        'Saved file identity changed',
                      );
                    }
                    files[i]
                      ..sha256 = hash
                      ..persisted = true;
                  }
                  draft.fileVersion = version as String?;
                  draft.fileSavedEdit = edit;
                  draft.fileStorageError = null;
                } finally {
                  _operations.remove(files);
                }
              }
            })
            .catchError((Object error) {
              draft.fileStorageError =
                  'Files could not be saved. Retry, or replace selections with saved files if another editor changed them.';
              throw error;
            })
            .whenComplete(() {
              if (identical(draft.fileWriting, writing))
                draft.fileWriting = null;
              _changed();
            });
    draft.fileWriting = writing;
    _changed();
    return writing;
  }

  Future<void> _reloadFiles(_ConversationDraft<T> draft) async {
    if (_disposed || draft.uploading || draft.controller.isSubmitting) return;
    await draft.fileTask;
    if (_disposed) return;
    draft.filesLoaded = false;
    draft.fileReloadRequested = true;
    draft.fileStorageError = null;
    final restoring = _restoreFiles(draft, replace: true);
    _changed();
    await restoring;
  }

  Future<void> _closeFiles(
    _ConversationDraft<T> draft, {
    required bool discard,
  }) async {
    try {
      await draft.fileTask;
      if (draft.filesDeleted) return;
      if (discard) {
        await _restoreFiles(draft);
        for (final file in draft.files) {
          _releaseFile(file);
        }
        draft.files.clear();
        draft.fileEdit++;
      } else if (!draft.filesLoaded && draft.fileEdit == 0) {
        return; // Never hydrate an unopened chat merely to dispose its editor.
      }
      await _flushFiles(draft);
    } catch (_) {
      // Match text drafts: disposal joins work but cannot promise a failed host
      // write succeeded. The last committed revision remains recoverable.
    }
  }

  Future<void> _reconcileFiles(
    _ConversationDraft<T> draft,
    Set<String> ids,
  ) async {
    if (ids.isEmpty) return;
    await _fileSerial(draft, () async {
      if (_disposed || draft.filesDeleted)
        throw StateError('Draft owner is closed');
      if (attachmentStorage != null) {
        // No read/hydration for a recovery in a background or unopened chat.
        final receipt = await attachmentStorage!.discardAccepted(
          draft.id!,
          ids.toList(),
        );
        if (draft.filesLoaded) {
          if (receipt['previousVersion'] == draft.fileVersion) {
            draft.fileVersion = receipt['version'] as String?;
          } else {
            // Another writer or uncertain prior commit: do not rebase local
            // edits onto an unseen revision and overwrite that writer's files.
            draft.fileStorageError =
                'Saved files changed in another editor. Replace selections with saved files to continue.';
          }
        }
      }
      final accepted = {
        ...draft.files,
        ...?draft.pendingFiles,
      }.where((file) => ids.contains(file.uploadKey)).toList();
      for (final file in accepted) {
        _releaseFile(file);
      }
      draft.files.removeWhere(accepted.contains);
      if (draft.pendingFiles case final pending?) {
        final remaining = pending
            .where((file) => !ids.contains(file.uploadKey))
            .toList();
        if (remaining.length != pending.length)
          draft.pendingFiles = remaining.isEmpty ? null : remaining;
      }
    });
    _scheduleFileSave(draft);
  }
}
