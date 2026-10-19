#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/backlog-journal.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/backlog-journal-test.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/backlog-journal-test.*) rm -rf "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT

# The suite owns its whole environment. A corpus runner or delivery wrapper can
# hand it a HOME shared with other live processes, git redirection variables and
# journal knobs; none of them may reach the fixtures or the emitters.
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
  XDG_CONFIG_HOME
unset GAAI_BACKLOG_JOURNAL_DIR GAAI_BACKLOG_JOURNAL_FAULT GAAI_BACKLOG_JOURNAL_SOURCE_REF \
  GAAI_BACKLOG_JOURNAL_RUN_TOKEN GAAI_BACKLOG_JOURNAL_WRITER_CONTEXT

pass() {
  set +e
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  set +e
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label (expected=$expected actual=$actual)"; fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo/.gaai/project/contexts/backlog"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name backlog-journal-test
}

MAIN_REPO="$TEST_ROOT/main"
init_repo "$MAIN_REPO"
BACKLOG="$MAIN_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"

cat > "$BACKLOG" <<'YAML'
items:
- id: STATUS_DRAFT
  status: draft
  phase_status: not_started
- id: STATUS_REFINED
  status: refined
  phase_status: not_started
- id: STATUS_PROGRESS
  status: in_progress
  phase_status: implemented
- id: STATUS_FAILED
  status: failed
  phase_status: failed
- id: STATUS_ESCALATED
  status: escalated
  phase_status: escalated
- id: STATUS_BLOCKED
  status: blocked
  phase_status: not_started
- id: STATUS_DONE
  status: done
  phase_status: done
- id: STATUS_DEFERRED
  status: deferred
  phase_status: not_started
- id: STATUS_CANCELLED
  status: cancelled
  phase_status: not_started
- id: STATUS_SUPERSEDED
  status: superseded
  phase_status: not_started
- id: PHASE_NOT_STARTED
  status: in_progress
  phase_status: not_started
- id: PHASE_PLANNED
  status: in_progress
  phase_status: planned
- id: PHASE_IMPLEMENTED
  status: in_progress
  phase_status: implemented
- id: PHASE_QA_FAILED
  status: in_progress
  phase_status: qa_failed
- id: PHASE_QA_PASSED
  status: in_progress
  phase_status: qa_passed
- id: PHASE_QA_ESCALATED
  status: in_progress
  phase_status: qa_escalated
- id: PHASE_COMMIT_STALLED
  status: in_progress
  phase_status: commit_stalled
- id: PHASE_DONE
  status: done
  phase_status: done
- id: PHASE_FAILED
  status: failed
  phase_status: failed
- id: PHASE_ESCALATED
  status: escalated
  phase_status: escalated
- id: SCALARS
  status: in_progress
  phase_status: implemented
  started_at: null
  completed_at: null
  blocked_reason: null
  pr_url: null
  pr_number: null
  pr_status: null
  cost_usd: null
- id: ABSENT_SCALARS
  status: in_progress
  phase_status: implemented
- id: EXISTING_SCALARS
  status: in_progress
  phase_status: implemented
  started_at: "2000-01-01T08:00:00Z"
  completed_at: "2000-01-01T08:01:00Z"
  blocked_reason: "external gate pending"
  pr_url: "https://github.com/example/project/pull/7"
  pr_number: 7
  pr_status: open
  cost_usd: 0.000001
- id: PRECISION_COST
  status: in_progress
  phase_status: implemented
  cost_usd: 0.123456789012345678901234567890
- id: OLD_OFFSET
  status: in_progress
  phase_status: implemented
  completed_at: "2000-01-01T09:00:00+01:00"
- id: LEADING_PR
  status: in_progress
  phase_status: implemented
  pr_number: 001
- id: LEADING_COST
  status: in_progress
  phase_status: implemented
  cost_usd: 001
- id: C01
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C02
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C03
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C04
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C05
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C06
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C07
  status: in_progress
  phase_status: implemented
  pr_status: null
- id: C08
  status: in_progress
  phase_status: implemented
  pr_status: null
YAML
git -C "$MAIN_REPO" add .
git -C "$MAIN_REPO" commit -qm init

source "$LIB"
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-main"

