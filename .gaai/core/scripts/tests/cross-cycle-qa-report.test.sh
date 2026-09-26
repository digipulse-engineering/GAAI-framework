#!/usr/bin/env bash
# cross-cycle-qa-report.test.sh — regression tests for cross-cycle qa-report injection
#
# T1: FAIL+replan_required=true → phase=plan, PLAN block appended with all 3 artefacts + marker framing
# T2: FAIL+replan_required=false → phase=impl, PLAN block absent, Section 4b triggers
# T3: FAIL without replan_required field (backward compat) → phase=impl (same as T2)
# T4: ESCALATE → phase=plan (same as T1)
# T5: PASS → no env exported, no injection
# T6: fresh story (no qa-report) → no env, prompt file does NOT contain "## Prior cycle QA findings"
# T7: qa-report 60KB → block contains truncation marker
# T8: FAIL+replan_required=true but no prior execution-plan in worktree → git show fallback succeeds
# T9: E160S14 integration — when qa-report deleted (drift simulated), helper behaves as fresh story
#
# Usage: bash .gaai/core/scripts/tests/cross-cycle-qa-report.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_LIB="$SCRIPT_DIR/../delivery-daemon.sh"
DISPATCH_LIB="$SCRIPT_DIR/../daemon-dispatch.sh"
PROMPT_LIB="$SCRIPT_DIR/../daemon-prompt-construct.sh"

# E1096S02 AC1: _resolve_cross_cycle_qa_report now delegates to the shared
# _qa_verdict_resolve resolver (daemon-dispatch.sh), which shells out to
# qa-verdict.mjs — needs a real PROJECT_DIR to find the script + schema.
export PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

FIXTURE_DIR="/tmp/gaai-cross-cycle-qa-report-test-$$"
mkdir -p "$FIXTURE_DIR"

cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT

SID="TST001"

# ── Helper: extract _resolve_cross_cycle_qa_report + its E1096S02 dependencies ──
# _resolve_cross_cycle_qa_report (delivery-daemon.sh) now calls the shared
# _qa_verdict_resolve resolver, which itself calls _derive_qa_expected_surfaces
# (both daemon-dispatch.sh) — extract all three into one sourceable script.
extract_helper() {
  local helper_script="$FIXTURE_DIR/helper.sh"
  sed -n '/^_resolve_cross_cycle_qa_report()/,/^}/p' "$DAEMON_LIB" > "$helper_script"
  sed -n '/^_derive_qa_expected_surfaces()/,/^}/p' "$DISPATCH_LIB" >> "$helper_script"
  sed -n '/^_qa_verdict_resolve()/,/^}/p' "$DISPATCH_LIB" >> "$helper_script"
  # Source it so the functions are available in our shell
  source "$helper_script"
}

# ── Helper: create a story.md with a File Inventory entry ──────────────────────
# _derive_qa_expected_surfaces reads this to build the expected-surfaces set —
# lets a fixture control that set without needing a real git-tracked diff.
make_story_with_inventory() {
  local dir="$1" surface="$2"
  local story_dir="${dir}/.gaai/project/contexts/artefacts/stories"
  mkdir -p "$story_dir"
  {
    echo "---"
    echo "id: ${SID}"
    echo "---"
    echo "## File Inventory"
    echo "- \`${surface}\` — test fixture surface"
  } > "${story_dir}/${SID}.story.md"
}

