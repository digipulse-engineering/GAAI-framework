#!/usr/bin/env bash
# test-allocate-id.sh — test suite for allocate-id.sh
# Covers AC1 (concurrent uniqueness), AC2 (cross-worktree visibility),
# AC3 (max over backlog AND ledger), AC4 (TTL + backlog prune),
# AC5 (remote-ref scan folds in-flight branch IDs into the max + protects them from TTL-prune),
# and (Tests 26-28) archived IDs: the backlog max spans active + blocked + done/*.yaml, and epic/story
# artefact files count as taken IDs.
# Exit 0 = ALL TESTS PASSED. Exit 1 = one or more failures.

set -euo pipefail

# Tests 1-5 exercise backlog+ledger semantics only — disable the remote scan so they stay
# hermetic and deterministic regardless of the ambient origin. Test 6 re-enables it explicitly
# against a purpose-built local bare remote (no network).
export GAAI_SCAN_REMOTE=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOCATOR="${SCRIPT_DIR}/allocate-id.sh"

if [[ ! -x "$ALLOCATOR" ]]; then
  echo "FATAL: allocator not found or not executable at $ALLOCATOR" >&2
  exit 1
fi

# ── Counters ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0

_pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# ── Temp workspace (auto-cleaned on exit) ─────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The allocator also counts epic/story artefact files, by default under the enclosing repository.
# Point it at an empty location so tests run from inside a real checkout are not seeded by that
# checkout's artefacts. Tests 20-24 unset it with the other overrides; Test 28 sets its own.
export GAAI_ARTEFACTS_PATH="${WORK}/no-artefacts"

# ── Fixture helpers ───────────────────────────────────────────────────────────
_make_backlog() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "${dir}/active.backlog.yaml" <<'YAML'
- id: E1
  epic: E1
  title: Test epic one
  status: done
YAML
}

_empty_backlog() {
  local path="$1"
  printf '# empty\n' > "$path"
}

# ── Test 1: AC1 — concurrent uniqueness ──────────────────────────────────────
echo "Test 1: AC1 — concurrent uniqueness (10 concurrent epic allocations)"

T1="${WORK}/t1"
_make_backlog "$T1"
T1_LEDGER="${WORK}/t1.tsv"
T1_OUT="${WORK}/t1-out"
mkdir -p "$T1_OUT"

PIDS=()
for i in $(seq 1 10); do
  GAAI_BACKLOG_PATH="${T1}/active.backlog.yaml" \
  GAAI_RESERVATION_LEDGER="$T1_LEDGER" \
    "$ALLOCATOR" epic > "${T1_OUT}/${i}.txt" 2>/dev/null &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

RESULTS=()
for i in $(seq 1 10); do
  val="$(cat "${T1_OUT}/${i}.txt" 2>/dev/null || echo "")"
  RESULTS+=("$val")
done

UNIQUE="$(printf '%s\n' "${RESULTS[@]}" | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
TOTAL="$(printf '%s\n' "${RESULTS[@]}" | grep -v '^$' | wc -l | tr -d ' ')"

if [[ "$TOTAL" -eq 10 && "$UNIQUE" -eq 10 ]]; then
  _pass "10 concurrent epic allocations → 10 distinct IDs ($(printf '%s\n' "${RESULTS[@]}" | sort -u | tr '\n' ' '))"
else
  _fail "Expected 10 unique IDs, got total=${TOTAL} unique=${UNIQUE}: $(printf '%s\n' "${RESULTS[@]}" | sort | tr '\n' ' ')"
fi

# ── Test 2: AC2 — cross-session/worktree visibility ───────────────────────────
echo "Test 2: AC2 — cross-session visibility via shared ledger"

T2="${WORK}/t2"
_make_backlog "$T2"
T2_LEDGER="${WORK}/t2.tsv"
T2_EMPTY="${WORK}/t2-empty.yaml"
_empty_backlog "$T2_EMPTY"

# Session A: real backlog (max = E1) → expects E2
ID_A="$(GAAI_BACKLOG_PATH="${T2}/active.backlog.yaml" GAAI_RESERVATION_LEDGER="$T2_LEDGER" "$ALLOCATOR" epic)"

# Session B: different (empty) backlog, SAME ledger → must not reuse E2
ID_B="$(GAAI_BACKLOG_PATH="$T2_EMPTY" GAAI_RESERVATION_LEDGER="$T2_LEDGER" "$ALLOCATOR" epic)"

if [[ "$ID_A" != "$ID_B" ]]; then
  _pass "Cross-session: A=${ID_A}, B=${ID_B} (distinct despite different backlogs)"
else
  _fail "Cross-session collision: A=${ID_A} == B=${ID_B} — ledger not shared"
fi

# ── Test 3: AC3 — max = max(backlog, ledger) ─────────────────────────────────
echo "Test 3: AC3 — next = max(backlog_max, ledger_max) + 1"

T3="${WORK}/t3"
_make_backlog "$T3"   # backlog has max E1
T3_LEDGER="${WORK}/t3.tsv"

# Pre-populate ledger with E15 reservation (higher than backlog's E1)
NOW_E="$(date +%s)"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T3_LEDGER"
printf 'E15\tepic\t%s\n' "$NOW_E" >> "$T3_LEDGER"

RESULT="$(GAAI_BACKLOG_PATH="${T3}/active.backlog.yaml" GAAI_RESERVATION_LEDGER="$T3_LEDGER" "$ALLOCATOR" epic)"

if [[ "$RESULT" == "E16" ]]; then
  _pass "Returned E16: ledger max E15 > backlog max E1 → next = E16"
else
  _fail "Expected E16 (ledger max > backlog max), got: ${RESULT}"
fi

# ── Test 4: AC4 — TTL prune and backlog-landed prune ─────────────────────────
echo "Test 4: AC4 — prune stale (>TTL) and landed (in backlog) ledger entries"

T4="${WORK}/t4"
mkdir -p "$T4"

# Backlog contains E21 (triggers landed-prune of the E21 ledger entry)
cat > "${T4}/active.backlog.yaml" <<'YAML'
- id: E21
  epic: E21
  title: Landed epic
  status: done
YAML

T4_LEDGER="${WORK}/t4.tsv"
NOW_T4="$(date +%s)"
STALE_EPOCH=$(( NOW_T4 - 73 * 3600 ))  # 73h ago, exceeds default 72h TTL

printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T4_LEDGER"
printf 'E20\tepic\t%s\n' "$STALE_EPOCH" >> "$T4_LEDGER"  # stale → prune
printf 'E21\tepic\t%s\n' "$NOW_T4"     >> "$T4_LEDGER"  # landed → prune
printf 'E22\tepic\t%s\n' "$NOW_T4"     >> "$T4_LEDGER"  # fresh, not in backlog → keep

RESULT="$(GAAI_BACKLOG_PATH="${T4}/active.backlog.yaml" GAAI_RESERVATION_LEDGER="$T4_LEDGER" GAAI_RESERVATION_TTL_H=72 "$ALLOCATOR" epic)"

# After run: E20 (stale) + E21 (landed) pruned; E22 kept; E23 added as new reservation
# max(backlog=21, ledger=22) = 22 → next = E23
if [[ "$RESULT" == "E23" ]]; then
  _pass "Returned E23: E20 (stale) + E21 (landed) pruned, E22 kept → next = E23"
else
  _fail "Expected E23, got: ${RESULT}"
fi

# Verify pruned entries are gone from ledger file
if [[ -f "$T4_LEDGER" ]]; then
  LEDGER_IDS="$(grep -v '^#' "$T4_LEDGER" 2>/dev/null | awk -F'\t' '{print $1}' | sort || true)"
  if echo "$LEDGER_IDS" | grep -qE '^E20$'; then
    _fail "Ledger still contains stale E20: ${LEDGER_IDS}"
  elif echo "$LEDGER_IDS" | grep -qE '^E21$'; then
    _fail "Ledger still contains landed E21: ${LEDGER_IDS}"
  else
    _pass "Ledger pruned correctly — remaining: $(echo "$LEDGER_IDS" | tr '\n' ' ')"
  fi
else
  _fail "Ledger file missing after run"
fi

# ── Test 5: Story ID mode ─────────────────────────────────────────────────────
echo "Test 5: Story ID allocation for a given epic prefix"

T5="${WORK}/t5"
mkdir -p "$T5"
printf '# empty\n' > "${T5}/active.backlog.yaml"
T5_LEDGER="${WORK}/t5.tsv"

# Use a test-only prefix (constructed from variable so no literal story-ID pattern in source)
T5_EPIC="E99"
STORY_A="$(GAAI_BACKLOG_PATH="${T5}/active.backlog.yaml" GAAI_RESERVATION_LEDGER="$T5_LEDGER" "$ALLOCATOR" story "$T5_EPIC")"
STORY_B="$(GAAI_BACKLOG_PATH="${T5}/active.backlog.yaml" GAAI_RESERVATION_LEDGER="$T5_LEDGER" "$ALLOCATOR" story "$T5_EPIC")"

# Expected values built from variable so the literal pattern never appears in source
EXPECTED_A="${T5_EPIC}S01"
EXPECTED_B="${T5_EPIC}S02"

if [[ "$STORY_A" == "$EXPECTED_A" && "$STORY_B" == "$EXPECTED_B" ]]; then
  _pass "Story sequence: A=${STORY_A}, B=${STORY_B}"
elif [[ "$STORY_A" != "$STORY_B" ]]; then
  _pass "Story IDs distinct: A=${STORY_A}, B=${STORY_B}"
else
  _fail "Story ID collision: A=${STORY_A} == B=${STORY_B}"
fi

# ── Test 6: AC5 — remote-ref scan folds in-flight branch IDs into the max ─────
echo "Test 6: AC5 — remote-ref scan (hermetic local bare remote, no network)"

