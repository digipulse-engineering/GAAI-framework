#!/usr/bin/env bash
# ── qa-admission-evidence.test.sh ──────────────────────────────────────────
# Regression coverage for the pre-QA admission account handed to the QA agent:
# the verifier's consumability predicate (lib/qa-admission-evidence.mjs), the
# dispatcher helper that runs it (_qa_admission_evidence) and the QA prompt
# contract for GAAI_QA_ADMISSION_EVIDENCE_PATH.
#
# Run: bash .gaai/core/scripts/tests/qa-admission-evidence.test.sh
# Exit 0 = all pass.
set -uo pipefail
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }

SCRIPT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VERIFIER="$SCRIPT_DIR/lib/qa-admission-evidence.mjs"
EXECUTOR="$SCRIPT_DIR/lib/local-admission-executor.mjs"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-qa-admission-evidence-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
STORY="T-QAEV"
POLICY_REL="policy/admission.json"

# ── Fixture repository: base B0 on origin/staging, candidate C on top ──────
REMOTE="$ROOT/remote.git"; REPO="$ROOT/repo"
git init -q --bare "$REMOTE"; git init -q "$REPO"
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name 'Evidence Fixture'
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" switch -qc staging; git -C "$REPO" remote add origin "$REMOTE"
mkdir -p "$REPO/policy" "$REPO/src"
printf '{"commands":[{"id":"unit","argv":["bash","checks/unit.sh","{head_sha}"]},{"id":"lint","argv":["bash","checks/lint.sh"]}]}\n' \
  > "$REPO/$POLICY_REL"
printf 'export const value = 1;\n' > "$REPO/src/value.mjs"
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" push -q origin staging; git -C "$REPO" fetch -q origin staging
B0="$(git -C "$REPO" rev-parse origin/staging)"
git -C "$REPO" switch -qc story/test
printf 'export const value = 2;\n' > "$REPO/src/value.mjs"
git -C "$REPO" add -A; git -C "$REPO" commit -qm candidate
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# A later base B1 on the target, and a commit D the target never contained.
git -C "$REPO" switch -q staging
printf 'next\n' > "$REPO/src/next.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm advance
B1="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" switch -q --detach "$B0"
printf 'divergent\n' > "$REPO/src/divergent.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm divergent
D_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" switch -q story/test
set_target() { git -C "$REPO" update-ref refs/remotes/origin/staging "$1"; }
set_target "$B0"

# ── Receipt builder: seals with the executor's own canonicalJson ───────────
# make_receipt <out> <json patch applied to a passing plain receipt>
make_receipt() {
  local out="$1" patch="${2:-}" after="${3:-null}"
  [[ -n "$patch" ]] || patch='{}'
  node --input-type=module -e '
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
const [, out, executor, story, head, base, patchJson, keepDigestJson] = process.argv;
const { canonicalJson } = await import(executor);
const result = id => ({ command_id: id, descriptor_digest: "d".repeat(64), configuration_digest: "c".repeat(64),
  outcome: "passed", exit_code: 0, signal: null, duration_ms: 1200, stdout_bytes: 10, stderr_bytes: 0,
  stdout_truncated: false, stderr_truncated: false });
const receipt = { schema_version: "1.0.0", boundary: "pre_qa", story_id: story,
  candidate: { base_ref: "staging", base_sha: base, head_sha: head, policy_version: "fixture" },
  binding_digest: "b".repeat(64), selected_surface_ids: ["source"], selected_command_ids: ["unit"],
  results: [result("unit")], outcome: "pass", publication_admitted: false,
  created_at: "2026-01-01T00:00:00.000Z" };
const patch = JSON.parse(patchJson);
for (const [key, value] of Object.entries(patch)) {
  if (key === "candidate") Object.assign(receipt.candidate, value);
  else if (key === "results_fn") receipt.results = value.map(r => typeof r === "string" ? result(r) : { ...result(r.command_id), ...r });
  else receipt[key] = value;
}
receipt.receipt_digest = createHash("sha256").update(canonicalJson(receipt)).digest("hex");
const keep = JSON.parse(keepDigestJson || "null");
if (keep) Object.assign(receipt, keep);          // mutate the body AFTER sealing
writeFileSync(out, JSON.stringify(receipt));
' "$out" "$EXECUTOR" "$STORY" "${HEAD_OVERRIDE:-$HEAD_SHA}" "${BASE_OVERRIDE:-$B0}" "$patch" "$after"
}

