#!/usr/bin/env bash
# commit-retry-containment.sh — descriptor-bound commit retry event/state owner.
#
# This helper is the only code allowed to name, parse, publish or invalidate
# commit-retry observations and durable state. Callers receive closed facts;
# they never reopen an authenticated path or infer an event identity.

_COMMIT_RETRY_COMMON_PY='import hashlib
import json
import os
import re
import secrets
import stat

DIGEST_RE = re.compile(r"[0-9a-f]{64}")
OUTCOME_RE = re.compile(r"[A-Za-z0-9:._/-]{1,160}")
STORY_RE = re.compile(r"[A-Za-z][A-Za-z0-9._-]{0,63}")
TIME_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
STATE_KEYS = (
    "schema_version", "story_id", "count", "content_digest", "outcome",
    "stall_pending", "last_event_id", "last_event_digest",
    "last_classification",
)

def parent_fd(path):
    parent, name = os.path.split(path)
    if not parent or not name:
        raise ValueError
    before = os.lstat(parent)
    if (not stat.S_ISDIR(before.st_mode) or before.st_uid != os.geteuid()
            or before.st_mode & 0o077):
        raise ValueError
    fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                 | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(fd)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        os.close(fd)
        raise ValueError
    return fd, name, (opened.st_dev, opened.st_ino)

def read_once(path, required=False):
    fd = None
    directory = None
    try:
        directory, name, parent_identity = parent_fd(path)
        try:
            before = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            if required:
                raise ValueError
            os.close(directory)
            return None
        fd = os.open(
            name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory
        )
        opened = os.fstat(fd)
        after = os.stat(name, dir_fd=directory, follow_symlinks=False)
        identity = (opened.st_dev, opened.st_ino)
        if (not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.geteuid()
                or opened.st_mode & 0o077
                or identity != (before.st_dev, before.st_ino)
                or identity != (after.st_dev, after.st_ino)):
            raise ValueError
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return {"path": path, "name": name, "fd": fd, "dir_fd": directory,
                "parent_identity": parent_identity, "identity": identity,
                "bytes": b"".join(chunks)}
    except Exception:
        if fd is not None:
            os.close(fd)
        if directory is not None:
            os.close(directory)
        raise

def close_opened(opened):
    if opened:
        os.close(opened["fd"])
        os.close(opened["dir_fd"])