backlog_journal_begin_run "$BACKLOG" backlog-scheduler.journal-set
TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
[[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] && pass "run token is library-minted 256-bit hex" || fail "run token shape"
assert_eq minted "$BACKLOG_JOURNAL_OUTCOME" "run token registration succeeds"

PREIMAGE="$(sha256_file "$BACKLOG")"
backlog_journal_emit "$BACKLOG" STATUS_REFINED status in_progress backlog-scheduler.journal-set "$TOKEN" >/dev/null
assert_eq 0 "$?" "valid status record emits"
assert_eq emitted "$BACKLOG_JOURNAL_OUTCOME" "emitted is the success outcome"
assert_eq "$PREIMAGE" "$(sha256_file "$BACKLOG")" "record is durable before backlog mutation"
[[ -f "$BACKLOG_JOURNAL_RECORD_PATH" ]] && pass "record locator exists" || fail "record locator missing"

set +e
backlog_journal_emit "$BACKLOG" STATUS_REFINED status in_progress backlog-scheduler.journal-set "$TOKEN" >/dev/null
REPLAY_RC=$?
set -e
assert_eq 10 "$REPLAY_RC" "exact replay has distinct pending exit"
assert_eq pending:replay "$BACKLOG_JOURNAL_OUTCOME" "exact replay is non-authorizing"
assert_eq "$PREIMAGE" "$(sha256_file "$BACKLOG")" "replay leaves backlog byte-identical"

# Every scalar field accepts its declared shape, including canonical legacy values.
while IFS='|' read -r story field value; do
  backlog_journal_emit "$BACKLOG" "$story" "$field" "$value" backlog-scheduler.journal-set "$TOKEN" >/dev/null
  [[ $? -eq 0 && "$BACKLOG_JOURNAL_OUTCOME" == emitted ]] \
    && pass "valid scalar shape $field" || fail "valid scalar shape $field"
done <<'CASES'
SCALARS|started_at|2000-01-01T09:00:00Z
SCALARS|completed_at|2000-01-01T09:01:00Z
SCALARS|blocked_reason|json:"external gate pending"
SCALARS|pr_url|https://github.com/example/project/pull/8
SCALARS|pr_number|8
SCALARS|pr_status|pending_review
SCALARS|cost_usd|0.125
EXISTING_SCALARS|cost_usd|1.25
PRECISION_COST|cost_usd|0.25
CASES

if jq -e '.record.old_value == "0.12345678901234567890123456789"' \
    "$BACKLOG_JOURNAL_RECORD_PATH" >/dev/null; then
  pass "existing cost preserves arbitrary decimal precision"
else
  fail "existing cost lost decimal precision"
fi

backlog_journal_emit "$BACKLOG" SCALARS blocked_reason 'json:"null"' \
  backlog-scheduler.journal-set "$TOKEN" >/dev/null
if [[ $? -eq 0 ]] && jq -e '.record.new_value == "null"' \
    "$BACKLOG_JOURNAL_RECORD_PATH" >/dev/null; then
  pass "blocked reason exact text null has an unambiguous wire"
else
  fail "blocked reason exact text null wire"
fi

backlog_journal_emit "$BACKLOG" ABSENT_SCALARS started_at 2000-01-01T09:00:00Z \
  backlog-scheduler.journal-set "$TOKEN" >/dev/null
if [[ $? -eq 0 ]] && jq -e '.record.old_value == null' \
    "$BACKLOG_JOURNAL_RECORD_PATH" >/dev/null; then
  pass "absent optional field is canonical null predecessor"
else
  fail "absent optional predecessor"
fi

# Nullable scalar shapes are explicit and authorizing.
while IFS='|' read -r field; do
  backlog_journal_emit "$BACKLOG" EXISTING_SCALARS "$field" null backlog-scheduler.journal-set "$TOKEN" >/dev/null
  [[ $? -eq 0 ]] && pass "nullable scalar $field" || fail "nullable scalar $field"
done <<'CASES'
started_at
completed_at
blocked_reason
pr_url
pr_number
pr_status
cost_usd
CASES

# Every ratified status edge is accepted.
while IFS='|' read -r story next; do
  backlog_journal_emit "$BACKLOG" "$story" status "$next" backlog-scheduler.journal-set "$TOKEN" >/dev/null
  [[ $? -eq 0 ]] && pass "status edge $story->$next" || fail "status edge $story->$next"
done <<'EDGES'
STATUS_DRAFT|refined
STATUS_DRAFT|cancelled
STATUS_DRAFT|superseded
STATUS_REFINED|blocked
STATUS_REFINED|cancelled
STATUS_REFINED|superseded
STATUS_PROGRESS|done
STATUS_PROGRESS|failed
STATUS_PROGRESS|blocked
STATUS_PROGRESS|escalated
STATUS_PROGRESS|cancelled
STATUS_PROGRESS|superseded
STATUS_FAILED|blocked
STATUS_FAILED|cancelled
STATUS_FAILED|superseded
STATUS_ESCALATED|blocked
STATUS_ESCALATED|cancelled
STATUS_ESCALATED|superseded
STATUS_BLOCKED|draft
STATUS_BLOCKED|refined
STATUS_BLOCKED|in_progress
STATUS_BLOCKED|done
STATUS_BLOCKED|cancelled
STATUS_BLOCKED|superseded
STATUS_DONE|cancelled
STATUS_DONE|superseded
STATUS_DEFERRED|cancelled
STATUS_DEFERRED|superseded
EDGES

# Every ratified phase edge is accepted.
while IFS='|' read -r story next; do
  backlog_journal_emit "$BACKLOG" "$story" phase_status "$next" backlog-scheduler.journal-set "$TOKEN" >/dev/null
  [[ $? -eq 0 ]] && pass "phase edge $story->$next" || fail "phase edge $story->$next"
done <<'EDGES'
PHASE_NOT_STARTED|planned
PHASE_NOT_STARTED|failed
PHASE_PLANNED|implemented
PHASE_PLANNED|failed
PHASE_IMPLEMENTED|qa_passed
PHASE_IMPLEMENTED|qa_failed
PHASE_IMPLEMENTED|qa_escalated
PHASE_IMPLEMENTED|failed
PHASE_QA_FAILED|not_started
PHASE_QA_FAILED|planned
PHASE_QA_FAILED|implemented
PHASE_QA_FAILED|qa_escalated
PHASE_QA_FAILED|failed
PHASE_QA_PASSED|implemented
PHASE_QA_PASSED|commit_stalled
PHASE_QA_PASSED|done
PHASE_QA_PASSED|failed
PHASE_QA_PASSED|escalated
EDGES

expect_rejected() {
  local label="$1" story="$2" field="$3" value="$4" expected_reason="$5"
  set +e
  backlog_journal_emit "$BACKLOG" "$story" "$field" "$value" backlog-scheduler.journal-set "$TOKEN" >/dev/null 2>"$TEST_ROOT/reject.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 && "$BACKLOG_JOURNAL_REASON" == "$expected_reason" ]]; then
    pass "$label"
  else
    fail "$label (rc=$rc reason=$BACKLOG_JOURNAL_REASON)"
  fi
}

expect_rejected "invalid status edge" STATUS_REFINED status done transition_invalid
expect_rejected "undocumented deferred edge" STATUS_REFINED status deferred transition_invalid
expect_rejected "terminal status edge" STATUS_CANCELLED status refined transition_invalid
expect_rejected "invalid phase edge" PHASE_NOT_STARTED phase_status done transition_invalid
expect_rejected "qa_escalated phase is terminal" PHASE_QA_ESCALATED phase_status escalated transition_invalid
expect_rejected "commit_stalled phase is terminal" PHASE_COMMIT_STALLED phase_status done transition_invalid
expect_rejected "unknown phase literal" PHASE_IMPLEMENTED phase_status worktree_recovery_failed value_malformed
expect_rejected "unknown field" SCALARS unknown_field value field_not_allowed
expect_rejected "retry counter excluded" SCALARS retry_count 1 field_not_allowed
expect_rejected "attempt counter excluded" SCALARS attempt_count 1 field_not_allowed
expect_rejected "impossible started_at" SCALARS started_at 2001-02-30T00:00:00Z value_malformed
expect_rejected "new offset timestamp excluded" SCALARS completed_at 2000-01-01T09:00:00+01:00 value_malformed
expect_rejected "existing offset timestamp excluded" OLD_OFFSET completed_at null value_malformed
expect_rejected "empty blocked reason" SCALARS blocked_reason "" value_malformed
expect_rejected "raw blocked reason text requires typed wire" SCALARS blocked_reason true value_malformed
expect_rejected "Unicode line separator excluded" SCALARS blocked_reason 'json:"line\u2028break"' value_malformed
expect_rejected "Unicode paragraph separator excluded" SCALARS blocked_reason 'json:"line\u2029break"' value_malformed
expect_rejected "PR URL query excluded" SCALARS pr_url 'https://github.com/example/project/pull/8?x=1' value_malformed
expect_rejected "zero PR number excluded" SCALARS pr_number 0 value_malformed
expect_rejected "unknown PR status excluded" SCALARS pr_status queued value_malformed
expect_rejected "exponent cost excluded" SCALARS cost_usd 1e3 value_malformed
expect_rejected "leading-zero old PR number excluded" LEADING_PR pr_number 2 value_malformed
expect_rejected "leading-zero old cost excluded" LEADING_COST cost_usd 2 value_malformed
expect_rejected "missing story" DOES_NOT_EXIST status done story_missing

# A valid-looking token cannot be forged, reused by another writer, or paired with an invalid writer.
FORGED_TOKEN="$(printf 'a%.0s' {1..64})"
set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status open backlog-scheduler.journal-set "$FORGED_TOKEN" >/dev/null 2>&1
FORGED_RC=$?
set -e
[[ $FORGED_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == run_token_unregistered ]] \
  && pass "well-shaped unregistered token rejected" || fail "unregistered token rejection"

set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status open daemon.impl "$TOKEN" >/dev/null 2>&1
WRITER_REUSE_RC=$?
set -e
[[ $WRITER_REUSE_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == run_token_unregistered ]] \
  && pass "token is bound to exact writer" || fail "token writer binding"

set +e
backlog_journal_begin_run "$BACKLOG" '../bad writer' >/dev/null 2>&1
BAD_WRITER_RC=$?
set -e
[[ $BAD_WRITER_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == writer_context_invalid ]] \
  && pass "writer grammar is closed" || fail "writer grammar rejection"

# Diagnostics are fixed-shape and never contain values or paths.
SECRET_VALUE='secret-value-that-must-not-leak'
set +e
backlog_journal_emit "$BACKLOG" SCALARS blocked_reason "json:\"$SECRET_VALUE\"" daemon.impl "$TOKEN" >/dev/null 2>"$TEST_ROOT/diag.err"
set -e
if grep -q "$SECRET_VALUE\|$BACKLOG\|https://\|/Users/" "$TEST_ROOT/diag.err"; then
  fail "diagnostic leaks forbidden content"
elif grep -Eq '^\[BACKLOG-JOURNAL\] story=SCALARS field=blocked_reason writer=daemon.impl seq=0 source=[0-9a-f]{12} record=- attempt=rejected outcome=rejected reason=run_token_unregistered$' "$TEST_ROOT/diag.err"; then
  pass "diagnostic is bounded and stable"
else
  fail "diagnostic shape"
fi

# Duplicate Story identity is non-authorizing.
DUP_REPO="$TEST_ROOT/duplicate"
init_repo "$DUP_REPO"
DUP_BACKLOG="$DUP_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"
cat > "$DUP_BACKLOG" <<'YAML'
items:
- id: DUP
  status: refined
- id: DUP
  status: in_progress
YAML
git -C "$DUP_REPO" add . && git -C "$DUP_REPO" commit -qm init
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-duplicate"
backlog_journal_begin_run "$DUP_BACKLOG" daemon.plan
DUP_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
set +e
backlog_journal_emit "$DUP_BACKLOG" DUP status in_progress daemon.plan "$DUP_TOKEN" >/dev/null 2>&1
DUP_RC=$?
set -e
[[ $DUP_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == story_duplicate ]] \
  && pass "duplicate story identity rejected" || fail "duplicate story identity"

# Unsafe target YAML and missing source objects fail before a record appears.
UNSAFE_REPO="$TEST_ROOT/unsafe"
init_repo "$UNSAFE_REPO"
UNSAFE_BACKLOG="$UNSAFE_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"
cat > "$UNSAFE_BACKLOG" <<'YAML'
items:
- id: UNSAFE
  status: refined
  status: in_progress
YAML
git -C "$UNSAFE_REPO" add . && git -C "$UNSAFE_REPO" commit -qm init
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-unsafe"
backlog_journal_begin_run "$UNSAFE_BACKLOG" daemon.plan
UNSAFE_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
set +e
backlog_journal_emit "$UNSAFE_BACKLOG" UNSAFE status done daemon.plan "$UNSAFE_TOKEN" >/dev/null 2>&1
UNSAFE_RC=$?
set -e
[[ $UNSAFE_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == backlog_unsafe_yaml ]] \
  && pass "duplicate target field is unsafe YAML" || fail "unsafe YAML rejection"

export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-source"
backlog_journal_begin_run "$BACKLOG" daemon.source
SOURCE_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
set +e
GAAI_BACKLOG_JOURNAL_SOURCE_REF=refs/heads/missing backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status open daemon.source "$SOURCE_TOKEN" >/dev/null 2>&1
SOURCE_RC=$?
set -e
[[ $SOURCE_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == source_unresolvable ]] \
  && pass "missing source object rejected" || fail "missing source rejection"
set +e
GAAI_BACKLOG_JOURNAL_SOURCE_REF='--help' backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status open daemon.source "$SOURCE_TOKEN" >/dev/null 2>&1
SOURCE_REF_RC=$?
set -e
[[ $SOURCE_REF_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == source_unresolvable ]] \
  && pass "unsafe source ref rejected before git resolution" || fail "unsafe source ref rejection"
SOURCE_RECORDS="$(find "$GAAI_BACKLOG_JOURNAL_DIR" -path '*/records/*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 0 "$SOURCE_RECORDS" "source failure creates no record"

# Source provenance binds the exact target predecessor, while unrelated fields may drift.
SOURCE_DRIFT_REPO="$TEST_ROOT/source-drift"
init_repo "$SOURCE_DRIFT_REPO"
SOURCE_DRIFT_BACKLOG="$SOURCE_DRIFT_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"
cat > "$SOURCE_DRIFT_BACKLOG" <<'YAML'
items:
- id: REQUIRED_DRIFT
  status: refined
  phase_status: not_started
  notes: source
- id: OPTIONAL_DRIFT
  status: in_progress
  phase_status: implemented
  notes: source
YAML
git -C "$SOURCE_DRIFT_REPO" add . && git -C "$SOURCE_DRIFT_REPO" commit -qm init
python3 - "$SOURCE_DRIFT_BACKLOG" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("  status: refined\n", "  status: blocked\n", 1)
text = text.replace("  notes: source\n", "  notes: unrelated-working-drift\n", 1)
text = text.replace(
    "- id: OPTIONAL_DRIFT\n  status: in_progress\n  phase_status: implemented\n",
    "- id: OPTIONAL_DRIFT\n  status: in_progress\n  phase_status: implemented\n  blocked_reason: working-only\n",
)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-source-drift"
backlog_journal_begin_run "$SOURCE_DRIFT_BACKLOG" daemon.source-drift
SOURCE_DRIFT_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
set +e
backlog_journal_emit "$SOURCE_DRIFT_BACKLOG" REQUIRED_DRIFT status done \
  daemon.source-drift "$SOURCE_DRIFT_TOKEN" >/dev/null 2>&1
REQUIRED_DRIFT_RC=$?
backlog_journal_emit "$SOURCE_DRIFT_BACKLOG" OPTIONAL_DRIFT blocked_reason 'json:"new"' \
  daemon.source-drift "$SOURCE_DRIFT_TOKEN" >/dev/null 2>&1
OPTIONAL_DRIFT_RC=$?
set -e
if [[ $REQUIRED_DRIFT_RC -ne 0 && $OPTIONAL_DRIFT_RC -ne 0 \
      && "$BACKLOG_JOURNAL_REASON" == source_value_mismatch ]]; then
  pass "source and working target predecessor mismatch is rejected"
else
  fail "source predecessor binding (required=$REQUIRED_DRIFT_RC optional=$OPTIONAL_DRIFT_RC reason=$BACKLOG_JOURNAL_REASON)"
fi
SOURCE_DRIFT_RECORDS="$(find "$GAAI_BACKLOG_JOURNAL_DIR" -path '*/records/*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 0 "$SOURCE_DRIFT_RECORDS" "source target drift creates no record"

# Storage failure is typed and cannot fall back.
STORAGE_FILE="$TEST_ROOT/not-a-directory"
: > "$STORAGE_FILE"
export GAAI_BACKLOG_JOURNAL_DIR="$STORAGE_FILE"
set +e
backlog_journal_begin_run "$BACKLOG" daemon.storage >/dev/null 2>&1
STORAGE_RC=$?
set -e
[[ $STORAGE_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == journal_storage_unavailable ]] \
  && pass "journal storage failure is typed" || fail "journal storage failure"

# Concurrent same-writer processes receive a contiguous, unique sequence.
# Every emitter loads the library, reports ready and blocks; all are released
# together, so each run exercises real contention instead of whatever overlap
# the scheduler happens to produce. Both sides wait on observable conditions,
# never on a fixed sleep: an emitter waits for the release file while this shell
# lives, and this shell waits until every emitter is ready or one has exited.
# BACKLOG_JOURNAL_TEST_BARRIER_SECONDS only caps that wait so a wedged emitter
# cannot hold the corpus; expiry releases the barrier and asserts nothing. Each
# emitter keeps its exit status, result line and typed diagnostics, and a
# failure prints them, so the corpus log names the rejection reason.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-concurrent"
backlog_journal_begin_run "$BACKLOG" daemon.concurrent
CONCURRENT_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
CONCURRENT_DIR="$TEST_ROOT/concurrent"
CONCURRENT_IDS="01 02 03 04 05 06 07 08"
mkdir -p "$CONCURRENT_DIR"
PIDS=""
for n in $CONCURRENT_IDS; do
  /bin/bash -c '
    source "$1" || exit 96
    : > "$5/ready-$3"
    while [[ ! -e "$5/go" ]]; do
      kill -0 "$6" 2>/dev/null || exit 97
      sleep 0.05
    done
    backlog_journal_emit "$2" "C$3" pr_status open daemon.concurrent "$4"' \
    _ "$LIB" "$BACKLOG" "$n" "$CONCURRENT_TOKEN" "$CONCURRENT_DIR" "$$" \
    >"$CONCURRENT_DIR/$n.out" 2>"$CONCURRENT_DIR/$n.err" &
  PIDS="$PIDS $n:$!"
done
CONCURRENT_CAP="${BACKLOG_JOURNAL_TEST_BARRIER_SECONDS:-300}"
if [[ ! "$CONCURRENT_CAP" =~ ^[0-9]+$ ]]; then
  printf 'BACKLOG_JOURNAL_TEST_BARRIER_SECONDS=%s is not a whole number of seconds; using 300\n' "$CONCURRENT_CAP" >&2
  CONCURRENT_CAP=300
fi
CONCURRENT_DEADLINE=$((SECONDS + CONCURRENT_CAP))
while :; do
  CONCURRENT_READY=0 CONCURRENT_ALIVE=0
  for n in $CONCURRENT_IDS; do [[ -e "$CONCURRENT_DIR/ready-$n" ]] && CONCURRENT_READY=$((CONCURRENT_READY + 1)); done
  for entry in $PIDS; do kill -0 "${entry#*:}" 2>/dev/null && CONCURRENT_ALIVE=$((CONCURRENT_ALIVE + 1)); done
  [[ $CONCURRENT_READY -eq 8 || $CONCURRENT_ALIVE -lt 8 || $SECONDS -ge $CONCURRENT_DEADLINE ]] && break
  sleep 0.05
done
: > "$CONCURRENT_DIR/go"
CONCURRENT_OK=true
CONCURRENT_STATUS=""
for entry in $PIDS; do
  CONCURRENT_RC=0
  wait "${entry#*:}" || CONCURRENT_RC=$?
  [[ $CONCURRENT_RC -eq 0 ]] || CONCURRENT_OK=false
  CONCURRENT_STATUS="$CONCURRENT_STATUS ${entry%%:*}=$CONCURRENT_RC"
done
concurrent_evidence() {
  local n
  printf 'concurrent evidence: ready_at_release=%s/8 exit=%s\n' "$CONCURRENT_READY" "${CONCURRENT_STATUS# }" >&2
  for n in $CONCURRENT_IDS; do
    printf -- '--- emitter %s stdout\n' "$n" >&2; cat "$CONCURRENT_DIR/$n.out" >&2
    printf -- '--- emitter %s stderr\n' "$n" >&2; cat "$CONCURRENT_DIR/$n.err" >&2
  done
}
$CONCURRENT_OK && pass "concurrent emissions all complete" \
  || { fail "concurrent emission process"; concurrent_evidence; }
CONCURRENT_RECORDS_DIR="$(find "$GAAI_BACKLOG_JOURNAL_DIR/writers" -type d -name records 2>/dev/null | head -1)"
if python3 - "$CONCURRENT_RECORDS_DIR" <<'PY'
import glob, json, os, sys
if not sys.argv[1] or not os.path.isdir(sys.argv[1]):
    print("concurrent evidence: records=0 sequences=[] (records dir absent)", file=sys.stderr)
    raise SystemExit(1)
paths = sorted(glob.glob(os.path.join(sys.argv[1], "*.json")))
seq = sorted(json.load(open(path))["record"]["sequence"] for path in paths)
if len(paths) == 8 and seq == list(range(1, 9)):
    raise SystemExit(0)
print(f"concurrent evidence: records={len(paths)} sequences={seq}", file=sys.stderr)
raise SystemExit(1)
PY
then pass "concurrent sequence is contiguous and fork-free"
else
  fail "concurrent sequence integrity"
  $CONCURRENT_OK && concurrent_evidence
fi

# Historical records retain their original registered-token provenance.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-historical-token"
backlog_journal_begin_run "$BACKLOG" daemon.history
HISTORICAL_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
backlog_journal_emit "$BACKLOG" C01 pr_status open daemon.history "$HISTORICAL_TOKEN" >/dev/null
backlog_journal_begin_run "$BACKLOG" daemon.history
CURRENT_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
rm "$GAAI_BACKLOG_JOURNAL_DIR/registrations/$HISTORICAL_TOKEN.json"
set +e
backlog_journal_emit "$BACKLOG" C02 pr_status open daemon.history "$CURRENT_TOKEN" >/dev/null 2>&1
HISTORICAL_TOKEN_RC=$?
set -e
if [[ $HISTORICAL_TOKEN_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == run_token_unregistered ]]; then
  pass "historical record token registration is revalidated"
else
  fail "historical token provenance (rc=$HISTORICAL_TOKEN_RC reason=$BACKLOG_JOURNAL_REASON)"
fi

# JSON booleans are not accepted as integer sequence numbers.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-boolean-sequence"
backlog_journal_begin_run "$BACKLOG" daemon.boolean-sequence
BOOLEAN_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
backlog_journal_emit "$BACKLOG" C01 pr_status open daemon.boolean-sequence "$BOOLEAN_TOKEN" >/dev/null
BOOLEAN_RECORD="$BACKLOG_JOURNAL_RECORD_PATH"
python3 - "$BOOLEAN_RECORD" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
wrapper = json.load(open(path))
wrapper["record"]["sequence"] = True
canon = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
wrapper["digest"] = hashlib.sha256(canon(wrapper["record"]).encode()).hexdigest()
with open(path, "w") as handle:
    handle.write(canon(wrapper) + "\n")
PY
set +e
backlog_journal_emit "$BACKLOG" C02 pr_status open daemon.boolean-sequence "$BOOLEAN_TOKEN" >/dev/null 2>&1
BOOLEAN_SEQUENCE_RC=$?
set -e
if [[ $BOOLEAN_SEQUENCE_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == digest_mismatch ]]; then
  pass "boolean record sequence is rejected"
else
  fail "boolean sequence validation (rc=$BOOLEAN_SEQUENCE_RC reason=$BACKLOG_JOURNAL_REASON)"
fi

# A partial/zero sequence write is never treated as durable advancement.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-short-sequence"
backlog_journal_begin_run "$BACKLOG" daemon.short-sequence
SHORT_SEQUENCE_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
SHORT_SEQUENCE_PREIMAGE="$(sha256_file "$BACKLOG")"
set +e
GAAI_BACKLOG_JOURNAL_FAULT=sequence_short_write backlog_journal_emit \
  "$BACKLOG" C01 pr_status open daemon.short-sequence "$SHORT_SEQUENCE_TOKEN" >/dev/null 2>&1
SHORT_SEQUENCE_RC=$?
set -e
if [[ $SHORT_SEQUENCE_RC -ne 0 && "$BACKLOG_JOURNAL_OUTCOME" == rejected \
      && "$BACKLOG_JOURNAL_REASON" == append_interrupted \
      && "$SHORT_SEQUENCE_PREIMAGE" == "$(sha256_file "$BACKLOG")" ]]; then
  pass "short sequence write is pending and non-authorizing"
else
  fail "short sequence write (rc=$SHORT_SEQUENCE_RC outcome=$BACKLOG_JOURNAL_OUTCOME reason=$BACKLOG_JOURNAL_REASON)"
fi

# Crash after publication is recovered as pending replay, never a second emission.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-crash"
backlog_journal_begin_run "$BACKLOG" daemon.crash
CRASH_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
set +e
GAAI_BACKLOG_JOURNAL_FAULT=after_record_publish backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status open daemon.crash "$CRASH_TOKEN" >/dev/null 2>&1
CRASH_RC=$?
set -e
[[ $CRASH_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == append_interrupted ]] \
  && pass "post-publication crash is pending" || fail "post-publication crash"
set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status open daemon.crash "$CRASH_TOKEN" >/dev/null 2>&1
CRASH_REPLAY_RC=$?
set -e
[[ $CRASH_REPLAY_RC -eq 10 && "$BACKLOG_JOURNAL_OUTCOME" == pending:replay ]] \
  && pass "post-publication retry is non-authorizing replay" || fail "crash replay recovery"

set +e
GAAI_BACKLOG_JOURNAL_FAULT=after_sequence_update backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status closed daemon.crash "$CRASH_TOKEN" >/dev/null 2>&1
SEQUENCE_CRASH_RC=$?
set -e
[[ $SEQUENCE_CRASH_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == append_interrupted ]] \
  && pass "post-sequence crash is pending" || fail "post-sequence crash"
set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status closed daemon.crash "$CRASH_TOKEN" >/dev/null 2>&1
SEQUENCE_REPLAY_RC=$?
set -e
[[ $SEQUENCE_REPLAY_RC -eq 10 ]] && pass "post-sequence retry is replay" || fail "post-sequence replay"

# Interrupted private write remains evidence and blocks later writes for that writer.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-temp-interrupt"
backlog_journal_begin_run "$BACKLOG" daemon.interrupt
INTERRUPT_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
set +e
GAAI_BACKLOG_JOURNAL_FAULT=after_temp_fsync backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status open daemon.interrupt "$INTERRUPT_TOKEN" >/dev/null 2>&1
TEMP_RC=$?
backlog_journal_emit "$BACKLOG" SCALARS pr_status closed daemon.interrupt "$INTERRUPT_TOKEN" >/dev/null 2>&1
TEMP_RETRY_RC=$?
set -e
[[ $TEMP_RC -ne 0 && $TEMP_RETRY_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == append_interrupted ]] \
  && pass "interrupted temp record blocks without deletion" || fail "temp interruption evidence"

# Tamper, sequence gap and conflicting duplicate remain non-authorizing.
export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-tamper"
backlog_journal_begin_run "$BACKLOG" daemon.tamper
TAMPER_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
backlog_journal_emit "$BACKLOG" SCALARS pr_status open daemon.tamper "$TAMPER_TOKEN" >/dev/null
TAMPER_PATH="$BACKLOG_JOURNAL_RECORD_PATH"
python3 - "$TAMPER_PATH" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["digest"] = "0" * 64
with open(path, "w") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status closed daemon.tamper "$TAMPER_TOKEN" >/dev/null 2>&1
TAMPER_RC=$?
set -e
[[ $TAMPER_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == digest_mismatch ]] \
  && pass "tampered digest rejected" || fail "tampered digest"

export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-policy-tamper"
backlog_journal_begin_run "$BACKLOG" daemon.policy-tamper
POLICY_TAMPER_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status open daemon.policy-tamper "$POLICY_TAMPER_TOKEN" >/dev/null
POLICY_TAMPER_PATH="$BACKLOG_JOURNAL_RECORD_PATH"
python3 - "$POLICY_TAMPER_PATH" <<'PY'
import hashlib, json, os, sys
path = sys.argv[1]
wrapper = json.load(open(path))
record = dict(wrapper["record"])
record["new_value"] = "not-a-policy-status"
intent = {key: record[key] for key in (
    "schema_version", "story_id", "field", "old_value", "new_value",
    "source_commit", "source_blob", "writer_context", "run_token",
)}
canon = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
intent_digest = hashlib.sha256(canon(intent).encode()).hexdigest()
record["intent_digest"] = intent_digest
wrapper = {
    "record": record,
    "intent_digest": intent_digest,
    "digest": hashlib.sha256(canon(record).encode()).hexdigest(),
}
replacement = os.path.join(
    os.path.dirname(path), f"{record['sequence']:020d}-{intent_digest[:16]}.json"
)
with open(replacement, "w") as handle:
    handle.write(canon(wrapper) + "\n")
os.chmod(replacement, 0o600)
os.unlink(path)
PY
set +e
backlog_journal_emit \
  "$BACKLOG" SCALARS pr_status closed daemon.policy-tamper "$POLICY_TAMPER_TOKEN" >/dev/null 2>&1
POLICY_TAMPER_RC=$?
set -e
[[ $POLICY_TAMPER_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == digest_mismatch ]] \
  && pass "self-consistent policy-invalid record rejected" || fail "policy-invalid record"

export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-fork"
backlog_journal_begin_run "$BACKLOG" daemon.fork
FORK_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
backlog_journal_emit "$BACKLOG" SCALARS pr_status open daemon.fork "$FORK_TOKEN" >/dev/null
FORK_WRITER_DIR="$(find "$GAAI_BACKLOG_JOURNAL_DIR/writers" -mindepth 1 -maxdepth 1 -type d | head -1)"
printf '3\n' > "$FORK_WRITER_DIR/.sequence"
set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status closed daemon.fork "$FORK_TOKEN" >/dev/null 2>&1
FORK_RC=$?
set -e
[[ $FORK_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == sequence_fork ]] \
  && pass "sequence regression/fork rejected" || fail "sequence fork"

export GAAI_BACKLOG_JOURNAL_DIR="$TEST_ROOT/journal-conflict"
backlog_journal_begin_run "$BACKLOG" daemon.conflict
CONFLICT_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
backlog_journal_emit "$BACKLOG" SCALARS pr_status open daemon.conflict "$CONFLICT_TOKEN" >/dev/null
CONFLICT_PATH="$BACKLOG_JOURNAL_RECORD_PATH"
python3 - "$CONFLICT_PATH" <<'PY'
import hashlib, json, os, sys
path = sys.argv[1]
wrapper = json.load(open(path))
record = dict(wrapper["record"])
record["new_value"] = "closed"
intent = {key: record[key] for key in (
    "schema_version", "story_id", "field", "old_value", "new_value",
    "source_commit", "source_blob", "writer_context", "run_token",
)}
canon = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
intent_digest = hashlib.sha256(canon(intent).encode()).hexdigest()
record["intent_digest"] = intent_digest
digest = hashlib.sha256(canon(record).encode()).hexdigest()
other = {"record": record, "intent_digest": intent_digest, "digest": digest}
other_path = os.path.join(os.path.dirname(path), f"{record['sequence']:020d}-{intent_digest[:16]}.json")
with open(other_path, "w") as handle:
    handle.write(canon(other) + "\n")
os.chmod(other_path, 0o600)
PY
set +e
backlog_journal_emit "$BACKLOG" SCALARS pr_status pending_review daemon.conflict "$CONFLICT_TOKEN" >/dev/null 2>&1
CONFLICT_RC=$?
set -e
[[ $CONFLICT_RC -ne 0 && "$BACKLOG_JOURNAL_REASON" == conflicting_duplicate ]] \
  && pass "conflicting duplicate rejected" || fail "conflicting duplicate"

printf '\nResults: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
