#!/usr/bin/env bash
# daemon-home-self-projection.test.sh — the daemon's own lifecycle projection
# must not halt it on its own coordination home.
#
# The lifecycle journal publishes a backlog transition to the target through a
# private index, then writes the verified target backlog into the home's working
# tree without advancing the home's branch. Before the settle, the next
# per-cycle home check refused that tree as `home_dirty` and the daemon stayed
# halted until an authorized restart.
#
# Every case builds a hermetic fixture: a bare remote, a repository clone and a
# `gaai-daemon-home` linked worktree tracking origin/staging. The projection is
# produced by the real journal emitter and the real projector
# (`chore_commit_project_journal`), and materialised into the home exactly as
# `_journal_persist_lifecycle_locked` does. The per-cycle check, the settle and
# its locked body are extracted from delivery-daemon.sh (the file runs launch
# guards at load); the home verifier, the journal and the shared staging lock
# are the real libraries.
#
#   S1  one [dispatch] projection            -> settled, rebound, clean, no file written
#   S2  two successive projections           -> settled to the tip
#   S3  projection + another modified file    -> refused, home untouched
#   S4  projection + a hand edit of backlog   -> refused, home untouched
#   S5  an [operator] commit in the advance   -> refused and named, home untouched
#   S6  a [dispatch]-stamped non-backlog write -> refused, home untouched
#   S7  projection + an untracked file        -> refused, home untouched
#   S8  staged backlog                        -> refused (index dirt is never settled)
#   S9  HEAD is not the bound target          -> refused, home untouched
#   S10 tree lags the target tip              -> refused, home untouched
#   S11 staging lock held by another owner    -> refused, then settled once released
#   S12 staging lock primitive unavailable    -> refused
#   S13 clean home                            -> passes with no ref movement
#   S14 the refusal names its cause once
#
# Usage: bash .gaai/core/scripts/tests/daemon-home-self-projection.test.sh

set -uo pipefail
unset GIT_EDITOR GAAI_PLAN_MODEL GAAI_QA_MODEL GAAI_IMPL_MODEL
unset GAAI_BACKLOG_PROJECTION_FAULT GAAI_LIFECYCLE_EXPECTED_SOURCE_SHA

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DD="$SCRIPTS_DIR/delivery-daemon.sh"
BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
TARGET_BRANCH=staging

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-home-selfproj-XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

# ── Functions under test, extracted by name ─────────────────────────────────
HARNESS="$ROOT/harness.sh"
: > "$HARNESS"
for _fn in _settle_redundant_self_projection _settle_redundant_self_projection_locked \
           _per_cycle_home_check; do
  sed -n "/^${_fn}()/,/^}/p" "$DD" >> "$HARNESS"
done
if grep -q '^_per_cycle_home_check()' "$HARNESS"; then
  pass "S0: the per-cycle home check was extracted"
else
  fail "S0: the per-cycle home check could not be extracted"
fi

# ── Real libraries ──────────────────────────────────────────────────────────
export LOCK_DIR="$ROOT/locks"
mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
export STAGING_LOCK="$LOCK_DIR/.staging.lock"
export SCHEDULER="$SCRIPTS_DIR/backlog-scheduler.sh"
export PROJECT_DIR="$ROOT"
export BACKLOG_FILE="$ROOT/unused.yaml"
: > "$BACKLOG_FILE"
# shellcheck source=../daemon-dispatch.sh
if ! source "$SCRIPTS_DIR/daemon-dispatch.sh" >/dev/null 2>&1; then
  echo "ERROR: daemon-dispatch.sh could not be sourced"; exit 1
fi
# shellcheck source=../lib/daemon-home.sh
source "$SCRIPTS_DIR/lib/daemon-home.sh"
# shellcheck source=../lib/backlog-journal.sh
source "$SCRIPTS_DIR/lib/backlog-journal.sh"
# shellcheck source=../lib/chore-commit.sh
source "$SCRIPTS_DIR/lib/chore-commit.sh"
# shellcheck disable=SC1090
source "$HARNESS"
declare -F _lifecycle_with_staging_lock >/dev/null \
  || { echo "ERROR: the shared staging lock primitive is unavailable"; exit 1; }

