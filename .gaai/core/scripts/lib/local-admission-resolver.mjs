#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const VERSION = '1.0.0';
const POLICY_KEYS = ['schema_version', 'policy_version', 'repository', 'limits', 'commands',
  'selectors', 'exhaustive_command_ids', 'non_executable_prefixes', 'broadening_prefixes',
  'broadening_patterns', 'dependency_inputs', 'risk_input_policy', 'required_environment',
  'executable_suffixes', 'executable_names'];
const LIMIT_KEYS = ['max_policy_bytes', 'max_diff_bytes', 'max_changed_paths', 'max_commands',
  'max_selectors', 'max_identifier_bytes', 'max_arguments_per_command', 'max_argument_bytes',
  'max_receipt_bytes', 'max_result_bytes'];
const COMMAND_KEYS = ['id', 'argv', 'timeout_seconds', 'output_limit_bytes', 'config_paths'];
const SELECTOR_KEYS = ['id', 'path_prefixes', 'exact_paths', 'command_ids'];
const ENVIRONMENT_KEYS = ['node_version', 'platform', 'arch', 'path_digest'];
const DERIVED_RISK_KEYS = ['cross_cutting', 'dependency_changed'];

class AdmissionError extends Error {
  constructor(reason, details = {}) { super(reason); this.reason = reason; this.details = details; }
}
const fail = (reason, details) => { throw new AdmissionError(reason, details); };
const digest = value => createHash('sha256').update(value).digest('hex');
const canonical = value => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort()
    .map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
};
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value, keys) => object(value) && Object.keys(value).length === keys.length
  && keys.every(key => Object.hasOwn(value, key));
const positive = value => Number.isSafeInteger(value) && value > 0;
const text = value => typeof value === 'string' && value.length > 0;
const unique = values => new Set(values).size === values.length;
const safePath = value => text(value) && !value.startsWith('/')
  && !value.includes('\\') && !/[\0-\x1f\x7f]/.test(value)
  && value.split('/').every(part => part && part !== '.' && part !== '..');
const boundedId = (value, limit) => text(value) && Buffer.byteLength(value, 'utf8') <= limit;
const hasPrefix = (path, prefix) => path === prefix || path.startsWith(`${prefix}/`);
const safeDetail = value => ({ detail_digest: digest(String(value)) });

function runGit(repo, args, maxBuffer, reason = 'repository_unresolvable') {
  const result = spawnSync('git', ['-C', repo, ...args], {
    encoding: null, maxBuffer, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' }
  });
  if (result.error || result.status !== 0) fail(reason);
  return result.stdout;
}

