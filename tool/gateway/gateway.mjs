// Real SDK HTTP gateway, deterministic provider, in-memory persistence. This
// qualifies the cross-language protocol without credentials or billable usage.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { createHandrailAssistant, createProviderToolLoopTransport } from '@handrail/ai-assistant/server/assistant';
import {
  InMemoryConversationEventStore, InMemoryApprovalProposalStore,
  InMemoryConversationCatalog, InMemoryDurableApplicationTurnStore,
  InMemoryToolExecutionLedger,
} from '@handrail/ai-assistant';

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
const stats = { invocations: 0, starts: 0, resumes: 0, admissions: 0 };
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
    if (request.url === '/test/finish') {
      for (const finish of release.values()) finish(); release.clear(); response.end('{}'); return;
    }
    if (request.url.endsWith('/turns/start')) stats.starts++;
    if (request.url.endsWith('/turns/resume')) stats.resumes++;
    const admission = request.url.endsWith('/synchronization') && JSON.parse(body).operation === 'append_mutations';
    if (admission) stats.admissions++;
    const result = await assistant.handle(new Request(`http://127.0.0.1${request.url}`, {
      method: request.method, headers: request.headers, ...(body ? { body } : {}) }));
    const loss = request.headers['x-test-lose-response'];
    const stage = typeof loss === 'string' ? loss.split(':').at(-1) : null;
    const matches = stage === 'admission' ? admission : stage === 'start' && request.url.endsWith('/turns/start');
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
