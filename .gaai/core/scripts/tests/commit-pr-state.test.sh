#!/usr/bin/env bash
# commit-pr-state.test.sh — AC5 regression for E222S02
#
# Asserts that handle_commit_phase guards the merge path by re-reading the
# selected PR's state (via `gh pr view --json state`) before calling the
# head-matched direct merge, when Guard 1 or 2 selected a PR via --state all.
#
# T1: CLOSED PR selected by Guard 2 → gh pr create is called (fresh PR), gh pr
#     merge is NOT called with the closed URL (AC2)
# T2: MERGED PR selected by Guard 2 → phase_status reconciled to done, gh pr
#     merge NOT called (AC3)
# T3: OPEN PR selected by Guard 2   → exact-SHA REST merge is called normally
# T4: merge API transport fails after the exact tested head merged → success
# T5: PR head moves during merge → TEST_GATE_BLOCKED / failed, never escalated
#
# Run: bash .gaai/core/scripts/tests/commit-pr-state.test.sh
# Exit 0 = all pass.

set -uo pipefail
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
SCHEDULER="$SCRIPTS/backlog-scheduler.sh"
DISPATCH="$SCRIPTS/daemon-dispatch.sh"

SANDBOX="$(mktemp -d /tmp/gaai-pr-state-test-XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ── Shared git fixture ────────────────────────────────────────────────────────
REMOTE="$SANDBOX/remote.git"
PROJ="$SANDBOX/project"
WT_BASE="$SANDBOX/worktrees"
LOCK_DIR="$SANDBOX/locks"
STUB_BIN="$SANDBOX/bin"
GH_CALL_LOG="$SANDBOX/gh-calls.log"
ROUTING_CAPTURE="$SANDBOX/routing-capture.log"
NOTIFY_CAPTURE="$SANDBOX/notify-capture.log"
BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
BACKLOG_FILE="$PROJ/$BACKLOG_REL"

mkdir -p "$WT_BASE" "$LOCK_DIR" "$STUB_BIN"
: > "$GH_CALL_LOG"
: > "$ROUTING_CAPTURE"
: > "$NOTIFY_CAPTURE"

git init --quiet --bare "$REMOTE"
git init --quiet "$PROJ"
git -C "$PROJ" config user.email t@t.t
git -C "$PROJ" config user.name "GAAI Test"
git -C "$PROJ" checkout -q -b staging
echo seed > "$PROJ/seed.txt"
mkdir -p "$(dirname "$BACKLOG_FILE")"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "initial"
git -C "$PROJ" remote add origin "$REMOTE"
git -C "$PROJ" push -q origin staging

# Helper: create story branch with one commit diverged from staging and push it.
# Does NOT pre-create a worktree — handle_commit_phase self-heals if the worktree
# dir is absent, so no worktree add is needed here (and it avoids the "branch already
# checked out in main repo" error that git raises when the branch is still active).
setup_story() {
  local sid="$1"
  git -C "$PROJ" checkout -q staging
  git -C "$PROJ" checkout -q -b "story/$sid"
  echo "$sid" > "$PROJ/${sid}.txt"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m "impl($sid): work"
  git -C "$PROJ" push -q origin "story/$sid"
  git -C "$PROJ" checkout -q staging
}

# Helper: write a minimal backlog entry (phase_status=qa_passed) and push to staging
write_backlog() {
  local sid="$1"
  cat > "$BACKLOG_FILE" <<YAML
items:
- id: ${sid}
  status: in_progress
  phase_status: qa_passed
  delivery_pipeline: 3phase
YAML
  git -C "$PROJ" add "$BACKLOG_REL"
  git -C "$PROJ" commit -q -m "backlog(${sid}): test fixture"
  git -C "$PROJ" push -q origin staging
  git -C "$PROJ" fetch -q origin staging
}

# ── gh stub ──────────────────────────────────────────────────────────────────
# Uses env vars to control what each call returns; records every call to GH_CALL_LOG.
#   GH_PR_STALE_URL   — URL returned for `gh pr list` (Guard 2 hit)
#   GH_PR_STATE       — state returned for `gh pr view <url> --json state`
#   GH_PR_STATE_AFTER_MERGE — optional state after the stub observes a merge call
#   GH_PR_NUMBER      — number returned for `gh pr view <branch> --json number`
#   GH_BRANCH_PR_NUMBER / GH_URL_PR_NUMBER — optional divergent lookup results
#   GH_PR_HEAD_SHA    — head SHA returned for `gh pr view <url> --json headRefOid`
#   GH_PR_HEAD_SHA_AFTER_MERGE — optional head after the stub observes a merge call
#   GH_PR_FRESH_URL   — URL returned by `gh pr create`
cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALL_LOG"
subcmd="${1:-}"; shift
case "$subcmd" in
  pr)
    action="${1:-}"; shift
    case "$action" in
      list)
        echo "${GH_PR_STALE_URL:-}"
        ;;
      view)
        _target="${1:-}"; shift
        _args="$*"
        _merge_seen=false
        grep -qE "gh api --method PUT .*pulls/[0-9]+/merge|gh pr merge" "$GH_CALL_LOG" 2>/dev/null && _merge_seen=true
        if   [[ "$_args" == *"--json state,headRefOid"* ]]; then
          _state="${GH_PR_STATE:-OPEN}"
          _head="${GH_PR_HEAD_SHA:-missing}"
          [[ "$_merge_seen" == "true" && -n "${GH_PR_STATE_AFTER_MERGE:-}" ]] && _state="$GH_PR_STATE_AFTER_MERGE"
          [[ "$_merge_seen" == "true" && -n "${GH_PR_HEAD_SHA_AFTER_MERGE:-}" ]] && _head="$GH_PR_HEAD_SHA_AFTER_MERGE"
          printf '%s\t%s\n' "$_state" "$_head"
        elif [[ "$_args" == *"--json state"* ]];            then
          if [[ "$_merge_seen" == "true" && -n "${GH_PR_STATE_AFTER_MERGE:-}" ]]; then
            echo "$GH_PR_STATE_AFTER_MERGE"
          else
            echo "${GH_PR_STATE:-OPEN}"
          fi
        elif [[ "$_args" == *"--json number"* ]];           then
          if [[ "$_target" == http* ]]; then
            echo "${GH_URL_PR_NUMBER:-${GH_PR_NUMBER:-99}}"
          else
            echo "${GH_BRANCH_PR_NUMBER:-${GH_PR_NUMBER:-99}}"
          fi
        elif [[ "$_args" == *"--json headRefOid"* ]];       then
          if [[ "$_merge_seen" == "true" && -n "${GH_PR_HEAD_SHA_AFTER_MERGE:-}" ]]; then
            echo "$GH_PR_HEAD_SHA_AFTER_MERGE"
          else
            echo "${GH_PR_HEAD_SHA:-missing}"
          fi
        elif [[ "$_args" == *"--json mergeable"* ]];        then
          if [[ -n "${GH_PR_MERGEABLE_JSON:-}" ]]; then
            echo "$GH_PR_MERGEABLE_JSON"
          else
            echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
          fi
        elif [[ "$_args" == *"--json url"* ]];              then echo "${GH_PR_STALE_URL:-}"
        else echo '{}'
        fi
        ;;
      create)
        echo "${GH_PR_FRESH_URL:-https://github.com/test/repo/pull/100}"
        exit 0
        ;;
      merge)
        # Admin-fallback behavior can be controlled separately when exercised.
        [[ -n "${GH_MERGE_STDERR:-}" ]] && echo "${GH_MERGE_STDERR}" >&2
        exit "${GH_MERGE_EXIT:-0}"
        ;;
    esac
    ;;
  api)
    [[ -n "${GH_MERGE_STDERR:-}" ]] && echo "${GH_MERGE_STDERR}" >&2
    [[ -z "${GH_MERGE_EXIT:-}" ]] && echo "${GH_MERGE_API_RESP:-true}"
    exit "${GH_MERGE_EXIT:-0}"
    ;;
