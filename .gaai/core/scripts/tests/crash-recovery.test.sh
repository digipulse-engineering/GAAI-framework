#!/usr/bin/env bash
# Forward-only recovery coordinator contract and fault matrix.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
DAEMON="$ROOT/.gaai/core/scripts/delivery-daemon.sh"
CLASSIFIER="$ROOT/.gaai/core/scripts/lib/stuck-classifier.sh"
TEST_BASH="${GAAI_TEST_BASH:-$BASH}"
PASS=0
FAIL=0
FAILURES=""
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gaai-forward-recovery.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILURES="${FAILURES}${1}"$'\n'
  printf '  FAIL: %s\n' "$1"
}
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

resolved_current=$(python3 - "$TEST_BASH" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)
resolved_running=$(python3 - "$BASH" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)
printf 'interpreter=%s version=%s\n' "$resolved_running" "$BASH_VERSION"
expect "selected interpreter is the running interpreter" test "$resolved_current" = "$resolved_running"

HARNESS="$TMP/coordinator.sh"
awk '/^_forward_sha256\(\)/{on=1} /^exceeded_stories\(\)/{on=0} on{print}' "$DAEMON" > "$HARNESS"
awk '/^_reconcile_story_file_from_staging\(\)/{on=1} /^# ── PR merge watcher/{on=0} on{print}' "$DAEMON" >> "$HARNESS"
awk '/^_attempt_secret_create\(\)/{on=1} /^# ── Launch 3phase/{on=0} on{print}' "$DAEMON" >> "$HARNESS"
# shellcheck source=/dev/null
source "$CLASSIFIER"
# shellcheck source=/dev/null
source "$ROOT/.gaai/core/scripts/lib/commit-retry-containment.sh"
# shellcheck source=/dev/null
source "$HARNESS"

AUTH_PROJECT="$TMP/auth-project"
AUTH_HARNESS="$AUTH_PROJECT/.gaai/core/scripts/daemon-dispatch.sh"
TRUSTED_CALLER="$AUTH_PROJECT/.gaai/core/scripts/delivery-daemon.sh"
FOREIGN_CALLER="$TMP/foreign-recovery-caller.sh"
mkdir -p "$(dirname "$AUTH_HARNESS")"
awk '/^_lifecycle_assert_base_held_assets\(\)/{on=1} /^_lifecycle_run_manifest\(\)/{on=0} on{print}' \
  "$ROOT/.gaai/core/scripts/daemon-dispatch.sh" > "$AUTH_HARNESS"
printf '%s\n' \
  'trusted_recovery_caller() {' \
  '  GAAI_LIFECYCLE_CALLER_ASSET=.gaai/core/scripts/delivery-daemon.sh _lifecycle_recovery_caller_authenticated' \
  '}' \
  'trusted_through_foreign() {' \
  '  foreign_recovery_intermediary' \
  '}' > "$TRUSTED_CALLER"
printf '%s\n' \
  'foreign_recovery_intermediary() {' \
  '  GAAI_LIFECYCLE_CALLER_ASSET=.gaai/core/scripts/delivery-daemon.sh _lifecycle_recovery_caller_authenticated' \
  '}' \
  'spoof_recovery_caller() {' \
  '  GAAI_LIFECYCLE_CALLER_ASSET=.gaai/core/scripts/delivery-daemon.sh _lifecycle_recovery_caller_authenticated' \
  '}' > "$FOREIGN_CALLER"
# shellcheck source=/dev/null
source "$AUTH_HARNESS"
# shellcheck source=/dev/null
source "$TRUSTED_CALLER"
# shellcheck source=/dev/null
source "$FOREIGN_CALLER"
PROJECT_DIR="$AUTH_PROJECT"
expect "immediate delivery-daemon caller is authenticated" trusted_recovery_caller
if trusted_through_foreign; then
  fail "foreign intermediary cannot borrow a later trusted daemon frame"
else
  pass "foreign intermediary cannot borrow a later trusted daemon frame"
fi
if spoof_recovery_caller; then
  fail "canonical caller environment from a foreign source is rejected"
else
  pass "canonical caller environment from a foreign source is rejected"
fi

legacy='check_stale_in_progress|crash_recovery_scan|_recovery_commit_story_phase_drift|_recovery_reconcile_crash_drift|_recovery_revert_refined|_recovery_set_status|_recovery_relaunch|_recovery_resolve_worktree|classify_stuck_story|worktree_recovery_failed'
if rg -n "$legacy" "$DAEMON" "$CLASSIFIER" >/dev/null 2>&1; then
  fail "legacy recovery implementation is absent"
else
  pass "legacy recovery implementation is absent"
fi
if rg -n 'forward_recovery_scan[[:space:]]*\|\|[[:space:]]*true|cycle_orphan_lock_scan[[:space:]]*\|\|[[:space:]]*true' "$DAEMON" >/dev/null 2>&1; then
  fail "forward callers propagate failures"
else
  pass "forward callers propagate failures"
fi

LOCK_DIR="$TMP/locks"
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
GAAI_WORKTREES_BASE="$TMP/worktrees"
mkdir -p "$GAAI_WORKTREES_BASE"
TARGET_BRANCH=staging
PROJECT_DIR="$TMP/repo"
REPO_ROOT="$PROJECT_DIR"
BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"
BACKLOG="$BACKLOG_FILE"

out=$(_forward_worktree_state ETEST true); rc=$?
expect "absent first-claim worktree is typed absent_new" test "$rc:$out" = "0:absent_new"
out=$(_forward_worktree_state ETEST false); rc=$?
expect "absent recovery worktree is unknown and blocking" test "$rc:$out" = "1:unknown"

mkdir -p "$GAAI_WORKTREES_BASE/ETEST-workspace"
git -C "$GAAI_WORKTREES_BASE/ETEST-workspace" init -q
git -C "$GAAI_WORKTREES_BASE/ETEST-workspace" config user.email test@example.invalid
git -C "$GAAI_WORKTREES_BASE/ETEST-workspace" config user.name test
printf 'base\n' > "$GAAI_WORKTREES_BASE/ETEST-workspace/base.txt"
git -C "$GAAI_WORKTREES_BASE/ETEST-workspace" add base.txt
git -C "$GAAI_WORKTREES_BASE/ETEST-workspace" commit -qm base
_check_worktree_integrity() { return 0; }
out=$(_forward_worktree_state ETEST false); rc=$?
expect "existing rc0 worktree is verified" test "$rc:$out" = "0:verified"

CHECK_CALLS=0
_check_worktree_integrity() {
  CHECK_CALLS=$((CHECK_CALLS + 1))
  return 1
}
RECOVER_CALLS=0
_recover_worktree_safe_base() { RECOVER_CALLS=$((RECOVER_CALLS + 1)); return 0; }
out=$(_forward_worktree_state ETEST false); rc=$?
expect "recoverable probe is non-mutating before target admission" \
  test "$rc:$out:$RECOVER_CALLS" = "1:recoverable:0"

_check_worktree_integrity() { return 2; }
out=$(_forward_worktree_state ETEST false); rc=$?
expect "fresh rc2 is typed unrecoverable" test "$rc:$out" = "2:unrecoverable"

git init --bare "$TMP/origin.git" >/dev/null
git init "$PROJECT_DIR" >/dev/null
git -C "$PROJECT_DIR" config user.email test@example.invalid
git -C "$PROJECT_DIR" config user.name test
git -C "$PROJECT_DIR" remote add origin "$TMP/origin.git"
git -C "$PROJECT_DIR" remote set-url --push origin "$TMP/origin.git"
[[ "$(git -C "$PROJECT_DIR" remote get-url --push origin)" == "$TMP/origin.git" ]] || exit 1
mkdir -p "$(dirname "$BACKLOG_FILE")"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_backlog() {
  local status="$1" phase="$2"
  mkdir -p "$(dirname "$BACKLOG_FILE")"
  {
    printf 'items:\n'
    printf -- '- id: ETEST\n'
    printf '  status: %s\n' "$status"
    printf '  phase_status: %s\n' "$phase"
    printf '  started_at: "%s"\n' "$started"
  } > "$BACKLOG_FILE"
  git -C "$PROJECT_DIR" add "$BACKLOG_REL"
  git -C "$PROJECT_DIR" commit -m state >/dev/null
  git -C "$PROJECT_DIR" push -f origin HEAD:staging >/dev/null
}
write_backlog in_progress not_started
expect "exact target classify succeeds" _forward_classify ETEST postclaim absent_new false
expect "postclaim absent_new is resumable" test "$_FORWARD_ACTION:$_FORWARD_REASON" = "resume:resumable"
rm -f "$_FORWARD_SNAPSHOT"

origin_url=$(git -C "$PROJECT_DIR" remote get-url origin)
git -C "$PROJECT_DIR" remote set-url origin "$TMP/missing.git"
if _forward_classify ETEST postclaim absent_new false; then
  fail "fetch failure cannot use cached target authority"
  rm -f "${_FORWARD_SNAPSHOT:-}"
else
  pass "fetch failure cannot use cached target authority"
fi
git -C "$PROJECT_DIR" remote set-url origin "$origin_url"

write_backlog refined not_started
expect "empty valid recovery scan is a closed no-op" forward_recovery_scan
ready_after_empty=false
if forward_recovery_scan; then ready_after_empty=true; fi
expect "empty recovery scan permits the ready-work path to continue" \
  test "$ready_after_empty" = true
if forward_recovery_scan --only-sid '../escape'; then
  fail "invalid only-sid is rejected before path use"
else
  pass "invalid only-sid is rejected before path use"
fi
for invalid_sid in '../escape' $'ENEW\nLINE' 'bad!'; do
  invalid_key=$(printf '%s' "$invalid_sid" | shasum -a 256 | awk '{print $1}')
  before_names=$(find "$LOCK_DIR" -maxdepth 1 -mindepth 1 -print | sort)
  evidence_rc=0; lock_rc=0; context_rc=0
  _forward_evidence "$invalid_sid" blocked invalid_record none \
    0000000000000000000000000000000000000000000000000000000000000000 \
    0000000000000000000000000000000000000000000000000000000000000000 \
    none >"$TMP/invalid-${invalid_key}.out" 2>&1 || evidence_rc=$?
  _forward_lock_state "$invalid_sid" >/dev/null 2>&1 || lock_rc=$?
  _forward_context_path "$invalid_sid" >/dev/null 2>&1 || context_rc=$?
  after_names=$(find "$LOCK_DIR" -maxdepth 1 -mindepth 1 -print | sort)
  if [[ "$evidence_rc:$lock_rc:$context_rc" == 1:1:1 \
      && "$before_names" == "$after_names" \
      && ! -s "$TMP/invalid-${invalid_key}.out" ]]; then
    pass "invalid Story identity is rejected before path/PID/evidence"
  else
    fail "invalid Story identity reached path/PID/evidence"
  fi
done

python3 - "$BACKLOG_FILE" <<'PY'
import sys
path = sys.argv[1]
raw = open(path).read()
open(path, "w").write(raw + raw.split("items:\n", 1)[1])
PY
git -C "$PROJECT_DIR" add "$BACKLOG_REL"
git -C "$PROJECT_DIR" commit -m duplicate >/dev/null
git -C "$PROJECT_DIR" push -f origin HEAD:staging >/dev/null
if forward_recovery_scan; then
  fail "duplicate Story identity blocks scan"
else
  pass "duplicate Story identity blocks scan"
fi

log() { :; }
mkdir -p "$TMP/absent"
target_source=$(git -C "$PROJECT_DIR" rev-parse origin/staging)
if _reconcile_story_file_from_staging ETEST "$TMP/absent/missing" "$target_source"; then
  fail "absent recovery reconcile is rejected"
else
  [[ "$?" -eq 2 ]] && pass "absent recovery reconcile is rejected" || fail "absent recovery reconcile rc"
fi
expect "bound first-claim absence is admitted" _reconcile_story_file_from_staging \
  ETEST "$TMP/absent/missing" "$target_source" true

# Composition falsifier: a pre-claim absent_new observation must not survive a
# later verified post-claim check. If that verified worktree disappears before
# reconcile, the allow-absence decision comes only from post_integrity and the
# launch boundary remains closed.
mkdir -p "$TMP/post-verified-disappears"
rmdir "$TMP/post-verified-disappears"
_pre_integrity=absent_new
_post_integrity=verified
composition_rc=0
_reconcile_story_file_from_staging ETEST "$TMP/post-verified-disappears" \
  "$target_source" \
  "$([[ "$_post_integrity" == absent_new ]] && printf true || printf false)" \
  || composition_rc=$?
if [[ "$composition_rc" -le 1 ]]; then
  : > "$TMP/composition-launched"
fi
if [[ "$composition_rc" -eq 2 && ! -e "$TMP/composition-launched" ]]; then
  pass "post-verified disappearance blocks reconcile and launch"
else
  fail "stale pre-claim absence authorized a vanished post-claim worktree"
fi
python3 - "$DAEMON" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("# Fresh pre-claim admission from the configured target.")
end = text.index("# ── Route: 3phase", start)
main = text[start:end]
call_start = main.index('_reconcile_story_file_from_staging "$story_id" "$_pre_wt" "$_post_source"')
call_end = main.index("|| _story_reconcile_rc=$?", call_start)
call = main[call_start:call_end]
if '"$_post_allow_absent"' not in call:
    raise SystemExit(1)
if '"$_pre_integrity" == absent_new' in call:
    raise SystemExit(1)
PY
expect "main reconcile derives absent_new only from immediate post-claim integrity" test "$?" -eq 0
mkdir -p "$TMP/unborn"
git -C "$TMP/unborn" init >/dev/null
if _reconcile_story_file_from_staging ETEST "$TMP/unborn" "$target_source"; then
  fail "unborn worktree is preserved and rejected"
else
  rc=$?
  if [[ "$rc" -eq 2 && -d "$TMP/unborn/.git" ]]; then
    pass "unborn worktree is preserved and rejected"
  else
    fail "unborn worktree preservation"
  fi
fi

make_preservation_repo() {
  local sid="$1" wt
  wt="$GAAI_WORKTREES_BASE/${sid}-workspace"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" config user.email test@example.invalid
  git -C "$wt" config user.name test
  printf 'preserve\n' > "$wt/evidence.txt"
  git -C "$wt" add evidence.txt
  git -C "$wt" commit -qm base
}
make_preservation_repo EDIRTY
printf 'dirty\n' >> "$GAAI_WORKTREES_BASE/EDIRTY-workspace/evidence.txt"
make_preservation_repo EUNTRACKED
printf 'untracked\n' > "$GAAI_WORKTREES_BASE/EUNTRACKED-workspace/untracked.txt"
mkdir -p "$GAAI_WORKTREES_BASE/EUNBORN-workspace"
git -C "$GAAI_WORKTREES_BASE/EUNBORN-workspace" init -q
printf 'unborn\n' > "$GAAI_WORKTREES_BASE/EUNBORN-workspace/evidence.txt"
make_preservation_repo ECORRUPT
corrupt_head=$(git -C "$GAAI_WORKTREES_BASE/ECORRUPT-workspace" rev-parse HEAD)
corrupt_object="$GAAI_WORKTREES_BASE/ECORRUPT-workspace/.git/objects/${corrupt_head:0:2}/${corrupt_head:2}"
mv "$corrupt_object" "${corrupt_object}.missing"
for sid in EDIRTY EUNTRACKED EUNBORN ECORRUPT; do
  preserve_rc=0
  _forward_worktree_state "$sid" false >/dev/null || preserve_rc=$?
  if [[ "$preserve_rc" -ne 0 \
      && -d "$GAAI_WORKTREES_BASE/${sid}-workspace" \
      && -e "$GAAI_WORKTREES_BASE/${sid}-workspace/evidence.txt" ]]; then
    pass "$sid evidence is preserved and blocks recovery"
  else
    fail "$sid evidence was removed or admitted"
  fi
done
python3 - "$DAEMON" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
span = text[text.index("_forward_worktree_state()"):text.index("exceeded_stories()")]
if "worktree remove --force" in span or "rm -rf" in span:
    raise SystemExit(1)
PY
expect "forward coordinator contains no force removal path" test "$?" -eq 0

python3 - "$DAEMON" <<'PY'
import re, sys
text = open(sys.argv[1]).read()

recovery = text[text.index('_forward_relaunch() {'):text.index('_forward_retained_settle() {')]
main_start = text.index('    if ! forward_context_remove "$_claim_context"')
main_end = text.index('\n    fi', text.index(
    '    if ! launch_3phase_in_tmux "$story_id" "$_trace_id"', main_start
))
main = text[main_start:main_end]

def ordered(span, needles):
    cursor = -1
    for needle in needles:
        cursor = span.find(needle, cursor + 1)
        if cursor < 0:
            return False
    return True

recovery_order = ordered(recovery, (
    '_forward_retire_dead_lock "$sid" "$lock_pid"',
    'forward_context_remove "$context" "$expected_context_digest"',
    'increment_retry "$sid"',
    'launch_3phase_in_tmux "$sid" "$trace_id"',
))
main_order = ordered(main, (
    'forward_context_remove "$_claim_context" "$_claim_context_digest"',
    'increment_retry "$story_id"',
    'launch_3phase_in_tmux "$story_id" "$_trace_id"',
))
restores = (
    '_forward_restore_context_row "$context" "$row"' in recovery
    and '_forward_restore_context_row "$_claim_context" "$_claim_row"' in main
)
if not recovery_order or not main_order or not restores \
        or len(re.findall(r'\bincrement_retry "\$', text)) != 2:
    raise SystemExit(1)
PY
expect "pre-spawn order retires cleanup, restores failed retry, and never retries elsewhere" \
  test "$?" -eq 0

(
  close_source=1111111111111111111111111111111111111111
  close_blob=2222222222222222222222222222222222222222
  close_record=$(printf '3%.0s' $(seq 1 64))
  close_context=$(printf '4%.0s' $(seq 1 64))
  close_source_digest=$(printf '5%.0s' $(seq 1 64))
  retry_calls=0; spawn_calls=0; MAX_CONCURRENT=1
  mkdir -p "$GAAI_WORKTREES_BASE/ECLOSE-workspace"
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_SOURCE="$close_source"; _FORWARD_BLOB="$close_blob"
    _FORWARD_RECORD_DIGEST="$close_record"; _FORWARD_SOURCE_DIGEST="$close_source_digest"
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_SNAPSHOT="$TMP/close-snapshot"
    : > "$_FORWARD_SNAPSHOT"
  }
  forward_context_read(){
    printf '%s\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s\n' \
      ECLOSE "$close_source" "$close_blob" "$close_record" "$close_context"
  }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }
  active_count(){ printf '0\n'; }
  has_exceeded_retries(){ return 1; }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _reconcile_story_file_from_staging(){ return 0; }
  forward_context_remove(){ return 1; }
  increment_retry(){ retry_calls=$(( retry_calls + 1 )); }
  launch_3phase_in_tmux(){ spawn_calls=$(( spawn_calls + 1 )); }
  close_rc=0
  _forward_relaunch ECLOSE "$TMP/close-context" "$close_context" || close_rc=$?
  printf '%s:%s:%s\n' "$close_rc" "$retry_calls" "$spawn_calls" > "$TMP/close-result"
)
expect "context close failure occurs before retry and spawn" \
  test "$(cat "$TMP/close-result")" = "1:0:0"

printf '\nPre-spawn context settlement fault matrix\n'
(
  settle_source=1111111111111111111111111111111111111111
  settle_blob=2222222222222222222222222222222222222222
  settle_record=$(printf '3%.0s' $(seq 1 64))
  settle_context_digest=$(printf '4%.0s' $(seq 1 64))
  settle_source_digest=$(printf '5%.0s' $(seq 1 64))
  settle_row=$(printf '%s\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s' \
    ESETTLE "$settle_source" "$settle_blob" "$settle_record" \
    "$settle_context_digest")
  retry_calls=0; spawn_calls=0; MAX_CONCURRENT=1
  settle_context="$TMP/settle-recovery-context"
  : > "$settle_context"
  mkdir -p "$GAAI_WORKTREES_BASE/ESETTLE-workspace"
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_SOURCE="$settle_source"; _FORWARD_BLOB="$settle_blob"
    _FORWARD_RECORD_DIGEST="$settle_record"; _FORWARD_SOURCE_DIGEST="$settle_source_digest"
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_SNAPSHOT="$TMP/settle-snapshot"
    : > "$_FORWARD_SNAPSHOT"
  }
  forward_context_read(){ printf '%s\n' "$settle_row"; }
  forward_context_remove(){ rm -f "$1"; }
  forward_context_install(){ : > "$1"; }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }
  active_count(){ printf '0\n'; }
  has_exceeded_retries(){ return 1; }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _reconcile_story_file_from_staging(){ return 0; }
  increment_retry(){ retry_calls=$((retry_calls + 1)); return 1; }
  launch_3phase_in_tmux(){ spawn_calls=$((spawn_calls + 1)); }
  settle_rc=0
  _forward_relaunch ESETTLE "$settle_context" "$settle_context_digest" || settle_rc=$?
  printf '%s:%s:%s:%s\n' "$settle_rc" \
    "$([[ -e "$settle_context" ]] && printf present || printf absent)" \
    "$retry_calls" "$spawn_calls" > "$TMP/settle-recovery-retry-result"
)
printf '  recovery retry-failure observed=%s expected=1:present:1:0\n' \
  "$(cat "$TMP/settle-recovery-retry-result")"
expect "recovery retry persistence failure retains the exact context without spawn" \
  test "$(cat "$TMP/settle-recovery-retry-result")" = "1:present:1:0"

(
  settle_source=1111111111111111111111111111111111111111
  settle_blob=2222222222222222222222222222222222222222
  settle_record=$(printf '3%.0s' $(seq 1 64))
  settle_context_digest=$(printf '4%.0s' $(seq 1 64))
  settle_source_digest=$(printf '5%.0s' $(seq 1 64))
  settle_row=$(printf '%s\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s' \
    ESETTLE "$settle_source" "$settle_blob" "$settle_record" \
    "$settle_context_digest")
  retry_calls=0; spawn_calls=0; MAX_CONCURRENT=1
  settle_context="$TMP/settle-recovery-spawn-context"
  : > "$settle_context"
  mkdir -p "$GAAI_WORKTREES_BASE/ESETTLE-workspace"
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_SOURCE="$settle_source"; _FORWARD_BLOB="$settle_blob"
    _FORWARD_RECORD_DIGEST="$settle_record"; _FORWARD_SOURCE_DIGEST="$settle_source_digest"
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_SNAPSHOT="$TMP/settle-spawn-snapshot"
    : > "$_FORWARD_SNAPSHOT"
  }
  forward_context_read(){ printf '%s\n' "$settle_row"; }
  forward_context_remove(){ rm -f "$1"; }
  forward_context_install(){ : > "$1"; }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }
  active_count(){ printf '0\n'; }
  has_exceeded_retries(){ return 1; }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _reconcile_story_file_from_staging(){ return 0; }
  increment_retry(){ retry_calls=$((retry_calls + 1)); }
  launch_3phase_in_tmux(){ spawn_calls=$((spawn_calls + 1)); return 1; }
  settle_rc=0
  _forward_relaunch ESETTLE "$settle_context" "$settle_context_digest" || settle_rc=$?
  printf '%s:%s:%s:%s\n' "$settle_rc" \
    "$([[ -e "$settle_context" ]] && printf present || printf absent)" \
    "$retry_calls" "$spawn_calls" > "$TMP/settle-recovery-spawn-result"
)
expect "recovery spawn failure keeps the durable retry and does not restore context" \
  test "$(cat "$TMP/settle-recovery-spawn-result")" = "1:absent:1:1"

python3 - "$DAEMON" "$TMP/settle-main-boundary.sh" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('    if ! forward_context_remove "$_claim_context"')
launch = text.index(
    '    if ! launch_3phase_in_tmux "$story_id" "$_trace_id"', start
)
end = text.index("\n    fi", launch) + len("\n    fi")
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("settle_main_boundary() {\n  for _settle_once in 1; do\n")
    out.write(text[start:end] + "\n")
    out.write("  done\n}\n")
PY

(
  # shellcheck disable=SC1090
  source "$TMP/settle-main-boundary.sh"
  story_id=ESETTLE
  _trace_id=00000000-0000-4000-8000-000000000005
  _claim_context="$TMP/settle-main-retry-context"
  _claim_context_digest=$(printf '4%.0s' $(seq 1 64))
  _claim_row=$(printf '%s\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tabsent_new\tresume\tresumable\tnone\t%s' \
    ESETTLE 1111111111111111111111111111111111111111 \
    2222222222222222222222222222222222222222 \
    "$(printf '3%.0s' $(seq 1 64))" "$_claim_context_digest")
  _post_source_digest=$(printf '5%.0s' $(seq 1 64))
  _post_record=$(printf '3%.0s' $(seq 1 64))
  _claim_source=1111111111111111111111111111111111111111
  _claim_blob=2222222222222222222222222222222222222222
  _claim_record="$_post_record"
  : > "$_claim_context"
  retry_calls=0; spawn_calls=0
  forward_context_read(){ printf '%s\n' "$_claim_row"; }
  forward_context_remove(){ rm -f "$1"; }
  forward_context_install(){ : > "$1"; }
  increment_retry(){ retry_calls=$((retry_calls + 1)); return 1; }
  launch_3phase_in_tmux(){ spawn_calls=$((spawn_calls + 1)); }
  _forward_main_hold(){ return 0; }
  _forward_evidence(){ return 0; }
  settle_main_boundary
  printf '%s:%s:%s\n' \
    "$([[ -e "$_claim_context" ]] && printf present || printf absent)" \
    "$retry_calls" "$spawn_calls" > "$TMP/settle-main-retry-result"
)
printf '  main retry-failure observed=%s expected=present:1:0\n' \
  "$(cat "$TMP/settle-main-retry-result")"
expect "main retry persistence failure retains the absent-new context without spawn" \
  test "$(cat "$TMP/settle-main-retry-result")" = "present:1:0"

(
  # shellcheck disable=SC1090
  source "$TMP/settle-main-boundary.sh"
  story_id=ESETTLE
  _trace_id=00000000-0000-4000-8000-000000000006
  _claim_context="$TMP/settle-main-spawn-context"
  _claim_context_digest=$(printf '4%.0s' $(seq 1 64))
  _claim_row=$(printf '%s\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tabsent_new\tresume\tresumable\tnone\t%s' \
    ESETTLE 1111111111111111111111111111111111111111 \
    2222222222222222222222222222222222222222 \
    "$(printf '3%.0s' $(seq 1 64))" "$_claim_context_digest")
  _claim_source=1111111111111111111111111111111111111111
  _claim_blob=2222222222222222222222222222222222222222
  _claim_record=$(printf '3%.0s' $(seq 1 64))
  : > "$_claim_context"
  retry_calls=0; spawn_calls=0
  forward_context_read(){ printf '%s\n' "$_claim_row"; }
  forward_context_remove(){ rm -f "$1"; }
  forward_context_install(){ : > "$1"; }
  increment_retry(){ retry_calls=$((retry_calls + 1)); }
  launch_3phase_in_tmux(){ spawn_calls=$((spawn_calls + 1)); return 1; }
  _forward_main_hold(){ return 0; }
  _forward_evidence(){ return 0; }
  _FORWARD_SOURCE_DIGEST=$(printf '5%.0s' $(seq 1 64))
  _FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
  settle_main_boundary
  printf '%s:%s:%s\n' \
    "$([[ -e "$_claim_context" ]] && printf present || printf absent)" \
    "$retry_calls" "$spawn_calls" > "$TMP/settle-main-spawn-result"
)
expect "main spawn failure keeps the durable retry and does not restore context" \
  test "$(cat "$TMP/settle-main-spawn-result")" = "absent:1:1"