function validatePolicy(policy, policyBytes, baseRef) {
  // environment_passthrough is the one optional key: the names (or PREFIX_*
  // patterns) of GAAI_ variables the project lets its gate commands inherit.
  // Absent means none. Everything else in the policy stays closed-world.
  const declaresPassthrough = Object.hasOwn(policy, 'environment_passthrough');
  if (!exactKeys(policy, declaresPassthrough ? [...POLICY_KEYS, 'environment_passthrough'] : POLICY_KEYS)
      || policy.schema_version !== VERSION
      || !text(policy.policy_version)
      || !exactKeys(policy.repository, ['project_id', 'remote', 'base_ref'])
      || !text(policy.repository.project_id) || !text(policy.repository.remote)
      || policy.repository.base_ref !== baseRef
      || !exactKeys(policy.limits, LIMIT_KEYS) || !LIMIT_KEYS.every(key => positive(policy.limits[key]))
      || policyBytes > policy.limits.max_policy_bytes || !Array.isArray(policy.commands)
      || !policy.commands.length || policy.commands.length > policy.limits.max_commands
      || !Array.isArray(policy.selectors) || !policy.selectors.length
      || policy.selectors.length > policy.limits.max_selectors
      || !Array.isArray(policy.exhaustive_command_ids) || !policy.exhaustive_command_ids.length
      || !Array.isArray(policy.non_executable_prefixes) || !Array.isArray(policy.broadening_prefixes)
      || !Array.isArray(policy.broadening_patterns)
      || !Array.isArray(policy.dependency_inputs) || !Array.isArray(policy.required_environment)
      || !Array.isArray(policy.executable_suffixes) || !Array.isArray(policy.executable_names)
      || !exactKeys(policy.risk_input_policy, ['keys', 'exhaustive_when_true'])) {
    fail('policy_malformed');
  }
  const { max_identifier_bytes: idLimit, max_arguments_per_command: argvLimit,
    max_argument_bytes: argBytes } = policy.limits;
  if (!boundedId(policy.policy_version, idLimit)
      || !boundedId(policy.repository.project_id, idLimit)) fail('policy_malformed');
  if (declaresPassthrough && (!Array.isArray(policy.environment_passthrough)
      || !unique(policy.environment_passthrough)
      || !policy.environment_passthrough.every(name => boundedId(name, idLimit)
        && /^GAAI_[A-Z0-9]+(?:_[A-Z0-9]+)*(?:_\*)?$/.test(name)))) fail('policy_malformed');
  const commandIds = new Set();
  for (const command of policy.commands) {
    if (!exactKeys(command, COMMAND_KEYS) || !boundedId(command.id, idLimit) || commandIds.has(command.id))
      fail(commandIds.has(command?.id) ? 'policy_ambiguous' : 'policy_malformed');
    if (!Array.isArray(command.argv) || !command.argv.length || command.argv.length > argvLimit
        || !command.argv.every(arg => text(arg) && Buffer.byteLength(arg, 'utf8') <= argBytes)
        || !positive(command.timeout_seconds) || !positive(command.output_limit_bytes)
        || !Array.isArray(command.config_paths) || !command.config_paths.every(safePath)) fail('policy_malformed');
    commandIds.add(command.id);
  }
  if (!unique(policy.exhaustive_command_ids)
      || !policy.exhaustive_command_ids.every(id => commandIds.has(id))) fail('command_unresolved');
  const selectorIds = new Set();
  for (const selector of policy.selectors) {
    if (!exactKeys(selector, SELECTOR_KEYS) || !boundedId(selector.id, idLimit)
        || selectorIds.has(selector.id) || !Array.isArray(selector.path_prefixes)
        || !selector.path_prefixes.every(safePath) || !Array.isArray(selector.exact_paths)
        || !selector.exact_paths.every(safePath)
        || (!selector.path_prefixes.length && !selector.exact_paths.length)
        || !Array.isArray(selector.command_ids) || !selector.command_ids.length
        || !unique(selector.command_ids) || !selector.command_ids.every(id => commandIds.has(id))) {
      fail(selectorIds.has(selector?.id) ? 'policy_ambiguous' : 'policy_malformed');
    }
    selectorIds.add(selector.id);
  }
  const pathGroups = [policy.non_executable_prefixes, policy.broadening_prefixes,
    policy.dependency_inputs, policy.executable_names];
  const patternsValid = policy.broadening_patterns.every(pattern => {
    if (!text(pattern) || pattern.includes('/') || pattern.includes('\\')
        || /[\0-\x1f\x7f?]/.test(pattern) || pattern.split('*').length !== 2) return false;
    const [prefix, suffix] = pattern.split('*');
    return prefix.length > 0 && suffix.length > 0;
  });
  if (!pathGroups.flat().every(safePath) || !pathGroups.every(unique) || !patternsValid
      || !unique(policy.broadening_patterns)
      || !policy.required_environment.every(name => ENVIRONMENT_KEYS.includes(name))
      || !unique(policy.required_environment)
      || !policy.executable_suffixes.every(value => text(value) && value.startsWith('.'))
      || !unique(policy.executable_suffixes)) fail('policy_malformed');
  const allowed = policy.risk_input_policy.keys;
  const broad = policy.risk_input_policy.exhaustive_when_true;
  if (!Array.isArray(allowed) || !Array.isArray(broad) || !unique(allowed) || !unique(broad)
      || !allowed.every(key => boundedId(key, idLimit) && /^[a-z][a-z0-9_]*$/.test(key))
      || !broad.every(key => allowed.includes(key))) fail('policy_malformed');
  return commandIds;
}

function gitBlobDigest(repo, sha, path, max) {
  const entry = runGit(repo, ['ls-tree', '-z', sha, '--', `:(literal)${path}`], max,
    'configuration_unresolved').toString();
  if (!entry) fail('configuration_unresolved', safeDetail(path));
  const match = /^(100644|100755) blob ([0-9a-f]{40})\t(.+)\0$/.exec(entry);
  if (!match || match[3] !== path) fail('configuration_unsafe', safeDetail(path));
  return digest(runGit(repo, ['cat-file', 'blob', match[2]], max, 'configuration_unresolved'));
}

