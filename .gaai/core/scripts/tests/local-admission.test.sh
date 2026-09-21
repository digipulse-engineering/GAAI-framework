#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXECUTOR="$SCRIPT_DIR/lib/local-admission-executor.mjs"
source "$SCRIPT_DIR/lib/local-admission.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-local-admission-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
REMOTE="$ROOT/remote.git"; REPO="$ROOT/repo"; RECEIPTS="$ROOT/receipts"
POLICY_REL="policy/local-admission.json"; RISK="$ROOT/risk.json"
git init -q --bare "$REMOTE"; git init -q "$REPO"
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name 'Admission Fixture'
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" switch -qc staging; git -C "$REPO" remote add origin "$REMOTE"
mkdir -p "$REPO/policy" "$REPO/src" "$REPO/checks" "$REPO/docs"
printf 'lockfileVersion: 9\n' > "$REPO/pnpm-lock.yaml"
printf '# docs\n' > "$REPO/docs/readme.md"
printf 'export const value = 1;\n' > "$REPO/src/value.mjs"
cat > "$REPO/checks/unit.sh" <<'EOF'
#!/usr/bin/env bash
printf 'token=do-not-store-me\n'
[[ -z "${GAAI_LEAK_PROBE:-}" ]] || exit 7
[[ -z "${EXPECT_KEEP:-}" || -n "${GAAI_KEEP_PROBE:-}" ]] || exit 8
[[ -z "${UNIT_MUTATE:-}" ]] || : > mutated.txt
[[ "${1:-}" == '; touch /tmp/gaai-admission-pwned' ]]
EOF
chmod +x "$REPO/checks/unit.sh"
node - "$REMOTE" > "$REPO/$POLICY_REL" <<'NODE'
const remote = process.argv[2];
process.stdout.write(`${JSON.stringify({
  schema_version:'1.0.0', policy_version:'fixture-v1',
  repository:{project_id:'fixture/project',remote,base_ref:'staging'},
  limits:{max_policy_bytes:65536,max_diff_bytes:65536,max_changed_paths:32,max_commands:4,
    max_selectors:4,max_identifier_bytes:64,max_arguments_per_command:8,max_argument_bytes:256,
    max_receipt_bytes:65536,max_result_bytes:32768},
  commands:[{id:'unit',argv:['bash','checks/unit.sh','; touch /tmp/gaai-admission-pwned'],
    timeout_seconds:5,output_limit_bytes:8,config_paths:['checks/unit.sh']}],
  selectors:[{id:'source',path_prefixes:['src'],exact_paths:[],command_ids:['unit']},
    {id:'checks',path_prefixes:['checks'],exact_paths:[],command_ids:['unit']}],
  exhaustive_command_ids:['unit'],non_executable_prefixes:['docs'],
  broadening_prefixes:['policy','package.json'],broadening_patterns:['tsconfig*.json'],
  dependency_inputs:['pnpm-lock.yaml'],
  risk_input_policy:{keys:['cross_cutting','dependency_changed'],
    exhaustive_when_true:['cross_cutting','dependency_changed']},
  required_environment:['node_version','platform','arch','path_digest'],
  environment_passthrough:['GAAI_KEEP_*','GAAI_ADVANCE_REPO'],
  executable_suffixes:['.sh','.js','.mjs','.json'],executable_names:['Dockerfile','Makefile']
}, null, 2)}\n`);
NODE
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" push -q origin staging; git -C "$REPO" fetch -q origin staging
BASE_SHA="$(git -C "$REPO" rev-parse origin/staging)"
git -C "$REPO" switch -qc story/test
printf 'export const value = 2;\n' > "$REPO/src/value.mjs"
git -C "$REPO" add -A; git -C "$REPO" commit -qm candidate
export GAAI_LOCAL_ADMISSION_POLICY_PATH="$POLICY_REL"
unset GAAI_LOCAL_ADMISSION_RISK_INPUTS_PATH GAAI_LOCAL_ADMISSION_MAX_RECEIPT_BYTES

