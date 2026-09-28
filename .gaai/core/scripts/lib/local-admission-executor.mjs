#!/usr/bin/env node
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const VERSION = '1.0.0';
const RESULT_KEYS = ['command_id', 'descriptor_digest', 'configuration_digest', 'outcome',
  'exit_code', 'signal', 'duration_ms', 'stdout_bytes', 'stderr_bytes',
  'stdout_truncated', 'stderr_truncated'];
const EXECUTION_KEYS = ['invocation_id', 'story_id', 'boundary', 'binding_digest',
  'materialized_argv_digest', 'execution_id'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
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

// Each command runs in a process group of its own, so nothing that ends this
// executor reaches it. A delivery wrapper killed mid-gate takes its terminal
// down with it; the hangup ends the executor, and the command group — a whole
// corpus run with its lease heartbeat — is reparented to init and keeps
// running, holding the lease the next gate waits on. The executor therefore
// owns the lifetime of the groups it starts: they are tracked while they run
// and ended when the executor is told to stop or finds its caller gone.
const running = new Set();

export function abandonOnCallerLoss({ intervalMs = 1000, exit = code => process.exit(code) } = {}) {
  const caller = process.ppid;
  const signals = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 };
  const abandon = code => {
    for (const child of running) terminate(child);
    running.clear();
    exit(code);
  };
  const handlers = Object.entries(signals).map(([name, code]) => {
    const handler = () => abandon(code);
    process.on(name, handler);
    return [name, handler];
  });
  // The caller can also vanish without a hangup reaching this process; its
  // children are then reparented, which changes the parent pid.
  const timer = setInterval(() => { if (process.ppid !== caller) abandon(129); }, intervalMs);
  timer.unref();
  return () => {
    clearInterval(timer);
    for (const [name, handler] of handlers) process.removeListener(name, handler);
  };
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
    running.add(child);
    const finish = (code, childSignal) => {
      if (settled) return;
      settled = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel); terminate(child);
      running.delete(child);
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

export function executionIdentity(plan, command, executionId) {
  return { invocation_id: plan.invocation.id, story_id: plan.invocation.story_id,
    boundary: plan.invocation.boundary, binding_digest: plan.binding_digest,
    materialized_argv_digest: digest(canonicalJson(command.argv)), execution_id: executionId };
}

export async function executePlan(plan, options = {}) {
  const declared = Array.isArray(plan.environment_passthrough) ? plan.environment_passthrough : [];
  if (!declared.every(name => typeof name === 'string' && /^GAAI_[A-Z0-9_]+$/.test(name))) throw new Error('plan_invalid');
  const results = [];
  for (const command of plan.selected_commands) {
    if (options.commandIds && !options.commandIds.includes(command.id)) continue;
    const result = await executeCommand(command, { ...options, keep: declared });
    if (plan.invocation) result.execution = executionIdentity(plan, command, randomUUID());
    results.push(result);
  }
  return results;
}

export function validateEvidence(plan, results, resultsDigest, commandIds) {
  if (!Array.isArray(results) || digest(canonicalJson(results)) !== resultsDigest) throw new Error('evidence_invalid');
  if (plan.status !== 'resolved') {
    if (results.length) throw new Error('evidence_invalid');
    return false;
  }
  if (!plan.binding || digest(canonicalJson(plan.binding)) !== plan.binding_digest
      || !Array.isArray(plan.selected_commands) || !plan.selected_commands.length
      || plan.selected_commands.length !== plan.binding.command_digests?.length
      || results.length !== (commandIds ? commandIds.length : plan.selected_commands.length))
    throw new Error('evidence_invalid');
  const commands = commandIds ? plan.selected_commands.filter(command => commandIds.includes(command.id)) : plan.selected_commands;
  if (commands.length !== results.length) throw new Error('evidence_invalid');
  if (plan.invocation && (!UUID.test(plan.invocation.id)
      || new Set(results.map(result => result?.execution?.execution_id)).size !== results.length))
    throw new Error('evidence_invalid');
  for (let index = 0; index < results.length; index++) {
    const result = results[index]; const command = commands[index];
    const bound = plan.binding.command_digests[plan.selected_commands.indexOf(command)];
    const keys = plan.invocation ? [...RESULT_KEYS, 'execution'] : RESULT_KEYS;
    if (!result || Object.keys(result).length !== keys.length
        || !keys.every(key => Object.hasOwn(result, key))
        || result.command_id !== command.id || result.descriptor_digest !== command.descriptor_digest
        || result.configuration_digest !== command.configuration_digest
        || bound.id !== command.id || bound.descriptor_digest !== command.descriptor_digest
        || bound.configuration_digest !== command.configuration_digest
        || !['passed', 'failed', 'timed_out', 'cancelled'].includes(result.outcome)
        || !(result.exit_code === null || Number.isSafeInteger(result.exit_code) && result.exit_code >= 0)
        || !(result.signal === null || typeof result.signal === 'string' && /^SIG[A-Z0-9]+$/.test(result.signal))
        || (result.outcome === 'passed' && (result.exit_code !== 0 || result.signal !== null))
        || !Number.isSafeInteger(result.duration_ms) || result.duration_ms < 0
        || !['stdout', 'stderr'].every(name => Number.isSafeInteger(result[`${name}_bytes`])
          && result[`${name}_bytes`] >= 0 && result[`${name}_bytes`] <= command.output_limit_bytes
          && typeof result[`${name}_truncated`] === 'boolean')) throw new Error('evidence_invalid');
    if (plan.invocation && (!result.execution
        || Object.keys(result.execution).length !== EXECUTION_KEYS.length
        || !UUID.test(result.execution.execution_id)
        || canonicalJson(result.execution) !== canonicalJson(executionIdentity(plan, command, result.execution.execution_id))))
      throw new Error('evidence_invalid');
  }
  return results.every(result => result.outcome === 'passed');
}

export function sealReceipt({ boundary, storyId, plan, results, resultsDigest, outcome,
  expectedBindingDigest, createdAt = new Date().toISOString(), maxBytes }) {
  if (plan.invocation && (plan.invocation.boundary !== boundary || plan.invocation.story_id !== storyId))
    throw new Error('evidence_invalid');
  const allPassed = validateEvidence(plan, results, resultsDigest);
  if (outcome === 'pass' && !allPassed) throw new Error('evidence_invalid');
  if (outcome === 'pass' && plan.limits?.max_result_bytes
      && Buffer.byteLength(canonicalJson(results)) > plan.limits.max_result_bytes)
    throw new Error('results_too_large');
  if (plan.status === 'resolved' && plan.binding_digest !== expectedBindingDigest) throw new Error('evidence_stale');
  const publicationAdmitted = boundary === 'final' && outcome === 'pass' && allPassed;
  const receipt = { schema_version: VERSION, boundary, story_id: storyId,
    candidate: plan.binding || null, binding_digest: plan.binding_digest || null,
    selected_surface_ids: plan.summary?.selected_surface_ids || [],
    selected_command_ids: plan.summary?.selected_command_ids || [],
    // Legacy wire projection only; validated internal results remain untouched.
    results: results.map(({ execution, ...facts }) => facts), outcome,
    publication_admitted: publicationAdmitted, created_at: createdAt };
  receipt.receipt_digest = digest(canonicalJson(receipt));
  const bytes = `${canonicalJson(receipt)}\n`;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1 || Buffer.byteLength(bytes) > maxBytes) {
    const error = new Error('receipt_too_large'); error.reason = 'receipt_too_large'; throw error;
  }
  return bytes;
}

