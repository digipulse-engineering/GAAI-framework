#!/usr/bin/env bash
# worktree-branch-guard.test.sh — regression suite for the landed-or-preserved
# branch-deletion guard (E1057S02). Mirrors the bare-remote + clone + worktree
# fixture pattern already used by worktree-integrity.test.sh /
# recovery-non-destructive.test.sh.
#
# T1: incident replay — unpushed branch survives as a preserved rename
# T2: landed via remote backlog status:done — branch hard-deleted
# T3: landed via remote-ref presence (pushed, no PR yet) — branch hard-deleted
# T4: single-fire log throttle across two not-landed preservation events
set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

FIXTURE_BASE="/tmp/gaai-branch-guard-test-$$"
trap 'rm -rf "$FIXTURE_BASE"' EXIT

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/worktree-integrity.sh
source "${SCRIPT_DIR}/lib/worktree-integrity.sh"
# _worktree_branch_is_landed lazily sources lib/backlog-yaml.sh on first call,
# which itself runs under `set -euo pipefail` — sourcing flips that mode for
# this whole shell too (source is not scope-limited). This test intentionally
# never runs under -e (matches the `set -uo pipefail` header above); every rc
# below is captured explicitly, so re-assert +e defensively in case a guard
# call flips it before rc capture.
set +e

BACKLOG_REL_FIXTURE=".gaai/project/contexts/backlog/active.backlog.yaml"

# Bare remote + main clone on staging, with an empty backlog fixture at the
# default BACKLOG_REL path so the (a1) check has something to read.
setup_fixture() {
  local base="$1"
  rm -rf "${base}_remote.git" "${base}_main"

  git init --bare "${base}_remote.git" -q
  git clone "${base}_remote.git" "${base}_main" -q 2>/dev/null

  git -C "${base}_main" config user.email "test@gaai.local"
  git -C "${base}_main" config user.name "GAAI Test"
  git -C "${base}_main" config core.hooksPath /dev/null

  mkdir -p "$(dirname "${base}_main/${BACKLOG_REL_FIXTURE}")"
  cat > "${base}_main/${BACKLOG_REL_FIXTURE}" <<'YAML'
items: []
YAML

  echo "initial" > "${base}_main/file.txt"
  git -C "${base}_main" add .
  git -C "${base}_main" commit -m "init" -q
  git -C "${base}_main" branch -M staging
  git -C "${base}_main" push origin staging -q
  git -C "${base}_main" fetch origin -q
}

# Creates local branch story/<sid> with one commit NOT present on origin/staging.
# Leaves the main clone checked out back on staging when done (no worktree
# needed — this is a throwaway fixture, not a real delivery).
make_unpushed_branch() {
  local base="$1" sid="$2"
  git -C "${base}_main" checkout -B "story/${sid}" staging -q 2>/dev/null
  echo "unpushed-${sid}-$RANDOM-$(date +%s%N 2>/dev/null || date +%s)" >> "${base}_main/file.txt"
  git -C "${base}_main" add file.txt
  git -C "${base}_main" commit -m "unpushed-${sid}" -q
  git -C "${base}_main" checkout staging -q
}

# ── T1: incident replay — unpushed branch survives as a preserved rename ────
echo ""
echo "T1: incident replay (unpushed branch, no PR, no landed backlog status)"
T1="${FIXTURE_BASE}/t1"
setup_fixture "$T1"
make_unpushed_branch "$T1" "T1"

PROJECT_DIR="${T1}_main"
LOCK_DIR="${T1}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

_t1_original_tip=$(git -C "${T1}_main" rev-parse "story/T1" 2>/dev/null || echo "")

# Subshell isolation: the guard's lazy backlog-yaml.sh source flips `set -e`
# for whatever shell runs it; `( ... )` confines that to the subshell so it
# never leaks into this test script's own option state.
( _worktree_branch_delete_or_preserve "T1" "story/T1" "test-incident" )
_rc_t1=$?

if ! git -C "${T1}_main" rev-parse --verify -q "story/T1" >/dev/null 2>&1; then
  pass "T1a: story/T1 no longer exists as a ref"
else
  fail "T1a: story/T1 still exists as a ref"
fi