rm -f /tmp/gaai-admission-pwned
if _run_local_admission pre_qa TST-LA "$REPO" staging "$RECEIPTS" >/dev/null; then
  PRE="$LOCAL_ADMISSION_RECEIPT_PATH"
  if [[ "$(node -e 'const r=require(process.argv[1]);process.stdout.write(String(r.publication_admitted))' "$PRE")" == false \
    && "$(node -e 'const r=require(process.argv[1]);process.stdout.write(`${r.results[0].stdout_bytes}|${r.results[0].stdout_truncated}`)' "$PRE")" == '8|true' \
    && ! -e /tmp/gaai-admission-pwned ]] && ! grep -q 'do-not-store-me' "$PRE"; then
    pass 'pre-QA PASS executes injection-shaped argv without shell and stores no output'
  else fail 'pre-QA privacy or argv execution contract'; fi
else fail "pre-QA expected PASS, got $LOCAL_ADMISSION_OUTCOME"; fi

SCRIPT_ALIAS="$ROOT/scripts-alias"
ALIAS_RECEIPT="$RECEIPTS/.local-admission-TST-ALIAS-pre_qa.json"
ln -s "$SCRIPT_DIR" "$SCRIPT_ALIAS"
if (
  # Source through a non-canonical path to reproduce macOS /var -> /private/var
  # snapshots and generic symlinked worktree roots.
  source "$SCRIPT_ALIAS/lib/local-admission.sh"
  _run_local_admission pre_qa TST-ALIAS "$REPO" staging "$RECEIPTS" >/dev/null
) && [[ -s "$ALIAS_RECEIPT" \
  && "$(node -e 'const r=require(process.argv[1]);process.stdout.write(r.outcome)' "$ALIAS_RECEIPT")" == pass ]]; then
  pass 'symlink-aliased framework paths execute the resolver and executor entrypoints'
else
  fail 'symlink-aliased framework path skipped a local-admission entrypoint'
fi

# The delivery wrapper exports its phase state, including a pointer into the
# live candidate worktree; the gate must not hand any of it to its commands.
# What a command may inherit from the GAAI_ namespace is exactly what the
# policy declares. checks/unit.sh exits 7 when it can see GAAI_LEAK_PROBE
# (undeclared) and 8 when EXPECT_KEEP is set but GAAI_KEEP_PROBE (declared
# through GAAI_KEEP_*) did not arrive.
export GAAI_LEAK_PROBE=1 GAAI_KEEP_PROBE=kept EXPECT_KEEP=1
if _run_local_admission pre_qa TST-ENV "$REPO" staging "$RECEIPTS" >/dev/null \
   && [[ "$LOCAL_ADMISSION_OUTCOME" == pass ]]; then
  pass 'gate commands inherit only the GAAI_* names the policy declares'
else fail "GAAI_* pass-through contract (outcome=$LOCAL_ADMISSION_OUTCOME)"; fi
unset GAAI_LEAK_PROBE GAAI_KEEP_PROBE EXPECT_KEEP
node --input-type=module - "$EXECUTOR" <<'NODE'
const { gateEnvironment } = await import(process.argv[2]);
const env = gateEnvironment({ PATH: '/p', HOME: '/h', GAAI_QA_REPORT_PATH: '/x', GAAI_KEPT: 'k' }, ['GAAI_KEPT']);
if (env.PATH !== '/p' || env.HOME !== '/h' || env.GAAI_KEPT !== 'k') process.exit(1);
if (Object.hasOwn(env, 'GAAI_QA_REPORT_PATH')) process.exit(2);
NODE
[[ $? -eq 0 ]] && pass 'gateEnvironment keeps the declared GAAI_ names and drops the rest' \
  || fail 'gateEnvironment contract'

