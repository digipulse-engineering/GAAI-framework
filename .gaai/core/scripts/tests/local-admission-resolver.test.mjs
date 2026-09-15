import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolveLocalAdmission } from '../lib/local-admission-resolver.mjs';

const RESOLVER = fileURLToPath(new URL('../lib/local-admission-resolver.mjs', import.meta.url));
const REMOTE = 'https://example.invalid/portable/project.git';
const POLICY_PATH = 'policy/local-admission.json';
const RISK = { cross_cutting: false, dependency_changed: false };
const ENVIRONMENT = { node_version: 'fixture-node', platform: 'fixture-platform',
  arch: 'fixture-arch', path_digest: 'fixture-path' };

function git(repo, ...args) {
  const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
  return result.stdout.trim();
}

function policy() {
  return {
    schema_version: '1.0.0', policy_version: 'fixture-v1',
    repository: { project_id: 'fixture/project', remote: REMOTE, base_ref: 'staging' },
    limits: { max_policy_bytes: 65536, max_diff_bytes: 65536, max_changed_paths: 32,
      max_commands: 4, max_selectors: 4, max_identifier_bytes: 64,
      max_arguments_per_command: 8, max_argument_bytes: 256,
      max_receipt_bytes: 65536, max_result_bytes: 32768 },
    commands: [
      { id: 'unit', argv: ['node', '--test', 'tests/unit.test.mjs', '{base_sha}', '{head_sha}'], timeout_seconds: 60,
        output_limit_bytes: 8192, config_paths: ['config/tool.json'] },
      { id: 'contract', argv: ['node', '--test', 'tests/contract.test.mjs'], timeout_seconds: 60,
        output_limit_bytes: 8192, config_paths: [] }
    ],
    selectors: [
      { id: 'source', path_prefixes: ['src'], exact_paths: [], command_ids: ['unit'] },
      { id: 'config', path_prefixes: ['config'], exact_paths: [], command_ids: ['unit'] }
    ],
    exhaustive_command_ids: ['unit', 'contract'], non_executable_prefixes: ['docs'],
    broadening_prefixes: ['policy', 'package.json'], broadening_patterns: ['tsconfig*.json'],
    dependency_inputs: ['pnpm-lock.yaml'],
    risk_input_policy: { keys: ['cross_cutting', 'dependency_changed'],
      exhaustive_when_true: ['cross_cutting', 'dependency_changed'] },
    required_environment: Object.keys(ENVIRONMENT), executable_suffixes: ['.js', '.mjs', '.sh', '.json'],
    executable_names: ['Dockerfile', 'Makefile']
  };
}

async function put(repo, path, value) {
  await mkdir(join(repo, path, '..'), { recursive: true });
  await writeFile(join(repo, path), value);
}

async function fixture(t, { alterPolicy, candidate } = {}) {
  const repo = await mkdtemp(join(tmpdir(), 'gaai-resolver-'));
  t.after(() => rm(repo, { recursive: true, force: true }));
  git(repo, 'init', '-q');
  git(repo, 'config', 'user.email', 'fixture@example.invalid');
  git(repo, 'config', 'user.name', 'Portable Fixture');
  git(repo, 'config', 'core.hooksPath', '/dev/null');
  git(repo, 'remote', 'add', 'origin', REMOTE);
  const basePolicy = policy();
  alterPolicy?.(basePolicy);
  await put(repo, POLICY_PATH, `${JSON.stringify(basePolicy, null, 2)}\n`);
  await put(repo, 'src/old.mjs', 'export const value = 1;\n');
  await put(repo, 'src/delete.mjs', 'export const removed = true;\n');
  await put(repo, 'config/tool.json', '{"mode":"strict"}\n');
  await put(repo, 'pnpm-lock.yaml', 'lockfileVersion: 9\n');
  await put(repo, 'docs/readme.md', '# Fixture\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'base');
  const baseSha = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'update-ref', 'refs/remotes/origin/staging', baseSha);
  await (candidate || (async () => put(repo, 'src/old.mjs', 'export const value = 2;\n')))(repo);
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'candidate');
  return { repo, baseSha, headSha: git(repo, 'rev-parse', 'HEAD') };
}

function resolve(fx, riskInputs, environment = ENVIRONMENT) {
  return resolveLocalAdmission({ ...fx, baseRef: 'staging', policyPath: POLICY_PATH,
    riskInputs, environment });
}

function cliArgs(fx, riskPath, output, resolver = RESOLVER) {
  return [resolver, '--repo', fx.repo, '--base-ref', 'staging', '--base-sha', fx.baseSha,
    '--head-sha', fx.headSha, '--policy', POLICY_PATH, '--risk-inputs', riskPath, '--output', output];
}

