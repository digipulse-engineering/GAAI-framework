#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const VERSION = '1.0.0';
const RESULT_KEYS = ['command_id', 'descriptor_digest', 'configuration_digest', 'outcome',
  'exit_code', 'signal', 'duration_ms', 'stdout_bytes', 'stderr_bytes',
  'stdout_truncated', 'stderr_truncated'];
const digest = value => createHash('sha256').update(value).digest('hex');
export const canonicalJson = value => {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort()
    .map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
};

// Delivery-variable filtering, not a sandbox. The gate attests a sealed
// candidate, and the caller is usually the delivery wrapper, whose GAAI_*
// variables describe the delivery in progress: phase pointers into the live
// worktree, routing, executor credentials. A command that honours one of them
// reaches past the seal (a test shim once overwrote the live QA report through
// GAAI_QA_REPORT_PATH, unsealing the candidate mid-run on every cycle). So the
// GAAI_ namespace is dropped, except the names the project's policy declares
// as pass-through — those are legitimate test and corpus inputs, and the
// resolver has already bound a digest of each value into the receipt. Every
// other variable passes through unchanged.
export const gateEnvironment = (env = process.env, keep = []) =>
  Object.fromEntries(Object.entries(env).filter(([name]) => !name.startsWith('GAAI_') || keep.includes(name)));

function terminate(child) {
  try {
    if (process.platform === 'win32') child.kill('SIGKILL');
    else process.kill(-child.pid, 'SIGKILL');
  } catch { /* already exited */ }
}

export function executeCommand(command, { cwd, signal, keep = [] } = {}) {
  return new Promise(resolve => {
    const started = Date.now();
    const counts = { stdout: 0, stderr: 0 };
    const truncated = { stdout: false, stderr: false };
    let forced = null;
    let settled = false;
    let timer;
    const child = spawn(command.argv[0], command.argv.slice(1), {
      cwd, env: gateEnvironment(process.env, keep), shell: false, detached: process.platform !== 'win32',
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const finish = (code, childSignal) => {
      if (settled) return;
      settled = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel); terminate(child);
      const outcome = forced || (childSignal ? 'cancelled' : code === 0 ? 'passed' : 'failed');
      resolve({ command_id: command.id, descriptor_digest: command.descriptor_digest,
        configuration_digest: command.configuration_digest, outcome,
        exit_code: Number.isInteger(code) ? code : null, signal: childSignal || null,
        duration_ms: Date.now() - started, stdout_bytes: counts.stdout,
        stderr_bytes: counts.stderr, stdout_truncated: truncated.stdout,
        stderr_truncated: truncated.stderr });
    };
    for (const [name, stream] of [['stdout', child.stdout], ['stderr', child.stderr]]) {
      stream.on('data', chunk => {
        if (counts[name] + chunk.length > command.output_limit_bytes) truncated[name] = true;
        counts[name] = Math.min(command.output_limit_bytes, counts[name] + chunk.length);
      });
    }
    child.on('error', () => finish(null, null));
    child.on('close', finish);
    const cancel = () => { forced = 'cancelled'; terminate(child); };
    signal?.addEventListener('abort', cancel, { once: true });
    timer = setTimeout(() => { forced = 'timed_out'; terminate(child); },
      command.timeout_seconds * 1000);
    if (signal?.aborted) cancel();
  });
}

export async function executePlan(plan, options = {}) {
  const declared = Array.isArray(plan.environment_passthrough) ? plan.environment_passthrough : [];
  if (!declared.every(name => typeof name === 'string' && /^GAAI_[A-Z0-9_]+$/.test(name))) throw new Error('plan_invalid');
  const results = [];
  for (const command of plan.selected_commands) results.push(await executeCommand(command, { ...options, keep: declared }));
  return results;
}

function validateEvidence(plan, results, resultsDigest) {
  if (!Array.isArray(results) || digest(canonicalJson(results)) !== resultsDigest) throw new Error('evidence_invalid');
  if (plan.status !== 'resolved') {
    if (results.length) throw new Error('evidence_invalid');
    return false;
  }
  if (!plan.binding || digest(canonicalJson(plan.binding)) !== plan.binding_digest
      || !Array.isArray(plan.selected_commands) || !plan.selected_commands.length
      || plan.selected_commands.length !== plan.binding.command_digests?.length
      || results.length !== plan.selected_commands.length)
    throw new Error('evidence_invalid');
  for (let index = 0; index < results.length; index++) {
    const result = results[index]; const command = plan.selected_commands[index];
    const bound = plan.binding.command_digests[index];
    if (!result || Object.keys(result).length !== RESULT_KEYS.length
        || !RESULT_KEYS.every(key => Object.hasOwn(result, key))
        || result.command_id !== command.id || result.descriptor_digest !== command.descriptor_digest
        || result.configuration_digest !== command.configuration_digest
        || bound.id !== command.id || bound.descriptor_digest !== command.descriptor_digest
        || bound.configuration_digest !== command.configuration_digest
        || !['passed', 'failed', 'timed_out', 'cancelled'].includes(result.outcome)
        || !Number.isSafeInteger(result.duration_ms) || result.duration_ms < 0
        || !['stdout', 'stderr'].every(name => Number.isSafeInteger(result[`${name}_bytes`])
          && result[`${name}_bytes`] >= 0 && result[`${name}_bytes`] <= command.output_limit_bytes
          && typeof result[`${name}_truncated`] === 'boolean')) throw new Error('evidence_invalid');
  }
  return results.every(result => result.outcome === 'passed');
}

export function sealReceipt({ boundary, storyId, plan, results, resultsDigest, outcome,
  expectedBindingDigest, createdAt = new Date().toISOString(), maxBytes }) {
  const allPassed = validateEvidence(plan, results, resultsDigest);
  if (plan.status === 'resolved' && plan.binding_digest !== expectedBindingDigest) throw new Error('evidence_stale');
  const publicationAdmitted = boundary === 'final' && outcome === 'pass' && allPassed;
  const receipt = { schema_version: VERSION, boundary, story_id: storyId,
    candidate: plan.binding || null, binding_digest: plan.binding_digest || null,
    selected_surface_ids: plan.summary?.selected_surface_ids || [],
    selected_command_ids: plan.summary?.selected_command_ids || [], results, outcome,
    publication_admitted: publicationAdmitted, created_at: createdAt };
  receipt.receipt_digest = digest(canonicalJson(receipt));
  const bytes = `${canonicalJson(receipt)}\n`;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || Buffer.byteLength(bytes) > maxBytes) {
    const error = new Error('receipt_too_large'); error.reason = 'receipt_too_large'; throw error;
  }
  return bytes;
}

