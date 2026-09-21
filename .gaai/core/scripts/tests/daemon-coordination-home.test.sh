#!/usr/bin/env bash
# daemon-coordination-home.test.sh — exact-current startup contract, regression-coverage criterion live-coordination matrices
#
# Covers the fail-closed live boundary: private-server lifecycle and races, the
# durable pending -> bound -> running transitions and every crash point between
# them, the descriptor-bound release barrier, exact settlement, and preservation
# instead of repair. Also guards the orthogonal wrapper-drain authority against
# regression, and proves `--status` is a completed read-only subprotocol.
#
# Usage: .gaai/core/scripts/tests/daemon-coordination-home.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=daemon-home-provision.test.sh
GAAI_HOME_FIXTURE_ONLY=1 source "$SCRIPT_DIR/daemon-home-provision.test.sh"

for _tool in git tmux; do
  command -v "$_tool" >/dev/null 2>&1 || { echo "ERROR: $_tool required"; exit 1; }
done

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-coord-XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
PROJ="$ROOT/proj"
trap 'gaai_teardown "$ROOT" "$PROJ"' EXIT
gaai_build_fixture "$ROOT" "$SCRIPTS_DIR"
START="$PROJ/.gaai/core/scripts/daemon-start.sh"
SETUP="$PROJ/.gaai/core/scripts/daemon-setup.sh"
HOME_WT="$(gaai_home_path "$PROJ")"
LIFECYCLE="$(gaai_lifecycle_root "$PROJ")"
OWNER="$LIFECYCLE/owner"

fresh_home() {
  gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1
  gaai_reset_home
  rm -rf "$LIFECYCLE" 2>/dev/null
  gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
}

socket_of() { sed -n 's/^socket=//p' "$OWNER" 2>/dev/null | head -1; }
session_of() { sed -n 's/^session=//p' "$OWNER" 2>/dev/null | head -1; }
state_of() { sed -n 's/^state=//p' "$OWNER" 2>/dev/null | head -1; }
attempt_of() { sed -n 's/^attempt_dir=//p' "$OWNER" 2>/dev/null | head -1; }

echo ""
echo "=== TC1: private socket root ownership, mode, type and path length ==="
fresh_home
gaai_run "$ROOT" "$START" >/dev/null 2>&1
SOCK="$(socket_of)"
SROOT="$(dirname "$SOCK")"
[[ -S "$SOCK" ]] && pass "TC1-1: the private server socket exists and is a socket" \
                 || fail "TC1-1: no socket at the derived path"
[[ "$(stat -L -c '%a' "$SROOT" 2>/dev/null || stat -L -f '%Lp' "$SROOT")" == "700" ]] \
  && pass "TC1-2: the socket root is mode 0700" || fail "TC1-2: the socket root is not 0700"
[[ "$(stat -L -c '%u' "$SROOT" 2>/dev/null || stat -L -f '%u' "$SROOT")" == "$(id -u)" ]] \
  && pass "TC1-3: the socket root is owned by the current UID" || fail "TC1-3: foreign socket-root owner"
[[ ! -L "$SROOT" ]] && pass "TC1-4: the socket root is not a symlink" || fail "TC1-4: the socket root is a symlink"
LIMIT=108; [[ "$(uname -s)" == "Darwin" ]] && LIMIT=104
[[ "${#SOCK}" -lt "$LIMIT" ]] \
  && pass "TC1-5: the complete physical socket path (${#SOCK}) is under the platform limit ($LIMIT)" \
  || fail "TC1-5: the socket path exceeds the platform limit"
# Derived from the common directory and the schema, never from TMPDIR.
case "$SOCK" in
  "${TMPDIR:-/nonexistent-tmpdir}"*) fail "TC1-6: the socket root followed TMPDIR" ;;
  *) pass "TC1-6: the socket root is independent of TMPDIR" ;;
esac

echo ""
echo "=== TC2: required options hold on the private server before any session ==="
[[ "$(tmux -f /dev/null -S "$SOCK" show-options -g -v exit-empty 2>/dev/null)" == "off" ]] \
  && pass "TC2-1: exit-empty is off on the private server" || fail "TC2-1: exit-empty is not off"
[[ "$(tmux -f /dev/null -S "$SOCK" show-options -g -v remain-on-exit 2>/dev/null)" == "on" ]] \
  && pass "TC2-2: remain-on-exit is on" || fail "TC2-2: remain-on-exit is not on"