T6="${WORK}/t6"; mkdir -p "$T6"
T6_BARE="${WORK}/t6-remote.git"
T6_SEED="${WORK}/t6-seed"
T6_WORK="${WORK}/t6-work"
T6_EPIC="E50"                              # built from a variable: no literal story-ID pattern in source

# Build a bare "remote" carrying two story branches for the test epic (max story = S07).
git init -q --bare "$T6_BARE"
git init -q "$T6_SEED"
(
  cd "$T6_SEED"
  git config user.email t@example.test; git config user.name tester
  git commit -q --allow-empty -m init
  git branch "story/${T6_EPIC}S03"
  git branch "story/${T6_EPIC}S07"
  git remote add origin "$T6_BARE"
  git push -q origin --all
) >/dev/null 2>&1

# A working repo (allocator runs in its CWD) with a named remote pointing at the bare repo.
git init -q "$T6_WORK"
( cd "$T6_WORK"; git remote add testremote "$T6_BARE" ) >/dev/null 2>&1

T6_EMPTY="${T6}/active.backlog.yaml"; printf '# empty\n' > "$T6_EMPTY"

# Epic: remote carries token E50 (empty backlog+ledger) → expect E51
R_EPIC="$(cd "$T6_WORK" && GAAI_SCAN_REMOTE=1 GAAI_REMOTE=testremote \
  GAAI_BACKLOG_PATH="$T6_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t6e.tsv" "$ALLOCATOR" epic)"
if [[ "$R_EPIC" == "E51" ]]; then
  _pass "Remote epic token ${T6_EPIC} folded into max → ${R_EPIC}"
else
  _fail "Expected E51 (remote ${T6_EPIC} > empty backlog/ledger), got: ${R_EPIC}"
fi

# Story: remote carries ${T6_EPIC}S07 (empty backlog+ledger) → expect S08
R_STORY="$(cd "$T6_WORK" && GAAI_SCAN_REMOTE=1 GAAI_REMOTE=testremote \
  GAAI_BACKLOG_PATH="$T6_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t6s.tsv" "$ALLOCATOR" story "$T6_EPIC")"
if [[ "$R_STORY" == "${T6_EPIC}S08" ]]; then
  _pass "Remote story branch folded into max → ${R_STORY}"
else
  _fail "Expected ${T6_EPIC}S08 (remote ${T6_EPIC}S07), got: ${R_STORY}"
fi

# TTL-prune protection: an over-TTL reservation whose ID is still on a remote branch must survive.
T6_LEDGER="${WORK}/t6p.tsv"
T6_NOW="$(date +%s)"; T6_STALE=$(( T6_NOW - 100 * 3600 ))   # 100h ago, beyond 72h TTL
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T6_LEDGER"
printf '%sS07\tstory\t%s\n' "$T6_EPIC" "$T6_STALE" >> "$T6_LEDGER"   # on remote → must be kept
printf '%sS99\tstory\t%s\n' "$T6_EPIC" "$T6_STALE" >> "$T6_LEDGER"   # not on remote → pruned

( cd "$T6_WORK" && GAAI_SCAN_REMOTE=1 GAAI_REMOTE=testremote \
  GAAI_BACKLOG_PATH="$T6_EMPTY" GAAI_RESERVATION_LEDGER="$T6_LEDGER" "$ALLOCATOR" epic ) >/dev/null

KEPT_IDS="$(grep -v '^#' "$T6_LEDGER" 2>/dev/null | awk -F'\t' '{print $1}' | sort | tr '\n' ' ' || true)"
if echo "$KEPT_IDS" | grep -q "${T6_EPIC}S07" && ! echo "$KEPT_IDS" | grep -q "${T6_EPIC}S99"; then
  _pass "TTL-prune protection: on-remote ${T6_EPIC}S07 kept, off-remote ${T6_EPIC}S99 pruned (remaining: ${KEPT_IDS})"
else
  _fail "TTL-prune protection broken — remaining: ${KEPT_IDS}"
fi

# ── Test 7: AC5 — word-embedded E<n> branch names do not inflate the epic max ─
echo "Test 7: AC5 — over-match guard (E2E-style branch names ignored)"

T7="${WORK}/t7"; mkdir -p "$T7"
T7_BARE="${WORK}/t7-remote.git"
T7_SEED="${WORK}/t7-seed"
T7_WORK="${WORK}/t7-work"

git init -q --bare "$T7_BARE"
git init -q "$T7_SEED"
(
  cd "$T7_SEED"
  git config user.email t@example.test; git config user.name tester
  git commit -q --allow-empty -m init
  git branch E2E-test-harness          # token E2 followed by a letter → must be ignored
  git branch feature-no-id             # no token at all
  git remote add origin "$T7_BARE"
  git push -q origin --all
) >/dev/null 2>&1
git init -q "$T7_WORK"
( cd "$T7_WORK"; git remote add testremote "$T7_BARE" ) >/dev/null 2>&1

T7_EMPTY="${T7}/active.backlog.yaml"; printf '# empty\n' > "$T7_EMPTY"

R7="$(cd "$T7_WORK" && GAAI_SCAN_REMOTE=1 GAAI_REMOTE=testremote \
  GAAI_BACKLOG_PATH="$T7_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t7.tsv" "$ALLOCATOR" epic)"
if [[ "$R7" == "E1" ]]; then
  _pass "E2E-test-harness ignored (empty backlog/ledger → ${R7}, not E2/E3)"
else
  _fail "Expected E1 (E2E-* must not seed the epic max), got: ${R7}"
fi

# ── Test 8: AC6 — git-CAS concurrency (hermetic local bare remote) ───────────
echo "Test 8: AC6 — git-CAS concurrent reservations get distinct IDs"

T8_BARE="${WORK}/t8-remote.git"
T8_SEED="${WORK}/t8-seed"
T8_WORK_A="${WORK}/t8-work-a"
T8_WORK_B="${WORK}/t8-work-b"

git init -q --bare "$T8_BARE"
git init -q "$T8_SEED"
(
  cd "$T8_SEED"
  git config user.email t@example.test
  git config user.name tester
  git commit -q --allow-empty -m init
  git remote add origin "$T8_BARE"
  git push -q origin HEAD
) >/dev/null 2>&1

git clone -q "$T8_BARE" "$T8_WORK_A" >/dev/null 2>&1
git clone -q "$T8_BARE" "$T8_WORK_B" >/dev/null 2>&1

T8_EMPTY="${WORK}/t8-empty.yaml"
printf '# empty\n' > "$T8_EMPTY"
T8_OUT_A="${WORK}/t8a.txt"
T8_OUT_B="${WORK}/t8b.txt"

(
  cd "$T8_WORK_A"
  GAAI_SCAN_REMOTE=1 GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="$T8_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t8a.tsv" \
    "$ALLOCATOR" epic > "$T8_OUT_A" 2>/dev/null
) &
PID_A=$!

(
  cd "$T8_WORK_B"
  GAAI_SCAN_REMOTE=1 GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="$T8_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t8b.tsv" \
    "$ALLOCATOR" epic > "$T8_OUT_B" 2>/dev/null
) &
PID_B=$!

wait "$PID_A" "$PID_B" 2>/dev/null || true

T8_ID_A="$(cat "$T8_OUT_A" 2>/dev/null || echo "")"
T8_ID_B="$(cat "$T8_OUT_B" 2>/dev/null || echo "")"

if [[ -n "$T8_ID_A" && -n "$T8_ID_B" && "$T8_ID_A" != "$T8_ID_B" ]]; then
  _pass "CAS concurrent: A=${T8_ID_A}, B=${T8_ID_B} (distinct)"
else
  _fail "CAS concurrent: A='${T8_ID_A}' B='${T8_ID_B}' — expected distinct non-empty IDs"
fi

# Verify refs/gaai/reservations was pushed to the bare remote after both runs.
T8_CAS_ON_REMOTE="$(cd "$T8_WORK_A" && \
  git ls-remote origin refs/gaai/reservations 2>/dev/null | awk '{print $1}' || echo "")"
if [[ -n "$T8_CAS_ON_REMOTE" ]]; then
  _pass "refs/gaai/reservations present on remote (OID=${T8_CAS_ON_REMOTE:0:12}...)"
else
  _fail "refs/gaai/reservations absent from remote after two CAS allocations"
fi

# ── Test 9: T-DEC-1 — dec mode basic allocation ──────────────────────────────
echo "Test 9: T-DEC-1 — dec mode basic allocation"

T9="${WORK}/t9"
mkdir -p "$T9"
T9_DECISIONS="${T9}/decisions"
mkdir -p "$T9_DECISIONS"
T9_LEDGER="${WORK}/t9.tsv"

# decisions dir has DEC-5.md and DEC-12.md (max = 12) → expect DEC-13
touch "${T9_DECISIONS}/DEC-5.md" "${T9_DECISIONS}/DEC-12.md"

T9_ID="$(GAAI_DECISIONS_PATH="$T9_DECISIONS" GAAI_RESERVATION_LEDGER="$T9_LEDGER" "$ALLOCATOR" dec)"

if [[ "$T9_ID" == "DEC-13" ]]; then
  _pass "dec mode: DEC-5.md + DEC-12.md in decisions dir → ${T9_ID}"
else
  _fail "dec mode: expected DEC-13 (max file = 12), got: ${T9_ID}"
fi

# Second call must return DEC-14 (ledger sees DEC-13)
T9_ID2="$(GAAI_DECISIONS_PATH="$T9_DECISIONS" GAAI_RESERVATION_LEDGER="$T9_LEDGER" "$ALLOCATOR" dec)"
if [[ "$T9_ID2" == "DEC-14" ]]; then
  _pass "dec mode sequential: second call → ${T9_ID2}"
else
  _fail "dec mode sequential: expected DEC-14, got: ${T9_ID2}"
fi

# Verify ledger contains dec-kind rows
if grep -q $'\tdec\t' "$T9_LEDGER" 2>/dev/null; then
  _pass "dec mode: ledger contains 'dec' kind rows"
else
  _fail "dec mode: ledger missing 'dec' kind rows"
fi

