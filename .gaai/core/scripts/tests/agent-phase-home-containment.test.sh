#!/usr/bin/env bash
# ── agent-phase-home-containment.test.sh ───────────────────────────────────
# An agent phase inherits the daemon's private HOME. A Story whose own suite
# launches a daemon re-provisions the entry-owned identity paths there, and
# from that point the live daemon can no longer authenticate its fetches: the
# phase's durable projection is rejected as source_unavailable and the cycle is
# discarded. The phase therefore snapshots those paths before the agent starts
# and restores them when it ends.
#
# Run: bash .gaai/core/scripts/tests/agent-phase-home-containment.test.sh
# Exit 0 = all pass.

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMPDIR_TEST="$(mktemp -d /tmp/gaai-home-containment-test-XXXXXX)"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

export PROJECT_DIR="$REPO_ROOT"
export LOCK_DIR="$TMPDIR_TEST/locks"
WORKTREE="$TMPDIR_TEST/worktree"
FAKEBIN="$TMPDIR_TEST/bin"
SHARED_HOME="$TMPDIR_TEST/private-home"
mkdir -p "$LOCK_DIR" "$WORKTREE/.delivery-logs" "$FAKEBIN" "$SHARED_HOME"

PROMPT_FILE="$TMPDIR_TEST/prompt.md"
printf 'Deliver the Story.\n' > "$PROMPT_FILE"

# The two-line credential configuration the daemon entry owns: the leading
# empty helper resets the chain accumulated from higher-level config files.
DAEMON_GITCONFIG="$TMPDIR_TEST/daemon.gitconfig"
printf '[credential]\n\thelper =\n\thelper = !gh auth git-credential\n' > "$DAEMON_GITCONFIG"
seed_home() {
  rm -rf "$SHARED_HOME"
  mkdir -p "$SHARED_HOME"
  ( umask 077; cp "$DAEMON_GITCONFIG" "$SHARED_HOME/.gitconfig" )
  ln -sf "$TMPDIR_TEST/operator-account.json" "$SHARED_HOME/.claude.json"
}

# Stands in for a Story's own "real daemon" smoke: it re-provisions the live
# home exactly as a fixture copy of the entry would.
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
if [[ "${FAKE_AGENT_REWRITES_HOME:-0}" == "1" ]]; then
  printf '#!/usr/bin/env bash\nprintf "username=fixture\\n"\n' \
    > "$GAAI_SHARED_HOME_ROOT/.gaai-git-credential-helper.sh"
  chmod 700 "$GAAI_SHARED_HOME_ROOT/.gaai-git-credential-helper.sh"
  printf '[credential]\n\thelper = !%s/.gaai-git-credential-helper.sh\n' \
    "$GAAI_SHARED_HOME_ROOT" > "$GAAI_SHARED_HOME_ROOT/.gitconfig"
  rm -f "$GAAI_SHARED_HOME_ROOT/.claude.json"
fi
printf '{"type":"result","subtype":"success"}\n'
SH
chmod +x "$FAKEBIN/claude"

# shellcheck source=../daemon-dispatch.sh
source "$REPO_ROOT/.gaai/core/scripts/daemon-dispatch.sh"

run_phase() {
  local story_id="$1" phase="$2" log_path="$WORKTREE/.delivery-logs/${1}.${2}.log"
  : > "$log_path"
  PATH="$FAKEBIN:$PATH" \
  GAAI_SHARED_HOME_ROOT="$SHARED_HOME" \
    _run_claude_with_loop_breaker "$story_id" "$phase" "$log_path" "$PROMPT_FILE" "$WORKTREE" 2>&1
}

echo "T1: an agent that re-provisions the private home leaves it as the daemon wrote it"
seed_home
OUT=$(FAKE_AGENT_REWRITES_HOME=1 run_phase T-REWRITE impl)

if cmp -s "$SHARED_HOME/.gitconfig" "$DAEMON_GITCONFIG"; then
  pass "T1a: the daemon's credential configuration is byte-identical after the phase"
else
  fail "T1a: gitconfig not restored"
fi
if [[ ! -e "$SHARED_HOME/.gaai-git-credential-helper.sh" ]]; then
  pass "T1b: the helper script the agent left behind is gone"
else
  fail "T1b: agent helper script survived the phase"
fi
if [[ -L "$SHARED_HOME/.claude.json" \
      && "$(readlink "$SHARED_HOME/.claude.json")" == "$TMPDIR_TEST/operator-account.json" ]]; then
  pass "T1c: the executor account link the agent removed is back"
else
  fail "T1c: executor account link not restored"
fi

RESTORE_LINE=$(printf '%s\n' "$OUT" | grep -c '^\[SHARED-HOME\] .* result=restored ')
if [[ "$RESTORE_LINE" -eq 1 ]]; then
  pass "T1d: the repair emits exactly one log line"
else
  fail "T1d: expected 1 restore log line, got $RESTORE_LINE"
fi
if printf '%s\n' "$OUT" | grep -q '^\[SHARED-HOME\] story=T-REWRITE phase=impl result=restored paths=.*\.gitconfig'; then
  pass "T1e: the log line names the story, the phase and the restored path"