test('normalizes additions, deletions and renames and selects the affected surface', async t => {
  const fx = await fixture(t, { candidate: async repo => {
    git(repo, 'mv', 'src/old.mjs', 'src/renamed.mjs');
    await rm(join(repo, 'src/delete.mjs'));
    await put(repo, 'src/added.mjs', 'export const added = true;\n');
  } });
  const result = resolve(fx);
  assert.equal(result.status, 'resolved');
  assert.equal(result.summary.changed_path_count, 4);
  assert.equal(result.summary.rename_count, 1);
  assert.deepEqual(result.summary.selected_surface_ids, ['source']);
  assert.deepEqual(result.summary.selected_command_ids, ['unit']);
});

test('uses the base-held policy even when the candidate deletes it', async t => {
  const fx = await fixture(t, { candidate: repo => rm(join(repo, POLICY_PATH)) });
  const result = resolve(fx);
  assert.equal(result.status, 'resolved');
  assert.deepEqual(result.summary.selected_command_ids, ['unit', 'contract']);
  assert.ok(result.binding.policy_digest);
});

test('dependency and governed risk changes broaden deterministically to exhaustive checks', async t => {
  const source = await fixture(t);
  const dependency = await fixture(t, { candidate: repo => put(repo, 'pnpm-lock.yaml', 'lockfileVersion: 9\nchanged: true\n') });
  const dependencyResult = resolve(dependency);
  assert.deepEqual(dependencyResult.summary.selected_command_ids, ['unit', 'contract']);
  assert.notEqual(resolve(source).binding.dependency_digest, dependencyResult.binding.dependency_digest);
  assert.notEqual(resolve(source).binding.normalized_diff_digest,
    dependencyResult.binding.normalized_diff_digest);
  const risk = await fixture(t);
  const ordinary = resolve(risk);
  const elevated = resolve(risk, { ...RISK, cross_cutting: true });
  assert.deepEqual(elevated.summary.selected_command_ids, ['unit', 'contract']);
  assert.notEqual(ordinary.binding.risk_digest, elevated.binding.risk_digest);
});

test('unknown and non-executable-only surfaces are non-authorizing', async t => {
  const unknown = await fixture(t, { candidate: repo => put(repo, 'scripts/build.mjs', 'export {};\n') });
  assert.equal(resolve(unknown).reason, 'unknown_executable_surface');
  const docs = await fixture(t, { candidate: repo => put(repo, 'docs/readme.md', '# Changed\n') });
  assert.equal(resolve(docs).reason, 'empty_executable_selection');
});

test('risk input shape is complete, closed and boolean', async t => {
  const fx = await fixture(t);
  assert.equal(resolve(fx, {}).reason, 'risk_input_unresolved');
  assert.equal(resolve(fx, { ...RISK, extra: false }).reason, 'risk_input_unresolved');
  assert.equal(resolve(fx, { ...RISK, cross_cutting: 'false' }).reason, 'risk_input_unresolved');
});

test('malformed, ambiguous and extra base policy fields fail closed', async t => {
  const malformed = await fixture(t, { alterPolicy: value => { delete value.selectors; } });
  assert.equal(resolve(malformed).reason, 'policy_malformed');
  const ambiguous = await fixture(t, { alterPolicy: value => value.commands.push({ ...value.commands[0] }) });
  assert.equal(resolve(ambiguous).reason, 'policy_ambiguous');
  const extra = await fixture(t, { alterPolicy: value => { value.commands[0].enabled = false; } });
  assert.equal(resolve(extra).reason, 'policy_malformed');
});

test('configuration and required environment values invalidate the binding', async t => {
  const ordinary = await fixture(t);
  const fx = await fixture(t, { candidate: repo => put(repo, 'config/tool.json', '{"mode":"other"}\n') });
  const first = resolve(fx, RISK, { ...ENVIRONMENT, platform: 'one' });
  const second = resolve(fx, RISK, { ...ENVIRONMENT, platform: 'two' });
  assert.equal(first.status, 'resolved');
  assert.notEqual(resolve(ordinary).binding.command_digests[0].configuration_digest,
    first.binding.command_digests[0].configuration_digest);
  assert.notEqual(first.binding.environment_digest, second.binding.environment_digest);
  assert.equal(resolve(fx, RISK, {}).reason, 'environment_fact_missing');
});

