#!/usr/bin/env bash
# Hermetic acceptance coverage for delivery-journal projection.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOURNAL_LIB="$SCRIPT_DIR/../lib/backlog-journal.sh"
CHORE_LIB="$SCRIPT_DIR/../lib/chore-commit.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/backlog-projection-test.XXXXXX")"
BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/backlog-projection-test.*) rm -rf "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label (expected=$expected actual=$actual)"; fi
}
assert_contains() {
  local value="$1" expected="$2" label="$3"
  if [[ "$value" == *"$expected"* ]]; then pass "$label"; else fail "$label (missing=$expected)"; fi
}

# shellcheck source=lib/backlog-journal.sh
source "$JOURNAL_LIB"
# shellcheck source=lib/chore-commit.sh
source "$CHORE_LIB"

setup_repo() {
  local name="$1" repo="$TEST_ROOT/$1" remote="$TEST_ROOT/$1-remote.git"
  git init -q --bare "$remote"
  git clone -q "$remote" "$repo" 2>/dev/null
  git -C "$repo" config user.email projection@example.invalid
  git -C "$repo" config user.name backlog-projection-test
  git -C "$repo" checkout -q -b staging
  mkdir -p "$repo/.gaai/project/contexts/backlog"
  printf '%s\n' '.gaai/project/contexts/backlog/.delivery-locks/' > "$repo/.gitignore"
  printf '%s\n' \
    '# formatting sentinel: keep exactly' \
    'items:' \
    '- id: A' \
    '  status: refined # target comment' \
    '  phase_status: not_started' \
    '  started_at: null' \
    '- id: B' \
    '  status: refined' \
    '  phase_status: not_started' \
    '- id: C' \
    '  status: refined' \
    '  phase_status: not_started' \
    'tail: "preserve: yes"' > "$repo/$BACKLOG_REL"
  git -C "$repo" add .
  git -C "$repo" commit -q -m initial
  git -C "$repo" push -q -u origin staging
  printf '%s' "$repo"
}

emit_record() {
  local repo="$1" story="$2" field="$3" value="$4" writer="$5"
  (
    cd "$repo" || exit 1
    GAAI_BACKLOG_JOURNAL_SOURCE_REF=origin/staging
    export GAAI_BACKLOG_JOURNAL_SOURCE_REF
    backlog_journal_begin_run "$repo/$BACKLOG_REL" "$writer" >/dev/null || exit 1
    backlog_journal_emit "$repo/$BACKLOG_REL" "$story" "$field" "$value" \
      "$writer" "$BACKLOG_JOURNAL_RUN_TOKEN" >/dev/null
  )
}

project_records() {
  local repo="$1" context="${2:-journal-projection}" fault="${3:-}" result="$TEST_ROOT/project-result"
  (
    cd "$repo" || exit 1
    export BACKLOG_FILE="$repo/$BACKLOG_REL" BACKLOG_REL TARGET_BRANCH=staging
    export GAAI_BACKLOG_PROJECTION_FAULT="$fault"
    local rc=0
    chore_commit_project_journal "$context" >/dev/null 2>"$TEST_ROOT/project.err" || rc=$?
    printf '%s\t%s\t%s\t%s\n' "$rc" "$CHORE_JOURNAL_OUTCOME" \
      "$CHORE_JOURNAL_REASON" "$CHORE_JOURNAL_COMMIT" > "$result"
  )
  IFS=$'\t' read -r PROJECT_RC PROJECT_OUTCOME PROJECT_REASON PROJECT_COMMIT < "$result"
}

