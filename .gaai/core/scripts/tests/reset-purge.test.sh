#!/usr/bin/env bash
# Forward-only preservation matrix: recovery never rewinds or purges evidence.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
DAEMON="$ROOT/.gaai/core/scripts/delivery-daemon.sh"
CLASSIFIER="$ROOT/.gaai/core/scripts/lib/stuck-classifier.sh"
TEST_BASH="${GAAI_TEST_BASH:-$BASH}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gaai-forward-preserve.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
expect(){ local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

current=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BASH")
selected=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$TEST_BASH")
printf 'interpreter=%s version=%s\n' "$current" "$BASH_VERSION"
expect "exact selected interpreter" test "$current" = "$selected"

HARNESS="$TMP/harness.sh"
awk '/^_forward_sha256\(\)/{on=1} /^exceeded_stories\(\)/{on=0} on{print}' "$DAEMON" > "$HARNESS"
awk '/^_reconcile_story_file_from_staging\(\)/{on=1} /^# ── PR merge watcher/{on=0} on{print}' "$DAEMON" >> "$HARNESS"
source "$CLASSIFIER"
source "$HARNESS"

legacy='_recovery_revert_refined|status refined \[daemon-recovery|reset_phase|missing-plan|no-progress'
if rg -n "$legacy" "$DAEMON" "$CLASSIFIER" >/dev/null 2>&1; then
  fail "reverse reset and purge contracts are absent"
else
  pass "reverse reset and purge contracts are absent"
fi
if rg -n '_legacy_|_retired_' "$DAEMON" "$CLASSIFIER" >/dev/null 2>&1; then
  fail "legacy behavior was not renamed in place"
else
  pass "legacy behavior was not renamed in place"
fi

LOCK_DIR="$TMP/locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
context=$(_forward_context_path EPRESERVE)
source_a=1111111111111111111111111111111111111111
source_b=2222222222222222222222222222222222222222
blob=3333333333333333333333333333333333333333
record=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
row=$(_forward_bind_context "$context" EPRESERVE "$source_a" "$blob" "$record" \
  none none none none none none verified resume resumable none) || exit 1
digest=${row##*$'\t'}
before=$(shasum -a 256 "$context" | awk '{print $1}')
if _forward_bind_context "$context" EPRESERVE "$source_b" "$blob" "$record" \
    none none none none none none verified resume resumable none >/dev/null; then
  fail "conflicting successor context is rejected"
else
  pass "conflicting successor context is rejected"
fi
after=$(shasum -a 256 "$context" | awk '{print $1}')
expect "context mismatch preserves exact evidence bytes" test "$after" = "$before"
if forward_context_remove "$context" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; then
  fail "wrong digest cannot purge context"
else
  pass "wrong digest cannot purge context"
fi
expect "wrong-digest failure preserves context" test -f "$context"
expect "exact digest retires context" forward_context_remove "$context" "$digest"

GAAI_WORKTREES_BASE="$TMP/worktrees"
wt="$GAAI_WORKTREES_BASE/EPRESERVE-workspace"
mkdir -p "$wt"
printf 'operator evidence\n' > "$wt/uncommitted.txt"
PROJECT_DIR="$TMP/repo"; REPO_ROOT="$PROJECT_DIR"
TARGET_BRANCH=staging
BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"; BACKLOG="$BACKLOG_FILE"
remote="$TMP/remote.git"
git init --bare "$remote" >/dev/null
git init "$PROJECT_DIR" >/dev/null
git -C "$PROJECT_DIR" config user.email "test@gaai.local"
git -C "$PROJECT_DIR" config user.name "GAAI Test"
mkdir -p "$(dirname "$BACKLOG_FILE")"
printf 'items: []\n' > "$BACKLOG_FILE"
git -C "$PROJECT_DIR" add "$BACKLOG_REL"
git -C "$PROJECT_DIR" commit -m "seed configured target" >/dev/null
git -C "$PROJECT_DIR" branch -M "$TARGET_BRANCH"
git -C "$PROJECT_DIR" remote add origin "$remote"
git -C "$PROJECT_DIR" remote set-url --push origin "$remote"
[[ "$(git -C "$PROJECT_DIR" remote get-url --push origin)" == "$remote" ]] || exit 1
git -C "$PROJECT_DIR" push -u origin "$TARGET_BRANCH" >/dev/null
expected_source=$(git -C "$PROJECT_DIR" rev-parse "origin/${TARGET_BRANCH}")
zero=0000000000000000000000000000000000000000000000000000000000000000
_forward_worktree_state(){ printf '%s\n' verified; }
_forward_plan_present(){ return 1; }
_forward_classify(){ return 1; }
_forward_evidence(){ :; }
if _forward_recovery_one EPRESERVE; then
  fail "source failure blocks recovery"
else
  pass "source failure blocks recovery"
fi
expect "blocked recovery preserves worktree bytes" grep -qx 'operator evidence' "$wt/uncommitted.txt"

log(){ :; }
unborn="$TMP/unborn"
git init "$unborn" >/dev/null
printf 'local evidence\n' > "$unborn/operator.txt"
if _reconcile_story_file_from_staging EPRESERVE "$unborn" "$expected_source"; then
  fail "unborn worktree cannot be converted to fresh pickup"
else
  rc=$?
  [[ "$rc" -eq 2 ]] && pass "unborn worktree cannot be converted to fresh pickup" \
    || fail "unborn worktree returns typed refusal"
fi
expect "unborn refusal preserves local evidence" grep -qx 'local evidence' "$unborn/operator.txt"

python3 - "$DAEMON" <<'PY'
import sys
text = open(sys.argv[1]).read()
start = text.index('_reconcile_story_file_from_staging()')
end = text.index('# ── PR merge watcher', start)
block = text[start:end]
for forbidden in ('worktree remove --force', 'rm -rf', 'branch -D', 'status refined'):
    if forbidden in block:
        raise SystemExit(1)
PY
expect "story reconcile contains no destructive fallback" test "$?" -eq 0

# ── A concluded (terminal) context must not hold a reopened Story hostage ──
# After an escalation the scan records action=forward_terminal with
# reason=terminal_projection and intended_fields=status=escalated (the exact
# record observed on a live daemon). An operator may
# then reset the row to refined; the next launch binds a non-terminal intention
# that can never equal the terminal record. That must retire the concluded
# context (bytes preserved beside it) and install a fresh one — while a
# non-terminal predecessor that disagrees stays a rejected conflict.
context_t=$(_forward_context_path ECONCLUDED)
row_t=$(_forward_bind_context "$context_t" ECONCLUDED "$source_a" "$blob" "$record" \
  none none none none none none unknown forward_terminal terminal_projection status=escalated) || exit 1
digest_t=${row_t##*$'\t'}
bytes_t=$(shasum -a 256 "$context_t" | awk '{print $1}')
if row_n=$(_forward_bind_context "$context_t" ECONCLUDED "$source_b" "$blob" "$record" \
    none none none none none none verified resume resumable none); then
  pass "a reopened Story binds a fresh context over a concluded one"
else
  fail "a concluded context still blocks the reopened Story (context_invalid)"
fi
expect "the fresh context carries the new intention" test "$(printf '%s' "$row_n" | cut -f12)" = resume
expect "the concluded context is preserved beside the path under its digest" \
  test "$(shasum -a 256 "${context_t}.concluded.${digest_t}" 2>/dev/null | awk '{print $1}')" = "$bytes_t"
if _forward_bind_context "$context_t" ECONCLUDED "$source_a" "$blob" "$record" \
    none none none none none none verified resume resumable none >/dev/null; then
  fail "a non-terminal predecessor that disagrees is still rejected"
else
  pass "a non-terminal predecessor that disagrees is still rejected"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
