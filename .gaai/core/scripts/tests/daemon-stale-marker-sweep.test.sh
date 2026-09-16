#!/usr/bin/env bash
# daemon-stale-marker-sweep.test.sh — regression tests for the stale
# active-spawn marker sweep and its placement in the daemon main loop.
#
# Covers: sweep_stale_active_markers() and the main-loop contract that the
# sweep — plus the idle-relevant housekeeping — runs on EVERY cycle, including
# the idle cycle (no ready Story) that ends in `sleep; continue` before the
# launch loop.
#
# Background: a wrapper killed mid-phase (SIGKILL, daemon crash, operator
# --stop) leaves $LOCK_DIR/<sid>.<phase>.active behind, and every relaunch path
# then holds the Story on it (outcome=blocked reason=effect_inhibited). The
# sweep used to sit after the ready-Story launch loop, so with nothing ready it
# never ran and the Story never relaunched — with no error anywhere.
#
# T1  no live wrapper session + marker older than the grace → removed, and one
#     log line names the story id, the phase and the age; the dead lock is
#     left for the relaunch path to retire
# T2  no live wrapper session + marker younger than the grace → left alone,
#     no log line
# T3  wrapper tmux session exists + marker older than the grace → left alone,
#     no log line
# T4  one real main-loop cycle with no ready Story removes the stale marker
#     before the first sleep, and both recovery scans of that same cycle
#     already observe it gone; a fresh marker survives the cycle
# T5  the idle-relevant housekeeping (cleanup-pending sweep, worktree prune,
#     merged-worktree reconcile, orphan reaper) also runs on that idle cycle
#
# Extraction contract (position-sensitive, like the other daemon suites):
#   - sweep_stale_active_markers() is extracted by name with brace-depth
#     tracking, so it may live anywhere in delivery-daemon.sh.
#   - The main loop is extracted from the "# ── Main loop" section header to
#     the end of the file. Every function the loop head calls before the idle
#     `continue` is stubbed below; a new call added to that head must get a
#     stub here, otherwise T4/T5 fail closed with "command not found".
#
# Usage: bash .gaai/core/scripts/tests/daemon-stale-marker-sweep.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }
portable_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$SCRIPT_DIR/../delivery-daemon.sh"

FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gaai-stale-marker-sweep-test.XXXXXX") || {
  echo "  FAIL: unable to create private temporary fixture root" >&2
  exit 1
}
chmod 700 "$FIXTURE_DIR"

FIXTURE_MODE=$(portable_mode "$FIXTURE_DIR" 2>/dev/null || true)
if [[ "$FIXTURE_MODE" == "700" ]]; then
  pass "FIXTURE: mktemp root is private"
else
  fail "FIXTURE: mktemp root is not mode 0700"
fi

cleanup() {
  [[ "${GAAI_KEEP_TEST_FIXTURES:-0}" == "1" ]] || rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# set_mtime_ago <path> <seconds>: portable mtime backdating (macOS touch has
# no -d @epoch form; python3 is already a daemon runtime dependency).
set_mtime_ago() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
path, ago = sys.argv[1], int(sys.argv[2])
t = time.time() - ago
os.utime(path, (t, t))
PY
}

