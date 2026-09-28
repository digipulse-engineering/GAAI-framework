#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { realpathSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolveLocalAdmission, reconstructAdmissionInputs } from './local-admission-resolver.mjs';
import { canonicalJson, validateEvidence } from './local-admission-executor.mjs';

export const APPLICABILITY_PATH = '.gaai/project/ci/local-admission-applicability.json';
export const IMPLEMENTATION_PATHS = ['local-admission.sh', 'local-admission-resolver.mjs',
  'local-admission-executor.mjs', 'local-admission-applicability.mjs']
  .map(name => `.gaai/core/scripts/lib/${name}`);
export const VERIFIER_CLOSURE = [...IMPLEMENTATION_PATHS,
  '.gaai/core/scripts/delivery-daemon.sh', '.gaai/core/scripts/backlog-scheduler.sh',
  '.gaai/core/scripts/lib/test-gate.sh', '.gaai/core/scripts/lib/yaml-runtime.sh',
  ...['pyyaml-runtime.pyz', 'PROVENANCE.json', 'LICENSE'].map(name => `.gaai/core/vendor/pyyaml/6.0.3/${name}`)];
const hash = value => createHash('sha256').update(value).digest('hex');
const equal = (left, right) => canonicalJson(left) === canonicalJson(right);
const fail = reason => { throw new Error(reason); };
const exact = (value, keys) => value && !Array.isArray(value) && typeof value === 'object'
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const safePath = value => typeof value === 'string' && value.length > 0
  && !/^[/:]/.test(value) && !/[\\\x00-\x1f\x7f*?\[\]]/.test(value)
  && value.split('/').every(part => part && part !== '.' && part !== '..');
const uniqueList = (value, check) => Array.isArray(value) && value.length > 0
  && new Set(value).size === value.length && value.every(check);
const identifier = value => typeof value === 'string' && /^[A-Za-z0-9._-]+$/.test(value);

