#!/usr/bin/env bash
# id-reservation-guard.test.sh — contract tests for scripts/lib/id-reservation-guard.sh,
# hooks/pre-push.d/18-id-reservation-guard.sh and the allocator modes they rely on
# (allocate-id.sh holder / reserve, and the holder column on shared reservation rows).
#
# Hermetic: a local bare remote and throwaway clones under a temp dir. Each simulated host has
# its own HOME, hence its own reservation holder token. No network, never touches the host repo.
#
# Usage: bash .gaai/core/scripts/tests/id-reservation-guard.test.sh
# Exit 0 = all pass.

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CORE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
GUARD_SRC="$CORE_DIR/scripts/lib/id-reservation-guard.sh"
ALLOC_SRC="$CORE_DIR/scripts/lib/allocate-id.sh"
HOOK_SRC="$CORE_DIR/hooks/pre-push.d/18-id-reservation-guard.sh"
DISPATCH_SRC="$CORE_DIR/hooks/pre-push"

_TMPDIR="${TMPDIR:-/tmp}"; _TMPDIR="${_TMPDIR%/}"
WORK="$(mktemp -d "${_TMPDIR}/gaai-id-guard-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Isolate git and the allocator from the caller's environment.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_TERMINAL_PROMPT=0
unset GAAI_RESERVATION_HOLDER GAAI_ID_GUARD_TARGET_BRANCH GAAI_ID_GUARD_BACKLOG_DIR \
  GAAI_ID_GUARD_ARTEFACTS_DIR GAAI_BACKLOG_PATH GAAI_ARTEFACTS_PATH GAAI_DECISIONS_PATH \
  GAAI_RESERVATION_LEDGER GAAI_SCAN_REMOTE GAAI_REMOTE GAAI_RESERVATION_BACKEND 2>/dev/null || true
export GAAI_REMOTE_TIMEOUT=5
export GAAI_ID_GUARD_TIMEOUT=10

HOME_A="$WORK/home-a"; HOME_B="$WORK/home-b"
mkdir -p "$HOME_A" "$HOME_B"

BACKLOG=".gaai/project/contexts/backlog"
ARTS=".gaai/project/contexts/artefacts"
EP="E7"                       # fixture epic; story ids are built as "${EP}S<nn>"
REMOTE="$WORK/remote.git"
ZERO="0000000000000000000000000000000000000000"
TAB=$'\t'

echo "=== id reservation guard ==="

for f in "$GUARD_SRC" "$ALLOC_SRC" "$HOOK_SRC" "$DISPATCH_SRC"; do
  if [[ ! -f "$f" ]]; then
    fail "T0: missing $f"; echo ""; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1
  fi
done
[[ -x "$HOOK_SRC" ]] && pass "T0: hook present and executable" || fail "T0: hook not executable"

# ── Fixture ───────────────────────────────────────────────────────────────────
_row() { printf -- '- id: %s\n  epic: %s\n  status: draft\n' "$1" "$EP"; }

git init -q --bare "$REMOTE"
SEED="$WORK/seed"
git init -q "$SEED"
git -C "$SEED" checkout -q -b staging
mkdir -p "$SEED/$BACKLOG/done" "$SEED/$ARTS/epics" "$SEED/$ARTS/stories" \
  "$SEED/.gaai/core/scripts/lib" "$SEED/.gaai/core/hooks/pre-push.d"
{
  printf 'items:\n'
  printf -- '- id: %s\n  status: draft\n' "$EP"
  _row "${EP}S01"; _row "${EP}S02"
} > "$SEED/$BACKLOG/active.backlog.yaml"
{ printf 'items:\n'; _row "${EP}S03"; } > "$SEED/$BACKLOG/done/archive-one.yaml"
printf '# epic\n' > "$SEED/$ARTS/epics/${EP}.epic.md"
for n in 01 02 03; do printf '# story\n' > "$SEED/$ARTS/stories/${EP}S${n}.story.md"; done
cp "$GUARD_SRC" "$ALLOC_SRC" "$SEED/.gaai/core/scripts/lib/"
cp "$HOOK_SRC" "$SEED/.gaai/core/hooks/pre-push.d/"
cp "$DISPATCH_SRC" "$SEED/.gaai/core/hooks/pre-push"
chmod +x "$SEED/.gaai/core/scripts/lib/"*.sh "$SEED/.gaai/core/hooks/pre-push" \
  "$SEED/.gaai/core/hooks/pre-push.d/"*.sh
