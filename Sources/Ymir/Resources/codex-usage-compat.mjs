import { registerHooks } from 'node:module';
import { adaptCopilotRequestRetry } from './copilot-request-retry.mjs';

export { adaptCopilotRequestRetry };

const marker = '// Ymir: Copilot Astra usage already includes retained reasoning.';
const nativeResponsesCall = 'const response = await responsesHandlerDependencies.createResponses(payload, {';
const raycastMarker = '// Ymir: Raycast Chat Completions compatibility route.';
const chatRoute = 'server.route("/v1/chat/completions", completionRoutes);';

const catalogMarker = '// Ymir: Use native Copilot Astra context limits.';
const catalogReturn = `return createCodexCatalogResponse(c, {
		...upstreamCatalog ?? {},
		models
	}, explicitSlugs, template.model_messages ?? FALLBACK_CODEX_MODELS[0].model_messages);`;

export function adaptCodexCatalog(source) {
  if (source.includes(catalogMarker)) return source;
  if (source.split(catalogReturn).length !== 2) {
    throw new Error('Ymir could not correct the Codex context window: the copilot-api model catalog changed.');
  }
  const adapterURL = new URL('./codex-catalog-compat.mjs', import.meta.url).href;
  const replacement = catalogReturn.replace('\n\t\tmodels\n', '\n\t\tmodels: ymirCopilotContext(models, visibleCandidates, modelMappings)\n');
  return `import { reconcileCopilotContext as ymirCopilotContext } from ${JSON.stringify(adapterURL)};\n`
    + source.replace(catalogReturn, `${catalogMarker}\n\t${replacement}`);
}

export function adaptRaycastRoutes(source) {
  if (source.includes(raycastMarker)) return source;
  if (source.split(chatRoute).length !== 2) {
    throw new Error('Ymir could not add Raycast support: the copilot-api server routes changed.');
  }
  const adapterURL = new URL('./raycast-compat.mjs', import.meta.url).href;
  return `import { handleRaycastRequest as ymirRaycast } from ${JSON.stringify(adapterURL)};\n` + source.replace(chatRoute, `${chatRoute}
  ${raycastMarker}
  server.post("/raycast/v1/chat/completions", c => ymirRaycast(c.req.raw, request => server.fetch(request)));
  server.get("/raycast/v1/models", c => ymirRaycast(c.req.raw, request => server.fetch(request)));`);
}

export function adaptCopilotResponses(source) {
  if (source.includes(marker)) return source;
  if (source.split(nativeResponsesCall).length !== 2) {
    throw new Error('Ymir could not apply the Codex usage compatibility fix: the copilot-api Responses handler changed.');
  }

  // Verified against Copilot GPT-6-Astra: replaying a reasoning item increases
  // input_tokens by its reasoning tokens plus framing. Codex otherwise adds a
  // second, byte-based estimate of reasoning from previous user turns.
  // This call is after provider aliases and Messages fallbacks return, so the
  // capability is advertised only for native Copilot Responses for this model.
  return source.replace(nativeResponsesCall, `${marker}
  if (payload.model === "gpt-6-astra") {
    c.header("x-reasoning-included", "true");
  }
  ${nativeResponsesCall}`);
}

registerHooks({
  load(url, context, nextLoad) {
    const result = nextLoad(url, context);
    if (!/\/node_modules\/@jeffreycao\/copilot-api\/dist\/server-[^/]+\.js$/.test(url)) {
      return result;
    }
    const source = typeof result.source === 'string'
      ? result.source
      : new TextDecoder().decode(result.source);
    return { ...result, source: adaptCopilotRequestRetry(adaptRaycastRoutes(adaptCodexCatalog(adaptCopilotResponses(source)))) };
  },
});