esac
GHEOF
chmod +x "$STUB_BIN/gh"

# Stub node to suppress routing-record emission
cat > "$STUB_BIN/node" <<'NODEEOF'
#!/usr/bin/env bash
exit 0
NODEEOF
chmod +x "$STUB_BIN/node"

export PATH="$STUB_BIN:$PATH"
export GH_CALL_LOG ROUTING_CAPTURE NOTIFY_CAPTURE

# ── Source daemon-dispatch.sh with minimal required env ──────────────────────
export PROJECT_DIR="$PROJ"
export BACKLOG_FILE
export GAAI_WORKTREES_BASE="$WT_BASE"
export TARGET_BRANCH="staging"
export SCHEDULER
export LOCK_DIR

source "$DISPATCH" 2>/dev/null || true

# Override heavy dependencies that are not relevant to the PR-state guard
log()                          { :; }
CYAN="" YELLOW="" NC="" RED="" GREEN="" BOLD=""
_ensure_worktree_deps_fresh()  { return 0; }
_check_worktree_integrity()    { return 0; }
_recover_worktree_safe_base()  { return 1; }
_admit_current_candidate()     {
  GAAI_ADMITTED_SHA=$(git -C "$4" rev-parse HEAD)
  GAAI_ADMITTED_BASE_SHA=$(git -C "$4" rev-parse origin/staging)
  if [[ "${GAAI_TEST_MOVE_BASE_AFTER_ADMISSION:-false}" == true ]]; then
    GAAI_TEST_ADMISSION_CALLS=$(( ${GAAI_TEST_ADMISSION_CALLS:-0} + 1 ))
    if [[ "$GAAI_TEST_ADMISSION_CALLS" -eq 1 ]]; then
      printf 'advanced\n' > "$PROJ/admission-base-advanced.txt"
      git -C "$PROJ" add admission-base-advanced.txt
      git -C "$PROJ" commit -q -m 'advance base after admission'
      git -C "$PROJ" push -q origin staging
    else
      git -C "$4" fetch -q origin staging
      git -C "$4" merge -q --no-edit origin/staging
      GAAI_ADMITTED_SHA=$(git -C "$4" rev-parse HEAD)
      GAAI_ADMITTED_BASE_SHA=$(git -C "$4" rev-parse origin/staging)
    fi
  fi
  return 0
}
chore_commit_field()           { return 0; }
chore_commit_multi_field()     { return 0; }
notify_escalation_inline()     { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$NOTIFY_CAPTURE"; }
_run_triage_for_story()        { return 0; }
_emit_commit_routing_record()  { printf '%s|%s|%s|%s|%s|%s|%s\n' "$@" >>"$ROUTING_CAPTURE"; }
_auto_resolve_pr_conflicts()   { [[ "${GAAI_TEST_AUTO_RESOLVE_SUCCESS:-false}" == "true" ]]; }

# These PR-state cases exercise behavior downstream of lifecycle persistence.
# Reflect journal-authorized fields into the hermetic backlog without giving
# production a scheduler fallback. The dedicated S14 suites cover the real
# journal/projector boundary and this double still propagates fixture failures.
_journal_persist_lifecycle() {
  local story_id="$1" _writer="$2" field value
  shift 2
  while (( $# >= 2 )); do
    field="$1"; value="$2"; shift 2
    "$SCHEDULER" --set-field "$story_id" "$field" "$value" "$BACKLOG_FILE" >/dev/null \
      || return 1
  done
}

# These legacy PR-state tests exercise behavior downstream of merge authority.
# Supply an explicit hosted-pass tuple; no local or absent evidence is allowed
# to authorize their merge assertions. The dedicated controller suite covers
# the full REST state machine and fail-closed outcomes.
_run_merge_test_gate() {
  TEST_GATE_AUTH_PR_NUMBER=""; TEST_GATE_AUTH_REPOSITORY_ID=""; TEST_GATE_AUTH_REPOSITORY_NAME=""
  TEST_GATE_AUTH_BASE_REF=""; TEST_GATE_AUTH_BASE_SHA=""; TEST_GATE_AUTH_HEAD_REF=""; TEST_GATE_AUTH_HEAD_SHA=""
  TEST_GATE_AUTH_WORKFLOW_ID=""; TEST_GATE_AUTH_RUN_ID=""; TEST_GATE_AUTH_RUN_NUMBER=""
  TEST_GATE_AUTH_RUN_ATTEMPT=""; TEST_GATE_AUTH_JOB_ID=""; TEST_GATE_AUTH_WORKTREE_PATH="$2"
  local configured_outcome="${GAAI_TEST_AUTHORITY_OUTCOME:-hosted_pass}"
  if [[ "$configured_outcome" == "hosted_then_human" ]]; then
    GAAI_TEST_AUTHORITY_CALL_COUNT=$(( ${GAAI_TEST_AUTHORITY_CALL_COUNT:-0} + 1 ))
    [[ "$GAAI_TEST_AUTHORITY_CALL_COUNT" -gt 1 ]] \
      && configured_outcome=human_required:trust_surface_changed \
      || configured_outcome=hosted_pass
  fi
  case "$configured_outcome" in
    human_required:trust_surface_changed)
      TEST_GATE_OUTCOME=human_required:trust_surface_changed
      export TEST_GATE_OUTCOME TEST_GATE_AUTH_PR_NUMBER TEST_GATE_AUTH_REPOSITORY_ID \
        TEST_GATE_AUTH_REPOSITORY_NAME TEST_GATE_AUTH_BASE_REF TEST_GATE_AUTH_BASE_SHA \
        TEST_GATE_AUTH_HEAD_REF TEST_GATE_AUTH_HEAD_SHA TEST_GATE_AUTH_WORKFLOW_ID \
        TEST_GATE_AUTH_RUN_ID TEST_GATE_AUTH_RUN_NUMBER TEST_GATE_AUTH_RUN_ATTEMPT \
        TEST_GATE_AUTH_JOB_ID TEST_GATE_AUTH_WORKTREE_PATH
      return 2
      ;;
    blocked:*)
      TEST_GATE_OUTCOME="$configured_outcome"
      export TEST_GATE_OUTCOME TEST_GATE_AUTH_PR_NUMBER TEST_GATE_AUTH_REPOSITORY_ID \
        TEST_GATE_AUTH_REPOSITORY_NAME TEST_GATE_AUTH_BASE_REF TEST_GATE_AUTH_BASE_SHA \
        TEST_GATE_AUTH_HEAD_REF TEST_GATE_AUTH_HEAD_SHA TEST_GATE_AUTH_WORKFLOW_ID \
        TEST_GATE_AUTH_RUN_ID TEST_GATE_AUTH_RUN_NUMBER TEST_GATE_AUTH_RUN_ATTEMPT \
        TEST_GATE_AUTH_JOB_ID TEST_GATE_AUTH_WORKTREE_PATH
      return 1
      ;;
  esac
  TEST_GATE_OUTCOME=hosted_pass
  TEST_GATE_AUTH_PR_NUMBER="${GH_URL_PR_NUMBER:-${GH_PR_NUMBER:-99}}"
  TEST_GATE_AUTH_REPOSITORY_ID=42
  TEST_GATE_AUTH_REPOSITORY_NAME=test/repo
  TEST_GATE_AUTH_BASE_REF=staging
  TEST_GATE_AUTH_BASE_SHA="$(git -C "$2" rev-parse origin/staging)"
  TEST_GATE_AUTH_HEAD_REF="story/$1"
  TEST_GATE_AUTH_HEAD_SHA="$5"
  TEST_GATE_AUTH_WORKFLOW_ID=7001
  TEST_GATE_AUTH_RUN_ID=9001
  TEST_GATE_AUTH_RUN_NUMBER=12
  TEST_GATE_AUTH_RUN_ATTEMPT=1
  TEST_GATE_AUTH_JOB_ID=9101
  export TEST_GATE_OUTCOME TEST_GATE_AUTH_PR_NUMBER TEST_GATE_AUTH_REPOSITORY_ID \
    TEST_GATE_AUTH_REPOSITORY_NAME TEST_GATE_AUTH_BASE_REF TEST_GATE_AUTH_BASE_SHA TEST_GATE_AUTH_HEAD_REF \
    TEST_GATE_AUTH_HEAD_SHA TEST_GATE_AUTH_WORKFLOW_ID TEST_GATE_AUTH_RUN_ID TEST_GATE_AUTH_RUN_NUMBER \
    TEST_GATE_AUTH_RUN_ATTEMPT TEST_GATE_AUTH_JOB_ID TEST_GATE_AUTH_WORKTREE_PATH
  return 0
}
_test_gate_recheck_pr_tuple() { echo hosted_pass; return 0; }

echo ""
echo "=== commit-pr-state: AC5 — PR-state guard in handle_commit_phase ==="
echo ""

# ────────────────────────────────────────────────────────────────────────────
# T1: CLOSED PR selected → gh pr create called, merge endpoint NOT called
# ────────────────────────────────────────────────────────────────────────────
echo "--- T1: CLOSED PR ---"
SID1="TST-PCS01"
setup_story "$SID1"
write_backlog "$SID1"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID1")"

STALE_T1="https://github.com/test/repo/pull/97"
export GH_PR_STALE_URL="$STALE_T1"
export GH_PR_STATE="CLOSED"
export GH_PR_FRESH_URL="https://github.com/test/repo/pull/100"
export GH_PR_NUMBER="100"
export GAAI_AUTO_MERGE_POLICY="off"
: > "$GH_CALL_LOG"

set +e
handle_commit_phase "$SID1" "trace-t1"
set -e

echo "T1a: gh pr create called (fresh PR opened after CLOSED guard)"
if grep -q "gh pr create" "$GH_CALL_LOG"; then
  pass "T1a: gh pr create was called"
else
  fail "T1a: gh pr create NOT called — CLOSED guard did not clear _skip_pr_create"
fi

echo "T1b: merge endpoint NOT called for the closed PR"
if grep -qE "gh api --method PUT .*pulls/97/merge|gh pr merge.*${STALE_T1}" "$GH_CALL_LOG"; then
  fail "T1b: merge was attempted for closed PR ($STALE_T1)"
else
  pass "T1b: no merge attempted for closed PR"
fi

# ────────────────────────────────────────────────────────────────────────────
# T2: MERGED PR selected → reconcile to done, merge endpoint NOT called
# ────────────────────────────────────────────────────────────────────────────
echo "--- T2: MERGED PR ---"
SID2="TST-PCS02"
setup_story "$SID2"
write_backlog "$SID2"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID2")"

STALE_T2="https://github.com/test/repo/pull/98"
export GH_PR_STALE_URL="$STALE_T2"
export GH_PR_STATE="MERGED"
export GAAI_AUTO_MERGE_POLICY="off"
: > "$GH_CALL_LOG"

set +e
handle_commit_phase "$SID2" "trace-t2"
set -e

echo "T2a: merge endpoint NOT called for MERGED PR"
if grep -qE "gh api --method PUT .*pulls/98/merge|gh pr merge" "$GH_CALL_LOG"; then
  fail "T2a: merge was called even though selected PR is MERGED"
else
  pass "T2a: merge endpoint NOT called"
fi

echo "T2b: phase_status=done after MERGED reconcile"
T2_PHASE=$(grep -A 10 "id: ${SID2}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T2_PHASE" == "done" ]]; then
  pass "T2b: phase_status=done (MERGED early-exit reconciled correctly)"