echo ""
echo "=== TC3: exact '=name' targeting resists a prefix collision ==="
SESS="$(session_of)"
tmux -f /dev/null -S "$SOCK" new-session -d -s "${SESS}-decoy" 'exec /bin/sh -c "sleep 60"' 2>/dev/null
OUT="$(gaai_run "$ROOT" "$START" --status 2>&1)"
if echo "$OUT" | grep -q 'verdict:     ambiguous'; then
  pass "TC3-1: a foreign session on the private server is ambiguous evidence, not adopted"
else
  fail "TC3-1: a foreign session did not make the verdict ambiguous: $OUT"
fi
tmux -f /dev/null -S "$SOCK" kill-session -t "=${SESS}-decoy" 2>/dev/null
OUT="$(gaai_run "$ROOT" "$START" --status 2>&1)"
echo "$OUT" | grep -q 'verdict:     live' \
  && pass "TC3-2: after the decoy is gone the exact session is live again" \
  || fail "TC3-2: exact targeting did not recover: $OUT"

echo ""
echo "=== TC4: --status is read-only ==="
BEFORE_OWNER="$(cksum < "$OWNER")"
BEFORE_HOME="$(git -C "$HOME_WT" rev-parse HEAD)"
BEFORE_PANES="$(tmux -f /dev/null -S "$SOCK" list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
gaai_run "$ROOT" "$START" --status >/dev/null 2>&1
[[ "$(cksum < "$OWNER")" == "$BEFORE_OWNER" ]] \
  && pass "TC4-1: --status did not mutate the owner record" || fail "TC4-1: --status mutated the owner record"
[[ "$(git -C "$HOME_WT" rev-parse HEAD)" == "$BEFORE_HOME" ]] \
  && pass "TC4-2: --status did not touch the home" || fail "TC4-2: --status moved the home"
[[ "$(tmux -f /dev/null -S "$SOCK" list-panes -a 2>/dev/null | wc -l | tr -d ' ')" == "$BEFORE_PANES" ]] \
  && pass "TC4-3: --status created no pane or session" || fail "TC4-3: --status changed the pane set"
[[ ! -d "$LIFECYCLE/lock.d" ]] \
  && pass "TC4-4: --status left no lifecycle lock held" || fail "TC4-4: --status left the lock held"

echo ""
echo "=== TC5: concurrent starts — exactly one daemon, no second spawn ==="
fresh_home
PANES_BEFORE=0
for _i in 1 2 3; do
  gaai_run "$ROOT" "$START" >"$ROOT/concurrent.$_i.out" 2>&1 &
done
wait
SOCK="$(socket_of)"
STARTED="$(grep -l 'Daemon started' "$ROOT"/concurrent.*.out 2>/dev/null | wc -l | tr -d ' ')"
REFUSED="$(grep -lE 'reason=(already_running|home_lock_failed|process_authority_invalid)' "$ROOT"/concurrent.*.out 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$STARTED" == "1" ]]; then
  pass "TC5-1: exactly one concurrent start succeeded"
else
  fail "TC5-1: $STARTED concurrent starts succeeded (expected 1)"
fi
if [[ "$REFUSED" == "2" ]]; then
  pass "TC5-2: the other two returned a typed refusal"
else
  fail "TC5-2: $REFUSED concurrent starts returned a typed refusal (expected 2)"
fi
PANES="$(tmux -f /dev/null -S "$SOCK" list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
[[ "$PANES" == "1" ]] && pass "TC5-3: exactly one pane exists on the private server" \
                      || fail "TC5-3: $PANES panes exist (expected 1)"

echo ""
echo "=== TC6: the lock is held across the whole start, and released after ==="
[[ ! -d "$LIFECYCLE/lock.d" ]] \
  && pass "TC6-1: the lifecycle lock is released once the start settles" \
  || fail "TC6-1: the lifecycle lock is still held after a completed start"

echo ""
echo "=== TC7: an orphaned pending record is settled, not spawned over ==="
fresh_home
# Controller crash BEFORE the first tmux effect: a pending record with no server.
mkdir -p "$LIFECYCLE"
printf 'schema=gaai-daemon-lifecycle/v1\nstate=pending\nattempt=orphan\nsocket=%s\nsession=%s\n' \
  "$(gaai_run "$ROOT" "$START" --status 2>/dev/null | sed -n 's/^  socket: *//p')" \
  "$(gaai_run "$ROOT" "$START" --status 2>/dev/null | sed -n 's/^  session: *//p')" > "$OWNER"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'Daemon started'; then
  pass "TC7-1: a pending record with no server is settled evidence and a fresh start proceeds"
