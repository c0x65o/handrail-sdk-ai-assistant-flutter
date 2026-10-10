// Real SDK HTTP gateway, deterministic provider, in-memory persistence. This
// qualifies the cross-language protocol without credentials or billable usage.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { createRequire } from 'node:module';
// Optional explicit cross-revision fixture. Default checks always use the
// installed public Git dependency; a local path never establishes adoption.
const dist = process.env.HANDRAIL_TEST_JS_SDK_DIST;
const { createHandrailAssistant, createProviderToolLoopTransport } = await import(dist
  ? pathToFileURL(resolve(dist, 'server/assistant.js')).href : '@handrail/ai-assistant/server/assistant');
const {
  InMemoryConversationEventStore, InMemoryApprovalProposalStore,
  InMemoryConversationCatalog, InMemoryDurableApplicationTurnStore,
  InMemoryToolExecutionLedger, parseConversationEvent, assistantToolArgumentReference,
} = await import(dist ? pathToFileURL(resolve(dist, 'index.js')).href : '@handrail/ai-assistant');

const required = (id) => ({ id, source: 'server_derived', trust: 'authoritative' });
const attribution = { organization: required('org'), project: required('project'),
  service_environment: required('test'), known_user: required('user'),
  session: required(null), automation: required(null) };
const context = { principalId: 'user', tenantId: 'tenant', scopeId: 'test', attribution };
const records = new Map();
let bundle = { events: new InMemoryConversationEventStore(),
  approvals: new InMemoryApprovalProposalStore({ authorize: () => 'allow' }),
  catalog: new InMemoryConversationCatalog({ authorize: () => 'allow' }),
  durableTurns: new InMemoryDurableApplicationTurnStore(), toolLedger: new InMemoryToolExecutionLedger(),
  activity: { async list() { return [...records.values()]; },
    async upsert(record) { records.set(record.conversationId, record); return record; },
    async markRead(conversationId) { const record = records.get(conversationId); if (!record) return null;
      const read = { ...record, unread: false }; records.set(conversationId, read); return read; } },
  usageReceiptSink: null, usageAdmissions: null };
let persistence = { attachmentLimits: { maximumBytes: 1000, acceptedMediaTypes: ['text/plain'], ttlMilliseconds: 60000 },
  persistence: {}, forScope: () => bundle };
let database;
if (dist) {
  // Source qualification uses the JS repository's existing test-only PostgreSQL
  // engine and real SDK stores. Dependency declarations/locks remain unchanged.
  const { PGlite } = createRequire(resolve(dist, '../package.json'))('@electric-sql/pglite');
  const { postgresFromClient } = await import(pathToFileURL(resolve(dist, 'postgres/index.js')).href);
  database = new PGlite();
  const adapt = db => {
    const client = { async query(sql, values = []) {
      const result = await db.query(sql, [...values]);
      return { rows: result.rows, rowCount: result.affectedRows ?? result.rows.length };
    }, transaction: operation => operation(client) };
    return client;
  };
  const client = { query: adapt(database).query,
    transaction: operation => database.transaction(tx => operation(adapt(tx))) };
  persistence = postgresFromClient(client, { attachmentLimits: persistence.attachmentLimits });
  await persistence.persistence.migrate();
  bundle = persistence.forScope(context, { createConversationId: randomUUID,
    authorizeConversation: () => 'allow', authorizeApproval: () => 'allow' });
}
const stats = { invocations: 0, starts: 0, resumes: 0, admissions: 0, deletions: 0, decisions: 0,
  displayReads: 0, snapshotReads: 0, displayBytes: 0, maximumDisplayBytes: 0, maximumDecisionBytes: 0 };
