#!/usr/bin/env bash
# pr-watcher.test.sh — regression tests for the PR merge watcher
#
# Covers: watch_pr_merge_status(), _reconcile_merged_pr(), sweep_cleanup_pending()
# All 8 acceptance-criteria tests (T1–T8).
#
# Usage: bash .gaai/core/scripts/tests/pr-watcher.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }
skip() { echo "  SKIP: $1"; SKIP_COUNT=$(( SKIP_COUNT + 1 )); }
portable_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$SCRIPT_DIR/../delivery-daemon.sh"
SCHEDULER="$SCRIPT_DIR/../backlog-scheduler.sh"
BACKLOG_LIB="$SCRIPT_DIR/../lib/backlog-yaml.sh"

FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gaai-pr-watcher-test.XXXXXX") || {
  echo "  FAIL: unable to create private temporary fixture root" >&2
  exit 1
}
chmod 700 "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR/lib"
cp "$BACKLOG_LIB" "$FIXTURE_DIR/lib/backlog-yaml.sh"

FIXTURE_MODE=$(portable_mode "$FIXTURE_DIR" 2>/dev/null || true)
if [[ "$FIXTURE_MODE" == "700" ]]; then
  pass "FIXTURE: mktemp root is private"
else
  fail "FIXTURE: mktemp root is not mode 0700"
fi