test('declared pass-through names are bound by value and carried to the executor; the rest stay out', async t => {
  const withRule = p => { p.environment_passthrough = ['GAAI_PT_*', 'GAAI_PT_EXACT']; };
  const fx = await fixture(t, { alterPolicy: withRule });
  const saved = { ...process.env };
  t.after(() => { for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]; Object.assign(process.env, saved); });
  delete process.env.GAAI_PT_EXACT;
  process.env.GAAI_PT_ONE = 'one'; process.env.GAAI_NOT_DECLARED = 'x'; process.env.GAAI_PT_lower = 'ignored';
  const first = resolve(fx, RISK);
  assert.equal(first.status, 'resolved');
  assert.deepEqual(first.environment_passthrough, ['GAAI_PT_ONE']);
  process.env.GAAI_NOT_DECLARED = 'y';
  assert.equal(resolve(fx, RISK).binding.environment_digest, first.binding.environment_digest);
  process.env.GAAI_PT_ONE = 'two';
  assert.notEqual(resolve(fx, RISK).binding.environment_digest, first.binding.environment_digest);
  process.env.GAAI_PT_EXACT = 'e';
  assert.deepEqual(resolve(fx, RISK).environment_passthrough, ['GAAI_PT_EXACT', 'GAAI_PT_ONE']);
  const plain = await fixture(t);
  assert.deepEqual(resolve(plain, RISK).environment_passthrough, []);
  for (const bad of [['NOT_GAAI'], ['GAAI_A', 'GAAI_A'], 'GAAI_A', ['gaai_lower'], ['GAAI_*'], ['GAAI_A*B'], ['GAAI_A*'], ['GAAI__X']]) {
    const broken = await fixture(t, { alterPolicy: p => { p.environment_passthrough = bad; } });
    assert.equal(resolve(broken, RISK).reason, 'policy_malformed', JSON.stringify(bad));
  }
});

test('selector and command descriptor values independently invalidate their digests', async t => {
  const ordinary = await fixture(t);
  const changed = await fixture(t, { alterPolicy: value => {
    value.selectors[0].path_prefixes.push('lib');
    value.commands[0].timeout_seconds += 1;
  } });
  const first = resolve(ordinary);
  const second = resolve(changed);
  assert.notEqual(first.binding.selector_digest, second.binding.selector_digest);
  assert.notEqual(first.binding.command_digests[0].descriptor_digest,
    second.binding.command_digests[0].descriptor_digest);
});

test('executor choice is neutral unless a project explicitly governs it', async t => {
  const fx = await fixture(t);
  const claude = resolve(fx, RISK, { ...ENVIRONMENT, GAAI_DAEMON_EXECUTOR: 'claude' });
  const codex = resolve(fx, RISK, { ...ENVIRONMENT, GAAI_DAEMON_EXECUTOR: 'codex' });
  assert.equal(claude.binding_digest, codex.binding_digest);
});

test('internal argv stays fixed and bounded while the observable summary is private', async t => {
  const injection = '; printf secret';
  const fx = await fixture(t, { alterPolicy: value => { value.commands[0].argv.push(injection); } });
  const result = resolve(fx);
  assert.equal(result.status, 'resolved');
  assert.equal(result.selected_commands[0].argv.at(-1), injection);
  assert.equal(result.selected_commands[0].argv.at(-3), fx.baseSha);
  assert.equal(result.selected_commands[0].argv.at(-2), fx.headSha);
  assert.deepEqual(result.limits, { max_receipt_bytes: 65536, max_result_bytes: 32768 });
  assert.doesNotMatch(JSON.stringify(result.summary), /argv|printf secret|tests\/unit/);
  const oversized = await fixture(t, { alterPolicy: value => {
    value.commands[0].argv.push('x'.repeat(value.limits.max_argument_bytes + 1));
  } });
  assert.equal(resolve(oversized).reason, 'policy_malformed');
  const tooMany = await fixture(t, { alterPolicy: value => {
    value.limits.max_arguments_per_command = 2;
  } });
  assert.equal(resolve(tooMany).reason, 'policy_malformed');
  const identifier = await fixture(t, { alterPolicy: value => {
    value.limits.max_identifier_bytes = 3;
  } });
  assert.equal(resolve(identifier).reason, 'policy_malformed');
});

test('stale identity, dirty candidates and missing configuration never resolve', async t => {
  const stale = await fixture(t);
  assert.equal(resolve({ ...stale, headSha: stale.baseSha }).reason, 'candidate_stale');
  const dirty = await fixture(t);
  await put(dirty.repo, 'src/untracked.mjs', 'export {};\n');
  assert.equal(resolve(dirty).reason, 'candidate_unsealed');
  const missing = await fixture(t, { candidate: repo => rm(join(repo, 'config/tool.json')) });
  assert.equal(resolve(missing).reason, 'configuration_unresolved');
  const advanced = await fixture(t);
  git(advanced.repo, 'update-ref', 'refs/remotes/origin/staging', advanced.headSha);
  assert.equal(resolve(advanced).reason, 'candidate_stale');
  const wrongRemote = await fixture(t);
  git(wrongRemote.repo, 'remote', 'set-url', 'origin', 'https://example.invalid/other.git');
  assert.equal(resolve(wrongRemote).reason, 'repository_mismatch');
});