# verify <receipt|''> [admitted_head] [admitted_base] [policy] → prints reason
verify() {
  local out="$ROOT/evidence.json"
  rm -f "$out"
  node "$VERIFIER" --receipt "$1" --story-id "$STORY" --repo "$REPO" \
    --admitted-head "${2-$HEAD_SHA}" --admitted-base "${3-$B0}" \
    --qa-base-ref origin/staging --policy "${4-$POLICY_REL}" --output "$out" >/dev/null 2>&1 \
    || { printf 'verifier_exit_nonzero'; return; }
  node -e 'const e=require(process.argv[1]);process.stdout.write(e.reason)' "$out"
}
field() { node -e 'const e=require(process.argv[1]);const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],e);process.stdout.write(JSON.stringify(v))' "$ROOT/evidence.json" "$1"; }
expect() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then pass "$label ($want)"; else fail "$label: expected $want, got $got"; fi
}
R="$ROOT/receipt.json"

echo "P: consumable receipts"
make_receipt "$R"
expect "P1 plain 1.0.0 receipt" consumable "$(verify "$R")"
expect "P1b argv comes from the policy at the receipt base" '["bash","checks/unit.sh","{head_sha}"]' "$(field commands.0.argv)"
expect "P1c facts are handed over" '"'"$HEAD_SHA"'"' "$(field head_sha)"
expect "P1d every policy command is declared, selected or not" '["unit","lint"]' "$(node -e 'process.stdout.write(JSON.stringify(require(process.argv[1]).declared_commands.map(c=>c.id)))' "$ROOT/evidence.json")"

set_target "$B1"
make_receipt "$R"
expect "P2 pinned receipt: base B0 while the QA base advanced to B1" consumable "$(verify "$R")"

BASE_OVERRIDE="$B1" make_receipt "$R" '{"schema_version":"2.0.0","invocation_id":"00000000-0000-4000-8000-000000000000","original_execution":{"binding_digest":"x"},"refreshed_execution":{"binding_digest":"y"},"results_fn":[{"command_id":"unit","execution":{"execution_id":"00000000-0000-4000-8000-000000000001"}}]}'
expect "P3 composite 2.0.0 receipt: base B1 newer than anything HEAD contains" consumable "$(verify "$R" "$HEAD_SHA" "$B1")"
set_target "$B0"

make_receipt "$R"
mkdir -p "$REPO/.delivery-logs"; printf 'log\n' > "$REPO/.delivery-logs/$STORY.qa.log"
expect "P4 a change confined to .delivery-logs/ keeps the tree clean" consumable "$(verify "$R")"
rm -rf "$REPO/.delivery-logs"

expect "P5 unreadable policy leaves the receipt consumable" consumable "$(verify "$R" "$HEAD_SHA" "$B0" policy/missing.json)"
expect "P5b ... with argv null" null "$(field commands.0.argv)"
expect "P5c ... and no declared commands" '[]' "$(field declared_commands)"