# ── Test 10: T-DEC-2 — dec mode concurrency (AC2) ────────────────────────────
echo "Test 10: T-DEC-2 — dec mode concurrent allocations (5 parallel)"

T10_DECISIONS="${WORK}/t10-decisions"
mkdir -p "$T10_DECISIONS"
T10_LEDGER="${WORK}/t10.tsv"
T10_OUT="${WORK}/t10-out"
mkdir -p "$T10_OUT"

PIDS=()
for i in $(seq 1 5); do
  GAAI_DECISIONS_PATH="$T10_DECISIONS" \
  GAAI_RESERVATION_LEDGER="$T10_LEDGER" \
    "$ALLOCATOR" dec > "${T10_OUT}/${i}.txt" 2>/dev/null &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

T10_RESULTS=()
for i in $(seq 1 5); do
  val="$(cat "${T10_OUT}/${i}.txt" 2>/dev/null || echo "")"
  T10_RESULTS+=("$val")
done

T10_UNIQUE="$(printf '%s\n' "${T10_RESULTS[@]}" | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
T10_TOTAL="$(printf '%s\n' "${T10_RESULTS[@]}" | grep -v '^$' | wc -l | tr -d ' ')"

if [[ "$T10_TOTAL" -eq 5 && "$T10_UNIQUE" -eq 5 ]]; then
  _pass "5 concurrent dec allocations → 5 distinct IDs ($(printf '%s\n' "${T10_RESULTS[@]}" | sort | tr '\n' ' '))"
else
  _fail "Expected 5 unique dec IDs, got total=${T10_TOTAL} unique=${T10_UNIQUE}: $(printf '%s\n' "${T10_RESULTS[@]}" | sort | tr '\n' ' ')"
fi

# ── Test 11: T-DEC-3 — kind-branched landed-prune (AC3) ──────────────────────
echo "Test 11: T-DEC-3 — kind-branched landed-prune (dec prune vs epic/story unchanged)"

T11="${WORK}/t11"
mkdir -p "$T11"
T11_DECISIONS="${T11}/decisions"
mkdir -p "$T11_DECISIONS"
T11_BACKLOG="${T11}/active.backlog.yaml"

# Backlog: E50 is landed
cat > "$T11_BACKLOG" <<'YAML'
- id: E50
  epic: E50
  title: Landed epic
  status: done
YAML

T11_LEDGER="${WORK}/t11.tsv"
NOW_T11="$(date +%s)"

# Create decisions dir with DEC-20.md (landed) and NOT DEC-30.md (not landed)
touch "${T11_DECISIONS}/DEC-20.md"

# Ledger entries:
#   DEC-20  dec   → file ${T11_DECISIONS}/DEC-20.md exists → should be pruned
#   DEC-30  dec   → file ${T11_DECISIONS}/DEC-30.md absent → should be KEPT
#   E50     epic  → in backlog → should be pruned (via backlog grep, not dec-file check)
#   E60     epic  → not in backlog → should be KEPT
# Key AC3 invariant: E50 is NOT pruned by the dec-file check even though DEC-20.md exists;
# it is pruned only because it appears in the backlog (kind-branch, not OR extension).
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T11_LEDGER"
printf 'DEC-20\tdec\t%s\n'  "$NOW_T11" >> "$T11_LEDGER"
printf 'DEC-30\tdec\t%s\n'  "$NOW_T11" >> "$T11_LEDGER"
printf 'E50\tepic\t%s\n'    "$NOW_T11" >> "$T11_LEDGER"
printf 'E60\tepic\t%s\n'    "$NOW_T11" >> "$T11_LEDGER"

# Run an epic allocation (triggers the prune loop over all entry kinds)
RESULT_T11="$(GAAI_BACKLOG_PATH="$T11_BACKLOG" GAAI_DECISIONS_PATH="$T11_DECISIONS" \
  GAAI_RESERVATION_LEDGER="$T11_LEDGER" "$ALLOCATOR" epic)"

# Check ledger state after pruning
T11_REMAINING="$(grep -v '^#' "$T11_LEDGER" 2>/dev/null | awk -F'\t' '{print $1}' | sort | tr '\n' ' ' || true)"

# DEC-20 (dec + file exists) → pruned
if echo "$T11_REMAINING" | grep -q "DEC-20"; then
  _fail "T-DEC-3: DEC-20 (dec + file exists) should be pruned but is still in ledger (remaining: ${T11_REMAINING})"
else
  _pass "T-DEC-3: DEC-20 (dec + file exists) correctly pruned"
fi

# DEC-30 (dec + file absent) → kept
if echo "$T11_REMAINING" | grep -q "DEC-30"; then
  _pass "T-DEC-3: DEC-30 (dec + file absent) correctly kept"
else
  _fail "T-DEC-3: DEC-30 (dec + file absent) should be kept but was pruned (remaining: ${T11_REMAINING})"
fi

# E50 (epic + in backlog) → pruned via backlog grep, NOT via dec-file check
if echo "$T11_REMAINING" | grep -qE '\bE50\b'; then
  _fail "T-DEC-3: E50 (epic + in backlog) should be pruned but is still in ledger (remaining: ${T11_REMAINING})"
else
  _pass "T-DEC-3: E50 (epic + in backlog) correctly pruned via backlog check"
fi

# E60 (epic + not in backlog) → kept
if echo "$T11_REMAINING" | grep -qE '\bE60\b'; then
  _pass "T-DEC-3: E60 (epic + not in backlog) correctly kept"
else
  _fail "T-DEC-3: E60 (epic + not in backlog) should be kept but was pruned (remaining: ${T11_REMAINING})"
fi

# ── Test 12: T-DEC-4 — CAS-retry recompute via _cas_max_dec under forced NFF ─
echo "Test 12: T-DEC-4 — CAS-retry recompute uses _cas_max_dec under forced NFF"

T12_BARE="${WORK}/t12-remote.git"
T12_SEED="${WORK}/t12-seed"
T12_WORK_A="${WORK}/t12-work-a"
T12_WORK_B="${WORK}/t12-work-b"
T12_DECISIONS_A="${WORK}/t12-decisions-a"
T12_DECISIONS_B="${WORK}/t12-decisions-b"
mkdir -p "$T12_DECISIONS_A" "$T12_DECISIONS_B"

# Initialise a bare remote and a seed repo
git init -q --bare "$T12_BARE"
git init -q "$T12_SEED"
(
  cd "$T12_SEED"
  git config user.email t@example.test
  git config user.name tester
  git commit -q --allow-empty -m init
  git remote add origin "$T12_BARE"
  git push -q origin HEAD
) >/dev/null 2>&1

# Pre-load refs/gaai/reservations on the bare remote with a dec entry at DEC-100.
# Both workers will fetch this and see DEC-100 as the CAS max before their own push.
# This verifies _cas_max_dec is used: if _cas_max_epic or _cas_max_story were mistakenly
# called instead (wrong kind match), they'd return 0 and both workers would return DEC-1,
# producing a collision and failing the distinct-ID assertion below.
T12_PRELOAD="${WORK}/t12-preload"
git init -q "$T12_PRELOAD"
(
  cd "$T12_PRELOAD"
  git config user.email t@example.test
  git config user.name tester
  git remote add origin "$T12_BARE"
  # Build a CAS blob/tree/commit with a dec entry at DEC-100
  _pre_blob="$(printf 'DEC-100\tdec\t1000000000\n' | git hash-object -w --stdin 2>/dev/null)"
  _pre_tree="$(printf '100644 blob %s\treservations.tsv\n' "$_pre_blob" | git mktree 2>/dev/null)"
  _pre_commit="$(
    GIT_AUTHOR_NAME=gaai GIT_AUTHOR_EMAIL=gaai@localhost \
    GIT_COMMITTER_NAME=gaai GIT_COMMITTER_EMAIL=gaai@localhost \
    GIT_AUTHOR_DATE="1000000000 +0000" GIT_COMMITTER_DATE="1000000000 +0000" \
    git commit-tree -m "pre-load DEC-100" "$_pre_tree" 2>/dev/null
  )"
  git update-ref refs/gaai/reservations "$_pre_commit" 2>/dev/null
  git push -q --force origin refs/gaai/reservations
) >/dev/null 2>&1

git clone -q "$T12_BARE" "$T12_WORK_A" >/dev/null 2>&1
git clone -q "$T12_BARE" "$T12_WORK_B" >/dev/null 2>&1

T12_EMPTY="${WORK}/t12-empty.yaml"
printf '# empty\n' > "$T12_EMPTY"
T12_OUT_A="${WORK}/t12a.txt"
T12_OUT_B="${WORK}/t12b.txt"

(
  cd "$T12_WORK_A"
  GAAI_SCAN_REMOTE=1 GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="$T12_EMPTY" GAAI_DECISIONS_PATH="$T12_DECISIONS_A" \
  GAAI_RESERVATION_LEDGER="${WORK}/t12a.tsv" \
    "$ALLOCATOR" dec > "$T12_OUT_A" 2>/dev/null
) &
T12_PID_A=$!

(
  cd "$T12_WORK_B"
  GAAI_SCAN_REMOTE=1 GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="$T12_EMPTY" GAAI_DECISIONS_PATH="$T12_DECISIONS_B" \
  GAAI_RESERVATION_LEDGER="${WORK}/t12b.tsv" \
    "$ALLOCATOR" dec > "$T12_OUT_B" 2>/dev/null
) &
T12_PID_B=$!

wait "$T12_PID_A" "$T12_PID_B" 2>/dev/null || true

T12_ID_A="$(cat "$T12_OUT_A" 2>/dev/null || echo "")"
T12_ID_B="$(cat "$T12_OUT_B" 2>/dev/null || echo "")"

# Both IDs must be non-empty, distinct, and > DEC-100 (proving _cas_max_dec was used)
T12_NUM_A="${T12_ID_A#DEC-}"
T12_NUM_B="${T12_ID_B#DEC-}"

