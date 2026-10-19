#!/usr/bin/env bash
# lib/stuck-classifier.sh — pinned, forward-only delivery classification.

[[ -n "${_STUCK_CLASSIFIER_SH_SOURCED:-}" ]] && return 0
_STUCK_CLASSIFIER_SH_SOURCED=1

# The authority-bearing YAML program below runs through the repository-controlled
# runtime boundary, never through an ambient interpreter or an ambient parser.
# The stdlib-only context programs further down keep their own invocation.
# shellcheck source=yaml-runtime.sh
if [[ -z "${_YAML_RUNTIME_SH_SOURCED:-}" ]]; then
  if ! source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yaml-runtime.sh"; then
    printf '%s\n' '[yaml-runtime] role=classifier action=load_boundary code=yaml_runtime_missing' >&2
    return 1 2>/dev/null || exit 30
  fi
fi

# One semantic validator is injected into each descriptor-bound operation so
# install, read and retire cannot drift onto different context schemas.
_FORWARD_CONTEXT_VALIDATE_PY='def validate_context(obj):
    keys = {
        "action", "attempt", "attempt_digest", "blob", "current_record_digest",
        "event_digest", "integrity", "intended_fields", "reason",
        "records_digest", "retained_source", "schema_version", "source",
        "state_digest", "story", "writer",
    }
    if (set(obj) != keys or obj.get("writer") != "recovery.scan"
            or obj.get("schema_version") != "1.0.0"):
        raise ValueError
    object_re = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
    digest_re = re.compile(r"[0-9a-f]{64}")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", obj.get("story", "")):
        raise ValueError
    if not object_re.fullmatch(obj.get("source", "")):
        raise ValueError
    if not object_re.fullmatch(obj.get("blob", "")):
        raise ValueError
    if not digest_re.fullmatch(obj.get("current_record_digest", "")):
        raise ValueError
    if obj.get("attempt") == "retained":
        if not digest_re.fullmatch(obj.get("attempt_digest", "")):
            raise ValueError
        if not digest_re.fullmatch(obj.get("records_digest", "")):
            raise ValueError
        if not object_re.fullmatch(obj.get("retained_source", "")):
            raise ValueError
    elif obj.get("attempt") == "none":
        if any(obj.get(key) != "none" for key in (
            "attempt_digest", "records_digest", "retained_source"
        )):
            raise ValueError
    else:
        raise ValueError
    commit_stall = (
        obj.get("action") == "forward_commit_stall"
        and obj.get("reason") == "stall_pending"
        and obj.get("intended_fields") == "phase_status=commit_stalled"
    )
    if commit_stall:
        if (obj.get("attempt") != "none"
                or not digest_re.fullmatch(obj.get("event_digest", ""))
                or not digest_re.fullmatch(obj.get("state_digest", ""))):
            raise ValueError
    elif obj.get("event_digest") != "none" or obj.get("state_digest") != "none":
        raise ValueError
    any_integrity = {"verified", "recoverable", "unrecoverable", "unknown", "absent_new"}
    matrix = {
        ("claim_candidate", "ready"): ({"verified", "absent_new"}, {"none"}),
        ("resume", "resumable"): ({"verified", "absent_new"}, {"none"}),
        ("forward_fail", "required_plan_absent"): (
            {"verified"}, {"phase_status=failed,status=failed"}
        ),
        ("forward_fail", "worktree_unrecoverable"): (
            {"unrecoverable"}, {"phase_status=failed,status=failed"}
        ),
        ("forward_terminal", "terminal_projection"): (
            any_integrity, {
                "none", "status=failed", "status=escalated",
                "phase_status=failed,status=failed",
            }
        ),
        ("hold_downstream", "merge_terminal_owned"): (any_integrity, {"none"}),
        ("forward_commit_stall", "stall_pending"): (
            any_integrity, {"phase_status=commit_stalled"}
        ),
        ("hold_operator", "policy_stall"): (any_integrity, {"none"}),
        ("no_effect", "not_actionable"): (any_integrity, {"none"}),
    }
    allowed = matrix.get((obj.get("action"), obj.get("reason")))
    if allowed is None:
        raise ValueError
    if obj.get("integrity") not in allowed[0] or obj.get("intended_fields") not in allowed[1]:
        raise ValueError
    if obj.get("action") == "claim_candidate" and obj.get("attempt") != "none":
        raise ValueError
'