git -C "$SEED" add -A
git -C "$SEED" commit -q -m seed
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin staging

# Append rows to the shared record on the remote, exactly as the allocator stores them.
_cas_append() {
  local rows="$1" parent blob tree commit
  git -C "$SEED" fetch -q origin "+refs/gaai/reservations:refs/gaai/reservations" 2>/dev/null || true
  parent="$(git -C "$SEED" rev-parse --verify --quiet refs/gaai/reservations || true)"
  blob="$({ [[ -n "$parent" ]] && git -C "$SEED" show "$parent:reservations.tsv"; printf '%s' "$rows"; } \
    | git -C "$SEED" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\treservations.tsv\n' "$blob" | git -C "$SEED" mktree)"
  if [[ -n "$parent" ]]; then
    commit="$(git -C "$SEED" commit-tree -m rows -p "$parent" "$tree")"
  else
    commit="$(git -C "$SEED" commit-tree -m rows "$tree")"
  fi
  git -C "$SEED" push -q origin "$commit:refs/gaai/reservations"
}
_cas_content() { git --git-dir="$REMOTE" show refs/gaai/reservations:reservations.tsv; }

_cas_append "$(printf '%s\tepic\t1000000000\n' "$EP")"$'\n'

_clone() {
  git clone -q -b staging "$REMOTE" "$1"
  git -C "$1" config gc.auto 0
}
A="$WORK/a"; B="$WORK/b"
_clone "$A"; _clone "$B"

# Host-local holder tokens (created by the allocator on first use).
HOLDER_A="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh holder)"
HOLDER_B="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh holder)"

_sync() { git -C "$1" fetch -q origin && git -C "$1" checkout -q staging && git -C "$1" reset -q --hard origin/staging; }

# Adds backlog rows and story files for each id, as one commit.
_add_stories() {
  local clone="$1"; shift
  local id
  for id in "$@"; do
    _row "$id" >> "$clone/$BACKLOG/active.backlog.yaml"
    printf '# story\n' > "$clone/$ARTS/stories/${id}.story.md"
  done
  git -C "$clone" add -A && git -C "$clone" commit -q -m "add $*"
}

# Runs the guard in pre-push mode for a push of HEAD to refs/heads/<branch>.
# Sets OUT and RC.
_prepush() {
  local clone="$1" home="$2" branch="${3:-staging}" remote="${4:-origin}" remote_sha
  remote_sha="$(git -C "$clone" rev-parse --verify --quiet "refs/remotes/origin/$branch" || echo "$ZERO")"
  OUT="$(cd "$clone" && printf 'refs/heads/%s %s refs/heads/%s %s\n' "$branch" "$(git rev-parse HEAD)" "$branch" "$remote_sha" \
    | HOME="$home" bash .gaai/core/scripts/lib/id-reservation-guard.sh pre-push "$remote" "$remote" 2>&1)"
  RC=$?
}

# ── T1: an unreserved new story is refused ───────────────────────────────────
_sync "$B"
_add_stories "$B" "${EP}S10"
_prepush "$B" "$HOME_B"
if [[ "$RC" -eq 1 ]] && grep -q "${EP}S10 .*not reserved" <<< "$OUT"; then
  pass "T1: unreserved new story refused, id named"
else
  fail "T1: expected refusal naming the id (rc=$RC): $OUT"
fi

# ── T2: allocator rows carry the holder; own reservation accepted ─────────────
_sync "$A"
ID_A1="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh story "$EP")"
ID_A2="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh story "$EP")"
if _cas_content | grep -q "^${ID_A1}${TAB}story${TAB}[0-9]*${TAB}${HOLDER_A}\$"; then
  pass "T2a: allocator writes the holder as the fourth column (${ID_A1})"
