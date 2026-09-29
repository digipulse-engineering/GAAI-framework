import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, chmodSync, statSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { gunzipSync } from 'node:zlib';
import { APPLICABILITY_PATH, IMPLEMENTATION_PATHS, VERIFIER_CLOSURE, proveApplicability,
  requiredControllerPaths, verifyCompositeReceipt, deriveIntegratedTree } from '../lib/local-admission-applicability.mjs';
import { resolveLocalAdmission } from '../lib/local-admission-resolver.mjs';
import { canonicalJson, executePlan, sealCompositeReceipt } from '../lib/local-admission-executor.mjs';

const selectorPath = 'policy/selector.json';
const registryPath = 'policy/trust.json';
const backlogPath = 'backlog.yaml';
const backlog = 'mode: active\nitems:\n- id: S1\n  status: in_progress\n  title: Own\n- id: S2\n  status: refined\n  title: Other\n- id: S3\n  status: refined\n  title: Third\n';
const hash = value => createHash('sha256').update(value).digest('hex');
// Immutable pre-composite watcher-only entry. No test-time Git ref lookup:
// gzip is storage only; the digest guards the exact legacy implementation.
const LEGACY_WATCHER_DIGEST = '6468f48b32b9833ef4df5dd939cf91a1941e8252b854eecf21d2c5dbb91b53c3';
const LEGACY_WATCHER_GZIP = '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';
function git(repo, ...args) {
  const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function put(repo, path, value) {
  mkdirSync(join(repo, path, '..'), { recursive: true });
  writeFileSync(join(repo, path), typeof value === 'string' || Buffer.isBuffer(value) ? value : `${JSON.stringify(value, null, 2)}\n`);
}
function copyVerifierClosure(repo) {
  for (const path of VERIFIER_CLOSURE) {
    const source = new URL(`../../${path.slice('.gaai/core/'.length)}`, import.meta.url);
    put(repo, path, readFileSync(source));
    chmodSync(join(repo, path), statSync(source).mode & 0o777);
  }
}
function selector(remote) {
  return { schema_version: '1.0.0', policy_version: 'fixture',
    repository: { project_id: 'fixture/project', remote, base_ref: 'staging' },
    limits: { max_policy_bytes: 65536, max_diff_bytes: 1024 * 1024, max_changed_paths: 32,
      max_commands: 8, max_selectors: 8, max_identifier_bytes: 128,
      max_arguments_per_command: 16, max_argument_bytes: 4096,
      max_receipt_bytes: 65536, max_result_bytes: 32768 },
    commands: [{ id: 'unit', argv: ['node', '-e', 'process.exit(0)'], timeout_seconds: 5,
      output_limit_bytes: 64, config_paths: [] },
    { id: 'governance', argv: ['node', '-e', 'process.exit(0)', '{base_sha}'], timeout_seconds: 5,
      output_limit_bytes: 64, config_paths: [] }],
    selectors: [{ id: 'source', path_prefixes: ['src'], exact_paths: [], command_ids: ['unit', 'governance'] }],
    exhaustive_command_ids: ['unit', 'governance'], non_executable_prefixes: [backlogPath],
    broadening_prefixes: ['policy'], broadening_patterns: [], dependency_inputs: ['lock.json'],
    risk_input_policy: { keys: ['cross_cutting', 'dependency_changed'], exhaustive_when_true: ['cross_cutting', 'dependency_changed'] },
    required_environment: ['node_version', 'platform', 'arch', 'path_digest'],
    executable_suffixes: ['.mjs', '.sh'], executable_names: ['Makefile'] };
}

async function fixture(t, options = {}) {
  const repo = mkdtempSync(join(tmpdir(), 'admission-applicability-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  git(repo, 'init', '-q'); git(repo, 'config', 'user.name', 'Fixture');
  git(repo, 'config', 'user.email', 'fixture@example.invalid'); git(repo, 'config', 'core.hooksPath', '/dev/null');
  const remote = 'https://example.invalid/fixture/project.git';
  git(repo, 'remote', 'add', 'origin', remote);
  const policy = selector(remote);
  options.selector?.(policy);
  put(repo, selectorPath, policy);
  const optIn = { schema_version: '1.0.0', repository: policy.repository, backlog_path: backlogPath,
    rows_key: 'items', identity_key: 'id', lifecycle_fields: ['status'],
    reusable_command_ids: ['unit', 'governance'], trust_registry_path: registryPath };
  options.optIn?.(optIn);
  if (!options.noOptIn) put(repo, APPLICABILITY_PATH, optIn);
  const registry = { schema_version: '1.0.0', repository: { id: 1, full_name: 'fixture/project', base_ref: 'staging' },
    workflow: { id: 1, path: '.github/workflows/check.yml', name: 'Checks', event: 'pull_request' },
    required_job: 'Authority', covered_paths: [registryPath, selectorPath, '.github/workflows/check.yml',
      ...requiredControllerPaths(65536), ...IMPLEMENTATION_PATHS, APPLICABILITY_PATH] };
  options.registry?.(registry);
  put(repo, registryPath, registry);
  copyVerifierClosure(repo);
  put(repo, backlogPath, options.before || backlog); put(repo, 'src/value.mjs', 'export const value = 1;\n');
  put(repo, 'lock.json', '{}\n');
  options.base?.(repo);
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'base');
  const oldBase = git(repo, 'rev-parse', 'HEAD'); git(repo, 'update-ref', 'refs/remotes/origin/staging', oldBase);
  put(repo, 'src/value.mjs', 'export const value = 2;\n');
  options.candidate?.(repo, optIn);
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'candidate');
  const headSha = options.candidateTree
    ? git(repo, 'commit-tree', options.candidateTree(repo, git(repo, 'rev-parse', 'HEAD^{tree}')), '-p', oldBase, '-m', 'candidate tree')
    : options.orphanHead
    ? git(repo, 'commit-tree', git(repo, 'rev-parse', 'HEAD^{tree}'), '-m', 'unrelated candidate')
    : git(repo, 'rev-parse', 'HEAD');
  if (options.orphanHead || options.candidateTree) git(repo, 'checkout', '-q', '--detach', headSha);
  const invocation = { id: randomUUID(), story_id: 'S1', boundary: options.boundary || 'final' };
  const resolve = baseSha => resolveLocalAdmission({ repo, baseRef: 'staging', baseSha, headSha,
    policyPath: selectorPath, invocation });
  const originalPlan = resolve(oldBase);
  assert.equal(originalPlan.status, 'resolved');
  const results = await executePlan(originalPlan, { cwd: repo });
  git(repo, 'checkout', '-q', '--detach', oldBase);
  put(repo, backlogPath, options.after || backlog.replaceAll('status: refined', 'status: done'));
  options.advance?.(repo);
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'lifecycle');
  const newBase = options.advanceTree
    ? git(repo, 'commit-tree', options.advanceTree(repo, git(repo, 'rev-parse', 'HEAD^{tree}')), '-p', oldBase, '-m', 'advanced tree')
    : git(repo, 'rev-parse', 'HEAD');
  git(repo, 'update-ref', 'refs/remotes/origin/staging', newBase);
  git(repo, 'checkout', '-q', '--detach', headSha);
  const plan = resolve(newBase);
  return { repo, originalPlan, plan, results, resolve, oldBase, newBase, headSha };
}