else
  fail "T2b: phase_status='${T2_PHASE}' (expected done)"
fi

# ────────────────────────────────────────────────────────────────────────────
# T3: OPEN PR selected → exact-head merge endpoint is called
# ────────────────────────────────────────────────────────────────────────────
echo "--- T3: OPEN PR ---"
SID3="TST-PCS03"
setup_story "$SID3"
write_backlog "$SID3"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID3")"

OPEN_URL_T3="https://github.com/test/repo/pull/99"
export GH_PR_STALE_URL="$OPEN_URL_T3"
export GH_PR_STATE="OPEN"
export GH_PR_STATE_AFTER_MERGE="MERGED"
export GH_PR_NUMBER="99"
export GH_BRANCH_PR_NUMBER="777"  # sibling PR for the same branch, different base
export GH_URL_PR_NUMBER="99"      # exact selected/gated PR
export GAAI_AUTO_MERGE_POLICY="on"
: > "$GH_CALL_LOG"

set +e
handle_commit_phase "$SID3" "trace-t3"
set -e

echo "T3a: direct REST merge called for the selected PR"
if grep -q "gh api --method PUT repos/test/repo/pulls/99/merge" "$GH_CALL_LOG"; then
  pass "T3a: exact PR merge API called"
else
  fail "T3a: exact PR merge API was not called"
