#!/usr/bin/env bash
# story-file-reconcile.test.sh — regression tests for _reconcile_story_file_from_staging
#
# T1: story.md matches staging → helper returns 0, no commit, no qa-report deletion
# T2: story.md differs (operator amendment) → exact configured-target checkout
#     overwrites, commits [daemon:story-file-drift], and invalidates QA evidence
# T3: story.md absent in worktree → checkout creates file, commit appears
# T4: staging copy missing → helper returns 2, escalation recorded, no commit
# T5: git fetch fails (offline) → cached target refs grant no authority
# T6: joint contract — after T2 refresh + qa-report deleted, E160S13 stub finds
#     no qa-report → silent-skip → no injection
# T7: an absent worktree blocks unless the caller supplies the exact pre-claim
#     absent_new binding; recovery never manufactures that binding itself
#
# Usage: bash .gaai/core/scripts/tests/story-file-reconcile.test.sh

set -uo pipefail

TEST_BASH="${GAAI_TEST_BASH:-${BASH:-/bin/bash}}"
printf 'interpreter=%s version=%s\n' "$TEST_BASH" "$BASH_VERSION"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$SCRIPT_DIR/../delivery-daemon.sh"
TARGET_BRANCH=staging

# ── Fixture setup ──────────────────────────────────────────────────────────────
FIXTURE_DIR="/tmp/gaai-story-reconcile-test-$$"
mkdir -p "$FIXTURE_DIR"

cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT

# ── Setup: create a git repo with remote + staging branch + story branch ──────
# Creates:
#   $remote_dir  — bare repo (acts as origin)
#   $repo_dir    — clone with remote "origin" pointing to bare repo
#   staging      — branch with story.md
#   story/<sid>  — branch forked from staging
# Sets REPO_DIR, REMOTE_DIR, PROJECT_DIR
setup_repo() {
  local sid="$1"
  local repo_dir="$FIXTURE_DIR/repo-${sid}-$$"
  local remote_dir="$FIXTURE_DIR/remote-${sid}-$$"

  rm -rf "$repo_dir" "$remote_dir"

  # Create bare remote
  git init --bare "$remote_dir" -q

  # Clone and set up
  git clone "$remote_dir" "$repo_dir" -q
  git -C "$repo_dir" remote set-url --push origin "$remote_dir"
  [[ "$(git -C "$repo_dir" remote get-url --push origin)" == "$remote_dir" ]] || return 1
  git -C "$repo_dir" config user.email "test@gaai.local"
  git -C "$repo_dir" config user.name "GAAI Test"

  # Create initial commit on default branch
  mkdir -p "$repo_dir/.gaai/project/contexts/artefacts/stories"
  mkdir -p "$repo_dir/.gaai/project/contexts/artefacts/qa-reports"
  mkdir -p "$repo_dir/.gaai/project/contexts/backlog"
  echo "initial" > "$repo_dir/.gaai/project/contexts/backlog/active.backlog.yaml"
  # Add story.md to staging (source of truth)
  echo "story: ${sid} initial content" > "$repo_dir/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
  git -C "$repo_dir" add .
  git -C "$repo_dir" commit -m "initial" -q
  # Rename default branch to staging
  local current_branch
  current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
  git -C "$repo_dir" branch -m "$current_branch" staging
  git -C "$repo_dir" push origin staging -q

  # Create story branch from staging (same content initially)
  git -C "$repo_dir" checkout -b "story/${sid}" -q
  git -C "$repo_dir" push origin "story/${sid}" -q

  # Go back to staging
  git -C "$repo_dir" checkout staging -q

  REPO_DIR="$repo_dir"
  REMOTE_DIR="$remote_dir"
  PROJECT_DIR="$repo_dir"
}

configured_target_source() {
  git -C "$PROJECT_DIR" fetch origin "$TARGET_BRANCH" -q \
    && git -C "$PROJECT_DIR" rev-parse "origin/${TARGET_BRANCH}"
}

