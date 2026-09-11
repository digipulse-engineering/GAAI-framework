#!/usr/bin/env bash
# impl-truncation-recovery.test.sh — an interrupted implementation is preserved
#
# When the implementation phase stops without producing a report, the work it had
# already written stays uncommitted in the story worktree, where it classifies as
# unverifiable and holds the Story. `_impl_commit_truncated` commits it instead,
# marked by trailers, so the tree is clean on the existing terms and the work is
# held as an object rather than as a working tree.
#
# Two things are asserted here:
#   1. Behaviour — against the real function extracted from daemon-dispatch.sh,
#      including every path on which it must refuse.
#   2. Wiring — that handle_impl_phase actually calls it on the failure exits
#      that leave work behind, and deliberately does not on the one that must
#      not be turned into a commit. A behaviour suite alone would keep passing
#      if every call site were deleted.
#
# Usage: bash .gaai/core/scripts/tests/impl-truncation-recovery.test.sh
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="${SCRIPTS_DIR}/daemon-dispatch.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1 — got '$2', expected '$3'"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

# ── Extract the functions under test ─────────────────────────────────────────
# Pulled from the shipped file so a rename or a move is caught here rather than
# passing against a stale copy.
extract() { sed -n "/^$1()/,/^}\$/p" "$2"; }

FUNCS=$(mktemp)
TALLY=$(mktemp)
trap 'rm -f "$FUNCS" "$TALLY"' EXIT

for fn in _restore_delivery_governance _impl_commit_truncated; do
  extract "$fn" "$DISPATCH"
done > "$FUNCS"
for fn in _restore_delivery_governance _impl_commit_truncated; do
  if ! grep -q "^${fn}()" "$FUNCS"; then
    echo "  FAIL: could not extract ${fn} — it moved or was renamed"
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
done

# ── Fixture ──────────────────────────────────────────────────────────────────
make_fixture() {
  T=$(mktemp -d)
  PROJECT_DIR="$T/project"
  WT="$T/wt"
  export PROJECT_DIR
  git init -q -b staging "$PROJECT_DIR"
  git -C "$PROJECT_DIR" config user.email test@test.com
  git -C "$PROJECT_DIR" config user.name Test
  mkdir -p "$PROJECT_DIR/.gaai/project/contexts/backlog"
  echo base > "$PROJECT_DIR/a.txt"
  echo "stories: []" > "$PROJECT_DIR/.gaai/project/contexts/backlog/active.backlog.yaml"
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" commit -qm base
  git -C "$PROJECT_DIR" worktree add -q "$WT" -b story/S1 HEAD
  git -C "$WT" config user.email test@test.com
  git -C "$WT" config user.name Test
}
drop_fixture() { cd /; rm -rf "$T"; }

# Make the worktree's next commit fail the way a hook or a missing identity does.
break_commits() {
  local hooks="$T/hooks"
  mkdir -p "$hooks"
  printf '#!/bin/sh\nexit 1\n' > "$hooks/pre-commit"
  chmod +x "$hooks/pre-commit"
  git -C "$WT" config core.hooksPath "$hooks"
}