# ── Helper: create a valid two-axis qa-verdict.json sidecar (DEC-200) ──────────
# verdict: PASS | FAIL | ESCALATE. route (FAIL only): impl | plan — plan requires
# a blocking, plan-rooted finding, which requires a matching expected surface
# (pair with make_story_with_inventory using the same $surface first).
make_qa_verdict_sidecar() {
  local dir="$1" verdict="$2" route="${3:-impl}" surface="${4:-}"
  local qa_dir="${dir}/.gaai/project/contexts/artefacts/qa-reports"
  mkdir -p "$qa_dir"
  local plan_c="PASS" sota_c="PASS" route_json="null" replan_json="null"
  local inventory="[]" findings="[]" evidence="[]"
  case "$verdict" in
    PASS) : ;;
    FAIL)
      plan_c="FAIL"
      if [[ "$route" == "plan" ]]; then
        route_json='"plan"'; replan_json="true"
        inventory="[{\"surface\":\"${surface}\",\"classification\":\"blocking\",\"review_domain\":\"other\",\"materiality\":\"deprecated\"}]"
        findings="[{\"finding_id\":\"f1\",\"surface\":\"${surface}\",\"classification\":\"blocking\",\"description\":\"x\",\"root_cause\":\"plan\"}]"
        evidence="[{\"surface\":\"${surface}\",\"finding_id\":\"f1\",\"outcome\":\"contradicts\",\"source_kind\":\"live\",\"authority_uri\":\"https://x.com/docs\",\"authority_title\":\"x\",\"accessed_at\":\"2026-08-07T00:00:00Z\",\"claim\":\"y\",\"excerpt\":\"z\",\"materiality\":\"deprecated\"}]"
      else
        route_json='"impl"'; replan_json="false"
      fi
      ;;
    ESCALATE)
      plan_c="ESCALATE"; route_json='"human"'; replan_json="null"
      ;;
  esac
  printf '{"schema_version":1,"story_id":"%s","evaluated_as_of":"2026-08-07T00:00:00Z","state_of_the_art_conformance":"%s","plan_conformance":"%s","changed_surface_inventory":%s,"findings":%s,"evidence":%s,"verdict":"%s","remediation_route":%s,"replan_required":%s,"report_path":"qa-reports/%s.qa-report.md"}' \
    "$SID" "$sota_c" "$plan_c" "$inventory" "$findings" "$evidence" "$verdict" "$route_json" "$replan_json" "$SID" \
    > "${qa_dir}/${SID}.qa-verdict.json"
}

# ── Helper: create a qa-report fixture ─────────────────────────────────────────
make_qa_report() {
  local dir="$1" verdict="$2" replan="${3:-}"
  local qa_dir="${dir}/.gaai/project/contexts/artefacts/qa-reports"
  mkdir -p "$qa_dir"
  {
    echo "---"
    echo "artefact_type: qa-report"
    echo "id: ${SID}"
    echo "---"
    echo ""
    echo "Verdict: ${verdict}"
    if [[ -n "$replan" ]]; then
      echo "replan_required: ${replan}"
    fi
    echo ""
    echo "## Findings"
    echo "Some findings here."
  } > "${qa_dir}/${SID}.qa-report.md"
}

# ── Helper: create a large qa-report (60KB+) ───────────────────────────────────
make_large_qa_report() {
  local dir="$1"
  local qa_dir="${dir}/.gaai/project/contexts/artefacts/qa-reports"
  mkdir -p "$qa_dir"
  {
    echo "---"
    echo "artefact_type: qa-report"
    echo "id: ${SID}"
    echo "---"
    echo ""
    echo "Verdict: FAIL"
    echo "replan_required: true"
    echo ""
    echo "## Findings"
    # Generate ~60KB of content
    local i
    for i in $(seq 1 600); do
      printf '%s\n' "Finding line $i: $(printf 'x%.0s' {1..90})"
    done
  } > "${qa_dir}/${SID}.qa-report.md"
}

# ── Helper: create plan artefact ───────────────────────────────────────────────
make_plan() {
  local dir="$1"
  local plan_dir="${dir}/.gaai/project/contexts/artefacts/plans"
  mkdir -p "$plan_dir"
  echo "## Plan for ${SID}" > "${plan_dir}/${SID}.execution-plan.md"
}

# ── Helper: create impl-report artefact ────────────────────────────────────────
make_impl_report() {
  local dir="$1"
  local impl_dir="${dir}/.gaai/project/contexts/artefacts/impl-reports"
  mkdir -p "$impl_dir"
  echo "## Impl report for ${SID}" > "${impl_dir}/${SID}.impl-report.md"
}