// Re-derive applicability at the sealing boundary. Neither an eligible flag nor
// a supplied composite vector is authority; every result keeps its actual plan.
export async function sealCompositeReceipt({ repo, originalPlan, plan, originalResults,
  freshResults, proof, boundary, storyId, maxBytes, outcome }) {
  const { proveApplicability } = await import('./local-admission-applicability.mjs');
  const verified = proveApplicability({ repo, originalPlan, plan, results: originalResults });
  if (verified.status !== 'eligible' || canonicalJson(verified) !== canonicalJson(proof)
      || plan.invocation.boundary !== boundary || plan.invocation.story_id !== storyId)
    throw new Error('applicability_invalid');
  const passed = validateEvidence(plan, freshResults, digest(canonicalJson(freshResults)), proof.fresh_command_ids);
  if (outcome === 'pass' && Buffer.byteLength(canonicalJson(freshResults)) > plan.limits.max_result_bytes)
    throw new Error('results_too_large');
  if (freshResults.some(result => originalResults.some(original => original.execution.execution_id === result.execution.execution_id)))
    throw new Error('evidence_invalid');
  if (outcome === 'pass' && !passed) throw new Error('evidence_invalid');
  const results = plan.selected_commands.map(command => {
    const evidence = proof.reusable_command_ids.includes(command.id) ? originalResults : freshResults;
    return evidence.find(result => result.command_id === command.id);
  });
  // Validate the current vector without changing or misattributing execution
  // identities; provenance has already been validated against its source plan.
  const current = results.map(result => {
    const { execution, ...facts } = result;
    return facts;
  });
  const { invocation, ...withoutInvocation } = plan;
  const receipt = JSON.parse(sealReceipt({ boundary, storyId, plan: withoutInvocation,
    results: current, resultsDigest: digest(canonicalJson(current)), outcome,
    expectedBindingDigest: plan.binding_digest, maxBytes }));
  delete receipt.receipt_digest;
  receipt.schema_version = '2.0.0';
  receipt.invocation_id = invocation.id;
  receipt.resolution_inputs = plan.resolution_inputs;
  receipt.results = results;
  receipt.original_execution = { binding: originalPlan.binding,
    binding_digest: originalPlan.binding_digest, results: originalResults,
    results_digest: digest(canonicalJson(originalResults)) };
  receipt.refreshed_execution = { binding: plan.binding, binding_digest: plan.binding_digest,
    results: freshResults, results_digest: digest(canonicalJson(freshResults)) };
  receipt.applicability = proof;
  receipt.provenance = results.map(result => ({ command_id: result.command_id,
    ...result.execution }));
  receipt.receipt_digest = digest(canonicalJson(receipt));
  const bytes = `${canonicalJson(receipt)}\n`;
  if (Buffer.byteLength(bytes) > maxBytes) throw new Error('receipt_too_large');
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
  if (args.mode === 'retain') {
    const plan = JSON.parse(await readFile(args.plan, 'utf8'));
    const results = JSON.parse(await readFile(args.results, 'utf8'));
    validateEvidence(plan, results, digest(canonicalJson(results)));
    const diagnostic = { schema_version: VERSION, outcome: args.outcome || 'blocked:stale_evidence',
      publication_admitted: false, current: false, invocation: plan.invocation,
      stage: args.stage, reason: args.reason,
      observation: { base_sha: args['observed-base'] || null, head_sha: args['observed-head'] || null,
        binding_digest: args['observed-binding'] || null },
      original_execution: { binding: plan.binding, binding_digest: plan.binding_digest,
        results, results_digest: digest(canonicalJson(results)) } };
    if (args.proof) diagnostic.applicability = JSON.parse(await readFile(args.proof, 'utf8'));
    if (args['fresh-results']) diagnostic.fresh_results = JSON.parse(await readFile(args['fresh-results'], 'utf8'));
    diagnostic.evidence_digest = digest(canonicalJson(diagnostic));
    const bytes = `${canonicalJson(diagnostic)}\n`;
    if (Buffer.byteLength(bytes) > Number(args['max-bytes'])) throw new Error('receipt_too_large');
    await writeFile(args.output, bytes, { mode: 0o600, flag: 'wx' });
    return;
  }
  if (args.mode === 'execute') {
    const plan = JSON.parse(await readFile(args.plan, 'utf8'));
    if (plan.status !== 'resolved' || !Array.isArray(plan.selected_commands)) throw new Error('plan_invalid');
    const proof = args.proof ? JSON.parse(await readFile(args.proof, 'utf8')) : null;
    const results = await executePlan(plan, { cwd: args.repo,
      ...(proof ? { commandIds: proof.fresh_command_ids } : {}) });
    const resultBytes = canonicalJson(results);
    await writeFile(args.output, `${resultBytes}\n`, { mode: 0o600, flag: 'wx' });
    process.stdout.write(`${digest(resultBytes)}\n`);
    return;
  }
  if (args.mode === 'compose') {
    const read = async name => JSON.parse(await readFile(args[name], 'utf8'));
    const bytes = await sealCompositeReceipt({ repo: args.repo,
      originalPlan: await read('original-plan'), plan: await read('plan'),
      originalResults: await read('original-results'), freshResults: await read('results'),
      proof: await read('proof'), boundary: args.boundary, storyId: args['story-id'],
      maxBytes: Number(args['max-bytes']), outcome: args.outcome });
    await writeFile(args.output, bytes, { mode: 0o600, flag: 'wx' });
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

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  abandonOnCallerLoss();
  main().catch(error => {
    const claimed = error.reason || error.message;
    const reason = ['input_invalid', 'plan_invalid', 'evidence_invalid', 'evidence_stale',
      'applicability_invalid', 'results_too_large', 'receipt_too_large'].includes(claimed) ? claimed : 'executor_error';
    process.stderr.write(`${JSON.stringify({ status: 'rejected', reason })}\n`);
    process.exitCode = reason === 'receipt_too_large' ? 3 : 2;
  });
}