# ── Extract the unit under test ───────────────────────────────────────────────
SWEEP_FN=$(awk '
  /^sweep_stale_active_markers\(\)/{p=1; depth=0}
  p {
    print
    for (i=1; i<=length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      if (c == "}") depth--
    }
    if (p && depth == 0 && NR > 1) { p=0 }
  }
' "$DAEMON")
if [[ "$SWEEP_FN" == sweep_stale_active_markers\(\)* && "$SWEEP_FN" == *$'\n}' ]]; then
  pass "EXTRACT: sweep_stale_active_markers() found in delivery-daemon.sh"
else
  fail "EXTRACT: sweep_stale_active_markers() not found in delivery-daemon.sh"
  echo "  (nothing else can be tested)"
  echo ""
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
  exit 1
fi

MAIN_LOOP=$(awk '/^# ── Main loop/{p=1} p{print}' "$DAEMON")
if [[ "$MAIN_LOOP" == *"while true; do"* && "$MAIN_LOOP" == *$'\ndone' ]]; then
  pass "EXTRACT: main loop found from the '# ── Main loop' header to end of file"
else
  fail "EXTRACT: main loop not found from the '# ── Main loop' header to end of file"
fi

# ── Unit harness for T1–T3 ────────────────────────────────────────────────────
# write_unit_harness <harness> <lock_dir> <log_file> <live sessions (space-sep)>
# The tmux stub answers `has-session -t <target>` from the live-session list;
# every other tmux invocation reports failure. Runs under set -euo pipefail to
# mirror the daemon's own options.
write_unit_harness() {
  local harness="$1" lock_dir="$2" log_file="$3" live="$4"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'LOCK_DIR=%q\nLOG_FILE=%q\nLIVE_SESSIONS=%q\n' "$lock_dir" "$log_file" "$live"
    cat <<'PRELUDE'
YELLOW='' NC=''
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
tmux() {
  if [[ "${1:-}" == "has-session" ]]; then
    local target="${3:-}" s
    for s in $LIVE_SESSIONS; do
      [[ "$s" == "$target" ]] && return 0
    done
    return 1
  fi
  return 1
}
PRELUDE
    printf '%s\n' "$SWEEP_FN"
    printf 'sweep_stale_active_markers\necho "EXIT:$?"\n'
  } > "$harness"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T1: dead wrapper, marker older than the 600s grace → removed + one log line
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T1: stale marker with no live wrapper session is removed and logged ==="

T1_LOCK="$FIXTURE_DIR/t1-locks"
T1_LOG="$FIXTURE_DIR/t1.log"
T1_HARNESS="$FIXTURE_DIR/t1-harness.sh"
mkdir -p "$T1_LOCK"
: > "$T1_LOG"
# The observed scene: a QA-phase marker from a wrapper killed mid-phase, plus
# its dead-PID lock. The lock is NOT the sweep's business — the relaunch path
# retires it once the marker is gone.
touch "$T1_LOCK/TST-SWEEP-QA.qa.active"
set_mtime_ago "$T1_LOCK/TST-SWEEP-QA.qa.active" 700
printf '999999\n' > "$T1_LOCK/TST-SWEEP-QA.lock"
# A second phase marker for another Story proves the loop covers every phase glob.
touch "$T1_LOCK/TST-SWEEP-CMT.commit.active"
set_mtime_ago "$T1_LOCK/TST-SWEEP-CMT.commit.active" 5000

write_unit_harness "$T1_HARNESS" "$T1_LOCK" "$T1_LOG" ""
T1_OUT=$(bash "$T1_HARNESS" 2>&1)

if [[ "$T1_OUT" == *"EXIT:0"* ]]; then
  pass "T1: sweep returns 0"
else
  fail "T1: sweep did not return 0 (output: $T1_OUT)"
fi
if [[ ! -e "$T1_LOCK/TST-SWEEP-QA.qa.active" ]]; then
  pass "T1: stale qa marker removed"
else
  fail "T1: stale qa marker still present"
fi
if [[ ! -e "$T1_LOCK/TST-SWEEP-CMT.commit.active" ]]; then
  pass "T1: stale commit marker removed"
else
  fail "T1: stale commit marker still present"
fi
if [[ -f "$T1_LOCK/TST-SWEEP-QA.lock" ]]; then
  pass "T1: dead lock left in place for the relaunch path to retire"
else
  fail "T1: dead lock was removed by the sweep"
fi
if grep -qE '^\[STALE-MARKER\] story=TST-SWEEP-QA phase=qa age=7[0-9][0-9]s removed .*/TST-SWEEP-QA\.qa\.active' "$T1_LOG"; then
  pass "T1: log line names story id, phase and age for the qa marker"
else
  fail "T1: no log line for the qa marker (log: $(cat "$T1_LOG"))"
fi
if grep -qE '^\[STALE-MARKER\] story=TST-SWEEP-CMT phase=commit age=50[0-9][0-9]s removed ' "$T1_LOG"; then
  pass "T1: log line names story id, phase and age for the commit marker"
else
  fail "T1: no log line for the commit marker (log: $(cat "$T1_LOG"))"
fi
T1_LINES=$(grep -c 'STALE-MARKER' "$T1_LOG" || true)
if [[ "$T1_LINES" == "2" ]]; then
  pass "T1: exactly one log line per removed marker"
else
  fail "T1: expected 2 STALE-MARKER log lines, got $T1_LINES"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# T2: dead wrapper, marker younger than the grace → left alone, no log line
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T2: marker younger than the grace is left alone ==="

T2_LOCK="$FIXTURE_DIR/t2-locks"
T2_LOG="$FIXTURE_DIR/t2.log"
T2_HARNESS="$FIXTURE_DIR/t2-harness.sh"
mkdir -p "$T2_LOCK"
: > "$T2_LOG"
touch "$T2_LOCK/TST-SWEEP-YOUNG.impl.active"
set_mtime_ago "$T2_LOCK/TST-SWEEP-YOUNG.impl.active" 60

write_unit_harness "$T2_HARNESS" "$T2_LOCK" "$T2_LOG" ""
T2_OUT=$(bash "$T2_HARNESS" 2>&1)

if [[ "$T2_OUT" == *"EXIT:0"* ]]; then
  pass "T2: sweep returns 0"
else
  fail "T2: sweep did not return 0 (output: $T2_OUT)"
fi
if [[ -f "$T2_LOCK/TST-SWEEP-YOUNG.impl.active" ]]; then
  pass "T2: young impl marker left in place"
else
  fail "T2: young impl marker was removed"
fi
if ! grep -q 'STALE-MARKER' "$T2_LOG"; then
  pass "T2: no removal log line"
else
  fail "T2: unexpected removal log line: $(cat "$T2_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# T3: live wrapper session, marker older than the grace → left alone, no log
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: marker whose wrapper tmux session exists is left alone ==="

T3_LOCK="$FIXTURE_DIR/t3-locks"
T3_LOG="$FIXTURE_DIR/t3.log"
T3_HARNESS="$FIXTURE_DIR/t3-harness.sh"
mkdir -p "$T3_LOCK"
: > "$T3_LOG"
# A legitimate long Impl phase looks exactly like a crashed wrapper by mtime.
touch "$T3_LOCK/TST-SWEEP-LIVE.impl.active"
set_mtime_ago "$T3_LOCK/TST-SWEEP-LIVE.impl.active" 5000

write_unit_harness "$T3_HARNESS" "$T3_LOCK" "$T3_LOG" "gaai-deliver-TST-SWEEP-LIVE"
T3_OUT=$(bash "$T3_HARNESS" 2>&1)

if [[ "$T3_OUT" == *"EXIT:0"* ]]; then
  pass "T3: sweep returns 0"
else
  fail "T3: sweep did not return 0 (output: $T3_OUT)"
fi
if [[ -f "$T3_LOCK/TST-SWEEP-LIVE.impl.active" ]]; then
  pass "T3: old marker with a live wrapper session left in place"
else
  fail "T3: old marker with a live wrapper session was removed"
fi
if ! grep -q 'STALE-MARKER' "$T3_LOG"; then
  pass "T3: no removal log line"
else
  fail "T3: unexpected removal log line: $(cat "$T3_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# T4 + T5: one real idle main-loop cycle
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: an idle main-loop cycle (no ready Story) removes the stale marker before it sleeps ==="

T4_LOCK="$FIXTURE_DIR/t4-locks"
T4_PROJECT="$FIXTURE_DIR/t4-project"
T4_LOG="$FIXTURE_DIR/t4.log"
T4_EVIDENCE="$FIXTURE_DIR/t4-evidence"
T4_HARNESS="$FIXTURE_DIR/t4-harness.sh"
mkdir -p "$T4_LOCK" "$T4_PROJECT" "$T4_EVIDENCE"
: > "$T4_LOG"
touch "$T4_LOCK/TST-SWEEP-IDLE.qa.active"
set_mtime_ago "$T4_LOCK/TST-SWEEP-IDLE.qa.active" 700
printf '999999\n' > "$T4_LOCK/TST-SWEEP-IDLE.lock"
# Control: a marker inside the grace window must survive the cycle.
touch "$T4_LOCK/TST-SWEEP-FRESH.impl.active"

# The harness runs the daemon's real main loop with every collaborator stubbed.
# EXIT_WHEN_IDLE_THRESHOLD=2 makes the loop take the "No stories ready" branch
# (sleep; continue) once, then auto-stop with exit 0 on the second idle poll —
# which is exactly the path the sweep used to be unreachable from. Both scan
# intervals are set so the orphan tick scan and the periodic recovery scan run
# on the very first cycle; each records whether the stale marker still existed
# when it was called (first observation only). The sleep stub snapshots the
# marker + evidence state at its first call, i.e. at the end of cycle one.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'LOCK_DIR=%q\nPROJECT_DIR=%q\nLOG_FILE=%q\nEVIDENCE=%q\n' \
    "$T4_LOCK" "$T4_PROJECT" "$T4_LOG" "$T4_EVIDENCE"
  cat <<'PRELUDE'
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
POLL_INTERVAL=0
MAX_CONCURRENT=3
EXIT_WHEN_IDLE_THRESHOLD=2
SUSPEND_JUMP_THRESHOLD_SEC=300
POST_RESUME_GRACE_SEC=60
RECOVERY_SCAN_INTERVAL=0
ORPHAN_SCAN_INTERVAL_TICKS=1
_daemon_evidence_fatal=false

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
tmux() { return 1; }
_record_marker_state() {
  [[ -e "$EVIDENCE/$1" ]] && return 0
  if [[ -e "$LOCK_DIR/TST-SWEEP-IDLE.qa.active" ]]; then
    echo present > "$EVIDENCE/$1"
  else
    echo absent > "$EVIDENCE/$1"
  fi
}
_per_cycle_home_check() { return 0; }
cycle_orphan_lock_scan() { _record_marker_state orphan_scan; return 0; }
clean_stale_locks() { :; }
check_heartbeats() { return 0; }
watch_pr_merge_status() { return 0; }
active_count() { echo 0; }
check_agent_activity_stale() { return 0; }
scan_and_track_escalated_failed() { return 0; }
check_resolution_notifications() { return 0; }
forward_recovery_scan() { _record_marker_state recovery_scan; return 0; }
find_ready_stories() { printf ''; return 0; }
sweep_cleanup_pending() { touch "$EVIDENCE/sweep_cleanup_pending"; return 0; }
reconcile_done_merged_worktrees() { touch "$EVIDENCE/reconcile_done_merged_worktrees"; return 0; }
reap_orphaned_worktrees() { touch "$EVIDENCE/reap_orphaned_worktrees"; return 0; }
git() { printf '%s\n' "$*" >> "$EVIDENCE/git_calls"; return 0; }
_sleep_calls=0
sleep() {
  _sleep_calls=$(( _sleep_calls + 1 ))
  if [[ ! -e "$EVIDENCE/first_sleep" ]]; then
    _record_marker_state first_sleep
    ls -1 "$EVIDENCE" > "$EVIDENCE/at_first_sleep.list"
  fi
  if (( _sleep_calls > 3 )); then
    echo "HARNESS: main loop did not auto-stop after 3 idle polls" >&2
    exit 97
  fi
}
PRELUDE
  printf '%s\n' "$SWEEP_FN"
  printf '%s\n' "$MAIN_LOOP"
} > "$T4_HARNESS"