test('only unchanged argv reuses results; both boundaries preserve immutable provenance', async t => {
  for (const boundary of ['final', 'pre_qa']) {
    const fx = await fixture(t, { boundary });
    const originalBytes = canonicalJson(fx.results);
    const proof = proveApplicability(fx);
    assert.equal(proof.status, 'eligible', JSON.stringify(proof));
    assert.deepEqual(proof.reusable_command_ids, ['unit']);
    assert.deepEqual(proof.fresh_command_ids, ['governance']);
    const freshResults = await executePlan(fx.plan, { cwd: fx.repo, commandIds: proof.fresh_command_ids });
    const receipt = JSON.parse(await sealCompositeReceipt({ ...fx, originalResults: fx.results,
      freshResults, proof, boundary, storyId: 'S1', maxBytes: 65536, outcome: 'pass' }));
    assert.equal(receipt.publication_admitted, boundary === 'final');
    assert.equal(canonicalJson(fx.results), originalBytes);
    assert.equal(canonicalJson(receipt.original_execution.results), originalBytes);
    assert.equal(receipt.results[0].execution.binding_digest, fx.originalPlan.binding_digest);
    assert.equal(receipt.results[1].execution.binding_digest, fx.plan.binding_digest);
    assert.equal(receipt.results[1].execution.materialized_argv_digest,
      hash(canonicalJson(fx.plan.selected_commands[1].argv)));
  }
});

function signed(receipt) {
  const copy = structuredClone(receipt);
  delete copy.receipt_digest;
  copy.receipt_digest = hash(canonicalJson(copy));
  return `${canonicalJson(copy)}\n`;
}

test('historical composite verifies exact sibling integration beyond merge without live environment', async t => {
  const before = backlog.replace('title: Own', 'title: "😀 café"');
  const after = before.replaceAll('status: refined', 'status: "terminé 😀"');
  const fx = await fixture(t, { before, after });
  const proof = proveApplicability(fx);
  assert.equal(proof.status, 'eligible');
  const freshResults = await executePlan(fx.plan, { cwd: fx.repo, commandIds: proof.fresh_command_ids });
  const raw = await sealCompositeReceipt({ ...fx, originalResults: fx.results, freshResults,
    proof, boundary: 'final', storyId: 'S1', maxBytes: 65536, outcome: 'pass' });
  const receipt = JSON.parse(raw);
  assert.equal(receipt.schema_version, '2.0.0');
  assert.notEqual(spawnSync('git', ['-C', fx.repo, 'merge-base', '--is-ancestor', fx.newBase, fx.headSha]).status, 0);
  // Independent oracle: literal fixture contents, not the production patcher.
  put(fx.repo, backlogPath, after);
  git(fx.repo, 'add', backlogPath);
  const tree = git(fx.repo, 'write-tree');
  const merge = git(fx.repo, 'commit-tree', tree, '-p', fx.newBase, '-m', 'external squash');
  git(fx.repo, 'checkout', '-q', '--detach', merge);
  put(fx.repo, 'observer.txt', 'later unrelated target content\n');
  git(fx.repo, 'add', '-A'); git(fx.repo, 'commit', '-qm', 'later target');
  git(fx.repo, 'update-ref', 'refs/remotes/origin/staging', git(fx.repo, 'rev-parse', 'HEAD'));
  const options = { repo: fx.repo, raw, repository: selector('https://example.invalid/fixture/project.git').repository,
    baseRef: 'staging', maxBytes: 65536, mergeSha: merge };
  process.env.GAAI_OBSERVER_ONLY = 'not an execution fact';
  try { assert.equal(verifyCompositeReceipt(options).status, 'verified'); }
  finally { delete process.env.GAAI_OBSERVER_ONLY; }
  assert.equal(resolveLocalAdmission({ repo: fx.repo, baseRef: 'staging', baseSha: fx.newBase,
    headSha: fx.headSha, policyPath: selectorPath }).status, 'rejected');
  for (const mutate of [
    value => { value.extra = true; }, value => { value.schema_version = '3.0.0'; },
    value => { value.boundary = 'pre_qa'; }, value => { value.outcome = 'blocked:stale_evidence'; },
    value => { value.publication_admitted = false; }, value => { value.resolution_inputs.extra = true; },
    value => { value.original_execution.extra = true; }, value => { value.applicability.extra = true; },
    value => { value.refreshed_execution.extra = true; }, value => { value.candidate.extra = true; },
    value => { value.results[0].execution.extra = true; }, value => { value.applicability.invocation.extra = true; },
    value => { value.resolution_inputs.risk_inputs = { unknown: false }; },
    value => { value.applicability.delta_digest = '0'.repeat(64); },
    value => { value.applicability.original_base_sha = fx.headSha; },
    value => { value.results[0].duration_ms++; }, value => { value.provenance[0].boundary = 'pre_qa'; },
    value => { value.provenance[0].execution_id = randomUUID(); },
    value => { value.original_execution.results[0].execution.invocation_id = randomUUID();
      value.original_execution.results_digest = hash(canonicalJson(value.original_execution.results)); },
    value => { value.refreshed_execution.results[0].execution.execution_id = value.original_execution.results[0].execution.execution_id;
      value.refreshed_execution.results_digest = hash(canonicalJson(value.refreshed_execution.results)); },
    value => { value.refreshed_execution.results = []; value.refreshed_execution.results_digest = hash('[]'); },
    value => { value.original_execution.results.reverse(); value.original_execution.results_digest = hash(canonicalJson(value.original_execution.results)); },
    value => { value.selected_command_ids.reverse(); }
  ]) {
    const changed = structuredClone(receipt); mutate(changed);
    assert.equal(verifyCompositeReceipt({ ...options, raw: signed(changed) }).status, 'rejected');
  }
  assert.equal(verifyCompositeReceipt({ ...options, raw: raw.replace('"schema_version":"2.0.0"',
    '"schema_version":"2.0.0","schema_version":"2.0.0"') }).status, 'rejected');
  for (const badMerge of [fx.headSha, fx.newBase, '0'.repeat(40),
    git(fx.repo, 'commit-tree', tree, '-p', fx.oldBase, '-m', 'wrong parent'),
    git(fx.repo, 'commit-tree', tree, '-p', fx.newBase, '-p', fx.headSha, '-m', 'multiple parents')])
    assert.equal(verifyCompositeReceipt({ ...options, mergeSha: badMerge }).status, 'rejected');
  for (const change of [
    () => put(fx.repo, backlogPath, before),
    () => put(fx.repo, backlogPath, after.replaceAll('"terminé 😀"', 'terminé 😀')),
    () => put(fx.repo, backlogPath, after.replace('status: in_progress', 'status: done')),
    () => put(fx.repo, 'src/value.mjs', 'export const value = 99;\n'),
    () => chmodSync(join(fx.repo, 'src/value.mjs'), 0o755),
    () => put(fx.repo, 'extra.txt', 'extra\n'),
    () => rmSync(join(fx.repo, 'src/value.mjs'))
  ]) {
    git(fx.repo, 'checkout', '-q', '--detach', merge);
    change(); git(fx.repo, 'add', '-A');
    const changedTree = git(fx.repo, 'write-tree');
    const changedMerge = git(fx.repo, 'commit-tree', changedTree, '-p', fx.newBase, '-m', 'wrong tree');
    assert.equal(verifyCompositeReceipt({ ...options, mergeSha: changedMerge }).status, 'rejected');
    git(fx.repo, 'reset', '--hard', '-q', merge);
  }
});

test('candidate original scalar conflicts and unlanded implementation refuse composition', async t => {
  for (const candidate of [
    repo => put(repo, backlogPath, backlog.replaceAll('status: refined', 'status: failed')),
    repo => put(repo, backlogPath, backlog.replaceAll('status: refined', 'status: "refined"')),
    repo => put(repo, '.gaai/core/scripts/lib/local-admission-executor.mjs', '// unlanded implementation\n')
  ]) {
    const fx = await fixture(t, { candidate,
      selector: policy => policy.selectors[0].path_prefixes.push('.gaai/core') });
    assert.equal(proveApplicability(fx).status, 'rejected');
  }
});

