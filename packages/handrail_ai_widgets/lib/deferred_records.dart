import 'package:flutter/material.dart';
import 'large_message.dart';

typedef HandrailRecordTextReader =
    Future<Map<String, Object?>> Function(
      String conversationId,
      String kind,
      String id,
      int generation,
      int revision,
      int offset,
      Future<void> cancellation,
    );

/// Explicit inspection of one bounded, revision-pinned section. Reading record
/// text never authorizes an approval or inserts content into model history.
class HandrailDeferredRecords extends StatefulWidget {
  const HandrailDeferredRecords({
    super.key,
    required this.conversationId,
    required this.generation,
    required this.records,
    required this.reader,
    required this.onRefresh,
  });
  final String conversationId;
  final int generation;
  final List<Map<String, Object?>> records;
  final HandrailRecordTextReader reader;
  final VoidCallback onRefresh;
  @override
  State<HandrailDeferredRecords> createState() => _DeferredRecordsState();
}

class _DeferredRecordsState extends State<HandrailDeferredRecords> {
  Object? _opened;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final record in widget.records)
        if (record['kind'] is String &&
            record['id'] is String &&
            record['revision'] is int)
          _record(record),
    ],
  );
  Widget _record(Map<String, Object?> record) {
    final kind = record['kind'] as String, id = record['id'] as String;
    final revision = record['revision'] as int;
    final identity = (
      widget.reader,
      widget.conversationId,
      widget.generation,
      kind,
      id,
      revision,
    );
    return _RecordDetails(
      key: ValueKey(identity),
      conversationId: widget.conversationId,
      generation: widget.generation,
      kind: kind,
      id: id,
      revision: revision,
      reader: widget.reader,
      expanded: _opened == identity,
      onOpen: () => setState(() => _opened = identity),
      onClose: () => setState(() => _opened = null),
      onRefresh: widget.onRefresh,
    );
  }
}

class _RecordDetails extends StatefulWidget {
  const _RecordDetails({
    super.key,
    required this.conversationId,
    required this.generation,
    required this.kind,
    required this.id,
    required this.revision,
    required this.reader,
    required this.expanded,
    required this.onOpen,
    required this.onClose,
    required this.onRefresh,
  });
  final String conversationId, kind, id;
  final int generation, revision;
  final HandrailRecordTextReader reader;
  final bool expanded;
  final VoidCallback onOpen, onClose, onRefresh;
  @override
  State<_RecordDetails> createState() => _RecordDetailsState();
}

class _RecordDetailsState extends State<_RecordDetails> {
  Future<Map<String, Object?>> _read(
    String conversationId,
    String id,
    int generation,
    int revision,
    int offset,
    Future<void> cancellation,
  ) => widget.reader(
    conversationId,
    widget.kind,
    id,
    generation,
    revision,
    offset,
    cancellation,
  );
  @override
  Widget build(BuildContext context) => HandrailLargeMessage(
    conversationId: widget.conversationId,
    id: widget.id,
    generation: widget.generation,
    revision: widget.revision,
    reader: _read,
    expanded: widget.expanded,
    structured: true,
    onOpen: widget.onOpen,
    onClose: widget.onClose,
    onRefresh: widget.onRefresh,
  );
}