RED='' NC=''
LOGF="$ROOT/daemon.log"
log() { printf '%s\n' "$*" >> "$LOGF"; }
# The vendored YAML runtime tuple is out of scope here: the fixture carries none.
_daemon_repair_tuple() { return 0; }

# ── Fixture ─────────────────────────────────────────────────────────────────
# new_fixture <name>: sets REPO, HOME_WT, JOURNAL, BOUND
new_fixture() {
  local base="$ROOT/$1"
  mkdir -p "$base"
  git init -q --bare "$base/remote.git"
  git clone -q "$base/remote.git" "$base/repo" 2>/dev/null
  git -C "$base/repo" config user.email fixture@example.invalid
  git -C "$base/repo" config user.name home-self-projection-test
  git -C "$base/repo" checkout -q -b staging
  mkdir -p "$base/repo/$(dirname "$BACKLOG_REL")" "$base/repo/tool"
  printf '%s\n' '.gaai/project/contexts/backlog/.delivery-locks/' > "$base/repo/.gitignore"
  printf '%s\n' \
    'items:' \
    '- id: STORY-1' \
    '  status: in_progress' \
    '  phase_status: not_started' \
    '- id: STORY-2' \
    '  status: refined' \
    '  phase_status: not_started' > "$base/repo/$BACKLOG_REL"
  printf '%s\n' 'echo framework' > "$base/repo/tool/framework.sh"
  git -C "$base/repo" add -A
  git -C "$base/repo" commit -q -m seed
  git -C "$base/repo" push -q -u origin staging
  git -C "$base/repo" worktree add -q -b gaai-daemon-home "$base/home" origin/staging 2>/dev/null
  git -C "$base/home" branch -q --set-upstream-to=origin/staging gaai-daemon-home
  REPO="$base/repo"
  HOME_WT="$base/home"
  JOURNAL="$base/journal"
  BOUND="$(git -C "$HOME_WT" rev-parse HEAD)"
}

# materialise_target: what the lifecycle writer does to the home's tree, before
# and after it projects — the verified target backlog, whole-file, via rename.
materialise_target() {
  local tmp
  git -C "$HOME_WT" fetch -q origin staging
  tmp="$(mktemp "$ROOT/.snapshot-XXXXXX")"
  git -C "$HOME_WT" show "origin/staging:$BACKLOG_REL" > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$HOME_WT/$BACKLOG_REL"
}

# project_dispatch <story> <field> <value>: one dispatch-owned lifecycle
# transition through the real journal and the real projector, run from the home.
project_dispatch() {
  local story="$1" field="$2" value="$3" rc=0
  materialise_target
  (
    cd "$HOME_WT" || exit 1
    export BACKLOG_FILE="$HOME_WT/$BACKLOG_REL" BACKLOG_REL TARGET_BRANCH
    export GAAI_BACKLOG_JOURNAL_DIR="$JOURNAL"
    export GAAI_BACKLOG_JOURNAL_SOURCE_REF=origin/staging
    backlog_journal_begin_run "$BACKLOG_FILE" dispatch.plan >/dev/null 2>&1 || exit 2
    backlog_journal_emit "$BACKLOG_FILE" "$story" "$field" "$value" \
      dispatch.plan "$BACKLOG_JOURNAL_RUN_TOKEN" >/dev/null 2>&1 || exit 3
    chore_commit_project_journal dispatch >/dev/null 2>&1 || exit 4
  ) || rc=$?
  [[ "$rc" -eq 0 ]] || { echo "fixture: projection failed rc=$rc"; return 1; }
  materialise_target
}

# foreign_commit <subject> <path> <content>: a write landed on the target from
# another clone, outside this daemon.
foreign_commit() {
  local subject="$1" path="$2" content="$3" other="$ROOT/other-$RANDOM$RANDOM"
  git clone -q -b staging "$(git -C "$REPO" remote get-url origin)" "$other" 2>/dev/null
  printf '%s\n' "$content" >> "$other/$path"
  git -C "$other" add -A
  git -C "$other" -c user.email=o@example.invalid -c user.name=other commit -q -m "$subject"
  git -C "$other" push -q origin staging
  rm -rf "$other"
}