else
  fail "T2a: no holder column for ${ID_A1}: $(_cas_content | tail -3)"
fi
_add_stories "$A" "$ID_A1" "$ID_A2"
_prepush "$A" "$HOME_A"
[[ "$RC" -eq 0 ]] && pass "T2b: ids reserved by this host accepted" || fail "T2b: rc=$RC: $OUT"

# ── T3: the founding incident — the same ids from another host, plus one unreserved ─
_sync "$B"
NEXT_FREE="$(printf '%sS%02d' "$EP" $(( 10#${ID_A2#${EP}S} + 1 )))"
_add_stories "$B" "$ID_A1" "$ID_A2" "$NEXT_FREE"
_prepush "$B" "$HOME_B"
if [[ "$RC" -eq 1 ]] \
  && grep -q "${ID_A1} .*reserved by another holder (${HOLDER_A:0:6}" <<< "$OUT" \
  && grep -q "${ID_A2} .*reserved by another holder" <<< "$OUT" \
  && grep -q "${NEXT_FREE} .*not reserved" <<< "$OUT"; then
  pass "T3a: incident replay refused — foreign ids and the unreserved one all named"
else
  fail "T3a: rc=$RC: $OUT"
fi
# The reserving host's push of the same ids still goes through; it then lands.
_prepush "$A" "$HOME_A"
[[ "$RC" -eq 0 ]] && pass "T3b: the reserving host's ids are unaffected" || fail "T3b: rc=$RC: $OUT"
git -C "$A" push -q origin HEAD:staging

# ── T4: editing an id already defined at the base is accepted ────────────────
_sync "$B"
printf 'edited\n' >> "$B/$ARTS/stories/${EP}S01.story.md"
sed -i.bak 's/^  status: draft$/  status: refined/' "$B/$BACKLOG/active.backlog.yaml" && rm -f "$B/$BACKLOG/active.backlog.yaml.bak"
git -C "$B" commit -q -am "edit existing"
_prepush "$B" "$HOME_B"
[[ "$RC" -eq 0 ]] && pass "T4: existing ids (not in the record) are never re-checked" || fail "T4: rc=$RC: $OUT"

# ── T5: a three-column row (no holder) is accepted with a notice ─────────────
_cas_append "$(printf '%sS20\tstory\t1000000000\n' "$EP")"$'\n'
_sync "$B"
_add_stories "$B" "${EP}S20"
_prepush "$B" "$HOME_B"
if [[ "$RC" -eq 0 ]] && grep -q "notice: ${EP}S20 is reserved by a row without a holder" <<< "$OUT"; then
  pass "T5: unattributed row accepted with a notice"
else
  fail "T5: rc=$RC: $OUT"
fi

# ── T6: derived (letter-suffixed) ids follow their anchor ────────────────────
_sync "$B"
_add_stories "$B" "${EP}S01a"
_prepush "$B" "$HOME_B"
[[ "$RC" -eq 0 ]] && pass "T6a: suffix of an anchor defined at the base accepted" || fail "T6a: rc=$RC: $OUT"
_sync "$B"
_add_stories "$B" "${EP}S40b"
_prepush "$B" "$HOME_B"
if [[ "$RC" -eq 1 ]] && grep -q "${EP}S40b .*derives from ${EP}S40" <<< "$OUT"; then
  pass "T6b: suffix of an unknown anchor refused"
else
  fail "T6b: rc=$RC: $OUT"
fi
_cas_append "$(printf '%sS02c\tstory\t1000000000\thost-other\n' "$EP")"$'\n'
_sync "$B"
_add_stories "$B" "${EP}S02c"
_prepush "$B" "$HOME_B"
if [[ "$RC" -eq 1 ]] && grep -q "${EP}S02c .*another holder (host-o" <<< "$OUT"; then
  pass "T6c: a derived id with its own foreign reservation is refused"
else
  fail "T6c: rc=$RC: $OUT"
fi