cleanup() {
  [[ "${GAAI_KEEP_TEST_FIXTURES:-0}" == "1" ]] || rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# ── Git repo helper ────────────────────────────────────────────────────────────
# Creates a bare remote + local clone with content committed to the `staging` branch.
setup_git_repo() {
  local project_dir="$1" content="$2"
  local remote_dir="${project_dir}_remote.git"
  rm -rf "$project_dir" "$remote_dir"
  git init --bare "$remote_dir" -q
  git clone "$remote_dir" "$project_dir" -q
  git -C "$project_dir" config user.email "test@gaai.local"
  git -C "$project_dir" config user.name "GAAI Test"
  # Use `staging` branch (matches TARGET_BRANCH in harnesses)
  git -C "$project_dir" checkout -b staging -q 2>/dev/null || git -C "$project_dir" checkout staging -q
  local backlog_dir="$project_dir/.gaai/project/contexts/backlog"
  mkdir -p "$backlog_dir"
  # Callers pass a bare story sequence. The real backlog nests it under a
  # top-level "items:" key, and story selection now runs through
  # backlog_in_progress_ids, whose yq query is ".items[] | select(...)". A bare
  # sequence matched the daemon's pre-yq grep/sed reads but returns nothing from
  # that query, so every watcher fixture selected zero stories and the code under
  # test no-opped. Wrap here so all fixtures are schema-valid at one site.
  printf 'items:\n%s\n' "$content" > "$backlog_dir/active.backlog.yaml"
  git -C "$project_dir" add .
  git -C "$project_dir" commit -m "initial" -q
  git -C "$project_dir" push -u origin staging -q
}

# ── Mock gh helper ─────────────────────────────────────────────────────────────
# Creates a mock `gh` binary that reads MOCK_GH_RESPONSE and MOCK_GH_EXIT from env.
create_mock_gh() {
  local mock_dir="$1"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "${MOCK_GH_RESPONSE:-{}}"
exit "${MOCK_GH_EXIT:-0}"
MOCK_EOF
  chmod +x "$mock_dir/gh"
}

# ── Harness builder ────────────────────────────────────────────────────────────
# Builds a minimal test harness that sources the three new watcher functions
# from delivery-daemon.sh via awk extraction.
build_harness() {
  local harness_file="$1"
  local project_dir="$2"
  local lock_dir="$3"
  local daemon_log="$4"
  local mock_gh_dir="$5"
  local extra_env="${6:-}"

  local backlog_rel=".gaai/project/contexts/backlog/active.backlog.yaml"

  cat > "$harness_file" <<HARNESS
#!/usr/bin/env bash
set -uo pipefail
# Mock gh must be first in PATH so auth checks pass
export PATH="$mock_gh_dir:\$PATH"

PROJECT_DIR="$project_dir"
GAAI_PROJECT_DIR="$project_dir/.gaai/project"
BACKLOG_REL="$backlog_rel"
BACKLOG="\$PROJECT_DIR/\$BACKLOG_REL"
BACKLOG_FILE="\$BACKLOG"
LOCK_DIR="$lock_dir"
LOG_DIR="$lock_dir/logs"
DRIFT_MARKER="$lock_dir/.drift-detected.audit"
LOG_FILE="$daemon_log"
STAGING_LOCK="\$LOCK_DIR/.staging.lock"
RETRY_FILE="\$LOCK_DIR/.retry-counts"
RESOLUTION_TRACKING="\$LOCK_DIR/.resolution-tracking"
SCHEDULER="$SCHEDULER"
TARGET_BRANCH="staging"
DRY_RUN=false
STALENESS_THRESHOLD=14400
POLL_INTERVAL=30
MAX_CONCURRENT=3
EXIT_WHEN_IDLE_THRESHOLD=0
MAX_RETRIES=3
DELIVERY_TIMEOUT=14400
MAX_TURNS=200
CLAUDE_MODEL=sonnet
HEARTBEAT_STALE=1800
SKIP_PERMISSIONS=true
STATUS_MODE=false
NOTIFICATION_WEBHOOK=""
WEBHOOK_SECRET=""
PLATFORM="\$(uname)"
LAUNCHER="tmux"
CLAUDE_FLAGS="--model sonnet --max-turns 200"
CAFFEINATE_PID=""

$extra_env

mkdir -p "\$LOG_DIR" "\$LOCK_DIR"

# Color stubs (no terminal in test harness)
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''

log() {
  local msg="[\$(date '+%H:%M:%S')] \$*"
  echo -e "\$msg" | sed 's/\o033\[[0-9;]*m//g' >> "\$LOG_FILE"
}

with_staging_lock() { "\$@"; }
file_mtime() { stat -f %m "\$1" 2>/dev/null || stat -c %Y "\$1" 2>/dev/null || echo 0; }

# watch_pr_merge_status selects its candidate stories through
# backlog_in_progress_ids, which lives in lib/backlog-yaml.sh since the yq
# migration. Without this source the call resolved to nothing, its trailing
# "|| true" swallowed the error, the candidate list came back empty, and the
# watcher returned before reconciling anything — leaving T2 to report the story
# as still in_progress against a code path that had silently no-opped.
#
# NOTE: this heredoc is unquoted, so backticks here would be command-substituted
# at generation time. Keep this comment backtick-free.
# shellcheck source=../lib/backlog-yaml.sh
source "$SCRIPT_DIR/../lib/backlog-yaml.sh"
# The lib declares "set -euo pipefail", and source is not scope-limited, so it
# would impose -e on this harness. The daemon functions under test rely on
# non-zero commands staying non-fatal, so restore the harness's own options.
set +e

# Extract the watcher functions + current-cycle gate dependencies from delivery-daemon.sh
eval "\$(awk '
  /^sweep_cleanup_pending\(\)/{p=1; depth=0}
  /^watch_pr_merge_status\(\)/{p=1; depth=0}
  /^_merged_pr_started_at\(\)/{p=1; depth=0}
  /^_merged_pr_is_current_cycle\(\)/{p=1; depth=0}
  /^_reconcile_merged_pr\(\)/{p=1; depth=0}
  p {
    print
    for (i=1; i<=length(\$0); i++) {
      c = substr(\$0, i, 1)
      if (c == "{") depth++
      if (c == "}") depth--
    }
    if (p && depth == 0 && NR > 1) { p=0 }
  }
' "$DAEMON" 2>/dev/null)"
HARNESS
}

# ═══════════════════════════════════════════════════════════════════════════════
# T1: pr_url set + gh returns mergedAt:null → story stays in_progress
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T1: no reconcile when mergedAt is null ==="

T1_DIR="$FIXTURE_DIR/t1-project"
T1_LOCK="$FIXTURE_DIR/t1-locks"
T1_LOG="$FIXTURE_DIR/t1.log"
T1_MOCK_GH="$FIXTURE_DIR/t1-mock-gh"
mkdir -p "$T1_LOCK"
touch "$T1_LOG"

T1_SID="T1-STORY-01"
T1_YAML="- id: $T1_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/42
  delivery_pipeline: 3phase"

setup_git_repo "$T1_DIR" "$T1_YAML"
create_mock_gh "$T1_MOCK_GH"
export MOCK_GH_RESPONSE='{"mergedAt":null,"state":"OPEN","baseRefName":"staging"}'
export MOCK_GH_EXIT=0

T1_HARNESS=$(mktemp "$FIXTURE_DIR/t1-XXXXXX")
build_harness "$T1_HARNESS" "$T1_DIR" "$T1_LOCK" "$T1_LOG" "$T1_MOCK_GH"
printf 'watch_pr_merge_status\n' >> "$T1_HARNESS"
chmod +x "$T1_HARNESS"
bash "$T1_HARNESS" 2>/dev/null

T1_STATUS=$(git -C "$T1_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  | grep "status:" | head -1 | awk '{print $2}' || echo "")

if [[ "$T1_STATUS" == "in_progress" ]]; then
  pass "T1: story stayed in_progress when mergedAt is null"
else
  fail "T1: expected in_progress, got '$T1_STATUS'"
fi
rm -f "$T1_HARNESS"

# ═══════════════════════════════════════════════════════════════════════════════
# T2: gh returns mergedAt + state:MERGED + baseRefName:staging → reconcile to done
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T2: reconcile to done when mergedAt is non-null and targets staging ==="

T2_DIR="$FIXTURE_DIR/t2-project"
T2_LOCK="$FIXTURE_DIR/t2-locks"
T2_LOG="$FIXTURE_DIR/t2.log"
T2_MOCK_GH="$FIXTURE_DIR/t2-mock-gh"
mkdir -p "$T2_LOCK"
touch "$T2_LOG"

T2_SID="T2-STORY-02"
T2_YAML="- id: $T2_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/99
  delivery_pipeline: 3phase
  started_at: \"2026-05-11T08:00:00Z\""

setup_git_repo "$T2_DIR" "$T2_YAML"
create_mock_gh "$T2_MOCK_GH"
export MOCK_GH_RESPONSE='{"mergedAt":"2026-05-11T10:00:00Z","state":"MERGED","baseRefName":"staging","createdAt":"2026-05-11T09:00:00Z"}'
export MOCK_GH_EXIT=0

T2_HARNESS=$(mktemp "$FIXTURE_DIR/t2-XXXXXX")
build_harness "$T2_HARNESS" "$T2_DIR" "$T2_LOCK" "$T2_LOG" "$T2_MOCK_GH"
printf 'watch_pr_merge_status\n' >> "$T2_HARNESS"
chmod +x "$T2_HARNESS"
bash "$T2_HARNESS" 2>/dev/null

T2_BACKLOG=$(git -C "$T2_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  || cat "$T2_DIR/.gaai/project/contexts/backlog/active.backlog.yaml")
T2_STATUS=$(printf '%s\n' "$T2_BACKLOG" | grep "status:" | head -1 | awk '{print $2}' || echo "")
T2_PHASE=$(printf '%s\n' "$T2_BACKLOG" | grep "phase_status:" | head -1 | awk '{print $2}' || echo "")

if [[ "$T2_STATUS" == "done" ]]; then
  pass "T2: status reconciled to done"
else
  fail "T2: expected done, got '$T2_STATUS'"
fi

if [[ "$T2_PHASE" == "done" ]]; then
  pass "T2: phase_status reconciled to done"
else
  fail "T2: expected phase_status=done, got '$T2_PHASE'"
fi

if printf '%s\n' "$T2_BACKLOG" | grep -q "completed_at:"; then
  pass "T2: completed_at field set"
else
  fail "T2: completed_at field missing"
fi
rm -f "$T2_HARNESS"

# ═══════════════════════════════════════════════════════════════════════════════
# T3: gh returns state:CLOSED + mergedAt:null → .pr-abandoned.audit + flag, no double-emit
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: PR closed without merge — single emission, no double-emit (MEDIUM-F6) ==="

T3_DIR="$FIXTURE_DIR/t3-project"
T3_LOCK="$FIXTURE_DIR/t3-locks"
T3_LOG="$FIXTURE_DIR/t3.log"
T3_MOCK_GH="$FIXTURE_DIR/t3-mock-gh"
mkdir -p "$T3_LOCK"
touch "$T3_LOG"

T3_SID="T3-STORY-03"
T3_YAML="- id: $T3_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/55
  delivery_pipeline: 3phase"

setup_git_repo "$T3_DIR" "$T3_YAML"
create_mock_gh "$T3_MOCK_GH"
export MOCK_GH_RESPONSE='{"mergedAt":null,"state":"CLOSED","baseRefName":"staging"}'
export MOCK_GH_EXIT=0

T3_HARNESS=$(mktemp "$FIXTURE_DIR/t3-XXXXXX")
build_harness "$T3_HARNESS" "$T3_DIR" "$T3_LOCK" "$T3_LOG" "$T3_MOCK_GH"
printf 'watch_pr_merge_status\n' >> "$T3_HARNESS"
chmod +x "$T3_HARNESS"

# First poll
bash "$T3_HARNESS" 2>/dev/null

T3_AUDIT="$T3_LOCK/.pr-abandoned.audit"
T3_FLAG="$T3_LOCK/.pr-abandoned.emitted.${T3_SID}"

if [[ -f "$T3_AUDIT" ]]; then
  pass "T3: .pr-abandoned.audit created on first poll"
else
  fail "T3: .pr-abandoned.audit not created on first poll"
fi

if [[ -f "$T3_FLAG" ]]; then
  pass "T3: .pr-abandoned.emitted flag created on first poll"
else
  fail "T3: .pr-abandoned.emitted flag not created on first poll"
fi

# Count lines before second poll
T3_LINES_BEFORE=$(wc -l < "$T3_AUDIT" 2>/dev/null || echo 0)

# Reset rate-limit so second poll fires
rm -f "$T3_LOCK/.pr-watcher.last-poll" 2>/dev/null || true

# Second poll (flag present → should NOT re-emit)
bash "$T3_HARNESS" 2>/dev/null

T3_LINES_AFTER=$(wc -l < "$T3_AUDIT" 2>/dev/null || echo 0)

if [[ "$T3_LINES_AFTER" -eq "$T3_LINES_BEFORE" ]]; then
  pass "T3: no double-emission on second poll (MEDIUM-F6 fix verified)"
else
  fail "T3: audit file grew from $T3_LINES_BEFORE to $T3_LINES_AFTER lines on second poll"
fi
rm -f "$T3_HARNESS"

# ═══════════════════════════════════════════════════════════════════════════════
# T4: gh CLI exits non-zero (rate limit) → watcher returns gracefully, story untouched
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: gh API failure — graceful skip, story stays in_progress ==="

T4_DIR="$FIXTURE_DIR/t4-project"
T4_LOCK="$FIXTURE_DIR/t4-locks"
T4_LOG="$FIXTURE_DIR/t4.log"
T4_MOCK_GH="$FIXTURE_DIR/t4-mock-gh"
mkdir -p "$T4_LOCK"
touch "$T4_LOG"

T4_SID="T4-STORY-04"
T4_YAML="- id: $T4_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/77
  delivery_pipeline: 3phase"

setup_git_repo "$T4_DIR" "$T4_YAML"
create_mock_gh "$T4_MOCK_GH"
export MOCK_GH_RESPONSE='rate limit exceeded'
export MOCK_GH_EXIT=1

T4_HARNESS=$(mktemp "$FIXTURE_DIR/t4-XXXXXX")
build_harness "$T4_HARNESS" "$T4_DIR" "$T4_LOCK" "$T4_LOG" "$T4_MOCK_GH"
printf 'watch_pr_merge_status\necho "EXIT:$?"\n' >> "$T4_HARNESS"
chmod +x "$T4_HARNESS"

T4_OUTPUT=$(bash "$T4_HARNESS" 2>/dev/null || true)
T4_EXIT=$(printf '%s\n' "$T4_OUTPUT" | grep "^EXIT:" | sed 's/EXIT://' | head -1)
T4_STATUS=$(git -C "$T4_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  | grep "status:" | head -1 | awk '{print $2}' || echo "")

if [[ "$T4_EXIT" == "0" ]]; then
  pass "T4: watcher returned exit 0 on gh API failure"
else
  fail "T4: expected exit 0, got '$T4_EXIT'"
fi

if [[ "$T4_STATUS" == "in_progress" ]]; then
  pass "T4: story stays in_progress after gh failure"
else
  fail "T4: expected in_progress, got '$T4_STATUS'"
fi
rm -f "$T4_HARNESS"

# ═══════════════════════════════════════════════════════════════════════════════
# T5: GAAI_PR_WATCHER_DISABLED=1 → watcher is no-op, story untouched
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T5: GAAI_PR_WATCHER_DISABLED=1 — watcher no-op ==="

T5_DIR="$FIXTURE_DIR/t5-project"
T5_LOCK="$FIXTURE_DIR/t5-locks"
T5_LOG="$FIXTURE_DIR/t5.log"
T5_MOCK_GH="$FIXTURE_DIR/t5-mock-gh"
mkdir -p "$T5_LOCK"
touch "$T5_LOG"

T5_SID="T5-STORY-05"
T5_YAML="- id: $T5_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/88
  delivery_pipeline: 3phase"

setup_git_repo "$T5_DIR" "$T5_YAML"
create_mock_gh "$T5_MOCK_GH"
export MOCK_GH_RESPONSE='{"mergedAt":"2026-05-11T10:00:00Z","state":"MERGED","baseRefName":"staging","createdAt":"2026-05-11T09:00:00Z"}'
export MOCK_GH_EXIT=0

T5_HARNESS=$(mktemp "$FIXTURE_DIR/t5-XXXXXX")
build_harness "$T5_HARNESS" "$T5_DIR" "$T5_LOCK" "$T5_LOG" "$T5_MOCK_GH" "export GAAI_PR_WATCHER_DISABLED=1"
printf 'watch_pr_merge_status\n' >> "$T5_HARNESS"
chmod +x "$T5_HARNESS"
bash "$T5_HARNESS" 2>/dev/null

T5_STATUS=$(git -C "$T5_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  | grep "status:" | head -1 | awk '{print $2}' || echo "")

if [[ "$T5_STATUS" == "in_progress" ]]; then
  pass "T5: story untouched when GAAI_PR_WATCHER_DISABLED=1"
else
  fail "T5: expected in_progress (watcher disabled), got '$T5_STATUS'"
fi

# The disabled log message is emitted by the daemon startup code, not the function itself.
# The function just returns 0 immediately. Verify the function returns 0 cleanly:
T5_HARNESS2=$(mktemp "$FIXTURE_DIR/t5b-XXXXXX")
build_harness "$T5_HARNESS2" "$T5_DIR" "$T5_LOCK" "$T5_LOG" "$T5_MOCK_GH" "export GAAI_PR_WATCHER_DISABLED=1"
printf 'watch_pr_merge_status\necho "EXIT:$?"\n' >> "$T5_HARNESS2"
chmod +x "$T5_HARNESS2"
T5_OUTPUT=$(bash "$T5_HARNESS2" 2>/dev/null || true)
T5_EXIT=$(printf '%s\n' "$T5_OUTPUT" | grep "^EXIT:" | sed 's/EXIT://' | head -1)

if [[ "$T5_EXIT" == "0" ]]; then
  pass "T5: watch_pr_merge_status returns 0 when disabled"
else
  fail "T5: expected exit 0 when disabled, got '$T5_EXIT'"
fi
rm -f "$T5_HARNESS" "$T5_HARNESS2"

# ═══════════════════════════════════════════════════════════════════════════════
# T6 (HIGH-F1): malformed pr_url → parse failure logged, story untouched, no crash
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T6: malformed pr_url — parse failure, no crash, story stays in_progress (HIGH-F1) ==="

T6_DIR="$FIXTURE_DIR/t6-project"
T6_LOCK="$FIXTURE_DIR/t6-locks"
T6_LOG="$FIXTURE_DIR/t6.log"
T6_MOCK_GH="$FIXTURE_DIR/t6-mock-gh"
mkdir -p "$T6_LOCK"
touch "$T6_LOG"

T6_SID="T6-STORY-06"
T6_YAML="- id: $T6_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://example.com/no-pull-pattern
  delivery_pipeline: 3phase"

setup_git_repo "$T6_DIR" "$T6_YAML"
create_mock_gh "$T6_MOCK_GH"
export MOCK_GH_RESPONSE='{"mergedAt":"2026-05-11T10:00:00Z","state":"MERGED","baseRefName":"staging","createdAt":"2026-05-11T09:00:00Z"}'
export MOCK_GH_EXIT=0

T6_HARNESS=$(mktemp "$FIXTURE_DIR/t6-XXXXXX")
build_harness "$T6_HARNESS" "$T6_DIR" "$T6_LOCK" "$T6_LOG" "$T6_MOCK_GH"
printf 'watch_pr_merge_status\necho "EXIT:$?"\n' >> "$T6_HARNESS"
chmod +x "$T6_HARNESS"
T6_OUTPUT=$(bash "$T6_HARNESS" 2>/dev/null || true)
T6_EXIT=$(printf '%s\n' "$T6_OUTPUT" | grep "^EXIT:" | sed 's/EXIT://' | head -1)

T6_STATUS=$(git -C "$T6_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  | grep "status:" | head -1 | awk '{print $2}' || echo "")

if [[ "$T6_EXIT" == "0" ]]; then
  pass "T6: watcher returned exit 0 on malformed pr_url (no crash)"
else
  fail "T6: expected exit 0, got '$T6_EXIT'"
fi

if [[ "$T6_STATUS" == "in_progress" ]]; then
  pass "T6: story stays in_progress on malformed pr_url"
else
  fail "T6: expected in_progress, got '$T6_STATUS'"
fi

T6_LOG_CONTENT=$(cat "$T6_LOG" 2>/dev/null || echo "")
if printf '%s\n' "$T6_LOG_CONTENT" | grep -q "does not match canonical"; then
  pass "T6: parse-failure warning logged"
else
  fail "T6: expected 'does not match canonical' in log (got: $(cat "$T6_LOG" 2>/dev/null | tail -5))"
fi
rm -f "$T6_HARNESS"

# ═══════════════════════════════════════════════════════════════════════════════
# T7 (HIGH-F3): cleanup-pending.audit written on failure + sweep_cleanup_pending retries
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T7: cleanup failure → .cleanup-pending.audit + sweep_cleanup_pending retries (HIGH-F3) ==="

T7_DIR="$FIXTURE_DIR/t7-project"
T7_LOCK="$FIXTURE_DIR/t7-locks"
T7_LOG="$FIXTURE_DIR/t7.log"
T7_MOCK_GH="$FIXTURE_DIR/t7-mock-gh"
mkdir -p "$T7_LOCK"
touch "$T7_LOG"

T7_SID="T7-STORY-07"
T7_YAML="- id: $T7_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/707
  delivery_pipeline: 3phase
  started_at: \"2026-05-11T08:00:00Z\""

setup_git_repo "$T7_DIR" "$T7_YAML"
create_mock_gh "$T7_MOCK_GH"
export MOCK_GH_RESPONSE='{"mergedAt":"2026-05-11T10:00:00Z","state":"MERGED","baseRefName":"staging","createdAt":"2026-05-11T09:00:00Z"}'
export MOCK_GH_EXIT=0

# Create a non-worktree directory at the worktree path.
# git worktree remove --force will fail on a directory that isn't a registered worktree.
# This simulates a worktree that was partially cleaned or is inaccessible.
T7_WT_BASE="$FIXTURE_DIR/t7-worktrees"
T7_WORKTREE_PATH="$T7_WT_BASE/${T7_SID}-workspace"
mkdir -p "$T7_WORKTREE_PATH"

# Set GAAI_WORKTREES_BASE so _reconcile_merged_pr resolves the same path
T7_HARNESS=$(mktemp "$FIXTURE_DIR/t7-XXXXXX")
build_harness "$T7_HARNESS" "$T7_DIR" "$T7_LOCK" "$T7_LOG" "$T7_MOCK_GH" \
  "export GAAI_WORKTREES_BASE=\"$T7_WT_BASE\""
printf 'watch_pr_merge_status\n' >> "$T7_HARNESS"
chmod +x "$T7_HARNESS"
bash "$T7_HARNESS" 2>/dev/null

# Assertions after first run:
T7_BACKLOG=$(git -C "$T7_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  || cat "$T7_DIR/.gaai/project/contexts/backlog/active.backlog.yaml")
T7_STATUS=$(printf '%s\n' "$T7_BACKLOG" | grep "status:" | head -1 | awk '{print $2}' || echo "")
T7_MARKER="$T7_LOCK/.cleanup-pending.audit"

if [[ "$T7_STATUS" == "done" ]]; then
  pass "T7: backlog reconciled to done despite cleanup failure"
else
  fail "T7: expected done after reconcile, got '$T7_STATUS'"
fi

if [[ -f "$T7_MARKER" ]]; then
  pass "T7: .cleanup-pending.audit marker written on cleanup failure"
else
  fail "T7: .cleanup-pending.audit not written"
fi

# Now simulate the blocking condition being resolved: remove the directory
# so sweep_cleanup_pending can clear the marker entry cleanly.
# (When worktree_path doesn't exist, wt_ok stays true → entry cleared.)
rm -rf "$T7_WORKTREE_PATH" 2>/dev/null || true

# Run sweep_cleanup_pending
T7_SWEEP=$(mktemp "$FIXTURE_DIR/t7-sweep-XXXXXX")
build_harness "$T7_SWEEP" "$T7_DIR" "$T7_LOCK" "$T7_LOG" "$T7_MOCK_GH" \
  "export GAAI_WORKTREES_BASE=\"$T7_WT_BASE\""
printf 'sweep_cleanup_pending\n' >> "$T7_SWEEP"
chmod +x "$T7_SWEEP"
bash "$T7_SWEEP" 2>/dev/null

if [[ ! -f "$T7_MARKER" ]]; then
  pass "T7: .cleanup-pending.audit marker cleared after successful sweep"
else
  # Marker may exist but be empty
  T7_MARKER_LINES=$(wc -l < "$T7_MARKER" 2>/dev/null || echo 0)
  if [[ "$T7_MARKER_LINES" -eq 0 ]]; then
    pass "T7: .cleanup-pending.audit marker empty after sweep (cleared)"
  else
    fail "T7: .cleanup-pending.audit still has $T7_MARKER_LINES lines after sweep with no directory"
  fi
fi
rm -f "$T7_HARNESS" "$T7_SWEEP"

# ═══════════════════════════════════════════════════════════════════════════════
# T8 (MEDIUM-F5): gh returns baseRefName != staging → skip reconcile, story in_progress
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T8: PR targets wrong base branch — skip reconcile, story stays in_progress (MEDIUM-F5) ==="

T8_DIR="$FIXTURE_DIR/t8-project"
T8_LOCK="$FIXTURE_DIR/t8-locks"
T8_LOG="$FIXTURE_DIR/t8.log"
T8_MOCK_GH="$FIXTURE_DIR/t8-mock-gh"
mkdir -p "$T8_LOCK"
touch "$T8_LOG"

T8_SID="T8-STORY-08"
T8_YAML="- id: $T8_SID
  status: in_progress
  phase_status: qa_passed
  pr_url: https://github.com/org/repo/pull/808
  delivery_pipeline: 3phase"

setup_git_repo "$T8_DIR" "$T8_YAML"
create_mock_gh "$T8_MOCK_GH"
# PR targets feature-branch, not staging
export MOCK_GH_RESPONSE='{"mergedAt":"2026-05-11T10:00:00Z","state":"MERGED","baseRefName":"feature-branch"}'
export MOCK_GH_EXIT=0

T8_HARNESS=$(mktemp "$FIXTURE_DIR/t8-XXXXXX")
build_harness "$T8_HARNESS" "$T8_DIR" "$T8_LOCK" "$T8_LOG" "$T8_MOCK_GH"
printf 'watch_pr_merge_status\n' >> "$T8_HARNESS"
chmod +x "$T8_HARNESS"
bash "$T8_HARNESS" 2>/dev/null

T8_STATUS=$(git -C "$T8_DIR" show "origin/staging:.gaai/project/contexts/backlog/active.backlog.yaml" 2>/dev/null \
  | grep "status:" | head -1 | awk '{print $2}' || echo "")

if [[ "$T8_STATUS" == "in_progress" ]]; then
  pass "T8: story stays in_progress when PR targets wrong base branch"
else
  fail "T8: expected in_progress, got '$T8_STATUS'"
fi

T8_LOG_CONTENT=$(cat "$T8_LOG" 2>/dev/null || echo "")
if printf '%s\n' "$T8_LOG_CONTENT" | grep -q "PR targets baseRefName"; then
  pass "T8: skip-reconcile log message present"
else
  fail "T8: expected 'PR targets baseRefName' in log (got: $(cat "$T8_LOG" 2>/dev/null | tail -5))"
fi
rm -f "$T8_HARNESS"

# ═══════════════════════════════════════════════════════════════════════════════
# Watcher-only RED: the full entrypoint must recognize watcher-only mode before any
# Delivery startup/preflight path.  The fixture is a private clone with an
# exact target checkout; the intentionally absent receipt should therefore be
# reported as proof_invalid (rc 3), never as ordinary daemon usage or
# startup failure.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Watcher-only RED: entrypoint isolation ==="

S20_RED_ROOT="$FIXTURE_DIR/s20-red"
S20_RED_REPO="$S20_RED_ROOT/repo"
S20_RED_REMOTE="$S20_RED_ROOT/remote.git"
S20_RED_STATE="$S20_RED_ROOT/operator-state"
S20_RED_BIN="$S20_RED_ROOT/bin"
mkdir -p "$S20_RED_REPO/.gaai" "$S20_RED_REPO/.gaai/project/contexts/backlog" \
  "$S20_RED_STATE/local-admission-receipts" "$S20_RED_STATE/external-merge-settlements" \
  "$S20_RED_BIN"
chmod 700 "$S20_RED_STATE" "$S20_RED_STATE/local-admission-receipts" \
  "$S20_RED_STATE/external-merge-settlements"
cp -R "$SCRIPT_DIR/../.." "$S20_RED_REPO/.gaai/core"
# The yaml runtime demands its vendored assets at exactly 0644 and refuses
# group/other-writable directories. cp materialises the copy through the
# inherited umask (077 under the delivery wrapper -> 0600), which fails that
# check for the copy under test. Under the daemon this stayed hidden: the lane
# passed only with the wrapper's environment present (bisected to a real-valued
# GAAI_REPO_ROOT; the runtime itself does not read it, and the masking path was
# not traced). The fixture must not depend on either. Fix the modes.
chmod -R u=rwX,go=rX "$S20_RED_REPO/.gaai/core"
printf '%s\n' 'items: []' > "$S20_RED_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"
git init --bare "$S20_RED_REMOTE" -q
git -C "$S20_RED_REPO" init -q
git -C "$S20_RED_REPO" config user.email test@example.invalid
git -C "$S20_RED_REPO" config user.name 'Watcher Test'
git -C "$S20_RED_REPO" checkout -b staging -q
git -C "$S20_RED_REPO" add .
git -C "$S20_RED_REPO" commit -m initial -q
git -C "$S20_RED_REPO" remote add origin "$S20_RED_REMOTE"
git -C "$S20_RED_REPO" push -u origin staging -q

S20_RED_SENTINEL="$S20_RED_ROOT/startup-called"
for tool in tmux claude codex caffeinate osascript; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
    "$tool" "$S20_RED_SENTINEL" > "$S20_RED_BIN/$tool"
  chmod +x "$S20_RED_BIN/$tool"
done

S20_RED_PROD_SHA_BEFORE=$(shasum -a 256 "$DAEMON" | awk '{print $1}')
set +e
S20_RED_OUTPUT=$(cd "$S20_RED_REPO" && PATH="$S20_RED_BIN:$PATH" \
  GAAI_TARGET_BRANCH=staging \
  "$BASH" .gaai/core/scripts/delivery-daemon.sh \
    --watch-once-story WATCHER-STORY-1 --operator-state-root "$S20_RED_STATE" 2>&1)
S20_RED_RC=$?
set -e
S20_RED_PROD_SHA_AFTER=$(shasum -a 256 "$DAEMON" | awk '{print $1}')

if [[ "$S20_RED_PROD_SHA_BEFORE" == "$S20_RED_PROD_SHA_AFTER" ]]; then
  pass "S20-RED: production bytes stayed unchanged"
else
  fail "S20-RED: production bytes changed during RED"
fi
if [[ "$S20_RED_RC" -eq 3 ]]; then
  pass "S20-RED: missing receipt returned proof rc 3"
else
  fail "S20-RED: expected proof rc 3, got rc $S20_RED_RC"
fi
if [[ ! -e "$S20_RED_SENTINEL" ]]; then
  pass "S20-RED: watcher-only bypassed launcher/model/startup sentinels"
else
  fail "S20-RED: forbidden startup sentinel executed"
fi
if printf '%s\n' "$S20_RED_OUTPUT" | grep -Eq '(^|[[:space:]])(url|path|sha|digest|credential|counter)='; then
  fail "S20-RED: diagnostic exposed a forbidden value-bearing field"
else
  pass "S20-RED: diagnostic remained names-only"
fi

# Complete validation fixture. The target is a local bare remote; the admitted
# head is a side commit and the configured target contains a one-parent squash
# with the exact admitted tree. The watcher must reach its deliberate
# pre-mutation stop (rc 4), proving the receipt/PR/lineage chain without push.
S20_VALID_ROOT="$FIXTURE_DIR/s20-valid"
S20_VALID_REPO="$S20_VALID_ROOT/repo"
S20_VALID_REMOTE="$S20_VALID_ROOT/remote.git"
S20_VALID_STATE="$S20_VALID_ROOT/operator-state"
S20_VALID_BIN="$S20_VALID_ROOT/bin"
mkdir -p "$S20_VALID_REPO/.gaai" "$S20_VALID_REPO/.gaai/project/contexts/backlog" \
  "$S20_VALID_REPO/.gaai/project/ci" "$S20_VALID_STATE/local-admission-receipts" \
  "$S20_VALID_STATE/external-merge-settlements" "$S20_VALID_BIN"
chmod 700 "$S20_VALID_STATE" "$S20_VALID_STATE/local-admission-receipts" \
  "$S20_VALID_STATE/external-merge-settlements"
cp -R "$SCRIPT_DIR/../.." "$S20_VALID_REPO/.gaai/core"
# The yaml runtime demands its vendored assets at exactly 0644 and refuses
# group/other-writable directories. cp materialises the copy through the
# inherited umask (077 under the delivery wrapper -> 0600), which fails that
# check for the copy under test. Under the daemon this stayed hidden: the lane
# passed only with the wrapper's environment present (bisected to a real-valued
# GAAI_REPO_ROOT; the runtime itself does not read it, and the masking path was
# not traced). The fixture must not depend on either. Fix the modes.
chmod -R u=rwX,go=rX "$S20_VALID_REPO/.gaai/core"
# ...but that chmod is a one-shot on a tree this fixture then COMMITS, and every
# `git reset --hard` below re-materialises the tracked vendor assets through the
# same inherited umask -- back to 0600. The daemon invocations do not reveal it:
# their checkout proof repairs exactly those three files to 0644 before reading
# them. Nothing else does, so the first consumer of the boundary that is not the
# daemon -- the scheduler call in the partial-terminal fixture below -- sees
# whichever mode the immediately preceding reset happened to leave, and dies with
# one opaque `code=yaml_runtime_manifest_invalid` line. Re-establish the exact
# mode after every checkout instead, and assert it rather than assume it.
s20_exact_vendor_modes() {
  local dir="$S20_VALID_REPO/.gaai/core/vendor/pyyaml/6.0.3" asset
  for asset in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
    [[ -f "$dir/$asset" ]] || continue
    chmod 0644 "$dir/$asset" 2>/dev/null || true
    if [[ "$(portable_mode "$dir/$asset" 2>/dev/null || true)" != "644" ]]; then
      fail "S20-FIXTURE: vendored runtime asset $asset is not at 0644 — every assertion behind the boundary is unreliable"
      return 1
    fi
  done
  return 0
}
if s20_exact_vendor_modes; then
  pass "S20-FIXTURE: vendored runtime assets start at exactly 0644"
fi
git init --bare "$S20_VALID_REMOTE" -q
git -C "$S20_VALID_REPO" init -q
git -C "$S20_VALID_REPO" config user.email test@example.invalid
git -C "$S20_VALID_REPO" config user.name 'Watcher Test'
git -C "$S20_VALID_REPO" checkout -b staging -q
printf '%s\n' "{\"schema_version\":\"1.0.0\",\"policy_version\":\"fixture\",\"repository\":{\"project_id\":\"example/watcher\",\"remote\":\"$S20_VALID_REMOTE\",\"base_ref\":\"staging\"},\"limits\":{\"max_receipt_bytes\":65536}}" \
  > "$S20_VALID_REPO/.gaai/project/ci/local-admission.json"
cat > "$S20_VALID_REPO/.gaai/project/contexts/backlog/active.backlog.yaml" <<'S20_YAML'
items:
  - id: WATCHER-STORY-1
    status: in_progress
    phase_status: qa_passed
    pr_status: pending_review
    pr_url: "https://github.com/example/watcher/pull/20"
    started_at: "2026-08-29T01:00:00Z"
S20_YAML
printf '%s\n' base > "$S20_VALID_REPO/proof.txt"
git -C "$S20_VALID_REPO" add .
git -C "$S20_VALID_REPO" commit -m base -q
S20_BASE=$(git -C "$S20_VALID_REPO" rev-parse HEAD)
printf '%s\n' candidate > "$S20_VALID_REPO/proof.txt"
git -C "$S20_VALID_REPO" add proof.txt
git -C "$S20_VALID_REPO" commit -m candidate -q
S20_HEAD=$(git -C "$S20_VALID_REPO" rev-parse HEAD)
S20_HEAD_TREE=$(git -C "$S20_VALID_REPO" rev-parse 'HEAD^{tree}')
git -C "$S20_VALID_REPO" remote add origin "$S20_VALID_REMOTE"
git -C "$S20_VALID_REPO" push origin HEAD:refs/heads/admitted-head -q
S20_MERGE=$(printf '%s\n' squash | git -C "$S20_VALID_REPO" commit-tree "$S20_HEAD_TREE" -p "$S20_BASE")
git -C "$S20_VALID_REPO" reset --hard "$S20_MERGE" -q
git -C "$S20_VALID_REPO" push -u origin HEAD:staging -q

S20_RECEIPT="$S20_VALID_STATE/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
node --input-type=module -e '
  import fs from "node:fs"; import {createHash} from "node:crypto";
  import {pathToFileURL} from "node:url";
  const [sentinel,helper,policyPath,remote,base,head,out]=process.argv.slice(1);
  if (sentinel !== "fixture-import") throw new Error("fixture_sentinel_invalid");
  const {canonicalJson,sealReceipt}=await import(pathToFileURL(helper).href);
  const policy=JSON.parse(fs.readFileSync(policyPath,"utf8"));
  const h=v=>createHash("sha256").update(v).digest("hex");
  const command={id:"oss",descriptor_digest:h("descriptor"),configuration_digest:h("config")};
  const binding={project_id:"example/watcher",repository_digest:h(remote),base_ref:"staging",base_sha:base,head_sha:head,
    normalized_diff_digest:h("diff"),dependency_digest:h("deps"),risk_digest:h("risk"),policy_version:"fixture",
    policy_digest:h(canonicalJson(policy)),selector_digest:h("selector"),environment_digest:h("environment"),command_digests:[command]};
  const plan={status:"resolved",binding,binding_digest:h(canonicalJson(binding)),selected_commands:[{...command,argv:["true"],timeout_seconds:1,output_limit_bytes:128}],
    summary:{selected_surface_ids:["oss"],selected_command_ids:["oss"]}};
  const results=[{command_id:"oss",descriptor_digest:command.descriptor_digest,configuration_digest:command.configuration_digest,
    outcome:"passed",exit_code:0,signal:null,duration_ms:1,stdout_bytes:0,stderr_bytes:0,stdout_truncated:false,stderr_truncated:false}];
  const bytes=sealReceipt({boundary:"final",storyId:"WATCHER-STORY-1",plan,results,resultsDigest:h(canonicalJson(results)),outcome:"pass",
    expectedBindingDigest:plan.binding_digest,createdAt:"2026-08-29T02:00:00Z",maxBytes:65536});
  fs.writeFileSync(out,bytes,{mode:0o600,flag:"wx"});
' fixture-import "$S20_VALID_REPO/.gaai/core/scripts/lib/local-admission-executor.mjs" \
  "$S20_VALID_REPO/.gaai/project/ci/local-admission.json" "$S20_VALID_REMOTE" \
  "$S20_BASE" "$S20_HEAD" "$S20_RECEIPT"
chmod 600 "$S20_RECEIPT"

cat > "$S20_VALID_BIN/gh" <<S20_GH
#!/usr/bin/env bash
printf '%s\n' '{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"MERGED","createdAt":"2026-08-28T22:00:00Z","mergedAt":"2026-08-29T03:00:00Z","baseRefName":"staging","headRefOid":"$S20_HEAD","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"$S20_MERGE"}}'
S20_GH
chmod +x "$S20_VALID_BIN/gh"
set +e
S20_VALID_OUTPUT=$(cd "$S20_VALID_REPO" && PATH="$S20_VALID_BIN:$PATH" \
  "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 \
  --operator-state-root "$S20_VALID_STATE" 2>&1)
S20_VALID_RC=$?
set -e
if [[ "$S20_VALID_RC" -eq 0 ]] && printf '%s\n' "$S20_VALID_OUTPUT" | grep -q \
    'outcome=reconciled fields=status,phase_status,pr_status,completed_at'; then
  pass "S20-VALID: exact receipt, reused PR and squash lineage reconciled"
else
  fail "S20-VALID: exact reconciliation failed (rc=$S20_VALID_RC)"
fi
S20_VALID_REMOTE_AFTER=$(git --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)
S20_VALID_PARENT=$(git --git-dir="$S20_VALID_REMOTE" show -s --format=%P "$S20_VALID_REMOTE_AFTER")
S20_VALID_CHANGED=$(git --git-dir="$S20_VALID_REMOTE" diff-tree --no-commit-id --name-only -r "$S20_VALID_REMOTE_AFTER")
S20_VALID_BACKLOG=$(git --git-dir="$S20_VALID_REMOTE" show "$S20_VALID_REMOTE_AFTER:.gaai/project/contexts/backlog/active.backlog.yaml")
if [[ "$S20_VALID_PARENT" == "$S20_MERGE" && "$S20_VALID_CHANGED" == ".gaai/project/contexts/backlog/active.backlog.yaml" ]]; then
  pass "S20-VALID: exact-parent commit changed only the backlog"
else
  fail "S20-VALID: generated commit parent or path delta was not exact"
fi
if printf '%s\n' "$S20_VALID_BACKLOG" | grep -q '^    status: done$' \
    && printf '%s\n' "$S20_VALID_BACKLOG" | grep -q '^    phase_status: done$' \
    && printf '%s\n' "$S20_VALID_BACKLOG" | grep -q '^    pr_status: merged$' \
    && printf '%s\n' "$S20_VALID_BACKLOG" | grep -Eq '^    completed_at: "?2026-08-29T03:00:00Z"?$'; then
  pass "S20-VALID: complete four-field terminal tuple landed"
else
  fail "S20-VALID: complete four-field terminal tuple missing"
fi
S20_SETTLEMENT="$S20_VALID_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json"
S20_SETTLEMENT_MODE=$(portable_mode "$S20_SETTLEMENT")
if [[ -f "$S20_SETTLEMENT" && "$S20_SETTLEMENT_MODE" == "600" ]]; then
  pass "S20-VALID: durable settlement is a private regular file"
else
  fail "S20-VALID: durable settlement missing or not mode 0600"
fi

# A fresh exact-target clone has none of the invoking checkout's transient
# object state.  It must reconcile the same immutable settlement idempotently,
# without creating a different commit or invoking Delivery startup tools.
S20_FRESH_REPO="$S20_VALID_ROOT/fresh-repo"
git clone --branch staging "$S20_VALID_REMOTE" "$S20_FRESH_REPO" -q
git -C "$S20_FRESH_REPO" config user.email test@example.invalid
git -C "$S20_FRESH_REPO" config user.name 'Watcher Test'
set +e
S20_IDEMPOTENT_OUTPUT=$(cd "$S20_FRESH_REPO" && PATH="$S20_VALID_BIN:$PATH" \
  "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 \
  --operator-state-root "$S20_VALID_STATE" 2>&1)
S20_IDEMPOTENT_RC=$?
set -e
S20_IDEMPOTENT_REMOTE=$(git --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)
if [[ "$S20_IDEMPOTENT_RC" -eq 0 && "$S20_IDEMPOTENT_REMOTE" == "$S20_VALID_REMOTE_AFTER" ]]; then
  pass "S20-IDEMPOTENT: fresh target clone accepted only the identical settlement"
else
  fail "S20-IDEMPOTENT: fresh clone changed or rejected exact settlement"
fi
if printf '%s\n' "$S20_IDEMPOTENT_OUTPUT" | grep -Eq '(^|[[:space:]])(url|path|sha|digest|credential|counter|outcome_value)='; then
  fail "S20-IDEMPOTENT: diagnostic exposed a forbidden value-bearing field"
else
  pass "S20-IDEMPOTENT: output remained privacy-safe"
fi

S20_REAL_GIT=$(command -v git)
s20_reset_target() {
  "$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" update-ref refs/heads/staging "$S20_MERGE"
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" fetch origin staging -q
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" reset --hard origin/staging -q
  s20_exact_vendor_modes || true
}
s20_new_state() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/local-admission-receipts" "$root/external-merge-settlements"
  chmod 700 "$root" "$root/local-admission-receipts" "$root/external-merge-settlements"
  cp "$S20_RECEIPT" "$root/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
  chmod 600 "$root/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
}
s20_run() {
  local repo="$1" state="$2" bin="$3"
  (cd "$repo" && PATH="$bin:$PATH" "$BASH" .gaai/core/scripts/delivery-daemon.sh \
    --watch-once-story WATCHER-STORY-1 --operator-state-root "$state" 2>&1)
}

# A configured pre-push hook is hostile ambient code.  The permanent effect
# path disables hooks explicitly and still produces the exact-parent commit.
s20_reset_target
S20_HOOK_STATE="$S20_VALID_ROOT/hook-state"
S20_HOOK_BIN="$S20_VALID_ROOT/hook-bin"
S20_HOOK_SENTINEL="$S20_VALID_ROOT/hook-called"
S20_GIT_CONFIG_SENTINEL="$S20_VALID_ROOT/git-config-called"
S20_AUTH_ENV_SENTINEL="$S20_VALID_ROOT/auth-env-seen"
S20_AUTH_HOME="$S20_VALID_ROOT/auth-home"
S20_AUTH_XDG="$S20_VALID_ROOT/auth-xdg"
S20_HOSTILE_SYSTEM_CONFIG="$S20_VALID_ROOT/hostile-system.gitconfig"
S20_SECONDARY_REMOTE="$S20_VALID_ROOT/secondary.git"
s20_new_state "$S20_HOOK_STATE"
"$S20_REAL_GIT" init --bare "$S20_SECONDARY_REMOTE" -q
mkdir -p "$S20_HOOK_BIN" "$S20_AUTH_HOME" "$S20_AUTH_XDG"
cat > "$S20_HOOK_BIN/gh" <<S20_AUTH_GH
#!/usr/bin/env bash
if [[ "\${1:-}" == auth && "\${2:-}" == git-credential ]]; then
  printf '%s|%s\n' "\${HOME:-}" "\${XDG_CONFIG_HOME:-}" > "$S20_AUTH_ENV_SENTINEL"
  while IFS= read -r line && [[ -n "\$line" ]]; do :; done
  printf '%s\n' 'username=watcher' 'password=fixture'
  exit 0
fi
printf '%s\n' '{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"MERGED","createdAt":"2026-08-28T22:00:00Z","mergedAt":"2026-08-29T03:00:00Z","baseRefName":"staging","headRefOid":"$S20_HEAD","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"$S20_MERGE"}}'
S20_AUTH_GH
chmod +x "$S20_HOOK_BIN/gh"
cat > "$S20_AUTH_HOME/.gitconfig" <<S20_AUTH_GLOBAL
[url "$S20_SECONDARY_REMOTE"]
  pushInsteadOf = $S20_VALID_REMOTE
S20_AUTH_GLOBAL
cat > "$S20_HOSTILE_SYSTEM_CONFIG" <<S20_AUTH_SYSTEM
[url "$S20_SECONDARY_REMOTE"]
  insteadOf = $S20_VALID_REMOTE
S20_AUTH_SYSTEM
cat > "$S20_VALID_REPO/.git/hooks/pre-push" <<S20_HOOK
#!/usr/bin/env bash
printf 'called\n' > "$S20_HOOK_SENTINEL"
exit 99
S20_HOOK
chmod +x "$S20_VALID_REPO/.git/hooks/pre-push"
cat > "$S20_HOOK_BIN/hostile-git-config" <<S20_GIT_CONFIG
#!/usr/bin/env bash
printf 'called\n' >> "$S20_GIT_CONFIG_SENTINEL"
exit 98
S20_GIT_CONFIG
chmod +x "$S20_HOOK_BIN/hostile-git-config"
# Exercise the exact fixed helper command under the same Git config isolation.
# Authentication state remains visible through HOME/XDG, while ambient Git
# rewrite configuration is disabled independently.
printf 'protocol=https\nhost=example.invalid\n\n' | \
  HOME="$S20_AUTH_HOME" XDG_CONFIG_HOME="$S20_AUTH_XDG" PATH="$S20_HOOK_BIN:$PATH" \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  "$S20_REAL_GIT" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
  credential fill >/dev/null
"$S20_REAL_GIT" -C "$S20_VALID_REPO" tag -a watcher-follow-tag -m hostile "$S20_MERGE"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config push.followTags true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config push.gpgSign true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config remote.origin.mirror true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config remote.origin.uploadpack "$S20_HOOK_BIN/hostile-git-config"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config remote.origin.receivepack "$S20_HOOK_BIN/hostile-git-config"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config core.fsmonitor "$S20_HOOK_BIN/hostile-git-config"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --add credential.helper "!$S20_HOOK_BIN/hostile-git-config"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --add "url.$S20_SECONDARY_REMOTE.pushInsteadOf" "$S20_VALID_REMOTE"
S20_REMOTE_REFS_BEFORE=$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" for-each-ref \
  --format='%(refname) %(objectname)' | grep -v '^refs/heads/staging ' | sort)
for tool in tmux claude codex caffeinate osascript; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 97\n' \
    "$tool" "$S20_HOOK_SENTINEL.startup" > "$S20_HOOK_BIN/$tool"
  chmod +x "$S20_HOOK_BIN/$tool"
done
set +e
S20_HOOK_OUTPUT=$(HOME="$S20_AUTH_HOME" XDG_CONFIG_HOME="$S20_AUTH_XDG" \
  GIT_CONFIG_SYSTEM="$S20_HOSTILE_SYSTEM_CONFIG" \
  s20_run "$S20_VALID_REPO" "$S20_HOOK_STATE" "$S20_HOOK_BIN")
S20_HOOK_RC=$?
set -e
if [[ "$S20_HOOK_RC" -eq 0 && ! -e "$S20_HOOK_SENTINEL" ]]; then
  pass "S20-HOOK: exact push bypassed hostile repository hooks"
else
  fail "S20-HOOK: hostile hook ran or reconciliation failed"
fi
S20_REMOTE_REFS_AFTER=$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" for-each-ref \
  --format='%(refname) %(objectname)' | grep -v '^refs/heads/staging ' | sort)
if [[ ! -e "$S20_GIT_CONFIG_SENTINEL" && "$S20_REMOTE_REFS_AFTER" == "$S20_REMOTE_REFS_BEFORE" \
    && -z "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" for-each-ref refs/tags/watcher-follow-tag)" \
    && -z "$("$S20_REAL_GIT" --git-dir="$S20_SECONDARY_REMOTE" for-each-ref)" ]]; then
  pass "S20-HARDENED-GIT: fsmonitor/uploadpack/receivepack/credential/followTags config was inert"
else
  fail "S20-HARDENED-GIT: ambient Git config executed or changed an extra remote ref"
fi
if [[ "$(cat "$S20_AUTH_ENV_SENTINEL" 2>/dev/null || true)" == "$S20_AUTH_HOME|$S20_AUTH_XDG" ]]; then
  pass "S20-AUTH: fixed credential helper retained operator HOME/XDG under isolated Git config"
else
  fail "S20-AUTH: fixed credential helper lost operator authentication environment"
fi
if [[ ! -e "$S20_HOOK_SENTINEL.startup" ]]; then
  pass "S20-HOOK: successful watcher did not start Delivery side effects"
else
  fail "S20-HOOK: successful watcher reached a Delivery startup tool"
fi
rm -f "$S20_VALID_REPO/.git/hooks/pre-push"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all push.followTags || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all push.gpgSign || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all remote.origin.mirror || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all remote.origin.uploadpack || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all remote.origin.receivepack || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all core.fsmonitor || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all credential.helper || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all "url.$S20_SECONDARY_REMOTE.pushInsteadOf" || true
"$S20_REAL_GIT" -C "$S20_VALID_REPO" tag -d watcher-follow-tag >/dev/null

# Unknown acknowledgement: the proxy refuses the push and then makes the
# authoritative fetch unavailable.  The watcher must retain settlement and
# return 75.  A different fresh clone then rematerializes and pushes the exact
# stored commit OID, proving no dependence on transient object storage.
s20_reset_target
S20_ACK_STATE="$S20_VALID_ROOT/ack-state"
S20_ACK_BIN="$S20_VALID_ROOT/ack-bin"
S20_ACK_MARKER="$S20_VALID_ROOT/ack-attempted"
s20_new_state "$S20_ACK_STATE"
mkdir -p "$S20_ACK_BIN"
cp "$S20_VALID_BIN/gh" "$S20_ACK_BIN/gh"
cat > "$S20_ACK_BIN/git" <<S20_ACK_GIT
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    : > "$S20_ACK_MARKER"
    exit 41
  fi
done
if [[ -e "$S20_ACK_MARKER" ]]; then
  for arg in "\$@"; do [[ "\$arg" == fetch ]] && exit 42; done
fi
exec "$S20_REAL_GIT" "\$@"
S20_ACK_GIT
chmod +x "$S20_ACK_BIN/git"
set +e
S20_ACK_OUTPUT=$(s20_run "$S20_VALID_REPO" "$S20_ACK_STATE" "$S20_ACK_BIN")
S20_ACK_RC=$?
set -e
S20_ACK_SETTLEMENT="$S20_ACK_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json"
S20_ACK_COMMIT=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).commit_sha)' "$S20_ACK_SETTLEMENT")
if [[ "$S20_ACK_RC" -eq 75 && -f "$S20_ACK_SETTLEMENT" \
    && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_MERGE" ]]; then
  pass "S20-ACK: unobservable push returned settlement_unknown with durable identity"
else
  fail "S20-ACK: unknown acknowledgement was misclassified"
fi
S20_ACK_FRESH="$S20_VALID_ROOT/ack-fresh"
rm -rf "$S20_ACK_FRESH"
"$S20_REAL_GIT" clone --branch staging "$S20_VALID_REMOTE" "$S20_ACK_FRESH" -q
"$S20_REAL_GIT" -C "$S20_ACK_FRESH" config user.email test@example.invalid
"$S20_REAL_GIT" -C "$S20_ACK_FRESH" config user.name 'Watcher Test'
set +e
S20_ACK_RETRY_OUTPUT=$(s20_run "$S20_ACK_FRESH" "$S20_ACK_STATE" "$S20_VALID_BIN")
S20_ACK_RETRY_RC=$?
set -e
S20_ACK_REMOTE=$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)
if [[ "$S20_ACK_RETRY_RC" -eq 0 && "$S20_ACK_REMOTE" == "$S20_ACK_COMMIT" ]]; then
  pass "S20-ACK: fresh clone rematerialized and landed the identical commit OID"
else
  fail "S20-ACK: retry regenerated or failed to land the durable settlement"
fi

# A true lost acknowledgement is distinct from a push that never landed: the
# proxy performs the real bare push, returns failure, and blocks exactly the
# first authoritative observation.  The first call must return 75 even though
# the exact commit landed; a fresh exact-target call then proves it and returns
# 0 without issuing a second push.
s20_reset_target
S20_ACK_LANDED_STATE="$S20_VALID_ROOT/ack-landed-state"
S20_ACK_LANDED_BIN="$S20_VALID_ROOT/ack-landed-bin"
S20_ACK_LANDED_MARKER="$S20_VALID_ROOT/ack-landed-attempted"
S20_ACK_LANDED_BLOCKED="$S20_VALID_ROOT/ack-landed-observation-blocked"
s20_new_state "$S20_ACK_LANDED_STATE"; mkdir -p "$S20_ACK_LANDED_BIN"
cp "$S20_VALID_BIN/gh" "$S20_ACK_LANDED_BIN/gh"
cat > "$S20_ACK_LANDED_BIN/git" <<S20_ACK_LANDED_GIT
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    "$S20_REAL_GIT" "\$@" >/dev/null 2>&1 || exit \$?
    : > "$S20_ACK_LANDED_MARKER"
    exit 41
  fi
done
if [[ -e "$S20_ACK_LANDED_MARKER" && ! -e "$S20_ACK_LANDED_BLOCKED" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == fetch ]]; then : > "$S20_ACK_LANDED_BLOCKED"; exit 42; fi
  done
fi
exec "$S20_REAL_GIT" "\$@"
S20_ACK_LANDED_GIT
chmod +x "$S20_ACK_LANDED_BIN/git"
set +e
S20_ACK_LANDED_OUTPUT=$(s20_run "$S20_VALID_REPO" "$S20_ACK_LANDED_STATE" "$S20_ACK_LANDED_BIN")
S20_ACK_LANDED_RC=$?
set -e
S20_ACK_LANDED_SETTLEMENT="$S20_ACK_LANDED_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json"
S20_ACK_LANDED_COMMIT=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).commit_sha)' \
  "$S20_ACK_LANDED_SETTLEMENT")
S20_ACK_LANDED_REMOTE=$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)
if [[ "$S20_ACK_LANDED_RC" -eq 75 && "$S20_ACK_LANDED_REMOTE" == "$S20_ACK_LANDED_COMMIT" \
    && -e "$S20_ACK_LANDED_BLOCKED" ]]; then
  pass "S20-ACK-LANDED: real push plus lost acknowledgement returned rc 75"
else
  fail "S20-ACK-LANDED: landed-but-unobserved push was misclassified"
fi
S20_ACK_LANDED_FRESH="$S20_VALID_ROOT/ack-landed-fresh"
S20_ACK_LANDED_VERIFY_BIN="$S20_VALID_ROOT/ack-landed-verify-bin"
S20_ACK_LANDED_SECOND_PUSH="$S20_VALID_ROOT/ack-landed-second-push"
"$S20_REAL_GIT" clone --branch staging "$S20_VALID_REMOTE" "$S20_ACK_LANDED_FRESH" -q
mkdir -p "$S20_ACK_LANDED_VERIFY_BIN"; cp "$S20_VALID_BIN/gh" "$S20_ACK_LANDED_VERIFY_BIN/gh"
cat > "$S20_ACK_LANDED_VERIFY_BIN/git" <<S20_ACK_VERIFY_GIT
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then : > "$S20_ACK_LANDED_SECOND_PUSH"; exit 99; fi
done
exec "$S20_REAL_GIT" "\$@"
S20_ACK_VERIFY_GIT
chmod +x "$S20_ACK_LANDED_VERIFY_BIN/git"
set +e
S20_ACK_LANDED_VERIFY_OUTPUT=$(s20_run "$S20_ACK_LANDED_FRESH" "$S20_ACK_LANDED_STATE" "$S20_ACK_LANDED_VERIFY_BIN")
S20_ACK_LANDED_VERIFY_RC=$?
set -e
if [[ "$S20_ACK_LANDED_VERIFY_RC" -eq 0 && ! -e "$S20_ACK_LANDED_SECOND_PUSH" \
    && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_ACK_LANDED_COMMIT" ]]; then
  pass "S20-ACK-LANDED: fresh exact-target invocation reconciled without another push"
else
  fail "S20-ACK-LANDED: idempotent reconciliation attempted a successor push"
fi

# Exact-parent race: an unrelated target descendant appears at the push edge.
# The lease must reject the stored child; there is no rebase or replacement.
s20_reset_target
S20_RACE_STATE="$S20_VALID_ROOT/race-state"
S20_RACE_BIN="$S20_VALID_ROOT/race-bin"
S20_RACE_REPO="$S20_VALID_ROOT/race-builder"
s20_new_state "$S20_RACE_STATE"
rm -f "$S20_VALID_ROOT/race-fired"
rm -rf "$S20_RACE_REPO"; "$S20_REAL_GIT" clone --branch staging "$S20_VALID_REMOTE" "$S20_RACE_REPO" -q
"$S20_REAL_GIT" -C "$S20_RACE_REPO" config user.email test@example.invalid
"$S20_REAL_GIT" -C "$S20_RACE_REPO" config user.name 'Watcher Test'
printf 'unrelated\n' > "$S20_RACE_REPO/unrelated.txt"
"$S20_REAL_GIT" -C "$S20_RACE_REPO" add unrelated.txt
"$S20_REAL_GIT" -C "$S20_RACE_REPO" commit -m unrelated -q
S20_RACE_TIP=$("$S20_REAL_GIT" -C "$S20_RACE_REPO" rev-parse HEAD)
"$S20_REAL_GIT" -C "$S20_RACE_REPO" push origin HEAD:refs/heads/race-tip -q
mkdir -p "$S20_RACE_BIN"; cp "$S20_VALID_BIN/gh" "$S20_RACE_BIN/gh"
cat > "$S20_RACE_BIN/git" <<S20_RACE_GIT
#!/usr/bin/env bash
remote_git() (
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  exec "$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" "\$@"
)
for arg in "\$@"; do
  if [[ "\$arg" == --force-with-lease=refs/heads/staging:* \
      && ! -e "$S20_VALID_ROOT/race-fired" ]]; then
    remote_git update-ref refs/heads/staging "$S20_RACE_TIP" || exit 98
    : > "$S20_VALID_ROOT/race-fired"
  fi
done
exec "$S20_REAL_GIT" "\$@"
S20_RACE_GIT
chmod +x "$S20_RACE_BIN/git"
set +e
S20_RACE_OUTPUT=$(s20_run "$S20_VALID_REPO" "$S20_RACE_STATE" "$S20_RACE_BIN")
S20_RACE_RC=$?
set -e
S20_RACE_REMOTE=$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)
S20_RACE_SETTLED=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).commit_sha)' \
  "$S20_RACE_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json")
if [[ "$S20_RACE_RC" -eq 4 && "$S20_RACE_REMOTE" == "$S20_RACE_TIP" && "$S20_RACE_REMOTE" != "$S20_RACE_SETTLED" ]]; then
  pass "S20-RACE: unrelated target advance rejected the exact-parent lease without rebase"
else
  fail "S20-RACE: target race was not contained (rc=$S20_RACE_RC remote=$S20_RACE_REMOTE settled=$S20_RACE_SETTLED)"
fi

# A validly canonical but different pre-existing settlement is a proof conflict,
# never overwrite authority.  The target remains the exact parent.
s20_reset_target
S20_CONFLICT_STATE="$S20_VALID_ROOT/conflict-state"
s20_new_state "$S20_CONFLICT_STATE"
S20_CONFLICT_FILE="$S20_CONFLICT_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json"
node --input-type=module -e '
  import fs from "node:fs"; import {createHash} from "node:crypto";
  import {pathToFileURL} from "node:url";
  const [source,target,helper]=process.argv.slice(1); const {canonicalJson}=await import(pathToFileURL(helper).href);
  const value=JSON.parse(fs.readFileSync(source)); value.receipt_digest="0".repeat(64); delete value.settlement_digest;
  value.settlement_digest=createHash("sha256").update(canonicalJson(value)).digest("hex");
  fs.writeFileSync(target,canonicalJson(value)+"\n",{mode:0o600,flag:"wx"});
' "$S20_SETTLEMENT" "$S20_CONFLICT_FILE" "$S20_VALID_REPO/.gaai/core/scripts/lib/local-admission-executor.mjs"
chmod 600 "$S20_CONFLICT_FILE"
set +e
S20_CONFLICT_OUTPUT=$(s20_run "$S20_VALID_REPO" "$S20_CONFLICT_STATE" "$S20_VALID_BIN")
S20_CONFLICT_RC=$?
set -e
if [[ "$S20_CONFLICT_RC" -eq 3 \
    && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_MERGE" ]]; then
  pass "S20-CONFLICT: different immutable settlement was rejected without overwrite"
else
  fail "S20-CONFLICT: conflicting settlement changed authority"
fi

# Replace the receipt inode while the second GitHub observation is running.
# Revalidation after that call must detect the swap before settlement or push.
s20_reset_target
S20_SWAP_STATE="$S20_VALID_ROOT/swap-state"
S20_SWAP_BIN="$S20_VALID_ROOT/swap-bin"
S20_SWAP_COUNT="$S20_VALID_ROOT/swap-count"
s20_new_state "$S20_SWAP_STATE"
mkdir -p "$S20_SWAP_BIN"
cat > "$S20_SWAP_BIN/gh" <<S20_SWAP_GH
#!/usr/bin/env bash
count=0; [[ -r "$S20_SWAP_COUNT" ]] && read -r count < "$S20_SWAP_COUNT"
count=\$((count+1)); printf '%s\n' "\$count" > "$S20_SWAP_COUNT"
if [[ "\$count" -eq 2 ]]; then
  receipt="$S20_SWAP_STATE/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
  cp "\$receipt" "\$receipt.swap"; chmod 600 "\$receipt.swap"; mv "\$receipt.swap" "\$receipt"
fi
printf '%s\n' '{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"MERGED","createdAt":"2026-08-28T22:00:00Z","mergedAt":"2026-08-29T03:00:00Z","baseRefName":"staging","headRefOid":"$S20_HEAD","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"$S20_MERGE"}}'
S20_SWAP_GH
chmod +x "$S20_SWAP_BIN/gh"
set +e
S20_SWAP_OUTPUT=$(s20_run "$S20_VALID_REPO" "$S20_SWAP_STATE" "$S20_SWAP_BIN")
S20_SWAP_RC=$?
set -e
if [[ "$S20_SWAP_RC" -eq 3 && ! -e "$S20_SWAP_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json" \
    && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_MERGE" ]]; then
  pass "S20-SWAP: receipt replacement at effect edge was rejected before mutation"
else
  fail "S20-SWAP: receipt replacement reached settlement or target mutation"
fi

# ── Full-entrypoint typed/fault matrix (intrinsic to the invoking Bash) ───────
S20_TYPED_SEEN="0 3 4 75"
S20_ALL_DIAGNOSTICS="$S20_VALID_OUTPUT
$S20_IDEMPOTENT_OUTPUT
$S20_ACK_OUTPUT
$S20_RACE_OUTPUT
$S20_CONFLICT_OUTPUT
$S20_SWAP_OUTPUT"
s20_expect_rc() {
  local label="$1" expected="$2" repo="$3" state="$4" bin="$5"
  local output rc
  set +e
  output=$(s20_run "$repo" "$state" "$bin")
  rc=$?
  set -e
  S20_ALL_DIAGNOSTICS="$S20_ALL_DIAGNOSTICS
$output"
  S20_TYPED_SEEN="$S20_TYPED_SEEN $rc"
  if [[ "$rc" -eq "$expected" ]]; then pass "$label"; else fail "$label (expected rc $expected, got $rc)"; fi
}

# Origin authority is a singleton inventory.  Duplicate fetch or push URLs are
# rejected before transport creation/evidence, and no secondary bare ref moves.
for S20_URL_FAULT in fetch push; do
  s20_reset_target
  S20_URL_STATE="$S20_VALID_ROOT/url-$S20_URL_FAULT"; s20_new_state "$S20_URL_STATE"
  if [[ "$S20_URL_FAULT" == fetch ]]; then
    "$S20_REAL_GIT" -C "$S20_VALID_REPO" config --add remote.origin.url "$S20_SECONDARY_REMOTE"
  else
    "$S20_REAL_GIT" -C "$S20_VALID_REPO" config --add remote.origin.pushurl "$S20_VALID_REMOTE"
    "$S20_REAL_GIT" -C "$S20_VALID_REPO" config --add remote.origin.pushurl "$S20_SECONDARY_REMOTE"
  fi
  s20_expect_rc "S20-ORIGIN: non-singleton $S20_URL_FAULT URL inventory rejected" 3 \
    "$S20_VALID_REPO" "$S20_URL_STATE" "$S20_VALID_BIN"
  if [[ -z "$("$S20_REAL_GIT" --git-dir="$S20_SECONDARY_REMOTE" for-each-ref)" ]]; then
    pass "S20-ORIGIN: non-singleton $S20_URL_FAULT inventory left secondary untouched"
  else
    fail "S20-ORIGIN: non-singleton $S20_URL_FAULT inventory reached secondary"
  fi
  if [[ "$S20_URL_FAULT" == fetch ]]; then
    "$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all remote.origin.url
    "$S20_REAL_GIT" -C "$S20_VALID_REPO" config remote.origin.url "$S20_VALID_REMOTE"
  else
    "$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all remote.origin.pushurl
  fi
done

# Swap the configured destination after durable settlement.  The stored
# effective endpoint and fresh singleton rebind must fail closed before push;
# neither primary nor secondary advances.
s20_reset_target
S20_CONFIG_SWAP_STATE="$S20_VALID_ROOT/config-swap-state"
S20_CONFIG_SWAP_BIN="$S20_VALID_ROOT/config-swap-bin"
S20_CONFIG_SWAP_MARKER="$S20_VALID_ROOT/config-swap-fired"
s20_new_state "$S20_CONFIG_SWAP_STATE"; mkdir -p "$S20_CONFIG_SWAP_BIN"
cp "$S20_VALID_BIN/gh" "$S20_CONFIG_SWAP_BIN/gh"
cat > "$S20_CONFIG_SWAP_BIN/git" <<S20_CONFIG_SWAP_GIT
#!/usr/bin/env bash
settlement="$S20_CONFIG_SWAP_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json"
if [[ -e "\$settlement" && ! -e "$S20_CONFIG_SWAP_MARKER" ]]; then
  : > "$S20_CONFIG_SWAP_MARKER"
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" config remote.origin.pushurl "$S20_SECONDARY_REMOTE"
fi
exec "$S20_REAL_GIT" "\$@"
S20_CONFIG_SWAP_GIT
chmod +x "$S20_CONFIG_SWAP_BIN/git"
S20_CONFIG_PRIMARY_BEFORE=$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)
s20_expect_rc "S20-ORIGIN: destination config swap after settlement rejected" 3 \
  "$S20_VALID_REPO" "$S20_CONFIG_SWAP_STATE" "$S20_CONFIG_SWAP_BIN"
if [[ "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_CONFIG_PRIMARY_BEFORE" \
    && -z "$("$S20_REAL_GIT" --git-dir="$S20_SECONDARY_REMOTE" for-each-ref)" ]]; then
  pass "S20-ORIGIN: config swap changed neither primary nor secondary"
else
  fail "S20-ORIGIN: config swap reached a remote effect"
fi
"$S20_REAL_GIT" -C "$S20_VALID_REPO" config --unset-all remote.origin.pushurl || true

# A raw absolute filesystem endpoint may itself be a symlink, but its physical
# destination is bound once and re-resolved at every effect edge.  A swap after
# settlement fails closed; a swap at the literal push edge cannot redirect the
# already-bound physical endpoint.
s20_reset_target
S20_SYMLINK_RAW="$S20_VALID_REMOTE"
S20_SYMLINK_A="$S20_VALID_ROOT/origin-physical-a.git"
S20_SYMLINK_B="$S20_VALID_ROOT/origin-physical-b.git"
mv "$S20_SYMLINK_RAW" "$S20_SYMLINK_A"
ln -s "$S20_SYMLINK_A" "$S20_SYMLINK_RAW"
"$S20_REAL_GIT" init --bare "$S20_SYMLINK_B" -q

S20_SYMLINK_SETTLEMENT_STATE="$S20_VALID_ROOT/symlink-settlement-state"
S20_SYMLINK_SETTLEMENT_BIN="$S20_VALID_ROOT/symlink-settlement-bin"
S20_SYMLINK_SETTLEMENT_MARKER="$S20_VALID_ROOT/symlink-settlement-fired"
s20_new_state "$S20_SYMLINK_SETTLEMENT_STATE"
mkdir -p "$S20_SYMLINK_SETTLEMENT_BIN"
cp "$S20_VALID_BIN/gh" "$S20_SYMLINK_SETTLEMENT_BIN/gh"
cat > "$S20_SYMLINK_SETTLEMENT_BIN/git" <<S20_SYMLINK_SETTLEMENT_GIT
#!/usr/bin/env bash
settlement="$S20_SYMLINK_SETTLEMENT_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json"
if [[ -e "\$settlement" && ! -e "$S20_SYMLINK_SETTLEMENT_MARKER" ]]; then
  rm "$S20_SYMLINK_RAW"
  ln -s "$S20_SYMLINK_B" "$S20_SYMLINK_RAW"
  : > "$S20_SYMLINK_SETTLEMENT_MARKER"
fi
exec "$S20_REAL_GIT" "\$@"
S20_SYMLINK_SETTLEMENT_GIT
chmod +x "$S20_SYMLINK_SETTLEMENT_BIN/git"
s20_expect_rc "S20-ORIGIN: physical endpoint symlink swap after settlement rejected" 3 \
  "$S20_VALID_REPO" "$S20_SYMLINK_SETTLEMENT_STATE" "$S20_SYMLINK_SETTLEMENT_BIN"
if [[ "$($S20_REAL_GIT --git-dir="$S20_SYMLINK_A" rev-parse refs/heads/staging)" == "$S20_MERGE" \
    && -z "$($S20_REAL_GIT --git-dir="$S20_SYMLINK_B" for-each-ref)" ]]; then
  pass "S20-ORIGIN: after-settlement symlink swap left both physical destinations untouched"
else
  fail "S20-ORIGIN: after-settlement symlink swap reached a remote effect"
fi
rm "$S20_SYMLINK_RAW"
ln -s "$S20_SYMLINK_A" "$S20_SYMLINK_RAW"

S20_SYMLINK_EDGE_STATE="$S20_VALID_ROOT/symlink-edge-state"
S20_SYMLINK_EDGE_BIN="$S20_VALID_ROOT/symlink-edge-bin"
S20_SYMLINK_EDGE_MARKER="$S20_VALID_ROOT/symlink-edge-fired"
s20_new_state "$S20_SYMLINK_EDGE_STATE"
mkdir -p "$S20_SYMLINK_EDGE_BIN"
cp "$S20_VALID_BIN/gh" "$S20_SYMLINK_EDGE_BIN/gh"
cat > "$S20_SYMLINK_EDGE_BIN/git" <<S20_SYMLINK_EDGE_GIT
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == --force-with-lease=refs/heads/staging:* \
      && ! -e "$S20_SYMLINK_EDGE_MARKER" ]]; then
    rm "$S20_SYMLINK_RAW"
    ln -s "$S20_SYMLINK_B" "$S20_SYMLINK_RAW"
    : > "$S20_SYMLINK_EDGE_MARKER"
  fi
done
exec "$S20_REAL_GIT" "\$@"
S20_SYMLINK_EDGE_GIT
chmod +x "$S20_SYMLINK_EDGE_BIN/git"
set +e
S20_SYMLINK_EDGE_OUTPUT=$(s20_run "$S20_VALID_REPO" "$S20_SYMLINK_EDGE_STATE" "$S20_SYMLINK_EDGE_BIN")
S20_SYMLINK_EDGE_RC=$?
set -e
S20_SYMLINK_EDGE_COMMIT=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).commit_sha)' \
  "$S20_SYMLINK_EDGE_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json")
if [[ "$S20_SYMLINK_EDGE_RC" -eq 0 \
    && "$($S20_REAL_GIT --git-dir="$S20_SYMLINK_A" rev-parse refs/heads/staging)" == "$S20_SYMLINK_EDGE_COMMIT" \
    && -z "$($S20_REAL_GIT --git-dir="$S20_SYMLINK_B" for-each-ref)" ]]; then
  pass "S20-ORIGIN: last-moment symlink swap could not redirect the bound physical push"
else
  fail "S20-ORIGIN: last-moment symlink swap redirected or blocked the bound physical push"
fi
rm "$S20_SYMLINK_RAW"
mv "$S20_SYMLINK_A" "$S20_SYMLINK_RAW"
rm -rf "$S20_SYMLINK_B"

# Strict parser, original symlink root and root/repository ancestry all fail
# before evidence, startup or Git effects.
s20_reset_target
set +e
(cd "$S20_VALID_REPO" && "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 >/dev/null 2>&1); S20_USAGE_A=$?
(cd "$S20_VALID_REPO" && "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 \
  --operator-state-root relative >/dev/null 2>&1); S20_USAGE_B=$?
(cd "$S20_VALID_REPO" && "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 \
  --operator-state-root "$S20_VALID_STATE" --dry-run >/dev/null 2>&1); S20_USAGE_C=$?
set -e
S20_TYPED_SEEN="$S20_TYPED_SEEN $S20_USAGE_A $S20_USAGE_B $S20_USAGE_C"
if [[ "$S20_USAGE_A:$S20_USAGE_B:$S20_USAGE_C" == "64:64:64" ]]; then
  pass "S20-USAGE: missing, relative and mixed arguments return rc 64"
else
  fail "S20-USAGE: strict parser did not close all malformed forms"
fi
S20_USAGE_SECRET='https://example.invalid/?token=DO-NOT-LEAK-USAGE'
S20_USAGE_INJECTED_ID=$(printf 'invalid\nwatch_once story=WATCHER-STORY-1 outcome=reconciled %s' "$S20_USAGE_SECRET")
set +e
S20_USAGE_INJECTED_OUTPUT=$(cd "$S20_VALID_REPO" && "$BASH" \
  .gaai/core/scripts/delivery-daemon.sh --watch-once-story "$S20_USAGE_INJECTED_ID" \
  --operator-state-root "$S20_VALID_STATE" 2>&1)
S20_USAGE_INJECTED_RC=$?
set -e
S20_TYPED_SEEN="$S20_TYPED_SEEN $S20_USAGE_INJECTED_RC"
S20_ALL_DIAGNOSTICS="$S20_ALL_DIAGNOSTICS
$S20_USAGE_INJECTED_OUTPUT"
if [[ "$S20_USAGE_INJECTED_RC" -eq 64 \
    && "$S20_USAGE_INJECTED_OUTPUT" == "watch_once story=invalid outcome=usage_invalid" \
    && "$(printf '%s\n' "$S20_USAGE_INJECTED_OUTPUT" | wc -l | tr -d ' ')" == "1" \
    && "$S20_USAGE_INJECTED_OUTPUT" != *"$S20_USAGE_SECRET"* \
    && "$S20_USAGE_INJECTED_OUTPUT" != *"outcome=reconciled"* ]]; then
  pass "S20-USAGE: invalid Story argv cannot forge or leak a diagnostic line"
else
  fail "S20-USAGE: invalid Story argv escaped the closed usage diagnostic"
fi
S20_ROOT_LINK="$S20_VALID_ROOT/operator-state-link"
ln -s "$S20_VALID_STATE" "$S20_ROOT_LINK"
s20_expect_rc "S20-ROOT: original symlink state root rejected" 64 "$S20_VALID_REPO" "$S20_ROOT_LINK" "$S20_VALID_BIN"
S20_ANCESTOR_ROOT="$S20_VALID_ROOT/ancestor-state"
rm -rf "$S20_ANCESTOR_ROOT"; mkdir -m 700 "$S20_ANCESTOR_ROOT"
"$S20_REAL_GIT" clone --branch staging "$S20_VALID_REMOTE" "$S20_ANCESTOR_ROOT/repo" -q
s20_expect_rc "S20-ROOT: state root containing executable repo rejected" 64 \
  "$S20_ANCESTOR_ROOT/repo" "$S20_ANCESTOR_ROOT" "$S20_VALID_BIN"

# OPEN and CLOSED-unmerged are the only rc 2 class.
for S20_UNMERGED_STATE in OPEN CLOSED; do
  s20_reset_target
  S20_CASE_STATE="$S20_VALID_ROOT/unmerged-${S20_UNMERGED_STATE}"
  S20_CASE_BIN="$S20_CASE_STATE/bin"
  s20_new_state "$S20_CASE_STATE"; mkdir -p "$S20_CASE_BIN"
  cat > "$S20_CASE_BIN/gh" <<S20_UNMERGED_GH
#!/usr/bin/env bash
printf '%s\n' '{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"$S20_UNMERGED_STATE","createdAt":"2026-08-28T22:00:00Z","mergedAt":null,"baseRefName":"staging","headRefOid":"$S20_HEAD","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":null}'
S20_UNMERGED_GH
  chmod +x "$S20_CASE_BIN/gh"
  s20_expect_rc "S20-UNMERGED: $S20_UNMERGED_STATE returns rc 2" 2 \
    "$S20_VALID_REPO" "$S20_CASE_STATE" "$S20_CASE_BIN"
done

# A partial terminal tuple is never repaired opportunistically.  The target is
# otherwise exact and contains the admitted squash; only status is terminal.
s20_reset_target
S20_PARTIAL_BACKLOG="$S20_VALID_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"
# A fixture step that builds state for later assertions is reported as a named
# assertion of its own. This one runs a real scheduler write through the YAML
# boundary, and the boundary's refusals are a bare one-line diagnostic plus a
# non-zero status: under `set -e` that terminated the whole suite here with no
# FAIL line and no result summary, so the cause had to be inferred from where
# the log stopped. Capture the status, name it, and let the remaining assertions
# report as unexercised instead of vanishing.
S20_PARTIAL_SET_RC=0
"$BASH" "$S20_VALID_REPO/.gaai/core/scripts/backlog-scheduler.sh" --set-field \
  WATCHER-STORY-1 status done "$S20_PARTIAL_BACKLOG" >/dev/null || S20_PARTIAL_SET_RC=$?
if [[ "$S20_PARTIAL_SET_RC" -ne 0 ]]; then
  fail "S20-PRESTATE: fixture could not write the terminal status (scheduler exit $S20_PARTIAL_SET_RC)"
  fail "S20-PRESTATE: partial terminal tuple rejected — not exercised, fixture unavailable"
  fail "S20-PRESTATE: partial terminal tuple caused no settlement or remote mutation — not exercised, fixture unavailable"
else
  pass "S20-PRESTATE: fixture wrote the terminal status through the YAML boundary"
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" add .gaai/project/contexts/backlog/active.backlog.yaml
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" commit -m 'partial terminal fixture' -q
  S20_PARTIAL_COMMIT=$("$S20_REAL_GIT" -C "$S20_VALID_REPO" rev-parse HEAD)
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" push --force origin HEAD:staging -q
  S20_PARTIAL_STATE="$S20_VALID_ROOT/partial-state"; s20_new_state "$S20_PARTIAL_STATE"
  s20_expect_rc "S20-PRESTATE: partial terminal tuple rejected" 3 \
    "$S20_VALID_REPO" "$S20_PARTIAL_STATE" "$S20_VALID_BIN"
  if [[ ! -e "$S20_PARTIAL_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json" \
      && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_PARTIAL_COMMIT" ]]; then
    pass "S20-PRESTATE: partial terminal tuple caused no settlement or remote mutation"
  else
    fail "S20-PRESTATE: partial terminal tuple reached an effect"
  fi
fi
s20_reset_target

# Receipt byte/schema/time/mode/link falsifiers.  Canonical schema/time mutants
# are resealed so their stated cause, rather than a stale digest, is exercised.
s20_mutate_receipt() {
  local path="$1" kind="$2"
  node --input-type=module -e '
    import fs from "node:fs"; import {createHash} from "node:crypto";
    import {pathToFileURL} from "node:url";
    const [path,kind,helper,base,head,merge]=process.argv.slice(1); const {canonicalJson}=await import(pathToFileURL(helper).href);
    const hash=value=>createHash("sha256").update(value).digest("hex");
    const value=JSON.parse(fs.readFileSync(path));
    if(kind==="schema") value.private_seed="DO-NOT-LEAK-RECEIPT-SEED";
    if(kind==="time") value.created_at="2026-08-30T02:00:00Z";
    if(kind==="story") value.story_id="OTHER-STORY-IDENTITY";
    if(kind==="project") value.candidate.project_id="other/project";
    if(kind==="repository") value.candidate.repository_digest="0".repeat(64);
    if(kind==="head") value.candidate.head_sha=merge;
    if(kind==="base") value.candidate.base_sha=merge;
    if(kind==="outcome") value.outcome="fail";
    if(kind==="publication") value.publication_admitted=false;
    if(["project","repository","head","base"].includes(kind)) value.binding_digest=hash(canonicalJson(value.candidate));
    if(kind==="digest") value.receipt_digest="0".repeat(64);
    else { delete value.receipt_digest; value.receipt_digest=hash(canonicalJson(value)); }
    fs.writeFileSync(path,canonicalJson(value)+"\n");
  ' "$path" "$kind" "$S20_VALID_REPO/.gaai/core/scripts/lib/local-admission-executor.mjs" \
    "$S20_BASE" "$S20_HEAD" "$S20_MERGE"
  chmod 600 "$path"
}
for S20_RECEIPT_FAULT in schema digest time mode symlink short extra; do
  s20_reset_target
  S20_CASE_STATE="$S20_VALID_ROOT/receipt-$S20_RECEIPT_FAULT"
  s20_new_state "$S20_CASE_STATE"
  S20_CASE_RECEIPT="$S20_CASE_STATE/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
  case "$S20_RECEIPT_FAULT" in
    schema|digest|time) s20_mutate_receipt "$S20_CASE_RECEIPT" "$S20_RECEIPT_FAULT" ;;
    mode) chmod 644 "$S20_CASE_RECEIPT" ;;
    symlink) mv "$S20_CASE_RECEIPT" "$S20_CASE_RECEIPT.target"; ln -s "$S20_CASE_RECEIPT.target" "$S20_CASE_RECEIPT" ;;
    short) dd if="$S20_CASE_RECEIPT" of="$S20_CASE_RECEIPT.short" bs=1 count=31 2>/dev/null; mv "$S20_CASE_RECEIPT.short" "$S20_CASE_RECEIPT"; chmod 600 "$S20_CASE_RECEIPT" ;;
    extra) printf 'DO-NOT-LEAK-EXTRA-SEED\n' >> "$S20_CASE_RECEIPT" ;;
  esac
  s20_expect_rc "S20-RECEIPT: $S20_RECEIPT_FAULT rejected" 3 \
    "$S20_VALID_REPO" "$S20_CASE_STATE" "$S20_VALID_BIN"
done
# Identity/authority mutants retain a valid canonical receipt digest (and a
# recomputed candidate binding digest when the binding changes), so each case
# reaches its named semantic guard rather than failing at canonicalization.
for S20_IDENTITY_FAULT in story project repository head base outcome publication; do
  s20_reset_target
  S20_CASE_STATE="$S20_VALID_ROOT/receipt-identity-$S20_IDENTITY_FAULT"
  s20_new_state "$S20_CASE_STATE"
  S20_CASE_RECEIPT="$S20_CASE_STATE/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
  s20_mutate_receipt "$S20_CASE_RECEIPT" "$S20_IDENTITY_FAULT"
  s20_expect_rc "S20-RECEIPT-IDENTITY: $S20_IDENTITY_FAULT rejected" 3 \
    "$S20_VALID_REPO" "$S20_CASE_STATE" "$S20_VALID_BIN"
  if [[ ! -e "$S20_CASE_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json" \
      && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_MERGE" ]]; then
    pass "S20-RECEIPT-IDENTITY: $S20_IDENTITY_FAULT had no effect"
  else
    fail "S20-RECEIPT-IDENTITY: $S20_IDENTITY_FAULT reached settlement or target mutation"
  fi
done
# Wrong-owner construction requires privilege on most kernels.  Exercise it
# when available; otherwise record the kernel's refusal rather than weakening
# or faking the production ownership check.
s20_reset_target
S20_OWNER_STATE="$S20_VALID_ROOT/receipt-owner"; s20_new_state "$S20_OWNER_STATE"
S20_OWNER_RECEIPT="$S20_OWNER_STATE/local-admission-receipts/.local-admission-WATCHER-STORY-1-final.json"
S20_CURRENT_UID=$(id -u); S20_OTHER_UID="${GAAI_TEST_WRONG_OWNER_UID:-$((S20_CURRENT_UID + 1))}"
if chown "$S20_OTHER_UID" "$S20_OWNER_RECEIPT" 2>/dev/null; then
  s20_expect_rc "S20-RECEIPT: wrong owner rejected" 3 "$S20_VALID_REPO" "$S20_OWNER_STATE" "$S20_VALID_BIN"
else
  skip "S20-RECEIPT: wrong-owner fixture requires privilege; rerun with GAAI_TEST_WRONG_OWNER_UID=<different-uid> under root/userns"
fi

# Wrong live GitHub identities are proof failures.  Each response remains valid
# JSON and differs at only the named authority edge.
s20_gh_case() {
  local name="$1" json="$2"
  s20_reset_target
  local state="$S20_VALID_ROOT/gh-$name" bin="$S20_VALID_ROOT/gh-$name/bin"
  s20_new_state "$state"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" '\''%s'\''\n' "$json" > "$bin/gh"; chmod +x "$bin/gh"
  s20_expect_rc "S20-GITHUB: $name rejected" 3 "$S20_VALID_REPO" "$state" "$bin"
}
S20_VALID_GH_PREFIX='{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"MERGED","createdAt":"2026-08-28T22:00:00Z","mergedAt":"2026-08-29T03:00:00Z"'
s20_gh_case wrong-repo "$S20_VALID_GH_PREFIX,"'"baseRefName":"staging","headRefOid":"'$S20_HEAD'","headRepository":{"nameWithOwner":"other/repo"},"isCrossRepository":false,"mergeCommit":{"oid":"'$S20_MERGE'"}}'
s20_gh_case wrong-base "$S20_VALID_GH_PREFIX,"'"baseRefName":"production","headRefOid":"'$S20_HEAD'","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"'$S20_MERGE'"}}'
s20_gh_case wrong-head "$S20_VALID_GH_PREFIX,"'"baseRefName":"staging","headRefOid":"'$S20_BASE'","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"'$S20_MERGE'"}}'
S20_WRONG_PARENT=$(printf 'wrong parent\n' | "$S20_REAL_GIT" -C "$S20_VALID_REPO" commit-tree "$S20_HEAD_TREE" -p "$S20_MERGE")
S20_WRONG_TREE=$(printf 'wrong tree\n' | "$S20_REAL_GIT" -C "$S20_VALID_REPO" commit-tree \
  "$("$S20_REAL_GIT" -C "$S20_VALID_REPO" rev-parse "$S20_BASE^{tree}")" -p "$S20_BASE")
s20_gh_case wrong-parent "$S20_VALID_GH_PREFIX,"'"baseRefName":"staging","headRefOid":"'$S20_HEAD'","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"'$S20_WRONG_PARENT'"}}'
s20_gh_case wrong-tree "$S20_VALID_GH_PREFIX,"'"baseRefName":"staging","headRefOid":"'$S20_HEAD'","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"'$S20_WRONG_TREE'"}}'

# The exact squash may be locally valid while absent from the configured target
# lineage; that target divergence is still a proof failure.
s20_reset_target
"$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" update-ref refs/heads/staging "$S20_HEAD"
"$S20_REAL_GIT" -C "$S20_VALID_REPO" fetch origin staging -q
"$S20_REAL_GIT" -C "$S20_VALID_REPO" reset --hard origin/staging -q
s20_exact_vendor_modes || true
S20_DIVERGENT_STATE="$S20_VALID_ROOT/divergent-state"; s20_new_state "$S20_DIVERGENT_STATE"
s20_expect_rc "S20-GITHUB: merge absent from target lineage rejected" 3 \
  "$S20_VALID_REPO" "$S20_DIVERGENT_STATE" "$S20_VALID_BIN"
s20_reset_target

# Bounded GitHub and lock waits are known pre-effect failures (rc 4).
s20_reset_target
S20_TIMEOUT_STATE="$S20_VALID_ROOT/timeout-state"; S20_TIMEOUT_BIN="$S20_TIMEOUT_STATE/bin"
s20_new_state "$S20_TIMEOUT_STATE"; mkdir -p "$S20_TIMEOUT_BIN"
printf '#!/usr/bin/env bash\nsleep 3\n' > "$S20_TIMEOUT_BIN/gh"; chmod +x "$S20_TIMEOUT_BIN/gh"
set +e
S20_TIMEOUT_OUTPUT=$(cd "$S20_VALID_REPO" && PATH="$S20_TIMEOUT_BIN:$PATH" GAAI_GITHUB_API_TIMEOUT=1 \
  "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 \
  --operator-state-root "$S20_TIMEOUT_STATE" 2>&1); S20_TIMEOUT_RC=$?
set -e
S20_TYPED_SEEN="$S20_TYPED_SEEN $S20_TIMEOUT_RC"; S20_ALL_DIAGNOSTICS="$S20_ALL_DIAGNOSTICS
$S20_TIMEOUT_OUTPUT"
[[ "$S20_TIMEOUT_RC" -eq 4 ]] && pass "S20-TIMEOUT: bounded GitHub wait returns rc 4" || fail "S20-TIMEOUT: GitHub wait rc $S20_TIMEOUT_RC"
python3 - "$S20_TIMEOUT_STATE/.staging.lock" <<'S20_LOCK' &
import fcntl,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(3)
S20_LOCK
S20_LOCK_PID=$!; sleep .2
set +e
S20_LOCK_OUTPUT=$(cd "$S20_VALID_REPO" && PATH="$S20_VALID_BIN:$PATH" GAAI_WATCH_ONCE_LOCK_TIMEOUT=1 \
  "$BASH" .gaai/core/scripts/delivery-daemon.sh --watch-once-story WATCHER-STORY-1 \
  --operator-state-root "$S20_TIMEOUT_STATE" 2>&1); S20_LOCK_RC=$?
set -e
wait "$S20_LOCK_PID" || true
S20_TYPED_SEEN="$S20_TYPED_SEEN $S20_LOCK_RC"; S20_ALL_DIAGNOSTICS="$S20_ALL_DIAGNOSTICS
$S20_LOCK_OUTPUT"
[[ "$S20_LOCK_RC" -eq 4 ]] && pass "S20-TIMEOUT: bounded lock wait returns rc 4" || fail "S20-TIMEOUT: lock wait rc $S20_LOCK_RC"
S20_LINK_LOCK_STATE="$S20_VALID_ROOT/link-lock-state"; s20_new_state "$S20_LINK_LOCK_STATE"
: > "$S20_LINK_LOCK_STATE/.staging.lock"; chmod 600 "$S20_LINK_LOCK_STATE/.staging.lock"
ln "$S20_LINK_LOCK_STATE/.staging.lock" "$S20_LINK_LOCK_STATE/.staging.lock.alias"
s20_expect_rc "S20-LOCK: multi-link lock entry rejected" 4 \
  "$S20_VALID_REPO" "$S20_LINK_LOCK_STATE" "$S20_VALID_BIN"

# Dirty checkout and effect-edge helper/lock swaps fail before settlement.
s20_reset_target
S20_DIRTY_STATE="$S20_VALID_ROOT/dirty-state"; s20_new_state "$S20_DIRTY_STATE"
printf 'dirty\n' > "$S20_VALID_REPO/untracked-watcher-seed"
s20_expect_rc "S20-DRIFT: dirty checkout rejected" 4 "$S20_VALID_REPO" "$S20_DIRTY_STATE" "$S20_VALID_BIN"
rm -f "$S20_VALID_REPO/untracked-watcher-seed"
# rev-parse --git-path may return a path relative to the repository.  Invoke an
# absolute daemon from an unrelated CWD and prove both bisect and rebase state
# remain visible to the watcher before settlement or push.
S20_UNRELATED_CWD="$S20_VALID_ROOT/unrelated-cwd"; mkdir -p "$S20_UNRELATED_CWD"
for S20_GIT_MARKER in BISECT_LOG rebase-apply; do
  s20_reset_target
  S20_MARKER_STATE="$S20_VALID_ROOT/marker-$S20_GIT_MARKER"; s20_new_state "$S20_MARKER_STATE"
  S20_MARKER_PATH=$("$S20_REAL_GIT" -C "$S20_VALID_REPO" rev-parse --git-path "$S20_GIT_MARKER")
  [[ "$S20_MARKER_PATH" == /* ]] || S20_MARKER_PATH="$S20_VALID_REPO/$S20_MARKER_PATH"
  if [[ "$S20_GIT_MARKER" == rebase-apply ]]; then mkdir -p "$S20_MARKER_PATH"; else : > "$S20_MARKER_PATH"; fi
  set +e
  S20_MARKER_OUTPUT=$(cd "$S20_UNRELATED_CWD" && PATH="$S20_VALID_BIN:$PATH" \
    "$BASH" "$S20_VALID_REPO/.gaai/core/scripts/delivery-daemon.sh" \
    --watch-once-story WATCHER-STORY-1 --operator-state-root "$S20_MARKER_STATE" 2>&1)
  S20_MARKER_RC=$?
  set -e
  S20_TYPED_SEEN="$S20_TYPED_SEEN $S20_MARKER_RC"; S20_ALL_DIAGNOSTICS="$S20_ALL_DIAGNOSTICS
$S20_MARKER_OUTPUT"
  if [[ "$S20_MARKER_RC" -eq 4 \
      && ! -e "$S20_MARKER_STATE/external-merge-settlements/.external-merge-WATCHER-STORY-1.json" \
      && "$("$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" rev-parse refs/heads/staging)" == "$S20_MERGE" ]]; then
    pass "S20-GIT-PATH: unrelated-CWD $S20_GIT_MARKER rejected before effect"
  else
    fail "S20-GIT-PATH: unrelated-CWD $S20_GIT_MARKER escaped detection"
  fi
  if [[ "$S20_GIT_MARKER" == rebase-apply ]]; then rmdir "$S20_MARKER_PATH"; else rm -f "$S20_MARKER_PATH"; fi
done
# A target advance before entry makes the clean checkout stale and is rejected
# before receipt/GitHub evidence.  A target advance on the second GitHub call
# is the corresponding effect-edge backlog race.
S20_ADVANCE_TREE=$("$S20_REAL_GIT" -C "$S20_VALID_REPO" rev-parse "$S20_MERGE^{tree}")
S20_ADVANCE=$(printf 'unrelated target advance\n' | "$S20_REAL_GIT" -C "$S20_VALID_REPO" commit-tree "$S20_ADVANCE_TREE" -p "$S20_MERGE")
"$S20_REAL_GIT" -C "$S20_VALID_REPO" push origin "$S20_ADVANCE:refs/heads/advance-fixture" -q
s20_reset_target
"$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" update-ref refs/heads/staging "$S20_ADVANCE"
S20_STALE_STATE="$S20_VALID_ROOT/stale-state"; s20_new_state "$S20_STALE_STATE"
s20_expect_rc "S20-DRIFT: stale exact-target checkout rejected" 4 \
  "$S20_VALID_REPO" "$S20_STALE_STATE" "$S20_VALID_BIN"
s20_reset_target
for S20_RACE_KIND in helper lock pr; do
  s20_reset_target
  S20_CASE_STATE="$S20_VALID_ROOT/effect-$S20_RACE_KIND"; S20_CASE_BIN="$S20_CASE_STATE/bin"
  s20_new_state "$S20_CASE_STATE"; mkdir -p "$S20_CASE_BIN"
  S20_CASE_COUNT="$S20_CASE_STATE/count"
  cat > "$S20_CASE_BIN/gh" <<S20_EFFECT_GH
#!/usr/bin/env bash
count=0; [[ -r "$S20_CASE_COUNT" ]] && read -r count < "$S20_CASE_COUNT"; count=\$((count+1)); printf '%s\n' "\$count" > "$S20_CASE_COUNT"
if [[ "\$count" -eq 2 ]]; then
  case "$S20_RACE_KIND" in
    helper) printf '\n# DO-NOT-LEAK-HELPER-SEED\n' >> "$S20_VALID_REPO/.gaai/core/scripts/backlog-scheduler.sh" ;;
    lock) mv "$S20_CASE_STATE/.staging.lock" "$S20_CASE_STATE/.staging.lock.old"; : > "$S20_CASE_STATE/.staging.lock"; chmod 600 "$S20_CASE_STATE/.staging.lock" ;;
  esac
fi
if [[ "$S20_RACE_KIND" == pr && "\$count" -eq 2 ]]; then head="$S20_BASE"; else head="$S20_HEAD"; fi
printf '%s\n' '{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"MERGED","createdAt":"2026-08-28T22:00:00Z","mergedAt":"2026-08-29T03:00:00Z","baseRefName":"staging","headRefOid":"'"\$head"'","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"$S20_MERGE"}}'
S20_EFFECT_GH
  chmod +x "$S20_CASE_BIN/gh"
  if [[ "$S20_RACE_KIND" == pr ]]; then S20_EXPECT=3; else S20_EXPECT=4; fi
  s20_expect_rc "S20-EFFECT: $S20_RACE_KIND race rejected" "$S20_EXPECT" "$S20_VALID_REPO" "$S20_CASE_STATE" "$S20_CASE_BIN"
  "$S20_REAL_GIT" -C "$S20_VALID_REPO" checkout -- .gaai/core/scripts/backlog-scheduler.sh
done
s20_reset_target
S20_BACKLOG_RACE_STATE="$S20_VALID_ROOT/effect-backlog"; S20_BACKLOG_RACE_BIN="$S20_BACKLOG_RACE_STATE/bin"
s20_new_state "$S20_BACKLOG_RACE_STATE"; mkdir -p "$S20_BACKLOG_RACE_BIN"
cat > "$S20_BACKLOG_RACE_BIN/gh" <<S20_BACKLOG_RACE_GH
#!/usr/bin/env bash
count=0; [[ -r "$S20_BACKLOG_RACE_STATE/count" ]] && read -r count < "$S20_BACKLOG_RACE_STATE/count"
count=\$((count+1)); printf '%s\n' "\$count" > "$S20_BACKLOG_RACE_STATE/count"
[[ "\$count" -eq 2 ]] && "$S20_REAL_GIT" --git-dir="$S20_VALID_REMOTE" update-ref refs/heads/staging "$S20_ADVANCE"
printf '%s\n' '{"url":"https://github.com/example/watcher/pull/20","number":20,"state":"MERGED","createdAt":"2026-08-28T22:00:00Z","mergedAt":"2026-08-29T03:00:00Z","baseRefName":"staging","headRefOid":"$S20_HEAD","headRepository":{"nameWithOwner":"example/watcher"},"isCrossRepository":false,"mergeCommit":{"oid":"$S20_MERGE"}}'
S20_BACKLOG_RACE_GH
chmod +x "$S20_BACKLOG_RACE_BIN/gh"
s20_expect_rc "S20-EFFECT: target/backlog race rejected" 4 \
  "$S20_VALID_REPO" "$S20_BACKLOG_RACE_STATE" "$S20_BACKLOG_RACE_BIN"
s20_reset_target

# The public result vocabulary is closed and no adversarial seed/evidence value
# may appear in any collected diagnostic.
for S20_EXPECTED_RC in 0 2 3 4 64 75; do
  if [[ " $S20_TYPED_SEEN " == *" $S20_EXPECTED_RC "* ]]; then
    pass "S20-TYPED: rc $S20_EXPECTED_RC observed"
  else
    fail "S20-TYPED: rc $S20_EXPECTED_RC missing"
  fi
done
if printf '%s\n' "$S20_ALL_DIAGNOSTICS" | grep -Eq \
    'DO-NOT-LEAK|https://github\.com|[0-9a-f]{40}|[0-9a-f]{64}|local-admission-receipts|external-merge-settlements'; then
  fail "S20-PRIVACY: adversarial value leaked in a typed diagnostic"
else
  pass "S20-PRIVACY: all typed diagnostics remained names/reasons only"
fi

# Every configured origin used by this corpus must resolve to a bare repository
# below the invocation's private mktemp root. A URL or shared-repository remote
# makes the test itself fail, even when the watcher assertions otherwise pass.
S20_FIXTURE_REAL=$(cd -P "$FIXTURE_DIR" && pwd -P)
S20_REMOTE_CONFINEMENT=ok
S20_REMOTE_COUNT=0
while IFS= read -r S20_GIT_DIR; do
  S20_REPO_DIR=${S20_GIT_DIR%/.git}
  while IFS= read -r S20_REMOTE_URL; do
    [[ -n "$S20_REMOTE_URL" ]] || continue
    S20_REMOTE_COUNT=$((S20_REMOTE_COUNT + 1))
    case "$S20_REMOTE_URL" in
      /*)
        S20_REMOTE_REAL=$(cd -P "$S20_REMOTE_URL" 2>/dev/null && pwd -P) || {
          S20_REMOTE_CONFINEMENT=failed
          continue
        }
        [[ "$S20_REMOTE_REAL" == "$S20_FIXTURE_REAL"/* ]] \
          || S20_REMOTE_CONFINEMENT=failed
        [[ "$(git --git-dir="$S20_REMOTE_REAL" rev-parse --is-bare-repository 2>/dev/null || true)" == true ]] \
          || S20_REMOTE_CONFINEMENT=failed
        ;;
      *) S20_REMOTE_CONFINEMENT=failed ;;
    esac
  done < <(git -C "$S20_REPO_DIR" remote get-url --all origin 2>/dev/null || true)
done < <(find "$FIXTURE_DIR" -type d -name .git -prune)
if [[ "$S20_REMOTE_CONFINEMENT" == ok && "$S20_REMOTE_COUNT" -gt 0 ]]; then
  pass "FIXTURE: every origin is a bare remote below the private mktemp root"
else
  fail "FIXTURE: a remote escaped the private mktemp root or was not bare"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
  exit 0
else
  exit 1
fi
