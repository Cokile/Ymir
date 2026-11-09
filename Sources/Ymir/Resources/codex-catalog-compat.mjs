// The gateway's bundled Codex catalog can shadow native Copilot model limits.
// Keep Astra's 1M default bounded by the context advertised by Copilot itself.
export function reconcileCopilotContext(models, candidates, modelMappings) {
  const slug = 'gpt-6-astra';
  if (modelMappings[slug] && modelMappings[slug] !== slug) return models;

  const candidate = candidates.find(candidate => candidate.slug === slug
    && candidate.catalogSlug === slug && candidate.providerName == null);
  const limit = candidate?.contextWindow;
  if (!Number.isSafeInteger(limit) || limit <= 0) return models;

  return models.map(model => model.slug === slug ? {
    ...model,
    context_window: Math.min(1000000, limit),
    max_context_window: limit,
  } : model);
}
