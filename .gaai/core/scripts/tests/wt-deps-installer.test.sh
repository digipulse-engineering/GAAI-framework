#!/usr/bin/env bash
# wt-deps-installer.test.sh — unit tests for ensure_wt_dependencies_installed()
#
# Tests the 4 scenarios from AC5:
#   T1  : marker present → skip path (exit 0, 1 log event, no pnpm call)
#   T1b : timing ≤100ms on skip path
#   T2  : marker absent + mock pnpm exits 0 → success (exit 0, 3 log events)
#   T3  : marker absent + mock pnpm exits 1 → failure (exit non-zero, 3 log events, 1 routing-record)
#   T4  : idempotency re-entry after success → skip path again
#
# Usage: bash .gaai/core/scripts/tests/wt-deps-installer.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/../daemon-dispatch.sh"

# ── Fixture setup ──────────────────────────────────────────────────────────────
FIXTURE_DIR="/tmp/gaai-wt-deps-test-$$"
WT_PATH="$FIXTURE_DIR/worktree"
# Mirrors _wt_deps_marker_dir's default (pnpm's virtual store at the workspace
# root). Previously a hardcoded product path, which only ever existed in one repo.
MARKER_DIR="$WT_PATH/node_modules/.pnpm"
MOCK_BIN="$FIXTURE_DIR/bin"
PNPM_LOG="$FIXTURE_DIR/pnpm-calls.log"
ROUTING_LOG="$FIXTURE_DIR/routing-records.log"

mkdir -p "$MOCK_BIN" "$WT_PATH/node_modules"
touch "$PNPM_LOG" "$ROUTING_LOG"

cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT

# ── Mock pnpm binary ───────────────────────────────────────────────────────────
# Writes invocation args to PNPM_LOG, optionally creates marker dir, exits with MOCK_PNPM_EXIT_CODE.
cat > "$MOCK_BIN/pnpm" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "pnpm $*" >> "$PNPM_LOG"
echo "env COREPACK_ENABLE_DOWNLOAD_PROMPT=${COREPACK_ENABLE_DOWNLOAD_PROMPT:-unset}" >> "$PNPM_LOG"
if [[ -n "${MOCK_PNPM_CREATE_MARKER:-}" ]]; then
  mkdir -p "$MOCK_PNPM_CREATE_MARKER"
fi
exit "${MOCK_PNPM_EXIT_CODE:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/pnpm"

export PATH="$MOCK_BIN:$PATH"
export PNPM_LOG
export ROUTING_LOG

# ── Minimal daemon globals required by daemon-dispatch.sh ─────────────────────
BACKLOG_FILE="$FIXTURE_DIR/active.backlog.yaml"
SCHEDULER="$SCRIPT_DIR/../backlog-scheduler.sh"
PROJECT_DIR="$FIXTURE_DIR"
LOCK_DIR="$FIXTURE_DIR/delivery-locks"
mkdir -p "$LOCK_DIR"
touch "$BACKLOG_FILE"
export BACKLOG_FILE SCHEDULER PROJECT_DIR LOCK_DIR

# ── Source daemon-dispatch.sh (no top-level execution code) ───────────────────
# shellcheck source=/dev/null
source "$DISPATCH"

# ── Override _emit_plan_routing_record to capture to ROUTING_LOG ──────────────
# Must override AFTER sourcing so it shadows the real function.
_emit_plan_routing_record() {
  local story_id="$1" trace_id="$2" provider="$3" fallback_reason="$4" duration_ms="$5"
  echo "routing_record story_id=${story_id} trace_id=${trace_id} provider=${provider} fallback_reason=${fallback_reason} duration_ms=${duration_ms}" >> "$ROUTING_LOG"
}

# ── Helper: count lines in a string ───────────────────────────────────────────
line_count() {
  echo "$1" | grep -c '' || true
}

# ════════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T1: marker present → skip path ==="

mkdir -p "$MARKER_DIR"
> "$PNPM_LOG"
> "$ROUTING_LOG"

output=$(ensure_wt_dependencies_installed "T1-STORY" "T1-TRACE" "$WT_PATH")
rc=$?

if [[ $rc -eq 0 ]]; then
  pass "T1: exit 0"