// The verified runtime supplies yaml. Programs and argv are distinct: no source
// text derived from repository contents is ever interpolated into a shell.
const PARSER = String.raw`
import json, sys
def reject(reason):
    print(json.dumps({"status":"rejected", "reason":reason}))
    sys.exit(0)
def pairs(items):
    result = {}
    for key, value in items:
        if key in result: raise ValueError("duplicate")
        result[key] = value
    return result
try:
    request = json.load(sys.stdin)
    if request["action"] == "json":
        docs = [json.loads(raw, object_pairs_hook=pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError("constant"))) for raw in request["documents"]]
        print(json.dumps({"status":"parsed", "documents":docs}, allow_nan=False))
        sys.exit(0)
    from yaml.nodes import MappingNode, SequenceNode, ScalarNode
    from yaml.tokens import AnchorToken, AliasToken, TagToken, DirectiveToken
    policy = request["policy"]
    def parse(raw):
        if any(isinstance(token, (AnchorToken, AliasToken, TagToken, DirectiveToken)) for token in yaml.scan(raw)):
            reject("yaml_ambiguous")
        loader = yaml.SafeLoader(raw)
        try:
            root = loader.get_single_node()
            def inspect(node):
                if isinstance(node, MappingNode):
                    keys = set()
                    for key, value in node.value:
                        if not isinstance(key, ScalarNode) or key.tag != "tag:yaml.org,2002:str" or key.value == "<<":
                            reject("yaml_ambiguous")
                        resolved = loader.construct_object(key)
                        if resolved in keys: reject("yaml_ambiguous")
                        keys.add(resolved)
                        inspect(value)
                elif isinstance(node, SequenceNode):
                    for value in node.value: inspect(value)
                elif not isinstance(node, ScalarNode) or node.tag not in {
                    "tag:yaml.org,2002:str", "tag:yaml.org,2002:bool", "tag:yaml.org,2002:int",
                    "tag:yaml.org,2002:float", "tag:yaml.org,2002:null", "tag:yaml.org,2002:timestamp"}:
                    reject("yaml_ambiguous")
                else:
                    loader.construct_object(node) # validate typed scalar syntax too
            inspect(root)
            return root
        finally:
            loader.dispose()
    before, after = request["before"], request["after"]
    roots = [parse(before), parse(after)]
    def mapping(node):
        if not isinstance(node, MappingNode): reject("backlog_shape_changed")
        return {key.value:value for key,value in node.value}
    rows = []
    for root in roots:
        collection = mapping(root).get(policy["rows_key"])
        if not isinstance(collection, SequenceNode): reject("backlog_shape_changed")
        identities = []
        for row in collection.value:
            ident = mapping(row).get(policy["identity_key"])
            if not isinstance(ident, ScalarNode) or ident.tag != "tag:yaml.org,2002:str" or not ident.value:
                reject("backlog_shape_changed")
            identities.append(ident.value)
        if len(set(identities)) != len(identities): reject("yaml_ambiguous")
        if request["story_id"] not in identities: reject("story_missing")
        rows.append((collection, identities))
    if rows[0][1] != rows[1][1]: reject("backlog_shape_changed")
    spans = [[], []]
    replacements = []
    def compare(left, right, path=()):
        if type(left) is not type(right): reject("backlog_shape_changed")
        allowed = len(path) == 3 and path[0] == policy["rows_key"] and isinstance(path[1], int) \
            and rows[0][1][path[1]] != request["story_id"] and path[2] in policy["lifecycle_fields"]
        if allowed:
            if not isinstance(left, ScalarNode): reject("backlog_shape_changed")
            spans[0].append((left.start_mark.index, left.end_mark.index))
            spans[1].append((right.start_mark.index, right.end_mark.index))
            old_raw = before[left.start_mark.index:left.end_mark.index]
            new_raw = after[right.start_mark.index:right.end_mark.index]
            if old_raw != new_raw:
                replacements.append((rows[0][1][path[1]], path[2], left, old_raw, new_raw))
            return
        if left.tag != right.tag: reject("non_lifecycle_change")
        if isinstance(left, MappingNode):
            if [key.value for key,_ in left.value] != [key.value for key,_ in right.value]:
                reject("backlog_shape_changed")
            for (key, value), (_, other) in zip(left.value, right.value):
                compare(value, other, path + (key.value,))
        elif isinstance(left, SequenceNode):
            if len(left.value) != len(right.value): reject("backlog_shape_changed")
            for index, (value, other) in enumerate(zip(left.value, right.value)):
                compare(value, other, path + (index,))
        elif left.value != right.value: reject("non_lifecycle_change")
    compare(*roots)
    def outside(raw, ranges):
        cursor, pieces = 0, []
        for start, end in sorted(ranges):
            if start < cursor or end < start: reject("yaml_ambiguous")
            pieces.append(raw[cursor:start])
            cursor = end
        pieces.append(raw[cursor:])
        return pieces
    if outside(before, spans[0]) != outside(after, spans[1]): reject("non_scalar_bytes_changed")
    result = {"status":"proven", "row_count":len(rows[0][1]), "scalar_count":len(spans[0])}
    if "head" in request:
        # Marks and slices both count Unicode code points. Replace in Python,
        # then encode; never mix these offsets with UTF-16 or UTF-8 indexes.
        head = request["head"]
        collection = mapping(parse(head)).get(policy["rows_key"])
        if not isinstance(collection, SequenceNode): reject("integration_conflict")
        head_rows = {}
        for row in collection.value:
            fields = mapping(row)
            ident = fields.get(policy["identity_key"])
            if not isinstance(ident, ScalarNode) or ident.tag != "tag:yaml.org,2002:str" or not ident.value:
                reject("integration_conflict")
            if ident.value in head_rows: reject("yaml_ambiguous")
            head_rows[ident.value] = fields
        edits = []
        for ident, field, original, old_raw, new_raw in replacements:
            node = head_rows.get(ident, {}).get(field)
            if not isinstance(node, ScalarNode) or node.tag != original.tag or node.value != original.value:
                reject("integration_conflict")
            start, end = node.start_mark.index, node.end_mark.index
            if head[start:end] != old_raw: reject("integration_conflict")
            edits.append((start, end, new_raw))
        cursor = len(head)
        for start, end, replacement in sorted(edits, reverse=True):
            if end > cursor or start > end: reject("integration_conflict")
            head = head[:start] + replacement + head[end:]
            cursor = start
        import base64
        result["integrated_base64"] = base64.b64encode(head.encode("utf-8")).decode("ascii")
    print(json.dumps(result))
except SystemExit:
    raise
except Exception:
    reject("parse_invalid")
`;