# A declared pass-through value is bound: changing it changes the binding.
# An undeclared GAAI_ value is not part of the gate at all, so it does not.
bind_of() { node -e 'const r=require(process.argv[1]);process.stdout.write(r.binding_digest)' "$RECEIPTS/.local-admission-$1-pre_qa.json"; }
GAAI_KEEP_PROBE=a _run_local_admission pre_qa TST-BIND-A "$REPO" staging "$RECEIPTS" >/dev/null
GAAI_KEEP_PROBE=b _run_local_admission pre_qa TST-BIND-B "$REPO" staging "$RECEIPTS" >/dev/null
GAAI_KEEP_PROBE=a GAAI_LEAK_PROBE=x _run_local_admission pre_qa TST-BIND-C "$REPO" staging "$RECEIPTS" >/dev/null
if [[ -n "$(bind_of TST-BIND-A)" && "$(bind_of TST-BIND-A)" != "$(bind_of TST-BIND-B)" \
   && "$(bind_of TST-BIND-A)" == "$(bind_of TST-BIND-C)" ]]; then
  pass 'a declared pass-through value is bound into the receipt; an undeclared one is not'
else fail "pass-through binding: A=$(bind_of TST-BIND-A | cut -c1-8) B=$(bind_of TST-BIND-B | cut -c1-8) C=$(bind_of TST-BIND-C | cut -c1-8)"; fi

# A command that mutates the candidate unseals it. The re-resolve then rejects
# with candidate_unsealed, the run is stale although no ref moved, and the
# note must say exactly that — this was undiagnosable for five cycles.
STALE_NOTE="$RECEIPTS/.local-admission-TST-MUT-pre_qa.stale.json"
UNIT_MUTATE=1 _run_local_admission pre_qa TST-MUT "$REPO" staging "$RECEIPTS" >/dev/null
MUT_RC=$?; rm -f "$REPO/mutated.txt"
if [[ $MUT_RC -ne 0 && "$LOCAL_ADMISSION_OUTCOME" == blocked:stale_evidence && -s "$STALE_NOTE" \
   && "$(node -e 'const n=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(`${n.why}|${n.resolver_reason}|${n.bound_base===n.fresh_base&&n.bound_head===n.fresh_head}`)' "$STALE_NOTE")" == 'resolver_no_binding|candidate_unsealed|true' ]]; then
  pass 'a command that mutates the candidate is reported stale with resolver_reason=candidate_unsealed and unmoved refs'
else fail "mutating command: rc=$MUT_RC outcome=$LOCAL_ADMISSION_OUTCOME note=$(cut -c1-160 "$STALE_NOTE" 2>/dev/null)"; fi

if _run_local_admission final TST-LA "$REPO" staging "$RECEIPTS" >/dev/null; then
  FINAL="$LOCAL_ADMISSION_RECEIPT_PATH"
  node --input-type=module - "$EXECUTOR" "$FINAL" <<'NODE'
import { createHash } from 'node:crypto';
const { canonicalJson, sealReceipt } = await import(process.argv[2]);
const receipt = JSON.parse(await (await import('node:fs/promises')).readFile(process.argv[3], 'utf8'));
const claimed = receipt.receipt_digest; delete receipt.receipt_digest;
if (claimed !== createHash('sha256').update(canonicalJson(receipt)).digest('hex')) process.exit(1);
const plan={status:'rejected',summary:{}};
const forged=JSON.parse(sealReceipt({boundary:'pre_qa',storyId:'T',plan,results:[],
  resultsDigest:createHash('sha256').update('[]').digest('hex'),outcome:'blocked:command_failed',
  publicationAdmitted:true,maxBytes:65536}));
if (forged.publication_admitted) process.exit(2);
const binding={head_sha:'0'.repeat(40)};
const resolved={status:'resolved',binding,binding_digest:createHash('sha256').update(canonicalJson(binding)).digest('hex'),
  selected_commands:[{id:'unit',descriptor_digest:'d',configuration_digest:'c',output_limit_bytes:8}],summary:{}};
try {
  sealReceipt({boundary:'final',storyId:'T',plan:resolved,results:[],
    resultsDigest:createHash('sha256').update('[]').digest('hex'),outcome:'pass',
    expectedBindingDigest:resolved.binding_digest,maxBytes:65536});
  process.exit(3);
} catch (error) { if (error.message !== 'evidence_invalid') process.exit(4); }
NODE
  if [[ $? -eq 0 && "$FINAL" != "$PRE" \
    && "$(node -e 'const r=require(process.argv[1]);process.stdout.write(String(r.publication_admitted))' "$FINAL")" == true ]]; then
    pass 'final receipt alone admits publication and its canonical self-digest verifies'
  else fail 'final receipt boundary or digest'; fi
