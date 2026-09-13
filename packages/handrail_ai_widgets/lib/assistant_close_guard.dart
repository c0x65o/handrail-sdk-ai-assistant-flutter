import 'dart:async';
import 'package:flutter/material.dart';
import 'composer_drafts.dart';
import 'workspace_binding.dart';

/// Connects a branded Close button or authorized navigation to the shared guard.
class HandrailAssistantCloseController {
  Future<bool> Function()? _request;
  Future<bool> requestClose() async => await _request?.call() ?? false;
}

/// Optional route policy for hosts that discard drafts when a surface closes.
/// Ordinary account-retained workspaces can close without this guard. Closing
/// never cancels server work; Stop remains an explicit action in the workspace.
class HandrailAssistantCloseGuard extends StatefulWidget {
  const HandrailAssistantCloseGuard({
    super.key,
    required this.binding,
    required this.drafts,
    required this.controller,
    required this.onClose,
    required this.child,
    this.enabled = true,
    this.confirmDraftDiscard = false,
    this.blockWhileWorking = false,
    this.businessBusy = false,
    this.assistantLabel = 'Assistant',
  });
  final HandrailWorkspaceBinding binding;
  final HandrailComposerController drafts;
  final HandrailAssistantCloseController controller;
  final VoidCallback onClose;
  final Widget child;
  final bool enabled, confirmDraftDiscard, blockWhileWorking, businessBusy;
  final String assistantLabel;

  @override
  State<HandrailAssistantCloseGuard> createState() => _CloseGuardState();
}

class _CloseGuardState extends State<HandrailAssistantCloseGuard> {
  StreamSubscription<Object?>? _subscription;
  DialogRoute<bool>? _dialog;
  final _dialogChanges = ValueNotifier(0);
  late final Future<bool> Function() _requestCallback = _requestClose;
  int _generation = 0;
  bool _closing = false;

  bool get _working =>
      widget.enabled &&
      widget.blockWhileWorking &&
      (widget.businessBusy ||
          widget.drafts.isWorking ||
          widget.binding.read()['workingAnywhere'] == true);
  bool get _dirty =>
      widget.enabled && widget.confirmDraftDiscard && widget.drafts.hasDrafts;

  void _bind() {
    widget.controller._request = _requestCallback;
    _subscription = widget.binding.changes.listen((_) => _changed());
    widget.drafts.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _dialogChanges.value++;
  }

  void _removeDialog() {
    final route = _dialog;
    _dialog = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(HandrailAssistantCloseGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.binding.scope != widget.binding.scope ||
        !identical(oldWidget.drafts, widget.drafts) ||
        !identical(oldWidget.controller, widget.controller)) {
      _generation++;
      _closing = false;
      _removeDialog();
      unawaited(_subscription?.cancel());
      oldWidget.drafts.removeListener(_changed);
      if (identical(oldWidget.controller._request, _requestCallback)) {
        oldWidget.controller._request = null;
      }
      _bind();
    }
    // A host business gate may change while the confirmation route is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dialogChanges.value++;
    });
  }

  Future<bool> _requestClose() async {
    if (!mounted || _closing) return false;
    _closing = true;
    final generation = _generation;
    final originDrafts = widget.drafts;
    var closed = false;
    bool current() => mounted && generation == _generation;
    try {
      if (_dirty || _working) {
        FocusManager.instance.primaryFocus?.unfocus();
        final route = DialogRoute<bool>(
          context: context,
          builder: (context) => ListenableBuilder(
            listenable: _dialogChanges,
            builder: (context, _) {
              if (!current()) return const SizedBox.shrink();
              final working = _working;
              return AlertDialog(
                key: const ValueKey('handrail-close-decision'),
                scrollable: true,
                title: Text(working
                    ? '${widget.assistantLabel} is still working'
                    : 'Discard draft?'),
                content: Text(working
                    ? 'Finish selecting files or wait for the operation. To stop a response, select its conversation and use Stop.'
                    : 'Drafts and selected files in your conversations will be discarded.'),
                actions: [
                  TextButton(
                    key: const ValueKey('handrail-keep-editing'),
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(working ? 'Stay' : 'Keep editing'),
                  ),
                  if (!working)
                    FilledButton(
                      key: const ValueKey('handrail-discard-draft'),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Discard'),
                    ),
                ],
              );
            },
          ),
        );
        _dialog = route;
        final accepted =
            await Navigator.of(context, rootNavigator: true).push(route);
        if (!current()) return false;
        _dialog = null;
        if (accepted != true || _working) return false;
      }
      if (!current()) return false;
      if (widget.confirmDraftDiscard) originDrafts.clear();
      widget.onClose();
      closed = true;
      return true;
    } finally {
      if (current() && !closed) _closing = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
        canPop: !_dirty && !_working,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_requestClose());
        },
        child: widget.child,
      );

  @override
  void dispose() {
    _generation++;
    _removeDialog();
    unawaited(_subscription?.cancel());
    widget.drafts.removeListener(_changed);
    if (identical(widget.controller._request, _requestCallback)) {
      widget.controller._request = null;
    }
    // The owned route can finish detaching after its parent account is removed.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _dialogChanges.dispose());
    super.dispose();
  }
}
