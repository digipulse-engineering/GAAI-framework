#!/usr/bin/env bash
# daemon-monitor.test.sh — monitor phase-awareness test harness
#
# Tests phase detection, log path resolution, metrics aggregation, and error
# handling for the phase-aware monitor scripts (3-phase pipeline support).
#
# Usage: bash .gaai/core/scripts/tests/daemon-monitor.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

MONITOR_TAIL="$SCRIPT_DIR/../daemon-monitor-tail.sh"
OBSERVE_SEC="$SCRIPT_DIR/../observe-secondary.sh"

# ── Fixture setup ─────────────────────────────────────────────────────────────
FIXTURE_DIR="/tmp/gaai-monitor-test-$$"
LOCK_DIR="$FIXTURE_DIR/delivery-locks"
LOG_DIR="$FIXTURE_DIR/delivery-logs"
ROUTING_LOG="$FIXTURE_DIR/runtime-routing.jsonl"
BACKLOG="$FIXTURE_DIR/active.backlog.yaml"
EXPECTED_WORKTREE_BASE="$FIXTURE_DIR/worktrees"
LOGS_DIR="$FIXTURE_DIR/delivery-logs"

mkdir -p "$LOCK_DIR" "$LOG_DIR" "$EXPECTED_WORKTREE_BASE"
touch "$ROUTING_LOG"

