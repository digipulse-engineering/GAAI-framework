#!/usr/bin/env bash
# corepack-cache-preflight.test.sh — the commit phase repairs a half-extracted
# Corepack pnpm release before anything it runs goes through the shim.
#
# Corepack treats an existing <cache>/v1/pnpm/<version>/ directory as an
# installed release and never downloads it again. When that directory exists
# but its entry file does not, every `pnpm` — including the push hook's
# typecheck — dies with MODULE_NOT_FOUND on every attempt. The preflight must
# move the broken directory aside (never delete it), re-prime, and verify.
#
# Hermetic: HOME, XDG_CACHE_HOME and COREPACK_HOME point into a throwaway
# fixture, and PATH is reduced to a stub dir plus the system dirs, so neither
# a real Corepack cache nor the network can be reached. The `pnpm` stub
# reproduces the one Corepack behaviour under test: resolve the cache root the
# same way, reuse any existing version directory, and fail with
# MODULE_NOT_FOUND when its entry file is missing.
#
#   T1  half-extracted under XDG_CACHE_HOME → moved aside with its contents
#       intact, re-primed without a prompt from the worktree, one log line,
#       and a following `pnpm` run succeeds (it failed before the preflight)
#   T2  intact cache → untouched, no re-prime
#   T3  COREPACK_HOME wins over XDG_CACHE_HOME
#   T4  a non-exported COREPACK_HOME is ignored (children never see it)
#   T5  neither set → $HOME/.cache/node/corepack
#   T6  re-prime fails → non-zero, named class, evidence kept
#   T7  no pnpm pin, and a pinned version not yet installed → no-op
#   T8  entry file taken from the `.corepack` install record, and from the
#       per-range table when the record is absent (pnpm >= 11 → bin/pnpm.mjs)
#   T9  handle_commit_phase runs the preflight before the dependency install
#       and before any push
#
# Usage: bash .gaai/core/scripts/tests/corepack-cache-preflight.test.sh
# Exit 0 = all pass.

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/../daemon-dispatch.sh"

_TMPDIR="${TMPDIR:-/tmp}"; _TMPDIR="${_TMPDIR%/}"
FIXTURE="$(mktemp -d "${_TMPDIR}/gaai-corepack-preflight-test.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

STUB_BIN="$FIXTURE/bin"
STUB_LOG="$FIXTURE/pnpm-calls.log"
WT="$FIXTURE/worktree"
mkdir -p "$STUB_BIN" "$WT"
: > "$STUB_LOG"

# ── Corepack-shaped pnpm stub ─────────────────────────────────────────────────
cat > "$STUB_BIN/pnpm" <<'STUB'
#!/usr/bin/env bash
echo "pnpm $* prompt=${COREPACK_ENABLE_DOWNLOAD_PROMPT:-unset} cwd=$(pwd -P)" >> "$STUB_LOG"
if [[ -n "${COREPACK_HOME+x}" ]]; then
  root="$COREPACK_HOME"
elif [[ -n "${XDG_CACHE_HOME+x}" ]]; then
  root="$XDG_CACHE_HOME/node/corepack"
else
  root="$HOME/.cache/node/corepack"
fi
spec=$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -1)
version="${spec#pnpm@}"; version="${version%%+*}"
major="${version%%.*}"
if (( major >= 11 )); then entry="bin/pnpm.mjs"; else entry="bin/pnpm.cjs"; fi
dir="$root/v1/pnpm/$version"
if [[ ! -d "$dir" ]]; then
  [[ "${STUB_PRIME_FAIL:-0}" == "1" ]] && { echo "Error: fetch failed (stubbed)" >&2; exit 1; }
  mkdir -p "$dir/bin" "$dir/dist"
  echo "// stub entry" > "$dir/$entry"
  printf '{"locator":{"name":"pnpm","reference":"%s"},"bin":{"pnpm":"./%s"},"hash":"stub"}' \
    "$version" "$entry" > "$dir/.corepack"
fi
if [[ ! -f "$dir/$entry" ]]; then
  echo "Error: Cannot find module '$dir/$entry'" >&2
  echo "  code: 'MODULE_NOT_FOUND'" >&2
  exit 1
fi
[[ "${1:-}" == "--version" ]] && echo "$version"
exit 0
STUB
chmod +x "$STUB_BIN/pnpm"
# The real Corepack must never be reached.
cat > "$STUB_BIN/corepack" <<'STUB'
#!/usr/bin/env bash
echo "corepack $*" >> "$STUB_LOG"
exit 97
STUB
chmod +x "$STUB_BIN/corepack"
export STUB_LOG