if [[ -n "$T12_ID_A" && -n "$T12_ID_B" && "$T12_ID_A" != "$T12_ID_B" ]]; then
  _pass "CAS dec concurrent: A=${T12_ID_A}, B=${T12_ID_B} (distinct)"
else
  _fail "CAS dec concurrent: A='${T12_ID_A}' B='${T12_ID_B}' — expected distinct non-empty IDs"
fi

# Both must be > 100 (the pre-loaded DEC-100 was in the CAS ref — _cas_max_dec must have read it)
if [[ "$T12_NUM_A" =~ ^[0-9]+$ && "$T12_NUM_B" =~ ^[0-9]+$ ]] \
    && (( T12_NUM_A > 100 )) && (( T12_NUM_B > 100 )); then
  _pass "CAS dec retry used _cas_max_dec: A=${T12_ID_A} > DEC-100, B=${T12_ID_B} > DEC-100"
else
  _fail "CAS dec retry did NOT use _cas_max_dec: A=${T12_ID_A} B=${T12_ID_B} — expected both > DEC-100"
fi

# Verify refs/gaai/reservations on the bare remote contains dec entries
T12_CAS_ON_REMOTE="$(cd "$T12_WORK_A" && \
  git ls-remote origin refs/gaai/reservations 2>/dev/null | awk '{print $1}' || echo "")"
if [[ -n "$T12_CAS_ON_REMOTE" ]]; then
  _pass "refs/gaai/reservations present on remote after dec CAS allocations (OID=${T12_CAS_ON_REMOTE:0:12}...)"
else
  _fail "refs/gaai/reservations absent from remote after dec CAS allocations"
fi

# ── Test 13: AC1 — story-only ledger rows raise the epic max ─────────────────
echo "Test 13: AC1 — ledger-only story rows (no epic row) raise the epic max"

T13="${WORK}/t13"
mkdir -p "$T13"
T13_EMPTY="${T13}/active.backlog.yaml"; _empty_backlog "$T13_EMPTY"
T13_LEDGER="${WORK}/t13.tsv"
T13_EPIC="E70"
NOW_T13="$(date +%s)"

# A run of story rows under the test epic prefix is reserved, with no epic row for it at all.
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T13_LEDGER"
for n in 01 02 03 04 05 06 07; do
  printf '%sS%s\tstory\t%s\n' "$T13_EPIC" "$n" "$NOW_T13" >> "$T13_LEDGER"
done

RESULT_T13="$(GAAI_BACKLOG_PATH="$T13_EMPTY" GAAI_RESERVATION_LEDGER="$T13_LEDGER" "$ALLOCATOR" epic)"

if [[ "$RESULT_T13" == "E71" ]]; then
  _pass "Story-only reservations for ${T13_EPIC} fold into epic max → ${RESULT_T13}"
else
  _fail "Expected E71 (epic max must reflect ${T13_EPIC}'s story rows), got: ${RESULT_T13}"
fi

# Boundary: a single story row alone (not a run) must still raise the max.
T13B_LEDGER="${WORK}/t13b.tsv"
T13B_EPIC="E80"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T13B_LEDGER"
printf '%sS01\tstory\t%s\n' "$T13B_EPIC" "$NOW_T13" >> "$T13B_LEDGER"

RESULT_T13B="$(GAAI_BACKLOG_PATH="$T13_EMPTY" GAAI_RESERVATION_LEDGER="$T13B_LEDGER" "$ALLOCATOR" epic)"
if [[ "$RESULT_T13B" == "E81" ]]; then
  _pass "Single story row for ${T13B_EPIC} still raises epic max → ${RESULT_T13B}"
else
  _fail "Expected E81 (single story row must raise epic max), got: ${RESULT_T13B}"
fi

# ── Test 14: AC2 — CAS-only story rows (no epic row) raise the epic max ──────
echo "Test 14: AC2 — CAS-only story rows (hermetic local bare remote) raise the epic max"

T14_BARE="${WORK}/t14-remote.git"
T14_PRELOAD="${WORK}/t14-preload"
T14_WORK="${WORK}/t14-work"
T14_EPIC="E90"

git init -q --bare "$T14_BARE"
git init -q "$T14_PRELOAD"
(
  cd "$T14_PRELOAD"
  git config user.email t@example.test
  git config user.name tester
  git remote add origin "$T14_BARE"
  # Preload refs/gaai/reservations with story-only rows for T14_EPIC (no epic row).
  _pre_blob="$(printf '%sS01\tstory\t1000000000\n%sS05\tstory\t1000000000\n' "$T14_EPIC" "$T14_EPIC" \
    | git hash-object -w --stdin 2>/dev/null)"
  _pre_tree="$(printf '100644 blob %s\treservations.tsv\n' "$_pre_blob" | git mktree 2>/dev/null)"
  _pre_commit="$(
    GIT_AUTHOR_NAME=gaai GIT_AUTHOR_EMAIL=gaai@localhost \
    GIT_COMMITTER_NAME=gaai GIT_COMMITTER_EMAIL=gaai@localhost \
    GIT_AUTHOR_DATE="1000000000 +0000" GIT_COMMITTER_DATE="1000000000 +0000" \
    git commit-tree -m "pre-load story-only rows" "$_pre_tree" 2>/dev/null
  )"
  git update-ref refs/gaai/reservations "$_pre_commit" 2>/dev/null
  git push -q --force origin refs/gaai/reservations
) >/dev/null 2>&1

git clone -q "$T14_BARE" "$T14_WORK" >/dev/null 2>&1
T14_EMPTY="${WORK}/t14-empty.yaml"; _empty_backlog "$T14_EMPTY"

RESULT_T14="$(cd "$T14_WORK" && GAAI_SCAN_REMOTE=1 GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="$T14_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t14.tsv" "$ALLOCATOR" epic)"

if [[ "$RESULT_T14" == "E91" ]]; then
  _pass "CAS-only story rows for ${T14_EPIC} fold into epic max → ${RESULT_T14}"
else
  _fail "Expected E91 (CAS epic max must reflect ${T14_EPIC}'s story rows), got: ${RESULT_T14}"
fi

# ── Test 15: AC3 — mixed epic + story rows, max over either kind ─────────────
echo "Test 15: AC3 — mixed epic-kind and story-kind rows, max wins regardless of kind"

T15="${WORK}/t15"
mkdir -p "$T15"
T15_EMPTY="${T15}/active.backlog.yaml"; _empty_backlog "$T15_EMPTY"
NOW_T15="$(date +%s)"
T15_LOW_EPIC="E10"
T15_HIGH_EPIC="E15"

# Case A: story row's epic number (high) exceeds the epic-kind row's number (low).
T15A_LEDGER="${WORK}/t15a.tsv"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T15A_LEDGER"
printf '%s\tepic\t%s\n'   "$T15_LOW_EPIC"  "$NOW_T15" >> "$T15A_LEDGER"
printf '%sS02\tstory\t%s\n' "$T15_HIGH_EPIC" "$NOW_T15" >> "$T15A_LEDGER"

RESULT_T15A="$(GAAI_BACKLOG_PATH="$T15_EMPTY" GAAI_RESERVATION_LEDGER="$T15A_LEDGER" "$ALLOCATOR" epic)"
if [[ "$RESULT_T15A" == "E16" ]]; then
  _pass "Story row for ${T15_HIGH_EPIC} outranks epic row ${T15_LOW_EPIC} → ${RESULT_T15A}"
else
  _fail "Expected E16 (story row's epic number must win), got: ${RESULT_T15A}"
fi

# Case B: reversed — the epic-kind row's own number (high) still wins over a lower story row.
T15B_LEDGER="${WORK}/t15b.tsv"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T15B_LEDGER"
printf '%s\tepic\t%s\n'   "$T15_HIGH_EPIC" "$NOW_T15" >> "$T15B_LEDGER"
printf '%sS02\tstory\t%s\n' "$T15_LOW_EPIC"  "$NOW_T15" >> "$T15B_LEDGER"

RESULT_T15B="$(GAAI_BACKLOG_PATH="$T15_EMPTY" GAAI_RESERVATION_LEDGER="$T15B_LEDGER" "$ALLOCATOR" epic)"
if [[ "$RESULT_T15B" == "E16" ]]; then
  _pass "Epic row ${T15_HIGH_EPIC} still wins over lower story row for ${T15_LOW_EPIC} → ${RESULT_T15B}"
else
  _fail "Expected E16 (epic row's own number must still win), got: ${RESULT_T15B}"
fi

# ── Test 16: AC4 — no story ID of the returned epic exists in any source ─────
echo "Test 16: AC4 — returned epic exceeds the max across all four sources at once"

T16="${WORK}/t16"
mkdir -p "$T16"
T16_BARE="${WORK}/t16-remote.git"
T16_SEED="${WORK}/t16-seed"
T16_WORK="${WORK}/t16-work"
T16_BACKLOG_EPIC="E30"
T16_REMOTE_EPIC="E40"
T16_LEDGER_EPIC="E50"
T16_CAS_EPIC="E60"

# Four different epic numbers, one per source, all via story-shaped rows/tokens where applicable:
#   backlog:       T16_BACKLOG_EPIC (story-shaped token)
#   remote branch: T16_REMOTE_EPIC
#   ledger:        T16_LEDGER_EPIC (story row)
#   CAS:           T16_CAS_EPIC (story row, highest)
cat > "${T16}/active.backlog.yaml" <<YAML
- id: ${T16_BACKLOG_EPIC}S01
  epic: ${T16_BACKLOG_EPIC}
  title: Backlog story token
  status: draft
YAML

git init -q --bare "$T16_BARE"
git init -q "$T16_SEED"
(
  cd "$T16_SEED"
  git config user.email t@example.test; git config user.name tester
  git commit -q --allow-empty -m init
  git branch "story/${T16_REMOTE_EPIC}S01"
  git remote add origin "$T16_BARE"
  git push -q origin --all
) >/dev/null 2>&1
git init -q "$T16_WORK"
( cd "$T16_WORK"; git remote add testremote "$T16_BARE" ) >/dev/null 2>&1