_t1_preserved_count=$(git -C "${T1}_main" for-each-ref --format='%(refname:short)' "refs/heads/story/T1-preserved-*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_t1_preserved_count" -eq 1 ]]; then
  pass "T1b: exactly one story/T1-preserved-* ref exists"
else
  fail "T1b: expected exactly one preserved ref, got ${_t1_preserved_count}"
fi

_t1_preserved_ref=$(git -C "${T1}_main" for-each-ref --format='%(refname:short)' "refs/heads/story/T1-preserved-*" 2>/dev/null | head -1)
if [[ -n "$_t1_preserved_ref" ]] && git -C "${T1}_main" log "$_t1_preserved_ref" --format=%H 2>/dev/null | grep -qF "$_t1_original_tip"; then
  pass "T1c: original commit SHA present on the preserved ref"
else
  fail "T1c: original commit SHA NOT found on preserved ref"
fi

if grep -qE '\|T1\|' "${LOCK_DIR}/.branch-preserved.audit" 2>/dev/null; then
  pass "T1d: audit log contains an entry for T1"
else
  fail "T1d: audit log missing T1 entry"
fi

if grep -qF "$_t1_original_tip" "${LOCK_DIR}/.branch-preserved.audit" 2>/dev/null; then
  pass "T1d2: audit log entry records the branch tip SHA"
else
  fail "T1d2: audit log entry missing tip SHA"
fi

if [[ "$_rc_t1" -eq 1 ]]; then
  pass "T1e: function returns 1 (preserved)"
else
  fail "T1e: expected rc=1, got ${_rc_t1}"
fi

# ── T2: landed via remote backlog status:done → hard-deleted ───────────────
echo ""
echo "T2: landed via remote backlog status:done"
T2="${FIXTURE_BASE}/t2"
setup_fixture "$T2"
make_unpushed_branch "$T2" "T2"

cat > "${T2}_main/${BACKLOG_REL_FIXTURE}" <<'YAML'
items:
- id: T2
  status: done
YAML
git -C "${T2}_main" add "${BACKLOG_REL_FIXTURE}"
git -C "${T2}_main" commit -m "backlog: T2 done" -q
git -C "${T2}_main" push origin staging -q
git -C "${T2}_main" fetch origin -q

PROJECT_DIR="${T2}_main"
LOCK_DIR="${T2}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

( _worktree_branch_delete_or_preserve "T2" "story/T2" "test-landed-backlog" )
_rc_t2=$?

if ! git -C "${T2}_main" rev-parse --verify -q "story/T2" >/dev/null 2>&1; then
  pass "T2a: story/T2 branch deleted"
else
  fail "T2a: story/T2 branch still exists"
fi

_t2_preserved_count=$(git -C "${T2}_main" for-each-ref --format='%(refname:short)' "refs/heads/story/T2-preserved-*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_t2_preserved_count" -eq 0 ]]; then
  pass "T2b: no preserved-* ref created"
else
  fail "T2b: unexpected preserved-* ref created (count=${_t2_preserved_count})"
fi

if [[ "$_rc_t2" -eq 0 ]]; then
  pass "T2c: function returns 0 (landed)"
else
  fail "T2c: expected rc=0, got ${_rc_t2}"
fi

# ── T3: landed via remote-ref presence (pushed, open-PR-equivalent) ────────
echo ""
echo "T3: landed via remote-ref presence (branch pushed, no PR entry)"
T3="${FIXTURE_BASE}/t3"
setup_fixture "$T3"
make_unpushed_branch "$T3" "T3"
git -C "${T3}_main" push origin "story/T3" -q

PROJECT_DIR="${T3}_main"
LOCK_DIR="${T3}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

( _worktree_branch_delete_or_preserve "T3" "story/T3" "test-landed-remote-ref" )
_rc_t3=$?

if ! git -C "${T3}_main" rev-parse --verify -q "story/T3" >/dev/null 2>&1; then
  pass "T3a: story/T3 branch deleted"
else
  fail "T3a: story/T3 branch still exists"
fi

if [[ "$_rc_t3" -eq 0 ]]; then
  pass "T3b: function returns 0 (landed via remote ref)"
else
  fail "T3b: expected rc=0, got ${_rc_t3}"