# ── Helper: setup git repo with artefacts on story branch ──────────────────────
setup_git_repo_with_plan() {
  local wt_path="$1"
  local remote_dir="${wt_path}_remote.git"
  rm -rf "$wt_path" "$remote_dir"
  git init --bare "$remote_dir" -q
  git clone "$remote_dir" "$wt_path" -q
  git -C "$wt_path" config user.email "test@gaai.local"
  git -C "$wt_path" config user.name "GAAI Test"

  # Create main branch with initial commit
  mkdir -p "$wt_path/.gaai/project/contexts/artefacts/plans"
  echo "init" > "$wt_path/.gaai/init.txt"
  git -C "$wt_path" add .
  git -C "$wt_path" commit -m "initial" -q
  git -C "$wt_path" branch -M main
  git -C "$wt_path" push origin main -q 2>/dev/null || true

  # Create story branch with plan
  git -C "$wt_path" checkout -b "story/${SID}" -q
  echo "## Plan via git for ${SID}" > "$wt_path/.gaai/project/contexts/artefacts/plans/${SID}.execution-plan.md"
  git -C "$wt_path" add .
  git -C "$wt_path" commit -m "add plan" -q
  git -C "$wt_path" push origin "story/${SID}" -q 2>/dev/null || true

  # Switch back to main and remove the worktree plan file
  git -C "$wt_path" checkout main -q
  rm -rf "$wt_path/.gaai/project/contexts/artefacts/plans/${SID}.execution-plan.md"
}

# ── Helper: simulate PLAN-block injection (mirrors handle_plan_phase logic) ────
inject_plan_block() {
  local qa_path="$1" wt_path="$2" prompt_file="$3"

  local _cc_qa_content _cc_qa_bytes _cc_plan_content _cc_plan_bytes _cc_impl_content _cc_impl_bytes

  _cc_qa_bytes=$(wc -c < "$qa_path" 2>/dev/null || echo 0)
  if (( _cc_qa_bytes > 51200 )); then
    _cc_qa_content="$(head -c 51200 "$qa_path" 2>/dev/null)

(... truncated at 50KB, full content at ${qa_path})"
  else
    _cc_qa_content="$(cat "$qa_path" 2>/dev/null || echo "(not available)")"
  fi

  local _cc_plan_path="${wt_path}/.gaai/project/contexts/artefacts/plans/${SID}.execution-plan.md"
  if [[ -s "$_cc_plan_path" ]]; then
    _cc_plan_bytes=$(wc -c < "$_cc_plan_path" 2>/dev/null || echo 0)
    if (( _cc_plan_bytes > 51200 )); then
      _cc_plan_content="$(head -c 51200 "$_cc_plan_path" 2>/dev/null)

(... truncated at 50KB, full content at ${_cc_plan_path})"
    else
      _cc_plan_content="$(cat "$_cc_plan_path" 2>/dev/null || echo "(not available)")"
    fi
  else
    local _cc_plan_git
    _cc_plan_git=$(git -C "$wt_path" show "story/${SID}:.gaai/project/contexts/artefacts/plans/${SID}.execution-plan.md" 2>/dev/null || true)
    if [[ -n "$_cc_plan_git" ]]; then
      _cc_plan_content="$_cc_plan_git"
      _cc_plan_bytes=$(printf '%s' "$_cc_plan_git" | wc -c)
    else
      _cc_plan_content="(prior execution-plan not available — produce a fresh plan informed by qa-report only)"
      _cc_plan_bytes=0
    fi
  fi

  local _cc_impl_path="${wt_path}/.gaai/project/contexts/artefacts/impl-reports/${SID}.impl-report.md"
  if [[ -s "$_cc_impl_path" ]]; then
    _cc_impl_bytes=$(wc -c < "$_cc_impl_path" 2>/dev/null || echo 0)
    _cc_impl_content="$(cat "$_cc_impl_path" 2>/dev/null || echo "(not available)")"
  else
    local _cc_impl_git
    _cc_impl_git=$(git -C "$wt_path" show "story/${SID}:.gaai/project/contexts/artefacts/impl-reports/${SID}.impl-report.md" 2>/dev/null || true)
    if [[ -n "$_cc_impl_git" ]]; then
      _cc_impl_content="$_cc_impl_git"
      _cc_impl_bytes=$(printf '%s' "$_cc_impl_git" | wc -c)
    else
      _cc_impl_content="(prior impl-report not available)"
      _cc_impl_bytes=0
    fi
  fi

  {
    printf '\n## Prior cycle QA findings\n\n%s\n' "$_cc_qa_content"
    printf '\n## Prior execution-plan\n\n%s\n' "$_cc_plan_content"
    printf '\n## Prior impl-report\n\n%s\n' "$_cc_impl_content"
    printf '%s\n' '
## Delta-aware planning instruction

You are re-planning after a prior cycle that partially implemented this story.
The qa-report above identifies what failed. Mark each step in your plan with
EXACTLY ONE of the following markers:

  ✓ KEEP    — Prior step implemented correctly and qa-report verified the AC.
               Do NOT touch those files. Assert they are unchanged.
  ↻ REVISE  — Prior step was implemented but the qa-report identified a defect.
               Specify the corrective action in one line.
  + NEW     — Additional step required (gap found during re-plan).
               Implement from scratch.

Justify each marker in one line. Err toward REVISE over KEEP when uncertain.'
  } >> "$prompt_file" 2>/dev/null
}