function parse(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]?.replace(/^--/, '');
    if (!key || !argv[index]?.startsWith('--') || argv[index + 1] === undefined
        || Object.hasOwn(options, key)) throw new Error('input_invalid');
    options[key] = argv[index + 1];
  }
  return options;
}

async function main() {
  const args = parse(process.argv.slice(2));
  if (args.mode === 'execute') {
    const plan = JSON.parse(await readFile(args.plan, 'utf8'));
    if (plan.status !== 'resolved' || !Array.isArray(plan.selected_commands)) throw new Error('plan_invalid');
    const results = await executePlan(plan, { cwd: args.repo });
    const resultBytes = canonicalJson(results);
    await writeFile(args.output, `${resultBytes}\n`, { mode: 0o600, flag: 'wx' });
    process.stdout.write(`${digest(resultBytes)}\n`);
    return;
  }
  if (args.mode !== 'seal' || !['pre_qa', 'final'].includes(args.boundary)) throw new Error('input_invalid');
  const plan = JSON.parse(await readFile(args.plan, 'utf8'));
  const results = JSON.parse(await readFile(args.results, 'utf8'));
  const bytes = sealReceipt({ boundary: args.boundary, storyId: args['story-id'], plan, results,
    resultsDigest: args['results-digest'], outcome: args.outcome,
    expectedBindingDigest: args['binding-digest'], maxBytes: Number(args['max-bytes']) });
  await writeFile(args.output, bytes, { mode: 0o600, flag: 'wx' });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(error => {
  process.stderr.write(`${JSON.stringify({ status: 'rejected', reason: error.reason || error.message || 'executor_error' })}\n`);
  process.exitCode = error.reason === 'receipt_too_large' ? 3 : 2;
});
