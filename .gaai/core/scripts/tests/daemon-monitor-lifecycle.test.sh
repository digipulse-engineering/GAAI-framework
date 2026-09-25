#!/usr/bin/env bash
# daemon-monitor-lifecycle.test.sh — presentation UI lifecycle: created by a
# successful launch, torn down by every `--stop` path (regression-coverage)
#
# Covers:
#   * AC1 — the presentation UI is created on a successful terminal-backed
#     launch, skipped under both opt-outs and with no terminal attached, a
#     subsequent `--monitor` attaches rather than creating a second UI, and
#     `restart` tears the UI down and recreates it;
#   * AC2 — the exact sibling `-mon` server is torn down on every settling
#     `--stop` path (the `state=none` early return, the settled-disposal
#     path, and the full stop path), an unrelated probe server survives every
#     invocation, the truncation line is present exactly where a stop
#     truncates the log, and every refusal preserves the presentation UI.
#
# Usage: .gaai/core/scripts/tests/daemon-monitor-lifecycle.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=daemon-home-provision.test.sh
GAAI_HOME_FIXTURE_ONLY=1 source "$SCRIPT_DIR/daemon-home-provision.test.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Fixture extension — presentation panes (kept here, not in the shared
# fixture, so the sibling suites are untouched and the Delivery inventory
# stays at exactly two files)
# ═══════════════════════════════════════════════════════════════════════════

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-monlc-XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
PROJ="$ROOT/proj"
gaai_build_fixture "$ROOT" "$SCRIPTS_DIR"
cp "$SCRIPTS_DIR/daemon-monitor-top.sh" "$SCRIPTS_DIR/daemon-monitor-tail.sh" \
   "$PROJ/.gaai/core/scripts/"
chmod 0755 "$PROJ/.gaai/core/scripts/daemon-monitor-top.sh" \
           "$PROJ/.gaai/core/scripts/daemon-monitor-tail.sh"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" commit -qm "panes" >/dev/null 2>&1
git -C "$PROJ" push -q origin staging 2>/dev/null

START="$PROJ/.gaai/core/scripts/daemon-start.sh"
SETUP="$PROJ/.gaai/core/scripts/daemon-setup.sh"
LIFECYCLE="$(gaai_lifecycle_root "$PROJ")"
OWNER_FILE="$LIFECYCLE/owner"
PID_FILE="$PROJ/.gaai/project/contexts/backlog/.delivery-locks/.daemon.pid"
LOG_FILE="$PROJ/.gaai/project/contexts/backlog/.delivery-daemon.log"

owner_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# ═══════════════════════════════════════════════════════════════════════════
# Probe server (an unrelated tmux server AC2 proves untouched) + pty harness
# ═══════════════════════════════════════════════════════════════════════════

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gaai-monp-XXXXXX")"
PROBE_DIR="$(cd "$PROBE_DIR" && pwd -P)"
PROBE_SOCK="$PROBE_DIR/p"
PROBE_CONF="$PROBE_DIR/conf"
printf 'set -g exit-empty off\nset -wg remain-on-exit on\n' > "$PROBE_CONF"
tmux -f "$PROBE_CONF" -S "$PROBE_SOCK" new-session -d -s keepalive 'sleep 900'

MON_SOCK=""
trap 'tmux -f /dev/null -S "${MON_SOCK:-/nonexistent}" kill-server 2>/dev/null; tmux -f /dev/null -S "$PROBE_SOCK" kill-server 2>/dev/null; rm -rf "$PROBE_DIR"; gaai_teardown "$ROOT" "$PROJ"' EXIT INT TERM

