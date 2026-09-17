// Real installed SDK gateway with deterministic storage/provider seams.
// An explicit local build may qualify source, but never establishes adoption.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { createRequire } from 'node:module';
const dist = process.env.HANDRAIL_TEST_JS_SDK_DIST;
const sdk = await import(dist ? pathToFileURL(resolve(dist, 'index.js')).href : '@handrail/ai-assistant');
const { createHandrailAssistant, createProviderToolLoopTransport } = await import(dist
  ? pathToFileURL(resolve(dist, 'server/assistant.js')).href : '@handrail/ai-assistant/server/assistant');
const limits = { maximumBytes: 1024, acceptedMediaTypes: ['application/pdf'], ttlMilliseconds: 60_000 };
let postgres, ownedDatabase;
if (dist) {
  // The current high-level SDK owns indexed history in PostgreSQL. Source
  // qualification must supply that declared contract, not a partial mock.
  const { PGlite } = createRequire(resolve(dist, '../package.json'))('@electric-sql/pglite');
  const { postgresFromClient } = await import(pathToFileURL(resolve(dist, 'postgres/index.js')).href);
  const database = ownedDatabase = new PGlite();
  const adapt = db => {
    const client = { async query(sql, values = []) {
      const result = await db.query(sql, [...values]);
      return { rows: result.rows, rowCount: result.affectedRows ?? result.rows.length };
    }, transaction: operation => operation(client) };
    return client;
  };
  const client = { query: adapt(database).query,
    transaction: operation => database.transaction(tx => operation(adapt(tx))) };
  postgres = postgresFromClient(client, { attachmentLimits: limits });
  await postgres.persistence.migrate();
}
const bundles = new Map();
let clock = Date.now();
function bundleFor(context) {
  const key = context.tenantId + ':' + context.scopeId;
  if (bundles.has(key)) return bundles.get(key);
  const metadata = new Map(), bytes = new Map(), activity = new Map();
  const attachments = sdk.createAttachmentStagingService({ limits, now: () => clock,
    blobs: { async put(input) { bytes.set(input.key, input.bytes); }, async get(key) { return bytes.get(key) ?? null; }, async delete(key) { bytes.delete(key); } },
    metadata: {
      async getByIdempotency(owner, conversation, identity) { return [...metadata.values()].find(r => r.ownerScopeId === owner && r.conversationId === conversation && r.idempotencyKey === identity) ?? null; },
      async getByContentRef(ref) { return metadata.get(ref) ?? null; },
      async getByAttachmentId(owner, conversation, id) { return [...metadata.values()].find(r => r.ownerScopeId === owner && r.conversationId === conversation && r.attachmentId === id) ?? null; },
      async create(record) { metadata.set(record.contentRef, record); return 'created'; },
      async markConsumed(ref, consumedAt) { metadata.set(ref, { ...metadata.get(ref), consumedAt }); },
      async listExpired(before) { return [...metadata.values()].filter(r => r.expiresAt <= before); },
      async delete(ref) { metadata.delete(ref); },
    } });
  const bundle = postgres ? { ...postgres.forScope(context, { createConversationId: randomUUID,
    authorizeConversation: () => 'allow', authorizeApproval: () => 'allow' }), attachments }
    : { attachments, events: new sdk.InMemoryConversationEventStore(),
    approvals: new sdk.InMemoryApprovalProposalStore({ authorize: () => 'allow' }),
    catalog: new sdk.InMemoryConversationCatalog({ authorize: () => 'allow' }),
    durableTurns: new sdk.InMemoryDurableApplicationTurnStore(), toolLedger: new sdk.InMemoryToolExecutionLedger(),
    activity: { async list() { return [...activity.values()]; }, async upsert(record) { activity.set(record.conversationId, record); return record; },
      async markRead(id) { const old = activity.get(id); if (!old) return null; const next = { ...old, unread: false }; activity.set(id, next); return next; } },
    usageReceiptSink: null, usageAdmissions: null };
  bundles.set(key, bundle); return bundle;
}
const attribution = (user) => Object.fromEntries(Object.entries({ organization: 'org', project: 'project', service_environment: 'test',
  known_user: user, session: null, automation: null }).map(([key, id]) => [key, { id, source: 'server_derived', trust: 'authoritative' }]));
const metadata = { provider_id: 'fixture', model_id: 'fixture', capabilities: {
  streaming: true, text: true, tool_calls: false, parallel_tool_calls: false, reasoning: false,
  document_input: { supported: true, capability: { supported_mime_types: ['application/pdf'], max_document_count: 2, max_document_bytes: 1024, requires_host_resolution: true } },
  provider_context: { supported: false, reason: 'provider_not_supported' }, context_window_tokens: null, max_output_tokens: null,
} };
const assistant = await createHandrailAssistant({ id: 'dart-attachments', attachmentUpload: true,
  authorize: (request) => { const user = request.headers.get('x-fixture-user');
    if (!['alice', 'bob'].includes(user)) throw new Error('Unauthenticated fixture');
    return { tenantId: 'fixture', scopeId: user, principalId: user, attribution: attribution(user) }; },
  persistence: { ...(postgres ?? { persistence: {} }), attachmentLimits: limits, forScope: bundleFor },
  provider: { metadata, createTransport(input) {
    const adapter = { metadata, provider_context: metadata.capabilities.provider_context,
      async *invoke(invocation) {
        yield { protocol_version: 'handrail.ai-runtime.v1', request_id: invocation.context.request_id,
          trace_id: invocation.context.trace_id, sequence: 0, type: 'response.started', attribution: input.context.attribution };
        yield { protocol_version: 'handrail.ai-runtime.v1', request_id: invocation.context.request_id,
          trace_id: invocation.context.trace_id, sequence: 1, type: 'response.text.delta', delta: 'Saved your file.' };
        return { status: 'completed', outcome: 'stop', usage: { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0,
          reasoning_tokens: 0, total_tokens: 0, provider_cost: { known: false } } };
      } };
    return createProviderToolLoopTransport({ adapter, tools: [], limits: input.limits,
      createContext: () => ({ request_id: randomUUID(), trace_id: randomUUID(), attribution: input.context.attribution, correlation_hints: {} }),
      executeTool: () => { throw new Error('No fixture tools'); } });
  } } });
const server = createServer(async (request, response) => {
  let reader;
  try {
    if (request.url === '/test/expire' && request.method === 'POST') { clock += 61_000; response.end('{}'); return; }
    const chunks = []; for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const result = await assistant.handle(new Request(`http://127.0.0.1${request.url}`, { method: request.method,
      headers: request.headers, ...(body.length ? { body } : {}) }));
    response.writeHead(result.status, Object.fromEntries(result.headers));
    reader = result.body?.getReader();
    response.on('close', () => { reader?.cancel().catch(() => {}); });
    if (reader) for (;;) { const { done, value } = await reader.read(); if (done || response.destroyed) break; response.write(value); }
    response.end();
  } catch (error) { process.stderr.write(String(error) + '\n'); response.writeHead(500); response.end('{}'); }
  finally { reader?.releaseLock(); }
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`http://127.0.0.1:${server.address().port}\n`));
process.on('SIGTERM', async () => {
  server.closeAllConnections();
  await assistant.stopUsageWorker();
  await ownedDatabase?.close();
  server.close(() => process.exit(0));
});