const release = new Map();
const adapter = { metadata: { provider_id: 'test', model_id: 'test', capabilities: {
  streaming: true, text: true, tool_calls: false, parallel_tool_calls: false, reasoning: false,
  document_input: { supported: false }, provider_context: { supported: false, reason: 'provider_not_supported' },
  context_window_tokens: null, max_output_tokens: null } },
  provider_context: { supported: false, reason: 'provider_not_supported' },
  async *invoke(input) {
    stats.invocations++;
    const frame = (sequence, payload) => ({ protocol_version: 'handrail.ai-runtime.v1',
      request_id: input.context.request_id, trace_id: input.context.trace_id, sequence, ...payload });
    let unblock;
    const wait = new Promise((resolve) => { unblock = resolve; release.set(input.context.request_id, resolve); });
    if (process.env.HANDRAIL_TEST_READ_VOLUME === '1') {
      if (input.signal.aborted) unblock();
      else input.signal.addEventListener('abort', () => { stats.providerAborts = (stats.providerAborts ?? 0) + 1; unblock(); }, { once: true });
    }
    yield frame(0, { type: 'response.started', attribution });
    const deltas = process.env.HANDRAIL_TEST_READ_VOLUME === '1' && stats.invocations === 1 ? 70 : 1;
    for (let i = 0; i < deltas; i++) {
      yield frame(i + 1, { type: 'response.text.delta', delta: deltas === 70 ? `delta${i} ` : 'Finished once' });
      // Simulated provider cadence, not a rate-window delay.
      if (deltas === 70) await new Promise(resolve => setTimeout(resolve, 100));
    }
    await wait;
    input.signal.removeEventListener('abort', unblock);
    if (input.signal.aborted) return { status: 'cancelled', reason: 'explicit_stop', usage: null };
    return { status: 'completed', outcome: 'stop', usage: { input_tokens: 0, cached_input_tokens: 0,
      output_tokens: 0, reasoning_tokens: 0, total_tokens: 0, provider_cost: { known: false } } };
  } };
const assistant = await createHandrailAssistant({ id: 'dart-test', authorize: () => context,
  ...(process.env.HANDRAIL_TEST_READ_VOLUME === '1' ? { diagnostics(event) {
    if (event.phase === 'failed') {
      stats.failures ??= [];
      if (stats.failures.length < 50) stats.failures.push({ operation: event.operation, code: event.code,
        cause: event.cause instanceof Error ? event.cause.message : event.cause });
    }
  } } : {}),
  attachmentUpload: false,
  persistence,
  provider: { metadata: adapter.metadata, createTransport(input) {
    return createProviderToolLoopTransport({ adapter, tools: [], limits: input.limits,
      createContext: () => ({ request_id: randomUUID(), trace_id: randomUUID(), attribution, correlation_hints: {} }),
      executeTool: () => { throw new Error('No tools in this fixture'); } });
  } } });
const dropped = new Set();
const volume = { startedAt: Date.now(), dispatches: [], maximumRolling60s: 0, historyConcurrency: 0, maximumHistoryConcurrency: 0 };
const sharedRequests = [];

