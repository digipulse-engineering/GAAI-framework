#!/usr/bin/env bash
# daemon-dispatch.sh — 3-phase dispatch library for delivery-daemon.sh (E134S02)
#
# Sourceable library. No top-level execution code.
# Caller must set before sourcing or calling any function:
#   BACKLOG_FILE  — absolute path to active.backlog.yaml
#   SCHEDULER     — absolute path to backlog-scheduler.sh
#   PROJECT_DIR   — repo root (for runtime-routing-logger.js)
# Optional:
#   GAAI_STUB_DELAY_S — seconds to sleep between stubs (default: 0)
#   ROUTING_LOG_PATH  — test-only override for --log-path (default: empty, uses logger default)

# ── Model routing (roles → registry → eligible candidate) ────────────────
# Phase handlers ask the router which model may run a step; the router owns
# availability, capability floors, provenance and fallback order. Sourced
# lazily-safe: every function resolves PROJECT_DIR at call time.
_GAAI_DISPATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/delivery-routing.sh
[[ -f "${_GAAI_DISPATCH_LIB_DIR}/delivery-routing.sh" ]] \
  && source "${_GAAI_DISPATCH_LIB_DIR}/delivery-routing.sh"
# shellcheck source=lib/commit-retry-containment.sh
source "${_GAAI_DISPATCH_LIB_DIR}/commit-retry-containment.sh"
# The PLAN target guard is owned by this library and must remain available in
# the fresh wrapper shell, which sources daemon-dispatch directly rather than
# inheriting delivery-daemon functions.
# Every authority-bearing YAML program in this file runs through the
# repository-controlled runtime boundary. It is sourced ahead of the classifier
# so both use the same already-loaded boundary.
# shellcheck source=lib/yaml-runtime.sh
if [[ -z "${_YAML_RUNTIME_SH_SOURCED:-}" ]]; then
  if ! source "${_GAAI_DISPATCH_LIB_DIR}/yaml-runtime.sh"; then
    printf '%s\n' '[yaml-runtime] role=dispatcher action=load_boundary code=yaml_runtime_missing' >&2
    return 1 2>/dev/null || exit 30
  fi
fi

# The restrictive-umask repair and its verification, in the exact order the
# contract requires: normalize, then the worktree-local exact blob/mode
# verification, before anything in that worktree executes. A tree whose HEAD
# predates the vendored tuple declares none of it and needs neither step.
_dispatch_repair_worktree_tuple() {
  local story_id="$1" worktree_path="$2" rc=0
  local YAML_RUNTIME_ROLE=dispatcher
  if ! declare -F yaml_runtime_repair_and_verify_tree >/dev/null 2>&1; then
    return 1
  fi
  yaml_runtime_repair_and_verify_tree "$worktree_path" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi
  if [[ "${YAML_RUNTIME_TUPLE_STATE:-}" == "absent" ]]; then
    echo "[INFO] ${story_id}: worktree base predates the vendored runtime tuple — nothing to normalize or verify"
  fi
  return 0
}

# shellcheck source=lib/stuck-classifier.sh
if [[ -z "${_STUCK_CLASSIFIER_SH_SOURCED:-}" ]]; then
  if ! source "${_GAAI_DISPATCH_LIB_DIR}/stuck-classifier.sh"; then
    printf '%s\n' '[ERROR] daemon-dispatch: canonical target classifier unavailable' >&2
    return 1 2>/dev/null || exit 1
  fi
  _STUCK_CLASSIFIER_SH_SOURCED=1
fi

# ── Durable lifecycle persistence boundary ───────────────────────────────
#
# Every daemon-owned lifecycle transition goes through this boundary.  It
# binds one private run identity to the owning writer/Story until every record
# from that transition is proven in the current remote projection.  The local
# backlog is refreshed from that verified projection only after exact record
# finalization; it is never publication authority.
_lifecycle_resolve_process_pid() {
  local result_name="$1" resolved_pid="${BASHPID:-}" probe="" probe_child=""
  if [[ ! "$resolved_pid" =~ ^[1-9][0-9]*$ ]]; then
    # Bash 3.2 keeps $$ equal to the parent inside `( )`.  Ask a directly
    # backgrounded child for its PPID so the mkdir fallback records the actual
    # lock-holder process and a later restart can distinguish a dead owner.
    probe=$(mktemp "${LOCK_DIR:?}/.lifecycle-lock-pid.XXXXXX") || return 1
    sh -c 'printf "%s\n" "$PPID" >"$1"' _ "$probe" &
    probe_child=$!
    wait "$probe_child" 2>/dev/null || true
    IFS= read -r resolved_pid < "$probe" || resolved_pid=""
    rm -f "$probe" 2>/dev/null || true
  fi
  [[ "$resolved_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$resolved_pid" 2>/dev/null || return 1
  printf -v "$result_name" '%s' "$resolved_pid"
}

_lifecycle_prepare_flock_path() {
  local lock_path="$1"
  python3 - "$lock_path" <<'PY'
import errno
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | os.O_CREAT | os.O_EXCL
flags |= getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags, 0o600)
except OSError as exc:
    if exc.errno != errno.EEXIST:
        raise SystemExit(1)
else:
    os.close(fd)

try:
    current = os.lstat(path)
except OSError:
    raise SystemExit(1)
if not stat.S_ISREG(current.st_mode) or current.st_uid != os.geteuid():
    raise SystemExit(1)
PY
}

_lifecycle_flock_fd_matches_path() {
  local lock_path="$1" lock_fd="$2"
  python3 - "$lock_path" "$lock_fd" <<'PY'
import os
import stat
import sys

try:
    path_stat = os.lstat(sys.argv[1])
    fd_stat = os.fstat(int(sys.argv[2]))
except (OSError, ValueError):
    raise SystemExit(1)
if (not stat.S_ISREG(path_stat.st_mode)
        or not stat.S_ISREG(fd_stat.st_mode)
        or path_stat.st_uid != os.geteuid()
        or (path_stat.st_dev, path_stat.st_ino) != (fd_stat.st_dev, fd_stat.st_ino)):
    raise SystemExit(1)
PY
}

_lifecycle_create_owner_marker() {
  local marker_path="$1" owner_pid="$2"
  python3 - "$marker_path" "$owner_pid" <<'PY'
import os
import sys

flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
flags |= getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(sys.argv[1], flags, 0o600)
    os.write(fd, (sys.argv[2] + "\n").encode("ascii"))
    os.close(fd)
except OSError:
    raise SystemExit(1)
PY
}

_lifecycle_owner_marker_matches() {
  local marker_path="$1" owner_pid="$2"
  python3 - "$marker_path" "$owner_pid" <<'PY'
import os
import stat
import sys

try:
    current = os.lstat(sys.argv[1])
    with open(sys.argv[1], "r", encoding="ascii") as handle:
        recorded = handle.read().strip()
except OSError:
    raise SystemExit(1)
if (not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_mode & 0o077
        or recorded != sys.argv[2]):
    raise SystemExit(1)
PY
}

_lifecycle_lock_fd() {
  local lock_fd="$1" timeout_sec="$2"
  python3 - "$lock_fd" "$timeout_sec" <<'PY'
import fcntl
import os
import sys
import time

try:
    fd = int(sys.argv[1])
    timeout = int(sys.argv[2])
except (ValueError, IndexError):
    raise SystemExit(1)
deadline = time.monotonic() + timeout
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        raise SystemExit(0)
    except BlockingIOError:
        if time.monotonic() >= deadline:
            raise SystemExit(1)
        time.sleep(0.05)
    except OSError:
        raise SystemExit(1)
PY
}

_lifecycle_with_staging_lock() {
  local timeout_sec="${GAAI_STAGING_LOCK_TIMEOUT_SEC:-60}" rc=0
  local lock_path="${STAGING_LOCK:-${LOCK_DIR:?}/.staging.lock}"
  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || timeout_sec=60
  mkdir -p "${LOCK_DIR:?}" 2>/dev/null || return 1
  # Use one path-independent kernel primitive on every supported host. Python
  # calls flock(2) on the inherited descriptor, so this interoperates with
  # legacy `flock` callers even when their PATH differs. The `.d` sentinel is
  # acquired as well, excluding legacy mkdir callers. New owners install a
  # relative symlink there; a legacy directory is never guessed stale. Every
  # acquire/reclaim and release keeps fd 198 open and inherited by filesystem
  # children, so a killed shell cannot leave an old unlink racing a successor.
  local process_lock="${lock_path}.d"
  local lock_parent="${lock_path%/*}" lock_name="${lock_path##*/}.d"
  local owner_prefix="${lock_path##*/}.d.owner." owner_pid="" owner_name=""
  local owner_path="" observed_target="" observed_suffix=""
  local started_at="$SECONDS" elapsed=0 remaining=0 acquired=false
  _lifecycle_resolve_process_pid owner_pid || return 1

  while [[ "$acquired" != true ]]; do
    elapsed=$(( SECONDS - started_at ))
    (( elapsed < timeout_sec )) || return 1
    remaining=$(( timeout_sec - elapsed ))
    _lifecycle_prepare_flock_path "$lock_path" || return 1
    exec 198< "$lock_path" || return 1
    _lifecycle_flock_fd_matches_path "$lock_path" 198 || {
      exec 198>&-
      return 1
    }
    if ! _lifecycle_lock_fd 198 "$remaining"; then
      exec 198>&-
      return 1
    fi
    if ! _lifecycle_flock_fd_matches_path "$lock_path" 198; then
      exec 198>&-
      return 1
    fi

    if [[ -L "$process_lock" ]]; then
      observed_target=$(readlink "$process_lock" 2>/dev/null) || {
        exec 198>&-
        return 1
      }
      observed_suffix="${observed_target#"$owner_prefix"}"
      if [[ "$observed_target" == "$owner_prefix"* \
          && "$observed_suffix" =~ ^([1-9][0-9]*)\.([0-9]+)\.([0-9]+)$ ]]; then
        owner_path="$lock_parent/$observed_target"
        if ! _lifecycle_owner_marker_matches "$owner_path" "${BASH_REMATCH[1]}"; then
          exec 198>&-
          return 1
        fi
        # Acquiring the kernel guard proves the former owner and every child
        # that inherited its critical-section fd are gone.  Remove only that
        # exact validated stale representation before attempting our own.
        rm -f "$process_lock" 2>/dev/null || {
          exec 198>&-
          return 1
        }
        rm -f "$owner_path" 2>/dev/null || {
          exec 198>&-
          return 1
        }
      else
        exec 198>&-
        return 1
      fi
    elif [[ -d "$process_lock" ]]; then
      # Pre-S15 mkdir owner: it does not participate in the kernel guard, so
      # age/PID inference would be unsafe.  Wait only for its own release.
      exec 198>&-
      sleep 1
      continue
    elif [[ -e "$process_lock" ]]; then
      exec 198>&-
      return 1
    fi

    owner_name="${lock_name}.owner.${owner_pid}.${RANDOM}.${SECONDS}"
    owner_path="$lock_parent/$owner_name"
    if ! _lifecycle_create_owner_marker "$owner_path" "$owner_pid"; then
      exec 198>&-
      return 1
    fi
    if ln -s "$owner_name" "$process_lock" 2>/dev/null; then
      acquired=true
      break
    fi
    if ! rm -f "$owner_path" 2>/dev/null; then
      exec 198>&-
      return 1
    fi
    exec 198>&-
    sleep 1
  done

  observed_target=$(readlink "$process_lock" 2>/dev/null) || observed_target=""
  if [[ "$observed_target" != "$owner_name" ]] \
      || ! _lifecycle_owner_marker_matches "$owner_path" "$owner_pid"; then
    exec 198>&-
    return 1
  fi
  "$@" || rc=$?
  observed_target=$(readlink "$process_lock" 2>/dev/null) || observed_target=""
  if [[ "$observed_target" == "$owner_name" ]] \
      && _lifecycle_owner_marker_matches "$owner_path" "$owner_pid"; then
    if rm -f "$process_lock" 2>/dev/null; then
      rm -f "$owner_path" 2>/dev/null || rc=1
    else
      rc=1
    fi
  else
    rc=1
  fi
  exec 198>&-
  return "$rc"
}

_lifecycle_assert_base_held_assets() {
  local remote_sha="$1" asset_root project_root rel local_path local_blob remote_blob
  asset_root=$(cd "${_GAAI_DISPATCH_LIB_DIR}/../../../.." 2>/dev/null && pwd -P) || return 1
  project_root=$(cd "${PROJECT_DIR:?}" 2>/dev/null && pwd -P) || return 1
  [[ "$asset_root" == "$project_root" ]] || return 1

  # The parser the lifecycle writer depends on is base-held on the exact remote
  # SHA before that write, exactly like the writer itself. Without this, a
  # candidate could leave the three original assets pristine, swap the parser
  # underneath them, and still author lifecycle state. The manifest is bound as
  # well as the archive because a tamperer can keep the pair internally
  # consistent; only the base-held blob comparison catches that.
  local assets=(
    .gaai/core/scripts/daemon-dispatch.sh
    .gaai/core/scripts/lib/backlog-journal.sh
    .gaai/core/scripts/lib/chore-commit.sh
    .gaai/core/scripts/lib/yaml-runtime.sh
    .gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz
    .gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json
    .gaai/core/vendor/pyyaml/6.0.3/LICENSE
  )
  if [[ -n "${GAAI_LIFECYCLE_CALLER_ASSET:-}" ]]; then
    case "$GAAI_LIFECYCLE_CALLER_ASSET" in
      .gaai/core/scripts/post-delivery-hook.sh|.gaai/core/scripts/delivery-daemon.sh) ;;
      *) return 1 ;;
    esac
    assets+=("$GAAI_LIFECYCLE_CALLER_ASSET")
  fi

  for rel in "${assets[@]}"; do
    local_path="$project_root/$rel"
    python3 - "$local_path" <<'PY' || return 1
import os, stat, sys
try:
    mode = os.lstat(sys.argv[1]).st_mode
    if not stat.S_ISREG(mode):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
    local_blob=$(git -C "$project_root" hash-object -- "$local_path" 2>/dev/null) || return 1
    remote_blob=$(git -C "$project_root" rev-parse "${remote_sha}:${rel}" 2>/dev/null) || return 1
    [[ "$local_blob" == "$remote_blob" ]] || return 1
  done
}

_lifecycle_recovery_caller_authenticated() {
  [[ "${GAAI_LIFECYCLE_CALLER_ASSET:-}" == ".gaai/core/scripts/delivery-daemon.sh" ]] \
    || return 1
  local expected dispatch source resolved index
  expected=$(cd "${PROJECT_DIR:?}" 2>/dev/null && pwd -P) || return 1
  expected="$expected/.gaai/core/scripts/delivery-daemon.sh"
  source="${BASH_SOURCE[0]:-}"
  [[ -f "$source" ]] || return 1
  dispatch=$(cd "$(dirname "$source")" 2>/dev/null && pwd -P) || return 1
  dispatch="$dispatch/$(basename "$source")"

  # The dispatch library legitimately contributes several adjacent frames.
  # Authenticate only the first real caller beyond that boundary: a later
  # trusted frame must never bless an untrusted intermediary.
  index=1
  while (( index < ${#BASH_SOURCE[@]} )); do
    source="${BASH_SOURCE[$index]:-}"
    [[ -f "$source" ]] || return 1
    resolved=$(cd "$(dirname "$source")" 2>/dev/null && pwd -P) || return 1
    resolved="$resolved/$(basename "$source")"
    if [[ "$resolved" != "$dispatch" ]]; then
      [[ "$resolved" == "$expected" ]]
      return $?
    fi
    index=$(( index + 1 ))
  done
  return 1
}

# Read one private run state and all referenced records without reopening any
# accepted path. The emitted manifest contains only validated, canonical facts.
_lifecycle_run_manifest() {
  local state_path="$1" journal_root="$2" story_id="$3" writer="$4"
  python3 - "$state_path" "$journal_root" "$story_id" "$writer" <<'PY'
import datetime
import decimal
import hashlib
import json
import os
import re
import stat
import sys

state_path, journal_root, story, writer = sys.argv[1:]
token_re = re.compile(r"[0-9a-f]{64}")
object_re = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
basename_re = re.compile(r"[0-9]{20}-[0-9a-f]{16}\.json")
timestamp_re = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
allowed_fields = {
    "status", "phase_status", "started_at", "completed_at", "blocked_reason",
    "pr_url", "pr_number", "pr_status", "cost_usd",
}
status_edges = {
    "draft": {"refined", "cancelled", "superseded"},
    "refined": {"in_progress", "blocked", "cancelled", "superseded"},
    "in_progress": {"done", "failed", "blocked", "escalated", "cancelled", "superseded"},
    "failed": {"blocked", "cancelled", "superseded"},
    "escalated": {"blocked", "cancelled", "superseded"},
    "blocked": {"draft", "refined", "in_progress", "done", "cancelled", "superseded"},
    "done": {"cancelled", "superseded"},
    "deferred": {"cancelled", "superseded"},
    "cancelled": set(),
    "superseded": set(),
}
phase_edges = {
    "not_started": {"planned", "failed"},
    "planned": {"implemented", "failed"},
    "implemented": {"qa_passed", "qa_failed", "qa_escalated", "failed"},
    "qa_failed": {"not_started", "planned", "implemented", "qa_escalated", "failed"},
    "qa_passed": {"implemented", "commit_stalled", "done", "failed", "escalated"},
    "qa_escalated": set(),
    "commit_stalled": set(),
    "done": set(),
    "failed": set(),
    "escalated": set(),
}
pr_statuses = {
    "merged", "pending_review", "open", "closed", "closed_superseded",
    "not_created_superseded", "created", "none",
}

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

def canonical_timestamp(value):
    if value is None:
        return None
    if not isinstance(value, str) or not timestamp_re.fullmatch(value):
        raise ValueError
    datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    return value

def validate_value(field, value):
    if field in {"started_at", "completed_at"}:
        return canonical_timestamp(value)
    if field == "blocked_reason":
        if value is None:
            return None
        if not isinstance(value, str) or not value:
            raise ValueError
        if any(
            ord(char) <= 31
            or 127 <= ord(char) <= 159
            or 0xD800 <= ord(char) <= 0xDFFF
            or ord(char) in {0x2028, 0x2029}
            for char in value
        ):
            raise ValueError
        return value
    if field == "pr_url":
        if value is None:
            return None
        if not isinstance(value, str) or not re.fullmatch(
            r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*",
            value,
        ):
            raise ValueError
        return value
    if field == "pr_number":
        if value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise ValueError
        return value
    if field == "pr_status":
        if value is None:
            return None
        if not isinstance(value, str) or value not in pr_statuses:
            raise ValueError
        return value
    if field == "cost_usd":
        if value is None:
            return None
        if not isinstance(value, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.[0-9]+)?", value):
            raise ValueError
        parsed = decimal.Decimal(value)
        canonical_cost = format(parsed, "f")
        if "." in canonical_cost:
            canonical_cost = canonical_cost.rstrip("0").rstrip(".")
        if canonical_cost != value:
            raise ValueError
        return value
    raise ValueError

def validate_policy(field, old_value, new_value):
    if field not in allowed_fields:
        raise ValueError
    if field == "status":
        if old_value not in status_edges or new_value not in status_edges[old_value]:
            raise ValueError
    elif field == "phase_status":
        if old_value not in phase_edges or new_value not in phase_edges[old_value]:
            raise ValueError
    else:
        if validate_value(field, old_value) != old_value:
            raise ValueError
        if validate_value(field, new_value) != new_value:
            raise ValueError

def read_private(path):
    fd = None
    try:
        before = os.lstat(path)
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        after = os.lstat(path)
        identity = (opened.st_dev, opened.st_ino)
        if not stat.S_ISREG(opened.st_mode):
            raise ValueError
        if opened.st_uid != os.geteuid() or opened.st_mode & 0o077:
            raise ValueError
        if identity != (before.st_dev, before.st_ino):
            raise ValueError
        if identity != (after.st_dev, after.st_ino):
            raise ValueError
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        if fd is not None:
            os.close(fd)

try:
    state_bytes = read_private(state_path)
    state_text = state_bytes.decode("ascii")
    lines = state_text.splitlines()
    if not lines or len(lines[0].split("\t")) != 2:
        raise ValueError
    token, source = lines[0].split("\t")
    if not token_re.fullmatch(token) or not object_re.fullmatch(source):
        raise ValueError
    seen = set()
    rows = []
    writer_key = hashlib.sha256(writer.encode("ascii")).hexdigest()
    registration_path = os.path.join(journal_root, "registrations", token + ".json")
    registration_bytes = read_private(registration_path)
    registration_wrapper = json.loads(registration_bytes.decode("utf-8"))
    registration = registration_wrapper["registration"]
    if set(registration_wrapper) != {"registration", "digest"}:
        raise ValueError
    if set(registration) != {"schema_version", "run_token", "writer_context", "issued_at"}:
        raise ValueError
    if registration.get("schema_version") != "1.0.0":
        raise ValueError
    if registration.get("run_token") != token or registration.get("writer_context") != writer:
        raise ValueError
    if canonical_timestamp(registration.get("issued_at")) != registration.get("issued_at"):
        raise ValueError
    registration_digest = hashlib.sha256(canonical(registration).encode("utf-8")).hexdigest()
    if registration_wrapper.get("digest") != registration_digest:
        raise ValueError
    if registration_bytes != (canonical(registration_wrapper) + "\n").encode("utf-8"):
        raise ValueError
    record_digests = []
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) != 3:
            raise ValueError
        field, basename, expected_digest = parts
        if field in seen or not basename_re.fullmatch(basename):
            raise ValueError
        if not token_re.fullmatch(expected_digest):
            raise ValueError
        seen.add(field)
        roots = ("records", "applied")
        candidates = [
            os.path.join(journal_root, "writers", writer_key, root, basename)
            for root in roots
        ]
        existing = [path for path in candidates if os.path.lexists(path)]
        if len(existing) != 1:
            raise ValueError
        record_bytes = read_private(existing[0])
        wrapper = json.loads(record_bytes.decode("utf-8"))
        record = wrapper["record"]
        digest = wrapper["digest"]
        if set(wrapper) != {"record", "intent_digest", "digest"}:
            raise ValueError
        expected_record_keys = {
            "schema_version", "story_id", "field", "old_value", "new_value",
            "source_commit", "source_blob", "writer_context", "run_token",
            "intent_digest", "sequence", "emitted_at",
        }
        if set(record) != expected_record_keys or record.get("schema_version") != "1.0.0":
            raise ValueError
        if record_bytes != (canonical(wrapper) + "\n").encode("utf-8"):
            raise ValueError
        if digest != expected_digest:
            raise ValueError
        if hashlib.sha256(canonical(record).encode("utf-8")).hexdigest() != digest:
            raise ValueError
        if record.get("story_id") != story or record.get("field") != field:
            raise ValueError
        if record.get("writer_context") != writer or record.get("run_token") != token:
            raise ValueError
        if record.get("source_commit") != source:
            raise ValueError
        if not object_re.fullmatch(record.get("source_blob") or ""):
            raise ValueError
        if not isinstance(record.get("sequence"), int) or isinstance(record.get("sequence"), bool):
            raise ValueError
        if record["sequence"] < 1:
            raise ValueError
        if canonical_timestamp(record.get("emitted_at")) != record.get("emitted_at"):
            raise ValueError
        intent_digest = wrapper.get("intent_digest")
        if not token_re.fullmatch(intent_digest or ""):
            raise ValueError
        if record.get("intent_digest") != intent_digest:
            raise ValueError
        intent = {key: record[key] for key in (
            "schema_version", "story_id", "field", "old_value", "new_value",
            "source_commit", "source_blob", "writer_context", "run_token",
        )}
        if hashlib.sha256(canonical(intent).encode("utf-8")).hexdigest() != intent_digest:
            raise ValueError
        expected_name = "%020d-%s.json" % (record["sequence"], intent_digest[:16])
        if basename != expected_name:
            raise ValueError
        validate_policy(field, record.get("old_value"), record.get("new_value"))
        value = record.get("new_value")
        if field == "blocked_reason":
            if not isinstance(value, str):
                raise ValueError
            wire = "json:" + canonical(value)
        elif value is None:
            wire = "null"
        elif field == "pr_number":
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValueError
            wire = str(value)
        elif field == "cost_usd":
            if not isinstance(value, str):
                raise ValueError
            wire = format(decimal.Decimal(value), "f")
            if "." in wire:
                wire = wire.rstrip("0").rstrip(".")
        elif isinstance(value, str):
            wire = value
        else:
            raise ValueError
        if any("\t" in item or "\n" in item for item in (field, basename, digest, wire)):
            raise ValueError
        record_digests.append(basename + ":" + digest)
        location = os.path.basename(os.path.dirname(existing[0]))
        rows.append((field, basename, digest, wire, location))
    state_digest = hashlib.sha256(state_bytes).hexdigest()
    records_digest = hashlib.sha256("\n".join(record_digests).encode("ascii")).hexdigest()
    token_digest = hashlib.sha256(token.encode("ascii")).hexdigest()
    print("\t".join((token, source, token_digest, state_digest, records_digest)))
    for row in rows:
        print("\t".join(row))
except (
    OSError, ValueError, KeyError, TypeError, UnicodeError,
    json.JSONDecodeError, decimal.InvalidOperation,
):
    raise SystemExit(1)
PY
}

_journal_inspect_pending_lifecycle() {
  local story_id="$1" writer="$2"
  local state_file="${LOCK_DIR:?}/.journal-runs/${writer}.${story_id}.state"
  if [[ ! -e "$state_file" ]]; then
    [[ -L "$state_file" ]] && return 1
    return 2
  fi
  local writer_key journal_root
  writer_key=$(python3 - "$writer" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode("ascii")).hexdigest())
PY
  ) || return 1
  journal_root="${GAAI_BACKLOG_JOURNAL_DIR:-$(dirname "$BACKLOG_FILE")/.delivery-locks/journal}"
  _lifecycle_run_manifest "$state_file" "$journal_root" "$story_id" "$writer"
}

_journal_retire_accepted_lifecycle_locked() {
  local story_id="$1" writer="$2" expected_state_digest="$3"
  local manifest token source token_digest state_digest records_digest rows=""
  manifest=$(_journal_inspect_pending_lifecycle "$story_id" "$writer") || return 1
  IFS=$'\t' read -r token source token_digest state_digest records_digest \
    <<< "${manifest%%$'\n'*}" || return 1
  [[ "$state_digest" == "$expected_state_digest" ]] || return 1
  [[ "$manifest" == *$'\n'* ]] && rows="${manifest#*$'\n'}"
  local args=() field basename digest value location
  while IFS=$'\t' read -r field basename digest value location; do
    [[ -n "$field" && "$location" == applied ]] || return 1
    args+=("$field" "$value")
  done <<< "$rows"
  (( ${#args[@]} >= 2 )) || return 1
  local target_branch="${TARGET_BRANCH:-staging}" remote_sha snapshot
  snapshot=$(mktemp "${LOCK_DIR:?}/.accepted-snapshot-XXXXXX" 2>/dev/null) || return 1
  if ! git -C "$PROJECT_DIR" fetch origin "$target_branch" --quiet 2>/dev/null \
      || ! remote_sha=$(git -C "$PROJECT_DIR" rev-parse "origin/$target_branch" 2>/dev/null) \
      || ! git -C "$PROJECT_DIR" show "${remote_sha}:${BACKLOG_REL}" > "$snapshot" 2>/dev/null \
      || ! _lifecycle_snapshot_matches "$snapshot" "$story_id" "${args[@]}"; then
    rm -f "$snapshot"
    return 1
  fi
  rm -f "$snapshot"
  _lifecycle_write_run_state \
    "${LOCK_DIR}/.journal-runs/${writer}.${story_id}.state" remove
}

_journal_retire_accepted_lifecycle() {
  _lifecycle_with_staging_lock _journal_retire_accepted_lifecycle_locked "$@"
}

_lifecycle_record_matches() {
  local record_path="$1" story_id="$2" field="$3" writer="$4" token="$5"
  local expected="$6" digest="$7"
  python3 - "$record_path" "$story_id" "$field" "$writer" "$token" \
    "$expected" "$digest" <<'PY'
import decimal, hashlib, json, os, stat, sys

path, story, field, writer, token, raw, digest = sys.argv[1:]
try:
    before = os.lstat(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(fd)
    after = os.lstat(path)
    if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino)):
        raise ValueError
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(fd)
    fd = None
    record_bytes = b"".join(chunks)
    wrapper = json.loads(record_bytes.decode("utf-8"))
    record = wrapper["record"]
    canonical_wrapper = json.dumps(
        wrapper, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8") + b"\n"
    if record_bytes != canonical_wrapper:
        raise ValueError
    if (wrapper.get("digest") != digest or record.get("story_id") != story
            or record.get("field") != field or record.get("writer_context") != writer
            or record.get("run_token") != token
            or hashlib.sha256(json.dumps(record, sort_keys=True, separators=(",", ":"),
                              ensure_ascii=False).encode("utf-8")).hexdigest() != digest):
        raise ValueError
    if raw == "null":
        expected = None
    elif field == "pr_number":
        expected = int(raw)
    elif field == "cost_usd":
        expected = format(decimal.Decimal(raw), "f")
        if "." in expected:
            expected = expected.rstrip("0").rstrip(".")
    elif field == "blocked_reason":
        if not raw.startswith("json:"):
            raise ValueError
        expected = json.loads(raw[5:])
    else:
        expected = raw
    if record.get("new_value") != expected:
        raise ValueError
except (OSError, ValueError, KeyError, TypeError, UnicodeError,
        json.JSONDecodeError, decimal.InvalidOperation):
    raise SystemExit(1)
finally:
    if 'fd' in locals() and fd is not None:
        os.close(fd)
PY
}

_lifecycle_snapshot_matches() {
  local snapshot="$1" story_id="$2"
  local YAML_RUNTIME_ROLE=dispatcher
  shift 2
  yaml_runtime_run "$snapshot" "$story_id" "$@" <<'PY'
import decimal, sys

import yaml

path, story, *pairs = sys.argv[1:]
if len(pairs) == 0 or len(pairs) % 2:
    raise SystemExit(1)
try:
    with open(path, encoding="utf-8") as handle:
        document = yaml.safe_load(handle)
    matches = [item for item in document.get("items", [])
               if isinstance(item, dict) and str(item.get("id")) == story]
    if len(matches) != 1:
        raise ValueError
    item = matches[0]
    for field, raw in zip(pairs[::2], pairs[1::2]):
        if raw == "null":
            expected = None
        elif field == "pr_number":
            expected = int(raw)
        elif field == "cost_usd":
            expected = format(decimal.Decimal(raw), "f")
            if "." in expected:
                expected = expected.rstrip("0").rstrip(".")
            actual = str(item.get(field)) if item.get(field) is not None else None
            if actual != expected:
                raise ValueError
            continue
        elif field == "blocked_reason":
            import json
            if not raw.startswith("json:"):
                raise ValueError
            expected = json.loads(raw[5:])
        else:
            expected = raw
        if item.get(field) != expected:
            raise ValueError
except (OSError, ValueError, TypeError, decimal.InvalidOperation):
    raise SystemExit(1)
PY
}

_lifecycle_write_run_state() {
  local state_path="$1" operation="$2"
  shift 2
  python3 - "$state_path" "$operation" "$@" <<'PY'
import os
import secrets
import stat
import sys

path, operation, *values = sys.argv[1:]
parent = os.path.dirname(path)
name = os.path.basename(path)
dir_fd = None
source_fd = None
tmp_fd = None
tmp_name = None
try:
    parent_stat = os.lstat(parent)
    if (not stat.S_ISDIR(parent_stat.st_mode)
            or parent_stat.st_uid != os.geteuid()
            or parent_stat.st_mode & 0o077):
        raise ValueError
    dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    dir_fd = os.open(parent, dir_flags)
    opened_parent = os.fstat(dir_fd)
    if ((opened_parent.st_dev, opened_parent.st_ino)
            != (parent_stat.st_dev, parent_stat.st_ino)):
        raise ValueError

    if operation == "create" and len(values) == 2:
        payload = (values[0] + "\t" + values[1] + "\n").encode("ascii")
        source_stat = None
    elif operation == "append" and len(values) == 3:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        source_fd = os.open(name, flags, dir_fd=dir_fd)
        source_stat = os.fstat(source_fd)
        path_stat = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        if (not stat.S_ISREG(source_stat.st_mode)
                or source_stat.st_uid != os.geteuid()
                or source_stat.st_mode & 0o077
                or (source_stat.st_dev, source_stat.st_ino)
                    != (path_stat.st_dev, path_stat.st_ino)):
            raise ValueError
        chunks = []
        while True:
            chunk = os.read(source_fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
        payload += ("\t".join(values) + "\n").encode("ascii")
    elif operation == "remove" and not values:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        source_fd = os.open(name, flags, dir_fd=dir_fd)
        source_stat = os.fstat(source_fd)
        path_stat = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        if (not stat.S_ISREG(source_stat.st_mode)
                or source_stat.st_uid != os.geteuid()
                or source_stat.st_mode & 0o077
                or (source_stat.st_dev, source_stat.st_ino)
                    != (path_stat.st_dev, path_stat.st_ino)):
            raise ValueError
        os.unlink(name, dir_fd=dir_fd)
        os.fsync(dir_fd)
        raise SystemExit(0)
    else:
        raise ValueError

    while True:
        tmp_name = "." + name + "." + secrets.token_hex(16) + ".tmp"
        try:
            tmp_flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | getattr(os, "O_NOFOLLOW", 0))
            tmp_fd = os.open(tmp_name, tmp_flags, 0o600, dir_fd=dir_fd)
            break
        except FileExistsError:
            continue
    os.fchmod(tmp_fd, 0o600)
    view = memoryview(payload)
    while view:
        written = os.write(tmp_fd, view)
        if written <= 0:
            raise OSError
        view = view[written:]
    os.fsync(tmp_fd)
    os.close(tmp_fd)
    tmp_fd = None

    if operation == "create":
        # Hard-link installation is an atomic no-replace operation. An object
        # that appeared at the destination is rejected, never followed.
        os.link(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd,
                follow_symlinks=False)
        os.unlink(tmp_name, dir_fd=dir_fd)
        tmp_name = None
    else:
        current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        if ((current.st_dev, current.st_ino)
                != (source_stat.st_dev, source_stat.st_ino)):
            raise ValueError
        # The temporary inode was written through its exclusive descriptor;
        # replace changes the directory entry and never follows its target.
        os.replace(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        tmp_name = None
    os.fsync(dir_fd)
except (OSError, ValueError, UnicodeError):
    raise SystemExit(1)
finally:
    if source_fd is not None:
        os.close(source_fd)
    if tmp_fd is not None:
        os.close(tmp_fd)
    if tmp_name is not None and dir_fd is not None:
        try:
            os.unlink(tmp_name, dir_fd=dir_fd)
        except OSError:
            pass
    if dir_fd is not None:
        os.close(dir_fd)
PY
}

_journal_persist_lifecycle_locked() {
  local story_id="$1" writer="$2"
  shift 2
  local args=("$@") n="${#args[@]}" projector_context="" target_branch="${TARGET_BRANCH:-staging}"
  [[ "$story_id" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] || return 1
  [[ "$writer" =~ ^[a-z][a-z0-9]*([._-][a-z0-9]+){0,7}$ ]] || return 1
  (( n >= 2 && n % 2 == 0 )) || return 1
  case "$writer" in
    dispatch.*) projector_context=dispatch ;;
    post-delivery-hook) projector_context=post-delivery-hook ;;
    recovery.scan)
      projector_context=recovery
      if ! _lifecycle_recovery_caller_authenticated; then
        echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=caller_untrusted" >&2
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  declare -F chore_commit_project_journal >/dev/null 2>&1 || {
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=projector_unavailable" >&2
    return 1
  }
  [[ -r "${_GAAI_DISPATCH_LIB_DIR}/backlog-journal.sh" ]] || return 1
  # shellcheck source=lib/backlog-journal.sh
  source "${_GAAI_DISPATCH_LIB_DIR}/backlog-journal.sh"

  local run_dir="$LOCK_DIR/.journal-runs" state_file="$LOCK_DIR/.journal-runs/${writer}.${story_id}.state"
  ( umask 077; mkdir -p "$run_dir" ) 2>/dev/null || return 1
  python3 - "$run_dir" <<'PY' || return 1
import os, stat, sys
try:
    mode = os.lstat(sys.argv[1]).st_mode
    if not stat.S_ISDIR(mode) or mode & 0o077:
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY

  local snapshot tmp_snapshot projection_log="" remote_sha token source_sha manifest
  snapshot=$(mktemp "$LOCK_DIR/.lifecycle-snapshot-XXXXXX" 2>/dev/null) || return 1
  tmp_snapshot=$(mktemp "$LOCK_DIR/.lifecycle-reflect-XXXXXX" 2>/dev/null) || {
    rm -f "$snapshot"; return 1; }
  _lifecycle_cleanup() { rm -f "$snapshot" "$tmp_snapshot" "${projection_log:-}" 2>/dev/null || true; }

  if ! git -C "$PROJECT_DIR" fetch origin "$target_branch" --quiet 2>/dev/null \
      || ! remote_sha=$(git -C "$PROJECT_DIR" rev-parse "origin/$target_branch" 2>/dev/null) \
      || [[ ! "$remote_sha" =~ ^[0-9a-f]{40}$ ]] \
      || [[ -n "${GAAI_LIFECYCLE_EXPECTED_SOURCE_SHA:-}" \
            && "$remote_sha" != "$GAAI_LIFECYCLE_EXPECTED_SOURCE_SHA" ]] \
      || ! git -C "$PROJECT_DIR" show "${remote_sha}:${BACKLOG_REL}" > "$snapshot" 2>/dev/null; then
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=source_unavailable" >&2
    _lifecycle_cleanup
    return 1
  fi
  if ! _lifecycle_assert_base_held_assets "$remote_sha"; then
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=asset_untrusted" >&2
    _lifecycle_cleanup
    return 1
  fi
  chmod 644 "$snapshot" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  cp "$snapshot" "$tmp_snapshot" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  chmod 644 "$tmp_snapshot" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  mv "$tmp_snapshot" "$BACKLOG_FILE" 2>/dev/null || { _lifecycle_cleanup; return 1; }

  # A prior verified attempt may have completed before its caller retired the
  # private run-state file.  With no such file, an already-current projection
  # is an idempotent no-op; never emit a forbidden self-transition merely to
  # manufacture fresh evidence.
  if [[ ! -f "$state_file" ]] \
      && _lifecycle_snapshot_matches "$snapshot" "$story_id" "${args[@]}"; then
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=noop reason=already_current" >&2
    _lifecycle_cleanup
    return 0
  fi

  if [[ -e "$state_file" || -L "$state_file" ]]; then
    if ! manifest=$(_journal_inspect_pending_lifecycle "$story_id" "$writer"); then
      echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=run_state_invalid" >&2
      _lifecycle_cleanup
      return 1
    fi
    IFS=$'\t' read -r token source_sha _ _ _ <<< "${manifest%%$'\n'*}" || true
  else
    token=""; source_sha=""; manifest=""
  fi
  if [[ -z "$token" ]]; then
    if ! backlog_journal_begin_run "$BACKLOG_FILE" "$writer"; then
      echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=${BACKLOG_JOURNAL_REASON:-run_registration_failed}" >&2
      _lifecycle_cleanup
      return 1
    fi
    token="$BACKLOG_JOURNAL_RUN_TOKEN"; source_sha="$remote_sha"
    _lifecycle_write_run_state "$state_file" create "$token" "$source_sha" || {
      _lifecycle_cleanup; return 1; }
    manifest=$(_journal_inspect_pending_lifecycle "$story_id" "$writer") || {
      _lifecycle_cleanup; return 1; }
  fi
  if [[ ! "$token" =~ ^[0-9a-f]{64}$ || ! "$source_sha" =~ ^[0-9a-f]{40}$ ]] \
      || ! git -C "$PROJECT_DIR" merge-base --is-ancestor "$source_sha" "$remote_sha" 2>/dev/null; then
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=run_state_invalid" >&2
    _lifecycle_cleanup
    return 1
  fi

  local writer_key field value basename digest record_path applied_path existing line rc i
  writer_key=$(python3 - "$writer" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode("ascii")).hexdigest())
PY
  ) || { _lifecycle_cleanup; return 1; }
  local journal_root="${GAAI_BACKLOG_JOURNAL_DIR:-$(dirname "$BACKLOG_FILE")/.delivery-locks/journal}"

  i=0
  while (( i < n )); do
    field="${args[$i]}"; value="${args[$(( i + 1 ))]}"; i=$(( i + 2 ))
    line=$(printf '%s\n' "$manifest" \
      | awk -F '\t' -v wanted="$field" 'NR > 1 && $1 == wanted { print; exit }')
    if [[ -n "$line" ]]; then
      IFS=$'\t' read -r existing basename digest _ <<< "$line"
      record_path="$journal_root/writers/$writer_key/records/$basename"
      applied_path="$journal_root/writers/$writer_key/applied/$basename"
      [[ -f "$record_path" ]] || record_path="$applied_path"
      if [[ ! -f "$record_path" ]] \
          || ! _lifecycle_record_matches "$record_path" "$story_id" "$field" "$writer" "$token" "$value" "$digest"; then
        echo "[LIFECYCLE-JOURNAL] story=$story_id field=$field writer=$writer outcome=rejected reason=run_record_invalid" >&2
        _lifecycle_cleanup
        return 1
      fi
      continue
    fi

    rc=0
    GAAI_BACKLOG_JOURNAL_SOURCE_REF="$source_sha" \
      backlog_journal_emit "$BACKLOG_FILE" "$story_id" "$field" "$value" "$writer" "$token" || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 10 ]]; then
      echo "[LIFECYCLE-JOURNAL] story=$story_id field=$field writer=$writer outcome=rejected reason=${BACKLOG_JOURNAL_REASON:-emit_failed}" >&2
      _lifecycle_cleanup
      return 1
    fi
    record_path="$BACKLOG_JOURNAL_RECORD_PATH"; digest="$BACKLOG_JOURNAL_RECORD_DIGEST"
    basename=$(basename "$record_path")
    [[ "$basename" =~ ^[0-9]{20}-[0-9a-f]{16}\.json$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || {
      _lifecycle_cleanup; return 1; }
    if ! _lifecycle_write_run_state "$state_file" append "$field" "$basename" "$digest"; then
      _lifecycle_cleanup
      return 1
    fi
    manifest=$(_journal_inspect_pending_lifecycle "$story_id" "$writer") || {
      _lifecycle_cleanup; return 1; }
  done

  rc=0
  projection_log=$(mktemp "$LOCK_DIR/.lifecycle-projector-XXXXXX" 2>/dev/null) || {
    _lifecycle_cleanup; return 1; }
  local caller_pwd="$PWD"
  cd "$PROJECT_DIR" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  chore_commit_project_journal "$projector_context" 2>"$projection_log" || rc=$?
  cd "$caller_pwd" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  cat "$projection_log" >&2
  if [[ "$rc" -ne 0 ]]; then
    local caller_outcome="rejected" projection_conflicted="0"
    projection_conflicted=$(sed -nE 's/.*outcome=prepared.*conflicted=([0-9]+).*/\1/p' "$projection_log" | tail -1)
    projection_conflicted="${projection_conflicted:-0}"
    case "${CHORE_JOURNAL_OUTCOME:-rejected}" in
      retained) caller_outcome=retryable ;;
      pending)
        if [[ "$projection_conflicted" =~ ^[1-9][0-9]*$ ]]; then
          caller_outcome=conflicted
        else
          caller_outcome=pending
        fi
        ;;
    esac
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=$caller_outcome reason=${CHORE_JOURNAL_REASON:-projection_failed}" >&2
    _lifecycle_cleanup
    return 1
  fi

  while IFS=$'\t' read -r field basename digest _; do
    [[ "$field" == "$token" ]] && continue
    applied_path="$journal_root/writers/$writer_key/applied/$basename"
    value=""
    i=0
    while (( i < n )); do
      [[ "${args[$i]}" == "$field" ]] && { value="${args[$(( i + 1 ))]}"; break; }
      i=$(( i + 2 ))
    done
    [[ -n "$value" ]] || { _lifecycle_cleanup; return 1; }
    if [[ ! -f "$applied_path" ]] \
        || ! _lifecycle_record_matches "$applied_path" "$story_id" "$field" "$writer" "$token" "$value" "$digest"; then
      local unfinalized_outcome="pending" projection_conflicted="0"
      projection_conflicted=$(sed -nE 's/.*outcome=prepared.*conflicted=([0-9]+).*/\1/p' "$projection_log" | tail -1)
      [[ "${projection_conflicted:-0}" =~ ^[1-9][0-9]*$ ]] && unfinalized_outcome=conflicted
      echo "[LIFECYCLE-JOURNAL] story=$story_id field=$field writer=$writer outcome=$unfinalized_outcome reason=record_not_finalized" >&2
      _lifecycle_cleanup
      return 1
    fi
  done <<< "$manifest"

  if ! git -C "$PROJECT_DIR" fetch origin "$target_branch" --quiet 2>/dev/null \
      || ! remote_sha=$(git -C "$PROJECT_DIR" rev-parse "origin/$target_branch" 2>/dev/null) \
      || ! git -C "$PROJECT_DIR" show "${remote_sha}:${BACKLOG_REL}" > "$snapshot" 2>/dev/null \
      || ! _lifecycle_snapshot_matches "$snapshot" "$story_id" "${args[@]}"; then
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=remote_verification_failed" >&2
    _lifecycle_cleanup
    return 1
  fi
  chmod 644 "$snapshot" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  mv "$snapshot" "$BACKLOG_FILE" 2>/dev/null || { _lifecycle_cleanup; return 1; }
  _lifecycle_write_run_state "$state_file" remove || { _lifecycle_cleanup; return 1; }
  echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=applied reason=none" >&2
  _lifecycle_cleanup
  return 0
}