echo "N: one negative per reason"
expect "N1 empty receipt handle" receipt_absent "$(verify '')"
expect "N1b not consumable" false "$(field consumable)"
expect "N2 missing receipt file" receipt_unreadable "$(verify "$ROOT/nope.json")"
printf 'not json' > "$ROOT/garbage.json"
expect "N3 unparseable receipt" receipt_unparseable "$(verify "$ROOT/garbage.json")"
make_receipt "$R" '{"schema_version":"3.0.0"}'
expect "N4 unsupported schema" receipt_schema_unsupported "$(verify "$R")"
make_receipt "$R" '{}' '{"selected_command_ids":["lint"],"results":[{"command_id":"lint","outcome":"passed"}]}'
expect "N5 selected command replaced, stored digest intact" receipt_integrity_failed "$(verify "$R")"
make_receipt "$R" '{}' '{"results":[]}'
expect "N6 results emptied, stored digest intact" receipt_integrity_failed "$(verify "$R")"
make_receipt "$R" '{"boundary":"final"}'
expect "N7 final-boundary receipt" receipt_other_boundary "$(verify "$R")"
make_receipt "$R" '{"story_id":"T-OTHER"}'
expect "N8 other Story" receipt_other_story "$(verify "$R")"
make_receipt "$R" '{"outcome":"blocked:command_failed"}'
expect "N9 non-pass outcome" receipt_not_pass "$(verify "$R")"
HEAD_OVERRIDE="$B0" make_receipt "$R"
expect "N10 receipt bound to another head" receipt_head_mismatch "$(verify "$R")"
make_receipt "$R"
expect "N11 gate admitted another head" receipt_head_mismatch "$(verify "$R" "$B0")"
git -C "$REPO" switch -q --detach "$D_SHA"
expect "N11b worktree HEAD moved after the gate (receipt and admitted head agree)" receipt_head_mismatch "$(verify "$R")"
git -C "$REPO" switch -q story/test
expect "N12 gate base unknown" admitted_base_unknown "$(verify "$R" "$HEAD_SHA" '')"
expect "N13 base mismatch at unchanged HEAD" receipt_base_mismatch "$(verify "$R" "$HEAD_SHA" "$B1")"
BASE_OVERRIDE="$D_SHA" make_receipt "$R"
expect "N14 admitted base not contained in the QA base" receipt_base_not_in_qa_base "$(verify "$R" "$HEAD_SHA" "$D_SHA")"
make_receipt "$R"
printf 'stray\n' > "$REPO/src/stray.txt"
expect "N15 untracked file" worktree_dirty "$(verify "$R")"
rm -f "$REPO/src/stray.txt"
printf 'export const value = 3;\n' > "$REPO/src/value.mjs"
expect "N16 modified tracked file" worktree_dirty "$(verify "$R")"
git -C "$REPO" checkout -q -- src/value.mjs
make_receipt "$R" '{"selected_command_ids":["unit","lint"]}'
expect "N17 selected command without a result" receipt_results_incomplete "$(verify "$R")"
make_receipt "$R" '{"results_fn":[{"command_id":"unit","outcome":"timed_out"}]}'
expect "N18 selected command not passed" receipt_results_incomplete "$(verify "$R")"
make_receipt "$R" '{"results_fn":["unit","unit"]}'
expect "N19 duplicate result" receipt_results_incomplete "$(verify "$R")"
make_receipt "$R" '{"results_fn":["unit","lint"]}'
expect "N20 result for an unselected command" receipt_results_incomplete "$(verify "$R")"
make_receipt "$R" '{"selected_command_ids":[],"results_fn":[]}'
expect "N21 empty selection" receipt_results_incomplete "$(verify "$R")"

echo "D: dispatcher helper and prompt contract"
PROJECT_DIR="$REPO_ROOT"
LOCK_DIR="$ROOT/locks"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/daemon-dispatch.sh"
export GAAI_LOCAL_ADMISSION_POLICY_PATH="$POLICY_REL"
make_receipt "$R"
GAAI_ADMISSION_RECEIPT="$R"; GAAI_ADMITTED_SHA="$HEAD_SHA"; GAAI_ADMITTED_BASE_SHA="$B0"
_qa_admission_evidence "$STORY" "$REPO" origin/staging > "$ROOT/line.txt"
line=$(cat "$ROOT/line.txt")
EVIDENCE="$GAAI_QA_ADMISSION_EVIDENCE"
[[ "$EVIDENCE" == "$LOCK_DIR/.qa-admission-evidence-${STORY}."*.json && -s "$EVIDENCE" ]] \
  && pass "D1 helper writes the evidence file in the marker dir" \
  || fail "D1 evidence file missing: '${EVIDENCE}'"
case "$line" in
  "[QA-ADMISSION] story=${STORY} consumable=true reason=consumable receipt=${R} digest="*" head=${HEAD_SHA} selected=unit evidence=${EVIDENCE}")
    pass "D2 one [QA-ADMISSION] line with receipt, digest, head, selection and evidence" ;;
  *) fail "D2 unexpected log line: $line" ;;