// Opt-in, synthetic host authorization gate for the pre-send investigation.
// This process only listens on loopback and owns an isolated test database.
let traceDenied = false;
const server = createServer(async (request, response) => {
  let reader, volumeRow;
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString();
    if (process.env.HANDRAIL_TEST_READ_VOLUME === '1') {
      const now = Date.now(), shared = request.url.startsWith('/api/ai/'), diagnostic = !shared || request.headers['x-test-diagnostic'] === '1';
      volumeRow = { ms: now - volume.startedAt, path: request.url, phase: request.headers['x-test-phase'] ?? 'diagnostic',
        diagnostic, shared, operation: body ? JSON.parse(body).operation : undefined };
      volume.dispatches.push(volumeRow);
      if (shared) {
        while (sharedRequests.length && sharedRequests[0] <= now - 60000) sharedRequests.shift();
        sharedRequests.push(now); volumeRow.rolling60s = sharedRequests.length;
        volume.maximumRolling60s = Math.max(volume.maximumRolling60s, sharedRequests.length);
        if (sharedRequests.length > 120) {
          volumeRow.status = 429;
          response.writeHead(429, { 'content-type': 'application/json', 'retry-after': '60' });
          response.end(JSON.stringify({ ok: false, error: { code: 'rate_limited', message: '120/60s fixture limit', retryable: true } })); return;
        }
        if (request.url.endsWith('/conversations/history')) {
          volume.historyConcurrency++;
          volume.maximumHistoryConcurrency = Math.max(volume.maximumHistoryConcurrency, volume.historyConcurrency);
          const historyRequest = JSON.parse(body);
          const reads = historyRequest.operation === 'bundle' ? historyRequest.input.reads : [historyRequest];
          volumeRow.reads = reads.map(read => ({ operation: read.operation,
            view: read.input.view?.type, exactTurn: typeof read.input.turnId === 'string' }));
        }
      }
      if (request.url === '/test/volume') {
        response.end(JSON.stringify(volume)); return;
      }
      if (request.url === '/test/inspect-turn') {
        const { conversationId, turnId } = JSON.parse(body);
        const events = await bundle.events.read({ conversationId, limit: 1000 });
        const turn = await bundle.durableTurns.load(conversationId, turnId);
        response.end(JSON.stringify({ stats, turn, events: events.entries.map(e => e.event.payload) })); return;
      }
      if (request.url === '/test/settled') {
        const { conversationId, turnId, status = 'completed' } = JSON.parse(body);
        const deadline = Date.now() + 15000;
        for (;;) {
          const events = await bundle.events.read({ conversationId, limit: 1000 });
          if (events.entries.some(({ event }) => event.payload.turn_id === turnId && event.payload.type === `turn.${status}`)) break;
          if (Date.now() >= deadline) throw new Error(`Fixture turn did not settle: ${status}`);
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        response.end('{}'); return;
      }
    }
    if (process.env.HANDRAIL_TEST_PRESEND_TRACE === '1') {
      if (request.url === '/test/trace-clear' && dist) {
        const { conversationId } = JSON.parse(body);
        const revision = await bundle.events.getLatestRevision(conversationId);
        await bundle.events.append({ conversationId, expectedRevision: revision, events: [parseConversationEvent({
          version: 1, event_id: randomUUID(), conversation_id: conversationId, revision: (revision ?? 0) + 1,
          occurred_at: new Date().toISOString(), actor: { type: 'system' }, source: { type: 'runtime' },
          payload: { type: 'conversation.cleared' },
        })] });
        response.end('{}'); return;
      }
      if (request.url === '/test/trace-auth') {
        traceDenied = JSON.parse(body).denied === true;
        response.end('{}'); return;
      }
      if (traceDenied && request.url.startsWith('/api/ai/')) {
        response.writeHead(403, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ ok: false, error: {
          code: 'forbidden', message: 'Synthetic authorization revoked.', retryable: false,
        } })); return;
      }
    }
    if (request.url === '/test/stats') {
      response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(stats)); return;
    }
    if (request.url === '/test/history-seed' && dist) {
      const { conversationId, count, text } = JSON.parse(body);
      if (!Number.isSafeInteger(count) || count < 1 || count > 1000) throw new Error('Invalid fixture count');
      if (text !== undefined && (typeof text !== 'string' || text.length * count > 1_000_000)) throw new Error('Invalid fixture text');
      const revision = await bundle.events.getLatestRevision(conversationId);
      const events = Array.from({ length: count }, (_, index) => {
        const sequence = (revision ?? 0) + index + 1;
        return parseConversationEvent({ version: 1, event_id: randomUUID(), conversation_id: conversationId,
          revision: sequence, occurred_at: new Date(Date.UTC(2026, 8, 1, 0, 0, sequence)).toISOString(),
          actor: { type: 'user' }, source: { type: 'runtime' }, payload: {
            type: 'message.created', message_id: `history-${sequence}`, role: 'user',
            content: [{ type: 'text', text: text ?? `Saved message ${sequence}: ${'bounded history '.repeat(64)}` }] } });
      });
      await bundle.events.append({ conversationId, expectedRevision: revision, events });
      response.end('{}'); return;
    }
    if (request.url === '/test/propose') {
      const { conversationId, large } = JSON.parse(body);
      const proposalId = randomUUID(), turnId = randomUUID(), toolCallId = randomUUID();
      const occurredAt = new Date().toISOString(), expiresAt = new Date(Date.now() + 60000).toISOString();
      const arguments_ = { amount: 42, ...(large ? { body: '😀'.repeat(24000) } : {}) };
      const reviewedArguments = large ? { type: 'opaque_reference', argument_ref: assistantToolArgumentReference(arguments_) }
        : { type: 'redacted_json', value: arguments_ };
      const eventAttribution = { actor: { type: 'system' }, source: { type: 'runtime' } };
      const proposal = await bundle.approvals.create({ permissionContext: context, proposalId,
        groupId: conversationId, turnId, toolCallId, toolName: 'fixture_review', reviewedArguments,
        expiresAt, attribution: eventAttribution, idempotencyKey: proposalId, idempotencyFingerprint: proposalId });
      const payloads = [
        { type: 'message.created', message_id: `${turnId}-input`, role: 'user', content: [{ type: 'text', text: 'Review this change' }] },
        { type: 'turn.started', turn_id: turnId, input_message_ids: [`${turnId}-input`] },
        { type: 'tool_call.requested', turn_id: turnId, tool_call_id: toolCallId,
          name: 'fixture_review', arguments: arguments_ },
        { type: 'approval.proposal_created', proposal_id: proposalId, group_id: conversationId,
          turn_id: turnId, tool_call_id: toolCallId, tool_name: 'fixture_review',
          // Mirror the authoritative proposal, including normalized legacy expiry.
          reviewed_arguments: reviewedArguments, expires_at: proposal.expires_at, status: 'pending', proposal_version: 1 },
      ];
      await bundle.events.append({ conversationId, expectedRevision: null,
        events: payloads.map((payload, index) => parseConversationEvent({ version: 1,
          event_id: randomUUID(), conversation_id: conversationId, revision: index + 1,
          occurred_at: occurredAt, ...eventAttribution, payload })) });
      response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(large ? { proposal_id: proposalId } : proposal)); return;
    }
    if (request.url === '/test/advance-approval') {
      // Test-only execution-state advancement; no business tool is invoked.
      const { proposalId } = JSON.parse(body);
      for (const [status, expectedVersion] of [['executing', 2], ['executed', 3]]) {
        await bundle.approvals.transition({ permissionContext: context, proposalId, expectedVersion, status,
          attribution: { actor: { type: 'system' }, source: { type: 'runtime' } },
          idempotencyKey: `${proposalId}-${status}`, idempotencyFingerprint: `${proposalId}-${status}` });
      }
      response.end('{}'); return;
    }
    if (request.url === '/test/finish') {
      for (const finish of release.values()) finish(); release.clear(); response.end('{}'); return;
    }
    if (request.url.endsWith('/approvals/transition') || request.url.endsWith('/approvals/transition-display')) stats.decisions++;
    if (request.url.endsWith('/conversations/history')) stats.displayReads++;
    if (request.url.endsWith('/synchronization') && JSON.parse(body).operation === 'pull_snapshot') stats.snapshotReads++;
    if (request.url.endsWith('/turns/start')) stats.starts++;
    if (request.url.endsWith('/turns/resume')) stats.resumes++;
    if (request.url.endsWith('/conversations/permanent-delete')) stats.deletions++;
    const admission = request.url.endsWith('/synchronization') && JSON.parse(body).operation === 'append_mutations';
    if (admission) stats.admissions++;
    let result = await assistant.handle(new Request(`http://127.0.0.1${request.url}`, {
      method: request.method, headers: request.headers, ...(body ? { body } : {}) }));
    if (process.env.HANDRAIL_TEST_READ_VOLUME === '1' && request.headers['x-test-legacy-history'] === '1' && request.url.endsWith('/capabilities')) {
      const value = await result.json(); delete value.value.displayHistory.readBundle;
      result = Response.json(value, { status: result.status, headers: result.headers });
    }
    if (volumeRow) volumeRow.status = result.status;
    if (request.url.endsWith('/conversations/history')) {
      const data = await result.clone().arrayBuffer(), bytes = data.byteLength;
      stats.displayBytes += bytes; stats.maximumDisplayBytes = Math.max(stats.maximumDisplayBytes, bytes);
      if (volumeRow?.operation === 'bundle' && result.ok) {
        const envelope = JSON.parse(new TextDecoder().decode(data)).value;
        for (const entry of [envelope.tail, envelope.related]) if (entry) {
          volumeRow.reads.push({ operation: 'page', view: entry.input.view?.type, derived: true });
        }
      }
    }
    if (request.url.endsWith('/approvals/transition-display')) stats.maximumDecisionBytes = Math.max(stats.maximumDecisionBytes, (await result.clone().arrayBuffer()).byteLength);
    const loss = request.headers['x-test-lose-response'];
    const stage = typeof loss === 'string' ? loss.split(':').at(-1) : null;
    const matches = stage === 'approval' ? (request.url.endsWith('/approvals/transition') || request.url.endsWith('/approvals/transition-display'))
      : stage === 'admission' ? admission : stage === 'delete'
      ? request.url.endsWith('/conversations/permanent-delete')
      : stage === 'start' && request.url.endsWith('/turns/start');
    if (matches && !dropped.has(loss)) {
      dropped.add(loss); if (volumeRow) volumeRow.lostAcknowledgement = true;
      await result.body?.cancel(); response.destroy(); return;
    }
    if (volumeRow) volumeRow.status = result.status;
    response.writeHead(result.status, Object.fromEntries(result.headers));
    reader = result.body?.getReader();
    response.on('close', () => { reader?.cancel().catch(() => {}); });
    if (reader) for (;;) {
      const { done, value } = await reader.read();
      if (done || response.destroyed) break;
      response.write(value);
    }
    response.end();
  } catch (error) {
    process.stderr.write(`${error.stack}\n`);
    response.writeHead(500); response.end('{}');
  } finally {
    reader?.releaseLock();
    if (volumeRow) {
      volumeRow.endMs = Date.now() - volume.startedAt;
      if (request.url.endsWith('/conversations/history') && volumeRow.status !== 429) volume.historyConcurrency--;
    }
  }
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`http://127.0.0.1:${server.address().port}\n`));
process.once('SIGTERM', async () => {
  for (const finish of release.values()) finish();
  await assistant.stopBackgroundWorkers();
  await database?.close();
  server.closeAllConnections(); server.close();
});