# ── T7: archiving a row (active → done/) adds nothing ────────────────────────
_sync "$B"
python_free_move() {
  # Move the two-line-tail row of ${EP}S02 from the active file to a new archive file.
  local f="$B/$BACKLOG/active.backlog.yaml"
  awk -v id="${EP}S02" '
    $0 == "- id: " id { skip = 1; next }
    skip && /^- id:/ { skip = 0 }
    !skip { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  { printf 'items:\n'; _row "${EP}S02"; } > "$B/$BACKLOG/done/archive-two.yaml"
}
python_free_move
git -C "$B" add -A && git -C "$B" commit -q -m archive
_prepush "$B" "$HOME_B"
[[ "$RC" -eq 0 ]] && pass "T7: archive move accepted" || fail "T7: rc=$RC: $OUT"

# ── T8: tags, deletions and the reservation ref cost nothing (no remote I/O) ─
OUT="$(cd "$B" && printf '%s\n' \
  "refs/tags/v1 $(git rev-parse HEAD) refs/tags/v1 $ZERO" \
  "(delete) $ZERO refs/heads/old $(git rev-parse HEAD)" \
  "refs/gaai/reservations $(git rev-parse HEAD) refs/gaai/reservations $ZERO" \
  | HOME="$HOME_B" bash .gaai/core/scripts/lib/id-reservation-guard.sh pre-push no-such-remote no-such-remote 2>&1)"
RC=$?
[[ "$RC" -eq 0 && -z "$OUT" ]] && pass "T8: non-branch pushes skipped before any remote access" || fail "T8: rc=$RC: $OUT"

# ── T9: a remote without the shared record leaves the guard inert ────────────
PLAIN="$WORK/plain.git"
git init -q --bare "$PLAIN"
git -C "$SEED" push -q "$PLAIN" staging
_sync "$B"
git -C "$B" remote add plain "$PLAIN"
_add_stories "$B" "${EP}S50"
_prepush "$B" "$HOME_B" staging plain
[[ "$RC" -eq 0 ]] && pass "T9: no refs/gaai/reservations on the remote → inert" || fail "T9: rc=$RC: $OUT"

# ── T10: an unreachable remote fails closed ──────────────────────────────────
git -C "$B" remote add gone "$WORK/does-not-exist.git"
_prepush "$B" "$HOME_B" staging gone
if [[ "$RC" -eq 1 ]] && grep -q "cannot read refs/gaai/reservations" <<< "$OUT"; then
  pass "T10: unreadable reservation record refuses the push"
else
  fail "T10: rc=$RC: $OUT"
fi

# ── T11: check mode (CI): --any-holder only requires a reservation ───────────
_sync "$B"
BASE_SHA="$(git -C "$B" rev-parse HEAD)"
_add_stories "$B" "${EP}S02c"
RES_SHA="$(git --git-dir="$REMOTE" rev-parse refs/gaai/reservations)"
git -C "$B" fetch -q origin "+refs/gaai/reservations:refs/gaai/reservations"
OUT="$(cd "$B" && bash .gaai/core/scripts/lib/id-reservation-guard.sh check --base "$BASE_SHA" --head HEAD --reservations "$RES_SHA" --any-holder 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] && pass "T11a: --any-holder accepts a foreign reservation" || fail "T11a: rc=$RC: $OUT"
OUT="$(cd "$B" && bash .gaai/core/scripts/lib/id-reservation-guard.sh check --base "$BASE_SHA" --head HEAD --reservations "$RES_SHA" --holder "$HOLDER_B" 2>&1)"; RC=$?
[[ "$RC" -eq 1 ]] && pass "T11b: --holder refuses the same foreign reservation" || fail "T11b: rc=$RC: $OUT"
_add_stories "$B" "${EP}S60"
OUT="$(cd "$B" && bash .gaai/core/scripts/lib/id-reservation-guard.sh check --base "$BASE_SHA" --head HEAD --reservations "$RES_SHA" --any-holder 2>&1)"; RC=$?
if [[ "$RC" -eq 1 ]] && grep -q "${EP}S60 .*not reserved" <<< "$OUT"; then
  pass "T11c: --any-holder still refuses an unreserved id"
else
  fail "T11c: rc=$RC: $OUT"
fi
OUT="$(cd "$B" && bash .gaai/core/scripts/lib/id-reservation-guard.sh check --base "$BASE_SHA" --head HEAD 2>&1)"; RC=$?
[[ "$RC" -eq 2 ]] && pass "T11d: incomplete check arguments → usage error (2)" || fail "T11d: rc=$RC: $OUT"

# ── T12: allocator holder and reserve modes ──────────────────────────────────
H1="$(HOME="$HOME_A" bash "$ALLOC_SRC" holder)"; H2="$(HOME="$HOME_A" bash "$ALLOC_SRC" holder)"
if [[ "$H1" == "$H2" && "$H1" == "$HOLDER_A" && "$H1" =~ ^h-[0-9a-f]{16}$ && "$HOLDER_A" != "$HOLDER_B" ]]; then
  pass "T12a: holder token is stable per host and distinct across hosts"
else
  fail "T12a: '$H1' '$H2' '$HOLDER_A' '$HOLDER_B'"
fi
[[ "$(GAAI_RESERVATION_HOLDER=session-x HOME="$HOME_A" bash "$ALLOC_SRC" holder)" == "session-x" ]] \
  && pass "T12b: GAAI_RESERVATION_HOLDER overrides the host token" || fail "T12b: override ignored"
if ! GAAI_RESERVATION_HOLDER='bad token' HOME="$HOME_A" bash "$ALLOC_SRC" holder >/dev/null 2>&1; then
  pass "T12c: an invalid holder override is rejected"
else
  fail "T12c: invalid override accepted"
fi
_sync "$B"
R1="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S70" 2>&1)"; RC1=$?
R2="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S70" 2>&1)"; RC2=$?
if [[ "$RC1" -eq 0 && "$R1" == "${EP}S70" && "$RC2" -eq 0 ]] \
   && [[ "$(_cas_content | grep -c "^${EP}S70${TAB}")" -eq 1 ]] \
   && _cas_content | grep -q "^${EP}S70${TAB}story${TAB}[0-9]*${TAB}${HOLDER_B}\$"; then
  pass "T12d: reserve claims an exact id once, idempotently, with the holder"