fi

echo "T3b: merge API pins the expected head SHA"
if grep "gh api --method PUT" "$GH_CALL_LOG" 2>/dev/null | grep -q -- "sha=$GH_PR_HEAD_SHA"; then
  pass "T3b: merge API sends the exact sha precondition"
else
  fail "T3b: merge API did not pin the expected head SHA"
fi

echo "T3c: normal merge path never enables persistent auto-merge"
if grep "gh pr merge" "$GH_CALL_LOG" 2>/dev/null | grep -q -- "--auto"; then
  fail "T3c: gh pr merge still uses --auto"
else
  pass "T3c: no --auto request was made"
fi

echo "T3d: sibling PR discovered by branch lookup is never merged"
if grep -q "pulls/777/merge" "$GH_CALL_LOG"; then
  fail "T3d: merge targeted sibling branch PR #777"
else
  pass "T3d: merge remained bound to selected URL's PR #99"
fi

unset GH_PR_STATE_AFTER_MERGE
unset GH_BRANCH_PR_NUMBER GH_URL_PR_NUMBER

# ────────────────────────────────────────────────────────────────────────────
# T4: the merge API's transport reports failure after the server merged the
#     exact tested head. Durable verification MUST treat this as success.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T4: merge response fails after the expected head merged ---"
SID4="TST-PCS04"
setup_story "$SID4"
write_backlog "$SID4"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID4")"

OPEN_URL_T4="https://github.com/test/repo/pull/104"
export GH_PR_STALE_URL="$OPEN_URL_T4"
export GH_PR_STATE="OPEN"                       # PR is open at the pre-merge guard
export GH_PR_STATE_AFTER_MERGE="MERGED"         # server merged before local cleanup failed
export GH_PR_NUMBER="104"
export GAAI_AUTO_MERGE_POLICY="on"
export GH_MERGE_EXIT="1"                         # gh returns non-zero...
export GH_MERGE_STDERR="transport closed after server accepted merge"
: > "$GH_CALL_LOG"

set +e
handle_commit_phase "$SID4" "trace-t4"
T4_RC=$?
set -e

echo "T4a: handle_commit_phase returns 0 (not escalated)"
if [[ "$T4_RC" -eq 0 ]]; then
  pass "T4a: handle_commit_phase returned 0"
else
  fail "T4a: handle_commit_phase returned $T4_RC (durable merged state ignored)"
fi

echo "T4b: phase_status=done (merge treated as success, not escalated)"
T4_PHASE=$(grep -A 10 "id: ${SID4}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T4_PHASE" == "done" ]]; then
  pass "T4b: phase_status=done"
else
  fail "T4b: phase_status='${T4_PHASE}' (expected done — durable merge verification failed)"
fi

echo "T4c: merge API WAS attempted"
if grep -q "gh api --method PUT" "$GH_CALL_LOG" 2>/dev/null; then
  pass "T4c: merge API attempted"
else
  fail "T4c: merge API NOT attempted"
fi