T4_OUT=$(bash "$T4_HARNESS" 2>&1)
T4_RC=$?

if [[ "$T4_RC" -eq 0 ]] && grep -q 'Auto-stop fired' "$T4_LOG"; then
  pass "T4: main loop ran idle cycles to a clean auto-stop (exit 0)"
else
  fail "T4: main loop did not auto-stop cleanly (rc=$T4_RC, output: $T4_OUT, log: $(cat "$T4_LOG"))"
fi
if grep -q 'No stories ready (idle 1/2' "$T4_LOG"; then
  pass "T4: the idle branch (No stories ready → sleep; continue) was exercised"
else
  fail "T4: the idle branch was not exercised (log: $(cat "$T4_LOG"))"
fi
if [[ ! -e "$T4_LOCK/TST-SWEEP-IDLE.qa.active" ]]; then
  pass "T4: stale qa marker removed by the idle cycle"
else
  fail "T4: stale qa marker survived the idle cycle"
fi
if [[ "$(cat "$T4_EVIDENCE/first_sleep" 2>/dev/null)" == "absent" ]]; then
  pass "T4: marker was already gone at the end of the first cycle (before the first sleep)"
else
  fail "T4: marker still present at the first sleep (state: $(cat "$T4_EVIDENCE/first_sleep" 2>/dev/null))"