else
  fail "T12d: rc1=$RC1 '$R1' rc2=$RC2 '$R2' rows=$(_cas_content | grep -c "^${EP}S70${TAB}")"
fi
OUT="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S70" 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]] && grep -q "already reserved by another holder" <<< "$OUT"; then
  pass "T12e: reserve refuses an id held by another holder"
else
  fail "T12e: another holder's id was re-claimed"
fi
OUT="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S20" 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]] && grep -q "reservation row without holder" <<< "$OUT"; then
  pass "T12f: reserve refuses an id that has a row without holder"
else
  fail "T12f: an unattributed id was re-claimed"
fi
if ! (cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh reserve "not-an-id" >/dev/null 2>&1); then
  pass "T12g: reserve rejects a malformed id"
else
  fail "T12g: malformed id accepted"
fi
[[ "$(_cas_content | grep -c "^${EP}${TAB}epic${TAB}")" -eq 1 && "$(_cas_content | grep -c "^${EP}S20${TAB}")" -eq 1 ]] \
  && pass "T12h: earlier rows survive every claim" || fail "T12h: record lost rows: $(_cas_content)"

# ── T13: end to end through git push and the hook dispatcher ─────────────────
_sync "$B"
git -C "$B" config core.hooksPath .gaai/core/hooks
_add_stories "$B" "${EP}S80"
BEFORE="$(git --git-dir="$REMOTE" rev-parse staging)"
if ! OUT="$(cd "$B" && HOME="$HOME_B" git push origin HEAD:staging 2>&1)" \
   && [[ "$(git --git-dir="$REMOTE" rev-parse staging)" == "$BEFORE" ]] \
   && grep -q "${EP}S80 .*not reserved" <<< "$OUT"; then
  pass "T13a: git push of an unreserved id is refused by the hook; remote unchanged"