test('strict scalar integration supports quoted null numeric and block values', async t => {
  for (const [oldValue, newValue] of [
    ['"queued 😀"', '"terminé"'], ['null', '42'], ['0.5', 'null'],
    ['|\n    queued\n', '|\n    completed 😀\n']
  ]) {
    const before = backlog.replace('status: refined', `status: ${oldValue}`);
    const after = backlog.replace('status: refined', `status: ${newValue}`);
    const fx = await fixture(t, { before, after });
    const proof = proveApplicability(fx);
    assert.equal(proof.status, 'eligible', JSON.stringify(proof));
    assert.equal(proof.integrated_backlog_digest, hash(after));
  }
  const unrelated = await fixture(t, { orphanHead: true });
  assert.equal(proveApplicability(unrelated).reason, 'original_base_not_ancestor');
});

function withEmptyTree(repo, tree) {
  const empty = git(repo, 'mktree');
  const modified = spawnSync('git', ['-C', repo, 'mktree'], { encoding: 'utf8',
    input: `${git(repo, 'ls-tree', tree)}\n040000 tree ${empty}\tzz-empty\n` });
  assert.equal(modified.status, 0, modified.stderr);
  return modified.stdout.trim();
}

test('integration preserves the original UTF-8 BOM outside lifecycle scalar spans', async t => {
  const before = `\uFEFF${backlog}`;
  const after = before.replaceAll('status: refined', 'status: done');
  const fx = await fixture(t, { before, after });
  const proof = proveApplicability(fx);
  assert.equal(proof.status, 'eligible', JSON.stringify(proof));
  assert.equal(proof.integrated_backlog_digest, hash(Buffer.from(after)));
});

test('full integration tree rejects empty directory changes in base and squash', async t => {
  const changedBase = await fixture(t, { advanceTree: withEmptyTree });
  assert.equal(proveApplicability(changedBase).reason, 'base_delta_not_lifecycle');
  const fx = await fixture(t);
  const proof = proveApplicability(fx);
  const freshResults = await executePlan(fx.plan, { cwd: fx.repo, commandIds: proof.fresh_command_ids });
  const raw = await sealCompositeReceipt({ ...fx, originalResults: fx.results, freshResults,
    proof, boundary: 'final', storyId: 'S1', maxBytes: 65536, outcome: 'pass' });
  put(fx.repo, backlogPath, backlog.replaceAll('status: refined', 'status: done'));
  git(fx.repo, 'add', backlogPath);
  const tree = git(fx.repo, 'write-tree');
  const badMerge = git(fx.repo, 'commit-tree', withEmptyTree(fx.repo, tree), '-p', fx.newBase, '-m', 'extra empty tree');
  assert.equal(verifyCompositeReceipt({ repo: fx.repo, raw,
    repository: selector('https://example.invalid/fixture/project.git').repository,
    baseRef: 'staging', maxBytes: 65536, mergeSha: badMerge }).status, 'rejected');
});

test('exact root tree preserves empty trees and symlinks through historical verification', async t => {
  const fx = await fixture(t, { base(repo) { symlinkSync('src/value.mjs', join(repo, 'value-link')); },
    candidateTree: withEmptyTree });
  const proof = proveApplicability(fx);
  assert.equal(proof.status, 'eligible', JSON.stringify(proof));
  const freshResults = await executePlan(fx.plan, { cwd: fx.repo, commandIds: proof.fresh_command_ids });
  const raw = await sealCompositeReceipt({ ...fx, originalResults: fx.results, freshResults,
    proof, boundary: 'final', storyId: 'S1', maxBytes: 65536, outcome: 'pass' });
  put(fx.repo, backlogPath, backlog.replaceAll('status: refined', 'status: done'));
  git(fx.repo, 'add', backlogPath);
  // Git's independent tree writer preserves quoted opaque path bytes. Empty
  // trees are not index entries, so the literal oracle restores that entry.
  const tree = withEmptyTree(fx.repo, git(fx.repo, 'write-tree'));
  const merge = git(fx.repo, 'commit-tree', tree, '-p', fx.newBase, '-m', 'exact integration');
  const options = { repo: fx.repo, raw, repository: selector('https://example.invalid/fixture/project.git').repository,
    baseRef: 'staging', maxBytes: 65536, mergeSha: merge };
  assert.equal(verifyCompositeReceipt(options).status, 'verified');
  assert.equal(verifyCompositeReceipt({ ...options, raw: Buffer.concat([Buffer.from(raw), Buffer.from([0xff])]) }).status, 'rejected');
  assert.equal(verifyCompositeReceipt({ ...options, raw: Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(raw)]) }).status, 'rejected');
  const omitted = git(fx.repo, 'commit-tree', git(fx.repo, 'write-tree'), '-p', fx.newBase, '-m', 'missing empty entry');
  assert.equal(verifyCompositeReceipt({ ...options, mergeSha: omitted }).status, 'rejected');
});

test('pure integration tree preserves non-UTF-8 entry bytes and gitlinks without filesystem names', async t => {
  const fx = await fixture(t);
  const blob = git(fx.repo, 'rev-parse', `${fx.headSha}:src/value.mjs`);
  const empty = git(fx.repo, 'mktree');
  const entries = spawnSync('git', ['-C', fx.repo, 'ls-tree', '-z', `${fx.headSha}^{tree}`]).stdout;
  const opaque = Buffer.concat([
    Buffer.from(`100644 blob ${blob}\topaque-`), Buffer.from([0xff, 0xfe, 0]),
    Buffer.from(`120000 blob ${blob}\topaque-link\0`),
    Buffer.from(`160000 commit ${fx.oldBase}\topaque-gitlink\0`),
    Buffer.from(`040000 tree ${empty}\topaque-empty\0`)
  ]);
  const makeTree = bytes => {
    const result = spawnSync('git', ['-C', fx.repo, 'mktree', '-z'], { input: bytes });
    assert.equal(result.status, 0, result.stderr.toString());
    return result.stdout.toString().trim();
  };
  const tree = makeTree(Buffer.concat([entries, opaque]));
  const head = git(fx.repo, 'commit-tree', tree, '-p', fx.oldBase, '-m', 'opaque tree only');
  const integrated = Buffer.from(backlog.replaceAll('status: refined', 'status: done'));
  const newBlob = spawnSync('git', ['-C', fx.repo, 'hash-object', '-w', '--stdin'], { input: integrated });
  assert.equal(newBlob.status, 0);
  const oldBlob = git(fx.repo, 'rev-parse', `${fx.headSha}:${backlogPath}`);
  // mktree independently derives the expected complete root; no checkout or
  // index flags hide dirty state, and the opaque name never reaches macOS FS.
  const expected = makeTree(Buffer.concat([
    Buffer.from(entries.toString('latin1').replace(`${oldBlob}\t${backlogPath}`, `${newBlob.stdout.toString().trim()}\t${backlogPath}`), 'latin1'), opaque
  ]));
  assert.equal(deriveIntegratedTree(fx.repo, head, backlogPath, integrated, 1024 * 1024), expected);
  assert.equal(git(fx.repo, 'rev-parse', 'HEAD'), fx.headSha);
  assert.equal(git(fx.repo, 'status', '--porcelain'), '');
});

