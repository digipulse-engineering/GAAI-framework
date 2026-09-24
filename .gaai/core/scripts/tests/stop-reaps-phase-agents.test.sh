#!/usr/bin/env bash
# ── stop-reaps-phase-agents.test.sh ─────────────────────────────────────────
# `daemon-start.sh --stop` must never leave a phase agent running.
#
# A delivery wrapper's SIGTERM only asks it to stop after the current phase, and
# Bash defers the trap while the phase's command substitution is pending, so a
# long phase outlasts the drain. The escalation then kills the wrapper — but the
# phase agent is not in the wrapper's process group (`timeout` leads a group of
# its own), so it was reparented to init and kept writing to the Story worktree
# after "Daemon stopped".
#
# Hermetic: every process signalled here is a fake this suite spawns in its own
# temporary directory (a fake wrapper, `timeout` from the host, and bash stand-ins
# for the node spawner and the model CLI). The drain functions are extracted from
# the shipped `daemon-start.sh` and run under its own `set -euo pipefail`, with no
# tmux server — so the privileged entry, its private roots and any running daemon
# are never touched.
#
# Run: bash .gaai/core/scripts/tests/stop-reaps-phase-agents.test.sh
# Exit 0 = all pass.

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
START="$SCRIPTS_DIR/daemon-start.sh"
SETUP="$SCRIPTS_DIR/daemon-setup.sh"
DISPATCH="$SCRIPTS_DIR/daemon-dispatch.sh"
PROJECT_ROOT_FOR_DISPATCH="$(cd "$SCRIPTS_DIR/../../.." && pwd -P)"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
ck() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gaai-stop-reap.XXXXXX")"
T="$(cd "$T" && pwd -P)"
REG="$T/spawned"
: > "$REG"

# Harness-own identity: pid + start stamp of every fake process, so cleanup can
# never signal a pid the OS has since handed to something else.
_t_stamp() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'; }
_t_alive() { kill -0 "$1" 2>/dev/null && [[ -n "$2" && "$(_t_stamp "$1")" == "$2" ]]; }
_t_register() { printf '%s %s\n' "$1" "$(_t_stamp "$1")" >> "$REG"; }
_t_alive_pid() { local s; s=$(grep "^$1 " "$REG" 2>/dev/null | head -1 | cut -d' ' -f2-); _t_alive "$1" "$s"; }

cleanup() {
  local pid stamp
  while read -r pid stamp; do
    [[ -n "$pid" ]] && _t_alive "$pid" "$stamp" && kill -KILL "$pid" 2>/dev/null
  done < "$REG"
  rm -rf "$T"
}
trap cleanup EXIT

# Nothing below may read or write the operator's configuration.
export HOME="$T/home" XDG_CONFIG_HOME="$T/xdg" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
unset GAAI_SHARED_HOME_ROOT GAAI_PLAN_MODEL GAAI_QA_MODEL GAAI_IMPL_MODEL GIT_EDITOR 2>/dev/null || true

export LOCK_DIR="$T/locks"
export GAAI_T_DIR="$T" GAAI_T_REG="$REG" GAAI_T_DISPATCH="$DISPATCH"
export GAAI_T_PROJECT="$PROJECT_ROOT_FOR_DISPATCH"
mkdir -p "$LOCK_DIR" "$T/bin" "$T/fakebin"
printf 'prompt\n' > "$T/prompt"