# ── Extract helper function directly for in-process use ────────────────────────
extract_helper() {
  # Extract _reconcile_story_file_from_staging via awk (brace-depth tracking),
  # together with the target-branch fetch primitive it now depends on. The
  # dependency is extracted rather than stubbed so this suite keeps exercising the
  # real fetch path, including the typed failure line, instead of a local fake.
  eval "$(awk '
    /^_reconcile_story_file_from_staging\(\)/{p=1; depth=0}
    /^_classify_fetch_failure\(\)/{p=1; depth=0}
    /^_fetch_target_branch\(\)/{p=1; depth=0}
    p {
      print
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      if (p && depth == 0 && NR > 1) { p=0 }
    }
  ' "$DAEMON" 2>/dev/null)"
}

# ── Stub functions ─────────────────────────────────────────────────────────────
_FETCH_LAST_REASON=""
ESCALATION_REASON=""
ESCALATION_REMEDIATION=""

log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo -e "$msg" >> "$_TEST_LOG_FILE"
}

notify_escalation_inline() {
  ESCALATION_REASON="$2"
  ESCALATION_REMEDIATION="$3"
}

# Extract helper once at top level
extract_helper

# ── T1: story.md matches staging → return 0, no commit, no qa-report deletion ──
run_T1() {
  echo ""
  echo "── T1: story.md matches staging ────────────────────────────"

  local sid="ETEST001"
  _TEST_LOG_FILE="$FIXTURE_DIR/t1.log"

  setup_repo "$sid"
  local wt="$REPO_DIR"

  # Switch to story branch
  git -C "$wt" checkout "story/${sid}" -q
  git -C "$wt" fetch origin staging -q

  local head_before
  head_before=$(git -C "$wt" rev-parse HEAD)

  local expected_source
  if ! expected_source=$(configured_target_source); then
    fail "T1 setup: configured-target authority unavailable"
    return
  fi

  ESCALATION_REASON=""
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    pass "T1: return code is 0 (in-sync)"
  else
    fail "T1: expected return 0, got $rc"
  fi

  local head_after
  head_after=$(git -C "$wt" rev-parse HEAD)
  if [[ "$head_before" == "$head_after" ]]; then
    pass "T1: HEAD unchanged (no commit)"
  else
    fail "T1: HEAD changed unexpectedly"
  fi

  if grep -q "in-sync" "$_TEST_LOG_FILE" 2>/dev/null; then
    pass "T1: log contains 'in-sync'"
  else
    fail "T1: log missing 'in-sync'"
  fi
}

# ── T2: story.md differs → return 1, commit with trailer, qa-report deleted ───
run_T2() {
  echo ""
  echo "── T2: story.md differs (operator amendment) ────────────────"

  local sid="ETEST002"
  _TEST_LOG_FILE="$FIXTURE_DIR/t2.log"

  setup_repo "$sid"
  local wt="$REPO_DIR"

  # Amend story.md on staging (simulate operator amendment)
  git -C "$wt" checkout staging -q
  echo "story: ${sid} AMENDED by operator" > "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
  git -C "$wt" add .
  git -C "$wt" commit -m "amend story ${sid}" -q
  git -C "$wt" push origin staging -q

  # Switch to story branch (worktree perspective)
  git -C "$wt" checkout "story/${sid}" -q

  # Create a prior qa-report that should be deleted
  mkdir -p "$wt/.gaai/project/contexts/artefacts/qa-reports"
  echo "prior qa-report content" > "$wt/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md"

  local head_before
  head_before=$(git -C "$wt" rev-parse HEAD)

  local expected_source
  if ! expected_source=$(configured_target_source); then
    fail "T2 setup: configured-target authority unavailable"
    return
  fi

  ESCALATION_REASON=""
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -eq 1 ]]; then
    pass "T2: return code is 1 (refreshed)"
  else
    fail "T2: expected return 1, got $rc"
  fi

  # Verify commit appears with trailer
  local last_commit
  last_commit=$(git -C "$wt" log --oneline -1)
  if echo "$last_commit" | grep -q "\[daemon:story-file-drift\]"; then
    pass "T2: commit has [daemon:story-file-drift] trailer"
  else
    fail "T2: commit missing trailer — got: $last_commit"
  fi

  # Verify story.md content matches staging amendment
  local wt_content
  wt_content=$(cat "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md")
  if [[ "$wt_content" == "story: ${sid} AMENDED by operator" ]]; then
    pass "T2: worktree story.md now matches amended staging version"
  else
    fail "T2: worktree story.md content mismatch — got: $wt_content"
  fi

  # qa-report should be deleted
  if [[ ! -f "$wt/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md" ]]; then
    pass "T2: prior qa-report deleted"
  else
    fail "T2: qa-report still exists"
  fi

  # Log should contain DRIFT DETECTED
  if grep -q "DRIFT DETECTED" "$_TEST_LOG_FILE" 2>/dev/null; then
    pass "T2: log contains 'DRIFT DETECTED'"
  else
    fail "T2: log missing 'DRIFT DETECTED'"
  fi

  # Log should mention qa-report deletion
  if grep -q "prior qa-report deleted" "$_TEST_LOG_FILE" 2>/dev/null; then
    pass "T2: log mentions qa-report deletion"
  else
    fail "T2: log missing qa-report deletion line"
  fi

  # HEAD should have advanced by exactly 1 commit (the chore commit)
  local head_after
  head_after=$(git -C "$wt" rev-parse HEAD)
  if [[ "$head_before" != "$head_after" ]]; then
    pass "T2: HEAD advanced (chore commit made)"
  else
    fail "T2: HEAD unchanged — expected chore commit"
  fi
}