# One descriptor-bound reader owns both Story classification and recovery
# enumeration.  The path is opened once without following links, its inode is
# held through the read, and the exact bytes are bound to the pinned Git blob
# before the strict YAML loader sees them.
_forward_read_snapshot() {
  [[ "$#" -ge 4 && "$#" -le 9 ]] || return 1
  local YAML_RUNTIME_ROLE=classifier
  yaml_runtime_run "$@" <<'PY'
import datetime
import hashlib
import os
import re
import stat
import subprocess
import sys

import yaml

path, source_sha, expected_blob, mode = sys.argv[1:5]
if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", source_sha):
    raise SystemExit(1)
if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", expected_blob):
    raise SystemExit(1)
if mode == "classify":
    if len(sys.argv) not in {9, 10}:
        raise SystemExit(1)
    story, scope, integrity, plan_present = sys.argv[5:9]
    now_raw = sys.argv[9] if len(sys.argv) == 10 else ""
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", story):
        raise SystemExit(1)
    if scope not in {"main", "postclaim", "recovery"}:
        raise SystemExit(1)
    if integrity not in {
        "verified", "recoverable", "unrecoverable", "unknown", "absent_new"
    }:
        raise SystemExit(1)
    if plan_present not in {"true", "false"}:
        raise SystemExit(1)
elif mode == "enumerate":
    if len(sys.argv) not in {5, 6}:
        raise SystemExit(1)
    only = sys.argv[5] if len(sys.argv) == 6 else ""
    if only and not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", only):
        raise SystemExit(1)
else:
    raise SystemExit(1)

fd = None
try:
    before = os.lstat(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    after = os.lstat(path)
    if not stat.S_ISREG(opened.st_mode):
        raise ValueError
    if opened.st_uid != os.geteuid() or opened.st_mode & 0o077:
        raise ValueError
    identity = (opened.st_dev, opened.st_ino)
    if identity != (before.st_dev, before.st_ino):
        raise ValueError
    if identity != (after.st_dev, after.st_ino):
        raise ValueError
    chunks = []
    while True:
        chunk = os.read(fd, 131072)
        if not chunk:
            break
        chunks.append(chunk)
    data = b"".join(chunks)
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)

try:
    actual_blob = subprocess.run(
        ["git", "hash-object", "--stdin"], input=data,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True,
    ).stdout.decode("ascii").strip()
except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
    raise SystemExit(1)
if actual_blob != expected_blob:
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
try:
    document = yaml.load(data.decode("utf-8"), Loader=UniqueLoader)
    items = document["items"]
    if not isinstance(items, list):
        raise ValueError
    indexed = {}
    for item in items:
        if not isinstance(item, dict):
            raise ValueError
        sid = item.get("id")
        if not isinstance(sid, str) or not re.fullmatch(
            r"[A-Za-z][A-Za-z0-9._-]{0,63}", sid
        ):
            raise ValueError
        if sid in indexed:
            raise ValueError
        indexed[sid] = item
except (KeyError, TypeError, UnicodeDecodeError, ValueError, yaml.YAMLError):
    raise SystemExit(1)

if mode == "enumerate":
    # A manual row is owned by a human or another session, so recovery never
    # resumes it, on a full scan or on an orphan-lock request for that row.
    # Each skipped row is reported on stderr for the daemon to log; stdout
    # keeps carrying only the selected ids.
    def is_manual(item):
        pipeline = item.get("delivery_pipeline")
        return isinstance(pipeline, str) and pipeline.strip() == "manual"
    if only:
        if only not in indexed:
            raise SystemExit(1)
        candidates = [only]
    else:
        candidates = [
            sid for sid, item in indexed.items()
            if item.get("status") == "in_progress"
        ]
    selected = []
    for sid in candidates:
        if is_manual(indexed[sid]):
            sys.stderr.write("[MANUAL-PIPELINE] story=%s skipped=recovery_scan\n" % sid)
            continue
        selected.append(sid)
    sys.stdout.write("\n".join(selected))
    raise SystemExit(0)

item = indexed.get(story)
if item is None:
    raise SystemExit(1)

status = item.get("status")
phase = item.get("phase_status")
started = item.get("started_at")
statuses = {"refined", "in_progress", "done", "failed", "escalated"}
phases = {
    "not_started", "planned", "implemented", "qa_failed", "qa_passed",
    "failed", "escalated", "qa_escalated", "done", "commit_stalled",
}
if status not in statuses or phase not in phases:
    action, reason = "block_invalid_record", "invalid_lifecycle"
elif status == "in_progress":
    canonical = isinstance(started, str) and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
        started,
    )
    if not canonical:
        action, reason = "block_invalid_record", "invalid_started_at"
    else:
        try:
            parsed = datetime.datetime.strptime(
                started, "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=datetime.timezone.utc)
            now = (
                datetime.datetime.fromtimestamp(int(now_raw), datetime.timezone.utc)
                if now_raw else datetime.datetime.now(datetime.timezone.utc)
            )
            if parsed > now:
                raise ValueError
        except (OverflowError, ValueError):
            action, reason = "block_invalid_record", "invalid_started_at"
        else:
            if phase == "done":
                action, reason = "hold_downstream", "merge_terminal_owned"
            elif phase == "commit_stalled":
                action, reason = "hold_operator", "policy_stall"
            elif phase in {"failed", "escalated", "qa_escalated"}:
                action, reason = "forward_terminal", "terminal_projection"
            elif integrity in {"unknown", "recoverable"}:
                action, reason = "block_integrity", "integrity_unverified"
            elif integrity == "absent_new" and scope != "postclaim":
                action, reason = "block_integrity", "integrity_unverified"
            elif integrity == "unrecoverable":
                action, reason = "forward_fail", "worktree_unrecoverable"
            elif phase == "planned" and plan_present == "false":
                action, reason = "forward_fail", "required_plan_absent"
            elif phase in {
                "not_started", "planned", "implemented", "qa_failed", "qa_passed"
            }:
                action, reason = "resume", "resumable"
            else:
                action, reason = "block_invalid_record", "invalid_lifecycle"
elif status == "refined" and phase == "not_started" and scope == "main":
    if integrity in {"verified", "absent_new"}:
        action, reason = "claim_candidate", "ready"
    else:
        action, reason = "block_integrity", "integrity_unverified"
else:
    action, reason = "no_effect", "not_actionable"

wire_started = started if isinstance(started, str) else "none"
facts = (
    action, reason, status or "none", phase or "none", wire_started,
    hashlib.sha256(data).hexdigest(), source_sha, expected_blob,
)
if any("\t" in str(value) or "\n" in str(value) for value in facts):
    raise SystemExit(1)
sys.stdout.write("\t".join(facts))
PY
}