# run_check: run the extracted per-cycle check against the fixture in a subshell
# and report the outcome, the bound target and the settle's refusal cause.
run_check() {
  (
    GAAI_DAEMON_HOME="$HOME_WT"
    GAAI_TARGET_SHA="${CHECK_BOUND:-$BOUND}"
    PROJECT_DIR="$HOME_WT"
    REPO_ROOT="$REPO"
    _GAAI_HOME_REFUSAL_REPORTED=""
    _GAAI_HOME_REFUSAL_POLLS=0
    if [[ "${CHECK_NO_LOCK:-0}" == 1 ]]; then unset -f _lifecycle_with_staging_lock; fi
    if _per_cycle_home_check 2>/dev/null; then
      printf 'ok|%s|%s\n' "$GAAI_TARGET_SHA" "${_GAAI_SETTLE_REFUSED_BY:-}"
    else
      printf 'refused:%s:%s|%s|%s\n' "${GAAI_HOME_REASON:-}" "${GAAI_HOME_EVIDENCE:-}" \
        "$GAAI_TARGET_SHA" "${_GAAI_SETTLE_REFUSED_BY:-}"
    fi
  )
}

home_head() { git -C "$HOME_WT" rev-parse HEAD; }
target_tip() { git -C "$REPO" ls-remote origin refs/heads/staging | awk '{print $1}'; }
home_clean() {
  git -C "$HOME_WT" diff --quiet && git -C "$HOME_WT" diff --cached --quiet \
    && [[ -z "$(git -C "$HOME_WT" ls-files --others --exclude-standard)" ]]
}
inode_of() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }
digest_of() { git hash-object --no-filters -- "$1"; }

# assert_untouched <label> <head> <backlog digest> [<other path> <other digest>]
assert_untouched() {
  local label="$1" head="$2" digest="$3"
  if [[ "$(home_head)" == "$head" && "$(digest_of "$HOME_WT/$BACKLOG_REL")" == "$digest" ]] \
      && { [[ $# -lt 5 ]] || [[ "$(digest_of "$HOME_WT/$4")" == "$5" ]]; }; then
    pass "$label: the home is preserved unchanged"
  else
    fail "$label: the refusal changed the home"
  fi
}

echo ""
echo "=== S1: one dispatch projection is settled, not halted on ==="
new_fixture s1
project_dispatch STORY-1 phase_status planned || fail "S1: fixture"
if git -C "$HOME_WT" diff --quiet; then
  fail "S1-pre: the projection did not leave the home dirty (fixture does not reproduce)"
else
  pass "S1-pre: the projection leaves the home's tree ahead of its HEAD, as the writer does"
fi
TIP="$(target_tip)"
INODE_BEFORE="$(inode_of "$HOME_WT/$BACKLOG_REL")"
DIGEST_BEFORE="$(digest_of "$HOME_WT/$BACKLOG_REL")"
: > "$LOGF"
OUT="$(run_check)"
case "$OUT" in
  "ok|$TIP|") pass "S1-a: the per-cycle check settles and rebinds to the target tip" ;;
  *)          fail "S1-a: the daemon halted on its own projection: $OUT" ;;
esac
[[ "$(home_head)" == "$TIP" ]] && pass "S1-b: the home's branch now names the tip" \
  || fail "S1-b: the home's branch was not advanced ($(home_head) vs $TIP)"
home_clean && pass "S1-c: the home is clean (worktree, index, untracked)" \
  || fail "S1-c: the home is still dirty after the settle"
if [[ "$(inode_of "$HOME_WT/$BACKLOG_REL")" == "$INODE_BEFORE" \
      && "$(digest_of "$HOME_WT/$BACKLOG_REL")" == "$DIGEST_BEFORE" ]]; then
  pass "S1-d: no working-tree file was written by the settle"
else
  fail "S1-d: the settle rewrote the backlog file"
fi
grep -q 'HOME-REBIND.*settled' "$LOGF" && pass "S1-e: the settle is logged as a rebind" \
  || fail "S1-e: the settle left no log line"
[[ "$(git -C "$HOME_WT" log -1 --format=%s HEAD)" == *'[dispatch]' ]] \
  && pass "S1-f: the tip is the real projector's [dispatch] commit" \
  || fail "S1-f: the tip is not a [dispatch] projection"
# The settled home is exactly current, so the next claim's fast-forward pull
# no longer trips on the redundant diff.
if git -C "$HOME_WT" pull -q --ff-only origin staging 2>/dev/null; then
  pass "S1-g: a later claim-style fast-forward pull succeeds on the settled home"
else
  fail "S1-g: the settled home still blocks a fast-forward pull"
fi

echo ""
echo "=== S2: two successive projections settle to the tip ==="
new_fixture s2
project_dispatch STORY-1 phase_status planned || fail "S2: fixture"
project_dispatch STORY-1 phase_status implemented || fail "S2: fixture"
TIP="$(target_tip)"
OUT="$(run_check)"
[[ "$OUT" == "ok|$TIP|" && "$(home_head)" == "$TIP" ]] && home_clean \
  && pass "S2: two [dispatch] writes are settled in one step" \
  || fail "S2: two own projections were not settled: $OUT"

echo ""
echo "=== S3: any other modified file still halts ==="
new_fixture s3
project_dispatch STORY-1 phase_status planned || fail "S3: fixture"
echo '# operator' >> "$HOME_WT/tool/framework.sh"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"; F="$(digest_of "$HOME_WT/tool/framework.sh")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:home_role=worktree_dirty*other_path_modified ]] \
  && pass "S3-a: foreign dirt beside the projection refuses with its cause" \
  || fail "S3-a: foreign dirt was not refused as expected: $OUT"