else fail "final expected PASS, got $LOCAL_ADMISSION_OUTCOME"; fi

SAVED_FINAL="$FINAL"
export GAAI_LOCAL_ADMISSION_RISK_INPUTS_PATH="$ROOT/missing-risk.json"
if ! _run_local_admission final TST-LA "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:risk_inputs_missing && ! -e "$SAVED_FINAL" ]]; then
  pass 'an invalid optional risk path removes any prior PASS receipt for that boundary'
else fail 'stale final receipt survived an early failure'; fi
unset GAAI_LOCAL_ADMISSION_RISK_INPUTS_PATH

GAAI_DAEMON_EXECUTOR=claude _run_local_admission pre_qa TST-C "$REPO" staging "$RECEIPTS" >/dev/null
C_BINDING="$(node -e 'const r=require(process.argv[1]);process.stdout.write(r.binding_digest)' "$LOCAL_ADMISSION_RECEIPT_PATH")"
GAAI_DAEMON_EXECUTOR=codex _run_local_admission pre_qa TST-D "$REPO" staging "$RECEIPTS" >/dev/null
D_BINDING="$(node -e 'const r=require(process.argv[1]);process.stdout.write(r.binding_digest)' "$LOCAL_ADMISSION_RECEIPT_PATH")"
[[ "$C_BINDING" == "$D_BINDING" ]] && pass 'Claude/Codex choice is admission-neutral' \
  || fail 'executor choice changed the binding'

ADVANCE="$ROOT/advance"
git clone -q --branch staging "$REMOTE" "$ADVANCE"
git -C "$ADVANCE" config user.email fixture@example.invalid
git -C "$ADVANCE" config user.name 'Admission Fixture'
printf '# advanced during check\n' >> "$ADVANCE/docs/readme.md"
git -C "$ADVANCE" add -A; git -C "$ADVANCE" commit -qm base-advance
git -C "$REPO" switch -q staging; git -C "$REPO" reset -q --hard origin/staging
git -C "$REPO" switch -qC story/base-advance
cat > "$REPO/checks/unit.sh" <<'EOF'
#!/usr/bin/env bash
# The updater repo arrives through the policy's declared pass-through. An
# empty path would make git act on the candidate itself and pass this test
# for the wrong reason, so refuse it.
[[ -n "${GAAI_ADVANCE_REPO:-}" ]] || exit 9
git -C "$GAAI_ADVANCE_REPO" push -q origin HEAD:staging
EOF
chmod +x "$REPO/checks/unit.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm advancing-command
export GAAI_ADVANCE_REPO="$ADVANCE"
BASE_NOTE="$RECEIPTS/.local-admission-TST-BASE-final.stale.json"
if ! _run_local_admission final TST-BASE "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:stale_evidence && -s "$BASE_NOTE" \
    && "$(node -e 'const n=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(`${n.why}|${n.fresh_base}`)' "$BASE_NOTE")" \
       == "base_advanced|$(git -C "$ADVANCE" rev-parse HEAD)" ]]; then
  pass 'second fetch rejects a base advanced by the updater while checks execute, and the note names the advance'
else fail "base-currentness outcome=$LOCAL_ADMISSION_OUTCOME note=$(cut -c1-160 "$BASE_NOTE" 2>/dev/null)"; fi
git -C "$REPO" push -q --force origin "$BASE_SHA:staging"
git -C "$REPO" fetch -q origin staging
unset GAAI_ADVANCE_REPO

