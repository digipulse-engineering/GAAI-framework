#!/usr/bin/env bash
# daemon-fetch-observability.test.sh — the daemon's target-branch fetch fails typed, never silent
#
# Covers `_classify_fetch_failure` and `_fetch_target_branch` in delivery-daemon.sh:
#   * a successful fetch writes nothing;
#   * a failed fetch writes exactly one `[FETCH] reason=<typed> action=<canonical>
#     target=origin/<branch> rc=<git rc> evidence=<git's own fatal line>` entry;
#   * the classifier maps git's stderr to credential_absent / credential_rejected /
#     remote_unreachable / ref_absent / fetch_failed;
#   * the credential_absent path is proven hermetically through a git shim that
#     emits exactly what git prints under GIT_TERMINAL_PROMPT=0 — no network;
#   * the evidence field is printable, escape-free and bounded;
#   * every daemon-process fetch of the target branch goes through the wrapper
#     (a census: no bare `git -C "$PROJECT_DIR" fetch origin` survives outside it).
#
# Usage: .gaai/core/scripts/tests/daemon-fetch-observability.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DAEMON="$SCRIPT_DIR/../delivery-daemon.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-fetch-XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

# ── Extract the units under test, with a recording `log` ─────────────────────
HARNESS="$ROOT/harness.sh"
{
  printf 'set -uo pipefail\nRED=""; NC=""\nLOG_FILE="%s/daemon.log"\n' "$ROOT"
  printf 'log() { printf "%%s\\n" "$*" >> "$LOG_FILE"; }\n'
  sed -n '/^_classify_fetch_failure()/,/^}/p' "$DAEMON"
  sed -n '/^_FETCH_LAST_REASON=""$/p' "$DAEMON"
  sed -n '/^_fetch_target_branch()/,/^}/p' "$DAEMON"
} > "$HARNESS"
grep -q '^_classify_fetch_failure()' "$HARNESS" && grep -q '^_fetch_target_branch()' "$HARNESS" \
  || { fail "EXTRACT: the units under test were not found in delivery-daemon.sh"; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1; }
# shellcheck source=/dev/null
source "$HARNESS"
reset_log() { : > "$LOG_FILE"; }
fetch_lines() { grep -c '^\[FETCH\]' "$LOG_FILE" 2>/dev/null || true; }

# ── Fixture: a bare origin with a `staging` branch and a clone as the home ───
git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/home" 2>/dev/null
git -C "$ROOT/home" config user.email test@gaai.local
git -C "$ROOT/home" config user.name gaai-test
git -C "$ROOT/home" checkout -q -b staging
printf 'x\n' > "$ROOT/home/f"
git -C "$ROOT/home" add f && git -C "$ROOT/home" commit -q -m init
git -C "$ROOT/home" push -q origin staging 2>/dev/null
PROJECT_DIR="$ROOT/home"
TARGET_BRANCH=staging

echo ""
echo "=== T1: a successful fetch is silent and returns 0 ==="
reset_log
if _fetch_target_branch; then pass "T1: rc=0"; else fail "T1: rc≠0 on a healthy fetch"; fi
[[ "$(fetch_lines)" -eq 0 ]] && pass "T1: no [FETCH] line on success" || fail "T1: a [FETCH] line was written on success"
[[ -z "$_FETCH_LAST_REASON" ]] && pass "T1: _FETCH_LAST_REASON is cleared" || fail "T1: _FETCH_LAST_REASON=$_FETCH_LAST_REASON after success"

echo ""
echo "=== T2: a missing remote branch is typed ref_absent ==="
reset_log
if _fetch_target_branch no-such-branch; then fail "T2: rc=0 for a missing branch"; else pass "T2: non-zero rc propagated"; fi
[[ "$(fetch_lines)" -eq 1 ]] && pass "T2: exactly one [FETCH] line" || fail "T2: $(fetch_lines) [FETCH] lines"
grep -q '^\[FETCH\] reason=ref_absent action=check_target_branch target=origin/no-such-branch rc=[0-9]* evidence=fatal: ' "$LOG_FILE" \
  && pass "T2: line carries reason, action, target, rc and git's own fatal line" \
  || fail "T2: unexpected line: $(cat "$LOG_FILE")"
[[ "$_FETCH_LAST_REASON" == ref_absent ]] && pass "T2: _FETCH_LAST_REASON=ref_absent" || fail "T2: _FETCH_LAST_REASON=$_FETCH_LAST_REASON"