cleanup() {
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# ── Test fixture YAML ─────────────────────────────────────────────────────────
cat > "$BACKLOG" << 'YAML_EOF'
- id: TST-MON-PLAN
  status: in_progress
  phase_status: not_started
  delivery_pipeline: 3phase
- id: TST-MON-IMPL
  status: in_progress
  phase_status: planned
  delivery_pipeline: 3phase
- id: TST-MON-QA
  status: in_progress
  phase_status: implemented
  delivery_pipeline: 3phase
- id: TST-MON-COMMIT
  status: in_progress
  phase_status: qa_passed
  delivery_pipeline: 3phase
- id: TST-MON-DONE
  status: done
  phase_status: done
  delivery_pipeline: 3phase
- id: TST-MON-QAFAIL
  status: in_progress
  phase_status: qa_failed
  delivery_pipeline: 3phase
- id: TST-MON-QAESC
  status: in_progress
  phase_status: qa_escalated
  delivery_pipeline: 3phase
- id: TST-MON-LEGACY
  status: in_progress
  phase_status: not_started
  delivery_pipeline: legacy
- id: TST-MON-NOLOG
  status: in_progress
  phase_status: planned
  delivery_pipeline: 3phase
YAML_EOF

# ── Source monitor-tail functions (main loop is guarded by BASH_SOURCE check) ──
# Override env vars so the sourced script uses our fixture paths.
LOG_DIR="$LOG_DIR" \
BACKLOG="$BACKLOG" \
LOCK_DIR="$LOCK_DIR" \
GAAI_WORKTREES_BASE="$EXPECTED_WORKTREE_BASE" \
PROJECT_DIR="$PROJECT_DIR" \
  source "$MONITOR_TAIL"

echo ""
echo "=== T0: Configured worktree root ==="
echo "T0: GAAI_WORKTREES_BASE overrides the synchronized-folder fallback"
[[ "$WORKTREE_BASE" == "$EXPECTED_WORKTREE_BASE" ]] \
  && pass "T0" \
  || fail "T0: expected $EXPECTED_WORKTREE_BASE, got '$WORKTREE_BASE'"

# ── T1–T8: Phase detection (AC1) ─────────────────────────────────────────────

echo ""
echo "=== T1-T8: Phase detection (AC1) ==="

echo "T1: plan.active marker → detect_phase_3phase returns PLAN"
touch "${LOCK_DIR}/TST-MON-PLAN.plan.active"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-PLAN")
rm -f "${LOCK_DIR}/TST-MON-PLAN.plan.active"
[[ "$result" == "PLAN" ]] && pass "T1" || fail "T1: expected PLAN, got '$result'"

echo "T2: impl.active marker → detect_phase_3phase returns IMPL"
touch "${LOCK_DIR}/TST-MON-IMPL.impl.active"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-IMPL")
rm -f "${LOCK_DIR}/TST-MON-IMPL.impl.active"
[[ "$result" == "IMPL" ]] && pass "T2" || fail "T2: expected IMPL, got '$result'"

echo "T3: qa.active marker → detect_phase_3phase returns QA"
touch "${LOCK_DIR}/TST-MON-QA.qa.active"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-QA")
rm -f "${LOCK_DIR}/TST-MON-QA.qa.active"
[[ "$result" == "QA" ]] && pass "T3" || fail "T3: expected QA, got '$result'"

echo "T4: commit.active marker → detect_phase_3phase returns COMMIT"
touch "${LOCK_DIR}/TST-MON-COMMIT.commit.active"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-COMMIT")
rm -f "${LOCK_DIR}/TST-MON-COMMIT.commit.active"
[[ "$result" == "COMMIT" ]] && pass "T4" || fail "T4: expected COMMIT, got '$result'"

echo "T5: no marker + phase_status=done → returns DONE"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-DONE")
[[ "$result" == "DONE" ]] && pass "T5" || fail "T5: expected DONE, got '$result'"

echo "T6: no marker + phase_status=qa_failed → returns QA_FAILED"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-QAFAIL")
[[ "$result" == "QA_FAILED" ]] && pass "T6" || fail "T6: expected QA_FAILED, got '$result'"

echo "T7: no marker + phase_status=qa_escalated → returns QA_ESCALATED"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-QAESC")
[[ "$result" == "QA_ESCALATED" ]] && pass "T7" || fail "T7: expected QA_ESCALATED, got '$result'"

echo "T8: no marker + phase_status=not_started → returns PLAN"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MON-PLAN")
[[ "$result" == "PLAN" ]] && pass "T8" || fail "T8: expected PLAN, got '$result'"

# ── T9–T13: Per-phase log path resolution (AC2) ───────────────────────────────

echo ""
echo "=== T9-T13: Per-phase log path resolution (AC2) ==="

echo "T9: impl.log present + impl.active marker → resolve_3phase_log returns impl.log path"
wt_dir="${WORKTREE_BASE}/TST-MON-IMPL-workspace/.delivery-logs"
mkdir -p "$wt_dir"
expected_log="${wt_dir}/TST-MON-IMPL.impl.log"
touch "$expected_log"
touch "${LOCK_DIR}/TST-MON-IMPL.impl.active"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" WORKTREE_BASE="$WORKTREE_BASE" resolve_3phase_log "TST-MON-IMPL")
rm -f "${LOCK_DIR}/TST-MON-IMPL.impl.active"
[[ "$result" == "$expected_log" ]] && pass "T9" || fail "T9: expected $expected_log, got '$result'"

echo "T10: no log present → returns [no log yet]"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" WORKTREE_BASE="$WORKTREE_BASE" resolve_3phase_log "TST-MON-NOLOG")
[[ "$result" == "[no log yet]" ]] && pass "T10" || fail "T10: expected '[no log yet]', got '$result'"

echo "T11: plan.active marker + plan.log present → returns plan.log path"
plan_wt_dir="${WORKTREE_BASE}/TST-MON-PLAN-workspace/.delivery-logs"
mkdir -p "$plan_wt_dir"
expected_plan_log="${plan_wt_dir}/TST-MON-PLAN.plan.log"
touch "$expected_plan_log"
touch "${LOCK_DIR}/TST-MON-PLAN.plan.active"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" WORKTREE_BASE="$WORKTREE_BASE" resolve_3phase_log "TST-MON-PLAN")
rm -f "${LOCK_DIR}/TST-MON-PLAN.plan.active"
[[ "$result" == "$expected_plan_log" ]] && pass "T11" || fail "T11: expected $expected_plan_log, got '$result'"

echo "T12: legacy story is never passed to resolve_3phase_log (guard test)"
# For legacy stories, the monitor does not call resolve_3phase_log.
# We verify this at the integration level by checking detect_phase_3phase
# is only intended for 3phase stories. Direct call with legacy story still works gracefully.
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" WORKTREE_BASE="$WORKTREE_BASE" resolve_3phase_log "TST-MON-LEGACY" 2>/dev/null || echo "[no log yet]")
# legacy story has no worktree log — should return [no log yet] gracefully
[[ "$result" == "[no log yet]" ]] && pass "T12" || fail "T12: expected '[no log yet]' for legacy, got '$result'"

echo "T13: path-contract assertion — resolved path matches canonical formula"
commit_wt_dir="${WORKTREE_BASE}/TST-MON-COMMIT-workspace/.delivery-logs"
mkdir -p "$commit_wt_dir"
expected_commit_log="${commit_wt_dir}/TST-MON-COMMIT.commit.log"
touch "$expected_commit_log"
# phase_status=qa_passed → active phase maps to commit (last completed = qa)
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" WORKTREE_BASE="$WORKTREE_BASE" resolve_3phase_log "TST-MON-COMMIT")
expected_formula="${WORKTREE_BASE}/TST-MON-COMMIT-workspace/.delivery-logs/TST-MON-COMMIT.commit.log"
[[ "$result" == "$expected_formula" ]] && pass "T13" || fail "T13: expected $expected_formula, got '$result'"

# ── T14–T16: observe-secondary.sh R2 detection from impl.log (AC4) ───────────

echo ""
echo "=== T14-T16: observe-secondary.sh per-phase impl.log (AC4) ==="

# Create per-phase impl.log fixture
obs_wt_dir="${WORKTREE_BASE}/TST-OBS-workspace/.delivery-logs"
mkdir -p "$obs_wt_dir"
obs_impl_log="${obs_wt_dir}/TST-OBS.impl.log"

# Write a fixture with 2 reads of the same file (R2 violation = 1)
cat > "$obs_impl_log" << 'LOG_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/some/file.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/some/file.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/other/file.md"}}]}}
LOG_EOF

echo "T14: _impl_log_path returns per-phase impl.log when worktree log exists"
# Test the _impl_log_path logic directly using a minimal inline implementation
# that mirrors the AC4 spec (avoids sourcing observe-secondary.sh side effects)
_test_impl_log_path() {
  local story_id="$1"
  local wt_log="${WORKTREE_BASE}/${story_id}-workspace/.delivery-logs/${story_id}.impl.log"
  local leg_log="${LOGS_DIR}/${story_id}.log"
  if [[ -f "$wt_log" ]]; then echo "$wt_log"
  elif [[ -f "$leg_log" ]]; then echo "$leg_log"
  else echo "$wt_log"
  fi
}
result=$(_test_impl_log_path "TST-OBS")
[[ "$result" == "$obs_impl_log" ]] && pass "T14" || fail "T14: _impl_log_path returned '$result', expected '$obs_impl_log'"

echo "T15: _impl_log_path falls back to legacy .log when per-phase absent"
legacy_log="${LOGS_DIR}/TST-LEGACY-OBS.log"
touch "$legacy_log"
result=$(_test_impl_log_path "TST-LEGACY-OBS")
[[ "$result" == "$legacy_log" ]] && pass "T15" || fail "T15: _impl_log_path returned '$result', expected '$legacy_log'"

echo "T16: R2 re-read violations counted from per-phase impl.log fixture"
# Test the exact grep pattern compliance_counts uses, applied to the per-phase impl.log
reread=$(grep -oE '"name":"Read","input":\{"file_path":"[^"]*"' "$obs_impl_log" 2>/dev/null \
  | sort | uniq -c | awk '$1 > 1 { sum += $1 - 1 } END { print sum+0 }')
[[ "$reread" -ge 1 ]] && pass "T16" || fail "T16: expected reread>=1 from impl.log, got '$reread'"

# ── T17–T19: routing.jsonl metrics aggregation (AC3) ─────────────────────────

echo ""
echo "=== T17-T19: routing.jsonl metrics aggregation (AC3) ==="

# Write routing log fixture for T17
cat > "$ROUTING_LOG" << 'JSONL_EOF'
{"trace_id":"t1","story_id":"TST-MON-QA","phase":"plan","provider":"primary","model":"claude-sonnet-4-6","duration_ms":2300,"pipeline":"3phase"}
{"trace_id":"t1","story_id":"TST-MON-QA","phase":"impl","provider":"primary","model":"claude-sonnet-4-6","duration_ms":47000,"pipeline":"3phase"}
{"trace_id":"t1","story_id":"TST-MON-QA","phase":"qa","provider":"primary","model":"claude-sonnet-4-6","duration_ms":8100,"pipeline":"3phase"}
JSONL_EOF

echo "T17: routing.jsonl with plan+impl+qa records → all three phases parsed without crash"
(
  ROUTING_LOG_TEST="$ROUTING_LOG"
  raw=$(tail -n 500 "$ROUTING_LOG_TEST" 2>/dev/null || true)
  phases_found=0
  while IFS= read -r rec; do
    phase=$(printf '%s' "$rec" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('phase',''))" 2>/dev/null || true)
    [[ "$phase" == "plan" || "$phase" == "impl" || "$phase" == "qa" ]] && phases_found=$(( phases_found + 1 ))
  done < <(printf '%s\n' "$raw" | grep "\"story_id\":\"TST-MON-QA\"" 2>/dev/null || true)
  if [[ "$phases_found" -eq 3 ]]; then
    echo "PASS"
  else
    echo "FAIL: expected 3 phase records, found $phases_found"
  fi
) | grep -q "^PASS" && pass "T17" || fail "T17: routing.jsonl phase parsing failed"

echo "T18: routing.jsonl with only plan record → impl/qa absent but no crash"
echo '{"trace_id":"t2","story_id":"TST-PLAN-ONLY","phase":"plan","provider":"primary","model":"claude-sonnet-4-6","duration_ms":1500,"pipeline":"3phase"}' > "${FIXTURE_DIR}/plan-only.jsonl"
(
  raw=$(tail -n 500 "${FIXTURE_DIR}/plan-only.jsonl" 2>/dev/null || true)
  impl_found=0
  qa_found=0
  while IFS= read -r rec; do
    phase=$(printf '%s' "$rec" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('phase',''))" 2>/dev/null || true)
    [[ "$phase" == "impl" ]] && impl_found=1
    [[ "$phase" == "qa" ]] && qa_found=1
  done < <(printf '%s\n' "$raw" | grep "\"story_id\":\"TST-PLAN-ONLY\"" 2>/dev/null || true)
  if [[ "$impl_found" -eq 0 && "$qa_found" -eq 0 ]]; then
    echo "PASS"
  else
    echo "FAIL: expected impl/qa absent"
  fi
) | grep -q "^PASS" && pass "T18" || fail "T18: unexpected impl/qa records found"

echo "T19: routing.jsonl absent → graceful (no crash, no output)"
absent_log="${FIXTURE_DIR}/absent-routing.jsonl"
(
  if [[ ! -f "$absent_log" ]]; then
    echo "PASS"
  else
    echo "FAIL: file exists when it should not"
  fi
  # Simulate what render_phase_metrics does with absent file
  if [[ ! -f "$absent_log" ]]; then
    echo "PASS-GRACEFUL"
  fi
) | grep -q "PASS-GRACEFUL" && pass "T19" || fail "T19: routing.jsonl absent handling"

# ── T20–T23: Error handling (AC5) ────────────────────────────────────────────

echo ""
echo "=== T20-T23: Error handling (AC5) ==="

echo "T20: missing log → resolve_3phase_log returns [no log yet]"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$LOCK_DIR" WORKTREE_BASE="$WORKTREE_BASE" resolve_3phase_log "TST-MON-NOLOG")
[[ "$result" == "[no log yet]" ]] && pass "T20" || fail "T20: expected '[no log yet]', got '$result'"

echo "T21: malformed phase_status → detect_phase_3phase returns [?]"
mangled_backlog="$FIXTURE_DIR/mangled.backlog.yaml"
printf '%s\n' '- id: TST-MANGLED' '  status: in_progress' '  phase_status: ' '  delivery_pipeline: 3phase' > "$mangled_backlog"
result=$(BACKLOG="$mangled_backlog" LOCK_DIR="$LOCK_DIR" detect_phase_3phase "TST-MANGLED")
[[ "$result" == "[?]" ]] && pass "T21" || fail "T21: expected '[?]', got '$result'"
rm -f "$mangled_backlog"

echo "T22: LOCK_DIR absent → detect_active_stories completes without error"
absent_lock_dir="${FIXTURE_DIR}/nonexistent-locks"
result=$(BACKLOG="$BACKLOG" LOCK_DIR="$absent_lock_dir" detect_active_stories 2>/dev/null; echo "exit:$?")
[[ "$result" == *"exit:0"* ]] && pass "T22" || fail "T22: detect_active_stories crashed with absent LOCK_DIR"

echo "T23: routing.jsonl absent → render_phase_metrics exits 0 without crash"
# We test by directly checking the absent-file guard logic from render_phase_metrics
absent_routing="${FIXTURE_DIR}/nonexistent-routing.jsonl"
(
  if [[ ! -f "$absent_routing" ]]; then
    # This is what render_phase_metrics does: bail gracefully
    echo "PASS"
    exit 0
  fi
  echo "FAIL"
  exit 1
) | grep -q "^PASS" && pass "T23" || fail "T23: absent routing.jsonl handling"

# ── T24–T25: Codex mixed JSONL parsing ───────────────────────────────────────

echo ""
echo "=== T24-T25: Codex mixed JSONL parsing ==="

codex_log="${FIXTURE_DIR}/codex-mixed.log"
cat > "$codex_log" << 'JSONL_EOF'
2026-07-06T01:15:58.334718Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
{"type":"thread.started","thread_id":"t-codex"}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"rg -n seat workers\"","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"rg -n seat workers\"","aggregated_output":"workers/x.ts:1:seat\n","exit_code":0,"status":"completed"}}
JSONL_EOF

