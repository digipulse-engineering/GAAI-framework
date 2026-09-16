#!/usr/bin/env bash
# Lifecycle caller cutover and stop-hook persistence regression.

set -uo pipefail

TEST_BASH="${GAAI_TEST_BASH:-${BASH:-/bin/bash}}"
printf 'INTERPRETER outer=%s inner=%s version=%s\n' \
  "${BASH:-unknown}" "$TEST_BASH" "$BASH_VERSION"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_SRC="$(cd "$(dirname "$0")/../../vendor/pyyaml/6.0.3" && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gaai-s14-hook-XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"

_mode_of() {
  if stat -f '%Lp' / >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1" 2>/dev/null
  else
    stat -c '%a' -- "$1" 2>/dev/null
  fi
}

setup_repo() {
  local repo="$1" remote="${1}.git"
  git init -q --bare "$remote"
  git clone -q "$remote" "$repo"
  git -C "$repo" remote set-url --push origin "$remote"
  [[ "$(git -C "$repo" remote get-url --push origin)" == "$remote" ]] || return 1
  git -C "$repo" config user.email test@gaai.local
  git -C "$repo" config user.name "GAAI Test"
  git -C "$repo" checkout -q -b staging
  mkdir -p "$repo/.gaai/project/contexts/backlog"
  mkdir -p "$repo/.gaai/core"
  cp -R "$SCRIPTS" "$repo/.gaai/core/scripts"
  # The lifecycle writer parses YAML through the vendored runtime, so the
  # complete tuple has to exist AND be committed in this sandbox: the base-held
  # assertion binds the parser to the exact remote blob before any lifecycle
  # write, exactly as it binds the writer itself.
  mkdir -p "$repo/.gaai/core/vendor/pyyaml/6.0.3"
  cp "$VENDOR_SRC/pyyaml-runtime.pyz" "$VENDOR_SRC/PROVENANCE.json" \
     "$VENDOR_SRC/LICENSE" "$repo/.gaai/core/vendor/pyyaml/6.0.3/"
  # cp without -p applies the current umask; the runtime requires exactly 0644.
  chmod 0644 "$repo/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" \
             "$repo/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json" \
             "$repo/.gaai/core/vendor/pyyaml/6.0.3/LICENSE"
  cat > "$repo/$BACKLOG_REL" <<'YAML'
items:
- id: TST-S14
  status: refined
  phase_status: not_started
  started_at: null
- id: TST-OTHER
  status: refined
  phase_status: not_started
- id: TST-ASSET
  status: refined
  phase_status: not_started
- id: TST-SYMLINK
  status: refined
  phase_status: not_started
- id: TST-TEMP
  status: refined
  phase_status: not_started
- id: TST-CONFLICT
  status: refined
  phase_status: not_started
- id: TST-RETRY-FINAL
  status: in_progress
  phase_status: qa_passed
- id: TST-RETRY-QA
  status: in_progress
  phase_status: implemented
- id: TST-EMPTY-RUN
  status: in_progress
  phase_status: planned
- id: TST-RECOVERY
  status: in_progress
  phase_status: planned
  started_at: "2026-08-25T10:00:00Z"
- id: TST-RETAINED
  status: in_progress
  phase_status: planned
  started_at: "2026-08-25T10:00:00Z"
- id: E999S99
  status: done
  phase_status: done
  cost_usd: null
  started_at: null
  completed_at: null
  pr_url: null
  pr_number: null
  pr_status: null
YAML
  git -C "$repo" add "$BACKLOG_REL" .gaai/core/scripts .gaai/core/vendor/pyyaml/6.0.3
  git -C "$repo" commit -q -m initial
  git -C "$repo" push -q -u origin staging
  # The tuple is verified against its own manifest inside the fixture before any
  # case runs, so a mode or digest problem here is attributed to the fixture and
  # not to the code under test.
  local rel
  for rel in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
    if [[ "$(_mode_of "$repo/.gaai/core/vendor/pyyaml/6.0.3/$rel")" != "644" ]]; then
      echo "  FAIL: fixture vendor file $rel is not at exact 0644" >&2
      return 1
    fi
  done
  ( cd "$repo" && "$TEST_BASH" .gaai/core/scripts/lib/yaml-runtime.sh --verify-tuple >/dev/null ) || {
    echo "  FAIL: fixture runtime tuple did not verify against its manifest" >&2
    return 1
  }
}

echo "Lifecycle caller cutover tests"
echo ""

echo "T1: stage-one production writer census"
if rg -n 'SCHEDULER.*--(set|journal)|chore_commit_(field|multi_field)|_commit_accumulated_backlog_drift|git (add|commit|rebase|push).*BACKLOG|git pull origin' \
    "$SCRIPTS/daemon-dispatch.sh" "$SCRIPTS/post-delivery-hook.sh" \
    >/dev/null 2>&1; then
  fail "T1: a stage-one legacy direct or ambient backlog publisher remains"
else
  pass "T1: dispatch and stop-hook writers use the journal boundary"
fi

REPO="$SANDBOX/repo"
setup_repo "$REPO"
PROJECT_DIR="$REPO"
BACKLOG_FILE="$REPO/$BACKLOG_REL"
SCHEDULER="$SCRIPTS/backlog-scheduler.sh"
TARGET_BRANCH=staging
LOCK_DIR="$REPO/.gaai/project/contexts/backlog/.delivery-locks"
STAGING_LOCK="$LOCK_DIR/.staging.lock"
mkdir -p "$LOCK_DIR"
source "$REPO/.gaai/core/scripts/lib/chore-commit.sh"
source "$REPO/.gaai/core/scripts/daemon-dispatch.sh"
source "$REPO/.gaai/core/scripts/lib/backlog-journal.sh"

echo "T1b: shared lock rejects symlinks without touching their target"
LOCK_ORIGINAL_PATH="$PATH"
LOCK_SENTINEL="$SANDBOX/lock-sentinel"
printf '%s\n' 'another-writer-evidence' > "$LOCK_SENTINEL"
rm -f "$STAGING_LOCK"
ln -s "$LOCK_SENTINEL" "$STAGING_LOCK"
T1B_RC=0
_lifecycle_with_staging_lock true >/dev/null 2>&1 || T1B_RC=$?
PATH="$LOCK_ORIGINAL_PATH"
if [[ "$T1B_RC" -ne 0 && "$(cat "$LOCK_SENTINEL")" == another-writer-evidence \
    && -L "$STAGING_LOCK" ]]; then
  pass "T1b: symlinked flock path fails closed without target mutation"
else
  fail "T1b: symlinked flock path was accepted or touched its target"
fi
rm -f "$STAGING_LOCK"

echo "T1b2: kernel serialization is independent of the caller PATH"
_lifecycle_prepare_flock_path "$STAGING_LOCK"
T1B2_READY="$SANDBOX/t1b2-ready"
T1B2_ENTERED="$SANDBOX/t1b2-entered"
LOCK_REAL_FLOCK=$(command -v flock 2>/dev/null || true)
if [[ -n "$LOCK_REAL_FLOCK" ]]; then
  ( "$LOCK_REAL_FLOCK" "$STAGING_LOCK" sh -c \
      'printf "%s\n" ready > "$1"; sleep 2' _ "$T1B2_READY" ) >/dev/null 2>&1 &
else
  ( exec 9< "$STAGING_LOCK"
    python3 - 9 "$T1B2_READY" <<'PY'
import fcntl, os, sys, time
fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)
with open(sys.argv[2], "w", encoding="ascii") as handle:
    handle.write("ready\n")
time.sleep(2)
PY
  ) >/dev/null 2>&1 &
fi
T1B2_HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -e "$T1B2_READY" ]] && break
  sleep 0.1
done
PATH=/usr/bin:/bin
GAAI_STAGING_LOCK_TIMEOUT_SEC=1
export PATH GAAI_STAGING_LOCK_TIMEOUT_SEC
T1B2_RC=0
_lifecycle_with_staging_lock sh -c 'printf "%s\n" entered > "$1"' _ "$T1B2_ENTERED" \
  >/dev/null 2>&1 || T1B2_RC=$?
PATH="$LOCK_ORIGINAL_PATH"
unset GAAI_STAGING_LOCK_TIMEOUT_SEC
export PATH
wait "$T1B2_HOLDER" 2>/dev/null || true
if [[ -e "$T1B2_READY" && "$T1B2_RC" -ne 0 && ! -e "$T1B2_ENTERED" ]]; then
  pass "T1b2: legacy flock and no-flock PATH callers share one kernel mutex"