else
  fail "T1: expected exit 0, got $rc"
fi

lc=$(line_count "$output")
if [[ $lc -eq 1 ]]; then
  pass "T1: exactly 1 log event"
else
  fail "T1: expected 1 log event, got $lc"
fi

if echo "$output" | grep -q "wt_deps_check marker_present=true"; then
  pass "T1: log contains wt_deps_check marker_present=true"
else
  fail "T1: missing wt_deps_check marker_present=true in: $output"
fi

pnpm_calls=$(wc -l < "$PNPM_LOG" | tr -d ' ')
if [[ "$pnpm_calls" -eq 0 ]]; then
  pass "T1: pnpm not invoked"
else
  fail "T1: pnpm was invoked $pnpm_calls times (expected 0)"
fi

routing_lines=$(wc -l < "$ROUTING_LOG" | tr -d ' ')
if [[ "$routing_lines" -eq 0 ]]; then
  pass "T1: no routing records emitted"
else
  fail "T1: expected 0 routing records, got $routing_lines"
fi

# ── T1b: timing ≤100ms ────────────────────────────────────────────────────────
echo ""
echo "=== T1b: skip path timing ≤100ms ==="

if [[ -n "${EPOCHREALTIME:-}" ]]; then
  t0=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  ensure_wt_dependencies_installed "T1b-STORY" "T1b-TRACE" "$WT_PATH" >/dev/null
  t1=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  elapsed=$(( t1 - t0 ))
  if [[ $elapsed -le 100 ]]; then
    pass "T1b: skip path elapsed ${elapsed}ms ≤ 100ms"
  else
    fail "T1b: skip path elapsed ${elapsed}ms > 100ms"
  fi
else
  echo "  WARN: EPOCHREALTIME unavailable (bash < 5) — T1b timing skipped"
fi

# ════════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T2: marker absent + mock pnpm exits 0 → success ==="

rm -rf "$MARKER_DIR"
> "$PNPM_LOG"
> "$ROUTING_LOG"
export MOCK_PNPM_CREATE_MARKER="$MARKER_DIR"
export MOCK_PNPM_EXIT_CODE=0

output=$(ensure_wt_dependencies_installed "T2-STORY" "T2-TRACE" "$WT_PATH")
rc=$?

if [[ $rc -eq 0 ]]; then
  pass "T2: exit 0"
else
  fail "T2: expected exit 0, got $rc"
fi

lc=$(line_count "$output")
if [[ $lc -eq 3 ]]; then
  pass "T2: exactly 3 log events"
else
  fail "T2: expected 3 log events, got $lc"
fi

line1=$(echo "$output" | sed -n '1p')
line2=$(echo "$output" | sed -n '2p')
line3=$(echo "$output" | sed -n '3p')

if echo "$line1" | grep -q "wt_deps_check marker_present=false"; then
  pass "T2: line 1 is wt_deps_check marker_present=false"
else
  fail "T2: line 1 unexpected: $line1"
fi

if echo "$line2" | grep -q "wt_deps_install_started"; then
  pass "T2: line 2 is wt_deps_install_started"
else
  fail "T2: line 2 unexpected: $line2"
fi

if echo "$line3" | grep -q "wt_deps_install_completed" && echo "$line3" | grep -q "duration_ms="; then
  pass "T2: line 3 is wt_deps_install_completed with duration_ms"
else
  fail "T2: line 3 unexpected: $line3"
fi

if [[ -d "$MARKER_DIR" ]]; then
  pass "T2: marker dir created by mock pnpm"
else
  fail "T2: marker dir not created"
fi

routing_lines=$(wc -l < "$ROUTING_LOG" | tr -d ' ')
if [[ "$routing_lines" -eq 0 ]]; then
  pass "T2: no routing records on success path"
else
  fail "T2: expected 0 routing records, got $routing_lines"
fi

# ════════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: marker absent + mock pnpm exits 1 → failure ==="

rm -rf "$MARKER_DIR"
> "$PNPM_LOG"
> "$ROUTING_LOG"
unset MOCK_PNPM_CREATE_MARKER
export MOCK_PNPM_EXIT_CODE=1