test('symlink and gitlink-like configuration modes fail closed before content binding', async t => {
  const external = join(tmpdir(), `gaai-external-${process.pid}-${Date.now()}.json`);
  t.after(() => rm(external, { force: true }));
  await writeFile(external, '{"mode":"first"}\n');
  const fx = await fixture(t, { candidate: async repo => {
    await rm(join(repo, 'config/tool.json'));
    await symlink(external, join(repo, 'config/tool.json'));
  } });
  const first = resolve(fx);
  await writeFile(external, '{"mode":"second"}\n');
  const second = resolve(fx);
  assert.equal(first.reason, 'candidate_path_unsafe');
  assert.equal(second.reason, 'candidate_path_unsafe');
  const gitlink = await fixture(t, { candidate: async repo => {
    const nested = join(repo, 'config/tool.json');
    await rm(nested);
    await mkdir(nested);
    git(nested, 'init', '-q');
    git(nested, 'config', 'user.email', 'fixture@example.invalid');
    git(nested, 'config', 'user.name', 'Nested Fixture');
    await put(nested, 'README.md', '# Nested\n');
    git(nested, 'add', '-A'); git(nested, 'commit', '-q', '-m', 'nested');
  } });
  assert.equal(resolve(gitlink).reason, 'candidate_path_unsafe');
});

test('CLI writes the internal plan privately and emits only its bounded summary', async t => {
  const fx = await fixture(t);
  const riskPath = join(tmpdir(), `gaai-risk-${process.pid}-${Date.now()}.json`);
  const output = join(tmpdir(), `gaai-plan-${process.pid}-${Date.now()}.json`);
  t.after(() => Promise.all([rm(riskPath, { force: true }), rm(output, { force: true })]));
  await writeFile(riskPath, JSON.stringify(RISK));
  const args = cliArgs(fx, riskPath, output);
  const run = spawnSync(process.execPath, args, { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(JSON.parse(run.stdout).outcome, 'resolved');
  assert.doesNotMatch(run.stdout, /argv|tests\/unit/);
  assert.equal(JSON.parse(await readFile(output, 'utf8')).status, 'resolved');
  assert.equal((await stat(output)).mode & 0o077, 0);
  for (const invalid of [args.slice(0, -2), args.with(3, '--repo'), args.with(1, '--unknown')]) {
    const rejected = spawnSync(process.execPath, invalid, { encoding: 'utf8' });
    assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /input_invalid/);
  }
});

test('CLI executes through a symlink-aliased entrypoint path', async t => {
  const fx = await fixture(t);
  const root = await mkdtemp(join(tmpdir(), 'gaai-resolver-alias-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const riskPath = join(root, 'risk.json');
  const output = join(root, 'plan.json');
  const alias = join(root, 'lib-alias');
  await writeFile(riskPath, JSON.stringify(RISK));
  await symlink(dirname(RESOLVER), alias, process.platform === 'win32' ? 'junction' : 'dir');
  const run = spawnSync(process.execPath,
    cliArgs(fx, riskPath, output, join(alias, 'local-admission-resolver.mjs')),
    { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(JSON.parse(run.stdout).outcome, 'resolved');
  assert.equal(JSON.parse(await readFile(output, 'utf8')).status, 'resolved');
});

test('indirect import ignores an unresolvable process entrypoint without disclosure', () => {
  const source = `await import(${JSON.stringify(pathToFileURL(RESOLVER).href)});`;
  const run = spawnSync(process.execPath, ['--input-type=module', '-'], {
    encoding: 'utf8', input: source
  });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stdout, '');
  assert.equal(run.stderr, '');
});

test('CLI refuses existing or symlink plan outputs without disclosure or clobbering', async t => {
  const fx = await fixture(t);
  const root = await mkdtemp(join(tmpdir(), 'gaai-plan-output-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const riskPath = join(root, 'risk.json');
  const existing = join(root, 'existing.json');
  const target = join(root, 'target.json');
  const link = join(root, 'link.json');
  await writeFile(riskPath, JSON.stringify(RISK));
  await writeFile(existing, 'public sentinel');
  await chmod(existing, 0o644);
  await writeFile(target, 'private sentinel');
  await symlink(target, link);
  for (const output of [existing, link]) {
    const run = spawnSync(process.execPath, cliArgs(fx, riskPath, output),
      { encoding: 'utf8' });
    assert.equal(run.status, 2);
    assert.match(run.stderr, /resolver_error/);
  }
  assert.equal(await readFile(existing, 'utf8'), 'public sentinel');
  assert.equal((await stat(existing)).mode & 0o777, 0o644);
  assert.equal(await readFile(target, 'utf8'), 'private sentinel');
});