const forbidden = [
  ['own Story', backlog.replace('status: in_progress', 'status: done')],
  ['contract field', backlog.replace('title: Other', 'title: Changed')],
  ['root metadata', backlog.replace('mode: active', 'mode: passive')],
  ['comment', backlog.replace('title: Other', 'title: Other # hidden')],
  ['formatting', backlog.replace('mode: active', 'mode:  active')],
  ['duplicate mapping key', backlog.replace('title: Other', 'title: Other\n  status: done')],
  ['resolved duplicate keys', backlog.replace('mode: active', 'true: active\n1: passive')],
  ['duplicate Story', backlog.replace('id: S3', 'id: S2')],
  ['row addition', `${backlog}- id: S4\n  status: done\n`],
  ['row removal', backlog.slice(0, backlog.indexOf('- id: S3'))],
  ['row reorder', backlog.replace('id: S2', 'id: TEMP').replace('id: S3', 'id: S2').replace('id: TEMP', 'id: S3')],
  ['key insertion', backlog.replace('title: Other', 'title: Other\n  phase_status: done')],
  ['key removal', backlog.replace('  title: Other\n', '')],
  ['collection lifecycle', backlog.replace('status: refined', 'status: [done]')],
  ['anchor', backlog.replace('title: Other', 'title: &label Other')],
  ['alias', backlog.replace('title: Other', 'title: *label')],
  ['merge key', backlog.replace('title: Other', '<<: {status: done}\n  title: Other')],
  ['custom tag', backlog.replace('title: Other', 'title: !custom Other')],
  ['multiple documents', `${backlog}\n---\nitems: []\n`],
  ['malformed YAML', `${backlog}broken: [\n`]
];
for (const [name, after] of forbidden) test(`rejects ${name}`, async t => {
  const fx = await fixture(t, { after });
  assert.equal(proveApplicability(fx).status, 'rejected');
});

test('unchanged normalized diff digest cannot hide forbidden base contents', async t => {
  const fx = await fixture(t, { candidate: repo => put(repo, backlogPath, backlog.replace('title: Other', 'title: Candidate')),
    after: backlog.replace('title: Other', 'title: Base contract changed') });
  assert.equal(fx.originalPlan.binding.normalized_diff_digest, fx.plan.binding.normalized_diff_digest);
  assert.equal(proveApplicability(fx).reason, 'non_lifecycle_change');
});

test('project-shaped OSS plus governance candidate reconciles; newly selected governance rejects', async t => {
  const projectShape = policy => {
    policy.non_executable_prefixes = [];
    policy.selectors = [
      { id: 'oss', path_prefixes: ['src', '.gaai/core'], exact_paths: [], command_ids: ['unit'] },
      { id: 'governance', path_prefixes: ['.gaai/project'], exact_paths: [backlogPath], command_ids: ['governance'] }
    ];
  };
  const governed = await fixture(t, { selector: projectShape,
    candidate: repo => put(repo, '.gaai/project/contexts/artefacts/impl-reports/S1.md', 'Implementation evidence\n') });
  assert.deepEqual(governed.originalPlan.summary.selected_surface_ids, ['governance', 'oss']);
  assert.equal(proveApplicability(governed).status, 'eligible');
  const codeOnly = await fixture(t, { selector: projectShape });
  assert.deepEqual(codeOnly.originalPlan.summary.selected_surface_ids, ['oss']);
  assert.deepEqual(codeOnly.plan.summary.selected_surface_ids, ['governance', 'oss']);
  assert.equal(proveApplicability(codeOnly).reason, 'inputs_changed');
});

for (const [name, options] of [
  ['missing opt-in', { noOptIn: true }],
  ['candidate-only opt-in', { noOptIn: true, candidate: (repo, optIn) => put(repo, APPLICABILITY_PATH, optIn) }],
  ['unknown policy key', { optIn: policy => { policy.extra = true; } }],
  ['wildcard path', { optIn: policy => { policy.backlog_path = '*.yaml'; } }],
  ['unknown command', { optIn: policy => { policy.reusable_command_ids = ['missing']; } }],
  ['incomplete trust coverage', { registry: value => { value.covered_paths.pop(); } }],
  ['candidate registry weakening', { candidate: repo => {
    const value = JSON.parse(readFileSync(join(repo, registryPath), 'utf8')); value.covered_paths.pop(); put(repo, registryPath, value);
  } }],
  ['mixed code delta', { advance: repo => put(repo, 'src/other.mjs', 'export {};\n') }],
  ['selector delta', { advance: repo => put(repo, selectorPath, `${readFileSync(join(repo, selectorPath), 'utf8')} `) }],
  ['duplicate JSON key', { candidate: repo => {}, advance: repo => {
    const text = readFileSync(join(repo, APPLICABILITY_PATH), 'utf8');
    put(repo, APPLICABILITY_PATH, text.replace('"schema_version":', '"schema_version":"1.0.0", "schema_version":'));
  } }],
  ['duplicate base-held JSON key', { base: repo => {
    const text = readFileSync(join(repo, APPLICABILITY_PATH), 'utf8');
    put(repo, APPLICABILITY_PATH, text.replace('"schema_version":', '"schema_version":"1.0.0", "schema_version":'));
  } }],
  ['missing admitted Story', { before: backlog.replace('id: S1', 'id: Missing'),
    after: backlog.replace('id: S1', 'id: Missing').replaceAll('status: refined', 'status: done') }]
]) test(`rejects ${name}`, async t => {
  const fx = await fixture(t, options);
  assert.equal(proveApplicability(fx).status, 'rejected');
});

test('result and proof tampering cannot seal; same attempt and current clean candidate required', async t => {
  const fx = await fixture(t);
  const proof = proveApplicability(fx);
  assert.equal(proof.status, 'eligible');
  const freshResults = await executePlan(fx.plan, { cwd: fx.repo, commandIds: proof.fresh_command_ids });
  const seal = overrides => sealCompositeReceipt({ ...fx, originalResults: fx.results, freshResults,
    proof, boundary: 'final', storyId: 'S1', maxBytes: 65536, outcome: 'pass', ...overrides });
  for (const mutate of [
    rows => rows.pop(), rows => rows.reverse(), rows => rows.push(rows[0]),
    rows => { rows[0].exit_code = 9; }, rows => { rows[0].signal = 'SIGTERM'; },
    rows => { rows[0].outcome = 'failed'; }, rows => { rows[0].outcome = 'timed_out'; },
    rows => { rows[0].outcome = 'cancelled'; }, rows => { rows[0].execution.invocation_id = randomUUID(); },
    rows => { rows[1].execution.execution_id = rows[0].execution.execution_id; },
    rows => { rows[0].execution.materialized_argv_digest = '0'.repeat(64); }
  ]) {
    const results = structuredClone(fx.results); mutate(results);
    await assert.rejects(seal({ originalResults: results }));
  }
  await assert.rejects(seal({ proof: { ...proof, fresh_command_ids: [] } }));
  await assert.rejects(seal({ originalPlan: { ...fx.originalPlan,
    summary: { ...fx.originalPlan.summary, base_sha: '0'.repeat(40) } } }));
  await assert.rejects(seal({ freshResults: [] }));
  await assert.rejects(seal({ boundary: 'pre_qa' }));
  await assert.rejects(seal({ maxBytes: 1 }), /receipt_too_large/);
  const failed = structuredClone(freshResults); failed[0].outcome = 'failed'; failed[0].exit_code = 1;
  await assert.rejects(seal({ freshResults: failed }));
  put(fx.repo, 'untracked', 'dirty');
  assert.equal(proveApplicability(fx).reason, 'current_plan_invalid');
});

test('fresh environment, HEAD, configuration and dependency changes reject applicability', async t => {
  for (const kind of ['environment', 'head', 'configuration', 'dependency', 'selection', 'invocation']) {
    const fx = await fixture(t);
    if (kind === 'environment') fx.plan.binding.environment_digest = 'changed';
    if (kind === 'head') fx.plan.binding.head_sha = '0'.repeat(40);
    if (kind === 'configuration') fx.plan.selected_commands[0].configuration_digest = 'changed';
    if (kind === 'dependency') fx.plan.binding.dependency_digest = 'changed';
    if (kind === 'selection') fx.plan.selected_commands.reverse();
    if (kind === 'invocation') fx.plan.invocation = { ...fx.plan.invocation, id: randomUUID() };
    fx.plan.binding_digest = hash(canonicalJson(fx.plan.binding));
    assert.equal(proveApplicability(fx).status, 'rejected', kind);
  }
});