# pty_run <probe-session> <cmd...> — a real pty for a command that terminates
# on its own (plain start / stop / status). `do_monitor` never terminates on
# its own — it always ends in `exec ... attach` — so no scenario below routes
# an explicit `--monitor` invocation through this synchronous helper; see
# async_start/async_stop.
pty_run() {
  local _s="$1"; shift
  local _done="$ROOT/pty.$_s.rc"
  rm -f "$_done"
  tmux -f "$PROBE_CONF" -S "$PROBE_SOCK" new-session -d -s "$_s" \
    "/usr/bin/env -i PATH=$ROOT/fakebin:/usr/bin:/bin HOME=$ROOT/opshome TERM=xterm-256color $*; printf '%s' \$? > '$_done'"
  gaai_wait_for 60 "$_done" || { printf 'PTY_TIMEOUT\n'; tmux -f /dev/null -S "$PROBE_SOCK" kill-session -t "=$_s" 2>/dev/null; return 1; }
  # -S - : the full scrollback from the start of the pane, not just the
  # currently visible screen — the daemon's own startup banner is longer than
  # one screen, so a plain `capture-pane -p` silently loses the early lines.
  # Target by bare name, not "=name": the exact-match form fails to resolve
  # once the pane has already exited (remain-on-exit keeps it addressable,
  # but only via the non-exact lookup), even though the session is still
  # listed and still alive by every other query.
  tmux -f /dev/null -S "$PROBE_SOCK" capture-pane -p -S - -t "$_s" 2>/dev/null
  tmux -f /dev/null -S "$PROBE_SOCK" kill-session -t "=$_s" 2>/dev/null
  return "$(cat "$_done" 2>/dev/null || echo 1)"
}

# async_start/async_stop/poll_until — for the one shape pty_run cannot express:
# a command whose own process ends in `exec ... attach`, which would hang a
# synchronous wait until PTY_TIMEOUT. These start the command detached, let the
# caller poll for the side effect it actually needs, then force-detach.
async_start() {
  local _s="$1"; shift
  tmux -f "$PROBE_CONF" -S "$PROBE_SOCK" new-session -d -s "$_s" \
    "/usr/bin/env -i PATH=$ROOT/fakebin:/usr/bin:/bin HOME=$ROOT/opshome TERM=xterm-256color $*"
}
async_stop() { tmux -f /dev/null -S "$PROBE_SOCK" kill-session -t "=$1" 2>/dev/null || true; }
poll_until() {
  local _n="$1"; shift
  local _i=0
  while [[ "$_i" -lt "$_n" ]]; do
    "$@" && return 0
    sleep 1; _i=$(( _i + 1 ))
  done
  return 1
}

mon_alive() { tmux -f /dev/null -S "$MON_SOCK" has-session -t "=$MON_SESS" 2>/dev/null; }
mon_alive_str() { mon_alive && printf 'yes' || printf 'no'; }
# assert_preserved <label> — a refusal must never make the UI WORSE than it was
# immediately before the refusing call. Differential, not absolute: on a base
# revision that does not yet create the UI on plain start, "before" is
# correctly "no" and the implication is vacuously satisfied; once AC1 lands,
# "before" is "yes" and this becomes a real preservation proof either way.
assert_preserved() {
  local _label="$1" _before="$2" _after
  _after="$(mon_alive_str)"
  if [[ "$_before" == "no" || "$_after" == "yes" ]]; then
    pass "$_label: presentation UI state preserved across the refusal ($_before -> $_after)"
  else
    fail "$_label: presentation UI was torn down on a refusal ($_before -> $_after)"
  fi
}
mon_has_client() { [[ -n "$(tmux -f /dev/null -S "$MON_SOCK" list-clients 2>/dev/null)" ]]; }
mon_sessions() { tmux -f /dev/null -S "$MON_SOCK" list-sessions 2>/dev/null | wc -l | tr -d ' '; }
mon_panes() { tmux -f /dev/null -S "$MON_SOCK" list-panes -a 2>/dev/null | wc -l | tr -d ' '; }
mon_srv_pid() { ps -eo pid,args 2>/dev/null | grep -F -- "-S $MON_SOCK " | grep -v grep | awk '{print $1}' | head -1; }
probe_alive() { tmux -f /dev/null -S "$PROBE_SOCK" has-session -t "=keepalive" 2>/dev/null; }