else
  fail "T1b2: PATH-dependent backend selection allowed overlapping callbacks"
fi

echo "T1c: portable owner lock recovers after its process is killed"
NO_FLOCK_BIN="$SANDBOX/no-flock-bin"
mkdir -p "$NO_FLOCK_BIN"
for LOCK_TOOL in cat chmod ln mkdir mktemp python3 readlink rm rmdir sh sleep; do
  ln -s "$(command -v "$LOCK_TOOL")" "$NO_FLOCK_BIN/$LOCK_TOOL"
done
LOCK_REAL_RM=$(command -v rm)
PATH="$NO_FLOCK_BIN"
GAAI_STAGING_LOCK_TIMEOUT_SEC=3
export PATH GAAI_STAGING_LOCK_TIMEOUT_SEC
( _lifecycle_with_staging_lock sh -c 'kill -KILL "$PPID"; sleep 1' ) >/dev/null 2>&1 &
T1C_CRASH_PID=$!
wait "$T1C_CRASH_PID" 2>/dev/null || true
T1C_ORPHAN=false
[[ -L "${STAGING_LOCK}.d" ]] && T1C_ORPHAN=true
T1C_CALLBACK="$SANDBOX/t1c-callback"
T1C_RC=0
_lifecycle_with_staging_lock sh -c 'printf "%s\n" retry > "$1"' _ "$T1C_CALLBACK" \
  >/dev/null 2>&1 || T1C_RC=$?
if [[ "$T1C_ORPHAN" == true && "$T1C_RC" -eq 0 && ! -e "${STAGING_LOCK}.d" \
    && "$(cat "$T1C_CALLBACK" 2>/dev/null || true)" == retry ]]; then
  pass "T1c: dead owner is reclaimed and the retry acquires exactly once"
else
  fail "T1c: crash lock was lost prematurely or blocked the retry"
fi

echo "T1d: portable owner lock never reclaims a live holder"
GAAI_STAGING_LOCK_TIMEOUT_SEC=3
( _lifecycle_with_staging_lock sleep 2 ) >/dev/null 2>&1 &
T1D_HOLDER_PID=$!
T1D_OWNER_READY=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -L "${STAGING_LOCK}.d" ]]; then
    T1D_OWNER_READY=true
    break
  fi
  sleep 0.1
done
GAAI_STAGING_LOCK_TIMEOUT_SEC=1
T1D_CONTENDER_RC=0
_lifecycle_with_staging_lock true >/dev/null 2>&1 || T1D_CONTENDER_RC=$?
wait "$T1D_HOLDER_PID" 2>/dev/null || true
if [[ "$T1D_OWNER_READY" == true && "$T1D_CONTENDER_RC" -ne 0 \
    && ! -e "${STAGING_LOCK}.d" ]]; then
  pass "T1d: live owner remains exclusive and releases its own lock"
else
  fail "T1d: live owner was reclaimed, overlapped or left stale state"
fi

echo "T1e: concurrent orphan reclaimers serialize with their successors"
sh -c 'exit 0' &
T1E_DEAD_PID=$!
wait "$T1E_DEAD_PID" 2>/dev/null || true
T1E_LOCK_PARENT="${STAGING_LOCK%/*}"
T1E_OWNER_NAME="${STAGING_LOCK##*/}.d.owner.${T1E_DEAD_PID}.1.1"
printf '%s\n' "$T1E_DEAD_PID" > "$T1E_LOCK_PARENT/$T1E_OWNER_NAME"
chmod 600 "$T1E_LOCK_PARENT/$T1E_OWNER_NAME"
ln -s "$T1E_OWNER_NAME" "${STAGING_LOCK}.d"
T1E_ACTIVE="$SANDBOX/t1e-active"
T1E_OVERLAP="$SANDBOX/t1e-overlap"
T1E_CALLS="$SANDBOX/t1e-calls"
INNER_VERSION_LOG="$SANDBOX/inner-versions.log"
export T1E_ACTIVE T1E_OVERLAP T1E_CALLS INNER_VERSION_LOG
printf '#!%s\n' "$TEST_BASH" > "$NO_FLOCK_BIN/t1e-callback"
cat >> "$NO_FLOCK_BIN/t1e-callback" <<'CALLBACK'
printf '%s\t%s\n' "$BASH" "$BASH_VERSION" >> "$INNER_VERSION_LOG"
if ! mkdir "$T1E_ACTIVE" 2>/dev/null; then
  printf '%s\n' overlap > "$T1E_OVERLAP"
fi
printf '%s\n' call >> "$T1E_CALLS"
sleep 0.2
rmdir "$T1E_ACTIVE" 2>/dev/null || true
CALLBACK
chmod +x "$NO_FLOCK_BIN/t1e-callback"
GAAI_STAGING_LOCK_TIMEOUT_SEC=3
( _lifecycle_with_staging_lock t1e-callback ) >/dev/null 2>&1 &
T1E_A=$!
( _lifecycle_with_staging_lock t1e-callback ) >/dev/null 2>&1 &
T1E_B=$!
wait "$T1E_A"; T1E_A_RC=$?
wait "$T1E_B"; T1E_B_RC=$?
if [[ "$T1E_A_RC" -eq 0 && "$T1E_B_RC" -eq 0 && ! -e "$T1E_OVERLAP" \
    && "$(cat "$T1E_CALLS" 2>/dev/null || true)" == $'call\ncall' \
    && ! -e "${STAGING_LOCK}.d" ]]; then
  pass "T1e: competing reclaimers execute serially without moving a successor lock"
else
  fail "T1e: competing reclaimers overlapped, skipped or duplicated a callback"
fi

echo "T1f: killed releaser cannot delete a live successor lock"
T1F_RELEASE_STARTED="$SANDBOX/t1f-release-started"
T1F_RELEASE_DONE="$SANDBOX/t1f-release-done"
T1F_ENTERED="$SANDBOX/t1f-entered"
T1F_VIOLATION="$SANDBOX/t1f-violation"
T1F_PROCESS_LOCK="${STAGING_LOCK}.d"
export LOCK_REAL_RM T1F_RELEASE_STARTED T1F_RELEASE_DONE T1F_PROCESS_LOCK
"$LOCK_REAL_RM" -f "$NO_FLOCK_BIN/rm"
printf '#!%s\n' "$TEST_BASH" > "$NO_FLOCK_BIN/rm"
cat >> "$NO_FLOCK_BIN/rm" <<'RM'
printf '%s\t%s\n' "$BASH" "$BASH_VERSION" >> "$INNER_VERSION_LOG"
for target in "$@"; do
  if [[ "$target" == "$T1F_PROCESS_LOCK" && ! -e "$T1F_RELEASE_DONE" ]]; then
    printf '%s\n' started > "$T1F_RELEASE_STARTED"
    sleep 1
    "$LOCK_REAL_RM" "$@"
    printf '%s\n' done > "$T1F_RELEASE_DONE"
    exit $?
  fi
done
exec "$LOCK_REAL_RM" "$@"
RM
chmod +x "$NO_FLOCK_BIN/rm"
( _lifecycle_with_staging_lock true ) >/dev/null 2>&1 &
T1F_RELEASER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -e "$T1F_RELEASE_STARTED" ]] && break
  sleep 0.1
done
kill -KILL "$T1F_RELEASER" 2>/dev/null || true
wait "$T1F_RELEASER" 2>/dev/null || true
export T1F_RELEASE_DONE T1F_ENTERED T1F_VIOLATION
printf '#!%s\n' "$TEST_BASH" > "$NO_FLOCK_BIN/t1f-callback"
cat >> "$NO_FLOCK_BIN/t1f-callback" <<'CALLBACK'
printf '%s\t%s\n' "$BASH" "$BASH_VERSION" >> "$INNER_VERSION_LOG"
[[ -e "$T1F_RELEASE_DONE" ]] || printf '%s\n' overlap > "$T1F_VIOLATION"
printf '%s\n' entered > "$T1F_ENTERED"
CALLBACK
chmod +x "$NO_FLOCK_BIN/t1f-callback"
T1F_SUCCESSOR_RC=0
_lifecycle_with_staging_lock t1f-callback >/dev/null 2>&1 || T1F_SUCCESSOR_RC=$?
if [[ -e "$T1F_RELEASE_STARTED" && -e "$T1F_RELEASE_DONE" \
    && -e "$T1F_ENTERED" && ! -e "$T1F_VIOLATION" \
    && "$T1F_SUCCESSOR_RC" -eq 0 && ! -e "$T1F_PROCESS_LOCK" ]]; then
  pass "T1f: inherited kernel guard delays the successor until unlink completes"