else
  fail "TC7-1: a pre-tmux crash blocked forever: $(echo "$OUT" | tail -1)"
fi

echo ""
echo "=== TC8: a corrupt owner record blocks every path ==="
gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1
mkdir -p "$LIFECYCLE"; printf 'garbage\n' > "$OWNER"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
echo "$OUT" | grep -q 'reason=process_authority_invalid' \
  && pass "TC8-1: a corrupt owner blocks startup" || fail "TC8-1: a corrupt owner did not block startup: $OUT"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
echo "$OUT" | grep -q 'evidence=owner_role=corrupt_record' \
  && pass "TC8-2: a corrupt owner names no settlement target and blocks --stop" \
  || fail "TC8-2: --stop acted on a corrupt owner: $OUT"
OUT="$(gaai_run "$ROOT" "$START" --status 2>&1)"
echo "$OUT" | grep -q 'state:       corrupt' \
  && pass "TC8-3: --status reports the corrupt state read-only" || fail "TC8-3: --status hid the corrupt state"
rm -f "$OWNER"

echo ""
echo "=== TC9: owner identity drift blocks settlement ==="
fresh_home
gaai_run "$ROOT" "$START" >/dev/null 2>&1
SOCK="$(socket_of)"
cp "$OWNER" "$ROOT/owner.bak"
sed 's#^socket=.*#socket=/tmp/.gaai-d-0/deadbeefdeadbeef#' "$ROOT/owner.bak" > "$OWNER"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
echo "$OUT" | grep -qE 'owner_role=(ambiguous|identity_drift)' \
  && pass "TC9-1: a swapped socket identity blocks settlement" \
  || fail "TC9-1: a swapped socket identity was settled anyway: $OUT"
cp "$ROOT/owner.bak" "$OWNER"
sed 's#^session=.*#session=gaai-daemon-0000000000000000#' "$ROOT/owner.bak" > "$OWNER"
OUT="$(gaai_run "$ROOT" "$START" --stop 2>&1)"
echo "$OUT" | grep -qE 'owner_role=(ambiguous|identity_drift)' \
  && pass "TC9-2: a swapped session identity blocks settlement" \
  || fail "TC9-2: a swapped session identity was settled anyway: $OUT"
cp "$ROOT/owner.bak" "$OWNER"
gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1

echo ""
echo "=== TC10: the release barrier — one record, exact match, no release otherwise ==="
fresh_home
# Bounded child harness, defined unconditionally so every case that runs a
# child directly (TC10 and TC11) shares the same FIFO discipline and timeout.
run_child_with_record() {
  local _dir="$1" _payload="$2" _pid
  # The test holds the FIFO open read-write so the child's own open never blocks,
  # runs the child in the background, writes the payload, then CLOSES the write end.
  # Closing matters: a payload with no terminator must reach the child as EOF, and
  # a writer left open would make the child sit on its full read timeout instead.
  exec 9<> "$_dir/release.fifo" || return 1
  /usr/bin/env -i "PATH=$ROOT/fakebin:/usr/bin:/bin" "HOME=$ROOT/opshome" TERM=dumb \
    "$LAUNCHER" --daemon-child "$_dir" > "$_dir/child.out" 2>&1 &
  _pid=$!
  # No timing assumption: keep the writer open until the child has either opened
  # its end (it writes ack.launcher right after) or refused earlier (child_failed).
  # Only then deliver the payload and close, so EOF can never precede the open.
  local _waited=0
  while [[ ! -e "$_dir/ack.launcher" && ! -e "$_dir/ack.child_failed" ]] && kill -0 "$_pid" 2>/dev/null; do
    sleep 0.2; _waited=$(( _waited + 1 )); [[ "$_waited" -ge 300 ]] && break
  done
  printf '%s' "$_payload" >&9
  exec 9>&-
  # Bounded: a child that never reaches its FIFO open, or blocks on it, must go
  # red with a typed timeout rather than hang the whole suite.
  ( sleep 60; kill "$_pid" 2>/dev/null ) >/dev/null 2>&1 & local _watchdog=$!
  wait "$_pid" 2>/dev/null; local _rc=$?
  # Reap the watchdog AND its sleep: killing only the subshell would leave the
  # sleep running and a `wait` on it would cost the full bound on every call.
  pkill -P "$_watchdog" 2>/dev/null; kill "$_watchdog" 2>/dev/null
  cat "$_dir/child.out" 2>/dev/null
  if [[ "$_rc" -eq 143 || "$_rc" -eq 137 ]]; then
    # Reported on stderr and by return code: this function runs inside a command
    # substitution, so a pass/fail emitted here would be captured, not counted.
    printf '  child under test exceeded the 60s bound in %s (timeout, not a verdict)\n' "$(basename "$_dir")" >&2
    return 124
  fi
  return 0
}

