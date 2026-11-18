#!/usr/bin/env bash
# allocate-id-shared-record.test.sh — contract tests for what allocate-id.sh does when it cannot
# record a reservation on the shared record (refs/gaai/reservations).
#
# The failure this guards against: a host whose push to refs/gaai/* is refused (an agent session
# whose credentials may only push its own branches, a read-only token, a server-side policy) used
# to get an id on stdout with exit 0 and a stderr warning that callers routinely discarded. The id
# then existed only on that host and was reused elsewhere. The allocator now fails closed.
#
# Hermetic: a local bare remote whose update hook refuses refs/gaai/* when a switch file exists,
# and throwaway clones under a temp dir. No network, never touches the host repo.
#
# Usage: bash .gaai/core/scripts/tests/allocate-id-shared-record.test.sh
# Exit 0 = all pass.

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CORE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ALLOC_SRC="$CORE_DIR/scripts/lib/allocate-id.sh"

_TMPDIR="${TMPDIR:-/tmp}"; _TMPDIR="${_TMPDIR%/}"
WORK="$(mktemp -d "${_TMPDIR}/gaai-alloc-shared-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_TERMINAL_PROMPT=0
unset GAAI_RESERVATION_HOLDER GAAI_BACKLOG_PATH GAAI_ARTEFACTS_PATH GAAI_DECISIONS_PATH \
  GAAI_RESERVATION_LEDGER GAAI_SCAN_REMOTE GAAI_REMOTE GAAI_RESERVATION_BACKEND \
  GAAI_ALLOW_UNCONFIRMED 2>/dev/null || true
export GAAI_REMOTE_TIMEOUT=5
export HOME="$WORK/home"
mkdir -p "$HOME"

BACKLOG=".gaai/project/contexts/backlog"
EP="E7"
REMOTE="$WORK/remote.git"
REFUSE="$WORK/refuse-gaai-refs"     # present = the remote refuses refs/gaai/*
ATTEMPTS="$WORK/gaai-push-attempts" # one line per push attempt the remote saw on refs/gaai/*

echo "=== allocate-id shared record ==="

if [[ ! -f "$ALLOC_SRC" ]]; then
  fail "T0: missing $ALLOC_SRC"; echo ""; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1
fi