echo "── 1. behaviour ─────────────────────────────────────────────────────────"
(
  . "$FUNCS"
  make_fixture
  before=$(git -C "$WT" rev-parse HEAD)
  _impl_commit_truncated S1 "$WT" no_report >/dev/null
  ck "clean tree reports settled" "$?" "0"
  ck "clean tree creates no commit" "$(git -C "$WT" rev-parse HEAD)" "$before"

  echo work >> "$WT/a.txt"
  echo new > "$WT/untracked.txt"
  echo "stories: [tampered]" > "$WT/.gaai/project/contexts/backlog/active.backlog.yaml"
  out=$(_impl_commit_truncated S1 "$WT" no_report); rc=$?
  ck "dirty tree reports settled" "$rc" "0"
  ck "tree is clean afterwards" "$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')" "0"
  ck "GAAI-Truncated trailer" "$(git -C "$WT" show -s --format='%(trailers:key=GAAI-Truncated,valueonly)' HEAD | tr -d '\n')" "true"
  ck "GAAI-Truncated-Reason trailer" "$(git -C "$WT" show -s --format='%(trailers:key=GAAI-Truncated-Reason,valueonly)' HEAD | tr -d '\n')" "no_report"
  ck "no attempt count is claimed" "$(git -C "$WT" show -s --format='%(trailers)' HEAD | grep -c 'GAAI-Attempt')" "0"
  ck "the commit stays on the story branch" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "story/S1"
  ck "untracked work is captured" "$(git -C "$WT" show --stat --format= HEAD | grep -c 'untracked.txt')" "1"
  ck "the backlog never reaches the branch" "$(git -C "$WT" show --stat --format= HEAD | grep -c 'active.backlog.yaml')" "0"
  ck "operator line is emitted" "$(printf '%s' "$out" | grep -c 'IMPL-TRUNCATED')" "1"

  before=$(git -C "$WT" rev-parse HEAD)
  _impl_commit_truncated S1 "$T/does-not-exist" no_report >/dev/null 2>&1
  ck "absent worktree is a no-op" "$(git -C "$WT" rev-parse HEAD)" "$before"

  # A detached HEAD is the test gate's scaffolding; a commit there would hang off
  # no branch, so it must be refused rather than made invisibly.
  git -C "$WT" checkout --detach -q
  echo detached >> "$WT/a.txt"
  out=$(_impl_commit_truncated S1 "$WT" no_report); rc=$?
  ck "detached HEAD reports unsettled" "$rc" "1"
  ck "and says why" "$(printf '%s' "$out" | grep -c 'detached')" "1"
  ck "and commits nothing" "$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')" "1"
  git -C "$WT" checkout -q story/S1 -- . 2>/dev/null
  git -C "$WT" checkout -q story/S1 2>/dev/null
  git -C "$WT" checkout -q -- . 2>/dev/null

  # A refused commit must be reported as unsettled, not swallowed.
  break_commits
  echo refused >> "$WT/a.txt"
  out=$(_impl_commit_truncated S1 "$WT" no_report); rc=$?
  ck "refused commit reports unsettled" "$rc" "1"
  ck "and says so" "$(printf '%s' "$out" | grep -c 'commit refused')" "1"
  ck "and leaves the work in place" "$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')" "1"
  drop_fixture

  # An unreadable tree prints nothing on stdout and looks exactly like a clean
  # one to anything that ignores the exit status. It must never read as settled.
  make_fixture
  echo work >> "$WT/a.txt"
  echo "gitdir: /nonexistent/admin/dir" > "$WT/.git"
  out=$(_impl_commit_truncated S1 "$WT" no_report); rc=$?
  ck "unreadable tree reports unsettled" "$rc" "1"
  ck "and says why" "$(printf '%s' "$out" | grep -c 'unreadable')" "1"
  drop_fixture
  echo "$PASS_COUNT $FAIL_COUNT" > "$TALLY"
)
read -r _p _f < "$TALLY"; PASS_COUNT=$(( PASS_COUNT + _p )); FAIL_COUNT=$(( FAIL_COUNT + _f ))

echo "── 2. wiring ────────────────────────────────────────────────────────────"
# Source-level assertions over the shipped file. Without these the suite above
# would keep passing with every call site removed.
IMPL_SPAN=$(awk '/^handle_impl_phase\(\) \{/{f=1} f{print} /^handle_qa_phase\(\) \{/{if(f) exit}' "$DISPATCH")
COMMIT_SPAN=$(awk '/^handle_commit_phase\(\) \{/{f=1} f{print}' "$DISPATCH")

ck "the executor-exit exits preserve the work" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -c '_impl_commit_truncated .* "executor_exit"')" "2"
ck "the missing-report exits preserve the work" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -c '_impl_commit_truncated .* "no_report"')" "2"
ck "the loop breaker preserves the work" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -c '_impl_commit_truncated .* "loop_breaker"')" "1"
ck "no other call site has appeared unreviewed" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -c '_impl_commit_truncated')" "5"
ck "every call site tolerates a refusal" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep '_impl_commit_truncated' | grep -c '|| true')" "5"

# The tampered-provenance exits must NOT preserve: the record covering the work
# changed underneath it, so the tree is exactly what must not become a commit.
ck "tampered provenance is never committed" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -B 8 'IMPL_PROVENANCE_TAMPERED' | grep -c '_impl_commit_truncated')" "0"
ck "and the exclusion is explained, not silent" \
   "$(printf '%s\n' "$IMPL_SPAN" | grep -c 'Deliberately not preserved')" "2"

ck "the PR body reports preserved commits" \
   "$(printf '%s\n' "$COMMIT_SPAN" | grep -c 'GAAI-Truncated,valueonly')" "1"
ck "and makes no claim about their content" \
   "$(printf '%s\n' "$COMMIT_SPAN" | grep -c 'not as a reviewed result')" "1"

echo
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