function parseTrusted(request, maxBytes) {
  const runtime = realpathSync(fileURLToPath(new URL('./yaml-runtime.sh', import.meta.url)));
  const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-p', '-c',
    'source "$1"; YAML_RUNTIME_ROLE=admission; yaml_runtime_run_c "$2"',
    'admission-parser', runtime, PARSER], { input: JSON.stringify(request), encoding: 'utf8', maxBuffer: maxBytes });
  if (result.error || result.status !== 0) {
    const reason = { 30: 'yaml_runtime_missing', 31: 'yaml_runtime_interpreter_invalid',
      32: 'yaml_runtime_manifest_invalid', 33: 'yaml_runtime_asset_invalid',
      34: 'yaml_runtime_platform_unsupported', 35: 'yaml_runtime_import_failed',
      36: 'yaml_runtime_semantic_mismatch' }[result.status];
    fail(reason || 'parser_unavailable');
  }
  let parsed;
  try { parsed = JSON.parse(result.stdout); } catch { fail('parser_unavailable'); }
  if (parsed.status === 'rejected') fail(parsed.reason);
  return parsed;
}

function git(repo, args, maxBytes, reason = 'git_unavailable') {
  const result = spawnSync('git', ['-C', repo, ...args], {
    encoding: null, maxBuffer: maxBytes, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' }
  });
  if (result.error || result.status !== 0) fail(reason);
  return result.stdout;
}

function blob(repo, sha, path, maxBytes, missing = 'blob_unavailable') {
  if (!safePath(path)) fail('policy_invalid');
  const entry = git(repo, ['ls-tree', '-z', sha, '--', `:(literal)${path}`], maxBytes).toString();
  if (!entry) fail(missing);
  const match = /^(100644|100755) blob ([0-9a-f]{40})\t([^\0]+)\0$/.exec(entry);
  if (!match || match[3] !== path) fail('blob_unsafe');
  const raw = git(repo, ['cat-file', 'blob', match[2]], maxBytes);
  return { raw, mode: match[1], digest: hash(raw), entry };
}

function consistentBlob(repo, shas, path, maxBytes, missing) {
  const blobs = shas.map(sha => blob(repo, sha, path, maxBytes, missing));
  if (!blobs.every(value => value.entry === blobs[0].entry)) fail('policy_or_trust_changed');
  return blobs[0];
}

function validatePolicy(policy, selector) {
  if (!exact(policy, ['schema_version', 'repository', 'backlog_path', 'rows_key', 'identity_key',
    'lifecycle_fields', 'reusable_command_ids', 'trust_registry_path']) || policy.schema_version !== '1.0.0'
      || !equal(policy.repository, selector.repository) || !safePath(policy.backlog_path)
      || !safePath(policy.trust_registry_path) || !identifier(policy.rows_key) || !identifier(policy.identity_key)
      || !uniqueList(policy.lifecycle_fields, identifier) || policy.lifecycle_fields.includes(policy.identity_key)
      || !uniqueList(policy.reusable_command_ids, identifier)
      || !policy.reusable_command_ids.every(id => selector.commands.some(command => command.id === id)))
    fail('policy_invalid');
}

export function requiredControllerPaths(maxBytes) {
  const library = realpathSync(fileURLToPath(new URL('./test-gate.sh', import.meta.url)));
  const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-p', '-c',
    'source "$1"; _test_gate_required_controller_paths', 'admission-trust', library],
  { encoding: 'utf8', maxBuffer: maxBytes });
  if (result.error || result.status !== 0) fail('trust_registry_invalid');
  const paths = result.stdout.trim().split('\n');
  if (!uniqueList(paths, safePath)) fail('trust_registry_invalid');
  return paths;
}