gaai_run "$ROOT" "$START" >/dev/null 2>&1
ATT="$(attempt_of)"
if [[ -n "$ATT" ]]; then
  RELEASE_DIGEST="$(sed -n 's/^release_digest=//p' "$ATT/manifest" | head -1)"
  ATTEMPT_ID="$(sed -n 's/^attempt=//p' "$ATT/manifest" | head -1)"
  RECORD="release attempt=$ATTEMPT_ID digest=$RELEASE_DIGEST"
  [[ "${#RECORD}" -le 512 ]] \
    && pass "TC10-1: the release record (${#RECORD} bytes) fits within the guaranteed PIPE_BUF" \
    || fail "TC10-1: the release record exceeds the guaranteed PIPE_BUF"
  [[ -p "$ATT/release.fifo" ]] \
    && pass "TC10-2: the barrier is a FIFO in the private 0700 directory" \
    || fail "TC10-2: no FIFO at the barrier path"
  # A child that never receives its EXACT record must not run the daemon. The test
  # holds the FIFO open read-write for the whole case: a writer that opened and closed
  # before the child's own open would destroy the buffer and block that open, which
  # would test the harness rather than the barrier.
  LAUNCHER="$(sed -n 's/^launcher=//p' "$OWNER" | head -1)"

  BAD="$ROOT/badattempt"; mkdir -p "$BAD"; chmod 0700 "$BAD"
  cp "$ATT/manifest" "$BAD/manifest"
  mkfifo -m 0600 "$BAD/release.fifo"
  OUT="$(run_child_with_record "$BAD" "release attempt=$ATTEMPT_ID digest=wrongdigest
")" || fail "harness: the child under test for BAD did not finish within the bound"
  if echo "$OUT" | grep -q 'release_role=record_mismatch'; then
    pass "TC10-3: a non-matching release record does not release the child"
  else
    fail "TC10-3: a non-matching release record was accepted: $OUT"
  fi

  BAD2="$ROOT/badattempt2"; mkdir -p "$BAD2"; chmod 0700 "$BAD2"
  cp "$ATT/manifest" "$BAD2/manifest"
  mkfifo -m 0600 "$BAD2/release.fifo"
  OUT="$(run_child_with_record "$BAD2" "release attempt=$ATTEMPT_ID digest=$RELEASE_DIGEST-truncated")" || fail "harness: the child under test for BAD2 did not finish within the bound"
  if echo "$OUT" | grep -qE 'release_role=(read_failed_or_eof|record_mismatch)'; then
    pass "TC10-4: a partial record with no terminator does not release the child"
  else
    fail "TC10-4: a partial record was treated as a release: $OUT"
  fi

  BAD3="$ROOT/badattempt3"; mkdir -p "$BAD3"; chmod 0700 "$BAD3"
  cp "$ATT/manifest" "$BAD3/manifest"
  mkfifo -m 0600 "$BAD3/release.fifo"
  OUT="$(run_child_with_record "$BAD3" "release attempt=someone-elses digest=$RELEASE_DIGEST
")" || fail "harness: the child under test for BAD3 did not finish within the bound"
  if echo "$OUT" | grep -q 'release_role=record_mismatch'; then
    pass "TC10-5: a record naming a different attempt does not release the child"
  else
    fail "TC10-5: a foreign attempt's record was accepted: $OUT"
  fi
else
  fail "TC10-0: no attempt directory recorded"
fi