# scenario_reset — returns the sandbox to state=none between scenarios. Never
# touches $PROBE_SOCK (the unrelated-server proof) or the forge-token fixture.
scenario_reset() {
  tmux -f /dev/null -S "$MON_SOCK" kill-server 2>/dev/null; rm -f "$MON_SOCK" 2>/dev/null
  tmux -f /dev/null -S "$DSOCK" kill-server 2>/dev/null; rm -f "$DSOCK" 2>/dev/null
  rm -rf "$LIFECYCLE" 2>/dev/null
  rm -f "$PID_FILE" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# One-time setup, then capture the stable per-repository namespace
# ═══════════════════════════════════════════════════════════════════════════

gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
gaai_run "$ROOT" "$START" >/dev/null 2>&1
DSOCK="$(owner_field "$OWNER_FILE" socket)"
DSESS="$(owner_field "$OWNER_FILE" session)"
MON_SOCK="$DSOCK-mon"
MON_SESS="gaai-monitor-${DSOCK##*/}"
scenario_reset
# The fixture's stub delivery-daemon.sh never writes to $LOG_FILE — only the
# real daemon runtime does, which is out of this suite's scope — so without a
# seed, every "byte-identical" / "truncation line present" assertion below
# would compare "does not exist" to itself and pass vacuously. A real,
# non-empty file makes B1's marker-line and B2/B3's untouched-content proofs
# meaningful. scenario_reset never clears $LOG_FILE, so this persists exactly
# as a real daemon's own accumulated log would.
printf '[seed] pre-existing daemon output before any --stop in this suite\n' > "$LOG_FILE"

echo ""
echo "=== Dual-shell coverage declaration ==="
SHELLS="$(gaai_supported_shells)"
echo "  supported interpreters exercised: $(echo "$SHELLS" | tr '\n' ' ')"
if gaai_bash32_available; then
  pass "TC0: both supported shells (Bash 3.2 and the current Bash) are available and exercised"
else
  echo "  NOTE: no Bash 3.2 interpreter on this host — the 3.2 half of the dual-shell"
  echo "        matrix cannot execute here. It MUST be executed on the macOS lane, whose"
  echo "        /bin/bash is 3.2, before this boundary is declared proven."
  pass "TC0: dual-shell coverage is declared explicitly rather than silently assumed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Part 1 — AC1: the presentation UI is created by a successful launch
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== A1: --no-monitor suppresses UI creation ==="
scenario_reset
OUT="$(pty_run a1 "$START" --no-monitor)"
echo "$OUT" | grep -q 'Daemon started' && pass "A1-1: daemon started" || fail "A1-1: no 'Daemon started' in: $OUT"
mon_alive && fail "A1-2: presentation UI exists despite --no-monitor" || pass "A1-2: no presentation UI created"
echo "$OUT" | grep -q 'auto-launch skipped' && pass "A1-3: hint names the auto-launch skip" || fail "A1-3: expected auto-launch-skipped hint, got: $OUT"

echo ""
echo "=== A2: GAAI_DAEMON_NO_MONITOR=1 suppresses UI creation ==="
scenario_reset
OUT="$(pty_run a2 GAAI_DAEMON_NO_MONITOR=1 "$START")"
echo "$OUT" | grep -q 'Daemon started' && pass "A2-1: daemon started" || fail "A2-1: no 'Daemon started' in: $OUT"
mon_alive && fail "A2-2: presentation UI exists despite GAAI_DAEMON_NO_MONITOR" || pass "A2-2: no presentation UI created"
echo "$OUT" | grep -q 'auto-launch skipped' && pass "A2-3: hint names the auto-launch skip" || fail "A2-3: expected auto-launch-skipped hint, got: $OUT"

echo ""
echo "=== A3: no terminal attached suppresses UI creation ==="
scenario_reset
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
echo "$OUT" | grep -q 'Daemon started' && pass "A3-1: daemon started" || fail "A3-1: no 'Daemon started' in: $OUT"
mon_alive && fail "A3-2: presentation UI exists with no terminal attached" || pass "A3-2: no presentation UI created"
echo "$OUT" | grep -q -- '--monitor' && pass "A3-3: hint names --monitor" || fail "A3-3: expected a --monitor hint, got: $OUT"

echo ""
echo "=== A4: a terminal-backed successful launch creates the UI without blocking ==="
scenario_reset
OUT="$(pty_run a4 "$START")"
echo "$OUT" | grep -q 'Daemon started' && pass "A4-1: daemon started (pty_run returning is the non-blocking proof)" || fail "A4-1: no 'Daemon started' in: $OUT"
mon_alive && pass "A4-2: presentation UI exists" || fail "A4-2: no presentation UI created"
[[ "$(mon_sessions)" == "1" ]] && pass "A4-3: exactly one presentation session" || fail "A4-3: expected 1 session, got $(mon_sessions)"
[[ "$(mon_panes)" == "2" ]] && pass "A4-4: exactly two panes (top + tail)" || fail "A4-4: expected 2 panes, got $(mon_panes)"

echo ""
echo "=== A4s: the presentation server never inherits an admitted secret ==="
if ! mon_alive; then
  fail "A4s: no presentation server exists to inspect (A4 must create one first)"
else
  GLOBAL_ENV="$(tmux -f /dev/null -S "$MON_SOCK" show-environment -g 2>/dev/null)"
  _leak=0
  for _name in GAAI_IMPL_AUTH_TOKEN GAAI_FORGE_TOKEN GH_TOKEN GAAI_FORGE_IDENTITY GAAI_DAEMON_WEBHOOK_SECRET GAAI_NOTIFICATION_WEBHOOK; do
    echo "$GLOBAL_ENV" | grep -q "^${_name}=" && _leak=1
  done
  [[ "$_leak" -eq 0 ]] && pass "A4s: none of the six scrubbed secret names reach the presentation server" || fail "A4s: a scrubbed name leaked into the presentation server: $GLOBAL_ENV"
fi

echo ""
echo "=== A5: a subsequent --monitor attaches rather than creating a second UI ==="
# A session/pane COUNT alone cannot distinguish "attached to A4's existing
# server" from "created a fresh one" — both end at 1 session / 2 panes. The
# server pid captured BEFORE this call is the differentiator: it must be
# non-empty (A4 already succeeded) AND unchanged afterward (no new server).
_srv_before="$(mon_srv_pid)"
async_start a5 "$START" --monitor
poll_until 20 mon_has_client
_a5_attached=$?
async_stop a5
_srv_after="$(mon_srv_pid)"
[[ "$_a5_attached" -eq 0 ]] && pass "A5-1: --monitor attached a client" || fail "A5-1: no client ever attached"
[[ "$(mon_sessions)" == "1" ]] && pass "A5-2: still exactly one presentation session" || fail "A5-2: expected 1 session, got $(mon_sessions)"
[[ "$(mon_panes)" == "2" ]] && pass "A5-3: still exactly two panes — no second UI" || fail "A5-3: expected 2 panes, got $(mon_panes)"
if [[ -n "$_srv_before" && "$_srv_before" == "$_srv_after" ]]; then
  pass "A5-4: the presentation server process is unchanged — attached, not recreated"
else
  fail "A5-4: expected the same server pid before and after, got '$_srv_before' -> '$_srv_after'"
fi

echo ""
echo "=== A6: restart tears down and recreates the UI ==="
_srv1="$(mon_srv_pid)"
OUT="$(pty_run a6 "$START" --restart)"
echo "$OUT" | grep -q 'Daemon started' && pass "A6-1: daemon restarted" || fail "A6-1: no 'Daemon started' in: $OUT"
mon_alive && pass "A6-2: presentation UI exists after restart" || fail "A6-2: no presentation UI after restart"
_srv2="$(mon_srv_pid)"
if [[ -n "$_srv1" && -n "$_srv2" && "$_srv1" != "$_srv2" ]]; then
  pass "A6-3: the presentation server process differs across restart (teardown-and-recreate, not reuse)"
else
  fail "A6-3: expected distinct server pids across restart, got '$_srv1' -> '$_srv2'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Part 2 — AC2: the UI is torn down on every settling --stop path
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== B1: full stop path tears down the UI and truncates the log with one line ==="
scenario_reset
pty_run b1 "$START" >/dev/null
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -eq 0 ]] && pass "B1-1: --stop exits 0" || fail "B1-1: --stop exited $_rc"
echo "$OUT" | grep -q '✅ Daemon stopped. Log truncated.' && pass "B1-2: success message names the truncation" || fail "B1-2: unexpected output: $OUT"
mon_alive && fail "B1-3: presentation server still answers" || pass "B1-3: presentation server no longer answers"
[[ -e "$MON_SOCK" ]] && fail "B1-4: presentation socket file survives" || pass "B1-4: presentation socket file is gone"
probe_alive && pass "B1-5: unrelated probe server survives" || fail "B1-5: unrelated probe server did not survive"
if [[ -f "$LOG_FILE" && "$(wc -l < "$LOG_FILE" | tr -d ' ')" == "1" ]] \
   && grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] log truncated by --stop$' "$LOG_FILE"; then
  pass "B1-6: the log holds exactly one operator-readable truncation line"
