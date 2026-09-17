part of '../handrail_ai_client.dart';

/// Account/API-scoped unsent files. Writers must atomically compare versions.
/// Reads hydrate only one conversation. Write replies contain metadata only;
/// provide `bytes` for a new immutable selection, omit it on later updates.
abstract interface class HandrailAttachmentDraftStore {
  Future<Map<String, Object?>?> readAttachmentDraft(String conversationId);
  Future<Map<String, Object?>?> writeAttachmentDraft(String conversationId,
      List<Map<String, Object?>> files, String? expectedVersion);
  Future<Map<String, Object?>> discardAcceptedFiles(
      String conversationId, List<String> ids);

  /// Confirmed permanent deletion only; fences all later writes to this ID.
  Future<void> eraseConversation(String conversationId);
}

/// Durable adapter over encrypted host storage. Metadata replacement must be
/// atomic; byte writes/deletes must be idempotent. Supply binary callbacks for
/// encrypted file/database storage; the key-value fallback uses per-file base64.
/// Ready updates, quota scans and accepted cleanup never read binary sources.
/// Serializes adapters sharing a namespace within this isolate. Multi-process
/// hosts must supply their own transactional implementation of the interface.
class HandrailKeyValueAttachmentDraftStore
    implements HandrailAttachmentDraftStore {
  HandrailKeyValueAttachmentDraftStore(
      {required this.namespace,
      required this.read,
      required this.write,
      required this.delete,
      this.readBytes,
      this.writeBytes,
      this.deleteBytes}) {
    if (namespace.isEmpty ||
        namespace.length > 2048 ||
        [readBytes, writeBytes, deleteBytes].where((v) => v != null).length %
                3 !=
            0) {
      throw ArgumentError(
          'An account namespace and all or no binary callbacks are required');
    }
  }
  final String namespace;
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String) write;
  final Future<void> Function(String) delete;
  final Future<List<int>?> Function(String)? readBytes;
  final Future<void> Function(String, List<int>)? writeBytes;
  final Future<void> Function(String)? deleteBytes;
  static const maximumFiles = 64,
      maximumBytes = 64 * 1024 * 1024,
      maximumConversations = 32;
  late final String _prefix =
      'handrail.files.v1.${crypto.sha256.convert(utf8.encode(namespace))}';
  String get _key => '$_prefix.manifest';
  String _deletedKey(String id) =>
      '$_prefix.deleted.${crypto.sha256.convert(utf8.encode(id))}';

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = HandrailKeyValuePendingTurnStore._locks[_key];
    final released = Completer<void>();
    HandrailKeyValuePendingTurnStore._locks[_key] = released.future;
    try {
      await previous;
      return await action();
    } finally {
      if (identical(
          HandrailKeyValuePendingTurnStore._locks[_key], released.future)) {
        HandrailKeyValuePendingTurnStore._locks.remove(_key);
      }
      released.complete();
    }
  }

  void _identity(String id) {
    if (!_historyId(id))
      throw const FormatException('Invalid attachment draft conversation');
  }

  bool _blobKey(Object? value) =>
      value is String &&
      value.startsWith('$_prefix.blob.') &&
      RegExp(r'^[a-f0-9]{64}$')
          .hasMatch(value.substring('$_prefix.blob.'.length));

  Future<_AttachmentDraftJournal> _load() async {
    final raw = await read(_key);
    if (raw == null) return _AttachmentDraftJournal({}, []);
    if (raw.length > 262144 || utf8.encode(raw).length > 262144)
      throw const FormatException('Attachment manifest exceeds its limit');
    final value = _object(jsonDecode(raw));
    if (value['version'] != 1 ||
        value['rows'] is! Map ||
        value['garbage'] is! List ||
        (value['rows'] as Map).length > maximumConversations ||
        (value['garbage'] as List).length > maximumFiles) {
      throw const FormatException('Invalid attachment manifest');
    }
    final rows = <String, Map<String, Object?>>{}, keys = <String>{};
    var count = 0, bytes = 0;
    for (final entry in _object(value['rows']).entries) {
      _identity(entry.key);
      final row = _object(entry.value), revision = row['version'];
      if (revision is! String ||
          revision.isEmpty ||
          revision.length > 128 ||
          row['files'] is! List ||
          (row['files'] as List).isEmpty ||
          (row['files'] as List).length > maximumFiles) {
        throw const FormatException('Invalid attachment draft');
      }
      final ids = <String>{};
      final files = <Map<String, Object?>>[];
      for (final input in _records(row['files'])) {
        final file = _attachmentDraftMetadata(input), key = input['blobKey'];
        if (!ids.add(file['id'] as String) ||
            !_blobKey(key) ||
            !keys.add(key as String)) {
          throw const FormatException('Invalid saved attachment identity');
        }
        files.add({...file, 'blobKey': key});
        count++;
        bytes += file['byteSize'] as int;
      }
      rows[entry.key] = {'version': revision, 'files': files};
    }
    final garbage = <Map<String, Object?>>[];
    for (final item in _records(value['garbage'])) {
      final key = item['key'], size = item['bytes'];
      if (!_blobKey(key) ||
          !keys.add(key as String) ||
          size is! int ||
          size < 1 ||
          size > maximumBytes) {
        throw const FormatException('Invalid attachment cleanup journal');
      }
      garbage.add({'key': key, 'bytes': size});
      count++;
      bytes += size;
    }
    if (count > maximumFiles || bytes > maximumBytes)
      throw _attachmentDraftCapacity;
    return _AttachmentDraftJournal(rows, garbage);
  }

  Future<void> _save(_AttachmentDraftJournal journal) async {
    final json = jsonEncode(
        {'version': 1, 'rows': journal.rows, 'garbage': journal.garbage});
    if (utf8.encode(json).length > 262144) throw _attachmentDraftCapacity;
    // Keep an empty manifest: one atomic replacement is the commit point.
    await write(_key, json);
  }

  Future<void> _collect(_AttachmentDraftJournal journal) async {
    if (journal.garbage.isEmpty) return;
    for (final item in journal.garbage) {
      final key = item['key'] as String;
      if (deleteBytes != null)
        await deleteBytes!(key);
      else
        await delete(key);
    }
    await _save(_AttachmentDraftJournal(journal.rows, []));
    journal.garbage.clear();
  }

  Future<_AttachmentDraftJournal> _recover() async {
    final journal = await _load();
    await _collect(journal);
    return journal;
  }

  Map<String, Object?>? _publicRow(Map<String, Object?>? row) => row == null
      ? null
      : {
          'version': row['version'],
          'files': _records(row['files'])
              .map((file) => Map<String, Object?>.unmodifiable(
                  {...file}..remove('blobKey')))
              .toList(growable: false),
        };

  @override
  Future<Map<String, Object?>?> readAttachmentDraft(String id) {
    _identity(id);
    return _exclusive(() async {
      final journal = await _recover();
      if (await read(_deletedKey(id)) != null) return null;
      final row = journal.rows[id];
      if (row == null) return null;
      final files = <Map<String, Object?>>[];
      for (final file in _records(row['files'])) {
        final key = file['blobKey'] as String, size = file['byteSize'] as int;
        List<int>? bytes;
        if (readBytes != null) {
          bytes = await readBytes!(key);
        } else {
          final encoded = await read(key);
          if (encoded != null && encoded.length <= ((size + 2) ~/ 3) * 4)
            bytes = base64Decode(encoded);
        }
        if (bytes == null ||
            bytes.length != size ||
            bytes.any((b) => b < 0 || b > 255) ||
            crypto.sha256.convert(bytes).toString() != file['sha256']) {
          throw const FormatException(
              'Saved attachment bytes are unavailable or changed');
        }
        files.add(Map.unmodifiable({
          ...file,
          'bytes': Uint8List.fromList(bytes).asUnmodifiableView()
        }..remove('blobKey')));
      }
      return {'version': row['version'], 'files': List.unmodifiable(files)};
    });
  }

  @override
  Future<Map<String, Object?>?> writeAttachmentDraft(
      String id, List<Map<String, Object?>> input, String? expectedVersion) {
    _identity(id);
    if (input.length > maximumFiles) throw _attachmentDraftCapacity;
    // Detach new bytes once, before the first await; ready updates omit them.
    var bytes = 0, capturedBytes = 0;
    final sources = <String, Uint8List>{}, ids = <String>{};
    final files = <Map<String, Object?>>[];
    for (final value in input) {
      final source = value['bytes'];
      if (source != null &&
          (source is! List<int> ||
              source.isEmpty ||
              source.length > maximumBytes)) {
        throw const FormatException('Invalid attachment source');
      }
      capturedBytes += source == null ? 0 : (source as List<int>).length;
      if (capturedBytes > maximumBytes) throw _attachmentDraftCapacity;
      final copy =
          source == null ? null : Uint8List.fromList(source as List<int>);
      final hash = copy == null
          ? value['sha256']
          : crypto.sha256.convert(copy).toString();
      final file = _attachmentDraftMetadata({...value, 'sha256': hash});
      if (!ids.add(file['id'] as String) ||
          copy != null &&
              (copy.length != file['byteSize'] ||
                  (source as List<int>).any((b) => b < 0 || b > 255) ||
                  value['sha256'] != null && value['sha256'] != hash)) {
        throw const FormatException('Attachment identity or bytes changed');
      }
      bytes += file['byteSize'] as int;
      if (bytes > maximumBytes) throw _attachmentDraftCapacity;
      if (copy != null) sources[file['id'] as String] = copy;
      files.add(file);
    }
    return _exclusive(() async {
      final journal = await _recover();
      if (await read(_deletedKey(id)) != null)
        throw StateError('Conversation was permanently deleted');
      final old = journal.rows[id];
      if (old?['version'] != expectedVersion) throw _attachmentDraftConflict;
      final previous = {
        for (final file in _records(old?['files'])) file['id'] as String: file
      };
      final next = <Map<String, Object?>>[], staged = <Map<String, Object?>>[];
      for (final file in files) {
        final saved = previous[file['id']];
        String key;
        if (saved != null) {
          final before = {...saved}
                ..remove('blobKey')
                ..remove('reference'),
              after = {...file}..remove('reference');
          if (jsonEncode(before) != jsonEncode(after) ||
              saved['reference'] != null &&
                  jsonEncode(saved['reference']) !=
                      jsonEncode(file['reference'])) {
            throw const FormatException('Saved attachment identity changed');
          }
          key = saved['blobKey'] as String;
        } else {
          if (!sources.containsKey(file['id']))
            throw const FormatException('New attachment bytes are required');
          key =
              '$_prefix.blob.${crypto.sha256.convert(utf8.encode(_assistantIdentity()))}';
          staged.add({'key': key, 'bytes': file['byteSize']});
        }
        next.add({...file, 'blobKey': key});
      }
      final all =
          journal.rows.values.expand((row) => _records(row['files'])).toList();
      if (all.length + staged.length > maximumFiles ||
          all.fold<int>(0, (sum, file) => sum + (file['byteSize'] as int)) +
                  staged.fold<int>(
                      0, (sum, item) => sum + (item['bytes'] as int)) >
              maximumBytes ||
          old == null &&
              next.isNotEmpty &&
              journal.rows.length >= maximumConversations)
        throw _attachmentDraftCapacity;
      final garbage = previous.values
          .where((file) => !ids.contains(file['id']))
          .map((file) => <String, Object?>{
                'key': file['blobKey'],
                'bytes': file['byteSize']
              })
          .toList();
      if (staged.isNotEmpty) {
        // A crash before the commit leaves old rows authoritative and new keys
        // discoverable for bounded cleanup. Never guess whether a write landed.
        await _save(_AttachmentDraftJournal(journal.rows, staged));
        for (final file
            in next.where((file) => !previous.containsKey(file['id']))) {
          final source = sources[file['id']]!, key = file['blobKey'] as String;
          if (writeBytes != null)
            await writeBytes!(key, source);
          else
            await write(key, base64Encode(source));
        }
      }
      final version = next.isEmpty ? null : _assistantIdentity();
      final rows = {...journal.rows};
      if (version == null)
        rows.remove(id);
      else
        rows[id] = {'version': version, 'files': next};
      final committed = _AttachmentDraftJournal(rows, garbage);
      await _save(committed);
      await _collect(committed);
      return _publicRow(rows[id]);
    });
  }

  @override
  Future<Map<String, Object?>> discardAcceptedFiles(
      String id, List<String> selected) {
    _identity(id);
    if (selected.length > maximumFiles ||
        selected.toSet().length != selected.length ||
        selected.any((value) => !_attachmentDraftId(value)))
      throw const FormatException('Invalid attachment receipt');
    final ids = Set<String>.of(selected);
    return _exclusive(() async {
      final journal = await _recover(), old = journal.rows[id];
      if (old == null) return {'previousVersion': null, 'version': null};
      final before = _records(old['files']),
          files = before.where((f) => !ids.contains(f['id'])).toList();
      if (files.length == before.length)
        return {'previousVersion': old['version'], 'version': old['version']};
      final version = files.isEmpty ? null : _assistantIdentity(),
          rows = {...journal.rows};
      if (version == null)
        rows.remove(id);
      else
        rows[id] = {'version': version, 'files': files};
      final next = _AttachmentDraftJournal(
          rows,
          before
              .where((f) => ids.contains(f['id']))
              .map((f) => <String, Object?>{
                    'key': f['blobKey'],
                    'bytes': f['byteSize']
                  })
              .toList());
      await _save(next);
      await _collect(next);
      return {'previousVersion': old['version'], 'version': version};
    });
  }

  @override
  Future<void> eraseConversation(String id) {
    _identity(id);
    return _exclusive(() async {
      // Fence first. A crash or cleanup failure must never permit resurrection.
      await write(_deletedKey(id), '1');
      final journal = await _recover(), old = journal.rows.remove(id);
      final next = _AttachmentDraftJournal(
          journal.rows,
          _records(old?['files'])
              .map((f) => <String, Object?>{
                    'key': f['blobKey'],
                    'bytes': f['byteSize']
                  })
              .toList());
      await _save(next);
      await _collect(next);
    });
  }
}

