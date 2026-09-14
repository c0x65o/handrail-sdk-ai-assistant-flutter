// Real SDK HTTP gateway, deterministic provider, in-memory persistence. This
// qualifies the cross-language protocol without credentials or billable usage.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
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
const bundle = { events: new InMemoryConversationEventStore(),
  approvals: new InMemoryApprovalProposalStore({ authorize: () => 'allow' }),
  catalog: new InMemoryConversationCatalog({ authorize: () => 'allow' }),
  durableTurns: new InMemoryDurableApplicationTurnStore(), toolLedger: new InMemoryToolExecutionLedger(),
  activity: { async list() { return [...records.values()]; },
    async upsert(record) { records.set(record.conversationId, record); return record; },
    async markRead(conversationId) { const record = records.get(conversationId); if (!record) return null;
      const read = { ...record, unread: false }; records.set(conversationId, read); return read; } },
  usageReceiptSink: null, usageAdmissions: null };
const stats = { invocations: 0, starts: 0, resumes: 0, admissions: 0, deletions: 0, decisions: 0 };
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
  persistence: { attachmentLimits: { maximumBytes: 1000, acceptedMediaTypes: ['text/plain'], ttlMilliseconds: 60000 },
    persistence: {}, forScope: () => bundle },
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
        { type: 'tool_call.requested', turn_id: turnId, tool_call_id: toolCallId,
          name: 'fixture_review', arguments: { amount: 42 } },
        { type: 'approval.proposal_created', proposal_id: proposalId, group_id: conversationId,
          turn_id: turnId, tool_call_id: toolCallId, tool_name: 'fixture_review',
          reviewed_arguments: reviewedArguments, expires_at: expiresAt, status: 'pending', proposal_version: 1 },
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
    if (request.url.endsWith('/turns/start')) stats.starts++;
    if (request.url.endsWith('/turns/resume')) stats.resumes++;
    if (request.url.endsWith('/conversations/permanent-delete')) stats.deletions++;
    const admission = request.url.endsWith('/synchronization') && JSON.parse(body).operation === 'append_mutations';
    if (admission) stats.admissions++;
    const result = await assistant.handle(new Request(`http://127.0.0.1${request.url}`, {
      method: request.method, headers: request.headers, ...(body ? { body } : {}) }));
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