fi

# ── T4: single-fire log throttle across two not-landed preservation events ─
echo ""
echo "T4: single-fire log throttle (2 preservation events, 1 log line)"
T4="${FIXTURE_BASE}/t4"
setup_fixture "$T4"
make_unpushed_branch "$T4" "T4"

PROJECT_DIR="${T4}_main"
LOCK_DIR="${T4}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

_t4_out1=$(_worktree_branch_delete_or_preserve "T4" "story/T4" "test-throttle-1" 2>&1)
_rc_t4_1=$?

sleep 1  # guarantee a distinct preserved-branch timestamp for the 2nd rename

# Recreate story/T4 — simulates the daemon retry path handing out a fresh
# branch that then dies again (the fast-crash-retry-loop scenario AC4 bounds).
make_unpushed_branch "$T4" "T4"
_t4_out2=$(_worktree_branch_delete_or_preserve "T4" "story/T4" "test-throttle-2" 2>&1)
_rc_t4_2=$?

_t4_audit_count=$(grep -cE '\|T4\|' "${LOCK_DIR}/.branch-preserved.audit" 2>/dev/null || echo 0)
if [[ "$_t4_audit_count" -eq 2 ]]; then
  pass "T4a: audit log has 2 entries for T4 (both preservation events recorded)"
else
  fail "T4a: expected 2 audit entries for T4, got ${_t4_audit_count}"
fi

_t4_log_lines=$(printf '%s\n%s\n' "$_t4_out1" "$_t4_out2" | grep -c '\[WORKTREE-GUARD\]' || true)
if [[ "$_t4_log_lines" -eq 1 ]]; then
  pass "T4b: [WORKTREE-GUARD] log line printed exactly once across both calls (throttled)"
else
  fail "T4b: expected exactly 1 [WORKTREE-GUARD] line, got ${_t4_log_lines}"
fi

if [[ "$_rc_t4_1" -eq 1 && "$_rc_t4_2" -eq 1 ]]; then
  pass "T4c: both calls return 1 (preserved)"
else
  fail "T4c: expected rc=1 for both calls, got rc1=${_rc_t4_1} rc2=${_rc_t4_2}"
fi

# ── T8: preservation REPLICATES the tip to the remote before renaming ───────
# A rename alone preserves nothing durable: the ref lives in one object store and
# nothing pushes it, so losing that store loses the work while the name survives.
echo ""
echo "T8: preservation pushes the tip to refs/gaai/preserved/* and records it"
T8="${FIXTURE_BASE}/t8"
setup_fixture "$T8"
make_unpushed_branch "$T8" "T8"

PROJECT_DIR="${T8}_main"
LOCK_DIR="${T8}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

_t8_tip=$(git -C "${T8}_main" rev-parse story/T8)
( _worktree_branch_delete_or_preserve "T8" "story/T8" "test-replication" ) >/dev/null 2>&1
_rc_t8=$?

_t8_preserved=$(git -C "${T8}_main" for-each-ref --format='%(refname:short)' "refs/heads/story/T8-preserved-*" | head -1)
_t8_remote_tip=$(git -C "${T8}_main" ls-remote origin "refs/gaai/preserved/${_t8_preserved}" 2>/dev/null | awk '{print $1}')

if [[ "$_t8_remote_tip" == "$_t8_tip" ]]; then
  pass "T8a: preserved tip is on the remote at refs/gaai/preserved/* with the exact SHA"
else
  fail "T8a: remote tip '${_t8_remote_tip}' != local tip '${_t8_tip}' — work is unreplicated"
fi

if grep -qE '\|T8\|.*\|replicated=yes$' "${LOCK_DIR}/.branch-preserved.audit" 2>/dev/null; then
  pass "T8b: audit line records replicated=yes"
else
  fail "T8b: audit line missing replicated=yes"
fi

# The object must survive deletion of the local ref — that is the whole point.
git -C "${T8}_main" branch -D "$_t8_preserved" >/dev/null 2>&1
if git -C "${T8}_remote.git" cat-file -e "$_t8_tip" 2>/dev/null; then
  pass "T8c: tip survives in the remote object store after the local ref is gone"