else
  fail "T1f: delayed old unlink raced or deleted a successor lock"
fi
"$LOCK_REAL_RM" -f "$NO_FLOCK_BIN/rm"
ln -s "$LOCK_REAL_RM" "$NO_FLOCK_BIN/rm"

echo "T1g: failed portable release is reported and remains recoverable"
"$LOCK_REAL_RM" -f "$NO_FLOCK_BIN/rm"
printf '#!%s\n' "$TEST_BASH" > "$NO_FLOCK_BIN/rm"
cat >> "$NO_FLOCK_BIN/rm" <<'RM'
printf '%s\t%s\n' "$BASH" "$BASH_VERSION" >> "$INNER_VERSION_LOG"
for target in "$@"; do
  [[ "$target" == "$T1F_PROCESS_LOCK" ]] && exit 1
done
exec "$LOCK_REAL_RM" "$@"
RM
chmod +x "$NO_FLOCK_BIN/rm"
T1G_RELEASE_RC=0
_lifecycle_with_staging_lock true >/dev/null 2>&1 || T1G_RELEASE_RC=$?
T1G_RETAINED=false
[[ -L "$T1F_PROCESS_LOCK" ]] && T1G_RETAINED=true
"$LOCK_REAL_RM" -f "$NO_FLOCK_BIN/rm"
ln -s "$LOCK_REAL_RM" "$NO_FLOCK_BIN/rm"
T1G_RECOVERY_RC=0
_lifecycle_with_staging_lock true >/dev/null 2>&1 || T1G_RECOVERY_RC=$?
if [[ "$T1G_RELEASE_RC" -ne 0 && "$T1G_RETAINED" == true \
    && "$T1G_RECOVERY_RC" -eq 0 && ! -e "$T1F_PROCESS_LOCK" ]]; then
  pass "T1g: unlink failure cannot claim success and the exact owner is recoverable"
else
  fail "T1g: unlink failure was hidden or left an unrecoverable owner"
fi
T1G2_MATCH=true
T1G2_OBSERVED=""
while IFS=$'\t' read -r T1G2_BINARY T1G2_VERSION; do
  T1G2_OBSERVED="${T1G2_OBSERVED}${T1G2_BINARY}:${T1G2_VERSION}|"
  [[ "$T1G2_BINARY" == "$TEST_BASH" && -n "$T1G2_VERSION" ]] || T1G2_MATCH=false
done < "$INNER_VERSION_LOG"
if [[ -s "$INNER_VERSION_LOG" && "$T1G2_MATCH" != true ]]; then
  fail "T1g2: nested interpreter mismatch: $T1G2_OBSERVED"
elif [[ -s "$INNER_VERSION_LOG" && "$T1G2_MATCH" == true ]]; then
  pass "T1g2: nested harnesses record the selected interpreter and version"
else
  fail "T1g2: nested harness interpreter evidence is empty"
fi

echo "T1h: ownerless legacy directory remains fail-closed until its owner releases"
mkdir "${STAGING_LOCK}.d"
GAAI_STAGING_LOCK_TIMEOUT_SEC=1
T1H_RC=0
_lifecycle_with_staging_lock true >/dev/null 2>&1 || T1H_RC=$?
if [[ "$T1H_RC" -ne 0 && -d "${STAGING_LOCK}.d" ]]; then
  pass "T1h: legacy live lock is never guessed stale or replaced"
else
  fail "T1h: ownerless legacy lock was removed or entered"
fi
rmdir "${STAGING_LOCK}.d" 2>/dev/null || true
PATH="$LOCK_ORIGINAL_PATH"
unset GAAI_STAGING_LOCK_TIMEOUT_SEC
export PATH

echo "T1i: first-stage writer allowlist excludes S15 contexts and unauthenticated recovery"
for T1B_WRITER in daemon.claim pr-watcher; do
  if ( cd "$REPO" && _journal_persist_lifecycle TST-S14 "$T1B_WRITER" status in_progress ) \
      >/dev/null 2>&1; then
    fail "T1i: S15 writer context ${T1B_WRITER} was accepted"
  else
    pass "T1i: S15 writer context ${T1B_WRITER} is rejected"
  fi
done
if ( cd "$REPO" && _journal_persist_lifecycle TST-RECOVERY recovery.scan \
      phase_status failed status failed ) >/dev/null 2>&1; then
  fail "T1i: direct recovery.scan caller was accepted"
else
  pass "T1i: direct recovery.scan caller is rejected"
fi

echo "T1i2: base-held daemon caller is the only recovery.scan authority"
DAEMON_ASSET="$REPO/.gaai/core/scripts/delivery-daemon.sh"
cat > "$DAEMON_ASSET" <<'DAEMON'
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"
LOCK_DIR="$PROJECT_DIR/.gaai/project/contexts/backlog/.delivery-locks"
STAGING_LOCK="$LOCK_DIR/.staging.lock"
TARGET_BRANCH=staging
source "$SCRIPT_DIR/lib/chore-commit.sh"
source "$SCRIPT_DIR/daemon-dispatch.sh"
GAAI_LIFECYCLE_CALLER_ASSET=.gaai/core/scripts/delivery-daemon.sh
export GAAI_LIFECYCLE_CALLER_ASSET
_journal_persist_lifecycle TST-RECOVERY recovery.scan phase_status failed status failed
DAEMON
chmod 755 "$DAEMON_ASSET"
git -C "$REPO" add .gaai/core/scripts/delivery-daemon.sh
git -C "$REPO" commit -q -m 'fixture: base-held recovery caller'
git -C "$REPO" push -q origin staging
if "$TEST_BASH" "$DAEMON_ASSET" >"$SANDBOX/t1i2.out" 2>"$SANDBOX/t1i2.err" \
    && git -C "$REPO" show "origin/staging:$BACKLOG_REL" \
      | awk '/TST-RECOVERY/{s=1} s&&/status: failed/{a=1} s&&/phase_status: failed/{b=1} END{exit !(a&&b)}'; then
  pass "T1i2: exact base-held daemon caller projects the forward failure"
else
  fail "T1i2: exact base-held daemon caller did not project recovery.scan"
fi
COPIED_DAEMON="$REPO/.gaai/core/scripts/copied-daemon.sh"
if cp "$DAEMON_ASSET" "$COPIED_DAEMON" \
    && "$TEST_BASH" "$COPIED_DAEMON" >/dev/null 2>&1; then
  fail "T1i2: copied daemon caller was accepted"
else
  pass "T1i2: copied daemon caller is rejected"
fi
rm -f "$COPIED_DAEMON"
printf '\n# candidate tamper\n' >> "$DAEMON_ASSET"
if "$TEST_BASH" "$DAEMON_ASSET" >/dev/null 2>&1; then
  fail "T1i2: changed daemon asset was accepted"
else
  pass "T1i2: changed daemon asset is rejected"
fi
git -C "$REPO" checkout -- .gaai/core/scripts/delivery-daemon.sh

echo "T1j: predictable legacy state temporaries cannot redirect writes"
mkdir -p "$LOCK_DIR/.journal-runs"
chmod 700 "$LOCK_DIR/.journal-runs"
T1J_SENTINEL="$SANDBOX/t1j-sentinel"
T1J_LEGACY_TMP="$LOCK_DIR/.journal-runs/dispatch.plan.TST-TEMP.state.tmp.$$"
printf '%s\n' untouched > "$T1J_SENTINEL"
ln -s "$T1J_SENTINEL" "$T1J_LEGACY_TMP"
T1J_RC=0
( cd "$REPO" && _journal_persist_lifecycle TST-TEMP dispatch.plan status in_progress ) \
  >/dev/null 2>&1 || T1J_RC=$?
T1J_REMOTE=$(git -C "$REPO" show origin/staging:"$BACKLOG_REL")
if [[ "$T1J_RC" -eq 0 && "$(cat "$T1J_SENTINEL")" == untouched \
    && -L "$T1J_LEGACY_TMP" ]] \
    && printf '%s\n' "$T1J_REMOTE" | awk '/TST-TEMP/{s=1} s&&/status: in_progress/{found=1} END{exit !found}'; then
  pass "T1j: state writes use private exclusive temporaries and never follow the legacy name"
