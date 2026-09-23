import assert from 'node:assert/strict';
import test from 'node:test';
import { adaptRaycastRoutes } from '../Sources/Ymir/Resources/codex-usage-compat.mjs';
import { toResponses, toChatCompletion, toChatStream, handleRaycastRequest } from '../Sources/Ymir/Resources/raycast-compat.mjs';

const completed = {
  id: 'resp_1', created_at: 1, status: 'completed',
  output: [{ type: 'message', content: [{ type: 'output_text', text: 'Hello 🌏' }] }],
  usage: { input_tokens: 3, output_tokens: 2, total_tokens: 5, output_tokens_details: { reasoning_tokens: 1 } },
};
const call = { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'weather', arguments: '{"city":"Paris"}' };

test('converts conversation, images, tool results, and request options', () => {
  const result = toResponses({
    model: 'reasoner', stream: true, max_tokens: 100, max_completion_tokens: 200, reasoning_effort: 'low',
    tools: [{ type: 'function', function: { name: 'weather', parameters: { type: 'object' } } }],
    tool_choice: { type: 'function', function: { name: 'weather' } },
    response_format: { type: 'json_schema', json_schema: { name: 'answer', schema: { type: 'object' } } },
    messages: [
      { role: 'system', content: 'Be brief' },
      { role: 'user', content: [{ type: 'text', text: 'Look' }, { type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } }] },
      { role: 'assistant', content: 'Checking', tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'weather', arguments: '{}' } }] },
      { role: 'tool', tool_call_id: 'call_1', content: 'sunny' },
    ],
  });
  assert.equal(result.max_output_tokens, 200);
  assert.deepEqual(result.reasoning, { effort: 'low' });
  assert.equal(result.store, false);
  assert.deepEqual(result.input.map(item => item.type), ['message', 'message', 'message', 'function_call', 'function_call_output']);
  assert.equal(result.input[1].content[1].type, 'input_image');
  assert.equal(result.input[2].content[0].type, 'output_text');
  assert.equal(result.input[4].call_id, 'call_1');
  assert.deepEqual(result.tool_choice, { type: 'function', name: 'weather' });
  assert.equal(result.tools[0].name, 'weather');
  assert.equal(result.text.format.name, 'answer');
  assert.throws(() => toResponses({ messages: [{ role: 'user', content: [{ type: 'input_audio' }] }] }), /Unsupported content/);
  assert.throws(() => toResponses({ messages: [], n: 2 }), /n=1/);
});

test('converts completion, token usage, tools and incomplete responses', () => {
  const result = toChatCompletion(completed, 'reasoner');
  assert.equal(result.choices[0].message.content, 'Hello 🌏');
  assert.equal(result.usage.total_tokens, 5);
  assert.equal(result.usage.completion_tokens_details.reasoning_tokens, 1);
  const tools = toChatCompletion({ ...completed, output: [call] }, 'reasoner');
  assert.equal(tools.choices[0].finish_reason, 'tool_calls');
  assert.equal(tools.choices[0].message.tool_calls[0].id, 'call_1');
  assert.equal(toChatCompletion({ ...completed, status: 'incomplete' }, 'reasoner').choices[0].finish_reason, 'length');
  assert.throws(() => toChatCompletion({ status: 'failed', error: { message: 'Denied' } }), /Denied/);
});

function sse(events) {
  const bytes = new TextEncoder().encode(events.map(event => `event: ${event.type}\r\ndata: ${JSON.stringify(event)}\r\n\r\n`).join(''));
  return new Response(new ReadableStream({ start(controller) {
    // Split every byte, including Unicode and CRLF, to exercise stream framing.
    for (const byte of bytes) controller.enqueue(new Uint8Array([byte]));
    controller.close();
  } }));
}
async function chunks(response) {
  const text = await response.text();
  return text.split('\n').filter(line => line.startsWith('data: ')).map(line => line.slice(6)).map(value => value === '[DONE]' ? value : JSON.parse(value));
}

test('streams text incrementally and returns usage with a terminal marker', async () => {
  const result = await chunks(toChatStream(sse([
    { type: 'response.created', response: { id: 'resp_1', created_at: 1 } },
    { type: 'response.output_text.delta', delta: 'Hello ' },
    { type: 'response.output_text.delta', delta: '🌏' },
    { type: 'response.completed', response: completed },
  ]), { model: 'reasoner', stream_options: { include_usage: true } }));
  assert.equal(result.filter(c => c.choices?.[0]?.delta?.content).map(c => c.choices[0].delta.content).join(''), 'Hello 🌏');
  assert.equal(result.at(-1), '[DONE]');
  assert.equal(result.at(-2).usage.total_tokens, 5);
  assert.equal(result.at(-3).choices[0].finish_reason, 'stop');
});