unset GH_MERGE_EXIT GH_MERGE_STDERR GH_PR_STATE_AFTER_MERGE

# ────────────────────────────────────────────────────────────────────────────
# T5: head changes after the gate but before the merge can land. This is a
#     TEST_GATE_BLOCKED failure, not a generic auto-merge escalation.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T5: PR head moves during exact-head merge ---"
SID5="TST-PCS05"
setup_story "$SID5"
write_backlog "$SID5"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID5")"

OPEN_URL_T5="https://github.com/test/repo/pull/105"
export GH_PR_STALE_URL="$OPEN_URL_T5"
export GH_PR_STATE="OPEN"
export GH_PR_STATE_AFTER_MERGE="OPEN"
export GH_PR_HEAD_SHA_AFTER_MERGE="$(printf '%040d' 3)"
export GH_PR_NUMBER="105"
export GH_MERGE_EXIT="1"
export GH_MERGE_STDERR="head sha does not match"
export GAAI_AUTO_MERGE_POLICY="on"
: > "$GH_CALL_LOG"

set +e
handle_commit_phase "$SID5" "trace-t5"
T5_RC=$?
set -e

echo "T5a: moved head blocks the commit phase"
if [[ "$T5_RC" -ne 0 ]]; then
  pass "T5a: handle_commit_phase returned non-zero"
else
  fail "T5a: moved PR head was authorized"
fi

echo "T5b: moved head uses failed phase_status, not generic escalation"
T5_PHASE=$(grep -A 10 "id: ${SID5}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T5_PHASE" == "failed" ]]; then
  pass "T5b: phase_status=failed (TEST_GATE_BLOCKED semantics)"
else
  fail "T5b: phase_status='${T5_PHASE}' (expected failed)"
fi

unset GH_MERGE_EXIT GH_MERGE_STDERR GH_PR_STATE_AFTER_MERGE \
  GH_PR_HEAD_SHA_AFTER_MERGE

# ────────────────────────────────────────────────────────────────────────────
# T6: dispatcher-level transient authority block — exact reason, resumable, no mutation
# ────────────────────────────────────────────────────────────────────────────
echo "--- T6: hosted authority blocks before merge policy/mutation ---"
SID6="TST-PCS06"
setup_story "$SID6"
write_backlog "$SID6"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID6")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/106"
export GH_PR_STATE="OPEN" GH_PR_NUMBER="106" GAAI_AUTO_MERGE_POLICY="on"
export GAAI_TEST_AUTHORITY_OUTCOME="blocked:run_pending"
: >"$GH_CALL_LOG"; : >"$ROUTING_CAPTURE"; : >"$NOTIFY_CAPTURE"

set +e
handle_commit_phase "$SID6" "trace-t6"
T6_RC=$?
set -e
T6_PHASE=$(grep -A 10 "id: ${SID6}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T6_RC" -ne 0 && "$T6_PHASE" == qa_passed \
      && $(grep -cE 'gh api --method PUT .*pulls/[0-9]+/merge|gh pr merge' "$GH_CALL_LOG" || true) -eq 0 \
      && $(grep -c 'blocked:run_pending' "$ROUTING_CAPTURE" || true) -ge 1 ]]; then
  pass "T6: blocked hosted authority preserves resumable phase with the exact reason before mutation"
else
  fail "T6: dispatcher blocked route mismatch (rc=$T6_RC phase=$T6_PHASE)"
fi

# ────────────────────────────────────────────────────────────────────────────
# T7: dispatcher-level human-required — pending review/done, notify, no merge
# ────────────────────────────────────────────────────────────────────────────
echo "--- T7: trust-surface change routes mandatory human review ---"
SID7="TST-PCS07"
setup_story "$SID7"
write_backlog "$SID7"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID7")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/107"
export GH_PR_STATE="OPEN" GH_PR_NUMBER="107" GAAI_AUTO_MERGE_POLICY="on"
export GAAI_TEST_AUTHORITY_OUTCOME="human_required:trust_surface_changed"
: >"$GH_CALL_LOG"; : >"$ROUTING_CAPTURE"; : >"$NOTIFY_CAPTURE"

set +e
handle_commit_phase "$SID7" "trace-t7"
T7_RC=$?
set -e
T7_PHASE=$(grep -A 10 "id: ${SID7}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T7_RC" -eq 0 && "$T7_PHASE" == done \
      && $(grep -cE 'gh api --method PUT .*pulls/[0-9]+/merge|gh pr merge' "$GH_CALL_LOG" || true) -eq 0 \
      && $(grep -c 'human_required:trust_surface_changed' "$ROUTING_CAPTURE" || true) -ge 1 \
      && $(grep -c 'human_required:trust_surface_changed' "$NOTIFY_CAPTURE" || true) -ge 1 ]]; then
  pass "T7: human-required leaves the PR pending for review and notifies without mutation"
else
  fail "T7: dispatcher human-required route mismatch (rc=$T7_RC phase=$T7_PHASE)"
fi
unset GAAI_TEST_AUTHORITY_OUTCOME

# ────────────────────────────────────────────────────────────────────────────
# T8: conflict-resolution re-gate becomes human-required, never a second PUT
# ────────────────────────────────────────────────────────────────────────────
echo "--- T8: conflict-resolved head can route human-required coherently ---"
SID8="TST-PCS08"
setup_story "$SID8"
write_backlog "$SID8"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID8")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/108"
export GH_PR_STATE="OPEN" GH_PR_NUMBER="108" GAAI_AUTO_MERGE_POLICY="on"
export GH_MERGE_EXIT=1 GH_MERGE_STDERR="conflicting"
export GH_PR_MERGEABLE_JSON='{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'
export GAAI_TEST_AUTHORITY_OUTCOME=hosted_then_human GAAI_TEST_AUTHORITY_CALL_COUNT=0
export GAAI_TEST_AUTO_RESOLVE_SUCCESS=true GAAI_MERGE_AUTHORITY_MERGE_RETRIES=1 \
  GAAI_MERGE_AUTHORITY_RETRY_SLEEP_SEC=0