# ── Fixture ───────────────────────────────────────────────────────────────────
git init -q --bare "$REMOTE"
cat > "$REMOTE/hooks/update" <<EOF
#!/usr/bin/env bash
case "\$1" in
  refs/gaai/*)
    echo x >> "$ATTEMPTS"
    if [[ -e "$REFUSE" ]]; then echo "permission denied to update \$1" >&2; exit 1; fi ;;
esac
exit 0
EOF
chmod +x "$REMOTE/hooks/update"

SEED="$WORK/seed"
git init -q "$SEED"
git -C "$SEED" checkout -q -b staging
mkdir -p "$SEED/$BACKLOG/done" "$SEED/.gaai/core/scripts/lib"
printf 'items:\n- id: %s\n  status: draft\n- id: %sS01\n  epic: %s\n  status: draft\n' "$EP" "$EP" "$EP" \
  > "$SEED/$BACKLOG/active.backlog.yaml"
cp "$ALLOC_SRC" "$SEED/.gaai/core/scripts/lib/"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m seed
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin staging

C="$WORK/clone"
git clone -q -b staging "$REMOTE" "$C"
git -C "$C" config gc.auto 0

_remote_ref() { git --git-dir="$REMOTE" rev-parse --verify --quiet refs/gaai/reservations || echo none; }
_local_ref() { git -C "$C" rev-parse --verify --quiet refs/gaai/reservations || echo none; }
# Runs the allocator in the clone. Sets OUT (stdout), ERR (stderr), RC.
_alloc() {
  local errf="$WORK/stderr"
  OUT="$(cd "$C" && "$@" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"
}
ALLOC=(bash .gaai/core/scripts/lib/allocate-id.sh)

# ── T1: normal path — recorded on the shared record, exit 0 ──────────────────
_alloc "${ALLOC[@]}" story "$EP"
if [[ "$RC" -eq 0 && "$OUT" == "${EP}S02" ]] && \
    git --git-dir="$REMOTE" show refs/gaai/reservations:reservations.tsv | grep -q "^${EP}S02	story	"; then
  pass "T1: confirmed allocation prints the id, exits 0 and is on the remote record"
else
  fail "T1: rc=$RC out='$OUT' err='$ERR'"
fi

# ── T2: refused push fails closed ────────────────────────────────────────────
touch "$REFUSE"; : > "$ATTEMPTS"
REMOTE_BEFORE="$(_remote_ref)"
_alloc "${ALLOC[@]}" story "$EP"
if [[ "$RC" -eq 3 && -z "$OUT" ]]; then
  pass "T2a: refused push → exit 3 and nothing on stdout"
else
  fail "T2a: expected rc=3 and empty stdout, got rc=$RC out='$OUT'"
fi
if grep -q "NO id allocated" <<< "$ERR" && grep -q "permission denied" <<< "$ERR" && \
    grep -q "GAAI_RESERVATION_HOLDER" <<< "$ERR"; then
  pass "T2b: stderr names the failure, git's reason and the relay route"
else
  fail "T2b: stderr lacks reason or route: $ERR"
fi
if [[ "$(wc -l < "$ATTEMPTS" | tr -d ' ')" == "1" ]]; then
  pass "T2c: a refusal is not retried as if it were a lost race (1 push attempt)"
else
  fail "T2c: expected 1 push attempt, remote saw $(wc -l < "$ATTEMPTS" | tr -d ' ')"
fi
if [[ "$(_remote_ref)" == "$REMOTE_BEFORE" && "$(_local_ref)" == "$REMOTE_BEFORE" ]]; then
  pass "T2d: remote record unchanged and the unpublished row rolled back locally"
else
  fail "T2d: remote=$(_remote_ref) local=$(_local_ref) expected both $REMOTE_BEFORE"
fi

# ── T3: once pushes work again, the refused id is not silently published ─────
rm -f "$REFUSE"
_alloc "${ALLOC[@]}" story "$EP"
if [[ "$RC" -eq 0 && -n "$OUT" ]]; then
  ROWS="$(git --git-dir="$REMOTE" show refs/gaai/reservations:reservations.tsv | grep -c "^${EP}S")"
  if [[ "$ROWS" == "2" ]]; then
    pass "T3: next allocation (${OUT}) publishes only its own row"
  else
    fail "T3: expected 2 story rows on the remote, found $ROWS"
  fi
else
  fail "T3: allocation after recovery failed rc=$RC err='$ERR'"
fi

# ── T4: GAAI_ALLOW_UNCONFIRMED=1 keeps the permissive behaviour, loudly ──────
touch "$REFUSE"
_alloc env GAAI_ALLOW_UNCONFIRMED=1 "${ALLOC[@]}" story "$EP"
if [[ "$RC" -eq 0 && "$OUT" =~ ^${EP}S[0-9]+$ ]] && grep -q "NOT on the shared reservation record" <<< "$ERR"; then
  pass "T4: opt-out prints the id with exit 0 and a warning"
else
  fail "T4: rc=$RC out='$OUT' err='$ERR'"
fi

# ── T5: reserve under a refusal — exit 1, one attempt, reason shown ──────────
: > "$ATTEMPTS"
_alloc "${ALLOC[@]}" reserve "${EP}S40"
if [[ "$RC" -eq 1 && -z "$OUT" && "$(wc -l < "$ATTEMPTS" | tr -d ' ')" == "1" ]] && \
    grep -q "permission denied" <<< "$ERR"; then
  pass "T5: reserve refused → exit 1, single attempt, git reason surfaced"
else
  fail "T5: rc=$RC out='$OUT' attempts=$(wc -l < "$ATTEMPTS" | tr -d ' ') err='$ERR'"
fi
rm -f "$REFUSE"

# ── T6: no remote configured → local-only allocation is unchanged ────────────
git -C "$C" remote remove origin
_alloc "${ALLOC[@]}" story "$EP"
if [[ "$RC" -eq 0 && "$OUT" =~ ^${EP}S[0-9]+$ ]]; then
  pass "T6: repository without a remote still allocates (exit 0)"
else
  fail "T6: rc=$RC out='$OUT' err='$ERR'"
fi

# ── T7: remote configured but shared record switched off → warning, never silent ─
git -C "$C" remote add origin "$REMOTE"
_alloc env GAAI_SCAN_REMOTE=0 "${ALLOC[@]}" story "$EP"
if [[ "$RC" -eq 0 && "$OUT" =~ ^${EP}S[0-9]+$ ]] && grep -q "NOT recorded on the shared reservation record" <<< "$ERR"; then
  pass "T7: GAAI_SCAN_REMOTE=0 prints the id but warns it is not shared"
else
  fail "T7: rc=$RC out='$OUT' err='$ERR'"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
