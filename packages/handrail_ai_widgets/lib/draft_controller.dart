import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';

/// A draft whose submission lifecycle is independent of response observation.
/// Create one per authenticated composer, and [reset] when its scope changes.
class HandrailDraftController extends TextEditingController {
  HandrailDraftController({
    String text = '',
    this.onDraftChanged,
    this.readDraft,
    this.writeDraft,
    this.validateDraft,
  }) : _lastText = text,
       super(text: text) {
    addListener(_observeDraft);
    if ((readDraft == null) != (writeDraft == null)) {
      throw ArgumentError('Draft storage requires both read and write');
    }
    _initial = readDraft == null ? Future.value() : _restore();
  }

  final Future<Map<String, Object?>?> Function()? readDraft;

  /// Return an actionable error to reject an edit before its text/revision or
  /// stored version changes. Empty text is always allowed so removal can free
  /// capacity. Hosts should surface [draftInputError] next to the editor.
  final String? Function(String text)? validateDraft;
  String? _inputError;
  String? get draftInputError => _inputError;

  bool _allowsText(String text) {
    final error = text.isEmpty ? null : validateDraft?.call(text);
    final changed = _inputError != error;
    _inputError = error;
    if (changed && !_disposed) notifyListeners();
    return error == null;
  }

  @override
  set value(TextEditingValue next) {
    if (next.text != super.value.text && !_allowsText(next.text)) return;
    super.value = next;
  }

  final Future<Map<String, Object?>?> Function(String text, String? version)?
  writeDraft;
  String? _version, _storageError;
  String? _persistingText;

  /// Immutable snapshot held by the active storage callback, for account-wide
  /// retention accounting even after the visible editor changes or closes.
  String? get persistingDraftText => _persistingText;
  bool _loaded = false, _saving = false, _restoring = false;
  int _edit = 0, _savedEdit = 0;
  Timer? _saveTimer;
  late final Future<void> _initial;
  Future<void>? _writing, _closed;
  bool get restoringDraft =>
      readDraft != null && !_loaded && _storageError == null;
  bool get savingDraft => _saving;
  String? get draftStorageError => _storageError;
  bool get hasPendingSubmission => _pendingAttempt != null;
  bool get draftIsDurable =>
      readDraft != null &&
      _loaded &&
      _savedEdit == _edit &&
      _storageError == null;

  Map<String, Object?>? _parseDraft(Map<String, Object?>? value) {
    if (value == null) return null;
    final version = value['version'], text = value['text'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 128 ||
        text is! String ||
        utf8.encode(text).length > 65536) {
      throw const FormatException('Invalid saved draft');
    }
    return {'version': version, 'text': text};
  }

  Future<void> _restore() async {
    try {
      final saved = _parseDraft(await readDraft!());
      final restored = saved?['text'] as String?;
      if (_edit == 0 && restored != null && !_allowsText(restored)) {
        throw StateError('Draft capacity reached');
      }
      _version = saved?['version'] as String?;
      _loaded = true;
      _storageError = null;
      if (_edit == 0) {
        if (saved != null) {
          _lastText = saved['text'] as String;
          if (!_disposed) {
            _restoring = true;
            text = _lastText;
            _restoring = false;
          }
        } else if (_lastText.isNotEmpty) {
          _edit++;
        }
      }
      if (!_disposed && _edit != _savedEdit) _scheduleSave();
    } catch (_) {
      _storageError =
          'The saved draft could not be opened. Retry before closing this chat.';
    }
    if (!_disposed) notifyListeners();
  }

