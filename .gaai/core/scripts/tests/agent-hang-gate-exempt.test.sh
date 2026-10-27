#!/usr/bin/env bash
# agent-hang-gate-exempt.test.sh
# The agent-hang detector must not kill a wrapper that is inside the admission
# gate it launched: the gate is silent for as long as the corpus takes, and it
# publishes .admission-gate-active.<wrapper pid> for exactly that long.
#
# The REAL check_agent_activity_stale and file_mtime are extracted from
# delivery-daemon.sh by name; agent-activity-stale.test.sh tests a pasted copy.
#
#   a. stale logs + fresh heartbeat + gate marker not older than the lock
#        -> wrapper untouched, [AGENT_HANG_EXEMPT] logged once across calls,
#           no audit entry, no hang marker
#   b. the same, no marker                          -> detected and signalled
#   c. marker OLDER than the lock (pid reuse)       -> detected and signalled
#   d. marker for another pid                       -> detected and signalled
#   e. marker removed after an exempt call          -> detected on the next call
#
# Usage: bash .gaai/core/scripts/tests/agent-hang-gate-exempt.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$SCRIPT_DIR/../delivery-daemon.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hang-gate-exempt.XXXXXX")"
PIDS=""
cleanup() {
  local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

LOCK_DIR="$SANDBOX/locks"; LOG_DIR="$SANDBOX/logs"; WT="$SANDBOX/worktree"
mkdir -p "$LOCK_DIR" "$LOG_DIR" "$WT/.delivery-logs"
PLATFORM="$(uname)"            # file_mtime reads it, as the daemon sets it
AGENT_HANG_THRESHOLD_SEC=480
HEARTBEAT_STALE=1800
SUSPEND_GRACE_UNTIL=0
AGENT_HANG_AUDIT="$LOCK_DIR/.agent-hang.audit"
RED='' NC=''
LOGGED_LINES="$SANDBOX/daemon.log"
log() { printf '%s\n' "$*" >> "$LOGGED_LINES"; }
_forward_resolve_worktree() { printf '%s\n' "$WT"; }
# The detector waits 30 s after SIGTERM before it checks for survivors. That
# wait is not under test: skip it, and let every other sleep run for real.
sleep() { [[ "${1:-}" == 30 ]] && return 0; command sleep "$@"; }

# The real functions, by name, from the shipped daemon.
EXTRACT="$SANDBOX/extracted.sh"
awk '
  /^file_mtime\(\)/ || /^check_agent_activity_stale\(\)/ { on = 1 }
  on { print }
  on && /^}/ { on = 0 }
' "$DAEMON" > "$EXTRACT"
if ! grep -q '^check_agent_activity_stale()' "$EXTRACT" || ! grep -q '^file_mtime()' "$EXTRACT"; then
  echo "  FAIL: could not extract check_agent_activity_stale and file_mtime from delivery-daemon.sh"
  exit 1
fi
# shellcheck source=/dev/null
source "$EXTRACT"

backdate() { # backdate <file> <minutes>
  local target; target=$(date -u -r $(( $(date +%s) - $2 * 60 )) +%Y%m%d%H%M.%S 2>/dev/null) \
    || target=$(date -u -d "$2 minutes ago" +%Y%m%d%H%M.%S)
  touch -m -t "$target" "$1"
}

