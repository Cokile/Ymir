import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { adaptCopilotRequestRetry, fetchCopilotResponsesWithRetry } from '../Sources/Ymir/Resources/copilot-request-retry.mjs';

const timeoutMessage = 'Timed out reading request body. Try again, or use a smaller request size.';
const timeoutBody = { error: { code: 'user_request_timeout', message: timeoutMessage } };
const timeoutResponse = (id = 'upstream-request') => Response.json(timeoutBody, {
  status: 408, headers: { 'x-request-id': id },
});

// The native HTTP transport from the pinned gateway. check-gateway runs these
// same tests against the downloaded server bundle instead of this fixture.
const fixture = `const createHttpResponses = async (payload, headers, clientSignal) => {
\tconst transportConfig = getUpstreamTransportConfig();
\tconst response = await fetchUpstreamWithLifecycle(\`\${copilotBaseUrl(state)}/responses\`, {
\t\tmethod: "POST",
\t\theaders,
\t\tbody: JSON.stringify(payload)
\t}, {
\t\tclientSignal,
\t\theadersTimeoutMs: transportConfig.headersTimeoutMs,
\t\tstreamInactivityTimeoutMs: transportConfig.streamInactivityTimeoutMs
\t});
\tlogCopilotRateLimits(response.headers);
\tif (!response.ok) {
\t\tconsola.error("Failed to create responses", response);
\t\tthrow new HTTPError("Failed to create responses", response);
\t}
\tif (payload.stream) return createResponsesSafeStream(createResponsesHttpEventStream(response));
\treturn await response.json();
};
const prepareResponsesWebSocketRequest = () => {};`;
const source = process.env.YMIR_GATEWAY_SERVER_BUNDLE
  ? readFileSync(process.env.YMIR_GATEWAY_SERVER_BUNDLE, 'utf8') : fixture;

class HTTPError extends Error {
  constructor(message, response) { super(message); this.response = response; }
}

function nativeTransport(fetchUpstream, retryDependencies = {}) {
  const adapted = adaptCopilotRequestRetry(source);
  const start = adapted.indexOf('const createHttpResponses = async');
  const end = adapted.indexOf('const prepareResponsesWebSocketRequest =', start);
  assert.ok(start >= 0 && end > start, 'Native HTTP transport boundary changed');
  const calls = [], delays = [], logs = [];
  const dependencies = {
    state: {}, copilotBaseUrl: () => 'https://copilot.test',
    requestContext: { getStore: () => ({ traceId: 'local-trace' }) },
    getUpstreamTransportConfig: () => ({ headersTimeoutMs: 300000, streamInactivityTimeoutMs: 300000 }),
    fetchUpstreamWithLifecycle: async (...args) => { calls.push(args); return fetchUpstream(...args); },
    ymirFetchCopilotResponses: (...args) => fetchCopilotResponsesWithRetry(...args, {
      wait: async ms => { delays.push(ms); }, log: line => logs.push(line), ...retryDependencies,
    }),
    logCopilotRateLimits() {}, consola: { error() {} }, HTTPError,
    // Keep streams lazy so tests can prove an accepted response is never replayed.
    createResponsesSafeStream: stream => stream,
    createResponsesHttpEventStream: response => response.body,
  };
  const handle = Function(...Object.keys(dependencies),
    adapted.slice(start, end) + '\nreturn createHttpResponses;')(...Object.values(dependencies));
  return { handle, calls, delays, logs, records: () => logs.map(line => JSON.parse(line.slice('Ymir request: '.length))) };
}

test('native HTTP transport recovers from Copilot body timeout without changing the request', async () => {
  const rejected = timeoutResponse();
  let attempts = 0;
  const transport = nativeTransport(async () => ++attempts === 1 ? rejected : Response.json({ id: 'ok' }));
  const payload = { model: 'gpt-6-astra', input: [{ type: 'reasoning', encrypted_content: 'unchanged' }] };
  const headers = { authorization: 'test-secret', 'x-request-id': 'stable-request', 'x-session-id': 'stable-session' };
  const signal = new AbortController().signal;
  assert.deepEqual(await transport.handle(payload, headers, signal), { id: 'ok' });
  assert.equal(transport.calls.length, 2);
  assert.deepEqual(transport.calls[0], transport.calls[1]);
  assert.equal(transport.calls[1][1].body, JSON.stringify(payload));
  assert.equal(transport.calls[1][2].clientSignal, signal);
  assert.equal(rejected.bodyUsed, true, 'Release the rejected response before another attempt');
  assert.deepEqual(transport.delays, [500]);
  assert.equal(transport.records().filter(record => record.event === 'retry_scheduled').length, 1);
  assert.doesNotMatch(transport.logs.join(' '), /test-secret|unchanged/);
});