def publish(path, wire, previous=None, no_replace=False):
    directory, name, parent_identity = parent_fd(path)
    tmp_fd = None
    tmp = ".%s.%s.tmp" % (name, secrets.token_hex(16))
    try:
        tmp_fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory,
        )
        view = memoryview(wire)
        while view:
            written = os.write(tmp_fd, view)
            if written <= 0:
                raise OSError
            view = view[written:]
        os.fsync(tmp_fd)
        os.close(tmp_fd)
        tmp_fd = None
        if previous is not None and parent_identity != previous["parent_identity"]:
            raise ValueError
        if no_replace:
            os.link(tmp, name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
            os.unlink(tmp, dir_fd=directory)
        elif previous is None:
            os.link(tmp, name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
            os.unlink(tmp, dir_fd=directory)
        else:
            current = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != previous["identity"]:
                raise ValueError
            os.replace(tmp, name, src_dir_fd=directory, dst_dir_fd=directory)
        tmp = None
        os.fsync(directory)
    finally:
        if tmp_fd is not None:
            os.close(tmp_fd)
        if tmp is not None:
            try:
                os.unlink(tmp, dir_fd=directory)
            except OSError:
                pass
        os.close(directory)

def retire(opened):
    directory, name = opened["dir_fd"], opened["name"]
    quarantine = ".%s.%s.retire" % (name, secrets.token_hex(16))
    current = os.stat(name, dir_fd=directory, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != opened["identity"]:
        raise ValueError
    os.rename(name, quarantine, src_dir_fd=directory, dst_dir_fd=directory)
    moved = os.stat(quarantine, dir_fd=directory, follow_symlinks=False)
    if (moved.st_dev, moved.st_ino) != opened["identity"]:
        # A successor won the name between the identity check and rename. Put
        # those exact moved bytes back without overwriting any newer winner.
        # If the name is already occupied, quarantine remains as evidence.
        try:
            os.link(quarantine, name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
            restored = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if (restored.st_dev, restored.st_ino) != (moved.st_dev, moved.st_ino):
                raise ValueError
            os.fsync(directory)
            os.unlink(quarantine, dir_fd=directory)
            os.fsync(directory)
        except FileExistsError:
            os.fsync(directory)
        raise ValueError
    os.fsync(directory)
    os.unlink(quarantine, dir_fd=directory)
    os.fsync(directory)

def parse_event(opened, story):
    obj = json.loads(opened["bytes"].decode("ascii"))
    keys = {"event_id", "observed_at", "outcome", "schema_version", "story_id"}
    wire = (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
    if (set(obj) != keys or wire != opened["bytes"]
            or obj.get("schema_version") != "1.0.0"
            or obj.get("story_id") != story
            or not DIGEST_RE.fullmatch(obj.get("event_id", ""))
            or not TIME_RE.fullmatch(obj.get("observed_at", ""))
            or not OUTCOME_RE.fullmatch(obj.get("outcome", ""))):
        raise ValueError
    obj["digest"] = hashlib.sha256(opened["bytes"]).hexdigest()
    return obj

def state_wire(obj):
    return "".join("%s=%s\n" % (key, obj[key]) for key in STATE_KEYS).encode("ascii")

def parse_state(opened, story):
    lines = opened["bytes"].decode("ascii").splitlines()
    if len(lines) != len(STATE_KEYS):
        raise ValueError
    obj = {}
    for expected, line in zip(STATE_KEYS, lines):
        key, separator, value = line.partition("=")
        if separator != "=" or key != expected:
            raise ValueError
        obj[key] = value
    count = int(obj["count"])
    if (state_wire(obj) != opened["bytes"]
            or obj["schema_version"] != "1.0.0"
            or obj["story_id"] != story or count < 1 or count > 1000
            or not re.fullmatch(r"diff:[0-9a-f]{64}", obj["content_digest"])
            or not OUTCOME_RE.fullmatch(obj["outcome"])
            or obj["stall_pending"] not in {"0", "1"}
            or not DIGEST_RE.fullmatch(obj["last_event_id"])
            or not DIGEST_RE.fullmatch(obj["last_event_digest"])
            or obj["last_classification"] not in {
                "initial", "content_changed", "outcome_changed", "repeated"
            }):
        raise ValueError
    obj["count_int"] = count
    obj["digest"] = hashlib.sha256(opened["bytes"]).hexdigest()
    return obj
'

_commit_retry_story_valid() {
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]]
}

_commit_retry_state_path() {
  _commit_retry_story_valid "${1:-}" || return 1
  printf '%s/.commit-deaths-%s\n' "${LOCK_DIR:?}" "$1"
}

_commit_retry_observation_path() {
  _commit_retry_story_valid "${1:-}" || return 1
  printf '%s/.commit-retry-observation-%s\n' "${LOCK_DIR:?}" "$1"
}

_commit_retry_stall_marker_path() {
  _commit_retry_story_valid "${1:-}" || return 1
  printf '%s/.commit-retry-stalled-%s\n' "${LOCK_DIR:?}" "$1"
}

_commit_retry_sanitize_outcome() {
  local outcome="${1:-wrapper_exit_nonzero}"
  outcome=$(printf '%s' "$outcome" | tr '\r\n|' '___' \
    | LC_ALL=C sed 's/[^A-Za-z0-9:._\/-]/_/g' | LC_ALL=C cut -c1-160)
  printf '%s\n' "${outcome:-wrapper_exit_nonzero}"
}

_commit_retry_prepare_parent() {
  ( umask 077; mkdir -p "${LOCK_DIR:?}" ) 2>/dev/null || return 1
  python3 - "$LOCK_DIR" <<'PY'
import os, stat, sys
try:
    opened = os.lstat(sys.argv[1])
    if (not stat.S_ISDIR(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

_commit_retry_publish_record() {
  local kind="$1" path="$2" story_id="$3"
  shift 3
  _commit_retry_story_valid "$story_id" || return 1
  _commit_retry_prepare_parent || return 1
  python3 - "$_COMMIT_RETRY_COMMON_PY" "$kind" "$path" "$story_id" "$@" <<'PY'
import datetime, json, sys
exec(sys.argv[1])
kind, path, story, *values = sys.argv[2:]
if not STORY_RE.fullmatch(story):
    raise SystemExit(1)
if kind == "observation" and len(values) == 1:
    outcome = values[0]
    if not OUTCOME_RE.fullmatch(outcome):
        raise SystemExit(1)
    obj = {
        "event_id": secrets.token_hex(32),
        "observed_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "outcome": outcome,
        "schema_version": "1.0.0",
        "story_id": story,
    }
elif kind == "stall" and len(values) == 3:
    outcome, cycles_raw, threshold_raw = values
    try:
        cycles, threshold = int(cycles_raw), int(threshold_raw)
    except ValueError:
        raise SystemExit(1)
    if (not OUTCOME_RE.fullmatch(outcome) or cycles < 1 or threshold < 1
            or cycles < threshold):
        raise SystemExit(1)
    obj = {
        "created_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "cycles": cycles,
        "outcome": outcome,
        "schema_version": "1.0.0",
        "story_id": story,
        "threshold": threshold,
    }
else:
    raise SystemExit(1)
wire = (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
try:
    publish(path, wire, no_replace=True)
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

_commit_retry_write_observation() {
  local story_id="${1:-}" outcome path
  _commit_retry_story_valid "$story_id" || return 1
  outcome=$(_commit_retry_sanitize_outcome "${2:-}") || return 1
  path=$(_commit_retry_observation_path "$story_id") || return 1
  _commit_retry_publish_record observation "$path" "$story_id" "$outcome"
}

_commit_retry_write_stall_marker() {
  local story_id="${1:-}" outcome path
  _commit_retry_story_valid "$story_id" || return 1
  outcome=$(_commit_retry_sanitize_outcome "${2:-}") || return 1
  path=$(_commit_retry_stall_marker_path "$story_id") || return 1
  _commit_retry_publish_record stall "$path" "$story_id" "$outcome" \
    "${3:-}" "${4:-}"
}

_commit_retry_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

_commit_retry_content_digest() {
  local story_id="$1" worktree_path="$2" base_ref="$3" digest
  _commit_retry_story_valid "$story_id" || return 1
  digest=$(set -o pipefail; git -C "$worktree_path" diff \
    --binary --full-index --no-ext-diff --no-textconv \
    "${base_ref}...HEAD" -- . \
    ':(exclude).gaai/project/contexts/backlog/active.backlog.yaml' \
    ':(exclude).gaai/core/skills/skills-index.yaml' \
    ':(exclude).gaai/project/skills/skills-index.yaml' \
    ":(exclude,glob).gaai/project/contexts/artefacts/**/${story_id}.*" \
    2>/dev/null | _commit_retry_sha256_stdin) || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'diff:%s\n' "$digest"
}

# Fold one event into durable state. State is fsync-published before the exact
# event inode is invalidated. A restart retires a matching duplicate without
# incrementing again. The three-field output is the established public API.
_commit_retry_observe() {
  local story_id="${1:-}" worktree_path="${2:-}" base_ref="${3:-}"
  local threshold="${4:-${COMMIT_PHASE_RETRY_THRESHOLD:-3}}"
  local state event digest
  _commit_retry_story_valid "$story_id" || return 1
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || return 1
  (( threshold > 1000 )) && threshold=1000
  _commit_retry_prepare_parent || return 1
  state=$(_commit_retry_state_path "$story_id") || return 1
  event=$(_commit_retry_observation_path "$story_id") || return 1
  digest=$(_commit_retry_content_digest "$story_id" "$worktree_path" "$base_ref") \
    || return 1
  python3 - "$_COMMIT_RETRY_COMMON_PY" "$state" "$event" "$story_id" \
    "$digest" "$threshold" <<'PY'
import sys
exec(sys.argv[1])
state_path, event_path, story, content_digest, threshold_raw = sys.argv[2:]
try:
    threshold = int(threshold_raw)
    if (not STORY_RE.fullmatch(story)
            or not re.fullmatch(r"diff:[0-9a-f]{64}", content_digest)
            or threshold < 1 or threshold > 1000):
        raise ValueError
    state_open = read_once(state_path)
    event_open = read_once(event_path)
    previous = parse_state(state_open, story) if state_open else None
    event = parse_event(event_open, story) if event_open else None

    if previous and previous["stall_pending"] == "1":
        if content_digest != previous["content_digest"]:
            raise ValueError
        if event:
            if (event["event_id"] != previous["last_event_id"]
                    or event["digest"] != previous["last_event_digest"]
                    or event["outcome"] != previous["outcome"]):
                raise ValueError
            retire(event_open)
        print("%s|%s|stall_pending" % (previous["count"], previous["outcome"]))
    else:
        if event is None:
            if previous is None or content_digest != previous["content_digest"]:
                raise ValueError
            print("%s|%s|%s" % (
                previous["count"], previous["outcome"],
                previous["last_classification"],
            ))
        elif (previous and event["event_id"] == previous["last_event_id"]
                and event["digest"] == previous["last_event_digest"]):
            if event["outcome"] != previous["outcome"]:
                raise ValueError
            retire(event_open)
            print("%s|%s|%s" % (
                previous["count"], previous["outcome"],
                previous["last_classification"],
            ))
        else:
            if previous is None:
                count, classification = 1, "initial"
            elif content_digest != previous["content_digest"]:
                count, classification = 1, "content_changed"
            elif event["outcome"] != previous["outcome"]:
                count, classification = 1, "outcome_changed"
            else:
                count = min(previous["count_int"] + 1, 1000)
                classification = "repeated"
            next_state = {
                "schema_version": "1.0.0",
                "story_id": story,
                "count": str(count),
                "content_digest": content_digest,
                "outcome": event["outcome"],
                "stall_pending": "1" if count >= threshold else "0",
                "last_event_id": event["event_id"],
                "last_event_digest": event["digest"],
                "last_classification": classification,
            }
            publish(state_path, state_wire(next_state), previous=state_open)
            # A failed exact invalidation is non-authorizing. The durable state
            # lets the next run retire this same event without counting twice.
            retire(event_open)
            result = "stall_pending" if next_state["stall_pending"] == "1" else classification
            print("%s|%s|%s" % (count, event["outcome"], result))
except (OSError, ValueError, KeyError, TypeError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
finally:
    if "state_open" in locals():
        close_opened(state_open)
    if "event_open" in locals():
        close_opened(event_open)
PY
}

# count|outcome|classification|actual-event-digest|state-digest
_commit_retry_state_snapshot() {
  local story_id="${1:-}" state
  _commit_retry_story_valid "$story_id" || return 1
  state=$(_commit_retry_state_path "$story_id") || return 1
  python3 - "$_COMMIT_RETRY_COMMON_PY" "$state" "$story_id" <<'PY'
import sys
exec(sys.argv[1])
path, story = sys.argv[2:]
opened = None
try:
    opened = read_once(path, required=True)
    state = parse_state(opened, story)
    classification = (
        "stall_pending" if state["stall_pending"] == "1"
        else state["last_classification"]
    )
    print("%s|%s|%s|%s|%s" % (
        state["count"], state["outcome"], classification,
        state["last_event_digest"], state["digest"],
    ))
except (OSError, ValueError, KeyError, TypeError, UnicodeError):
    raise SystemExit(1)
finally:
    close_opened(opened)
PY
}

# Retire only authenticated bytes. The optional digest binds terminal cleanup
# to the exact state that authorized the forward projection.
_commit_retry_clear() {
  local story_id="${1:-}" expected="${2:-none}" state event marker
  _commit_retry_story_valid "$story_id" || return 1
  [[ "$expected" == none || "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  state=$(_commit_retry_state_path "$story_id") || return 1
  event=$(_commit_retry_observation_path "$story_id") || return 1
  marker=$(_commit_retry_stall_marker_path "$story_id") || return 1
  python3 - "$_COMMIT_RETRY_COMMON_PY" "$state" "$event" "$marker" \
    "$story_id" "$expected" <<'PY'
import sys
exec(sys.argv[1])
state_path, event_path, marker_path, story, expected = sys.argv[2:]
opened_values = []
try:
    state_open = read_once(state_path)
    event_open = read_once(event_path)
    marker_open = read_once(marker_path)
    if state_open:
        state = parse_state(state_open, story)
        if expected != "none" and state["digest"] != expected:
            raise ValueError
        if expected == "none" and state["stall_pending"] == "1":
            raise ValueError
        opened_values.append(state_open)
    elif expected != "none":
        raise ValueError
    if event_open:
        parse_event(event_open, story)
        opened_values.append(event_open)
    if marker_open:
        obj = json.loads(marker_open["bytes"].decode("ascii"))
        canonical = (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
        if (canonical != marker_open["bytes"]
                or set(obj) != {"created_at", "cycles", "outcome", "schema_version", "story_id", "threshold"}
                or obj.get("schema_version") != "1.0.0"
                or obj.get("story_id") != story):
            raise ValueError
        opened_values.append(marker_open)
    # Event first prevents a stale observation surviving a successful clear;
    # every failure is propagated and every remaining object stays typed.
    for opened in (event_open, marker_open, state_open):
        if opened:
            retire(opened)
except (OSError, ValueError, KeyError, TypeError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
finally:
    for opened in opened_values:
        close_opened(opened)
PY
}

# Owner-only state directory check used by _commit_retry_diagnose (argv[1] = dir).
_COMMIT_RETRY_DIR_CHECK_PY='
import os, stat, sys
try:
    opened = os.lstat(sys.argv[1])
    if (not stat.S_ISDIR(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
'

# Read-only diagnosis for a failed _commit_retry_observe call. Re-reads the
# same inputs the observer would and prints exactly one classification token.
# Never publishes, retires, creates a directory or rewrites any state, event
# or marker file — _commit_retry_observe, its raise conditions and every
# caller decision stay exactly as they are.
_commit_retry_diagnose() {
  local story_id="${1:-}" worktree_path="${2:-}" base_ref="${3:-}"
  local threshold="${4:-${COMMIT_PHASE_RETRY_THRESHOLD:-3}}"
  local state event digest
  _commit_retry_story_valid "$story_id" || return 1
  if [[ ! "$threshold" =~ ^[1-9][0-9]*$ ]]; then
    printf 'config_invalid\n'
    return 0
  fi
  (( threshold > 1000 )) && threshold=1000
  # No heredoc inside a compound command here: `declare -f` re-serializes such a
  # heredoc incorrectly (bash 3.2 for `<<X || ...`, bash 5.2 for `if ! ... <<X`),
  # so a caller that saves and restores this function would run a corrupted body.
  local dir_rc=0
  python3 -c "$_COMMIT_RETRY_DIR_CHECK_PY" "${LOCK_DIR:?}" || dir_rc=$?
  if (( dir_rc != 0 )); then
    printf 'state_dir_unavailable\n'
    return 0
  fi
  state=$(_commit_retry_state_path "$story_id") || return 1
  event=$(_commit_retry_observation_path "$story_id") || return 1
  if ! digest=$(_commit_retry_content_digest "$story_id" "$worktree_path" "$base_ref"); then
    printf 'content_digest_unavailable\n'
    return 0
  fi
  python3 - "$_COMMIT_RETRY_COMMON_PY" "$state" "$event" "$story_id" \
    "$digest" "$threshold" <<'PY'
import sys
exec(sys.argv[1])
state_path, event_path, story, content_digest, threshold_raw = sys.argv[2:]
state_open = None
event_open = None
result = None
try:
    try:
        state_open = read_once(state_path)
    except (OSError, ValueError):
        result = "state_invalid"
    if result is None:
        try:
            event_open = read_once(event_path)
        except (OSError, ValueError):
            result = "event_invalid"
    if result is None:
        try:
            previous = parse_state(state_open, story) if state_open else None
        except (ValueError, KeyError, TypeError, UnicodeError):
            result = "state_invalid"
    if result is None:
        try:
            event = parse_event(event_open, story) if event_open else None
        except (ValueError, KeyError, TypeError, UnicodeError, json.JSONDecodeError):
            result = "event_invalid"
    if result is None:
        if previous and previous["stall_pending"] == "1":
            if content_digest != previous["content_digest"]:
                result = "stall_content_changed"
            elif event and (event["event_id"] != previous["last_event_id"]
                            or event["digest"] != previous["last_event_digest"]
                            or event["outcome"] != previous["outcome"]):
                result = "event_mismatch"
            else:
                result = "state_publish_failed"
        elif event is None:
            if previous is None:
                result = "no_history"
            elif content_digest != previous["content_digest"]:
                result = "state_content_changed"
            else:
                result = "state_publish_failed"
        elif (previous and event["event_id"] == previous["last_event_id"]
                and event["digest"] == previous["last_event_digest"]
                and event["outcome"] != previous["outcome"]):
            result = "event_mismatch"
        else:
            result = "state_publish_failed"
    print(result)
except (OSError, ValueError, KeyError, TypeError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
finally:
    if state_open:
        close_opened(state_open)
    if event_open:
        close_opened(event_open)
PY
}