: >"$GH_CALL_LOG"; : >"$ROUTING_CAPTURE"; : >"$NOTIFY_CAPTURE"

set +e
handle_commit_phase "$SID8" "trace-t8"
T8_RC=$?
set -e
T8_PHASE=$(grep -A 10 "id: ${SID8}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
T8_PUTS=$(grep -cE 'gh api --method PUT .*pulls/[0-9]+/merge' "$GH_CALL_LOG" || true)
if [[ "$T8_RC" -eq 0 && "$T8_PHASE" == done && "$T8_PUTS" -eq 1 \
      && $(grep -c 'human_required:trust_surface_changed' "$ROUTING_CAPTURE" || true) -ge 1 \
      && $(grep -c 'human_required:trust_surface_changed' "$NOTIFY_CAPTURE" || true) -ge 1 ]]; then
  pass "T8: resolved-head human-required route leaves review pending without a second PUT"
else
  fail "T8: resolved-head human route mismatch (rc=$T8_RC phase=$T8_PHASE puts=$T8_PUTS)"
fi
unset GH_MERGE_EXIT GH_MERGE_STDERR GH_PR_MERGEABLE_JSON \
  GAAI_TEST_AUTHORITY_OUTCOME GAAI_TEST_AUTHORITY_CALL_COUNT GAAI_TEST_AUTO_RESOLVE_SUCCESS \
  GAAI_MERGE_AUTHORITY_MERGE_RETRIES GAAI_MERGE_AUTHORITY_RETRY_SLEEP_SEC

# ────────────────────────────────────────────────────────────────────────────
# T9: even after successful dispatcher initialization, losing the controller
#     at runtime must block before policy resolution or any merge mutation.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T9: missing hosted controller fails closed at dispatch ---"
SID9="TST-PCS09"
setup_story "$SID9"
write_backlog "$SID9"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID9")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/109"
export GH_PR_STATE="OPEN" GH_PR_NUMBER="109" GAAI_AUTO_MERGE_POLICY="on"
: >"$GH_CALL_LOG"; : >"$ROUTING_CAPTURE"; : >"$NOTIFY_CAPTURE"
ORIGINAL_MERGE_GATE=$(declare -f _run_merge_test_gate)
unset -f _run_merge_test_gate

set +e
handle_commit_phase "$SID9" "trace-t9"
T9_RC=$?
set -e
eval "$ORIGINAL_MERGE_GATE"
T9_PHASE=$(grep -A 10 "id: ${SID9}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T9_RC" -ne 0 && "$T9_PHASE" == qa_passed \
      && $(grep -cE 'gh api --method PUT .*pulls/[0-9]+/merge|gh pr merge' "$GH_CALL_LOG" || true) -eq 0 \
      && $(grep -c 'blocked:github_unavailable' "$ROUTING_CAPTURE" || true) -ge 1 ]]; then
  pass "T9: missing hosted controller preserves resumable state and cannot reach merge"
else
  fail "T9: missing-controller route mismatch (rc=$T9_RC phase=$T9_PHASE)"
fi

# ────────────────────────────────────────────────────────────────────────────
# T10: a deterministic policy-identity block must stall, not retry. Leaving the
#      durable qa_passed phase in place lets RECOVERY re-launch the wrapper on
#      every scan; each re-launch re-pushes the candidate and buys another
#      complete hosted run, and the bounded-death counter cannot contain it
#      because it resets whenever the worktree HEAD moves.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T10: deterministic policy mismatch stalls instead of retrying ---"
SID10="TST-PCS10"
setup_story "$SID10"
write_backlog "$SID10"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID10")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/110"
export GH_PR_STATE="OPEN"
export GH_PR_NUMBER="110"
export GAAI_TEST_AUTHORITY_OUTCOME="blocked:repository_mismatch"
T10_MARKER="$LOCK_DIR/.commit-policy-stalled-${SID10}"
printf 'story_id=%s\noutcome=blocked:repository_mismatch\n' "$SID10" > "$T10_MARKER"
: > "$GH_CALL_LOG"; : > "$ROUTING_CAPTURE"; : > "$NOTIFY_CAPTURE"

set +e
handle_commit_phase "$SID10" "trace-t10"
T10_RC=$?
set -e

T10_PHASE=$(grep -A 10 "id: ${SID10}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T10_RC" -ne 0 && "$T10_PHASE" == commit_stalled && -f "$T10_MARKER" ]]; then
  pass "T10a: deterministic block stalls at commit_stalled without clearing an operator marker"
else
  fail "T10a: expected rc!=0, commit_stalled, and preserved marker (rc=$T10_RC phase='${T10_PHASE}' marker=$(test -f "$T10_MARKER" && echo yes || echo no))"
fi

if [[ $(grep -cE 'gh api --method PUT .*pulls/[0-9]+/merge|gh pr merge' "$GH_CALL_LOG" || true) -eq 0 ]]; then
  pass "T10b: no merge was attempted on a blocked candidate"
else
  fail "T10b: merge attempted despite a blocked hosted authority"
fi

if [[ $(grep -c 'blocked:repository_mismatch' "$ROUTING_CAPTURE" || true) -ge 1 \
      && $(grep -c 'blocked:repository_mismatch' "$NOTIFY_CAPTURE" || true) -ge 1 ]]; then
  pass "T10c: the exact outcome reaches both the routing record and the operator"
else
  fail "T10c: deterministic outcome missing from routing/notification capture"
fi

# ────────────────────────────────────────────────────────────────────────────
# T11: the circuit breaker must not swallow a recoverable run/PR association
#      mismatch. It keeps qa_passed so the existing recovery path owns it.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T11: run/PR tuple mismatch remains retryable ---"
SID11="TST-PCS11"
setup_story "$SID11"
write_backlog "$SID11"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID11")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/111"
export GH_PR_STATE="OPEN"
export GH_PR_NUMBER="111"
export GAAI_TEST_AUTHORITY_OUTCOME="blocked:pr_tuple_mismatch"
: > "$GH_CALL_LOG"; : > "$ROUTING_CAPTURE"

