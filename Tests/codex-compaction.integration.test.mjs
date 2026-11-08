// Optional real-client regression: YMIR_CODEX_TEST_BINARY=/path/to/codex node --test Tests/codex-compaction.integration.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { adaptCopilotResponses } from '../Sources/Ymir/Resources/codex-usage-compat.mjs';

const binary = process.env.YMIR_CODEX_TEST_BINARY;
const handler = `const handleResponses = async (c) => {
\tconst payload = await c.req.json();
  const response = await responsesHandlerDependencies.createResponses(payload, {
    transport: 'http',
  });
  return response;
};`;

async function runCase(threshold) {
  const directory = mkdtempSync(join(tmpdir(), 'ymir-codex-regression-'));
  const original = 'A'.repeat(160000);
  let requests = 0;
  const violations = [];
  const createResponses = async payload => {
    for (const item of payload.input ?? []) {
      if (item.type === 'reasoning' && item.encrypted_content !== original) violations.push('reasoning changed upstream');
    }
    requests++;
    const message = { type: 'message', id: `msg_${requests}`, role: 'assistant', status: 'completed',
      content: [{ type: 'output_text', text: 'OK', annotations: [] }] };
    const output = requests === 1 ? [{ type: 'reasoning', id: 'rs_fixture', summary: [], encrypted_content: original }, message] : [message];
    const response = { id: `resp_${requests}`, object: 'response', status: 'completed', model: payload.model, output,
      usage: { input_tokens: requests === 1 ? 5000 : 34900, output_tokens: requests === 1 ? 30000 : 100,
        total_tokens: 35000, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: requests === 1 ? 29998 : 0 } } };
    async function* stream() {
      const events = [{ type: 'response.created', response: { ...response, output: [], status: 'in_progress' } }];
      for (const [index, item] of output.entries()) {
        events.push({ type: 'response.output_item.added', output_index: index, item });
        if (item.type === 'message') events.push({ type: 'response.output_text.delta', item_id: item.id, output_index: index, content_index: 0, delta: 'OK' });
        events.push({ type: 'response.output_item.done', output_index: index, item });
      }
      events.push({ type: 'response.completed', response });
      for (const event of events) yield { event: event.type, data: JSON.stringify(event) };
    }
    return stream();
  };
  const source = adaptCopilotResponses(handler);
  const handle = Function('responsesHandlerDependencies',
    `${source}; return handleResponses;`)({ createResponses });
  const server = http.createServer(async (req, res) => {
    try {
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const c = { req: { json: async () => JSON.parse(Buffer.concat(chunks)), header: key => req.headers[key] },
        header: (key, value) => res.setHeader(key, value), json: (body, status) => ({ body, status }) };
      const response = await handle(c);
      if (response.status) { res.writeHead(response.status); res.end(JSON.stringify(response.body)); return; }
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      for await (const chunk of response) res.write(`event: ${chunk.event}\ndata: ${chunk.data}\n\n`);
      res.end();
    } catch (error) { violations.push(error.message); res.destroy(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const toml = value => typeof value === 'object' && value !== null
    ? '{' + Object.entries(value).map(([key, v]) => JSON.stringify(key) + '=' + toml(v)).join(',') + '}' : JSON.stringify(value);
  const config = { model: 'gpt-6-astra', model_provider: 'ymir_test', model_context_window: 70000,
    model_auto_compact_token_limit: threshold,
    'model_providers.ymir_test': { name: 'Local test', base_url: `http://127.0.0.1:${server.address().port}`, wire_api: 'responses', requires_openai_auth: false },
    mcp_servers: {}, 'features.apps': false, 'features.shell_tool': false, 'analytics.enabled': false };
  const args = ['app-server', '--stdio', ...Object.entries(config).flatMap(([key, value]) => ['-c', key + '=' + toml(value)])];
  const child = spawn(binary, args, { stdio: ['pipe', 'pipe', 'ignore'] });
  const events = [];
  let notify;
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => { events.push(JSON.parse(line)); notify?.(); });
  let cursor = 0;
  const wait = async predicate => {
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      while (cursor < events.length) {
        const event = events[cursor++];
        if (event.error) throw new Error(JSON.stringify(event.error));
        if (predicate(event)) return event;
      }
      await new Promise(resolve => { const timer = setTimeout(resolve, 100); notify = () => { clearTimeout(timer); resolve(); }; });
    }
    throw new Error('Timed out waiting for Codex');
  };
  const send = (method, params, id) => child.stdin.write(JSON.stringify({ method, params, ...(id === undefined ? {} : { id }) }) + '\n');
  try {
    send('initialize', { clientInfo: { name: 'ymir_compaction_test', version: '1' }, capabilities: { experimentalApi: true } }, 1);
    await wait(e => e.id === 1); send('initialized', {});
    send('thread/start', { ephemeral: true, model: 'gpt-6-astra', modelProvider: 'ymir_test', cwd: directory,
      approvalPolicy: 'never', sandbox: 'read-only', baseInstructions: 'Reply with OK.', developerInstructions: '', environments: [], selectedCapabilityRoots: [] }, 2);
    const threadId = (await wait(e => e.id === 2)).result.thread.id;
    const turnIDs = [];
    for (let i = 0; i < 3; i++) {
      send('turn/start', { threadId, input: [{ type: 'text', text: 'Continue.' }] }, 3 + i);
      const event = await wait(e => e.method === 'turn/completed');
      assert.equal(event.params.turn.status, 'completed');
      turnIDs.push(event.params.turn.id);
    }
    assert.deepEqual(violations, []);
    const compactionTurns = events.filter(e => e.method === 'item/started' && e.params.item.type === 'contextCompaction')
      .map(e => turnIDs.indexOf(e.params.turnId) + 1);
    return { compactionTurns, requests };
  } finally {
    child.kill(); lines.close();
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true });
  }
}

test('real Codex: preserves reasoning without premature compaction below the threshold', { skip: !binary, timeout: 90000 }, async () => {
  assert.deepEqual(await runCase(60000), { compactionTurns: [], requests: 3 });
});

test('real Codex: compacts normally above the threshold', { skip: !binary, timeout: 90000 }, async () => {
  assert.deepEqual(await runCase(30000), { compactionTurns: [2, 3], requests: 5 });
});