# A wrapper whose heartbeat is fresh while every tracked log is stale.
new_wrapper() { # new_wrapper <sid>  -> sets WPID
  local sid="$1"
  command sleep 300 & WPID=$!; PIDS="$PIDS $WPID"
  echo "$WPID" > "$LOCK_DIR/$sid.lock";  backdate "$LOCK_DIR/$sid.lock" 40
  touch "$LOCK_DIR/$sid.heartbeat"
  echo '{"type":"tool_use"}' > "$WT/.delivery-logs/$sid.qa.log"; backdate "$WT/.delivery-logs/$sid.qa.log" 30
  echo 'wrapper' > "$LOG_DIR/$sid.wrapper.log";                   backdate "$LOG_DIR/$sid.wrapper.log" 30
}
# Every case starts from an empty lock directory: the detector scans all of it.
reset_observations() {
  local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; PIDS=""
  rm -f "$LOCK_DIR"/*.lock "$LOCK_DIR"/*.heartbeat "$LOCK_DIR"/*.agent-hang.marker \
        "$LOCK_DIR"/.admission-gate-active.* "$AGENT_HANG_AUDIT"
  : > "$LOGGED_LINES"; _AGENT_HANG_EXEMPT_LOGGED=" "
}
alive() { kill -0 "$1" 2>/dev/null; }

echo "=== a. gate marker not older than the lock: exempt ==="
reset_observations
new_wrapper TST-A; A_PID=$WPID
touch "$LOCK_DIR/.admission-gate-active.$A_PID"            # written during the gate, after the lock
check_agent_activity_stale; check_agent_activity_stale; sleep 1
if alive "$A_PID"; then pass "the wrapper inside its gate is not signalled"; else fail "the wrapper inside its gate was killed"; fi
if [[ "$(grep -c '^\[AGENT_HANG_EXEMPT\] TST-A ' "$LOGGED_LINES")" -eq 1 ]]; then
  pass "[AGENT_HANG_EXEMPT] is logged once across repeated checks"
else
  fail "exempt log lines: $(grep -c 'AGENT_HANG_EXEMPT' "$LOGGED_LINES")"
fi
if [[ ! -e "$AGENT_HANG_AUDIT" && ! -e "$LOCK_DIR/TST-A.agent-hang.marker" ]] && ! grep -q 'AGENT_HANG_DETECTED' "$LOGGED_LINES"; then
  pass "no audit entry, no hang marker, no detection"
else
  fail "the exempt wrapper left hang evidence"
fi

echo "=== b. no marker: detected ==="
reset_observations
new_wrapper TST-B; B_PID=$WPID
check_agent_activity_stale; sleep 1
if ! alive "$B_PID" && grep -q 'AGENT_HANG_DETECTED\] TST-B' "$LOGGED_LINES"; then
  pass "a wrapper without a gate marker is detected and signalled as before"
else
  fail "b: alive=$(alive "$B_PID" && echo yes || echo no)"
fi

echo "=== c. marker older than the lock (pid reuse): detected ==="
reset_observations
new_wrapper TST-C; C_PID=$WPID
touch "$LOCK_DIR/.admission-gate-active.$C_PID"; backdate "$LOCK_DIR/.admission-gate-active.$C_PID" 120
check_agent_activity_stale; sleep 1
if ! alive "$C_PID" && ! grep -q 'AGENT_HANG_EXEMPT' "$LOGGED_LINES"; then
  pass "a marker older than the lock grants no immunity"
else
  fail "c: alive=$(alive "$C_PID" && echo yes || echo no)"
fi

echo "=== d. marker for another pid: detected ==="
reset_observations
new_wrapper TST-D; D_PID=$WPID
touch "$LOCK_DIR/.admission-gate-active.$((D_PID + 99999))"
check_agent_activity_stale; sleep 1
if ! alive "$D_PID" && ! grep -q 'AGENT_HANG_EXEMPT' "$LOGGED_LINES"; then
  pass "another wrapper's marker grants no immunity"
else
  fail "d: alive=$(alive "$D_PID" && echo yes || echo no)"
fi

echo "=== e. the exemption ends with the marker ==="
reset_observations
new_wrapper TST-E; E_PID=$WPID
touch "$LOCK_DIR/.admission-gate-active.$E_PID"
check_agent_activity_stale; sleep 1
E_FIRST=$(alive "$E_PID" && echo alive || echo killed)
rm -f "$LOCK_DIR/.admission-gate-active.$E_PID"        # the gate returned
check_agent_activity_stale; sleep 1
if [[ "$E_FIRST" == alive ]] && ! alive "$E_PID"; then
  pass "untouched during the gate, detected once the gate has returned"
else
  fail "e: during gate=$E_FIRST, after gate alive=$(alive "$E_PID" && echo yes || echo no)"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