test('retries are bounded and the final upstream error, body and request ID survive', async () => {
  let attempts = 0;
  const transport = nativeTransport(async () => timeoutResponse(`request-${++attempts}`));
  await assert.rejects(transport.handle({}, {}, undefined), asyncError => {
    assert.ok(asyncError instanceof HTTPError);
    assert.equal(asyncError.response.status, 408);
    assert.equal(asyncError.response.headers.get('x-request-id'), 'request-3');
    assert.equal(asyncError.response.bodyUsed, false);
    return true;
  });
  assert.equal(transport.calls.length, 3);
  assert.deepEqual(transport.delays, [500, 1000]);
  assert.equal(transport.records().at(-1).event, 'request_rejected');
  assert.equal(transport.records().at(-1).retries_exhausted, true);
  assert.equal(transport.records().at(-1).error_code, 'user_request_timeout');
  assert.equal(transport.records().at(-1).upstream_request_id, 'request-3');
});

test('returns the exact final error body after retry exhaustion', async () => {
  const transport = nativeTransport(async () => timeoutResponse());
  try { await transport.handle({}, {}, undefined); assert.fail('Expected HTTPError'); }
  catch (error) { assert.deepEqual(await error.response.json(), timeoutBody); }
});

for (const [label, response] of [
  ['different 408 code', () => Response.json({ error: { code: 'other_timeout' } }, { status: 408 })],
  ['non-JSON 408', () => new Response('Request Timeout', { status: 408 })],
  ['authentication error', () => Response.json(timeoutBody, { status: 401 })],
  ['rate limit', () => Response.json(timeoutBody, { status: 429 })],
  ['server error', () => Response.json(timeoutBody, { status: 500 })],
]) {
  test(`does not retry or consume a ${label}`, async () => {
    const original = response();
    const expected = await original.clone().text();
    const transport = nativeTransport(async () => original);
    await assert.rejects(transport.handle({}, {}, undefined), error => error.response === original);
    assert.equal(await original.text(), expected);
    assert.equal(transport.calls.length, 1);
    assert.deepEqual(transport.delays, []);
  });
}

test('does not replay ambiguous network failures', async () => {
  const failure = new TypeError('fetch failed');
  const transport = nativeTransport(async () => { throw failure; });
  await assert.rejects(transport.handle({}, {}, undefined), error => error === failure);
  assert.equal(transport.calls.length, 1);
});

test('does not retry an accepted stream, even if it later fails', async () => {
  let failStream;
  const body = new ReadableStream({ start(controller) { failStream = () => controller.error(new Error('stream lost')); } });
  const transport = nativeTransport(async () => new Response(body));
  const stream = await transport.handle({ stream: true }, {}, undefined);
  failStream();
  await assert.rejects(new Response(stream).text(), /stream lost/);
  assert.equal(transport.calls.length, 1);
});

test('can recover before opening a streaming response', async () => {
  let attempts = 0;
  const events = 'event: response.completed\ndata: {"id":"ok"}\n\n';
  const transport = nativeTransport(async () => ++attempts === 1 ? timeoutResponse() : new Response(events));
  assert.equal(await new Response(await transport.handle({ stream: true }, {}, undefined)).text(), events);
  assert.equal(transport.calls.length, 2);
});

test('already-cancelled clients never send a request', async () => {
  const transport = nativeTransport(async () => Response.json({ id: 'ok' }));
  await assert.rejects(transport.handle({}, {}, AbortSignal.abort()), { name: 'AbortError' });
  assert.equal(transport.calls.length, 0);
});

test('cancellation during real backoff prevents another upload', async () => {
  const controller = new AbortController();
  const transport = nativeTransport(async () => timeoutResponse(), {
    wait: undefined, log: line => {
      if (line.includes('"event":"retry_scheduled"')) setTimeout(() => controller.abort(), 5);
    },
  });
  await assert.rejects(transport.handle({}, {}, controller.signal), { name: 'AbortError' });
  assert.equal(transport.calls.length, 1);
});

test('does not retry a non-replayable request body', async () => {
  let attempts = 0;
  const original = timeoutResponse();
  const result = await fetchCopilotResponsesWithRetry(async () => { attempts++; return original; },
    'https://copilot.test/responses', { body: new ReadableStream() }, {}, {}, { log() {} });
  assert.equal(result, original);
  assert.equal(attempts, 1);
  assert.equal(original.bodyUsed, false);
});