set +e
handle_commit_phase "$SID11" "trace-t11"
T11_RC=$?
set -e

T11_PHASE=$(grep -A 10 "id: ${SID11}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T11_RC" -ne 0 && "$T11_PHASE" == qa_passed ]]; then
  pass "T11: recoverable PR tuple mismatch leaves the story resumable at qa_passed"
else
  fail "T11: expected rc!=0 and phase_status=qa_passed (rc=$T11_RC phase='${T11_PHASE}')"
fi

unset GAAI_TEST_AUTHORITY_OUTCOME

# ────────────────────────────────────────────────────────────────────────────
# T12: if the primary backlog mutation fails, publish an atomic fallback marker
#      that crash recovery treats as a durable no-relaunch instruction.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T12: scheduler failure publishes durable recovery inhibit ---"
SID12="TST-PCS12"
setup_story "$SID12"
write_backlog "$SID12"
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse "story/$SID12")"
export GH_PR_STALE_URL="https://github.com/test/repo/pull/112"
export GH_PR_STATE="OPEN"
export GH_PR_NUMBER="112"
export GAAI_TEST_AUTHORITY_OUTCOME="blocked:policy_base_ref_mismatch"
REAL_SCHEDULER="$SCRIPTS/backlog-scheduler.sh"
export REAL_SCHEDULER
cat > "$STUB_BIN/failing-commit-stall-scheduler" <<'SCHEDULER_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--set-phase-status" && "${3:-}" == "commit_stalled" ]] \
    || [[ "${1:-}" == "--set-field" && "${3:-}" == "phase_status" && "${4:-}" == "commit_stalled" ]]; then
  exit 70
fi
exec "$REAL_SCHEDULER" "$@"
SCHEDULER_EOF
chmod +x "$STUB_BIN/failing-commit-stall-scheduler"
SCHEDULER="$STUB_BIN/failing-commit-stall-scheduler"
export SCHEDULER
T12_MARKER="$LOCK_DIR/.commit-policy-stalled-${SID12}"
: > "$GH_CALL_LOG"; : > "$ROUTING_CAPTURE"; : > "$NOTIFY_CAPTURE"

set +e
handle_commit_phase "$SID12" "trace-t12"
T12_RC=$?
set -e

T12_PHASE=$(grep -A 10 "id: ${SID12}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T12_RC" -ne 0 && "$T12_PHASE" == qa_passed && -f "$T12_MARKER" \
      && $(grep -c '^outcome=blocked:policy_base_ref_mismatch$' "$T12_MARKER" || true) -eq 1 ]]; then
  pass "T12a: scheduler failure leaves qa_passed plus an exact durable stall marker"
else
  fail "T12a: fallback persistence mismatch (rc=$T12_RC phase='${T12_PHASE}' marker=$(test -f "$T12_MARKER" && echo yes || echo no))"
fi

if [[ $(grep -cE 'gh api --method PUT .*pulls/[0-9]+/merge|gh pr merge' "$GH_CALL_LOG" || true) -eq 0 \
      && $(grep -c 'Persistence=marker' "$NOTIFY_CAPTURE" || true) -ge 1 ]]; then
  pass "T12b: fallback route attempts no merge and tells the operator how it persisted"
else
  fail "T12b: fallback route merged or omitted persistence evidence"
fi

SCHEDULER="$SCRIPTS/backlog-scheduler.sh"
export SCHEDULER
unset GAAI_TEST_AUTHORITY_OUTCOME REAL_SCHEDULER

# ────────────────────────────────────────────────────────────────────────────
# T13: base movement after a successful admission cannot reuse that receipt.
#      The first exact push is observed stale; retry admission merges the new
#      base, emits a new SHA and only then may PR creation occur.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T13: moved base forces final re-admission before PR creation ---"
SID13="TST-PCS13"
setup_story "$SID13"
write_backlog "$SID13"
export GH_PR_STALE_URL="" GH_PR_FRESH_URL="https://github.com/test/repo/pull/113"
export GH_PR_STATE="OPEN" GH_PR_NUMBER="113"
export GAAI_TEST_AUTHORITY_OUTCOME="human_required:trust_surface_changed"
export GAAI_TEST_MOVE_BASE_AFTER_ADMISSION=true GAAI_TEST_ADMISSION_CALLS=0
: > "$GH_CALL_LOG"; : > "$ROUTING_CAPTURE"

set +e
handle_commit_phase "$SID13" "trace-t13"
T13_RC=$?
set -e
T13_WT="$WT_BASE/${SID13}-workspace"
T13_REMOTE_HEAD=$(git -C "$PROJ" rev-parse "origin/story/${SID13}")
T13_LOCAL_HEAD=$(git -C "$T13_WT" rev-parse HEAD)
if [[ "$T13_RC" -eq 0 && "$GAAI_TEST_ADMISSION_CALLS" -eq 2 \
      && "$T13_REMOTE_HEAD" == "$T13_LOCAL_HEAD" \
      && $(grep -c '^gh pr create ' "$GH_CALL_LOG" || true) -eq 1 ]] \
    && git -C "$T13_WT" merge-base --is-ancestor origin/staging HEAD; then
  pass "T13: stale first receipt is re-admitted on the moved base before the sole PR create"
else
  fail "T13: expected two admissions, exact updated remote head and one PR (rc=$T13_RC calls=$GAAI_TEST_ADMISSION_CALLS)"
fi
unset GAAI_TEST_MOVE_BASE_AFTER_ADMISSION GAAI_TEST_ADMISSION_CALLS GAAI_TEST_AUTHORITY_OUTCOME