# ── Source the library under test ─────────────────────────────────────────────
BACKLOG_FILE="$FIXTURE/active.backlog.yaml"
SCHEDULER="$SCRIPT_DIR/../backlog-scheduler.sh"
PROJECT_DIR="$FIXTURE"
LOCK_DIR="$FIXTURE/locks"
mkdir -p "$LOCK_DIR"
touch "$BACKLOG_FILE"
export BACKLOG_FILE SCHEDULER PROJECT_DIR LOCK_DIR
# shellcheck source=/dev/null
source "$DISPATCH"

# From here on nothing outside the fixture is reachable by name.
export PATH="$STUB_BIN:/usr/bin:/bin"
unset COREPACK_HOME XDG_CACHE_HOME LOCALAPPDATA
export HOME="$FIXTURE/home"
export TMPDIR="$FIXTURE/tmp"
mkdir -p "$HOME" "$TMPDIR"

PINNED="10.11.1"
pin() {
  printf '{\n  "name": "fixture",\n  "packageManager": "%s"\n}\n' "$1" > "$WT/package.json"
}

# A release exactly as observed broken: directory present, empty dist/, an
# install record, no entry file.
half_extract() {
  local dir="$1/v1/pnpm/$2"
  mkdir -p "$dir/dist"
  printf '{"locator":{"name":"pnpm","reference":"%s"},"bin":{"pnpm":"./bin/pnpm.cjs"},"hash":"stub"}' \
    "$2" > "$dir/.corepack"
  echo "partial" > "$dir/dist/.evidence-marker"
}

intact() {
  local dir="$1/v1/pnpm/$2"
  mkdir -p "$dir/bin"
  echo "// intact" > "$dir/bin/pnpm.cjs"
  printf '{"locator":{"name":"pnpm","reference":"%s"},"bin":{"pnpm":"./bin/pnpm.cjs"},"hash":"stub"}' \
    "$2" > "$dir/.corepack"
}

run_preflight() {
  PREFLIGHT_RC=0
  PREFLIGHT_OUT=""
  if declare -F _ensure_corepack_pnpm_intact >/dev/null 2>&1; then
    PREFLIGHT_OUT=$(_ensure_corepack_pnpm_intact "$1" "$WT" 2>&1) || PREFLIGHT_RC=$?
  else
    PREFLIGHT_RC=127
    PREFLIGHT_OUT="(preflight absent from daemon-dispatch.sh)"
  fi
}

count_lines() { printf '%s' "$1" | grep -c '' || true; }
evidence_dirs() { find "$1/v1/pnpm" -maxdepth 1 -name "$2.broken-*" -type d 2>/dev/null; }

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T1: half-extracted release under XDG_CACHE_HOME is repaired ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t1"
ROOT="$XDG_CACHE_HOME/node/corepack"
pin "pnpm@${PINNED}+sha512.abcdef"
half_extract "$ROOT" "$PINNED"
: > "$STUB_LOG"

# The incident, reproduced: every pnpm through the shim dies.
if (cd "$WT" && pnpm types) >/dev/null 2>&1; then
  fail "T1: fixture does not reproduce MODULE_NOT_FOUND before the preflight"
else
  pass "T1: fixture reproduces MODULE_NOT_FOUND before the preflight"
fi
: > "$STUB_LOG"

run_preflight "T1-STORY"
[[ $PREFLIGHT_RC -eq 0 ]] && pass "T1: preflight exit 0" \
  || fail "T1: expected exit 0, got $PREFLIGHT_RC (${PREFLIGHT_OUT})"
[[ -f "$ROOT/v1/pnpm/$PINNED/bin/pnpm.cjs" ]] && pass "T1: entry file present after re-prime" \
  || fail "T1: entry file still missing"
EV=$(evidence_dirs "$ROOT" "$PINNED")
if [[ $(count_lines "$EV") -eq 1 && -f "$EV/dist/.evidence-marker" && -f "$EV/.corepack" ]]; then
  pass "T1: broken release moved aside with its contents intact"
else
  fail "T1: evidence dir missing or altered (got: '${EV}')"