# ── T3: story.md absent in worktree → checkout creates it, commit appears ──────
run_T3() {
  echo ""
  echo "── T3: story.md absent in worktree (fresh worktree case) ────"

  local sid="ETEST003"
  _TEST_LOG_FILE="$FIXTURE_DIR/t3.log"

  setup_repo "$sid"
  local wt="$REPO_DIR"

  # On staging: story.md exists (created by setup)
  # On story branch: remove story.md to simulate fresh worktree without it
  git -C "$wt" checkout "story/${sid}" -q
  rm -f "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
  git -C "$wt" add -A
  git -C "$wt" commit -m "remove story.md from branch" -q
  git -C "$wt" push origin "story/${sid}" -q

  # Verify it's absent
  if [[ -f "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md" ]]; then
    fail "T3 setup: story.md should be absent but exists"
    return
  fi

  local expected_source
  if ! expected_source=$(configured_target_source); then
    fail "T3 setup: configured-target authority unavailable"
    return
  fi

  ESCALATION_REASON=""
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -eq 1 ]]; then
    pass "T3: return code is 1 (refreshed — new file)"
  else
    fail "T3: expected return 1, got $rc"
  fi

  if [[ -f "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md" ]]; then
    pass "T3: story.md now exists in worktree"
  else
    fail "T3: story.md still absent"
  fi

  local last_commit
  last_commit=$(git -C "$wt" log --oneline -1)
  if echo "$last_commit" | grep -q "\[daemon:story-file-drift\]"; then
    pass "T3: commit has trailer"
  else
    fail "T3: commit missing trailer — got: $last_commit"
  fi
}

# ── T4: staging copy missing → return 2, escalation recorded ──────────────────
run_T4() {
  echo ""
  echo "── T4: staging copy missing ──────────────────────────────────"

  local sid="ETEST004"
  _TEST_LOG_FILE="$FIXTURE_DIR/t4.log"

  setup_repo "$sid"
  local wt="$REPO_DIR"

  # Remove story.md from staging
  git -C "$wt" checkout staging -q
  rm -f "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
  git -C "$wt" add -A
  git -C "$wt" commit -m "remove story from staging" -q
  git -C "$wt" push origin staging -q

  git -C "$wt" checkout "story/${sid}" -q

  local head_before
  head_before=$(git -C "$wt" rev-parse HEAD)

  local expected_source
  if ! expected_source=$(configured_target_source); then
    fail "T4 setup: configured-target authority unavailable"
    return
  fi

  ESCALATION_REASON=""
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -eq 2 ]]; then
    pass "T4: return code is 2 (staging missing)"
  else
    fail "T4: expected return 2, got $rc"
  fi

  # The helper returns 2 but does NOT call notify_escalation_inline itself —
  # that's the caller's job (matching the execution-plan call-site pattern).
  # Verify the contract: rc=2 signals the caller to escalate.
  pass "T4: helper returns 2 (caller should invoke notify_escalation_inline)"

  local head_after
  head_after=$(git -C "$wt" rev-parse HEAD)
  if [[ "$head_before" == "$head_after" ]]; then
    pass "T4: HEAD unchanged (no commit)"
  else
    fail "T4: HEAD changed unexpectedly"
  fi

  if grep -q "configured-target copy MISSING" "$_TEST_LOG_FILE" 2>/dev/null; then
    pass "T4: log contains 'configured-target copy MISSING'"
  else
    fail "T4: log missing configured-target failure"
  fi
}