function validateCandidatePathModes(repo, shas, paths, max) {
  for (const path of paths) {
    let present = false;
    for (const sha of shas) {
      const entry = runGit(repo, ['ls-tree', '-z', sha, '--', `:(literal)${path}`], max,
        'diff_unresolvable').toString();
      if (!entry) continue;
      present = true;
      const match = /^(100644|100755) blob ([0-9a-f]{40})\t(.+)\0$/.exec(entry);
      if (!match || match[3] !== path) fail('candidate_path_unsafe', safeDetail(path));
    }
    if (!present) fail('diff_unresolvable');
  }
}

function isExecutablePath(path, policy, repo, baseSha, headSha) {
  const basename = path.split('/').at(-1);
  if (policy.executable_names.includes(basename)
      || policy.executable_suffixes.some(suffix => path.endsWith(suffix))) return true;
  return [baseSha, headSha].some(sha => runGit(repo,
    ['ls-tree', sha, '--', `:(literal)${path}`], policy.limits.max_diff_bytes,
    'diff_unresolvable').toString().startsWith('100755 '));
}

function materializeArgv(argv, baseSha, headSha) {
  const values = { '{base_sha}': baseSha, '{head_sha}': headSha };
  return argv.map(arg => Object.hasOwn(values, arg) ? values[arg] : arg);
}

function normalizeDiff(raw, maxPaths) {
  let decoded;
  try { decoded = new TextDecoder('utf-8', { fatal: true }).decode(raw); }
  catch { fail('diff_malformed'); }
  const tokens = decoded.split('\0');
  if (tokens.at(-1) === '') tokens.pop();
  const entries = [];
  for (let index = 0; index < tokens.length;) {
    const status = tokens[index++];
    if (!/^(A|M|D|T|U|X|B|R[0-9]+)$/.test(status)) fail('diff_malformed');
    if (status.startsWith('R')) entries.push({ status, from: tokens[index++], to: tokens[index++] });
    else entries.push({ status, path: tokens[index++] });
    if (Object.values(entries.at(-1)).some(value => value === undefined)) fail('diff_malformed');
  }
  if (!entries.length) fail('empty_candidate_diff');
  if (entries.length > maxPaths) fail('diff_too_large');
  const paths = [...new Set(entries.flatMap(entry => entry.path ? [entry.path] : [entry.from, entry.to]))].sort();
  if (!paths.every(safePath)) fail('diff_malformed');
  return { entries, paths };
}