# ── Fakes ───────────────────────────────────────────────────────────────────
# The model CLI: keeps writing to the worktree; on TERM makes one final write
# and exits, as a real agent finishing its last step would.
cat > "$T/bin/fake-claude" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$$" "$(TZ=UTC LC_ALL=C ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //;s/ $//')" >> "$GAAI_T_REG"
echo "$$" > "$GAAI_T_DIR/$GAAI_T_SID.claude.pid"
trap 'echo "final write on TERM" >> "$PWD/work.txt"; exit 143' TERM
printf '{"type":"system","subtype":"init"}\n'
while :; do echo tick >> "$PWD/work.txt"; sleep 0.2; done
SH
# The node spawner: runs the CLI as a child and ends it when TERMed.
cat > "$T/bin/fake-spawner" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$$" "$(TZ=UTC LC_ALL=C ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //;s/ $//')" >> "$GAAI_T_REG"
"$BASH" "$GAAI_T_DIR/bin/fake-claude" & c=$!
trap 'kill -TERM "$c" 2>/dev/null; wait "$c"; exit 143' TERM
wait "$c"
SH
printf '#!/usr/bin/env bash\nexec "$BASH" "%s/bin/fake-claude" "$@"\n' "$T" > "$T/fakebin/claude"
chmod +x "$T/bin/fake-claude" "$T/bin/fake-spawner" "$T/fakebin/claude"

# The wrapper: the generated wrapper's signal contract (SIGTERM sets an
# interrupt flag and is honoured only at the next loop boundary; the lock file
# holds its pid), launching one phase the way daemon-dispatch.sh does.
#   impl — the claude-harness impl shape: `timeout … <spawner>` inside $(…)
#   loop — the real _run_claude_with_loop_breaker (plan/QA/codex shape)
# The worktree path travels in the environment only: a wrapper whose argv held
# it would be matched by the worktree orphan reaper.
cat > "$T/wrapper.sh" <<'SH'
set +e
SID="$1"; MODE="$2"
printf '%s %s\n' "$$" "$(TZ=UTC LC_ALL=C ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //;s/ $//')" >> "$GAAI_T_REG"
export GAAI_T_SID="$SID"
PROJECT_DIR="$GAAI_T_PROJECT"
source "$GAAI_T_DISPATCH" || exit 90
LOCK_FILE="$LOCK_DIR/$SID.lock"
echo $$ > "$LOCK_FILE"
_INTERRUPT_REQUESTED=0
trap '_INTERRUPT_REQUESTED=1; date +%s > "$LOCK_DIR/$SID.interrupted"' TERM INT
trap 'echo "exit" > "$GAAI_T_DIR/$SID.wrapper-exit"; rm -f "$LOCK_FILE"' EXIT
cd "$GAAI_T_WT" || exit 91
case "$MODE" in
  impl)
    to=$(_resolve_timeout_cmd); prefix=()
    [[ -n "$to" ]] && prefix=("$to" --kill-after=15s 7200s)
    if declare -F _phase_agent_exec >/dev/null 2>&1; then
      out=$(_phase_agent_exec "$SID" ${prefix[@]+"${prefix[@]}"} "$BASH" "$GAAI_T_DIR/bin/fake-spawner")
    else
      # The launch shape before identity records existed.
      out=$(exec ${prefix[@]+"${prefix[@]}"} "$BASH" "$GAAI_T_DIR/bin/fake-spawner")
    fi
    rc=$?
    declare -F _phase_agent_clear >/dev/null 2>&1 && _phase_agent_clear "$SID"
    ;;
  loop)
    PATH="$GAAI_T_DIR/fakebin:$PATH" GAAI_DAEMON_EXECUTOR=claude GAAI_PHASE_TIMEOUT_SEC=7200 \
      _run_claude_with_loop_breaker "$SID" qa "$GAAI_T_DIR/$SID.log" "$GAAI_T_DIR/prompt" "$GAAI_T_WT" >/dev/null 2>&1
    rc=$?
    ;;
esac
echo "$rc" > "$GAAI_T_DIR/$SID.phase-rc"
[[ "$rc" -ne 0 ]] && _impl_commit_truncated "$SID" "$GAAI_T_WT" executor_exit >> "$GAAI_T_DIR/$SID.wrapper.out" 2>&1
exit 1
SH

make_worktree() {  # <sid> — a story branch with one commit
  local wt="$T/$1-workspace"
  git init -q "$wt"
  git -C "$wt" checkout -q -b "story/$1"
  git -C "$wt" config user.name fixture
  git -C "$wt" config user.email fixture@example.invalid
  git -C "$wt" config commit.gpgsign false
  echo base > "$wt/base.txt"
  git -C "$wt" add -A && git -C "$wt" commit -qm base
  printf '%s' "$wt"
}