else
  fail "T1j: a predictable state temporary redirected or blocked the lifecycle write"
fi
rm -f "$T1J_LEGACY_TMP"

echo "T1k: run-state namespace mutations are directory-durable"
T1K_STATE_DIR="$SANDBOX/t1k-state"
T1K_SITE_DIR="$SANDBOX/t1k-site"
T1K_FSYNC_LOG="$SANDBOX/t1k-fsync.log"
mkdir -p "$T1K_STATE_DIR" "$T1K_SITE_DIR"
chmod 700 "$T1K_STATE_DIR"
cat > "$T1K_SITE_DIR/sitecustomize.py" <<'PY'
import os
import stat

_real_fsync = os.fsync
_real_open = os.open

def _trace(event):
    with open(os.environ["T1K_FSYNC_LOG"], "a", encoding="ascii") as handle:
        handle.write(event + "\n")

def _traced_fsync(fd):
    if stat.S_ISDIR(os.fstat(fd).st_mode):
        _trace("directory")
    return _real_fsync(fd)

def _traced_open(path, flags, mode=0o777, *, dir_fd=None):
    if (isinstance(path, str) and path.startswith(".dispatch.plan.TST-DURABLE.state.")
            and flags & os.O_CREAT):
        _trace("relative-create" if dir_fd is not None else "path-create")
    if dir_fd is None:
        return _real_open(path, flags, mode)
    return _real_open(path, flags, mode, dir_fd=dir_fd)

os.fsync = _traced_fsync
os.open = _traced_open
PY
T1K_STATE="$T1K_STATE_DIR/dispatch.plan.TST-DURABLE.state"
T1K_RC=0
PYTHONPATH="$T1K_SITE_DIR" T1K_FSYNC_LOG="$T1K_FSYNC_LOG" \
  _lifecycle_write_run_state "$T1K_STATE" create \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || T1K_RC=$?
PYTHONPATH="$T1K_SITE_DIR" T1K_FSYNC_LOG="$T1K_FSYNC_LOG" \
  _lifecycle_write_run_state "$T1K_STATE" append status \
    00000000000000000000-aaaaaaaaaaaaaaaa.json \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || T1K_RC=$?
PYTHONPATH="$T1K_SITE_DIR" T1K_FSYNC_LOG="$T1K_FSYNC_LOG" \
  _lifecycle_write_run_state "$T1K_STATE" remove || T1K_RC=$?
T1K_DIR_SYNCS=$(awk '$0 == "directory" { count++ } END { print count + 0 }' "$T1K_FSYNC_LOG" 2>/dev/null)
T1K_RELATIVE_CREATES=$(awk '$0 == "relative-create" { count++ } END { print count + 0 }' "$T1K_FSYNC_LOG" 2>/dev/null)
T1K_PATH_CREATES=$(awk '$0 == "path-create" { count++ } END { print count + 0 }' "$T1K_FSYNC_LOG" 2>/dev/null)
if [[ "$T1K_RC" -eq 0 && "$T1K_DIR_SYNCS" -eq 3 \
    && "$T1K_RELATIVE_CREATES" -eq 2 && "$T1K_PATH_CREATES" -eq 0 \
    && ! -e "$T1K_STATE" ]]; then
  pass "T1k: state temporaries stay dir-bound and every namespace mutation is durable"
else
  fail "T1k: run-state temporary or namespace durability escaped the validated directory"
fi

echo "T2: stale ambient drift cannot bleed into a dispatch transition"
python3 - "$BACKLOG_FILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace("- id: TST-OTHER\n  status: refined", "- id: TST-OTHER\n  status: failed"))
PY
( cd "$REPO" && _journal_persist_lifecycle TST-S14 dispatch.plan \
    status in_progress started_at 2026-08-24T12:00:00Z )
T2_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if printf '%s\n' "$T2_REMOTE" | awk '/TST-S14/{s=1} s&&/status: in_progress/{a=1} /TST-OTHER/{o=1} o&&/status: refined/{b=1} END{exit !(a&&b)}'; then
  pass "T2: target claim landed and unrelated stale drift was discarded"
else
  fail "T2: target claim missing or stale unrelated row leaked"
fi

echo "T3: blocked projection suppresses authority and resumes with one run"
git -C "$REPO" reset --mixed origin/staging >/dev/null
python3 - "$BACKLOG_FILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text() + "- id: TST-RESTART\n  status: refined\n  phase_status: not_started\n")
PY
git -C "$REPO" add "$BACKLOG_REL"
git -C "$REPO" commit -q -m fixture-restart
git -C "$REPO" push -q origin staging
GAAI_BACKLOG_PROJECTION_FAULT=before_push
export GAAI_BACKLOG_PROJECTION_FAULT
T3_RC=0
( cd "$REPO" && _journal_persist_lifecycle TST-RESTART dispatch.plan status in_progress ) \
  2>"$SANDBOX/t3-blocked.log" || T3_RC=$?
unset GAAI_BACKLOG_PROJECTION_FAULT
T3_BEFORE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
T3_STATE="$LOCK_DIR/.journal-runs/dispatch.plan.TST-RESTART.state"
if [[ "$T3_RC" -ne 0 && -f "$T3_STATE" ]] \
    && grep -q 'outcome=retryable reason=push_not_attempted' "$SANDBOX/t3-blocked.log" \
    && ! printf '%s\n' "$T3_BEFORE" | awk '/TST-RESTART/{s=1} s&&/status: in_progress/{found=1} END{exit !found}'; then
  pass "T3a: retryable projection left remote unchanged and run evidence retained"
else
  fail "T3a: retryable projection was misclassified, authorized state or lost evidence"
fi
T3_MANIFEST=$(_journal_inspect_pending_lifecycle TST-RESTART dispatch.plan 2>/dev/null || true)
IFS=$'\t' read -r T3_TOKEN T3_SOURCE T3_TOKEN_DIGEST T3_STATE_DIGEST T3_RECORDS_DIGEST \
  <<< "${T3_MANIFEST%%$'\n'*}"