remote_backlog() { git -C "$1" show "origin/staging:$BACKLOG_REL"; }
pending_count() { find "$1/.gaai/project/contexts/backlog/.delivery-locks/journal/writers" -path '*/records/*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }
applied_count() { find "$1/.gaai/project/contexts/backlog/.delivery-locks/journal/writers" -path '*/applied/*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }

printf '\n=== T1: fresh remote projection, byte preservation, private index ===\n'
T1_REPO="$(setup_repo t1)"
T1_BASE="$(git -C "$T1_REPO" rev-parse origin/staging)"
T1_HEAD="$(git -C "$T1_REPO" rev-parse HEAD)"
emit_record "$T1_REPO" A status in_progress daemon.impl || fail "T1: status record emitted"
emit_record "$T1_REPO" B phase_status planned daemon.impl || fail "T1: phase record emitted"
# Ambient backlog is deliberately stale and dirty; it must not authorize content.
printf '\n# ambient-only secret sentinel\n' >> "$T1_REPO/$BACKLOG_REL"
T1_STATUS="$(git -C "$T1_REPO" status --porcelain=v1)"
project_records "$T1_REPO"
assert_eq 0 "$PROJECT_RC" "T1: projection succeeds"
assert_eq applied "$PROJECT_OUTCOME" "T1: outcome is applied"
T1_REMOTE="$(remote_backlog "$T1_REPO")"
assert_contains "$T1_REMOTE" 'status: in_progress # target comment' "T1: eligible status is projected"
assert_contains "$T1_REMOTE" 'phase_status: planned' "T1: independent phase is projected"
if [[ "$T1_REMOTE" != *ambient-only* ]]; then pass "T1: ambient content is excluded"; else fail "T1: ambient content leaked"; fi
assert_contains "$T1_REMOTE" '# formatting sentinel: keep exactly' "T1: unrelated bytes are preserved"
assert_contains "$T1_REMOTE" 'tail: "preserve: yes"' "T1: unrelated tail is preserved"
assert_eq "$T1_BASE" "$(git -C "$T1_REPO" rev-parse "origin/staging^")" "T1: candidate has exact remote parent"
assert_eq "$T1_HEAD" "$(git -C "$T1_REPO" rev-parse HEAD)" "T1: ambient HEAD is unchanged"
assert_eq "$T1_STATUS" "$(git -C "$T1_REPO" status --porcelain=v1)" "T1: ambient worktree/index are unchanged"
assert_eq 0 "$(pending_count "$T1_REPO")" "T1: verified records are retired"
assert_eq 2 "$(applied_count "$T1_REPO")" "T1: exact applied records are retained as evidence"
T1_ATTEMPT="$(find "$T1_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/applied-projections" -type f -name '*.json' | head -1)"
if ! grep -q "$TEST_ROOT\|/records/\|/applied/" "$T1_ATTEMPT"; then pass "T1: manifest is path-free"; else fail "T1: manifest leaks a filesystem locator"; fi

printf '\n=== T2: applied history preserves writer sequence and prevents re-apply ===\n'
git -C "$T1_REPO" restore "$BACKLOG_REL"
git -C "$T1_REPO" pull -q --ff-only
emit_record "$T1_REPO" C status in_progress daemon.impl || fail "T2: next sequence emits after retirement"
project_records "$T1_REPO"
assert_eq 0 "$PROJECT_RC" "T2: later writer record projects"
assert_contains "$(remote_backlog "$T1_REPO")" 'id: C' "T2: target story remains present"
assert_eq 3 "$(applied_count "$T1_REPO")" "T2: applied history remains contiguous"
project_records "$T1_REPO"
assert_eq noop "$PROJECT_OUTCOME" "T2: applied evidence is not re-authorized"

printf '\n=== T3: same-field conflict is isolated from independent valid work ===\n'
T3_REPO="$(setup_repo t3)"
emit_record "$T3_REPO" A status in_progress daemon.one || fail "T3: first conflict record emitted"
emit_record "$T3_REPO" A status blocked daemon.two || fail "T3: second conflict record emitted"
emit_record "$T3_REPO" B phase_status planned daemon.three || fail "T3: independent record emitted"
project_records "$T3_REPO"
assert_eq 0 "$PROJECT_RC" "T3: independent group projects"
T3_REMOTE="$(remote_backlog "$T3_REPO")"
assert_contains "$T3_REMOTE" 'phase_status: planned' "T3: independent valid group applied"
assert_contains "$T3_REMOTE" 'status: refined # target comment' "T3: conflicted field remains unchanged"
assert_eq 2 "$(pending_count "$T3_REPO")" "T3: both conflicting records remain exact"
assert_eq 1 "$(applied_count "$T3_REPO")" "T3: only independent record retires"

printf '\n=== T4: malformed evidence is isolated by trusted group locator ===\n'
T4_REPO="$(setup_repo t4)"
emit_record "$T4_REPO" B phase_status planned daemon.mixed || fail "T4: independent prefix record emitted"
emit_record "$T4_REPO" A status in_progress daemon.mixed || fail "T4: corruptible tail record emitted"
T4_LAST="$(find "$T4_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/writers" -path '*/records/*.json' -type f | sort | tail -1)"
python3 - "$T4_LAST" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle: value = json.load(handle)
value["digest"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle: json.dump(value, handle, sort_keys=True, separators=(",", ":")); handle.write("\n")
PY
chmod 600 "$T4_LAST"
project_records "$T4_REPO"
assert_eq 0 "$PROJECT_RC" "T4: valid independent record still projects"
assert_contains "$(remote_backlog "$T4_REPO")" 'phase_status: planned' "T4: independent record applied despite malformed peer"
assert_eq 1 "$(applied_count "$T4_REPO")" "T4: only verified record retires"
assert_eq 1 "$(pending_count "$T4_REPO")" "T4: malformed record remains pending"

printf '\n=== T5: exact expected-old lease rejects remote movement ===\n'
T5_REPO="$(setup_repo t5)"
T5_REMOTE="$TEST_ROOT/t5-remote.git"
emit_record "$T5_REPO" A status in_progress daemon.lease || fail "T5: record emitted"
T5_BIN="$TEST_ROOT/t5-bin"; mkdir -p "$T5_BIN"
REAL_GIT="$(command -v git)"
T5_ONCE="$TEST_ROOT/t5-once"
: > "$T5_ONCE"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$1" == "push" && ! -s "'"$T5_ONCE"'" ]]; then' \
  '  printf 1 > "'"$T5_ONCE"'"' \
  '  race="'"$TEST_ROOT"'/t5-race"' \
  '  "'"$REAL_GIT"'" clone -q "'"$T5_REMOTE"'" "$race" 2>/dev/null' \
  '  "'"$REAL_GIT"'" -C "$race" config user.email race@example.invalid' \
  '  "'"$REAL_GIT"'" -C "$race" config user.name race' \
  '  "'"$REAL_GIT"'" -C "$race" checkout -q staging' \
  '  printf race > "$race/race.txt"' \
  '  "'"$REAL_GIT"'" -C "$race" add race.txt' \
  '  "'"$REAL_GIT"'" -C "$race" commit -q -m race' \
  '  "'"$REAL_GIT"'" -C "$race" push -q origin staging' \
  'fi' \
  'exec "'"$REAL_GIT"'" "$@"' > "$T5_BIN/git"
chmod +x "$T5_BIN/git"
(
  cd "$T5_REPO" || exit 1
  export PATH="$T5_BIN:$PATH" BACKLOG_FILE="$T5_REPO/$BACKLOG_REL" BACKLOG_REL TARGET_BRANCH=staging
  T5_RC=0; chore_commit_project_journal journal-projection >/dev/null 2>/dev/null || T5_RC=$?
  printf '%s\t%s\t%s\n' "$T5_RC" "$CHORE_JOURNAL_OUTCOME" "$CHORE_JOURNAL_REASON" > "$TEST_ROOT/t5-result"
)
IFS=$'\t' read -r T5_RC T5_OUTCOME T5_REASON < "$TEST_ROOT/t5-result"
assert_eq 1 "$T5_RC" "T5: lease race fails closed"
assert_eq retained "$T5_OUTCOME" "T5: evidence is retained"
assert_eq lease_rejected "$T5_REASON" "T5: exact lease rejection is classified"
assert_eq 1 "$(pending_count "$T5_REPO")" "T5: rejected record remains pending"
if [[ "$(remote_backlog "$T5_REPO")" != *'status: in_progress # target comment'* ]]; then pass "T5: rejected candidate did not overwrite remote"; else fail "T5: candidate overwrote the race"; fi

printf '\n=== T6: accepted-but-interrupted attempt recovers deterministically ===\n'
T6_REPO="$(setup_repo t6)"
emit_record "$T6_REPO" A status in_progress daemon.recovery || fail "T6: record emitted"
project_records "$T6_REPO" journal-projection after_push
assert_eq 1 "$PROJECT_RC" "T6: injected interruption reports failure"
assert_eq retained "$PROJECT_OUTCOME" "T6: accepted attempt remains recoverable"
assert_eq 1 "$(pending_count "$T6_REPO")" "T6: record remains pending before recovery"
project_records "$T6_REPO" recovery
assert_eq 0 "$PROJECT_RC" "T6: recovery invocation succeeds"
assert_eq noop "$PROJECT_OUTCOME" "T6: recovery finalizes then finds no new work"
assert_eq 0 "$(pending_count "$T6_REPO")" "T6: recovered record retires"
assert_eq 1 "$(applied_count "$T6_REPO")" "T6: recovered record is retained as applied evidence"

printf '\n=== T7: commit, verification and finalization faults retain evidence ===\n'
T7A_REPO="$(setup_repo t7a)"
emit_record "$T7A_REPO" A status in_progress daemon.commit-fault || fail "T7a: record emitted"
T7A_BASE="$(git -C "$T7A_REPO" rev-parse origin/staging)"
project_records "$T7A_REPO" journal-projection commit_failure
assert_eq 1 "$PROJECT_RC" "T7a: commit fault fails closed"
assert_eq commit_failed "$PROJECT_REASON" "T7a: commit fault has a closed reason"
assert_eq "$T7A_BASE" "$(git -C "$T7A_REPO" rev-parse origin/staging)" "T7a: commit fault does not move remote"
assert_eq 1 "$(pending_count "$T7A_REPO")" "T7a: commit fault retains record"

T7B_REPO="$(setup_repo t7b)"
emit_record "$T7B_REPO" A status in_progress daemon.verify-fault || fail "T7b: record emitted"
project_records "$T7B_REPO" journal-projection verification_failure
assert_eq 1 "$PROJECT_RC" "T7b: verification fault fails closed"
assert_eq verification_failed "$PROJECT_REASON" "T7b: verification fault has a closed reason"
assert_eq 1 "$(pending_count "$T7B_REPO")" "T7b: unverifiable record remains pending"
project_records "$T7B_REPO" recovery
assert_eq noop "$PROJECT_OUTCOME" "T7b: exact accepted candidate is recovered"
assert_eq 0 "$(pending_count "$T7B_REPO")" "T7b: recovery retires only proven record"

T7C_REPO="$(setup_repo t7c)"
emit_record "$T7C_REPO" A status in_progress daemon.finalize-fault || fail "T7c: record emitted"
project_records "$T7C_REPO" journal-projection finalize_failure
assert_eq 1 "$PROJECT_RC" "T7c: finalization fault fails closed"
assert_eq finalization_failed "$PROJECT_REASON" "T7c: finalization fault has a closed reason"
assert_eq 1 "$(pending_count "$T7C_REPO")" "T7c: unretired evidence remains pending"
project_records "$T7C_REPO" recovery
assert_eq 0 "$(pending_count "$T7C_REPO")" "T7c: restart finalizes exact sealed attempt"

printf '\n=== T8: same-value sibling history cannot authorize ===\n'
T8_REPO="$(setup_repo t8)"
T8_STAGING="$(git -C "$T8_REPO" rev-parse staging)"
git -C "$T8_REPO" checkout -q --orphan sibling
git -C "$T8_REPO" rm -q -rf .
mkdir -p "$T8_REPO/.gaai/project/contexts/backlog"
printf '%s\n' '.gaai/project/contexts/backlog/.delivery-locks/' > "$T8_REPO/.gitignore"
git -C "$T8_REPO" show "$T8_STAGING:$BACKLOG_REL" > "$T8_REPO/$BACKLOG_REL"
git -C "$T8_REPO" add .
git -C "$T8_REPO" commit -q -m sibling
T8_SIBLING="$(git -C "$T8_REPO" rev-parse HEAD)"
(
  cd "$T8_REPO" || exit 1
  export GAAI_BACKLOG_JOURNAL_SOURCE_REF="$T8_SIBLING"
  backlog_journal_begin_run "$T8_REPO/$BACKLOG_REL" daemon.sibling >/dev/null || exit 1
  backlog_journal_emit "$T8_REPO/$BACKLOG_REL" A status in_progress daemon.sibling \
    "$BACKLOG_JOURNAL_RUN_TOKEN" >/dev/null
) || fail "T8: sibling record emitted"
git -C "$T8_REPO" checkout -q staging
project_records "$T8_REPO"
assert_eq 8 "$PROJECT_RC" "T8: unrelated source is non-authorizing"
assert_eq pending "$PROJECT_OUTCOME" "T8: sibling evidence remains pending"
assert_eq 1 "$(pending_count "$T8_REPO")" "T8: sibling record is retained"
assert_contains "$(remote_backlog "$T8_REPO")" 'status: refined # target comment' "T8: coincidental old value does not mutate remote"

printf '\n=== T9: dependent same-field successor waits then converges ===\n'
T9_REPO="$(setup_repo t9)"
# Build an ancestor carrying the successor predecessor, then return through an
# allowed blocked -> refined lifecycle to the current remote base.
python3 - "$T9_REPO/$BACKLOG_REL" 'status: refined # target comment' 'status: in_progress # target comment' <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as handle: value = handle.read()
with open(path, "w", encoding="utf-8") as handle: handle.write(value.replace(old, new, 1))
PY
git -C "$T9_REPO" add "$BACKLOG_REL" && git -C "$T9_REPO" commit -q -m progress
T9_PROGRESS="$(git -C "$T9_REPO" rev-parse HEAD)"
python3 - "$T9_REPO/$BACKLOG_REL" 'status: in_progress # target comment' 'status: blocked # target comment' <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as handle: value = handle.read()
with open(path, "w", encoding="utf-8") as handle: handle.write(value.replace(old, new, 1))
PY
git -C "$T9_REPO" add "$BACKLOG_REL" && git -C "$T9_REPO" commit -q -m blocked
python3 - "$T9_REPO/$BACKLOG_REL" 'status: blocked # target comment' 'status: refined # target comment' <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as handle: value = handle.read()
with open(path, "w", encoding="utf-8") as handle: handle.write(value.replace(old, new, 1))
PY
git -C "$T9_REPO" add "$BACKLOG_REL" && git -C "$T9_REPO" commit -q -m refined-again
git -C "$T9_REPO" push -q origin staging
emit_record "$T9_REPO" A status in_progress daemon.successor || fail "T9: predecessor record emitted"
git -C "$T9_REPO" show "$T9_PROGRESS:$BACKLOG_REL" > "$T9_REPO/$BACKLOG_REL"
(
  cd "$T9_REPO" || exit 1
  export GAAI_BACKLOG_JOURNAL_SOURCE_REF="$T9_PROGRESS"
  backlog_journal_begin_run "$T9_REPO/$BACKLOG_REL" daemon.successor >/dev/null || exit 1
  backlog_journal_emit "$T9_REPO/$BACKLOG_REL" A status done daemon.successor \
    "$BACKLOG_JOURNAL_RUN_TOKEN" >/dev/null
) || fail "T9: successor record emitted"
git -C "$T9_REPO" restore "$BACKLOG_REL"
project_records "$T9_REPO"
assert_contains "$(remote_backlog "$T9_REPO")" 'status: in_progress # target comment' "T9: eligible predecessor applies first"
assert_eq 1 "$(pending_count "$T9_REPO")" "T9: dependent successor waits"
assert_eq 1 "$(applied_count "$T9_REPO")" "T9: only predecessor retires"
project_records "$T9_REPO"
assert_contains "$(remote_backlog "$T9_REPO")" 'status: done # target comment' "T9: successor converges on next fresh projection"
assert_eq 0 "$(pending_count "$T9_REPO")" "T9: successor retires only after application"

printf '\n=== T10: optional scalar insertion and canonical manifest order ===\n'
T10_REPO="$(setup_repo t10)"
emit_record "$T10_REPO" B started_at 2000-01-01T12:00:00Z daemon.scalar-b || fail "T10: timestamp record emitted"
emit_record "$T10_REPO" C pr_number 17 daemon.scalar-c || fail "T10: integer record emitted"
emit_record "$T10_REPO" A blocked_reason 'json:"évidence bornée"' daemon.scalar-a || fail "T10: Unicode record emitted"
project_records "$T10_REPO"
T10_REMOTE="$(remote_backlog "$T10_REPO")"
assert_contains "$T10_REMOTE" 'blocked_reason: "évidence bornée"' "T10: Unicode optional scalar is inserted"
assert_contains "$T10_REMOTE" 'started_at: "2000-01-01T12:00:00Z"' "T10: timestamp optional scalar is inserted"
assert_contains "$T10_REMOTE" 'pr_number: 17' "T10: integer optional scalar is inserted"
T10_ATTEMPT="$(find "$T10_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/applied-projections" -type f -name '*.json' | head -1)"
T10_ORDER="$(python3 - "$T10_ATTEMPT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle: selected = json.load(handle)["attempt"]["selected"]
print(" ".join(f"{item['story_id']}:{item['field']}" for item in selected))
PY
)"
assert_eq 'A:blocked_reason B:started_at C:pr_number' "$T10_ORDER" "T10: cross-writer groups are sealed in canonical order"

printf '\n=== T11: writer order constrains cross-group canonical scheduling ===\n'
T11_REPO="$(setup_repo t11)"
emit_record "$T11_REPO" C status in_progress daemon.ordered || fail "T11: sequence one emitted"
emit_record "$T11_REPO" A phase_status planned daemon.ordered || fail "T11: sequence two emitted"
project_records "$T11_REPO"
assert_eq 0 "$PROJECT_RC" "T11: ordered projection succeeds"
T11_ATTEMPT="$(find "$T11_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/applied-projections" -type f -name '*.json' | head -1)"
T11_ORDER="$(python3 - "$T11_ATTEMPT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle: selected = json.load(handle)["attempt"]["selected"]
print(" ".join(f"{item['sequence']}:{item['story_id']}:{item['field']}" for item in selected))
PY
)"
assert_eq '1:C:status 2:A:phase_status' "$T11_ORDER" "T11: writer sequence wins over lexical group inversion"
assert_eq 0 "$(pending_count "$T11_REPO")" "T11: ordered independent records both retire"

printf '\n=== T12: private storage, unknown tail and replay isolation ===\n'
T12A_REPO="$(setup_repo t12a)"
emit_record "$T12A_REPO" A status in_progress daemon.storage || fail "T12a: record emitted"
T12A_ROOT="$T12A_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal"
chmod 755 "$T12A_ROOT"
project_records "$T12A_REPO"
assert_eq 1 "$PROJECT_RC" "T12a: permissive journal root fails closed"
assert_eq attempt_storage_unavailable "$PROJECT_REASON" "T12a: permissive root has a closed reason"
assert_eq 1 "$(pending_count "$T12A_REPO")" "T12a: rejected storage retains record"
chmod 700 "$T12A_ROOT"
mv "$T12A_ROOT" "$T12A_ROOT.real"
ln -s "$T12A_ROOT.real" "$T12A_ROOT"
project_records "$T12A_REPO"
assert_eq 1 "$PROJECT_RC" "T12a: symlinked journal root fails closed"
T12A_REAL_PENDING="$(find "$T12A_ROOT.real/writers" -path '*/records/*.json' -type f | wc -l | tr -d ' ')"
assert_eq 1 "$T12A_REAL_PENDING" "T12a: symlink rejection does not retire evidence"
unlink "$T12A_ROOT"
mv "$T12A_ROOT.real" "$T12A_ROOT"

T12B_REPO="$(setup_repo t12b)"
emit_record "$T12B_REPO" B phase_status planned daemon.unknown || fail "T12b: valid prefix emitted"
emit_record "$T12B_REPO" A status in_progress daemon.unknown || fail "T12b: tail emitted"
T12B_RECORDS="$(find "$T12B_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/writers" -type d -name records | head -1)"
printf incomplete > "$T12B_RECORDS/.00000000000000000002-interrupted.tmp"
chmod 600 "$T12B_RECORDS/.00000000000000000002-interrupted.tmp"
project_records "$T12B_REPO"
assert_contains "$(remote_backlog "$T12B_REPO")" 'phase_status: planned' "T12b: valid prefix survives unknown tail"
assert_contains "$(remote_backlog "$T12B_REPO")" 'status: refined # target comment' "T12b: unknown sequence blocks writer tail"
assert_eq 1 "$(pending_count "$T12B_REPO")" "T12b: blocked JSON tail remains pending"
if [[ -f "$T12B_RECORDS/.00000000000000000002-interrupted.tmp" ]]; then pass "T12b: unknown evidence remains exact"; else fail "T12b: unknown evidence disappeared"; fi

T12C_REPO="$(setup_repo t12c)"
emit_record "$T12C_REPO" B phase_status planned daemon.replay || fail "T12c: valid prefix emitted"
emit_record "$T12C_REPO" A status in_progress daemon.replay || fail "T12c: replayable tail emitted"
T12C_WRITER="$(find "$T12C_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/writers" -mindepth 1 -maxdepth 1 -type d | head -1)"
T12C_SEQ2="$(find "$T12C_WRITER/records" -type f -name '00000000000000000002-*.json' | head -1)"
cp "$T12C_SEQ2" "$T12C_WRITER/applied/$(basename "$T12C_SEQ2")"
chmod 600 "$T12C_WRITER/applied/$(basename "$T12C_SEQ2")"
project_records "$T12C_REPO"
assert_contains "$(remote_backlog "$T12C_REPO")" 'phase_status: planned' "T12c: valid prefix survives replayed tail"
assert_contains "$(remote_backlog "$T12C_REPO")" 'status: refined # target comment' "T12c: replay sequence blocks writer tail"
assert_eq 1 "$(pending_count "$T12C_REPO")" "T12c: replayed pending record remains exact"

printf '\n=== T13: unsafe YAML and independent byte-audit failures are closed ===\n'
T13A_REPO="$(setup_repo t13a)"
emit_record "$T13A_REPO" A status in_progress daemon.yaml || fail "T13a: record emitted"
printf '%s\n' 'alias_source: &shared {value: one}' 'alias_copy: *shared' >> "$T13A_REPO/$BACKLOG_REL"
git -C "$T13A_REPO" add "$BACKLOG_REL" && git -C "$T13A_REPO" commit -q -m unsafe-alias
git -C "$T13A_REPO" push -q origin staging
project_records "$T13A_REPO"
assert_eq 8 "$PROJECT_RC" "T13a: anchored/aliased YAML is non-authorizing"
assert_eq 1 "$(pending_count "$T13A_REPO")" "T13a: unsafe YAML retains record"
T13A_DIAG="$(cat "$TEST_ROOT/project.err")"
if [[ "$T13A_DIAG" != *alias_copy* && "$T13A_DIAG" != *"$T13A_REPO"* && "$T13A_DIAG" != *Traceback* ]]; then pass "T13a: YAML failure diagnostic is bounded"; else fail "T13a: YAML failure leaked content or traceback"; fi

T13B_REPO="$(setup_repo t13b)"
emit_record "$T13B_REPO" A status in_progress daemon.byte-audit || fail "T13b: record emitted"
T13B_BASE="$(git -C "$T13B_REPO" rev-parse origin/staging)"
project_records "$T13B_REPO" journal-projection unrelated_byte
assert_eq 1 "$PROJECT_RC" "T13b: unrelated byte injection fails closed"
assert_eq projection_invalid "$PROJECT_REASON" "T13b: byte-audit failure has a closed reason"
assert_eq "$T13B_BASE" "$(git -C "$T13B_REPO" rev-parse origin/staging)" "T13b: byte-audit failure cannot move remote"
assert_eq 1 "$(pending_count "$T13B_REPO")" "T13b: byte-audit failure retains record"

run_movement_case() {
  local mode="$1" trigger="$2" name="move-${1}-${2}" repo remote parent bin once real_git result
  repo="$(setup_repo "$name")"; remote="$TEST_ROOT/$name-remote.git"
  printf base > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -q -m movement-base
  git -C "$repo" push -q origin staging
  parent="$(git -C "$repo" rev-parse 'origin/staging^')"
  emit_record "$repo" A status in_progress daemon.movement || return 1
  bin="$TEST_ROOT/$name-bin"; mkdir -p "$bin"; once="$TEST_ROOT/$name-once"; : > "$once"
  real_git="$(command -v git)"
  cat > "$bin/git" <<WRAP
#!/usr/bin/env bash
if [[ "\$1" == "$trigger" && ! -s "$once" ]]; then
  printf 1 > "$once"
  if [[ "$mode" == forward ]]; then
    race="$TEST_ROOT/$name-race"
    "$real_git" clone -q "$remote" "\$race" 2>/dev/null
    "$real_git" -C "\$race" config user.email race@example.invalid
    "$real_git" -C "\$race" config user.name race
    "$real_git" -C "\$race" checkout -q staging
    printf race > "\$race/race-$trigger.txt"
    "$real_git" -C "\$race" add "race-$trigger.txt"
    "$real_git" -C "\$race" commit -q -m race
    "$real_git" -C "\$race" push -q origin staging
  elif [[ "$mode" == backward ]]; then
    "$real_git" --git-dir="$remote" update-ref refs/heads/staging "$parent"
  else
    "$real_git" --git-dir="$remote" update-ref -d refs/heads/staging
    "$real_git" --git-dir="$remote" update-ref refs/heads/staging "$parent"
  fi
fi
exec "$real_git" "\$@"
WRAP
  chmod +x "$bin/git"
  result="$TEST_ROOT/$name-result"
  (
    cd "$repo" || exit 1
    export PATH="$bin:$PATH" BACKLOG_FILE="$repo/$BACKLOG_REL" BACKLOG_REL TARGET_BRANCH=staging
    local rc=0; chore_commit_project_journal journal-projection >/dev/null 2>/dev/null || rc=$?
    printf '%s\t%s\t%s\n' "$rc" "$CHORE_JOURNAL_OUTCOME" "$CHORE_JOURNAL_REASON" > "$result"
  )
  IFS=$'\t' read -r MOVE_RC MOVE_OUTCOME MOVE_REASON < "$result"
  assert_eq 1 "$MOVE_RC" "T14 $mode/$trigger: movement fails closed"
  assert_eq lease_rejected "$MOVE_REASON" "T14 $mode/$trigger: literal expected-old lease rejects"
  assert_eq 1 "$(pending_count "$repo")" "T14 $mode/$trigger: record remains pending"
}

printf '\n=== T14: forward, backward and delete/recreate races at both windows ===\n'
for T14_TRIGGER in hash-object push; do
  for T14_MODE in forward backward delete-recreate; do
    run_movement_case "$T14_MODE" "$T14_TRIGGER"
  done
done

printf '\n=== T15: retirement/archive crash boundary recovers exactly ===\n'
T15_REPO="$(setup_repo t15)"
emit_record "$T15_REPO" A status in_progress daemon.archive || fail "T15: record emitted"
project_records "$T15_REPO" journal-projection archive_failure
assert_eq 1 "$PROJECT_RC" "T15: injected archive interruption reports failure"
assert_eq archive_interrupted "$PROJECT_REASON" "T15: archive interruption has a closed reason"
assert_eq 0 "$(pending_count "$T15_REPO")" "T15: already-retired record is not recreated"
assert_eq 1 "$(applied_count "$T15_REPO")" "T15: retired evidence remains durable"
project_records "$T15_REPO" recovery archive_helper_failure
assert_eq 1 "$PROJECT_RC" "T15: real recovery archive failure fails closed"
assert_eq retained "$PROJECT_OUTCOME" "T15: recovery archive evidence stays retained"
assert_eq archive_failed "$PROJECT_REASON" "T15: real recovery archive failure is typed"
assert_eq 1 "$(find "$T15_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/projections" -type f -name '*.json' | wc -l | tr -d ' ')" "T15: sealed attempt survives recovery archive failure"
project_records "$T15_REPO" recovery
assert_eq noop "$PROJECT_OUTCOME" "T15: restart archives sealed attempt then no-ops"
T15_ATTEMPT="$(find "$T15_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/applied-projections" -type f -name '*.json' | head -1)"
if ! grep -q 'target_ref\|refs/heads/' "$T15_ATTEMPT"; then pass "T15: sealed evidence contains no branch metadata"; else fail "T15: branch metadata leaked into sealed evidence"; fi

printf '\n=== T16: backlog file and canonical Git path are one authority ===\n'
T16_REPO="$(setup_repo t16)"
emit_record "$T16_REPO" A status in_progress daemon.path || fail "T16: record emitted"
T16_ALIAS_REL=".gaai/project/contexts/backlog/alias.backlog.yaml"
cp "$T16_REPO/$BACKLOG_REL" "$T16_REPO/$T16_ALIAS_REL"
git -C "$T16_REPO" add "$T16_ALIAS_REL"
git -C "$T16_REPO" commit -q -m identical-alias
git -C "$T16_REPO" push -q origin staging
T16_CANONICAL_BEFORE="$(remote_backlog "$T16_REPO")"
T16_ALIAS_BEFORE="$(git -C "$T16_REPO" show "origin/staging:$T16_ALIAS_REL")"
(
  cd "$T16_REPO" || exit 1
  export BACKLOG_FILE="$T16_REPO/$BACKLOG_REL" BACKLOG_REL="$T16_ALIAS_REL" TARGET_BRANCH=staging
  local_rc=0
  chore_commit_project_journal journal-projection >/dev/null 2>"$TEST_ROOT/t16-alias.err" || local_rc=$?
  printf '%s\t%s\n' "$local_rc" "$CHORE_JOURNAL_REASON" > "$TEST_ROOT/t16-alias-result"
)
IFS=$'\t' read -r T16_ALIAS_RC T16_ALIAS_REASON < "$TEST_ROOT/t16-alias-result"
assert_eq 1 "$T16_ALIAS_RC" "T16a: identical tracked alias is rejected"
assert_eq backlog_path_invalid "$T16_ALIAS_REASON" "T16a: alias rejection is typed"
assert_eq "$T16_CANONICAL_BEFORE" "$(remote_backlog "$T16_REPO")" "T16a: canonical backlog remains unchanged"
assert_eq "$T16_ALIAS_BEFORE" "$(git -C "$T16_REPO" show "origin/staging:$T16_ALIAS_REL")" "T16a: alias backlog remains unchanged"
assert_eq 1 "$(pending_count "$T16_REPO")" "T16a: rejected alias retains evidence"
T16_LINK="$T16_REPO/.gaai/project/contexts/backlog/linked.backlog.yaml"
ln -s "$(basename "$BACKLOG_REL")" "$T16_LINK"
(
  cd "$T16_REPO" || exit 1
  export BACKLOG_FILE="$T16_LINK" BACKLOG_REL TARGET_BRANCH=staging
  local_rc=0
  chore_commit_project_journal journal-projection >/dev/null 2>"$TEST_ROOT/t16-link.err" || local_rc=$?
  printf '%s\t%s\n' "$local_rc" "$CHORE_JOURNAL_REASON" > "$TEST_ROOT/t16-link-result"
)
IFS=$'\t' read -r T16_LINK_RC T16_LINK_REASON < "$TEST_ROOT/t16-link-result"
assert_eq 1 "$T16_LINK_RC" "T16b: symlinked backlog input is rejected"
assert_eq backlog_path_invalid "$T16_LINK_REASON" "T16b: symlink rejection is typed"

run_privacy_fault() {
  local fault="$1" expected_reason="$2" label="$3" repo diag lines
  repo="$(setup_repo "privacy-$fault")"
  emit_record "$repo" A status in_progress daemon.privacy || { fail "$label: record emitted"; return; }
  project_records "$repo" journal-projection "$fault"
  diag="$(cat "$TEST_ROOT/project.err")"
  lines="$(wc -l < "$TEST_ROOT/project.err" | tr -d ' ')"
  assert_eq 1 "$PROJECT_RC" "$label: boundary fails closed"
  assert_eq "$expected_reason" "$PROJECT_REASON" "$label: chore reason is typed"
  if [[ "$diag" != *Traceback* && "$diag" != *"$repo"* && "$diag" != *active.backlog.yaml* \
      && "$diag" != *operator-secret* ]]; then
    pass "$label: diagnostic leaks no path, content or traceback"
  else
    fail "$label: diagnostic leaked path, content or traceback"
  fi
  if [[ "$lines" =~ ^[0-9]+$ && "$lines" -le 3 ]]; then
    pass "$label: diagnostic remains bounded"
  else
    fail "$label: diagnostic is unbounded (lines=$lines)"
  fi
  assert_eq 1 "$(pending_count "$repo")" "$label: failure retains pending evidence"
}

printf '\n=== T17: seal/finalize failures are typed and privacy-safe ===\n'
run_privacy_fault seal_missing_manifest seal_failed "T17a missing seal input"
run_privacy_fault seal_malformed_manifest seal_failed "T17b malformed seal input"
run_privacy_fault counts_missing_manifest projection_invalid "T17c missing counts manifest"
run_privacy_fault counts_malformed_manifest projection_invalid "T17d malformed counts manifest"
run_privacy_fault finalize_missing_attempt finalization_failed "T17e missing attempt"
run_privacy_fault finalize_malformed_attempt finalization_failed "T17f malformed attempt"
run_privacy_fault finalize_missing_record finalization_failed "T17g missing record"
run_privacy_fault finalize_malformed_record finalization_failed "T17h malformed record"

printf '\n=== T18: real publisher command failures always have closed state ===\n'
run_git_failure() {
  local command="$1" match_arg="$2" expected_reason="$3" label="$4" repo bin real_git
  repo="$(setup_repo "git-fail-$command-${match_arg//[^A-Za-z0-9]/x}")"
  emit_record "$repo" A status in_progress daemon.command || { fail "$label: record emitted"; return; }
  bin="$TEST_ROOT/bin-$command-${match_arg//[^A-Za-z0-9]/x}"; mkdir -p "$bin"
  real_git="$(command -v git)"
  cat > "$bin/git" <<WRAP
#!/usr/bin/env bash
if [[ "\$1" == "$command" && ( -z "$match_arg" || "\${2:-}" == "$match_arg" || "\${2:-}" == *"$match_arg" ) ]]; then
  exit 71
fi
exec "$real_git" "\$@"
WRAP
  chmod +x "$bin/git"
  (
    cd "$repo" || exit 1
    export PATH="$bin:$PATH" BACKLOG_FILE="$repo/$BACKLOG_REL" BACKLOG_REL TARGET_BRANCH=staging
    local_rc=0
    chore_commit_project_journal journal-projection >/dev/null 2>"$TEST_ROOT/command.err" || local_rc=$?
    printf '%s\t%s\t%s\n' "$local_rc" "$CHORE_JOURNAL_OUTCOME" "$CHORE_JOURNAL_REASON" > "$TEST_ROOT/command-result"
  )
  IFS=$'\t' read -r COMMAND_RC COMMAND_OUTCOME COMMAND_REASON < "$TEST_ROOT/command-result"
  assert_eq 1 "$COMMAND_RC" "$label: command failure is closed"
  assert_eq rejected "$COMMAND_OUTCOME" "$label: outcome is typed"
  assert_eq "$expected_reason" "$COMMAND_REASON" "$label: reason is typed"
  assert_eq 1 "$(pending_count "$repo")" "$label: pending evidence is retained"
}

run_git_failure rev-parse --show-toplevel input_invalid "T18a repository resolution"
run_git_failure rev-parse HEAD ambient_state_unavailable "T18b ambient HEAD"
run_git_failure status '' ambient_state_unavailable "T18c ambient status"
run_git_failure rev-parse origin/staging base_unresolvable "T18d fetched base"
run_git_failure hash-object '' commit_failed "T18e hash-object"
run_git_failure read-tree '' commit_failed "T18f read-tree"
run_git_failure update-index '' commit_failed "T18g update-index"
run_git_failure write-tree '' commit_failed "T18h write-tree"
run_git_failure rev-parse '^' commit_failed "T18i sole-parent proof"

T18J_REPO="$(setup_repo scratch-failure)"
emit_record "$T18J_REPO" A status in_progress daemon.scratch || fail "T18j: record emitted"
T18J_BIN="$TEST_ROOT/scratch-bin"; mkdir -p "$T18J_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 71' > "$T18J_BIN/mktemp"; chmod +x "$T18J_BIN/mktemp"
(
  cd "$T18J_REPO" || exit 1
  export PATH="$T18J_BIN:$PATH" BACKLOG_FILE="$T18J_REPO/$BACKLOG_REL" BACKLOG_REL TARGET_BRANCH=staging
  local_rc=0
  chore_commit_project_journal journal-projection >/dev/null 2>"$TEST_ROOT/scratch.err" || local_rc=$?
  printf '%s\t%s\t%s\n' "$local_rc" "$CHORE_JOURNAL_OUTCOME" "$CHORE_JOURNAL_REASON" > "$TEST_ROOT/scratch-result"
)
IFS=$'\t' read -r T18J_RC T18J_OUTCOME T18J_REASON < "$TEST_ROOT/scratch-result"
assert_eq 1 "$T18J_RC" "T18j scratch: failure is closed"
assert_eq rejected "$T18J_OUTCOME" "T18j scratch: outcome is typed"
assert_eq scratch_unavailable "$T18J_REASON" "T18j scratch: reason is typed"

T18K_REPO="$(setup_repo live-archive-failure)"
emit_record "$T18K_REPO" A status in_progress daemon.archive-live || fail "T18k: record emitted"
project_records "$T18K_REPO" journal-projection archive_helper_failure
assert_eq 1 "$PROJECT_RC" "T18k live archive: helper failure is closed"
assert_eq retained "$PROJECT_OUTCOME" "T18k live archive: outcome is typed"
assert_eq archive_failed "$PROJECT_REASON" "T18k live archive: reason is typed"
assert_eq 1 "$(applied_count "$T18K_REPO")" "T18k live archive: retired evidence remains durable"
assert_eq 1 "$(find "$T18K_REPO/.gaai/project/contexts/backlog/.delivery-locks/journal/projections" -type f -name '*.json' | wc -l | tr -d ' ')" "T18k live archive: sealed attempt remains retryable"
T18K_DIAG="$(cat "$TEST_ROOT/project.err")"
if [[ "$T18K_DIAG" != *Traceback* && "$T18K_DIAG" != *"$T18K_REPO"* ]]; then pass "T18k live archive: diagnostic is privacy-safe"; else fail "T18k live archive: diagnostic leaked"; fi
project_records "$T18K_REPO" recovery
assert_eq noop "$PROJECT_OUTCOME" "T18k live archive: retry archives then no-ops"

printf '\n=== T19: admission-hold resume procedure — reset lands on target ===\n'
# Applies the exact two-field reset + commit + push the admission-hold
# diagnostic's resume procedure prescribes, using backlog-scheduler.sh
# --set-field directly (the same tool the diagnostic's rendered burst names —
# NOT the daemon's internal journal path, which enforces PHASE_EDGES
# transition validity the operator's manual recovery burst is not subject
# to), and asserts it lands on origin/staging with every unrelated byte
# preserved.
SCHEDULER="$SCRIPT_DIR/../backlog-scheduler.sh"
T19_REPO="$(setup_repo t19)"
T19_BASE="$(git -C "$T19_REPO" rev-parse origin/staging)"
bash "$SCHEDULER" --set-field A status in_progress "$T19_REPO/$BACKLOG_REL" >/dev/null \
  || fail "T19: --set-field status applied"
bash "$SCHEDULER" --set-field A phase_status implemented "$T19_REPO/$BACKLOG_REL" >/dev/null \
  || fail "T19: --set-field phase_status applied"
(
  cd "$T19_REPO" || exit 1
  git add "$BACKLOG_REL" \
    && git commit -q -m "chore(A): resume after admission hold [pre_qa]" \
    && git push -q origin HEAD:staging
)
assert_eq 0 "$?" "T19: resume commit+push exits 0"
T19_REMOTE="$(remote_backlog "$T19_REPO")"
# --set-field is a straightforward line rewrite (unlike the journal's
# comment-preserving projection exercised in T1) — it drops the inline
# comment on the line it rewrites; that is this tool's real, unchanged
# behavior, not a regression to assert away.
assert_contains "$T19_REMOTE" 'status: in_progress' "T19: reset status lands on target"
assert_contains "$T19_REMOTE" 'phase_status: implemented' "T19: reset phase_status lands on target"
assert_contains "$T19_REMOTE" '# formatting sentinel: keep exactly' "T19: unrelated bytes are preserved"
assert_contains "$T19_REMOTE" 'tail: "preserve: yes"' "T19: unrelated tail is preserved"
assert_eq "$T19_BASE" "$(git -C "$T19_REPO" rev-parse "origin/staging^")" "T19: resume candidate has exact remote parent"

printf '\n=== T19b: a local-only edit never reaches origin/staging (resume-procedure verification gate) ===\n'
# Mirrors T1's ambient-sentinel style: a local-only edit (applied with
# --set-field but never committed/pushed) must never appear in the
# remote-authoritative read the diagnostic's step 3 verification relies on.
T19B_REMOTE_BEFORE="$(git -C "$T19_REPO" rev-parse origin/staging)"
bash "$SCHEDULER" --set-field A status done "$T19_REPO/$BACKLOG_REL" >/dev/null \
  || fail "T19b: local-only --set-field applied"
T19B_REMOTE_AFTER="$(git -C "$T19_REPO" rev-parse origin/staging)"
assert_eq "$T19B_REMOTE_BEFORE" "$T19B_REMOTE_AFTER" "T19b: local-only edit leaves origin/staging unchanged"
if [[ "$(remote_backlog "$T19_REPO")" != *'status: done'* ]]; then
  pass "T19b: remote-authoritative read does not see the local-only edit"
else
  fail "T19b: local-only edit leaked into the remote-authoritative read"
fi

printf '\n=== T19c: resume procedure at the FINAL boundary (target qa_passed) lands the same way ===\n'
# T19/T19b already prove the pre_qa target (phase_status: implemented). The
# diagnostic's rendered resume target at the final boundary is qa_passed
# when the QA-report sidecar is present (implemented otherwise — the
# sidecar-detection itself is daemon-dispatch.sh territory, exercised by
# the AC6a-final/AC6b-dispatch cases in daemon-state-machine.test.sh); this
# case proves the SAME --set-field+commit+push mechanism lands that second
# target value correctly too, with every unrelated byte preserved.
T19C_REPO="$(setup_repo t19c)"
T19C_BASE="$(git -C "$T19C_REPO" rev-parse origin/staging)"
bash "$SCHEDULER" --set-field A status in_progress "$T19C_REPO/$BACKLOG_REL" >/dev/null \
  || fail "T19c: --set-field status applied"
bash "$SCHEDULER" --set-field A phase_status qa_passed "$T19C_REPO/$BACKLOG_REL" >/dev/null \
  || fail "T19c: --set-field phase_status applied"
(
  cd "$T19C_REPO" || exit 1
  git add "$BACKLOG_REL" \
    && git commit -q -m "chore(A): resume after admission hold [final]" \
    && git push -q origin HEAD:staging
)
assert_eq 0 "$?" "T19c: resume commit+push exits 0"
T19C_REMOTE="$(remote_backlog "$T19C_REPO")"
assert_contains "$T19C_REMOTE" 'status: in_progress' "T19c: reset status lands on target"
assert_contains "$T19C_REMOTE" 'phase_status: qa_passed' "T19c: reset phase_status (final-boundary target) lands on target"
assert_contains "$T19C_REMOTE" '# formatting sentinel: keep exactly' "T19c: unrelated bytes are preserved"
assert_eq "$T19C_BASE" "$(git -C "$T19C_REPO" rev-parse "origin/staging^")" "T19c: resume candidate has exact remote parent"

printf '\n=== T20: applying the diagnostics full procedure makes the story dispatchable\n'
printf '    again — proven through a REAL admission-boundary call, not a bare rm+[[ -f ]] ===\n'
# G2 remediation: the previous T19d/T19e asserted "dispatchable again" via
# `rm -f X` then `[[ ! -f X ]]` — an assertion that can only fail if `rm`
# itself fails, proving nothing about the admission boundary. This block
# resolves the hold path through _admission_hold_path, asserts hold state
# through _admission_hold_active (not [[ -f ]]), and — after applying the
# diagnostic's full procedure (backlog reset lands on origin/staging while
# checked out on the TARGET branch, per the diagnostic's own "fresh checkout
# of staging" framing and T19/T19c above; only THEN does the explicit last
# step, hold removal, apply) — drives a REAL admission-boundary call
# (_prepare_pre_qa_admission / _admit_current_candidate) and asserts it
# actually runs the admission, at both the pre_qa and final boundaries.
# _journal_persist_lifecycle is overridden with a no-op success double: the
# real function projects onto the REMOTE target branch via a separate
# PROJECT_DIR fetch + journal mechanism and never touches the candidate
# repo's own worktree copy of the backlog file — T1-T19 above already
# exercise that real remote-fetching substrate. This block is only about the
# admission boundary's own hold-guard control flow (does it run the
# admission or not), so the double just needs to succeed. A double that
# writes the field into the candidate repo's OWN tracked backlog file (as
# daemon-state-machine.test.sh's double does, against an untracked standalone
# YAML fixture there) would leave the candidate's git worktree dirty here —
# verified experimentally: it broke _reconcile_admission_base's
# clean-working-tree check on the very next boundary call, which is exactly
# the "dispatchable again" property this block exists to prove. Sidecar
# presence/absence is deliberately NOT re-varied here either: reading
# _prepare_pre_qa_admission/_admit_current_candidate shows the sidecar only
# ever affects _write_admission_diagnostic's rendered phase_target string
# (already covered by T19/T19c's real backlog-persistence assertions), never
# the hold-guard control flow this block proves.
DISPATCH_LIB="$SCRIPT_DIR/../daemon-dispatch.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../daemon-dispatch.sh
source "$DISPATCH_LIB"
_journal_persist_lifecycle() {
  return 0
}
T20_ADMIT_LOG="$TEST_ROOT/t20-admit.log"
_run_local_admission() {
  printf 'run\n' >> "$T20_ADMIT_LOG"
  LOCAL_ADMISSION_OUTCOME="blocked:execution_failed"
  return 1
}

# ── T20a: pre_qa boundary ────────────────────────────────────────────────
T20A_REPO="$(setup_repo t20a)"
BACKLOG_FILE="$T20A_REPO/$BACKLOG_REL"
T20A_LOCKS="$T20A_REPO/.gaai/project/contexts/backlog/.delivery-locks"
mkdir -p "$T20A_LOCKS"

# Apply the diagnostic's steps 1-3 (fresh checkout of the target, reset,
# publish) while still on `staging` — exactly as T19 does.
bash "$SCHEDULER" --set-field A status in_progress "$BACKLOG_FILE" >/dev/null \
  || fail "T20a: --set-field status applied"
bash "$SCHEDULER" --set-field A phase_status implemented "$BACKLOG_FILE" >/dev/null \
  || fail "T20a: --set-field phase_status applied"
(
  cd "$T20A_REPO" || exit 1
  git add "$BACKLOG_REL" && git commit -q -m "chore(A): resume after admission hold [pre_qa]" && git push -q origin HEAD:staging
)
assert_eq 0 "$?" "T20a: resume commit+push exits 0"
assert_contains "$(remote_backlog "$T20A_REPO")" 'phase_status: implemented' "T20a: reset phase_status lands on target"

# Now branch off the (just-reset) target for the story's own candidate —
# the admission boundary operates on this candidate, never on the reset
# commit itself.
git -C "$T20A_REPO" checkout -q -b story/T20A
printf 'change\n' > "$T20A_REPO/change.txt"
git -C "$T20A_REPO" add -A && git -C "$T20A_REPO" commit -q -m "story change"
T20A_HEAD="$(git -C "$T20A_REPO" rev-parse HEAD)"

LOCK_DIR="$T20A_LOCKS" _write_admission_hold A pre_qa "$T20A_HEAD" blocked:command_timed_out "" "" \
  || fail "T20a: hold write setup succeeded"
if LOCK_DIR="$T20A_LOCKS" _admission_hold_active A pre_qa; then
  pass "T20a: hold is active before removal (_admission_hold_active)"
else
  fail "T20a: hold not active immediately after writing it"
fi
: > "$T20_ADMIT_LOG"
LOCK_DIR="$T20A_LOCKS" TARGET_BRANCH=staging \
  _prepare_pre_qa_admission A trace-t20a-held "$T20A_REPO" >/tmp/t20a-held.out 2>&1 || true
if [[ ! -s "$T20_ADMIT_LOG" ]] && grep -q "ADMISSION-HOLD" /tmp/t20a-held.out; then
  pass "T20a: still held — zero admission executions (step 4 not yet applied)"
else
  fail "T20a: held boundary ran an admission or did not report the hold"
fi

# Step 4, last: remove the hold — resolved through _admission_hold_path.
rm -f "$(LOCK_DIR="$T20A_LOCKS" _admission_hold_path A pre_qa)"
if LOCK_DIR="$T20A_LOCKS" _admission_hold_active A pre_qa; then
  fail "T20a: hold still active after its explicit removal"
else
  pass "T20a: hold is inactive after removal (_admission_hold_active, not [[ -f ]])"
fi
: > "$T20_ADMIT_LOG"
LOCK_DIR="$T20A_LOCKS" TARGET_BRANCH=staging \
  _prepare_pre_qa_admission A trace-t20a-free "$T20A_REPO" >/tmp/t20a-free.out 2>&1 || true
if [[ -s "$T20_ADMIT_LOG" ]]; then
  pass "T20a: the story is dispatchable again — the real pre_qa admission boundary ran"
else
  fail "T20a: pre_qa boundary did not run the admission after hold removal"
fi

# ── T20b: final boundary, the same proof ────────────────────────────────
T20B_REPO="$(setup_repo t20b)"
BACKLOG_FILE="$T20B_REPO/$BACKLOG_REL"
T20B_LOCKS="$T20B_REPO/.gaai/project/contexts/backlog/.delivery-locks"
mkdir -p "$T20B_LOCKS"

bash "$SCHEDULER" --set-field A status in_progress "$BACKLOG_FILE" >/dev/null \
  || fail "T20b: --set-field status applied"
bash "$SCHEDULER" --set-field A phase_status qa_passed "$BACKLOG_FILE" >/dev/null \
  || fail "T20b: --set-field phase_status applied"
(
  cd "$T20B_REPO" || exit 1
  git add "$BACKLOG_REL" && git commit -q -m "chore(A): resume after admission hold [final]" && git push -q origin HEAD:staging
)
assert_eq 0 "$?" "T20b: resume commit+push exits 0"
assert_contains "$(remote_backlog "$T20B_REPO")" 'phase_status: qa_passed' "T20b: reset phase_status (final-boundary target) lands on target"

git -C "$T20B_REPO" checkout -q -b story/T20B
printf 'change\n' > "$T20B_REPO/change.txt"
git -C "$T20B_REPO" add -A && git -C "$T20B_REPO" commit -q -m "story change"
T20B_HEAD="$(git -C "$T20B_REPO" rev-parse HEAD)"

LOCK_DIR="$T20B_LOCKS" _write_admission_hold A final "$T20B_HEAD" blocked:command_timed_out "" "" \
  || fail "T20b: hold write setup succeeded"
: > "$T20_ADMIT_LOG"
LOCK_DIR="$T20B_LOCKS" TARGET_BRANCH=staging \
  _admit_current_candidate final A trace-t20b-held "$T20B_REPO" >/tmp/t20b-held.out 2>&1 || true
if [[ ! -s "$T20_ADMIT_LOG" ]] && grep -q "ADMISSION-HOLD" /tmp/t20b-held.out; then
  pass "T20b: still held at the final boundary — zero admission executions"
else
  fail "T20b: held final boundary ran an admission or did not report the hold"
fi
rm -f "$(LOCK_DIR="$T20B_LOCKS" _admission_hold_path A final)"
if LOCK_DIR="$T20B_LOCKS" _admission_hold_active A final; then
  fail "T20b: hold still active after its explicit removal"
else
  pass "T20b: hold is inactive after removal at the final boundary (_admission_hold_active)"
fi
: > "$T20_ADMIT_LOG"
LOCK_DIR="$T20B_LOCKS" TARGET_BRANCH=staging \
  _admit_current_candidate final A trace-t20b-free "$T20B_REPO" >/tmp/t20b-free.out 2>&1 || true
if [[ -s "$T20_ADMIT_LOG" ]]; then
  pass "T20b: the story is dispatchable again at the final boundary — the real admission boundary ran"
else
  fail "T20b: final boundary did not run the admission after hold removal"
fi

rm -f /tmp/t20a-held.out /tmp/t20a-free.out /tmp/t20b-held.out /tmp/t20b-free.out
unset -f _run_local_admission
unset T20_ADMIT_LOG

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'RESULTS: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
[[ "$FAIL_COUNT" -eq 0 ]]