start_wrapper() {  # <sid> <mode> — prints the wrapper pid once its agent is running
  local sid="$1" mode="$2" wt w i
  wt=$(make_worktree "$sid")
  GAAI_T_WT="$wt" "$BASH" "$T/wrapper.sh" "$sid" "$mode" > "$T/$sid.wrapper.out" 2>&1 &
  w=$!
  for i in $(seq 1 100); do
    if [[ -s "$T/$sid.claude.pid" ]]; then
      # A dispatch library without identity records never writes one for impl.
      grep -q '^_phase_agent_exec()' "$DISPATCH" || break
      [[ -s "$LOCK_DIR/$sid.agent.pid" ]] && break
    fi
    sleep 0.1
  done
  sleep 0.5
  printf '%s' "$w"
}

DRAIN_SPAN=$(awk '/^_list_live_wrappers\(\) \{/{f=1} /^# ── Shared bootstrap/{f=0} f' "$START")

run_drain() {  # exactly the shipped drain, under the entry's own shell options
  (
    set -euo pipefail
    STOP_DRAIN_TIMEOUT=1
    STOP_AGENT_GRACE=10
    TMUX_SOCKET=""
    _tmux() { return 1; }
    # shellcheck source=../lib/daemon-home.sh
    source "$SCRIPTS_DIR/lib/daemon-home.sh"
    eval "$DRAIN_SPAN"
    _drain_wrappers
  ) > "$T/drain.out" 2>&1
  echo $? > "$T/drain.rc"
}

# ═══════════════════════════════════════════════════════════════════════════
echo "── 1. a TERM-deferring wrapper mid-impl: stop ends the agent chain ─────"
W1=$(start_wrapper S1 impl)
C1=$(cat "$T/S1.claude.pid")
A1=$(head -1 "$LOCK_DIR/S1.agent.pid" 2>/dev/null || echo "")
_t_alive_pid "$C1" && pass "precondition: the fake agent is running" || fail "precondition: the fake agent did not start"
run_drain
ck "the drain completed without an error under set -euo pipefail" "$(cat "$T/drain.rc")" "0"
_t_alive_pid "$C1" && fail "the model CLI survived the stop" || pass "the model CLI does not survive the stop"
if [[ -n "$A1" ]] && kill -0 "$A1" 2>/dev/null; then fail "the recorded agent head ($A1) survived the stop"
else pass "the recorded agent head does not survive the stop"; fi
[[ -f "$T/S1.wrapper-exit" ]] && pass "the wrapper exited on its own (it was not SIGKILLed)" \
  || fail "the wrapper was killed before it could handle the agent's exit"
ck "the agent was TERMed first and made its final write" "$(grep -c 'final write on TERM' "$T/S1-workspace/work.txt" 2>/dev/null)" "1"
ck "the interrupted work is preserved as a truncated commit" \
   "$(git -C "$T/S1-workspace" log -1 --format=%B 2>/dev/null | grep -c '^GAAI-Truncated: true$')" "1"
ck "the wrapper was never escalated to SIGKILL" "$(grep -c "SIGKILL S1 " "$T/drain.out")" "0"
[[ -e "$LOCK_DIR/S1.agent.pid" ]] && fail "the agent record outlived the agent" || pass "the agent record is cleared"
ck "the interrupt marker is preserved for forward recovery" "$([[ -f "$LOCK_DIR/S1.interrupted" ]] && echo yes)" "yes"

echo "── 2. a wrapper that already died: its orphaned agent is reaped ────────"
W2=$(start_wrapper S2 impl)
C2=$(cat "$T/S2.claude.pid")
kill -KILL "$W2" 2>/dev/null
sleep 1
_t_alive_pid "$C2" && pass "precondition: killing the wrapper does not end its agent (the defect's mechanism)" \
  || fail "precondition: the agent died with its wrapper — the fixture does not reproduce the escape"
run_drain
ck "the drain completed without an error" "$(cat "$T/drain.rc")" "0"
grep -q 'No live wrappers to drain' "$T/drain.out" && pass "no wrapper was left to drain" || fail "a wrapper was unexpectedly live"
_t_alive_pid "$C2" && fail "the orphaned agent survived the stop" || pass "the orphaned agent is reaped"
ck "and was TERMed before anything harder" "$(grep -c 'final write on TERM' "$T/S2-workspace/work.txt" 2>/dev/null)" "1"

