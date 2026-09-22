import assert from 'node:assert/strict';
import test from 'node:test';
import { adaptCopilotResponses } from '../Sources/Ymir/Resources/codex-usage-compat.mjs';

// This is the route boundary the loader adapts. Provider aliases and Messages
// fallbacks return before the native Copilot transport is selected.
const handler = `async function handle(c, payload, responsesHandlerDependencies) {
  if (payload.providerAlias) return 'provider';
  if (payload.messagesFallback) return 'messages';
  const response = await responsesHandlerDependencies.createResponses(payload, {
    transport: payload.transport,
  });
  return response;
}`;

async function run(payload) {
  const headers = {};
  const adapted = Function(`${adaptCopilotResponses(handler)}; return handle;`)();
  const result = await adapted({ header: (key, value) => { headers[key] = value; } }, payload, {
    createResponses: async () => ({ usage: { input_tokens: 301, output_tokens: 5 } }),
  });
  return { headers, result };
}

for (const transport of ['http', 'websocket']) {
  test(`signals included reasoning for native Astra over ${transport}`, async () => {
    assert.deepEqual(await run({ model: 'gpt-6-astra', transport }), {
      headers: { 'x-reasoning-included': 'true' },
      result: { usage: { input_tokens: 301, output_tokens: 5 } },
    });
  });
}

test('does not advertise the capability for unverified models', async () => {
  assert.deepEqual((await run({ model: 'gpt-5.5' })).headers, {});
});

test('does not alter custom providers or Messages fallback', async () => {
  assert.deepEqual(await run({ model: 'gpt-6-astra', providerAlias: true }), { headers: {}, result: 'provider' });
  assert.deepEqual(await run({ model: 'gpt-6-astra', messagesFallback: true }), { headers: {}, result: 'messages' });
});

test('is idempotent and rejects missing or ambiguous handler boundaries', () => {
  const adapted = adaptCopilotResponses(handler);
  assert.equal(adaptCopilotResponses(adapted), adapted);
  assert.throws(() => adaptCopilotResponses('unrecognized handler'), /handler changed/);
  assert.throws(() => adaptCopilotResponses(handler + handler), /handler changed/);
});