printf '\nCommit-stall forward guard matrix\n'
RETRY_REPO="$TMP/retry-repo"
git init "$RETRY_REPO" >/dev/null
git -C "$RETRY_REPO" config user.email test@example.invalid
git -C "$RETRY_REPO" config user.name test
printf 'base\n' > "$RETRY_REPO/app.txt"
git -C "$RETRY_REPO" add app.txt
git -C "$RETRY_REPO" commit -m base >/dev/null
git -C "$RETRY_REPO" branch target
git -C "$RETRY_REPO" update-ref refs/remotes/origin/staging refs/heads/target
printf 'candidate\n' >> "$RETRY_REPO/app.txt"
git -C "$RETRY_REPO" add app.txt
git -C "$RETRY_REPO" commit -m candidate >/dev/null
COMMIT_PHASE_RETRY_THRESHOLD=3
GREEN=''; NC=''
PROJECT_COUNT=0
NOTIFIED=0
EVIDENCE=none
_FORWARD_ACTION=resume
_FORWARD_REASON=resumable
_FORWARD_PHASE=qa_passed
_FORWARD_SOURCE=1111111111111111111111111111111111111111
_FORWARD_BLOB=2222222222222222222222222222222222222222
_FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
_FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
_FORWARD_SNAPSHOT="$TMP/retry-snapshot"
: > "$_FORWARD_SNAPSHOT"
_forward_context_path() { printf '%s\n' "$TMP/retry-context"; }
_forward_project() { PROJECT_COUNT=$((PROJECT_COUNT + 1)); return 0; }
_forward_worktree_state() { printf 'verified\n'; }
_forward_plan_present() { return 0; }
_forward_classify() {
  _FORWARD_ACTION=hold_operator
  _FORWARD_REASON=policy_stall
  _FORWARD_PHASE=commit_stalled
  _FORWARD_SOURCE_DIGEST=$(printf '6%.0s' $(seq 1 64))
  _FORWARD_RECORD_DIGEST=$(printf '7%.0s' $(seq 1 64))
  _FORWARD_SNAPSHOT="$TMP/retry-snapshot-current"
  : > "$_FORWARD_SNAPSHOT"
}
_lifecycle_snapshot_matches() { [[ "$3:$4" == phase_status:commit_stalled ]]; }
evidence_probe=$(_forward_evidence_for_intention EPROBE accepted policy_stall none \
  "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
  phase_status=commit_stalled 2>&1) || exit 1
expect "evidence exposes a field name without its intended value" \
  test "${evidence_probe##*fields=}" = phase_status
if _forward_evidence EPROBE accepted policy_stall none \
    "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
    phase_status=commit_stalled >/dev/null 2>&1; then
  fail "value-bound intention is rejected by the evidence surface"
else
  pass "value-bound intention is rejected by the evidence surface"
fi
_forward_evidence() { EVIDENCE="$2:$3:$4:$7"; }
notify_escalation() { NOTIFIED=$((NOTIFIED + 1)); }
log() { :; }

_commit_retry_write_observation ERETRY blocked:tests_failed
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
expect "first repeated commit outcome remains below threshold" test "$guard_rc:$PROJECT_COUNT" = "0:0"

printf 'real progress\n' >> "$RETRY_REPO/app.txt"
git -C "$RETRY_REPO" add app.txt
git -C "$RETRY_REPO" commit -m progress >/dev/null
_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
_commit_retry_write_observation ERETRY blocked:tests_failed
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
expect "real candidate progress resets repeated-outcome count" \
  grep -qx 'count=1' "$(_commit_retry_state_path ERETRY)"
expect "progress reset cannot project a stall" test "$guard_rc:$PROJECT_COUNT" = "0:0"

_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
_FORWARD_SOURCE=1111111111111111111111111111111111111111
_FORWARD_BLOB=2222222222222222222222222222222222222222
_FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
_FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
_FORWARD_SNAPSHOT="$TMP/retry-snapshot"
: > "$_FORWARD_SNAPSHOT"
_commit_retry_write_observation ERETRY blocked:tests_failed
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
expect "second identical outcome remains below threshold" test "$guard_rc:$PROJECT_COUNT" = "0:0"

ORIGINAL_FORWARD_BIND=$(declare -f _forward_bind_context)
_forward_bind_context() { return 1; }
for _ in 1; do
  _FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
  _FORWARD_SOURCE=1111111111111111111111111111111111111111
  _FORWARD_BLOB=2222222222222222222222222222222222222222
  _FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
  _FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
  _FORWARD_SNAPSHOT="$TMP/retry-snapshot"
  : > "$_FORWARD_SNAPSHOT"
  _commit_retry_write_observation ERETRY blocked:tests_failed
  guard_rc=0
  _forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
done
expect "crash after event consumption before context bind preserves stall_pending" \
  grep -qx 'stall_pending=1' "$(_commit_retry_state_path ERETRY)"
expect "pre-bind crash creates no context and cannot project" \
  test "$guard_rc:$PROJECT_COUNT" = "1:0"
expect "pre-bind crash leaves context absent" test ! -e "$TMP/retry-context"
eval "$ORIGINAL_FORWARD_BIND"
ORIGINAL_POLICY_RESUME=$(declare -f _forward_resume_policy_stall)
_forward_resume_policy_stall() { return 1; }
_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
_FORWARD_SOURCE=1111111111111111111111111111111111111111
_FORWARD_BLOB=2222222222222222222222222222222222222222
_FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
_FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
_FORWARD_SNAPSHOT="$TMP/retry-snapshot"
: > "$_FORWARD_SNAPSHOT"
after_bind_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || after_bind_rc=$?
stall_context_row=$(forward_context_read "$TMP/retry-context") || exit 1
IFS=$'\t' read -r _ _ _ _ _ _ _ _ stall_event_digest stall_state_digest \
  _ _ _ _ stall_context_digest <<< "$stall_context_row"
expect "restart without marker binds exact event/state digests" \
  test "$after_bind_rc:$stall_event_digest:$stall_state_digest" = \
    "1:$( _commit_retry_state_snapshot ERETRY | awk -F '|' '{print $4":"$5}' )"
expect "crash after context bind preserves the same stall state" \
  grep -qx 'stall_pending=1' "$(_commit_retry_state_path ERETRY)"
eval "$ORIGINAL_POLICY_RESUME"
_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
_FORWARD_SOURCE=1111111111111111111111111111111111111111
_FORWARD_BLOB=2222222222222222222222222222222222222222
_FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
_FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
_FORWARD_SNAPSHOT="$TMP/retry-snapshot"
: > "$_FORWARD_SNAPSHOT"
restart_rc=0
_forward_resume_policy_stall ERETRY "$RETRY_REPO" "$TMP/retry-context" \
  "$stall_context_digest" "$_FORWARD_SOURCE" "$_FORWARD_BLOB" \
  "$_FORWARD_RECORD_DIGEST" "$stall_event_digest" "$stall_state_digest" \
  || restart_rc=$?
expect "fresh restart projects the fixed policy stall exactly once and settles" \
  test "$restart_rc:$PROJECT_COUNT:$EVIDENCE:$NOTIFIED" = \
    "0:1:accepted:policy_stall:none:phase_status:1"
expect "commit-stall evidence contains no value-bearing field token" \
  test "${EVIDENCE##*:}" = phase_status
expect "settlement retires exact context and helper state" \
  test ! -e "$TMP/retry-context" -a ! -e "$(_commit_retry_state_path ERETRY)"

# Crash after the journal projector has landed commit_stalled but before
# context/helper retirement. The restart adopts the same digests and must not
# invoke a successor projection.
COMMIT_PHASE_RETRY_THRESHOLD=1
PROJECT_COUNT=0; EVIDENCE=none; NOTIFIED=0
_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
_FORWARD_SOURCE=1111111111111111111111111111111111111111
_FORWARD_BLOB=2222222222222222222222222222222222222222
_FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
_FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
_FORWARD_SNAPSHOT="$TMP/after-snapshot"; : > "$_FORWARD_SNAPSHOT"
ORIGINAL_POLICY_RESUME=$(declare -f _forward_resume_policy_stall)
_forward_resume_policy_stall(){ return 1; }
_commit_retry_write_observation EAFTER blocked:tests_failed || exit 1
after_bind_guard_rc=0
_forward_commit_retry_guard EAFTER "$RETRY_REPO" verified true \
  >/dev/null 2>&1 || after_bind_guard_rc=$?
[[ "$after_bind_guard_rc" -ne 0 ]] || exit 1
eval "$ORIGINAL_POLICY_RESUME"
after_context_row=$(forward_context_read "$TMP/retry-context") || exit 1
IFS=$'\t' read -r _ _ _ _ _ _ _ _ after_event after_state _ _ _ _ after_context_digest \
  <<< "$after_context_row"
_forward_project(){ PROJECT_COUNT=$(( PROJECT_COUNT + 1 )); : > "$TMP/after-projected"; return 1; }
after_crash_rc=0
_forward_resume_policy_stall EAFTER "$RETRY_REPO" "$TMP/retry-context" \
  "$after_context_digest" "$_FORWARD_SOURCE" "$_FORWARD_BLOB" \
  "$_FORWARD_RECORD_DIGEST" "$after_event" "$after_state" || after_crash_rc=$?
expect "post-projection crash preserves exact context and helper state" \
  test "$after_crash_rc:$PROJECT_COUNT" = 1:1 -a -e "$TMP/retry-context" \
    -a -e "$(_commit_retry_state_path EAFTER)"
_FORWARD_ACTION=hold_operator; _FORWARD_REASON=policy_stall; _FORWARD_PHASE=commit_stalled
_FORWARD_SNAPSHOT="$TMP/after-current"; : > "$_FORWARD_SNAPSHOT"
_forward_project(){ PROJECT_COUNT=$(( PROJECT_COUNT + 1 )); return 0; }
after_restart_rc=0
_forward_resume_policy_stall EAFTER "$RETRY_REPO" "$TMP/retry-context" \
  "$after_context_digest" "$_FORWARD_SOURCE" "$_FORWARD_BLOB" \
  "$_FORWARD_RECORD_DIGEST" "$after_event" "$after_state" || after_restart_rc=$?
expect "restart adopts post-projection identity without successor projection" \
  test "$after_restart_rc:$PROJECT_COUNT:$EVIDENCE" = \
    "0:1:accepted:policy_stall:none:phase_status"
expect "post-projection adoption retires exact durable identity" \
  test ! -e "$TMP/retry-context" -a ! -e "$(_commit_retry_state_path EAFTER)"

# A retained recovery.scan run for qa_passed -> commit_stalled is adopted by
# its real manifest identity. A source mismatch blocks and preserves both
# context and helper state; the exact manifest retires once and exposes the
# real attempt-token digest while observability exposes only fields=phase_status.
retained_result=$(
  PROJECT_COUNT=0; EVIDENCE=none; JOURNAL_RETIRED=none
  _FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
  _FORWARD_SOURCE=1111111111111111111111111111111111111111
  _FORWARD_BLOB=2222222222222222222222222222222222222222
  _FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
  _FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
  _FORWARD_SNAPSHOT="$TMP/retained-snapshot"; : > "$_FORWARD_SNAPSHOT"
  ORIGINAL_POLICY_RESUME=$(declare -f _forward_resume_policy_stall)
  _forward_resume_policy_stall(){ return 1; }
  _commit_retry_write_observation ERETAIN blocked:tests_failed || exit 1
  retained_bind_rc=0
  _forward_commit_retry_guard ERETAIN "$RETRY_REPO" verified true \
    >/dev/null 2>&1 || retained_bind_rc=$?
  [[ "$retained_bind_rc" -ne 0 ]] || exit 1
  eval "$ORIGINAL_POLICY_RESUME"
  retained_context_row=$(forward_context_read "$TMP/retry-context") || exit 1
  IFS=$'\t' read -r _ retained_source _ _ _ _ _ _ retained_event retained_state \
    _ _ _ _ retained_context_digest <<< "$retained_context_row"
  retained_token=$(printf 'a%.0s' $(seq 1 64))
  retained_token_digest=$(printf 'b%.0s' $(seq 1 64))
  retained_run_state=$(printf 'c%.0s' $(seq 1 64))
  retained_records=$(printf 'd%.0s' $(seq 1 64))
  retained_record_digest=$(printf 'e%.0s' $(seq 1 64))
  retained_row=$'phase_status\t00000000000000000000-aaaaaaaaaaaaaaaa.json\t'"$retained_record_digest"$'\tcommit_stalled\tapplied'
  wrong_manifest=$(printf '%s\t%s\t%s\t%s\t%s\n%s\n' \
    "$retained_token" 9999999999999999999999999999999999999999 \
    "$retained_token_digest" "$retained_run_state" "$retained_records" "$retained_row")
  _FORWARD_ACTION=hold_operator; _FORWARD_REASON=policy_stall; _FORWARD_PHASE=commit_stalled
  _FORWARD_SNAPSHOT="$TMP/retained-current"; : > "$_FORWARD_SNAPSHOT"
  _journal_retire_accepted_lifecycle(){ JOURNAL_RETIRED="$3"; }
  wrong_retained_rc=0
  _forward_resume_policy_stall ERETAIN "$RETRY_REPO" "$TMP/retry-context" \
    "$retained_context_digest" "$retained_source" "$_FORWARD_BLOB" \
    "$_FORWARD_RECORD_DIGEST" "$retained_event" "$retained_state" \
    "$wrong_manifest" || wrong_retained_rc=$?
  wrong_preserved=false
  if [[ "$wrong_retained_rc:$JOURNAL_RETIRED" == 1:none \
      && -e "$TMP/retry-context" \
      && -e "$(_commit_retry_state_path ERETAIN)" ]]; then
    wrong_preserved=true
  fi
  exact_manifest=$(printf '%s\t%s\t%s\t%s\t%s\n%s\n' \
    "$retained_token" "$retained_source" "$retained_token_digest" \
    "$retained_run_state" "$retained_records" "$retained_row")
  exact_retained_rc=0
  _forward_resume_policy_stall ERETAIN "$RETRY_REPO" "$TMP/retry-context" \
    "$retained_context_digest" "$retained_source" "$_FORWARD_BLOB" \
    "$_FORWARD_RECORD_DIGEST" "$retained_event" "$retained_state" \
    "$exact_manifest" || exact_retained_rc=$?
  settled=false
  if [[ ! -e "$TMP/retry-context" \
      && ! -e "$(_commit_retry_state_path ERETAIN)" ]]; then
    settled=true
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$wrong_preserved" \
    "$exact_retained_rc" "$JOURNAL_RETIRED" "$EVIDENCE" "$settled" \
    "$retained_run_state:$retained_token_digest"
)
IFS='|' read -r wrong_preserved exact_retained_rc JOURNAL_RETIRED EVIDENCE \
  retained_settled retained_expected <<< "$retained_result"
expect "retained commit_stalled source mismatch preserves exact identity" \
  test "$wrong_preserved" = true
expect "exact retained commit_stalled run settles once with real evidence" \
  test "$exact_retained_rc:$JOURNAL_RETIRED:$EVIDENCE" = \
    "0:${retained_expected%%:*}:accepted:policy_stall:${retained_expected#*:}:phase_status"
expect "retained evidence never leaks its value-bound intention" \
  test "${EVIDENCE##*:}" = phase_status
expect "retained settlement retires context and helper state" \
  test "$retained_settled" = true
COMMIT_PHASE_RETRY_THRESHOLD=3

_commit_retry_clear ERETRY
_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
_FORWARD_SOURCE=1111111111111111111111111111111111111111
_FORWARD_BLOB=2222222222222222222222222222222222222222
_FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
_FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
_FORWARD_SNAPSHOT="$TMP/retry-snapshot"
: > "$_FORWARD_SNAPSHOT"
_commit_retry_write_observation ERETRY blocked:tests_failed
ORIGINAL_RETRY_SHA=$(declare -f _commit_retry_sha256_stdin)
_commit_retry_sha256_stdin() { return 1; }
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
eval "$ORIGINAL_RETRY_SHA"
expect "unavailable candidate digest blocks without lifecycle projection" \
  test "$guard_rc:$PROJECT_COUNT" = "1:1"

_commit_retry_clear ERETRY
_FORWARD_ACTION=resume; _FORWARD_REASON=resumable; _FORWARD_PHASE=qa_passed
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
expect "missing durable outcome cannot fabricate wrapper_exit_nonzero" \
  test "$guard_rc:$PROJECT_COUNT" = "1:1"

printf 'blocked:tests_failed\nextra\n' > "$(_commit_retry_observation_path ERETRY)"
chmod 600 "$(_commit_retry_observation_path ERETRY)"
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
expect "malformed durable outcome blocks without stall or relaunch" \
  test "$guard_rc:$PROJECT_COUNT" = "1:1"
rm -f "$(_commit_retry_observation_path ERETRY)"

chmod 500 "$LOCK_DIR"
write_rc=0
_commit_retry_write_observation ERETRY wrapper_exit_nonzero || write_rc=$?
chmod 700 "$LOCK_DIR"
guard_rc=0
_forward_commit_retry_guard ERETRY "$RETRY_REPO" verified true || guard_rc=$?
expect "durable outcome write failure remains fail-closed" \
  test "$write_rc:$guard_rc:$PROJECT_COUNT" = "1:1:1"

python3 - "$ROOT/.gaai/core/scripts/daemon-dispatch.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(
    r'if ! _commit_retry_write_observation.*?\n\s*fi', text, re.S
)
if not match or "return 1" not in match.group(0):
    raise SystemExit(1)
PY
expect "dispatch propagates durable outcome write failure" test "$?" -eq 0

printf '\nAttempt-secret fault matrix\n'
SECRET_LOCK="$TMP/secret-locks"
mkdir -p "$SECRET_LOCK"; chmod 700 "$SECRET_LOCK"
LOCK_DIR="$SECRET_LOCK"
SECRET_VALUE='token-value-with-spaces'
secret=$(_attempt_secret_create ESECRET "$SECRET_VALUE") || exit 1
mode=$(stat -c %a "$secret" 2>/dev/null) \
  || mode=$(stat -f %Lp "$secret" 2>/dev/null) \
  || mode=""
expect "secret is a unique private regular file" test "$mode" = 600
expect "secret bytes are exact and not shell source" test "$(cat "$secret")" = "$SECRET_VALUE"
wrapper="$TMP/secret-wrapper.sh"
cat > "$wrapper" <<'WRAP'
#!/usr/bin/env sh
printf '%s' "${GAAI_IMPL_AUTH_TOKEN:-}" > "${SECRET_RESULT:?}"
WRAP
chmod 700 "$wrapper"
launcher=$(_attempt_launcher_create ESECRET "$secret" "$wrapper") || exit 1
if rg -F "$SECRET_VALUE" "$launcher" >/dev/null 2>&1; then
  fail "launcher contains no token bytes"
else
  pass "launcher contains no token bytes"
fi
SECRET_RESULT="$TMP/secret-result"; export SECRET_RESULT
expect "verified launcher transfers token without shell source" "$launcher"
expect "wrapper received exact token" test "$(cat "$SECRET_RESULT")" = "$SECRET_VALUE"
expect "successful launch removes per-attempt secret" test ! -e "$secret"
expect "successful launch removes per-attempt launcher" test ! -e "$launcher"

secret=$(_attempt_secret_create ESECRET 'mode-tamper') || exit 1
launcher=$(_attempt_launcher_create ESECRET "$secret" "$wrapper") || exit 1
chmod 644 "$secret"
rm -f "$SECRET_RESULT"
if "$launcher" >/dev/null 2>&1; then
  fail "mode-tampered secret is rejected"
else
  pass "mode-tampered secret is rejected"
fi
expect "mode failure never executes wrapper" test ! -e "$SECRET_RESULT"
expect "bounded cleanup removes tampered secret" _attempt_file_cleanup "$secret"
expect "bounded cleanup removes failed launcher" _attempt_file_cleanup "$launcher"

secret=$(_attempt_secret_create ESECRET 'missing-secret') || exit 1
launcher=$(_attempt_launcher_create ESECRET "$secret" "$wrapper") || exit 1
_attempt_file_cleanup "$secret" || exit 1
rm -f "$SECRET_RESULT"
if "$launcher" >/dev/null 2>&1; then
  fail "missing secret is fail-closed"
else
  pass "missing secret is fail-closed"
fi
expect "missing secret never executes wrapper" test ! -e "$SECRET_RESULT"
expect "failed launcher cleanup is bounded" _attempt_file_cleanup "$launcher"

sentinel="$TMP/symlink-target"
printf 'preserve\n' > "$sentinel"
link="$SECRET_LOCK/.daemon-secret.ESECRET.attacker.env"
ln -s "$sentinel" "$link"
expect "cleanup unlinks an allowed symlink entry" _attempt_file_cleanup "$link"
expect "symlink cleanup never touches target" grep -qx preserve "$sentinel"

secret_a=$(_attempt_secret_create ESECRET 'concurrent-a') || exit 1
secret_b=$(_attempt_secret_create ESECRET 'concurrent-b') || exit 1
expect "concurrent attempts use distinct secret names" test "$secret_a" != "$secret_b"
result_a="$TMP/result-a" result_b="$TMP/result-b"
launcher_a=$(_attempt_launcher_create ESECRET "$secret_a" "$wrapper") || exit 1
launcher_b=$(_attempt_launcher_create ESECRET "$secret_b" "$wrapper") || exit 1
( SECRET_RESULT="$result_a" "$launcher_a" ) & pa=$!
( SECRET_RESULT="$result_b" "$launcher_b" ) & pb=$!
wait "$pa"; rca=$?; wait "$pb"; rcb=$?
if [[ "$rca" -eq 0 && "$rcb" -eq 0 \
    && "$(cat "$result_a")" == concurrent-a && "$(cat "$result_b")" == concurrent-b ]]; then
  pass "concurrent attempt secrets cannot collide or cross-adopt"
else
  fail "concurrent attempt isolation"
fi

if rg -n '\.daemon-secrets\.env|secrets_prefix|\. ["'"'"']?\$?secrets_file' "$DAEMON" >/dev/null 2>&1; then
  fail "shared or shell-sourced daemon secret path is absent"
else
  pass "shared or shell-sourced daemon secret path is absent"
fi

printf '\nGlobal QA remediation RED falsifiers (F1-F7)\n'

# F1 — a durable resumable context left by a temporary inhibitor is deferred,
# not an unrecoverable startup error. The context must survive for the next
# periodic scan; a retained journal attempt may never be called deferred.
(
  LOCK_DIR="$TMP/red-f1-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  _forward_context_path(){ printf '%s/recovery.scan.%s.json\n' "$LOCK_DIR" "$1"; }
  GAAI_WORKTREES_BASE="$TMP/red-f1-worktrees"
  mkdir -p "$GAAI_WORKTREES_BASE/EF1-workspace"
  f1_source=1111111111111111111111111111111111111111
  f1_blob=2222222222222222222222222222222222222222
  f1_record=$(printf '3%.0s' $(seq 1 64))
  f1_source_digest=$(printf '4%.0s' $(seq 1 64))
  f1_context=$(_forward_context_path EF1) || exit 1
  forward_context_install "$f1_context" EF1 "$f1_source" "$f1_blob" \
    "$f1_record" none none none none none none verified resume resumable none \
    || exit 1
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_resolve_worktree(){ printf '%s\n' "$GAAI_WORKTREES_BASE/EF1-workspace"; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_STATUS=in_progress; _FORWARD_PHASE=implemented
    _FORWARD_SOURCE="$f1_source"; _FORWARD_BLOB="$f1_blob"
    _FORWARD_RECORD_DIGEST="$f1_record"; _FORWARD_SOURCE_DIGEST="$f1_source_digest"
    _FORWARD_SNAPSHOT="$TMP/red-f1-current"; : > "$_FORWARD_SNAPSHOT"
  }
  _journal_inspect_pending_lifecycle(){ return 2; }
  forward_classify_snapshot(){
    printf 'resume\tresumable\tin_progress\timplemented\t2026-08-25T10:00:00Z\t%s\t%s\t%s\n' \
      "$f1_record" "$f1_source" "$f1_blob"
  }
  git(){
    case " $* " in
      *' merge-base --is-ancestor '*) return 0 ;;
      *' rev-parse '*) printf '%s\n' "$f1_blob" ;;
      *' show '*) printf 'items:\n- id: EF1\n  status: in_progress\n  phase_status: implemented\n  started_at: "2026-08-25T10:00:00Z"\n' ;;
      *) command git "$@" ;;
    esac
  }
  f1_relaunch_impl=$(declare -f _forward_relaunch)
  f1_runner_impl=$(declare -f _forward_runner_state)
  _forward_relaunch(){ return 2; }
  _forward_evidence(){ printf '%s:%s\n' "$2" "$3" >> "$TMP/red-f1-evidence"; }
  f1_rc=0
  _forward_recovery_one EF1 || f1_rc=$?
  printf '%s:%s\n' "$f1_rc" \
    "$([[ -e "$f1_context" ]] && printf present || printf absent)" \
    > "$TMP/red-f1-result"

  # A real absent-new context remains the authority across a live runner and
  # capacity inhibition, then launches exactly once on the next eligible scan.
  eval "$f1_relaunch_impl"
  f1_abs_context=$(_forward_context_path EF1ABS) || exit 1
  forward_context_install "$f1_abs_context" EF1ABS "$f1_source" "$f1_blob" \
    "$f1_record" none none none none none none absent_new resume resumable none \
    || exit 1
  _forward_worktree_state(){
    if [[ "$1:${2:-false}" == EF1ABS:true ]]; then
      printf 'absent_new\n'
    else
      printf 'verified\n'
    fi
  }
  _reconcile_story_file_from_staging(){ return 0; }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  tmux(){ return 1; }
  has_exceeded_retries(){ return 1; }
  MAX_CONCURRENT=1
  f1_runner_mode=live; f1_active=0; f1_retry=0; f1_spawn=0
  _forward_runner_state(){ printf '%s\n' "$f1_runner_mode"; }
  active_count(){ printf '%s\n' "$f1_active"; }
  increment_retry(){ f1_retry=$((f1_retry + 1)); }
  launch_3phase_in_tmux(){ f1_spawn=$((f1_spawn + 1)); }
  node(){ printf '00000000-0000-4000-8000-000000000001'; }
  f1_live_rc=0
  _forward_recovery_one EF1ABS || f1_live_rc=$?
  f1_live_context=$([[ -e "$f1_abs_context" ]] && printf present || printf absent)
  f1_runner_mode=clear; f1_active=1; f1_capacity_rc=0
  _forward_recovery_one EF1ABS || f1_capacity_rc=$?
  f1_capacity_context=$([[ -e "$f1_abs_context" ]] && printf present || printf absent)
  f1_active=0; f1_eligible_rc=0
  _forward_recovery_one EF1ABS || f1_eligible_rc=$?
  f1_eligible_context=$([[ -e "$f1_abs_context" ]] && printf present || printf absent)
  printf '%s:%s:%s:%s:%s:%s:%s:%s\n' \
    "$f1_live_rc" "$f1_live_context" "$f1_capacity_rc" "$f1_capacity_context" \
    "$f1_eligible_rc" "$f1_eligible_context" "$f1_retry" "$f1_spawn" \
    > "$TMP/red-f1-cycle-result"

  # Reconciliation output that cannot identify every live runner is unknown,
  # never evidence that the story is clear to relaunch.
  eval "$f1_runner_impl"
  f1_runner_payload='{"live":[],"stale":[],"expired":[],"unreadable":[]}'
  node(){ printf '%s\n' "$f1_runner_payload"; }
  f1_runner_clear=$(_forward_runner_state EF1ABS) || f1_runner_clear=reject
  f1_runner_payload='{}'
  f1_runner_missing=$(_forward_runner_state EF1ABS) || f1_runner_missing=reject
  f1_runner_payload='{"live":[{}],"stale":[],"expired":[],"unreadable":[]}'
  f1_runner_malformed=$(_forward_runner_state EF1ABS) || f1_runner_malformed=reject
  f1_runner_payload='{"live":[],"stale":[{}],"expired":[],"unreadable":[]}'
  f1_runner_stale_bad=$(_forward_runner_state EF1ABS) || f1_runner_stale_bad=reject
  f1_runner_payload='{"live":[],"stale":[{"story_id":"EF1ABS","pid":123,"state":"running"}],"expired":[],"unreadable":[]}'
  f1_runner_stale=$(_forward_runner_state EF1ABS) || f1_runner_stale=reject
  f1_runner_payload='{"live":[],"stale":[],"expired":[{"story_id":"EF1ABS","pid":123,"state":"running"}],"unreadable":[]}'
  f1_runner_expired=$(_forward_runner_state EF1ABS) || f1_runner_expired=reject
  printf '%s:%s:%s:%s:%s:%s\n' "$f1_runner_clear" "$f1_runner_missing" \
    "$f1_runner_malformed" "$f1_runner_stale_bad" "$f1_runner_stale" \
    "$f1_runner_expired" > "$TMP/red-f1-runner-result"

  # A journal result outside its documented domain is an explicit invalid
  # record block. Deferred recovery remains a successful global scan.
  _journal_inspect_pending_lifecycle(){ return 7; }
  f1_journal_rc=0
  _forward_recovery_one EF1 || f1_journal_rc=$?
  f1_journal_evidence=$(tail -1 "$TMP/red-f1-evidence")
  _forward_recovery_one(){ return 2; }
  forward_enumerate_snapshot(){ printf 'EF1\n'; }
  f1_scan_rc=0
  forward_recovery_scan --only-sid EF1 || f1_scan_rc=$?
  printf '%s:%s:%s\n' "$f1_journal_rc" "$f1_journal_evidence" "$f1_scan_rc" \
    > "$TMP/red-f1-domain-result"
)
printf '  RED-F1 observed=%s expected=2:present\n' "$(cat "$TMP/red-f1-result")"
expect "RED-F1 resumable context defers across restart/periodic eligibility" \
  test "$(cat "$TMP/red-f1-result")" = "2:present"