export function resolveLocalAdmission({ repo, baseRef, baseSha, headSha, policyPath, riskInputs,
  environment }) {
  try {
    if (!text(repo) || !text(baseRef) || !/^[0-9a-f]{40}$/.test(baseSha)
        || !/^[0-9a-f]{40}$/.test(headSha) || !safePath(policyPath)
        || (riskInputs !== undefined && !object(riskInputs)))
      fail('input_invalid');
    runGit(repo, ['check-ref-format', `refs/heads/${baseRef}`]);
    const policyEntry = runGit(repo, ['ls-tree', '-z', baseSha, '--', `:(literal)${policyPath}`],
      undefined, 'policy_missing').toString();
    const policyMatch = /^(100644|100755) blob ([0-9a-f]{40})\t(.+)\0$/.exec(policyEntry);
    if (!policyMatch || policyMatch[3] !== policyPath) fail('policy_unsafe');
    const policyRaw = runGit(repo, ['cat-file', 'blob', policyMatch[2]], undefined, 'policy_missing');
    let policy;
    try { policy = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(policyRaw)); }
    catch { fail('policy_malformed'); }
    validatePolicy(policy, policyRaw.length, baseRef);
    if (!boundedId(baseRef, policy.limits.max_identifier_bytes)) fail('policy_malformed');
    const max = policy.limits.max_diff_bytes;
    const actualHead = runGit(repo, ['rev-parse', 'HEAD^{commit}'], max).toString().trim();
    const actualBase = runGit(repo, ['rev-parse', `refs/remotes/origin/${baseRef}^{commit}`], max).toString().trim();
    const remote = runGit(repo, ['remote', 'get-url', 'origin'], max).toString().trim();
    if (actualHead !== headSha || actualBase !== baseSha) fail('candidate_stale');
    if (remote !== policy.repository.remote) fail('repository_mismatch');
    if (runGit(repo, ['status', '--porcelain=v1', '--untracked-files=all', '--', '.',
      ':(exclude,top).delivery-logs/**'], max).length) fail('candidate_unsealed');
    const rawDiff = runGit(repo, ['diff', '--name-status', '-M', '-z', baseSha, headSha], max, 'diff_unresolvable');
    if (rawDiff.length > max) fail('diff_too_large');
    const { entries, paths } = normalizeDiff(rawDiff, policy.limits.max_changed_paths);
    validateCandidatePathModes(repo, [baseSha, headSha], paths, max);
    const selected = new Set();
    const surfaces = new Set();
    let broadening = false;
    let dependencyChanged = false;
    for (const path of paths) {
      let matched = false;
      if (policy.non_executable_prefixes.some(prefix => hasPrefix(path, prefix))) matched = true;
      if (policy.broadening_prefixes.some(prefix => hasPrefix(path, prefix))) {
        matched = true; broadening = true; surfaces.add('exhaustive');
      }
      if (policy.broadening_patterns.some(pattern => {
        const [prefix, suffix] = pattern.split('*');
        return !path.includes('/') && path.startsWith(prefix) && path.endsWith(suffix);
      })) {
        matched = true; broadening = true; surfaces.add('exhaustive');
      }
      if (policy.dependency_inputs.includes(path)) {
        matched = true; broadening = true; dependencyChanged = true; surfaces.add('dependency');
      }
      for (const selector of policy.selectors) if (selector.exact_paths.includes(path)
          || selector.path_prefixes.some(prefix => hasPrefix(path, prefix))) {
        matched = true;
        surfaces.add(selector.id);
        selector.command_ids.forEach(id => selected.add(id));
      }
      if (!matched) {
        if (hasPrefix(path, 'packages') || hasPrefix(path, 'workers')) {
          fail('unknown_surface', safeDetail(path));
        }
        if (isExecutablePath(path, policy, repo, baseSha, headSha)) {
          fail('unknown_executable_surface', safeDetail(path));
        }
        surfaces.add('governance-default');
        selected.add('governance');
      }
    }
    const riskKeys = policy.risk_input_policy.keys;
    const derivedRisk = Object.fromEntries(riskKeys.map(key => [key, false]));
    if (Object.hasOwn(derivedRisk, 'cross_cutting')) derivedRisk.cross_cutting = broadening;
    if (Object.hasOwn(derivedRisk, 'dependency_changed')) derivedRisk.dependency_changed = dependencyChanged;
    if (riskInputs === undefined && riskKeys.some(key => !DERIVED_RISK_KEYS.includes(key))) {
      fail('risk_input_unresolved');
    }
    if (riskInputs !== undefined) {
      const providedKeys = Object.keys(riskInputs);
      if (providedKeys.length !== riskKeys.length || !providedKeys.every(key => riskKeys.includes(key))
          || !riskKeys.every(key => typeof riskInputs[key] === 'boolean')) fail('risk_input_unresolved');
      for (const key of riskKeys) derivedRisk[key] = derivedRisk[key] || riskInputs[key];
    }
    if (policy.risk_input_policy.exhaustive_when_true.some(key => derivedRisk[key])) broadening = true;
    if (broadening) policy.exhaustive_command_ids.forEach(id => selected.add(id));
    if (!selected.size) fail('empty_executable_selection');
    const dependencies = policy.dependency_inputs.map(path =>
      [digest(path), gitBlobDigest(repo, headSha, path, max)]);
    const runtimeEnvironment = environment || {
      node_version: process.versions.node,
      platform: process.platform,
      arch: process.arch,
      path_digest: digest(process.env.PATH ?? '')
    };
    const missingFacts = policy.required_environment.filter(name => !Object.hasOwn(runtimeEnvironment, name));
    if (missingFacts.length) fail('environment_fact_missing', { fact_digests: missingFacts.map(digest) });
    // The declared pass-through, resolved against this process: the exact names
    // the executor will let through, each with a digest of its value. They join
    // the environment facts, so the receipt binds what the commands actually
    // saw — a changed value is a changed binding — and a policy that declares
    // nothing binds exactly what it always did.
    const passthroughRules = policy.environment_passthrough || [];
    // A rule is an exact name or an underscore-delimited PREFIX_*. Only names the
    // executor will accept (uppercase, digits, underscores) can match — anything
    // else in the namespace is simply not part of the gate.
    const passthroughNames = Object.keys(process.env).filter(name => /^GAAI_[A-Z0-9_]+$/.test(name)
      && passthroughRules.some(rule => rule.endsWith('*') ? name.startsWith(rule.slice(0, -1)) : name === rule)).sort();
    const facts = [...policy.required_environment.map(name => [name, runtimeEnvironment[name]]),
      ...passthroughNames.map(name => [name, digest(process.env[name])])];
    const commands = policy.commands.filter(command => selected.has(command.id)).map(command => ({
      id: command.id, argv: materializeArgv(command.argv, baseSha, headSha),
      timeout_seconds: command.timeout_seconds,
      output_limit_bytes: command.output_limit_bytes, descriptor_digest: digest(canonical(command)),
      configuration_digest: digest(canonical(command.config_paths.map(path =>
        [digest(path), gitBlobDigest(repo, headSha, path, max)])))
    }));
    if (!commands.length || commands.length !== selected.size) fail('command_unresolved');
    const binding = { project_id: policy.repository.project_id,
      repository_digest: digest(remote), base_ref: baseRef, base_sha: baseSha,
      head_sha: headSha, normalized_diff_digest: digest(canonical(entries)),
      dependency_digest: digest(canonical(dependencies)), risk_digest: digest(canonical(derivedRisk)),
      policy_version: policy.policy_version, policy_digest: digest(canonical(policy)),
      selector_digest: digest(canonical({ selectors: policy.selectors, exhaustive: policy.exhaustive_command_ids,
        broadening_patterns: policy.broadening_patterns })),
      environment_digest: digest(canonical(facts)),
      command_digests: commands.map(({ id, descriptor_digest, configuration_digest }) =>
        ({ id, descriptor_digest, configuration_digest })) };
    const summary = { schema_version: VERSION, outcome: 'resolved', repository_digest: binding.repository_digest,
      base_ref: baseRef, base_sha: baseSha, head_sha: headSha, binding_digest: digest(canonical(binding)),
      changed_path_count: paths.length, rename_count: entries.filter(item => item.status.startsWith('R')).length,
      selected_surface_ids: [...surfaces].sort(), selected_command_ids: commands.map(item => item.id) };
    return { status: 'resolved', binding, binding_digest: summary.binding_digest,
      selected_commands: commands, environment_passthrough: passthroughNames, limits: { max_receipt_bytes: policy.limits.max_receipt_bytes,
        max_result_bytes: policy.limits.max_result_bytes }, summary };
  } catch (error) {
    const reason = error instanceof AdmissionError ? error.reason : 'resolver_error';
    return { status: 'rejected', reason, summary: { schema_version: VERSION, outcome: reason,
      ...(error instanceof AdmissionError ? error.details : {}) } };
  }
}