test('streams parallel function calls using separate tool indexes', async () => {
  const other = { ...call, id: 'fc_2', call_id: 'call_2', name: 'clock', arguments: '{}' };
  const result = await chunks(toChatStream(sse([
    { type: 'response.output_item.added', item: { ...call, arguments: '' } },
    { type: 'response.output_item.added', item: { ...other, arguments: '' } },
    { type: 'response.function_call_arguments.delta', item_id: 'fc_2', delta: '{}' },
    { type: 'response.function_call_arguments.delta', item_id: 'fc_1', delta: call.arguments },
    { type: 'response.completed', response: { ...completed, output: [call, other] } },
  ]), { model: 'reasoner' }));
  const deltas = result.flatMap(c => c.choices?.[0]?.delta?.tool_calls ?? []);
  assert.deepEqual(deltas.filter(d => d.id).map(d => [d.index, d.id]), [[0, 'call_1'], [1, 'call_2']]);
  assert.equal(deltas.filter(d => d.index === 0).map(d => d.function.arguments).join(''), call.arguments);
  assert.equal(result.at(-2).choices[0].finish_reason, 'tool_calls');
});

test('reports explicit failures and streams that end prematurely', async () => {
  for (const events of [[], [{ type: 'response.failed', response: { error: { message: 'Denied' } } }]]) {
    const result = await chunks(toChatStream(sse(events), { model: 'reasoner' }));
    assert.equal(result.at(-2).error.type, 'upstream_error');
    assert.equal(result.at(-1), '[DONE]');
    assert.equal(result.some(c => c.choices?.[0]?.finish_reason === 'stop'), false);
  }
});

test('cancelling a client stream cancels the upstream reader', async () => {
  let cancelled = false;
  const upstream = new Response(new ReadableStream({ cancel() { cancelled = true; } }));
  await toChatStream(upstream, { model: 'reasoner' }).body.cancel();
  assert.equal(cancelled, true);
});

test('routes chat models directly and Responses models through translation', async () => {
  for (const endpoint of ['/chat/completions', '/responses']) {
    const calls = [];
    const response = await handleRaycastRequest(new Request('http://localhost/raycast/v1/chat/completions', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test' },
      body: JSON.stringify({ model: 'test', messages: [{ role: 'user', content: 'Hi' }] }),
    }), async request => {
      const path = new URL(request.url).pathname;
      assert.equal(request.headers.get('Authorization'), 'Bearer test');
      calls.push(path);
      if (path === '/v1/models') return Response.json({ data: [{ id: 'test', supported_endpoints: [endpoint] }] });
      const payload = await request.json();
      assert.equal(!!payload.messages, endpoint === '/chat/completions');
      return Response.json(endpoint === '/responses' ? completed : { choices: [{ message: { content: 'direct' } }] });
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls, ['/v1/models', `/v1${endpoint}`]);
    assert.equal((await response.json()).choices[0].message.content, endpoint === '/responses' ? 'Hello 🌏' : 'direct');
  }
});

test('preserves upstream errors and rejects unknown models without inference', async () => {
  const request = () => new Request('http://localhost/raycast/v1/chat/completions', {
    method: 'POST', body: JSON.stringify({ model: 'missing', messages: [] }),
  });
  assert.equal((await handleRaycastRequest(request(), async () => new Response('Unauthorized', { status: 401 }))).status, 401);
  assert.equal((await handleRaycastRequest(request(), async () => Response.json({ data: [] }))).status, 400);
});

test('route injection is scoped, idempotent and fails on an unknown gateway shape', () => {
  const source = 'server.route("/v1/chat/completions", completionRoutes);';
  const adapted = adaptRaycastRoutes(source);
  assert.ok(adapted.includes(source));
  assert.ok(adapted.includes('/raycast/v1/chat/completions'));
  assert.equal(adaptRaycastRoutes(adapted), adapted);
  assert.throws(() => adaptRaycastRoutes(''), /routes changed/);
  assert.throws(() => adaptRaycastRoutes(source + source), /routes changed/);
});