T16_LEDGER="${WORK}/t16.tsv"
NOW_T16="$(date +%s)"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T16_LEDGER"
printf '%sS01\tstory\t%s\n' "$T16_LEDGER_EPIC" "$NOW_T16" >> "$T16_LEDGER"

# Preload CAS with the highest story-shaped row on the same bare remote.
(
  cd "$T16_SEED"
  _pre_blob="$(printf '%sS01\tstory\t1000000000\n' "$T16_CAS_EPIC" | git hash-object -w --stdin 2>/dev/null)"
  _pre_tree="$(printf '100644 blob %s\treservations.tsv\n' "$_pre_blob" | git mktree 2>/dev/null)"
  _pre_commit="$(
    GIT_AUTHOR_NAME=gaai GIT_AUTHOR_EMAIL=gaai@localhost \
    GIT_COMMITTER_NAME=gaai GIT_COMMITTER_EMAIL=gaai@localhost \
    GIT_AUTHOR_DATE="1000000000 +0000" GIT_COMMITTER_DATE="1000000000 +0000" \
    git commit-tree -m "pre-load highest story-shaped row" "$_pre_tree" 2>/dev/null
  )"
  git update-ref refs/gaai/reservations "$_pre_commit" 2>/dev/null
  git push -q --force origin refs/gaai/reservations
) >/dev/null 2>&1

RESULT_T16="$(cd "$T16_WORK" && GAAI_SCAN_REMOTE=1 GAAI_REMOTE=testremote GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="${T16}/active.backlog.yaml" GAAI_RESERVATION_LEDGER="$T16_LEDGER" "$ALLOCATOR" epic)"

# Highest of the four sources is the CAS epic number → expect that +1.
if [[ "$RESULT_T16" == "E61" ]]; then
  _pass "Epic max correctly reflects the highest of all four sources (CAS ${T16_CAS_EPIC}) → ${RESULT_T16}"
else
  _fail "Expected E61 (max across backlog=30/remote=40/ledger=50/CAS=60), got: ${RESULT_T16}"
fi

# ── Test 17: AC5 — malformed ledger row: warn, keep max, survive ─────────────
echo "Test 17: AC5 — malformed local-ledger row is warned about, ignored for max, and kept"

T17="${WORK}/t17"
mkdir -p "$T17"
T17_EMPTY="${T17}/active.backlog.yaml"; _empty_backlog "$T17_EMPTY"
T17_LEDGER="${WORK}/t17.tsv"
NOW_T17="$(date +%s)"

# Well-formed E5 epic row + a kind-less malformed row (id only, no tabs) — kind-less so it is
# invisible to every $2=="epic"/$2=="story" awk pattern, making "does not lower the max" a real
# assertion rather than a tautology (per the plan's Edge Cases note).
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T17_LEDGER"
printf 'E5\tepic\t%s\n' "$NOW_T17" >> "$T17_LEDGER"
printf 'garbage-malformed-row\n' >> "$T17_LEDGER"

T17_STDERR="${WORK}/t17.stderr"
RESULT_T17="$(GAAI_BACKLOG_PATH="$T17_EMPTY" GAAI_RESERVATION_LEDGER="$T17_LEDGER" "$ALLOCATOR" epic 2>"$T17_STDERR")"

if [[ "$RESULT_T17" == "E6" ]]; then
  _pass "Malformed row did not lower/raise the max → ${RESULT_T17}"
else
  _fail "Expected E6 (malformed row must not affect max=5), got: ${RESULT_T17}"
fi

if grep -q "malformed row in local ledger" "$T17_STDERR" 2>/dev/null; then
  _pass "Warning emitted for malformed local-ledger row"
else
  _fail "Expected 'malformed row in local ledger' warning on stderr, got: $(cat "$T17_STDERR" 2>/dev/null)"
fi

if grep -qF "garbage-malformed-row" "$T17_LEDGER" 2>/dev/null; then
  _pass "Malformed row survives in the ledger (not dropped)"
else
  _fail "Malformed row was dropped from the ledger — should survive per AC5"
fi

# ── Test 18: AC5 — malformed CAS row: warn, keep max, survive ────────────────
echo "Test 18: AC5 — malformed shared-record (CAS) row is warned about, ignored for max, kept"

T18_BARE="${WORK}/t18-remote.git"
T18_PRELOAD="${WORK}/t18-preload"
T18_WORK="${WORK}/t18-work"

git init -q --bare "$T18_BARE"
git init -q "$T18_PRELOAD"
(
  cd "$T18_PRELOAD"
  git config user.email t@example.test
  git config user.name tester
  git remote add origin "$T18_BARE"
  # Preload with a well-formed E5 epic row + a kind-less malformed row (id only, no tabs).
  _pre_blob="$(printf 'E5\tepic\t1000000000\ngarbage-malformed-row\n' | git hash-object -w --stdin 2>/dev/null)"
  _pre_tree="$(printf '100644 blob %s\treservations.tsv\n' "$_pre_blob" | git mktree 2>/dev/null)"
  _pre_commit="$(
    GIT_AUTHOR_NAME=gaai GIT_AUTHOR_EMAIL=gaai@localhost \
    GIT_COMMITTER_NAME=gaai GIT_COMMITTER_EMAIL=gaai@localhost \
    GIT_AUTHOR_DATE="1000000000 +0000" GIT_COMMITTER_DATE="1000000000 +0000" \
    git commit-tree -m "pre-load malformed row" "$_pre_tree" 2>/dev/null
  )"
  git update-ref refs/gaai/reservations "$_pre_commit" 2>/dev/null
  git push -q --force origin refs/gaai/reservations
) >/dev/null 2>&1

git clone -q "$T18_BARE" "$T18_WORK" >/dev/null 2>&1
T18_EMPTY="${WORK}/t18-empty.yaml"; _empty_backlog "$T18_EMPTY"

T18_STDERR="${WORK}/t18.stderr"
RESULT_T18="$(cd "$T18_WORK" && GAAI_SCAN_REMOTE=1 GAAI_RESERVATION_BACKEND=git-cas \
  GAAI_BACKLOG_PATH="$T18_EMPTY" GAAI_RESERVATION_LEDGER="${WORK}/t18.tsv" "$ALLOCATOR" epic 2>"$T18_STDERR")"

if [[ "$RESULT_T18" == "E6" ]]; then
  _pass "Malformed CAS row did not affect the max (well-formed E5 → E6) → ${RESULT_T18}"
else
  _fail "Expected E6 (malformed CAS row must not affect max=5), got: ${RESULT_T18}"
fi

if grep -q "malformed row in shared reservation record" "$T18_STDERR" 2>/dev/null; then
  _pass "Warning emitted for malformed shared-record (CAS) row"
else
  _fail "Expected 'malformed row in shared reservation record' warning on stderr, got: $(cat "$T18_STDERR" 2>/dev/null)"
fi

# Verify the malformed row still appears in the CAS ref content on the bare remote after the run.
T18_CAS_CONTENT="$(cd "$T18_WORK" && git fetch -q origin '+refs/gaai/reservations:refs/gaai/reservations' 2>/dev/null; \
  git show refs/gaai/reservations:reservations.tsv 2>/dev/null || true)"
if printf '%s' "$T18_CAS_CONTENT" | grep -qF "garbage-malformed-row"; then
  _pass "Malformed row survives in the shared CAS record (not dropped)"
else
  _fail "Malformed row missing from the CAS record after the run — should survive per AC5"
fi

# ── Test 19: AC6 — story-mode regression + malformed-row inertness ───────────
echo "Test 19: AC6 — story-mode allocation under an existing epic is unaffected"

T19="${WORK}/t19"
mkdir -p "$T19"
T19_EMPTY="${T19}/active.backlog.yaml"; _empty_backlog "$T19_EMPTY"
T19_LEDGER="${WORK}/t19.tsv"
T19_EPIC="E99"

STORY_T19_A="$(GAAI_BACKLOG_PATH="$T19_EMPTY" GAAI_RESERVATION_LEDGER="$T19_LEDGER" "$ALLOCATOR" story "$T19_EPIC")"
STORY_T19_B="$(GAAI_BACKLOG_PATH="$T19_EMPTY" GAAI_RESERVATION_LEDGER="$T19_LEDGER" "$ALLOCATOR" story "$T19_EPIC")"

if [[ "$STORY_T19_A" == "${T19_EPIC}S01" && "$STORY_T19_B" == "${T19_EPIC}S02" ]]; then
  _pass "Story-mode sequence unaffected: A=${STORY_T19_A}, B=${STORY_T19_B}"
else
  _fail "Expected ${T19_EPIC}S01/${T19_EPIC}S02, got: A=${STORY_T19_A} B=${STORY_T19_B}"
fi

# A malformed row already in the ledger (from an unrelated prior allocation) must not break,
# hang, or misallocate a story-mode allocation — it is inert for story-mode exactly as for epic.
printf 'unrelated-garbage-row\n' >> "$T19_LEDGER"
STORY_T19_C="$(GAAI_BACKLOG_PATH="$T19_EMPTY" GAAI_RESERVATION_LEDGER="$T19_LEDGER" "$ALLOCATOR" story "$T19_EPIC" 2>/dev/null)"

if [[ "$STORY_T19_C" == "${T19_EPIC}S03" ]]; then
  _pass "Story-mode allocation inert to a malformed ledger row → ${STORY_T19_C}"
else
  _fail "Expected ${T19_EPIC}S03 (malformed row must not break story-mode), got: ${STORY_T19_C}"
fi

# ── Test 20: AC1 — shared ledger across worktrees, per-worktree backlog/decisions ────
echo "Test 20: AC1 — shared ledger across worktrees, per-worktree backlog/decisions (overrides unset)"