test('each required registration is mandatory', async t => {
  for (const path of [...IMPLEMENTATION_PATHS, APPLICABILITY_PATH]) {
    const fx = await fixture(t, { registry: value => { value.covered_paths = value.covered_paths.filter(item => item !== path); } });
    assert.equal(proveApplicability(fx).reason, 'trust_registry_invalid', path);
  }
});

test('non-fast-forward base rejects', async t => {
  const fx = await fixture(t);
  git(fx.repo, 'checkout', '-q', '--orphan', 'unrelated');
  put(fx.repo, backlogPath, backlog.replaceAll('status: refined', 'status: done'));
  put(fx.repo, 'src/value.mjs', 'export const value = 1;\n');
  git(fx.repo, 'add', '-A'); git(fx.repo, 'commit', '-qm', 'unrelated-base');
  const unrelated = git(fx.repo, 'rev-parse', 'HEAD');
  git(fx.repo, 'update-ref', 'refs/remotes/origin/staging', unrelated);
  git(fx.repo, 'checkout', '-q', '--detach', fx.headSha);
  assert.equal(proveApplicability({ ...fx, plan: fx.resolve(unrelated) }).reason, 'base_not_fast_forward');
});

test('existing hosted controller keeps all admission registrations human-only across base advancement', async t => {
  const fx = await fixture(t);
  const controller = fileURLToPath(new URL('../lib/test-gate.sh', import.meta.url));
  const identity = { id: 1, full_name: 'fixture/project' };
  const script = `source "$1"
_test_gate_gh_json() {
  case "$2" in
    'repos/{owner}/{repo}') printf '%s\\n' "$FIXTURE_REPOSITORY" ;;
    'repos/{owner}/{repo}/pulls/1') printf '%s\\n' "$FIXTURE_PR" ;;
    'repos/{owner}/{repo}/git/ref/heads/staging') printf '%s\\n' "$FIXTURE_REF" ;;
    *) return 1 ;;
  esac
}
_test_gate_gh_paginated_array() { printf '[{"number":1,"state":"open"}]\\n'; }
_test_gate_observe_authority_once S1 "$2" "$3" 10
`;
  for (const base of [fx.oldBase, fx.newBase]) {
    for (const path of [...IMPLEMENTATION_PATHS, APPLICABILITY_PATH]) {
      git(fx.repo, 'checkout', '-q', '--detach', base);
      put(fx.repo, path, 'changed trust surface\n');
      git(fx.repo, 'add', '-A'); git(fx.repo, 'commit', '-qm', 'trust-change');
      const head = git(fx.repo, 'rev-parse', 'HEAD');
      const pr = { number: 1, state: 'open', draft: false, mergeable: true,
        head: { ref: 'story', sha: head, repo: identity }, base: { ref: 'staging', sha: base, repo: identity } };
      const result = spawnSync('/bin/bash', ['-c', script, 'fixture', controller, fx.repo, head],
        { encoding: 'utf8', env: { ...process.env, GAAI_PREMERGE_AUTHORITY_POLICY_PATH: registryPath,
          FIXTURE_REPOSITORY: JSON.stringify(identity), FIXTURE_PR: JSON.stringify(pr),
          FIXTURE_REF: JSON.stringify({ object: { sha: base } }) } });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), 'human_required:trust_surface_changed', `${path}: ${result.stderr}`);
    }
  }
});