fi
if [[ "$(basename "$EV")" =~ ^${PINNED//./\\.}\.broken-[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
  pass "T1: evidence dir carries a timestamp suffix"
else
  fail "T1: unexpected evidence name '$(basename "$EV")'"
fi
if grep -q "^pnpm --version prompt=0 cwd=$(cd "$WT" && pwd -P)\$" "$STUB_LOG"; then
  pass "T1: re-primed with pnpm --version, prompt disabled, from the worktree"
else
  fail "T1: re-prime call not as expected: $(cat "$STUB_LOG")"
fi
if [[ $(count_lines "$PREFLIGHT_OUT") -eq 1 ]] && grep -q "REPAIRED pnpm@${PINNED}" <<<"$PREFLIGHT_OUT"; then
  pass "T1: exactly one REPAIRED log line"
else
  fail "T1: log not one REPAIRED line: ${PREFLIGHT_OUT}"
fi
if (cd "$WT" && pnpm types) >/dev/null 2>&1; then
  pass "T1: pnpm through the shim succeeds after the preflight"
else
  fail "T1: pnpm through the shim still fails after the preflight"
fi
grep -q '^corepack ' "$STUB_LOG" && fail "T1: real corepack command invoked" || pass "T1: corepack binary never invoked"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T2: intact release is left alone ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t2"
ROOT="$XDG_CACHE_HOME/node/corepack"
intact "$ROOT" "$PINNED"
: > "$STUB_LOG"
run_preflight "T2-STORY"
[[ $PREFLIGHT_RC -eq 0 ]] && pass "T2: exit 0" || fail "T2: expected exit 0, got $PREFLIGHT_RC"
[[ ! -s "$STUB_LOG" ]] && pass "T2: no re-prime" || fail "T2: pnpm invoked: $(cat "$STUB_LOG")"
[[ -z "$(evidence_dirs "$ROOT" "$PINNED")" ]] && pass "T2: nothing moved" || fail "T2: intact release moved"
if [[ $(count_lines "$PREFLIGHT_OUT") -eq 1 ]] && grep -q "intact" <<<"$PREFLIGHT_OUT"; then
  pass "T2: one 'intact' log line"
else
  fail "T2: unexpected log: ${PREFLIGHT_OUT}"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: COREPACK_HOME takes precedence over XDG_CACHE_HOME ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t3"
export COREPACK_HOME="$FIXTURE/corepack-home-t3"
half_extract "$COREPACK_HOME" "$PINNED"
half_extract "$XDG_CACHE_HOME/node/corepack" "$PINNED"
: > "$STUB_LOG"
run_preflight "T3-STORY"
if [[ $PREFLIGHT_RC -eq 0 && -f "$COREPACK_HOME/v1/pnpm/$PINNED/bin/pnpm.cjs" \
      && -n "$(evidence_dirs "$COREPACK_HOME" "$PINNED")" ]]; then
  pass "T3: release under COREPACK_HOME repaired"
else
  fail "T3: COREPACK_HOME release not repaired (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi
if [[ -z "$(evidence_dirs "$XDG_CACHE_HOME/node/corepack" "$PINNED")" \
      && ! -f "$XDG_CACHE_HOME/node/corepack/v1/pnpm/$PINNED/bin/pnpm.cjs" ]]; then
  pass "T3: the XDG cache Corepack would not read is untouched"
else
  fail "T3: XDG cache was touched although COREPACK_HOME is set"
fi
unset COREPACK_HOME

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: a non-exported COREPACK_HOME does not steer the check ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t4"
half_extract "$XDG_CACHE_HOME/node/corepack" "$PINNED"
COREPACK_HOME="$FIXTURE/not-exported-t4"   # shell variable only
export -n COREPACK_HOME
: > "$STUB_LOG"
run_preflight "T4-STORY"
if [[ $PREFLIGHT_RC -eq 0 && -f "$XDG_CACHE_HOME/node/corepack/v1/pnpm/$PINNED/bin/pnpm.cjs" \
      && ! -e "$FIXTURE/not-exported-t4" ]]; then
  pass "T4: resolved the cache the child actually reads (XDG)"
else
  fail "T4: followed a variable Corepack cannot see (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi
unset COREPACK_HOME

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T5: neither COREPACK_HOME nor XDG_CACHE_HOME → \$HOME/.cache ==="
unset XDG_CACHE_HOME
ROOT="$HOME/.cache/node/corepack"
half_extract "$ROOT" "$PINNED"
: > "$STUB_LOG"
run_preflight "T5-STORY"
if [[ $PREFLIGHT_RC -eq 0 && -f "$ROOT/v1/pnpm/$PINNED/bin/pnpm.cjs" && -n "$(evidence_dirs "$ROOT" "$PINNED")" ]]; then
  pass "T5: HOME-relative cache repaired"
else
  fail "T5: HOME-relative cache not repaired (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T6: re-prime failure is reported, evidence kept ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t6"
ROOT="$XDG_CACHE_HOME/node/corepack"
half_extract "$ROOT" "$PINNED"
: > "$STUB_LOG"
export STUB_PRIME_FAIL=1
run_preflight "T6-STORY"
unset STUB_PRIME_FAIL
[[ $PREFLIGHT_RC -ne 0 ]] && pass "T6: non-zero exit" || fail "T6: expected failure, got exit 0"
if [[ $(count_lines "$PREFLIGHT_OUT") -eq 1 ]] \
    && grep -q "UNUSABLE pnpm@${PINNED}.*\[class=corepack_cache_unusable\]" <<<"$PREFLIGHT_OUT" \
    && grep -q "fetch failed (stubbed)" <<<"$PREFLIGHT_OUT"; then
  pass "T6: one log line naming the class and the first re-prime output"
else
  fail "T6: unexpected log: ${PREFLIGHT_OUT}"
fi
EV=$(evidence_dirs "$ROOT" "$PINNED")
[[ -n "$EV" && -f "$EV/dist/.evidence-marker" ]] && pass "T6: broken release kept as evidence" \
  || fail "T6: evidence lost"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T7: nothing to do ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t7"
ROOT="$XDG_CACHE_HOME/node/corepack"
printf '{ "name": "fixture" }\n' > "$WT/package.json"
half_extract "$ROOT" "$PINNED"
: > "$STUB_LOG"
run_preflight "T7-STORY"
if [[ $PREFLIGHT_RC -eq 0 && -z "$PREFLIGHT_OUT" && ! -s "$STUB_LOG" && -z "$(evidence_dirs "$ROOT" "$PINNED")" ]]; then
  pass "T7: no pnpm pin → silent no-op"
else
  fail "T7: acted without a pnpm pin (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi
pin "pnpm@9.15.0"
: > "$STUB_LOG"
run_preflight "T7b-STORY"
if [[ $PREFLIGHT_RC -eq 0 && ! -s "$STUB_LOG" && ! -e "$ROOT/v1/pnpm/9.15.0" ]] \
    && grep -q "not yet installed" <<<"$PREFLIGHT_OUT"; then
  pass "T7: pinned version not yet installed → left to Corepack"
else
  fail "T7: absent version handled wrongly (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T8: entry file resolution ==="
export XDG_CACHE_HOME="$FIXTURE/xdg-t8"
ROOT="$XDG_CACHE_HOME/node/corepack"
pin "pnpm@11.2.0"
mkdir -p "$ROOT/v1/pnpm/11.2.0/bin"
echo "// wrong major's entry" > "$ROOT/v1/pnpm/11.2.0/bin/pnpm.cjs"   # no record, no .mjs
: > "$STUB_LOG"
run_preflight "T8-STORY"
if [[ $PREFLIGHT_RC -eq 0 && -f "$ROOT/v1/pnpm/11.2.0/bin/pnpm.mjs" && -n "$(evidence_dirs "$ROOT" "11.2.0")" ]]; then
  pass "T8: pnpm >= 11 without an install record expects bin/pnpm.mjs"
else
  fail "T8: range-table entry not honoured (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi
pin "pnpm@${PINNED}"
mkdir -p "$ROOT/v1/pnpm/$PINNED/lib"
echo "// entry" > "$ROOT/v1/pnpm/$PINNED/lib/entry.cjs"
printf '{"locator":{"name":"pnpm","reference":"%s"},"bin":{"pnpm":"./lib/entry.cjs"},"hash":"stub"}' \
  "$PINNED" > "$ROOT/v1/pnpm/$PINNED/.corepack"
: > "$STUB_LOG"
run_preflight "T8b-STORY"
if [[ $PREFLIGHT_RC -eq 0 && ! -s "$STUB_LOG" ]] && grep -q "intact" <<<"$PREFLIGHT_OUT"; then
  pass "T8: the install record's bin entry is authoritative"
else
  fail "T8: install record ignored (rc=$PREFLIGHT_RC out=${PREFLIGHT_OUT})"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== T9: commit phase runs the preflight before any pnpm or push ==="
BODY=$(declare -f handle_commit_phase 2>/dev/null)
L_PRE=$(grep -n '_ensure_corepack_pnpm_intact' <<<"$BODY" | head -1 | cut -d: -f1)
L_DEPS=$(grep -n '_ensure_worktree_deps_fresh' <<<"$BODY" | head -1 | cut -d: -f1)
L_PUSH=$(grep -n ' push origin' <<<"$BODY" | head -1 | cut -d: -f1)
if [[ -n "$L_PRE" && -n "$L_DEPS" && -n "$L_PUSH" && "$L_PRE" -lt "$L_DEPS" && "$L_PRE" -lt "$L_PUSH" ]]; then
  pass "T9: preflight precedes the dependency install and the push"
else
  fail "T9: preflight not wired ahead of pnpm/push (pre=${L_PRE:-none} deps=${L_DEPS:-none} push=${L_PUSH:-none})"
fi
if grep -A3 '_ensure_corepack_pnpm_intact' <<<"$BODY" | grep -q 'corepack_cache_unusable'; then
  pass "T9: failure routed under its own class"
else
  fail "T9: failure class not routed"
fi

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ $FAIL_COUNT -eq 0 ]]