function validateRegistry(registry, policy, selectorPath, maxBytes) {
  if (!exact(registry, ['schema_version', 'repository', 'workflow', 'required_job', 'covered_paths'])
      || registry.schema_version !== '1.0.0'
      || !exact(registry.repository, ['id', 'full_name', 'base_ref'])
      || !Number.isSafeInteger(registry.repository.id) || registry.repository.id <= 0
      || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(registry.repository.full_name)
      || registry.repository.full_name !== policy.repository.project_id
      || registry.repository.base_ref !== policy.repository.base_ref
      || !exact(registry.workflow, ['id', 'path', 'name', 'event'])
      || !Number.isSafeInteger(registry.workflow.id) || registry.workflow.id <= 0
      || !safePath(registry.workflow.path) || typeof registry.workflow.name !== 'string' || !registry.workflow.name
      || registry.workflow.event !== 'pull_request' || typeof registry.required_job !== 'string' || !registry.required_job
      || !uniqueList(registry.covered_paths, safePath)
      || ![...requiredControllerPaths(maxBytes), ...IMPLEMENTATION_PATHS, APPLICABILITY_PATH, selectorPath,
        policy.trust_registry_path, registry.workflow.path].every(path => registry.covered_paths.includes(path)))
    fail('trust_registry_invalid');
}

function rootTree(repo, sha, maxBytes) {
  const oid = git(repo, ['rev-parse', `${sha}^{tree}`], maxBytes).toString().trim();
  if (!/^[0-9a-f]{40}$/.test(oid)) fail('tree_invalid');
  return oid;
}

export function deriveIntegratedTree(repo, head, backlogPath, integrated, maxBytes) {
  if (!/^[0-9a-f]{40}$/.test(head) || !safePath(backlogPath) || !Buffer.isBuffer(integrated)
      || !Number.isSafeInteger(maxBytes) || maxBytes < 1 || integrated.length > maxBytes) fail('input_invalid');
  const objectId = (type, bytes) => createHash('sha1').update(`${type} ${bytes.length}\0`).update(bytes).digest();
  const parts = backlogPath.split('/').map(part => Buffer.from(part));
  // Rewrite only ancestor tree object IDs in memory. Every other byte remains
  // unchanged, including empty trees, gitlinks and non-UTF-8 Git names. A flat
  // recursive leaf listing cannot prove equality of the complete root tree.
  const replace = (oid, depth) => {
    const raw = git(repo, ['cat-file', 'tree', oid], maxBytes);
    let replacementOffset; let replacement;
    for (let offset = 0; offset < raw.length;) {
      const space = raw.indexOf(32, offset); const nul = raw.indexOf(0, space + 1);
      if (space < offset || nul <= space + 1 || nul + 21 > raw.length) fail('tree_invalid');
      const mode = raw.subarray(offset, space).toString('ascii');
      if (!/^(40000|100644|100755|120000|160000)$/.test(mode)) fail('tree_invalid');
      if (raw.subarray(space + 1, nul).equals(parts[depth])) {
        if (replacementOffset !== undefined) fail('tree_invalid');
        replacementOffset = nul + 1;
        if (depth === parts.length - 1) {
          if (!['100644', '100755'].includes(mode)) fail('blob_unsafe');
          replacement = objectId('blob', integrated);
        } else {
          if (mode !== '40000') fail('tree_invalid');
          replacement = replace(raw.subarray(nul + 1, nul + 21).toString('hex'), depth + 1);
        }
      }
      offset = nul + 21;
    }
    if (replacementOffset === undefined) fail('integration_conflict');
    const rewritten = Buffer.from(raw);
    replacement.copy(rewritten, replacementOffset);
    return objectId('tree', rewritten);
  };
  return replace(rootTree(repo, head, maxBytes), 0).toString('hex');
}

function integrationDigest(repo, head, backlogPath, integrated, maxBytes) {
  return hash(deriveIntegratedTree(repo, head, backlogPath, integrated, maxBytes));
}