# ── Helper: test Section 4b gate ───────────────────────────────────────────────
# Returns 0 if Section 4b would trigger, 1 if skipped.
test_section_4b_gate() {
  local qa_path="$1" phase="${2:-}"
  # Simulate the gate condition from daemon-prompt-construct.sh line 336
  if [[ -n "${qa_path:-}" && -f "$qa_path" && -s "$qa_path" && "${phase:-impl}" == "impl" ]]; then
    return 0
  else
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Cross-cycle qa-report injection tests ==="
echo ""

extract_helper

# ── T1: FAIL+route=plan (DEC-200 D5) → phase=plan, PLAN block appended ─────────
run_t1() {
  echo "T1: FAIL+route=plan → phase=plan, PLAN block with all artefacts"
  local wt="$FIXTURE_DIR/t1-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "FAIL" "true"
  make_plan "$wt"
  make_impl_report "$wt"
  make_story_with_inventory "$wt" "src/thing.ts"
  make_qa_verdict_sidecar "$wt" "FAIL" "plan" "src/thing.ts"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  local path phase verdict replan
  path=$(printf '%s' "$out" | head -1)
  phase=$(printf '%s' "$out" | sed -n '2p')
  verdict=$(printf '%s' "$out" | sed -n '3p')
  replan=$(printf '%s' "$out" | sed -n '4p')

  [[ "$phase" == "plan" ]] && pass "T1: phase=plan" || fail "T1: expected phase=plan got='$phase'"
  [[ "$verdict" == "FAIL" ]] && pass "T1: verdict=FAIL" || fail "T1: expected verdict=FAIL got='$verdict'"
  [[ "$replan" == "true" ]] && pass "T1: replan=true" || fail "T1: expected replan=true got='$replan'"

  local prompt="$FIXTURE_DIR/t1-prompt.txt"
  echo "BASE PLAN PROMPT" > "$prompt"
  inject_plan_block "$path" "$wt" "$prompt"

  grep -q "^## Prior cycle QA findings" "$prompt" && pass "T1: QA findings header present" || fail "T1: QA findings header missing"
  grep -q "^## Prior execution-plan" "$prompt" && pass "T1: prior plan header present" || fail "T1: prior plan header missing"
  grep -q "^## Prior impl-report" "$prompt" && pass "T1: impl-report header present" || fail "T1: impl-report header missing"
  grep -q "Delta-aware planning instruction" "$prompt" && pass "T1: delta-aware framing present" || fail "T1: delta-aware framing missing"
  grep -q "✓ KEEP" "$prompt" && pass "T1: KEEP marker present" || fail "T1: KEEP marker missing"
}

# ── T2: FAIL+route=impl (DEC-200 D5) → phase=impl, Section 4b triggers ────────
run_t2() {
  echo "T2: FAIL+route=impl → phase=impl, Section 4b triggers"
  local wt="$FIXTURE_DIR/t2-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "FAIL" "false"
  make_qa_verdict_sidecar "$wt" "FAIL" "impl"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  local phase verdict replan
  phase=$(printf '%s' "$out" | sed -n '2p')
  verdict=$(printf '%s' "$out" | sed -n '3p')
  replan=$(printf '%s' "$out" | sed -n '4p')

  [[ "$phase" == "impl" ]] && pass "T2: phase=impl" || fail "T2: expected phase=impl got='$phase'"
  [[ "$verdict" == "FAIL" ]] && pass "T2: verdict=FAIL" || fail "T2: expected verdict=FAIL got='$verdict'"
  [[ "$replan" == "false" ]] && pass "T2: replan=false" || fail "T2: expected replan=false got='$replan'"

  local qa_path
  qa_path=$(printf '%s' "$out" | head -1)
  test_section_4b_gate "$qa_path" "impl" && pass "T2: Section 4b gate triggers" || fail "T2: Section 4b gate did not trigger"
}

# ── T3: legacy Markdown-only report, no sidecar → no injection (DEC-200 D7) ────
# Repurposed (E1096S02): once JSON is the sole source of truth for a VALID
# cycle, "FAIL without replan_required field" no longer applies — a Markdown-
# only report (no qa-verdict.json) is exactly the currentness-rerun case.
# _resolve_cross_cycle_qa_report defers to the dispatch-side currentness gate
# (see daemon-state-machine.test.sh QARERUN-*) rather than injecting here.
run_t3() {
  echo "T3: legacy Markdown-only report (no sidecar) → no injection"
  local wt="$FIXTURE_DIR/t3-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "FAIL" ""

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)

  [[ -z "$out" ]] && pass "T3: no output (no sidecar -> currentness gate owns this, not injection)" || fail "T3: expected no output got='$out'"
}