printf '  F1 cycle observed=%s expected=2:present:2:present:0:absent:1:1\n' \
  "$(cat "$TMP/red-f1-cycle-result")"
expect "F1 absent-new context survives runner/capacity and launches once" \
  test "$(cat "$TMP/red-f1-cycle-result")" = \
    "2:present:2:present:0:absent:1:1"
printf '  F1 runner observed=%s expected=clear:reject:reject:reject:clear:live\n' \
  "$(cat "$TMP/red-f1-runner-result")"
expect "F1 runner reconciliation rejects incomplete or anonymous live reports" \
  test "$(cat "$TMP/red-f1-runner-result")" = \
    "clear:reject:reject:reject:clear:live"
printf '  F1 domain observed=%s expected=1:blocked:invalid_record:0\n' \
  "$(cat "$TMP/red-f1-domain-result")"
expect "F1 unexpected journal rc blocks while deferred scan remains successful" \
  test "$(cat "$TMP/red-f1-domain-result")" = "1:blocked:invalid_record:0"

# F2 — reconcile may change the target. A fresh authority check after that
# boundary must reject A->B before context retirement, retry or spawn.
(
  f2_a=1111111111111111111111111111111111111111
  f2_b=2222222222222222222222222222222222222222
  f2_blob=3333333333333333333333333333333333333333
  f2_record=$(printf '4%.0s' $(seq 1 64))
  f2_context=$(printf '5%.0s' $(seq 1 64))
  f2_current="$f2_a"; retry_calls=0; spawn_calls=0; remove_calls=0
  MAX_CONCURRENT=1
  _forward_resolve_worktree(){ printf '%s\n' "$TMP/red-f2-worktree"; }
  mkdir -p "$TMP/red-f2-worktree"
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_SOURCE="$f2_current"; _FORWARD_BLOB="$f2_blob"
    _FORWARD_RECORD_DIGEST="$f2_record"
    _FORWARD_SOURCE_DIGEST=$(printf '6%.0s' $(seq 1 64))
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_SNAPSHOT="$TMP/red-f2-snapshot"; : > "$_FORWARD_SNAPSHOT"
  }
  forward_context_read(){
    printf 'EF2\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s\n' \
      "$f2_a" "$f2_blob" "$f2_record" "$f2_context"
  }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }
  active_count(){ printf '0\n'; }
  has_exceeded_retries(){ return 1; }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _reconcile_story_file_from_staging(){ f2_current="$f2_b"; return 0; }
  node(){ printf '00000000-0000-4000-8000-000000000000'; }
  forward_context_remove(){ remove_calls=$((remove_calls + 1)); }
  increment_retry(){ retry_calls=$((retry_calls + 1)); }
  launch_3phase_in_tmux(){ spawn_calls=$((spawn_calls + 1)); }
  f2_rc=0
  _forward_relaunch EF2 "$TMP/red-f2-context" "$f2_context" || f2_rc=$?
  f2_recovery_result="$f2_rc:$remove_calls:$retry_calls:$spawn_calls"
  remove_calls=0; retry_calls=0; spawn_calls=0; f2_main_rc=0
  f2_current="$f2_b"
  if _forward_revalidate_after_reconcile EF2 "$f2_a" "$f2_blob" \
      "$f2_record" postclaim false; then
    forward_context_remove "$TMP/red-f2-context" "$f2_context"
    increment_retry EF2
    launch_3phase_in_tmux EF2 trace
  else
    f2_main_rc=$?
  fi
  printf '%s:%s:%s:%s:%s\n' "$f2_recovery_result" "$f2_main_rc" \
    "$remove_calls" "$retry_calls" "$spawn_calls" \
    > "$TMP/red-f2-result"
)
printf '  RED-F2 observed=%s expected=1:0:0:0:1:0:0:0\n' "$(cat "$TMP/red-f2-result")"
expect "RED-F2 target A-to-B during reconcile cannot retire/retry/spawn" \
  test "$(cat "$TMP/red-f2-result")" = "1:0:0:0:1:0:0:0"

# Recovery has a second last window after its final revalidation: UUID
# generation can overlap a target advance before dead-lock retirement and
# context/retry/spawn effects. The immutable A context must remain recoverable
# and the fresh B identity must be the only evidence authority.
fl_a=1111111111111111111111111111111111111111
fl_record_b=$(printf '6%.0s' $(seq 1 64))
fl_digest_b=$(printf '8%.0s' $(seq 1 64))
(
  fl_a=1111111111111111111111111111111111111111
  fl_b=2222222222222222222222222222222222222222
  fl_blob_a=3333333333333333333333333333333333333333
  fl_blob_b=4444444444444444444444444444444444444444
  fl_record_a=$(printf '5%.0s' $(seq 1 64))
  fl_record_b=$(printf '6%.0s' $(seq 1 64))
  fl_digest_a=$(printf '7%.0s' $(seq 1 64))
  fl_digest_b=$(printf '8%.0s' $(seq 1 64))
  fl_context_digest=$(printf '9%.0s' $(seq 1 64))
  fl_context="$TMP/recovery-last-edge-context"
  fl_target="$TMP/recovery-last-edge-target"
  printf '%s\n' "$fl_a" > "$fl_target"; : > "$fl_context"
  fl_remove=0; fl_retry=0; fl_spawn=0; fl_retire=0; fl_evidence=none
  MAX_CONCURRENT=1
  _forward_resolve_worktree(){ printf '%s\n' "$TMP/recovery-last-edge-worktree"; }
  mkdir -p "$TMP/recovery-last-edge-worktree"
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    fl_current=$(cat "$fl_target")
    _FORWARD_SOURCE="$fl_current"
    if [[ "$fl_current" == "$fl_a" ]]; then
      _FORWARD_BLOB="$fl_blob_a"; _FORWARD_RECORD_DIGEST="$fl_record_a"
      _FORWARD_SOURCE_DIGEST="$fl_digest_a"
    else
      _FORWARD_BLOB="$fl_blob_b"; _FORWARD_RECORD_DIGEST="$fl_record_b"
      _FORWARD_SOURCE_DIGEST="$fl_digest_b"
    fi
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_SNAPSHOT="$TMP/recovery-last-edge-snapshot"; : > "$_FORWARD_SNAPSHOT"
  }
  forward_context_read(){
    [[ -e "$fl_context" ]] || return 1
    printf 'EFL\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s\n' \
      "$fl_a" "$fl_blob_a" "$fl_record_a" "$fl_context_digest"
  }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }
  active_count(){ printf '0\n'; }
  has_exceeded_retries(){ return 1; }
  _reconcile_story_file_from_staging(){ return 0; }
  node(){
    printf '%s\n' "$fl_b" > "$fl_target"
    printf '00000000-0000-4000-8000-000000000020'
  }
  _forward_retire_dead_lock(){ fl_retire=$((fl_retire + 1)); }
  forward_context_remove(){ fl_remove=$((fl_remove + 1)); rm -f "$1"; }
  increment_retry(){ fl_retry=$((fl_retry + 1)); }
  launch_3phase_in_tmux(){ fl_spawn=$((fl_spawn + 1)); fl_launch_source="$3"; }
  _forward_evidence(){
    fl_evidence="$2|$3|$5|$6"
  }
  # Negative control: disabling only the final guard must make this fixture
  # reproduce the former fail-open A launch, proving that the filesystem race
  # (rather than a shell-local variable) is what the assertion exercises.
  fl_guard_impl=$(declare -f _forward_last_edge_guard)
  _forward_last_edge_guard(){ return 0; }
  fl_unguarded_rc=0; fl_launch_source=none
  _forward_relaunch EFL "$fl_context" "$fl_context_digest" || fl_unguarded_rc=$?
  printf '%s:%s:%s:%s:%s:%s:%s:%s\n' "$fl_unguarded_rc" \
    "$([[ -e "$fl_context" ]] && printf present || printf absent)" \
    "$fl_remove" "$fl_retry" "$fl_spawn" "$fl_retire" "$fl_evidence" \
    "$fl_launch_source" > "$TMP/recovery-last-edge-unguarded-result"
  eval "$fl_guard_impl"
  printf '%s\n' "$fl_a" > "$fl_target"; : > "$fl_context"
  fl_remove=0; fl_retry=0; fl_spawn=0; fl_retire=0; fl_evidence=none
  fl_rc=0; fl_launch_source=none
  _forward_relaunch EFL "$fl_context" "$fl_context_digest" || fl_rc=$?
  fl_context_state=absent; fl_context_source=absent
  if [[ -e "$fl_context" ]]; then
    fl_context_state=present
    fl_context_source=$(forward_context_read "$fl_context" | cut -f2)
  fi
  printf '%s:%s:%s:%s:%s:%s:%s:%s\n' "$fl_rc" "$fl_context_state" \
    "$fl_remove" "$fl_retry" "$fl_spawn" "$fl_retire" "$fl_evidence" \
    "$fl_context_source" > "$TMP/recovery-last-edge-result"
)
printf '  recovery last-edge negative-control=%s expected=0:absent:1:1:1:0:none:%s\n' \
  "$(cat "$TMP/recovery-last-edge-unguarded-result")" "$fl_a"
expect "recovery UUID-window falsifier fails open when only its final guard is disabled" \
  test "$(cat "$TMP/recovery-last-edge-unguarded-result")" = \
    "0:absent:1:1:1:0:none:$fl_a"
printf '  recovery last-edge observed=%s expected=1:present:0:0:0:0:blocked|remote_changed|%s|%s:%s\n' \
  "$(cat "$TMP/recovery-last-edge-result")" "$fl_digest_b" "$fl_record_b" "$fl_a"
expect "recovery UUID-window drift preserves A context and consumes no effect" \
  test "$(cat "$TMP/recovery-last-edge-result")" = \
    "1:present:0:0:0:0:blocked|remote_changed|$fl_digest_b|$fl_record_b:$fl_a"
python3 - "$DAEMON" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("# Settle retained lifecycle authority before temporary execution checks.")
end = text.index("# ── Route: 3phase", start)
main = text[start:end]
order = [
    main.index('_reconcile_story_file_from_staging "$story_id"'),
    main.index('_forward_revalidate_after_reconcile "$story_id"'),
    main.index('_forward_bind_context "$_claim_context"'),
]
if order != sorted(order):
    raise SystemExit(1)
PY
expect "main post-claim uses common final authority before context" test "$?" -eq 0

# F3 — target admission must precede every mutating safe-base repair.
(
  LOCK_DIR="$TMP/red-f3-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  GAAI_WORKTREES_BASE="$TMP/red-f3-worktrees"
  mkdir -p "$GAAI_WORKTREES_BASE/EF3-workspace"
  git -C "$GAAI_WORKTREES_BASE/EF3-workspace" init -q
  git -C "$GAAI_WORKTREES_BASE/EF3-workspace" config user.email test@example.invalid
  git -C "$GAAI_WORKTREES_BASE/EF3-workspace" config user.name test
  printf 'base\n' > "$GAAI_WORKTREES_BASE/EF3-workspace/base.txt"
  git -C "$GAAI_WORKTREES_BASE/EF3-workspace" add base.txt
  git -C "$GAAI_WORKTREES_BASE/EF3-workspace" commit -qm base
  # The earlier commit-stall matrix intentionally replaces this helper with a
  # verified stub. Re-extract the production function so this falsifier reaches
  # the actual pre-authority repair path rather than that unrelated fixture.
  eval "$(awk '/^_forward_worktree_state\(\)/{on=1} /^# Populates the _FORWARD_/{on=0} on{print}' "$DAEMON")"
  _check_worktree_integrity(){ return 1; }
  _recover_worktree_safe_base(){ : > "$TMP/red-f3-repair-called"; return 1; }
  _forward_classify(){ return 1; }
  _forward_evidence(){ :; }
  f3_rc=0
  _forward_recovery_one EF3 || f3_rc=$?
  rm -f "$TMP/red-f3-repair-called"
  _forward_classify(){
    _FORWARD_ACTION=block_invalid_record
    _FORWARD_REASON=invalid_lifecycle
    _FORWARD_STATUS=refined
    _FORWARD_PHASE=not_started
    return 0
  }
  _forward_prepare_worktree(){ : > "$TMP/red-f3-main-repair-called"; return 1; }
  f3_main_rc=0
  if _forward_classify EF3 main unknown false \
      && _forward_main_record_admitted pre; then
    _forward_prepare_worktree EF3 1111111111111111111111111111111111111111 true \
      || f3_main_rc=$?
  else
    f3_main_rc=$?
  fi
  printf '%s:%s:%s:%s\n' "$f3_rc" \
    "$([[ -e "$TMP/red-f3-repair-called" ]] && printf repair || printf no-repair)" \
    "$f3_main_rc" \
    "$([[ -e "$TMP/red-f3-main-repair-called" ]] && printf repair || printf no-repair)" \
    > "$TMP/red-f3-result"
)
printf '  RED-F3 observed=%s expected=1:no-repair:1:no-repair\n' "$(cat "$TMP/red-f3-result")"
expect "RED-F3 unavailable target authority cannot mutate worktree" \
  test "$(cat "$TMP/red-f3-result")" = "1:no-repair:1:no-repair"

# F4 — replace the private index inode after `git show`. A parser that merely
# reopens the path accepts the attack as an empty queue; descriptor/blob binding
# rejects it. A genuinely canonical empty queue remains a no-op.
(
  LOCK_DIR="$TMP/red-f4-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  PROJECT_DIR="$TMP/red-f4-repo"; REPO_ROOT="$PROJECT_DIR"
  BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
  BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"; BACKLOG="$BACKLOG_FILE"
  TARGET_BRANCH=staging
  git init --bare "$TMP/red-f4-origin.git" >/dev/null
  git init "$PROJECT_DIR" >/dev/null
  git -C "$PROJECT_DIR" config user.email test@example.invalid
  git -C "$PROJECT_DIR" config user.name test
  git -C "$PROJECT_DIR" remote add origin "$TMP/red-f4-origin.git"
  git -C "$PROJECT_DIR" remote set-url --push origin "$TMP/red-f4-origin.git"
  [[ "$(git -C "$PROJECT_DIR" remote get-url --push origin)" == "$TMP/red-f4-origin.git" ]] || exit 1
  mkdir -p "$(dirname "$BACKLOG_FILE")"
  printf 'items:\n- id: EF4\n  status: in_progress\n  phase_status: implemented\n  started_at: "2026-08-25T10:00:00Z"\n' > "$BACKLOG_FILE"
  git -C "$PROJECT_DIR" add "$BACKLOG_REL"
  git -C "$PROJECT_DIR" commit -qm populated
  git -C "$PROJECT_DIR" push -q origin HEAD:staging
  # The seam is a redefinition of the boundary entry, not a `python3` shell
  # function: a shell function cannot intercept a command word containing a
  # slash, and the boundary invokes an absolute interpreter path.
  #
  # THE ARGV SHAPE CHANGED AND THE PREDICATE IS REWRITTEN, NOT PORTED. The base
  # caller spelled `python3 - "$path"`, so the sentinel was $1 and the path $2.
  # The boundary entry takes the caller program on stdin and NO `-` sentinel in
  # argv, so the path arrives as $1 and every later argument shifts down by one.
  # A predicate still keyed on $2 would silently stop matching, the swap would
  # never fire, and this falsifier would report a false pass — which is why the
  # expected result below is asserted as 1:0:0 and not merely "non-zero".
  RED_F4_SWAP=true
  _red_f4_real=$(declare -f yaml_runtime_run)
  yaml_runtime_run(){
    if [[ "$RED_F4_SWAP" == true && "${1:-}" == "$LOCK_DIR"/.forward-index-* ]]; then
      printf 'items: []\n' > "${1}.successor"
      chmod 600 "${1}.successor"
      mv "${1}.successor" "$1"
    fi
    eval "${_red_f4_real/#yaml_runtime_run/_red_f4_orig}"
    _red_f4_orig "$@"
  }
  _forward_recovery_one(){ : > "$TMP/red-f4-dispatched"; return 0; }
  f4_swap_rc=0
  forward_recovery_scan || f4_swap_rc=$?
  RED_F4_SWAP=false
  printf 'items: []\n' > "$BACKLOG_FILE"
  git -C "$PROJECT_DIR" add "$BACKLOG_REL"
  git -C "$PROJECT_DIR" commit -qm empty
  git -C "$PROJECT_DIR" push -q -f origin HEAD:staging
  f4_empty_rc=0
  forward_recovery_scan || f4_empty_rc=$?
  f4_unsafe=0
  rg -n 'yaml\.safe_load\(open\(' "$DAEMON" >/dev/null 2>&1 && f4_unsafe=1
  printf '%s:%s:%s\n' "$f4_swap_rc" "$f4_empty_rc" "$f4_unsafe" \
    > "$TMP/red-f4-result"
)
printf '  RED-F4 observed=%s expected=1:0:0\n' "$(cat "$TMP/red-f4-result")"
expect "RED-F4 descriptor-bound canonical index distinguishes swap from valid empty" \
  test "$(cat "$TMP/red-f4-result")" = "1:0:0"

# F5 — durable sub-threshold state is the exact restart checkpoint after the
# event inode was consumed. Re-observation must not need or invent an event.
(
  LOCK_DIR="$TMP/red-f5-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  f5_repo="$TMP/red-f5-repo"
  git init "$f5_repo" >/dev/null
  git -C "$f5_repo" config user.email test@example.invalid
  git -C "$f5_repo" config user.name test
  printf 'base\n' > "$f5_repo/app.txt"
  git -C "$f5_repo" add app.txt; git -C "$f5_repo" commit -qm base
  git -C "$f5_repo" update-ref refs/remotes/origin/staging HEAD
  printf 'candidate\n' >> "$f5_repo/app.txt"
  git -C "$f5_repo" add app.txt; git -C "$f5_repo" commit -qm candidate
  _commit_retry_write_observation EF5 blocked:tests_failed || exit 1
  f5_first=$(_commit_retry_observe EF5 "$f5_repo" origin/staging 3) || exit 1
  f5_state_before=$(_commit_retry_state_snapshot EF5) || exit 1
  f5_second_rc=0
  f5_second=$(_commit_retry_observe EF5 "$f5_repo" origin/staging 3) || f5_second_rc=$?
  f5_state_after=$(_commit_retry_state_snapshot EF5) || exit 1
  printf '%s\t%s\t%s\t%s\n' "$f5_second_rc" "$f5_first" "$f5_second" \
    "$([[ "$f5_state_before" == "$f5_state_after" ]] && printf same || printf changed)" \
    > "$TMP/red-f5-result"
)
printf '  RED-F5 observed=%s expected=0:<same result>:same\n' "$(cat "$TMP/red-f5-result")"
IFS=$'\t' read -r f5_rc f5_first f5_second f5_same < "$TMP/red-f5-result"
expect "RED-F5 consumed sub-threshold event resumes exact state without increment" \
  test "$f5_rc:$f5_first:$f5_second:$f5_same" = "0:$f5_first:$f5_first:same"

# F6 — descriptor retirement must restore a raced successor at its canonical
# name (or preserve both when occupied), never strand it in quarantine.
(
  LOCK_DIR="$TMP/red-f6-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  f6_repo="$TMP/red-f6-repo"
  git init "$f6_repo" >/dev/null
  git -C "$f6_repo" config user.email test@example.invalid
  git -C "$f6_repo" config user.name test
  printf 'base\n' > "$f6_repo/app.txt"
  git -C "$f6_repo" add app.txt; git -C "$f6_repo" commit -qm base
  git -C "$f6_repo" update-ref refs/remotes/origin/staging HEAD
  printf 'candidate\n' >> "$f6_repo/app.txt"
  git -C "$f6_repo" add app.txt; git -C "$f6_repo" commit -qm candidate
  _commit_retry_write_observation EF6 blocked:tests_failed || exit 1
  f6_event=$(_commit_retry_observation_path EF6)
  f6_successor="$LOCK_DIR/.commit-retry-successor-EF6"
  _commit_retry_publish_record observation "$f6_successor" EF6 blocked:other_failure || exit 1
  f6_old_bytes=$(cat "$f6_event"); f6_successor_bytes=$(cat "$f6_successor")
  f6_fault="$TMP/red-f6-python"; mkdir -p "$f6_fault"
  cat > "$f6_fault/sitecustomize.py" <<'PY'
import os
_real_rename = os.rename
_done = False
def _race(src, dst, *args, **kwargs):
    global _done
    with open(os.environ["GAAI_F6_TRACE"], "a", encoding="utf-8") as trace:
        trace.write(repr((src, dst, kwargs)) + "\n")
    if (not _done and src == ".commit-retry-observation-EF6"
            and ".commit-retry-observation-EF6." in str(dst)
            and str(dst).endswith(".retire")):
        _done = True
        sfd = kwargs.get("src_dir_fd")
        dfd = kwargs.get("dst_dir_fd")
        _real_rename(src, ".commit-retry-predecessor-EF6", src_dir_fd=sfd, dst_dir_fd=dfd)
        _real_rename(".commit-retry-successor-EF6", src, src_dir_fd=sfd, dst_dir_fd=sfd)
    return _real_rename(src, dst, *args, **kwargs)
os.rename = _race
PY
  f6_rc=0
  GAAI_F6_FAULT_PY="$f6_fault/sitecustomize.py"; export GAAI_F6_FAULT_PY
  GAAI_F6_TRACE="${GAAI_RED_RECEIPT_DIR:-$TMP}/red-f6-rename.trace"; export GAAI_F6_TRACE
  _COMMIT_RETRY_COMMON_PY="${_COMMIT_RETRY_COMMON_PY}
exec(open(os.environ['GAAI_F6_FAULT_PY'], encoding='utf-8').read())"
  _commit_retry_observe EF6 "$f6_repo" origin/staging 3 >/dev/null || f6_rc=$?
  unset GAAI_F6_FAULT_PY GAAI_F6_TRACE
  f6_current=missing; [[ -e "$f6_event" ]] && f6_current=$(cat "$f6_event")
  f6_predecessor=missing
  [[ -e "$LOCK_DIR/.commit-retry-predecessor-EF6" ]] \
    && f6_predecessor=$(cat "$LOCK_DIR/.commit-retry-predecessor-EF6")
  printf '%s:%s:%s\n' "$f6_rc" \
    "$([[ "$f6_current" == "$f6_successor_bytes" ]] && printf successor || printf lost)" \
    "$([[ "$f6_predecessor" == "$f6_old_bytes" ]] && printf predecessor || printf lost)" \
    > "$TMP/red-f6-result"
)
printf '  RED-F6 observed=%s expected=1:successor:predecessor\n' "$(cat "$TMP/red-f6-result")"
expect "RED-F6 ABA retirement preserves successor and predecessor evidence" \
  test "$(cat "$TMP/red-f6-result")" = "1:successor:predecessor"

# F7 — every closed main/recovery decision needs one bounded evidence record;
# value-bearing operational prose is not the evidence grammar.
python3 - "$DAEMON" "$TMP/red-f7-result" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("# Fresh pre-claim admission")
end = text.index("# Under set -e", start)
lines = text[start:end].splitlines()
silent = 0
for index, line in enumerate(lines):
    if "continue" not in line:
        continue
    window = "\n".join(lines[max(0, index - 8):index + 1])
    if "_forward_evidence" not in window and "_forward_main_hold" not in window:
        silent += 1
leaks = 0
for match in re.finditer(r"(?:log|notify_escalation)[^\n]*(?:\n[^\n]*){0,2}", text):
    block = match.group(0)
    if any(token in block for token in (
        "${_cd_outcome}", "${_cd_new}", "phase_status=commit_stalled",
    )):
        leaks += 1
open(sys.argv[2], "w", encoding="ascii").write(f"{silent}:{leaks}\n")
PY
printf '  RED-F7 observed=%s expected=0:0\n' "$(cat "$TMP/red-f7-result")"
expect "RED-F7 every closed main-loop path emits bounded names-only evidence" \
  test "$(cat "$TMP/red-f7-result")" = "0:0"
f7_source=$(printf '7%.0s' $(seq 1 64))
f7_record=$(printf '8%.0s' $(seq 1 64))
eval "$(awk '/^_forward_evidence\(\)/{on=1} /^# Context intentions/{on=0} on{print}' "$DAEMON")"
f7_line=$(_forward_main_hold EF7 pending_run "$f7_source" "$f7_record" 2>&1)
expect "F7 main hold emits one exact names-only evidence record" \
  test "$f7_line" = \
    "[FORWARD-RECOVERY] story=EF7 writer=recovery.scan outcome=held reason=pending_run attempt=none source_digest=$f7_source record_digest=$f7_record fields=none"
