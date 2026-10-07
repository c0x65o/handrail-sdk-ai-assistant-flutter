// Linked ONLY into the disposable diagnostic library by run-presend-trace.mjs.
// These helpers exercise the production private predicate without exporting it.
part of 'handrail_ai_client.dart';

Map<String, Object?> presendPrivateState(HandrailConversationSession s) => {
  'capturable':
      _PreparedChanges.capture(s, preparedRevision: s.document?.revision) !=
      null,
  'changesAfter': s._displayWindow?._changesAfter,
  'changesCursor': s._displayWindow?._changesCursor,
  'consumedChanges': s._displayWindow?._consumedChanges,
  'documentRevision': s.document?.revision,
  'canonicalRevision': s._control?.canonicalRevision,
  'projectionRevision': s._control?.revision,
  'generation': s._control?.generation,
};

bool presendPrivateProof(
  HandrailConversationSession s,
  String mutation, {
  bool atCapture = false,
}) {
  if (mutation == 'prepared revision') {
    return _PreparedChanges.capture(
          s,
          preparedRevision: s.document?.revision == null ? 0 : null,
        ) !=
        null;
  }
  var witness = _PreparedChanges.capture(
    s,
    preparedRevision: s.document?.revision,
  );
  if (witness == null) throw StateError('Fixture has no preparation witness');
  final w = s._displayWindow!, c = s._control!;
  var current = s, fresh = c;
  // The actual refresh increments these once, before/after authorized control.
  if (!atCapture) {
    s._preparationGeneration++;
    s._displayReadGeneration++;
  }
  switch (mutation) {
    case 'none':
      break;
    case 'reuse':
      if (!witness.consume(s, fresh)) throw StateError('First use failed');
    case 'session':
      current = HandrailConversationSession(
        client: s.client,
        conversationId: s.conversationId,
        pollingInterval: null,
      );
    case 'client':
      current = HandrailConversationSession(
        client: HandrailAiClient(baseUri: s.client.baseUri),
        conversationId: s.conversationId,
        pollingInterval: null,
      );
    case 'workspace selection':
      s.workspace.select(null);
      s.workspace.select(s.conversationId);
    case 'window version':
      w._version++;
    case 'activation':
      s._displayActivation = Completer<void>();
    case 'closed activation':
      s._displayActivation.complete();
    case 'disposed':
      s._disposed = true;
    case 'inactive':
      s._displayActive = false;
    case 'refresh':
      s._preparationGeneration++;
    case 'observation':
      s._observationGeneration++;
    case 'display read':
      s._displayReadGeneration++;
    case 'related epoch':
      s._relatedEpoch++;
    case 'related version':
      s._relatedVersion++;
    case 'approval epoch':
      s._approvalHistoryEpoch++;
    case 'window observation':
      w._observationGeneration++;
    case 'window replaced':
      s._displayWindow = HandrailDisplayWindow(
        client: s.client,
        capability: w.capability,
      );
    case 'control replaced':
      s._control = _copyProofControl(c);
    case 'document missing':
      s._document = null;
    case 'document revision':
      s._document = HandrailConversationDocument._(
        s.conversationId,
        0,
        const {},
        const [],
        const [],
      );
    case 'error':
      s._error = const HandrailGatewayException('forbidden', 'Synthetic');
    case 'refresh error':
      s._refreshError = const HandrailGatewayException('failed', 'Synthetic');
    case 'scheduled refresh':
      s._displayRefreshRequested = true;
    case 'stream refresh':
      s._streamRefreshTimer = Timer(Duration.zero, () {});
    case 'display loading':
      s._displayRequests.add(Completer<void>());
    case 'related loading':
      s._loadingRelated = Future.value();
    case 'approval loading':
      s._loadingApprovalHistory = Future.value();
    case 'related pagination':
      s._relatedCursor = 'remaining';
    case 'related trim':
      s._relatedTruncated = true;
    case 'window disposed':
      w._disposed = true;
    case 'window selection':
      w._selection.complete();
    case 'window conversation':
      w._conversationId = 'other';
    case 'window preparing':
      w._status = 'preparing';
    case 'window generation':
      w._generation++;
    case 'window revision':
      w._revision++;
    case 'watermark':
      w._changesAfter--;
    case 'cursor':
      w._changesCursor = 'remaining';
    case 'unconsumed':
      w._consumedChanges = false;
    case 'initial page':
      w._change = HandrailDisplayWindowOperation.initial;
    case 'pending':
      w._pending = Future.value();
    case 'queued latest':
      w._queuedLatest = Future.value();
    case 'read request':
      w._readRequest = Completer<void>();
    case 'content request':
      w._contentRequest = Completer<void>();
    case 'loading':
      w._loading = HandrailDisplayWindowOperation.changes;
    case 'failed':
      w._failedOperation = HandrailDisplayWindowOperation.changes;
    case 'window error':
      w._error = StateError('Synthetic');
    case 'newer':
      w._hasNewer = true;
    case 'scrolled':
      w._followingLatest = false;
    case 'deferred':
      w._records = [
        HandrailDisplayRecord.fromJson({
          'kind': 'message',
          'id': 'deferred',
          'revision': c.revision,
          'turnId': null,
          'bytes': 100000,
          'deferred': true,
          'value': null,
        }),
      ];
    case 'fresh conversation':
      fresh = _copyProofControl(c, conversation: 'other');
    case 'fresh generation':
      fresh = _copyProofControl(c, generation: c.generation + 1);
    case 'fresh canonical':
      fresh = _copyProofControl(c, canonical: c.canonicalRevision + 1);
    case 'fresh projection':
      fresh = _copyProofControl(c, revision: c.revision + 1);
    case 'fresh preparing':
      fresh = _copyProofControl(c, preparing: true);
    case 'fresh active':
      fresh = _copyProofControl(c, active: 'remote');
    default:
      throw ArgumentError(mutation);
  }
  if (atCapture)
    return _PreparedChanges.capture(
          s,
          preparedRevision: s.document?.revision,
        ) !=
        null;
  return witness.consume(current, fresh);
}

HandrailDisplayControl _copyProofControl(
  HandrailDisplayControl c, {
  String? conversation,
  int? generation,
  int? canonical,
  int? revision,
  bool? preparing,
  String? active,
}) => HandrailDisplayControl._(
  conversation ?? c.conversationId,
  generation ?? c.generation,
  revision ?? c.revision,
  canonical ?? c.canonicalRevision,
  preparing ?? c.preparing,
  active ?? c.activeTurnId,
  c.activeTurn,
  c.latestTurn,
  c.requestedTurn,
  c.hasPendingApprovals,
);