esac
[[ "$(printf '%s\n' "$line" | grep -c '^\[QA-ADMISSION\]')" == 1 ]] \
  && pass "D2b exactly one line" || fail "D2b line count"
GAAI_ADMISSION_RECEIPT=""
line=$(_qa_admission_evidence "$STORY" "$REPO" origin/staging)
case "$line" in
  *" consumable=false reason=receipt_absent receipt=none digest=none head=none selected=none evidence="*)
    pass "D3 a gate without a receipt handle degrades to receipt_absent" ;;
  *) fail "D3 unexpected log line: $line" ;;
esac
GAAI_ADMISSION_RECEIPT="$R"
NODELESS="$ROOT/nodeless"; mkdir -p "$NODELESS"
for tool in git date mkdir mv rm dirname cat; do
  ln -sf "$(command -v "$tool")" "$NODELESS/$tool"
done
PATH="$NODELESS" _qa_admission_evidence "$STORY" "$REPO" origin/staging > "$ROOT/line.txt"
line=$(cat "$ROOT/line.txt"); EVIDENCE="$GAAI_QA_ADMISSION_EVIDENCE"
if [[ "$line" == *" consumable=false reason=verifier_failed "* ]] \
    && [[ $(ls "$LOCK_DIR"/.qa-admission-evidence-"$STORY".*.json | wc -l) -eq 1 ]] \
    && node -e 'const e=require(process.argv[1]);process.exit(e.consumable===false&&e.reason==="verifier_failed"?0:1)' "$EVIDENCE"; then
  pass "D4 missing runtime falls back to verifier_failed, file and line"
else
  fail "D4 fallback: $line"
fi

# D4b: a stale consumable account from an earlier cycle cannot survive a run
# whose writes all fail (unwritable marker dir, no runtime).
_qa_admission_evidence "$STORY" "$REPO" origin/staging >/dev/null   # consumable account on disk
chmod 500 "$LOCK_DIR"
PATH="$NODELESS" _qa_admission_evidence "$STORY" "$REPO" origin/staging >/dev/null
chmod 700 "$LOCK_DIR"
EVIDENCE="$GAAI_QA_ADMISSION_EVIDENCE"
if [[ ! -e "$EVIDENCE" ]] || ! node -e 'process.exit(require(process.argv[1]).consumable===true?0:1)' "$EVIDENCE" 2>/dev/null; then
  pass "D4b no stale consumable account survives a failed run"
else
  fail "D4b a previous cycle's consumable account survived"
fi

QA_PROMPT="$ROOT/qa-prompt.md"
_expand_daemon_prompt_template "$REPO_ROOT/.gaai/core/agents/sub-agents/qa.daemon-prompt.md" "$QA_PROMPT" \
  "GAAI_STORY_PATH=/w/s.md" "GAAI_PLAN_PATH=/w/p.md" "GAAI_IMPL_REPORT_PATH=/w/i.md" \
  "GAAI_QA_REPORT_PATH=/w/q.md" "GAAI_QA_SCHEMA_PATH=/w/schema.json" "GAAI_QA_VERDICT_PATH=/w/v.json" \
  "GAAI_QA_EXPECTED_SURFACES_PATH=/w/surfaces.json" "GAAI_QA_ADMISSION_EVIDENCE_PATH=$EVIDENCE" \
  "GAAI_EPIC_PATH=/w/e.md" "GAAI_BASE_REF=origin/staging" "GAAI_WORKTREE_PATH=/w" \
  "GAAI_MEMORY_DELTA_PATH=/w/m.md"
grep -qF "$EVIDENCE" "$QA_PROMPT" && pass "D5 expanded QA prompt carries the evidence path" \
  || fail "D5 evidence path missing from the expanded QA prompt"
if grep -qE '\$GAAI_[A-Z_]+' "$QA_PROMPT"; then
  fail "D6 unexpanded tokens: $(grep -oE '\$GAAI_[A-Z_]+' "$QA_PROMPT" | sort -u | tr '\n' ' ')"
else
  pass "D6 no unexpanded \$GAAI_ token"
fi

printf '\nqa-admission-evidence: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