T20_HOME="${WORK}/t20-home"; mkdir -p "$T20_HOME"
T20_REPO="${WORK}/t20-repo"
git init -q "$T20_REPO"
( cd "$T20_REPO"; git config user.email t@example.test; git config user.name tester; git commit -q --allow-empty -m init )

mkdir -p "${T20_REPO}/.gaai/project/contexts/backlog"
cat > "${T20_REPO}/.gaai/project/contexts/backlog/active.backlog.yaml" <<'YAML'
- id: E5
  epic: E5
  title: Main checkout epic
  status: done
YAML

T20_WT="${WORK}/t20-wt"
( cd "$T20_REPO" && git worktree add -q -b t20-wt-branch "$T20_WT" ) >/dev/null 2>&1
mkdir -p "${T20_WT}/.gaai/project/contexts/backlog"
cat > "${T20_WT}/.gaai/project/contexts/backlog/active.backlog.yaml" <<'YAML'
- id: E2
  epic: E2
  title: Worktree epic (lower than main checkout — must not leak across worktrees)
  status: done
YAML

ID_20A="$(
  cd "$T20_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T20_HOME"; "$ALLOCATOR" epic
)"
ID_20B="$(
  cd "$T20_WT"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T20_HOME"; "$ALLOCATOR" epic
)"

T20_LEDGER_COUNT="$(find "${T20_HOME}/.gaai/reservations" -maxdepth 1 -name '*.tsv' 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$ID_20A" == "E6" && "$ID_20B" == "E7" && "$T20_LEDGER_COUNT" -eq 1 ]]; then
  _pass "Shared ledger across worktrees: main=${ID_20A} (own backlog max E5), worktree=${ID_20B} (sequential, not repeated), exactly 1 ledger file"
else
  _fail "Expected main=E6 worktree=E7 with 1 ledger file; got main=${ID_20A} worktree=${ID_20B} ledger_count=${T20_LEDGER_COUNT}"
fi

# ── Test 21: AC2 — cross-worktree sequential + concurrent uniqueness, shared lock ────
echo "Test 21: AC2 — cross-worktree sequential + concurrent uniqueness (shared lock)"

T21_REPO="${WORK}/t21-repo"
git init -q "$T21_REPO"
( cd "$T21_REPO"; git config user.email t@example.test; git config user.name tester; git commit -q --allow-empty -m init )
mkdir -p "${T21_REPO}/.gaai/project/contexts/backlog"
_empty_backlog "${T21_REPO}/.gaai/project/contexts/backlog/active.backlog.yaml"

T21_WT_A="${WORK}/t21-wt-a"
T21_WT_B="${WORK}/t21-wt-b"
( cd "$T21_REPO" && git worktree add -q -b t21-wt-a-branch "$T21_WT_A" ) >/dev/null 2>&1
( cd "$T21_REPO" && git worktree add -q -b t21-wt-b-branch "$T21_WT_B" ) >/dev/null 2>&1
mkdir -p "${T21_WT_A}/.gaai/project/contexts/backlog" "${T21_WT_B}/.gaai/project/contexts/backlog"
_empty_backlog "${T21_WT_A}/.gaai/project/contexts/backlog/active.backlog.yaml"
_empty_backlog "${T21_WT_B}/.gaai/project/contexts/backlog/active.backlog.yaml"

T21_HOME_SEQ="${WORK}/t21-home-seq"; mkdir -p "$T21_HOME_SEQ"
ID_21A="$(
  cd "$T21_WT_A"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T21_HOME_SEQ"; "$ALLOCATOR" epic
)"
ID_21B="$(
  cd "$T21_WT_B"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T21_HOME_SEQ"; "$ALLOCATOR" epic
)"
ID_21C="$(
  cd "$T21_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T21_HOME_SEQ"; "$ALLOCATOR" epic
)"

if [[ "$ID_21A" != "$ID_21B" && "$ID_21B" != "$ID_21C" && "$ID_21A" != "$ID_21C" ]]; then
  _pass "Sequential cross-worktree: A(wt)=${ID_21A}, B(wt)=${ID_21B}, C(main)=${ID_21C} — all distinct"
else
  _fail "Sequential cross-worktree collision: A=${ID_21A} B=${ID_21B} C=${ID_21C}"
fi

# Concurrent — the test that actually proves the lock moved with the ledger: a lock still keyed
# the old (per-worktree) way would let both writes race independently.
T21_HOME_CONC="${WORK}/t21-home-conc"; mkdir -p "$T21_HOME_CONC"
T21_OUT_A="${WORK}/t21-out-a.txt"
T21_OUT_B="${WORK}/t21-out-b.txt"

(
  cd "$T21_WT_A"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T21_HOME_CONC"; "$ALLOCATOR" epic > "$T21_OUT_A" 2>/dev/null
) &
PID_21A=$!
(
  cd "$T21_WT_B"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T21_HOME_CONC"; "$ALLOCATOR" epic > "$T21_OUT_B" 2>/dev/null
) &
PID_21B=$!
wait "$PID_21A" "$PID_21B" 2>/dev/null || true

CONC_A="$(cat "$T21_OUT_A" 2>/dev/null || echo "")"
CONC_B="$(cat "$T21_OUT_B" 2>/dev/null || echo "")"

if [[ -n "$CONC_A" && -n "$CONC_B" && "$CONC_A" != "$CONC_B" ]]; then
  _pass "Concurrent cross-worktree allocation: A=${CONC_A}, B=${CONC_B} — distinct (lock genuinely shared)"
else
  _fail "Concurrent cross-worktree allocation collided or failed: A='${CONC_A}' B='${CONC_B}'"
fi

# ── Test 22: AC3 — repo isolation across hosts + cwd independence within one worktree ─
echo "Test 22: AC3 — separate repos keep separate ledgers; one worktree is cwd-independent"

T22_HOME="${WORK}/t22-home"; mkdir -p "$T22_HOME"
T22_REPO_A="${WORK}/t22-repo-a"
T22_REPO_B="${WORK}/t22-repo-b"
git init -q "$T22_REPO_A"
git init -q "$T22_REPO_B"
for r in "$T22_REPO_A" "$T22_REPO_B"; do
  ( cd "$r"; git config user.email t@example.test; git config user.name tester; git commit -q --allow-empty -m init )
  mkdir -p "${r}/.gaai/project/contexts/backlog"
  _empty_backlog "${r}/.gaai/project/contexts/backlog/active.backlog.yaml"
done

ID_22A="$(
  cd "$T22_REPO_A"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T22_HOME"; "$ALLOCATOR" epic
)"
ID_22B="$(
  cd "$T22_REPO_B"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T22_HOME"; "$ALLOCATOR" epic
)"

if [[ "$ID_22A" == "E1" && "$ID_22B" == "E1" ]]; then
  _pass "Two unrelated repos on the same host keep separate ledgers: A=${ID_22A}, B=${ID_22B} (both E1)"
else
  _fail "Expected both A and B to be E1 (separate ledgers, fix must not merge repos); got A=${ID_22A} B=${ID_22B}"
fi

mkdir -p "${T22_REPO_A}/sub/dir"
ID_22C="$(
  cd "${T22_REPO_A}/sub/dir"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T22_HOME"; "$ALLOCATOR" epic
)"

if [[ "$ID_22C" == "E2" ]]; then
  _pass "cwd-independent: allocation from a subdirectory sees repo A's prior reservation → ${ID_22C}"
else
  _fail "Expected E2 (subdirectory invocation must derive the same ledger path as repo root), got: ${ID_22C}"
fi

# ── Test 23: AC4 — migration of legacy per-worktree-keyed ledgers ────────────
echo "Test 23: AC4 — migration of legacy per-worktree-keyed ledgers (happy/idempotent/prunable/lost)"

_legacy_hash() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | cut -c1-12
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | cut -c1-12
  else
    printf '%s' "$input" | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | cut -c1-12
  fi
}

T23_HOME="${WORK}/t23-home"; mkdir -p "${T23_HOME}/.gaai/reservations"
T23_REPO="${WORK}/t23-repo"
git init -q "$T23_REPO"
( cd "$T23_REPO"; git config user.email t@example.test; git config user.name tester; git commit -q --allow-empty -m init )
mkdir -p "${T23_REPO}/.gaai/project/contexts/backlog"
_empty_backlog "${T23_REPO}/.gaai/project/contexts/backlog/active.backlog.yaml"

T23_WT="${WORK}/t23-wt"
( cd "$T23_REPO" && git worktree add -q -b t23-wt-branch "$T23_WT" ) >/dev/null 2>&1
mkdir -p "${T23_WT}/.gaai/project/contexts/backlog"
_empty_backlog "${T23_WT}/.gaai/project/contexts/backlog/active.backlog.yaml"

NOW_T23="$(date +%s)"
T23_WT_REALPATH="$(cd "$T23_WT" && pwd -P)"
T23_LEGACY_ID="$(_legacy_hash "$T23_WT_REALPATH")"
T23_LEGACY_LEDGER="${T23_HOME}/.gaai/reservations/${T23_LEGACY_ID}.tsv"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T23_LEGACY_LEDGER"
printf 'E40\tepic\t%s\n' "$NOW_T23" >> "$T23_LEGACY_LEDGER"

# Run from the MAIN checkout (not the worktree whose legacy ledger was seeded) — proves
# migration is driven by the repo's worktree list, not "which worktree ran the command".
ID_23A="$(
  cd "$T23_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T23_HOME"; "$ALLOCATOR" epic
)"

if [[ "$ID_23A" == "E41" ]]; then
  _pass "Legacy ledger (seeded E40) migrated and folded into the max → ${ID_23A}"
else
  _fail "Expected E41 (migrated legacy E40 must raise the max), got: ${ID_23A}"
fi

T23_NEW_LEDGER="$(find "${T23_HOME}/.gaai/reservations" -maxdepth 1 -name '*.tsv' ! -name "${T23_LEGACY_ID}.tsv" | head -1)"
if [[ -n "$T23_NEW_LEDGER" ]] && awk -F'\t' '$1=="E40" && $2=="epic"{f=1} END{exit !f}' "$T23_NEW_LEDGER" 2>/dev/null; then
  _pass "Migrated row physically present in the new common-git-dir-keyed ledger"