# ────────────────────────────────────────────────────────────────────────────
# T14/T15: local preparation failures remain retryable. The journal policy has
# no legacy commit_failed/worktree_recovery_failed transition, so S14 must not
# collapse these pre-publication failures into terminal `failed`.
# ────────────────────────────────────────────────────────────────────────────
echo "--- T14: dependency preparation failure remains retryable ---"
SID14="TST-PCS14"
setup_story "$SID14"
write_backlog "$SID14"
_ensure_worktree_deps_fresh() { return 1; }
: > "$GH_CALL_LOG"
set +e
handle_commit_phase "$SID14" "trace-t14"
T14_RC=$?
set -e
T14_PHASE=$(grep -A 10 "id: ${SID14}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T14_RC" -ne 0 && "$T14_PHASE" == qa_passed ]] \
    && ! grep -qE 'gh pr create|gh api --method PUT .*pulls/[0-9]+/merge' "$GH_CALL_LOG"; then
  pass "T14: dependency failure preserves qa_passed and publishes nothing"
else
  fail "T14: dependency failure changed retry class or reached publication"
fi

echo "--- T14b: package-manager cache failure remains retryable ---"
SID14B="TST-PCS14B"
setup_story "$SID14B"
write_backlog "$SID14B"
_T14B_REAL_PREFLIGHT=$(declare -f _ensure_corepack_pnpm_intact)
T14B_DEPS_CALLED=false
_ensure_corepack_pnpm_intact() { return 1; }
_ensure_worktree_deps_fresh() { T14B_DEPS_CALLED=true; return 0; }
: > "$GH_CALL_LOG"; : > "$ROUTING_CAPTURE"
set +e
handle_commit_phase "$SID14B" "trace-t14b"
T14B_RC=$?
set -e
eval "$_T14B_REAL_PREFLIGHT"
T14B_PHASE=$(grep -A 10 "id: ${SID14B}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T14B_RC" -ne 0 && "$T14B_PHASE" == qa_passed && "$T14B_DEPS_CALLED" == false ]] \
    && grep -q "^${SID14B}|trace-t14b|error|corepack_cache_unusable|" "$ROUTING_CAPTURE" \
    && ! grep -qE 'gh pr create|gh api --method PUT .*pulls/[0-9]+/merge' "$GH_CALL_LOG"; then
  pass "T14b: cache failure routes corepack_cache_unusable, preserves qa_passed, publishes nothing"
else
  fail "T14b: cache failure changed retry class, ran pnpm or reached publication (rc=$T14B_RC phase=$T14B_PHASE deps=$T14B_DEPS_CALLED)"
fi

echo "--- T15: worktree integrity failure remains retryable ---"
SID15="TST-PCS15"
setup_story "$SID15"
write_backlog "$SID15"
_ensure_worktree_deps_fresh() { return 0; }
_check_worktree_integrity() { return 2; }
: > "$GH_CALL_LOG"
set +e
handle_commit_phase "$SID15" "trace-t15"
T15_RC=$?
set -e
T15_PHASE=$(grep -A 10 "id: ${SID15}" "$BACKLOG_FILE" | grep "phase_status:" | head -1 | awk '{print $2}')
if [[ "$T15_RC" -ne 0 && "$T15_PHASE" == qa_passed ]] \
    && ! grep -qE 'gh pr create|gh api --method PUT .*pulls/[0-9]+/merge' "$GH_CALL_LOG"; then
  pass "T15: integrity failure preserves qa_passed and publishes nothing"
else
  fail "T15: integrity failure changed retry class or reached publication"
fi

# ────────────────────────────────────────────────────────────────────────────
# T16: a PR merged for an EARLIER cycle of the same story/<id> branch is not
# landing evidence for the head this phase just published. Guard 2 found it
# via --state all; treating it as MERGED projected a fresh, unmerged candidate
# to done/merged and released its dependants. It must be handled like a CLOSED
# PR: open a fresh PR and record it pending review, never reconcile the story
# as merged. (T2 keeps the legitimate case: the merged PR's head IS the
# published head.)
# ────────────────────────────────────────────────────────────────────────────
echo "--- T16: MERGED PR from an earlier cycle opens a fresh PR ---"
SID16="TST-PCS16"
setup_story "$SID16"
write_backlog "$SID16"
_check_worktree_integrity() { return 0; }
STALE_T16="https://github.com/test/repo/pull/96"
FRESH_T16="https://github.com/test/repo/pull/101"
export GH_PR_STALE_URL="$STALE_T16"
export GH_PR_STATE="MERGED"
# The earlier cycle merged a different head: here, the base commit.
export GH_PR_HEAD_SHA="$(git -C "$PROJ" rev-parse staging)"
export GH_PR_FRESH_URL="$FRESH_T16"
export GH_PR_NUMBER="101"
export GAAI_AUTO_MERGE_POLICY="off"
: > "$GH_CALL_LOG"
set +e
handle_commit_phase "$SID16" "trace-t16"
set -e
T16_PR_STATUS=$(grep -A 10 "id: ${SID16}" "$BACKLOG_FILE" | grep "pr_status:" | head -1 | awk '{print $2}' || true)
T16_PR_URL=$(grep -A 10 "id: ${SID16}" "$BACKLOG_FILE" | grep "pr_url:" | head -1 | awk '{print $2}' | tr -d '"' || true)
if grep -q "gh pr create" "$GH_CALL_LOG"; then
  pass "T16a: fresh PR created instead of reusing the earlier cycle's merged PR"
else
  fail "T16a: gh pr create NOT called — the stale merged PR was taken as this cycle's"
fi
if [[ "$T16_PR_STATUS" == pending_review && "$T16_PR_URL" == "$FRESH_T16" ]]; then
  pass "T16b: row carries the fresh PR pending review, not the earlier merge"
else
  fail "T16b: row reconciled against the earlier cycle's PR (pr_status=${T16_PR_STATUS}, pr_url=${T16_PR_URL})"
fi
if grep -qE "pulls/96/merge|gh pr merge.*${STALE_T16}" "$GH_CALL_LOG"; then
  fail "T16c: merge attempted on the earlier cycle's PR"
else
  pass "T16c: earlier cycle's PR never merged"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "FAILURES: $FAIL_COUNT"
  exit 1
fi