T3_EXPECTED_TOKEN_DIGEST=$(printf '%s' "$T3_TOKEN" | shasum -a 256 | awk '{print $1}')
if [[ "$T3_TOKEN" =~ ^[0-9a-f]{64}$ && "$T3_SOURCE" =~ ^[0-9a-f]{40}$ \
    && "$T3_TOKEN_DIGEST" == "$T3_EXPECTED_TOKEN_DIGEST" \
    && "$T3_STATE_DIGEST" =~ ^[0-9a-f]{64}$ \
    && "$T3_RECORDS_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
  pass "T3a2: retained inspection exposes the actual token/source/record digests"
else
  fail "T3a2: retained inspection did not bind the real attempt"
fi
T3_RECORD_BASENAME=$(printf '%s\n' "$T3_MANIFEST" | awk -F '\t' 'NR == 2 {print $2}')
T3_WRITER_KEY=$(printf '%s' dispatch.plan | shasum -a 256 | awk '{print $1}')
T3_RECORD="$LOCK_DIR/journal/writers/$T3_WRITER_KEY/records/$T3_RECORD_BASENAME"
cp "$T3_RECORD" "$SANDBOX/t3-record.saved"
printf ' ' >> "$T3_RECORD"
if _journal_inspect_pending_lifecycle TST-RESTART dispatch.plan \
    >"$SANDBOX/t3-tamper.out" 2>"$SANDBOX/t3-tamper.err"; then
  fail "T3a3: changed retained record bytes were accepted"
elif [[ ! -s "$SANDBOX/t3-tamper.out" && ! -s "$SANDBOX/t3-tamper.err" ]]; then
  pass "T3a3: changed retained record bytes block without leaking evidence"
else
  fail "T3a3: changed retained record rejection leaked evidence"
fi
mv "$SANDBOX/t3-record.saved" "$T3_RECORD"
chmod 600 "$T3_RECORD"
cp "$T3_RECORD" "$SANDBOX/t3-record.original"
cp "$T3_STATE" "$SANDBOX/t3-state.original"
for T3_KIND in extra_key schema source_blob sequence emitted_at intent_mismatch; do
  cp "$SANDBOX/t3-record.original" "$T3_RECORD"
  cp "$SANDBOX/t3-state.original" "$T3_STATE"
  python3 - "$T3_RECORD" "$T3_STATE" "$T3_KIND" <<'PY'
import hashlib, json, sys

record_path, state_path, kind = sys.argv[1:]
with open(record_path, encoding="utf-8") as handle:
    wrapper = json.load(handle)
record = wrapper["record"]
if kind == "extra_key":
    record["unexpected"] = "x"
elif kind == "schema":
    record["schema_version"] = "9.9.9"
elif kind == "source_blob":
    record["source_blob"] = "not-an-object"
elif kind == "sequence":
    record["sequence"] = 0
elif kind == "emitted_at":
    record["emitted_at"] = "not-a-time"
elif kind == "intent_mismatch":
    record["intent_digest"] = "f" * 64
wire = lambda value: json.dumps(
    value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
)
wrapper["digest"] = hashlib.sha256(wire(record).encode("utf-8")).hexdigest()
with open(record_path, "w", encoding="utf-8") as handle:
    handle.write(wire(wrapper) + "\n")
with open(state_path, encoding="ascii") as handle:
    lines = handle.read().splitlines()
parts = lines[1].split("\t")
parts[2] = wrapper["digest"]
lines[1] = "\t".join(parts)
with open(state_path, "w", encoding="ascii") as handle:
    handle.write("\n".join(lines) + "\n")
PY
  chmod 600 "$T3_RECORD" "$T3_STATE"
  if _journal_inspect_pending_lifecycle TST-RESTART dispatch.plan \
      >"$SANDBOX/t3-semantic.out" 2>"$SANDBOX/t3-semantic.err"; then
    fail "T3a4: semantic record forgery $T3_KIND was accepted"
  elif [[ ! -s "$SANDBOX/t3-semantic.out" && ! -s "$SANDBOX/t3-semantic.err" ]]; then
    pass "T3a4: semantic record forgery $T3_KIND is rejected"
  else
    fail "T3a4: semantic record forgery $T3_KIND leaked evidence"
  fi
done
for T3_CODEPOINT in 2028 2029; do
  cp "$SANDBOX/t3-record.original" "$T3_RECORD"
  cp "$SANDBOX/t3-state.original" "$T3_STATE"
  T3_FORGED_BASENAME=$(python3 - "$T3_RECORD" "$T3_STATE" "$T3_CODEPOINT" <<'PY'
import hashlib, json, os, sys

record_path, state_path, codepoint = sys.argv[1:]
with open(record_path, encoding="utf-8") as handle:
    wrapper = json.load(handle)
record = wrapper["record"]
record["field"] = "blocked_reason"
record["old_value"] = None
record["new_value"] = chr(int(codepoint, 16))
intent = {key: record[key] for key in (
    "schema_version", "story_id", "field", "old_value", "new_value",
    "source_commit", "source_blob", "writer_context", "run_token",
)}
wire = lambda value: json.dumps(
    value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
)
intent_digest = hashlib.sha256(wire(intent).encode("utf-8")).hexdigest()
record["intent_digest"] = intent_digest
wrapper["intent_digest"] = intent_digest
wrapper["digest"] = hashlib.sha256(wire(record).encode("utf-8")).hexdigest()
basename = f"{record['sequence']:020d}-{intent_digest[:16]}.json"
forged_path = os.path.join(os.path.dirname(record_path), basename)
with open(forged_path, "w", encoding="utf-8") as handle:
    handle.write(wire(wrapper) + "\n")
os.chmod(forged_path, 0o600)
with open(state_path, encoding="ascii") as handle:
    lines = handle.read().splitlines()
lines[1] = "\t".join(("blocked_reason", basename, wrapper["digest"]))
with open(state_path, "w", encoding="ascii") as handle:
    handle.write("\n".join(lines) + "\n")
print(basename)
PY
  )
  chmod 600 "$T3_STATE"
  if _journal_inspect_pending_lifecycle TST-RESTART dispatch.plan \
      >"$SANDBOX/t3-policy.out" 2>"$SANDBOX/t3-policy.err"; then
    fail "T3a5: blocked_reason U+$T3_CODEPOINT policy forgery was accepted"
  elif [[ ! -s "$SANDBOX/t3-policy.out" && ! -s "$SANDBOX/t3-policy.err" ]]; then
    pass "T3a5: blocked_reason U+$T3_CODEPOINT policy forgery is rejected"
  else
    fail "T3a5: blocked_reason U+$T3_CODEPOINT rejection leaked evidence"
  fi
  rm -f "$(dirname "$T3_RECORD")/$T3_FORGED_BASENAME"
done
mv "$SANDBOX/t3-record.original" "$T3_RECORD"
mv "$SANDBOX/t3-state.original" "$T3_STATE"
chmod 600 "$T3_RECORD" "$T3_STATE"

# The empty-run discard must never reach a run state that did project a field.
# This one carries exactly one valid row, so the discard has to refuse it and
# leave the file byte-identical, and the settle classifier has to report it as
# a live pending run (rc 0) rather than absence.
cp "$T3_STATE" "$SANDBOX/t3-rowed-state.expected"
T3AR_DISCARD_RC=0
IFS=$'\t' read -r _ _ _ T3AR_STATE_DIGEST _ \
  <<< "$(_journal_inspect_pending_lifecycle TST-RESTART dispatch.plan | head -1)"
( cd "$REPO" && _journal_discard_empty_lifecycle TST-RESTART dispatch.plan \
  "$T3AR_STATE_DIGEST" ) 2>/dev/null || T3AR_DISCARD_RC=$?
T3AR_SETTLE_RC=0
T3AR_SETTLE_OUT=$(_journal_settle_pending_lifecycle TST-RESTART dispatch.plan \
  2>/dev/null) || T3AR_SETTLE_RC=$?
if [[ "$T3AR_DISCARD_RC" -ne 0 ]] \
    && cmp -s "$T3_STATE" "$SANDBOX/t3-rowed-state.expected" \
    && [[ "$T3AR_SETTLE_RC" -eq 0 && "$T3AR_SETTLE_OUT" == *$'\n'* ]]; then
  pass "T3a6: a run state carrying a projected field is never discarded"
else
  fail "T3a6: a projected-field run state was discarded or misclassified"
fi
unset T3AR_DISCARD_RC T3AR_SETTLE_RC T3AR_SETTLE_OUT T3AR_STATE_DIGEST

T3B_RC=0
( cd "$REPO" && _journal_resume_pending_lifecycle TST-RESTART dispatch.plan ) \
  2>"$SANDBOX/t3-resume.log" || T3B_RC=$?
T3_AFTER=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T3B_RC" -eq 0 ]] \
    && printf '%s\n' "$T3_AFTER" | awk '/TST-RESTART/{s=1} s&&/status: in_progress/{found=1} END{exit !found}' \
    && [[ ! -f "$T3_STATE" ]]; then
  pass "T3b: retry finalized the retained record and retired run state"
else
  sed 's/^/    /' "$SANDBOX/t3-resume.log" >&2
  T3_DIAG_RC=0
  _journal_inspect_pending_lifecycle TST-RESTART dispatch.plan \
    >"$SANDBOX/t3-resume.manifest" 2>"$SANDBOX/t3-resume.inspect.err" || T3_DIAG_RC=$?
  printf '    resume_rc=%s inspect_rc=%s state_present=%s\n' \
    "$T3B_RC" "$T3_DIAG_RC" "$([[ -f "$T3_STATE" ]] && printf true || printf false)" >&2
  sed 's/^/    manifest: /' "$SANDBOX/t3-resume.manifest" >&2
  sed 's/^/    inspect: /' "$SANDBOX/t3-resume.inspect.err" >&2
  fail "T3b: retained run did not resume exactly"
fi

# A header-only run state is the footprint of a writer killed between the
# state-file create and its first record append: a run token exists, but no
# field was ever projected. It names no transition, so there is nothing to
# resume and nothing to verify — and while it stays on disk every later cycle
# re-reads it, refuses, and burns one retry, which wedged a live Story for
# three consecutive cycles until an operator moved the file aside by hand.
# It is therefore discarded and reported as absence (rc 2, the dispatcher's
# "nothing pending" result). This replaces the earlier contract, which
# preserved the file as "retained ambiguity": there is no evidence to
# preserve when no record was emitted, and the row-bearing case above still
# proves that a run state which DID project a field is never touched here.
echo "T3c: header-only run state is discarded as absence"
backlog_journal_begin_run "$BACKLOG_FILE" dispatch.impl
T3C_STATE="$LOCK_DIR/.journal-runs/dispatch.impl.TST-EMPTY-RUN.state"
T3C_SOURCE=$(git -C "$REPO" rev-parse origin/staging)
_lifecycle_write_run_state "$T3C_STATE" create \
  "$BACKLOG_JOURNAL_RUN_TOKEN" "$T3C_SOURCE"
T3C_RC=0
( cd "$REPO" && _journal_resume_pending_lifecycle TST-EMPTY-RUN dispatch.impl ) \
  >"$SANDBOX/t3c.out" 2>"$SANDBOX/t3c.err" || T3C_RC=$?
if [[ "$T3C_RC" -eq 2 && ! -e "$T3C_STATE" ]] \
    && grep -q 'outcome=discarded reason=empty_run_state' "$SANDBOX/t3c.err" \
    && grep -q 'story=TST-EMPTY-RUN writer=dispatch.impl' "$SANDBOX/t3c.err"; then
  pass "T3c: empty run state is discarded and reported as nothing pending"
else
  sed 's/^/    /' "$SANDBOX/t3c.err" >&2
  printf '    resume_rc=%s state_present=%s\n' "$T3C_RC" \
    "$([[ -e "$T3C_STATE" ]] && printf true || printf false)" >&2
  fail "T3c: empty run state was not discarded as absence"
fi

echo "T3c2: settle classifies and discards a header-only run state"
backlog_journal_begin_run "$BACKLOG_FILE" dispatch.qa
T3C2_STATE="$LOCK_DIR/.journal-runs/dispatch.qa.TST-EMPTY-RUN.state"
_lifecycle_write_run_state "$T3C2_STATE" create \
  "$BACKLOG_JOURNAL_RUN_TOKEN" "$T3C_SOURCE"
T3C2_RC=0
( cd "$REPO" && _journal_settle_pending_lifecycle TST-EMPTY-RUN dispatch.qa ) \
  >"$SANDBOX/t3c2.out" 2>"$SANDBOX/t3c2.err" || T3C2_RC=$?
if [[ "$T3C2_RC" -eq 2 && ! -e "$T3C2_STATE" && ! -s "$SANDBOX/t3c2.out" ]] \
    && grep -q 'outcome=discarded reason=empty_run_state' "$SANDBOX/t3c2.err"; then
  pass "T3c2: settle reports absence after discarding the empty run state"
else
  fail "T3c2: settle did not discard the empty run state as absence"
fi

echo "T3c3: a malformed run-state header still fails closed"
backlog_journal_begin_run "$BACKLOG_FILE" dispatch.commit
T3C3_STATE="$LOCK_DIR/.journal-runs/dispatch.commit.TST-EMPTY-RUN.state"
_lifecycle_write_run_state "$T3C3_STATE" create \
  "$BACKLOG_JOURNAL_RUN_TOKEN" "$T3C_SOURCE"
# Truncate the run token: the header no longer parses, so this is a corrupt
# file rather than an un-started run, and must never be silently erased.
printf 'deadbeef\t%s\n' "$T3C_SOURCE" > "$T3C3_STATE"
chmod 600 "$T3C3_STATE"
cp "$T3C3_STATE" "$SANDBOX/t3c3-state.expected"
T3C3_RC=0
( cd "$REPO" && _journal_resume_pending_lifecycle TST-EMPTY-RUN dispatch.commit ) \
  >/dev/null 2>"$SANDBOX/t3c3.err" || T3C3_RC=$?
T3C3_SETTLE_RC=0
( cd "$REPO" && _journal_settle_pending_lifecycle TST-EMPTY-RUN dispatch.commit ) \
  >/dev/null 2>&1 || T3C3_SETTLE_RC=$?
if [[ "$T3C3_RC" -eq 1 && "$T3C3_SETTLE_RC" -eq 1 ]] \
    && cmp -s "$T3C3_STATE" "$SANDBOX/t3c3-state.expected"; then
  pass "T3c3: corrupt run-state header refuses and preserves the file"
else
  fail "T3c3: corrupt run-state header was accepted or erased"
fi
rm -f "$T3C3_STATE"
T3D_RC=0
_journal_inspect_pending_lifecycle TST-ABSENT dispatch.plan >/dev/null 2>&1 || T3D_RC=$?
if [[ "$T3D_RC" -eq 2 ]]; then
  pass "T3d: missing retained state is explicit absence, never a pseudo-token"
else
  fail "T3d: missing retained state was not classified as absence"
fi

echo "T4: integral cost metadata retains its canonical magnitude"
T4_RC=0
( cd "$REPO" && _journal_persist_lifecycle E999S99 post-delivery-hook cost_usd 100 ) || T4_RC=$?
T4_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T4_RC" -eq 0 ]] \
    && printf '%s\n' "$T4_REMOTE" | awk '/E999S99/{s=1} s&&/cost_usd: 100/{found=1} END{exit !found}'; then
  pass "T4: integral cost remains 100 through record and remote verification"
else
  fail "T4: integral cost was rejected or changed magnitude"
fi

echo "T5: base-held assets and private run state reject candidate tamper"
printf '\n# candidate tamper\n' >> "$REPO/.gaai/core/scripts/daemon-dispatch.sh"
T5_ASSET_RC=0
( cd "$REPO" && _journal_persist_lifecycle TST-ASSET dispatch.plan status in_progress ) \
  2>"$SANDBOX/t5-asset.log" || T5_ASSET_RC=$?
git -C "$REPO" checkout -- .gaai/core/scripts/daemon-dispatch.sh
T5_ASSET_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T5_ASSET_RC" -ne 0 ]] \
    && grep -q 'outcome=rejected reason=asset_untrusted' "$SANDBOX/t5-asset.log" \
    && printf '%s\n' "$T5_ASSET_REMOTE" | awk '/TST-ASSET/{s=1} s&&/status: refined/{found=1} END{exit !found}'; then
  pass "T5a: candidate asset tamper cannot author lifecycle state"
else
  fail "T5a: candidate asset tamper was not rejected before persistence"
fi

# T5d (the base-held runtime falsifier): replace the checked-out parser archive
# with different bytes AND rewrite the manifest so the pair stays internally
# consistent — matching size and digest. A self-consistency check alone would
# accept this; only the base-held comparison against the exact remote blob
# refuses it. Without that binding a candidate could leave the three original
# assets pristine and swap the parser underneath them.
T5D_ARCHIVE="$REPO/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
T5D_MANIFEST="$REPO/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json"
cp "$T5D_ARCHIVE" "$SANDBOX/t5d-archive.orig"
cp "$T5D_MANIFEST" "$SANDBOX/t5d-manifest.orig"
python3 - "$T5D_ARCHIVE" "$T5D_MANIFEST" <<'PY'
import hashlib, json, sys

archive_path, manifest_path = sys.argv[1:3]
data = open(archive_path, "rb").read() + b"\n# consistent tamper\n"
open(archive_path, "wb").write(data)
manifest = json.loads(open(manifest_path, "rb").read().decode("utf-8"))
manifest["output"]["size_bytes"] = len(data)
manifest["output"]["sha256"] = hashlib.sha256(data).hexdigest()
open(manifest_path, "w").write(
    json.dumps(manifest, sort_keys=True, indent=2, separators=(",", ": "),
               ensure_ascii=True) + "\n")
PY
chmod 0644 "$T5D_ARCHIVE" "$T5D_MANIFEST"
T5D_RC=0
( cd "$REPO" && _journal_persist_lifecycle TST-OTHER dispatch.plan status in_progress ) \
  2>"$SANDBOX/t5d-runtime.log" || T5D_RC=$?
cp "$SANDBOX/t5d-archive.orig" "$T5D_ARCHIVE"
cp "$SANDBOX/t5d-manifest.orig" "$T5D_MANIFEST"
chmod 0644 "$T5D_ARCHIVE" "$T5D_MANIFEST"
T5D_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T5D_RC" -ne 0 ]] \
    && grep -q 'outcome=rejected reason=asset_untrusted' "$SANDBOX/t5d-runtime.log" \
    && printf '%s\n' "$T5D_REMOTE" | awk '/TST-OTHER/{s=1} s&&/status: refined/{found=1} END{exit !found}'; then
  pass "T5d: an internally consistent runtime tamper is still base-held-rejected"
else
  fail "T5d: consistent archive+manifest tamper was not rejected before persistence"
fi

mkdir -p "$LOCK_DIR/.journal-runs"
chmod 700 "$LOCK_DIR/.journal-runs"
ln -s "$SANDBOX/missing-run-state" "$LOCK_DIR/.journal-runs/dispatch.plan.TST-SYMLINK.state"
T5_SYMLINK_RC=0
( cd "$REPO" && _journal_persist_lifecycle TST-SYMLINK dispatch.plan status in_progress ) \
  2>"$SANDBOX/t5-symlink.log" || T5_SYMLINK_RC=$?
T5_SYMLINK_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T5_SYMLINK_RC" -ne 0 ]] \
    && grep -q 'outcome=rejected reason=run_state_invalid' "$SANDBOX/t5-symlink.log" \
    && [[ -L "$LOCK_DIR/.journal-runs/dispatch.plan.TST-SYMLINK.state" ]] \
    && printf '%s\n' "$T5_SYMLINK_REMOTE" | awk '/TST-SYMLINK/{s=1} s&&/status: refined/{found=1} END{exit !found}'; then
  pass "T5b: symlinked run state is retained but never adopted"
else
  fail "T5b: symlinked run state was replaced, adopted or published"
fi

rm -f "$LOCK_DIR/.journal-runs/dispatch.plan.TST-SYMLINK.state"
printf '%064d\t%040d\n' 1 2 > "$LOCK_DIR/.journal-runs/dispatch.plan.TST-SYMLINK.state"
chmod 644 "$LOCK_DIR/.journal-runs/dispatch.plan.TST-SYMLINK.state"
T5_MODE_RC=0
( cd "$REPO" && _journal_resume_pending_lifecycle TST-SYMLINK dispatch.plan ) \
  2>"$SANDBOX/t5-mode.log" || T5_MODE_RC=$?
if [[ "$T5_MODE_RC" -ne 0 ]] \
    && python3 - "$LOCK_DIR/.journal-runs/dispatch.plan.TST-SYMLINK.state" <<'PY'
import os, stat, sys
raise SystemExit(0 if stat.S_IMODE(os.lstat(sys.argv[1]).st_mode) == 0o644 else 1)
PY
then
  pass "T5c: permissive run state is retained but never adopted"
else
  fail "T5c: permissive run state was rewritten or adopted"
fi

echo "T6: competing current-predecessor records are explicitly conflicted"
CONFLICT_SOURCE=$(git -C "$REPO" rev-parse origin/staging)
backlog_journal_begin_run "$BACKLOG_FILE" dispatch.plan
CONFLICT_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
GAAI_BACKLOG_JOURNAL_SOURCE_REF="$CONFLICT_SOURCE" \
  backlog_journal_emit "$BACKLOG_FILE" TST-CONFLICT status in_progress dispatch.plan "$CONFLICT_TOKEN" >/dev/null
CONFLICT_RECORD="$BACKLOG_JOURNAL_RECORD_PATH"
CONFLICT_DIGEST="$BACKLOG_JOURNAL_RECORD_DIGEST"
CONFLICT_BASENAME=$(basename "$CONFLICT_RECORD")
printf '%s\t%s\nstatus\t%s\t%s\n' \
  "$CONFLICT_TOKEN" "$CONFLICT_SOURCE" "$CONFLICT_BASENAME" "$CONFLICT_DIGEST" \
  > "$LOCK_DIR/.journal-runs/dispatch.plan.TST-CONFLICT.state"
chmod 600 "$LOCK_DIR/.journal-runs/dispatch.plan.TST-CONFLICT.state"
backlog_journal_begin_run "$BACKLOG_FILE" dispatch.impl
CONFLICT_PEER_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
GAAI_BACKLOG_JOURNAL_SOURCE_REF="$CONFLICT_SOURCE" \
  backlog_journal_emit "$BACKLOG_FILE" TST-CONFLICT status in_progress dispatch.impl "$CONFLICT_PEER_TOKEN" >/dev/null
T6_CONFLICT_RC=0
( cd "$REPO" && _journal_resume_pending_lifecycle TST-CONFLICT dispatch.plan ) \
  2>"$SANDBOX/t6-conflict.log" || T6_CONFLICT_RC=$?
T6_CONFLICT_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T6_CONFLICT_RC" -ne 0 ]] \
    && grep -q 'outcome=conflicted reason=no_eligible_record' "$SANDBOX/t6-conflict.log" \
    && [[ -f "$LOCK_DIR/.journal-runs/dispatch.plan.TST-CONFLICT.state" ]] \
    && printf '%s\n' "$T6_CONFLICT_REMOTE" | awk '/TST-CONFLICT/{s=1} s&&/status: refined/{found=1} END{exit !found}'; then
  pass "T6: conflicted records remain recoverable and cannot claim completion"
else
  sed 's/^/    /' "$SANDBOX/t6-conflict.log" >&2
  T6_DIAG_RC=0
  _journal_inspect_pending_lifecycle TST-CONFLICT dispatch.plan \
    >"$SANDBOX/t6-conflict.manifest" 2>"$SANDBOX/t6-conflict.inspect.err" || T6_DIAG_RC=$?
  printf '    resume_rc=%s inspect_rc=%s\n' "$T6_CONFLICT_RC" "$T6_DIAG_RC" >&2
  sed 's/^/    manifest: /' "$SANDBOX/t6-conflict.manifest" >&2
  sed 's/^/    inspect: /' "$SANDBOX/t6-conflict.inspect.err" >&2
  fail "T6: conflicted records were misclassified, retired or published"
fi

echo "T6b: retryable admission loss uses policy-ratified boundary edges"
T6B_FINAL_RC=0
( cd "$REPO" && _route_admission_block TST-RETRY-FINAL trace-final final \
    blocked:stale_evidence ) >/dev/null 2>&1 || T6B_FINAL_RC=$?
T6B_FINAL_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T6B_FINAL_RC" -eq 0 \
    && "$(cat "$LOCK_DIR/.qa-route-TST-RETRY-FINAL" 2>/dev/null || true)" == impl ]] \
    && printf '%s\n' "$T6B_FINAL_REMOTE" \
      | awk '/TST-RETRY-FINAL/{s=1} s&&/phase_status: implemented/{found=1} END{exit !found}'; then
  pass "T6b: final retry rewinds qa_passed to implemented through the real policy"
else
  fail "T6b: final retry used an invalid edge or lost its IMPL route"
fi

T6B_QA_RC=0
( cd "$REPO" && _route_admission_block TST-RETRY-QA trace-qa pre_qa \
    blocked:stale_evidence ) >/dev/null 2>&1 || T6B_QA_RC=$?
T6B_QA_REMOTE=$(git -C "$REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T6B_QA_RC" -eq 0 \
    && "$(cat "$LOCK_DIR/.qa-route-TST-RETRY-QA" 2>/dev/null || true)" == impl ]] \
    && printf '%s\n' "$T6B_QA_REMOTE" \
      | awk '/TST-RETRY-QA/{s=1} s&&/phase_status: qa_failed/{found=1} END{exit !found}'; then
  pass "T6b: pre-QA retry retains the implemented to qa_failed policy edge"
else
  fail "T6b: pre-QA retry no longer preserves its ratified edge"
fi

echo "T7: Stop hook blocks later side effects until metadata projection verifies"
HOOK_REPO="$SANDBOX/hook-repo"
setup_repo "$HOOK_REPO"
git -C "$HOOK_REPO" commit -q --allow-empty -m 'chore(E999S99): in_progress'
git -C "$HOOK_REPO" commit -q --allow-empty -m 'chore(E999S99): done [delivery]'
git -C "$HOOK_REPO" push -q origin staging
mkdir -p "$HOOK_REPO/.gaai/project/contexts/backlog/.delivery-logs"
printf '{"type":"result","total_cost_usd":1.25}\n' \
  > "$HOOK_REPO/.gaai/project/contexts/backlog/.delivery-logs/E999S99.log"
T7_RC=0
printf '{"transcript_path":""}\n' | GAAI_BACKLOG_PROJECTION_FAULT=before_push \
  "$TEST_BASH" "$HOOK_REPO/.gaai/core/scripts/post-delivery-hook.sh" >/dev/null 2>&1 || T7_RC=$?
T7_REMOTE=$(git -C "$HOOK_REPO" show "origin/staging:$BACKLOG_REL")
if [[ "$T7_RC" -ne 0 ]] \
    && printf '%s\n' "$T7_REMOTE" | awk '/E999S99/{s=1} s&&/cost_usd: null/{found=1} END{exit !found}' \
    && [[ ! -e "$HOOK_REPO/.gaai/project/contexts/backlog/.freshness-flags/tier1-refresh-needed" ]]; then
  pass "T7a: Stop hook failure produced no remote metadata or later freshness side effect"
else
  fail "T7a: Stop hook failed open"
fi
printf '{"transcript_path":""}\n' \
  | "$TEST_BASH" "$HOOK_REPO/.gaai/core/scripts/post-delivery-hook.sh" >/dev/null 2>&1
T7_AFTER=$(git -C "$HOOK_REPO" show "origin/staging:$BACKLOG_REL")
if printf '%s\n' "$T7_AFTER" | awk '/E999S99/{s=1} s&&/cost_usd: 1.25/{found=1} END{exit !found}'; then
  pass "T7b: Stop hook restart finalized the retained metadata"
else
  fail "T7b: Stop hook restart did not recover metadata"
fi

echo "T8: full retained projection settles once and a fresh restart retires orphan context"
RETAINED_DAEMON="$REPO/.gaai/core/scripts/delivery-daemon.sh"
cat > "$RETAINED_DAEMON" <<'DAEMON_HEAD'
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_ROOT="$PROJECT_DIR"
BACKLOG_REL=.gaai/project/contexts/backlog/active.backlog.yaml
BACKLOG_FILE="$PROJECT_DIR/$BACKLOG_REL"
BACKLOG="$BACKLOG_FILE"
LOCK_DIR="$PROJECT_DIR/.gaai/project/contexts/backlog/.delivery-locks"
STAGING_LOCK="$LOCK_DIR/.staging.lock"
TARGET_BRANCH=staging
GAAI_WORKTREES_BASE="$PROJECT_DIR/.worktrees"
mkdir -p "$GAAI_WORKTREES_BASE" "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
log() { printf '%s\n' "$*" >&2; }
source "$SCRIPT_DIR/lib/chore-commit.sh"
source "$SCRIPT_DIR/lib/backlog-yaml.sh"
source "$SCRIPT_DIR/lib/worktree-integrity.sh"
source "$SCRIPT_DIR/lib/stuck-classifier.sh"
source "$SCRIPT_DIR/lib/backlog-journal.sh"
source "$SCRIPT_DIR/daemon-dispatch.sh"
DAEMON_HEAD
awk '/^_forward_sha256\(\)/{on=1} /^exceeded_stories\(\)/{on=0} on{print}' \
  "$SCRIPTS/delivery-daemon.sh" >> "$RETAINED_DAEMON"
cat >> "$RETAINED_DAEMON" <<'DAEMON_BODY'
GAAI_LIFECYCLE_CALLER_ASSET=.gaai/core/scripts/delivery-daemon.sh
export GAAI_LIFECYCLE_CALLER_ASSET
mode="${1:-prepare}"
context=$(_forward_context_path TST-RETAINED) || exit 1
if [[ "$mode" == restart ]]; then
  _forward_recovery_one TST-RETAINED
  [[ ! -e "$context" && ! -L "$context" ]]
  exit $?
fi
source_sha=$(git -C "$PROJECT_DIR" rev-parse origin/staging) || exit 1
backlog_journal_begin_run "$BACKLOG_FILE" recovery.scan || exit 1
token="$BACKLOG_JOURNAL_RUN_TOKEN"
GAAI_BACKLOG_JOURNAL_SOURCE_REF="$source_sha" \
  backlog_journal_emit "$BACKLOG_FILE" TST-RETAINED phase_status failed recovery.scan "$token" || exit 1
phase_name=$(basename "$BACKLOG_JOURNAL_RECORD_PATH")
phase_digest="$BACKLOG_JOURNAL_RECORD_DIGEST"
GAAI_BACKLOG_JOURNAL_SOURCE_REF="$source_sha" \
  backlog_journal_emit "$BACKLOG_FILE" TST-RETAINED status failed recovery.scan "$token" || exit 1
status_name=$(basename "$BACKLOG_JOURNAL_RECORD_PATH")
status_digest="$BACKLOG_JOURNAL_RECORD_DIGEST"
state="$LOCK_DIR/.journal-runs/recovery.scan.TST-RETAINED.state"
mkdir -p "$(dirname "$state")"; chmod 700 "$(dirname "$state")"
_lifecycle_write_run_state "$state" create "$token" "$source_sha" || exit 1
_lifecycle_write_run_state "$state" append phase_status "$phase_name" "$phase_digest" || exit 1
_lifecycle_write_run_state "$state" append status "$status_name" "$status_digest" || exit 1
manifest=$(_journal_inspect_pending_lifecycle TST-RETAINED recovery.scan) || exit 1
_forward_manifest_args "$manifest" || exit 1
_forward_classify TST-RETAINED recovery unknown false || exit 1
old_source="$_FORWARD_SOURCE"; old_blob="$_FORWARD_BLOB"; old_record="$_FORWARD_RECORD_DIGEST"
IFS=$'\t' read -r _ retained_source token_digest state_digest records_digest \
  <<< "${manifest%%$'\n'*}"
row=$(_forward_bind_context "$context" TST-RETAINED "$old_source" "$old_blob" \
  "$old_record" retained "$token_digest" "$retained_source" "$records_digest" \
  none none unknown forward_terminal terminal_projection \
  phase_status=failed,status=failed) || exit 1
context_digest=${row##*$'\t'}
_forward_retained_settle TST-RETAINED "$manifest" "$context" "$context_digest" || exit 1
[[ ! -e "$state" && ! -e "$context" ]] || exit 1
# Recreate the exact post-projector/pre-context-retirement crash window. A
# second process must recognize accepted remote bytes without a run-state.
forward_context_install "$context" TST-RETAINED "$old_source" "$old_blob" \
  "$old_record" retained "$token_digest" "$retained_source" "$records_digest" \
  none none unknown forward_terminal terminal_projection \
  phase_status=failed,status=failed || exit 1
DAEMON_BODY
chmod 755 "$RETAINED_DAEMON"
# Prior projection tests intentionally advance the bare remote without
# rewriting this fixture checkout. Reconcile only the authoritative backlog,
# then fast-forward before publishing the base-held recovery asset.
git -C "$REPO" fetch -q origin staging
git -C "$REPO" checkout -q origin/staging -- "$BACKLOG_REL"
git -C "$REPO" merge -q --ff-only origin/staging
git -C "$REPO" add .gaai/core/scripts/delivery-daemon.sh "$BACKLOG_REL"
git -C "$REPO" commit -q -m 'fixture: retained recovery coordinator'
git -C "$REPO" push -q origin staging
# The production settlement boundary now requires a real, clean Story
# worktree before it can retire retained lifecycle evidence.  Materialize that
# exact worktree in the hermetic fixture instead of authorizing cleanup from an
# ambient or absent path.
git -C "$REPO" worktree add -q --detach \
  "$REPO/.worktrees/TST-RETAINED-workspace" origin/staging
T8_PREPARE_RC=0
"$TEST_BASH" "$RETAINED_DAEMON" prepare >"$SANDBOX/t8-prepare.out" \
  2>"$SANDBOX/t8-prepare.err" || T8_PREPARE_RC=$?
T8_STATE="$LOCK_DIR/.journal-runs/recovery.scan.TST-RETAINED.state"
T8_CONTEXT="$LOCK_DIR/.recovery-contexts/recovery.scan.TST-RETAINED.json"
if [[ "$T8_PREPARE_RC" -eq 0 && ! -e "$T8_STATE" && -f "$T8_CONTEXT" ]] \
    && git -C "$REPO" show "origin/staging:$BACKLOG_REL" \
      | awk '/TST-RETAINED/{s=1} s&&/status: failed/{a=1} s&&/phase_status: failed/{b=1} END{exit !(a&&b)}'; then
  pass "T8a: real recovery journal projected once, retired state and preserved crash context"
else
  fail "T8a: retained projection did not complete the exact success/crash window"
fi
T8_RESTART_RC=0
"$TEST_BASH" "$RETAINED_DAEMON" restart >"$SANDBOX/t8-restart.out" \
  2>"$SANDBOX/t8-restart.err" || T8_RESTART_RC=$?
if [[ "$T8_RESTART_RC" -eq 0 && ! -e "$T8_STATE" && ! -e "$T8_CONTEXT" ]] \
    && grep -q 'outcome=accepted reason=already_current' "$SANDBOX/t8-restart.err"; then
  pass "T8b: fresh process retired orphan retained context idempotently"
else
  fail "T8b: fresh restart did not close the retained crash window"
fi

echo ""
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