fi
if [[ "$(cat "$T4_EVIDENCE/orphan_scan" 2>/dev/null)" == "absent" ]]; then
  pass "T4: orphan-lock tick scan of the same cycle already saw the marker gone"
else
  fail "T4: orphan-lock tick scan saw the marker (state: $(cat "$T4_EVIDENCE/orphan_scan" 2>/dev/null))"
fi
if [[ "$(cat "$T4_EVIDENCE/recovery_scan" 2>/dev/null)" == "absent" ]]; then
  pass "T4: periodic recovery scan of the same cycle already saw the marker gone (relaunch is unblocked)"
else
  fail "T4: periodic recovery scan saw the marker (state: $(cat "$T4_EVIDENCE/recovery_scan" 2>/dev/null))"
fi
if grep -qE '^\[STALE-MARKER\] story=TST-SWEEP-IDLE phase=qa age=7[0-9][0-9]s removed ' "$T4_LOG"; then
  pass "T4: removal was logged with story id, phase and age"
else
  fail "T4: removal log line missing (log: $(cat "$T4_LOG"))"
fi
if [[ -f "$T4_LOCK/TST-SWEEP-FRESH.impl.active" ]]; then
  pass "T4: fresh impl marker (inside the grace) survived the cycle"
else
  fail "T4: fresh impl marker was removed"
fi
if [[ -f "$T4_LOCK/TST-SWEEP-IDLE.lock" ]]; then
  pass "T4: dead lock left in place (the relaunch path retires it)"
else
  fail "T4: dead lock was removed by the main loop"
fi

echo ""
echo "=== T5: idle-relevant housekeeping runs on the idle cycle too ==="

T5_LIST="$T4_EVIDENCE/at_first_sleep.list"
for hk in sweep_cleanup_pending reconcile_done_merged_worktrees reap_orphaned_worktrees; do
  if grep -qx "$hk" "$T5_LIST" 2>/dev/null; then
    pass "T5: $hk ran before the first idle sleep"
  else
    fail "T5: $hk did not run before the first idle sleep (evidence: $(cat "$T5_LIST" 2>/dev/null | tr '\n' ' '))"
  fi
done
if grep -qF -- "-C $T4_PROJECT worktree prune" "$T4_EVIDENCE/git_calls" 2>/dev/null; then
  pass "T5: git worktree prune ran on the idle cycle"
else
  fail "T5: git worktree prune did not run (git calls: $(cat "$T4_EVIDENCE/git_calls" 2>/dev/null | tr '\n' ';'))"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