# forward_classify_snapshot <story> <snapshot> <source-sha> <blob> <scope>
#   <integrity> <plan-present> [<now-epoch>]
#
# Emits one tab-delimited, allowlisted fact row:
#   action reason status phase started_at bytes_digest source_sha blob
# Classification is intentionally side-effect free. In particular it never
# creates a recovery context or guesses authority from local repository state.
forward_classify_snapshot() {
  [[ "$#" -ge 7 && "$#" -le 8 ]] || return 1
  local story="$1" path="$2" source="$3" blob="$4" scope="$5"
  local integrity="$6" plan="$7"
  if [[ "$#" -eq 8 ]]; then
    _forward_read_snapshot "$path" "$source" "$blob" classify \
      "$story" "$scope" "$integrity" "$plan" "$8"
  else
    _forward_read_snapshot "$path" "$source" "$blob" classify \
      "$story" "$scope" "$integrity" "$plan"
  fi
}

# forward_enumerate_snapshot <snapshot> <source-sha> <blob> [<only-story>]
# Emits canonical in-progress Story IDs, or the one requested canonical ID.
forward_enumerate_snapshot() {
  [[ "$#" -ge 3 && "$#" -le 4 ]] || return 1
  if [[ "$#" -eq 4 ]]; then
    _forward_read_snapshot "$1" "$2" "$3" enumerate "$4"
  else
    _forward_read_snapshot "$1" "$2" "$3" enumerate
  fi
}

# forward_context_install <path> <story> <source-sha> <blob> <record-digest>
#   <attempt> <attempt-digest> <retained-source> <records-digest>
#   <event-digest> <state-digest> <integrity> <action> <reason> <intended-fields>
#
# The parent directory must already be private. The context is installed with
# no-replace semantics and is never updated in place.
forward_context_install() {
  [[ "$#" -eq 15 ]] || return 1
  python3 - "$_FORWARD_CONTEXT_VALIDATE_PY" "$@" <<'PY'
import json
import os
import re
import secrets
import stat
import sys

exec(sys.argv[1])
(path, story, source, blob, record_digest, attempt, attempt_digest,
 retained_source, records_digest, event_digest, state_digest, integrity,
 action, reason, intended) = sys.argv[2:]
parent, name = os.path.split(path)
if not parent or not name:
    raise SystemExit(1)
try:
    parent_stat = os.lstat(parent)
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise ValueError
    if parent_stat.st_uid != os.geteuid() or parent_stat.st_mode & 0o077:
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
document = {
    "action": action,
    "attempt": attempt,
    "attempt_digest": attempt_digest,
    "blob": blob,
    "current_record_digest": record_digest,
    "event_digest": event_digest,
    "integrity": integrity,
    "intended_fields": intended,
    "reason": reason,
    "records_digest": records_digest,
    "retained_source": retained_source,
    "schema_version": "1.0.0",
    "source": source,
    "state_digest": state_digest,
    "story": story,
    "writer": "recovery.scan",
}
try:
    validate_context(document)
except (TypeError, ValueError):
    raise SystemExit(1)
wire = (
    json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
).encode("ascii")
dir_fd = os.open(
    parent,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
opened_parent = os.fstat(dir_fd)
if (not stat.S_ISDIR(opened_parent.st_mode)
        or opened_parent.st_uid != os.geteuid()
        or opened_parent.st_mode & 0o077
        or (opened_parent.st_dev, opened_parent.st_ino)
            != (parent_stat.st_dev, parent_stat.st_ino)):
    os.close(dir_fd)
    raise SystemExit(1)
tmp = ".%s.%s.tmp" % (name, secrets.token_hex(12))
fd = None
try:
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=dir_fd,
    )
    view = memoryview(wire)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError
        view = view[written:]
    os.fsync(fd)
    os.close(fd)
    fd = None
    os.link(
        tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False
    )
    os.fsync(dir_fd)
    os.unlink(tmp, dir_fd=dir_fd)
except (FileExistsError, OSError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)
    try:
        os.unlink(tmp, dir_fd=dir_fd)
    except OSError:
        pass
    os.close(dir_fd)
PY
}