else
  fail "T1e: restore log line missing or malformed: $(printf '%s\n' "$OUT" | grep '\[SHARED-HOME\]')"
fi
if printf '%s\n' "$OUT" | grep -q 'gaai-git-credential-helper.sh'; then
  pass "T1f: the log line names the helper path it removed"
else
  fail "T1f: helper path not named in the log"
fi

echo "T2: a phase that leaves the home alone is silent"
seed_home
OUT=$(FAKE_AGENT_REWRITES_HOME=0 run_phase T-CLEAN qa)
if ! printf '%s\n' "$OUT" | grep -q '^\[SHARED-HOME\]'; then
  pass "T2a: no repair line when nothing drifted"
else
  fail "T2a: unexpected repair line on an untouched home"
fi
if cmp -s "$SHARED_HOME/.gitconfig" "$DAEMON_GITCONFIG"; then
  pass "T2b: the untouched configuration is left exactly as it was"
else
  fail "T2b: untouched configuration was modified"
fi

echo "T3: the repair defers while an admission gate is executing"
seed_home
sleep 120 &
GATE_PID=$!
printf 'pid=%s\n' "$GATE_PID" > "${LOCK_DIR}/.admission-gate-active.${GATE_PID}"
OUT=$(FAKE_AGENT_REWRITES_HOME=1 GAAI_SHARED_HOME_RESTORE_WAIT_SECONDS=0 run_phase T-GATE impl)
kill "$GATE_PID" 2>/dev/null || true
wait "$GATE_PID" 2>/dev/null || true

if printf '%s\n' "$OUT" | grep -q '^\[SHARED-HOME\] story=T-GATE phase=impl result=deferred reason=admission_gate_active '; then
  pass "T3a: the deferral is logged with its reason"
else
  fail "T3a: expected a deferred line: $(printf '%s\n' "$OUT" | grep '\[SHARED-HOME\]')"
fi
if ! cmp -s "$SHARED_HOME/.gitconfig" "$DAEMON_GITCONFIG"; then
  pass "T3b: nothing was rewritten under the running gate"
else
  fail "T3b: the home was repaired while a gate was in flight"
fi
rm -f "${LOCK_DIR}"/.admission-gate-active.*

echo "T4: a marker whose writer is gone never inhibits the repair"
seed_home
DEAD_PID_MARKER=""
for candidate in $(seq 30000 30200); do
  kill -0 "$candidate" 2>/dev/null || { DEAD_PID_MARKER="$candidate"; break; }
done
if [[ -n "$DEAD_PID_MARKER" ]]; then
  printf 'pid=%s\n' "$DEAD_PID_MARKER" > "${LOCK_DIR}/.admission-gate-active.${DEAD_PID_MARKER}"
  OUT=$(FAKE_AGENT_REWRITES_HOME=1 GAAI_SHARED_HOME_RESTORE_WAIT_SECONDS=0 run_phase T-STALE impl)
  if cmp -s "$SHARED_HOME/.gitconfig" "$DAEMON_GITCONFIG"; then
    pass "T4a: the repair ran despite the stale marker"
  else
    fail "T4a: a stale marker blocked the repair"
  fi
  if [[ ! -e "${LOCK_DIR}/.admission-gate-active.${DEAD_PID_MARKER}" ]]; then
    pass "T4b: the stale marker was swept"
  else
    fail "T4b: stale marker survived"
  fi
else
  fail "T4: could not find an unused pid to build a stale marker"
fi
rm -f "${LOCK_DIR}"/.admission-gate-active.*

echo "T5: the repair names paths and never credential material"
seed_home
printf 'helper = !/usr/bin/secret-bearing-helper\n' > "$SHARED_HOME/.gitconfig"
OUT=$(FAKE_AGENT_REWRITES_HOME=1 run_phase T-QUIET impl)
if ! printf '%s\n' "$OUT" | grep '^\[SHARED-HOME\]' | grep -q 'secret-bearing-helper\|gh auth git-credential'; then
  pass "T5a: no line of either configuration reaches the log"
else
  fail "T5a: the repair log carried file content"
fi

echo "T6: a wrapper that is not on the daemon's private home touches nothing"
OPERATOR_HOME="$TMPDIR_TEST/operator-home"
mkdir -p "$OPERATOR_HOME"
printf 'operator\n' > "$OPERATOR_HOME/.gitconfig"
OUT=$(PATH="$FAKEBIN:$PATH" HOME="$OPERATOR_HOME" FAKE_AGENT_REWRITES_HOME=0 \
  _run_claude_with_loop_breaker T-OPHOME plan "$WORKTREE/.delivery-logs/T-OPHOME.plan.log" \
  "$PROMPT_FILE" "$WORKTREE" 2>&1)
if [[ "$(cat "$OPERATOR_HOME/.gitconfig")" == "operator" ]] \
   && ! printf '%s\n' "$OUT" | grep -q '^\[SHARED-HOME\]'; then
  pass "T6a: an operator HOME is neither snapshotted nor rewritten"
else
  fail "T6a: the containment engaged outside the daemon's private root"
fi

echo
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