else
  fail "B1-6: unexpected log content: $(cat "$LOG_FILE" 2>/dev/null)"
fi

echo ""
echo "=== B2: settled disposal tears down the UI and never truncates the log ==="
scenario_reset
gaai_run "$ROOT" "$START" >/dev/null 2>&1
_child_pid="$(owner_field "$OWNER_FILE" child_pid)"
tmux -f /dev/null -S "$DSOCK" kill-session -t "=$DSESS" 2>/dev/null
_waited=0
while [[ "$_waited" -lt 30 ]] && kill -0 "$_child_pid" 2>/dev/null; do sleep 1; _waited=$(( _waited + 1 )); done
_log_before="$(cksum "$LOG_FILE" 2>/dev/null || echo none)"
async_start b2 "$START" --monitor
poll_until 20 mon_alive
_b2_raised=$?
async_stop b2
[[ "$_b2_raised" -eq 0 ]] && pass "B2-1: --monitor raised a UI over the settled lifecycle" || fail "B2-1: no UI ever raised"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -eq 0 ]] && pass "B2-2: --stop exits 0" || fail "B2-2: --stop exited $_rc"
echo "$OUT" | grep -q 'Settled lifecycle disposed of. Log preserved.' && pass "B2-3: success message names disposal, not truncation" || fail "B2-3: unexpected output: $OUT"
mon_alive && fail "B2-4: presentation server still answers" || pass "B2-4: presentation server no longer answers"
[[ -e "$MON_SOCK" ]] && fail "B2-5: presentation socket file survives" || pass "B2-5: presentation socket file is gone"
probe_alive && pass "B2-6: unrelated probe server survives" || fail "B2-6: unrelated probe server did not survive"
_log_after="$(cksum "$LOG_FILE" 2>/dev/null || echo none)"
[[ "$_log_before" == "$_log_after" ]] && pass "B2-7: the log is byte-identical — this path never truncates" || fail "B2-7: log changed across a disposal that must not truncate"