const COMPOSITE_KEYS = ['schema_version', 'boundary', 'story_id', 'candidate', 'binding_digest',
  'selected_surface_ids', 'selected_command_ids', 'results', 'outcome', 'publication_admitted',
  'created_at', 'receipt_digest', 'invocation_id', 'resolution_inputs', 'original_execution',
  'refreshed_execution', 'applicability', 'provenance'];
const ENVELOPE_KEYS = ['binding', 'binding_digest', 'results', 'results_digest'];

// Receives the descriptor-bound bytes, never a receipt path. This is an
// immutable evidence check, not execution reuse or an admission entrypoint.
export function verifyCompositeReceipt({ repo, raw, repository, baseRef, maxBytes, mergeSha }) {
  try {
    if ((!Buffer.isBuffer(raw) && typeof raw !== 'string')
        || !Number.isSafeInteger(maxBytes) || maxBytes < 1 || Buffer.byteLength(raw) > maxBytes)
      fail('receipt_invalid');
    const rawText = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(Buffer.from(raw));
    const [receipt] = parseTrusted({ action: 'json', documents: [rawText] }, maxBytes).documents;
    if (!exact(receipt, COMPOSITE_KEYS) || receipt.schema_version !== '2.0.0'
        || receipt.boundary !== 'final' || receipt.outcome !== 'pass' || receipt.publication_admitted !== true
        || !identifier(receipt.story_id) || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(receipt.invocation_id)
        || !exact(receipt.resolution_inputs, ['policy_path', 'risk_inputs'])
        || !safePath(receipt.resolution_inputs.policy_path)
        || !exact(receipt.original_execution, ENVELOPE_KEYS)
        || !exact(receipt.refreshed_execution, ENVELOPE_KEYS)) fail('receipt_invalid');
    const { receipt_digest: claimed, ...unsigned } = receipt;
    if (hash(canonicalJson(unsigned)) !== claimed || rawText !== `${canonicalJson(receipt)}\n`)
      fail('receipt_invalid');
    const current = receipt.candidate; const original = receipt.original_execution;
    if (!current || !original.binding || current.base_ref !== baseRef
        || current.project_id !== repository.project_id || current.repository_digest !== hash(repository.remote)
        || !equal(receipt.refreshed_execution.binding, current)
        || receipt.refreshed_execution.binding_digest !== receipt.binding_digest) fail('receipt_invalid');
    const shas = [original.binding.base_sha, current.base_sha, current.head_sha];
    if (!shas.every(sha => typeof sha === 'string' && /^[0-9a-f]{40}$/.test(sha))) fail('receipt_invalid');
    const policyBlob = consistentBlob(repo, shas, receipt.resolution_inputs.policy_path, maxBytes);
    const [selector] = parseTrusted({ action: 'json', documents: [policyBlob.raw.toString('utf8')] }, maxBytes).documents;
    if (!equal(selector.repository, repository) || Buffer.byteLength(raw) > selector.limits.max_receipt_bytes
        || policyBlob.raw.length > selector.limits.max_policy_bytes) fail('receipt_invalid');
    const invocation = { id: receipt.invocation_id, story_id: receipt.story_id, boundary: receipt.boundary };
    const reconstruct = binding => reconstructAdmissionInputs({ repo, baseRef,
      baseSha: binding.base_sha, headSha: binding.head_sha, policyPath: receipt.resolution_inputs.policy_path,
      riskInputs: receipt.resolution_inputs.risk_inputs ?? undefined, invocation, policy: selector,
      environmentDigest: binding.environment_digest });
    const originalPlan = reconstruct(original.binding); const plan = reconstruct(current);
    if (!equal(originalPlan.binding, original.binding) || !equal(plan.binding, current)
        || originalPlan.binding_digest !== original.binding_digest || plan.binding_digest !== receipt.binding_digest
        || !equal(plan.summary.selected_command_ids, receipt.selected_command_ids)
        || !equal(plan.summary.selected_surface_ids, receipt.selected_surface_ids)
        || hash(canonicalJson(original.results)) !== original.results_digest) fail('receipt_invalid');
    const proof = proveImmutableApplicability({ repo, originalPlan, plan, results: original.results });
    if (proof.status !== 'eligible' || !equal(proof, receipt.applicability)) fail('applicability_invalid');
    const fresh = receipt.refreshed_execution;
    if (!validateEvidence(plan, fresh.results, fresh.results_digest, proof.fresh_command_ids)
        || Buffer.byteLength(canonicalJson(fresh.results)) > plan.limits.max_result_bytes
        || fresh.results.some(result => original.results.some(old => old.execution.execution_id === result.execution.execution_id)))
      fail('evidence_invalid');
    const expected = plan.selected_commands.map(command =>
      (proof.reusable_command_ids.includes(command.id) ? original.results : fresh.results)
        .find(result => result.command_id === command.id));
    if (!equal(expected, receipt.results) || !equal(receipt.provenance,
      expected.map(result => ({ command_id: result.command_id, ...result.execution })))) fail('evidence_invalid');
    if (mergeSha !== undefined) {
      if (!/^[0-9a-f]{40}$/.test(mergeSha)
          || git(repo, ['show', '-s', '--format=%P', mergeSha], plan.limits.max_diff_bytes).toString().trim() !== current.base_sha
          || hash(rootTree(repo, mergeSha, plan.limits.max_diff_bytes)) !== proof.integration_digest)
        fail('integration_mismatch');
    }
    return { status: 'verified', receipt_digest: claimed, integration_digest: proof.integration_digest };
  } catch { return { status: 'rejected', reason: 'composite_invalid' }; }
}