_FORWARD_SOURCE_DIGEST=$(printf '9%.0s' $(seq 1 64))
_FORWARD_RECORD_DIGEST=$(printf 'a%.0s' $(seq 1 64))
f7_zero=$(printf '0%.0s' $(seq 1 64))
f7_unbound=$(_forward_main_hold EF7 source_unavailable 2>&1)
expect "F7 pre-authority hold cannot inherit ambient Story digests" \
  test "$f7_unbound" = \
    "[FORWARD-RECOVERY] story=EF7 writer=recovery.scan outcome=held reason=source_unavailable attempt=none source_digest=$f7_zero record_digest=$f7_zero fields=none"

printf '\nSecond global QA remediation RED falsifiers (G1-G4)\n'

# G1 — the private context action that carries the exact commit-stall
# intention is distinct from the intention-free operator hold observed after
# the remote projection is already current.
python3 - "$DAEMON" "$CLASSIFIER" "$TMP/red-g1-result" <<'PY'
import re, sys
daemon = open(sys.argv[1], encoding="utf-8").read()
classifier = open(sys.argv[2], encoding="utf-8").read()
has_action = "forward_commit_stall" in daemon and "forward_commit_stall" in classifier
wrong_hold = (
    re.search(
        r"hold_operator\s+\\\s*\n\s*policy_stall\s+phase_status=commit_stalled",
        daemon,
    ) is not None
    or re.search(
        r'\("hold_operator", "policy_stall"\):\s*\('
        r'any_integrity,\s*\{[^}]*phase_status=commit_stalled[^}]*\}\s*\)',
        classifier,
        re.DOTALL,
    ) is not None
)
open(sys.argv[3], "w", encoding="ascii").write(
    f"{int(has_action)}:{int(wrong_hold)}\n"
)
PY
printf '  RED-G1 observed=%s expected=1:0\n' "$(cat "$TMP/red-g1-result")"
expect "RED-G1 commit stall uses its closed action, never mutating hold_operator" \
  test "$(cat "$TMP/red-g1-result")" = "1:0"

# G2 — a malformed retained manifest must be authenticated before either the
# recovery coordinator or the relaunch boundary can call a mutating worktree
# preparation/revalidation helper.
(
  g2_source=1111111111111111111111111111111111111111
  g2_blob=2222222222222222222222222222222222222222
  g2_record=$(printf '3%.0s' $(seq 1 64))
  g2_digest=$(printf '4%.0s' $(seq 1 64))
  mkdir -p "$TMP/red-g2-worktree"
  _forward_resolve_worktree(){ printf '%s\n' "$TMP/red-g2-worktree"; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_STATUS=in_progress; _FORWARD_PHASE=implemented
    _FORWARD_SOURCE="$g2_source"; _FORWARD_BLOB="$g2_blob"
    _FORWARD_RECORD_DIGEST="$g2_record"; _FORWARD_SOURCE_DIGEST="$g2_digest"
    _FORWARD_SNAPSHOT="$TMP/red-g2-snapshot"; : > "$_FORWARD_SNAPSHOT"
  }
  _forward_absent_context_admitted(){ return 1; }
  _forward_prepare_worktree(){ : > "$TMP/red-g2-recovery-mutated"; printf 'verified\n'; }
  _journal_inspect_pending_lifecycle(){ printf 'malformed\n'; return 0; }
  _forward_evidence(){ return 0; }
  g2_recovery_rc=0
  _forward_recovery_one EG2 || g2_recovery_rc=$?

  forward_context_read(){
    printf 'EG2\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s\n' \
      "$g2_source" "$g2_blob" "$g2_record" "$g2_digest"
  }
  _forward_revalidate_after_reconcile(){
    : > "$TMP/red-g2-relaunch-mutated"
    _FORWARD_FINAL_INTEGRITY=verified
    return 0
  }
  g2_relaunch_rc=0
  _forward_relaunch EG2 "$TMP/red-g2-context" "$g2_digest" || g2_relaunch_rc=$?
  printf '%s:%s:%s:%s\n' "$g2_recovery_rc" \
    "$([[ -e "$TMP/red-g2-recovery-mutated" ]] && printf mutated || printf preserved)" \
    "$g2_relaunch_rc" \
    "$([[ -e "$TMP/red-g2-relaunch-mutated" ]] && printf mutated || printf preserved)" \
    > "$TMP/red-g2-result"
)
printf '  RED-G2 observed=%s expected=1:preserved:1:preserved\n' \
  "$(cat "$TMP/red-g2-result")"
expect "RED-G2 retained manifest authentication precedes every worktree mutation" \
  test "$(cat "$TMP/red-g2-result")" = "1:preserved:1:preserved"

# G3 — a descriptor-authenticated no-attempt context from ancestor A must be
# safely superseded after the target owner advances to eligible B. The old
# context cannot become a permanent blocker.
(
  LOCK_DIR="$TMP/red-g3-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  _forward_context_path(){ printf '%s/recovery.scan.%s.json\n' "$LOCK_DIR" "$1"; }
  GAAI_WORKTREES_BASE="$TMP/red-g3-worktrees"
  mkdir -p "$GAAI_WORKTREES_BASE/EG3-workspace"
  g3_a=1111111111111111111111111111111111111111
  g3_b=2222222222222222222222222222222222222222
  g3_blob_a=3333333333333333333333333333333333333333
  g3_blob_b=4444444444444444444444444444444444444444
  g3_record_a=$(printf '5%.0s' $(seq 1 64))
  g3_record_b=$(printf '6%.0s' $(seq 1 64))
  g3_source_digest=$(printf '7%.0s' $(seq 1 64))
  g3_context=$(_forward_context_path EG3) || exit 1
  forward_context_install "$g3_context" EG3 "$g3_a" "$g3_blob_a" \
    "$g3_record_a" none none none none none none verified resume resumable none \
    || exit 1
  _forward_resolve_worktree(){ printf '%s\n' "$GAAI_WORKTREES_BASE/EG3-workspace"; }
  _forward_plan_present(){ return 0; }
  _forward_prepare_worktree(){ printf 'verified\n'; }
  _forward_classify(){
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_STATUS=in_progress; _FORWARD_PHASE=implemented
    _FORWARD_SOURCE="$g3_b"; _FORWARD_BLOB="$g3_blob_b"
    _FORWARD_RECORD_DIGEST="$g3_record_b"
    _FORWARD_SOURCE_DIGEST="$g3_source_digest"
    _FORWARD_SNAPSHOT="$TMP/red-g3-current"; : > "$_FORWARD_SNAPSHOT"
  }
  _journal_inspect_pending_lifecycle(){ return 2; }
  forward_classify_snapshot(){
    printf 'resume\tresumable\tin_progress\timplemented\t2026-08-25T10:00:00Z\t%s\t%s\t%s\n' \
      "$g3_record_a" "$g3_a" "$g3_blob_a"
  }
  git(){
    case " $* " in
      *' merge-base --is-ancestor '*) return 0 ;;
      *' rev-parse '*) printf '%s\n' "$g3_blob_a" ;;
      *' show '*) printf 'items:\n- id: EG3\n  status: in_progress\n  phase_status: implemented\n  started_at: "2026-08-25T10:00:00Z"\n' ;;
      *) command git "$@" ;;
    esac
  }
  _forward_revalidate_after_reconcile(){
    _FORWARD_SOURCE="$g3_b"; _FORWARD_BLOB="$g3_blob_b"
    _FORWARD_RECORD_DIGEST="$g3_record_b"; _FORWARD_SOURCE_DIGEST="$g3_source_digest"
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_FINAL_INTEGRITY=verified
    _FORWARD_SNAPSHOT="$TMP/red-g3-final"; : > "$_FORWARD_SNAPSHOT"
  }
  _forward_lock_state(){ printf 'absent\tnone\n'; }
  _forward_active_markers_clear(){ return 0; }
  _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }
  MAX_CONCURRENT=1
  active_count(){ printf '0\n'; }
  has_exceeded_retries(){ return 1; }
  _reconcile_story_file_from_staging(){ return 0; }
  node(){ printf '00000000-0000-4000-8000-000000000003'; }
  g3_retry=0; g3_spawn=0
  increment_retry(){ g3_retry=$((g3_retry + 1)); }
  launch_3phase_in_tmux(){ g3_spawn=$((g3_spawn + 1)); }
  _forward_evidence(){ return 0; }
  g3_rc=0
  _forward_recovery_one EG3 || g3_rc=$?
  printf '%s:%s:%s:%s\n' "$g3_rc" \
    "$([[ -e "$g3_context" ]] && printf present || printf absent)" \
    "$g3_retry" "$g3_spawn" > "$TMP/red-g3-result"

  # Evidence is durable authorization for supersession. If it cannot be
  # recorded, the exact A context remains and no B effect is attempted.
  forward_context_install "$g3_context" EG3 "$g3_a" "$g3_blob_a" \
    "$g3_record_a" none none none none none none verified resume resumable none \
    || exit 1
  _forward_evidence(){ return 1; }
  g3_retry=0; g3_spawn=0; g3_evidence_rc=0
  _forward_recovery_one EG3 || g3_evidence_rc=$?
  g3_evidence_row=$(forward_context_read "$g3_context") || exit 1
  IFS=$'\t' read -r _ g3_evidence_source _ <<< "$g3_evidence_row"
  printf '%s:%s:%s:%s\n' "$g3_evidence_rc" "$g3_evidence_source" \
    "$g3_retry" "$g3_spawn" > "$TMP/red-g3-evidence-result"

  # A second target advance during the final relaunch revalidation leaves the
  # freshly bound B context recoverable but cannot increment or spawn B.
  g3_evidence_digest=${g3_evidence_row##*$'\t'}
  forward_context_remove "$g3_context" "$g3_evidence_digest" || exit 1
  forward_context_install "$g3_context" EG3 "$g3_a" "$g3_blob_a" \
    "$g3_record_a" none none none none none none verified resume resumable none \
    || exit 1
  _forward_evidence(){ return 0; }
  g3_c=8888888888888888888888888888888888888888
  g3_blob_c=9999999999999999999999999999999999999999
  g3_record_c=$(printf 'a%.0s' $(seq 1 64))
  g3_revalidate_calls=0
  _forward_revalidate_after_reconcile(){
    g3_revalidate_calls=$((g3_revalidate_calls + 1))
    if [[ "$g3_revalidate_calls" -eq 1 ]]; then
      _FORWARD_SOURCE="$g3_b"; _FORWARD_BLOB="$g3_blob_b"
      _FORWARD_RECORD_DIGEST="$g3_record_b"
      _FORWARD_SOURCE_DIGEST="$g3_source_digest"
      _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
      _FORWARD_FINAL_INTEGRITY=verified
      _FORWARD_SNAPSHOT="$TMP/red-g3-race-b"; : > "$_FORWARD_SNAPSHOT"
      return 0
    fi
    _FORWARD_SOURCE="$g3_c"; _FORWARD_BLOB="$g3_blob_c"
    _FORWARD_RECORD_DIGEST="$g3_record_c"
    _FORWARD_SNAPSHOT="$TMP/red-g3-race-c"; : > "$_FORWARD_SNAPSHOT"
    return 1
  }
  g3_retry=0; g3_spawn=0; g3_race_rc=0
  _forward_recovery_one EG3 || g3_race_rc=$?
  g3_race_row=$(forward_context_read "$g3_context") || exit 1
  IFS=$'\t' read -r _ g3_race_source _ <<< "$g3_race_row"
  printf '%s:%s:%s:%s:%s\n' "$g3_race_rc" "$g3_race_source" \
    "$g3_retry" "$g3_spawn" "$g3_revalidate_calls" \
    > "$TMP/red-g3-race-result"
)
printf '  RED-G3 observed=%s expected=0:absent:1:1\n' "$(cat "$TMP/red-g3-result")"
expect "RED-G3 ancestor no-attempt context is superseded and launches B once" \
  test "$(cat "$TMP/red-g3-result")" = "0:absent:1:1"
printf '  G3 evidence observed=%s expected=4:%s:0:0\n' \
  "$(cat "$TMP/red-g3-evidence-result")" \
  1111111111111111111111111111111111111111
expect "G3 evidence failure preserves A context before CAS" \
  test "$(cat "$TMP/red-g3-evidence-result")" = \
    "4:1111111111111111111111111111111111111111:0:0"
printf '  G3 race observed=%s expected=1:%s:0:0:2\n' \
  "$(cat "$TMP/red-g3-race-result")" \
  2222222222222222222222222222222222222222
expect "G3 A-to-B-to-C final drift preserves B context without effect" \
  test "$(cat "$TMP/red-g3-race-result")" = \
    "1:2222222222222222222222222222222222222222:0:0:2"

# G4 — evidence is a fail-closed operation, not best-effort text. Dynamic
# recovery injection proves return propagation; the static main-loop census
# rejects every unchecked hold/evidence before a continue or later Story.
(
  LOCK_DIR="$TMP/red-g4-locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  _forward_context_path(){ printf '%s/recovery.scan.%s.json\n' "$LOCK_DIR" "$1"; }
  g4_source=1111111111111111111111111111111111111111
  g4_blob=2222222222222222222222222222222222222222
  g4_record=$(printf '3%.0s' $(seq 1 64))
  g4_digest=$(printf '4%.0s' $(seq 1 64))
  mkdir -p "$TMP/red-g4-worktree"
  _forward_resolve_worktree(){ printf '%s\n' "$TMP/red-g4-worktree"; }
  _forward_plan_present(){ return 0; }
  _forward_prepare_worktree(){ printf 'verified\n'; }
  _forward_absent_context_admitted(){ return 1; }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _forward_classify(){
    _FORWARD_ACTION=hold_downstream; _FORWARD_REASON=merge_terminal_owned
    _FORWARD_STATUS=in_progress; _FORWARD_PHASE=done
    _FORWARD_SOURCE="$g4_source"; _FORWARD_BLOB="$g4_blob"
    _FORWARD_RECORD_DIGEST="$g4_record"; _FORWARD_SOURCE_DIGEST="$g4_digest"
    _FORWARD_SNAPSHOT="$TMP/red-g4-snapshot"; : > "$_FORWARD_SNAPSHOT"
  }
  _forward_evidence(){ return 1; }
  g4_recovery_rc=0
  _forward_recovery_one EG4 || g4_recovery_rc=$?
  printf '%s\n' "$g4_recovery_rc" > "$TMP/red-g4-dynamic-result"

  # A temporary relaunch inhibition is normally scan-success/pending (rc2).
  # If its evidence cannot be emitted, it becomes a hard scan failure while
  # preserving the exact context for the next restart/periodic cycle.
  _forward_classify(){
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_STATUS=in_progress; _FORWARD_PHASE=implemented
    _FORWARD_SOURCE="$g4_source"; _FORWARD_BLOB="$g4_blob"
    _FORWARD_RECORD_DIGEST="$g4_record"; _FORWARD_SOURCE_DIGEST="$g4_digest"
    _FORWARD_SNAPSHOT="$TMP/red-g4-deferred-snapshot"; : > "$_FORWARD_SNAPSHOT"
  }
  _forward_relaunch(){ return 2; }
  g4_deferred_rc=0
  _forward_recovery_one EG4 || g4_deferred_rc=$?
  g4_deferred_context=$(_forward_context_path EG4) || exit 1
  printf '%s:%s\n' "$g4_deferred_rc" \
    "$([[ -e "$g4_deferred_context" ]] && printf present || printf absent)" \
    > "$TMP/red-g4-deferred-result"
)

# Execute the exact current main-loop orphan, periodic, capacity and
# retry/launcher blocks with a failing evidence sink. This fault injection
# runs production snippets, not a separately reimplemented control flow.
python3 - "$DAEMON" "$TMP/red-g4-main-boundaries.sh" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()

def through_first_fi(start_marker):
    start = text.index(start_marker)
    end = text.index("\n    fi", start) + len("\n    fi")
    return text[start:end]

def function_block(name):
    start = text.index(f"{name}() {{")
    end = text.index("\n}", start) + len("\n}")
    return text[start:end]

startup_start = text.index('_startup_recovery_rc=0')
startup_end = text.index('\nfi', startup_start) + len('\nfi')
startup = text[startup_start:startup_end]
capacity = through_first_fi('    if (( _live_active >= MAX_CONCURRENT )); then')
orphan_start = text.index('    _orphan_scan_rc=0')
orphan_end = text.index('\n    _orphan_scan_tick=0', orphan_start)
orphan = text[orphan_start:orphan_end]
periodic_start = text.index('    _periodic_recovery_rc=0')
periodic_end_marker = '    last_recovery_scan_ts=$(date +%s)\n  fi'
periodic_end = text.index(periodic_end_marker, periodic_start) \
    + len('    last_recovery_scan_ts=$(date +%s)')
periodic = text[periodic_start:periodic_end]
launch_start = text.index('    if ! increment_retry "$story_id"; then')
launch_if = text.index(
    '    if ! launch_3phase_in_tmux "$story_id" "$_trace_id"',
    launch_start,
)
launch_end = text.index("\n    fi", launch_if) + len("\n    fi")
launch = text[launch_start:launch_end]
evidence_fatal = function_block('_forward_evidence_fatal')
daemon_on_exit = function_block('_daemon_on_exit')

with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write(evidence_fatal + "\n")
    out.write(daemon_on_exit + "\n")
    out.write("g4_startup_boundary() {\n")
    out.write(startup + "\n")
    out.write("  : > \"$G4_STARTUP_LATER\"\n}\n")
    out.write("g4_orphan_boundary() {\n  for _g4_once in 1; do\n")
    out.write(orphan + "\n")
    out.write("  done\n  : > \"$G4_ORPHAN_LATER\"\n}\n")
    out.write("g4_periodic_boundary() {\n  for _g4_once in 1; do\n")
    out.write(periodic + "\n")
    out.write("  done\n  : > \"$G4_PERIODIC_LATER\"\n}\n")
    out.write("g4_capacity_boundary() {\n  for _g4_once in 1; do\n")
    out.write(capacity + "\n")
    out.write("  done\n  : > \"$G4_CAPACITY_LATER\"\n}\n")
    out.write("g4_launch_boundary() {\n  for _g4_once in 1; do\n")
    out.write(launch + "\n")
    out.write("  done\n  : > \"$G4_LAUNCH_LATER\"\n}\n")
PY

G4_FATAL_DIGEST=$(printf '4%.0s' $(seq 1 64)); export G4_FATAL_DIGEST
G4_STARTUP_LATER="$TMP/red-g4-startup-later"; export G4_STARTUP_LATER
G4_STARTUP_TRAP="$TMP/red-g4-startup-trap"; export G4_STARTUP_TRAP
G4_STARTUP_NOTIFY="$TMP/red-g4-startup-notify"; export G4_STARTUP_NOTIFY
g4_startup_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  LOCK_DIR="$G4_STARTUP_TRAP"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  RED=; NC=; _daemon_evidence_fatal=false
  _daemon_err_src=; _daemon_err_line=; _daemon_err_cmd=
  log(){ :; }
  notify_escalation(){ : > "$G4_STARTUP_NOTIFY"; }
  trap _daemon_on_exit EXIT
  forward_recovery_scan(){
    _forward_evidence EG4 blocked invalid_record none "$G4_FATAL_DIGEST" \
      "$G4_FATAL_DIGEST" none || return 4
  }
  g4_startup_boundary 2>&-
) || g4_startup_rc=$?
printf '%s:%s:%s:%s\n' "$g4_startup_rc" \
  "$([[ -e "$G4_STARTUP_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_STARTUP_TRAP/.daemon-crash" ]] && printf crash || printf no-crash)" \
  "$([[ -e "$G4_STARTUP_NOTIFY" ]] && printf notified || printf no-notify)" \
  > "$TMP/red-g4-startup-result"

G4_ORPHAN_LATER="$TMP/red-g4-orphan-later"; export G4_ORPHAN_LATER
G4_ORPHAN_SLEEP="$TMP/red-g4-orphan-sleep"; export G4_ORPHAN_SLEEP
G4_ORPHAN_TRAP="$TMP/red-g4-orphan-trap"; export G4_ORPHAN_TRAP
G4_ORPHAN_NOTIFY="$TMP/red-g4-orphan-notify"; export G4_ORPHAN_NOTIFY
g4_orphan_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  LOCK_DIR="$G4_ORPHAN_TRAP"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  RED=; NC=; POLL_INTERVAL=0; _daemon_evidence_fatal=false
  _daemon_err_src=; _daemon_err_line=; _daemon_err_cmd=
  log(){ :; }
  notify_escalation(){ : > "$G4_ORPHAN_NOTIFY"; }
  sleep(){ : > "$G4_ORPHAN_SLEEP"; }
  trap _daemon_on_exit EXIT
  cycle_orphan_lock_scan(){
    _forward_evidence EG4 blocked invalid_record none "$G4_FATAL_DIGEST" \
      "$G4_FATAL_DIGEST" none || return 4
  }
  g4_orphan_boundary 2>&-
) || g4_orphan_rc=$?
printf '%s:%s:%s:%s:%s\n' "$g4_orphan_rc" \
  "$([[ -e "$G4_ORPHAN_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_ORPHAN_SLEEP" ]] && printf slept || printf no-sleep)" \
  "$([[ -e "$G4_ORPHAN_TRAP/.daemon-crash" ]] && printf crash || printf no-crash)" \
  "$([[ -e "$G4_ORPHAN_NOTIFY" ]] && printf notified || printf no-notify)" \
  > "$TMP/red-g4-orphan-result"
rm -f "$G4_ORPHAN_LATER" "$G4_ORPHAN_SLEEP"
g4_orphan_retry_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  RED=; NC=; POLL_INTERVAL=0
  cycle_orphan_lock_scan(){ return 1; }
  log(){ :; }
  sleep(){ : > "$G4_ORPHAN_SLEEP"; }
  g4_orphan_boundary
) || g4_orphan_retry_rc=$?
printf '%s:%s:%s\n' "$g4_orphan_retry_rc" \
  "$([[ -e "$G4_ORPHAN_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_ORPHAN_SLEEP" ]] && printf slept || printf no-sleep)" \
  > "$TMP/red-g4-orphan-retry-result"

G4_PERIODIC_LATER="$TMP/red-g4-periodic-later"; export G4_PERIODIC_LATER
G4_PERIODIC_SLEEP="$TMP/red-g4-periodic-sleep"; export G4_PERIODIC_SLEEP
G4_PERIODIC_TRAP="$TMP/red-g4-periodic-trap"; export G4_PERIODIC_TRAP
G4_PERIODIC_NOTIFY="$TMP/red-g4-periodic-notify"; export G4_PERIODIC_NOTIFY
g4_periodic_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  LOCK_DIR="$G4_PERIODIC_TRAP"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  RED=; NC=; POLL_INTERVAL=0; last_recovery_scan_ts=0
  _daemon_evidence_fatal=false; _daemon_err_src=; _daemon_err_line=; _daemon_err_cmd=
  log(){ :; }
  notify_escalation(){ : > "$G4_PERIODIC_NOTIFY"; }
  sleep(){ : > "$G4_PERIODIC_SLEEP"; }
  trap _daemon_on_exit EXIT
  forward_recovery_scan(){
    _forward_evidence EG4 blocked invalid_record none "$G4_FATAL_DIGEST" \
      "$G4_FATAL_DIGEST" none || return 4
  }
  g4_periodic_boundary 2>&-
) || g4_periodic_rc=$?
printf '%s:%s:%s:%s:%s\n' "$g4_periodic_rc" \
  "$([[ -e "$G4_PERIODIC_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_PERIODIC_SLEEP" ]] && printf slept || printf no-sleep)" \
  "$([[ -e "$G4_PERIODIC_TRAP/.daemon-crash" ]] && printf crash || printf no-crash)" \
  "$([[ -e "$G4_PERIODIC_NOTIFY" ]] && printf notified || printf no-notify)" \
  > "$TMP/red-g4-periodic-result"
rm -f "$G4_PERIODIC_LATER" "$G4_PERIODIC_SLEEP"
g4_periodic_retry_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  RED=; NC=; POLL_INTERVAL=0; last_recovery_scan_ts=0
  forward_recovery_scan(){ return 1; }
  log(){ :; }
  sleep(){ : > "$G4_PERIODIC_SLEEP"; }
  g4_periodic_boundary
) || g4_periodic_retry_rc=$?
printf '%s:%s:%s\n' "$g4_periodic_retry_rc" \
  "$([[ -e "$G4_PERIODIC_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_PERIODIC_SLEEP" ]] && printf slept || printf no-sleep)" \
  > "$TMP/red-g4-periodic-retry-result"

G4_CAPACITY_LATER="$TMP/red-g4-capacity-later"; export G4_CAPACITY_LATER
G4_CAPACITY_TRAP="$TMP/red-g4-capacity-trap"; export G4_CAPACITY_TRAP
G4_CAPACITY_NOTIFY="$TMP/red-g4-capacity-notify"; export G4_CAPACITY_NOTIFY
g4_capacity_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  LOCK_DIR="$G4_CAPACITY_TRAP"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  RED=; NC=; _daemon_evidence_fatal=false
  _daemon_err_src=; _daemon_err_line=; _daemon_err_cmd=
  log(){ :; }
  notify_escalation(){ : > "$G4_CAPACITY_NOTIFY"; }
  trap _daemon_on_exit EXIT
  story_id=EG4; _live_active=1; MAX_CONCURRENT=1
  _post_source_digest=$(printf '4%.0s' $(seq 1 64))
  _post_record=$(printf '3%.0s' $(seq 1 64))
  g4_capacity_boundary 2>&-
) || g4_capacity_rc=$?
printf '%s:%s:%s:%s\n' "$g4_capacity_rc" \
  "$([[ -e "$G4_CAPACITY_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_CAPACITY_TRAP/.daemon-crash" ]] && printf crash || printf no-crash)" \
  "$([[ -e "$G4_CAPACITY_NOTIFY" ]] && printf notified || printf no-notify)" \
  > "$TMP/red-g4-capacity-result"

G4_RETRY="$TMP/red-g4-retry"; export G4_RETRY
G4_SPAWN="$TMP/red-g4-spawn"; export G4_SPAWN
G4_LAUNCH_LATER="$TMP/red-g4-launch-later"; export G4_LAUNCH_LATER
G4_LAUNCH_TRAP="$TMP/red-g4-launch-trap"; export G4_LAUNCH_TRAP
G4_LAUNCH_NOTIFY="$TMP/red-g4-launch-notify"; export G4_LAUNCH_NOTIFY
g4_launch_rc=0
(
  # shellcheck disable=SC1090
  source "$TMP/red-g4-main-boundaries.sh"
  LOCK_DIR="$G4_LAUNCH_TRAP"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  RED=; NC=; _daemon_evidence_fatal=false
  _daemon_err_src=; _daemon_err_line=; _daemon_err_cmd=
  log(){ :; }
  notify_escalation(){ : > "$G4_LAUNCH_NOTIFY"; }
  trap _daemon_on_exit EXIT
  story_id=EG4; _trace_id=00000000-0000-4000-8000-000000000004
  _FORWARD_SOURCE_DIGEST=$(printf '4%.0s' $(seq 1 64))
  _FORWARD_RECORD_DIGEST=$(printf '3%.0s' $(seq 1 64))
  _claim_source=1111111111111111111111111111111111111111
  _claim_blob=2222222222222222222222222222222222222222
  _claim_record="$_FORWARD_RECORD_DIGEST"
  increment_retry(){ printf 'durable\n' > "$G4_RETRY"; }
  launch_3phase_in_tmux(){ printf 'attempted\n' > "$G4_SPAWN"; return 1; }
  g4_launch_boundary 2>&-
) || g4_launch_rc=$?
printf '%s:%s:%s:%s:%s:%s\n' "$g4_launch_rc" \
  "$([[ -e "$G4_RETRY" ]] && printf retained || printf absent)" \
  "$([[ -e "$G4_SPAWN" ]] && printf attempted || printf absent)" \
  "$([[ -e "$G4_LAUNCH_LATER" ]] && printf reached || printf stopped)" \
  "$([[ -e "$G4_LAUNCH_TRAP/.daemon-crash" ]] && printf crash || printf no-crash)" \
  "$([[ -e "$G4_LAUNCH_NOTIFY" ]] && printf notified || printf no-notify)" \
  > "$TMP/red-g4-launch-result"