echo ""
echo "=== T3: the classifier maps git's words to typed reasons ==="
t3() {
  local _exp="$1" _in="$2" _got
  _got="$(_classify_fetch_failure "$_in")"
  [[ "$_got" == "$_exp" ]] && pass "T3: '$_in' → $_exp" || fail "T3: '$_in' → $_got (expected $_exp)"
}
t3 credential_absent   "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
t3 credential_absent   "fatal: could not read Username for 'https://github.com': Device not configured"
t3 credential_absent   "fatal: could not read Password for 'https://x@github.com': terminal prompts disabled"
t3 credential_rejected $'remote: Repository not found.\nfatal: Authentication failed for \'https://github.com/o/r.git/\''
t3 credential_rejected $'remote: Invalid username or token.\nfatal: Authentication failed'
t3 credential_rejected $'git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.'
t3 remote_unreachable  "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com"
t3 remote_unreachable  "fatal: unable to access 'https://github.com/o/r.git/': Failed to connect to github.com port 443: Connection refused"
t3 remote_unreachable  "ssh: connect to host github.com port 22: Operation timed out"
t3 ref_absent          "fatal: couldn't find remote ref nope"
t3 fetch_failed        "fatal: bad object HEAD"
t3 fetch_failed        ""

echo ""
echo "=== T4: credential_absent end to end, hermetically, through a git shim ==="
# The shim prints exactly what git prints under GIT_TERMINAL_PROMPT=0 with no
# credential, so the wrapper is exercised on the real failure text with no remote.
mkdir -p "$ROOT/shim"
cat > "$ROOT/shim/git" <<'SHIM'
#!/bin/sh
case "$*" in
  *" fetch origin "*)
    printf "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n" >&2
    exit 128 ;;
esac
exec /usr/bin/git "$@"
SHIM
chmod 0755 "$ROOT/shim/git"
reset_log
_rc=0
PATH="$ROOT/shim:$PATH" _fetch_target_branch || _rc=$?
[[ "$_rc" -eq 128 ]] && pass "T4: git's rc=128 is propagated" || fail "T4: rc=$_rc"
[[ "$(fetch_lines)" -eq 1 ]] && pass "T4: exactly one [FETCH] line" || fail "T4: $(fetch_lines) [FETCH] lines"
grep -qx "\[FETCH\] reason=credential_absent action=provision_forge_credential target=origin/staging rc=128 evidence=fatal: could not read Username for 'https://github.com': terminal prompts disabled" "$LOG_FILE" \
  && pass "T4: the line is the typed credential_absent entry an operator can act on" \
  || fail "T4: unexpected line: $(cat "$LOG_FILE")"
grep -q '^fatal:' "$LOG_FILE" && fail "T4: a bare fatal: line reached the log" || pass "T4: no bare fatal: line in the log"

echo ""
echo "=== T5: the evidence field is git's fatal line, printable, escape-free, bounded ==="
cat > "$ROOT/shim/git" <<'SHIM'
#!/bin/sh
case "$*" in
  *" fetch origin "*)
    printf 'remote: first line that is not the reason\n' >&2
    printf 'fatal: \033[31mred\033[0m back\\slash tab\there %s\n' "$(printf 'x%.0s' $(seq 1 400))" >&2
    exit 128 ;;
esac
exec /usr/bin/git "$@"
SHIM
reset_log
PATH="$ROOT/shim:$PATH" _fetch_target_branch || true
_ev="$(sed -n 's/^\[FETCH\] .* evidence=//p' "$LOG_FILE")"
case "$_ev" in fatal:*) pass "T5: the fatal: line was chosen over the first stderr line" ;; *) fail "T5: evidence='$_ev'" ;; esac
printf '%s' "$_ev" | LC_ALL=C grep -q '[^[:print:]]' && fail "T5: non-printable bytes survived" || pass "T5: printable only"
case "$_ev" in *'\'*) fail "T5: a backslash survived (log expands escapes)" ;; *) pass "T5: no backslash" ;; esac
case "$_ev" in *'[31m'*) fail "T5: ANSI escape text survived" ;; *) pass "T5: escape sequences removed" ;; esac
[[ "${#_ev}" -le 200 ]] && pass "T5: bounded to 200 characters (${#_ev})" || fail "T5: ${#_ev} characters"
grep -q 'reason=fetch_failed action=operator_disposition_required' "$LOG_FILE" \
  && pass "T5: an unclassified failure is fetch_failed with operator disposition" \
  || fail "T5: $(cat "$LOG_FILE")"

echo ""
echo "=== T6: every daemon-process fetch of the target goes through the wrapper (census) ==="
# Only the wrapper itself may run the bare fetch. Generated scripts (heredocs that
# run in a wrapper process with their own log) do not use `-C "$PROJECT_DIR"`.
_n="$(grep -c 'git -C "\$PROJECT_DIR" fetch origin' "$DAEMON" || true)"
[[ "$_n" -eq 1 ]] && pass "T6: exactly one bare target fetch remains, inside _fetch_target_branch" \
  || fail "T6: $_n bare 'git -C \"\$PROJECT_DIR\" fetch origin' sites — a fetch failure can still be silent"
_in_wrapper="$(sed -n '/^_fetch_target_branch()/,/^}/p' "$DAEMON" | grep -c 'git -C "\$PROJECT_DIR" fetch origin' || true)"
[[ "$_in_wrapper" -eq 1 ]] && pass "T6: that one site is the wrapper's own fetch" \
  || fail "T6: the remaining bare fetch is outside _fetch_target_branch"

echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
exit 0