else
  fail "T13a: $OUT"
fi
(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S80" >/dev/null 2>&1)
if OUT="$(cd "$B" && HOME="$HOME_B" git push origin HEAD:staging 2>&1)" \
   && [[ "$(git --git-dir="$REMOTE" rev-parse staging)" == "$(git -C "$B" rev-parse HEAD)" ]]; then
  pass "T13b: after reserving the exact id the same push goes through"
else
  fail "T13b: $OUT"
fi
git -C "$B" config --unset core.hooksPath

# ── T14: a new epic needs a reservation too ──────────────────────────────────
_sync "$A"
NEW_EPIC="E9"
{ printf -- '- id: %s\n  status: draft\n' "$NEW_EPIC"; } >> "$A/$BACKLOG/active.backlog.yaml"
printf '# epic\n' > "$A/$ARTS/epics/${NEW_EPIC}.epic.md"
git -C "$A" add -A && git -C "$A" commit -q -m "epic"
_prepush "$A" "$HOME_A"
if [[ "$RC" -eq 1 ]] && grep -q "${NEW_EPIC} .*not reserved" <<< "$OUT"; then
  pass "T14a: an unreserved epic is refused"
else
  fail "T14a: rc=$RC: $OUT"
fi
(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh reserve "$NEW_EPIC" >/dev/null 2>&1)
_prepush "$A" "$HOME_A"
[[ "$RC" -eq 0 ]] && pass "T14b: the reserved epic is accepted" || fail "T14b: rc=$RC: $OUT"

# ── T15: a feature branch is measured from its fork point with the target ────
_sync "$B"
git -C "$B" checkout -q -b feature
# The target moves on: host A lands one of its own reserved ids.
_sync "$A"
ID_A3="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh story "$EP")"
_add_stories "$A" "$ID_A3"
git -C "$A" push -q origin HEAD:staging
# The branch merges the new target in, then adds an id of its own.
git -C "$B" fetch -q origin
git -C "$B" merge -q --no-edit origin/staging
(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S90" >/dev/null 2>&1)
_add_stories "$B" "${EP}S90"
_prepush "$B" "$HOME_B" feature
[[ "$RC" -eq 0 ]] && pass "T15: ids merged in from the target are not counted as added" || fail "T15: rc=$RC: $OUT"

# ── T16: the collision after the reserver landed (rebase keeps both definitions) ─
_sync "$A"
ID_A4="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh story "$EP")"
_sync "$B"
git -C "$B" checkout -q -b collide
_row "$ID_A4" >> "$B/$BACKLOG/active.backlog.yaml"
printf '# other\n' > "$B/$ARTS/stories/${ID_A4}-other-topic.story.md"
git -C "$B" add -A && git -C "$B" commit -q -m "B picks the same number"
_add_stories "$A" "$ID_A4"
git -C "$A" push -q origin HEAD:staging
git -C "$B" fetch -q origin
git -C "$B" fetch -q origin "+refs/gaai/reservations:refs/gaai/reservations"
OUT="$(cd "$B" && bash .gaai/core/scripts/lib/id-reservation-guard.sh check --base origin/staging --head HEAD \
  --reservations refs/gaai/reservations --any-holder 2>&1)"; RC=$?
if [[ "$RC" -eq 1 ]] && grep -q "${ID_A4} .*defined again" <<< "$OUT"; then
  pass "T16a: CI mode refuses a second definition of an id already on the target tip"
else
  fail "T16a: rc=$RC: $OUT"
fi
git -C "$B" rebase -q origin/staging >/dev/null 2>&1 || git -C "$B" rebase --abort >/dev/null 2>&1
_prepush "$B" "$HOME_B" collide
if [[ "$RC" -eq 1 ]] && grep -q "${ID_A4} .*defined again" <<< "$OUT"; then
  pass "T16b: after a clean rebase the duplicate definition is still refused"
else
  fail "T16b: rc=$RC: $OUT"
fi

# ── T17: a second host pushing to the branch that already carries the ids ────
_sync "$A"
git -C "$A" checkout -q -b shared
ID_A5="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh story "$EP")"
_add_stories "$A" "$ID_A5"
git -C "$A" push -q origin HEAD:shared
git -C "$B" fetch -q origin
git -C "$B" checkout -q -B shared origin/shared
printf 'fix\n' >> "$B/$ARTS/stories/${ID_A5}.story.md"
git -C "$B" commit -q -am "fix on the shared branch"
_prepush "$B" "$HOME_B" shared
[[ "$RC" -eq 0 ]] && pass "T17a: ids already on the pushed remote branch are not re-judged" || fail "T17a: rc=$RC: $OUT"
_prepush "$B" "$HOME_B" copy-of-shared
if [[ "$RC" -eq 1 ]] && grep -q "${ID_A5} .*another holder" <<< "$OUT" && ! grep -q "$HOLDER_A" <<< "$OUT"; then
  pass "T17b: a new branch from that work is refused, without printing the full foreign token"
else
  fail "T17b: rc=$RC: $OUT"
fi

# ── T18: unrelated history is checked against the target tip, not skipped ───
_sync "$B"
git -C "$B" checkout -q --orphan lonely
_add_stories "$B" "${EP}S95"
_prepush "$B" "$HOME_B" lonely
if [[ "$RC" -eq 1 ]] && grep -q "${EP}S95 .*not reserved" <<< "$OUT"; then
  pass "T18: an orphan branch adding an unreserved id is refused"
else
  fail "T18: rc=$RC: $OUT"
fi

# ── T19: reserve bounds its numerals ─────────────────────────────────────────
_sync "$B"
OUT="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "E99999999999999999999" 2>&1)"; RC=$?
[[ "$RC" -ne 0 ]] && pass "T19a: an overflowing numeral is rejected" || fail "T19a: $OUT"
OUT="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "E5000" 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]] && grep -q "likely typo" <<< "$OUT" && ! _cas_content | grep -q "^E5000${TAB}"; then
  pass "T19b: a far jump above the known maximum is refused and not recorded"
else
  fail "T19b: rc=$RC: $OUT"
fi
BIG_EPIC="E999999"
for bad in "E888888a" "${BIG_EPIC}S01"; do
  OUT="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "$bad" 2>&1)"; RC=$?
  if [[ "$RC" -ne 0 ]] && grep -q "epic number .* likely typo" <<< "$OUT"; then
    pass "T19c: the epic numeral of $bad is bounded too"
  else
    fail "T19c: $bad rc=$RC: $OUT"
  fi
done
# The bound counts the backlog, not only the record: an epic numbered near the backlog's
# highest is accepted even when the record has never seen numbers that high.
_sync "$B"
printf -- '- id: E300\n  status: draft\n' >> "$B/$BACKLOG/active.backlog.yaml"
git -C "$B" commit -q -am "an epic from before the record"
OUT="$(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "E301" 2>&1)"; RC=$?
[[ "$RC" -eq 0 && "$OUT" == "E301" ]] && pass "T19d: the gap is measured against the backlog too" || fail "T19d: rc=$RC: $OUT"

# ── T20: definitions in less common shapes are still seen ────────────────────
_sync "$B"
mkdir -p "$B/$ARTS/stories/sub"
printf '# s\n' > "$B/$ARTS/stories/sub/${EP}S92.story.md"
printf '# s\n' > "$B/$ARTS/stories/${EP}S93_slug.story.md"
printf 'items:\n  - id: %sS94\n    status: draft\n  - id: "%sS91"   # quoted, commented\n' "$EP" "$EP" \
  > "$B/$BACKLOG/deferred.backlog.yml"
git -C "$B" add -A && git -C "$B" commit -q -m shapes
_prepush "$B" "$HOME_B"
if [[ "$RC" -eq 1 ]] && grep -q "${EP}S91 " <<< "$OUT" && grep -q "${EP}S92 " <<< "$OUT" \
   && grep -q "${EP}S93 " <<< "$OUT" && grep -q "${EP}S94 " <<< "$OUT"; then
  pass "T20: indented list in a .yml file, sub-directory, underscore slug, quoted row all seen"
else
  fail "T20: rc=$RC: $OUT"
fi

# ── T21: a file for an id whose row already exists adds nothing ──────────────
_sync "$B"
_row "${EP}S96" >> "$B/$BACKLOG/active.backlog.yaml"
git -C "$B" commit -q -am "row only"
(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S96" >/dev/null 2>&1)
git -C "$B" push -q origin HEAD:staging
printf '# s\n' > "$B/$ARTS/stories/${EP}S96.story.md"
git -C "$B" add -A && git -C "$B" commit -q -m "file for the existing row"
_prepush "$A" "$HOME_A" >/dev/null 2>&1
_prepush "$B" "$HOME_A"
[[ "$RC" -eq 0 ]] && pass "T21: adding the artefact file of an existing row is not a second definition" || fail "T21: rc=$RC: $OUT"

# ── T22: working copies and archives of an existing story are not definitions ─
_sync "$B"
mkdir -p "$B/$ARTS/stories/archive"
printf '# draft\n' > "$B/$ARTS/stories/${EP}S01.r1-candidate.story.md"
printf '# preview\n' > "$B/$ARTS/stories/${EP}S01.preview.story.md"
printf '# old\n' > "$B/$ARTS/stories/archive/${EP}S01.story.md"
git -C "$B" add -A && git -C "$B" commit -q -m "variants"
_prepush "$B" "$HOME_B"
[[ "$RC" -eq 0 ]] && pass "T22: candidate, preview and archived copies are accepted" || fail "T22: rc=$RC: $OUT"

# ── T23: nested lists of id objects inside a row are references, not rows ────
_sync "$B"
printf -- '- id: %sS97\n  depends_on:\n    - id: %sS01\n    - id: %sS98\n' "$EP" "$EP" "$EP" \
  >> "$B/$BACKLOG/active.backlog.yaml"
(cd "$B" && HOME="$HOME_B" bash .gaai/core/scripts/lib/allocate-id.sh reserve "${EP}S97" >/dev/null 2>&1)
git -C "$B" commit -q -am "row with nested references"
_prepush "$B" "$HOME_B"
[[ "$RC" -eq 0 ]] && pass "T23: nested '- id:' references are neither duplicates nor new ids" || fail "T23: rc=$RC: $OUT"

# ── T24: own work already landed by squash merge, pushed again from a stacked branch ─
_sync "$A"
git -C "$A" checkout -q -b feat-one
ID_A6="$(cd "$A" && HOME="$HOME_A" bash .gaai/core/scripts/lib/allocate-id.sh story "$EP")"
_add_stories "$A" "$ID_A6"
git -C "$A" checkout -q -b feat-two
printf 'more\n' > "$A/$ARTS/notes.md"; git -C "$A" add -A; git -C "$A" commit -q -m "stacked"
# Squash-merge feat-one into the target: same content, a commit unknown to feat-two.
_sync "$SEED" 2>/dev/null || { git -C "$SEED" fetch -q origin; git -C "$SEED" reset -q --hard origin/staging; }
git -C "$SEED" merge -q --squash "$(git -C "$A" rev-parse feat-one)" >/dev/null 2>&1 \
  || { git -C "$SEED" fetch -q "$A" feat-one && git -C "$SEED" merge -q --squash FETCH_HEAD; }
git -C "$SEED" commit -q -m "squash feat-one"
git -C "$SEED" push -q origin staging
git -C "$A" fetch -q origin
_prepush "$A" "$HOME_A" feat-two
[[ "$RC" -eq 0 ]] && pass "T24a: the hook accepts the host's own work landed by squash" || fail "T24a: rc=$RC: $OUT"
git -C "$A" fetch -q origin "+refs/gaai/reservations:refs/gaai/reservations"
OUT="$(cd "$A" && bash .gaai/core/scripts/lib/id-reservation-guard.sh check --base origin/staging --head feat-two \
  --reservations refs/gaai/reservations --any-holder 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] && pass "T24b: CI accepts it too (identical artefact file)" || fail "T24b: rc=$RC: $OUT"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