else
  fail "T8c: tip lost once the local ref was deleted — replication did not protect it"
fi

[[ "$_rc_t8" -eq 1 ]] && pass "T8d: still returns 1 (preserved)" || fail "T8d: expected rc=1, got ${_rc_t8}"

# ── T9: replication failure must be loud, un-throttled, and honestly recorded ─
# Offline / unauthenticated / read-only remote are normal. Preservation must not
# be blocked by them, but it must never be silently reported as safe.
echo ""
echo "T9: unreachable remote → still preserved, recorded replicated=no, logged every time"
T9="${FIXTURE_BASE}/t9"
setup_fixture "$T9"
make_unpushed_branch "$T9" "T9"

PROJECT_DIR="${T9}_main"
LOCK_DIR="${T9}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"
git -C "${T9}_main" remote set-url origin "${FIXTURE_BASE}/does-not-exist.git"

_t9_tip=$(git -C "${T9}_main" rev-parse story/T9)
_t9_out1=$( ( _worktree_branch_delete_or_preserve "T9" "story/T9" "test-offline-1" ) 2>&1 )
_rc_t9=$?

if git -C "${T9}_main" for-each-ref --format='%(refname:short)' "refs/heads/story/T9-preserved-*" | grep -q .; then
  pass "T9a: preserved locally despite the unreachable remote (network never blocks preservation)"
else
  fail "T9a: preservation was blocked by a network failure"
fi

if grep -qE '\|T9\|.*\|replicated=no$' "${LOCK_DIR}/.branch-preserved.audit" 2>/dev/null; then
  pass "T9b: audit line records replicated=no — no false claim of safety"
else
  fail "T9b: audit line does not record replicated=no"
fi

case "$_t9_out1" in
  *"LOCALLY ONLY"*) pass "T9c: operator log names the unreplicated preservation" ;;
  *) fail "T9c: unreplicated preservation was not surfaced to the operator" ;;
esac

# Second event within the throttle window: the throttle must NOT suppress it.
make_unpushed_branch "$T9" "T9"
_t9_out2=$( ( _worktree_branch_delete_or_preserve "T9" "story/T9" "test-offline-2" ) 2>&1 )
case "$_t9_out2" in
  *"LOCALLY ONLY"*) pass "T9d: second unreplicated preservation also logged (throttle bypassed)" ;;
  *) fail "T9d: throttle suppressed a data-safety event" ;;
esac

# ── gh stub for the (a2) merged-PR clause ────────────────────────────────────
# Answers BOTH call shapes on purpose, so T5 is a true regression test rather
# than a test that only passes because the implementation changed:
#   --json state       (the pre-fix call) → reports MERGED, which is what made
#                       the old name-only match delete unrelated work
#   --json headRefOid  (the current call) → reports $GH_STUB_MERGED_OIDS, one
#                       per line, matching `gh ... --jq '.[].headRefOid'`
# GH_STUB_FAIL=1 emulates absent/unauthenticated/failing gh.
gh() {
  [[ "${GH_STUB_FAIL:-0}" == "1" ]] && return 1
  local a want_oid=0
  for a in "$@"; do
    [[ "$a" == *headRefOid* ]] && want_oid=1
  done
  if [[ "$want_oid" == "1" ]]; then
    [[ -n "${GH_STUB_MERGED_OIDS:-}" ]] && printf '%s\n' "$GH_STUB_MERGED_OIDS"
    return 0
  fi
  printf '[{"state":"MERGED"}]\n'
  return 0
}

# ── T5: REGRESSION — a merged PR on a REUSED branch name must NOT affirm ─────
# story/<sid> is reused across delivery cycles and GitHub retains headRefName on
# merged PRs forever, so cycle N's merged PR kept affirming "landed" for cycle
# N+1's unrelated, unpushed tip — and the caller then hard-deleted it.
echo ""
echo "T5: stale merged PR on a reused branch name (tip has moved on) → preserved"
T5="${FIXTURE_BASE}/t5"
setup_fixture "$T5"
make_unpushed_branch "$T5" "T5"

PROJECT_DIR="${T5}_main"
LOCK_DIR="${T5}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