else
  _fail "Migrated E40 row not found physically in the new ledger"
fi

# Idempotency: run again — migrated row is not re-added (still exactly one copy).
ID_23B="$(
  cd "$T23_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T23_HOME"; "$ALLOCATOR" epic
)"
T23_E40_COUNT="$(awk -F'\t' '$1=="E40"{c++} END{print c+0}' "$T23_NEW_LEDGER" 2>/dev/null)"
if [[ "$ID_23B" == "E42" && "$T23_E40_COUNT" -eq 1 ]]; then
  _pass "Idempotent second run: sequential allocation → ${ID_23B}; E40 still appears exactly once"
else
  _fail "Expected E42 with E40 appearing once; got ID=${ID_23B} E40_count=${T23_E40_COUNT}"
fi

# Boundary (prunable): worktree directory removed directly (not via `git worktree remove`) —
# still reported by `git worktree list --porcelain` as prunable; its legacy ledger must migrate.
T23_WT_PRUNABLE="${WORK}/t23-wt-prunable"
( cd "$T23_REPO" && git worktree add -q -b t23-wt-prunable-branch "$T23_WT_PRUNABLE" ) >/dev/null 2>&1
T23_PRUNABLE_REALPATH="$(cd "$T23_WT_PRUNABLE" && pwd -P)"
T23_PRUNABLE_LEGACY_ID="$(_legacy_hash "$T23_PRUNABLE_REALPATH")"
T23_PRUNABLE_LEGACY_LEDGER="${T23_HOME}/.gaai/reservations/${T23_PRUNABLE_LEGACY_ID}.tsv"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T23_PRUNABLE_LEGACY_LEDGER"
printf 'E80\tepic\t%s\n' "$NOW_T23" >> "$T23_PRUNABLE_LEGACY_LEDGER"

rm -rf "$T23_WT_PRUNABLE"

T23_PRUNABLE_LISTED="$(cd "$T23_REPO" && git worktree list --porcelain 2>/dev/null | grep -c "^worktree ${T23_PRUNABLE_REALPATH}\$" || true)"
if [[ "$T23_PRUNABLE_LISTED" -ge 1 ]]; then
  _pass "Fixture sanity: git worktree list still reports the prunable worktree"
else
  _fail "Fixture sanity failed: git worktree list no longer reports the removed-but-not-pruned worktree"
fi

ID_23C="$(
  cd "$T23_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T23_HOME"; "$ALLOCATOR" epic
)"
if [[ "$ID_23C" == "E81" ]]; then
  _pass "Prunable worktree's legacy ledger (E80) still migrated → ${ID_23C}"
else
  _fail "Expected E81 (prunable-worktree legacy E80 must still migrate), got: ${ID_23C}"
fi

# Error path (accepted loss, stated not silent): worktree fully removed via
# `git worktree remove --force` no longer appears in the list at all — its legacy ledger is
# NOT migrated, and the run still succeeds without error.
T23_WT_GONE="${WORK}/t23-wt-gone"
( cd "$T23_REPO" && git worktree add -q -b t23-wt-gone-branch "$T23_WT_GONE" ) >/dev/null 2>&1
T23_GONE_REALPATH="$(cd "$T23_WT_GONE" && pwd -P)"
T23_GONE_LEGACY_ID="$(_legacy_hash "$T23_GONE_REALPATH")"
T23_GONE_LEGACY_LEDGER="${T23_HOME}/.gaai/reservations/${T23_GONE_LEGACY_ID}.tsv"
printf '# GAAI ID reservation ledger — do not edit manually\n' > "$T23_GONE_LEGACY_LEDGER"
printf 'E95\tepic\t%s\n' "$NOW_T23" >> "$T23_GONE_LEGACY_LEDGER"

( cd "$T23_REPO" && git worktree remove --force "$T23_WT_GONE" ) >/dev/null 2>&1

ID_23D="$(
  cd "$T23_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T23_HOME"; "$ALLOCATOR" epic
)"
if [[ "$ID_23D" == "E82" ]]; then
  _pass "Fully-removed worktree's legacy ledger (E95) correctly NOT migrated (accepted loss) → ${ID_23D}"
else
  _fail "Expected E82 (E95 from a fully-removed worktree must NOT be migrated — would be E96 if it were), got: ${ID_23D}"
fi

# ── Test 24: AC5 — resolution-failure guard (both directions) ────────────────
echo "Test 24: AC5 — resolution-failure guard (command fails / relative / empty)"

REAL_GIT="$(command -v git)"
T24_REPO="${WORK}/t24-repo"
git init -q "$T24_REPO"
( cd "$T24_REPO"; git config user.email t@example.test; git config user.name tester; git commit -q --allow-empty -m init )

# Shim 1: git rev-parse --git-common-dir FAILS (non-zero, no output); everything else passes through.
T24_HOME1="${WORK}/t24-home1"; mkdir -p "$T24_HOME1"
T24_SHIM1="${WORK}/t24-shim1"; mkdir -p "$T24_SHIM1"
cat > "${T24_SHIM1}/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "rev-parse" && "\$2" == "--git-common-dir" ]]; then
  exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "${T24_SHIM1}/git"

T24_STDERR1="${WORK}/t24-stderr1.txt"
set +e
( cd "$T24_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T24_HOME1"; PATH="${T24_SHIM1}:${PATH}" "$ALLOCATOR" epic ) >/dev/null 2>"$T24_STDERR1"
T24_RC1=$?
set -e

if [[ "$T24_RC1" -ne 0 ]]; then
  _pass "Failing git-common-dir resolution exits non-zero (rc=${T24_RC1})"
else
  _fail "Expected non-zero exit when git-common-dir resolution fails, got rc=0"
fi
if grep -q "cannot resolve the repository's common git directory" "$T24_STDERR1" 2>/dev/null; then
  _pass "Failure message names the resolution step that failed"
else
  _fail "Expected an informative message naming the failed resolution step, got: $(cat "$T24_STDERR1" 2>/dev/null)"
fi
if [[ ! -d "${T24_HOME1}/.gaai/reservations" || -z "$(ls -A "${T24_HOME1}/.gaai/reservations" 2>/dev/null)" ]]; then
  _pass "No ledger file created under the fixture HOME after the failed run"
else
  _fail "A ledger file was created despite the resolution failure: $(ls -A "${T24_HOME1}/.gaai/reservations" 2>/dev/null)"
fi

# Shim 2: git rev-parse --git-common-dir prints a RELATIVE, non-existent path (cd fails).
T24_HOME2="${WORK}/t24-home2"; mkdir -p "$T24_HOME2"
T24_SHIM2="${WORK}/t24-shim2"; mkdir -p "$T24_SHIM2"
cat > "${T24_SHIM2}/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "rev-parse" && "\$2" == "--git-common-dir" ]]; then
  echo "nonexistent-relative-dir-xyz/.git"
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "${T24_SHIM2}/git"

T24_STDERR2="${WORK}/t24-stderr2.txt"
set +e
( cd "$T24_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T24_HOME2"; PATH="${T24_SHIM2}:${PATH}" "$ALLOCATOR" epic ) >/dev/null 2>"$T24_STDERR2"
T24_RC2=$?
set -e

if [[ "$T24_RC2" -ne 0 ]]; then
  _pass "Relative/non-existent git-common-dir result exits non-zero (rc=${T24_RC2})"
else
  _fail "Expected non-zero exit for a relative/non-existent git-common-dir result, got rc=0"
fi
if grep -qE "cannot resolve the repository's common git directory to an absolute path|resolved to a relative or empty value" "$T24_STDERR2" 2>/dev/null; then
  _pass "Failure message names the problem (relative/unresolvable value)"
else
  _fail "Expected a message naming the relative/unresolvable value, got: $(cat "$T24_STDERR2" 2>/dev/null)"
fi
if [[ ! -d "${T24_HOME2}/.gaai/reservations" || -z "$(ls -A "${T24_HOME2}/.gaai/reservations" 2>/dev/null)" ]]; then
  _pass "No ledger file created under the fixture HOME after the relative-path failure"
else
  _fail "A ledger file was created despite the relative-path failure: $(ls -A "${T24_HOME2}/.gaai/reservations" 2>/dev/null)"
fi

# Shim 3: git rev-parse --git-common-dir prints NOTHING (empty result, exit 0).
T24_HOME3="${WORK}/t24-home3"; mkdir -p "$T24_HOME3"
T24_SHIM3="${WORK}/t24-shim3"; mkdir -p "$T24_SHIM3"
cat > "${T24_SHIM3}/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "rev-parse" && "\$2" == "--git-common-dir" ]]; then
  printf ''
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "${T24_SHIM3}/git"

T24_STDERR3="${WORK}/t24-stderr3.txt"
set +e
( cd "$T24_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T24_HOME3"; PATH="${T24_SHIM3}:${PATH}" "$ALLOCATOR" epic ) >/dev/null 2>"$T24_STDERR3"
T24_RC3=$?
set -e

if [[ "$T24_RC3" -ne 0 ]]; then
  _pass "Empty git-common-dir result exits non-zero (rc=${T24_RC3})"
else
  _fail "Expected non-zero exit for an empty git-common-dir result, got rc=0"
fi
if grep -q "resolved to an empty value" "$T24_STDERR3" 2>/dev/null; then
  _pass "Failure message names the empty-value problem"
else
  _fail "Expected a message naming the empty-value problem, got: $(cat "$T24_STDERR3" 2>/dev/null)"
fi
if [[ ! -d "${T24_HOME3}/.gaai/reservations" || -z "$(ls -A "${T24_HOME3}/.gaai/reservations" 2>/dev/null)" ]]; then
  _pass "No ledger file created under the fixture HOME after the empty-value failure"