assert_untouched S3-b "$H" "$D" tool/framework.sh "$F"

echo ""
echo "=== S4: a backlog that differs from the target still halts ==="
new_fixture s4
project_dispatch STORY-1 phase_status planned || fail "S4: fixture"
echo '# hand edit' >> "$HOME_WT/$BACKLOG_REL"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:*backlog_differs_from_target ]] \
  && pass "S4-a: a non-identical backlog refuses" \
  || fail "S4-a: a non-identical backlog was not refused: $OUT"
assert_untouched S4-b "$H" "$D"

echo ""
echo "=== S5: an [operator] write in the advance still halts and is named ==="
new_fixture s5
foreign_commit 'chore(backlog): reset a row [operator]' "$BACKLOG_REL" '# operator row'
project_dispatch STORY-1 phase_status planned || fail "S5: fixture"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:*advance_not_own_projection*'[operator]'* ]] \
  && pass "S5-a: a human write in the advance refuses and is named" \
  || fail "S5-a: a human write was accepted or not named: $OUT"
assert_untouched S5-b "$H" "$D"

echo ""
echo "=== S6: a [dispatch]-stamped write outside the backlog still halts ==="
new_fixture s6
foreign_commit 'chore(framework): project lifecycle journal [dispatch]' tool/framework.sh '# code'
project_dispatch STORY-1 phase_status planned || fail "S6: fixture"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:*target_changed_other_paths ]] \
  && pass "S6-a: a stamped subject does not authorise a non-backlog change" \
  || fail "S6-a: a non-backlog change was accepted: $OUT"
assert_untouched S6-b "$H" "$D"

echo ""
echo "=== S7: an untracked file beside the projection still halts ==="
new_fixture s7
project_dispatch STORY-1 phase_status planned || fail "S7: fixture"
echo stray > "$HOME_WT/stray.txt"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:*untracked_present ]] \
  && pass "S7-a: untracked dirt refuses" || fail "S7-a: untracked dirt was not refused: $OUT"
assert_untouched S7-b "$H" "$D"

echo ""
echo "=== S8: staged dirt is never settled ==="
new_fixture s8
project_dispatch STORY-1 phase_status planned || fail "S8: fixture"
git -C "$HOME_WT" add -- "$BACKLOG_REL"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:home_role=index_dirty* ]] \
  && pass "S8-a: index dirt refuses" || fail "S8-a: index dirt was not refused: $OUT"
assert_untouched S8-b "$H" "$D"