class _AttachmentDraftJournal {
  _AttachmentDraftJournal(this.rows, this.garbage);
  final Map<String, Map<String, Object?>> rows;
  final List<Map<String, Object?>> garbage;
}

const _attachmentDraftCapacity = HandrailGatewayException(
    'attachment_draft_full',
    'Saved files have reached this account’s device limit. Remove another selection and retry.');
const _attachmentDraftConflict = HandrailGatewayException(
    'attachment_draft_conflict',
    'Saved files changed in another view. Your current selections remain available.');
bool _attachmentDraftId(String id) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(id);
Map<String, Object?> _attachmentDraftMetadata(Map<String, Object?> input) {
  final id = input['id'],
      name = input['filename'],
      type = input['mediaType'],
      size = input['byteSize'],
      hash = input['sha256'];
  if (id is! String ||
      !_attachmentDraftId(id) ||
      name is! String ||
      name.isEmpty ||
      name.length > 255 ||
      RegExp(r'[\x00-\x1f\x7f/\\]').hasMatch(name) ||
      type is! String ||
      type.length > 255 ||
      !RegExp(r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$').hasMatch(type) ||
      size is! int ||
      size < 1 ||
      size > HandrailKeyValueAttachmentDraftStore.maximumBytes ||
      hash is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
    throw const FormatException('Invalid saved attachment metadata');
  Map<String, Object?>? reference;
  if (input['reference'] != null) {
    final ref = _object(input['reference']);
    if (ref.keys.any((key) => !const [
              'attachment_id',
              'content_ref',
              'media_type',
              'byte_size',
              'filename'
            ].contains(key)) ||
        ref['attachment_id'] is! String ||
        (ref['attachment_id'] as String).isEmpty ||
        (ref['attachment_id'] as String).length > 256 ||
        ref['content_ref'] is! String ||
        (ref['content_ref'] as String).isEmpty ||
        (ref['content_ref'] as String).length > 2048 ||
        ref['media_type'] != type ||
        ref['byte_size'] != size ||
        ref['filename'] != null && ref['filename'] != name) {
      throw const FormatException('Invalid saved attachment reference');
    }
    reference = {
      for (final key in [
        'attachment_id',
        'content_ref',
        'media_type',
        'byte_size',
        'filename'
      ])
        if (ref.containsKey(key)) key: ref[key]
    };
  }
  return {
    'id': id,
    'filename': name,
    'mediaType': type,
    'byteSize': size,
    'sha256': hash,
    if (reference != null) 'reference': Map.unmodifiable(reference)
  };
}