python3 - "$DAEMON" "$TMP/red-g4-static-result" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
unchecked = 0
lines = text.splitlines()
for index, line in enumerate(lines):
    if re.search(r"\b_forward_(?:evidence|evidence_for_intention|main_hold)\b", line):
        stripped = line.strip()
        if stripped.endswith("() {"):
            continue
        statement = stripped
        cursor = index
        while statement.rstrip().endswith("\\") and cursor + 1 < len(lines):
            cursor += 1
            statement += " " + lines[cursor].strip()
        intentional_return = (
            '_forward_evidence "$sid" "$outcome" "$reason"' in statement
            or '_forward_evidence "$sid" held "$reason"' in statement
        )
        if not intentional_return and not statement.startswith("if ! ") \
                and "||" not in statement:
            unchecked += 1
open(sys.argv[2], "w", encoding="ascii").write(f"{unchecked}\n")
PY
printf '  RED-G4 observed=%s:%s expected=4:0\n' \
  "$(cat "$TMP/red-g4-dynamic-result")" "$(cat "$TMP/red-g4-static-result")"
expect "RED-G4 evidence failures propagate and main-loop callsites are checked" \
  test "$(cat "$TMP/red-g4-dynamic-result"):$(cat "$TMP/red-g4-static-result")" = "4:0"
printf '  G4 deferred observed=%s expected=4:present\n' \
  "$(cat "$TMP/red-g4-deferred-result")"
expect "G4 deferred evidence failure preserves context and blocks scan" \
  test "$(cat "$TMP/red-g4-deferred-result")" = "4:present"
printf '  G4 startup observed=%s expected=1:stopped:no-crash:no-notify\n' \
  "$(cat "$TMP/red-g4-startup-result")"
expect "G4 startup evidence failure exits without crash or notification fallback" \
  test "$(cat "$TMP/red-g4-startup-result")" = \
    "1:stopped:no-crash:no-notify"
printf '  G4 orphan observed=%s expected=1:stopped:no-sleep:no-crash:no-notify\n' \
  "$(cat "$TMP/red-g4-orphan-result")"
expect "G4 cycle-orphan evidence failure terminates instead of retrying" \
  test "$(cat "$TMP/red-g4-orphan-result")" = \
    "1:stopped:no-sleep:no-crash:no-notify"
printf '  G4 orphan retry observed=%s expected=0:reached:slept\n' \
  "$(cat "$TMP/red-g4-orphan-retry-result")"
expect "G4 ordinary cycle-orphan block remains retryable" \
  test "$(cat "$TMP/red-g4-orphan-retry-result")" = "0:reached:slept"
printf '  G4 periodic observed=%s expected=1:stopped:no-sleep:no-crash:no-notify\n' \
  "$(cat "$TMP/red-g4-periodic-result")"
expect "G4 periodic evidence failure terminates instead of retrying" \
  test "$(cat "$TMP/red-g4-periodic-result")" = \
    "1:stopped:no-sleep:no-crash:no-notify"
printf '  G4 periodic retry observed=%s expected=0:reached:slept\n' \
  "$(cat "$TMP/red-g4-periodic-retry-result")"
expect "G4 ordinary periodic block remains retryable" \
  test "$(cat "$TMP/red-g4-periodic-retry-result")" = "0:reached:slept"
printf '  G4 capacity observed=%s expected=1:stopped:no-crash:no-notify\n' \
  "$(cat "$TMP/red-g4-capacity-result")"
expect "G4 capacity evidence failure terminates before the next Story" \
  test "$(cat "$TMP/red-g4-capacity-result")" = \
    "1:stopped:no-crash:no-notify"
printf '  G4 launch observed=%s expected=1:retained:attempted:stopped:no-crash:no-notify\n' \
  "$(cat "$TMP/red-g4-launch-result")"
expect "G4 post-launch evidence failure preserves attempted effect and terminates" \
  test "$(cat "$TMP/red-g4-launch-result")" = \
    "1:retained:attempted:stopped:no-crash:no-notify"

printf '\nRecovery caller evidence fault matrix (R1-R5c)\n'

# Extract and execute the exact recovery caller branches.  These falsifiers
# intentionally stub the inner policy/classification operations: a recoverable
# rc=1 must be translated by its caller into one bounded names-only evidence
# record, while an evidence sink failure must be promoted to fatal rc=4.
python3 - "$DAEMON" "$TMP/recovery-evidence-boundaries.sh" <<'PY'
import sys, textwrap

text = open(sys.argv[1], encoding="utf-8").read()

def between(start, end, offset=0):
    begin = text.index(start, offset)
    finish = text.index(end, begin)
    return textwrap.dedent(text[begin:finish]).rstrip()

r1 = between("          local stale_policy_rc=0", "          return 0")
r2 = between("      local adopted_policy_rc=0", "      return 0")
r3 = between("      local retained_policy_rc=0", "      return 0")
r5_scope = text.index("  local args=()")
r5_start = text.index("  local projected_source_digest=", r5_scope)
r5_end = text.index("  _forward_evidence_for_intention \"$sid\" accepted terminal_projection", r5_start)
r5 = textwrap.dedent(text[r5_start:r5_end]).rstrip()

with open(sys.argv[2], "w", encoding="utf-8") as out:
    for name, body in (("r1_boundary", r1), ("r2_boundary", r2),
                       ("r3_boundary", r3), ("r5_boundary", r5)):
        out.write(f"{name}() {{\n{body}\n  : > \"$R_LATER\"\n}}\n")
PY
# shellcheck source=/dev/null
source "$TMP/recovery-evidence-boundaries.sh"

R_SOURCE_DIGEST=$(printf 'a%.0s' $(seq 1 64))
R_RECORD=$(printf 'b%.0s' $(seq 1 64))
R_TOKEN=$(printf 'c%.0s' $(seq 1 64))
R_ZERO=$(printf '0%.0s' $(seq 1 64))
R_EVIDENCE_RC=0
R_HASH_RC=0
_forward_sha256(){
  [[ "$R_HASH_RC" -eq 0 ]] || return "$R_HASH_RC"
  printf '%s\n' "$R_SOURCE_DIGEST"
}
_forward_resume_policy_stall(){ return 1; }
_forward_evidence_for_intention(){
  printf '%s|%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "$6" "$7" \
    >> "$R_EVIDENCE"
  return "$R_EVIDENCE_RC"
}

run_recovery_evidence_case() {
  local label="$1" boundary="$2" expected="$3" mode="${4:-policy}"
  sid="E${label}"; wt="$TMP/${label}-worktree"
  context="$TMP/${label}-context"; context_digest="$R_TOKEN"
  s_source=1111111111111111111111111111111111111111
  s_blob=2222222222222222222222222222222222222222
  s_record="$R_RECORD"; s_digest="$R_TOKEN"; s_event="$R_TOKEN"; s_state="$R_TOKEN"
  stall_context_digest="$R_TOKEN"; stall_source="$s_source"
  stall_blob="$s_blob"; stall_record="$R_RECORD"
  stall_event="$R_TOKEN"; stall_state="$R_TOKEN"
  adopted_event="$R_TOKEN"; adopted_state="$R_TOKEN"
  token_digest="$R_TOKEN"; manifest=manifest; intended=status=failed
  integrity=verified; plan=true; args=(status failed)
  _FORWARD_SOURCE_DIGEST="$R_SOURCE_DIGEST"; _FORWARD_RECORD_DIGEST="$R_RECORD"
  case "$label" in
    R5*) _FORWARD_INTENDED=status=failed ;;
    *) _FORWARD_INTENDED=phase_status=commit_stalled ;;
  esac
  _FORWARD_SNAPSHOT="$TMP/${label}-snapshot"
  R_EVIDENCE="$TMP/${label}-evidence"; R_LATER="$TMP/${label}-later"
  R_CONTEXT="$context"; R_STATE="$TMP/${label}-state"
  : > "$_FORWARD_SNAPSHOT"; : > "$R_CONTEXT"; : > "$R_STATE"
  rm -f "$R_EVIDENCE" "$R_LATER"
  R_HASH_RC=0
  [[ "$mode" == hash_fail ]] && R_HASH_RC=1
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    if [[ "$mode" == classify_fail ]]; then
      _FORWARD_SOURCE_DIGEST=; _FORWARD_RECORD_DIGEST=
      return 1
    fi
    _FORWARD_SOURCE_DIGEST="$R_SOURCE_DIGEST"
    _FORWARD_RECORD_DIGEST="$R_RECORD"
    _FORWARD_SNAPSHOT="$TMP/${label}-reclassified"; : > "$_FORWARD_SNAPSHOT"
    return 0
  }
  _lifecycle_snapshot_matches(){ [[ "$mode" != snapshot_mismatch ]]; }
  forward_context_remove(){ [[ "$mode" != context_remove_fail ]]; }
  local rc=0 observed=none count=0 preserved later=stopped
  "$boundary" || rc=$?
  [[ -f "$R_EVIDENCE" ]] && observed=$(cat "$R_EVIDENCE")
  [[ -f "$R_EVIDENCE" ]] && count=$(wc -l < "$R_EVIDENCE" | tr -d ' ')
  [[ -e "$R_CONTEXT" && -e "$R_STATE" ]] && preserved=preserved || preserved=lost
  [[ -e "$R_LATER" ]] && later=reached
  printf '  %s observed=%s:%s:%s:%s expected=1:1:%s:preserved:stopped\n' \
    "$label" "$rc" "$count" "$observed" "$preserved" "$expected"
  expect "$label recovery caller emits one exact evidence record before stopping" \
    test "$rc:$count:$observed:$preserved:$later" = \
      "1:1:$expected:preserved:stopped"

  rm -f "$R_EVIDENCE" "$R_LATER"; : > "$_FORWARD_SNAPSHOT"
  R_EVIDENCE_RC=1; rc=0
  "$boundary" || rc=$?
  R_EVIDENCE_RC=0
  R_HASH_RC=0
  expect "$label evidence sink failure is fatal rc4" test "$rc" = 4
}

run_recovery_evidence_case R1 r1_boundary \
  "retryable|policy_stall|none|$R_SOURCE_DIGEST|$R_RECORD|phase_status=commit_stalled"
run_recovery_evidence_case R1H r1_boundary \
  "retryable|source_unavailable|none|$R_ZERO|$R_RECORD|phase_status=commit_stalled" \
  hash_fail
run_recovery_evidence_case R2 r2_boundary \
  "retryable|policy_stall|none|$R_SOURCE_DIGEST|$R_RECORD|phase_status=commit_stalled"
run_recovery_evidence_case R3 r3_boundary \
  "retryable|policy_stall|$R_TOKEN|$R_SOURCE_DIGEST|$R_RECORD|phase_status=commit_stalled"

# R4 exercises the real retained-settlement helper through its real recovery
# caller. The admission classification precedes the manifest and the helper
# owns the only post-settlement reclassification. A third caller classification
# could otherwise advance A to B after cleanup while evidence still names A.
# Exactly one terminal evidence decision belongs to the caller, never the helper.
R4_SOURCE=1111111111111111111111111111111111111111
R4_BLOB=2222222222222222222222222222222222222222
R4_RECORD=$(printf 'd%.0s' $(seq 1 64))
R4_SOURCE_B=6666666666666666666666666666666666666666
R4_BLOB_B=7777777777777777777777777777777777777777
R4_RECORD_B=$(printf '8%.0s' $(seq 1 64))
R4_TOKEN=$(printf 'e%.0s' $(seq 1 64))
R4_TOKEN_DIGEST=$(printf 'f%.0s' $(seq 1 64))
R4_STATE_DIGEST=$(printf '1%.0s' $(seq 1 64))
R4_RECORDS_DIGEST=$(printf '2%.0s' $(seq 1 64))
R4_SOURCE_DIGEST=$(printf '3%.0s' $(seq 1 64))
R4_SOURCE_DIGEST_B=$(printf '9%.0s' $(seq 1 64))
R4_ROW_DIGEST=$(printf '4%.0s' $(seq 1 64))
R4_CONTEXT_DIGEST=$(printf '5%.0s' $(seq 1 64))
R4_MANIFEST=$(printf '%s\t%s\t%s\t%s\t%s\nstatus\t00000000000000000000-aaaaaaaaaaaaaaaa.json\t%s\tfailed\tapplied\n' \
  "$R4_TOKEN" "$R4_SOURCE" "$R4_TOKEN_DIGEST" "$R4_STATE_DIGEST" \
  "$R4_RECORDS_DIGEST" "$R4_ROW_DIGEST")
R4_CONTEXT="$TMP/R4-context"
R4_STATE="$TMP/R4-state"
R4_EVIDENCE="$TMP/R4-evidence"
R4_LATER="$TMP/R4-later"
R4_CLASSIFY_COUNT=0
R4_REMOVE_COUNT=0
R4_RETIRE_COUNT=0
R4_PROJECT_COUNT=0
R4_DOWNSTREAM_COUNT=0
R4_MATCH_COUNT=0
R4_CLASSIFY_MODE=success
R4_INTEGRITY_MODE=verified

_forward_resolve_worktree(){ printf '%s\n' "$TMP/R4-worktree"; }
_forward_plan_present(){ return 0; }
_forward_absent_context_admitted(){ return 1; }
_forward_context_path(){ printf '%s\n' "$R4_CONTEXT"; }
_forward_worktree_state(){
  case "$R4_INTEGRITY_MODE" in
    return1) return 1 ;;
    unknown) printf 'unknown\n' ;;
    *) printf 'verified\n' ;;
  esac
}
_forward_classify(){
  R4_CLASSIFY_COUNT=$((R4_CLASSIFY_COUNT + 1))
  if [[ "$R4_CLASSIFY_COUNT" -eq 2 \
      && ( "$R4_CLASSIFY_MODE" == drift \
        || "$R4_CLASSIFY_MODE" == match_fail \
        || "$R4_CLASSIFY_MODE" == internal_fail ) ]]; then
    _FORWARD_SOURCE="$R4_SOURCE_B"
    _FORWARD_BLOB="$R4_BLOB_B"
    _FORWARD_RECORD_DIGEST="$R4_RECORD_B"
    _FORWARD_SOURCE_DIGEST="$R4_SOURCE_DIGEST_B"
  else
    _FORWARD_SOURCE="$R4_SOURCE"
    _FORWARD_BLOB="$R4_BLOB"
    _FORWARD_RECORD_DIGEST="$R4_RECORD"
    _FORWARD_SOURCE_DIGEST="$R4_SOURCE_DIGEST"
  fi
  _FORWARD_ACTION=forward_terminal
  _FORWARD_REASON=terminal_projection
  _FORWARD_STATUS=in_progress
  _FORWARD_PHASE=qa_passed
  _FORWARD_SNAPSHOT="$TMP/R4-snapshot-$R4_CLASSIFY_COUNT"
  : > "$_FORWARD_SNAPSHOT"
  # Count 1 is admission; count 2 is the helper's exact post-settlement check.
  if [[ "$R4_CLASSIFY_COUNT:$R4_CLASSIFY_MODE" == 2:internal_fail ]]; then
    return 1
  fi
  return 0
}
_journal_inspect_pending_lifecycle(){ printf '%s' "$R4_MANIFEST"; }
_lifecycle_snapshot_matches(){
  R4_MATCH_COUNT=$((R4_MATCH_COUNT + 1))
  [[ "$R4_CLASSIFY_MODE:$R4_MATCH_COUNT" != match_fail:2 ]]
}
_forward_bind_context(){
  : > "$R4_CONTEXT"
  printf 'ER4\t%s\t%s\t%s\tretained\t%s\t%s\t%s\tnone\tnone\tverified\tforward_terminal\tterminal_projection\tstatus=failed\t%s\n' \
    "$R4_SOURCE" "$R4_BLOB" "$R4_RECORD" "$R4_TOKEN_DIGEST" \
    "$R4_SOURCE" "$R4_RECORDS_DIGEST" "$R4_CONTEXT_DIGEST"
}
forward_context_remove(){
  [[ "$1:$2" == "$R4_CONTEXT:$R4_CONTEXT_DIGEST" ]] || return 1
  R4_REMOVE_COUNT=$((R4_REMOVE_COUNT + 1))
  rm -f "$R4_CONTEXT"
}
_journal_retire_accepted_lifecycle(){
  [[ "$1:$2:$3" == "ER4:recovery.scan:$R4_STATE_DIGEST" ]] || return 1
  R4_RETIRE_COUNT=$((R4_RETIRE_COUNT + 1))
  rm -f "$R4_STATE"
}
_forward_project(){ R4_PROJECT_COUNT=$((R4_PROJECT_COUNT + 1)); return 0; }
_forward_commit_retry_guard(){ R4_DOWNSTREAM_COUNT=$((R4_DOWNSTREAM_COUNT + 1)); }
_forward_relaunch(){ R4_DOWNSTREAM_COUNT=$((R4_DOWNSTREAM_COUNT + 1)); }
_forward_evidence_for_intention(){
  printf '%s|%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "$6" "$7" \
    >> "$R_EVIDENCE"
  return "$R_EVIDENCE_RC"
}

run_r4_retained_caller_case() {
  local expected_rc="$1" mode="$2" expected_evidence="$3"
  local expected_accepted="$4" expected_remove="$5" expected_retire="$6"
  local expected_context="$7" expected_state="$8"
  local expected_classify="$9" expected_global_digest="${10}"
  local rc=0 evidence_count=0 accepted_count=0
  R4_CLASSIFY_COUNT=0; R4_REMOVE_COUNT=0; R4_RETIRE_COUNT=0
  R4_PROJECT_COUNT=0; R4_DOWNSTREAM_COUNT=0; R4_MATCH_COUNT=0
  R4_CLASSIFY_MODE="$mode"
  R4_INTEGRITY_MODE=verified
  [[ "$mode" == integrity_return ]] && R4_INTEGRITY_MODE=return1
  [[ "$mode" == integrity_unknown ]] && R4_INTEGRITY_MODE=unknown
  R_EVIDENCE="$R4_EVIDENCE"
  rm -f "$R4_EVIDENCE" "$R4_LATER" "$R4_CONTEXT" "$R4_STATE"
  : > "$R4_STATE"
  _forward_recovery_one ER4 || rc=$?
  [[ -f "$R4_EVIDENCE" ]] \
    && evidence_count=$(wc -l < "$R4_EVIDENCE" | tr -d ' ')
  [[ -f "$R4_EVIDENCE" ]] \
    && accepted_count=$(awk -F '|' '$1 == "accepted" && $2 == "already_current" { count++ } END { print count + 0 }' "$R4_EVIDENCE")
  local observed_evidence=none
  [[ -f "$R4_EVIDENCE" ]] && observed_evidence=$(cat "$R4_EVIDENCE")
  printf '  R4-%s observed=%s:%s:%s:%s:%s:%s:%s:%s:%s:%s expected=%s:%s:1:%s:%s:%s:%s:%s:0:%s\n' \
    "$mode" \
    "$rc" "$R4_CLASSIFY_COUNT" "$evidence_count" "$accepted_count" \
    "$R4_REMOVE_COUNT" "$R4_RETIRE_COUNT" \
    "$([[ -e "$R4_CONTEXT" ]] && printf present || printf gone)" \
    "$([[ -e "$R4_STATE" ]] && printf present || printf gone)" \
    "$((R4_PROJECT_COUNT + R4_DOWNSTREAM_COUNT))" "$_FORWARD_SOURCE_DIGEST" \
    "$expected_rc" "$expected_classify" "$expected_accepted" \
    "$expected_remove" "$expected_retire" "$expected_context" \
    "$expected_state" "$expected_global_digest"
  expect "R4-$mode helper owns the only post-settlement classification" \
    test "$rc:$R4_CLASSIFY_COUNT:$evidence_count:$accepted_count:$R4_REMOVE_COUNT:$R4_RETIRE_COUNT:$([[ -e "$R4_CONTEXT" ]] && printf present || printf gone):$([[ -e "$R4_STATE" ]] && printf present || printf gone):$((R4_PROJECT_COUNT + R4_DOWNSTREAM_COUNT)):$_FORWARD_SOURCE_DIGEST" = \
      "$expected_rc:$expected_classify:1:$expected_accepted:$expected_remove:$expected_retire:$expected_context:$expected_state:0:$expected_global_digest"
  expect "R4-$mode caller records one exact terminal evidence decision" \
    test "$observed_evidence" = "$expected_evidence"
}

R_EVIDENCE_RC=0
run_r4_retained_caller_case 1 integrity_return \
  "retryable|integrity_unverified|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 1 "$R4_SOURCE_DIGEST"
R_EVIDENCE_RC=1
run_r4_retained_caller_case 4 integrity_return \
  "retryable|integrity_unverified|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 1 "$R4_SOURCE_DIGEST"
R_EVIDENCE_RC=0
run_r4_retained_caller_case 1 integrity_unknown \
  "retryable|integrity_unverified|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 1 "$R4_SOURCE_DIGEST"
R_EVIDENCE_RC=0
run_r4_retained_caller_case 1 internal_fail \
  "retryable|source_unavailable|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 2 "$R4_SOURCE_DIGEST_B"
R_EVIDENCE_RC=1
run_r4_retained_caller_case 4 internal_fail \
  "retryable|source_unavailable|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 2 "$R4_SOURCE_DIGEST_B"
R_EVIDENCE_RC=0
run_r4_retained_caller_case 1 match_fail \
  "retryable|projection_failed|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 2 "$R4_SOURCE_DIGEST_B"
R_EVIDENCE_RC=1
run_r4_retained_caller_case 4 match_fail \
  "retryable|projection_failed|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  0 0 0 present present 2 "$R4_SOURCE_DIGEST_B"
R_EVIDENCE_RC=0
run_r4_retained_caller_case 0 success \
  "accepted|already_current|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  1 1 1 gone gone 2 "$R4_SOURCE_DIGEST"
R_EVIDENCE_RC=1
run_r4_retained_caller_case 4 success \
  "accepted|already_current|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|status=failed" \
  1 1 1 gone gone 2 "$R4_SOURCE_DIGEST"
R_EVIDENCE_RC=0
run_r4_retained_caller_case 0 drift \
  "accepted|already_current|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST_B|$R4_RECORD_B|status=failed" \
  1 1 1 gone gone 2 "$R4_SOURCE_DIGEST_B"
R_EVIDENCE_RC=1
run_r4_retained_caller_case 4 drift \
  "accepted|already_current|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST_B|$R4_RECORD_B|status=failed" \
  1 1 1 gone gone 2 "$R4_SOURCE_DIGEST_B"
if grep -Fq "accepted|already_current|$R4_TOKEN_DIGEST|$R4_SOURCE_DIGEST|$R4_RECORD|" \
    "$R4_EVIDENCE"; then
  fail "R4-drift accepted evidence never reuses stale source/record A"
else
  pass "R4-drift accepted evidence never reuses stale source/record A"
fi
R_EVIDENCE_RC=0

python3 - "$DAEMON" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("_forward_retained_settle() {")
end = text.index("\n}\n\n_forward_recovery_one()", start)
helper = text[start:end]
for forbidden in ("_forward_evidence", "log ", "notify_escalation"):
    if forbidden in helper:
        raise SystemExit(1)
PY
expect "R4 retained settlement helper has no evidence, log, or notification authority" \
  test "$?" -eq 0

_forward_project(){ return 0; }
_FORWARD_INTENDED=status=failed
run_recovery_evidence_case R5a r5_boundary \
  "retryable|source_unavailable|none|$R_SOURCE_DIGEST|$R_RECORD|status=failed" \
  classify_fail
run_recovery_evidence_case R5b r5_boundary \
  "conflict|remote_changed|none|$R_SOURCE_DIGEST|$R_RECORD|status=failed" \
  snapshot_mismatch
run_recovery_evidence_case R5c r5_boundary \
  "retryable|context_invalid|none|$R_SOURCE_DIGEST|$R_RECORD|status=failed" \
  context_remove_fail

printf '\nMain-loop last-window authority falsifier\n'

# Execute the exact current main-loop boundary from final revalidation through
# retry/spawn. The race hook advances the externally observed target after A
# passes its final check but before the context is bound. A stable-B control
# proves that the harness still permits one authorized B launch.
python3 - "$DAEMON" "$TMP/main-last-window-boundary.sh" <<'PY'
import sys, textwrap

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("    # Re-pin immediately after reconciliation")
launch = text.index('    if ! launch_3phase_in_tmux "$story_id" "$_trace_id"', start)
end = text.index("\n    fi", launch) + len("\n    fi")
body = textwrap.dedent(text[start:end]).rstrip()
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("mlw_boundary() {\n  for _mlw_once in 1; do\n")
    out.write(textwrap.indent(body, "    ") + "\n")
    out.write("  done\n}\n")
PY
# shellcheck source=/dev/null
source "$TMP/main-last-window-boundary.sh"

MLW_SOURCE_A=1111111111111111111111111111111111111111
MLW_BLOB_A=2222222222222222222222222222222222222222
MLW_RECORD_A=$(printf '3%.0s' $(seq 1 64))
MLW_SOURCE_DIGEST_A=$(printf '4%.0s' $(seq 1 64))
MLW_SOURCE_B=5555555555555555555555555555555555555555
MLW_BLOB_B=6666666666666666666666666666666666666666
MLW_RECORD_B=$(printf '7%.0s' $(seq 1 64))
MLW_SOURCE_DIGEST_B=$(printf '8%.0s' $(seq 1 64))
MLW_CONTEXT_DIGEST=$(printf '9%.0s' $(seq 1 64))
MLW_TARGET="$TMP/main-last-window-target"
MLW_CONTEXT="$TMP/main-last-window-context"
MLW_STATE="$TMP/main-last-window-state"
MLW_EVIDENCE="$TMP/main-last-window-evidence"