test('diagnostics correlate retries and record sizes, counts and header latency without request content', async () => {
  let time = 0, attempts = 0;
  const transport = nativeTransport(async () => {
    time += 60000;
    return ++attempts === 1 ? timeoutResponse('failure-id')
      : Response.json({ id: 'ok' }, { headers: { 'x-request-id': 'success-id', 'x-oai-request-id': 'oai-id' } });
  }, { now: () => time, wait: async ms => { time += ms; } });
  const payload = {
    model: 'gpt-6-astra', stream: false,
    instructions: 'private-instructions',
    input: [
      { role: 'user', content: [{ type: 'input_text', text: 'private-prompt 🌏' }, { type: 'input_image', image_url: 'private-image' }] },
      { type: 'reasoning', encrypted_content: 'private-reasoning' },
      { type: 'function_call_output', output: 'private-tool-output' },
    ],
    tools: [{ type: 'function', name: 'private-tool-name', description: 'private-description' }],
  };
  await transport.handle(payload, { authorization: 'private-key', 'x-request-id': 'sent-id', 'x-interaction-id': 'session-id' }, undefined);
  const records = transport.records();
  assert.deepEqual(records.map(record => record.event), [
    'request_started', 'attempt_started', 'attempt_response', 'retry_scheduled',
    'attempt_started', 'attempt_response', 'request_accepted',
  ]);
  assert.equal(new Set(records.map(record => record.diagnostic_id)).size, 1);
  assert.ok(records.every(record => record.trace_id === 'local-trace' && !Number.isNaN(Date.parse(record.timestamp))));
  const start = records[0];
  assert.equal(start.body_bytes, Buffer.byteLength(JSON.stringify(payload), 'utf8'));
  assert.equal(start.model, payload.model);
  assert.equal(start.stream, false);
  assert.equal(start.input_items, 3);
  assert.equal(start.tools, 1);
  assert.equal(start.reasoning_items, 1);
  assert.equal(start.encrypted_reasoning_bytes, Buffer.byteLength('private-reasoning'));
  assert.equal(start.images, 1);
  assert.equal(start.tool_output_items, 1);
  assert.equal(start.upstream_host, 'copilot.test');
  assert.equal(start.sent_request_id, 'sent-id');
  assert.equal(start.interaction_id, 'session-id');
  assert.equal(start.headers_timeout_ms, 300000);
  assert.equal(records[2].headers_ms, 60000);
  assert.equal(records[2].upstream_request_id, 'failure-id');
  assert.equal(records.at(-1).upstream_oai_request_id, 'oai-id');
  assert.equal(records.at(-1).total_ms, 120500);
  assert.equal(records.at(-1).attempt, 2);
  assert.doesNotMatch(transport.logs.join('\n'), /private-/);
});

test('diagnostics retain transport error codes without logging messages or URLs', async () => {
  const failure = new TypeError('private request details', { cause: Object.assign(new Error('private upstream URL'), { code: 'ETIMEDOUT' }) });
  const transport = nativeTransport(async () => { throw failure; });
  await assert.rejects(transport.handle({}, {}, undefined), error => error === failure);
  const last = transport.records().at(-1);
  assert.equal(last.event, 'request_failed');
  assert.equal(last.error_name, 'TypeError');
  assert.equal(last.cause_code, 'ETIMEDOUT');
  assert.doesNotMatch(transport.logs.join('\n'), /private/);
});

test('cancellation is recorded separately from transport failure', async () => {
  const transport = nativeTransport(async () => Response.json({ id: 'ok' }));
  await assert.rejects(transport.handle({}, {}, AbortSignal.abort()), { name: 'AbortError' });
  assert.equal(transport.records().at(-1).event, 'request_cancelled');
  assert.equal(transport.records().some(record => record.event === 'attempt_started'), false);
});

test('concurrent requests have distinct diagnostic IDs despite shared gateway trace IDs', async () => {
  const transport = nativeTransport(async () => Response.json({ id: 'ok' }));
  await Promise.all(['first', 'second'].map(model => transport.handle({ model }, {}, undefined)));
  const records = transport.records();
  const starts = records.filter(record => record.event === 'request_started');
  assert.equal(new Set(starts.map(record => record.diagnostic_id)).size, 2);
  for (const start of starts) {
    const request = records.filter(record => record.diagnostic_id === start.diagnostic_id);
    assert.deepEqual(request.map(record => record.event), ['request_started', 'attempt_started', 'attempt_response', 'request_accepted']);
  }
});

test('a broken log sink does not change successful requests or timeout recovery', async () => {
  let attempts = 0;
  const transport = nativeTransport(async () => ++attempts === 1 ? timeoutResponse() : Response.json({ id: 'ok' }), {
    log: () => { throw new Error('log sink failed'); },
  });
  assert.deepEqual(await transport.handle({}, {}, undefined), { id: 'ok' });
  assert.equal(transport.calls.length, 2);
});

test('adapter changes only native HTTP Responses and rejects unexpected bundle shapes', () => {
  const otherRoute = 'const other = () => fetchUpstreamWithLifecycle(url, init, options);';
  const adapted = adaptCopilotRequestRetry(fixture + otherRoute);
  assert.ok(adapted.includes(otherRoute));
  assert.equal(adaptCopilotRequestRetry(adapted), adapted);
  assert.throws(() => adaptCopilotRequestRetry(''), /HTTP Responses transport changed/);
  assert.throws(() => adaptCopilotRequestRetry(fixture + fixture), /HTTP Responses transport changed/);
  assert.throws(() => adaptCopilotRequestRetry(fixture.replace('body: JSON.stringify(payload)', 'body: payload')), /HTTP Responses transport changed/);
});