# The tip that a previous cycle's PR merged.
_t5_old_tip=$(git -C "${T5}_main" rev-parse story/T5)
# The branch is reused and advances: current tip is now a different object.
make_unpushed_branch "$T5" "T5"
_t5_new_tip=$(git -C "${T5}_main" rev-parse story/T5)

GH_STUB_MERGED_OIDS="$_t5_old_tip"
# Subshell isolation: same reason as T1 — the guard's lazy backlog-yaml.sh
# source flips `set -e` for whatever shell runs it.
( _worktree_branch_delete_or_preserve "T5" "story/T5" "test-stale-merged-pr" ) >/dev/null 2>&1
_rc_t5=$?
unset GH_STUB_MERGED_OIDS

if [[ "$_t5_old_tip" != "$_t5_new_tip" ]]; then
  pass "T5a: fixture is valid — reused branch tip actually moved"
else
  fail "T5a: fixture invalid — tip did not move, T5 proves nothing"
fi

if [[ "$_rc_t5" -eq 1 ]]; then
  pass "T5b: stale merged PR did NOT affirm landed (rc=1, preserved)"
else
  fail "T5b: expected rc=1 (preserved), got ${_rc_t5} — unrelated work would be deleted"
fi

if git -C "${T5}_main" rev-parse --verify -q "$_t5_new_tip" >/dev/null 2>&1 \
    && git -C "${T5}_main" branch -a --contains "$_t5_new_tip" 2>/dev/null | grep -q 'preserved'; then
  pass "T5c: the current tip survives on a preserved branch"
else
  fail "T5c: current tip is not reachable from any preserved branch"
fi

# ── T6: a merged PR that merged THIS EXACT TIP still affirms ────────────────
# The fix must not break the legitimate case, or every landed branch leaks.
echo ""
echo "T6: merged PR whose headRefOid IS the current tip → hard-deleted"
T6="${FIXTURE_BASE}/t6"
setup_fixture "$T6"
make_unpushed_branch "$T6" "T6"

PROJECT_DIR="${T6}_main"
LOCK_DIR="${T6}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

_t6_tip=$(git -C "${T6}_main" rev-parse story/T6)
GH_STUB_MERGED_OIDS="deadbeef00000000000000000000000000000000
${_t6_tip}"
# Subshell isolation: same reason as T1 — the guard's lazy backlog-yaml.sh
# source flips `set -e` for whatever shell runs it.
( _worktree_branch_delete_or_preserve "T6" "story/T6" "test-exact-merged-pr" ) >/dev/null 2>&1
_rc_t6=$?
unset GH_STUB_MERGED_OIDS

if [[ "$_rc_t6" -eq 0 ]]; then
  pass "T6a: exact-tip merged PR affirms landed (rc=0), even among other PRs"
else
  fail "T6a: expected rc=0 (deleted), got ${_rc_t6} — landed branches would leak"
fi

if ! git -C "${T6}_main" rev-parse --verify -q "story/T6" >/dev/null 2>&1; then
  pass "T6b: branch story/T6 hard-deleted"
else
  fail "T6b: story/T6 still present after a verified landing"
fi

# ── T7: unavailable gh must fail closed to preserve ─────────────────────────
echo ""
echo "T7: absent/unauthenticated/failing gh → preserved (fail closed)"
T7="${FIXTURE_BASE}/t7"
setup_fixture "$T7"
make_unpushed_branch "$T7" "T7"

PROJECT_DIR="${T7}_main"
LOCK_DIR="${T7}_main/.gaai-locks"
mkdir -p "$LOCK_DIR"
TARGET_BRANCH="staging"

GH_STUB_FAIL=1
# Subshell isolation: same reason as T1 — the guard's lazy backlog-yaml.sh
# source flips `set -e` for whatever shell runs it.
( _worktree_branch_delete_or_preserve "T7" "story/T7" "test-gh-unavailable" ) >/dev/null 2>&1
_rc_t7=$?
unset GH_STUB_FAIL

if [[ "$_rc_t7" -eq 1 ]]; then
  pass "T7: failing gh does not affirm (rc=1, preserved)"
else
  fail "T7: expected rc=1 (preserved), got ${_rc_t7} — provider failure must never affirm"
fi

unset -f gh

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== worktree-branch-guard test suite ==="
echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