# ── T4: ESCALATE → phase=plan ──────────────────────────────────────────────────
run_t4() {
  echo "T4: ESCALATE → phase=plan"
  local wt="$FIXTURE_DIR/t4-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "ESCALATE"
  make_qa_verdict_sidecar "$wt" "ESCALATE"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  local phase verdict replan
  phase=$(printf '%s' "$out" | sed -n '2p')
  verdict=$(printf '%s' "$out" | sed -n '3p')
  replan=$(printf '%s' "$out" | sed -n '4p')

  [[ "$phase" == "plan" ]] && pass "T4: phase=plan" || fail "T4: expected phase=plan got='$phase'"
  [[ "$verdict" == "ESCALATE" ]] && pass "T4: verdict=ESCALATE" || fail "T4: expected verdict=ESCALATE got='$verdict'"
  # E1096S02: JSON-sourced replan_required is always a literal token (null/true/false),
  # never truly absent the way an unparsed Markdown field could be.
  [[ "$replan" == "null" ]] && pass "T4: replan=null" || fail "T4: expected replan=null got='$replan'"

  local qa_path
  qa_path=$(printf '%s' "$out" | head -1)
  test_section_4b_gate "$qa_path" "plan" && fail "T4: Section 4b should NOT trigger for plan" || pass "T4: Section 4b correctly skipped for plan"
}

# ── T5: PASS → no env exported, no injection ───────────────────────────────────
run_t5() {
  echo "T5: PASS → no injection"
  local wt="$FIXTURE_DIR/t5-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "PASS"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)

  [[ -z "$out" ]] && pass "T5: no output (no injection)" || fail "T5: expected no output got='$out'"
}

# ── T6: fresh story (no qa-report) → no env, prompt lacks Prior cycle header ──
run_t6() {
  echo "T6: fresh story — no qa-report, semantic property"
  local wt="$FIXTURE_DIR/t6-wt"
  mkdir -p "$wt"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)

  [[ -z "$out" ]] && pass "T6: no output" || fail "T6: expected no output got='$out'"

  local prompt="$FIXTURE_DIR/t6-prompt.txt"
  echo "BASE PLAN PROMPT" > "$prompt"
  ! grep -q "^## Prior cycle QA findings" "$prompt" && pass "T6: semantic property — no Prior cycle QA findings header" || fail "T6: unexpected Prior cycle QA findings header in prompt"
}

# ── T7: qa-report 60KB → truncation marker ─────────────────────────────────────
run_t7() {
  echo "T7: 60KB qa-report → truncation marker"
  local wt="$FIXTURE_DIR/t7-wt"
  mkdir -p "$wt"
  make_large_qa_report "$wt"
  make_plan "$wt"
  make_impl_report "$wt"
  # ESCALATE (not route=plan) keeps this fixture simple — T7's assertions are
  # about prompt truncation/size, not route selection (route=plan is covered
  # by T1; ESCALATE forces phase=plan the same way, per DEC-200 D5).
  make_qa_verdict_sidecar "$wt" "ESCALATE"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  local path phase
  path=$(printf '%s' "$out" | head -1)
  phase=$(printf '%s' "$out" | sed -n '2p')

  [[ "$phase" == "plan" ]] && pass "T7: phase=plan" || fail "T7: expected phase=plan got='$phase'"

  local prompt="$FIXTURE_DIR/t7-prompt.txt"
  echo "BASE PLAN PROMPT" > "$prompt"
  inject_plan_block "$path" "$wt" "$prompt"

  grep -q "truncated at 50KB" "$prompt" && pass "T7: truncation marker present" || fail "T7: truncation marker missing"
  local prompt_size
  prompt_size=$(wc -c < "$prompt")
  (( prompt_size < 204800 )) && pass "T7: prompt within 200KB bound" || fail "T7: prompt exceeds 200KB (${prompt_size} bytes)"
}

