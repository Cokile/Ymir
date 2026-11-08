#!/usr/bin/env node
// Download a release without installing/running it, then check Ymir's adapters
// against its actual bundle. An optional version checks a candidate upgrade.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { adaptCopilotResponses, adaptRaycastRoutes } from '../Sources/Ymir/Resources/codex-usage-compat.mjs';

const version = process.argv[2] ?? readFileSync(new URL('../Sources/Ymir/Resources/copilot-api-version.txt', import.meta.url), 'utf8').trim();
assert.match(version, /^\d+\.\d+\.\d+$/, 'Provide an exact stable gateway version.');
const specification = `@jeffreycao/copilot-api@${version}`;
const directory = mkdtempSync(join(tmpdir(), 'ymir-gateway-check-'));

function run(command, args) {
  const result = spawnSync(command, args, { cwd: directory, encoding: 'utf8', timeout: 120000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
}

try {
  const [packed] = JSON.parse(run('npm', ['pack', specification, '--ignore-scripts', '--json', '--pack-destination', directory]));
  assert.equal(packed.version, version);
  assert.equal(packed.filename, basename(packed.filename));
  run('tar', ['-xzf', join(directory, packed.filename), '-C', directory, 'package/package.json', 'package/dist']);
  const manifest = JSON.parse(readFileSync(join(directory, 'package/package.json'), 'utf8'));
  assert.equal(manifest.name, '@jeffreycao/copilot-api');
  assert.equal(manifest.version, version);
  const distribution = join(directory, 'package/dist');
  const bundles = readdirSync(distribution).filter(name => /^server-[^/]+\.js$/.test(name));
  assert.equal(bundles.length, 1, 'Expected exactly one gateway server bundle.');
  const source = readFileSync(join(distribution, bundles[0]), 'utf8');
  const adapted = adaptRaycastRoutes(adaptCopilotResponses(source));
  assert.equal(adaptRaycastRoutes(adaptCopilotResponses(adapted)), adapted, 'Adapters must be idempotent.');
  const adaptedPath = join(directory, 'adapted-server.mjs');
  writeFileSync(adaptedPath, adapted);
  run(process.execPath, ['--check', adaptedPath]);
  console.log(`${specification}: usage-header and Raycast adapters match; adapted JavaScript parses.`);
  console.log('Run the adapter and real-Codex regression tests before updating the version pin.');
} finally {
  rmSync(directory, { recursive: true, force: true });
}