echo ""
echo "=== B3: the state=none early return tears down a UI raised with no daemon (#3176) ==="
scenario_reset
_log_before="$(cksum "$LOG_FILE" 2>/dev/null || echo none)"
async_start b3 "$START" --monitor
poll_until 20 mon_alive
_b3_raised=$?
async_stop b3
[[ "$_b3_raised" -eq 0 ]] && pass "B3-1: --monitor raised a UI with no daemon running" || fail "B3-1: no UI ever raised"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -eq 0 ]] && pass "B3-2: --stop exits 0" || fail "B3-2: --stop exited $_rc"
echo "$OUT" | grep -q 'No daemon running.' && pass "B3-3: success message unchanged" || fail "B3-3: unexpected output: $OUT"
mon_alive && fail "B3-4: presentation server still answers" || pass "B3-4: presentation server no longer answers"
[[ -e "$MON_SOCK" ]] && fail "B3-5: presentation socket file survives" || pass "B3-5: presentation socket file is gone"
probe_alive && pass "B3-6: unrelated probe server survives" || fail "B3-6: unrelated probe server did not survive"
_log_after="$(cksum "$LOG_FILE" 2>/dev/null || echo none)"
[[ "$_log_before" == "$_log_after" ]] && pass "B3-7: the log is byte-identical — this path never truncates" || fail "B3-7: log changed across a state=none stop"