_forward_classify(){
  _FORWARD_SOURCE=$(cat "$MLW_TARGET")
  if [[ "$_FORWARD_SOURCE" == "$MLW_SOURCE_A" ]]; then
    _FORWARD_BLOB="$MLW_BLOB_A"
    _FORWARD_RECORD_DIGEST="$MLW_RECORD_A"
    _FORWARD_SOURCE_DIGEST="$MLW_SOURCE_DIGEST_A"
  else
    _FORWARD_BLOB="$MLW_BLOB_B"
    _FORWARD_RECORD_DIGEST="$MLW_RECORD_B"
    _FORWARD_SOURCE_DIGEST="$MLW_SOURCE_DIGEST_B"
  fi
  _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
  _FORWARD_SNAPSHOT="$TMP/main-last-window-snapshot"; : > "$_FORWARD_SNAPSHOT"
}
_forward_revalidate_after_reconcile(){
  _forward_classify
  _FORWARD_FINAL_INTEGRITY=verified
  [[ "$_FORWARD_SOURCE" == "$2" && "$_FORWARD_BLOB" == "$3" \
      && "$_FORWARD_RECORD_DIGEST" == "$4" ]]
}
_forward_context_path(){
  [[ "$MLW_MODE" == race ]] && printf '%s\n' "$MLW_SOURCE_B" > "$MLW_TARGET"
  printf '%s\n' "$MLW_CONTEXT"
}
_forward_bind_context(){
  local row
  row=$(printf '%s\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s' \
    "$2" "$3" "$4" "$5" "$MLW_CONTEXT_DIGEST")
  printf '%s\n' "$row" > "$1"
  printf '%s\n' "$row"
}
_forward_active_markers_clear(){ return 0; }
_forward_runner_clear(){ return 0; }
tmux(){ return 1; }
active_count(){ printf '0\n'; }
node(){ printf '00000000-0000-4000-8000-000000000010'; }
forward_context_remove(){ rm -f "$1"; }
_forward_restore_context_row(){ : > "$1"; }
_forward_main_hold(){ printf 'hold|%s\n' "$2" >> "$MLW_EVIDENCE"; }
_forward_evidence(){
  printf '%s|%s|%s|%s\n' "$2" "$3" "$5" "$6" >> "$MLW_EVIDENCE"
}
increment_retry(){ MLW_RETRY=$((MLW_RETRY + 1)); }
launch_3phase_in_tmux(){
  MLW_SPAWN=$((MLW_SPAWN + 1))
  MLW_TMUX=$((MLW_TMUX + 1))
  MLW_MODEL=$((MLW_MODEL + 1))
  MLW_WORKTREE=$((MLW_WORKTREE + 1))
  MLW_LAUNCH_AUTH="$3:$4:$5"
}

run_main_last_window_case() {
  local mode="$1" source="$2" blob="$3" record="$4" source_digest="$5"
  MLW_MODE="$mode"; story_id=EMLW; _pre_wt="$TMP/main-last-window-wt"
  _post_source="$source"; _post_blob="$blob"; _post_record="$record"
  _post_source_digest="$source_digest"; _post_allow_absent=false
  _post_plan=false
  MAX_CONCURRENT=1; launched=0
  MLW_RETRY=0; MLW_SPAWN=0; MLW_TMUX=0; MLW_MODEL=0; MLW_WORKTREE=0
  MLW_LAUNCH_AUTH=none
  rm -f "$MLW_CONTEXT" "$MLW_STATE" "$MLW_EVIDENCE"
  : > "$MLW_STATE"; printf '%s\n' "$source" > "$MLW_TARGET"
  mlw_boundary
  local evidence=none context=present state=present authority_source="$_FORWARD_SOURCE"
  [[ -s "$MLW_EVIDENCE" ]] && evidence=$(cat "$MLW_EVIDENCE")
  [[ -e "$MLW_CONTEXT" ]] && authority_source=$(cut -f2 "$MLW_CONTEXT")
  [[ -e "$MLW_CONTEXT" ]] || context=gone
  [[ -e "$MLW_STATE" ]] || state=gone
  printf '%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n' "$evidence" "$context" "$state" \
    "$MLW_RETRY" "$MLW_SPAWN" "$MLW_TMUX" "$MLW_MODEL" "$MLW_WORKTREE" \
    "$authority_source" "$(cat "$MLW_TARGET")" "$MLW_LAUNCH_AUTH"
}

mlw_race=$(run_main_last_window_case race "$MLW_SOURCE_A" "$MLW_BLOB_A" \
  "$MLW_RECORD_A" "$MLW_SOURCE_DIGEST_A")
printf '  last-window race observed=%s expected=blocked|remote_changed|%s|%s:present:present:0:0:0:0:0:%s:%s:none\n' \
  "$mlw_race" "$MLW_SOURCE_DIGEST_B" "$MLW_RECORD_B" "$MLW_SOURCE_A" "$MLW_SOURCE_B"
expect "last-window A-to-B advance blocks every A effect and preserves A recovery context" \
  test "$mlw_race" = \
    "blocked|remote_changed|$MLW_SOURCE_DIGEST_B|$MLW_RECORD_B:present:present:0:0:0:0:0:$MLW_SOURCE_A:$MLW_SOURCE_B:none"

mlw_stable=$(run_main_last_window_case stable "$MLW_SOURCE_B" "$MLW_BLOB_B" \
  "$MLW_RECORD_B" "$MLW_SOURCE_DIGEST_B")
printf '  last-window stable-B observed=%s expected=none:gone:present:1:1:1:1:1:%s:%s:%s:%s:%s\n' \
  "$mlw_stable" "$MLW_SOURCE_B" "$MLW_SOURCE_B" "$MLW_SOURCE_B" "$MLW_BLOB_B" "$MLW_RECORD_B"
expect "last-window stable B launches exactly one B attempt" \
  test "$mlw_stable" = \
    "none:gone:present:1:1:1:1:1:$MLW_SOURCE_B:$MLW_SOURCE_B:$MLW_SOURCE_B:$MLW_BLOB_B:$MLW_RECORD_B"

printf '\nFresh-wrapper classifier dependency falsifier\n'

WRAP_REPO="$TMP/wrapper-repo"
WRAP_ORIGIN="$TMP/wrapper-origin.git"
WRAP_LOCKS="$TMP/wrapper-locks"
WRAP_WORKTREES="$TMP/wrapper-worktrees"
git init --bare "$WRAP_ORIGIN" >/dev/null
git init "$WRAP_REPO" >/dev/null
git -C "$WRAP_REPO" config user.email test@example.invalid
git -C "$WRAP_REPO" config user.name test
git -C "$WRAP_REPO" remote add origin "$WRAP_ORIGIN"
mkdir -p "$WRAP_REPO/.gaai/project/contexts/backlog" "$WRAP_LOCKS" "$WRAP_WORKTREES"
chmod 700 "$WRAP_LOCKS"
cat > "$WRAP_REPO/.gaai/project/contexts/backlog/active.backlog.yaml" <<EOF
items:
- id: EWRAP
  status: in_progress
  phase_status: not_started
  started_at: "$started"
EOF
git -C "$WRAP_REPO" add .gaai/project/contexts/backlog/active.backlog.yaml
git -C "$WRAP_REPO" commit -m wrapper-a >/dev/null
git -C "$WRAP_REPO" push origin HEAD:staging >/dev/null

wrapper_guard_result=$("$TEST_BASH" -s -- "$ROOT" "$WRAP_REPO" "$WRAP_LOCKS" \
  "$WRAP_WORKTREES" <<'BASH'
set -u
root="$1"; PROJECT_DIR="$2"; REPO_ROOT="$2"; LOCK_DIR="$3"
GAAI_WORKTREES_BASE="$4"; TARGET_BRANCH=staging
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"; SCHEDULER=/bin/false

# This is the fresh wrapper dependency boundary: no daemon/classifier function
# is inherited or sourced separately by the fixture.
source "$root/.gaai/core/scripts/daemon-dispatch.sh" || exit 1
defined=$(type -t forward_classify_snapshot 2>/dev/null || printf missing)
git -C "$PROJECT_DIR" fetch origin staging --quiet || exit 1
expected_source=$(git -C "$PROJECT_DIR" rev-parse origin/staging) || exit 1
expected_blob=$(git -C "$PROJECT_DIR" rev-parse \
  "${expected_source}:${BACKLOG_REL}") || exit 1
snapshot=$(mktemp "$LOCK_DIR/.wrapper-snapshot-XXXXXX") || exit 1
git -C "$PROJECT_DIR" show "${expected_source}:${BACKLOG_REL}" > "$snapshot" \
  || exit 1
facts=$(forward_classify_snapshot EWRAP "$snapshot" "$expected_source" \
  "$expected_blob" postclaim verified false) || exit 1
rm -f "$snapshot"
IFS=$'\t' read -r _ _ _ _ _ expected_record _ _ <<< "$facts"

stable_rc=0
_plan_expected_target_guard EWRAP "$expected_source" "$expected_blob" \
  "$expected_record" || stable_rc=$?

printf 'drift\n' > "$PROJECT_DIR/drift.txt"
git -C "$PROJECT_DIR" add drift.txt
git -C "$PROJECT_DIR" commit -m wrapper-b >/dev/null
git -C "$PROJECT_DIR" push origin HEAD:staging >/dev/null
drift_rc=0
_plan_expected_target_guard EWRAP "$expected_source" "$expected_blob" \
  "$expected_record" || drift_rc=$?

marker="$LOCK_DIR/model-called"; retry=0
_emit_plan_routing_record(){ :; }
increment_retry(){ retry=$((retry + 1)); }
claude(){ : > "$marker"; }
codex(){ : > "$marker"; }
handle_rc=0
handle_plan_phase EWRAP trace "$expected_source" "$expected_blob" \
  "$expected_record" > "$LOCK_DIR/handle.log" 2>&1 || handle_rc=$?
branch=absent; worktree=absent; model=absent
git -C "$PROJECT_DIR" rev-parse --verify story/EWRAP >/dev/null 2>&1 \
  && branch=present
[[ -e "$GAAI_WORKTREES_BASE/EWRAP-workspace" ]] && worktree=present
[[ -e "$marker" ]] && model=present
printf '%s:%s:%s:%s:%s:%s:%s:%s\n' "$defined" "$stable_rc" "$drift_rc" \
  "$handle_rc" "$branch" "$worktree" "$model" "$retry"
BASH
)
printf '  wrapper dependency observed=%s expected=function:0:1:1:absent:absent:absent:0\n' \
  "$wrapper_guard_result"
expect "fresh wrapper owns canonical classifier and blocks drift before every PLAN effect" \
  test "$wrapper_guard_result" = "function:0:1:1:absent:absent:absent:0"

printf '\nPhase-agnostic wrapper authority and final-effect falsifiers\n'

python3 - "$ROOT/.gaai/core/scripts/daemon-dispatch.sh" "$DAEMON" <<'PY'
import sys

dispatch = open(sys.argv[1], encoding="utf-8").read()
daemon = open(sys.argv[2], encoding="utf-8").read()

ds = dispatch.index("dispatch_3phase_story() {")
de = dispatch.index("\n}\n", ds)
dspan = dispatch[ds:de]
guard = dspan.index('_dispatch_expected_target_guard "$story_id"')
phase = dspan.index('ps=$(get_phase_status "$story_id")')
pending = dspan.index('_journal_resume_pending_lifecycle')
currentness = dspan.index('if [[ "$ps" == "qa_passed"')
handler = dspan.index('handle_plan_phase "$story_id"')
if not guard < phase < pending < currentness < handler:
    raise SystemExit(1)

ws = daemon.index("launch_3phase_in_tmux() {")
we = daemon.index("# ── Prevent macOS sleep", ws)
wrapper = daemon[ws:we]
required = (
    'export GAAI_DISPATCH_IDENTITY_GUARD=required',
    '_ps_before=\\$(get_phase_status "$story_id"',
    'dispatch_3phase_story "$story_id" "$trace_id"',
    '_receipt_observed=0',
    'if [[ "\\$_receipt_observed" == "1" || "\\$_ps" != "\\$_ps_before" ]]',
    '_dispatch_rebind_expected_target_identity "$story_id"',
)
cursor = -1
for needle in required:
    cursor = wrapper.find(needle, cursor + 1)
    if cursor < 0:
        raise SystemExit(1)

relaunch = daemon[daemon.index("_forward_relaunch() {"):daemon.index("_forward_retained_settle() {")]
last = daemon[daemon.index("_forward_last_edge_guard() {"):daemon.index("_forward_context_path() {")]
if '_forward_worktree_state "$sid" "$allow_absent"' not in last:
    raise SystemExit(1)
if '_forward_plan_present "$sid" "$wt"' not in last:
    raise SystemExit(1)
dead = relaunch.index('if [[ "$lock_state" == dead ]]')
retire = relaunch.index('_forward_retire_dead_lock "$sid" "$lock_pid"', dead)
deferred = relaunch.index('return 2', retire)
remove = relaunch.index('forward_context_remove "$context"', dead)
if not dead < retire < deferred < remove:
    raise SystemExit(1)

plan = dispatch[dispatch.index("handle_plan_phase() {"):dispatch.index("handle_impl_phase() {")]
for needle in (
    'GAAI_QA_INJECT_PHASE:-',
    '_plan_story_worktree_owned',
):
    if needle not in plan:
        raise SystemExit(1)
if 'branch="refs/heads/story/${story_id}"' not in dispatch:
    raise SystemExit(1)
PY
expect "real wrapper guards every phase, rebinds after transition, and final edges are fresh/deferred" \
  test "$?" -eq 0

WRAPPER_RUNTIME="$TMP/wrapper-runtime"
WRAPPER_RUNTIME_ORIGIN="$TMP/wrapper-runtime-origin.git"
WRAPPER_RUNTIME_LOCKS="$TMP/wrapper-runtime-locks"
mkdir -p "$WRAPPER_RUNTIME/.gaai/core/scripts/lib" \
  "$WRAPPER_RUNTIME/.gaai/project/contexts/backlog" \
  "$WRAPPER_RUNTIME/.gaai/project/contexts/artefacts/stories" \
  "$WRAPPER_RUNTIME_LOCKS"
chmod 700 "$WRAPPER_RUNTIME_LOCKS"
git init --bare "$WRAPPER_RUNTIME_ORIGIN" >/dev/null
git init "$WRAPPER_RUNTIME" >/dev/null
git -C "$WRAPPER_RUNTIME" config user.email test@example.invalid
git -C "$WRAPPER_RUNTIME" config user.name test
git -C "$WRAPPER_RUNTIME" remote add origin "$WRAPPER_RUNTIME_ORIGIN"
printf '%s\n' '# EWRUNTIME contract v1' \
  > "$WRAPPER_RUNTIME/.gaai/project/contexts/artefacts/stories/EWRUNTIME.story.md"
git -C "$WRAPPER_RUNTIME" add \
  .gaai/project/contexts/artefacts/stories/EWRUNTIME.story.md
cat > "$WRAPPER_RUNTIME/.gaai/core/scripts/daemon-dispatch.sh" <<EOF
source "$ROOT/.gaai/core/scripts/daemon-dispatch.sh" || return 1
get_phase_status(){
  if [[ "\${WRAPPER_TEST_MODE:-guard}" == rebind_* ]]; then
    cat "\$WRAPPER_TEST_PHASE_FILE"
  else
    printf '%s\n' "\${WRAPPER_TEST_PHASE:?}"
  fi
}
_wrapper_set_story_field(){
  yaml_runtime_run "\$BACKLOG_FILE" "\$1" "\$2" "\$3" <<'PY'
import os, sys, yaml
path, story, field, value = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = yaml.safe_load(handle)
rows = [item for item in document.get("items", [])
        if isinstance(item, dict) and item.get("id") == story]
if len(rows) != 1:
    raise SystemExit(1)
rows[0][field] = value
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(document, handle, sort_keys=False)
os.chmod(path, 0o644)
PY
}
_journal_resume_pending_lifecycle(){ : > "\$WRAPPER_TEST_SENTINELS/pending"; }
_journal_persist_lifecycle(){ : > "\$WRAPPER_TEST_SENTINELS/currentness"; }
handle_plan_phase(){ : > "\$WRAPPER_TEST_SENTINELS/handler"; }
handle_impl_phase(){
  case "\${WRAPPER_TEST_MODE:-guard}" in
    rebind_*)
      : > "\$WRAPPER_TEST_SENTINELS/impl"
      if [[ "\$WRAPPER_TEST_MODE" == rebind_receipt_same_phase_error ]]; then
        _wrapper_set_story_field EOTHER notes durable-B || return 1
        git -C "\$PROJECT_DIR" add "\$BACKLOG_REL" || return 1
        git -C "\$PROJECT_DIR" commit \
          -m 'wrapper same-phase durable transition B' >/dev/null || return 1
        git -C "\$PROJECT_DIR" push origin HEAD:staging >/dev/null || return 1
        CHORE_JOURNAL_OUTCOME=applied
        CHORE_JOURNAL_COMMIT=\$(git -C "\$PROJECT_DIR" rev-parse HEAD) \
          || return 1
        # Model a failure after remote publication but before local adoption.
        git -C "\$PROJECT_DIR" show \
          "\${WRAPPER_TEST_ORIGINAL_SOURCE}:\${BACKLOG_REL}" \
          > "\$BACKLOG_FILE" || return 1
        return 1
      fi
      _wrapper_set_story_field EWRUNTIME phase_status implemented || return 1
      git -C "\$PROJECT_DIR" add "\$BACKLOG_REL" || return 1
      git -C "\$PROJECT_DIR" commit -m 'wrapper durable transition B' >/dev/null || return 1
      git -C "\$PROJECT_DIR" push origin HEAD:staging >/dev/null || return 1
      CHORE_JOURNAL_OUTCOME=applied
      CHORE_JOURNAL_COMMIT=\$(git -C "\$PROJECT_DIR" rev-parse HEAD) || return 1
      cp "\$BACKLOG_FILE" "\$WRAPPER_TEST_B_SNAPSHOT" || return 1
      case "\$WRAPPER_TEST_MODE" in
        rebind_unrelated) _wrapper_set_story_field EOTHER notes unrelated-D ;;
        rebind_same_story_field) _wrapper_set_story_field EWRUNTIME notes concurrent-C ;;
        rebind_same_story_phase) _wrapper_set_story_field EWRUNTIME phase_status qa_passed ;;
        rebind_same_story_contract)
          printf '%s\n' '# EWRUNTIME contract v2' \
            > "\$PROJECT_DIR/.gaai/project/contexts/artefacts/stories/EWRUNTIME.story.md"
          ;;
        rebind_other_story_code)
          mkdir -p "\$PROJECT_DIR/packages/other-story"
          printf '%s\n' 'delivery owned by EOTHER' \
            > "\$PROJECT_DIR/packages/other-story/change.txt"
          ;;
        rebind_absent) CHORE_JOURNAL_OUTCOME=; CHORE_JOURNAL_COMMIT= ;;
        rebind_stale) CHORE_JOURNAL_COMMIT="\$WRAPPER_TEST_ORIGINAL_SOURCE" ;;
        rebind_nonancestor)
          CHORE_JOURNAL_COMMIT=\$(git -C "\$PROJECT_DIR" commit-tree \
            "\$(git -C "\$PROJECT_DIR" rev-parse HEAD^{tree})" \
            -m 'nonancestor receipt') || return 1
          ;;
        rebind_fetch_fail)
          git -C "\$PROJECT_DIR" remote set-url origin \
            "\$PROJECT_DIR/missing-origin.git" || return 1
          ;;
      esac
      case "\$WRAPPER_TEST_MODE" in
        rebind_unrelated|rebind_same_story_field|rebind_same_story_phase|rebind_same_story_contract|rebind_other_story_code)
          git -C "\$PROJECT_DIR" add "\$BACKLOG_REL" || return 1
          if [[ "\$WRAPPER_TEST_MODE" == rebind_same_story_contract ]]; then
            git -C "\$PROJECT_DIR" add \
              .gaai/project/contexts/artefacts/stories/EWRUNTIME.story.md \
              || return 1
          elif [[ "\$WRAPPER_TEST_MODE" == rebind_other_story_code ]]; then
            git -C "\$PROJECT_DIR" add packages/other-story/change.txt || return 1
          fi
          git -C "\$PROJECT_DIR" commit -m 'wrapper concurrent target C' >/dev/null || return 1
          git -C "\$PROJECT_DIR" push origin HEAD:staging >/dev/null || return 1
          cp "\$WRAPPER_TEST_B_SNAPSHOT" "\$BACKLOG_FILE" || return 1
          ;;
      esac
      printf 'implemented\n' > "\$WRAPPER_TEST_PHASE_FILE"
      # A durable phase write can be followed by a handler error.  The wrapper
      # must still validate/rebind that write before interpreting the rc.
      if [[ "\$WRAPPER_TEST_MODE" == rebind_same_story_phase ]]; then
        return 1
      fi
      ;;
    *) : > "\$WRAPPER_TEST_SENTINELS/handler" ;;
  esac
}
handle_qa_phase(){
  case "\${WRAPPER_TEST_MODE:-guard}" in
    rebind_*) : > "\$WRAPPER_TEST_SENTINELS/qa"; return 1 ;;
    *) : > "\$WRAPPER_TEST_SENTINELS/handler" ;;
  esac
}
handle_commit_phase(){ : > "\$WRAPPER_TEST_SENTINELS/handler"; }
_emit_routing_record(){ : > "\$WRAPPER_TEST_SENTINELS/routing"; }
_reconcile_yaml_status_on_exit(){ : > "\$WRAPPER_TEST_SENTINELS/reconcile"; }
_reap_worktree_orphans(){ : > "\$WRAPPER_TEST_SENTINELS/reaper"; }
EOF
printf ':\n' > "$WRAPPER_RUNTIME/.gaai/core/scripts/lib/chore-commit.sh"
awk '/^launch_3phase_in_tmux\(\)/{on=1} /^# ── Prevent macOS sleep/{on=0} on{print}' \
  "$DAEMON" > "$TMP/launch-wrapper.sh"
# shellcheck source=/dev/null
source "$TMP/launch-wrapper.sh"
log(){ :; }
tmux(){
  local command="" arg
  case "${1:-}" in
    new-session)
      for arg in "$@"; do command="$arg"; done
      "$command"
      ;;
    has-session) return 1 ;;
    *) return 0 ;;
  esac
}
PROJECT_DIR="$WRAPPER_RUNTIME"; REPO_ROOT="$WRAPPER_RUNTIME"
LOCK_DIR="$WRAPPER_RUNTIME_LOCKS"; LOG_DIR="$TMP/wrapper-runtime-logs"
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
BACKLOG="$WRAPPER_RUNTIME/$BACKLOG_REL"; BACKLOG_FILE="$BACKLOG"
SCHEDULER=/bin/false; TARGET_BRANCH=staging; TMUX_PIPE_PANE_AVAILABLE=false
GAAI_DAEMON_EXECUTOR=claude; GAAI_IMPL_AUTH_TOKEN=""; PLATFORM=Linux
RED=""; GREEN=""; NC=""; BLUE=""; YELLOW=""
mkdir -p "$LOG_DIR"

wrapper_phase_guard_result=""
WRAPPER_TEST_MODE=guard; export WRAPPER_TEST_MODE
for WRAPPER_TEST_PHASE in planned implemented qa_passed qa_failed; do
  export WRAPPER_TEST_PHASE
  WRAPPER_TEST_SENTINELS="$TMP/wrapper-runtime-${WRAPPER_TEST_PHASE}"
  export WRAPPER_TEST_SENTINELS
  mkdir -p "$WRAPPER_TEST_SENTINELS"
  cat > "$BACKLOG" <<EOF
items:
- id: EWRUNTIME
  status: in_progress
  phase_status: $WRAPPER_TEST_PHASE
  started_at: "$started"
EOF
  git -C "$WRAPPER_RUNTIME" add "$BACKLOG_REL"
  git -C "$WRAPPER_RUNTIME" commit -m "wrapper $WRAPPER_TEST_PHASE authority A" >/dev/null
  git -C "$WRAPPER_RUNTIME" push --force origin HEAD:staging >/dev/null
  git -C "$WRAPPER_RUNTIME" fetch origin staging --quiet || exit 1
  identity_source=$(git -C "$WRAPPER_RUNTIME" rev-parse origin/staging) || exit 1
  identity_blob=$(git -C "$WRAPPER_RUNTIME" rev-parse \
    "${identity_source}:${BACKLOG_REL}") || exit 1
  identity_snapshot=$(mktemp "$WRAPPER_RUNTIME_LOCKS/.identity-XXXXXX") || exit 1
  git -C "$WRAPPER_RUNTIME" show "${identity_source}:${BACKLOG_REL}" \
    > "$identity_snapshot" || exit 1
  identity_facts=$(forward_classify_snapshot EWRUNTIME "$identity_snapshot" \
    "$identity_source" "$identity_blob" postclaim verified false) || exit 1
  rm -f "$identity_snapshot"
  IFS=$'\t' read -r _ _ _ _ _ identity_record _ _ <<< "$identity_facts"
  printf '%s\n' "$WRAPPER_TEST_PHASE" > "$WRAPPER_RUNTIME/drift.txt"
  git -C "$WRAPPER_RUNTIME" add drift.txt
  git -C "$WRAPPER_RUNTIME" commit -m "wrapper $WRAPPER_TEST_PHASE authority B" >/dev/null
  git -C "$WRAPPER_RUNTIME" push origin HEAD:staging >/dev/null
  wrapper_rc=0
  launch_3phase_in_tmux EWRUNTIME trace "$identity_source" "$identity_blob" \
    "$identity_record" || wrapper_rc=$?
  effects=$(find "$WRAPPER_TEST_SENTINELS" -type f -print | wc -l | tr -d ' ')
  authority_files=absent
  [[ -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.lock" \
      && -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.heartbeat" ]] \
    && authority_files=preserved
  wrapper_phase_guard_result="${wrapper_phase_guard_result}${WRAPPER_TEST_PHASE}:${wrapper_rc}:${effects}:${authority_files};"
  rm -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.lock" \
    "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.heartbeat"
done
printf '  wrapper guard observed=%s\n' "$wrapper_phase_guard_result"
expect "generated wrapper blocks A-to-B before pending/currentness/handler/routing/model/cleanup for every phase" \
  test "$wrapper_phase_guard_result" = \
    "planned:1:0:preserved;implemented:1:0:preserved;qa_passed:1:0:preserved;qa_failed:1:0:preserved;"

cp "$WRAPPER_RUNTIME/.gaai/core/scripts/daemon-dispatch.sh" \
  "$TMP/wrapper-dispatch-good.sh"
cat > "$WRAPPER_RUNTIME/.gaai/core/scripts/daemon-dispatch.sh" <<'EOF'
_reap_worktree_orphans(){ : > "$WRAPPER_TEST_SENTINELS/reaper"; }
_reconcile_yaml_status_on_exit(){ : > "$WRAPPER_TEST_SENTINELS/reconcile"; }
return 1
EOF
WRAPPER_TEST_MODE=guard; WRAPPER_TEST_PHASE=planned
export WRAPPER_TEST_MODE WRAPPER_TEST_PHASE
WRAPPER_TEST_SENTINELS="$TMP/wrapper-runtime-source-fail"
export WRAPPER_TEST_SENTINELS
mkdir -p "$WRAPPER_TEST_SENTINELS"
source_fail_rc=0
launch_3phase_in_tmux EWRUNTIME trace "$identity_source" "$identity_blob" \
  "$identity_record" || source_fail_rc=$?
source_fail_effects=$(find "$WRAPPER_TEST_SENTINELS" -type f -print \
  | wc -l | tr -d ' ')
source_fail_authority=absent
[[ -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.lock" \
    && -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.heartbeat" ]] \
  && source_fail_authority=preserved
expect "wrapper source failure latches authority before cleanup" \
  test "$source_fail_rc:$source_fail_effects:$source_fail_authority" = \
    '1:0:preserved'
rm -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.lock" \
  "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.heartbeat"
cp "$TMP/wrapper-dispatch-good.sh" \
  "$WRAPPER_RUNTIME/.gaai/core/scripts/daemon-dispatch.sh"