echo ""
echo "=== TC11: manifest and asset swaps fail closed before the daemon runs ==="
LAUNCHER="$(sed -n 's/^launcher=//p' "$OWNER" | head -1)"
SWAP="$ROOT/swapattempt"; mkdir -p "$SWAP"; chmod 0700 "$SWAP"
sed 's/^daemon_digest=.*/daemon_digest=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$ATT/manifest" > "$SWAP/manifest"
mkfifo -m 0600 "$SWAP/release.fifo"
# Run through the bounded harness with an EMPTY release payload: a child that
# wrongly passes its asset gates meets EOF at the barrier and refuses at once,
# so a weakened proof goes red in seconds instead of waiting out the 300s read.
OUT="$(run_child_with_record "$SWAP" "")" || fail "harness: the child under test for SWAP did not finish within the bound"
echo "$OUT" | grep -q 'daemon_role=fd_blob_mismatch' \
  && pass "TC11-1: a swapped daemon digest is refused at the descriptor, before any release" \
  || fail "TC11-1: a swapped daemon digest was accepted: $OUT"
SWAP2="$ROOT/swapattempt2"; mkdir -p "$SWAP2"; chmod 0700 "$SWAP2"
sed 's#^home=.*#home=/nonexistent/home#' "$ATT/manifest" > "$SWAP2/manifest"
mkfifo -m 0600 "$SWAP2/release.fifo"
# Run through the bounded harness with an EMPTY release payload: a child that
# wrongly passes its asset gates meets EOF at the barrier and refuses at once,
# so a weakened proof goes red in seconds instead of waiting out the 300s read.
OUT="$(run_child_with_record "$SWAP2" "")" || fail "harness: the child under test for SWAP2 did not finish within the bound"
echo "$OUT" | grep -qE 'asset_root_unresolved|daemon_role=absent' \
  && pass "TC11-2: a swapped asset root is refused before any daemon effect" \
  || fail "TC11-2: a swapped asset root was accepted: $OUT"
SWAP3="$ROOT/swapattempt3"; mkdir -p "$SWAP3"; chmod 0700 "$SWAP3"
sed 's/^credential_mode=.*/credential_mode=present/' "$ATT/manifest" > "$SWAP3/manifest"
mkfifo -m 0600 "$SWAP3/release.fifo"
# Run through the bounded harness with an EMPTY release payload: a child that
# wrongly passes its asset gates meets EOF at the barrier and refuses at once,
# so a weakened proof goes red in seconds instead of waiting out the 300s read.
OUT="$(run_child_with_record "$SWAP3" "")" || fail "harness: the child under test for SWAP3 did not finish within the bound"
echo "$OUT" | grep -q 'secret_path_absent\|secret_role=absent' \
  && pass "TC11-3: absent-to-present credential fabrication fails closed" \
  || fail "TC11-3: credential fabrication was accepted: $OUT"

echo ""
echo "=== TC12: the live daemon verifies the home and never repairs it ==="
DD="$SCRIPTS_DIR/delivery-daemon.sh"
if grep -q '_per_cycle_home_check()' "$DD"; then
  pass "TC12-1: delivery-daemon.sh exposes the verify-only per-cycle check"
else
  fail "TC12-1: the verify-only per-cycle check is missing"
fi
if ! grep -n '_gaai_provision_daemon_home "' "$DD" >/dev/null; then
  pass "TC12-2: delivery-daemon.sh invokes no runtime provisioner"
else
  fail "TC12-2: delivery-daemon.sh still invokes a runtime provisioner"
fi
if grep -q 'declare -F _gaai_provision_daemon_home' "$DD"; then
  pass "TC12-3: delivery-daemon.sh refuses a stale library carrying the retired provisioner"
else
  fail "TC12-3: the stale-library guard is missing"
fi
if grep -q 'GAAI_DAEMON_LAUNCH_ATTEMPT' "$DD" && grep -q 'ack.ready' "$DD"; then
  pass "TC12-4: delivery-daemon.sh validates its launch tuple and acknowledges readiness"
else
  fail "TC12-4: the launch-tuple validation or ready acknowledgement is missing"
fi
if grep -q 'credential_downgrade' "$DD" && grep -q 'credential_fabrication' "$DD"; then
  pass "TC12-5: the daemon fails closed on credential downgrade and fabrication"
else
  fail "TC12-5: the daemon does not check credential-mode integrity"
fi