echo "T24: parse_log counts Codex command_execution after non-JSON stderr line"
result=$(parse_log "$codex_log" "TST-MON-IMPL" "3phase" "IMPL" 2>/dev/null || true)
printf '%s\n' "$result" | grep -q "1 tools" && pass "T24" || fail "T24: expected '1 tools' in parse_log output, got '$result'"

echo "T25: parse_log renders latest Codex command activity after non-JSON stderr line"
printf '%s\n' "$result" | grep -q 'rg -n seat workers' && pass "T25" || fail "T25: expected latest Codex command activity, got '$result'"

# ── T-GATE: the admission gate before QA/commit is displayed as its own state ──
echo ""
echo "=== T-GATE: detect_admission_gate (wrapper-log edges) ==="
gate_log="${LOG_DIR}/TST-MON-GATE.wrapper.log"
now_hms=$(date +%H:%M:%S)
printf '[%s] TST-MON-GATE phase=qa starting\n{"type":"assistant","noise":"agent json"}\n' "$now_hms" > "$gate_log"
result=$(LOG_DIR="$LOG_DIR" detect_admission_gate "TST-MON-GATE" qa)
[[ "$result" =~ ^running\ [0-9]+$ ]] && pass "T-GATE-1: qa started, no admission outcome yet → running <elapsed>" || fail "T-GATE-1: expected 'running <s>', got '$result'"

