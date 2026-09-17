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
  }) : _lastText = text,
       super(text: text) {
    addListener(_observeDraft);
    if ((readDraft == null) != (writeDraft == null)) {
      throw ArgumentError('Draft storage requires both read and write');
    }
    _initial = readDraft == null ? Future.value() : _restore();
  }

  final Future<Map<String, Object?>?> Function()? readDraft;
  final Future<Map<String, Object?>?> Function(String text, String? version)?
  writeDraft;
  String? _version, _storageError;
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

  /// Flush captured text before releasing the account's encrypted store.
  Future<void> flushDraft() {
    if (_closed case final closing?) return closing;
    _saveTimer?.cancel();
    _saveTimer = null;
    if (writeDraft == null) return Future.value();
    if (_writing case final current?) return current;
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
                final saved = _parseDraft(
                  await writeDraft!(currentText, _version),
                );
                _version = saved?['version'] as String?;
                _savedEdit = edit;
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
    _saveTimer?.cancel();
    _saveTimer = null;
    _version = saved?['version'] as String?;
    _loaded = true;
    _saving = false;
    _storageError = null;
    _edit++;
    _savedEdit = _edit;
    _restoring = true;
    _lastText = saved?['text'] as String? ?? '';
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
    if (_disposed) return;
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
    _closed = flushDraft().catchError((Object _) {}).whenComplete(() {
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