echo ""
echo "=== TC13: wrapper-drain authority is unchanged (non-regression) ==="
if grep -q '_list_live_wrappers()' "$SCRIPTS_DIR/daemon-start.sh" \
   && grep -q '_drain_wrappers()' "$SCRIPTS_DIR/daemon-start.sh"; then
  pass "TC13-1: the orthogonal wrapper-drain functions are retained"
else
  fail "TC13-1: the wrapper-drain authority was lost"
fi
if grep -q 'GAAI_STOP_DRAIN_TIMEOUT' "$SCRIPTS_DIR/daemon-start.sh"; then
  pass "TC13-2: the drain timeout override is retained"
else
  fail "TC13-2: the drain timeout override was lost"
fi
# The drain SIGTERMs wrapper PIDs from lock files — never the daemon PID. Settlement
# targets the persisted session, so no failure path signals daemon authority directly.
if ! grep -nE 'kill (-[A-Z]+ )?"\$(_pid|_ack_pid|_pane_pid)"' "$SCRIPTS_DIR/daemon-start.sh" >/dev/null; then
  pass "TC13-3: no failure path signals the daemon PID directly"
else
  fail "TC13-3: a path signals the daemon PID directly:"
  grep -nE 'kill (-[A-Z]+ )?"\$(_pid|_ack_pid|_pane_pid)"' "$SCRIPTS_DIR/daemon-start.sh" | sed 's/^/        /'
fi

echo ""
echo "=== TC14: operator-state paths still follow the real checkout ==="
if grep -qE '^[[:space:]]*export GAAI_REPO_ROOT="\$PROJECT_ROOT"' "$SCRIPTS_DIR/daemon-start.sh"; then
  pass "TC14-1: daemon-start.sh exports GAAI_REPO_ROOT=PROJECT_ROOT"
else
  fail "TC14-1: GAAI_REPO_ROOT export was lost"
fi
for _v in GAAI_REPO_ROOT GAAI_CI_TEST_GATE_TIMEOUT_SEC GAAI_CI_TEST_GATE_MATERIALIZE_SEC; do
  if grep -qE "tmux_env_args\+=\(-e \"$_v=" "$SCRIPTS_DIR/daemon-start.sh"; then
    pass "TC14-2[$_v]: still forwarded to the session environment"
  else
    fail "TC14-2[$_v]: no longer forwarded"
  fi
done

echo ""
echo "=== TC15: exact restart settlement ==="
fresh_home
gaai_run "$ROOT" "$START" >/dev/null 2>&1
SOCK1="$(socket_of)"; PID1="$(sed -n 's/^child_pid=//p' "$OWNER" | head -1)"
OUT="$(gaai_run "$ROOT" "$START" --restart 2>&1)"
PID2="$(sed -n 's/^child_pid=//p' "$OWNER" | head -1)"
if echo "$OUT" | grep -q 'Daemon started' && [[ -n "$PID2" && "$PID1" != "$PID2" ]]; then
  pass "TC15-1: --restart settled the old lifecycle and established a new one"
else
  fail "TC15-1: --restart did not produce a new lifecycle (pid1=$PID1 pid2=$PID2)"
fi
if ! kill -0 "$PID1" 2>/dev/null; then
  pass "TC15-2: the previous daemon process is gone"
else
  fail "TC15-2: the previous daemon process survived the restart"
fi
[[ "$(state_of)" == "running" ]] && pass "TC15-3: the new lifecycle reached durable running" \
                                 || fail "TC15-3: the new lifecycle did not reach running"

echo ""
echo "=== TC16: a clean stop leaves no server, socket, owner or attempt residue ==="
SOCK="$(socket_of)"; ATT="$(attempt_of)"
gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1
[[ ! -e "$OWNER" ]] && pass "TC16-1: the owner record is removed" || fail "TC16-1: the owner record survives"
[[ ! -e "$SOCK" ]] && pass "TC16-2: the exact persisted socket is removed" || fail "TC16-2: the socket survives"
[[ ! -d "$ATT" ]] && pass "TC16-3: the exact persisted attempt directory is removed" \
                  || fail "TC16-3: the attempt directory survives"
OUT="$(gaai_run "$ROOT" "$START" --status 2>&1)"
echo "$OUT" | grep -q 'state:       none' \
  && pass "TC16-4: --status reports a settled lifecycle" || fail "TC16-4: --status does not report settled"