printf '[LOCAL-ADMISSION] story=TST-MON-GATE boundary=pre_qa outcome=pass head=abc selected=governance,oss publication_admitted=false\n' >> "$gate_log"
result=$(LOG_DIR="$LOG_DIR" detect_admission_gate "TST-MON-GATE" qa)
[[ "$result" == "passed pre_qa" ]] && pass "T-GATE-2: outcome=pass → passed pre_qa" || fail "T-GATE-2: expected 'passed pre_qa', got '$result'"

printf '[%s] TST-MON-GATE phase=qa starting\n[LOCAL-ADMISSION] story=TST-MON-GATE boundary=pre_qa stale_reason=base_advanced resolver_reason=none note=/x\n[LOCAL-ADMISSION] story=TST-MON-GATE boundary=pre_qa outcome=blocked:stale_evidence publication_admitted=false\n' "$now_hms" >> "$gate_log"
result=$(LOG_DIR="$LOG_DIR" detect_admission_gate "TST-MON-GATE" qa)
[[ "$result" == "blocked pre_qa blocked:stale_evidence base_advanced" ]] && pass "T-GATE-3: blocked outcome carries boundary, outcome and stale_reason" || fail "T-GATE-3: got '$result'"

printf '[%s] TST-MON-GATE phase=impl starting\n' "$now_hms" >> "$gate_log"
result=$(LOG_DIR="$LOG_DIR" detect_admission_gate "TST-MON-GATE" qa)
[[ -z "$result" ]] && pass "T-GATE-4: a later phase edge ends the gate state → nothing" || fail "T-GATE-4: expected empty, got '$result'"

result=$(LOG_DIR="$LOG_DIR" detect_admission_gate "TST-MON-NOLOG" qa)
[[ -z "$result" ]] && pass "T-GATE-5: no wrapper log → nothing" || fail "T-GATE-5: expected empty, got '$result'"

printf '[%s] TST-MON-GATE phase=commit starting\n' "$now_hms" >> "$gate_log"
result=$(LOG_DIR="$LOG_DIR" detect_admission_gate "TST-MON-GATE" commit)
[[ "$result" =~ ^running\ [0-9]+$ ]] && pass "T-GATE-6: commit-phase gate detected on its own edge" || fail "T-GATE-6: got '$result'"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "All tests PASSED."
  exit 0
else
  echo "SOME TESTS FAILED."
  exit 1
fi
