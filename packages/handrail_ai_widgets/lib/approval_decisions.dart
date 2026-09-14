import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

/// Structural binding supplied by the account-owned SDK approval controller.
typedef HandrailApprovalBinding = ({
  Object scope,
  Stream<Object?> changes,
  Map<String, Object?> Function() read,
  Future<void> Function(String, int) review,
  Future<void> Function(String, int, String, bool) decide,
  Future<void> Function(String) retry,
});

/// Standard decisions cannot be hidden by transcript/activity styling. A host
/// renderer may format validated arguments, but cannot grant approval permission.
class HandrailApprovalDecisionsView extends StatefulWidget {
  const HandrailApprovalDecisionsView(
      {super.key, required this.binding, this.reviewBuilder, this.titleFor});
  final HandrailApprovalBinding binding;

  /// Business wording only; proposal identity and decision gates are unchanged.
  final String? Function(Map<String, Object?>)? titleFor;
  final Widget? Function(BuildContext, Map<String, Object?>)? reviewBuilder;
  @override
  State<HandrailApprovalDecisionsView> createState() =>
      _ApprovalDecisionsState();
}

class _ApprovalDecisionsState extends State<HandrailApprovalDecisionsView> {
  StreamSubscription<Object?>? _subscription;
  int _generation = 0;
  String? _conversation;
  final _errors = <String, String>{};
  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _conversation = widget.binding.read()['conversationId'] as String?;
    _subscription = widget.binding.changes.listen((_) {
      if (!mounted) return;
      final id = widget.binding.read()['conversationId'] as String?;
      if (_conversation != id) {
        _generation++;
        _errors.clear();
        _conversation = id;
      }
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant HandrailApprovalDecisionsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding.scope, widget.binding.scope) ||
        !identical(oldWidget.binding.changes, widget.binding.changes)) {
      _generation++;
      _errors.clear();
      _subscription?.cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _generation++;
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _act(String id, Future<void> Function() action) async {
    final generation = _generation;
    try {
      _errors.remove(id);
      await action();
    } catch (_) {
      if (mounted && generation == _generation)
        _errors[id] =
            'The approval could not be updated. Check its current review or saved decision.';
    } finally {
      if (mounted && generation == _generation) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.binding.read();
    final items = (state['items'] as List? ?? const [])
        .whereType<Map>()
        .map((v) => Map<String, Object?>.from(v))
        .toList();
    if (items.isEmpty && state['error'] == null) return const SizedBox.shrink();
    final binding = widget.binding;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (state['error'] is String) Text(state['error'] as String),
      for (final item in items)
        Builder(builder: (context) {
          final id = item['proposal_id'] as String;
          final version = item['proposal_version'] as int;
          final pending = item['pendingDecision'] == true;
          final busy = item['busy'] == true;
          final status = item['expired'] == true && item['status'] == 'pending'
              ? 'expired'
              : item['status'] as String? ?? 'pending';
          final review = item['reviewed'] == true;
          final error = item['error'] as String? ?? _errors[id];
          return Card(
            key: ValueKey(('approval', state['conversationId'], id)),
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (item['group_id'] is String)
                      Text('Group: ${item['group_id']}'),
                    Text(
                        widget.titleFor?.call(item) ??
                            item['tool_name'] as String? ??
                            'Proposed change',
                        style: Theme.of(context).textTheme.titleSmall),
                    Text(pending
                        ? 'Checking saved decision'
                        : switch (status) {
                            'pending' => 'Review required',
                            'confirmed' => 'Approved · awaiting execution',
                            'rejected' => 'Rejected',
                            'expired' => 'Expired',
                            'executing' => 'Executing',
                            'executed' => 'Executed',
                            'failed' => 'Execution failed',
                            _ => status,
                          }),
                    if (review) ...[
                      widget.reviewBuilder?.call(context, item) ??
                          SelectableText(const JsonEncoder.withIndent('  ')
                              .convert(item['arguments'])),
                      if (item['complete'] != true)
                        const Text(
                            'This review is incomplete. Approval is unavailable.'),
                    ],
                    if (error != null)
                      Semantics(liveRegion: true, child: Text(error)),
                    if (busy || item['reviewing'] == true)
                      const LinearProgressIndicator(),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      if (!pending && status == 'pending') ...[
                        TextButton(
                            onPressed: item['canReview'] == true
                                ? () =>
                                    _act(id, () => binding.review(id, version))
                                : null,
                            child: Text(
                                review ? 'Reload review' : 'Review change')),
                        FilledButton(
                            onPressed: item['canConfirm'] == true
                                ? () => _act(
                                    id,
                                    () => binding.decide(id, version,
                                        item['binding'] as String, true))
                                : null,
                            child: const Text('Approve')),
                        TextButton(
                            onPressed: item['canReject'] == true
                                ? () => _act(
                                    id,
                                    () => binding.decide(id, version,
                                        item['binding'] as String, false))
                                : null,
                            child: const Text('Reject')),
                      ],
                      if (pending)
                        TextButton(
                            onPressed: busy
                                ? null
                                : () => _act(id, () => binding.retry(id)),
                            child: const Text('Check saved decision')),
                    ]),
                  ],
                )),
          );
        }),
    ]);
  }
}