# ── T8: FAIL+replan_required=true, no worktree plan → git show fallback ────────
run_t8() {
  echo "T8: FAIL+replan_required=true, no worktree plan → git show fallback"
  local wt="$FIXTURE_DIR/t8-wt"
  setup_git_repo_with_plan "$wt"
  make_qa_report "$wt" "FAIL" "true"
  make_impl_report "$wt"
  # ESCALATE keeps this fixture simple — T8 tests the git-show plan-content
  # fallback (inject_plan_block), not route selection (see T1 for route=plan).
  make_qa_verdict_sidecar "$wt" "ESCALATE"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  local path phase
  path=$(printf '%s' "$out" | head -1)
  phase=$(printf '%s' "$out" | sed -n '2p')

  [[ "$phase" == "plan" ]] && pass "T8: phase=plan" || fail "T8: expected phase=plan got='$phase'"

  local prompt="$FIXTURE_DIR/t8-prompt.txt"
  echo "BASE PLAN PROMPT" > "$prompt"
  inject_plan_block "$path" "$wt" "$prompt"

  grep -q "## Prior execution-plan" "$prompt" && pass "T8: prior execution-plan header present" || fail "T8: prior execution-plan header missing"
  grep -q "Plan via git" "$prompt" && pass "T8: plan content from git show" || fail "T8: plan content not from git show"
}

# ── T9: E160S14 integration — qa-report absent after drift delete ──────────────
run_t9() {
  echo "T9: sibling-story integration — qa-report deleted (drift simulated)"
  local wt="$FIXTURE_DIR/t9-wt"
  mkdir -p "$wt"

  local out
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)

  [[ -z "$out" ]] && pass "T9: no output (behaves as fresh story)" || fail "T9: expected no output got='$out'"

  local prompt="$FIXTURE_DIR/t9-prompt.txt"
  echo "BASE PLAN PROMPT" > "$prompt"
  ! grep -q "^## Prior cycle QA findings" "$prompt" && pass "T9: semantic property holds (same as T6)" || fail "T9: unexpected Prior cycle QA findings header"
}

# ── T10: restart-before/after-QA parity (AC6) ──────────────────────────────────
# Same fixture files on disk, two independent invocations (simulating a daemon
# restart between them) — the resolver is a pure function of on-disk state, so
# both calls must return byte-identical output.
run_t10() {
  echo "T10: restart-before/after-QA parity — two independent resolves agree"
  local wt="$FIXTURE_DIR/t10-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "FAIL" "false"
  make_qa_verdict_sidecar "$wt" "FAIL" "impl"

  local out1 out2
  out1=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  out2=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)

  [[ "$out1" == "$out2" ]] && pass "T10: restart parity — identical output across two independent resolves" \
    || fail "T10: outputs diverged — out1='$out1' out2='$out2'"
}

# ── T11: sidecar present but internally invalid → no injection, no throw ──────
# Fail-open on injection only: the dispatch-side currentness/QA_HANDOFF_INVALID
# gates (daemon-dispatch.sh), not this function, own rejecting an invalid
# handoff — this function only ever decides PLAN-prompt content.
run_t11() {
  echo "T11: sidecar present but invalid (verdict disagrees with axes) → no injection"
  local wt="$FIXTURE_DIR/t11-wt"
  mkdir -p "$wt"
  make_qa_report "$wt" "FAIL" "false"
  local qa_dir="${wt}/.gaai/project/contexts/artefacts/qa-reports"
  mkdir -p "$qa_dir"
  # plan_conformance=PASS + sota=PASS derives aggregate PASS, but verdict
  # claims FAIL — an internally inconsistent (invalid) handoff.
  printf '{"schema_version":1,"story_id":"%s","evaluated_as_of":"2026-08-07T00:00:00Z","state_of_the_art_conformance":"PASS","plan_conformance":"PASS","changed_surface_inventory":[],"findings":[],"evidence":[],"verdict":"FAIL","remediation_route":"impl","replan_required":false,"report_path":"qa-reports/%s.qa-report.md"}' \
    "$SID" "$SID" > "${qa_dir}/${SID}.qa-verdict.json"

  local out rc
  out=$(_resolve_cross_cycle_qa_report "$SID" "$wt" 2>/dev/null)
  rc=$?

  [[ "$rc" -eq 0 ]] && pass "T11: no throw (rc=0)" || fail "T11: unexpected non-zero rc=$rc"
  [[ -z "$out" ]] && pass "T11: no output (invalid handoff -> no injection)" || fail "T11: expected no output got='$out'"
}