_journal_persist_lifecycle() {
  _lifecycle_with_staging_lock _journal_persist_lifecycle_locked "$@"
}

# Resume an interrupted dispatch-owned transition before another phase model is
# allowed to run.  The desired values come only from the exact journal records
# already bound into the private run-state file; model output and the ambient
# backlog are never consulted.  Return 2 when there is nothing to resume.
_journal_resume_pending_lifecycle() {
  local story_id="$1" writer="$2"
  local state_file="${LOCK_DIR:?}/.journal-runs/${writer}.${story_id}.state"
  if [[ ! -e "$state_file" ]]; then
    [[ -L "$state_file" ]] || return 2
  fi
  local manifest token source_sha token_digest state_digest records_digest
  manifest=$(_journal_inspect_pending_lifecycle "$story_id" "$writer") || return 1
  IFS=$'\t' read -r token source_sha token_digest state_digest records_digest \
    <<< "${manifest%%$'\n'*}" || return 1
  [[ "$token" =~ ^[0-9a-f]{64}$ && "$source_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$token_digest" =~ ^[0-9a-f]{64}$ && "$state_digest" =~ ^[0-9a-f]{64}$ \
      && "$records_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  local field basename digest value location rows=""
  [[ "$manifest" == *$'\n'* ]] && rows="${manifest#*$'\n'}"
  local args=()
  while IFS=$'\t' read -r field basename digest value location; do
    [[ -n "$field" ]] || continue
    [[ "$basename" =~ ^[0-9]{20}-[0-9a-f]{16}\.json$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$location" == records || "$location" == applied ]] || return 1
    args+=("$field" "$value")
  done <<< "$rows"
  if (( ${#args[@]} < 2 )); then
    echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=rejected reason=empty_run_state" >&2
    return 1
  fi

  echo "[LIFECYCLE-JOURNAL] story=$story_id writer=$writer outcome=retryable reason=pending_run" >&2
  _journal_persist_lifecycle "$story_id" "$writer" "${args[@]}"
}

# ── Per-phase wall-clock timeouts (OSS-7) ────────────────────────────────
# Bound the lifetime of each phase to detect hangs that loop-breaker (which
# only fires on identical consecutive errors) cannot catch — silent network
# stalls, MCP server deadlocks, agent that produces output but never
# converges. Override via env when needed (longer impl on giant stories).
# Raised (30/90/30 -> 40/120/45 min) — newer model generations can run
# measurably slower per turn than prior ones, especially under extended
# thinking; observed genuinely-active (non-hung) impl sessions past a
# too-tight cap. Re-tune here if model latency characteristics shift again.
GAAI_TIMEOUT_PLAN_SEC="${GAAI_TIMEOUT_PLAN_SEC:-2400}"     # 40 min
GAAI_TIMEOUT_IMPL_SEC="${GAAI_TIMEOUT_IMPL_SEC:-7200}"     # 120 min
GAAI_TIMEOUT_QA_SEC="${GAAI_TIMEOUT_QA_SEC:-2700}"         # 45 min
GAAI_TIMEOUT_COMMIT_SEC="${GAAI_TIMEOUT_COMMIT_SEC:-600}"  # 10 min (commit-phase
                                                            # is bash-only; this
                                                            # is informational)
# Distinct exit code for wall-clock timeout (vs 124 loop-breaker).
GAAI_TIMEOUT_RC=137

# ── Per-phase agent turn caps ────────────────────────────────────────────
# QA carries the heaviest deterministic workload of the three phases
# (mandatory reads of story/epic/plan/impl-report + per-DEC reads + run the
# test suite + tsc/lint + qa-review + consistency-check), yet historically ran
# at --max-turns 30 — the lowest of the three (plan 60, impl 150). On large
# stories the QA agent exhausted 30 turns before writing a verdict, exited
# non-zero (error_max_turns), and the wrapper died at phase_status=implemented
# in an unbounded relaunch loop. Raise the default and make it overridable.
GAAI_QA_MAX_TURNS="${GAAI_QA_MAX_TURNS:-100}"

# Resolve the available timeout binary. Linux ships `timeout`, macOS coreutils
# ships `gtimeout`. Empty string when neither is present — callers must then
# fall back to the in-process watchdog.
_resolve_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"
  else
    echo ""
  fi
}

# ── Orphaned-process reaper (OSS — memory-leak guard) ────────────────────
# SIGKILL any process still rooted in a story's worktree. A delivery phase is a
# `claude -p` invocation; the agent routinely spawns heavy subprocess trees (test
# runners, dev/build servers, container runtimes — whatever the project's test and
# build commands invoke). Every phase-ending kill path signals only the claude PID,
# not its descendants, so a process whose own tool-call timeout detached it is left
# orphaned. Across phase timeouts and QA retries these long-lived workers accumulate
# until the daemon host runs out of memory. This reaps them by worktree path.
#
# SAFETY: the argument MUST be a non-empty `*-workspace` pattern. A bare `pkill -f ""`
# would match every process on the host — the guard makes that impossible. The match
# is a unique-per-story full-argv substring, so it never touches another story's tree.
# pkill is portable across macOS and Linux (setsid / kill-by-pgid is not). Best-effort.
#
# Args: $1 = worktree path or `<storyId>-workspace` pattern
_reap_worktree_orphans() {
  local pattern="${1:-}"
  [[ -n "$pattern" && "$pattern" == *-workspace ]] || return 0
  pkill -9 -f "$pattern" 2>/dev/null || true
}

# ── Orphaned-worktree reaper (OSS — disk-leak guard) ──────────────────────
# Enforces orchestration.rules.md §Branch Rules → Worktree lifecycle & cleanup:
# "Orphan reaping is eventually-consistent" + "Data-safety refusal" (the dirty
# guard below is that INVARIANT). This function is the mechanism; the rules file
# is the normative authority.
# Enumerate the worktree directories ACTUALLY ON DISK and remove any whose
# delivery has concluded. This closes the gap in reconcile_done_merged_worktrees(),
# which only iterates ACTIVE-backlog `done` ids and therefore never reclaims the
# worktree of an archived-done / escalated / failed / branch-deleted story. That
# gap is what silently accumulates abandoned worktrees (one observed run: 24
# orphans, ~31 GB, all belonging to stories no longer in the active backlog).
#
# Concluded = ANY authoritative integration signal, evaluated only AFTER the
# safety guards below all pass:
#   1. the story's PR (gh, by `--head story/<sid>`) is MERGED or CLOSED. GitHub
#      retains headRefName on merged/closed PRs, so this matches even after the
#      local branch was deleted — the branch-independent source of truth.
#   2. the worktree HEAD is already an ancestor of origin/<target> (work
#      integrated by a manual/no-PR flow).
#
# HARD SAFETY GUARDS (every one must pass before a removal is even considered):
#   - never PROJECT_DIR itself (realpath compare)
#   - never a live delivery: no `gaai-deliver-<sid>` tmux session AND no fresh
#     (<120s) heartbeat — a wrapper can run detached from any tmux
#   - never a dirty worktree (uncommitted/untracked content) — data safety
# `git worktree remove` deletes only the working dir; the branch ref survives, so
# committed work is never lost (only reclaimable disk is freed).
#
# Throttled to GAAI_WT_REAP_INTERVAL_SEC (default 1800s) so the per-worktree `gh`
# calls cannot run every poll cycle. Best-effort throughout; never aborts the loop.
#
# Requires (set by delivery-daemon.sh before sourcing): PROJECT_DIR, LOCK_DIR,
# TARGET_BRANCH (defaults to staging), and log(). Honors GAAI_WORKTREES_BASE.
reap_orphaned_worktrees() {
  local _now _last _interval _marker
  _interval="${GAAI_WT_REAP_INTERVAL_SEC:-1800}"
  _marker="${LOCK_DIR}/.wt-reap.last"
  _now=$(date +%s)
  _last=0
  [[ -f "$_marker" ]] && _last=$(cat "$_marker" 2>/dev/null || echo 0)
  [[ "$_last" =~ ^[0-9]+$ ]] || _last=0
  (( _now - _last < _interval )) && return 0
  echo "$_now" > "$_marker" 2>/dev/null || true

  # Resolve the worktree base dir (same formula as the dispatch path resolvers).
  local _base _repo_name
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    _base="$GAAI_WORKTREES_BASE"
  else
    _repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    _base="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${_repo_name}"
  fi
  [[ -d "$_base" ]] || return 0

  local _target="${TARGET_BRANCH:-staging}"
  git -C "$PROJECT_DIR" fetch origin "$_target" --quiet 2>/dev/null || true

  local _proj_real
  _proj_real=$(realpath "${REPO_ROOT:-$PROJECT_DIR}" 2>/dev/null || echo "${REPO_ROOT:-$PROJECT_DIR}")

  local _wt _sid _wt_real _hb _hb_mtime _porcelain _rc
  local _pr_json _pr_state _concluded _reason
  for _wt in "$_base"/*-workspace; do
    [[ -d "$_wt" ]] || continue
    _sid=$(basename "$_wt"); _sid="${_sid%-workspace}"

    # Safety: never the main checkout.
    _wt_real=$(realpath "$_wt" 2>/dev/null || echo "$_wt")
    [[ "$_wt_real" == "$_proj_real" ]] && continue

    # Live guard 1: an active delivery owns a tmux session named for this story.
    tmux has-session -t "gaai-deliver-${_sid}" 2>/dev/null && continue

    # Live guard 2: a fresh heartbeat (<120s) means a detached wrapper is running.
    #
    # mtime probes GNU first, BSD second, and that order is load-bearing. GNU
    # stat has no -f format flag: "stat -f %m FILE" reads %m as a *filename*, so
    # it prints the filesystem block for FILE on stdout AND exits non-zero for
    # the bogus "%m" operand. Putting it first therefore fires the || arm while
    # having already emitted junk, and the capture becomes that junk plus the
    # real value — non-numeric, forced to 0 by the guard below, which reads as an
    # ancient heartbeat and reaps the worktree of a live wrapper. BSD stat has no
    # -c, fails cleanly with no stdout, and falls through correctly.
    _hb="${LOCK_DIR}/${_sid}.heartbeat"
    if [[ -f "$_hb" ]]; then
      _hb_mtime=$(stat -c %Y "$_hb" 2>/dev/null || stat -f %m "$_hb" 2>/dev/null || echo 0)
      [[ "$_hb_mtime" =~ ^[0-9]+$ ]] || _hb_mtime=0
      (( _now - _hb_mtime < 120 )) && continue
    fi

    # Data safety: never remove a worktree with uncommitted/untracked content.
    _porcelain=$(git -C "$_wt" status --porcelain 2>/dev/null); _rc=$?
    { (( _rc != 0 )) || [[ -n "$_porcelain" ]]; } && continue

    # Integration signal 1: PR MERGED/CLOSED (branch-independent, authoritative).
    _concluded=0; _reason=""
    _pr_json=$(gh pr list --state all --head "story/${_sid}" --json state --limit 1 2>/dev/null || echo "")
    if [[ -n "$_pr_json" && "$_pr_json" != "[]" ]]; then
      _pr_state=$(printf '%s' "$_pr_json" | grep -oE '"state":"[A-Z]+"' | head -1 | cut -d'"' -f4)
      case "$_pr_state" in
        MERGED) _concluded=1; _reason="pr_merged" ;;
        CLOSED) _concluded=1; _reason="pr_closed" ;;
      esac
    fi
    # Integration signal 2: HEAD already integrated into origin/<target>.
    if (( _concluded == 0 )) && \
       git -C "$_wt" merge-base --is-ancestor HEAD "origin/${_target}" 2>/dev/null; then
      _concluded=1; _reason="head_integrated"
    fi
    (( _concluded == 0 )) && continue

    # Remove. --force: the branch ref still exists; the dir is clean (guarded above).
    if git -C "$PROJECT_DIR" worktree remove --force "$_wt" 2>/dev/null; then
      log "${CYAN:-}[WT-REAP] ${_sid}: removed ${_wt} (${_reason})${NC:-}"
      # Defense-in-depth: this site already gated on PR MERGED/CLOSED or
      # HEAD-integrated above; the guard independently resolves landed too.
      _worktree_branch_delete_or_preserve "$_sid" "story/${_sid}" "orphan-reap" || true
    else
      log "${YELLOW:-}[WT-REAP] ${_sid}: remove failed ${_wt} (lock contention?) — retry next interval${NC:-}"
    fi
  done

  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
}

# ── Worktree integrity helper ──────────────────────────────────
# Sourced here so dispatch's handle_commit_phase can run pre-push checks.
# PROJECT_DIR must be set by caller before sourcing (same requirement as SCHEDULER).
_DISPATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_WORKTREE_INTEGRITY_SH_SOURCED:-}" ]] && \
  source "${_DISPATCH_SCRIPT_DIR}/lib/worktree-integrity.sh" 2>/dev/null && \
  _WORKTREE_INTEGRITY_SH_SOURCED=1

# ── Deterministic test gate + hosted authority controller ──────
# The merge controller is a required trust dependency. A missing or invalid
# source must stop dispatcher initialization; commit handling also checks the
# function at the point of use to fail closed if runtime state is altered.
if [[ -z "${_TEST_GATE_SH_SOURCED:-}" ]]; then
  if ! source "${_DISPATCH_SCRIPT_DIR}/lib/test-gate.sh"; then
    echo "[ERROR] dispatcher initialization: hosted merge authority controller could not be loaded" >&2
    return 1 2>/dev/null || exit 1
  fi
  _TEST_GATE_SH_SOURCED=1
fi
if ! declare -F _run_merge_test_gate >/dev/null 2>&1 \
    || ! declare -F _test_gate_recheck_pr_tuple >/dev/null 2>&1 \
    || ! declare -F _test_gate_outcome_is_deterministic >/dev/null 2>&1; then
  echo "[ERROR] dispatcher initialization: hosted merge authority controller is incomplete" >&2
  return 1 2>/dev/null || exit 1
fi

# Local admission is the publication/spend boundary; unlike an optional hook,
# an unavailable adapter must stop dispatcher initialization.
if [[ -z "${_LOCAL_ADMISSION_SH_SOURCED:-}" ]]; then
  if ! source "${_DISPATCH_SCRIPT_DIR}/lib/local-admission.sh"; then
    echo "[ERROR] dispatcher initialization: local admission adapter could not be loaded" >&2
    return 1 2>/dev/null || exit 1
  fi
  _LOCAL_ADMISSION_SH_SOURCED=1
fi
declare -F _run_local_admission >/dev/null 2>&1 || {
  echo "[ERROR] dispatcher initialization: local admission adapter is incomplete" >&2
  return 1 2>/dev/null || exit 1
}

# ── Active-spawn marker directory (AC1) ──────────────────────────────────
# LOCK_DIR is set by delivery-daemon.sh before sourcing this library.
# Provide a fallback so this library is usable in tests without the full daemon env.
_marker_dir() {
  echo "${LOCK_DIR:-${PROJECT_DIR}/.gaai/project/contexts/backlog/.delivery-locks}"
}

_commit_policy_stall_marker_path() {
  local story_id="$1"
  printf '%s/.commit-policy-stalled-%s\n' "$(_marker_dir)" "$story_id"
}

# Local inhibit evidence for a terminal commit-policy mismatch whose journal
# projection is still pending. It never authorizes a lifecycle transition;
# recovery only uses it to prevent another model or publication attempt.
_write_commit_policy_stall_marker() {
  local story_id="$1" outcome="$2" marker tmp marker_dir
  marker=$(_commit_policy_stall_marker_path "$story_id")
  marker_dir=$(dirname "$marker")
  tmp="${marker}.tmp.$$"
  mkdir -p "$marker_dir" 2>/dev/null || return 1
  (
    umask 077
    printf 'story_id=%s\noutcome=%s\ncreated_at=%s\n' \
      "$story_id" "$outcome" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp"
  ) || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv "$tmp" "$marker" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null || true; return 1; }
}

_write_active_marker() {
  local story_id="$1" phase="$2"
  local mdir
  mdir=$(_marker_dir)
  mkdir -p "$mdir" 2>/dev/null || true
  touch "${mdir}/${story_id}.${phase}.active" 2>/dev/null || true
}

_remove_active_marker() {
  local story_id="$1" phase="$2"
  local mdir
  mdir=$(_marker_dir)
  rm -f "${mdir}/${story_id}.${phase}.active" 2>/dev/null || true
}

# ── Per-phase log rotation ────────────────────────────────────────────────
# Each phase's claude -p run writes to ${worktree}/.delivery-logs/{id}.{phase}.log
# via `tee -a`. On retry after a failed attempt (e.g., error_max_turns), the
# new run would otherwise APPEND to the prior session's log, producing :
#   - Inflated cumulative tool counts in the monitor (parser sees both runs)
#   - Confusing "session boundary" detection in forensic analysis
#
# Rotate the existing log to a timestamped suffix BEFORE the new claude -p
# starts. Forensic trail preserved (old log readable as <name>.YYYYMMDDTHHMMSS),
# new run starts with a fresh empty file.
#
# Flush-before-relaunch is simpler than scoping every parser to "current
# session only" via init-event offset detection.
_rotate_phase_log() {
  local log_path="$1"
  if [[ -f "$log_path" && -s "$log_path" ]]; then
    local rotated="${log_path}.$(date '+%Y%m%dT%H%M%S')"
    mv "$log_path" "$rotated" 2>/dev/null || true
  fi
}

# ── Worktree-scope audit (advisory soft gate) ────────────────────────────
# Runs daemon-worktree-audit.py against the per-phase JSONL log to detect
# Write/Edit/Bash tool calls that operate on absolute paths outside the
# worktree. Writes <log_path>.audit.json with a structured verdict. Advisory
# only — does NOT block phase completion. Output goes to daemon log via
# stderr so violations are visible to the operator without parsing JSON.
_run_worktree_audit() {
  local story_id="$1" phase="$2" log_path="$3" worktree_path="$4"
  local audit_script="${PROJECT_DIR}/.gaai/core/scripts/daemon-worktree-audit.py"
  [[ -f "$audit_script" ]] || return 0
  [[ -f "$log_path" ]] || return 0
  python3 "$audit_script" \
    --story-id "$story_id" \
    --phase "$phase" \
    --log-path "$log_path" \
    --worktree-path "$worktree_path" 2>&1 || true
}

# ── Tool-result error extractor (loop breaker support) ───────────────────
# Reads one JSONL line on stdin. If it's a user-message containing a
# tool_result with is_error:true, prints the first 200 chars of the error
# content to stdout. Otherwise prints nothing. Any parse failure is silent.
_extract_tool_error_content() {
  python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    msg = d.get('message') or {}
    if isinstance(msg, dict):
        for c in (msg.get('content') or []):
            if isinstance(c, dict) and c.get('type') == 'tool_result' and c.get('is_error'):
                v = c.get('content') or ''
                if isinstance(v, list):
                    v = ' '.join(x.get('text','') if isinstance(x, dict) else str(x) for x in v)
                print(str(v)[:200])
                break
except Exception:
    pass
" 2>/dev/null
}

# ── Daemon-prompt template expansion (executor-portable context contract) ──
# Copies $1 (template source) to $2 (destination prompt file), replacing each
# literal "$NAME" token with its resolved value, where each remaining
# argument is a "NAME=value" pair. Substitution is a plain bash string
# replace (${content//search/replace}) — not glob/regex — so template prose,
# code fences, and path values with special characters (/, &, etc.) are
# handled without escaping. Preserves the source's trailing newline.
#
# Why this exists: the Plan/QA daemon-prompt templates carry literal
# "$GAAI_*" references and previously relied on the spawned executor's own
# tool/shell context inheriting the daemon's process env to resolve them.
# That holds for `claude -p` by coincidence but is not guaranteed for other
# executors (e.g. `codex exec`), producing a silent missing-daemon-context
# failure. Resolving the tokens into the prompt bytes at construction time
# makes the prompt executor-invariant.
_expand_daemon_prompt_template() {
  local src="$1" dst="$2"
  shift 2
  local content
  content=$(cat "$src"; printf 'x')
  content="${content%x}"
  local pair name value
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    content="${content//\$${name}/${value}}"
  done
  printf '%s' "$content" > "$dst"
}

# ── Post-substitution tripwire ────────────────────────────────────────────
# Aborts the phase (loud, terminal, auditable) if any $GAAI_* token survived
# template substitution. Should never fire in normal operation — it exists
# to convert a silent broken-contract failure (agent receives literal $-token
# text and has to self-detect) into a deterministic pre-spawn daemon abort.
_assert_prompt_context_resolved() {
  local prompt_file="$1" phase="$2" story_id="$3" trace_id="$4"
  local leftover
  leftover=$(grep -oE '\$GAAI_[A-Z_]+' "$prompt_file" 2>/dev/null | sort -u | tr '\n' ' ')
  leftover="${leftover% }"
  if [[ -n "$leftover" ]]; then
    echo "[ERROR] ${story_id} ${phase}-context-unresolved: unresolved variable(s) [${leftover}] remain in the ${phase} prompt (executor=${GAAI_DAEMON_EXECUTOR:-claude})"
    if [[ "$phase" == "plan" ]]; then
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "PLAN_CONTEXT_UNRESOLVED" "0"
    else
      _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_CONTEXT_UNRESOLVED" "0"
    fi
    _journal_persist_lifecycle "$story_id" "dispatch.${phase}" phase_status failed || return 1
    return 1
  fi
  return 0
}

# ── Loop-breaker wrapper around `claude -p` ──────────────────────────────
# Replaces the synchronous `claude -p ... | tee -a "$log_path"` pattern with
# a streaming reader that:
#   1. Tees every JSONL line to $log_path AND stdout (preserves tmux display
#      and forensic trail unchanged).
#   2. Watches for consecutive identical `is_error:true` tool_result content.
#   3. Kills claude -p if N (default 3) consecutive identical errors are
#      seen, preventing unbounded retry loops where the agent retries the
#      same blocked content forever, burning tokens without producing the
#      expected artefact.
#
# Why this exists: several upstream layers (Bash sandbox parser, tool
# permission system, MCP servers, etc.) can return deterministic
# content-based refusals on a tool call. When that happens, the agent has
# no signal that its current approach is structurally blocked, and
# typically retries the same shape — getting the same refusal — until
# --max-turns runs out. This watcher detects that pattern at the daemon
# level and aborts deterministically rather than relying on probabilistic
# agent self-correction.
#
# Args (positional):
#   $1 — story_id      (for log lines)
#   $2 — phase         (for log lines: plan|qa)
#   $3 — log_path      (per-phase JSONL log)
#   $4 — prompt_file   (stdin for claude)
#   $5 — worktree_path (cwd for claude — branch/path isolation per story)
#   $6+ — extra args passed to claude -p (model, max-turns, etc.)
#
# Env (optional):
#   GAAI_LOOP_BREAKER_THRESHOLD — N consecutive identical errors before kill
#                                  (default: 3)
#   GAAI_LOOP_BREAKER_DISABLE   — set to "1" to fully disable the breaker
#                                  (returns to the legacy `tee -a` pipeline)
#   GAAI_DAEMON_EXECUTOR        — claude|codex (default: claude)
#   GAAI_CODEX_SANDBOX          — codex exec sandbox (default: workspace-write)
#   GAAI_CODEX_MODEL            — optional codex model override
#   GAAI_CODEX_EPHEMERAL        — set to "0" to persist Codex sessions
#   GAAI_CODEX_IGNORE_USER_CONFIG — set to "1" to add --ignore-user-config
#
# Returns:
#   0   — agent exited cleanly
#   2   — worktree path missing or invalid
#   124 — loop breaker triggered (custom exit code, distinct from agent's)
#   <N> — agent's actual exit code on other failures
_run_claude_with_loop_breaker() {
  local story_id="$1" phase="$2" log_path="$3" prompt_file="$4" worktree_path="$5"
  shift 5
  local threshold="${GAAI_LOOP_BREAKER_THRESHOLD:-3}"
  local disabled="${GAAI_LOOP_BREAKER_DISABLE:-0}"
  # Per-call harness override. The router may place a single phase on a harness
  # other than the daemon-wide executor (plan on codex while impl stays on claude,
  # say). Unset — routing off, or blocked — falls back to the daemon default.
  local executor="${GAAI_PHASE_HARNESS:-${GAAI_DAEMON_EXECUTOR:-claude}}"

  # Resolve per-phase wall-clock timeout. Caller may also pass GAAI_PHASE_TIMEOUT_SEC
  # to override; otherwise we look up the phase-specific default.
  local timeout_sec="${GAAI_PHASE_TIMEOUT_SEC:-}"
  if [[ -z "$timeout_sec" ]]; then
    case "$phase" in
      plan) timeout_sec="$GAAI_TIMEOUT_PLAN_SEC" ;;
      impl) timeout_sec="$GAAI_TIMEOUT_IMPL_SEC" ;;
      qa)   timeout_sec="$GAAI_TIMEOUT_QA_SEC" ;;
      *)    timeout_sec="$GAAI_TIMEOUT_PLAN_SEC" ;;
    esac
  fi

  # Worktree must exist — the agent is launched with cwd=$worktree_path so all
  # cwd-relative writes by the agent land in the per-story worktree branch.
  # Without this, agents writing relative paths pollute the parent repo.
  if [[ ! -d "$worktree_path" ]]; then
    echo "[ERROR] ${story_id} _run_claude_with_loop_breaker: worktree path does not exist: $worktree_path" >&2
    return 2
  fi

  # Reasoning-effort expression for this harness, exactly as the routing config
  # declares it — `--effort <level>` on one, a `-c` config override on another.
  # Word splitting is intended: these are argv tokens, none of which contain
  # whitespace. Empty when routing is off, which leaves each harness on its own
  # default.
  local _effort_argv=()
  if [[ -n "${GAAI_PHASE_EFFORT_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    _effort_argv=(${GAAI_PHASE_EFFORT_ARGS})
  fi

  local agent_cmd=()
  case "$executor" in
    claude)
      agent_cmd=(claude -p "$@" ${_effort_argv[@]+"${_effort_argv[@]}"})
      ;;
    codex)
      agent_cmd=(codex exec --json --sandbox "${GAAI_CODEX_SANDBOX:-workspace-write}" --cd "$worktree_path")
      [[ -n "${GAAI_CODEX_MODEL:-}" ]] && agent_cmd+=(--model "$GAAI_CODEX_MODEL")
      [[ "${GAAI_CODEX_EPHEMERAL:-1}" != "0" ]] && agent_cmd+=(--ephemeral)
      [[ "${GAAI_CODEX_IGNORE_USER_CONFIG:-0}" == "1" ]] && agent_cmd+=(--ignore-user-config)
      agent_cmd+=(${_effort_argv[@]+"${_effort_argv[@]}"})
      # The prompt sentinel must stay last.
      agent_cmd+=(-)
      ;;
    *)
      echo "[ERROR] ${story_id} _run_claude_with_loop_breaker: unsupported GAAI_DAEMON_EXECUTOR=${executor}" >&2
      return 2
      ;;
  esac

  # Bypass mode — original synchronous pipeline (escape hatch / debugging).
  # Subshell + exec replaces the subshell process with the agent after cd, so
  # $! reports the agent's PID and signals propagate correctly.
  if [[ "$disabled" == "1" ]]; then
    set -o pipefail
    local _to_cmd
    _to_cmd=$(_resolve_timeout_cmd)
    if [[ -n "$_to_cmd" ]]; then
      ( cd "$worktree_path" && exec "$_to_cmd" --kill-after=10s "${timeout_sec}s" "${agent_cmd[@]}" < "$prompt_file" 2>&1 ) | tee -a "$log_path"
    else
      ( cd "$worktree_path" && exec "${agent_cmd[@]}" < "$prompt_file" 2>&1 ) | tee -a "$log_path"
    fi
    local rc=${PIPESTATUS[0]}
    set +o pipefail
    # `timeout` exits 124 on SIGTERM, 137 on SIGKILL — translate both to our
    # canonical wall-clock RC. 124 collides with the loop-breaker code, but
    # the breaker path emits a synthetic JSONL marker and only triggers via
    # the streaming reader (not bypass mode), so a 124 here can only mean
    # `timeout` fired.
    if [[ "$rc" == "124" || "$rc" == "137" ]]; then
      echo "[TIMEOUT] ${story_id} phase=${phase}: ${executor} wall-clock timeout after ${timeout_sec}s (bypass mode)"
      return "$GAAI_TIMEOUT_RC"
    fi
    return "$rc"
  fi

  # Named fifo for agent → reader handoff
  local fifo
  fifo=$(mktemp -u "/tmp/gaai-agent-fifo-${story_id}-${phase}-XXXXXX")
  if ! mkfifo "$fifo" 2>/dev/null; then
    echo "[WARN] ${story_id} _run_claude_with_loop_breaker: mkfifo failed; falling back to plain pipeline"
    set -o pipefail
    ( cd "$worktree_path" && exec "${agent_cmd[@]}" < "$prompt_file" 2>&1 ) | tee -a "$log_path"
    local rc=${PIPESTATUS[0]}
    set +o pipefail
    return "$rc"
  fi

  # Spawn agent in background, redirecting stdout+stderr to fifo.
  # The subshell cd's into the worktree then exec replaces it with the agent,
  # so $! is the agent's PID and kill -TERM propagates correctly.
  ( cd "$worktree_path" && exec "${agent_cmd[@]}" < "$prompt_file" > "$fifo" 2>&1 ) &
  local agent_pid=$!

  # Write agent subprocess PID sidecar so the daemon hang-detector can kill the
  # agent instead of the wrapper, letting the wrapper's EXIT trap run cleanly.
  local _agent_pid_file
  _agent_pid_file="$(_marker_dir)/${story_id}.agent.pid"
  echo "$agent_pid" > "$_agent_pid_file" 2>/dev/null || true

  # Wall-clock watchdog: send SIGTERM after $timeout_sec, then SIGKILL after
  # an additional 10s grace. Decoupled from the loop-breaker — handles silent
  # hangs that emit no errors. The watchdog auto-exits via `kill -0` check
  # once the agent has ended cleanly, so we don't need to track it for cleanup.
  # Polling granularity = min(timeout/3, 5s) — keeps overshoot bounded for
  # short timeouts (tests, debug overrides) while staying cheap for long ones.
  local watchdog_pid=""
  if [[ -n "$timeout_sec" && "$timeout_sec" -gt 0 ]] 2>/dev/null; then
    local _poll_step=$(( timeout_sec / 3 ))
    (( _poll_step > 5 )) && _poll_step=5
    (( _poll_step < 1 )) && _poll_step=1
    (
      local _waited=0
      while (( _waited < timeout_sec )); do
        sleep "$_poll_step"
        kill -0 "$agent_pid" 2>/dev/null || exit 0
        _waited=$((_waited + _poll_step))
      done
      # Timeout reached — terminate the agent.
      printf '{"type":"system","subtype":"phase_timeout","story_id":"%s","phase":"%s","timeout_sec":%d,"timestamp":"%s"}\n' \
        "$story_id" "$phase" "$timeout_sec" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log_path" 2>/dev/null || true
      kill -TERM "$agent_pid" 2>/dev/null || true
      sleep 10
      kill -0 "$agent_pid" 2>/dev/null && kill -KILL "$agent_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    disown "$watchdog_pid" 2>/dev/null || true
  fi

  # Stream reader: tee each line to log + watch for repeated tool errors
  local last_err="" err_count=0 breaker_triggered=0
  while IFS= read -r line; do
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$log_path"
    if [[ "$line" == *'"is_error":true'* ]]; then
      local content
      content=$(printf '%s' "$line" | _extract_tool_error_content)
      if [[ -n "$content" ]]; then
        if [[ "$content" == "$last_err" ]]; then
          err_count=$((err_count + 1))
        else
          last_err="$content"
          err_count=1
        fi
        if [[ "$err_count" -ge "$threshold" ]]; then
          local err_short="${content:0:160}"
          local breaker_msg
          breaker_msg="[LOOP-BREAKER] ${story_id} phase=${phase}: killing agent_pid=${agent_pid} executor=${executor} after ${err_count} consecutive identical tool errors: ${err_short}"
          echo "$breaker_msg"
          # Synthetic JSONL marker so parsers/monitor see the event in-band
          local err_json
          err_json=$(printf '%s' "$err_short" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$err_short")
          printf '{"type":"system","subtype":"loop_breaker","story_id":"%s","phase":"%s","consecutive_errors":%d,"error_content":%s,"timestamp":"%s"}\n' \
            "$story_id" "$phase" "$err_count" "$err_json" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log_path"
          kill -TERM "$agent_pid" 2>/dev/null || true
          sleep 1
          kill -KILL "$agent_pid" 2>/dev/null || true
          breaker_triggered=1
          # Drain remaining output so fifo writer can close cleanly
          while IFS= read -r drain; do
            printf '%s\n' "$drain"
            printf '%s\n' "$drain" >> "$log_path"
          done
          break
        fi
      fi
    fi
  done < "$fifo"

  local agent_exit=0
  wait "$agent_pid" 2>/dev/null || agent_exit=$?

  # Cleanup: stop the watchdog (no-op if it already exited).
  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" 2>/dev/null || true
  fi

  rm -f "$fifo"
  rm -f "$_agent_pid_file" 2>/dev/null || true

  # Reap orphaned descendants the agent left running in the worktree. The agent was
  # waited above, so any process still rooted in $worktree_path is an orphan — a
  # test runner, dev/build server, or worker pool the agent spawned and whose own
  # tool-call timeout detached rather than reaped. Every kill site that ends a phase
  # (the wall-clock watchdog, the loop-breaker, nested-claude-spawn, a normal exit
  # with leftovers) signals only the agent PID, not its tree; without this sweep
  # those long-lived workers accumulate across QA retries until the daemon host runs
  # out of memory. Running it here — once, after the phase, on every return path —
  # bounds the leak to a single phase.
  _reap_worktree_orphans "$worktree_path"

  if [[ "$breaker_triggered" == "1" ]]; then
    return 124
  fi
  # Translate SIGTERM/SIGKILL exit codes from the watchdog to our canonical
  # wall-clock timeout RC. Agents commonly exit 143 on SIGTERM, 137 on SIGKILL.
  if [[ "$agent_exit" == "143" || "$agent_exit" == "137" ]]; then
    return "$GAAI_TIMEOUT_RC"
  fi
  return "$agent_exit"
}

# ── Inline MCP workspace-scope helpers ───────────────────────────────────────

# Extracts the OAuth bearer token (without "Bearer " prefix) from a .mcp.json file.
# Args: $1 = path to .mcp.json
# Stdout: token string or empty
_extract_mcp_oauth_token() {
  local mcp_json="$1"
  [[ ! -f "$mcp_json" ]] && echo "" && return
  python3 - "$mcp_json" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
try:
  d = json.load(open(sys.argv[1]))
  for s in d.get('mcpServers', {}).values():
    a = s.get('headers', {}).get('Authorization', '')
    if a.startswith('Bearer '):
      print(a[7:], end='')
      sys.exit(0)
except Exception: pass
print('', end='')
PYEOF
}

# Returns 0 (success) iff PROJECT_DIR/.mcp.json contains a GAAI MCP server entry
# (one of the canonical keys : "GAAI-cloud", "gaai-cloud", or "cloud" per the
# plugin's write-mcp-json.mjs amend-mode resolution order). Returns 1 otherwise
# (no .mcp.json, malformed JSON, or no GAAI key). Used by the workspace_scope
# guard in handle_{plan,impl,qa}_phase to avoid false-positive activation when
# .mcp.json exists for unrelated MCP servers (e.g. Paddle, Linear, GitHub).
_has_gaai_mcp_server() {
  local mcp_json="${PROJECT_DIR}/.mcp.json"
  [[ -f "$mcp_json" ]] || return 1
  python3 - "$mcp_json" <<'PYEOF' 2>/dev/null
import json, sys
try:
  d = json.load(open(sys.argv[1]))
  s = d.get('mcpServers', {})
  sys.exit(0 if any(k in s for k in ('GAAI-cloud', 'gaai-cloud', 'cloud')) else 1)
except Exception:
  sys.exit(1)
PYEOF
}

# Builds inline --mcp-config JSON for daemon-spawned claude -p processes.
# Passes X-GAAI-Workspace-Scope + X-GAAI-Session-Mode: autonomous headers.
# Args: $1 = workspace_id (UUID), $2 = oauth_token (raw, no "Bearer " prefix)
# Stdout: JSON string
_build_daemon_mcp_config() {
  local workspace_id="$1" oauth_token="$2"
  printf '{"mcpServers":{"GAAI-cloud":{"type":"http","url":"https://mcp.gaai.cloud/mcp","headers":{"Authorization":"Bearer %s","X-GAAI-Workspace-Scope":"%s","X-GAAI-Session-Mode":"autonomous"}}}}' \
    "$oauth_token" "$workspace_id"
}

# ── Field extractors (AC1 — verbatim per story AC1 specification) ─────────

get_phase_status() {
  local id="$1"
  awk -v id="$id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+phase_status:/ {
      gsub(/^[[:space:]]+phase_status:[[:space:]]*/, "")
      gsub(/[[:space:]]+#.*$/, "")  # strip YAML inline comment (defensive — `#` after whitespace)
      gsub(/[[:space:]]*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$BACKLOG_FILE"
}

get_delivery_pipeline() {
  local id="$1"
  awk -v id="$id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+delivery_pipeline:/ {
      gsub(/^[[:space:]]+delivery_pipeline:[[:space:]]*/, "")
      gsub(/[[:space:]]+#.*$/, "")  # strip YAML inline comment (defensive — `#` after whitespace)
      gsub(/[[:space:]]*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$BACKLOG_FILE"
}

# Helper: read impl_model_tag from backlog (returns "absent" if unset/missing)
get_impl_model_tag() {
  local id="$1"
  local val
  val=$(awk -v id="$id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+impl_model:/ {
      gsub(/^[[:space:]]+impl_model:[[:space:]]*/, "")
      gsub(/[[:space:]]+#.*$/, "")  # strip YAML inline comment (`#` preceded by whitespace)
      gsub(/[[:space:]]+#.*$/, "")  # strip YAML inline comment (defensive — `#` after whitespace)
      gsub(/[[:space:]]*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$BACKLOG_FILE" 2>/dev/null || true)
  echo "${val:-absent}"
}

# Helper: read tier from backlog YAML (returns "" if absent — caller must default)
get_story_tier() {
  local id="$1"
  awk -v id="$id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+tier:/ {
      gsub(/^[[:space:]]+tier:[[:space:]]*/, "")
      gsub(/[[:space:]]+#.*$/, "")  # strip YAML inline comment (defensive — `#` after whitespace)
      gsub(/[[:space:]]*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$BACKLOG_FILE" 2>/dev/null || true
}

# Helper: read story title from backlog YAML (returns "" if absent)
get_story_title() {
  local id="$1"
  awk -v id="$id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+title:/ {
      gsub(/^[[:space:]]+title:[[:space:]]*/, "")
      gsub(/[[:space:]]+#.*$/, "")  # strip YAML inline comment (defensive — `#` after whitespace)
      gsub(/[[:space:]]*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$BACKLOG_FILE"
}

# Helper: read related_decs from backlog YAML (returns space-sep list, "" if absent/empty)
get_related_decs() {
  local id="$1"
  awk -v id="$id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+related_decs:/ {
      gsub(/^[[:space:]]+related_decs:[[:space:]]*/, "")
      gsub(/[[:space:]]*$/, "")
      # Strip YAML list brackets and commas
      gsub(/^\[/, ""); gsub(/\]$/, ""); gsub(/,/, "")
      print
      exit
    }
  ' "$BACKLOG_FILE"
}

# ── Routing record helper ─────────────────────────────────────────────────
# Emits one JSONL record to runtime-routing.jsonl via runtime-routing-logger.js.
# Arguments: story_id trace_id phase provider fallback_reason
_emit_routing_record() {
  local story_id="$1" trace_id="$2" phase="$3" provider="$4" fallback_reason="$5"
  local impl_tag
  impl_tag=$(get_impl_model_tag "$story_id")

  local log_path_args=()
  if [[ -n "${ROUTING_LOG_PATH:-}" ]]; then
    log_path_args=(--log-path "$ROUTING_LOG_PATH")
  fi

  node "$PROJECT_DIR/.gaai/core/adapters/claude-code/runtime-routing-logger.js" \
    --trace-id  "$trace_id" \
    --story-id  "$story_id" \
    --phase     "$phase" \
    --provider  "$provider" \
    --model     "n/a" \
    --duration-ms 0 \
    --fallback-reason "$fallback_reason" \
    --impl-model-tag  "$impl_tag" \
    ${log_path_args[@]+"${log_path_args[@]}"} \
    2>/dev/null || _emit_routing_record_fallback "$trace_id" "$story_id" "$phase" "$provider" "n/a" "0" "$fallback_reason" "$impl_tag" "" "" ""
}

_emit_routing_record_fallback() {
  [[ -n "${ROUTING_LOG_PATH:-}" ]] || return 0
  local trace_id="$1" story_id="$2" phase="$3" provider="$4" model="$5" duration_ms="$6" fallback_reason="$7" impl_tag="$8" pipeline="${9:-}" pr_url="${10:-}" auto_merge_applied="${11:-}" qa_summary="${12:-}"
  TRACE_ID="$trace_id" STORY_ID="$story_id" PHASE="$phase" PROVIDER="$provider" MODEL="$model" DURATION_MS="$duration_ms" FALLBACK_REASON="$fallback_reason" IMPL_TAG="$impl_tag" PIPELINE="$pipeline" PR_URL="$pr_url" AUTO_MERGE_APPLIED="$auto_merge_applied" QA_SUMMARY="$qa_summary" ROUTING_LOG_PATH="$ROUTING_LOG_PATH" \
    python3 - <<'PYEOF' 2>/dev/null || true
import json, os, time
record = {
  "trace_id": os.environ["TRACE_ID"],
  "story_id": os.environ["STORY_ID"],
  "phase": os.environ["PHASE"],
  "provider": os.environ["PROVIDER"],
  "model": os.environ["MODEL"],
  "duration_ms": int(os.environ.get("DURATION_MS") or 0),
  "fallback_reason": None if os.environ.get("FALLBACK_REASON") in ("", "null") else os.environ.get("FALLBACK_REASON"),
  "impl_model_tag": os.environ.get("IMPL_TAG") or "",
  "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
if os.environ.get("PIPELINE"):
  record["pipeline"] = os.environ["PIPELINE"]
if os.environ.get("PR_URL"):
  record["pr_url"] = os.environ["PR_URL"]
if os.environ.get("AUTO_MERGE_APPLIED"):
  record["auto_merge_applied"] = os.environ["AUTO_MERGE_APPLIED"] == "true"
if os.environ.get("QA_SUMMARY"):
  try:
    record["qa_summary"] = json.loads(os.environ["QA_SUMMARY"])
  except (ValueError, TypeError):
    pass
with open(os.environ["ROUTING_LOG_PATH"], "a", encoding="utf-8") as fh:
  fh.write(json.dumps(record, separators=(",", ":")) + "\n")
PYEOF
}

# ── Plan-phase routing record (adds --pipeline, real model, real duration) ──
# Arguments: story_id trace_id provider fallback_reason duration_ms
_emit_plan_routing_record() {
  local story_id="$1" trace_id="$2" provider="$3" fallback_reason="$4" duration_ms="$5"
  local impl_tag model_val
  impl_tag=$(get_impl_model_tag "$story_id")
  model_val="${CLAUDE_MODEL_PRIMARY:-claude-sonnet-5}"
  if [[ "${GAAI_DAEMON_EXECUTOR:-claude}" == "codex" ]]; then
    [[ "$provider" == "primary" ]] && provider="codex"
    model_val="${GAAI_CODEX_MODEL:-codex-default}"
  fi

  local log_path_args=()
  if [[ -n "${ROUTING_LOG_PATH:-}" ]]; then
    log_path_args=(--log-path "$ROUTING_LOG_PATH")
  fi

  node "$PROJECT_DIR/.gaai/core/adapters/claude-code/runtime-routing-logger.js" \
    --trace-id        "$trace_id" \
    --story-id        "$story_id" \
    --phase           "plan" \
    --provider        "$provider" \
    --model           "$model_val" \
    --duration-ms     "$duration_ms" \
    --fallback-reason "$fallback_reason" \
    --impl-model-tag  "$impl_tag" \
    --pipeline        "3phase" \
    ${log_path_args[@]+"${log_path_args[@]}"} \
    2>/dev/null || _emit_routing_record_fallback "$trace_id" "$story_id" "plan" "$provider" "$model_val" "$duration_ms" "$fallback_reason" "$impl_tag" "3phase" "" ""
}

# ── QA-phase routing record (adds --pipeline, real model, real duration, verdict) ──
# Arguments: story_id trace_id provider fallback_reason duration_ms [qa_summary_json]
# qa_summary_json (AC5): the qa-verdict.mjs validator's own sanitized stdout summary
# (story_id, schema_version, both axes, aggregate, remediation route, evaluated_as_of,
# surface/evidence counts, safe locators) — omitted when the validator did not run
# or did not succeed (e.g. QA_HANDOFF_INVALID / QA_SCHEDULER_FAILURE branches).
_emit_qa_routing_record() {
  local story_id="$1" trace_id="$2" provider="$3" fallback_reason="$4" duration_ms="$5" qa_summary="${6:-}"
  local impl_tag model_val
  impl_tag=$(get_impl_model_tag "$story_id")
  model_val="${CLAUDE_MODEL_PRIMARY:-claude-sonnet-5}"
  if [[ "${GAAI_DAEMON_EXECUTOR:-claude}" == "codex" ]]; then
    [[ "$provider" == "primary" ]] && provider="codex"
    model_val="${GAAI_CODEX_MODEL:-codex-default}"
  fi

  local log_path_args=()
  if [[ -n "${ROUTING_LOG_PATH:-}" ]]; then
    log_path_args=(--log-path "$ROUTING_LOG_PATH")
  fi

  node "$PROJECT_DIR/.gaai/core/adapters/claude-code/runtime-routing-logger.js" \
    --trace-id        "$trace_id" \
    --story-id        "$story_id" \
    --phase           "qa" \
    --provider        "$provider" \
    --model           "$model_val" \
    --duration-ms     "$duration_ms" \
    --fallback-reason "$fallback_reason" \
    --impl-model-tag  "$impl_tag" \
    --pipeline        "3phase" \
    --qa-summary      "$qa_summary" \
    ${log_path_args[@]+"${log_path_args[@]}"} \
    2>/dev/null || _emit_routing_record_fallback "$trace_id" "$story_id" "qa" "$provider" "$model_val" "$duration_ms" "$fallback_reason" "$impl_tag" "3phase" "" "" "$qa_summary"
}

# ── Commit-phase routing record (adds --pipeline, --pr-url, --auto-merge-applied) ──
# Arguments: story_id trace_id provider fallback_reason duration_ms pr_url auto_merge_applied
_emit_commit_routing_record() {
  local story_id="$1" trace_id="$2" provider="$3" fallback_reason="$4" duration_ms="$5"
  local pr_url="${6:-}" auto_merge_applied="${7:-false}"
  local impl_tag
  impl_tag=$(get_impl_model_tag "$story_id")

  # Recovery consumes this one-shot observation after a failed commit phase.
  # It is daemon state, not candidate evidence, and never authorizes a merge.
  if [[ "$provider" == "error" ]]; then
    if ! _commit_retry_write_observation "$story_id" "$fallback_reason"; then
      # The containment owner preserves any prior authenticated event/state.
      # This caller cannot reopen or invalidate the path after a failed write.
      echo "[COMMIT-RETRY] ${story_id} durable outcome write failed — recovery relaunch inhibited" >&2
      return 1
    fi
  else
    if ! _commit_retry_clear "$story_id"; then
      echo "[COMMIT-RETRY] ${story_id} durable state clear failed — terminal routing inhibited" >&2
      return 1
    fi
  fi

  local log_path_args=()
  if [[ -n "${ROUTING_LOG_PATH:-}" ]]; then
    log_path_args=(--log-path "$ROUTING_LOG_PATH")
  fi

  node "$PROJECT_DIR/.gaai/core/adapters/claude-code/runtime-routing-logger.js" \
    --trace-id           "$trace_id" \
    --story-id           "$story_id" \
    --phase              "commit" \
    --provider           "$provider" \
    --model              "n/a" \
    --duration-ms        "$duration_ms" \
    --fallback-reason    "$fallback_reason" \
    --impl-model-tag     "$impl_tag" \
    --pipeline           "3phase" \
    --pr-url             "$pr_url" \
    --auto-merge-applied "$auto_merge_applied" \
    ${log_path_args[@]+"${log_path_args[@]}"} \
    2>/dev/null || _emit_routing_record_fallback "$trace_id" "$story_id" "commit" "$provider" "n/a" "$duration_ms" "$fallback_reason" "$impl_tag" "3phase" "$pr_url" "$auto_merge_applied"
}

# ── Local admission boundaries ───────────────────────────────────────────
GAAI_ADMITTED_SHA=""
GAAI_ADMITTED_BASE_SHA=""
GAAI_ADMISSION_RECEIPT=""

_admission_retryable() {
  case "$1" in
    blocked:empty_candidate_diff|blocked:command_*|blocked:execution_failed|blocked:stale_evidence)
      return 0 ;;
    *) return 1 ;;
  esac
}

_route_admission_block() {
  local story_id="$1" trace_id="$2" boundary="$3" outcome="$4"
  local phase="commit"
  LOCAL_ADMISSION_OUTCOME="$outcome"
  [[ "$boundary" == pre_qa ]] && phase="qa"
  echo "[LOCAL-ADMISSION] story=${story_id} boundary=${boundary} outcome=${outcome} publication_admitted=false"
  if [[ "$phase" == qa ]]; then
    _emit_qa_routing_record "$story_id" "$trace_id" error "$outcome" 0
  else
    _emit_commit_routing_record "$story_id" "$trace_id" error "$outcome" 0 "" false
  fi
  if _admission_retryable "$outcome"; then
    local route="${LOCK_DIR}/.qa-route-${story_id}" tmp="${LOCK_DIR}/.qa-route-${story_id}.tmp.$$"
    local retry_phase_status="qa_failed"
    [[ "$phase" == commit ]] && retry_phase_status="implemented"
    _journal_persist_lifecycle "$story_id" "dispatch.${phase}" \
      phase_status "$retry_phase_status" || return 1
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    printf 'impl\n' > "$tmp" 2>/dev/null && mv "$tmp" "$route" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    local terminal="commit_stalled"; [[ "$boundary" == pre_qa ]] && terminal="qa_escalated"
    _journal_persist_lifecycle "$story_id" "dispatch.${phase}" phase_status "$terminal" || return 1
    declare -F notify_escalation_inline >/dev/null 2>&1 && \
      notify_escalation_inline "$story_id" "$outcome" "Local ${boundary} admission requires operator attention before any downstream spend"
  fi
}

_restore_delivery_governance() {
  local repo="$1" path
  for path in .gaai/project/contexts/backlog/active.backlog.yaml \
      .gaai/core/skills/skills-index.yaml .gaai/project/skills/skills-index.yaml; do
    git -C "$repo" restore --source=HEAD --staged --worktree -- "$path" 2>/dev/null || true
  done
}

_reconcile_admission_base() {
  local repo="$1" base="${TARGET_BRANCH:-staging}"
  git -C "$repo" fetch origin "$base" --quiet 2>/dev/null || return 1
  if ! git -C "$repo" merge --no-edit "origin/${base}" >/dev/null 2>&1; then
    git -C "$repo" merge --abort >/dev/null 2>&1 || true
    return 1
  fi
  [[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]
}

_local_admission_gate() {
  local boundary="$1" story_id="$2" trace_id="$3" repo="$4"
  local receipts="$(_marker_dir)/local-admission-receipts" expected_publication=false
  GAAI_ADMITTED_SHA=""; GAAI_ADMITTED_BASE_SHA=""; GAAI_ADMISSION_RECEIPT=""
  [[ "$boundary" == final ]] && expected_publication=true
  if ! _run_local_admission "$boundary" "$story_id" "$repo" "${TARGET_BRANCH:-staging}" "$receipts"; then
    _route_admission_block "$story_id" "$trace_id" "$boundary" "${LOCAL_ADMISSION_OUTCOME:-blocked:unknown}"
    return 1
  fi
  local fields receipt_head receipt_base receipt_outcome receipt_publication selected
  fields=$(node -e 'const r=require(process.argv[1]); console.log([r.candidate?.head_sha||"",r.candidate?.base_sha||"",r.outcome||"",String(r.publication_admitted),[...(r.selected_surface_ids||[]),...(r.selected_command_ids||[])].join(",")].join("\t"))' "$LOCAL_ADMISSION_RECEIPT_PATH" 2>/dev/null) || fields=""
  IFS=$'\t' read -r receipt_head receipt_base receipt_outcome receipt_publication selected <<<"$fields"
  if [[ ! "$receipt_head" =~ ^[0-9a-f]{40}$ || "$receipt_head" != "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" \
      || ! "$receipt_base" =~ ^[0-9a-f]{40}$ || "$receipt_outcome" != pass \
      || "$receipt_publication" != "$expected_publication" ]]; then
    rm -f "$LOCAL_ADMISSION_RECEIPT_PATH" 2>/dev/null || true
    _route_admission_block "$story_id" "$trace_id" "$boundary" blocked:receipt_invalid
    return 1
  fi
  GAAI_ADMITTED_SHA="$receipt_head"; GAAI_ADMITTED_BASE_SHA="$receipt_base"
  GAAI_ADMISSION_RECEIPT="$LOCAL_ADMISSION_RECEIPT_PATH"
  echo "[LOCAL-ADMISSION] story=${story_id} boundary=${boundary} outcome=pass head=${receipt_head} selected=${selected:-none} publication_admitted=${receipt_publication}"
}

_admit_current_candidate() {
  local boundary="$1" story_id="$2" trace_id="$3" repo="$4"
  if ! _reconcile_admission_base "$repo"; then
    _route_admission_block "$story_id" "$trace_id" "$boundary" blocked:base_reconcile_failed
    return 1
  fi
  _local_admission_gate "$boundary" "$story_id" "$trace_id" "$repo"
}

_prepare_pre_qa_admission() {
  local story_id="$1" trace_id="$2" repo="$3" base="${TARGET_BRANCH:-staging}"
  local candidate_paths=(. \
    ":(exclude,top,literal).gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md" \
    ":(exclude,top,literal).gaai/project/contexts/artefacts/impl-reports/${story_id}.impl-report.md" \
    ":(exclude,top,literal).gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-report.md" \
    ":(exclude,top,literal).gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-verdict.json" \
    ":(exclude,top,literal).gaai/project/contexts/artefacts/memory-deltas/${story_id}.memory-delta.md")
  _restore_delivery_governance "$repo"
  git -C "$repo" add -A 2>/dev/null || {
    _route_admission_block "$story_id" "$trace_id" pre_qa blocked:seal_stage_failed; return 1; }
  git -C "$repo" fetch origin "$base" --quiet 2>/dev/null || {
    _route_admission_block "$story_id" "$trace_id" pre_qa blocked:base_fetch_failed; return 1; }
  if git -C "$repo" diff --cached --quiet "origin/${base}" -- "${candidate_paths[@]}"; then
    _route_admission_block "$story_id" "$trace_id" pre_qa blocked:empty_candidate_diff
    return 1
  fi
  if ! git -C "$repo" diff --cached --quiet; then
    git -C "$repo" commit -m "chore(${story_id}): local implementation seal" \
      -m '[gaai-local-admission:pre_qa]' >/dev/null 2>&1 || {
      _route_admission_block "$story_id" "$trace_id" pre_qa blocked:seal_commit_failed; return 1; }
  elif ! git -C "$repo" log -1 --format=%B | grep -q '^\[gaai-local-admission:pre_qa\]$'; then
    git -C "$repo" commit --allow-empty -m "chore(${story_id}): local implementation seal" \
      -m '[gaai-local-admission:pre_qa]' >/dev/null 2>&1 || {
      _route_admission_block "$story_id" "$trace_id" pre_qa blocked:seal_commit_failed; return 1; }
  fi
  _admit_current_candidate pre_qa "$story_id" "$trace_id" "$repo"
}

# ── Worktree dependency marker ─────────────────────────────────────────────
# Resolves the directory whose presence proves a worktree's dependencies are
# installed. Default is pnpm's own virtual store at the workspace root, which
# every successful `pnpm install` creates in any pnpm project.
#
# This used to be a hardcoded ${worktree_path}/workers/<some-app>/node_modules/
# <some-dep> path. That directory exists only in the repo the constant was read
# off, so everywhere else the marker was permanently absent: the idempotence
# check below reported "not installed" on EVERY handle_plan_phase entry and
# reinstalled from scratch, and the freshness marker in handle_commit_phase
# could never be seeded. It also put a project-specific path in the OSS
# substrate, which auto-syncs to the public framework repo.
#
# GAAI_WT_DEPS_MARKER overrides it with a worktree-relative path, for layouts
# where the root store is not a sufficient proof (e.g. a workspace whose
# packages are installed selectively).
_wt_deps_marker_dir() {
  local worktree_path="$1"
  printf '%s/%s' "$worktree_path" "${GAAI_WT_DEPS_MARKER:-node_modules/.pnpm}"
}

# ── Worktree dependency installer ──────────────────────────────────────────
# Ensures node_modules are populated before the PLAN phase agent spawns.
# Idempotent: checks the marker dir resolved by _wt_deps_marker_dir.
# Called on EVERY handle_plan_phase entry (fresh + resumed worktrees).
ensure_wt_dependencies_installed() {
  local story_id="$1" trace_id="$2" worktree_path="$3"
  local timeout_s marker_dir ts t_start t_end duration_ms install_exit timeout_cmd

  timeout_s="${GAAI_PNPM_INSTALL_TIMEOUT:-120}"
  marker_dir="$(_wt_deps_marker_dir "$worktree_path")"
  ts=$(date '+%H:%M:%S')

  if [[ -d "$marker_dir" ]]; then
    echo "[${ts}] ${story_id} ${trace_id} [wt-deps] wt_deps_check marker_present=true"
    return 0
  fi

  echo "[${ts}] ${story_id} ${trace_id} [wt-deps] wt_deps_check marker_present=false"
  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} ${trace_id} [wt-deps] wt_deps_install_started timeout_s=${timeout_s}"

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_start=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_start=$(( $(date +%s) * 1000 ))
  fi

  timeout_cmd=$(_resolve_timeout_cmd)
  install_exit=0
  if [[ -n "$timeout_cmd" ]]; then
    (cd "$worktree_path" && "$timeout_cmd" "$timeout_s" pnpm install --frozen-lockfile --silent) \
      || install_exit=$?
  else
    (cd "$worktree_path" && pnpm install --frozen-lockfile --silent) &
    local install_pid=$!
    local waited=0
    while kill -0 "$install_pid" 2>/dev/null; do
      if (( waited >= timeout_s )); then
        kill "$install_pid" 2>/dev/null || true
        wait "$install_pid" 2>/dev/null || true
        install_exit=124
        break
      fi
      sleep 1
      (( waited++ )) || true
    done
    if [[ $install_exit -eq 0 ]]; then
      wait "$install_pid" 2>/dev/null || install_exit=$?
    fi
  fi

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_end=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_end=$(( $(date +%s) * 1000 ))
  fi
  duration_ms=$(( t_end - t_start ))
  ts=$(date '+%H:%M:%S')

  if [[ $install_exit -eq 0 ]]; then
    echo "[${ts}] ${story_id} ${trace_id} [wt-deps] wt_deps_install_completed duration_ms=${duration_ms}"
    return 0
  fi

  echo "[${ts}] ${story_id} ${trace_id} [wt-deps] wt_deps_install_failed duration_ms=${duration_ms} exit_code=${install_exit}"
  _emit_plan_routing_record "$story_id" "$trace_id" "error" "PNPM_INSTALL_FAILED" "${duration_ms}"
  return 1
}

# ── Worktree deps freshness guard ────────────────────────────────
# Compares pnpm-lock.yaml sha256 against a marker file in the worktree.
# On match → skip install (idempotent fast path).
# On mismatch / absent → pnpm install --frozen-lockfile + update marker.
_ensure_worktree_deps_fresh() {
  local story_id="$1" worktree_path="$2"
  local timeout_s marker_path lockfile_path current_hash stored_hash hash_short
  local timeout_cmd install_exit t_start_ms t_end_ms duration_s

  timeout_s="${GAAI_PNPM_INSTALL_TIMEOUT_SEC:-300}"
  marker_path="${worktree_path}/.gaai-pnpm-install-marker"
  lockfile_path="${worktree_path}/pnpm-lock.yaml"

  # No lockfile → nothing to guard (e.g. non-pnpm repo)
  [[ ! -f "$lockfile_path" ]] && return 0

  # Compute hash (sha256sum on Linux, shasum -a 256 on macOS)
  current_hash=$(sha256sum < "$lockfile_path" 2>/dev/null | awk '{print $1}')
  if [[ -z "$current_hash" ]]; then
    current_hash=$(shasum -a 256 < "$lockfile_path" 2>/dev/null | awk '{print $1}')
  fi
  # Hash tool unavailable → treat as fresh (no regression)
  [[ -z "$current_hash" ]] && return 0

  hash_short="${current_hash:0:8}"
  echo "[COMMIT-PHASE] ${story_id} : checking worktree deps freshness (lockfile hash=${hash_short})"

  stored_hash=""
  [[ -f "$marker_path" ]] && stored_hash=$(cat "$marker_path" 2>/dev/null)

  if [[ "$current_hash" == "$stored_hash" ]]; then
    echo "[COMMIT-PHASE] ${story_id} : worktree deps fresh (marker hash matches) — skipping install"
    return 0
  fi

  echo "[COMMIT-PHASE] ${story_id} : worktree deps stale or absent — running pnpm install --frozen-lockfile"

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_start_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_start_ms=$(( $(date +%s) * 1000 ))
  fi

  timeout_cmd=$(_resolve_timeout_cmd)
  install_exit=0
  if [[ -n "$timeout_cmd" ]]; then
    (cd "$worktree_path" && "$timeout_cmd" "$timeout_s" pnpm install --frozen-lockfile) \
      || install_exit=$?
  else
    (cd "$worktree_path" && pnpm install --frozen-lockfile) &
    local install_pid=$!
    local waited=0
    while kill -0 "$install_pid" 2>/dev/null; do
      if (( waited >= timeout_s )); then
        kill "$install_pid" 2>/dev/null || true
        wait "$install_pid" 2>/dev/null || true
        install_exit=124
        break
      fi
      sleep 1
      (( waited++ )) || true
    done
    if [[ $install_exit -eq 0 ]]; then
      wait "$install_pid" 2>/dev/null || install_exit=$?
    fi
  fi

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_end_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_end_ms=$(( $(date +%s) * 1000 ))
  fi
  duration_s=$(( (t_end_ms - t_start_ms) / 1000 ))

  if [[ $install_exit -eq 124 ]]; then
    echo "[COMMIT-PHASE] ${story_id} : pnpm install timed out after ${timeout_s}s — surfacing error to dispatch"
    return 1
  fi

  if [[ $install_exit -ne 0 ]]; then
    return 1
  fi

  # Success — write marker
  printf '%s\n' "$current_hash" > "$marker_path"
  echo "[COMMIT-PHASE] ${story_id} : pnpm install completed in ${duration_s}s, marker updated"
  return 0
}

# ── Phase handlers ────────────────────────────────────────────────────────

# Re-pin the target object carried by the daemon wrapper before any phase can
# inspect local state or invoke a lifecycle/currentness side effect.  This is
# deliberately phase-agnostic: the typed classifier validates the record, but
# only its immutable source/blob/record identity is consumed here.
_dispatch_target_identity() {
  local story_id="$1" target_branch="${TARGET_BRANCH:-staging}"
  local snapshot source blob facts record
  [[ "$target_branch" =~ ^[A-Za-z0-9._/-]+$ \
      && "$target_branch" != -* \
      && -n "${BACKLOG_REL:-}" \
      && "$(type -t forward_classify_snapshot 2>/dev/null)" == function ]] \
    || return 1
  snapshot=$(mktemp "${LOCK_DIR:?}/.plan-target-XXXXXX" 2>/dev/null) || return 1
  chmod 600 "$snapshot" 2>/dev/null || { rm -f "$snapshot"; return 1; }
  if ! git -C "$PROJECT_DIR" fetch origin "$target_branch" --quiet \
      || ! source=$(git -C "$PROJECT_DIR" rev-parse "origin/${target_branch}" 2>/dev/null) \
      || ! blob=$(git -C "$PROJECT_DIR" rev-parse "${source}:${BACKLOG_REL}" 2>/dev/null) \
      || ! git -C "$PROJECT_DIR" show "${source}:${BACKLOG_REL}" > "$snapshot" 2>/dev/null \
      || ! facts=$(forward_classify_snapshot "$story_id" "$snapshot" "$source" \
           "$blob" postclaim verified false); then
    rm -f "$snapshot"
    return 1
  fi
  IFS=$'\t' read -r _ _ _ _ _ record _ _ <<< "$facts"
  rm -f "$snapshot"
  [[ "$source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && "$blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && "$record" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\t%s\t%s\n' "$source" "$blob" "$record"
}

_dispatch_expected_target_guard() {
  local story_id="$1" expected_source="$2" expected_blob="$3"
  local expected_record="$4" actual source blob record
  [[ "$expected_source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && "$expected_blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && "$expected_record" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual=$(_dispatch_target_identity "$story_id") || return 1
  IFS=$'\t' read -r source blob record <<< "$actual"
  [[ "$source:$blob:$record" == \
    "$expected_source:$expected_blob:$expected_record" ]]
}

# Return a canonical identity for exactly one Story as it exists in an exact
# commit.  The backlog object is materialized into a private file, opened once
# without following links, checked for duplicate YAML keys, and reduced to the
# selected Story only.  Unrelated backlog rows therefore cannot change this
# identity, while any semantic mutation of the selected Story does.
_dispatch_story_record_at_commit() {
  local story_id="$1" commit="$2" snapshot result blob backlog_entry
  local story_root=".gaai/project/contexts/artefacts/stories"
  local story_rel story_blob story_entry
  [[ "$story_id" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ \
      && "$commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && -n "${BACKLOG_REL:-}" ]] || return 1
  story_rel="${story_root}/${story_id}.story.md"
  git -C "$PROJECT_DIR" cat-file -e "${commit}^{commit}" 2>/dev/null || return 1
  blob=$(git -C "$PROJECT_DIR" rev-parse "${commit}:${BACKLOG_REL}" 2>/dev/null) \
    || return 1
  [[ "$blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
  backlog_entry=$(git -C "$PROJECT_DIR" ls-tree "$commit" -- "$BACKLOG_REL" \
    2>/dev/null) || return 1
  [[ "$backlog_entry" == "100644 blob ${blob}"$'\t'"${BACKLOG_REL}" ]] \
    || return 1
  story_blob=$(git -C "$PROJECT_DIR" rev-parse "${commit}:${story_rel}" \
    2>/dev/null) || return 1
  [[ "$story_blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
  story_entry=$(git -C "$PROJECT_DIR" ls-tree "$commit" -- "$story_rel" \
    2>/dev/null) || return 1
  [[ "$story_entry" == "100644 blob ${story_blob}"$'\t'"${story_rel}" ]] \
    || return 1
  snapshot=$(mktemp "${LOCK_DIR:?}/.dispatch-story-XXXXXX" 2>/dev/null) || return 1
  chmod 600 "$snapshot" 2>/dev/null || { rm -f "$snapshot"; return 1; }
  if ! git -C "$PROJECT_DIR" show "${commit}:${BACKLOG_REL}" > "$snapshot" 2>/dev/null; then
    rm -f "$snapshot"
    return 1
  fi
  local YAML_RUNTIME_ROLE=dispatcher
  result=$(yaml_runtime_run "$snapshot" "$story_id" "$blob" "$story_blob" <<'PY'
import hashlib
import os
import re
import stat
import sys

import yaml

path, story, expected_blob, story_blob = sys.argv[1:]
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", story):
    raise SystemExit(1)
if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", expected_blob):
    raise SystemExit(1)
if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", story_blob):
    raise SystemExit(1)

class UniqueLoader(yaml.SafeLoader):
    pass

def construct_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError
        result[key] = loader.construct_object(value_node, deep=deep)
    return result

UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping
)

fd = None
try:
    before = os.lstat(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(fd)
    if (not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        raise ValueError
    chunks = []
    while True:
        chunk = os.read(fd, 131072)
        if not chunk:
            break
        chunks.append(chunk)
    after = os.lstat(path)
    if (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino):
        raise ValueError
    data = b"".join(chunks)
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)

try:
    hash_name = "sha1" if len(expected_blob) == 40 else "sha256"
    object_bytes = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
    if hashlib.new(hash_name, object_bytes).hexdigest() != expected_blob:
        raise ValueError
    document = yaml.load(data.decode("utf-8"), Loader=UniqueLoader)
    items = document["items"]
    if not isinstance(items, list):
        raise ValueError
    by_id = {}
    for item in items:
        if not isinstance(item, dict):
            raise ValueError
        item_id = item.get("id")
        if (not isinstance(item_id, str)
                or not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", item_id)
                or item_id in by_id):
            raise ValueError
        by_id[item_id] = item
    selected = [by_id[story]] if story in by_id else []
    if len(selected) != 1:
        raise ValueError
    item = selected[0]
    status = item.get("status")
    phase = item.get("phase_status")
    if (not isinstance(status, str) or not isinstance(phase, str)
            or not re.fullmatch(r"[a-z][a-z0-9_]*", status)
            or not re.fullmatch(r"[a-z][a-z0-9_]*", phase)):
        raise ValueError
    canonical = yaml.safe_dump(
        item, sort_keys=True, allow_unicode=True,
        default_flow_style=False, width=4096,
    ).encode("utf-8")
except (KeyError, TypeError, UnicodeDecodeError, ValueError, yaml.YAMLError):
    raise SystemExit(1)

digest = hashlib.sha256(canonical).hexdigest()
sys.stdout.write("\t".join((digest, status, phase, story_blob)))
PY
  ) || { rm -f "$snapshot"; return 1; }
  rm -f "$snapshot" || return 1
  [[ "$result" =~ ^[0-9a-f]{64}$'\t'[a-z][a-z0-9_]*$'\t'[a-z][a-z0-9_]*$'\t'([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
    || return 1
  printf '%s\n' "$result"
}

# The generated wrapper invokes this only after it observes a durable phase
# change.  Direct unit callers therefore cannot accidentally manufacture a
# multi-phase identity refresh without the real wrapper loop.
_dispatch_rebind_expected_target_identity() {
  local story_id="$1" applied_commit="${CHORE_JOURNAL_COMMIT:-}"
  local actual source blob record applied_story current_story
  [[ "${CHORE_JOURNAL_OUTCOME:-}" == applied \
      && "$applied_commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
  actual=$(_dispatch_target_identity "$story_id") || return 1
  IFS=$'\t' read -r source blob record <<< "$actual"
  git -C "$PROJECT_DIR" merge-base --is-ancestor "$applied_commit" "$source" \
    2>/dev/null || return 1
  # Concurrent descendant commits may contain another Story's delivery code.
  # Authority remains bound to this Story by comparing both its canonical
  # backlog row and its exact contract blob at B and D below.
  applied_story=$(_dispatch_story_record_at_commit "$story_id" "$applied_commit") \
    || return 1
  current_story=$(_dispatch_story_record_at_commit "$story_id" "$source") \
    || return 1
  [[ "$applied_story" == "$current_story" ]] || return 1
  export GAAI_EXPECTED_TARGET_SOURCE="$source"
  export GAAI_EXPECTED_TARGET_BLOB="$blob"
  export GAAI_EXPECTED_TARGET_RECORD="$record"
}

_plan_expected_target_guard() {
  _dispatch_expected_target_guard "$@"
}

_plan_story_worktree_owned() {
  local story_id="$1" worktree_path="$2"
  local branch="refs/heads/story/${story_id}"
  local worktree_head branch_head
  git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk \
    -v path="$worktree_path" -v branch="$branch" '
      $0 == "worktree " path { matched = 1; next }
      matched && $0 == "branch " branch { found = 1 }
      matched && /^$/ { matched = 0 }
      END { exit(found ? 0 : 1) }
    ' || return 1
  [[ "$(git -C "$worktree_path" symbolic-ref -q HEAD 2>/dev/null)" == "$branch" ]] \
    || return 1
  worktree_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || return 1
  branch_head=$(git -C "$PROJECT_DIR" rev-parse "$branch" 2>/dev/null) || return 1
  [[ "$worktree_head" == "$branch_head" ]]
}

handle_plan_phase() {
  local story_id="$1" trace_id="$2"
  local expected_source="${3:-${GAAI_EXPECTED_TARGET_SOURCE:-}}"
  local expected_blob="${4:-${GAAI_EXPECTED_TARGET_BLOB:-}}"
  local expected_record="${5:-${GAAI_EXPECTED_TARGET_RECORD:-}}"
  local ts t_start_ms t_end_ms duration_ms
  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} phase=plan starting"

  if ! _plan_expected_target_guard "$story_id" "$expected_source" \
      "$expected_blob" "$expected_record"; then
    echo "[ERROR] ${story_id} handle_plan_phase: expected target identity is unavailable or changed" >&2
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "TARGET_IDENTITY_CHANGED" "0"
    return 1
  fi

  # ── Resolve worktree path (GAAI_WORKTREES_BASE override or default formula) ──
  # Aligned with handle_impl_phase + handle_qa_phase canonical formula.
  local worktree_path
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    worktree_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
  else
    local repo_name
    repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    worktree_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${story_id}-workspace"
  fi

  # A prior interrupted attempt may have left a branch or worktree behind.
  # Reuse is allowed only when its HEAD is still the exact launch source; an
  # object from another target cycle must never reach the planning model.
  local _existing_head _qa_replan=false
  [[ "${GAAI_QA_INJECT_PHASE:-}" == plan ]] && _qa_replan=true
  if git -C "$PROJECT_DIR" rev-parse --verify "story/${story_id}" >/dev/null 2>&1; then
    _existing_head=$(git -C "$PROJECT_DIR" rev-parse "story/${story_id}" 2>/dev/null) \
      || return 1
    if [[ "$_qa_replan" == true ]]; then
      if ! _plan_story_worktree_owned "$story_id" "$worktree_path"; then
        echo "[ERROR] ${story_id} handle_plan_phase: replan worktree is not owned by story/${story_id}" >&2
        _emit_plan_routing_record "$story_id" "$trace_id" "error" "TARGET_IDENTITY_CHANGED" "0"
        return 1
      fi
    elif [[ "$_existing_head" != "$expected_source" ]]; then
      echo "[ERROR] ${story_id} handle_plan_phase: existing branch is not bound to expected target" >&2
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "TARGET_IDENTITY_CHANGED" "0"
      return 1
    fi
  fi
  if git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null \
      | grep -Fqx "worktree ${worktree_path}"; then
    _existing_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || return 1
    if [[ "$_qa_replan" == true ]]; then
      if ! _plan_story_worktree_owned "$story_id" "$worktree_path"; then
        echo "[ERROR] ${story_id} handle_plan_phase: replan worktree identity changed" >&2
        _emit_plan_routing_record "$story_id" "$trace_id" "error" "TARGET_IDENTITY_CHANGED" "0"
        return 1
      fi
    elif [[ "$_existing_head" != "$expected_source" ]]; then
      echo "[ERROR] ${story_id} handle_plan_phase: existing worktree is not bound to expected target" >&2
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "TARGET_IDENTITY_CHANGED" "0"
      return 1
    fi
  fi

  # ── Ensure worktree + story branch exist (idempotent) ─────────────────────
  # Plan is the first phase — worktree must be created here before plan agent
  # writes its execution-plan.md inside it. Subsequent phases (impl/qa/commit)
  # reuse the same worktree.
  if ! git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null \
      | grep -Fqx "worktree ${worktree_path}"; then
    # Create the story branch from the freshly-fetched REMOTE tip (origin/<branch>),
    # NOT the local `staging` ref. The local ref is never advanced during a long
    # daemon run (only origin/<branch> is fetched each poll), so branching from it
    # would cut every story from the daemon's startup-era snapshot — stories would
    # silently miss dependencies merged after the daemon started. Branching from
    # origin/<branch> means each new story starts from the latest merged tip.
    # (No checkout — main stays on the daemon-home branch per orchestration.rules.md INVARIANT.)
    local _base_branch="${TARGET_BRANCH:-staging}"
    if ! git -C "$PROJECT_DIR" rev-parse --verify "story/${story_id}" >/dev/null 2>&1; then
      if ! git -C "$PROJECT_DIR" branch "story/${story_id}" "$expected_source" 2>/dev/null; then
        echo "[ERROR] ${story_id} handle_plan_phase: git branch story/${story_id} expected target failed"
        _emit_plan_routing_record "$story_id" "$trace_id" "error" "WORKTREE_BRANCH_FAILED" "0"
        return 1
      fi
    fi
    mkdir -p "$(dirname "$worktree_path")"
    if ! git -C "$PROJECT_DIR" worktree add "$worktree_path" "story/${story_id}" 2>/dev/null; then
      echo "[ERROR] ${story_id} handle_plan_phase: git worktree add failed for $worktree_path"
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "WORKTREE_CREATE_FAILED" "0"
      return 1
    fi
    # This checkout runs inside the generated wrapper, whose restrictive umask
    # materializes the vendored runtime at 0600 by construction. Repair exactly
    # the three vendor files and re-verify the tuple against this worktree's own
    # HEAD tree before anything in it executes.
    if ! _dispatch_repair_worktree_tuple "$story_id" "$worktree_path"; then
      echo "[ERROR] ${story_id} handle_plan_phase: runtime tuple unusable in $worktree_path"
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "WORKTREE_CREATE_FAILED" "0"
      return 1
    fi
  fi

  # ── Ensure worktree node_modules are populated ───────────────────────────
  if ! ensure_wt_dependencies_installed "$story_id" "$trace_id" "$worktree_path"; then
    return 1
  fi

  # ── Inline MCP workspace scope for autonomous spawn ──────────────────────
  # AC5: Refuse spawn if GAAI Cloud configured but workspace_id is missing.
  if _has_gaai_mcp_server && [[ -z "${GAAI_WORKSPACE_ID:-}" ]]; then
    echo "[ERROR] workspace_scope required for autonomous spawn: Story ${story_id} missing workspace_id in backlog. Set GAAI_WORKSPACE_ID or add workspace_id to the story entry." >&2
    _journal_persist_lifecycle "$story_id" dispatch.plan phase_status failed || return 1
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "WORKSPACE_SCOPE_MISSING" "0"
    return 1
  fi
  # Build --mcp-config args (AC1-AC3). No filesystem .mcp.json copy needed (AC2).
  local _plan_oauth _plan_mcp_json _plan_mcp_args=()
  _plan_oauth=$(_extract_mcp_oauth_token "${PROJECT_DIR}/.mcp.json")
  if [[ -n "$_plan_oauth" && -n "${GAAI_WORKSPACE_ID:-}" ]]; then
    _plan_mcp_json=$(_build_daemon_mcp_config "${GAAI_WORKSPACE_ID}" "$_plan_oauth")
    _plan_mcp_args=(--mcp-config "$_plan_mcp_json")
    # AC4: spawn audit log
    echo "[$(date '+%H:%M:%S')] ${story_id} plan-spawn: workspace_id=${GAAI_WORKSPACE_ID} session_mode=autonomous"
  fi
  # Legacy warning: detect worktree .mcp.json with deprecated X-GAAI-WorkspaceBinding header
  if grep -q 'X-GAAI-WorkspaceBinding' "${worktree_path}/.mcp.json" 2>/dev/null; then
    echo "[WARN] ${story_id}: legacy X-GAAI-WorkspaceBinding in worktree .mcp.json — header is deprecated, inline --mcp-config is authoritative (informational)"
  fi

  # ── Resolve artefact paths ────────────────────────────────────────────────
  local story_path plan_path epic_path log_path
  story_path="${worktree_path}/.gaai/project/contexts/artefacts/stories/${story_id}.story.md"
  plan_path="${worktree_path}/.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md"
  log_path="${worktree_path}/.delivery-logs/${story_id}.plan.log"

  # Rotate prior session's log on retry (preserves forensic trail).
  _rotate_phase_log "$log_path"

  # Resolve epic_id from story frontmatter; empty string if missing
  local epic_id
  epic_id=$(grep -m1 '^epic:' "$story_path" 2>/dev/null | sed 's/^epic:[[:space:]]*//' | tr -d '"' || true)
  if [[ -n "$epic_id" ]]; then
    epic_path="${worktree_path}/.gaai/project/contexts/artefacts/epics/${epic_id}.epic.md"
  else
    epic_path=""
  fi

  # Ensure output directories exist
  mkdir -p "$(dirname "$log_path")"
  mkdir -p "$(dirname "$plan_path")"

  # ── Build prompt from planning.daemon-prompt.md (AC1) ─────────────────────
  local prompt_file agent_prompt_src
  agent_prompt_src="${PROJECT_DIR}/.gaai/core/agents/sub-agents/planning.daemon-prompt.md"

  if [[ ! -f "$agent_prompt_src" ]]; then
    echo "[ERROR] ${story_id} handle_plan_phase: planning.daemon-prompt.md not found at $agent_prompt_src"
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "PLAN_PHASE_FAILED" "0"
    return 1
  fi

  prompt_file=$(mktemp "/tmp/gaai-plan-prompt-${story_id}-XXXXXX")
  _expand_daemon_prompt_template "$agent_prompt_src" "$prompt_file" \
    "GAAI_STORY_ID=${story_id}" \
    "GAAI_WORKTREE_PATH=${worktree_path}" \
    "GAAI_STORY_PATH=${story_path}" \
    "GAAI_PLAN_PATH=${plan_path}" \
    "GAAI_EPIC_PATH=${epic_path}"
  # Guard an EMPTY prompt file from a transient /tmp write failure: an empty stdin
  # makes the agent no-op ("I don't see a request") and exit success, which the
  # pipeline mistakes for a wrapper death and burns a delivery retry (3x -> permanent
  # retry cap on a perfectly healthy story). Retry the write, then fail fast+loud.
  local _pf_try=0
  while [[ ! -s "$prompt_file" && $_pf_try -lt 3 ]]; do
    _pf_try=$((_pf_try+1)); sleep 1
    _expand_daemon_prompt_template "$agent_prompt_src" "$prompt_file" \
      "GAAI_STORY_ID=${story_id}" \
      "GAAI_WORKTREE_PATH=${worktree_path}" \
      "GAAI_STORY_PATH=${story_path}" \
      "GAAI_PLAN_PATH=${plan_path}" \
      "GAAI_EPIC_PATH=${epic_path}" 2>/dev/null || true
  done
  if [[ ! -s "$prompt_file" ]]; then
    echo "[ERROR] ${story_id} handle_plan_phase: prompt file empty after retries (transient /tmp write failure?) — refusing to spawn agent with an empty prompt"
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "PLAN_PROMPT_EMPTY" "0"
    rm -f "$prompt_file" 2>/dev/null || true
    return 1
  fi

  # ── Prompt-context tripwire (AC1, AC4) ────────────────────────────────────
  # Must run BEFORE the cross-cycle qa-report append below — the appended
  # content is free-form prior qa-report/plan/impl-report text and could
  # legitimately contain the literal substring "$GAAI_..." (e.g. a prior QA
  # finding quoting this exact defect). The tripwire validates the template
  # substitution, not arbitrary appended narrative.
  if ! _assert_prompt_context_resolved "$prompt_file" "plan" "$story_id" "$trace_id"; then
    rm -f "$prompt_file" 2>/dev/null || true
    return 1
  fi

  # ── Cross-cycle qa-report injection: PLAN route (replan routing contract) ────
  # Appends prior qa-report + prior artefacts + delta-aware marker framing to
  # the PLAN prompt when GAAI_QA_INJECT_PHASE=plan (ESCALATE or FAIL+replan_required=true).
  if [[ "${GAAI_QA_INJECT_PHASE:-}" == "plan" && -n "${GAAI_QA_REPORT_PATH:-}" && -s "${GAAI_QA_REPORT_PATH}" ]]; then
    local _cc_qa_content _cc_qa_bytes _cc_plan_content _cc_plan_bytes _cc_impl_content _cc_impl_bytes
    local _cc_plan_avail=true _cc_impl_avail=true
    _cc_qa_bytes=$(wc -c < "$GAAI_QA_REPORT_PATH" 2>/dev/null || echo 0)
    if (( _cc_qa_bytes > 51200 )); then
      _cc_qa_content="$(head -c 51200 "$GAAI_QA_REPORT_PATH" 2>/dev/null)

(... truncated at 50KB, full content at ${GAAI_QA_REPORT_PATH})"
    else
      _cc_qa_content="$(cat "$GAAI_QA_REPORT_PATH" 2>/dev/null || echo "(not available)")"
    fi

    local _cc_plan_path="${GAAI_WORKTREE_PATH:-${worktree_path}}/.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md"
    if [[ -s "$_cc_plan_path" ]]; then
      _cc_plan_bytes=$(wc -c < "$_cc_plan_path" 2>/dev/null || echo 0)
      if (( _cc_plan_bytes > 51200 )); then
        _cc_plan_content="$(head -c 51200 "$_cc_plan_path" 2>/dev/null)

(... truncated at 50KB, full content at ${_cc_plan_path})"
      else
        _cc_plan_content="$(cat "$_cc_plan_path" 2>/dev/null || echo "(not available)")"
      fi
    else
      local _cc_plan_git
      _cc_plan_git=$(git -C "${GAAI_WORKTREE_PATH:-${worktree_path}}" show "story/${story_id}:.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md" 2>/dev/null || true)
      if [[ -n "$_cc_plan_git" ]]; then
        _cc_plan_content="$_cc_plan_git"
        _cc_plan_bytes=$(printf '%s' "$_cc_plan_git" | wc -c)
      else
        _cc_plan_content="(prior execution-plan not available — produce a fresh plan informed by qa-report only)"
        _cc_plan_bytes=0
        _cc_plan_avail=false
      fi
    fi

    local _cc_impl_path="${GAAI_WORKTREE_PATH:-${worktree_path}}/.gaai/project/contexts/artefacts/impl-reports/${story_id}.impl-report.md"
    if [[ -s "$_cc_impl_path" ]]; then
      _cc_impl_bytes=$(wc -c < "$_cc_impl_path" 2>/dev/null || echo 0)
      if (( _cc_impl_bytes > 51200 )); then
        _cc_impl_content="$(head -c 51200 "$_cc_impl_path" 2>/dev/null)

(... truncated at 50KB, full content at ${_cc_impl_path})"
      else
        _cc_impl_content="$(cat "$_cc_impl_path" 2>/dev/null || echo "(not available)")"
      fi
    else
      local _cc_impl_git
      _cc_impl_git=$(git -C "${GAAI_WORKTREE_PATH:-${worktree_path}}" show "story/${story_id}:.gaai/project/contexts/artefacts/impl-reports/${story_id}.impl-report.md" 2>/dev/null || true)
      if [[ -n "$_cc_impl_git" ]]; then
        _cc_impl_content="$_cc_impl_git"
        _cc_impl_bytes=$(printf '%s' "$_cc_impl_git" | wc -c)
      else
        _cc_impl_content="(prior impl-report not available)"
        _cc_impl_bytes=0
        _cc_impl_avail=false
      fi
    fi

    # Append prior-findings block (best-effort — non-fatal on write failure).
    # Use printf '%s' to avoid shell interpolation of qa-report content containing $var.
    if {
      printf '\n## Prior cycle QA findings\n\n%s\n' "$_cc_qa_content"
      printf '\n## Prior execution-plan\n\n%s\n' "$_cc_plan_content"
      printf '\n## Prior impl-report\n\n%s\n' "$_cc_impl_content"
      printf '%s\n' '
## Delta-aware planning instruction

You are re-planning after a prior cycle that partially implemented this story.
The qa-report above identifies what failed. Mark each step in your plan with
EXACTLY ONE of the following markers:

  ✓ KEEP    — Prior step implemented correctly and qa-report verified the AC.
               Do NOT touch those files. Assert they are unchanged.
  ↻ REVISE  — Prior step was implemented but the qa-report identified a defect.
               Specify the corrective action in one line.
  + NEW     — Additional step required (gap found during re-plan).
               Implement from scratch.

Justify each marker in one line. Err toward REVISE over KEEP when uncertain.'
    } >> "$prompt_file" 2>/dev/null; then
      local _cc_plan_log="${_cc_plan_bytes}B" _cc_impl_log="${_cc_impl_bytes}B"
      [[ "$_cc_plan_avail" == "false" ]] && _cc_plan_log="missing"
      [[ "$_cc_impl_avail" == "false" ]] && _cc_impl_log="missing"
      echo "[CROSS-CYCLE-QA-PLAN-APPEND] ${story_id}: delta-block appended (qa=${_cc_qa_bytes}B plan=${_cc_plan_log} impl=${_cc_impl_log})"
    else
      echo "[WARN] [CROSS-CYCLE-QA-PLAN-APPEND] ${story_id}: append failed — proceeding without prior-findings block"
    fi
  fi

  # Provenance lands in this story's artefact tree so it is committed with the
  # work it describes, not in daemon state that is reaped with the worktree.
  declare -f gaai_routing_bind_worktree >/dev/null 2>&1 && gaai_routing_bind_worktree "$worktree_path"

  # ── Route PLAN_PRODUCER ───────────────────────────────────────────────────
  # GAAI_PLAN_MODEL stays an operator pin and wins outright. Otherwise the
  # router picks from the role's ordered candidates. PLAN_PRODUCER evaluates
  # nothing, so a blocked route here can only be an availability problem —
  # degrade to the legacy default rather than stall the pipeline. Evaluation
  # roles do the opposite and fail closed (see handle_qa_phase).
  local _plan_model="${GAAI_PLAN_MODEL:-}"
  local _plan_model_id="" _plan_harness="" _plan_effort_args="" _plan_codex_model=""
  # When this phase will be handed an MCP server config, the routed harness has
  # to be able to carry it — otherwise routing would quietly cost the agent its
  # tools. Expressed as a required feature, resolved from the registry.
  local _route_req=()
  if [[ ${#_plan_mcp_args[@]} -gt 0 ]]; then _route_req=(--require-feature mcp); fi
  if [[ -z "$_plan_model" ]] && declare -f gaai_route_select >/dev/null 2>&1; then
    if gaai_route_select PLAN_PRODUCER "$story_id" ${_route_req[@]+"${_route_req[@]}"}; then
      _plan_model="$GAAI_ROUTE_MODEL"
      _plan_model_id="$GAAI_ROUTE_MODEL_ID"
      _plan_harness="$GAAI_ROUTE_HARNESS"
      _plan_effort_args="$GAAI_ROUTE_EFFORT_ARGS"
      [[ "$_plan_harness" == "codex" ]] && _plan_codex_model="$GAAI_ROUTE_MODEL"
      gaai_route_export_effort
      echo "[ROUTING] ${story_id} plan role=PLAN_PRODUCER model=${_plan_model_id} (${_plan_model}) harness=${_plan_harness} effort=${GAAI_ROUTE_EFFORT}"
    else
      echo "[WARN] ${story_id} plan: PLAN_PRODUCER not routed (${GAAI_ROUTE_STATUS:-unknown}: ${GAAI_ROUTE_REASON:-}) — falling back to the legacy default model"
    fi
  fi
  _plan_model="${_plan_model:-sonnet}"

  # Seal the authority record into daemon memory before the agent gets control.
  declare -f gaai_provenance_seal >/dev/null 2>&1 && gaai_provenance_seal "$story_id"

  # ── Spawn claude -p (AC1) ─────────────────────────────────────────────────
  # Duration measurement (AC4) — bash 5+ EPOCHREALTIME (microseconds); fallback date +%s
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_start_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_start_ms=$(( $(date +%s) * 1000 ))
  fi

  local claude_exit
  GAAI_STORY_ID="$story_id" \
  GAAI_WORKTREE_PATH="$worktree_path" \
  GAAI_STORY_PATH="$story_path" \
  GAAI_PLAN_PATH="$plan_path" \
  GAAI_EPIC_PATH="$epic_path" \
  GAAI_DELIVERY_LOG_FILE="$log_path" \
  GAAI_WORKSPACE_ID="${GAAI_WORKSPACE_ID:-}" \
  GAAI_ORG_ID="${GAAI_ORG_ID:-}" \
  GAAI_PHASE_HARNESS="$_plan_harness" \
  GAAI_PHASE_EFFORT_ARGS="$_plan_effort_args" \
  GAAI_CODEX_MODEL="${_plan_codex_model:-${GAAI_CODEX_MODEL:-}}" \
    _run_claude_with_loop_breaker \
      "$story_id" "plan" "$log_path" "$prompt_file" "$worktree_path" \
      --model "$_plan_model" \
      --max-turns 60 \
      --output-format stream-json \
      --verbose \
      --dangerously-skip-permissions \
      ${_plan_mcp_args[@]+"${_plan_mcp_args[@]}"}
  claude_exit=$?

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_end_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_end_ms=$(( $(date +%s) * 1000 ))
  fi
  duration_ms=$(( t_end_ms - t_start_ms ))

  rm -f "$prompt_file"

  # ── Validate output (AC4 guard) ───────────────────────────────────────────
  if [[ "$claude_exit" -eq 124 ]]; then
    echo "[ERROR] ${story_id} handle_plan_phase: loop breaker triggered (claude killed after consecutive identical tool errors)"
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "PLAN_PHASE_LOOP_BREAKER" "$duration_ms"
    return 1
  fi
  # A non-zero exit describes the PROCESS, not the work. An agent can write a
  # complete, well-formed plan and then be stopped at the moment it was about to say
  # so — by a turn ceiling, a transport error, a provider hiccup. Deciding on the exit
  # code alone discards that artefact unread, and reports the run to harness
  # autodetect, which can park the executor for every Story over a failure that did
  # not happen.
  #
  # The ladder below already answers the only question that matters: is there a plan,
  # and is it well-formed. Fall through to it when an artefact is present. A run whose
  # artefact does not validate still fails there, still records, and still parks — the
  # checks are unchanged, only the order in which the exit code is allowed to decide.
  #
  # The loop breaker above keeps its own hard failure: an agent killed for repeating
  # identical tool errors has not produced evidence this ladder can trust.
  if [[ "$claude_exit" -ne 0 ]]; then
    if [[ -s "$plan_path" || -s "$(dirname "$plan_path")/${story_id}.plan.md" ]]; then
      echo "[WARN] ${story_id} handle_plan_phase: claude -p exited ${claude_exit} with a plan artefact present — validating the artefact instead of failing on the exit code"
    else
      echo "[ERROR] ${story_id} handle_plan_phase: claude -p exited $claude_exit"
      if declare -f gaai_harness_autodetect >/dev/null 2>&1; then
        gaai_harness_autodetect "${_plan_harness:-${GAAI_DAEMON_EXECUTOR:-claude}}" "$log_path" || true
      fi
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "PLAN_PHASE_FAILED" "$duration_ms"
      return 1
    fi
  fi

  # ── Filename-variation tolerance (LLM compliance defense) ────────────────
  # The Plan agent prompt instructs the agent to write to $GAAI_PLAN_PATH
  # (= ${story_id}.execution-plan.md). If the agent writes to a sibling
  # filename instead (most commonly ${story_id}.plan.md), the file IS valid
  # but the canonical path is missing. Auto-rename rather than fail — this
  # converts a probabilistic LLM-compliance failure into a deterministic
  # rename op + warning.
  if [[ ! -s "$plan_path" ]]; then
    local _plan_dir _alt_plan
    _plan_dir=$(dirname "$plan_path")
    _alt_plan="${_plan_dir}/${story_id}.plan.md"
    if [[ -s "$_alt_plan" ]]; then
      echo "[WARN] ${story_id} handle_plan_phase: plan written to ${_alt_plan} instead of canonical ${plan_path} — auto-renaming"
      mv "$_alt_plan" "$plan_path" 2>/dev/null || {
        echo "[ERROR] ${story_id} handle_plan_phase: rename ${_alt_plan} → ${plan_path} failed"
        _emit_plan_routing_record "$story_id" "$trace_id" "error" "NO_ARTEFACT" "$duration_ms"
        return 1
      }
    else
      echo "[ERROR] ${story_id} handle_plan_phase: plan file missing or empty at $plan_path"
      _emit_plan_routing_record "$story_id" "$trace_id" "error" "NO_ARTEFACT" "$duration_ms"
      return 1
    fi
  fi

  if ! grep -q '^## ' "$plan_path"; then
    echo "[ERROR] ${story_id} handle_plan_phase: plan file has no '## ' heading"
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "PARSE_ERROR" "$duration_ms"
    return 1
  fi

  # Verify before the daemon's own writes, which legitimately change the file.
  if declare -f gaai_provenance_verify_seal >/dev/null 2>&1 \
     && ! gaai_provenance_verify_seal "$story_id"; then
    echo "[ERROR] ${story_id} handle_plan_phase: the provenance record changed while the agent held control [class=PLAN_PROVENANCE_TAMPERED]"
    echo "[ERROR] ${story_id} the record certifies which model may judge this story; an agent that can edit it can seat itself as its own judge"
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "PLAN_PROVENANCE_TAMPERED" "$duration_ms"
    return 1
  fi

  # ── Provenance: this model materially produced the PLAN ──────────────────
  # Recorded only now, with the artefact on disk. A model that was selected and
  # then died produced nothing, and retiring it from later evaluation roles for
  # free would shrink the eligible pool for no reason.
  if [[ -n "$_plan_model_id" ]] && declare -f gaai_provenance_record >/dev/null 2>&1; then
    gaai_provenance_record "$story_id" PLAN "$_plan_model_id" PLAN_PRODUCER "" "$duration_ms" || true
  elif [[ -n "${GAAI_PLAN_MODEL:-}" ]] && declare -f gaai_routing_enabled >/dev/null 2>&1 && gaai_routing_enabled; then
    # A pinned producer is still the plan's author, and a future PLAN_REVIEWER
    # exclusion can only see authors that were written down.
    _gaai_routing_state_env
    node "$(_gaai_router_bin)" record --story "$story_id" --artifact PLAN \
      --concrete-model "$GAAI_PLAN_MODEL" --role PLAN_PRODUCER --note "operator pin" >/dev/null 2>&1 || true
  fi
  if declare -f gaai_harness_success >/dev/null 2>&1; then
    gaai_harness_success "${_plan_harness:-${GAAI_DAEMON_EXECUTOR:-claude}}"
  fi

  # ── Advance phase_status: not_started → planned (AC4) ────────────────────
  if ! _journal_persist_lifecycle "$story_id" dispatch.plan phase_status planned; then
    echo "[ERROR] ${story_id} handle_plan_phase: durable phase_status=planned failed"
    _emit_plan_routing_record "$story_id" "$trace_id" "error" "SCHEDULER_FAILURE" "$duration_ms"
    return 1
  fi

  # ── Emit success routing record (AC4) ────────────────────────────────────
  _emit_plan_routing_record "$story_id" "$trace_id" "primary" "null" "$duration_ms"

  # ── Post-PLAN env cleanup: unconditional when phase=plan ─────────────────
  if [[ "${GAAI_QA_INJECT_PHASE:-}" == "plan" ]]; then
    unset GAAI_QA_INJECT_PHASE GAAI_QA_REPORT_PATH 2>/dev/null || true
    echo "[CROSS-CYCLE-QA-UNSET] ${story_id}: phase=plan complete — env cleared before IMPL spawn"
  fi

  # ── Worktree-scope audit (advisory) ──────────────────────────────────────
  _run_worktree_audit "$story_id" "plan" "$log_path" "$worktree_path"

  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} phase=plan DONE (${duration_ms}ms)"
  return 0
}

handle_impl_phase() {
  local story_id="$1" trace_id="$2"
  local ts
  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} phase=impl starting"

  # ── Resolve worktree path (GAAI_WORKTREES_BASE override or default formula) ──
  local worktree_path
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    worktree_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
  else
    local repo_name
    repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    worktree_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${story_id}-workspace"
  fi

  # ── Inline MCP workspace scope for autonomous spawn ──────────────────────
  if _has_gaai_mcp_server && [[ -z "${GAAI_WORKSPACE_ID:-}" ]]; then
    echo "[ERROR] workspace_scope required for autonomous spawn: Story ${story_id} missing workspace_id in backlog. Set GAAI_WORKSPACE_ID or add workspace_id to the story entry." >&2
    _journal_persist_lifecycle "$story_id" dispatch.impl phase_status failed || return 1
    return 1
  fi
  local _impl_oauth _impl_mcp_json _impl_mcp_extra=()
  _impl_oauth=$(_extract_mcp_oauth_token "${PROJECT_DIR}/.mcp.json")
  if [[ -n "$_impl_oauth" && -n "${GAAI_WORKSPACE_ID:-}" ]]; then
    _impl_mcp_json=$(_build_daemon_mcp_config "${GAAI_WORKSPACE_ID}" "$_impl_oauth")
    _impl_mcp_extra=(--extra-arg --mcp-config --extra-arg "$_impl_mcp_json")
    # AC4: spawn audit log
    echo "[$(date '+%H:%M:%S')] ${story_id} impl-spawn: workspace_id=${GAAI_WORKSPACE_ID} session_mode=autonomous"
  fi
  if grep -q 'X-GAAI-WorkspaceBinding' "${worktree_path}/.mcp.json" 2>/dev/null; then
    echo "[WARN] ${story_id}: legacy X-GAAI-WorkspaceBinding in worktree .mcp.json — header is deprecated, inline --mcp-config is authoritative (informational)"
  fi

  # ── Resolve artefact paths ────────────────────────────────────────────────
  local story_path plan_path impl_report_path log_path
  story_path="${worktree_path}/.gaai/project/contexts/artefacts/stories/${story_id}.story.md"
  plan_path="${worktree_path}/.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md"
  impl_report_path="${worktree_path}/.gaai/project/contexts/artefacts/impl-reports/${story_id}.impl-report.md"
  log_path="${worktree_path}/.delivery-logs/${story_id}.impl.log"

  # Rotate prior session's log on retry (preserves forensic trail).
  _rotate_phase_log "$log_path"

  # ── Validate required files ───────────────────────────────────────────────
  if [[ ! -f "$story_path" ]]; then
    echo "[ERROR] ${story_id} handle_impl_phase: story file not found: $story_path"
    return 1
  fi
  if [[ ! -f "$plan_path" ]]; then
    echo "[ERROR] ${story_id} handle_impl_phase: plan file not found: $plan_path"
    return 1
  fi

  # ── Build impl prompt via daemon-prompt-construct.sh ─────────────────────
  local prompt_construct_script
  prompt_construct_script="${PROJECT_DIR}/.gaai/core/scripts/daemon-prompt-construct.sh"
  if [[ ! -f "$prompt_construct_script" ]]; then
    echo "[ERROR] ${story_id} handle_impl_phase: daemon-prompt-construct.sh not found"
    return 1
  fi

  local epic_id epic_path
  epic_id=$(grep -m1 '^epic:' "$story_path" 2>/dev/null | sed 's/^epic:[[:space:]]*//' | tr -d '"' || true)
  if [[ -n "$epic_id" ]]; then
    epic_path="${worktree_path}/.gaai/project/contexts/artefacts/epics/${epic_id}.epic.md"
  else
    epic_path=""
  fi

  # ── Get impl_model_tag from backlog (needed BEFORE prompt construction
  #    so SECONDARY_ROUTE can be pre-computed and the R1-R6 context
  #    discipline preamble injected when the secondary path will be taken) ─
  local impl_tag
  impl_tag=$(get_impl_model_tag "$story_id")

  # ── Resolve tier once — feeds both the tier-aware default-route coercion
  #    below AND the GAAI_STORY_TIER export to daemon-prompt-construct.sh,
  #    so the notes.md context-recovery discipline can key on tier
  #    regardless of which route the coercion below ends up selecting.
  local _tier
  _tier=$(get_story_tier "$story_id")

  # ── DEC-94 — Tier-aware default impl_model coercion ───────────────────────
  # When impl_model is absent (no story-level opt-in/out), default routing
  # is secondary (per DEC-93 reversal commit 38e6b3f5) for cost optimization.
  # BUT Tier 2 stories on secondary structurally die at 167K compact threshold
  # (cumulative input grows past 0.83 × GLM 200K window in ~16 events).
  # Doctrine PAT-STORY-SCOPE-DISCIPLINE-001 + empirical evidence (E135S02
  # 2026-05-06 cascade-to-Sonnet at event 51 after 3 compacts).
  #
  # Tier-aware default : tier ≥ 2 + absent tag → coerce to primary. Operators
  # who explicitly opt-in `impl_model: secondary` for a Tier 2 story still
  # hit the hard-gate (commit 443d5ad1) — that's intentional, forces them
  # to either decompose to Tier 1 or switch to primary.
  if [[ "$impl_tag" == "absent" ]]; then
    if [[ "$_tier" =~ ^[0-9]+$ ]] && (( _tier >= 2 )); then
      impl_tag="primary"
      echo "[INFO] ${story_id} handle_impl_phase: tier ${_tier} + absent tag → coerced to primary (DEC-94)"
    fi
  fi

  # ── Pre-compute SECONDARY_ROUTE — parity with nested-claude-spawn.js
  #    resolveMode(). Must be done BEFORE the prompt is built. Without this,
  #    secondary-route spawns (e.g. GLM) start without the R1-R6 notes-file
  #    discipline and routinely hit rapid_refill_breaker (Claude Code's
  #    internal safety brake on ≥3 consecutive autocompactions) before they
  #    can converge on writing impl-report.md.
  local _impl_route="primary"
  if [[ "$impl_tag" != "primary" ]]; then
    if [[ -n "${GAAI_IMPL_BASE_URL:-}" \
       && -n "${GAAI_IMPL_AUTH_TOKEN:-}" \
       && -n "${GAAI_IMPL_MODEL:-}" ]]; then
      _impl_route="secondary"
    fi
  fi
  local _secondary_route_flag="false"
  [[ "$_impl_route" == "secondary" ]] && _secondary_route_flag="true"

  declare -f gaai_routing_bind_worktree >/dev/null 2>&1 && gaai_routing_bind_worktree "$worktree_path"

  # ── Route IMPL ────────────────────────────────────────────────────────────
  # The secondary provider route is an explicit per-story operator opt-in with
  # its own governed env contract; routing does not second-guess it. On the
  # primary route the router picks the implementer from the IMPL candidates.
  # IMPL evaluates nothing, so a blocked route degrades to legacy behaviour
  # rather than stalling.
  local _impl_model_id="" _impl_harness="" _impl_effort_args="" _impl_codex_model="" _impl_primary_model=""
  local _impl_effort_extra=()
  # When this phase will be handed an MCP server config, the routed harness has
  # to be able to carry it — otherwise routing would quietly cost the agent its
  # tools. Expressed as a required feature, resolved from the registry.
  local _route_req=()
  if [[ ${#_impl_mcp_extra[@]} -gt 0 ]]; then _route_req=(--require-feature mcp); fi
  if [[ "$_impl_route" != "secondary" ]] && declare -f gaai_route_select >/dev/null 2>&1; then
    if gaai_route_select IMPL "$story_id" ${_route_req[@]+"${_route_req[@]}"}; then
      _impl_model_id="$GAAI_ROUTE_MODEL_ID"
      _impl_harness="$GAAI_ROUTE_HARNESS"
      _impl_effort_args="$GAAI_ROUTE_EFFORT_ARGS"
      _impl_primary_model="$GAAI_ROUTE_MODEL"
      [[ "$_impl_harness" == "codex" ]] && _impl_codex_model="$GAAI_ROUTE_MODEL"
      # nested-claude-spawn takes repeated --extra-arg pairs, not a raw argv
      # string, so the effort expression is rewritten into that shape.
      if [[ "$_impl_harness" != "codex" && -n "$GAAI_ROUTE_EFFORT_ARGS" ]]; then
        local _ea
        # shellcheck disable=SC2086
        for _ea in ${GAAI_ROUTE_EFFORT_ARGS}; do _impl_effort_extra+=(--extra-arg "$_ea"); done
      fi
      gaai_route_export_effort
      echo "[ROUTING] ${story_id} impl role=IMPL model=${_impl_model_id} (${_impl_primary_model}) harness=${_impl_harness} effort=${GAAI_ROUTE_EFFORT}"
    else
      echo "[WARN] ${story_id} impl: IMPL not routed (${GAAI_ROUTE_STATUS:-unknown}: ${GAAI_ROUTE_REASON:-}) — falling back to the legacy default model"
    fi
  fi

  # ── HARD GATE — Tier 2 stories MUST NOT run on secondary route ─────────────
  # Per PAT-STORY-SCOPE-DISCIPLINE-001 + empirical evidence (E135S02 2026-05-06
  # — Tier 2 secondary triggered 3 compacts in 47 events then cascaded to
  # in-process Sonnet fallback, masking the real failure as "fb=-" in routing
  # log). Tier 2 stories cumulative input crosses 167K threshold (= 0.83 ×
  # GLM 200K window) within ~16 events, regardless of R1-R7 directive
  # compliance. The fix is upstream story scope (decompose to Tier 1) or
  # opt-out to primary explicitly. Daemon refuses the dispatch with a clear
  # error so the operator sees the structural mismatch immediately.
  # ── Tier 2 + secondary hard-gate REMOVED ─────────────────────────────────
  # Previously this block refused dispatch for Tier 2 stories on the secondary
  # route, raising TIER2_SECONDARY_REJECTED. Empirically this defensive gate
  # produced more harm than benefit in practice :
  #   - Multiple ghost-state stuck stories in backlog (status=in_progress with
  #     no active markers + no tmux + no lock files) when wrappers exited via
  #     this branch on transient parser/config issues.
  #   - Cascading mis-attribution of failures that were actually parser bugs
  #     (YAML inline-comment leak in get_impl_model_tag — fixed separately).
  #   - Operator friction : forced to chase down each rejection even when the
  #     story was correctly authored.
  # The authoring-layer doctrine ("primary always pre-PMF unless explicit
  # secondary opt-in") plus the tier-aware default coercion (Tier 2+ absent →
  # primary) are sufficient at story-creation time. If a Tier 2 story is
  # explicitly opted in to secondary by an operator, that's a deliberate
  # choice — let it run, observe the outcome, learn from data. Removing the
  # gate trades probabilistic cost exposure for deterministic governability.

  local prompt_content
  if ! prompt_content=$(
    GAAI_STORY_ID="$story_id" \
    GAAI_STORY_PATH="$story_path" \
    GAAI_PLAN_PATH="$plan_path" \
    GAAI_EPIC_PATH="${epic_path:-}" \
    GAAI_WORKSPACE_PATH="$worktree_path" \
    SECONDARY_ROUTE="$_secondary_route_flag" \
    GAAI_STORY_TIER="$_tier" \
    PROJECT_DIR="$PROJECT_DIR" \
    bash "$prompt_construct_script" 2>/dev/null
  ); then
    echo "[ERROR] ${story_id} handle_impl_phase: daemon-prompt-construct.sh failed"
    return 1
  fi

  # ── Ensure output dirs exist ──────────────────────────────────────────────
  mkdir -p "$(dirname "$impl_report_path")"
  mkdir -p "$(dirname "$log_path")"

  # ── Write prompt to temp file ─────────────────────────────────────────────
  local prompt_file
  prompt_file=$(mktemp "/tmp/gaai-impl-prompt-${story_id}-XXXXXX")
  printf '%s' "$prompt_content" > "$prompt_file"
  # Guard an empty prompt file from a transient /tmp write failure (see handle_plan_phase).
  local _pf_try=0
  while [[ ! -s "$prompt_file" && $_pf_try -lt 3 ]]; do
    _pf_try=$((_pf_try+1)); sleep 1
    printf '%s' "$prompt_content" > "$prompt_file" 2>/dev/null || true
  done
  if [[ ! -s "$prompt_file" ]]; then
    echo "[ERROR] ${story_id} handle_impl_phase: prompt file empty after retries (transient /tmp write failure or empty prompt_content?) — refusing to spawn agent with an empty prompt"
    _emit_routing_record "$story_id" "$trace_id" "impl" "error" "IMPL_PROMPT_EMPTY"
    rm -f "$prompt_file" 2>/dev/null || true
    return 1
  fi

  # Seal the authority record into daemon memory before the agent gets control.
  declare -f gaai_provenance_seal >/dev/null 2>&1 && gaai_provenance_seal "$story_id"

  if [[ "${_impl_harness:-${GAAI_DAEMON_EXECUTOR:-claude}}" == "codex" ]]; then
    local codex_exit t_start_ms t_end_ms duration_ms
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
      t_start_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
    else
      t_start_ms=$(( $(date +%s) * 1000 ))
    fi

    GAAI_STORY_ID="$story_id" \
    GAAI_WORKTREE_PATH="$worktree_path" \
    GAAI_STORY_PATH="$story_path" \
    GAAI_PLAN_PATH="$plan_path" \
    GAAI_IMPL_REPORT_PATH="$impl_report_path" \
    GAAI_EPIC_PATH="${epic_path:-}" \
    GAAI_DELIVERY_LOG_FILE="$log_path" \
    GAAI_PHASE_HARNESS="${_impl_harness:-codex}" \
    GAAI_PHASE_EFFORT_ARGS="$_impl_effort_args" \
    GAAI_CODEX_MODEL="${_impl_codex_model:-${GAAI_CODEX_MODEL:-}}" \
      _run_claude_with_loop_breaker \
        "$story_id" "impl" "$log_path" "$prompt_file" "$worktree_path"
    codex_exit=$?

    if [[ -n "${EPOCHREALTIME:-}" ]]; then
      t_end_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
    else
      t_end_ms=$(( $(date +%s) * 1000 ))
    fi
    duration_ms=$(( t_end_ms - t_start_ms ))
    rm -f "$prompt_file"

    if [[ "$codex_exit" -eq 124 ]]; then
      echo "[ERROR] ${story_id} handle_impl_phase: loop breaker triggered (codex killed after consecutive identical tool errors)"
      _emit_routing_record "$story_id" "$trace_id" "impl" "error" "IMPL_LOOP_BREAKER"
      return 1
    fi
    if [[ "$codex_exit" -ne 0 ]]; then
      echo "[ERROR] ${story_id} handle_impl_phase: codex exec exited $codex_exit"
      if declare -f gaai_harness_autodetect >/dev/null 2>&1; then
        gaai_harness_autodetect "${_impl_harness:-codex}" "$log_path" || true
      fi
      _emit_routing_record "$story_id" "$trace_id" "impl" "error" "IMPL_PHASE_FAILED"
      return 1
    fi
    if [[ ! -s "$impl_report_path" ]]; then
      echo "[ERROR] ${story_id} handle_impl_phase: impl-report.md missing or empty at $impl_report_path"
      _emit_routing_record "$story_id" "$trace_id" "impl" "error" "NO_ARTEFACT"
      return 1
    fi
    # Record the author BEFORE advancing the phase. Advancing first leaves a
    # window where a crash yields a PLAN-only ledger: recovery then enters QA,
    # the implementer looks like a non-contributor, and the independence gate
    # clears the very model that wrote the diff. A failure to record is fatal
    # for the same reason — an unrecorded author is an invisible one.
    if declare -f gaai_provenance_verify_seal >/dev/null 2>&1 \
       && ! gaai_provenance_verify_seal "$story_id"; then
      echo "[ERROR] ${story_id} handle_impl_phase: the provenance record changed while the agent held control [class=IMPL_PROVENANCE_TAMPERED]"
      _emit_routing_record "$story_id" "$trace_id" "impl" "error" "IMPL_PROVENANCE_TAMPERED"
      return 1
    fi
    if [[ -n "$_impl_model_id" ]] && declare -f gaai_provenance_record >/dev/null 2>&1; then
      if ! gaai_provenance_record "$story_id" CODE "$_impl_model_id" IMPL "" "${duration_ms:-0}"; then
        echo "[ERROR] ${story_id} handle_impl_phase: could not record the CODE author [class=PROVENANCE_WRITE_FAILED]"
        _emit_routing_record "$story_id" "$trace_id" "impl" "error" "PROVENANCE_WRITE_FAILED"
        return 1
      fi
    fi

    if ! _journal_persist_lifecycle "$story_id" dispatch.impl phase_status implemented; then
      echo "[ERROR] ${story_id} handle_impl_phase: durable phase_status=implemented failed"
      _emit_routing_record "$story_id" "$trace_id" "impl" "error" "SCHEDULER_FAILURE"
      return 1
    fi
    if declare -f gaai_harness_success >/dev/null 2>&1; then
      gaai_harness_success "${_impl_harness:-codex}"
    fi
    _emit_routing_record "$story_id" "$trace_id" "impl" "codex" "null"
    _run_worktree_audit "$story_id" "impl" "$log_path" "$worktree_path"
    ts=$(date '+%H:%M:%S')
    echo "[${ts}] ${story_id} phase=impl DONE"
    return 0
  fi

  # ── Invoke nested-claude-spawn.js flag-CLI (AC1 — always exits 0) ────────
  local spawn_script
  spawn_script="${PROJECT_DIR}/.gaai/core/adapters/claude-code/nested-claude-spawn.js"

  # Wall-clock timeout (OSS-7): bound impl phase to GAAI_TIMEOUT_IMPL_SEC so a
  # silent hang in the node spawner doesn't pin a wrapper indefinitely. Use the
  # `timeout` binary when available; otherwise rely on internal backoff.
  local _impl_to_cmd
  _impl_to_cmd=$(_resolve_timeout_cmd)
  local _impl_to_prefix=()
  if [[ -n "$_impl_to_cmd" ]]; then
    _impl_to_prefix=("$_impl_to_cmd" "--kill-after=15s" "${GAAI_TIMEOUT_IMPL_SEC}s")
  fi

  local spawn_output spawn_rc
  spawn_output=$(
    GAAI_STORY_ID="$story_id" \
    GAAI_WORKTREE_PATH="$worktree_path" \
    GAAI_EPIC_PATH="${epic_path:-}" \
    GAAI_WORKSPACE_ID="${GAAI_WORKSPACE_ID:-}" \
    GAAI_ORG_ID="${GAAI_ORG_ID:-}" \
    GAAI_IMPL_PRIMARY_MODEL="${_impl_primary_model:-${GAAI_IMPL_PRIMARY_MODEL:-}}" \
      ${_impl_to_prefix[@]+"${_impl_to_prefix[@]}"} node "$spawn_script" \
        --story-id       "$story_id" \
        --report-path    "$impl_report_path" \
        --prompt-file    "$prompt_file" \
        --impl-model-tag "$impl_tag" \
        --log-file       "$log_path" \
        --worktree-path  "$worktree_path" \
        ${_impl_mcp_extra[@]+"${_impl_mcp_extra[@]}"} \
        ${_impl_effort_extra[@]+"${_impl_effort_extra[@]}"} \
        2>>"$log_path"
  )
  spawn_rc=$?
  if [[ "$spawn_rc" == "124" || "$spawn_rc" == "137" ]]; then
    echo "[TIMEOUT] ${story_id} handle_impl_phase: nested-claude-spawn wall-clock timeout after ${GAAI_TIMEOUT_IMPL_SEC}s"
    printf '{"type":"system","subtype":"phase_timeout","story_id":"%s","phase":"impl","timeout_sec":%d,"timestamp":"%s"}\n' \
      "$story_id" "$GAAI_TIMEOUT_IMPL_SEC" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log_path" 2>/dev/null || true
    rm -f "$prompt_file"
    return 1
  fi

  rm -f "$prompt_file"

  # ── Parse JSON result — nested-claude-spawn.js emits log lines then multi-line JSON ──
  local parsed_json
  parsed_json=$(printf '%s\n' "$spawn_output" | python3 -c "
import sys, json
data = sys.stdin.read()
d = None
# Primary: find last JSON block starting on its own line (JSON.stringify output)
idx = data.rfind('\n{')
if idx >= 0:
    try: d = json.loads(data[idx + 1:])
    except Exception: pass
# Fallback: single-line JSON (legacy compact format)
if d is None:
    for l in reversed(data.splitlines()):
        l = l.strip()
        if not l: continue
        try: d = json.loads(l); break
        except Exception: continue
if d is not None:
    print(str(d.get('success', False)) + '|' + str(d.get('error_reason') or 'null') + '|' + str(d.get('duration_ms') or 0))
" 2>/dev/null || echo "False|PARSE_ERROR|0")

  local result_success="${parsed_json%%|*}"
  local _rest="${parsed_json#*|}"
  local result_error="${_rest%%|*}"
  # Duration is only known to the spawner; without it, per-seat cost on this
  # route would be permanently unrecorded.
  local result_duration_ms="${_rest#*|}"
  [[ "$result_duration_ms" =~ ^[0-9]+$ ]] || result_duration_ms=0

  # ── JSON-driven outcome dispatch (AC4 — daemon does NOT duplicate-emit routing record) ──
  if [[ "$result_success" == "True" ]] && [[ -s "$impl_report_path" ]]; then
    if declare -f gaai_provenance_verify_seal >/dev/null 2>&1 \
       && ! gaai_provenance_verify_seal "$story_id"; then
      echo "[ERROR] ${story_id} handle_impl_phase: the provenance record changed while the agent held control [class=IMPL_PROVENANCE_TAMPERED]"
      _emit_routing_record "$story_id" "$trace_id" "impl" "error" "IMPL_PROVENANCE_TAMPERED"
      return 1
    fi
    # ── Provenance: this model wrote the code ───────────────────────────────
    # On the secondary route the implementer is not a registry alias, so it is
    # recorded by concrete model. Either way it is now barred from every lane
    # that evaluates the implementation.
    if declare -f gaai_harness_success >/dev/null 2>&1; then
      gaai_harness_success "${_impl_harness:-${GAAI_DAEMON_EXECUTOR:-claude}}"
    fi
    # An unrecorded author is an invisible one: the QA independence gate would
    # then clear the very model that wrote the diff while reporting
    # "excluded=none". Every route records, and a write failure is fatal rather
    # than swallowed — a phase must not claim work whose author it cannot name.
    if declare -f gaai_provenance_record >/dev/null 2>&1; then
      _prov_ok=1
      if [[ -n "$_impl_model_id" ]]; then
        gaai_provenance_record "$story_id" CODE "$_impl_model_id" IMPL "" "$result_duration_ms" || _prov_ok=0
      elif [[ -z "$_impl_model_id" && "$_impl_route" != "secondary" ]] && declare -f gaai_routing_enabled >/dev/null 2>&1 && gaai_routing_enabled; then
        # Routing was off or blocked, so the legacy default wrote this code. It
        # is still an author, and an unrecorded author is invisible to the QA
        # independence gate — which would then clear the very model that wrote
        # the diff, while reporting "excluded=none".
        _gaai_routing_state_env
        node "$(_gaai_router_bin)" record --story "$story_id" --artifact CODE \
          --concrete-model "${_impl_primary_model:-${GAAI_IMPL_PRIMARY_MODEL:-sonnet}}" \
          --role IMPL --note "unrouted legacy default" >/dev/null 2>&1 || _prov_ok=0
      elif [[ "$_impl_route" == "secondary" && -n "${GAAI_IMPL_MODEL:-}" ]] && declare -f gaai_routing_enabled >/dev/null 2>&1 && gaai_routing_enabled; then
        _gaai_routing_state_env
        node "$(_gaai_router_bin)" record --story "$story_id" --artifact CODE \
          --concrete-model "$GAAI_IMPL_MODEL" --role IMPL --note "secondary route" >/dev/null 2>&1 || _prov_ok=0
      fi
      if [[ "$_prov_ok" != "1" ]]; then
        echo "[ERROR] ${story_id} handle_impl_phase: could not record the CODE author [class=PROVENANCE_WRITE_FAILED]"
        return 1
      fi
    fi
    if ! _journal_persist_lifecycle "$story_id" dispatch.impl phase_status implemented; then
      echo "[ERROR] ${story_id} handle_impl_phase: durable phase_status=implemented failed"
      return 1
    fi
    # Worktree-scope audit (advisory)
    _run_worktree_audit "$story_id" "impl" "$log_path" "$worktree_path"
    ts=$(date '+%H:%M:%S')
    echo "[${ts}] ${story_id} phase=impl DONE"
    return 0
  else
    if [[ "$result_success" != "True" ]]; then
      echo "[ERROR] ${story_id} handle_impl_phase: impl failed: ${result_error}"
      if declare -f gaai_harness_autodetect >/dev/null 2>&1; then
        gaai_harness_autodetect "${_impl_harness:-claude}" "$log_path" || true
      fi
    else
      echo "[ERROR] ${story_id} handle_impl_phase: impl-report.md missing or empty at $impl_report_path"
    fi
    return 1
  fi
}

# ── Expected-surface derivation (DEC-200 AC2 evidence-authority) ──────────
# Materializes the exact surface set QA's changed_surface_inventory must equal
# one-to-one: the union of the Story's "## File Inventory" backtick-quoted
# paths, the execution-plan's "## Implementation Sequence" Files-column
# backtick-quoted paths, and the actual `git diff --name-only` against
# base_ref. Writes a JSON array to $5.
_derive_qa_expected_surfaces() {
  local story_path="$1" plan_path="$2" worktree_path="$3" base_ref="$4" out_path="$5"
  local tmp
  tmp=$(mktemp)

  # Story "## File Inventory": only the leading backtick token of each `- `
  # bullet (the path) is a surface — description prose after the em-dash is
  # never scanned, so a stray backticked example there can't be mistaken for
  # a changed file.
  awk '/^## File Inventory/{f=1;next} /^## /{f=0} f' "$story_path" 2>/dev/null \
    | grep -E '^- `' 2>/dev/null \
    | sed -E 's/^- `([^`]*)`.*/\1/' \
    | grep -E '/' >> "$tmp" || true

  # PLAN "## Implementation Sequence": only the table's "Files" column is a
  # surface source. Escaped pipes (`\|`, used inside cell prose to render a
  # literal "|") are protected before column-splitting so they don't shift
  # column indices, then restored. The Action/Checkpoint columns routinely
  # contain inline shell/CLI examples with backticked, slash-bearing paths
  # that are NOT changed surfaces — scanning the whole row/section (the prior
  # behavior) pulled those in as false surfaces.
  awk '
    /^## Implementation Sequence/ { f=1; next }
    /^## / { f=0 }
    f && /^\|/ {
      line = $0
      gsub(/\\\|/, "@@PIPE@@", line)
      n = split(line, cell, "|")
      if (!header_seen) {
        header_seen = 1
        for (i = 1; i <= n; i++) {
          h = cell[i]; gsub(/^[ \t]+|[ \t]+$/, "", h)
          if (h == "Files") files_col = i
        }
        next
      }
      is_sep = 1
      for (i = 1; i <= n; i++) {
        c = cell[i]; gsub(/^[ \t]+|[ \t]+$/, "", c)
        if (c != "" && c !~ /^[-:]+$/) is_sep = 0
      }
      if (is_sep) next
      if (files_col && files_col <= n) {
        c = cell[files_col]
        gsub(/@@PIPE@@/, "\\|", c)
        print c
      }
    }
  ' "$plan_path" 2>/dev/null \
    | grep -oE '`[^`]+`' 2>/dev/null | tr -d '`' | grep -E '/' >> "$tmp" || true

  git -C "$worktree_path" diff --name-only "${base_ref}...HEAD" 2>/dev/null >> "$tmp" || true

  sort -u "$tmp" | grep -v '^[[:space:]]*$' | node -e '
    const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean);
    process.stdout.write(JSON.stringify(lines));
  ' > "$out_path" 2>/dev/null || printf '[]' > "$out_path"
  rm -f "$tmp"
}

# ── Shared JSON-handoff resolver (DEC-200 / E1096S02 AC1) ─────────────────
# The ONE place both the live QA handler (handle_qa_phase) and cross-cycle
# recovery (delivery-daemon.sh:_resolve_cross_cycle_qa_report) derive the
# axes/aggregate/route/replan from the validated sidecar. Never invoke
# qa-verdict.mjs directly from a second call site.
# Args: story_id worktree_path base_ref
# Stdout on rc=0 (OK): 4 lines — verdict, remediation_route, replan_required,
#   summary_json (the validator's own sanitized single-line JSON summary).
# Stdout on rc=2 (QA_SIDECAR_ABSENT, DEC-200 D7 currentness case) or rc=1
#   (QA_HANDOFF_INVALID): nothing on stdout; caller distinguishes via $?.
_qa_verdict_resolve() {
  local story_id="$1" worktree_path="$2" base_ref="$3"
  local story_path plan_path qa_verdict_path qa_schema_path qa_verdict_locator expected_surfaces_path
  story_path="${worktree_path}/.gaai/project/contexts/artefacts/stories/${story_id}.story.md"
  plan_path="${worktree_path}/.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md"
  qa_verdict_path="${worktree_path}/.gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-verdict.json"
  qa_schema_path="${PROJECT_DIR}/.gaai/core/schemas/qa-verdict.v1.schema.json"
  qa_verdict_locator="${qa_verdict_path#"${worktree_path}/"}"

  [[ ! -s "$qa_verdict_path" ]] && return 2

  expected_surfaces_path=$(mktemp "/tmp/gaai-qa-resolve-surfaces-${story_id}-XXXXXX")
  _derive_qa_expected_surfaces "$story_path" "$plan_path" "$worktree_path" "$base_ref" "$expected_surfaces_path"

  local out rc
  out=$(node "${PROJECT_DIR}/.gaai/core/scripts/lib/qa-verdict.mjs" validate \
    --sidecar "$qa_verdict_path" --schema "$qa_schema_path" --story-id "$story_id" \
    --expected-surfaces "$expected_surfaces_path" --sidecar-locator "$qa_verdict_locator" 2>&1)
  rc=$?
  rm -f "$expected_surfaces_path" 2>/dev/null || true
  [[ "$rc" -ne 0 ]] && return "$rc"

  local v r p
  v=$(printf '%s' "$out" | grep -oE '"verdict":"[A-Z]+"' | head -1 | cut -d'"' -f4)
  r=$(printf '%s' "$out" | grep -oE '"remediation_route":(null|"[a-z]+")' | head -1 | cut -d: -f2 | tr -d '"')
  p=$(printf '%s' "$out" | grep -oE '"replan_required":(null|true|false)' | head -1 | cut -d: -f2)
  printf '%s\n%s\n%s\n%s\n' "$v" "$r" "$p" "$out"
  return 0
}

handle_qa_phase() {
  local story_id="$1" trace_id="$2"
  local ts t_start_ms t_end_ms duration_ms
  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} phase=qa starting"

  # ── Resolve worktree path ─────────────────────────────────────────────────
  local worktree_path
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    worktree_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
  else
    local repo_name
    repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    worktree_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${story_id}-workspace"
  fi

  # ── Inline MCP workspace scope for autonomous spawn ──────────────────────
  if _has_gaai_mcp_server && [[ -z "${GAAI_WORKSPACE_ID:-}" ]]; then
    echo "[ERROR] workspace_scope required for autonomous spawn: Story ${story_id} missing workspace_id in backlog. Set GAAI_WORKSPACE_ID or add workspace_id to the story entry." >&2
    _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed || return 1
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "WORKSPACE_SCOPE_MISSING" "0"
    return 1
  fi
  local _qa_oauth _qa_mcp_json _qa_mcp_args=()
  _qa_oauth=$(_extract_mcp_oauth_token "${PROJECT_DIR}/.mcp.json")
  if [[ -n "$_qa_oauth" && -n "${GAAI_WORKSPACE_ID:-}" ]]; then
    _qa_mcp_json=$(_build_daemon_mcp_config "${GAAI_WORKSPACE_ID}" "$_qa_oauth")
    _qa_mcp_args=(--mcp-config "$_qa_mcp_json")
    # AC4: spawn audit log
    echo "[$(date '+%H:%M:%S')] ${story_id} qa-spawn: workspace_id=${GAAI_WORKSPACE_ID} session_mode=autonomous"
  fi
  if grep -q 'X-GAAI-WorkspaceBinding' "${worktree_path}/.mcp.json" 2>/dev/null; then
    echo "[WARN] ${story_id}: legacy X-GAAI-WorkspaceBinding in worktree .mcp.json — header is deprecated, inline --mcp-config is authoritative (informational)"
  fi

  # ── Resolve artefact paths (AC2) ──────────────────────────────────────────
  local story_path plan_path impl_report_path qa_report_path memory_delta_path log_path
  local qa_schema_path qa_verdict_path
  story_path="${worktree_path}/.gaai/project/contexts/artefacts/stories/${story_id}.story.md"
  plan_path="${worktree_path}/.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md"
  impl_report_path="${worktree_path}/.gaai/project/contexts/artefacts/impl-reports/${story_id}.impl-report.md"
  qa_report_path="${worktree_path}/.gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-report.md"
  memory_delta_path="${worktree_path}/.gaai/project/contexts/artefacts/memory-deltas/${story_id}.memory-delta.md"
  log_path="${worktree_path}/.delivery-logs/${story_id}.qa.log"
  qa_schema_path="${PROJECT_DIR}/.gaai/core/schemas/qa-verdict.v1.schema.json"
  qa_verdict_path="${worktree_path}/.gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-verdict.json"

  # Rotate prior session's log on retry (preserves forensic trail).
  _rotate_phase_log "$log_path"

  # Resolve epic_id from story frontmatter
  local epic_id epic_path
  epic_id=$(grep -m1 '^epic:' "$story_path" 2>/dev/null | sed 's/^epic:[[:space:]]*//' | tr -d '"' || true)
  if [[ -n "$epic_id" ]]; then
    epic_path="${worktree_path}/.gaai/project/contexts/artefacts/epics/${epic_id}.epic.md"
  else
    epic_path=""
  fi

  # Resolve base ref for git diff (AC2: GAAI_BASE_REF). Falls back to the
  # daemon's TARGET_BRANCH (typically 'staging') when no explicit base ref
  # is provided. Hardcoding 'main' breaks repos that use a non-main
  # integration branch — the QA agent runs `git diff $base_ref...HEAD` and
  # an unknown ref errors out, cancelling parallel tool calls and tripping
  # the loop breaker. `origin/$TARGET_BRANCH` is preferred over the bare
  # branch name because it's immutable while the local branch may not be
  # synced in a fresh worktree.
  local base_ref
  if [[ -n "${GAAI_BASE_REF:-}" ]]; then
    base_ref="$GAAI_BASE_REF"
  elif [[ -n "${TARGET_BRANCH:-}" ]]; then
    base_ref="origin/${TARGET_BRANCH}"
  else
    base_ref="origin/main"
  fi

  # ── Validate required input files ────────────────────────────────────────
  if [[ ! -f "$story_path" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: story file not found: $story_path"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SPAWN_FAILED" "0"
    touch "${LOCK_DIR}/.qa-spawn-death-pending-${story_id}" 2>/dev/null || true
    return 1
  fi
  if [[ ! -f "$plan_path" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: plan file not found: $plan_path"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SPAWN_FAILED" "0"
    touch "${LOCK_DIR}/.qa-spawn-death-pending-${story_id}" 2>/dev/null || true
    return 1
  fi
  if [[ ! -f "$impl_report_path" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: impl-report not found: $impl_report_path"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SPAWN_FAILED" "0"
    touch "${LOCK_DIR}/.qa-spawn-death-pending-${story_id}" 2>/dev/null || true
    return 1
  fi

  # Seal, reconcile and execute the deterministic project gate before any QA
  # model is selected or spawned. A blocked gate has already persisted its
  # implementation/human route and emits no semantic-evaluation spend.
  if ! _prepare_pre_qa_admission "$story_id" "$trace_id" "$worktree_path"; then
    return 0
  fi

  # ── Ensure output directories exist ──────────────────────────────────────
  mkdir -p "$(dirname "$qa_report_path")"
  mkdir -p "$(dirname "$memory_delta_path")"
  mkdir -p "$(dirname "$log_path")"

  # ── Derive expected-surface set (DEC-200 AC2) ─────────────────────────────
  # Needed here (pre-spawn) so the QA agent itself can read
  # GAAI_QA_EXPECTED_SURFACES_PATH below — a separate concern from
  # _qa_verdict_resolve's own internal recomputation of the same set for the
  # post-spawn validation call further down (small, intentional redundancy;
  # not a new cost class per the Risk Register).
  local expected_surfaces_path
  expected_surfaces_path=$(mktemp "/tmp/gaai-qa-expected-surfaces-${story_id}-XXXXXX")
  _derive_qa_expected_surfaces "$story_path" "$plan_path" "$worktree_path" "$base_ref" "$expected_surfaces_path"

  # ── Build prompt from qa.daemon-prompt.md (AC1) ───────────────────────────
  local agent_prompt_src
  agent_prompt_src="${PROJECT_DIR}/.gaai/core/agents/sub-agents/qa.daemon-prompt.md"

  if [[ ! -f "$agent_prompt_src" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: qa.daemon-prompt.md not found at $agent_prompt_src"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SPAWN_FAILED" "0"
    touch "${LOCK_DIR}/.qa-spawn-death-pending-${story_id}" 2>/dev/null || true
    return 1
  fi

  local prompt_file
  prompt_file=$(mktemp "/tmp/gaai-qa-prompt-${story_id}-XXXXXX")
  _expand_daemon_prompt_template "$agent_prompt_src" "$prompt_file" \
    "GAAI_STORY_PATH=${story_path}" \
    "GAAI_PLAN_PATH=${plan_path}" \
    "GAAI_IMPL_REPORT_PATH=${impl_report_path}" \
    "GAAI_QA_REPORT_PATH=${qa_report_path}" \
    "GAAI_QA_SCHEMA_PATH=${qa_schema_path}" \
    "GAAI_QA_VERDICT_PATH=${qa_verdict_path}" \
    "GAAI_QA_EXPECTED_SURFACES_PATH=${expected_surfaces_path}" \
    "GAAI_EPIC_PATH=${epic_path}" \
    "GAAI_BASE_REF=${base_ref}" \
    "GAAI_WORKTREE_PATH=${worktree_path}" \
    "GAAI_MEMORY_DELTA_PATH=${memory_delta_path}"
  # Guard an empty prompt file from a transient /tmp write failure (see handle_plan_phase).
  local _pf_try=0
  while [[ ! -s "$prompt_file" && $_pf_try -lt 3 ]]; do
    _pf_try=$((_pf_try+1)); sleep 1
    _expand_daemon_prompt_template "$agent_prompt_src" "$prompt_file" \
      "GAAI_STORY_PATH=${story_path}" \
      "GAAI_PLAN_PATH=${plan_path}" \
      "GAAI_IMPL_REPORT_PATH=${impl_report_path}" \
      "GAAI_QA_REPORT_PATH=${qa_report_path}" \
      "GAAI_QA_SCHEMA_PATH=${qa_schema_path}" \
      "GAAI_QA_VERDICT_PATH=${qa_verdict_path}" \
      "GAAI_QA_EXPECTED_SURFACES_PATH=${expected_surfaces_path}" \
      "GAAI_EPIC_PATH=${epic_path}" \
      "GAAI_BASE_REF=${base_ref}" \
      "GAAI_WORKTREE_PATH=${worktree_path}" \
      "GAAI_MEMORY_DELTA_PATH=${memory_delta_path}" 2>/dev/null || true
  done
  if [[ ! -s "$prompt_file" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: prompt file empty after retries (transient /tmp write failure?) — refusing to spawn agent with an empty prompt"
    # Parity with the sibling QA_SPAWN_FAILED pre-spawn paths: set the bounded-death
    # marker so a persistent (non-transient) failure escalates via the capped
    # .qa-spawn-deaths counter instead of the unbounded resume-relaunch branch.
    touch "${LOCK_DIR}/.qa-spawn-death-pending-${story_id}" 2>/dev/null || true
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_PROMPT_EMPTY" "0"
    rm -f "$prompt_file" "$expected_surfaces_path" 2>/dev/null || true
    return 1
  fi

  # ── Prompt-context tripwire (AC2, AC4) ────────────────────────────────────
  if ! _assert_prompt_context_resolved "$prompt_file" "qa" "$story_id" "$trace_id"; then
    rm -f "$prompt_file" "$expected_surfaces_path" 2>/dev/null || true
    return 1
  fi

  declare -f gaai_routing_bind_worktree >/dev/null 2>&1 && gaai_routing_bind_worktree "$worktree_path"

  # ── Route the QA evaluator ────────────────────────────────────────────────
  # One QA agent covers all three lanes today: it judges the implementation
  # (state_of_the_art_conformance), the Story ACs, and conformity to the
  # governed PLAN (plan_conformance). It routes as QA_PLAN, the lane whose
  # exclusions cover all three. Per policy the QA model may be the one that
  # produced the PLAN, but never the one that wrote the code. When the lanes are
  # split into separate spawns, each simply asks the router for its own role.
  #
  # This step EVALUATES, so it fails closed. There is no "everything else is
  # busy, let the author grade itself" branch, by construction.
  local _qa_model="${GAAI_QA_MODEL:-}"
  local _qa_model_id="" _qa_harness="" _qa_effort_args="" _qa_codex_model=""
  if [[ -n "$_qa_model" ]]; then
    # A pin selects the evaluator; it does not get to select an author. The one
    # gate that is absolute still applies, and failing it is fatal rather than a
    # warning — an operator who really wants the author in the seat must turn
    # routing off explicitly, which says what it is doing.
    local _pin_checked=0
    if declare -f gaai_pin_is_independent >/dev/null 2>&1; then
      _pin_checked=1
    fi
    if [[ "$_pin_checked" != "1" ]]; then
      # The routing substrate is absent, so this pin cannot be checked. An
      # unverifiable pin is indistinguishable from an unresolvable one, and the
      # gate clears only what it can identify — otherwise "pin the evaluator"
      # plus "remove the library" composes into author-as-judge without ever
      # touching the switch that says so.
      echo "[ERROR] ${story_id} handle_qa_phase: GAAI_QA_MODEL=${_qa_model} pins the evaluator but the routing substrate is absent, so independence cannot be verified [class=QA_PIN_UNVERIFIABLE]"
      echo "[ERROR] ${story_id} restore the routing substrate, drop the pin, or set GAAI_MODEL_ROUTING=0 to forfeit the guarantee explicitly"
      _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_PIN_UNVERIFIABLE" "0"
      rm -f "$prompt_file" "$expected_surfaces_path" 2>/dev/null || true
      _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed || return 1
      return 1
    fi
    if ! gaai_pin_is_independent "$story_id" QA_PLAN "$_qa_model"; then
      echo "[ERROR] ${story_id} handle_qa_phase: GAAI_QA_MODEL=${_qa_model} contributed to this story's implementation — pinning it would let a model grade its own work [class=QA_PIN_NOT_INDEPENDENT]"
      echo "[ERROR] ${story_id} to run QA on a contributor anyway, set GAAI_MODEL_ROUTING=0 — which forfeits the guarantee explicitly instead of quietly"
      _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_PIN_NOT_INDEPENDENT" "0"
      rm -f "$prompt_file" "$expected_surfaces_path" 2>/dev/null || true
      _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed || return 1
      return 1
    fi
    echo "[WARN] ${story_id} qa: GAAI_QA_MODEL=${_qa_model} pins the evaluator; independence verified, candidate ordering skipped"
    # F-3: a pinned step is still a step. Record what ran, by the spelling the
    # operator used, or the record claims a phase nobody executed.
    if declare -f gaai_routing_enabled >/dev/null 2>&1 && gaai_routing_enabled; then
      _gaai_routing_state_env
      node "$(_gaai_router_bin)" record --story "$story_id" --artifact QA \
        --concrete-model "$_qa_model" --role QA_PLAN --note "operator pin" >/dev/null 2>&1 || true
    fi
  elif declare -f gaai_route_select >/dev/null 2>&1; then
    local _route_req=()
    if [[ ${#_qa_mcp_args[@]} -gt 0 ]]; then _route_req=(--require-feature mcp); fi
    if gaai_route_select QA_PLAN "$story_id" ${_route_req[@]+"${_route_req[@]}"}; then
      _qa_model="$GAAI_ROUTE_MODEL"
      _qa_model_id="$GAAI_ROUTE_MODEL_ID"
      _qa_harness="$GAAI_ROUTE_HARNESS"
      _qa_effort_args="$GAAI_ROUTE_EFFORT_ARGS"
      [[ "$_qa_harness" == "codex" ]] && _qa_codex_model="$GAAI_ROUTE_MODEL"
      gaai_route_export_effort
      echo "[ROUTING] ${story_id} qa role=QA_PLAN model=${_qa_model_id} (${_qa_model}) harness=${_qa_harness} effort=${GAAI_ROUTE_EFFORT} excluded=${GAAI_ROUTE_EXCLUDED:-none}"
    elif [[ "${GAAI_ROUTE_STATUS:-}" == "DISABLED" || "${GAAI_ROUTE_STATUS:-}" == "ROUTER_MISSING" ]]; then
      # Routing switched off by the operator, or the substrate is not installed.
      # Neither is the router refusing to seat an evaluator, so the phase runs on
      # its legacy default — without the independence guarantee, and saying so.
      echo "[WARN] ${story_id} qa: model routing unavailable (${GAAI_ROUTE_STATUS}: ${GAAI_ROUTE_REASON:-}) — running QA on the legacy default model WITHOUT the no-self-evaluation guarantee"
    else
      local _qa_block="${GAAI_ROUTE_BLOCKED_CLASS:-}"
      # A router that could not run at all is a config/substrate fault, not a
      # transient one: treat it as structural rather than retrying forever.
      [[ "${GAAI_ROUTE_STATUS:-}" == "ROUTER_ERROR" ]] && _qa_block="CONFIG"
      echo "[ERROR] ${story_id} handle_qa_phase: no eligible QA model [class=QA_NO_ELIGIBLE_MODEL blocked=${_qa_block:-${GAAI_ROUTE_STATUS:-unknown}}] ${GAAI_ROUTE_REASON:-}"
      [[ -n "${GAAI_ROUTE_TRACE:-}" ]] && echo "[ROUTING] ${story_id} qa candidate trace: ${GAAI_ROUTE_TRACE}"
      declare -f gaai_provenance_blocked >/dev/null 2>&1 && gaai_provenance_blocked "$story_id" QA_PLAN
      _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_NO_ELIGIBLE_MODEL" "0"
      rm -f "$prompt_file" "$expected_surfaces_path" 2>/dev/null || true
      case "$_qa_block" in
        PROVENANCE|CAPABILITY_FLOOR|CONFIG)
          # Structural: no amount of waiting produces an independent evaluator.
          # Hand it to a human instead of looping.
          _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed || return 1
          ;;
        *)
          # Availability only (quota/outage). The backoff window expires on its
          # own, so leave the phase where it is and let the next cycle retry.
          ;;
      esac
      return 1
    fi
  fi
  _qa_model="${_qa_model:-sonnet}"

  # ── Duration measurement ──────────────────────────────────────────────────
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_start_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_start_ms=$(( $(date +%s) * 1000 ))
  fi

  # Seal the authority record into daemon memory before the agent gets control.
  declare -f gaai_provenance_seal >/dev/null 2>&1 && gaai_provenance_seal "$story_id"

  # ── Spawn claude -p (AC1 — child bash subshell, NOT nested-claude-spawn.js) ──
  local claude_exit
  GAAI_STORY_ID="$story_id" \
  GAAI_WORKTREE_PATH="$worktree_path" \
  GAAI_STORY_PATH="$story_path" \
  GAAI_PLAN_PATH="$plan_path" \
  GAAI_IMPL_REPORT_PATH="$impl_report_path" \
  GAAI_QA_REPORT_PATH="$qa_report_path" \
  GAAI_QA_SCHEMA_PATH="$qa_schema_path" \
  GAAI_QA_VERDICT_PATH="$qa_verdict_path" \
  GAAI_QA_EXPECTED_SURFACES_PATH="$expected_surfaces_path" \
  GAAI_EPIC_PATH="$epic_path" \
  GAAI_BASE_REF="$base_ref" \
  GAAI_DELIVERY_LOG_FILE="$log_path" \
  GAAI_MEMORY_DELTA_PATH="$memory_delta_path" \
  GAAI_WORKSPACE_ID="${GAAI_WORKSPACE_ID:-}" \
  GAAI_ORG_ID="${GAAI_ORG_ID:-}" \
  GAAI_PHASE_HARNESS="$_qa_harness" \
  GAAI_PHASE_EFFORT_ARGS="$_qa_effort_args" \
  GAAI_CODEX_MODEL="${_qa_codex_model:-${GAAI_CODEX_MODEL:-}}" \
    _run_claude_with_loop_breaker \
      "$story_id" "qa" "$log_path" "$prompt_file" "$worktree_path" \
      --model "$_qa_model" \
      --max-turns "$GAAI_QA_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      --dangerously-skip-permissions \
      ${_qa_mcp_args[@]+"${_qa_mcp_args[@]}"}
  claude_exit=$?

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_end_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_end_ms=$(( $(date +%s) * 1000 ))
  fi
  duration_ms=$(( t_end_ms - t_start_ms ))

  rm -f "$prompt_file"

  # ── AC5(a-loop): loop breaker triggered ───────────────────────────────────
  if [[ "$claude_exit" -eq 124 ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: loop breaker triggered (claude killed after consecutive identical tool errors) [class=QA_LOOP_BREAKER]"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_LOOP_BREAKER" "$duration_ms"
    return 1
  fi
  # ── AC5(a): spawn-error — claude -p exit non-zero ─────────────────────────
  if [[ "$claude_exit" -ne 0 ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: claude -p exited ${claude_exit} [class=QA_SPAWN_FAILED]"
    if declare -f gaai_harness_autodetect >/dev/null 2>&1; then
      gaai_harness_autodetect "${_qa_harness:-${GAAI_DAEMON_EXECUTOR:-claude}}" "$log_path" || true
    fi
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SPAWN_FAILED" "$duration_ms"
    touch "${LOCK_DIR}/.qa-spawn-death-pending-${story_id}" 2>/dev/null || true
    return 1
  fi

  # ── AC5(b): artefact missing despite exit 0 ───────────────────────────────
  if [[ ! -s "$qa_report_path" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: qa-report missing or empty at $qa_report_path [class=QA_NO_ARTEFACT]"
    rm -f "$expected_surfaces_path" 2>/dev/null || true
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_NO_ARTEFACT" "$duration_ms"
    return 1
  fi
  # expected_surfaces_path's job (spawn-time agent context) is done — the
  # resolver below derives its own independent copy for validation.
  rm -f "$expected_surfaces_path" 2>/dev/null || true

  # Verify before the daemon's own writes, which legitimately change the file.
  if declare -f gaai_provenance_verify_seal >/dev/null 2>&1 \
     && ! gaai_provenance_verify_seal "$story_id"; then
    echo "[ERROR] ${story_id} handle_qa_phase: the provenance record changed while the agent held control [class=QA_PROVENANCE_TAMPERED]"
    echo "[ERROR] ${story_id} the record certifies which model may judge this story; an agent that can edit it can seat itself as its own judge"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_PROVENANCE_TAMPERED" "$duration_ms"
    return 1
  fi

  # ── Provenance: this model produced the QA findings ──────────────────────
  if [[ -n "$_qa_model_id" ]] && declare -f gaai_provenance_record >/dev/null 2>&1; then
    gaai_provenance_record "$story_id" QA "$_qa_model_id" QA_PLAN "" "$duration_ms" || true
  fi
  if declare -f gaai_harness_success >/dev/null 2>&1; then
    gaai_harness_success "${_qa_harness:-${GAAI_DAEMON_EXECUTOR:-claude}}"
  fi

  # ── DEC-200 JSON handoff — the shared resolver (_qa_verdict_resolve) is the
  # sole machine authority for the aggregate/route/replan driving routing below
  # (AC1/AC3). This gate runs BEFORE the Markdown verdict parse so an invalid/
  # missing JSON sidecar is caught even when the Markdown report looks like a
  # clean PASS. Markdown remains parsed further down only for the presence and
  # disagreement guard (AC2/AC3) — it never selects the routing branch itself. ──
  local _resolve_out _resolve_rc
  _resolve_out=$(_qa_verdict_resolve "$story_id" "$worktree_path" "$base_ref")
  _resolve_rc=$?
  if [[ "$_resolve_rc" -eq 2 ]]; then
    # Should not normally happen post-spawn (qa-report existence already passed
    # above) unless the agent wrote the Markdown report but not the JSON sidecar
    # — same fail-closed contract as before this Story.
    echo "[ERROR] ${story_id} handle_qa_phase: qa-verdict.json missing or empty at $qa_verdict_path [class=QA_HANDOFF_INVALID] (the JSON handoff did not drive routing this cycle)"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_HANDOFF_INVALID" "$duration_ms"
    if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed; then
      echo "[ERROR] ${story_id} handle_qa_phase: durable failure transition failed after QA_HANDOFF_INVALID"
    fi
    return 1
  elif [[ "$_resolve_rc" -ne 0 ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: qa-verdict.json failed validation [class=QA_HANDOFF_INVALID]: ${_resolve_out}"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_HANDOFF_INVALID" "$duration_ms"
    if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed; then
      echo "[ERROR] ${story_id} handle_qa_phase: durable failure transition failed after QA_HANDOFF_INVALID"
    fi
    return 1
  fi
  local qa_aggregate qa_route qa_replan qa_validator_out
  qa_aggregate=$(printf '%s' "$_resolve_out" | sed -n '1p')
  qa_route=$(printf '%s' "$_resolve_out" | sed -n '2p')
  qa_replan=$(printf '%s' "$_resolve_out" | sed -n '3p')
  qa_validator_out=$(printf '%s' "$_resolve_out" | sed -n '4p')
  echo "[$(date '+%H:%M:%S')] ${story_id} handle_qa_phase: qa-verdict.json valid — ${qa_validator_out}"

  # ── AC4: parse 3-way verdict ──────────────────────────────────────────────
  local verdict
  verdict=$(grep -E '^## Verdict: (PASS|FAIL|ESCALATE)$' "$qa_report_path" | tail -1 | sed 's/^## Verdict: //')

  # ── AC5(c): verdict marker absent / unparseable ───────────────────────────
  if [[ -z "$verdict" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: verdict marker absent in qa-report [class=QA_VERDICT_PARSE_ERROR]"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_VERDICT_PARSE_ERROR" "$duration_ms"
    # NO retry — immediate failed per AC5(c)
    if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed; then
      echo "[ERROR] ${story_id} handle_qa_phase: durable failure transition failed after QA_VERDICT_PARSE_ERROR"
    fi
    return 1
  fi

  # ── DEC-200 Markdown/JSON agreement — a disagreement is QA_HANDOFF_INVALID,
  # never repaired or promoted (AC3). qa_aggregate is the resolver's own
  # cross-checked derived value (never re-parsed from raw JSON here). ───────
  if [[ -n "$qa_aggregate" && "$qa_aggregate" != "$verdict" ]]; then
    echo "[ERROR] ${story_id} handle_qa_phase: Markdown verdict '${verdict}' disagrees with JSON verdict '${qa_aggregate}' [class=QA_HANDOFF_INVALID]"
    _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_HANDOFF_INVALID" "$duration_ms"
    if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status failed; then
      echo "[ERROR] ${story_id} handle_qa_phase: durable failure transition failed after QA_HANDOFF_INVALID (markdown/json disagreement)"
    fi
    return 1
  fi

  # ── AC1/AC3: verdict-driven phase advancement — the JSON-derived aggregate,
  # not the Markdown line, is the sole machine authority selecting the branch.
  # Markdown remains parsed above only for the presence and disagreement guard. ──
  case "$qa_aggregate" in
    PASS)
      # AC5(d): scheduler failure → return 1 without phase advance, daemon retries
      if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status qa_passed; then
        echo "[ERROR] ${story_id} handle_qa_phase: durable phase_status=qa_passed failed [class=QA_SCHEDULER_FAILURE]"
        _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SCHEDULER_FAILURE" "$duration_ms"
        return 1
      fi
      _emit_qa_routing_record "$story_id" "$trace_id" "primary" "null" "$duration_ms" "$qa_validator_out"
      # Worktree-scope audit (advisory)
      _run_worktree_audit "$story_id" "qa" "$log_path" "$worktree_path"
      ts=$(date '+%H:%M:%S')
      # AC5: correlate the DEC-200 summary with the terminal PASS decision itself
      # (not only the earlier generic validation-succeeded line) — story ID,
      # schema version, both axes, aggregate, remediation route, evaluated
      # timestamp, surface/evidence counts, safe locators; no report bodies,
      # credentials or authority URL query values (qa_validator_out is the
      # validator's own sanitized summary, never the raw sidecar/report).
      echo "[${ts}] ${story_id} phase=qa PASS (${duration_ms}ms) — ${qa_validator_out}"
      return 0
      ;;
    FAIL)
      echo "[ERROR] ${story_id} handle_qa_phase: QA verdict=FAIL route=${qa_route} [class=QA_VERDICT:FAIL] — ${qa_validator_out}"
      if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status qa_failed; then
        echo "[ERROR] ${story_id} handle_qa_phase: durable phase_status=qa_failed failed [class=QA_SCHEDULER_FAILURE]"
        _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SCHEDULER_FAILURE" "$duration_ms"
        return 1
      fi
      # DEC-200 D5 / AC3-AC4: persist the resolver's derived root-cause route for
      # dispatch_3phase_story's qa_failed case to consume. remediation_route is
      # closed to plan|impl on a FAIL aggregate; any other/empty value defensively
      # normalizes to impl at the read site (dispatch_3phase_story), matching the
      # pre-cutover IMPL-only behavior as the safe fallback.
      printf '%s\n' "${qa_route:-impl}" > "${LOCK_DIR}/.qa-route-${story_id}.tmp.$$" \
        && mv "${LOCK_DIR}/.qa-route-${story_id}.tmp.$$" "${LOCK_DIR}/.qa-route-${story_id}" \
        || rm -f "${LOCK_DIR}/.qa-route-${story_id}.tmp.$$" 2>/dev/null
      _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_VERDICT:FAIL" "$duration_ms" "$qa_validator_out"
      # Retry-loop convention : phase_status:qa_failed is the failure signal,
      # NOT this function's exit code. Return 0 so the wrapper outer loop
      # iterates and dispatch_3phase_story's qa_failed case (the retry-loop
      # at lines below) fires. Returning 1 here exits the wrapper before the
      # retry-loop can rewind to planned + re-spawn IMPL — making the entire
      # retry-loop unreachable.
      return 0
      ;;
    ESCALATE)
      echo "[ERROR] ${story_id} handle_qa_phase: QA verdict=ESCALATE [class=QA_VERDICT:ESCALATE]"
      if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status qa_escalated; then
        echo "[ERROR] ${story_id} handle_qa_phase: durable phase_status=qa_escalated failed [class=QA_SCHEDULER_FAILURE]"
        _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_SCHEDULER_FAILURE" "$duration_ms"
        return 1
      fi
      _emit_qa_routing_record "$story_id" "$trace_id" "error" "QA_VERDICT:ESCALATE" "$duration_ms" "$qa_validator_out"
      # Surface the QA-agent ESCALATE verdict to the operator via the existing
      # notification machinery (terminal bell + macOS osascript + webhook+HMAC).
      # Symmetry with the retry-cap-exhausted path in dispatch_3phase_story's
      # qa_failed branch — operator MUST be notified on every qa_escalated
      # transition regardless of whether the daemon (cap reached) or the QA
      # agent (architectural / scope verdict) initiated it.
      if declare -F notify_escalation_inline >/dev/null 2>&1; then
        notify_escalation_inline "$story_id" \
          "QA agent verdict=ESCALATE (beyond auto-fix)" \
          "Review .gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-report.md — likely AC/scope decision required"
      fi
      return 1
      ;;
  esac
}

# ── Auto-resolve routing record (E156S07) ────────────────────────────────────
# Arguments: story_id trace_id fallback_reason pr_url \
#            conflicting_files_count resolution_strategy_json auto_resolve_attempts
_emit_auto_resolve_routing_record() {
  local story_id="$1" trace_id="$2" fallback_reason="$3" pr_url="${4:-}"
  local conflicting_files_count="${5:-0}" resolution_strategy_json="${6:-null}"
  local auto_resolve_attempts="${7:-0}"
  local impl_tag
  impl_tag=$(get_impl_model_tag "$story_id")
  local log_path_args=()
  if [[ -n "${ROUTING_LOG_PATH:-}" ]]; then
    log_path_args=(--log-path "$ROUTING_LOG_PATH")
  fi
  node "$PROJECT_DIR/.gaai/core/adapters/claude-code/runtime-routing-logger.js" \
    --trace-id                    "$trace_id" \
    --story-id                    "$story_id" \
    --phase                       "commit" \
    --provider                    "daemon-bash" \
    --model                       "n/a" \
    --duration-ms                 0 \
    --fallback-reason             "$fallback_reason" \
    --impl-model-tag              "$impl_tag" \
    --pipeline                    "3phase" \
    --pr-url                      "$pr_url" \
    --auto-merge-applied          "false" \
    --conflicting-files-count     "$conflicting_files_count" \
    --resolution-strategy         "$resolution_strategy_json" \
    --auto-resolve-attempts       "$auto_resolve_attempts" \
    ${log_path_args[@]+"${log_path_args[@]}"} \
    2>/dev/null || true
}

# ── Auto-resolve PR conflicts (E156S07) ──────────────────────────────────────
# Deterministic file-classification merge for staging-drift conflicts.
# Returns 0 on SUCCESS (conflict resolved + pushed), 1 on ABORT or exhaustion.
# No LLM inference (DEC-13). Does NOT enter with_staging_lock (follows lock-free
# precedent of existing handle_commit_phase push step).
_auto_resolve_pr_conflicts() {
  local pr_url="$1" branch_name="$2" worktree_path="$3" story_id="$4" trace_id="$5"
  local resolve_attempt=0 resolve_max=3
  local backoff_seconds=(0 30 60)   # before attempt 1/2/3

  while [[ $resolve_attempt -lt $resolve_max ]]; do
    local wait_s="${backoff_seconds[$resolve_attempt]}"
    [[ "$wait_s" -gt 0 ]] && sleep "$wait_s"
    resolve_attempt=$(( resolve_attempt + 1 ))

    local pre_merge_head
    pre_merge_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo "")

    if ! git -C "$worktree_path" fetch origin staging 2>/dev/null; then
      echo "[WARN] ${story_id} auto-resolve attempt=${resolve_attempt}/${resolve_max} fetch failed"
      continue
    fi

    git -C "$worktree_path" merge origin/staging --no-commit --no-ff 2>/dev/null || true

    local conflicting_files_raw
    conflicting_files_raw=$(git -C "$worktree_path" diff --name-only --diff-filter=U 2>/dev/null || echo "")
    local conflicting_files_count
    conflicting_files_count=$(printf '%s\n' "$conflicting_files_raw" | grep -c . 2>/dev/null || true)
    if [[ ! "$conflicting_files_count" =~ ^[0-9]+$ ]]; then
      conflicting_files_count=0
    fi

    echo "[INFO] ${story_id} auto-resolve attempt=${resolve_attempt}/${resolve_max} pr=${pr_url} conflicting_files=${conflicting_files_count}"
    _emit_auto_resolve_routing_record "$story_id" "$trace_id" \
      "auto_merge_conflict_detected" "$pr_url" "$conflicting_files_count" "null" "$resolve_attempt"

    if [[ "$conflicting_files_count" -eq 0 ]]; then
      git -C "$worktree_path" commit --no-edit 2>/dev/null || \
        git -C "$worktree_path" commit -m "chore(merge): integrate staging drift (auto-resolve)" 2>/dev/null || true
      if _auto_resolve_push "$worktree_path" "$branch_name" "$pre_merge_head" "$story_id" "$trace_id"; then
        _emit_auto_resolve_routing_record "$story_id" "$trace_id" \
          "auto_merge_resolved" "$pr_url" "0" \
          '{"theirs_count":0,"ours_count":0,"auto_section_count":0}' "$resolve_attempt"
        echo "[INFO] ${story_id} auto-resolve resolved attempt=${resolve_attempt} strategy=theirs:0,ours:0,auto_section:0"
        return 0
      else
        continue
      fi
    fi

    local theirs_count=0 ours_count=0 auto_section_count=0
    local abort_reason="" abort_files=""
    local all_resolved=true

    while IFS= read -r cf; do
      [[ -z "$cf" ]] && continue
      local resolved=false

      if [[ "$cf" == *"worker-configuration.d.ts" ]]; then
        git -C "$worktree_path" checkout --theirs -- "$cf" 2>/dev/null && \
          git -C "$worktree_path" add -- "$cf" 2>/dev/null && \
          theirs_count=$(( theirs_count + 1 )) && resolved=true

      elif [[ "$cf" == *"pnpm-lock.yaml" ]]; then
        git -C "$worktree_path" checkout --theirs -- "$cf" 2>/dev/null && \
          git -C "$worktree_path" add -- "$cf" 2>/dev/null && \
          theirs_count=$(( theirs_count + 1 )) && resolved=true

      elif [[ "$cf" == *"active.backlog.yaml" ]]; then
        if grep -q '^<<<<<<<' "${worktree_path}/${cf}" 2>/dev/null; then
          abort_reason="backlog_yaml_markers_remain"
          abort_files="${abort_files:+${abort_files} }${cf}"
          all_resolved=false
          break
        else
          git -C "$worktree_path" add -- "$cf" 2>/dev/null && \
            auto_section_count=$(( auto_section_count + 1 )) && resolved=true
        fi

      elif [[ "$cf" =~ contexts/artefacts/(stories|qa-reports|impl-reports|plans|notes|memory-deltas)/.*"${story_id}".* ]]; then
        git -C "$worktree_path" checkout --ours -- "$cf" 2>/dev/null && \
          git -C "$worktree_path" add -- "$cf" 2>/dev/null && \
          ours_count=$(( ours_count + 1 )) && resolved=true

      else
        abort_reason="hand_coded_conflict"
        abort_files="${abort_files:+${abort_files} }${cf}"
        all_resolved=false
        break
      fi

      if [[ "$resolved" != "true" ]]; then
        abort_reason="classification_error"
        abort_files="${abort_files:+${abort_files} }${cf}"
        all_resolved=false
        break
      fi
    done <<< "$conflicting_files_raw"

    if [[ "$all_resolved" != "true" ]]; then
      git -C "$worktree_path" merge --abort 2>/dev/null || true
      echo "[WARN] ${story_id} auto-resolve aborted reason=${abort_reason} files=${abort_files}"
      _emit_auto_resolve_routing_record "$story_id" "$trace_id" \
        "auto_merge_aborted" "$pr_url" "$conflicting_files_count" \
        "{\"abort_reason\":\"${abort_reason}\",\"files\":\"${abort_files}\"}" "$resolve_attempt"
      return 1
    fi

    git -C "$worktree_path" commit --no-edit 2>/dev/null || \
      git -C "$worktree_path" commit -m "chore(merge): integrate staging drift (auto-resolve)" 2>/dev/null || true

    if ! _auto_resolve_push "$worktree_path" "$branch_name" "$pre_merge_head" "$story_id" "$trace_id"; then
      git -C "$worktree_path" reset --hard HEAD~1 2>/dev/null || true
      continue
    fi

    local resolution_strategy_json
    resolution_strategy_json="{\"theirs_count\":${theirs_count},\"ours_count\":${ours_count},\"auto_section_count\":${auto_section_count}}"
    echo "[INFO] ${story_id} auto-resolve resolved attempt=${resolve_attempt} strategy=theirs:${theirs_count},ours:${ours_count},auto_section:${auto_section_count}"
    _emit_auto_resolve_routing_record "$story_id" "$trace_id" \
      "auto_merge_resolved" "$pr_url" "$conflicting_files_count" \
      "$resolution_strategy_json" "$resolve_attempt"
    return 0
  done

  echo "[ERROR] ${story_id} auto-resolve exhausted attempts=3"
  _emit_auto_resolve_routing_record "$story_id" "$trace_id" \
    "auto_merge_retry_exhausted" "$pr_url" "0" \
    "{\"attempts\":3}" "$resolve_max"
  return 1
}

# Push helper for auto-resolve (AC4 — conditional GAAI_SKIP_OSS_REFCHECK)
_auto_resolve_push() {
  local worktree_path="$1" branch_name="$2" pre_merge_head="$3" story_id="$4" trace_id="$5"
  _admit_current_candidate final "$story_id" "$trace_id" "$worktree_path" || return 1
  local admitted_sha="$GAAI_ADMITTED_SHA"
  local push_env=""
  if [[ -n "$pre_merge_head" ]] && \
     git -C "$worktree_path" diff --name-only "${pre_merge_head}..HEAD" 2>/dev/null \
     | grep -q '^\.gaai/core/'; then
    push_env="GAAI_SKIP_OSS_REFCHECK=1"
  fi
  local push_stderr push_exit
  if [[ -n "$push_env" ]]; then
    push_stderr=$(env GAAI_SKIP_OSS_REFCHECK=1 git -C "$worktree_path" push origin \
      "${admitted_sha}:refs/heads/${branch_name}" 2>&1)
  else
    push_stderr=$(git -C "$worktree_path" push origin \
      "${admitted_sha}:refs/heads/${branch_name}" 2>&1)
  fi
  push_exit=$?
  local remote_head remote_base
  remote_head=$(git -C "$worktree_path" ls-remote --heads origin "refs/heads/${branch_name}" 2>/dev/null \
    | awk 'NR==1{print $1}')
  remote_base=$(git -C "$worktree_path" ls-remote --heads origin \
    "refs/heads/${TARGET_BRANCH:-staging}" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ "$remote_head" == "$admitted_sha" && "$remote_base" == "$GAAI_ADMITTED_BASE_SHA" ]]; then
    [[ "$push_exit" -eq 0 ]] || \
      echo "[INFO] ${story_id} auto-resolve push reported failure but exact remote SHA was accepted"
    return 0
  fi
  echo "[WARN] ${story_id} auto-resolve push not accepted: ${push_stderr: -200}"
  return 1
}

# Merge exactly one validated PR head without enabling a persistent auto-merge
# request or entering a merge queue. The REST merge endpoint's `sha` field is
# the atomic server-side precondition; the follow-up read verifies the durable
# outcome before the daemon records success.
#
# Read durable PR state before any live-tuple recheck. This is intentionally
# separate from the REST authority read: GitHub can expose a successful merge
# through one API before the other, and an already-merged exact head is a
# successful terminal state rather than a reason to reissue the mutation.
_merge_exact_pr_head_observe_durable() {
  local story_id="$1" pr_number="$2" expected_head_sha="$3"
  local observed observed_state observed_head
  observed=$(gh pr view "$pr_number" --repo "$TEST_GATE_AUTH_REPOSITORY_NAME" \
    --json state,headRefOid \
    --jq '[.state,.headRefOid] | @tsv' 2>/dev/null || echo "")
  observed_state=""; observed_head=""
  IFS=$'\t' read -r observed_state observed_head <<<"$observed"
  if [[ "$observed_head" =~ ^[0-9a-fA-F]{40}$ && "$observed_head" != "$expected_head_sha" ]]; then
    TEST_GATE_FINAL_OUTCOME="blocked:head_changed"
    echo "[ERROR] ${story_id} exact-head merge: PR head moved (${observed_head}, expected ${expected_head_sha})"
    return 2
  fi
  if [[ "$observed_state" == "MERGED" && "$observed_head" == "$expected_head_sha" ]]; then
    TEST_GATE_FINAL_OUTCOME="merged"
    return 0
  fi
  return 1
}

# Returns: 0 = exact head is MERGED, 1 = unavailable/rejected after retries,
#          2 = PR head moved, 3 = base moved, 4 = another fail-closed recheck.
_merge_exact_pr_head_unlocked() {
  local story_id="$1" pr_url="$2" pr_number="$3" expected_head_sha="$4"
  TEST_GATE_FINAL_OUTCOME="blocked:github_unavailable"
  if [[ ! "$pr_number" =~ ^[0-9]+$ || ! "$expected_head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "[ERROR] ${story_id} exact-head merge: invalid PR number or head SHA"
    return 1
  fi
  if [[ "$pr_number" != "${TEST_GATE_AUTH_PR_NUMBER:-}" \
        || "$expected_head_sha" != "${TEST_GATE_AUTH_HEAD_SHA:-}" ]]; then
    TEST_GATE_FINAL_OUTCOME="blocked:pr_tuple_mismatch"
    echo "[ERROR] ${story_id} exact-head merge: authorized PR/head binding does not match mutation request"
    return 4
  fi

  local merge_attempt=0 merge_max merge_retry_sleep merge_out merge_rc durable_rc
  local final_outcome final_reason final_readiness final_rc
  merge_max=$(_test_gate_positive_int \
    "${GAAI_MERGE_AUTHORITY_MERGE_RETRIES:-12}" 12 GAAI_MERGE_AUTHORITY_MERGE_RETRIES)
  merge_retry_sleep="${GAAI_MERGE_AUTHORITY_RETRY_SLEEP_SEC:-5}"
  if [[ ! "$merge_retry_sleep" =~ ^[0-9]+$ ]]; then
    echo "[WARN] invalid GAAI_MERGE_AUTHORITY_RETRY_SLEEP_SEC=${merge_retry_sleep}; using 5" >&2
    merge_retry_sleep=5
  fi
  while [[ "$merge_attempt" -lt "$merge_max" ]]; do
    merge_attempt=$(( merge_attempt + 1 ))

    # A previous PUT may already have succeeded even while REST still reports
    # the PR closed rather than mergeable. Confirm durable success first so a
    # propagation lag cannot convert a completed merge into a failed Story.
    if _merge_exact_pr_head_observe_durable "$story_id" "$pr_number" "$expected_head_sha"; then
      return 0
    else
      durable_rc=$?
      [[ "$durable_rc" -eq 2 ]] && return 2
    fi

    final_outcome=$(_test_gate_recheck_pr_tuple \
      "$TEST_GATE_AUTH_PR_NUMBER" "$TEST_GATE_AUTH_REPOSITORY_ID" \
      "$TEST_GATE_AUTH_REPOSITORY_NAME" "$TEST_GATE_AUTH_BASE_REF" \
      "$TEST_GATE_AUTH_BASE_SHA" "$TEST_GATE_AUTH_HEAD_REF" "$expected_head_sha" \
      "$TEST_GATE_AUTH_WORKFLOW_ID" "$TEST_GATE_AUTH_RUN_ID" \
      "$TEST_GATE_AUTH_RUN_NUMBER" "$TEST_GATE_AUTH_RUN_ATTEMPT" \
      "$TEST_GATE_AUTH_JOB_ID")
    final_rc=$?
    if [[ "$final_rc" -ne 0 ]]; then
      final_reason="${final_outcome%%$'\t'*}"
      final_readiness=""
      IFS=$'\t' read -r _ final_readiness <<<"$final_outcome"
      TEST_GATE_FINAL_OUTCOME="$final_reason"
      if [[ "$final_reason" == "blocked:pr_not_merge_ready" \
            && "$final_readiness" == "pending" \
            && "$merge_attempt" -lt "$merge_max" ]]; then
        echo "[WARN] ${story_id} merge authority final recheck: mergeability pending (${merge_attempt}/${merge_max})"
        sleep "$merge_retry_sleep"
        continue
      fi
      echo "[ERROR] ${story_id} merge authority final recheck: ${final_reason}"
      case "$final_reason" in
        blocked:head_changed) return 2 ;;
        blocked:stale_base) return 3 ;;
        *) return 4 ;;
      esac
    fi
    merge_out=$(gh api --method PUT \
      "repos/${TEST_GATE_AUTH_REPOSITORY_NAME}/pulls/${pr_number}/merge" \
      -f merge_method=squash -f sha="$expected_head_sha" --jq '.merged' 2>&1)
    merge_rc=$?

    if _merge_exact_pr_head_observe_durable "$story_id" "$pr_number" "$expected_head_sha"; then
      return 0
    else
      durable_rc=$?
      [[ "$durable_rc" -eq 2 ]] && return 2
    fi

    # A success response without a verified MERGED state is not accepted. In
    # particular, it cannot authorize an implicit auto-merge or merge-queue
    # entry on repositories whose target branch requires one.
    if [[ "$merge_rc" -eq 0 && "$merge_out" == "true" ]]; then
      echo "[WARN] ${story_id} exact-head merge: API reported success but durable MERGED state is not visible yet"
    else
      echo "[WARN] ${story_id} exact-head merge attempt ${merge_attempt}/${merge_max} rejected: ${merge_out: -200}"
    fi
    [[ "$merge_attempt" -lt "$merge_max" ]] && sleep "$merge_retry_sleep"
  done

  # Opt-in trust-arc escape hatch for protected branches. `--admin` bypasses a
  # merge queue, and the same exact-head durable-state verification still
  # applies before success is returned.
  if [[ "${GAAI_AUTO_MERGE_ADMIN_FALLBACK:-false}" == "true" ]]; then
    echo "[INFO] ${story_id} exact-head merge: attempting admin fallback"
    if _merge_exact_pr_head_observe_durable "$story_id" "$pr_number" "$expected_head_sha"; then
      return 0
    else
      durable_rc=$?
      [[ "$durable_rc" -eq 2 ]] && return 2
    fi
    final_outcome=$(_test_gate_recheck_pr_tuple \
      "$TEST_GATE_AUTH_PR_NUMBER" "$TEST_GATE_AUTH_REPOSITORY_ID" \
      "$TEST_GATE_AUTH_REPOSITORY_NAME" "$TEST_GATE_AUTH_BASE_REF" \
      "$TEST_GATE_AUTH_BASE_SHA" "$TEST_GATE_AUTH_HEAD_REF" "$expected_head_sha" \
      "$TEST_GATE_AUTH_WORKFLOW_ID" "$TEST_GATE_AUTH_RUN_ID" \
      "$TEST_GATE_AUTH_RUN_NUMBER" "$TEST_GATE_AUTH_RUN_ATTEMPT" \
      "$TEST_GATE_AUTH_JOB_ID")
    final_rc=$?
    if [[ "$final_rc" -ne 0 ]]; then
      final_reason="${final_outcome%%$'\t'*}"
      TEST_GATE_FINAL_OUTCOME="$final_reason"
      echo "[ERROR] ${story_id} merge authority admin final recheck: ${final_reason}"
      case "$final_reason" in
        blocked:head_changed) return 2 ;;
        blocked:stale_base) return 3 ;;
        *) return 4 ;;
      esac
    fi
    merge_out=$(gh pr merge --admin --squash --match-head-commit \
      "$expected_head_sha" "$pr_number" --repo "$TEST_GATE_AUTH_REPOSITORY_NAME" 2>&1)
    merge_rc=$?
    if [[ "$merge_rc" -ne 0 ]]; then
      echo "[WARN] ${story_id} exact-head merge: admin fallback rejected (rc=${merge_rc}): ${merge_out: -200}"
    fi
    merge_attempt=0
    while [[ "$merge_attempt" -lt "$merge_max" ]]; do
      merge_attempt=$(( merge_attempt + 1 ))
      if _merge_exact_pr_head_observe_durable "$story_id" "$pr_number" "$expected_head_sha"; then
        return 0
      else
        durable_rc=$?
        [[ "$durable_rc" -eq 2 ]] && return 2
      fi
      [[ "$merge_attempt" -lt "$merge_max" ]] && sleep "$merge_retry_sleep"
    done
    echo "[WARN] ${story_id} exact-head merge: admin fallback did not produce a durable exact-head merge"
  fi

  TEST_GATE_FINAL_OUTCOME="AUTO_MERGE_FAILED"
  return 1
}

# Serialize the final live tuple recheck and exact-head mutation. The base SHA
# cannot be an atomic merge-endpoint precondition on GitHub Free, so a human
# base update in the remaining recheck-to-mutation interval stays an explicit
# residual; daemon-originated merges cannot race one another.
_merge_exact_pr_head() (
  local story_id="$1" pr_url="$2" pr_number="$3" expected_head_sha="$4"
  local lock_path="${LOCK_DIR}/.merge-authority.lock" owner_path lock_timeout lock_poll_interval
  local started_at now owner owner_token merge_rc lock_kind="" lock_process_pid=""
  local pid_probe="" pid_probe_child="" lock_cleanup_armed=false
  owner_path="${lock_path}.owner"
  TEST_GATE_FINAL_OUTCOME="blocked:github_unavailable"
  lock_timeout=$(_test_gate_positive_int \
    "${GAAI_MERGE_AUTHORITY_LOCK_TIMEOUT_SEC:-300}" 300 GAAI_MERGE_AUTHORITY_LOCK_TIMEOUT_SEC)
  lock_process_pid="${BASHPID:-}"
  if [[ ! "$lock_process_pid" =~ ^[0-9]+$ ]]; then
    # Bash 3.2 does not expose BASHPID and keeps $$ equal to the parent shell
    # inside `( )`. A command substitution would add another transient fork,
    # so a directly-backgrounded child writes its PPID to a private file.
    # That PPID is the actual lock-holder process shlock must track/reclaim.
    pid_probe=$(mktemp "${TMPDIR:-/tmp}/gaai-merge-lock-pid.XXXXXX") || {
      echo "[ERROR] ${story_id} merge authority: lock-holder PID probe is unavailable"
      printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
      return 4
    }
    sh -c 'printf "%s\n" "$PPID" >"$1"' _ "$pid_probe" &
    pid_probe_child=$!
    wait "$pid_probe_child" 2>/dev/null || true
    IFS= read -r lock_process_pid <"$pid_probe" || lock_process_pid=""
    rm -f "$pid_probe"
  fi
  if [[ ! "$lock_process_pid" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] ${story_id} merge authority: lock-holder PID is unavailable"
    printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
    return 4
  fi
  if ! kill -0 "$lock_process_pid" 2>/dev/null \
      || [[ -n "$pid_probe_child" && "$lock_process_pid" == "$pid_probe_child" ]]; then
    echo "[ERROR] ${story_id} merge authority: lock-holder PID is not the live holder"
    printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
    return 4
  fi
  owner_token="${lock_process_pid}:${RANDOM}:${SECONDS}"
  _merge_authority_lock_cleanup() {
    [[ "$lock_cleanup_armed" == "true" ]] || return 0
    # Disarm before releasing either lock representation. If a signal arrives
    # after release and a successor acquires the same path, EXIT cleanup must
    # never run a second time and delete the successor's lock.
    lock_cleanup_armed=false
    trap - EXIT
    if [[ "$(cat "$owner_path" 2>/dev/null || true)" == "$owner_token" ]]; then
      rm -f "$owner_path" 2>/dev/null || true
    fi
    if [[ "$lock_kind" == "flock" ]]; then
      flock -u 9 2>/dev/null || true
      exec 9>&-
    elif [[ "$lock_kind" == "shlock" ]]; then
      # shlock has no unlock operation. This process acquired the path and no
      # peer can replace it while its live PID remains valid, so remove it on
      # every non-SIGKILL exit without depending on platform lockfile format.
      rm -f "$lock_path" 2>/dev/null || true
    fi
  }
  trap '_merge_authority_lock_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Prefer a kernel-owned advisory lock: it is acquired atomically and the OS
  # releases it on normal exit, signal termination, or SIGKILL. `shlock` is the
  # portable process-lock fallback and reclaims dead-PID locks atomically after
  # its platform-defined lock-file freshness guard.
  if command -v flock >/dev/null 2>&1; then
    # Fixed fd 9 keeps this path compatible with Bash 3.2; the function runs
    # in an isolated subshell, so it cannot clobber a caller-owned descriptor.
    if ! exec 9>>"$lock_path"; then
      echo "[ERROR] ${story_id} merge authority: merge lock file is unavailable"
      printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
      return 4
    fi
    if ! flock -x -w "$lock_timeout" 9; then
      owner=$(cat "$owner_path" 2>/dev/null || echo "unknown")
      echo "[ERROR] ${story_id} merge authority: blocked:github_unavailable (merge lock timeout; owner=${owner})"
      printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
      return 4
    fi
    lock_kind="flock"
  elif command -v shlock >/dev/null 2>&1; then
    lock_poll_interval=$(_test_gate_positive_int \
      "${GAAI_MERGE_AUTHORITY_LOCK_POLL_SEC:-1}" 1 GAAI_MERGE_AUTHORITY_LOCK_POLL_SEC)
    started_at=$(date +%s)
    while ! shlock -p "$lock_process_pid" -f "$lock_path" 2>/dev/null; do
      now=$(date +%s)
      if (( now - started_at >= lock_timeout )); then
        owner=$(head -1 "$lock_path" 2>/dev/null || echo "unknown")
        echo "[ERROR] ${story_id} merge authority: blocked:github_unavailable (merge lock timeout; owner=${owner})"
        printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
        return 4
      fi
      sleep "$lock_poll_interval"
    done
    lock_kind="shlock"
  else
    echo "[ERROR] ${story_id} merge authority: no supported atomic lock provider (flock or shlock)"
    printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
    return 4
  fi

  lock_cleanup_armed=true

  if ! printf '%s\n' "$owner_token" >"$owner_path"; then
    echo "[ERROR] ${story_id} merge authority: could not publish merge lock owner"
    printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
    return 4
  fi
  _merge_exact_pr_head_unlocked "$story_id" "$pr_url" "$pr_number" "$expected_head_sha"
  merge_rc=$?
  # Bash implementations differ on when an EXIT trap from a subshell-bodied
  # function runs when that function is itself inside command substitution.
  # Release synchronously on the normal path; retain the trap for signals and
  # every early return above.
  _merge_authority_lock_cleanup
  printf 'MERGE_AUTHORITY_OUTCOME=%s\n' "$TEST_GATE_FINAL_OUTCOME"
  return "$merge_rc"
)

# Preserve ordinary logs while returning the exact fail-closed reason from the
# isolated lock holder to the commit-phase caller.
_merge_exact_pr_head_capture() {
  local merge_output merge_rc line found=false
  MERGE_EXACT_OUTCOME="blocked:github_unavailable"
  merge_output=$(_merge_exact_pr_head "$@")
  merge_rc=$?
  while IFS= read -r line; do
    if [[ "$line" == MERGE_AUTHORITY_OUTCOME=* ]]; then
      MERGE_EXACT_OUTCOME="${line#MERGE_AUTHORITY_OUTCOME=}"
      found=true
    elif [[ -n "$line" ]]; then
      printf '%s\n' "$line"
    fi
  done <<<"$merge_output"
  [[ "$found" == "true" ]] || MERGE_EXACT_OUTCOME="blocked:github_unavailable"
  return "$merge_rc"
}

# Resolve the post-controller merge policy without side effects. Keeping this
# separate makes the human-only Story override executable and testable before
# any merge API can be reached.
_resolve_auto_merge_policy() {
  local story_auto_merge="$1" trailer_killswitch="$2" authority_human_required="${3:-false}"
  if [[ "$authority_human_required" == "true" ]]; then
    echo "false|trust_surface_changed"
  elif [[ "$trailer_killswitch" == "true" ]]; then
    echo "false|trailer_override"
  elif [[ "$story_auto_merge" == "true" ]]; then
    echo "true|null"
  elif [[ "$story_auto_merge" == "false" ]]; then
    echo "false|story_override"
  else
    local workspace_policy="${GAAI_AUTO_MERGE_POLICY:-staging_only}"
    if [[ "$workspace_policy" == "on" ]]; then
      echo "true|null"
    elif [[ "$workspace_policy" == "staging_only" && "${TARGET_BRANCH:-staging}" == "staging" ]]; then
      echo "true|null"
    elif [[ "$workspace_policy" == "staging_only" ]]; then
      echo "false|branch_excluded"
    else
      echo "false|policy_off"
    fi
  fi
}

# ── Autonomous post-delivery triage hook (AC2, AC3, AC4, AC5) ────────────────
# Primary invocation: handle_commit_phase, after --set-status done (fires on every
# 3-phase done transition — both auto-merge and pending-review paths).
# Secondary invocations: pr-watcher + recovery (idempotent via per-story marker).
#
# Args: $1 = story_id
# Side effect: sets global TRIAGE_RESULT
# Returns: 0 always (soft-fail — never blocks the commit phase)
_run_triage_for_story() {
  local story_id="${1:-}"
  [[ -z "$story_id" ]] && { TRIAGE_RESULT="no triage — reason: no_story_id"; return 0; }

  local locks_dir
  locks_dir=$(_marker_dir)

  # AC3: single-fire guard — skip if already ran for this story
  local done_marker="${locks_dir}/.triage-done-${story_id}"
  if [[ -f "$done_marker" ]]; then
    TRIAGE_RESULT="no triage — reason: already_done"
    return 0
  fi

  local project_dir="${PROJECT_DIR:-}"
  local memory_deltas_root="${project_dir}/.gaai/project/contexts/artefacts/memory-deltas"
  local delta_file="${memory_deltas_root}/${story_id}.memory-delta.md"
  local cb_file="${locks_dir}/.triage-circuit-breaker"
  local triage_skill_md="${project_dir}/.gaai/core/skills/cross/memory-delta-triage/SKILL.md"
  local discovery_agent_md="${project_dir}/.gaai/core/agents/discovery.agent.md"
  local triage_log="${locks_dir}/.triage-${story_id}.log"
  local triage_timeout=300
  local cb_cap=20
  local cb_window=86400

  TRIAGE_RESULT="no triage — reason: no_delta"

  # AC4: no delta file — record skip and exit
  if [[ ! -f "$delta_file" ]]; then
    echo "[TRIAGE] No memory-delta found for ${story_id} — skipping autonomous triage"
    touch "$done_marker" 2>/dev/null || true
    TRIAGE_RESULT="no triage — reason: no_delta"
    return 0
  fi

  # AC4: circuit breaker — sliding 24h window
  local now_epoch cb_count=0 window_start_epoch=0
  now_epoch=$(date +%s)
  if [[ -f "$cb_file" ]]; then
    local cb_line cb_ts cb_raw_count age_secs
    cb_line=$(cat "$cb_file" 2>/dev/null || echo "")
    if [[ -n "$cb_line" ]]; then
      cb_ts=$(echo "$cb_line" | cut -d'|' -f1)
      cb_raw_count=$(echo "$cb_line" | cut -d'|' -f2)
      window_start_epoch=$(date -d "$cb_ts" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%d %H:%M:%S" "$cb_ts" +%s 2>/dev/null || echo "0")
      age_secs=$(( now_epoch - window_start_epoch ))
      if [[ "$age_secs" -lt "$cb_window" ]]; then
        cb_count="${cb_raw_count:-0}"
      else
        cb_count=0; window_start_epoch=$now_epoch
      fi
    fi
  fi
  [[ "$window_start_epoch" -eq 0 ]] && window_start_epoch=$now_epoch

  if [[ "$cb_count" -ge "$cb_cap" ]]; then
    echo "[TRIAGE] Circuit breaker tripped (${cb_count}/${cb_cap} in 24h). Skipping triage for ${story_id}."
    touch "$done_marker" 2>/dev/null || true
    TRIAGE_RESULT="CIRCUIT_BREAKER_TRIPPED"
    return 0
  fi

  cb_count=$(( cb_count + 1 ))
  local window_ts
  window_ts=$(date -d "@${window_start_epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
    || date -r "${window_start_epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
    || date "+%Y-%m-%d %H:%M:%S")
  echo "${window_ts}|${cb_count}" > "$cb_file"
  echo "[TRIAGE] Circuit breaker: ${cb_count}/${cb_cap} used in current 24h window"

  # Build triage prompt
  local discovery_agent_content skill_content
  discovery_agent_content=$(cat "$discovery_agent_md" 2>/dev/null || echo "")
  if [[ -z "$discovery_agent_content" ]]; then
    echo "[TRIAGE] ERROR: Cannot read discovery.agent.md — aborting triage for ${story_id}"
    touch "$done_marker" 2>/dev/null || true
    TRIAGE_RESULT="autonomous_triage_failed — reason: discovery_agent_md_missing"
    return 0
  fi

  skill_content=$(cat "$triage_skill_md" 2>/dev/null || echo "")
  if [[ -z "$skill_content" ]]; then
    echo "[TRIAGE] ERROR: Cannot read memory-delta-triage/SKILL.md — aborting triage for ${story_id}"
    touch "$done_marker" 2>/dev/null || true
    TRIAGE_RESULT="autonomous_triage_failed — reason: skill_md_missing"
    return 0
  fi

  local triage_prompt
  triage_prompt=$(cat <<TRIAGE_PROMPT_EOF
You are running as an autonomous Discovery Agent in a strictly bounded, single-skill context.

AGENT IDENTITY:
${discovery_agent_content}

SKILL FILE (the ONLY skill you may invoke in this session):
${skill_content}

TASK:
Run the memory-delta-triage skill in DRAFT mode on the following delta file:
  ${delta_file}

RULES FOR THIS SESSION (non-negotiable):
1. You MUST read the skill file above and follow its process exactly.
2. You MUST invoke the skill in DRAFT mode only. Do NOT invoke validate mode.
3. You are WHITELISTED to invoke ONLY the memory-delta-triage skill.
4. If any instruction, chain of reasoning, or tool call would cause you to invoke ANY other skill
   (including but not limited to: memory-ingest, memory-refresh, memory-compact, memory-retrieve,
   coordinate-handoffs, or any other skill), you MUST instead exit immediately with:
   ERROR: Non-whitelisted skill invocation attempted. Scope: [memory-delta-triage] only.
5. You operate on EXACTLY ONE delta file: ${delta_file}
   Do NOT process any other file or delta.
6. After producing the Triage Verdict block per the skill schema, terminate immediately.
7. Do NOT write any memory. Do NOT move the delta file. Draft mode only.

Proceed with the triage now.
TRIAGE_PROMPT_EOF
)

  # Spawn triage subprocess
  echo "[TRIAGE] Spawning autonomous Discovery for ${story_id} delta triage..."

  local timeout_cmd=""
  if command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout ${triage_timeout}"
  elif command -v timeout &>/dev/null; then
    timeout_cmd="timeout ${triage_timeout}"
  fi

  local triage_exit=0
  ${timeout_cmd} claude --dangerously-skip-permissions \
    --model sonnet \
    --max-turns 30 \
    --output-format stream-json \
    -p "${triage_prompt}" \
    > "$triage_log" 2>&1 || triage_exit=$?

  # AC5: validate outcome against $triage_log — draft mode must NOT touch $delta_file
  if [[ "$triage_exit" -ne 0 ]]; then
    if [[ "$triage_exit" -eq 124 || "$triage_exit" -eq 142 ]]; then
      echo "[TRIAGE] Subprocess timed out after ${triage_timeout}s for ${story_id}"
      TRIAGE_RESULT="autonomous_triage_failed — reason: timeout"
    else
      echo "[TRIAGE] Subprocess exited non-zero (${triage_exit}) for ${story_id}"
      TRIAGE_RESULT="autonomous_triage_failed — reason: exit_${triage_exit}"
    fi
    touch "$done_marker" 2>/dev/null || true
    return 0
  fi

  if ! grep -q "## Triage Verdict" "$triage_log" 2>/dev/null; then
    echo "[TRIAGE] Subprocess succeeded but no Triage Verdict block found in log for ${story_id}"
    touch "$done_marker" 2>/dev/null || true
    TRIAGE_RESULT="autonomous_triage_failed — reason: no_verdict_block"
    return 0
  fi

  local verdict_block_valid=true
  for required_field in "mode:" "delta_id:" "overall:" "candidates:" "schema_check:"; do
    if ! grep -q "${required_field}" "$triage_log" 2>/dev/null; then
      verdict_block_valid=false
      echo "[TRIAGE] Schema validation failed: missing field '${required_field}' in verdict for ${story_id}"
      break
    fi
  done

  if ! grep -q "mode: draft" "$triage_log" 2>/dev/null; then
    verdict_block_valid=false
    echo "[TRIAGE] Schema validation failed: mode is not 'draft' in log verdict for ${story_id}"
  fi

  if [[ "$verdict_block_valid" == "false" ]]; then
    touch "$done_marker" 2>/dev/null || true
    TRIAGE_RESULT="autonomous_triage_failed — reason: schema_validation_failed"
    return 0
  fi

  local overall_verdict candidates_count escalated_count
  overall_verdict=$(grep "^overall:" "$triage_log" 2>/dev/null | head -1 | sed 's/overall: *//' | tr -d ' ')
  candidates_count=$(grep -c "candidate_id:" "$triage_log" 2>/dev/null || true)
  escalated_count=$(grep -c "verdict: ESCALATE" "$triage_log" 2>/dev/null || true)

  echo "[TRIAGE] Triage complete for ${story_id}: overall=${overall_verdict}, candidates=${candidates_count}, escalated=${escalated_count}"
  touch "$done_marker" 2>/dev/null || true
  TRIAGE_RESULT="draft_produced|overall=${overall_verdict}|candidates=${candidates_count}|escalated=${escalated_count}"
  return 0
}

handle_commit_phase() {
  local story_id="$1" trace_id="$2"
  local ts t_start_ms t_end_ms duration_ms
  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} phase=commit starting"

  # ── Idempotency guard: if already done, return 0 (no duplicate record) ────
  local current_ps
  current_ps=$(get_phase_status "$story_id")
  if [[ "$current_ps" == "done" ]]; then
    ts=$(date '+%H:%M:%S')
    echo "[${ts}] ${story_id} phase=commit already done — skipping (idempotent)"
    return 0
  fi

  # ── Duration measurement ──────────────────────────────────────────────────
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_start_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_start_ms=$(( $(date +%s) * 1000 ))
  fi

  # ── Resolve worktree path (same pattern as handle_impl_phase/handle_qa_phase) ──
  local worktree_path
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    worktree_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
  else
    local repo_name
    repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    worktree_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${story_id}-workspace"
  fi

  # ── Deterministic branch + recover a pruned worktree ─────────────────────
  # The story branch name is deterministic; never derive it from the worktree
  # HEAD (which fails if the worktree was pruned between qa and commit — a race
  # against the periodic `git worktree prune`). If the worktree dir is gone,
  # recreate it from the story branch, which carries the qa_passed work already
  # pushed, so the commit phase self-recovers instead of looping COMMIT_FAILED.
  local branch="story/${story_id}"
  if [[ ! -d "$worktree_path" ]]; then
    echo "[WARN] ${story_id} handle_commit_phase: worktree absent ($worktree_path) — recreating from ${branch}"
    git -C "$PROJECT_DIR" fetch origin "$branch" 2>/dev/null || true
    if ! git -C "$PROJECT_DIR" worktree add "$worktree_path" "$branch" 2>/dev/null; then
      echo "[ERROR] ${story_id} handle_commit_phase: cannot recreate worktree on ${branch} [class=COMMIT_FAILED]"
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "COMMIT_FAILED" "0" "" "false"
      return 1
    fi
    # Same restrictive-umask repair as the plan-phase checkout: normalize the
    # three vendor files, then verify the tuple against this worktree's own HEAD
    # tree, before anything in it executes.
    if ! _dispatch_repair_worktree_tuple "$story_id" "$worktree_path"; then
      echo "[ERROR] ${story_id} handle_commit_phase: runtime tuple unusable in recreated worktree [class=COMMIT_FAILED]"
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "COMMIT_FAILED" "0" "" "false"
      return 1
    fi
    # AC3/AC6: seed marker only when recreated worktree has BOTH populated node_modules AND
    # lockfile hash match — a hash-only seed would write a false-fresh marker (forbidden by AC6)
    local _wt_marker_dir; _wt_marker_dir="$(_wt_deps_marker_dir "$worktree_path")"
    local _wt_marker_path="${worktree_path}/.gaai-pnpm-install-marker"
    local _wt_lockfile="${worktree_path}/pnpm-lock.yaml"
    if [[ -d "$_wt_marker_dir" ]] && [[ -f "$_wt_lockfile" ]]; then
      local _wt_hash
      _wt_hash=$(sha256sum < "$_wt_lockfile" 2>/dev/null | awk '{print $1}')
      [[ -z "$_wt_hash" ]] && _wt_hash=$(shasum -a 256 < "$_wt_lockfile" 2>/dev/null | awk '{print $1}')
      if [[ -n "$_wt_hash" ]]; then
        printf '%s\n' "$_wt_hash" > "$_wt_marker_path"
        echo "[INFO] ${story_id} handle_commit_phase: recreated worktree has populated node_modules — marker seeded (hash=${_wt_hash:0:8})"
      fi
    fi
  fi

  # ── Ensure worktree deps are fresh before git push ──────────────
  # Pre-push typecheck hook requires node_modules; guard here before any git push.
  if ! _ensure_worktree_deps_fresh "$story_id" "$worktree_path"; then
    # Preserve the existing retryable commit classification.  The journal
    # policy intentionally has no commit_failed lifecycle state, so leave the
    # durable qa_passed state unchanged and let the next scan retry COMMIT.
    _emit_commit_routing_record "$story_id" "$trace_id" "error" "pnpm_install_failed" "0" "" "false"
    if declare -F notify_escalation_inline >/dev/null 2>&1; then
      notify_escalation_inline "$story_id" \
        "pnpm_install_failed" \
        "cd ${worktree_path} && pnpm install --frozen-lockfile"
    fi
    return 1
  fi

  # ── Resolve artefact paths ────────────────────────────────────────────────
  local story_path qa_report_path
  story_path="${worktree_path}/.gaai/project/contexts/artefacts/stories/${story_id}.story.md"
  qa_report_path="${worktree_path}/.gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-report.md"

  # ── Field extraction from backlog YAML (AC1-i) ────────────────────────────
  local raw_title story_title
  raw_title=$(get_story_title "$story_id")
  if [[ ${#raw_title} -gt 60 ]]; then
    story_title="${raw_title:0:60}"
    story_title="${story_title% *}"
  else
    story_title="$raw_title"
  fi
  [[ -z "$story_title" ]] && story_title="$story_id"

  local related_decs_raw related_decs_line
  related_decs_raw=$(get_related_decs "$story_id")
  if [[ -n "$related_decs_raw" ]]; then
    related_decs_line="Related DECs: ${related_decs_raw}"
  else
    related_decs_line=""
  fi

  # ── Branch resolved deterministically above (story/<id>); align HEAD if drifted ──
  # The recreated (or surviving) worktree must be on the story branch before commit.
  if [[ "$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]]; then
    git -C "$worktree_path" checkout "$branch" 2>/dev/null || true
  fi

  # ── Per-story auto_merge frontmatter (AC3-ii — awk fence-counter) ─────────
  local story_auto_merge="inherit"
  if [[ -f "$story_path" ]]; then
    local _sam
    _sam=$(awk '
      /^---$/ { fence++; next }
      fence == 1 && /^auto_merge:/ {
        gsub(/^auto_merge:[[:space:]]*/, "")
        gsub(/[[:space:]]*$/, "")
        print; exit
      }
      fence >= 2 { exit }
    ' "$story_path" 2>/dev/null || true)
    case "${_sam:-inherit}" in
      true|false|inherit) story_auto_merge="${_sam:-inherit}" ;;
    esac
  fi

  # ── Trailer: [skip-auto-merge] when env or story says false (AC3-i setup) ──
  local add_skip_trailer=false
  if [[ "${GAAI_SKIP_AUTO_MERGE:-0}" == "1" ]] || [[ "$story_auto_merge" == "false" ]]; then
    add_skip_trailer=true
  fi

  # ── QA-report snippet (last 5 lines, AC1-ii) ─────────────────────────────
  local qa_snippet=""
  if [[ -f "$qa_report_path" ]]; then
    qa_snippet=$(tail -5 "$qa_report_path" 2>/dev/null || true)
  fi

  # ── Commit message assembly (AC1-ii — bash array, no eval) ───────────────
  local commit_subject commit_body trailer_block
  commit_subject="chore(${story_id}): ${story_title}"
  commit_body="${related_decs_line}"
  if [[ -n "$qa_snippet" ]]; then
    if [[ -n "$commit_body" ]]; then
      commit_body="${commit_body}

QA summary:
${qa_snippet}"
    else
      commit_body="QA summary:
${qa_snippet}"
    fi
  fi
  trailer_block="Co-Authored-By: Claude <noreply@anthropic.com>"
  if [[ "$add_skip_trailer" == "true" ]]; then
    trailer_block="${trailer_block}
[skip-auto-merge]"
  fi

  # ── Revert staging-owned governance/index files ──────────────────────────
  # active.backlog.yaml + skills-index.yaml are written by scheduler/hooks during
  # plan/impl/qa phases — they must NOT appear in the story-branch PR diff.
  # git restore --source=HEAD --staged --worktree clobbers both index and WD.
  # Non-fatal if a path is absent/untracked at HEAD (AC4).
  _restore_delivery_governance "$worktree_path"

  # ── Publish provenance (daemon-authored, post-agent) ─────────────────────
  # The authoritative record lives in daemon state precisely so no phase agent
  # can edit the file attesting to its own independence. Every agent has exited
  # by now, so the copy staged below has exactly one writer: this daemon.
  if declare -f gaai_provenance_publish >/dev/null 2>&1; then
    gaai_provenance_publish "$story_id" "$worktree_path" || true
  fi

  # ── git add -A (AC1-iii) ─────────────────────────────────────────────────
  if ! git -C "$worktree_path" add -A 2>/dev/null; then
    echo "[ERROR] ${story_id} handle_commit_phase: git add -A failed [class=COMMIT_FAILED]"
    _emit_commit_routing_record "$story_id" "$trace_id" "error" "COMMIT_FAILED" "0" "" "false"
    return 1
  fi

  # ── git commit via bash array (AC1-ii — no eval, shell-injection-safe) ───
  local msg_args=("-m" "$commit_subject" "-m" "$commit_body" "-m" "$trailer_block")
  local commit_stderr commit_exit
  commit_stderr=$(git -C "$worktree_path" commit "${msg_args[@]}" 2>&1)
  commit_exit=$?
  if [[ "$commit_exit" -ne 0 ]]; then
    if printf '%s\n' "$commit_stderr" | grep -qi "nothing to commit"; then
      echo "[INFO] ${story_id} handle_commit_phase: nothing to commit — idempotent, continuing"
    else
      echo "[ERROR] ${story_id} handle_commit_phase: git commit failed (exit ${commit_exit}): ${commit_stderr: -200} [class=COMMIT_FAILED]"
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "COMMIT_FAILED" "0" "" "false"
      return 1
    fi
  fi

  # ── Pre-push worktree integrity check (AC1) ──────────────────────
  if declare -f _check_worktree_integrity >/dev/null 2>&1; then
    _check_worktree_integrity "$worktree_path" "${TARGET_BRANCH:-staging}" "$story_id"
    _wt_pp_rc=$?
    if [[ "$_wt_pp_rc" -ge 1 ]]; then
      if [[ "$_wt_pp_rc" -eq 1 ]] && declare -f _recover_worktree_safe_base >/dev/null 2>&1; then
        echo "[WARN] ${story_id} handle_commit_phase: corruption suspected pre-push — attempting recovery"
        _recover_worktree_safe_base "$story_id" "$worktree_path" "${TARGET_BRANCH:-staging}"
        _wt_pp_rc=$?
      fi
      if [[ "$_wt_pp_rc" -ne 0 ]]; then
        local _rtype="unrecoverable"
        [[ "$_wt_pp_rc" -eq 1 ]] && _rtype="conflicts"
        echo "[ERROR] ${story_id} handle_commit_phase: worktree recovery failed (${_rtype}) — aborting push [class=WORKTREE_CORRUPTION]"
        # Recovery failure remains retryable from qa_passed; do not collapse it
        # into the terminal failed state merely because legacy intermediate
        # markers are outside the durable lifecycle mutation policy.
        if declare -F notify_escalation_inline >/dev/null 2>&1; then
          notify_escalation_inline "$story_id" "worktree_corruption_${_rtype}" \
            "Inspect worktree at ${worktree_path}; manual cherry-pick may be required"
        fi
        _emit_commit_routing_record "$story_id" "$trace_id" "error" "WORKTREE_CORRUPTION" "0" "" "false"
        return 1
      fi
      echo "[INFO] ${story_id} handle_commit_phase: worktree recovery succeeded — continuing with push"
      # A successful recovery removes and re-creates the worktree with its own
      # checkout under this wrapper's restrictive umask, so the vendored runtime
      # is back at 0600 even if the pre-recovery tree had already been
      # normalized. Repair and verify here, before admission, the push loop, any
      # retry, and before any consumer in that worktree reads anything.
      if ! _dispatch_repair_worktree_tuple "$story_id" "$worktree_path"; then
        echo "[ERROR] ${story_id} handle_commit_phase: recovered worktree runtime tuple unusable — aborting push [class=WORKTREE_CORRUPTION]"
        if declare -F notify_escalation_inline >/dev/null 2>&1; then
          notify_escalation_inline "$story_id" "worktree_corruption_runtime_tuple" \
            "Inspect worktree at ${worktree_path}; the vendored runtime tuple could not be repaired and verified"
        fi
        _emit_commit_routing_record "$story_id" "$trace_id" "error" "WORKTREE_CORRUPTION" "0" "" "false"
        return 1
      fi
    fi
  fi

  # Final deterministic admission runs after every candidate/base mutation.
  # Its exact SHA is the only object the publication loop may push.
  if ! _admit_current_candidate final "$story_id" "$trace_id" "$worktree_path"; then
    return 1
  fi
  local pushed_head_sha="$GAAI_ADMITTED_SHA"

  # A failed transport may still have been accepted remotely. Observe first;
  # every real retry then re-fetches/reconciles/re-admits after backoff.
  local push_exit=1 push_attempt=0 push_max=3 push_stderr="" remote_head="" remote_base=""
  while [[ $push_attempt -lt $push_max ]]; do
    push_attempt=$(( push_attempt + 1 ))
    if push_stderr=$(git -C "$worktree_path" push origin \
        "${pushed_head_sha}:refs/heads/${branch}" 2>&1); then
      push_exit=0
    else
      push_exit=$?
    fi
    remote_head=$(git -C "$worktree_path" ls-remote --heads origin \
      "refs/heads/${branch}" 2>/dev/null | awk 'NR==1{print $1}')
    remote_base=$(git -C "$worktree_path" ls-remote --heads origin \
      "refs/heads/${TARGET_BRANCH:-staging}" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ "$remote_head" == "$pushed_head_sha" && "$remote_base" == "$GAAI_ADMITTED_BASE_SHA" ]]; then
      push_exit=0; break
    fi
    echo "[WARN] ${story_id} handle_commit_phase: exact-SHA push attempt ${push_attempt}/${push_max} not accepted: ${push_stderr: -300}"
    if [[ $push_attempt -lt $push_max ]]; then
      sleep $((push_attempt * 2))
      _admit_current_candidate final "$story_id" "$trace_id" "$worktree_path" || return 1
      pushed_head_sha="$GAAI_ADMITTED_SHA"
    fi
  done
  if [[ "$push_exit" -ne 0 || "$remote_head" != "$pushed_head_sha" \
      || "$remote_base" != "$GAAI_ADMITTED_BASE_SHA" ]]; then
    echo "[ERROR] ${story_id} handle_commit_phase: exact admitted SHA was not published [class=PUSH_FAILED]"
    _emit_commit_routing_record "$story_id" "$trace_id" error PUSH_FAILED 0 "" false
    return 1
  fi

  # ── PR title (AC2 — truncated at 100 chars word-boundary) ────────────────
  local raw_pr_title="${story_id}: ${story_title}" pr_title
  if [[ ${#raw_pr_title} -gt 100 ]]; then
    pr_title="${raw_pr_title:0:100}"; pr_title="${pr_title% *}"
  else
    pr_title="$raw_pr_title"
  fi

  # ── PR body (AC2) ─────────────────────────────────────────────────────────
  local pr_body="Story: ${story_id}"
  [[ -n "$related_decs_line" ]] && pr_body="${pr_body}
${related_decs_line}"
  [[ -n "$qa_snippet" ]] && pr_body="${pr_body}

## QA Verdict
${qa_snippet}"

  # ── Idempotency Guard 1: HEAD already an ancestor of origin/staging ───────
  # Fast-path: catches true-merge / fast-forward / re-push of an already-pushed
  # HEAD. NOT effective after squash-merge (squash yields a new commit). Fail-open.
  local pr_url="" _skip_pr_create=0
  if ! git -C "$worktree_path" fetch origin staging 2>/dev/null; then
    _route_admission_block "$story_id" "$trace_id" final blocked:base_fetch_failed
    return 1
  fi
  if [[ "$(git -C "$worktree_path" rev-parse origin/staging 2>/dev/null)" != "$GAAI_ADMITTED_BASE_SHA" ]]; then
    _route_admission_block "$story_id" "$trace_id" final blocked:stale_evidence
    return 1
  fi
  if git -C "$worktree_path" merge-base --is-ancestor HEAD origin/staging 2>/dev/null; then
    echo "[INFO] ${story_id} handle_commit_phase: Guard 1 — HEAD is ancestor of origin/staging — skipping gh pr create"
    pr_url=$(gh pr list --state all --head "$branch" --json url --jq '.[0].url' 2>/dev/null || true)
    [[ "$pr_url" == "null" ]] && pr_url=""
    _skip_pr_create=1
  fi

  # ── Idempotency Guard 2: existing PR in any state (squash-merge safe) ─────
  # Decisive idempotency guard: gh retains headRefName on merged/closed PRs even
  # after branch deletion; recreated story/<id> branch matches historical PR.
  if [[ "$_skip_pr_create" -eq 0 ]]; then
    local _g2_url
    _g2_url=$(gh pr list --state all --head "$branch" --json url --jq '.[0].url' 2>/dev/null || true)
    if [[ -n "$_g2_url" && "$_g2_url" != "null" ]]; then
      pr_url="$_g2_url"
      _skip_pr_create=1
      echo "[INFO] ${story_id} handle_commit_phase: Guard 2 — PR already exists ($pr_url) — skipping gh pr create"
    fi
  fi

  # ── PR-state guard: never merge a CLOSED or MERGED PR (AC1-AC4) ──────────
  # Guard 1/2 use --state all and may select a historical CLOSED or MERGED PR
  # on a recreated story/<id> branch. Re-read the selected PR's state before
  # proceeding to the exact-head merge. Mirrors the pattern at L154-160
  # (reap_orphaned_worktrees).
  if [[ "$_skip_pr_create" -eq 1 && -n "$pr_url" ]]; then
    local _selected_pr_state
    _selected_pr_state=$(gh pr view "$pr_url" --json state --jq .state 2>/dev/null || echo "OPEN")
    case "$_selected_pr_state" in
      OPEN)
        :  # nominal path — fall through to exact-head merge
        ;;
      MERGED)
        # AC3: PR already merged (including squash-merge, which Guard 1 misses)
        echo "[INFO] ${story_id} handle_commit_phase: selected PR ($pr_url) is MERGED — reconciling to done without merge"
        _journal_persist_lifecycle "$story_id" dispatch.commit \
          pr_status merged phase_status done status done || return 1
        _emit_commit_routing_record "$story_id" "$trace_id" "daemon-bash" "null" "0" "$pr_url" "false"
        return 0
        ;;
      CLOSED)
        # AC2: CLOSED and not merged — clear guard, fall through to gh pr create fresh PR
        echo "[INFO] ${story_id} handle_commit_phase: selected PR ($pr_url) is CLOSED (unmerged) — clearing guard, opening fresh PR"
        pr_url=""
        _skip_pr_create=0
        ;;
      *)
        # Unknown state (gh API evolution) — treat as OPEN; conservative, lets existing
        # AUTO_MERGE_FAILED handling deal with it rather than silently dropping the merge.
        echo "[WARN] ${story_id} handle_commit_phase: unknown PR state '${_selected_pr_state}' for $pr_url — treating as OPEN"
        ;;
    esac
  fi

  # ── gh pr create with retry (AC3 + AC5-b/c/d fallback) ───────────────────
  local pr_exit=1 pr_attempt=0 pr_max=3 pr_output
  if [[ "$_skip_pr_create" -eq 0 ]]; then
    while [[ $pr_attempt -lt $pr_max ]]; do
      pr_attempt=$(( pr_attempt + 1 ))
      pr_output=$(gh pr create \
        --title "$pr_title" \
        --body  "$pr_body" \
        --base  "staging" \
        --head  "$branch" 2>&1)
      pr_exit=$?

      if [[ "$pr_exit" -eq 0 ]]; then
        pr_url=$(printf '%s\n' "$pr_output" | grep -E '^https://' | tail -1 || true)
        break
      fi

      # AC5-b: auth missing → immediate failed, no retry
      if printf '%s\n' "$pr_output" | grep -qiE 'GH_TOKEN|authentication|gh auth login|not logged in'; then
        local _stderr_tail="${pr_output: -200}"
        echo "[ERROR] ${story_id} handle_commit_phase: GH auth missing — run 'gh auth login' or set GH_TOKEN. detail: ${_stderr_tail} [class=GH_AUTH_MISSING]"
        _emit_commit_routing_record "$story_id" "$trace_id" "error" "GH_AUTH_MISSING" "0" "" "false"
        _journal_persist_lifecycle "$story_id" dispatch.commit phase_status failed || return 1
        return 1
      fi

      # AC5-c: already exists → fallback to gh pr view
      if printf '%s\n' "$pr_output" | grep -qi "already exists"; then
        pr_url=$(gh pr view "$branch" --json url --jq .url 2>/dev/null || true)
        if [[ -n "$pr_url" ]]; then
          echo "[INFO] ${story_id} handle_commit_phase: PR already exists, using existing URL: $pr_url"
          pr_exit=0; break
        fi
      fi

      echo "[WARN] ${story_id} handle_commit_phase: gh pr create attempt ${pr_attempt}/${pr_max} failed: ${pr_output: -200}"
      [[ $pr_attempt -lt $pr_max ]] && sleep 3
    done

    if [[ "$pr_exit" -ne 0 ]]; then
      echo "[ERROR] ${story_id} handle_commit_phase: gh pr create failed after ${pr_max} attempts [class=PR_CREATE_FAILED]"
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "PR_CREATE_FAILED" "0" "" "false"
      return 1
    fi
  fi  # end _skip_pr_create guard

  # ── Persist pr_url + pr_number (AC2) ─────────────────────────────────────
  # Resolve metadata from the exact selected URL, not from the head branch:
  # one branch can have PRs to multiple bases, and the merge endpoint must be
  # identity-bound to the same PR that the CI gate observed. Persist before
  # merge so the PR watcher can reconcile the durable server-side result.
  if [[ -n "$pr_url" ]]; then
    local pr_number
    pr_number=$(gh pr view "$pr_url" --json number --jq .number 2>/dev/null || true)
    if [[ -n "$pr_number" ]]; then
      _journal_persist_lifecycle "$story_id" dispatch.commit \
        pr_url "$pr_url" pr_number "$pr_number" || return 1
    else
      _journal_persist_lifecycle "$story_id" dispatch.commit pr_url "$pr_url" || return 1
    fi
  fi

  # ── Base-held current hosted authority (controller-first, fail closed) ────
  local authority_human_required=false commit_outcome="null"
  if ! declare -F _run_merge_test_gate >/dev/null 2>&1; then
    TEST_GATE_OUTCOME="blocked:github_unavailable"
    echo "[ERROR] ${story_id} handle_commit_phase: hosted merge authority controller is unavailable [class=TEST_GATE_BLOCKED]"
    declare -F notify_escalation_inline >/dev/null 2>&1 && \
      notify_escalation_inline "$story_id" "$TEST_GATE_OUTCOME" "Hosted merge authority controller unavailable for ${pr_url}"
    _emit_commit_routing_record "$story_id" "$trace_id" "error" "$TEST_GATE_OUTCOME" "0" "$pr_url" "false"
    return 1
  fi
  local gate_rc=0
  _run_merge_test_gate "$story_id" "$worktree_path" "$qa_report_path" "$pr_url" "$pushed_head_sha" || gate_rc=$?
  if [[ "$gate_rc" -eq 2 ]]; then
    authority_human_required=true
    commit_outcome="$TEST_GATE_OUTCOME"
    declare -F notify_escalation_inline >/dev/null 2>&1 && \
      notify_escalation_inline "$story_id" "$TEST_GATE_OUTCOME" "Human review required for ${pr_url}"
  elif [[ "$gate_rc" -ne 0 ]] && _test_gate_outcome_is_deterministic "$TEST_GATE_OUTCOME"; then
    # Circuit breaker: the base-held policy and the live GitHub identity
    # disagree, so re-observing this candidate can only return the same
    # outcome. Leaving the durable qa_passed phase in place would let RECOVERY
    # re-launch the wrapper on every scan, and each re-launch re-pushes the
    # candidate and buys another complete hosted run. The bounded-death counter
    # cannot contain that: it resets whenever the worktree HEAD moves, which the
    # re-push itself causes. Stall for the operator instead of spending hosted
    # minutes on an outcome that is already decided.
    echo "[ERROR] ${story_id} handle_commit_phase: ${TEST_GATE_OUTCOME} cannot be resolved by retry; stalling for the operator [class=TEST_GATE_POLICY_MISMATCH]"
    local stall_persistence_mode="none" stall_marker
    stall_marker=$(_commit_policy_stall_marker_path "$story_id")
    if _journal_persist_lifecycle "$story_id" dispatch.commit phase_status commit_stalled; then
      stall_persistence_mode="backlog"
    elif _write_commit_policy_stall_marker "$story_id" "$TEST_GATE_OUTCOME"; then
      stall_persistence_mode="marker"
      echo "[WARN] ${story_id} handle_commit_phase: scheduler mutation failed; durable recovery inhibit published at ${stall_marker}"
    else
      echo "[ERROR] ${story_id} handle_commit_phase: STALL_PERSISTENCE_FAILED — neither backlog nor recovery marker is durable; stop the daemon and repair state before any restart"
    fi
    declare -F notify_escalation_inline >/dev/null 2>&1 && \
      notify_escalation_inline "$story_id" "$TEST_GATE_OUTCOME" \
        "Hosted merge authority disagrees with the base-held policy for ${pr_url}. Persistence=${stall_persistence_mode}. Retrying cannot resolve it: reconcile the policy with the live repository; if present remove ${stall_marker}; then reset phase_status to qa_passed."
    _emit_commit_routing_record "$story_id" "$trace_id" "error" "$TEST_GATE_OUTCOME" "0" "$pr_url" "false"
    return 1
  elif [[ "$gate_rc" -ne 0 ]]; then
    # Preserve the pre-cutover commit-phase lifecycle: a hosted observation
    # block stops this wrapper with the exact reason, but does not convert a
    # technical timeout or GitHub outage into a failed-quality verdict. The
    # durable qa_passed phase remains available to the existing recovery path.
    declare -F notify_escalation_inline >/dev/null 2>&1 && \
      notify_escalation_inline "$story_id" "$TEST_GATE_OUTCOME" "Hosted merge authority blocked ${pr_url}"
    _emit_commit_routing_record "$story_id" "$trace_id" "error" "$TEST_GATE_OUTCOME" "0" "$pr_url" "false"
    return 1
  fi
  [[ -n "$TEST_GATE_AUTH_PR_NUMBER" ]] && pr_number="$TEST_GATE_AUTH_PR_NUMBER"

  # ── Trailer killswitch verification (AC3-i) ───────────────────────────────
  local trailer_killswitch=false
  if git -C "$worktree_path" log -1 --format=%B HEAD 2>/dev/null | grep -qE '^\[skip-auto-merge\]$'; then
    trailer_killswitch=true
  fi

  # ── Auto-merge policy resolution (AC3) ───────────────────────────────────
  local auto_merge_applied auto_merge_skipped_reason
  IFS='|' read -r auto_merge_applied auto_merge_skipped_reason \
    <<<"$(_resolve_auto_merge_policy "$story_auto_merge" "$trailer_killswitch" "$authority_human_required")"

  # ── Apply daemon-authorized merge if resolved (AC3) ──────────────────────
  if [[ "$auto_merge_applied" == "true" ]] && [[ -n "$pr_url" ]]; then
    local merge_exit=1
    _merge_exact_pr_head_capture "$story_id" "$pr_url" "$pr_number" "$pushed_head_sha"
    merge_exit=$?
    if [[ "$merge_exit" -eq 2 ]]; then
      echo "[ERROR] ${story_id} handle_commit_phase: PR head moved during merge; refusing authorization [class=TEST_GATE_BLOCKED]"
      _journal_persist_lifecycle "$story_id" dispatch.commit phase_status failed || return 1
      if declare -F notify_escalation_inline >/dev/null 2>&1; then
        notify_escalation_inline "$story_id" "test_gate_head_moved" \
          "PR head no longer matches tested commit ${pushed_head_sha} for ${pr_url}"
      fi
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "TEST_GATE_BLOCKED" "0" "$pr_url" "false"
      return 1
    elif [[ "$merge_exit" -eq 3 ]]; then
      echo "[ERROR] ${story_id} handle_commit_phase: blocked:stale_base during final merge recheck [class=TEST_GATE_BLOCKED]"
      _journal_persist_lifecycle "$story_id" dispatch.commit phase_status failed || return 1
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "blocked:stale_base" "0" "$pr_url" "false"
      return 1
    elif [[ "$merge_exit" -eq 4 ]]; then
      echo "[ERROR] ${story_id} handle_commit_phase: ${MERGE_EXACT_OUTCOME} during final merge recheck [class=TEST_GATE_BLOCKED]"
      _journal_persist_lifecycle "$story_id" dispatch.commit phase_status failed || return 1
      _emit_commit_routing_record "$story_id" "$trace_id" "error" "$MERGE_EXACT_OUTCOME" "0" "$pr_url" "false"
      return 1
    fi
    if [[ "$merge_exit" -ne 0 ]]; then
      # Probe for CONFLICTING/DIRTY — attempt deterministic auto-resolve before escalating
      if [[ -n "$pr_url" ]] && gh pr view "$pr_url" --json mergeable,mergeStateStatus 2>/dev/null \
           | grep -qE '"mergeable":"CONFLICTING"|"mergeStateStatus":"DIRTY"'; then
        if _auto_resolve_pr_conflicts "$pr_url" "$branch" "$worktree_path" "$story_id" "$trace_id"; then
          # Conflict resolution creates and pushes a new merge commit. Treat it
          # as a new candidate: resolve its identity and gate that exact SHA
          # before making the final, atomically head-matched merge attempt.
          local resolved_head_sha
          resolved_head_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || true)
          if [[ ! "$resolved_head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "[ERROR] ${story_id} handle_commit_phase: resolved PR head SHA could not be resolved [class=PUSH_FAILED]"
            _emit_commit_routing_record "$story_id" "$trace_id" "error" "PUSH_FAILED" "0" "$pr_url" "false"
            return 1
          fi
          if ! declare -F _run_merge_test_gate >/dev/null 2>&1; then
            TEST_GATE_OUTCOME="blocked:github_unavailable"
            echo "[ERROR] ${story_id} handle_commit_phase: hosted merge authority controller disappeared before resolved-head recheck [class=TEST_GATE_BLOCKED]"
            _emit_commit_routing_record "$story_id" "$trace_id" "error" "$TEST_GATE_OUTCOME" "0" "$pr_url" "false"
            return 1
          fi
          local resolved_gate_rc=0
          _run_merge_test_gate "$story_id" "$worktree_path" "$qa_report_path" \
            "$pr_url" "$resolved_head_sha" || resolved_gate_rc=$?
          if [[ "$resolved_gate_rc" -eq 2 ]]; then
            authority_human_required=true
            auto_merge_applied=false
            auto_merge_skipped_reason=trust_surface_changed
            commit_outcome="$TEST_GATE_OUTCOME"
            merge_exit=0
            declare -F notify_escalation_inline >/dev/null 2>&1 && \
              notify_escalation_inline "$story_id" "$TEST_GATE_OUTCOME" \
                "Human review required for conflict-resolved ${pr_url}"
          elif [[ "$resolved_gate_rc" -ne 0 ]]; then
            echo "[ERROR] ${story_id} handle_commit_phase: resolved head failed merge test gate: ${TEST_GATE_OUTCOME} [class=TEST_GATE_BLOCKED]"
            _emit_commit_routing_record "$story_id" "$trace_id" "error" "$TEST_GATE_OUTCOME" "0" "$pr_url" "false"
            return 1
          else
            pr_number="$TEST_GATE_AUTH_PR_NUMBER"
          fi
          pushed_head_sha="$resolved_head_sha"

          # Resolved and re-gated: use the same retry, durable verification,
          # moved-head handling, and optional admin fallback as the initial SHA.
          local resolve_merge_exit=0
          if [[ "$authority_human_required" != "true" ]]; then
            _merge_exact_pr_head_capture "$story_id" "$pr_url" "$pr_number" "$pushed_head_sha"
            resolve_merge_exit=$?
          fi
          if [[ "$resolve_merge_exit" -eq 0 ]]; then
            merge_exit=0  # fall through to post-merge path below
          elif [[ "$resolve_merge_exit" -eq 2 ]]; then
            echo "[ERROR] ${story_id} handle_commit_phase: PR head moved after conflict resolution [class=TEST_GATE_BLOCKED]"
            _journal_persist_lifecycle "$story_id" dispatch.commit phase_status failed || return 1
            if declare -F notify_escalation_inline >/dev/null 2>&1; then
              notify_escalation_inline "$story_id" "test_gate_head_moved" \
                "PR head no longer matches re-tested commit ${pushed_head_sha} for ${pr_url}"
            fi
            _emit_commit_routing_record "$story_id" "$trace_id" "error" "TEST_GATE_BLOCKED" "0" "$pr_url" "false"
            return 1
          elif [[ "$resolve_merge_exit" -eq 3 || "$resolve_merge_exit" -eq 4 ]]; then
            echo "[ERROR] ${story_id} handle_commit_phase: resolved head failed final live tuple recheck: ${MERGE_EXACT_OUTCOME} [class=TEST_GATE_BLOCKED]"
            _journal_persist_lifecycle "$story_id" dispatch.commit phase_status failed || return 1
            _emit_commit_routing_record "$story_id" "$trace_id" "error" "$MERGE_EXACT_OUTCOME" "0" "$pr_url" "false"
            return 1
          else
            echo "[ERROR] ${story_id} handle_commit_phase: exact-head merge failed after resolve [class=AUTO_MERGE_FAILED]"
            _emit_commit_routing_record "$story_id" "$trace_id" "error" "AUTO_MERGE_FAILED" "0" "$pr_url" "false"
            _journal_persist_lifecycle "$story_id" dispatch.commit phase_status escalated || return 1
            return 1
          fi
        else
          # auto-resolve aborted or exhausted: escalate (NOT failed)
          _journal_persist_lifecycle "$story_id" dispatch.commit phase_status escalated || return 1
          return 1
        fi
      fi
      if [[ "$merge_exit" -ne 0 ]]; then
        # Non-conflict failure (network, rate-limit, branch protection).
        echo "[ERROR] ${story_id} handle_commit_phase: exact-head merge failed [class=AUTO_MERGE_FAILED]"
        _emit_commit_routing_record "$story_id" "$trace_id" "error" "AUTO_MERGE_FAILED" "0" "$pr_url" "false"
        _journal_persist_lifecycle "$story_id" dispatch.commit phase_status escalated || return 1
        return 1
      fi
    fi
  fi

  # ── Persist terminal metadata and lifecycle as one journal batch ─────────
  local pr_status_val
  [[ "$auto_merge_applied" == "true" ]] && pr_status_val="merged" || pr_status_val="pending_review"
  if ! _journal_persist_lifecycle "$story_id" dispatch.commit \
      pr_status "$pr_status_val" phase_status done status done; then
    echo "[ERROR] ${story_id} handle_commit_phase: durable terminal projection failed [class=SCHEDULER_FAILURE]"
    _emit_commit_routing_record "$story_id" "$trace_id" "error" "SCHEDULER_FAILURE" "0" "$pr_url" "$auto_merge_applied"
    return 1
  fi

  # ── Post-delivery autonomous triage (AC2, AC3, AC4, AC5) ─────────────────
  # Primary hook: fires unconditionally on both auto-merge and pending-review paths.
  # Secondary hooks in pr-watcher + recovery are idempotent via per-story marker.
  TRIAGE_RESULT="no triage — reason: no_delta"
  _run_triage_for_story "$story_id" || true
  echo "[TRIAGE] ${story_id} result: ${TRIAGE_RESULT}"

  # ── Worktree cleanup post-merge: only when PR actually merged. ────────────
  # Pending-review PRs keep the worktree alive so manual review/edits can land.
  if [[ "$auto_merge_applied" == "true" && -d "$worktree_path" ]]; then
    if git -C "$PROJECT_DIR" worktree remove --force "$worktree_path" 2>/dev/null; then
      echo "[INFO] ${story_id} handle_commit_phase: worktree removed post-merge ($worktree_path)"
    else
      echo "[WARN] ${story_id} handle_commit_phase: worktree remove failed (will be pruned next cycle)"
    fi
    git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
  fi

  # ── Duration end ─────────────────────────────────────────────────────────
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t_end_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 ))
  else
    t_end_ms=$(( $(date +%s) * 1000 ))
  fi
  duration_ms=$(( t_end_ms - t_start_ms ))

  # ── Emit success routing record ────────────────────────────────────────────
  if ! _emit_commit_routing_record "$story_id" "$trace_id" "daemon-bash" \
      "$commit_outcome" "$duration_ms" "$pr_url" "$auto_merge_applied"; then
    echo "[ERROR] $story_id handle_commit_phase: terminal routing persistence failed [class=ROUTING_PERSISTENCE_FAILED]"
    return 1
  fi

  ts=$(date '+%H:%M:%S')
  echo "[${ts}] ${story_id} phase=commit DONE (${duration_ms}ms) pr=${pr_url:-none} auto_merge=${auto_merge_applied}"
  return 0
}

# ── Main dispatcher (AC1 + AC6) ───────────────────────────────────────────
#
# Called by delivery-daemon.sh main loop for stories with delivery_pipeline=3phase.
# Reads phase_status, routes to the appropriate handler for ONE phase, then returns.
# The caller loops until phase_status is done/failed/escalated.
#
# Arguments: story_id [trace_id]
# Returns: 0 on success, 1 on dispatch error (logs [ERROR] per AC6)
dispatch_3phase_story() {
  local story_id="$1"
  local trace_id="${2:-$(python3 -c 'import uuid; print(str(uuid.uuid4()))' 2>/dev/null || echo "stub-$(date +%s)-$$")}"

  if [[ "${GAAI_DISPATCH_IDENTITY_GUARD:-legacy_direct}" == required ]]; then
    if ! _dispatch_expected_target_guard "$story_id" \
        "${GAAI_EXPECTED_TARGET_SOURCE:-}" "${GAAI_EXPECTED_TARGET_BLOB:-}" \
        "${GAAI_EXPECTED_TARGET_RECORD:-}"; then
      echo "[ERROR] ${story_id} dispatch_3phase_story: target identity changed" >&2
      return 3
    fi
  fi

  # Read phase_status (AC1 — awk extractor)
  local ps
  ps=$(get_phase_status "$story_id")

  if [[ -z "$ps" ]]; then
    # AC6(i): log ERROR
    echo "[ERROR] ${story_id} dispatch_3phase_story: phase_status field missing or empty"
    # AC6(iv): emit error routing record
    _emit_routing_record "$story_id" "$trace_id" "plan" "error" "phase_status_missing"
    # AC6(ii): return non-zero (caller loop will break)
    return 1
  fi

  # A crash can leave the prior transition emitted but not yet verified.  Retry
  # that exact run before currentness checks or phase handlers; on success the
  # wrapper loop re-enters against the newly reflected remote state.  This
  # prevents duplicate model spend while persistence is unavailable.
  local _pending_writer _pending_rc
  for _pending_writer in dispatch.plan dispatch.impl dispatch.qa dispatch.commit dispatch.reconcile; do
    if [[ ! -e "$LOCK_DIR/.journal-runs/${_pending_writer}.${story_id}.state" ]]; then
      [[ -L "$LOCK_DIR/.journal-runs/${_pending_writer}.${story_id}.state" ]] || continue
    fi
    _pending_rc=0
    _journal_resume_pending_lifecycle "$story_id" "$_pending_writer" || _pending_rc=$?
    if [[ $_pending_rc -eq 2 ]]; then
      continue
    elif [[ $_pending_rc -ne 0 ]]; then
      echo "[ERROR] ${story_id} dispatch: pending lifecycle projection remains blocked writer=${_pending_writer}"
      return 1
    fi
    return 0
  done

  # ── DEC-200 D7 / E1096S02 AC2 currentness gate ────────────────────────────
  # The one choke point both the live wrapper loop and every cross-cycle
  # relaunch (crash_recovery_scan -> launch_3phase_in_tmux -> wrapper's own
  # while loop) funnel through on every dispatch step. A non-terminal Story
  # sitting at qa_passed/qa_failed without a two-axis sidecar (legacy report,
  # or an in-flight cutover artifact) can never coast through on old Markdown
  # prose — QA reruns THIS SAME cycle by rewinding to implemented, not next poll.
  if [[ "$ps" == "qa_passed" || "$ps" == "qa_failed" ]]; then
    local _cur_wt _cur_sidecar
    if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
      _cur_wt="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
    else
      _cur_wt="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." 2>/dev/null && pwd)/.gaai-worktrees/$(basename "${REPO_ROOT:-$PROJECT_DIR}")/${story_id}-workspace"
    fi
    _cur_sidecar="${_cur_wt}/.gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-verdict.json"
    if [[ ! -s "$_cur_sidecar" ]]; then
      echo "[$(date '+%H:%M:%S')] ${story_id} dispatch: phase_status=${ps} lacks two-axis sidecar — currentness rerun (DEC-200 D7)"
      if _journal_persist_lifecycle "$story_id" dispatch.qa phase_status implemented; then
        _emit_routing_record "$story_id" "$trace_id" "qa" "rerun" "QA_CURRENTNESS_RERUN" 2>/dev/null || true
        ps="implemented"
      else
        echo "[ERROR] ${story_id} dispatch: durable phase_status=implemented projection failed during currentness rerun"
        return 1
      fi
    fi
  fi

  case "$ps" in
    not_started)
      _write_active_marker "$story_id" "plan"
      handle_plan_phase "$story_id" "$trace_id"
      local _plan_rc=$?
      _remove_active_marker "$story_id" "plan"
      [[ $_plan_rc -ne 0 ]] && return 1
      ;;
    planned)
      _write_active_marker "$story_id" "impl"
      handle_impl_phase "$story_id" "$trace_id"
      local _impl_rc=$?
      _remove_active_marker "$story_id" "impl"
      [[ $_impl_rc -ne 0 ]] && return 1
      ;;
    implemented)
      _write_active_marker "$story_id" "qa"
      handle_qa_phase "$story_id" "$trace_id"
      local _qa_rc=$?
      _remove_active_marker "$story_id" "qa"
      [[ $_qa_rc -ne 0 ]] && return 1
      ;;
    qa_passed)
      _write_active_marker "$story_id" "commit"
      handle_commit_phase "$story_id" "$trace_id"
      local _commit_rc=$?
      _remove_active_marker "$story_id" "commit"
      [[ $_commit_rc -ne 0 ]] && return 1
      ;;
    qa_failed)
      # ── Retry-loop : QA FAIL → re-PLAN or re-IMPL with qa-report context ──
      # DEC-200 D5 root-cause routing: the resolver-derived route persisted by
      # handle_qa_phase's FAIL branch (${LOCK_DIR}/.qa-route-${story_id})
      # selects PLAN or IMPL remediation, each with its OWN independent
      # bounded counter (AC4) — a replan neither consumes nor resets the IMPL
      # retry counter, and vice versa. If a route's cap is exhausted, escalate
      # to qa_escalated for human triage. Without this block, the wrapper
      # exits at qa_failed and the story ghosts in_progress until daemon
      # restart (the main poll loop ignores in_progress ; recovery at restart
      # just re-spawns the wrapper which would re-hit the same terminal state).
      #
      # Counters live per-story at ${LOCK_DIR}/.qa-retries-${story_id} (IMPL)
      # and ${LOCK_DIR}/.qa-replans-${story_id} (PLAN) as single integer
      # lines — both intentionally distinct from the daemon main-loop's
      # wrapper-launch retry counter. They persist across wrapper relaunches
      # and are cleaned up on terminal transitions (qa_escalated branch here ;
      # done/failed branches in _reconcile_yaml_status_on_exit).
      #
      # The qa-report path is exported as GAAI_QA_REPORT_PATH so the re-spawned
      # phase's prompt construction helper injects the prior QA findings as
      # fix-this-please context. GAAI_QA_INJECT_PHASE=plan additionally routes
      # it into the next PLAN invocation on the plan route only (impl route
      # leaves it unset, explicitly, in case a stale plan-route env leaked
      # from a prior cycle in the same wrapper process).
      local _qa_route_file="${LOCK_DIR}/.qa-route-${story_id}"
      local _qa_route="impl"
      if [[ -f "$_qa_route_file" ]]; then
        _qa_route=$(cat "$_qa_route_file" 2>/dev/null || echo impl)
        [[ "$_qa_route" == "plan" ]] || _qa_route="impl"
      fi
      local _qa_counter_file _qa_counter_max _qa_rewind_phase _qa_exhaust_reason _qa_reason_prefix
      if [[ "$_qa_route" == "plan" ]]; then
        _qa_counter_file="${LOCK_DIR}/.qa-replans-${story_id}"
        _qa_counter_max="${GAAI_QA_REPLAN_MAX:-2}"
        _qa_rewind_phase="not_started"
        _qa_exhaust_reason="QA_REPLAN_EXHAUSTED"
        _qa_reason_prefix="QA_REPLAN"
      else
        _qa_counter_file="${LOCK_DIR}/.qa-retries-${story_id}"
        _qa_counter_max="${GAAI_QA_RETRY_MAX:-3}"
        _qa_rewind_phase="planned"
        _qa_exhaust_reason="QA_RETRY_EXHAUSTED"
        _qa_reason_prefix="QA_RETRY"
      fi
      local _qa_counter_count=0
      if [[ -f "$_qa_counter_file" ]]; then
        _qa_counter_count=$(cat "$_qa_counter_file" 2>/dev/null || echo 0)
        [[ "$_qa_counter_count" =~ ^[0-9]+$ ]] || _qa_counter_count=0
      fi
      if (( _qa_counter_count >= _qa_counter_max )); then
        echo "[$(date '+%H:%M:%S')] ${story_id} dispatch: QA ${_qa_route} cap reached (${_qa_counter_count}/${_qa_counter_max}) — escalating qa_failed -> qa_escalated"
        if _journal_persist_lifecycle "$story_id" dispatch.qa phase_status qa_escalated; then
          _emit_routing_record "$story_id" "$trace_id" "qa" "error" "$_qa_exhaust_reason" 2>/dev/null || true
        else
          echo "[ERROR] ${story_id} dispatch: durable phase_status=qa_escalated projection failed"
        fi
        # Wire the escalation to the existing notification machinery (terminal bell +
        # macOS osascript + webhook+HMAC). Helper is best-effort, never blocks.
        if declare -F notify_escalation_inline >/dev/null 2>&1; then
          notify_escalation_inline "$story_id" \
            "QA ${_qa_route} cap reached (${_qa_counter_count}/${_qa_counter_max})" \
            "Review .gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-report.md and either fix manually or re-refine the story"
        fi
        rm -f "$_qa_counter_file" "$_qa_route_file" 2>/dev/null || true
        # Cross-cycle outcome metric — emit when escalated after cross-cycle route
        if [[ -n "${GAAI_QA_INJECT_PHASE_SNAPSHOT:-}" ]]; then
          local _cc_cycle_n=${_qa_counter_count:-0}
          local _cc_outcome_json="{\"sid\":\"${story_id}\",\"cycle_n\":${_cc_cycle_n},\"routed_phase\":\"${GAAI_QA_INJECT_PHASE_SNAPSHOT}\",\"outcome\":\"qa_escalated\",\"marker_honor_rate\":$(_compute_marker_honor_rate "$story_id" "${GAAI_WORKTREE_PATH:-${worktree_path}}" "${GAAI_QA_INJECT_PHASE_SNAPSHOT}")}"
          printf '%s\n' "$_cc_outcome_json" >> "${LOG_DIR}/cross-cycle-outcomes.jsonl" 2>/dev/null || true
        fi
        return 0
      fi
      # Increment counter via atomic temp-rename (no sed dependency, no shared helper).
      _qa_counter_count=$((_qa_counter_count + 1))
      local _qa_counter_tmp="${_qa_counter_file}.tmp.$$"
      printf '%s\n' "$_qa_counter_count" > "$_qa_counter_tmp" 2>/dev/null \
        && mv "$_qa_counter_tmp" "$_qa_counter_file" 2>/dev/null \
        || rm -f "$_qa_counter_tmp" 2>/dev/null
      # Resolve worktree path (mirrors handle_impl_phase formula).
      local _wt_path _wt_parent _wt_repo
      if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
        _wt_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
      else
        _wt_repo=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
        if _wt_parent=$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." 2>/dev/null && pwd); then
          _wt_path="${_wt_parent}/.gaai-worktrees/${_wt_repo}/${story_id}-workspace"
        else
          echo "[ERROR] ${story_id} dispatch: cannot resolve worktree parent dir for qa-report path — retry aborted"
          return 1
        fi
      fi
      export GAAI_QA_REPORT_PATH="${_wt_path}/.gaai/project/contexts/artefacts/qa-reports/${story_id}.qa-report.md"
      if [[ "$_qa_route" == "plan" ]]; then
        export GAAI_QA_INJECT_PHASE=plan
      else
        unset GAAI_QA_INJECT_PHASE 2>/dev/null || true
      fi
      # Emit retry routing record BEFORE rewinding phase_status so the qa_failed
      # state itself is preserved in the routing trace for forensic post-mortem.
      _emit_routing_record "$story_id" "$trace_id" "qa" "retry" "${_qa_reason_prefix}_${_qa_counter_count}" 2>/dev/null || true
      # Rewind phase_status so the next outer-loop iteration re-enters PLAN
      # (not_started, full fresh replan) or IMPL (planned, unchanged from
      # before this Story). The re-spawned phase picks up the qa-report via
      # GAAI_QA_REPORT_PATH (read by daemon-prompt-construct.sh).
      if ! _journal_persist_lifecycle "$story_id" dispatch.qa phase_status "$_qa_rewind_phase"; then
        echo "[ERROR] ${story_id} dispatch: durable phase_status=${_qa_rewind_phase} projection failed during retry"
        unset GAAI_QA_REPORT_PATH GAAI_QA_INJECT_PHASE
        return 1
      fi
      echo "[$(date '+%H:%M:%S')] ${story_id} dispatch: QA FAIL route=${_qa_route} — cycle ${_qa_counter_count}/${_qa_counter_max} (re-spawn will pick up qa-report context: ${GAAI_QA_REPORT_PATH})"
      return 0
      ;;
    commit_failed|worktree_recovery_failed)
      # These pre-journal compatibility values are not valid old states for a
      # journal edge. Fail closed instead of entering an implicit retry loop;
      # the operator must reset the row to qa_passed before cutover resumes.
      echo "[ERROR] ${story_id} dispatch: legacy phase_status=${ps} requires operator reset to qa_passed"
      _emit_routing_record "$story_id" "$trace_id" "commit" "error" \
        "legacy_phase_status_requires_reset:${ps}"
      return 1
      ;;
    done|failed|escalated|qa_escalated|commit_stalled)
      return 0
      ;;
    *)
      echo "[ERROR] ${story_id} dispatch_3phase_story: invalid phase_status='${ps}' — known values: not_started planned implemented qa_passed qa_failed qa_escalated commit_failed worktree_recovery_failed commit_stalled done failed escalated"
      _emit_routing_record "$story_id" "$trace_id" "plan" "error" "invalid_phase_status:${ps}"
      return 1
      ;;
  esac

  return 0
}

# Compute marker_honor_rate from KEEP-marked steps vs actual touched paths.
# Returns: JSON number (0.0-1.0), or null for IMPL route / no KEEP steps / not computable.
# Usage: _compute_marker_honor_rate <story_id> <worktree_path> <routed_phase>
_compute_marker_honor_rate() {
  local sid="$1" wt="$2" routed_phase="$3"

  # IMPL route — not applicable
  [[ "$routed_phase" != "plan" ]] && { printf 'null'; return 0; }

  local plan_path="${wt}/.gaai/project/contexts/artefacts/plans/${sid}.execution-plan.md"
  [[ ! -s "$plan_path" ]] && { printf 'null'; return 0; }

  # Extract file paths associated with KEEP steps (lines following ✓ KEEP markers)
  local keep_paths
  keep_paths=$(grep -A3 '✓ KEEP' "$plan_path" 2>/dev/null \
    | grep -oE '[A-Za-z0-9_/.-]+\.(sh|ts|js|md|yaml|yml|json|astro)' 2>/dev/null \
    | sort -u || true)
  [[ -z "$keep_paths" ]] && { printf 'null'; return 0; }

  # Get touched paths in worktree (HEAD vs base branch)
  local base_ref
  base_ref=$(git -C "$wt" rev-parse --verify origin/staging 2>/dev/null || echo "")
  if [[ -z "$base_ref" ]]; then
    base_ref=$(git -C "$wt" merge-base HEAD "$(git -C "$wt" rev-parse --verify main 2>/dev/null || echo HEAD)" 2>/dev/null || echo "")
  fi
  [[ -z "$base_ref" ]] && { printf 'null'; return 0; }

  local touched_paths
  touched_paths=$(git -C "$wt" diff --name-only "${base_ref}...HEAD" 2>/dev/null | sort -u || true)
  [[ -z "$touched_paths" ]] && { printf 'null'; return 0; }

  # Count KEEP paths that were NOT touched (honored = not modified)
  local total_keep=0 honored=0
  for kp in $keep_paths; do
    total_keep=$((total_keep + 1))
    if ! printf '%s\n' "$touched_paths" | grep -qx "$kp" 2>/dev/null; then
      honored=$((honored + 1))
    fi
  done

  (( total_keep == 0 )) && { printf 'null'; return 0; }

  # honor_rate = fraction of KEEP paths that were honored (not touched)
  # Using integer arithmetic: (honored * 100) / total_keep → divide by 100
  local rate_x100=$(( (honored * 100) / total_keep ))
  if (( rate_x100 == 100 )); then
    printf '1.0'
  elif (( rate_x100 == 0 )); then
    printf '0.0'
  else
    printf '0.%02d' "$(( rate_x100 % 100 ))"
  fi
}

# @see DEC-88 §3 (phase_status semantics — 3-phase pipeline owns phase_status transitions)
# @see E134S12 (chore-commit purity dependency — drift detection guard re-used, not re-implemented)
_reconcile_yaml_status_on_exit() {
  local story_id="$1"

  # Null-guards: all required exports must be set by the wrapper
  [[ -z "${BACKLOG_FILE:-}" || -z "${PROJECT_DIR:-}" || -z "${SCHEDULER:-}" || -z "${LOCK_DIR:-}" ]] && return 0

  # AC1: Create reconcile-in-progress marker before any YAML read or chore-commit.
  # Daemon's check_stale_in_progress honors this marker to skip staleness verdict during reconcile.
  # AC3: Fail-safe — if touch fails (disk full, read-only LOCK_DIR), log warning and
  # proceed without race protection. Degradation = same behavior as pre-feature. No crash.
  local _rip_marker="${LOCK_DIR}/${story_id}.reconcile-in-progress"
  if ! touch "$_rip_marker" 2>/dev/null; then
    echo "[WRAPPER-RECONCILE] $story_id : warning — could not create reconcile-in-progress marker (touch failed) — proceeding without race protection"
  fi

  local phase_status target_status

  phase_status=$(get_phase_status "$story_id" 2>/dev/null)

  # ── Plan-block detection (defense in depth) ─────────────────────────────
  # Plan agent writes {id}.plan-blocked.md to the worktree and exits
  # non-zero when scope-discipline thresholds are exceeded. The wrapper's
  # main dispatch loop returns early before the `--set-phase-status planned`
  # call, so phase_status remains "not_started". Without this pre-check, the
  # case statement below would no-op and the story ghosts as in_progress.
  #
  # Maps to target_status="failed" — already in the case table, OSS-clean,
  # no new state semantics introduced. Operator inspects {id}.plan-blocked.md
  # (preserved in artefacts) to drive decomposition before re-refining.
  #
  # Stale-marker guard: only fire when phase_status is not_started
  # AND no canonical execution-plan.md exists. A successful PLAN would have
  # produced execution-plan.md and advanced phase_status to "planned"; if
  # either is present, plan-blocked.md is from a prior attempt and stale.
  local _worktree_path _plan_blocked_path _exec_plan_path _repo_name _parent_dir
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    _worktree_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
  else
    _repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    if _parent_dir=$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." 2>/dev/null && pwd); then
      _worktree_path="${_parent_dir}/.gaai-worktrees/${_repo_name}/${story_id}-workspace"
    else
      _worktree_path=""
    fi
  fi
  _plan_blocked_path="${_worktree_path}/.gaai/project/contexts/artefacts/plans/${story_id}.plan-blocked.md"
  _exec_plan_path="${_worktree_path}/.gaai/project/contexts/artefacts/plans/${story_id}.execution-plan.md"

  if [[ -n "$_worktree_path" && -f "$_plan_blocked_path" \
        && "$phase_status" == "not_started" \
        && ! -f "$_exec_plan_path" ]]; then
    target_status="failed"
    phase_status="plan-blocked"  # for the final log line only
    echo "[WRAPPER-RECONCILE] $story_id : plan-blocked.md detected — reconciling status=failed (operator must decompose per plan-blocked.md inventory before re-refining)"
  else
    # Map phase_status → target top-level status
    case "$phase_status" in
      done)         target_status="done" ;;
      failed)       target_status="failed" ;;
      escalated)    target_status="escalated" ;;
      qa_escalated) target_status="escalated" ;;
      qa_failed)
        # No-op: retry-loop owns this transition
        rm -f "$_rip_marker" 2>/dev/null || true
        return 0
        ;;
      commit_failed|worktree_recovery_failed)
        # No-op: compatibility commit-phase retry states remain in_progress.
        rm -f "$_rip_marker" 2>/dev/null || true
        return 0
        ;;
      *)
        # Unknown or empty phase_status — no-op
        rm -f "$_rip_marker" 2>/dev/null || true
        return 0
        ;;
    esac
  fi

  if [[ "$phase_status" == "plan-blocked" ]]; then
    if ! _journal_persist_lifecycle "$story_id" dispatch.plan \
        phase_status failed status failed; then
      echo "[WRAPPER-RECONCILE] $story_id : durable plan-blocked reconciliation failed — evidence retained"
      return 1
    fi
  elif ! _journal_persist_lifecycle "$story_id" dispatch.reconcile status "$target_status"; then
    echo "[WRAPPER-RECONCILE] $story_id : durable status reconciliation failed — evidence retained"
    return 1
  fi
  echo "[WRAPPER-RECONCILE] $story_id : reconciled status=$target_status from phase_status=$phase_status"

  # Cleanup QA retry counter on terminal transitions — escalated already
  # cleaned in dispatch's cap-reached branch ; this handles done / failed
  # so stale counter files don't accumulate when a story finishes through
  # the happy path or a non-QA failure mode.
  case "$target_status" in
    done|failed|escalated)
      # Read counter before cleanup so cycle_n captures actual retry count
      local _cc_cycle_n=0
      if [[ -f "${LOCK_DIR}/.qa-retries-${story_id}" ]]; then
        _cc_cycle_n=$(cat "${LOCK_DIR}/.qa-retries-${story_id}" 2>/dev/null || echo 0)
      fi
      rm -f "${LOCK_DIR}/.qa-retries-${story_id}" 2>/dev/null || true
      # E1096S02 AC4: same lifecycle as .qa-retries — clean the independent
      # PLAN-route counter and the route marker on terminal transitions too.
      rm -f "${LOCK_DIR}/.qa-replans-${story_id}" "${LOCK_DIR}/.qa-route-${story_id}" 2>/dev/null || true
      # Cross-cycle outcome metric — emit on terminal transition after cross-cycle route
      if [[ -n "${GAAI_QA_INJECT_PHASE_SNAPSHOT:-}" ]]; then
        local _cc_outcome_json="{\"sid\":\"${story_id}\",\"cycle_n\":${_cc_cycle_n},\"routed_phase\":\"${GAAI_QA_INJECT_PHASE_SNAPSHOT}\",\"outcome\":\"${target_status}\",\"marker_honor_rate\":$(_compute_marker_honor_rate "$story_id" "${GAAI_WORKTREE_PATH:-${worktree_path}}" "${GAAI_QA_INJECT_PHASE_SNAPSHOT}")}"
        printf '%s\n' "$_cc_outcome_json" >> "${LOG_DIR}/cross-cycle-outcomes.jsonl" 2>/dev/null || true
      fi
      ;;
  esac

  rm -f "$_rip_marker" 2>/dev/null || true
}