echo ""
echo "=== TC17: a target that advances mid-attempt is a race, not a refresh ==="
fresh_home
# Advance origin/staging after setup converged the home: the home is now stale and
# the first observation already refuses. This is the same guard the second
# observation applies inside a single attempt.
gaai_advance_target "$PROJ"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
echo "$OUT" | grep -qE 'reason=(home_identity_invalid|target_advanced)' \
  && pass "TC17-1: an advanced target refuses rather than launching against a stale home" \
  || fail "TC17-1: an advanced target was accepted: $OUT"
[[ ! -e "$OWNER" ]] \
  && pass "TC17-2: the refusal created no owner record, server or session" \
  || fail "TC17-2: a refused attempt left lifecycle state behind"

echo ""
echo "=== TC18: an unreachable target fails closed, without a cached-ref fallback ==="
fresh_home
git -C "$PROJ" remote set-url origin /nonexistent/remote.git
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
echo "$OUT" | grep -q 'reason=target_fetch_failed action=none' \
  && pass "TC18-1: a failed fetch returns target_fetch_failed + none" \
  || fail "TC18-1: a failed fetch did not fail closed: $OUT"
[[ ! -e "$OWNER" ]] \
  && pass "TC18-2: no lifecycle was created against a cached ref" \
  || fail "TC18-2: a lifecycle was created despite an unreachable target"
git -C "$PROJ" remote set-url origin "$ROOT/remote.git"