# ── T12: prior local-admission evidence (Section 4c) ────────────
# Runs the real daemon-prompt-construct.sh (not a stub) with GAAI_ADMISSION_EVIDENCE_*
# set, and asserts the receipt-bearing and receipt-absent blocks' content before
# comparing bytes. Also checks: retained-receipt path stays outside the candidate
# worktree; the block is byte-identical whether or not SECONDARY_ROUTE (the
# claude/codex-equivalent routing knob this constructor exposes) is set; and an
# empty GAAI_ADMISSION_EVIDENCE_STATE reproduces today's output exactly.
run_t12() {
  echo "T12: prior local-admission evidence"
  local wt="$FIXTURE_DIR/t12-wt"
  mkdir -p "$wt"
  make_story_with_inventory "$wt" "some/file.ts"
  local story_path="${wt}/.gaai/project/contexts/artefacts/stories/${SID}.story.md"
  local plan_path="${wt}/.gaai/project/contexts/artefacts/plans/${SID}.execution-plan.md"
  mkdir -p "$(dirname "$plan_path")"
  echo "# Plan" > "$plan_path"
  local retained_receipt="${FIXTURE_DIR}/locks/.admission-retained-receipt-${SID}-pre_qa.json"

  local out_receipt
  out_receipt=$(GAAI_STORY_ID="$SID" GAAI_STORY_PATH="$story_path" GAAI_PLAN_PATH="$plan_path" \
    GAAI_WORKSPACE_PATH="$wt" PROJECT_DIR="$PROJECT_DIR" \
    GAAI_ADMISSION_EVIDENCE_STATE=receipt GAAI_ADMISSION_EVIDENCE_BOUNDARY=pre_qa \
    GAAI_ADMISSION_EVIDENCE_OUTCOME=blocked:command_failed \
    GAAI_ADMISSION_EVIDENCE_RESULTS="c1:failed:1" \
    GAAI_ADMISSION_EVIDENCE_RECEIPT="$retained_receipt" \
    bash "$PROMPT_LIB" 2>/dev/null)
  local rc1=$?
  [[ "$rc1" -eq 0 ]] && pass "T12: receipt-state exits 0" || fail "T12: receipt-state exited $rc1"
  grep -q "boundary: pre_qa" <<<"$out_receipt" && pass "T12: receipt-state renders boundary" || fail "T12: receipt-state missing boundary"
  grep -q "outcome: blocked:command_failed" <<<"$out_receipt" && pass "T12: receipt-state renders outcome" || fail "T12: receipt-state missing outcome"
  grep -q "c1:failed:1" <<<"$out_receipt" && pass "T12: receipt-state renders non-passing result" || fail "T12: receipt-state missing result"
  grep -qF "$retained_receipt" <<<"$out_receipt" && pass "T12: receipt-state renders retained receipt path" || fail "T12: receipt-state missing retained path"
  # Scope the containment check to the admission-evidence block itself — the
  # wider prompt legitimately mentions $wt/ elsewhere (NOTES_PATH etc).
  local receipt_block
  receipt_block=$(sed -n '/^=== PRIOR LOCAL ADMISSION FAILURE/,/^=== END PRIOR LOCAL ADMISSION FAILURE ===$/p' <<<"$out_receipt")
  if grep -qF "${wt}/" <<<"$receipt_block"; then
    fail "T12: retained receipt path leaked into the candidate worktree"
  else
    pass "T12: retained receipt path stays outside the candidate worktree"
  fi
  # Full containment check per the Story's own test requirement: not merely
  # "outside the candidate" but specifically "inside the lock directory" —
  # the two are independent claims (a path could be outside the worktree and
  # still not be under LOCK_DIR, e.g. /tmp or the repo root).
  if [[ "$retained_receipt" == "${FIXTURE_DIR}/locks/"* ]] && grep -qF "$retained_receipt" <<<"$receipt_block"; then
    pass "T12: retained receipt path lies inside the lock directory"
  else
    fail "T12: retained receipt path is not inside the lock directory (got: $retained_receipt)"
  fi

  local out_unavail
  out_unavail=$(GAAI_STORY_ID="$SID" GAAI_STORY_PATH="$story_path" GAAI_PLAN_PATH="$plan_path" \
    GAAI_WORKSPACE_PATH="$wt" PROJECT_DIR="$PROJECT_DIR" \
    GAAI_ADMISSION_EVIDENCE_STATE=unavailable GAAI_ADMISSION_EVIDENCE_BOUNDARY=pre_qa \
    GAAI_ADMISSION_EVIDENCE_OUTCOME=blocked:empty_candidate_diff \
    GAAI_ADMISSION_EVIDENCE_REASON=blocked:empty_candidate_diff \
    bash "$PROMPT_LIB" 2>/dev/null)
  grep -q "evidence=unavailable reason=blocked:empty_candidate_diff" <<<"$out_unavail" \
    && pass "T12: unavailable-state renders the typed reason" || fail "T12: unavailable-state missing reason"
  local unavail_block
  unavail_block=$(sed -n '/^=== PRIOR LOCAL ADMISSION FAILURE/,/^=== END PRIOR LOCAL ADMISSION FAILURE ===$/p' <<<"$out_unavail")
  if grep -qE '^  - ' <<<"$unavail_block"; then
    fail "T12: unavailable-state fabricated a non-passing result line"
  else
    pass "T12: unavailable-state fabricates no result fields"
  fi

  local out_receipt_route2
  out_receipt_route2=$(GAAI_STORY_ID="$SID" GAAI_STORY_PATH="$story_path" GAAI_PLAN_PATH="$plan_path" \
    GAAI_WORKSPACE_PATH="$wt" PROJECT_DIR="$PROJECT_DIR" SECONDARY_ROUTE=true GAAI_STORY_TIER=2 \
    GAAI_ADMISSION_EVIDENCE_STATE=receipt GAAI_ADMISSION_EVIDENCE_BOUNDARY=pre_qa \
    GAAI_ADMISSION_EVIDENCE_OUTCOME=blocked:command_failed \
    GAAI_ADMISSION_EVIDENCE_RESULTS="c1:failed:1" \
    GAAI_ADMISSION_EVIDENCE_RECEIPT="$retained_receipt" \
    bash "$PROMPT_LIB" 2>/dev/null)
  local block1 block2
  block1=$(sed -n '/^=== PRIOR LOCAL ADMISSION FAILURE/,/^=== END PRIOR LOCAL ADMISSION FAILURE ===$/p' <<<"$out_receipt")
  block2=$(sed -n '/^=== PRIOR LOCAL ADMISSION FAILURE/,/^=== END PRIOR LOCAL ADMISSION FAILURE ===$/p' <<<"$out_receipt_route2")
  [[ -n "$block1" && "$block1" == "$block2" ]] \
    && pass "T12: admission-evidence block is byte-identical regardless of SECONDARY_ROUTE/tier" \
    || fail "T12: admission-evidence block differs across route settings"

  local out_empty out_noenv
  out_empty=$(GAAI_STORY_ID="$SID" GAAI_STORY_PATH="$story_path" GAAI_PLAN_PATH="$plan_path" \
    GAAI_WORKSPACE_PATH="$wt" PROJECT_DIR="$PROJECT_DIR" GAAI_ADMISSION_EVIDENCE_STATE="" \
    bash "$PROMPT_LIB" 2>/dev/null)
  out_noenv=$(GAAI_STORY_ID="$SID" GAAI_STORY_PATH="$story_path" GAAI_PLAN_PATH="$plan_path" \
    GAAI_WORKSPACE_PATH="$wt" PROJECT_DIR="$PROJECT_DIR" \
    bash "$PROMPT_LIB" 2>/dev/null)
  [[ "$out_empty" == "$out_noenv" ]] \
    && pass "T12: empty GAAI_ADMISSION_EVIDENCE_STATE reproduces today's output byte-for-byte" \
    || fail "T12: empty-state output differs from the no-env baseline"
}

# ══════════════════════════════════════════════════════════════════════════════

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11
run_t12

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Results ==="
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "  OVERALL: FAIL"
  exit 1
fi
echo "  OVERALL: PASS"
exit 0
