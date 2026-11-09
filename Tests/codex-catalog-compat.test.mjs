import assert from 'node:assert/strict';
import test from 'node:test';
import { reconcileCopilotContext } from '../Sources/Ymir/Resources/codex-catalog-compat.mjs';
import { adaptCodexCatalog } from '../Sources/Ymir/Resources/codex-usage-compat.mjs';

const astra = { slug: 'gpt-6-astra', context_window: 272000, max_context_window: 872000,
  auto_compact_token_limit: null, model_messages: { instructions_template: 'Preserve instructions.' } };
const candidate = { slug: astra.slug, catalogSlug: astra.slug, contextWindow: 1050000 };

// The actual bundled return boundary, with dependencies supplied by the test.
const handler = `export function catalog(models, visibleCandidates, modelMappings) {
  const c = {}, upstreamCatalog = { version: 1 }, explicitSlugs = new Set();
  const template = { model_messages: {} };
  const createCodexCatalogResponse = (c, response) => response;
  return createCodexCatalogResponse(c, {
\t\t...upstreamCatalog ?? {},
\t\tmodels
\t}, explicitSlugs, template.model_messages ?? FALLBACK_CODEX_MODELS[0].model_messages);
}`;

test('corrects the catalog at the gateway return boundary without changing other metadata', async () => {
  const adapted = await import('data:text/javascript,' + encodeURIComponent(adaptCodexCatalog(handler)));
  const result = adapted.catalog([astra], [candidate], {});
  assert.deepEqual(result, { version: 1, models: [{ ...astra, context_window: 1000000, max_context_window: 1050000 }] });
  assert.equal(astra.context_window, 272000, 'Do not mutate the shared bundled catalog.');
});

test('respects a smaller live Copilot limit', () => {
  assert.deepEqual(reconcileCopilotContext([astra], [{ ...candidate, contextWindow: 128000 }], {}),
    [{ ...astra, context_window: 128000, max_context_window: 128000 }]);
});

test('leaves other models, provider aliases, and routed Astra models unchanged', () => {
  const other = { ...astra, slug: 'gpt-5.5' };
  const alias = { ...astra, slug: 'codex/gpt-6-astra' };
  const models = [other, alias];
  assert.deepEqual(reconcileCopilotContext(models, [candidate], {}), models);
  assert.equal(reconcileCopilotContext([astra], [{ ...candidate, providerName: 'codex' }], {})[0], astra);
  assert.equal(reconcileCopilotContext([astra], [candidate], { [astra.slug]: alias.slug })[0], astra);
});

test('leaves the catalog unchanged without a valid native Copilot candidate', () => {
  const models = [astra];
  assert.equal(reconcileCopilotContext(models, [], {}), models);
  for (const contextWindow of [undefined, null, 0, -1, NaN, Infinity, '1050000', 1.5]) {
    assert.equal(reconcileCopilotContext(models, [{ ...candidate, contextWindow }], {}), models);
  }
});

test('is idempotent and rejects missing or ambiguous catalog boundaries', () => {
  const adapted = adaptCodexCatalog(handler);
  assert.equal(adaptCodexCatalog(adapted), adapted);
  assert.throws(() => adaptCodexCatalog('unrecognized catalog'), /catalog changed/);
  assert.throws(() => adaptCodexCatalog(handler + handler), /catalog changed/);
});