function parseArgs(argv) {
  const allowed = ['repo', 'base-ref', 'base-sha', 'head-sha', 'policy', 'risk-inputs', 'output'];
  if (argv.length % 2 !== 0) fail('input_invalid');
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]?.slice(2);
    if (!argv[index]?.startsWith('--') || !allowed.includes(key) || Object.hasOwn(options, key)
        || argv[index + 1] === undefined) fail('input_invalid');
    options[key] = argv[index + 1];
  }
  if (!['repo', 'base-ref', 'base-sha', 'head-sha', 'policy', 'output']
    .every(key => Object.hasOwn(options, key))) fail('input_invalid');
  return options;
}

async function main() {
  let args;
  try { args = parseArgs(process.argv.slice(2)); }
  catch { process.stderr.write('{"status":"rejected","reason":"input_invalid"}\n'); process.exitCode = 2; return; }
  let riskInputs;
  if (args['risk-inputs']) {
    try { riskInputs = JSON.parse(await readFile(args['risk-inputs'], 'utf8')); }
    catch { riskInputs = {}; }
  }
  const result = resolveLocalAdmission({ repo: args.repo, baseRef: args['base-ref'],
    baseSha: args['base-sha'], headSha: args['head-sha'], policyPath: args.policy, riskInputs });
  if (!args.output) { process.stderr.write('{"status":"rejected","reason":"input_invalid"}\n'); process.exitCode = 2; return; }
  await writeFile(args.output, `${JSON.stringify(result)}\n`, { mode: 0o600, flag: 'wx' });
  process.stdout.write(`${JSON.stringify(result.summary)}\n`);
  if (result.status !== 'resolved') process.exitCode = 3;
}

function isDirectInvocation(entrypoint) {
  if (!entrypoint) return false;
  try {
    return realpathSync(entrypoint) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isDirectInvocation(process.argv[1])) main().catch(() => {
  process.stderr.write('{"status":"rejected","reason":"resolver_error"}\n'); process.exitCode = 2;
});