echo ""
echo "=== S9: a home whose HEAD is not the bound target still halts ==="
new_fixture s9
# Bind to a real commit that is not HEAD: the projection advances the target,
# and the bound commit is its tip while the home's HEAD stays behind.
project_dispatch STORY-2 phase_status planned || fail "S9: fixture"
CHECK_BOUND="$(target_tip)"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(CHECK_BOUND="$CHECK_BOUND" run_check)"
[[ "$OUT" == refused:home_dirty:*head_not_bound ]] \
  && pass "S9-a: a HEAD other than the bound target refuses" \
  || fail "S9-a: an unbound HEAD was settled: $OUT"
assert_untouched S9-b "$H" "$D"
unset CHECK_BOUND

echo ""
echo "=== S10: a tree that lags the target tip still halts ==="
new_fixture s10
project_dispatch STORY-1 phase_status planned || fail "S10: fixture"
SAVED="$ROOT/s10.saved"; cp "$HOME_WT/$BACKLOG_REL" "$SAVED"
project_dispatch STORY-2 phase_status planned || fail "S10: fixture"
cp "$SAVED" "$HOME_WT/$BACKLOG_REL"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(run_check)"
[[ "$OUT" == refused:home_dirty:*backlog_differs_from_target ]] \
  && pass "S10-a: a tree that is not the tip's refuses" \
  || fail "S10-a: a lagging tree was settled: $OUT"
assert_untouched S10-b "$H" "$D"

echo ""
echo "=== S11: the settle holds the shared staging lock ==="
new_fixture s11
project_dispatch STORY-1 phase_status planned || fail "S11: fixture"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
READY="$ROOT/s11.held"; rm -f "$READY"
( _lifecycle_with_staging_lock /bin/bash -c 'touch "$1"; sleep 6' _ "$READY" ) &
HOLDER=$!
for _ in $(seq 1 50); do [[ -e "$READY" ]] && break; sleep 0.1; done
OUT="$(GAAI_STAGING_LOCK_TIMEOUT_SEC=2 run_check)"
[[ "$OUT" == refused:home_dirty:*staging_lock_unavailable ]] \
  && pass "S11-a: a held staging lock defers the settle" \
  || fail "S11-a: the settle did not wait for the staging lock: $OUT"
assert_untouched S11-b "$H" "$D"
wait "$HOLDER" 2>/dev/null
TIP="$(target_tip)"
OUT="$(run_check)"
[[ "$OUT" == "ok|$TIP|" ]] && pass "S11-c: once released, the next cycle settles" \
  || fail "S11-c: the settle did not recover after the lock was released: $OUT"

echo ""
echo "=== S12: without the staging lock primitive the settle refuses ==="
new_fixture s12
project_dispatch STORY-1 phase_status planned || fail "S12: fixture"
H="$(home_head)"; D="$(digest_of "$HOME_WT/$BACKLOG_REL")"
OUT="$(CHECK_NO_LOCK=1 run_check)"
[[ "$OUT" == refused:home_dirty:*staging_lock_unavailable ]] \
  && pass "S12-a: no lock, no settle" || fail "S12-a: settled without the lock: $OUT"
assert_untouched S12-b "$H" "$D"

echo ""
echo "=== S13: a clean home passes with no ref movement ==="
new_fixture s13
H="$(home_head)"
OUT="$(run_check)"
[[ "$OUT" == "ok|$BOUND|" && "$(home_head)" == "$H" ]] \
  && pass "S13: a clean exact-current home passes unchanged" \
  || fail "S13: a clean home was not accepted unchanged: $OUT"

echo ""
echo "=== S14: a refusal names the settle's cause once ==="
new_fixture s14
project_dispatch STORY-1 phase_status planned || fail "S14: fixture"
echo '# operator' >> "$HOME_WT/tool/framework.sh"
: > "$LOGF"
run_check >/dev/null
if grep -q 'reason=home_dirty' "$LOGF" \
    && grep -q 'not provably this daemon.*other_path_modified' "$LOGF"; then
  pass "S14: the refusal and the settle's cause are both logged"
else
  fail "S14: the refusal log does not name the cause: $(tr '\n' ' ' < "$LOGF")"
fi

echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
exit 0
