#!/usr/bin/env node
// JSON is valid YAML. Keeping this generated file in JSON also lets us preserve
// other providers safely on subsequent runs without a YAML dependency.
import { readFile, mkdir, writeFile, rename } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const baseURL = 'http://127.0.0.1:4141/raycast/v1';
const response = await fetch(`${baseURL}/models`, { signal: AbortSignal.timeout(10000) });
if (!response.ok) throw new Error(`Start the updated Ymir gateway first (HTTP ${response.status}).`);
const models = (await response.json()).data.filter(model =>
  model.capabilities?.type === 'chat' && model.policy?.state !== 'disabled' &&
  model.supported_endpoints?.some(endpoint => ['/chat/completions', '/responses', '/v1/messages'].includes(endpoint)));
if (!models.length) throw new Error('The Ymir gateway returned no chat models. Existing configuration was left untouched.');
const provider = {
  id: 'ymir', name: 'Ymir', base_url: baseURL,
  models: models.map(model => ({
    id: model.id, name: model.display_name ?? model.name ?? model.id,
    context: model.capabilities.limits?.max_prompt_tokens ?? model.capabilities.limits?.max_context_window_tokens,
    abilities: {
      temperature: { supported: false },
      vision: { supported: model.capabilities.supports?.vision === true },
      system_message: { supported: true },
      tools: { supported: model.capabilities.supports?.tool_calls === true },
      reasoning_effort: { supported: (model.capabilities.supports?.reasoning_effort?.length ?? 0) > 0 },
    },
  })),
};
const path = process.argv[2] ?? join(homedir(), '.config/raycast/ai/providers.yaml');
let config = { providers: [] };
let original;
try { original = await readFile(path, 'utf8'); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
if (original?.trim()) {
  try { config = JSON.parse(original); }
  catch { throw new Error('An existing YAML configuration needs a manual merge. Pass a different output path to generate the Ymir provider separately.'); }
  if (!Array.isArray(config.providers)) throw new Error('Existing configuration has no providers array. It was left untouched.');
}
const index = config.providers.findIndex(item => item.id === 'ymir');
if (index < 0) config.providers.push(provider);
else config.providers[index] = provider;
await mkdir(dirname(path), { recursive: true });
if (original) await writeFile(`${path}.ymir-backup-${Date.now()}`, original, { mode: 0o600, flag: 'wx' });
const temporary = `${path}.ymir-${process.pid}.tmp`;
await writeFile(temporary, JSON.stringify(config, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
await rename(temporary, path);
console.log(`Configured ${models.length} Ymir chat models in ${path}`);
