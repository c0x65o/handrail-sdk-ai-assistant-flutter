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
  InMemoryToolExecutionLedger, parseConversationEvent,
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
  displayReads: 0, snapshotReads: 0, displayBytes: 0, maximumDisplayBytes: 0 };
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
    const wait = new Promise((resolve) => release.set(input.context.request_id, resolve));
    yield frame(0, { type: 'response.started', attribution });
    yield frame(1, { type: 'response.text.delta', delta: 'Finished once' });
    await wait;
    return { status: 'completed', outcome: 'stop', usage: { input_tokens: 0, cached_input_tokens: 0,
      output_tokens: 0, reasoning_tokens: 0, total_tokens: 0, provider_cost: { known: false } } };
  } };
const assistant = await createHandrailAssistant({ id: 'dart-test', authorize: () => context,
  attachmentUpload: false,
  persistence,
  provider: { metadata: adapter.metadata, createTransport(input) {
    return createProviderToolLoopTransport({ adapter, tools: [], limits: input.limits,
      createContext: () => ({ request_id: randomUUID(), trace_id: randomUUID(), attribution, correlation_hints: {} }),
      executeTool: () => { throw new Error('No tools in this fixture'); } });
  } } });
const dropped = new Set();
const server = createServer(async (request, response) => {
  let reader;
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString();
    if (request.url === '/test/stats') {
      response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(stats)); return;
    }
    if (request.url === '/test/history-seed' && dist) {
      const { conversationId, count } = JSON.parse(body);
      if (!Number.isSafeInteger(count) || count < 1 || count > 1000) throw new Error('Invalid fixture count');
      const revision = await bundle.events.getLatestRevision(conversationId);
      const events = Array.from({ length: count }, (_, index) => {
        const sequence = (revision ?? 0) + index + 1;
        return parseConversationEvent({ version: 1, event_id: randomUUID(), conversation_id: conversationId,
          revision: sequence, occurred_at: new Date(Date.UTC(2026, 8, 1, 0, 0, sequence)).toISOString(),
          actor: { type: 'user' }, source: { type: 'runtime' }, payload: {
            type: 'message.created', message_id: `history-${sequence}`, role: 'user',
            content: [{ type: 'text', text: `Saved message ${sequence}: ${'bounded history '.repeat(64)}` }] } });
      });
      await bundle.events.append({ conversationId, expectedRevision: revision, events });
      response.end('{}'); return;
    }
    if (request.url === '/test/propose') {
      const { conversationId } = JSON.parse(body);
      const proposalId = randomUUID(), turnId = randomUUID(), toolCallId = randomUUID();
      const occurredAt = new Date().toISOString(), expiresAt = new Date(Date.now() + 60000).toISOString();
      const reviewedArguments = { type: 'redacted_json', value: { amount: 42 } };
      const eventAttribution = { actor: { type: 'system' }, source: { type: 'runtime' } };
      const proposal = await bundle.approvals.create({ permissionContext: context, proposalId,
        groupId: conversationId, turnId, toolCallId, toolName: 'fixture_review', reviewedArguments,
        expiresAt, attribution: eventAttribution, idempotencyKey: proposalId, idempotencyFingerprint: proposalId });
      const payloads = [
        { type: 'message.created', message_id: `${turnId}-input`, role: 'user', content: [{ type: 'text', text: 'Review this change' }] },
        { type: 'turn.started', turn_id: turnId, input_message_ids: [`${turnId}-input`] },
        { type: 'tool_call.requested', turn_id: turnId, tool_call_id: toolCallId,
          name: 'fixture_review', arguments: { amount: 42 } },
        { type: 'approval.proposal_created', proposal_id: proposalId, group_id: conversationId,
          turn_id: turnId, tool_call_id: toolCallId, tool_name: 'fixture_review',
          // Mirror the authoritative proposal, including normalized legacy expiry.
          reviewed_arguments: reviewedArguments, expires_at: proposal.expires_at, status: 'pending', proposal_version: 1 },
      ];
      await bundle.events.append({ conversationId, expectedRevision: null,
        events: payloads.map((payload, index) => parseConversationEvent({ version: 1,
          event_id: randomUUID(), conversation_id: conversationId, revision: index + 1,
          occurred_at: occurredAt, ...eventAttribution, payload })) });
      response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(proposal)); return;
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
    if (request.url.endsWith('/approvals/transition')) stats.decisions++;
    if (request.url.endsWith('/conversations/history')) stats.displayReads++;
    if (request.url.endsWith('/synchronization') && JSON.parse(body).operation === 'pull_snapshot') stats.snapshotReads++;
    if (request.url.endsWith('/turns/start')) stats.starts++;
    if (request.url.endsWith('/turns/resume')) stats.resumes++;
    if (request.url.endsWith('/conversations/permanent-delete')) stats.deletions++;
    const admission = request.url.endsWith('/synchronization') && JSON.parse(body).operation === 'append_mutations';
    if (admission) stats.admissions++;
    const result = await assistant.handle(new Request(`http://127.0.0.1${request.url}`, {
      method: request.method, headers: request.headers, ...(body ? { body } : {}) }));
    if (request.url.endsWith('/conversations/history')) {
      const bytes = (await result.clone().arrayBuffer()).byteLength;
      stats.displayBytes += bytes; stats.maximumDisplayBytes = Math.max(stats.maximumDisplayBytes, bytes);
    }
    const loss = request.headers['x-test-lose-response'];
    const stage = typeof loss === 'string' ? loss.split(':').at(-1) : null;
    const matches = stage === 'approval' ? request.url.endsWith('/approvals/transition')
      : stage === 'admission' ? admission : stage === 'delete'
      ? request.url.endsWith('/conversations/permanent-delete')
      : stage === 'start' && request.url.endsWith('/turns/start');
    if (matches && !dropped.has(loss)) {
      dropped.add(loss); await result.body?.cancel(); response.destroy(); return;
    }
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
  } finally { reader?.releaseLock(); }
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`http://127.0.0.1:${server.address().port}\n`));
process.once('SIGTERM', async () => {
  for (const finish of release.values()) finish();
  await assistant.stopBackgroundWorkers();
  await database?.close();
  server.closeAllConnections(); server.close();
});