echo ""
echo "=== B4: --stop succeeds unchanged when no presentation server ever existed ==="
scenario_reset
gaai_run "$ROOT" "$START" >/dev/null 2>&1
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -eq 0 ]] && pass "B4-1: --stop exits 0" || fail "B4-1: --stop exited $_rc"
echo "$OUT" | grep -q '✅ Daemon stopped.' && pass "B4-2: success message present with no presentation server to tear down" || fail "B4-2: unexpected output: $OUT"

echo ""
echo "=== B5: owner_role=corrupt_record refuses and preserves the UI ==="
scenario_reset
pty_run b5 "$START" >/dev/null
_before="$(mon_alive_str)"
printf 'garbage\n' > "$OWNER_FILE"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -ne 0 ]] && pass "B5-1: --stop refuses (non-zero exit)" || fail "B5-1: --stop unexpectedly succeeded"
echo "$OUT" | grep -q 'owner_role=corrupt_record' && pass "B5-2: refusal names owner_role=corrupt_record" || fail "B5-2: unexpected output: $OUT"
assert_preserved "B5-3" "$_before"

echo ""
echo "=== B6: owner_role=identity_drift_at_stop refuses and preserves the UI ==="
scenario_reset
pty_run b6 "$START" >/dev/null
_before="$(mon_alive_str)"
_owner_tmp="$ROOT/owner.b6.tmp"
sed 's/^session=.*/session=gaai-foreign-session/' "$OWNER_FILE" > "$_owner_tmp" && mv "$_owner_tmp" "$OWNER_FILE"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -ne 0 ]] && pass "B6-1: --stop refuses (non-zero exit)" || fail "B6-1: --stop unexpectedly succeeded"
echo "$OUT" | grep -q 'owner_role=identity_drift_at_stop' && pass "B6-2: refusal names owner_role=identity_drift_at_stop" || fail "B6-2: unexpected output: $OUT"
assert_preserved "B6-3" "$_before"
tmux -f /dev/null -S "$DSOCK" kill-server 2>/dev/null || true

echo ""
echo "=== B7: settlement_role=child_persisted (full stop path) refuses and preserves the UI ==="
scenario_reset
pty_run b7 "$START" >/dev/null
_before="$(mon_alive_str)"
sleep 600 &
_helper_pid=$!
_owner_tmp="$ROOT/owner.b7.tmp"
sed "s/^child_pid=.*/child_pid=$_helper_pid/" "$OWNER_FILE" > "$_owner_tmp" && mv "$_owner_tmp" "$OWNER_FILE"
tmux -f /dev/null -S "$DSOCK" kill-session -t "=$DSESS" 2>/dev/null
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -ne 0 ]] && pass "B7-1: --stop refuses (non-zero exit)" || fail "B7-1: --stop unexpectedly succeeded"
echo "$OUT" | grep -q 'settlement_role=child_persisted' && pass "B7-2: refusal names settlement_role=child_persisted" || fail "B7-2: unexpected output: $OUT"
assert_preserved "B7-3" "$_before"
kill "$_helper_pid" 2>/dev/null || true
wait "$_helper_pid" 2>/dev/null || true

echo ""
echo "=== B8: settlement_role=child_persisted (settled disposal path) refuses and preserves the UI ==="
scenario_reset
gaai_run "$ROOT" "$START" >/dev/null 2>&1
_child_pid="$(owner_field "$OWNER_FILE" child_pid)"
tmux -f /dev/null -S "$DSOCK" kill-session -t "=$DSESS" 2>/dev/null
_waited=0
while [[ "$_waited" -lt 30 ]] && kill -0 "$_child_pid" 2>/dev/null; do sleep 1; _waited=$(( _waited + 1 )); done
async_start b8 "$START" --monitor
poll_until 20 mon_alive
async_stop b8
_before="$(mon_alive_str)"
sleep 600 &
_helper_pid=$!
_owner_tmp="$ROOT/owner.b8.tmp"
sed "s/^child_pid=.*/child_pid=$_helper_pid/" "$OWNER_FILE" > "$_owner_tmp" && mv "$_owner_tmp" "$OWNER_FILE"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
_rc=$?
[[ "$_rc" -ne 0 ]] && pass "B8-1: --stop refuses (non-zero exit)" || fail "B8-1: --stop unexpectedly succeeded"
echo "$OUT" | grep -q 'settlement_role=child_persisted' && pass "B8-2: refusal names settlement_role=child_persisted" || fail "B8-2: unexpected output: $OUT"
assert_preserved "B8-3" "$_before"
kill "$_helper_pid" 2>/dev/null || true
wait "$_helper_pid" 2>/dev/null || true