git -C "$REPO" switch -q staging; git -C "$REPO" reset -q --hard origin/staging
git -C "$REPO" switch -qC story/unresolved
mkdir -p "$REPO/unknown"; printf 'export {};\n' > "$REPO/unknown/surface.mjs"
git -C "$REPO" add -A; git -C "$REPO" commit -qm unresolved-surface
if ! _run_local_admission pre_qa TST-RESOLVE "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:unknown_executable_surface \
    && -z "$LOCAL_ADMISSION_RECEIPT_PATH" ]]; then
  pass 'resolver rejection is typed and executes no command'
else fail "resolver-rejection outcome=$LOCAL_ADMISSION_OUTCOME"; fi

git -C "$REPO" switch -q staging; git -C "$REPO" reset -q --hard origin/staging
git -C "$REPO" switch -qC story/fail
printf '#!/usr/bin/env bash\nexit 9\n' > "$REPO/checks/unit.sh"; chmod +x "$REPO/checks/unit.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm failing-command
if ! _run_local_admission final TST-FAIL "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:command_failed \
    && "$(node -e 'const r=require(process.argv[1]);process.stdout.write(String(r.publication_admitted))' "$LOCAL_ADMISSION_RECEIPT_PATH")" == false ]]; then
  pass 'failed command yields a bounded non-publication receipt'
else fail "failed command outcome=$LOCAL_ADMISSION_OUTCOME"; fi

git -C "$REPO" reset -q --hard origin/staging; git -C "$REPO" switch -qC story/mutate
printf '#!/usr/bin/env bash\nprintf mutation >> src/mutated.txt\n' > "$REPO/checks/unit.sh"; chmod +x "$REPO/checks/unit.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm mutating-command
if ! _run_local_admission final TST-STALE "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:stale_evidence ]]; then
  pass 'command-side candidate mutation invalidates evidence'
else fail "mutation outcome=$LOCAL_ADMISSION_OUTCOME"; fi
git -C "$REPO" reset -q --hard HEAD
rm -f "$REPO/src/mutated.txt"

git -C "$REPO" reset -q --hard origin/staging; git -C "$REPO" switch -qC story/late-mutate
node - "$REPO" "$RECEIPTS/.local-admission-TST-LATE-final.json" > "$REPO/checks/unit.sh" <<'NODE'
const [repo, receipt] = process.argv.slice(2);
const worker = `const fs=require('fs');const [repo,receipt]=process.argv.slice(1);const end=Date.now()+5000;(function poll(){if(fs.existsSync(receipt)){fs.writeFileSync(repo+'/src/late.txt','late');return}if(Date.now()<end)setTimeout(poll,5)})()`;
const launcher = `require('child_process').spawn(process.execPath,['-e',${JSON.stringify(worker)},${JSON.stringify(repo)},${JSON.stringify(receipt)}],{detached:true,stdio:'ignore'}).unref()`;
process.stdout.write(`#!/usr/bin/env bash\nnode -e ${JSON.stringify(launcher)}\n`);
NODE
chmod +x "$REPO/checks/unit.sh"; git -C "$REPO" add -A; git -C "$REPO" commit -qm late-mutating-command
if ! _run_local_admission final TST-LATE "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:stale_evidence && -z "$LOCAL_ADMISSION_RECEIPT_PATH" ]]; then
  pass 'post-seal re-resolution removes evidence changed by an escaped late helper'
else fail "late-mutation outcome=$LOCAL_ADMISSION_OUTCOME"; fi
rm -f "$REPO/src/late.txt"
git -C "$REPO" switch -q staging; git -C "$REPO" reset -q --hard origin/staging
node - "$REPO/$POLICY_REL" <<'NODE'
const fs = require('node:fs');
const path = process.argv[2];
const policy = JSON.parse(fs.readFileSync(path, 'utf8'));
policy.limits.max_result_bytes = 1;
fs.writeFileSync(path, `${JSON.stringify(policy, null, 2)}\n`);
NODE
git -C "$REPO" add "$POLICY_REL"; git -C "$REPO" commit -qm tight-result-bound
git -C "$REPO" push -q origin staging; git -C "$REPO" fetch -q origin staging
git -C "$REPO" switch -qC story/size
printf 'export const value = 3;\n' > "$REPO/src/value.mjs"
git -C "$REPO" add -A; git -C "$REPO" commit -qm size-candidate