set +e
output=$(ensure_wt_dependencies_installed "T3-STORY" "T3-TRACE" "$WT_PATH")
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  pass "T3: exit non-zero ($rc)"
else
  fail "T3: expected non-zero exit, got 0"
fi

lc=$(line_count "$output")
if [[ $lc -eq 3 ]]; then
  pass "T3: exactly 3 log events"
else
  fail "T3: expected 3 log events, got $lc"
fi

line1=$(echo "$output" | sed -n '1p')
line2=$(echo "$output" | sed -n '2p')
line3=$(echo "$output" | sed -n '3p')

if echo "$line1" | grep -q "wt_deps_check marker_present=false"; then
  pass "T3: line 1 is wt_deps_check marker_present=false"
else
  fail "T3: line 1 unexpected: $line1"
fi

if echo "$line2" | grep -q "wt_deps_install_started"; then
  pass "T3: line 2 is wt_deps_install_started"
else
  fail "T3: line 2 unexpected: $line2"
fi

if echo "$line3" | grep -q "wt_deps_install_failed" && echo "$line3" | grep -q "exit_code=1"; then
  pass "T3: line 3 is wt_deps_install_failed with exit_code=1"
else
  fail "T3: line 3 unexpected: $line3"
fi

routing_lines=$(wc -l < "$ROUTING_LOG" | tr -d ' ')
if [[ "$routing_lines" -eq 1 ]]; then
  pass "T3: exactly 1 routing record emitted"
else
  fail "T3: expected 1 routing record, got $routing_lines"
fi

if grep -q "PNPM_INSTALL_FAILED" "$ROUTING_LOG"; then
  pass "T3: routing record contains PNPM_INSTALL_FAILED"
else
  fail "T3: routing record missing PNPM_INSTALL_FAILED (got: $(cat "$ROUTING_LOG"))"
fi

# ════════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: idempotency — re-entry after success ==="

# Marker was NOT created (T3 mock pnpm exited 1 without creating it)
# Recreate marker manually to simulate a resumed-WT scenario
mkdir -p "$MARKER_DIR"
> "$PNPM_LOG"
> "$ROUTING_LOG"
# Reset to success-exit just in case
export MOCK_PNPM_EXIT_CODE=0
unset MOCK_PNPM_CREATE_MARKER 2>/dev/null || true

output=$(ensure_wt_dependencies_installed "T4-STORY" "T4-TRACE" "$WT_PATH")
rc=$?

if [[ $rc -eq 0 ]]; then
  pass "T4: exit 0 on re-entry"
else
  fail "T4: expected exit 0, got $rc"
fi

lc=$(line_count "$output")
if [[ $lc -eq 1 ]]; then
  pass "T4: exactly 1 log event (skip path)"
else
  fail "T4: expected 1 log event, got $lc"
fi

if echo "$output" | grep -q "wt_deps_check marker_present=true"; then
  pass "T4: skip path taken on re-entry"
else
  fail "T4: expected skip path on re-entry, got: $output"
fi

pnpm_calls=$(wc -l < "$PNPM_LOG" | tr -d ' ')
if [[ "$pnpm_calls" -eq 0 ]]; then
  pass "T4: pnpm not invoked on re-entry"
else
  fail "T4: pnpm was invoked $pnpm_calls times on re-entry (expected 0)"
fi

# ════════════════════════════════════════════════════════════════════════════════
echo ""
# ── T9: the install answers Corepack's download prompt by policy ─────────────
# Under the daemon's private HOME, Corepack asks before downloading the pinned
# package manager. No one is there to answer, so the install must run with the
# prompt disabled or it blocks until the timeout and the phase never starts.
echo "T9: pnpm sees COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
: > "$PNPM_LOG"; rm -rf "$WT_PATH/node_modules"
ensure_wt_dependencies_installed "TST-T9" "trace-t9" "$WT_PATH" 5 >/dev/null 2>&1 || true
if grep -q '^env COREPACK_ENABLE_DOWNLOAD_PROMPT=0$' "$PNPM_LOG"; then
  pass "T9: the prompt is disabled for the unattended install"
else
  fail "T9: pnpm ran without the prompt disabled — $(grep '^env' "$PNPM_LOG" | tail -1)"
fi

echo "══════════════════════════════════════════════════"
echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "══════════════════════════════════════════════════"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