echo ""
echo "=== B9: on the full stop path, teardown is structurally unreachable from any refusal ==="
# settlement_role=session_persisted cannot be forced live: `tmux kill-session`
# always removes the session, so this is a structural proof over the shipped
# source instead — the same property B5-B8 prove live for every refusal that
# CAN be constructed. Scoped to the full stop path's own tail (after the
# settled-verdict branch has already returned), not the whole file: refusals
# on other branches (e.g. corrupt_record) legitimately precede that branch's
# own, earlier teardown call and are not part of this claim.
_dostop_start="$(grep -n '^do_stop()' "$START" | head -1 | cut -d: -f1)"
_dostop_end="$(awk '/^do_stop\(\)/{f=1} f && /^}/{print NR; exit}' "$START")"
# The anchor string also appears earlier, inside a helper this function calls
# (_settled_disposal_verdict's own token) — the search for it must be scoped to
# do_stop's own body, or it picks up that unrelated, much-earlier occurrence.
_full_tail_start="$(awk -v s="$_dostop_start" -v e="$_dostop_end" 'NR>=s && NR<=e && /owner_role=identity_drift_at_stop/{print NR; exit}' "$START")"
if [[ -n "$_full_tail_start" && -n "$_dostop_end" ]]; then
  _refuse_lines="$(awk -v s="$_full_tail_start" -v e="$_dostop_end" 'NR>=s && NR<=e && /_gaai_home_refuse/{print NR}' "$START")"
  _teardown_lines="$(awk -v s="$_full_tail_start" -v e="$_dostop_end" 'NR>=s && NR<=e && /_monitor_teardown/{print NR}' "$START")"
  _ok=1
  [[ -n "$_teardown_lines" ]] || _ok=0
  for _tl in $_teardown_lines; do
    for _rl in $_refuse_lines; do
      [[ "$_tl" -gt "$_rl" ]] || _ok=0
    done
  done
  [[ "$_ok" -eq 1 ]] && pass "B9: the full-path teardown call is strictly after every refusal on that path" || fail "B9: teardown is reachable at or before a refusal on the full stop path"
else
  fail "B9: could not locate the full stop-path anchors to check"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Part 3 — dual-shell pass over the core pair (AC1 creation + AC2 teardown)
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Dual-shell core pair: UI creation (A4) and full-path teardown (B1) ==="
while IFS= read -r _sh; do
  [[ -n "$_sh" ]] || continue
  _shname="$(basename "$_sh")"
  scenario_reset
  OUT="$(pty_run "ds-$_shname" "$_sh" --noprofile --norc -p "$START")"
  echo "$OUT" | grep -q 'Daemon started' && pass "DS-$_shname-1: daemon started under $_shname" || fail "DS-$_shname-1: no 'Daemon started' under $_shname: $OUT"
  mon_alive && pass "DS-$_shname-2: presentation UI created under $_shname" || fail "DS-$_shname-2: no presentation UI under $_shname"
  OUT="$(gaai_run "$ROOT" "$_sh" --noprofile --norc -p "$START" --stop 2>&1)"
  echo "$OUT" | grep -q '✅ Daemon stopped. Log truncated.' && pass "DS-$_shname-3: full stop path under $_shname" || fail "DS-$_shname-3: unexpected stop output under $_shname: $OUT"
  mon_alive && fail "DS-$_shname-4: presentation server survives stop under $_shname" || pass "DS-$_shname-4: presentation server torn down under $_shname"
done <<< "$SHELLS"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