echo "── 3. identity: a reused or unproven pid is never signalled ────────────"
# Victims detached from this shell's job table so their end prints no job notice.
V1=$(sleep 300 >/dev/null 2>&1 & echo $!); _t_register "$V1"
V2=$(sleep 300 >/dev/null 2>&1 & echo $!); _t_register "$V2"
printf '%s\nincarnation=%s\n' "$V1" "Thu Jan  1 00:00:00 1970" > "$LOCK_DIR/S3.agent.pid"
printf '%s\n' "$V2" > "$LOCK_DIR/S3b.agent.pid"
run_drain
ck "the drain completed without an error" "$(cat "$T/drain.rc")" "0"
_t_alive_pid "$V1" && pass "a live pid under a different start stamp is not signalled" || fail "a reused pid was signalled"
_t_alive_pid "$V2" && pass "a record without a start stamp is not signalled" || fail "an unproven pid was signalled"
[[ -e "$LOCK_DIR/S3.agent.pid" ]] && fail "the provably stale record was kept" || pass "the provably stale record is removed"
[[ -e "$LOCK_DIR/S3b.agent.pid" ]] && pass "the unproven record is left in place for inspection" || fail "the unproven record was removed"
ck "neither was named as a signal target" "$(grep -c 'phase agent of S3' "$T/drain.out")" "0"
kill -KILL "$V1" "$V2" 2>/dev/null
rm -f "$LOCK_DIR/S3b.agent.pid"

echo "── 4. the loop-breaker launch (plan/QA shape): the agent is reaped ────"
W4=$(start_wrapper S4 loop)
C4=$(cat "$T/S4.claude.pid")
_t_alive_pid "$C4" && pass "precondition: the fake agent is running" || fail "precondition: the fake agent did not start"
ck "the record carries a start stamp" "$(grep -c '^incarnation=.\+' "$LOCK_DIR/S4.agent.pid" 2>/dev/null)" "1"
run_drain
ck "the drain completed without an error" "$(cat "$T/drain.rc")" "0"
_t_alive_pid "$C4" && fail "the agent survived the stop" || pass "the agent does not survive the stop"
[[ -f "$T/S4.wrapper-exit" ]] && pass "the wrapper exited on its own" || fail "the wrapper was killed before it could handle the agent's exit"
# The agent shares the wrapper's process group here, so a group signal would
# have hit the wrapper too; it must instead have seen its agent exit and
# returned from the phase normally.
ck "the wrapper observed the agent's exit (signalled by pid, not by group)" \
   "$([[ -s "$T/S4.phase-rc" ]] && echo yes)" "yes"

echo "── 5. wiring ──────────────────────────────────────────────────────────"
IMPL_SPAN=$(awk '/^handle_impl_phase\(\) \{/{f=1} f{print} /^handle_qa_phase\(\) \{/{if(f) exit}' "$DISPATCH")
LB_SPAN=$(awk '/^_run_claude_with_loop_breaker\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$DISPATCH")
ck "the impl agent is launched through the identity record" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -c '_phase_agent_exec "\$story_id"')" "1"
ck "the loop-breaker agent is recorded with its identity" \
   "$(printf '%s\n' "$LB_SPAN" | grep -c '_phase_agent_record "\$story_id" "\$agent_pid"')" "1"
ck "every synchronous loop-breaker launch is recorded too" \
   "$(printf '%s\n' "$LB_SPAN" | grep -c '_phase_agent_exec "\$story_id"')" "3"
DRAIN_FN=$(awk '/^_drain_wrappers\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$START")
ck "the drain reaps agents before escalating a wrapper" \
   "$(printf '%s\n' "$DRAIN_FN" | awk '/_reap_phase_agents/{r=1} /Escalating to exact tmux kill-session/{print (r?1:0); exit}')" "1"
ck "agents are found by record, never by a command-line pattern" \
   "$(printf '%s\n' "$DRAIN_SPAN" | grep -cE '\bp(kill|grep)\b')" "0"
for _f in "$START" "$SETUP"; do
  ck "$(basename "$_f") admits GAAI_STOP_AGENT_GRACE" \
     "$(sed -n '/^_GAAI_CONFIG_ALLOW=/,/'"'"'$/p' "$_f" | grep -cw GAAI_STOP_AGENT_GRACE)" "1"
done

echo
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