# The exact journal publisher receipt names commit B.  Rebind may advance to a
# descendant D only when EWRUNTIME is byte-semantically identical there;
# same-Story drift, missing/stale receipts, non-ancestry and fetch failures all
# latch authority before any cleanup effect.
WRAPPER_TEST_PHASE_FILE="$TMP/wrapper-runtime-phase"
WRAPPER_TEST_B_SNAPSHOT="$TMP/wrapper-runtime-B.yaml"
export WRAPPER_TEST_PHASE_FILE WRAPPER_TEST_B_SNAPSHOT
rebind_results=""
for WRAPPER_TEST_MODE in rebind_unrelated rebind_other_story_code \
  rebind_receipt_same_phase_error \
  rebind_same_story_field rebind_same_story_contract \
  rebind_same_story_phase rebind_absent rebind_stale rebind_nonancestor \
  rebind_fetch_fail; do
  export WRAPPER_TEST_MODE
  git -C "$WRAPPER_RUNTIME" remote set-url origin "$WRAPPER_RUNTIME_ORIGIN"
  WRAPPER_TEST_SENTINELS="$TMP/wrapper-runtime-${WRAPPER_TEST_MODE}"
  export WRAPPER_TEST_SENTINELS
  mkdir -p "$WRAPPER_TEST_SENTINELS"
  printf 'planned\n' > "$WRAPPER_TEST_PHASE_FILE"
  cat > "$BACKLOG" <<EOF
items:
- id: EWRUNTIME
  status: in_progress
  phase_status: planned
  started_at: "$started"
- id: EOTHER
  status: refined
  phase_status: not_started
  notes: A-${WRAPPER_TEST_MODE}
EOF
  git -C "$WRAPPER_RUNTIME" add "$BACKLOG_REL"
  git -C "$WRAPPER_RUNTIME" commit \
    -m "wrapper ${WRAPPER_TEST_MODE} authority A" >/dev/null
  git -C "$WRAPPER_RUNTIME" push --force origin HEAD:staging >/dev/null
  git -C "$WRAPPER_RUNTIME" fetch origin staging --quiet
  rebind_source=$(git -C "$WRAPPER_RUNTIME" rev-parse origin/staging)
  WRAPPER_TEST_ORIGINAL_SOURCE="$rebind_source"
  export WRAPPER_TEST_ORIGINAL_SOURCE
  rebind_blob=$(git -C "$WRAPPER_RUNTIME" rev-parse \
    "${rebind_source}:${BACKLOG_REL}")
  rebind_snapshot=$(mktemp "$WRAPPER_RUNTIME_LOCKS/.rebind-XXXXXX")
  git -C "$WRAPPER_RUNTIME" show "${rebind_source}:${BACKLOG_REL}" \
    > "$rebind_snapshot"
  rebind_facts=$(forward_classify_snapshot EWRUNTIME "$rebind_snapshot" \
    "$rebind_source" "$rebind_blob" postclaim verified true)
  rm -f "$rebind_snapshot"
  IFS=$'\t' read -r _ _ _ _ _ rebind_record _ _ <<< "$rebind_facts"
  rc=0
  launch_3phase_in_tmux EWRUNTIME trace "$rebind_source" "$rebind_blob" \
    "$rebind_record" || rc=$?
  effects=$(find "$WRAPPER_TEST_SENTINELS" -type f -exec basename {} \; \
    | sort | tr '\n' ',')
  authority_files=absent
  [[ -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.lock" \
      && -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.heartbeat" ]] \
    && authority_files=preserved
  rebind_results="${rebind_results}${WRAPPER_TEST_MODE}:${rc}:${effects}:${authority_files};"
  rm -f "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.lock" \
    "$WRAPPER_RUNTIME_LOCKS/EWRUNTIME.heartbeat"
done
git -C "$WRAPPER_RUNTIME" remote set-url origin "$WRAPPER_RUNTIME_ORIGIN"
printf '  wrapper rebind observed=%s\n' "$rebind_results"
expect "wrapper accepts other-Story advances and latches every lost target authority" \
  test "$rebind_results" = \
    'rebind_unrelated:1:impl,qa,reaper,reconcile,:absent;rebind_other_story_code:1:impl,qa,reaper,reconcile,:absent;rebind_receipt_same_phase_error:1:impl,:preserved;rebind_same_story_field:1:impl,:preserved;rebind_same_story_contract:1:impl,:preserved;rebind_same_story_phase:1:impl,:preserved;rebind_absent:1:impl,:preserved;rebind_stale:1:impl,:preserved;rebind_nonancestor:1:impl,:preserved;rebind_fetch_fail:1:impl,:preserved;'

# The commit-bound Story reducer must authenticate the bytes held on its open
# descriptor against commit:path.  A same-owner replacement with another valid
# private YAML file cannot forge B/D equality, and malformed duplicate IDs
# anywhere in the backlog invalidate the whole authority object.
BLOB_REPO="$TMP/commit-bound-repo"
BLOB_LOCKS="$TMP/commit-bound-locks"
BLOB_FORGED="$TMP/commit-bound-forged.yaml"
BLOB_ERROR="$TMP/commit-bound-error.log"
mkdir -p "$BLOB_REPO/.gaai/project/contexts/backlog" \
  "$BLOB_REPO/.gaai/project/contexts/artefacts/stories" "$BLOB_LOCKS"
chmod 700 "$BLOB_LOCKS"
git init "$BLOB_REPO" >/dev/null
git -C "$BLOB_REPO" config user.email test@example.invalid
git -C "$BLOB_REPO" config user.name test
cat > "$BLOB_REPO/$BACKLOG_REL" <<'EOF'
items:
- id: EBOUND
  status: in_progress
  phase_status: planned
  notes: exact-commit-bytes
- id: EOTHER
  status: refined
  phase_status: not_started
EOF
printf '%s\n' '# EBOUND contract' \
  > "$BLOB_REPO/.gaai/project/contexts/artefacts/stories/EBOUND.story.md"
git -C "$BLOB_REPO" add "$BACKLOG_REL" \
  .gaai/project/contexts/artefacts/stories/EBOUND.story.md
git -C "$BLOB_REPO" commit -m 'commit-bound authority' >/dev/null
bound_commit=$(git -C "$BLOB_REPO" rev-parse HEAD)
cat > "$BLOB_FORGED" <<'EOF'
items:
- id: EBOUND
  status: in_progress
  phase_status: planned
  notes: forged-same-owner-bytes
- id: EOTHER
  status: refined
  phase_status: not_started
EOF
chmod 600 "$BLOB_FORGED"
bound_swap_rc=0
(
  PROJECT_DIR=$BLOB_REPO
  LOCK_DIR=$BLOB_LOCKS
  source "$ROOT/.gaai/core/scripts/daemon-dispatch.sh" || exit 1
  # Same argv shift as RED-F4: the snapshot is $1 under the boundary entry, not
  # $2 as it was under the `python3 - <path>` spelling.
  _bound_real=$(declare -f yaml_runtime_run)
  yaml_runtime_run(){
    cp "$BLOB_FORGED" "$1" || return 1
    chmod 600 "$1" || return 1
    eval "${_bound_real/#yaml_runtime_run/_bound_orig}"
    _bound_orig "$@"
  }
  _dispatch_story_record_at_commit EBOUND "$bound_commit"
) > /dev/null 2> "$BLOB_ERROR" || bound_swap_rc=$?
expect "commit-bound Story identity rejects same-owner snapshot substitution" \
  test "$bound_swap_rc" -eq 1
expect "commit-bound descriptor rejection is privacy-safe" \
  test ! -s "$BLOB_ERROR"

cat > "$BLOB_REPO/$BACKLOG_REL" <<'EOF'
items:
- id: EBOUND
  status: in_progress
  phase_status: planned
- id: EOTHER
  status: refined
  phase_status: not_started
- id: EOTHER
  status: refined
  phase_status: not_started
EOF
git -C "$BLOB_REPO" add "$BACKLOG_REL"
git -C "$BLOB_REPO" commit -m 'duplicate unrelated Story identity' >/dev/null
duplicate_commit=$(git -C "$BLOB_REPO" rev-parse HEAD)
duplicate_rc=0
(
  PROJECT_DIR=$BLOB_REPO
  LOCK_DIR=$BLOB_LOCKS
  source "$ROOT/.gaai/core/scripts/daemon-dispatch.sh" || exit 1
  _dispatch_story_record_at_commit EBOUND "$duplicate_commit"
) > /dev/null 2> "$BLOB_ERROR" || duplicate_rc=$?
expect "commit-bound Story identity rejects duplicate IDs globally" \
  test "$duplicate_rc" -eq 1

printf '\nFresh effect-edge, dead-lock and QA-replan runtime falsifiers\n'
(
  edge_source=1111111111111111111111111111111111111111
  edge_blob=2222222222222222222222222222222222222222
  edge_record=$(printf '3%.0s' $(seq 1 64))
  edge_calls=0; edge_seen=none; edge_plan=false
  _forward_resolve_worktree(){ printf '%s\n' "$TMP/edge-wt"; }
  _forward_worktree_state(){ printf '%s:%s\n' "$1" "$2" > "$TMP/edge-state"; printf 'verified\n'; }
  _forward_plan_present(){ [[ "$edge_plan" == true ]]; }
  _forward_classify(){
    edge_calls=$((edge_calls + 1)); edge_seen="$3:$4"
    _FORWARD_SOURCE="$edge_source"; _FORWARD_BLOB="$edge_blob"
    _FORWARD_RECORD_DIGEST="$edge_record"; _FORWARD_ACTION=resume
    _FORWARD_REASON=resumable
  }
  mkdir -p "$TMP/edge-wt"
  edge_rc=0
  _forward_last_edge_guard EEDGE "$edge_source" "$edge_blob" "$edge_record" \
    recovery false || edge_rc=$?
  printf '%s:%s:%s:%s\n' "$edge_rc" "$edge_calls" "$(cat "$TMP/edge-state")" "$edge_seen"
) > "$TMP/fresh-edge-result"
expect "last edge freshly re-reads worktree and plan before authority" \
  test "$(cat "$TMP/fresh-edge-result")" = "0:1:EEDGE:false:verified:false"

awk '/^_forward_relaunch\(\)/{on=1} /^_forward_retained_settle\(\)/{on=0} on{print}' \
  "$DAEMON" > "$TMP/forward-relaunch-real.sh"
(
  # Earlier R4 evidence cases intentionally install a downstream sentinel
  # double.  Reload the production function in this isolated process so this
  # falsifier exercises the real dead-owner boundary.
  source "$TMP/forward-relaunch-real.sh"
  dead_source=1111111111111111111111111111111111111111
  dead_blob=2222222222222222222222222222222222222222
  dead_record=$(printf '3%.0s' $(seq 1 64)); dead_digest=$(printf '4%.0s' $(seq 1 64))
  dead_context="$TMP/dead-context"; : > "$dead_context"
  dead_retire=0; dead_remove=0; dead_retry=0; dead_spawn=0; MAX_CONCURRENT=1
  _forward_resolve_worktree(){ printf '%s\n' "$TMP/dead-wt"; }
  _forward_worktree_state(){ printf 'verified\n'; }
  _forward_plan_present(){ return 0; }
  _forward_classify(){
    _FORWARD_SOURCE="$dead_source"; _FORWARD_BLOB="$dead_blob"
    _FORWARD_RECORD_DIGEST="$dead_record"; _FORWARD_SOURCE_DIGEST="$dead_digest"
    _FORWARD_ACTION=resume; _FORWARD_REASON=resumable
    _FORWARD_SNAPSHOT="$TMP/dead-snapshot"; : > "$_FORWARD_SNAPSHOT"
  }
  forward_context_read(){
    printf 'EDEAD\t%s\t%s\t%s\tnone\tnone\tnone\tnone\tnone\tnone\tverified\tresume\tresumable\tnone\t%s\n' \
      "$dead_source" "$dead_blob" "$dead_record" "$dead_digest"
  }
  _journal_inspect_pending_lifecycle(){ return 2; }
  _forward_revalidate_after_reconcile(){ _FORWARD_FINAL_INTEGRITY=verified; }
  _forward_lock_state(){ printf 'dead\t999999999\n'; }
  _forward_active_markers_clear(){ return 0; }; _forward_runner_state(){ printf 'clear\n'; }
  tmux(){ return 1; }; active_count(){ printf '0\n'; }; has_exceeded_retries(){ return 1; }
  _reconcile_story_file_from_staging(){ return 0; }
  _forward_retire_dead_lock(){ dead_retire=$((dead_retire + 1)); }
  forward_context_remove(){ dead_remove=$((dead_remove + 1)); }
  increment_retry(){ dead_retry=$((dead_retry + 1)); }
  launch_3phase_in_tmux(){ dead_spawn=$((dead_spawn + 1)); }
  mkdir -p "$TMP/dead-wt"
  dead_rc=0; _forward_relaunch EDEAD "$dead_context" "$dead_digest" || dead_rc=$?
  printf '%s:%s:%s:%s:%s:%s\n' "$dead_rc" "$dead_retire" "$dead_remove" \
    "$dead_retry" "$dead_spawn" "$([[ -e "$dead_context" ]] && printf present || printf gone)"
) > "$TMP/dead-lock-result"
printf '  dead-lock observed=%s expected=2:1:0:0:0:present\n' \
  "$(cat "$TMP/dead-lock-result")"
expect "exact dead lock is retired and deferred with context/retry/spawn untouched" \
  test "$(cat "$TMP/dead-lock-result")" = "2:1:0:0:0:present"

OWN_REPO="$TMP/qa-replan-repo"; OWN_WT="$TMP/qa-replan-worktree"
git init "$OWN_REPO" >/dev/null
git -C "$OWN_REPO" config user.email test@example.invalid
git -C "$OWN_REPO" config user.name test
printf 'base\n' > "$OWN_REPO/base.txt"; git -C "$OWN_REPO" add base.txt
git -C "$OWN_REPO" commit -m base >/dev/null
git -C "$OWN_REPO" branch story/EOWN
git -C "$OWN_REPO" worktree add "$OWN_WT" story/EOWN >/dev/null
OWN_WT=$(cd "$OWN_WT" && pwd -P)
printf 'ahead\n' > "$OWN_WT/ahead.txt"; git -C "$OWN_WT" add ahead.txt
git -C "$OWN_WT" commit -m 'story worktree ahead of target' >/dev/null
own_result=$("$TEST_BASH" -s -- "$ROOT" "$OWN_REPO" "$OWN_WT" <<'BASH'
set -u
root="$1"; PROJECT_DIR="$2"; worktree="$3"
LOCK_DIR=$(mktemp -d); trap 'rm -rf "$LOCK_DIR"' EXIT
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
source "$root/.gaai/core/scripts/daemon-dispatch.sh" || exit 1
owned=0; _plan_story_worktree_owned EOWN "$worktree" || owned=$?
git -C "$worktree" checkout --detach >/dev/null 2>&1
detached=0; _plan_story_worktree_owned EOWN "$worktree" || detached=$?
printf '%s:%s\n' "$owned" "$detached"
BASH
)
expect "QA replan admits only the exact registered story branch without HEAD==target" \
  test "$own_result" = "0:1"

printf '\nRestrictive-umask runtime-tuple repair on both authorized recovery callers\n'

# A checkout made by a process with a restrictive umask materializes the three
# vendored runtime files at 0600, which the runtime boundary refuses on its
# exact-mode check. Both authorized callers of the shared recovery helper repair
# exactly those three files and then re-verify the tuple against the worktree's
# own HEAD tree, before admission, a retry, a spawn, a push or any consumer. The
# helper itself is never edited and is never stubbed anywhere except where noted.

D10_VENDOR="$ROOT/.gaai/core/vendor/pyyaml/6.0.3"

d10_mode_of() {
  if stat -f '%Lp' / >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1" 2>/dev/null
  else
    stat -c '%a' -- "$1" 2>/dev/null
  fi
}

# d10_seed_tuple <tree-root> — the four tuple paths at 0644.
d10_seed_tuple() {
  local root="$1"
  mkdir -p "$root/.gaai/core/scripts/lib" "$root/.gaai/core/vendor/pyyaml/6.0.3"
  cp "$ROOT/.gaai/core/scripts/lib/yaml-runtime.sh" "$root/.gaai/core/scripts/lib/"
  cp "$D10_VENDOR/pyyaml-runtime.pyz" "$D10_VENDOR/PROVENANCE.json" \
     "$D10_VENDOR/LICENSE" "$root/.gaai/core/vendor/pyyaml/6.0.3/"
  chmod 0644 "$root/.gaai/core/scripts/lib/yaml-runtime.sh" \
             "$root/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" \
             "$root/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json" \
             "$root/.gaai/core/vendor/pyyaml/6.0.3/LICENSE"
}

# d10_private_core <base> — a private copy of the core tree whose helper copy has
# its descriptor mode change forced to fail. This is the only way to produce that
# fault deterministically without root, and it never touches production.
d10_private_core() {
  local base="$1" helper
  mkdir -p "$base/.gaai"
  cp -R "$ROOT/.gaai/core" "$base/.gaai/core"
  helper="$base/.gaai/core/scripts/lib/yaml-runtime.sh"
  awk '{ if ($0 ~ /^                    os\.fchmod\(fd, EXACT_FILE_MODE\)$/) print "                    raise OSError(13, \"forced\")"; else print }' \
    "$helper" > "$helper.tmp" && mv "$helper.tmp" "$helper"
  grep -q 'raise OSError(13, "forced")' "$helper" || return 1
  printf '%s\n' "$base"
}

# d10_make_repo <base> <sid> — a private repository with a bare origin carrying
# origin/staging, and a story worktree holding one clean local commit that is not
# reachable from that remote ref.
d10_make_repo() {
  local base="$1" sid="$2"
  local origin="$base/origin.git" repo="$base/repo" wt="$base/worktrees/${sid}-workspace"
  mkdir -p "$repo/.gaai/project/contexts/backlog" "$base/worktrees" "$base/locks"
  chmod 700 "$base/locks"
  d10_seed_tuple "$repo"
  printf 'items:\n- id: %s\n  status: in_progress\n  phase_status: qa_passed\n  started_at: "1997-07-16T10:00:00Z"\n' \
    "$sid" > "$repo/.gaai/project/contexts/backlog/active.backlog.yaml"
  git init -q --bare "$origin" >/dev/null 2>&1
  git init -q "$repo" >/dev/null 2>&1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -qm base >/dev/null 2>&1
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q origin HEAD:refs/heads/staging >/dev/null 2>&1
  git -C "$repo" fetch -q origin staging >/dev/null 2>&1
  git -C "$repo" branch "story/${sid}" HEAD >/dev/null 2>&1
  git -C "$repo" worktree add "$wt" "story/${sid}" >/dev/null 2>&1
  printf 'ahead\n' > "$wt/ahead.txt"
  git -C "$wt" add ahead.txt >/dev/null 2>&1
  git -C "$wt" commit -qm 'story commit not reachable from the remote ref' >/dev/null 2>&1
}

# The stub body both rows install AFTER sourcing the real library. It is the ONLY
# stub either row is allowed to use.
D10_STUB_BODY='
_recover_worktree_safe_base() {
  local rsid="$1" rwt="$2"
  if [ "${D10_FAULT}" != stillahead ]; then
    git -C "$rwt" reset --hard origin/staging >/dev/null 2>&1 || return 1
  fi
  rm -f "$rwt/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" \
        "$rwt/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json" \
        "$rwt/.gaai/core/vendor/pyyaml/6.0.3/LICENSE"
  ( umask 077
    cp "$D10_SOURCE_VENDOR/pyyaml-runtime.pyz" "$D10_SOURCE_VENDOR/PROVENANCE.json" \
       "$D10_SOURCE_VENDOR/LICENSE" "$rwt/.gaai/core/vendor/pyyaml/6.0.3/" )
  case "${D10_FAULT}" in
    symlink)
      rm -f "$rwt/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
      ln -s "$D10_LINK_TARGET" "$rwt/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
      ;;
    swap)
      printf "swapped\n" > "$rwt/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
      chmod 0600 "$rwt/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
      ;;
  esac
  return 0
}
'

d10_link_target() {
  local path="$TMP/d10-link-target.pyz"
  if [[ ! -f "$path" ]]; then
    cp "$D10_VENDOR/pyyaml-runtime.pyz" "$path"
    chmod 0600 "$path"
  fi
  printf '%s\n' "$path"
}

# d10_expect_refusal_stage <label> <fault> <output> — the success-status rule, per
# refusal stage. This is stage accuracy, not a softened refusal.
#
# The pair is ordered normalize -> worktree-local exact verification, and the
# normalizer inspects no content by design: it opens no archive, digests nothing
# and reads no blob. A symlinked path, a foreign owner and a failed descriptor
# mode change are therefore refusals of the NORMALIZER itself, and on those runs
# no success status may exist at all.
#
# A content swap is invisible to that program by construction — the file is
# regular, owned by this uid and keeps its (st_dev, st_ino) across the repair — so
# it is necessarily caught one stage later, by the worktree-local exact blob/mode
# verification. Demanding "no code=ok" there would assert that normalization
# failed, which the contract does not claim and which no correct implementation
# can satisfy; it would test a harness artefact instead of the contract. What the
# contract does say is asserted instead, and is strictly stronger for that stage:
# the refusal carries the verification's own role and action, every success status
# on the run is the normalizer's own, and none appears at or after the refusal.
# The typed refusal, the fail-closed outcome and the ordering assertions around
# this call are unchanged for every fault.
d10_expect_refusal_stage() {
  local label="$1" fault="$2" out="$3" refuse last_ok
  if [[ "$fault" != swap ]]; then
    expect "$label: the success status never appears on a refusal path" \
      test "$(printf '%s\n' "$out" | grep -c 'code=ok')" -eq 0
    return 0
  fi
  expect "$label: the refusal is the worktree-local verification, the stage after normalization" \
    grep -q 'role=verify action=worktree_tuple code=yaml_runtime_asset_invalid' <<<"$out"
  refuse=$(printf '%s\n' "$out" | grep -n 'code=yaml_runtime_asset_invalid' | head -1 | cut -d: -f1)
  last_ok=$(printf '%s\n' "$out" | grep -n 'code=ok' | tail -1 | cut -d: -f1)
  # The defaults keep the expression well-formed on a broken run; the -n term is
  # what makes a missing refusal line fail the case rather than pass it.
  expect "$label: every success status is the normalizer's own and none appears at or after the refusal" \
    test "$(printf '%s\n' "$out" | grep -c 'code=ok')" \
      -eq "$(printf '%s\n' "$out" | grep -c 'role=normalize action=vendor_modes code=ok')" \
      -a -n "$refuse" -a "${last_ok:-0}" -lt "${refuse:-0}"
}

# ── Row 8: the real handle_commit_phase, pre-push recovery site ──────────────
d10_row8() {
  local fault="$1"
  local base="$TMP/d10-row8-$fault" core="$ROOT"
  local sid=ED10R8
  mkdir -p "$base"
  if [[ "$fault" == "fchmod" ]]; then
    core=$(d10_private_core "$base/core") || { printf 'PRIVATE_CORE_FAILED\n'; return 0; }
  fi
  d10_make_repo "$base" "$sid"
  D10_FAULT="$fault" D10_SOURCE_VENDOR="$D10_VENDOR" D10_LINK_TARGET="$(d10_link_target)" \
  D10_STUB="$D10_STUB_BODY" \
  "$TEST_BASH" -s -- "$core" "$base" "$sid" <<'BASH' 2>&1
set -u
core="$1"; base="$2"; sid="$3"
PROJECT_DIR="$base/repo"; REPO_ROOT="$PROJECT_DIR"
GAAI_WORKTREES_BASE="$base/worktrees"
LOCK_DIR="$base/locks"
TARGET_BRANCH=staging
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"
export GAAI_WORKTREE_COMMITS_AHEAD_MAX=0
# 1. Source the REAL dispatcher first. It sources the real lib/worktree-integrity.sh,
#    which would otherwise overwrite a stub installed before it — so the order is
#    load-bearing, and the suite's own top-level stub is NOT what this case lands on.
source "$core/.gaai/core/scripts/daemon-dispatch.sh" || { echo "SOURCE_FAILED"; exit 1; }
declare -f _check_worktree_integrity | grep -q 'WORKTREE-CHECK' \
  || { echo "REAL_INTEGRITY_ABSENT"; exit 1; }
# 2. THEN install the ONLY allowed stub.
eval "$D10_STUB"
handle_commit_phase "$sid" trace-d10-row8
echo "RC=$?"
for f in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
  p="$GAAI_WORKTREES_BASE/${sid}-workspace/.gaai/core/vendor/pyyaml/6.0.3/$f"
  if [ -L "$p" ]; then m=symlink
  elif stat -f '%Lp' / >/dev/null 2>&1; then m=$(stat -f '%Lp' -- "$p" 2>/dev/null)
  else m=$(stat -c '%a' -- "$p" 2>/dev/null); fi
  echo "MODE $f=${m:-absent}"
done
p="$GAAI_WORKTREES_BASE/${sid}-workspace/.gaai/core/scripts/lib/yaml-runtime.sh"
if stat -f '%Lp' / >/dev/null 2>&1; then echo "MODE helper=$(stat -f '%Lp' -- "$p")"
else echo "MODE helper=$(stat -c '%a' -- "$p")"; fi
BASH
}

D10_R8_OK=$(d10_row8 none)
# The three vendor names are matched explicitly because this case also prints the
# helper's mode, which must NOT be counted here. `grep -E` is required: `\|` is a
# GNU BRE extension that the BSD grep on the macOS lanes matches literally, so a
# BRE alternation would silently count zero lines on a correct tuple.
expect "row 8: recovered tuple is at exact 0644 immediately before admission" \
  test "$(printf '%s\n' "$D10_R8_OK" | grep -c -E '^MODE (pyyaml-runtime\.pyz|PROVENANCE\.json|LICENSE)=644$')" -eq 3
expect "row 8: the normalizer reported completion before the caller verified" \
  grep -q 'action=vendor_modes code=ok' <<<"$D10_R8_OK"
D10_R8_L_RECOVERY=$(printf '%s\n' "$D10_R8_OK" | grep -n 'worktree recovery succeeded' | head -1 | cut -d: -f1)
D10_R8_L_OK=$(printf '%s\n' "$D10_R8_OK" | grep -n 'action=vendor_modes code=ok' | head -1 | cut -d: -f1)
D10_R8_L_ADMIT=$(printf '%s\n' "$D10_R8_OK" | grep -n 'LOCAL-ADMISSION' | head -1 | cut -d: -f1)
expect "row 8: recovery success, then normalization, then admission — in that order" \
  test -n "$D10_R8_L_RECOVERY" -a -n "$D10_R8_L_OK" -a -n "$D10_R8_L_ADMIT" \
    -a "$D10_R8_L_RECOVERY" -lt "$D10_R8_L_OK" -a "$D10_R8_L_OK" -lt "$D10_R8_L_ADMIT"
expect "row 8: no mode change reached any file outside the three vendor paths" \
  grep -q '^MODE helper=644$' <<<"$D10_R8_OK"
expect "row 8: admission began (the pre-admission sequence completed)" \
  grep -q 'LOCAL-ADMISSION' <<<"$D10_R8_OK"