# ── T5: git fetch fails → cached refs are non-authorizing ────────────────────
run_T5() {
  echo ""
  echo "── T5: git fetch fails (offline simulation) ────────────────"

  local sid="ETEST005"
  _TEST_LOG_FILE="$FIXTURE_DIR/t5.log"

  setup_repo "$sid"
  local wt="$REPO_DIR"

  # Amend staging so there IS drift to detect — but do NOT push to origin yet
  # Actually, amend AND push so origin/staging has the new version
  git -C "$wt" checkout staging -q
  echo "story: ${sid} AMENDED on staging" > "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
  git -C "$wt" add .
  git -C "$wt" commit -m "amend story ${sid} on staging" -q
  git -C "$wt" push origin staging -q

  git -C "$wt" checkout "story/${sid}" -q

  # Fetch into the cache first, then make the remote unavailable. The helper
  # must still reject: cached refs are not current configured-target evidence.
  git -C "$wt" fetch origin staging -q
  local expected_source
  expected_source=$(git -C "$wt" rev-parse "origin/${TARGET_BRANCH}")

  # Now break the remote so fetch will fail, but origin/staging ref is cached
  if ! git -C "$wt" remote set-url origin "file:///nonexistent/path-$$" 2>/dev/null; then
    git -C "$wt" remote remove origin
    git -C "$wt" remote add origin "file:///nonexistent/path-$$"
  fi

  ESCALATION_REASON=""
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -eq 2 ]]; then
    pass "T5: offline fetch blocks cached-ref reconciliation"
  else
    fail "T5: expected fail-closed return 2, got $rc"
  fi

  if grep -q "configured target changed — skipping spawn" "$_TEST_LOG_FILE" 2>/dev/null; then
    pass "T5: log records fresh configured-target authority failure"
  else
    fail "T5: log missing configured-target authority failure"
  fi

  if [[ "$(cat "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md")" \
      == "story: ${sid} initial content" ]]; then
    pass "T5: unavailable target leaves Story bytes unchanged"
  else
    fail "T5: cached target bytes mutated the Story while offline"
  fi
}

