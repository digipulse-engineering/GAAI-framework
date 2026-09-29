#!/usr/bin/env node
// Read-only account of a pre-QA admission, for the QA agent.
//
// The pre-QA gate has just proven its selected commands on the exact candidate
// QA is about to judge. Whether that receipt is still usable as regression
// evidence is a deterministic question, so it is answered here — once, before
// QA writes anything into the worktree — and not in model turns. The result is
// information for the agent. It never authorizes anything: publication still
// rests on the admitted head captured at gate time and the final-boundary
// receipt.
//
// Usage: qa-admission-evidence.mjs --receipt <path|''> --story-id <id>
//   --repo <worktree> --admitted-head <sha|''> --admitted-base <sha|''>
//   --qa-base-ref <ref> --policy <repo-relative path> --output <path>
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { canonicalJson } from './local-admission-executor.mjs';

const SCHEMAS = new Set(['1.0.0', '2.0.0']);
const SHA = /^[0-9a-f]{40}$/;

class Unusable extends Error {}
const reject = reason => { throw new Unusable(reason); };

function git(repo, args) {
  const result = spawnSync('git', ['-C', repo, ...args], {
    encoding: 'utf8', env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' } });
  return { ok: !result.error && result.status === 0, out: result.stdout || '' };
}

// The same clean-tree predicate the resolver applies to a candidate, so the
// bytes QA judges are the bytes that were admitted.
function worktreeClean(repo) {
  const status = git(repo, ['status', '--porcelain=v1', '--untracked-files=all', '--', '.',
    ':(exclude,top).delivery-logs/**']);
  return status.ok && status.out.length === 0;
}

// Command argv as the base-held policy declares it. Display only: a policy the
// base cannot supply leaves argv null and does not affect consumability.
function policyArgv(repo, baseSha, policyPath) {
  if (!policyPath || policyPath.startsWith('/') || policyPath.split('/').includes('..')) return new Map();
  const blob = git(repo, ['cat-file', 'blob', `${baseSha}:${policyPath}`]);
  if (!blob.ok) return new Map();
  try {
    const commands = JSON.parse(blob.out).commands;
    return new Map((Array.isArray(commands) ? commands : [])
      .filter(command => typeof command?.id === 'string' && Array.isArray(command.argv))
      .map(command => [command.id, command.argv]));
  } catch { return new Map(); }
}

export async function evaluate({ receipt: receiptPath, storyId, repo, admittedHead,
  admittedBase, qaBaseRef, policy }) {
  if (!receiptPath) reject('receipt_absent');
  let raw;
  try { raw = await readFile(receiptPath, 'utf8'); } catch { reject('receipt_unreadable'); }
  let receipt;
  try { receipt = JSON.parse(raw); } catch { reject('receipt_unparseable'); }
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) reject('receipt_unparseable');
  if (!SCHEMAS.has(receipt.schema_version)) reject('receipt_schema_unsupported');
  const { receipt_digest: stored, ...body } = receipt;
  const recomputed = createHash('sha256').update(canonicalJson(body)).digest('hex');
  if (typeof stored !== 'string' || recomputed !== stored) reject('receipt_integrity_failed');
  if (receipt.boundary !== 'pre_qa') reject('receipt_other_boundary');
  if (receipt.story_id !== storyId) reject('receipt_other_story');
  if (receipt.outcome !== 'pass') reject('receipt_not_pass');

  const candidate = receipt.candidate || {};
  const head = git(repo, ['rev-parse', 'HEAD']).out.trim();
  if (!SHA.test(candidate.head_sha || '') || candidate.head_sha !== head
      || candidate.head_sha !== admittedHead) reject('receipt_head_mismatch');
  if (!SHA.test(admittedBase || '')) reject('admitted_base_unknown');
  if (candidate.base_sha !== admittedBase) reject('receipt_base_mismatch');
  const qaBase = git(repo, ['rev-parse', '--verify', '-q', `${qaBaseRef}^{commit}`]).out.trim();
  if (!SHA.test(qaBase) || !git(repo, ['merge-base', '--is-ancestor', admittedBase, qaBase]).ok)
    reject('receipt_base_not_in_qa_base');
  if (!worktreeClean(repo)) reject('worktree_dirty');

  const selected = receipt.selected_command_ids;
  const results = Array.isArray(receipt.results) ? receipt.results : [];
  if (!Array.isArray(selected) || selected.length === 0 || new Set(selected).size !== selected.length
      || results.length !== selected.length
      || !selected.every(id => results.filter(r => r?.command_id === id).length === 1)
      || !results.every(r => r?.outcome === 'passed')) reject('receipt_results_incomplete');

  const argv = policyArgv(repo, candidate.base_sha, policy);
  return {
    consumable: true, reason: 'consumable', receipt_path: receiptPath, receipt_digest: stored,
    receipt_schema_version: receipt.schema_version, head_sha: candidate.head_sha,
    base_ref: candidate.base_ref ?? null, base_sha: candidate.base_sha,
    qa_base_ref: qaBaseRef, qa_base_sha: qaBase,
    selected_surface_ids: Array.isArray(receipt.selected_surface_ids) ? receipt.selected_surface_ids : [],
    selected_command_ids: selected,
    // Every command the policy declares, so QA can tell an unselected policy
    // command from one of the Story's own suites. Display only; [] when unreadable.
    policy_path: policy || null,
    declared_commands: [...argv].map(([id, commandArgv]) => ({ id, argv: commandArgv })),
    commands: selected.map(id => {
      const result = results.find(r => r.command_id === id);
      return { id, outcome: result.outcome, exit_code: result.exit_code ?? null,
        duration_ms: result.duration_ms ?? null, argv: argv.get(id) ?? null };
    }),
  };
}

function parse(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]?.replace(/^--/, '');
    if (!key || !argv[index]?.startsWith('--') || argv[index + 1] === undefined
        || Object.hasOwn(options, key)) throw new Error('input_invalid');
    options[key] = argv[index + 1];
  }
  for (const key of ['story-id', 'repo', 'qa-base-ref', 'output'])
    if (!options[key]) throw new Error('input_invalid');
  return options;
}

async function main() {
  const args = parse(process.argv.slice(2));
  let evidence;
  try {
    evidence = await evaluate({ receipt: args.receipt, storyId: args['story-id'], repo: args.repo,
      admittedHead: args['admitted-head'] || '', admittedBase: args['admitted-base'] || '',
      qaBaseRef: args['qa-base-ref'], policy: args.policy || '' });
  } catch (error) {
    if (!(error instanceof Unusable)) throw error;
    evidence = { consumable: false, reason: error.message, receipt_path: args.receipt || null };
  }
  const document = { schema_version: 1, story_id: args['story-id'], ...evidence,
    evaluated_at: new Date().toISOString() };
  const tmp = `${args.output}.tmp.${process.pid}`;
  await writeFile(tmp, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, args.output);
  // One log fragment for the daemon's [QA-ADMISSION] line.
  const selected = document.selected_command_ids?.join(',');
  process.stdout.write(`consumable=${document.consumable} reason=${document.reason}`
    + ` receipt=${document.receipt_path || 'none'} digest=${document.receipt_digest || 'none'}`
    + ` head=${document.head_sha || 'none'} selected=${selected || 'none'}\n`);
}

// Compared through realpath: Node reports the canonical module URL, so a caller
// reaching this file through a symlinked directory would otherwise skip main().
const invokedDirectly = () => {
  try { return import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href; }
  catch { return false; }
};
if (process.argv[1] && invokedDirectly()) {
  main().catch(() => { process.exitCode = 2; });
}