  void _scheduleSave() {
    if (writeDraft == null || _disposed) return;
    _saving = true;
    _storageError = null;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      _saveTimer = null;
      unawaited(flushDraft().catchError((Object _) {}));
    });
  }

  /// Capture the exact edit at activation, before uploads or network writes.
  int get draftEdit => _edit;
  Future<String?> captureVersion(int edit) async {
    await flushDraft();
    return _edit == edit && _savedEdit == edit ? _version : null;
  }

  /// Confirmed server admission only. A matching text value is insufficient:
  /// only this saved revision may be deleted, preserving all newer local work.
  Future<void> reconcileAcceptedVersion(String version) {
    if (_disposed || readDraft == null || writeDraft == null) {
      return Future.error(StateError('Draft owner is unavailable'));
    }
    _saveTimer?.cancel();
    _saveTimer = null;
    final previous = _writing;
    late final Future<void> work;
    work =
        Future<void>.microtask(() async {
              await previous?.catchError((Object _) {});
              await _initial;
              var outcome = 'removed';
              try {
                await writeDraft!('', version);
              } catch (_) {
                final current = _parseDraft(await readDraft!());
                if (current?['version'] == version) rethrow;
                outcome = current == null ? 'absent' : 'changed';
              }
              if (_version != version) return;
              if (outcome != 'changed') _version = null;
              if (_savedEdit == _edit) {
                _edit++;
                _savedEdit = _edit;
                _revision++;
                _pendingAttempt = null;
                _lastText = '';
                if (!_disposed) {
                  _restoring = true;
                  text = '';
                  _restoring = false;
                }
                _saving = false;
                _storageError = outcome == 'changed'
                    ? 'The saved draft changed in another view. Reload it before editing.'
                    : null;
              }
            })
            .catchError((Object error) {
              _storageError =
                  'The message was accepted, but its local draft could not be cleared. Retry the saved message.';
              throw error;
            })
            .whenComplete(() {
              if (identical(_writing, work)) {
                _writing = null;
                if (!_disposed && _edit != _savedEdit) _scheduleSave();
              }
              if (!_disposed) notifyListeners();
            });
    _writing = work;
    return work;
  }

  /// Flush captured text before releasing the account's encrypted store.
  Future<void> flushDraft() => _closed ?? _flushDraft();
  Future<void> _flushDraft() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (writeDraft == null) return Future.value();
    if (_writing case final current?) {
      return current.then((_) async {
        if (_savedEdit != _edit) await _flushDraft();
      });
    }
    late final Future<void> work;
    work =
        Future<void>.microtask(() async {
              await _initial;
              if (!_loaded) await _restore();
              if (!_loaded) throw StateError('Draft storage unavailable');
              while (_savedEdit != _edit) {
                final currentText = _lastText, edit = _edit;
                if (utf8.encode(currentText).length > 65536) {
                  throw StateError('Draft exceeds 64 KiB');
                }
                _persistingText = currentText;
                try {
                  final saved = _parseDraft(
                    await writeDraft!(currentText, _version),
                  );
                  _version = saved?['version'] as String?;
                  _savedEdit = edit;
                } finally {
                  _persistingText = null;
                }
              }
              _saving = false;
              _storageError = null;
            })
            .catchError((Object error) {
              _saving = false;
              _storageError =
                  'This draft could not be saved on this device. Keep this chat open and retry, or explicitly reload the saved draft.';
              throw error;
            })
            .whenComplete(() {
              if (identical(_writing, work)) _writing = null;
              if (!_disposed) notifyListeners();
            });
    _writing = work;
    return work;
  }

  /// Explicit replacement only. Late reads cannot erase newer typing.
  Future<void> reloadSavedDraft() async {
    if (readDraft == null || _disposed) return;
    _saveTimer?.cancel();
    _saveTimer = null;
    await _writing?.catchError((Object _) {});
    final edit = _edit;
    final saved = _parseDraft(await readDraft!());
    if (_disposed || edit != _edit) return;
    final restored = saved?['text'] as String? ?? '';
    if (!_allowsText(restored)) throw StateError('Draft capacity reached');
    _saveTimer?.cancel();
    _saveTimer = null;
    _version = saved?['version'] as String?;
    _loaded = true;
    _saving = false;
    _storageError = null;
    _edit++;
    _savedEdit = _edit;
    _restoring = true;
    _lastText = restored;
    text = _lastText;
    _restoring = false;
    _revision++;
    _pendingAttempt = null;
    notifyListeners();
  }

  /// Completes after dispose has flushed captured edits and evicted local text.
  Future<void> get closed => _closed ?? Future.value();

  final ValueChanged<String>? onDraftChanged;
  String _lastText;
  int _revision = 0;
  Object? _submission;
  _DraftAttempt? _pendingAttempt;
  bool _disposed = false;

  bool get isSubmitting => _submission != null;

  void _observeDraft() {
    if (_restoring || _lastText == text) return;
    _lastText = text;
    _revision++;
    _edit++;
    _scheduleSave();
    onDraftChanged?.call(text);
  }

  /// Captures one edit revision. Forward [accepted] to the SDK session's
  /// onAccepted callback; completion/failure never clears a newer draft.
  /// Returns null for a duplicate submission. Errors retain their original type.
  Future<T?> submit<T>(
    Future<T> Function(String text, VoidCallback accepted) send,
  ) async {
    if (_disposed || isSubmitting || restoringDraft) return null;
    final attempt = _pendingAttempt = _DraftAttempt(_revision);
    final submittedText = text;
    return _execute(attempt, (accepted) => send(submittedText, accepted));
  }

  /// Reconciles the saved submission without treating the current draft as a
  /// new message. An unchanged original draft clears on admission; later edits
  /// and drafts restored without their original submission identity survive.
  Future<T?> retry<T>(Future<T> Function(VoidCallback accepted) send) async {
    if (_disposed || isSubmitting) return null;
    return _execute(_pendingAttempt, send);
  }

  /// Captures the original draft identity for account-owned recovery on reopen.
  /// A newer submission or edit cannot be cleared by this acknowledgement.
  VoidCallback capturePendingAcceptance() {
    final attempt = _pendingAttempt;
    return () {
      if (_disposed || attempt == null || !identical(_pendingAttempt, attempt))
        return;
      _pendingAttempt = null;
      if (_revision == attempt.revision) clear();
    };
  }

  Future<T?> _execute<T>(
    _DraftAttempt? attempt,
    Future<T> Function(VoidCallback accepted) send,
  ) async {
    final token = _submission = Object();
    var admitted = false;
    notifyListeners();
    try {
      return await send(() {
        if (_disposed || !identical(_submission, token) || admitted) return;
        admitted = true;
        if (attempt != null && identical(_pendingAttempt, attempt)) {
          _pendingAttempt = null;
          if (_revision == attempt.revision) clear();
        }
      });
    } finally {
      if (!_disposed && identical(_submission, token)) {
        _submission = null;
        notifyListeners();
      }
    }
  }

  /// Invalidates callbacks from the previous conversation/account immediately.
  void reset({String text = ''}) {
    if (_disposed || !_allowsText(text)) return;
    final changed = _lastText != text;
    _submission = null;
    _pendingAttempt = null;
    _revision++;
    _edit++;
    _lastText = text;
    _scheduleSave();
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (changed) onDraftChanged?.call(text);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _submission = null;
    _pendingAttempt = null;
    removeListener(_observeDraft);
    _closed = _flushDraft().catchError((Object _) {}).whenComplete(() {
      _lastText = '';
      _version = null;
    });
    // TextEditingValue must be cleared before ChangeNotifier is disposed.
    value = TextEditingValue.empty;
    super.dispose();
  }
}

class _DraftAttempt {
  const _DraftAttempt(this.revision);
  final int revision;
}