echo ""
echo "=== TC19-7: the rebind accepts both of this daemon's own writers, and only those ==="
# Behavioural, not a grep: extract the classifier and run it against a real
# commit chain. The journal writer stamps `[dispatch]`, the claim writer
# `[daemon]`; an `[operator]` write is human and must still refuse.
_fn_start=$(grep -n '^_rebind_target_after_self_claim()' "$DD" | cut -d: -f1)
_fn_end=$(awk -v s="$_fn_start" 'NR>s && /^}/ {print NR; exit}' "$DD")
_fn_src=$(sed -n "${_fn_start},${_fn_end}p" "$DD")
_rb=$(mktemp -d "${TMPDIR:-/tmp}/tc19-7.XXXXXX")
git init -q --bare "$_rb/remote.git"
git -c init.defaultBranch=staging init -q "$_rb/home"
git -C "$_rb/home" remote add origin "$_rb/remote.git"
_gc() { git -C "$_rb/home" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
_gc "base"; _bound=$(git -C "$_rb/home" rev-parse HEAD)
_gc "chore(story): in_progress [daemon]"
_gc "chore(framework): project lifecycle journal [dispatch]"
git -C "$_rb/home" push -q origin HEAD:staging 2>/dev/null
_out=$(/bin/bash -c "
  log() { :; }
  $_fn_src
  GAAI_DAEMON_HOME='$_rb/home' GAAI_TARGET_SHA='$_bound' TARGET_BRANCH=staging
  if _rebind_target_after_self_claim; then echo rebound=\$GAAI_TARGET_SHA; else echo refused blocked=\${_GAAI_REBIND_BLOCKED_BY:-none}; fi
")
_head=$(git -C "$_rb/home" rev-parse HEAD)
if [[ "$_out" == "rebound=$_head" ]]; then
  pass "TC19-7a: an advance made only of [daemon] and [dispatch] writes rebinds"
else
  fail "TC19-7a: the daemon's own journal write was treated as foreign: $_out"
fi
_gc "chore(story): reset to refined [operator]"
git -C "$_rb/home" push -q origin HEAD:staging 2>/dev/null
_out=$(/bin/bash -c "
  log() { :; }
  $_fn_src
  GAAI_DAEMON_HOME='$_rb/home' GAAI_TARGET_SHA='$_bound' TARGET_BRANCH=staging
  if _rebind_target_after_self_claim; then echo rebound; else echo refused blocked=\${_GAAI_REBIND_BLOCKED_BY:-none}; fi
")
if [[ "$_out" == refused*operator* ]]; then
  pass "TC19-7b: an interleaved [operator] write still refuses and is named"
else
  fail "TC19-7b: a human write was accepted as the daemon's own: $_out"
fi
rm -rf "$_rb"

echo ""
echo "=== TC19: a target that advanced past the launch tuple is diagnosed once, with its cause ==="
# The daemon pins its home to the sha its launch proved. When the target advances
# past it the exact-current model halts every cycle — correctly — but until now the
# log showed only `home_role=stale_head` repeating every poll, naming neither the
# advance nor the remedy, and a foreign commit interleaved with the daemon's own
# backlog projection silently defeated the self-claim rebind.
DD="$SCRIPTS_DIR/delivery-daemon.sh"

if grep -q '_GAAI_REBIND_BLOCKED_BY' "$DD"; then
  pass "TC19-1: the rebind records what blocked it"
else
  fail "TC19-1: the rebind still refuses without recording a cause"
fi

if sed -n '/^_rebind_target_after_self_claim()/,/^}/p' "$DD" | grep -q 'foreign='; then
  pass "TC19-2: the rebind separates foreign commits from this daemon's own projection"
else
  fail "TC19-2: the rebind does not identify the foreign commits"
fi

if sed -n '/^_per_cycle_home_check()/,/^}/p' "$DD" | grep -q '_GAAI_HOME_REFUSAL_REPORTED'; then
  pass "TC19-3: the per-cycle refusal is reported per distinct advance, not per poll"
else
  fail "TC19-3: the per-cycle refusal still repeats on every poll"
fi

if sed -n '/^_per_cycle_home_check()/,/^}/p' "$DD" | grep -q 'an authorized restart'; then
  pass "TC19-4: the refusal names the remedy"
else
  fail "TC19-4: the refusal does not name the remedy"
fi

# The refusal must still be fail-closed: no rebind, no repair, no continuation.
if sed -n '/^_per_cycle_home_check()/,/^}/p' "$DD" | grep -q 'return 1'; then
  pass "TC19-5: a refused home still stops the cycle"
else
  fail "TC19-5: a refused home no longer stops the cycle"
fi

# Behavioural: a foreign commit between the bound sha and the new head must defeat
# the rebind, and the daemon must say so.
TC19_ROOT="$ROOT/tc19"; mkdir -p "$TC19_ROOT"
git init --quiet --bare "$TC19_ROOT/remote.git"
git clone --quiet "$TC19_ROOT/remote.git" "$TC19_ROOT/home" 2>/dev/null
git -C "$TC19_ROOT/home" config user.email t@t.t
git -C "$TC19_ROOT/home" config user.name t
git -C "$TC19_ROOT/home" checkout -q -b staging
echo seed > "$TC19_ROOT/home/seed.txt"
git -C "$TC19_ROOT/home" add -A && git -C "$TC19_ROOT/home" commit -q -m seed
git -C "$TC19_ROOT/home" push -q origin staging
TC19_BOUND=$(git -C "$TC19_ROOT/home" rev-parse HEAD)
echo a > "$TC19_ROOT/home/a.txt"; git -C "$TC19_ROOT/home" add -A
git -C "$TC19_ROOT/home" commit -q -m 'chore(backlog): reset a row [operator]'
echo b > "$TC19_ROOT/home/b.txt"; git -C "$TC19_ROOT/home" add -A
git -C "$TC19_ROOT/home" commit -q -m 'chore(STORY-1): in_progress [daemon]'
git -C "$TC19_ROOT/home" push -q origin staging
git -C "$TC19_ROOT/home" fetch -q origin staging

# delivery-daemon.sh runs launch guards at load, so the function is extracted
# rather than sourced — the same idiom the other daemon suites use.
TC19_FN="$TC19_ROOT/rebind.sh"
sed -n '/^_rebind_target_after_self_claim()/,/^}/p' "$DD" > "$TC19_FN"
TC19_OUT=$(
  GAAI_DAEMON_HOME="$TC19_ROOT/home" GAAI_TARGET_SHA="$TC19_BOUND" TARGET_BRANCH=staging \
  /bin/bash -c '
    log() { :; }
    . "'"$TC19_FN"'"
    if _rebind_target_after_self_claim; then echo "REBOUND:$GAAI_TARGET_SHA"; else echo "REFUSED:${_GAAI_REBIND_BLOCKED_BY:-none}"; fi
  ' 2>/dev/null | tail -1
)
case "$TC19_OUT" in
  REFUSED:*operator*) pass "TC19-6: a foreign commit in the advance defeats the rebind and is named" ;;
  REFUSED:*)          fail "TC19-6: the rebind refused but did not name the foreign commit: $TC19_OUT" ;;
  *)                  fail "TC19-6: the rebind accepted an advance it did not author: $TC19_OUT" ;;
esac

echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
exit 0