if ! _run_local_admission final TST-SIZE "$REPO" staging "$RECEIPTS" >/dev/null \
  && [[ "$LOCAL_ADMISSION_OUTCOME" == blocked:results_too_large \
    && "$(node -e 'const r=require(process.argv[1]);process.stdout.write(String(r.publication_admitted))' "$LOCAL_ADMISSION_RECEIPT_PATH")" == false ]]; then
  pass 'base-held result size overflow is durably non-authorizing'
else fail "result size outcome=$LOCAL_ADMISSION_OUTCOME"; fi

node --input-type=module - "$EXECUTOR" "$ROOT" <<'NODE'
import { writeFile, readFile } from 'node:fs/promises';
const { executeCommand } = await import(process.argv[2]);
const root = process.argv[3];
const pidFile = `${root}/child.pid`;
const strayFile = `${root}/stray.pid`;
// SIGKILL delivery and orphan reaping are asynchronous under load. Poll only to
// distinguish that OS scheduling window from a process group that remains live.
const gone = async pid => {
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline) {
    try { process.kill(pid, 0); } catch { return true; }
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  return false;
};
const normal = await executeCommand({ id:'normal', argv:['bash','-c',`sleep 30 >/dev/null 2>&1 & echo $! > '${strayFile}'`],
  timeout_seconds:5,output_limit_bytes:8,descriptor_digest:'d',configuration_digest:'c' }, { cwd:root });
if (normal.outcome !== 'passed') process.exit(4);
const stray = Number((await readFile(strayFile, 'utf8')).trim());
if (!await gone(stray)) process.exit(5);
const timed = await executeCommand({ id:'timeout', argv:['bash','-c',`sleep 30 & echo $! > '${pidFile}'; wait`],
  timeout_seconds:1,output_limit_bytes:8,descriptor_digest:'d',configuration_digest:'c' }, { cwd:root });
if (timed.outcome !== 'timed_out') process.exit(1);
const pid = Number((await readFile(pidFile, 'utf8')).trim());
if (!await gone(pid)) process.exit(2);
const controller = new AbortController();
setTimeout(() => controller.abort(), 50);
const cancelled = await executeCommand({ id:'cancel',argv:['sleep','30'],timeout_seconds:5,
  output_limit_bytes:8,descriptor_digest:'d',configuration_digest:'c' }, { cwd:root,signal:controller.signal });
if (cancelled.outcome !== 'cancelled') process.exit(3);
NODE
[[ $? -eq 0 ]] && pass 'normal completion and timeout kill the process group; cancellation stays distinct' \
  || fail 'timeout/cancellation executor contract'

# The corpus suite that installs an executor shim honouring GAAI_QA_REPORT_PATH
# must never inherit that pointer from the process that runs it.
if grep -qE '^unset GAAI_QA_REPORT_PATH GAAI_QA_VERDICT_PATH GAAI_PLAN_PATH' "$SCRIPT_DIR/tests/daemon-state-machine.test.sh"; then
  pass 'the state-machine suite refuses the wrapper phase pointers at start'
else fail 'daemon-state-machine.test.sh no longer unsets the wrapper phase pointers'; fi

# ── In-flight marker: published while a gate holds a binding, gone after ──────
#
# A gate binds base and head and then runs for tens of minutes. Advancing the base
# in that window discards the cycle. Nothing published that a binding was live, so
# whoever merged could not know. The marker is advisory: it grants nothing.
INFLIGHT="$RECEIPTS/.local-admission-TST-FLIGHT-pre_qa.inflight.json"
rm -f "$INFLIGHT"
_run_local_admission pre_qa TST-FLIGHT "$REPO" staging "$RECEIPTS" >/dev/null 2>&1 || true
if [[ ! -e "$INFLIGHT" ]]; then
  pass 'the in-flight marker does not outlive the gate that published it'
else fail 'the in-flight marker survived the gate'; fi