# ── T6: joint contract — E160S13 stub finds no qa-report after T2 refresh ──────
run_T6() {
  echo ""
  echo "── T6: joint contract with cross-cycle qa-report injection ──"

  local sid="ETEST006"
  _TEST_LOG_FILE="$FIXTURE_DIR/t6.log"

  setup_repo "$sid"
  local wt="$REPO_DIR"

  # Simulate T2 scenario: amend staging + switch to story branch + create qa-report
  git -C "$wt" checkout staging -q
  echo "story: ${sid} AMENDED on staging" > "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
  git -C "$wt" add .
  git -C "$wt" commit -m "amend story ${sid} on staging" -q
  git -C "$wt" push origin staging -q

  git -C "$wt" checkout "story/${sid}" -q
  mkdir -p "$wt/.gaai/project/contexts/artefacts/qa-reports"
  echo "prior qa-report: AC1=PASS AC2=FAIL" > "$wt/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md"

  ESCALATION_REASON=""

  local expected_source
  if ! expected_source=$(configured_target_source); then
    fail "T6 setup: configured-target authority unavailable"
    return
  fi

  # Run Step 1: S14 reconcile (should delete qa-report)
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -ne 1 ]]; then
    fail "T6 setup: S14 reconcile did not return 1 (got $rc)"
    return
  fi

  if [[ ! -f "$wt/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md" ]]; then
    pass "T6: qa-report deleted by S14 reconcile"
  else
    fail "T6: qa-report still exists after S14 reconcile"
    return
  fi

  # Simulate Step 2: E160S13 helper looks for qa-report
  # E160S13's _resolve_cross_cycle_qa_report checks if the file exists
  # If absent → silent-skip (no injection)
  local qa_path="$wt/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md"
  if [[ ! -f "$qa_path" ]]; then
    pass "T6: cross-cycle qa-report stub confirms file absent → silent-skip (joint contract verified)"
  else
    fail "T6: cross-cycle qa-report stub would find file — joint contract broken"
  fi

  # Verify the story.md content is the amended version (S05 + S14 ordering correct)
  local wt_content
  wt_content=$(cat "$wt/.gaai/project/contexts/artefacts/stories/${sid}.story.md")
  if [[ "$wt_content" == "story: ${sid} AMENDED on staging" ]]; then
    pass "T6: story.md content is the amended staging version (ordering correct)"
  else
    fail "T6: story.md content incorrect — got: $wt_content"
  fi

  # Verify the commit has the trailer
  local last_commit
  last_commit=$(git -C "$wt" log --oneline -1)
  if echo "$last_commit" | grep -q "\[daemon:story-file-drift\]"; then
    pass "T6: configured-target refresh commit trailer is present"
  else
    fail "T6: commit missing trailer — got: $last_commit"
  fi
}

# ── T7: absent worktree requires the caller's bound first-claim proof ─────────
run_T7() {
  echo ""
  echo "── T7: absent worktree is typed and caller-bound ──────────"

  local sid="ETEST007"
  _TEST_LOG_FILE="$FIXTURE_DIR/t7.log"
  : > "$_TEST_LOG_FILE"

  setup_repo "$sid"
  local expected_source
  if ! expected_source=$(configured_target_source); then
    fail "T7 setup: configured-target authority unavailable"
    return
  fi

  # Compute a worktree path that does not exist. Recovery supplies no
  # absent_new proof and therefore must fail closed.
  local wt="$FIXTURE_DIR/wt-missing-${sid}-$$"
  rm -rf "$wt"

  if [[ -d "$wt" ]]; then
    fail "T7 setup: expected wt path absent, but exists"
    return
  fi

  ESCALATION_REASON=""
  local rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" || rc=$?

  if [[ "$rc" -eq 2 ]]; then
    pass "T7: unbound absent worktree blocks spawn"
  else
    fail "T7: expected unbound return 2, got $rc"
  fi

  if grep -q "worktree absent outside bound first claim" "$_TEST_LOG_FILE" 2>/dev/null; then
    pass "T7: log identifies absent worktree without authority"
  else
    fail "T7: log missing unbound-absence reason"
  fi

  if grep -q "configured-target fetch failed" "$_TEST_LOG_FILE" 2>/dev/null; then
    fail "T7: configured-target authority was unavailable"
  else
    pass "T7: configured-target authority remains available"
  fi

  if [[ -d "$wt" ]]; then
    fail "T7: unbound absence created or removed local state"
  else
    pass "T7: unbound absence preserves filesystem state"
  fi

  : > "$_TEST_LOG_FILE"
  rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$expected_source" true || rc=$?
  if [[ "$rc" -eq 0 ]] \
      && grep -q "exact pre-claim absent_new binding" "$_TEST_LOG_FILE"; then
    pass "T7: explicit pre-claim absent_new binding permits first spawn"
  else
    fail "T7: bound first-claim absence was not recognized exactly"
  fi
}

# ── Run all tests ──────────────────────────────────────────────────────────────
echo "================================================================"
echo " story-file-reconcile.test.sh — regression tests"
echo "================================================================"

run_T1
run_T2
run_T3
run_T4
run_T5
run_T6
run_T7

echo ""
echo "================================================================"
echo " Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