export function proveApplicability(input) {
  try {
    const { repo, plan } = input;
    if (plan.status !== 'resolved') fail('current_plan_invalid');
    const current = plan.binding;
    const live = resolveLocalAdmission({ repo, baseRef: current.base_ref, baseSha: current.base_sha,
      headSha: current.head_sha, policyPath: plan.resolution_inputs.policy_path,
      riskInputs: plan.resolution_inputs.risk_inputs ?? undefined, invocation: plan.invocation });
    if (!equal(live, plan)) fail('current_plan_invalid');
    return proveImmutableApplicability(input, true);
  } catch { return { schema_version: '1.0.0', status: 'rejected', reason: 'current_plan_invalid' }; }
}

function proveImmutableApplicability({ repo, originalPlan, plan, results }, checkExecutingClosure = false) {
  try {
    const context = originalPlan.invocation;
    if (!exact(context, ['id', 'story_id', 'boundary']) || !/^[0-9a-f-]{36}$/.test(context.id)
        || !identifier(context.story_id) || !['pre_qa', 'final'].includes(context.boundary)
        || !equal(context, plan.invocation)) fail('invocation_mismatch');
    if (originalPlan.status !== 'resolved' || plan.status !== 'resolved'
        || !validateEvidence(originalPlan, results, hash(canonicalJson(results)))) fail('execution_not_passed');
    if (Buffer.byteLength(canonicalJson(results)) > originalPlan.limits.max_result_bytes) fail('results_too_large');
    const old = originalPlan.binding; const current = plan.binding;
    if (hash(canonicalJson(current)) !== plan.binding_digest) fail('plan_invalid');
    const { base_sha: oldBase, normalized_diff_digest: oldDiff, ...oldStable } = old;
    const { base_sha: newBase, normalized_diff_digest: newDiff, ...newStable } = current;
    if (!equal(oldStable, newStable) || oldBase === newBase
        || !equal(originalPlan.resolution_inputs, plan.resolution_inputs)
        || !equal(originalPlan.limits, plan.limits)
        || !equal(originalPlan.summary.selected_command_ids, plan.summary.selected_command_ids)
        || !equal(originalPlan.summary.selected_surface_ids, plan.summary.selected_surface_ids)
        || !equal(originalPlan.environment_passthrough, plan.environment_passthrough)) fail('inputs_changed');
    const max = plan.limits.max_diff_bytes; const policyMax = plan.limits.max_policy_bytes;
    git(repo, ['merge-base', '--is-ancestor', oldBase, newBase], max, 'base_not_fast_forward');
    git(repo, ['merge-base', '--is-ancestor', oldBase, current.head_sha], max, 'original_base_not_ancestor');
    const shas = [oldBase, newBase, current.head_sha];
    const optIn = consistentBlob(repo, shas, APPLICABILITY_PATH, policyMax, 'opt_in_missing');
    const selectorBlob = consistentBlob(repo, shas, plan.resolution_inputs.policy_path, policyMax);
    const [policy, selector] = parseTrusted({ action: 'json',
      documents: [optIn.raw.toString('utf8'), selectorBlob.raw.toString('utf8')] }, max).documents;
    validatePolicy(policy, selector);
    const registryBlob = consistentBlob(repo, shas, policy.trust_registry_path, policyMax);
    const [registry] = parseTrusted({ action: 'json', documents: [registryBlob.raw.toString('utf8')] }, max).documents;
    validateRegistry(registry, policy, plan.resolution_inputs.policy_path, policyMax);
    for (const path of VERIFIER_CLOSURE) {
      const trusted = consistentBlob(repo, shas, path, max, 'implementation_unavailable');
      if (checkExecutingClosure) {
        const installed = new URL(`../../${path.slice('.gaai/core/'.length)}`, import.meta.url);
        if (hash(readFileSync(installed)) !== trusted.digest) fail('implementation_untrusted');
      }
    }
    for (const historical of [originalPlan, plan]) {
      const reconstructed = reconstructAdmissionInputs({ repo, baseRef: current.base_ref,
        baseSha: historical.binding.base_sha, headSha: current.head_sha, policyPath: plan.resolution_inputs.policy_path,
        riskInputs: plan.resolution_inputs.risk_inputs ?? undefined, invocation: context, policy: selector,
        environmentDigest: historical.binding.environment_digest });
      if (!equal(reconstructed.binding, historical.binding)
          || !equal(reconstructed.selected_commands, historical.selected_commands)
          || !equal(reconstructed.summary, historical.summary)) fail('original_plan_invalid');
    }
    const delta = git(repo, ['diff', '--raw', '--no-abbrev', '--no-renames', '-z', oldBase, newBase], max);
    const before = blob(repo, oldBase, policy.backlog_path, max);
    const after = blob(repo, newBase, policy.backlog_path, max);
    const names = git(repo, ['diff', '--name-only', '--no-renames', '-z', oldBase, newBase], max).toString();
    if (names !== `${policy.backlog_path}\0` || before.mode !== after.mode
        || deriveIntegratedTree(repo, oldBase, policy.backlog_path, after.raw, max) !== rootTree(repo, newBase, max))
      fail('base_delta_not_lifecycle');
    // The old name/status digest is recomputed from immutable endpoints; equal
    // endpoint path sets cannot hide different base content from the blob proof.
    const tokens = git(repo, ['diff', '--name-status', '-M', '-z', oldBase, current.head_sha], max).toString().split('\0');
    tokens.pop();
    const entries = [];
    for (let index = 0; index < tokens.length;) {
      const status = tokens[index++];
      if (status.startsWith('R')) entries.push({ status, from: tokens[index++], to: tokens[index++] });
      else entries.push({ status, path: tokens[index++] });
    }
    if (hash(canonicalJson(entries)) !== oldDiff) fail('original_plan_invalid');
    const oldPaths = new Set(entries.flatMap(entry => entry.path ? [entry.path] : [entry.from, entry.to]));
    if (!equal(originalPlan.summary, { ...plan.summary, base_sha: oldBase,
      binding_digest: originalPlan.binding_digest, changed_path_count: oldPaths.size,
      rename_count: entries.filter(entry => entry.status.startsWith('R')).length }))
      fail('original_plan_invalid');
    const declared = selector.commands.filter(command => old.command_digests.some(value => value.id === command.id));
    if (declared.length !== originalPlan.selected_commands.length) fail('original_plan_invalid');
    for (let index = 0; index < declared.length; index++) {
      const command = declared[index]; const actual = originalPlan.selected_commands[index];
      const freshCommand = plan.selected_commands[index];
      const argv = command.argv.map(arg => arg === '{base_sha}' ? oldBase : arg === '{head_sha}' ? old.head_sha : arg);
      if (command.id !== actual.id || hash(canonicalJson(command)) !== actual.descriptor_digest
          || !equal(actual, { ...freshCommand, argv })) fail('original_plan_invalid');
    }
    const head = blob(repo, current.head_sha, policy.backlog_path, max);
    // Preserve an initial BOM as a source character; stripping it would alter
    // bytes outside every approved scalar replacement span.
    const decode = raw => new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(raw);
    const yamlProof = parseTrusted({ action: 'yaml', before: decode(before.raw),
      after: decode(after.raw), head: decode(head.raw), policy, story_id: context.story_id }, max);
    if (yamlProof.status !== 'proven') fail('parse_invalid');
    const reusable = plan.selected_commands.filter((command, index) => policy.reusable_command_ids.includes(command.id)
      && equal(command, originalPlan.selected_commands[index])).map(command => command.id);
    const proof = { schema_version: '1.0.0', status: 'eligible', invocation: context,
      original_binding_digest: originalPlan.binding_digest, current_binding_digest: plan.binding_digest,
      original_results_digest: hash(canonicalJson(results)), original_base_sha: oldBase, current_base_sha: newBase,
      head_sha: current.head_sha, policy_digest: optIn.digest, trust_registry_digest: registryBlob.digest,
      old_backlog_digest: before.digest, new_backlog_digest: after.digest, delta_digest: hash(delta),
      head_backlog_digest: head.digest,
      integrated_backlog_digest: hash(Buffer.from(yamlProof.integrated_base64, 'base64')),
      integration_digest: integrationDigest(repo, current.head_sha, policy.backlog_path,
        Buffer.from(yamlProof.integrated_base64, 'base64'), max),
      row_count: yamlProof.row_count, scalar_count: yamlProof.scalar_count,
      reusable_command_ids: reusable,
      fresh_command_ids: plan.selected_commands.map(command => command.id).filter(id => !reusable.includes(id)) };
    proof.proof_digest = hash(canonicalJson(proof));
    if (Buffer.byteLength(canonicalJson(proof)) > plan.limits.max_receipt_bytes) fail('proof_too_large');
    return proof;
  } catch (error) {
    const allowed = ['invocation_mismatch', 'execution_not_passed', 'evidence_invalid', 'results_too_large',
      'plan_invalid', 'inputs_changed', 'current_plan_invalid', 'base_not_fast_forward', 'opt_in_missing',
      'policy_or_trust_changed', 'policy_invalid', 'trust_registry_invalid', 'base_delta_not_lifecycle',
      'original_plan_invalid', 'parse_invalid', 'proof_too_large', 'blob_unavailable', 'blob_unsafe',
      'git_unavailable', 'parser_unavailable', 'yaml_ambiguous', 'backlog_shape_changed', 'story_missing',
      'non_lifecycle_change', 'non_scalar_bytes_changed', 'yaml_runtime_missing', 'yaml_runtime_interpreter_invalid',
      'yaml_runtime_manifest_invalid', 'yaml_runtime_asset_invalid', 'yaml_runtime_platform_unsupported',
      'yaml_runtime_import_failed', 'yaml_runtime_semantic_mismatch', 'integration_conflict',
      'original_base_not_ancestor', 'implementation_unavailable', 'implementation_untrusted'];
    return { schema_version: '1.0.0', status: 'rejected',
      reason: allowed.includes(error.message) ? error.message : 'applicability_invalid' };
  }
}

function isDirectInvocation() {
  try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); }
  catch { return false; }
}

if (isDirectInvocation()) {
  try {
    const [repo, originalPath, currentPath, resultsPath, output] = process.argv.slice(2);
    const read = path => JSON.parse(readFileSync(path, 'utf8'));
    const proof = proveApplicability({ repo, originalPlan: read(originalPath), plan: read(currentPath), results: read(resultsPath) });
    writeFileSync(output, `${canonicalJson(proof)}\n`, { mode: 0o600, flag: 'wx' });
    process.stdout.write(`${proof.status === 'eligible' ? 'eligible' : proof.reason}\n`);
    if (proof.status !== 'eligible') process.exitCode = 3;
  } catch {
    process.stderr.write('{"status":"rejected","reason":"applicability_invalid"}\n');
    process.exitCode = 2;
  }
}