# Published during the run: observed from inside a selected command, which is the
# only moment a binding is actually held.
WITNESS="$ROOT/inflight-witness"; rm -f "$WITNESS"
cat > "$REPO/checks/witness.sh" <<WEOF
#!/usr/bin/env bash
ls "$RECEIPTS" 2>/dev/null | grep -c 'TST-WITNESS-pre_qa.inflight.json' > "$WITNESS"
exit 0
WEOF
chmod +x "$REPO/checks/witness.sh"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" -c user.email=t@t.t -c user.name=t commit -qm 'witness check' >/dev/null 2>&1
git -C "$REPO" push -q origin HEAD:staging >/dev/null 2>&1 || true
if _local_admission_publish_inflight "$RECEIPTS" TST-WITNESS pre_qa staging aaaa bbbb \
   && [[ -f "$RECEIPTS/.local-admission-TST-WITNESS-pre_qa.inflight.json" ]]; then
  pass 'a bound gate publishes its marker'
else fail 'a bound gate published no marker'; fi

MARKER="$RECEIPTS/.local-admission-TST-WITNESS-pre_qa.inflight.json"
if node -e '
  const d = require(process.argv[1]);
  const ok = d.story === "TST-WITNESS" && d.boundary === "pre_qa"
    && d.bound_base === "aaaa" && d.bound_head === "bbbb"
    && Number.isInteger(d.pid) && typeof d.started_at === "string";
  process.exit(ok ? 0 : 1);
' "$MARKER" 2>/dev/null; then
  pass 'the marker names the story, the boundary, the bound pair and its publisher'
else fail "the marker is missing or malformed: $(cat "$MARKER" 2>/dev/null)"; fi

# GNU stat first, BSD second, and the order is load-bearing: GNU's -f means
# --file-system, so "stat -f '%Lp' FILE" never reports a mode and the probe
# silently compares the wrong thing on Linux. BSD stat has no -c and falls
# through cleanly.
_marker_mode="$(stat -c '%a' "$MARKER" 2>/dev/null || stat -f '%Lp' "$MARKER" 2>/dev/null)"
if [[ "$_marker_mode" == "600" ]]; then
  pass 'the marker is owner-only'
else fail "the marker is readable beyond its owner (mode=${_marker_mode:-unreadable})"; fi

_LOCAL_ADMISSION_INFLIGHT="$MARKER"
_local_admission_cleanup "$ROOT/no-such-scratch"
if [[ ! -e "$MARKER" ]]; then
  pass 'the shared cleanup path removes the marker on every exit'
else fail 'the cleanup path left the marker behind'; fi

# The reader: exit 2 while a live gate holds a binding, 0 when none does, and
# residue from a dead publisher is reported without blocking.
GS="$SCRIPT_DIR/gate-status.sh"
GSDIR="$ROOT/gs"; mkdir -p "$GSDIR"
if /bin/bash "$GS" --quiet "$GSDIR"; then
  pass 'gate-status reports a free target when nothing is bound'
else fail 'gate-status reported a bound gate with no marker present'; fi
printf '{"story":"S","boundary":"final","base_ref":"staging","bound_base":"abc","bound_head":"def","pid":%s,"started_at":"2026-01-01T00:00:00Z"}\n' "$$" > "$GSDIR/.local-admission-S-final.inflight.json"
/bin/bash "$GS" --quiet "$GSDIR"; if [[ "$?" -eq 2 ]]; then
  pass 'gate-status exits 2 while a live gate holds a binding'
else fail 'gate-status did not signal a live binding'; fi
printf '{"story":"D","boundary":"final","base_ref":"staging","bound_base":"abc","bound_head":"def","pid":999999,"started_at":"2026-01-01T00:00:00Z"}\n' > "$GSDIR/.local-admission-D-final.inflight.json"
rm -f "$GSDIR/.local-admission-S-final.inflight.json"
GS_OUT="$(/bin/bash "$GS" "$GSDIR" 2>&1)"
if printf '%s' "$GS_OUT" | grep -q residue; then
  pass 'gate-status calls a dead publisher residue rather than a binding'
else fail "gate-status treated residue as a live binding: ${GS_OUT}"; fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