for D10_R8_FAULT in symlink swap fchmod; do
  D10_R8_OUT=$(d10_row8 "$D10_R8_FAULT")
  expect "row 8/$D10_R8_FAULT: the helper refuses with the existing typed asset code" \
    grep -q 'code=yaml_runtime_asset_invalid' <<<"$D10_R8_OUT"
  expect "row 8/$D10_R8_FAULT: the caller classifies it as worktree corruption" \
    grep -q '\[class=WORKTREE_CORRUPTION\]' <<<"$D10_R8_OUT"
  expect "row 8/$D10_R8_FAULT: handle_commit_phase returns 1" \
    grep -q '^RC=1$' <<<"$D10_R8_OUT"
  # The distinguishing fact: the refusal landed BEFORE admission began. "no push"
  # is corroborating only — the push loop is unreachable in this fixture either way.
  expect "row 8/$D10_R8_FAULT: no admission-routing record at all" \
    test "$(printf '%s\n' "$D10_R8_OUT" | grep -c 'LOCAL-ADMISSION')" -eq 0
  d10_expect_refusal_stage "row 8/$D10_R8_FAULT" "$D10_R8_FAULT" "$D10_R8_OUT"
done

# ── Row 9: the real _forward_prepare_worktree, the caller that owns propagation ──
# Entering at _forward_repair_worktree_exact alone would prove only that the repair
# returns non-zero; it would prove nothing about propagation, which is the property
# this depends on. None of the suite's four _forward_prepare_worktree redefinitions
# is a drive of this path and none may be cited as one.
d10_row9() {
  local fault="$1" via="${2:-prepare}"
  local base="$TMP/d10-row9-$fault-$via" core="$ROOT"
  local sid=ED10R9
  mkdir -p "$base"
  if [[ "$fault" == "fchmod" ]]; then
    core=$(d10_private_core "$base/core") || { printf 'PRIVATE_CORE_FAILED\n'; return 0; }
  fi
  d10_make_repo "$base" "$sid"
  D10_FAULT="$fault" D10_SOURCE_VENDOR="$D10_VENDOR" D10_LINK_TARGET="$(d10_link_target)" \
  D10_STUB="$D10_STUB_BODY" \
  "$TEST_BASH" -s -- "$core" "$base" "$sid" "$via" <<'BASH' 2>&1
set -u
core="$1"; base="$2"; sid="$3"; via="$4"
PROJECT_DIR="$base/repo"; REPO_ROOT="$PROJECT_DIR"
GAAI_WORKTREES_BASE="$base/worktrees"
LOCK_DIR="$base/locks"
TARGET_BRANCH=staging
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"
export GAAI_WORKTREE_COMMITS_AHEAD_MAX=0
awk '/^_forward_sha256\(\)/{on=1} /^exceeded_stories\(\)/{on=0} on{print}' \
  "$core/.gaai/core/scripts/delivery-daemon.sh" > "$base/coordinator.sh"
# The coordinator window starts at _forward_sha256, but the caller-side wrapper of
# the D10 pair, _daemon_repair_tuple, is defined earlier in the SAME production
# file — in the startup region, which cannot be sourced here because it also runs
# top-level preflight code. Its one real body is therefore extracted verbatim from
# the same file, exactly as this suite already appends further real slices to its
# own harness: the repair coordinator must call production's own wrapper, never a
# re-implementation and never a stub. Left out, the wrapper is simply an undefined
# command whose non-zero status would look like a fail-closed refusal while
# proving nothing at all about the D10 pair — which is why the run below asserts
# the real wrapper is in scope before any case executes.
awk '$0 == "_daemon_repair_tuple() {" {on=1} on{print} on && $0 == "}" {on=0}' \
  "$core/.gaai/core/scripts/delivery-daemon.sh" >> "$base/coordinator.sh"
source "$core/.gaai/core/scripts/lib/stuck-classifier.sh" || { echo "SOURCE_FAILED"; exit 1; }
source "$base/coordinator.sh" || { echo "SOURCE_FAILED"; exit 1; }
declare -f _daemon_repair_tuple | grep -q 'yaml_runtime_repair_and_verify_tree' \
  || { echo "REAL_REPAIR_WRAPPER_ABSENT"; exit 1; }
echo "WRAPPER=real"
# The awk harness re-sources no library and _forward_worktree_state calls the real
# integrity check, so the real library is sourced FIRST — that is also what
# displaces the suite's inherited top-level stubs, none of which a row-9 case may
# land on — and only THEN is the one allowed stub installed.
source "$core/.gaai/core/scripts/lib/worktree-integrity.sh" || { echo "SOURCE_FAILED"; exit 1; }
declare -f _check_worktree_integrity | grep -q 'WORKTREE-CHECK' \
  || { echo "REAL_INTEGRITY_ABSENT"; exit 1; }
eval "$D10_STUB"
log() { printf '%s\n' "$*"; }
expected=$(git -C "$PROJECT_DIR" rev-parse origin/staging)
# The first verdict is earned, not stubbed: the worktree holds one clean commit
# that is not reachable from origin/staging, and the threshold is 0, so the real
# check observes commits_ahead > 0 on a valid HEAD and returns 1:recoverable.
first=$(_forward_worktree_state "$sid" false); first_rc=$?
echo "FIRST=$first_rc:$first"
if [ "$via" = revalidate ]; then
  _forward_revalidate_after_reconcile "$sid" "$expected" \
    0000000000000000000000000000000000000000 \
    "$(printf '0%.0s' $(seq 1 64))" recovery false
  echo "RC=$?"
else
  out=$(_forward_prepare_worktree "$sid" "$expected" false)
  echo "RC=$?"
  echo "OUT=$out"
fi
for f in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
  p="$GAAI_WORKTREES_BASE/${sid}-workspace/.gaai/core/vendor/pyyaml/6.0.3/$f"
  if [ -L "$p" ]; then m=symlink
  elif stat -f '%Lp' / >/dev/null 2>&1; then m=$(stat -f '%Lp' -- "$p" 2>/dev/null)
  else m=$(stat -c '%a' -- "$p" 2>/dev/null); fi
  echo "MODE $f=${m:-absent}"
done
BASH
}

D10_R9_OK=$(d10_row9 none)
expect "row 9: the D10 pair runs through production's own caller-side wrapper" \
  grep -q '^WRAPPER=real$' <<<"$D10_R9_OK"
expect "row 9: the first verdict is earned from the fixture, not from a stub" \
  grep -q '^FIRST=1:recoverable$' <<<"$D10_R9_OK"
expect "row 9: the real prepare path returns verified after repair and normalization" \
  grep -q '^OUT=verified$' <<<"$D10_R9_OK"
expect "row 9: the recovered tuple is at exact 0644 before the fresh verdict" \
  test "$(printf '%s\n' "$D10_R9_OK" | grep -c '=644$')" -eq 3
expect "row 9: the normalizer reported completion on this run" \
  grep -q 'action=vendor_modes code=ok' <<<"$D10_R9_OK"

D10_R9_AHEAD=$(d10_row9 stillahead)
expect "row 9: a successful repair and a successful normalization still fail the fresh verdict" \
  test "$(printf '%s\n' "$D10_R9_AHEAD" | grep -c '^OUT=verified$')" -eq 0
expect "row 9: the fresh-verdict control proves the second state verdict really runs" \
  grep -q 'action=vendor_modes code=ok' <<<"$D10_R9_AHEAD"

for D10_R9_FAULT in symlink swap fchmod; do
  D10_R9_OUT=$(d10_row9 "$D10_R9_FAULT")
  expect "row 9/$D10_R9_FAULT: the helper refuses with the existing typed asset code" \
    grep -q 'code=yaml_runtime_asset_invalid' <<<"$D10_R9_OUT"
  expect "row 9/$D10_R9_FAULT: the non-zero return propagates out of the real prepare path" \
    test "$(printf '%s\n' "$D10_R9_OUT" | grep -c '^RC=0$')" -eq 0
  expect "row 9/$D10_R9_FAULT: no verified verdict is produced" \
    test "$(printf '%s\n' "$D10_R9_OUT" | grep -c '^OUT=verified$')" -eq 0
  d10_expect_refusal_stage "row 9/$D10_R9_FAULT" "$D10_R9_FAULT" "$D10_R9_OUT"
done

# The fchmod-failure fault is the strict ordering discriminator: it leaves the
# worktree content clean and non-ahead, so had the refusal not preceded the fresh
# state verdict, that verdict would have returned verified/0. Observing no
# verified with a non-zero return therefore proves the refusal landed first.
D10_R9_REVAL=$(d10_row9 fchmod revalidate)
expect "row 9: the refusal reaches revalidation before classification, context, retry or spawn" \
  test "$(printf '%s\n' "$D10_R9_REVAL" | grep -c '^RC=0$')" -eq 0

printf '\nUnconditional startup normalization of the effective daemon home\n'

# The startup step is otherwise evidenced only by an operator record and by a
# static coverage census, which observes no execution. This is the durable proof,
# driving the REAL daemon entrypoint. It never starts a daemon: --status only sets
# the status flag during argument parsing and its handler runs far downstream of
# the preflight region, exiting without launching, spawning or pushing anything.
d10_startup() {
  local fault="$1" mask="${2:-077}"
  local base="$TMP/d10-startup-$fault-$mask"
  local home="$base/home" state="$base/state" stub="$base/stubbin"
  local core="$ROOT"
  mkdir -p "$base" "$state" "$stub"
  if [[ "$fault" == "fchmod" || "$fault" == "owner" ]]; then
    core=$(d10_private_core "$base/core") || { printf 'PRIVATE_CORE_FAILED\n'; return 0; }
  fi
  # Recording stubs. `claude` exists only for a command lookup and is never
  # executed; `tmux` is necessarily invoked once, as a version probe, by the
  # pipe-pane capability detection that runs after the startup pair — so the
  # no-start evidence is an argv contract, never an empty-log contract.
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/tmux.log"\nif [ "$1" = "-V" ]; then echo "tmux 3.4"; fi\nexit 0\n' \
    "$stub" > "$stub/tmux"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/claude.log"\nexit 0\n' "$stub" > "$stub/claude"
  chmod 0755 "$stub/tmux" "$stub/claude"

  mkdir -p "$home/.gaai/project/contexts/backlog"
  # The home library layout the entrypoint actually requires.
  mkdir -p "$home/.gaai/core/scripts/lib"
  cp "$core/.gaai/core/scripts/delivery-daemon.sh" \
     "$core/.gaai/core/scripts/backlog-scheduler.sh" "$home/.gaai/core/scripts/"
  cp "$core/.gaai/core/scripts/lib/chore-commit.sh" \
     "$core/.gaai/core/scripts/lib/backlog-yaml.sh" \
     "$core/.gaai/core/scripts/lib/worktree-integrity.sh" \
     "$core/.gaai/core/scripts/lib/stuck-classifier.sh" \
     "$core/.gaai/core/scripts/lib/home-branch-guard.sh" \
     "$core/.gaai/core/scripts/lib/daemon-home.sh" "$home/.gaai/core/scripts/lib/"
  printf 'items: []\n' > "$home/.gaai/project/contexts/backlog/active.backlog.yaml"
  # The tuple is materialized under an EXPLICITLY SET umask. The restrictive
  # condition is constructed here; it is never presented as an observed default.
  ( umask "$mask"
    mkdir -p "$home/.gaai/core/vendor/pyyaml/6.0.3"
    cp "$core/.gaai/core/scripts/lib/yaml-runtime.sh" "$home/.gaai/core/scripts/lib/"
    cp "$D10_VENDOR/pyyaml-runtime.pyz" "$D10_VENDOR/PROVENANCE.json" \
       "$D10_VENDOR/LICENSE" "$home/.gaai/core/vendor/pyyaml/6.0.3/" )
  if [[ "$mask" == "077" ]]; then
    chmod 0600 "$home/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" \
               "$home/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json" \
               "$home/.gaai/core/vendor/pyyaml/6.0.3/LICENSE"
  else
    chmod 0644 "$home/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" \
               "$home/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json" \
               "$home/.gaai/core/vendor/pyyaml/6.0.3/LICENSE"
  fi
  git init -q "$home" >/dev/null 2>&1
  git -C "$home" config user.email test@example.invalid
  git -C "$home" config user.name test
  git -C "$home" add -A >/dev/null 2>&1
  git -C "$home" commit -qm home >/dev/null 2>&1
  case "$fault" in
    swap) printf 'swapped\n' > "$home/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" ;;
    symlink)
      rm -f "$home/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
      ln -s "$(d10_link_target)" "$home/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" ;;
    owner)
      awk '{ if ($0 ~ /^                if before\.st_uid != os\.geteuid\(\):$/) print "                if before.st_uid != os.geteuid() + 1:"; else print }' \
        "$home/.gaai/core/scripts/lib/yaml-runtime.sh" > "$home/helper.tmp" \
        && mv "$home/helper.tmp" "$home/.gaai/core/scripts/lib/yaml-runtime.sh"
      chmod 0600 "$home/.gaai/core/scripts/lib/yaml-runtime.sh" ;;
  esac
  env GAAI_DAEMON_HOME="$home" GAAI_REPO_ROOT="$base/state" \
      PATH="$stub:$PATH" \
      "$TEST_BASH" "$home/.gaai/core/scripts/delivery-daemon.sh" --status 2>&1
  echo "RC=$?"
  for f in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
    p="$home/.gaai/core/vendor/pyyaml/6.0.3/$f"
    if [ -L "$p" ]; then m=symlink
    elif stat -f '%Lp' / >/dev/null 2>&1; then m=$(stat -f '%Lp' -- "$p" 2>/dev/null)
    else m=$(stat -c '%a' -- "$p" 2>/dev/null); fi
    echo "MODE $f=${m:-absent}"
  done
  echo "TMUX_RECORDS=$( [ -f "$stub/tmux.log" ] && wc -l < "$stub/tmux.log" | tr -d ' ' || echo 0)"
  echo "TMUX_ARGV=$( [ -f "$stub/tmux.log" ] && tr '\n' ',' < "$stub/tmux.log" || true)"
  echo "CLAUDE_LOG=$( [ -f "$stub/claude.log" ] && echo present || echo absent)"
}

D10_START_OK=$(d10_startup none 077)
expect "startup: a 0600 daemon-home tuple is normalized to exact 0644" \
  test "$(printf '%s\n' "$D10_START_OK" | grep -c '=644$')" -eq 3
expect "startup: normalization and verification precede any status output" \
  test "$(printf '%s\n' "$D10_START_OK" | grep -n 'code=ok' | head -1 | cut -d: -f1)" \
       -lt "$(printf '%s\n' "$D10_START_OK" | grep -n 'GAAI Delivery Daemon' | head -1 | cut -d: -f1)"
expect "startup: the run crosses the gate and reaches the status handler" \
  grep -q 'GAAI Delivery Daemon' <<<"$D10_START_OK"
expect "startup: exactly one tmux record" \
  grep -q '^TMUX_RECORDS=1$' <<<"$D10_START_OK"
expect "startup: that record is the version probe and carries no session or effect verb" \
  grep -q '^TMUX_ARGV=-V,$' <<<"$D10_START_OK"
expect "startup: the executor is never executed" \
  grep -q '^CLAUDE_LOG=absent$' <<<"$D10_START_OK"

D10_START_022=$(d10_startup none 022)
expect "startup: under an ordinary umask the step is an idempotent no-op that still re-verifies" \
  test "$(printf '%s\n' "$D10_START_022" | grep -c '=644$')" -eq 3
expect "startup: the idempotent run still reaches the status handler" \
  grep -q 'GAAI Delivery Daemon' <<<"$D10_START_022"

for D10_START_FAULT in swap symlink owner fchmod; do
  D10_START_OUT=$(d10_startup "$D10_START_FAULT" 077)
  expect "startup/$D10_START_FAULT: the existing typed asset code is emitted" \
    grep -q 'code=yaml_runtime_asset_invalid' <<<"$D10_START_OUT"
  expect "startup/$D10_START_FAULT: startup takes the existing fail-closed exit" \
    grep -q '^RC=1$' <<<"$D10_START_OUT"
  expect "startup/$D10_START_FAULT: the status handler is never reached" \
    test "$(printf '%s\n' "$D10_START_OUT" | grep -c 'GAAI Delivery Daemon')" -eq 0
  d10_expect_refusal_stage "startup/$D10_START_FAULT" "$D10_START_FAULT" "$D10_START_OUT"
  expect "startup/$D10_START_FAULT: the refusal precedes the version probe, so both stub logs stay absent" \
    grep -q '^TMUX_RECORDS=0$' <<<"$D10_START_OUT"
  expect "startup/$D10_START_FAULT: the executor is never executed" \
    grep -q '^CLAUDE_LOG=absent$' <<<"$D10_START_OUT"
done
# Nothing outside the vendor directory is touched, including a symlink's target.
expect "the symlink faults never changed the link target's mode" \
  test "$(d10_mode_of "$(d10_link_target)")" = "600"

printf '\nUnowned claims: the scan skips a Story it does not own instead of blocking on it\n'

(
  AC_TMP="$TMP/e1057s06"; mkdir -p "$AC_TMP"
  LOCK_DIR="$AC_TMP/locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  GAAI_WORKTREES_BASE="$AC_TMP/worktrees"; mkdir -p "$GAAI_WORKTREES_BASE"
  TARGET_BRANCH=staging
  BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
  PROJECT_DIR="$AC_TMP/repo"; REPO_ROOT="$PROJECT_DIR"
  BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"; BACKLOG="$BACKLOG_FILE"
  _journal_inspect_pending_lifecycle() { return 2; }
  # Many earlier blocks in this file globally redefine real forward_* helpers
  # against their own fixtures and never restore them (_forward_classify,
  # _forward_context_path, _forward_resolve_worktree, _forward_bind_context,
  # and more). Re-extracting and re-sourcing the pristine span here, inside
  # this subshell only, discards every accumulated mock at once rather than
  # chasing each one individually.
  AC_HARNESS="$AC_TMP/coordinator.sh"
  awk '/^_forward_sha256\(\)/{on=1} /^exceeded_stories\(\)/{on=0} on{print}' "$DAEMON" > "$AC_HARNESS"
  awk '/^_reconcile_story_file_from_staging\(\)/{on=1} /^# ── PR merge watcher/{on=0} on{print}' "$DAEMON" >> "$AC_HARNESS"
  awk '/^_attempt_secret_create\(\)/{on=1} /^# ── Launch 3phase/{on=0} on{print}' "$DAEMON" >> "$AC_HARNESS"
  # shellcheck source=/dev/null
  source "$AC_HARNESS"

  git init --bare "$AC_TMP/origin.git" >/dev/null
  git init "$PROJECT_DIR" >/dev/null
  git -C "$PROJECT_DIR" config user.email test@example.invalid
  git -C "$PROJECT_DIR" config user.name test
  git -C "$PROJECT_DIR" remote add origin "$AC_TMP/origin.git"
  mkdir -p "$(dirname "$BACKLOG_FILE")"
  ac_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  write_ac_backlog() {
    {
      printf 'items:\n'
      for row in "$@"; do
        IFS=: read -r rid rstatus rphase <<< "$row"
        printf -- '- id: %s\n' "$rid"
        printf '  status: %s\n' "$rstatus"
        printf '  phase_status: %s\n' "$rphase"
        [[ "$rstatus" == in_progress ]] && printf '  started_at: "%s"\n' "$ac_started"
      done
    } > "$BACKLOG_FILE"
    git -C "$PROJECT_DIR" add "$BACKLOG_REL"
    git -C "$PROJECT_DIR" commit -qm state >/dev/null
    git -C "$PROJECT_DIR" push -qf origin HEAD:staging >/dev/null
  }

  R="$AC_TMP/results"; mkdir -p "$R"

  # --- AC1: a wholly unowned in-progress Story no longer blocks the scan ---
  write_ac_backlog "EUNOWN:in_progress:not_started"
  ac1_rc=0
  forward_recovery_scan || ac1_rc=$?
  printf '%s' "$ac1_rc" > "$R/ac1_rc"

  # --- AC5: a genuinely daemon-owned, unverifiable claim still blocks the scan ---
  mkdir -p "$GAAI_WORKTREES_BASE/EOWNED-workspace"
  printf '999999\n' > "$LOCK_DIR/EOWNED.lock"; chmod 600 "$LOCK_DIR/EOWNED.lock"
  write_ac_backlog "EOWNED:in_progress:not_started"
  ac5_rc=0
  forward_recovery_scan || ac5_rc=$?
  printf '%s' "$ac5_rc" > "$R/ac5_rc"
  rm -f "$LOCK_DIR/EOWNED.lock"
  rm -rf "$GAAI_WORKTREES_BASE/EOWNED-workspace"

  # --- AC2: the unowned skip leaves no per-Story observable trace ---
  # Isolated from AC1/AC5/AC4's shared LOCK_DIR/GAAI_WORKTREES_BASE so this
  # assertion is hermetic and order-independent (AC6), and scoped to the
  # per-Story artifacts AC2 actually governs. The recovery scan's pre-existing
  # crash-window check (delivery-daemon.sh, unconditional whenever a pending
  # journal run-state is absent) already creates the SHARED
  # ".recovery-contexts" parent directory for any in-progress Story reaching
  # that point, regardless of ownership and unrelated to this Story's change
  # (confirmed unchanged against origin/staging) — so the parent directory's
  # own existence is not itself evidence of an effect this Story introduced.
  # What AC2 promises, and what is asserted here, is that the unowned skip
  # creates no PER-STORY artifact and no backlog mutation.
  AC2_TMP="$AC_TMP/ac2"; mkdir -p "$AC2_TMP"
  LOCK_DIR="$AC2_TMP/locks"; mkdir -p "$LOCK_DIR"; chmod 700 "$LOCK_DIR"
  GAAI_WORKTREES_BASE="$AC2_TMP/worktrees"; mkdir -p "$GAAI_WORKTREES_BASE"
  write_ac_backlog "EUNOWN:in_progress:not_started"
  before_backlog=$(git -C "$PROJECT_DIR" rev-parse origin/staging:"$BACKLOG_REL")
  ac2_rc=0
  _forward_recovery_one EUNOWN || ac2_rc=$?
  after_backlog=$(git -C "$PROJECT_DIR" rev-parse origin/staging:"$BACKLOG_REL")
  ac2_ok=true
  [[ "$ac2_rc" == 0 ]] || ac2_ok=false
  [[ "$before_backlog" == "$after_backlog" ]] || ac2_ok=false
  [[ ! -e "$LOCK_DIR/EUNOWN.lock" ]] || ac2_ok=false
  [[ ! -e "$LOCK_DIR/EUNOWN.heartbeat" ]] || ac2_ok=false
  [[ ! -e "$LOCK_DIR/.recovery-contexts/recovery.scan.EUNOWN.json" ]] || ac2_ok=false
  [[ ! -e "$GAAI_WORKTREES_BASE/EUNOWN-workspace" ]] || ac2_ok=false
  [[ ! -e "$LOCK_DIR/.retry-counts" ]] || ac2_ok=false
  if [[ "$ac2_ok" == true ]]; then
    printf 'pass' > "$R/ac2"
  else
    printf 'fail' > "$R/ac2"
  fi
  LOCK_DIR="$AC_TMP/locks"
  GAAI_WORKTREES_BASE="$AC_TMP/worktrees"

  # --- AC4: both the skip and a real block leave a Story-naming record on the
  # operator daemon log surface, not only the process error stream ---
  LOG_FILE="$AC_TMP/daemon.log"; : > "$LOG_FILE"
  log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
  ac4_skip_rc=0
  _forward_recovery_one EUNOWN >/dev/null 2>"$AC_TMP/ac4-skip.stderr" || ac4_skip_rc=$?
  if [[ "$ac4_skip_rc" == 0 ]] \
      && grep -q 'story=EUNOWN .*outcome=noop reason=unowned_claim' "$LOG_FILE" \
      && grep -q 'story=EUNOWN .*outcome=noop reason=unowned_claim' "$AC_TMP/ac4-skip.stderr"; then
    printf 'pass' > "$R/ac4_skip"
  else
    printf 'fail' > "$R/ac4_skip"
  fi

  mkdir -p "$GAAI_WORKTREES_BASE/EOWNED-workspace"
  printf '999999\n' > "$LOCK_DIR/EOWNED.lock"; chmod 600 "$LOCK_DIR/EOWNED.lock"
  write_ac_backlog "EOWNED:in_progress:not_started"
  : > "$LOG_FILE"
  ac4_block_rc=0
  _forward_recovery_one EOWNED >/dev/null 2>"$AC_TMP/ac4-block.stderr" || ac4_block_rc=$?
  if [[ "$ac4_block_rc" == 1 ]] \
      && grep -q 'story=EOWNED .*outcome=blocked reason=integrity_unverified' "$LOG_FILE"; then
    printf 'pass' > "$R/ac4_block"
  else
    printf 'fail' > "$R/ac4_block"
  fi
  rm -f "$LOCK_DIR/EOWNED.lock"
  rm -rf "$GAAI_WORKTREES_BASE/EOWNED-workspace"

  # --- AC3: each ownership signal present in isolation keeps the claim owned ---
  write_ac_backlog "ESIG:in_progress:not_started"
  probe() { local rc=0; _forward_claim_unowned ESIG || rc=$?; printf '%s' "$rc"; }

  probe > "$R/ac3_baseline"

  printf '999999\n' > "$LOCK_DIR/ESIG.lock"; chmod 600 "$LOCK_DIR/ESIG.lock"
  probe > "$R/ac3_lock"
  rm -f "$LOCK_DIR/ESIG.lock"

  touch "$LOCK_DIR/ESIG.heartbeat"
  probe > "$R/ac3_heartbeat"
  rm -f "$LOCK_DIR/ESIG.heartbeat"

  ac_ctx=$(_forward_context_path ESIG)
  : > "$ac_ctx"
  probe > "$R/ac3_context"
  rm -f "$ac_ctx"

  mkdir -p "$GAAI_WORKTREES_BASE/ESIG-workspace"
  probe > "$R/ac3_worktree"
  rm -rf "$GAAI_WORKTREES_BASE/ESIG-workspace"

  probe > "$R/ac3_cleared"
)

R="$TMP/e1057s06/results"
expect "unowned claim: a wholly unowned in-progress Story lets the scan succeed" \
  test "$(cat "$R/ac1_rc" 2>/dev/null)" = 0
expect "unowned claim: a genuinely owned, unverifiable claim still blocks the scan" \
  test "$(cat "$R/ac5_rc" 2>/dev/null)" = 1
expect "unowned claim: the skip mutates nothing — backlog, locks and worktrees untouched" \
  test "$(cat "$R/ac2" 2>/dev/null)" = pass
expect "unowned claim: the skip is diagnosable from the operator daemon log" \
  test "$(cat "$R/ac4_skip" 2>/dev/null)" = pass
expect "unowned claim: a genuine refusal also names the Story on the operator daemon log" \
  test "$(cat "$R/ac4_block" 2>/dev/null)" = pass
expect "unowned claim: zero ownership signals is unowned" \
  test "$(cat "$R/ac3_baseline" 2>/dev/null)" = 0
expect "unowned claim: a lock file alone keeps the claim owned" \
  test "$(cat "$R/ac3_lock" 2>/dev/null)" = 1
expect "unowned claim: a heartbeat alone keeps the claim owned" \
  test "$(cat "$R/ac3_heartbeat" 2>/dev/null)" = 1
expect "unowned claim: a retained recovery context alone keeps the claim owned" \
  test "$(cat "$R/ac3_context" 2>/dev/null)" = 1
expect "unowned claim: a worktree at the daemon's own root alone keeps the claim owned" \
  test "$(cat "$R/ac3_worktree" 2>/dev/null)" = 1
expect "unowned claim: signals cleared, the claim is unowned again" \
  test "$(cat "$R/ac3_cleared" 2>/dev/null)" = 0

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'Failed assertions:\n%s' "$FAILURES"
fi
(( FAIL == 0 ))