const shellLibrary = fileURLToPath(new URL('../lib/local-admission.sh', import.meta.url));
async function shellFixture(t, boundary, scenario = 'eligible') {
  const root = mkdtempSync(join(tmpdir(), 'admission-shell-proof-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, 'candidate'); const remote = join(root, 'remote.git'); const updater = join(root, 'updater');
  mkdirSync(repo); mkdirSync(remote);
  git(remote, 'init', '-q', '--bare'); git(repo, 'init', '-q');
  git(repo, 'config', 'user.name', 'Fixture'); git(repo, 'config', 'user.email', 'fixture@example.invalid');
  git(repo, 'config', 'core.hooksPath', '/dev/null'); git(repo, 'switch', '-qc', 'staging');
  git(repo, 'remote', 'add', 'origin', remote);
  const policy = selector(remote);
  policy.environment_passthrough = ['GAAI_FIXTURE_*'];
  policy.commands[0].argv = ['node', 'checks/run.mjs', 'unit'];
  policy.commands[1].argv = ['node', 'checks/run.mjs', 'governance', '{base_sha}'];
  policy.commands.forEach(command => { command.config_paths = ['checks/run.mjs']; });
  put(repo, selectorPath, policy);
  put(repo, APPLICABILITY_PATH, { schema_version: '1.0.0', repository: policy.repository,
    backlog_path: backlogPath, rows_key: 'items', identity_key: 'id', lifecycle_fields: ['status'],
    reusable_command_ids: ['unit'], trust_registry_path: registryPath });
  put(repo, registryPath, { schema_version: '1.0.0', repository: { id: 1, full_name: 'fixture/project', base_ref: 'staging' },
    workflow: { id: 1, path: '.github/workflows/check.yml', name: 'Checks', event: 'pull_request' },
    required_job: 'Authority', covered_paths: [registryPath, selectorPath, '.github/workflows/check.yml',
      ...requiredControllerPaths(65536), ...IMPLEMENTATION_PATHS, APPLICABILITY_PATH] });
  copyVerifierClosure(repo);
  put(repo, backlogPath, backlog); put(repo, 'lock.json', '{}\n'); put(repo, 'src/value.mjs', 'export const value = 1;\n');
  put(repo, 'checks/run.mjs', `import fs from 'node:fs';
import {spawn,spawnSync} from 'node:child_process';
const [kind, base] = process.argv.slice(2);
const root = process.env.GAAI_FIXTURE_ROOT;
fs.appendFileSync(root+'/'+kind+'.count', (base || 'unit')+'\\n');
if (kind === 'unit') {
 const result=spawnSync('git',['-C',root+'/updater','push','-q','origin','first:staging']);
 if(result.status!==0) process.exit(9);
}
if (kind === 'governance' && base !== process.env.GAAI_FIXTURE_OLD_BASE) {
 if(process.env.GAAI_FIXTURE_SCENARIO==='refresh_failure') process.exit(7);
 if(process.env.GAAI_FIXTURE_SCENARIO==='dirty_refresh') fs.writeFileSync('dirty.txt','dirty');
 if(process.env.GAAI_FIXTURE_SCENARIO==='refresh_caller_loss') {
  const child=spawn('sleep',['60'],{stdio:'ignore'});
  fs.writeFileSync(root+'/refresh-pids.json',JSON.stringify({executor:process.ppid,command:process.pid,child:child.pid}));
  await new Promise(resolve=>child.on('exit',resolve));
 }
}
`);
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'base'); git(repo, 'push', '-q', 'origin', 'staging');
  const oldBase = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'switch', '-qc', 'story'); put(repo, 'src/value.mjs', 'export const value = 2;\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'candidate');
  git(root, 'clone', '-q', '--branch', 'staging', remote, updater);
  git(updater, 'config', 'user.name', 'Fixture'); git(updater, 'config', 'user.email', 'fixture@example.invalid');
  put(updater, backlogPath, backlog.replaceAll('status: refined', 'status: done'));
  git(updater, 'add', '-A'); git(updater, 'commit', '-qm', 'first-lifecycle');
  git(updater, 'branch', 'first'); const newBase = git(updater, 'rev-parse', 'HEAD');
  put(updater, backlogPath, backlog.replaceAll('status: refined', 'status: failed'));
  git(updater, 'add', '-A'); git(updater, 'commit', '-qm', 'second-lifecycle'); git(updater, 'branch', 'second');
  const receipts = join(root, 'receipts');
  // Interpose only this fixture's receipt rename as a deterministic last-race
  // barrier; no polling worker, live repository or operator process is touched.
  const script = `source "$1"
node() {
  if [[ "\${GAAI_FIXTURE_SCENARIO:-}" == persistence_failure && "$2" == --mode && "$3" == retain ]]; then return 1; fi
  if [[ "\${GAAI_FIXTURE_SCENARIO:-}" == retained*collision && "$2" == --mode && "$3" == retain ]]; then
    local previous="" argument collision
    for argument in "$@"; do
      if [[ "$previous" == --output ]]; then
        collision="$argument"
        [[ "$GAAI_FIXTURE_SCENARIO" == retained_destination_collision ]] && collision="\${argument%.tmp.*}"
        printf 'existing evidence' > "$collision"
        printf '%s' "$collision" > "$GAAI_FIXTURE_ROOT/collision-path"
      fi
      previous="$argument"
    done
  fi
  command node "$@"
}
git() {
  if [[ "\${GAAI_FIXTURE_SCENARIO:-}" == final_fetch_failed && "$3" == fetch && -f "$GAAI_FIXTURE_RECEIPT" ]]; then return 1; fi
  command git "$@"
}
mv() {
  command mv "$@" || return $?
  if [[ ( "\${GAAI_FIXTURE_SCENARIO:-}" == last_race || "\${GAAI_FIXTURE_SCENARIO:-}" == persistence_failure || "\${GAAI_FIXTURE_SCENARIO:-}" == retained*collision ) && "$2" == "$GAAI_FIXTURE_RECEIPT" && "$1" != *.blocked.json* ]]; then
    command git -C "$GAAI_FIXTURE_ROOT/updater" push -q origin second:staging
  fi
}
_run_local_admission "$2" S1 "$3" staging "$4"
gate_rc=$?
printf '\\nGATE=%s|%s|%s\\n' "$gate_rc" "$LOCAL_ADMISSION_OUTCOME" "$LOCAL_ADMISSION_RECEIPT_PATH"
exit 0
`;
  const receipt = join(receipts, `.local-admission-S1-${boundary}.json`);
  const args = attemptBoundary => ['--noprofile', '--norc', '-c', script,
    'fixture', shellLibrary, attemptBoundary, repo, receipts];
  const env = { ...process.env, GAAI_LOCAL_ADMISSION_POLICY_PATH: selectorPath,
    GAAI_FIXTURE_ROOT: root, GAAI_FIXTURE_SCENARIO: scenario, GAAI_FIXTURE_OLD_BASE: oldBase,
    GAAI_FIXTURE_RECEIPT: receipt };
  const run = (attemptBoundary = boundary) => spawnSync(process.env.ADMISSION_TEST_BASH || '/bin/bash',
    args(attemptBoundary), { encoding: 'utf8', env });
  const launch = (attemptBoundary = boundary) => spawn(process.env.ADMISSION_TEST_BASH || '/bin/bash',
    args(attemptBoundary), { stdio: 'ignore', env });
  return { root, repo, remote, updater, oldBase, newBase, receipt, receipts, run, launch };
}

async function watcherFixture(t, composite) {
  const root = mkdtempSync(join(tmpdir(), 'admission-watcher-proof-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, 'repo'); const remote = join(root, 'remote.git'); const updater = join(root, 'updater');
  mkdirSync(repo); mkdirSync(remote); git(remote, 'init', '-q', '--bare'); git(repo, 'init', '-q');
  git(repo, 'config', 'user.name', 'Fixture'); git(repo, 'config', 'user.email', 'fixture@example.invalid');
  git(repo, 'config', 'core.hooksPath', '/dev/null'); git(repo, 'switch', '-qc', 'staging');
  git(repo, 'remote', 'add', 'origin', remote); copyVerifierClosure(repo);
  const policyPath = '.gaai/project/ci/local-admission.json';
  const backlogPath = '.gaai/project/contexts/backlog/active.backlog.yaml';
  const started = new Date(Date.now() - 60000).toISOString();
  const before = `items:\n- id: S1\n  status: in_progress\n  phase_status: qa_passed\n  pr_status: pending_review\n  pr_url: "https://github.com/fixture/project/pull/1"\n  started_at: "${started}"\n- id: S2\n  title: "😀 café"\n  status: refined\n`;
  const after = before.replace('status: refined', 'status: done');
  const policy = selector(remote);
  policy.non_executable_prefixes = [backlogPath];
  policy.environment_passthrough = ['GAAI_FIXTURE_*'];
  policy.commands[0].argv = ['node', 'checks/run.mjs', 'unit'];
  policy.commands[1].argv = ['node', 'checks/run.mjs', 'governance', '{base_sha}'];
  policy.commands.forEach(command => { command.config_paths = ['checks/run.mjs']; });
  put(repo, policyPath, policy);
  if (composite) {
    put(repo, APPLICABILITY_PATH, { schema_version: '1.0.0', repository: policy.repository,
      backlog_path: backlogPath, rows_key: 'items', identity_key: 'id', lifecycle_fields: ['status'],
      reusable_command_ids: ['unit'], trust_registry_path: registryPath });
    put(repo, registryPath, { schema_version: '1.0.0', repository: { id: 1, full_name: 'fixture/project', base_ref: 'staging' },
      workflow: { id: 1, path: '.github/workflows/check.yml', name: 'Checks', event: 'pull_request' },
      required_job: 'Authority', covered_paths: [...new Set([registryPath, policyPath, '.github/workflows/check.yml',
        ...requiredControllerPaths(65536), ...IMPLEMENTATION_PATHS, APPLICABILITY_PATH])] });
  }
  put(repo, backlogPath, before); put(repo, 'lock.json', '{}\n'); put(repo, 'src/value.mjs', 'export const value = 1;\n');
  put(repo, 'checks/run.mjs', `import fs from 'node:fs'; import {spawnSync} from 'node:child_process';
const [kind, base] = process.argv.slice(2); const root = process.env.GAAI_FIXTURE_ROOT;
fs.appendFileSync(root+'/'+kind+'.count', (base || 'unit')+'\\n');
if(kind==='unit' && process.env.GAAI_FIXTURE_ADVANCE==='yes') {
  const result=spawnSync('git',['-C',root+'/updater','push','-q','origin','staging']);
  if(result.status!==0)process.exit(9);
}
`);
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'base'); git(repo, 'push', '-q', 'origin', 'staging');
  const oldBase = git(repo, 'rev-parse', 'HEAD');
  git(root, 'clone', '-q', '--branch', 'staging', remote, updater);
  git(updater, 'config', 'user.name', 'Fixture'); git(updater, 'config', 'user.email', 'fixture@example.invalid');
  put(updater, backlogPath, after); git(updater, 'add', backlogPath); git(updater, 'commit', '-qm', 'other lifecycle');
  const newBase = composite ? git(updater, 'rev-parse', 'HEAD') : oldBase;
  git(repo, 'switch', '-qc', 'candidate'); put(repo, 'src/value.mjs', 'export const value = 2;\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'candidate');
  const head = git(repo, 'rev-parse', 'HEAD');
  const state = join(root, 'state'); const receipts = join(state, 'local-admission-receipts');
  for (const path of [state, receipts, join(state, 'external-merge-settlements')]) mkdirSync(path, { mode: 0o700 });
  const gate = spawnSync(process.env.ADMISSION_TEST_BASH || '/bin/bash', ['--noprofile', '--norc', '-c',
    'source "$1"; _run_local_admission final S1 "$2" staging "$3"', 'fixture', shellLibrary, repo, receipts],
  { encoding: 'utf8', env: { ...process.env, GAAI_LOCAL_ADMISSION_POLICY_PATH: policyPath,
    GAAI_FIXTURE_ROOT: root, GAAI_FIXTURE_ADVANCE: composite ? 'yes' : 'no' } });
  assert.equal(gate.status, 0, gate.stdout + gate.stderr);
  const receiptPath = join(receipts, '.local-admission-S1-final.json');
  const raw = readFileSync(receiptPath, 'utf8'); const receipt = JSON.parse(raw);
  assert.equal(receipt.schema_version, composite ? '2.0.0' : '1.0.0');
  assert.equal(git(repo, 'rev-parse', 'HEAD'), head);
  assert.deepEqual(readFileSync(join(root, 'unit.count'), 'utf8').trim().split('\n'), ['unit']);
  assert.deepEqual(readFileSync(join(root, 'governance.count'), 'utf8').trim().split('\n'),
    composite ? [oldBase, newBase] : [oldBase]);
  if (composite) assert.equal(spawnSync('git', ['-C', repo, 'merge-base', '--is-ancestor', newBase, head]).status, 1);
  // The oracle uses literal independent fixture contents, never integrationDigest.
  if (composite) { put(repo, backlogPath, after); git(repo, 'add', backlogPath); }
  const tree = git(repo, 'write-tree');
  const merge = git(repo, 'commit-tree', tree, '-p', newBase, '-m', 'external squash');
  git(repo, 'push', '-q', 'origin', `${head}:refs/heads/admitted-head`);
  git(repo, 'reset', '--hard', '-q', merge); git(repo, 'push', '-q', 'origin', 'HEAD:staging');
  const mergedAt = new Date(Date.now() + 1000).toISOString();
  const bin = join(root, 'bin'); mkdirSync(bin);
  const github = { url: 'https://github.com/fixture/project/pull/1', number: 1, state: 'MERGED',
    createdAt: started, mergedAt, baseRefName: 'staging', headRefOid: head,
    headRepository: { nameWithOwner: 'fixture/project' }, isCrossRepository: false, mergeCommit: { oid: merge } };
  put(root, 'github.json', github);
  put(root, 'bin/gh', '#!/bin/sh\ncase "$*" in *"pr view"*) cat "$WATCHER_FIXTURE_JSON" ;; *) exit 1 ;; esac\n');
  chmodSync(join(bin, 'gh'), 0o755);
  const run = () => spawnSync(process.env.ADMISSION_TEST_BASH || '/bin/bash',
    [join(repo, '.gaai/core/scripts/delivery-daemon.sh'), '--watch-once-story', 'S1', '--operator-state-root', state],
    { encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WATCHER_FIXTURE_JSON: join(root, 'github.json'),
      GAAI_OBSERVER_ONLY: 'different process environment' } });
  const target = () => git(remote, 'rev-parse', 'refs/heads/staging');
  const sync = () => { git(repo, 'fetch', '-q', 'origin', 'staging'); git(repo, 'reset', '--hard', '-q', 'origin/staging'); };
  return { root, repo, remote, state, raw, receipt, receiptPath, run, target, sync, merge, newBase, head, tree,
    backlogPath, before, after, github };
}

for (const composite of [false, true]) test(`watcher real producer ${composite ? 'composite' : 'ordinary'} terminal and legacy matrix`,
  { skip: process.env.ADMISSION_WATCHER_E2E !== '1' }, async t => {
    const fx = await watcherFixture(t, composite);
    // Invalid evidence has no lifecycle or settlement effect, even with a
    // recomputed self-digest. Restore only this fixture's private receipt.
    for (const mutate of [
      receipt => { receipt.schema_version = 'unknown'; },
      receipt => { receipt.boundary = 'pre_qa'; },
      receipt => { receipt.outcome = 'blocked:stale_evidence'; },
      ...(composite ? [
        receipt => { receipt.applicability.delta_digest = '0'.repeat(64); },
        receipt => { receipt.provenance[0].execution_id = randomUUID(); }
      ] : [])
    ]) {
      const changed = structuredClone(fx.receipt); mutate(changed); writeFileSync(fx.receiptPath, signed(changed));
      assert.notEqual(fx.run().status, 0);
      assert.equal(fx.target(), fx.merge);
      assert.equal(readdirSync(join(fx.state, 'external-merge-settlements')).length, 0);
    }
    writeFileSync(fx.receiptPath, fx.raw);
    if (composite) {
      const oldBase = fx.receipt.original_execution.binding.base_sha;
      for (const badMerge of [
        git(fx.repo, 'commit-tree', git(fx.repo, 'rev-parse', `${fx.head}^{tree}`), '-p', fx.newBase, '-m', 'omitted delta'),
        git(fx.repo, 'commit-tree', fx.tree, '-p', oldBase, '-m', 'wrong parent'),
        git(fx.repo, 'commit-tree', fx.tree, '-p', fx.newBase, '-p', fx.head, '-m', 'multiple parents')
      ]) {
        git(fx.repo, 'push', '-q', 'origin', `${badMerge}:refs/heads/negative-${badMerge}`);
        git(fx.remote, 'update-ref', 'refs/heads/staging', badMerge); fx.sync();
        put(fx.root, 'github.json', { ...fx.github, mergeCommit: { oid: badMerge } });
        assert.notEqual(fx.run().status, 0); assert.equal(fx.target(), badMerge);
        assert.equal(readdirSync(join(fx.state, 'external-merge-settlements')).length, 0);
      }
      git(fx.remote, 'update-ref', 'refs/heads/staging', fx.merge); fx.sync();
      put(fx.root, 'github.json', fx.github);
      // Target-held closure refusal, without candidate or ambient fallbacks.
      const helper = '.gaai/core/scripts/lib/local-admission-resolver.mjs';
      chmodSync(join(fx.repo, helper), 0o666);
      assert.notEqual(fx.run().status, 0); assert.equal(fx.target(), fx.merge);
      chmodSync(join(fx.repo, helper), 0o644);
      rmSync(join(fx.repo, helper)); git(fx.repo, 'add', '-A'); git(fx.repo, 'commit', '-qm', 'partial verifier closure');
      git(fx.repo, 'push', '-q', 'origin', 'HEAD:staging');
      const partialTarget = fx.target();
      assert.notEqual(fx.run().status, 0); assert.equal(fx.target(), partialTarget);
      assert.equal(readdirSync(join(fx.state, 'external-merge-settlements')).length, 0);
      git(fx.remote, 'update-ref', 'refs/heads/staging', fx.merge); fx.sync();
    }
    // The exact immutable old entry is committed only into this owned target
    // after the external squash. Its own target-held entrypoint guard remains active.
    const legacy = gunzipSync(Buffer.from(LEGACY_WATCHER_GZIP, 'base64'));
    assert.equal(hash(legacy), LEGACY_WATCHER_DIGEST);
    put(fx.repo, '.gaai/core/scripts/delivery-daemon.sh', legacy);
    git(fx.repo, 'add', '-A'); git(fx.repo, 'commit', '-qm', 'legacy observer');
    git(fx.repo, 'push', '-q', 'origin', 'HEAD:staging');
    const legacyTarget = fx.target();
    const oldRun = fx.run();
    if (composite) {
      assert.notEqual(oldRun.status, 0, 'legacy reader must reject composite');
      assert.equal(fx.target(), legacyTarget);
    } else {
      assert.equal(oldRun.status, 0, oldRun.stdout + oldRun.stderr);
      assert.match(git(fx.remote, 'show', `refs/heads/staging:${fx.backlogPath}`), /status: done/);
      // Keep the old settlement as evidence, then start an independent current
      // reader case from the same immutable merge and a new operator state.
      const saved = readFileSync(join(fx.state, 'external-merge-settlements/.external-merge-S1.json'));
      put(fx.root, 'legacy-settlement.json', saved);
      rmSync(join(fx.state, 'external-merge-settlements/.external-merge-S1.json'));
    }
    git(fx.remote, 'update-ref', 'refs/heads/staging', fx.merge); fx.sync();
    const currentRun = fx.run();
    assert.equal(currentRun.status, 0, currentRun.stdout + currentRun.stderr);
    const settled = fx.target();
    assert.equal(git(fx.remote, 'show', '-s', '--format=%P', settled), fx.merge);
    const projected = git(fx.remote, 'show', `${settled}:${fx.backlogPath}`);
    assert.match(projected, /phase_status: done/); assert.match(projected, /pr_status: merged/);
    if (composite) assert.match(projected, /id: S2[\s\S]*status: done/);
    fx.sync(); put(fx.repo, 'later.txt', 'later target\n'); git(fx.repo, 'add', '-A'); git(fx.repo, 'commit', '-qm', 'later target');
    git(fx.repo, 'push', '-q', 'origin', 'HEAD:staging'); const later = fx.target();
    const repeat = fx.run();
    assert.equal(repeat.status, 0, repeat.stdout + repeat.stderr); assert.equal(fx.target(), later);
  });

for (const scenario of ['retained_collision', 'retained_destination_collision'])
test(`${scenario} refuses without deleting pre-existing evidence`, async t => {
  const fx = await shellFixture(t, 'final', scenario);
  const result = fx.run();
  assert.match(result.stdout, /GATE=1\|blocked:evidence_persistence_failed\|/);
  const collision = readFileSync(join(fx.root, 'collision-path'), 'utf8');
  assert.equal(readFileSync(collision, 'utf8'), 'existing evidence');
  assert.equal(existsSync(fx.receipt), false);
});

for (const boundary of ['pre_qa', 'final']) test(`shell ${boundary} reuses expensive execution and refreshes exact base argv`, async t => {
  const fx = await shellFixture(t, boundary);
  const result = fx.run();
  assert.match(result.stdout, /GATE=0\|pass\|/, result.stderr);
  const receipt = JSON.parse(readFileSync(fx.receipt, 'utf8'));
  assert.equal(receipt.publication_admitted, boundary === 'final');
  assert.equal(readFileSync(join(fx.root, 'unit.count'), 'utf8'), 'unit\n');
  assert.equal(readFileSync(join(fx.root, 'governance.count'), 'utf8'), `${fx.oldBase}\n${fx.newBase}\n`);
  assert.equal(receipt.original_execution.binding.base_sha, fx.oldBase);
  assert.equal(receipt.candidate.base_sha, fx.newBase);
  assert.equal(receipt.original_execution.results[0].execution.execution_id, receipt.results[0].execution.execution_id);
  assert.notEqual(receipt.original_execution.results[1].execution.execution_id, receipt.results[1].execution.execution_id);
  const next = fx.run();
  assert.match(next.stdout, /GATE=0\|pass\|/, next.stderr);
  const second = JSON.parse(readFileSync(fx.receipt, 'utf8'));
  assert.notEqual(second.invocation_id, receipt.invocation_id);
  assert.equal(readFileSync(join(fx.root, 'unit.count'), 'utf8'), 'unit\nunit\n');
  if (boundary === 'pre_qa') {
    const final = fx.run('final');
    assert.match(final.stdout, /GATE=0\|pass\|/, final.stderr);
    assert.equal(readFileSync(join(fx.root, 'unit.count'), 'utf8'), 'unit\nunit\nunit\n');
  }
});

test('caller loss during refreshed execution kills the executor and its command group', async t => {
  const fx = await shellFixture(t, 'final', 'refresh_caller_loss');
  const gate = fx.launch();
  t.after(() => { try { gate.kill('SIGKILL'); } catch {} });
  const pidPath = join(fx.root, 'refresh-pids.json');
  // Liveness bounds, not timing assertions: reaching the refreshed command runs a
  // whole gate (fetch, resolve, execute, re-resolve), which takes several seconds
  // on a loaded host; teardown waits out the executor's once-a-second parent check.
  const waitUntil = async (predicate, ms) => {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      if (predicate()) return true;
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    return false;
  };
  assert.equal(await waitUntil(() => existsSync(pidPath), 120000), true, 'refreshed command did not start');
  const pids = JSON.parse(readFileSync(pidPath, 'utf8'));
  assert.equal(pids.executor > 0 && pids.command > 0 && pids.child > 0, true);
  gate.kill('SIGKILL');
  const gone = pid => { try { process.kill(pid, 0); return false; } catch { return true; } };
  assert.equal(await waitUntil(() => gone(pids.executor) && gone(pids.command) && gone(pids.child), 15000), true,
    `refreshed execution survived caller loss: ${JSON.stringify(pids)}`);
  assert.equal(existsSync(fx.receipt), false, 'caller loss produced a conventional receipt');
  const marker = readdirSync(fx.receipts).find(name => name.endsWith('.inflight.json'));
  assert.ok(marker, 'fixture never published its in-flight binding');
  const gateStatus = spawnSync('/bin/bash', [fileURLToPath(new URL('../gate-status.sh', import.meta.url)),
    '--quiet', fx.receipts], { encoding: 'utf8' });
  assert.equal(gateStatus.status, 0, gateStatus.stdout + gateStatus.stderr);
});

for (const scenario of ['last_race', 'dirty_refresh', 'refresh_failure', 'final_fetch_failed']) test(`shell retains non-authorizing ${scenario} evidence`, async t => {
  const fx = await shellFixture(t, 'final', scenario);
  const result = fx.run();
  assert.match(result.stdout, /GATE=1\|blocked:/, result.stderr);
  const receipt = JSON.parse(readFileSync(fx.receipt, 'utf8'));
  assert.equal(receipt.publication_admitted, false);
  assert.notEqual(receipt.outcome, 'pass');
  if (scenario !== 'refresh_failure') {
    assert.match(result.stdout, /GATE=1\|blocked:stale_evidence\|\s*$/);
    assert.equal(receipt.current, false);
    assert.equal(receipt.original_execution.results.length, 2);
    assert.equal(receipt.original_execution.results[0].outcome, 'passed');
    assert.equal(receipt.fresh_results.length, 1);
  } else assert.match(result.stdout, /blocked:command_failed/);
});

test('shell pre_qa keeps its composite receipt when the base advances again after sealing', async t => {
  const fx = await shellFixture(t, 'pre_qa', 'last_race');
  const result = fx.run();
  assert.match(result.stdout, /GATE=0\|pass\|/, result.stderr);
  assert.match(result.stdout, new RegExp(`base_advanced=[0-9a-f]{40} pinned_base=${fx.newBase} candidate=unchanged`));
  const receipt = JSON.parse(readFileSync(fx.receipt, 'utf8'));
  assert.equal(receipt.outcome, 'pass');
  assert.equal(receipt.publication_admitted, false);
  assert.equal(receipt.candidate.base_sha, fx.newBase);
  assert.equal(receipt.original_execution.binding.base_sha, fx.oldBase);
});

test('retention write failure removes current PASS and reports no retained evidence', async t => {
  const fx = await shellFixture(t, 'final', 'persistence_failure');
  const result = fx.run();
  assert.match(result.stdout, /GATE=1\|blocked:evidence_persistence_failed\|\s*$/);
  assert.equal(existsSync(fx.receipt), false);
  assert.equal(readdirSync(join(fx.root, 'receipts')).some(name => name.endsWith('.blocked.json')), false);
  assert.equal(readdirSync(join(fx.root, 'receipts')).some(name => name.endsWith('.inflight.json')), false);
  assert.doesNotMatch(result.stdout, /retained=/);
});