else
  _fail "A ledger file was created despite the empty-value failure: $(ls -A "${T24_HOME3}/.gaai/reservations" 2>/dev/null)"
fi

# ── Test 25: AC6 — header documents the actual cross-worktree mechanism ──────
echo "Test 25: AC6 — header documents the actual cross-worktree mechanism"

if grep -q "keyed by a 12-char hash of the repo root path" "$ALLOCATOR" 2>/dev/null; then
  _fail "Header still contains the old inaccurate phrase ('keyed by a 12-char hash of the repo root path')"
else
  _pass "Old inaccurate header phrase is gone"
fi

if grep -qi "git-common-dir\|common git directory" "$ALLOCATOR" 2>/dev/null; then
  _pass "Header references the common-git-directory mechanism"
else
  _fail "Header does not mention the common-git-directory mechanism"
fi

if grep -qi "migrat" "$ALLOCATOR" 2>/dev/null; then
  _pass "Header documents the migration of legacy per-worktree-keyed reservations"
else
  _fail "Header does not mention migration of legacy reservations"
fi

# ── Test 26: archived story IDs are never re-issued ──────────────────────────
# Regression: the story max used to read active.backlog.yaml alone, so once every story of an epic
# was archived to done/*.yaml the allocator handed out that epic's first story ID again.
echo "Test 26: archived-only story IDs are skipped (active + blocked + done/*.yaml)"

T26="${WORK}/t26 backlog dir"            # space in the path: each backlog file must stay one argument
mkdir -p "${T26}/done"
T26_EPIC="E77"                           # built from variables: no literal story-ID pattern in source
T26_OTHER="E3"
T26_ACTIVE="${T26}/active.backlog.yaml"

# _story_rows <epic> <status> <nn>... — print one backlog row per story number.
_story_rows() {
  local epic="$1" status="$2"; shift 2
  local nn
  for nn in "$@"; do
    printf -- '- id: %sS%s\n  epic: %s\n  status: %s\n' "$epic" "$nn" "$epic" "$status"
  done
}

# Active backlog holds another epic's row only; the target epic's done stories S01-S04 are archived.
_story_rows "$T26_OTHER" refined 01 > "$T26_ACTIVE"
_story_rows "$T26_EPIC" done 01 02 03 04 > "${T26}/done/archived-2000-01-01.yaml"

R26A="$(GAAI_BACKLOG_PATH="$T26_ACTIVE" GAAI_RESERVATION_LEDGER="${WORK}/t26a.tsv" "$ALLOCATOR" story "$T26_EPIC")"
if [[ "$R26A" == "${T26_EPIC}S05" ]]; then
  _pass "Archived ${T26_EPIC}S01-S04 skipped (active has none of them) → ${R26A}"
else
  _fail "Expected ${T26_EPIC}S05 (S01-S04 archived in done/), got: ${R26A}"
fi

# A row parked in blocked.backlog.yaml is taken too.
_story_rows "$T26_EPIC" blocked 06 > "${T26}/blocked.backlog.yaml"
R26B="$(GAAI_BACKLOG_PATH="$T26_ACTIVE" GAAI_RESERVATION_LEDGER="${WORK}/t26b.tsv" "$ALLOCATOR" story "$T26_EPIC")"
if [[ "$R26B" == "${T26_EPIC}S07" ]]; then
  _pass "blocked.backlog.yaml row ${T26_EPIC}S06 counted → ${R26B}"
else
  _fail "Expected ${T26_EPIC}S07 (S06 in blocked.backlog.yaml), got: ${R26B}"
fi

# Every archive file is read, not only the first one the glob returns.
_story_rows "$T26_EPIC" done 09 > "${T26}/done/archived-2000-02-01.yaml"
R26C="$(GAAI_BACKLOG_PATH="$T26_ACTIVE" GAAI_RESERVATION_LEDGER="${WORK}/t26c.tsv" "$ALLOCATOR" story "$T26_EPIC")"
if [[ "$R26C" == "${T26_EPIC}S10" ]]; then
  _pass "Max taken across all done/*.yaml archives (S09 in the second) → ${R26C}"
else
  _fail "Expected ${T26_EPIC}S10 (S09 in a second archive), got: ${R26C}"
fi

# ── Test 27: archived epic IDs are never re-issued ───────────────────────────
echo "Test 27: archived-only epic IDs are skipped (active + blocked + done/*.yaml)"

T27="${WORK}/t27"; mkdir -p "${T27}/done"
T27_ACTIVE="${T27}/active.backlog.yaml"
_story_rows E10 refined 01 > "$T27_ACTIVE"
_story_rows E40 done 01 02 > "${T27}/done/archived-2000-01-01.yaml"

R27A="$(GAAI_BACKLOG_PATH="$T27_ACTIVE" GAAI_RESERVATION_LEDGER="${WORK}/t27a.tsv" "$ALLOCATOR" epic)"
if [[ "$R27A" == "E41" ]]; then
  _pass "Archived epic E40 outranks active E10 → ${R27A}"
else
  _fail "Expected E41 (E40 archived in done/, active max E10), got: ${R27A}"
fi

_story_rows E45 blocked 01 > "${T27}/blocked.backlog.yaml"
R27B="$(GAAI_BACKLOG_PATH="$T27_ACTIVE" GAAI_RESERVATION_LEDGER="${WORK}/t27b.tsv" "$ALLOCATOR" epic)"
if [[ "$R27B" == "E46" ]]; then
  _pass "blocked.backlog.yaml epic E45 counted → ${R27B}"
else
  _fail "Expected E46 (E45 in blocked.backlog.yaml), got: ${R27B}"
fi

# ── Test 28: epic/story artefact files count as taken IDs ────────────────────
echo "Test 28: epic/story artefact files count as taken IDs (no backlog row anywhere)"

T28="${WORK}/t28"; mkdir -p "$T28"
T28_EMPTY="${T28}/active.backlog.yaml"; _empty_backlog "$T28_EMPTY"
T28_EPIC="E60"

T28_ART="${T28}/artefacts"
mkdir -p "${T28_ART}/epics" "${T28_ART}/stories"
touch "${T28_ART}/stories/${T28_EPIC}S03.story.md" \
      "${T28_ART}/stories/${T28_EPIC}S05a.story.md" \
      "${T28_ART}/stories/${T28_EPIC}1S09.story.md" \
      "${T28_ART}/stories/_template.story.md" \
      "${T28_ART}/epics/_template.epic.md"

# Story: the suffixed S05a file counts as S05; the S09 file belongs to a longer epic number sharing
# the prefix digits and must not count.
R28A="$(GAAI_BACKLOG_PATH="$T28_EMPTY" GAAI_ARTEFACTS_PATH="$T28_ART" \
  GAAI_RESERVATION_LEDGER="${WORK}/t28a.tsv" "$ALLOCATOR" story "$T28_EPIC")"
if [[ "$R28A" == "${T28_EPIC}S06" ]]; then
  _pass "Story artefact files counted (suffixed S05a = S05, longer-epic S09 ignored) → ${R28A}"
else
  _fail "Expected ${T28_EPIC}S06 (story files S03 and S05a), got: ${R28A}"
fi

# Epic: a story file proves its epic exists, so the longer epic number's story file sets the max.
R28B="$(GAAI_BACKLOG_PATH="$T28_EMPTY" GAAI_ARTEFACTS_PATH="$T28_ART" \
  GAAI_RESERVATION_LEDGER="${WORK}/t28b.tsv" "$ALLOCATOR" epic)"
if [[ "$R28B" == "E602" ]]; then
  _pass "A story artefact file raises the epic max to its epic → ${R28B}"
else
  _fail "Expected E602 (story file under epic E601), got: ${R28B}"
fi

# Epic files, plain and suffixed (E70b, E12-name), count; templates do not.
T28_ART2="${T28}/artefacts-epics"; mkdir -p "${T28_ART2}/epics"
touch "${T28_ART2}/epics/E12-named-epic.epic.md" "${T28_ART2}/epics/E70b.epic.md" \
      "${T28_ART2}/epics/_template.epic.md"
R28C="$(GAAI_BACKLOG_PATH="$T28_EMPTY" GAAI_ARTEFACTS_PATH="$T28_ART2" \
  GAAI_RESERVATION_LEDGER="${WORK}/t28c.tsv" "$ALLOCATOR" epic)"
if [[ "$R28C" == "E71" ]]; then
  _pass "Epic artefact files counted, suffixed E70b included → ${R28C}"
else
  _fail "Expected E71 (epic files E12-named-epic and E70b), got: ${R28C}"
fi

# Default resolution: with every override unset, the archive and artefacts of the repository the
# allocator runs in are found under its standard layout.
T28_REPO="${WORK}/t28-repo"; T28_HOME="${WORK}/t28-home"; mkdir -p "$T28_HOME"
git init -q "$T28_REPO"
( cd "$T28_REPO"; git config user.email t@example.test; git config user.name tester; git commit -q --allow-empty -m init )
T28_CTX="${T28_REPO}/.gaai/project/contexts"
mkdir -p "${T28_CTX}/backlog/done" "${T28_CTX}/artefacts/stories"
_empty_backlog "${T28_CTX}/backlog/active.backlog.yaml"
_story_rows "$T28_EPIC" done 02 > "${T28_CTX}/backlog/done/archived-2000-01-01.yaml"
touch "${T28_CTX}/artefacts/stories/${T28_EPIC}S04.story.md"

R28D="$(
  cd "$T28_REPO"; unset GAAI_RESERVATION_LEDGER GAAI_BACKLOG_PATH GAAI_DECISIONS_PATH GAAI_ARTEFACTS_PATH
  export HOME="$T28_HOME"; "$ALLOCATOR" story "$T28_EPIC"
)"
if [[ "$R28D" == "${T28_EPIC}S05" ]]; then
  _pass "Default paths: repo archive (S02) and story file (S04) both found → ${R28D}"
else
  _fail "Expected ${T28_EPIC}S05 from the default archive + artefacts paths, got: ${R28D}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