# Read the exact immutable context bytes after no-follow owner/mode/inode checks.
forward_context_read() {
  [[ "$#" -eq 1 ]] || return 1
  python3 - "$_FORWARD_CONTEXT_VALIDATE_PY" "$1" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

exec(sys.argv[1])
path = sys.argv[2]
fd = None
dir_fd = None
try:
    parent, name = os.path.split(path)
    parent_before = os.lstat(parent)
    if (not stat.S_ISDIR(parent_before.st_mode)
            or parent_before.st_uid != os.geteuid()
            or parent_before.st_mode & 0o077):
        raise ValueError
    dir_fd = os.open(
        parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    parent_opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(parent_opened.st_mode)
            or parent_opened.st_uid != os.geteuid()
            or parent_opened.st_mode & 0o077
            or (parent_opened.st_dev, parent_opened.st_ino)
                != (parent_before.st_dev, parent_before.st_ino)):
        raise ValueError
    before = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    fd = os.open(
        name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd
    )
    opened = os.fstat(fd)
    after = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if not stat.S_ISREG(opened.st_mode):
        raise ValueError
    if opened.st_uid != os.geteuid() or opened.st_mode & 0o077:
        raise ValueError
    identity = (opened.st_dev, opened.st_ino)
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
    data = b"".join(chunks)
    obj = json.loads(data)
    validate_context(obj)
    values = [
        obj[key] for key in (
            "story", "source", "blob", "current_record_digest", "attempt",
            "attempt_digest", "retained_source", "records_digest",
            "event_digest", "state_digest", "integrity", "action", "reason",
            "intended_fields",
        )
    ]
    if any(
        not isinstance(value, str) or "\t" in value or "\n" in value
        for value in values
    ):
        raise ValueError
    sys.stdout.write(
        "\t".join(values + [hashlib.sha256(data).hexdigest()])
    )
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)
    if dir_fd is not None:
        os.close(dir_fd)
PY
}

forward_context_remove() {
  [[ "$#" -eq 2 && "$2" =~ ^[0-9a-f]{64}$ ]] || return 1
  python3 - "$_FORWARD_CONTEXT_VALIDATE_PY" "$1" "$2" <<'PY'
import hashlib
import json
import os
import re
import secrets
import stat
import sys

exec(sys.argv[1])
path, expected_digest = sys.argv[2:]
fd = None
dir_fd = None
quarantine = None
try:
    parent, name = os.path.split(path)
    parent_before = os.lstat(parent)
    if (not stat.S_ISDIR(parent_before.st_mode)
            or parent_before.st_uid != os.geteuid()
            or parent_before.st_mode & 0o077):
        raise ValueError
    dir_fd = os.open(
        parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    parent_opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(parent_opened.st_mode)
            or parent_opened.st_uid != os.geteuid()
            or parent_opened.st_mode & 0o077
            or (parent_opened.st_dev, parent_opened.st_ino) != (
                parent_before.st_dev, parent_before.st_ino
            )):
        raise ValueError
    before = os.lstat(path)
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
    opened = os.fstat(fd)
    after = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
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
    data = b"".join(chunks)
    if hashlib.sha256(data).hexdigest() != expected_digest:
        raise ValueError
    obj = json.loads(data)
    validate_context(obj)
    quarantine = ".%s.%s.retire" % (name, secrets.token_hex(12))
    os.rename(name, quarantine, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    moved = os.stat(quarantine, dir_fd=dir_fd, follow_symlinks=False)
    if identity != (moved.st_dev, moved.st_ino):
        # The name changed after validation. Restore the successor without
        # overwriting anything and retain evidence if restoration cannot win.
        os.link(
            quarantine, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd,
            follow_symlinks=False,
        )
        os.unlink(quarantine, dir_fd=dir_fd)
        quarantine = None
        os.fsync(dir_fd)
        raise ValueError
    os.unlink(quarantine, dir_fd=dir_fd)
    quarantine = None
    os.fsync(dir_fd)
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)
    if dir_fd is not None:
        os.close(dir_fd)
PY
}
