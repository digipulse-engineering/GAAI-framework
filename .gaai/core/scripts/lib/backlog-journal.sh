#!/usr/bin/env bash
# Policy-bound, provider-neutral delivery lifecycle journal.
#
# Sourcing this library has no filesystem side effect. A caller may mutate its
# working-copy backlog only when backlog_journal_emit returns 0 with outcome
# "emitted". Replay and every ambiguous state are deliberately non-authorizing.

BACKLOG_JOURNAL_OUTCOME=""
BACKLOG_JOURNAL_REASON=""
BACKLOG_JOURNAL_RECORD_PATH=""
BACKLOG_JOURNAL_RECORD_DIGEST=""
BACKLOG_JOURNAL_SEQUENCE=""
BACKLOG_JOURNAL_RUN_TOKEN=""

# Parser availability is owned by the repository-controlled runtime boundary, so
# this library no longer probes an ambient interpreter or an ambient parser.
# shellcheck source=yaml-runtime.sh
if [[ -z "${_YAML_RUNTIME_SH_SOURCED:-}" ]]; then
  if ! source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yaml-runtime.sh"; then
    printf '%s\n' '[yaml-runtime] role=journal action=load_boundary code=yaml_runtime_missing' >&2
    return 1 2>/dev/null || exit 30
  fi
fi

_backlog_journal_safe_story() {
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] && printf '%s' "$1" || printf '-'
}

_backlog_journal_safe_field() {
  case "${1:-}" in
    status|phase_status|started_at|completed_at|blocked_reason|pr_url|pr_number|pr_status|cost_usd)
      printf '%s' "$1"
      ;;
    *) printf '-' ;;
  esac
}

_backlog_journal_safe_writer() {
  local value="${1:-}"
  if (( ${#value} <= 64 )) && [[ "$value" =~ ^[a-z][a-z0-9]*([._-][a-z0-9]+){0,7}$ ]]; then
    printf '%s' "$value"
  else
    printf '-'
  fi
}

_backlog_journal_shell_diagnostic() {
  local story_id="${1:-}" field="${2:-}" writer="${3:-}" reason="${4:-policy_invalid}"
  printf '[BACKLOG-JOURNAL] story=%s field=%s writer=%s seq=0 source=- record=- attempt=rejected outcome=rejected reason=%s\n' \
    "$(_backlog_journal_safe_story "$story_id")" \
    "$(_backlog_journal_safe_field "$field")" \
    "$(_backlog_journal_safe_writer "$writer")" \
    "$reason" >&2
}

# Mint and durably register a 256-bit token for one normalized writer context.
# Usage: backlog_journal_begin_run <backlog-file> <writer-context>
backlog_journal_begin_run() {
  local backlog_file="${1:-}" writer_context="${2:-}"
  local result rc

  BACKLOG_JOURNAL_OUTCOME=""
  BACKLOG_JOURNAL_REASON=""
  BACKLOG_JOURNAL_RUN_TOKEN=""

  # Registration is a stdlib-only program: it composes no YAML and imports no
  # parser, so it keeps its own invocation. An unavailable interpreter is already
  # fail-closed here — the empty result and non-zero status below reject the run.
  if result=$(python3 - "$backlog_file" "$writer_context" <<'PY'
import datetime
import hashlib
import json
import os
import re
import secrets
import sys
import tempfile


WRITER_RE = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+){0,7}$")


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def fail(reason):
    print(f"rejected\t{reason}\t-")
    raise SystemExit(1)


def normalize_storage_path(raw_path):
    """Normalize only the platform TMPDIR alias, then reject other symlinks."""
    path = os.path.abspath(raw_path)
    temp_input = os.path.abspath(os.environ.get("TMPDIR", tempfile.gettempdir()))
    temp_root = os.path.realpath(temp_input)
    try:
        if os.path.commonpath([temp_input, path]) == temp_input:
            path = os.path.join(temp_root, os.path.relpath(path, temp_input))
    except ValueError:
        pass
    resolved = os.path.realpath(path)
    if resolved != path:
        fail("journal_storage_permissions")
    return resolved


backlog_file, writer = sys.argv[1:3]
if not WRITER_RE.fullmatch(writer or "") or len(writer.encode("ascii", "ignore")) > 64:
    fail("writer_context_invalid")
if not backlog_file:
    fail("backlog_missing")

backlog_abs = os.path.realpath(backlog_file)
backlog_dir = os.path.dirname(backlog_abs)
journal_input = os.environ.get(
    "GAAI_BACKLOG_JOURNAL_DIR",
    os.path.join(backlog_dir, ".delivery-locks", "journal"),
)
journal_root = normalize_storage_path(journal_input)
registrations = os.path.join(journal_root, "registrations")
try:
    os.makedirs(journal_root, mode=0o700, exist_ok=True)
    os.makedirs(registrations, mode=0o700, exist_ok=True)
    if (os.stat(journal_root, follow_symlinks=False).st_mode & 0o077
            or os.stat(registrations, follow_symlinks=False).st_mode & 0o077):
        fail("journal_storage_permissions")
except OSError:
    fail("journal_storage_unavailable")

while True:
    token = secrets.token_hex(32)
    registration = {
        "schema_version": "1.0.0",
        "run_token": token,
        "writer_context": writer,
        "issued_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    digest = hashlib.sha256(canonical_json(registration).encode("utf-8")).hexdigest()
    wrapper = {"registration": registration, "digest": digest}
    payload = (canonical_json(wrapper) + "\n").encode("utf-8")
    final_path = os.path.join(registrations, f"{token}.json")
    temp_path = os.path.join(registrations, f".{token}.{os.getpid()}.tmp")
    try:
        fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError("short write")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.link(temp_path, final_path)
        os.unlink(temp_path)
        dir_fd = os.open(registrations, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        print(f"minted\tnone\t{token}")
        break
    except FileExistsError:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        continue
    except PermissionError:
        fail("journal_storage_permissions")
    except OSError:
        fail("append_interrupted")
PY
  ); then
    rc=0
  else
    rc=$?
  fi

  IFS=$'\t' read -r BACKLOG_JOURNAL_OUTCOME BACKLOG_JOURNAL_REASON BACKLOG_JOURNAL_RUN_TOKEN <<< "$result"
  if [[ $rc -ne 0 || "$BACKLOG_JOURNAL_OUTCOME" != "minted" || \
        ! "$BACKLOG_JOURNAL_RUN_TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
    BACKLOG_JOURNAL_OUTCOME="${BACKLOG_JOURNAL_OUTCOME:-rejected}"
    BACKLOG_JOURNAL_REASON="${BACKLOG_JOURNAL_REASON:-policy_invalid}"
    BACKLOG_JOURNAL_RUN_TOKEN=""
    _backlog_journal_shell_diagnostic "-" "-" "$writer_context" "$BACKLOG_JOURNAL_REASON"
    return 1
  fi
  return 0
}

# Emit exactly one durable record. Return values:
#   0  emitted (the sole mutation-authorizing outcome)
#   10 pending replay (record locator returned, backlog mutation forbidden)
#   1  all other closed rejections/pending evidence
backlog_journal_emit() {
  local backlog_file="${1:-}" story_id="${2:-}" field="${3:-}" new_value="${4:-}"
  local writer_context="${5:-${GAAI_BACKLOG_JOURNAL_WRITER_CONTEXT:-backlog-scheduler.journal-set}}"
  local run_token="${6:-${GAAI_BACKLOG_JOURNAL_RUN_TOKEN:-}}"
  local result rc

  BACKLOG_JOURNAL_OUTCOME=""
  BACKLOG_JOURNAL_REASON=""
  BACKLOG_JOURNAL_RECORD_PATH=""
  BACKLOG_JOURNAL_RECORD_DIGEST=""
  BACKLOG_JOURNAL_SEQUENCE=""

  local YAML_RUNTIME_ROLE=journal
  if result=$(yaml_runtime_run "$backlog_file" "$story_id" "$field" "$new_value" \
      "$writer_context" "$run_token" <<'PY'
import datetime
import decimal
import errno
import fcntl
import glob
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile


class JournalError(Exception):
    def __init__(self, reason, sequence=0, source_digest="", record_digest="", attempt="rejected"):
        super().__init__(reason)
        self.reason = reason
        self.sequence = sequence
        self.source_digest = source_digest
        self.record_digest = record_digest
        self.attempt = attempt


def normalize_storage_path(raw_path):
    """Normalize only the platform TMPDIR alias, then reject other symlinks."""
    path = os.path.abspath(raw_path)
    temp_input = os.path.abspath(os.environ.get("TMPDIR", tempfile.gettempdir()))
    temp_root = os.path.realpath(temp_input)
    try:
        if os.path.commonpath([temp_input, path]) == temp_input:
            path = os.path.join(temp_root, os.path.relpath(path, temp_input))
    except ValueError:
        pass
    resolved = os.path.realpath(path)
    if resolved != path:
        raise JournalError("journal_storage_permissions")
    return resolved


ALLOWED_FIELDS = {
    "status", "phase_status", "started_at", "completed_at", "blocked_reason",
    "pr_url", "pr_number", "pr_status", "cost_usd",
}
STATUS_VALUES = {
    "draft", "refined", "in_progress", "done", "failed", "blocked",
    "cancelled", "superseded", "escalated", "deferred",
}
STATUS_EDGES = {
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
PHASE_VALUES = {
    "not_started", "planned", "implemented", "qa_passed", "qa_failed",
    "qa_escalated", "commit_stalled", "done", "failed", "escalated",
}
PHASE_EDGES = {
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
PR_STATUSES = {
    "merged", "pending_review", "open", "closed", "closed_superseded",
    "not_created_superseded", "created", "none",
}
WRITER_RE = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+){0,7}$")
STORY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,63}$")
TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
OBJECT_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SOURCE_REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")
TIMESTAMP_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
PR_URL_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$")
POSITIVE_INT_RE = re.compile(r"^[1-9][0-9]*$")
COST_RE = re.compile(r"^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$")


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def safe_label(value, pattern, byte_limit=64):
    try:
        encoded = (value or "").encode("ascii")
    except UnicodeError:
        return "-"
    return value if len(encoded) <= byte_limit and pattern.fullmatch(value or "") else "-"


def diagnostic(story_id, field, writer, sequence, source_digest, record_digest,
               attempt, outcome, reason):
    print(
        "[BACKLOG-JOURNAL] "
        f"story={safe_label(story_id, STORY_RE)} "
        f"field={field if field in ALLOWED_FIELDS else '-'} "
        f"writer={safe_label(writer, WRITER_RE)} seq={sequence} "
        f"source={source_digest[:12] if source_digest else '-'} "
        f"record={record_digest[:12] if record_digest else '-'} "
        f"attempt={attempt if attempt in {'initial', 'replay', 'recovery', 'rejected'} else 'rejected'} "
        f"outcome={outcome} reason={reason}",
        file=sys.stderr,
    )


def git_output(args):
    try:
        return subprocess.check_output(args, stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        raise JournalError("source_unresolvable")


def git_content(args):
    try:
        return subprocess.check_output(args, stderr=subprocess.DEVNULL, text=True)
    except (OSError, subprocess.CalledProcessError, UnicodeError):
        raise JournalError("source_unresolvable")


def load_yaml_source(source, target_story_id):
    # The boundary has already attested and imported the runtime; this resolves
    # from the verified in-memory module and can never reach an ambient tree.
    import yaml

    try:
        class BacklogSafeLoader(yaml.SafeLoader):
            pass

        # Preserve integer, decimal and timestamp lexemes. Policy validation
        # inspects the composed scalar node before these strings are
        # canonicalized, so PyYAML cannot normalize a forbidden presentation.
        for tag in (
            "tag:yaml.org,2002:int",
            "tag:yaml.org,2002:float",
            "tag:yaml.org,2002:timestamp",
        ):
            BacklogSafeLoader.add_constructor(
                tag,
                lambda loader, node: loader.construct_scalar(node),
            )

        root = yaml.compose(source, Loader=BacklogSafeLoader)
        if not isinstance(root, yaml.MappingNode):
            raise JournalError("backlog_unsafe_yaml")
        if any(not isinstance(key, yaml.ScalarNode) for key, _ in root.value):
            raise JournalError("backlog_unsafe_yaml")
        items_nodes = [value for key, value in root.value if key.value == "items"]
        if len(items_nodes) != 1 or not isinstance(items_nodes[0], yaml.SequenceNode):
            raise JournalError("backlog_unsafe_yaml")
        target_nodes = []
        for item_node in items_nodes[0].value:
            if not isinstance(item_node, yaml.MappingNode):
                raise JournalError("backlog_unsafe_yaml")
            if any(not isinstance(key, yaml.ScalarNode) for key, _ in item_node.value):
                raise JournalError("backlog_unsafe_yaml")
            id_nodes = [value for key, value in item_node.value if key.value == "id"]
            if len(id_nodes) != 1 or not isinstance(id_nodes[0], yaml.ScalarNode):
                raise JournalError("backlog_unsafe_yaml")
            if id_nodes[0].value == target_story_id:
                target_nodes.append(item_node)
        if len(target_nodes) > 1:
            raise JournalError("story_duplicate")
        target_field_nodes = {}
        if target_nodes:
            keys = [key.value for key, _ in target_nodes[0].value]
            if "<<" in keys or len(keys) != len(set(keys)):
                raise JournalError("backlog_unsafe_yaml")
            target_field_nodes = {key.value: value for key, value in target_nodes[0].value}
        # SafeLoader prevents executable/object construction. Duplicate legacy
        # fields in unrelated rows do not influence the target row and are not
        # accepted as target identity or mutation authority.
        document = yaml.load(source, Loader=BacklogSafeLoader)
        if not isinstance(document, dict) or not isinstance(document.get("items"), list):
            raise JournalError("backlog_unsafe_yaml")
        matches = [
            item for item in document["items"]
            if isinstance(item, dict) and str(item.get("id")) == target_story_id
        ]
        if not matches:
            raise JournalError("story_missing")
        if len(matches) != 1:
            raise JournalError("story_duplicate")
        return matches[0], target_field_nodes, yaml
    except JournalError:
        raise
    except (UnicodeError, yaml.YAMLError):
        raise JournalError("backlog_unsafe_yaml")


def load_yaml_path(path, target_story_id):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return load_yaml_source(handle.read(), target_story_id)
    except JournalError:
        raise
    except (OSError, UnicodeError):
        raise JournalError("backlog_unsafe_yaml")


def canonical_timestamp(value):
    if value is None:
        return None
    if isinstance(value, datetime.datetime):
        if value.tzinfo is None:
            raise JournalError("value_malformed")
        value = value.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not isinstance(value, str) or not TIMESTAMP_RE.fullmatch(value):
        raise JournalError("value_malformed")
    try:
        datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise JournalError("value_malformed")
    return value


def canonical_blocked_reason(value):
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise JournalError("value_malformed")
    for char in value:
        code = ord(char)
        if (code <= 31 or 127 <= code <= 159 or 0xD800 <= code <= 0xDFFF
                or code in {0x2028, 0x2029}):
            raise JournalError("value_malformed")
    return value


def canonical_pr_url(value):
    if value is None:
        return None
    if not isinstance(value, str) or not PR_URL_RE.fullmatch(value):
        raise JournalError("value_malformed")
    return value


def canonical_pr_number(value):
    if value is None:
        return None
    if isinstance(value, bool):
        raise JournalError("value_malformed")
    raw = str(value)
    if not POSITIVE_INT_RE.fullmatch(raw):
        raise JournalError("value_malformed")
    return int(raw)


def canonical_pr_status(value):
    if value is None:
        return None
    if not isinstance(value, str) or value not in PR_STATUSES:
        raise JournalError("value_malformed")
    return value


def canonical_cost(value, from_cli=False):
    if value is None:
        return None
    if isinstance(value, bool):
        raise JournalError("value_malformed")
    raw = str(value)
    if (from_cli or isinstance(value, str)) and not COST_RE.fullmatch(raw):
        raise JournalError("value_malformed")
    try:
        parsed = decimal.Decimal(raw)
    except decimal.InvalidOperation:
        raise JournalError("value_malformed")
    if not parsed.is_finite() or parsed < 0:
        raise JournalError("value_malformed")
    canonical = format(parsed, "f")
    if "." in canonical:
        canonical = canonical.rstrip("0").rstrip(".")
    return canonical or "0"


def canonical_scalar(field, value):
    if field in {"started_at", "completed_at"}:
        return canonical_timestamp(value)
    if field == "blocked_reason":
        return canonical_blocked_reason(value)
    if field == "pr_url":
        return canonical_pr_url(value)
    if field == "pr_number":
        return canonical_pr_number(value)
    if field == "pr_status":
        return canonical_pr_status(value)
    if field == "cost_usd":
        return canonical_cost(value)
    raise JournalError("field_not_allowed")


def resolve_predecessor(field, item, field_nodes, yaml):
    required = field in {"status", "phase_status"}
    node = field_nodes.get(field)
    if node is None:
        if required:
            raise JournalError("backlog_unsafe_yaml")
        return None
    if not isinstance(node, yaml.ScalarNode) or node.style in {"|", ">"}:
        raise JournalError("backlog_unsafe_yaml")

    null_tag = "tag:yaml.org,2002:null"
    string_tag = "tag:yaml.org,2002:str"
    allowed_tags = {
        "status": {string_tag},
        "phase_status": {string_tag},
        "started_at": {null_tag, string_tag, "tag:yaml.org,2002:timestamp"},
        "completed_at": {null_tag, string_tag, "tag:yaml.org,2002:timestamp"},
        "blocked_reason": {null_tag, string_tag},
        "pr_url": {null_tag, string_tag},
        "pr_number": {null_tag, "tag:yaml.org,2002:int"},
        "pr_status": {null_tag, string_tag},
        "cost_usd": {null_tag, "tag:yaml.org,2002:int", "tag:yaml.org,2002:float"},
    }
    if node.tag not in allowed_tags[field]:
        raise JournalError("value_malformed")

    value = item.get(field)
    if field == "status":
        if not isinstance(value, str) or value not in STATUS_VALUES:
            raise JournalError("value_malformed")
        return value
    if field == "phase_status":
        if not isinstance(value, str) or value not in PHASE_VALUES:
            raise JournalError("value_malformed")
        return value
    return canonical_scalar(field, value)


def parse_new_scalar(field, raw):
    if field == "blocked_reason":
        if raw == "null":
            value = None
        elif raw.startswith("json:"):
            try:
                value = json.loads(raw[5:])
            except json.JSONDecodeError:
                raise JournalError("value_malformed")
            if not isinstance(value, str):
                raise JournalError("value_malformed")
        else:
            raise JournalError("value_malformed")
        return canonical_blocked_reason(value)
    value = None if raw == "null" else raw
    if field == "cost_usd":
        return canonical_cost(value, from_cli=True)
    return canonical_scalar(field, value)


def validate_policy(field, old_value, raw_new_value):
    if field not in ALLOWED_FIELDS:
        raise JournalError("field_not_allowed")
    if field == "status":
        if not isinstance(old_value, str) or old_value not in STATUS_VALUES:
            raise JournalError("value_malformed")
        if raw_new_value not in STATUS_VALUES:
            raise JournalError("value_malformed")
        if raw_new_value not in STATUS_EDGES[old_value]:
            raise JournalError("transition_invalid")
        return old_value, raw_new_value
    if field == "phase_status":
        if not isinstance(old_value, str) or old_value not in PHASE_VALUES:
            raise JournalError("value_malformed")
        if raw_new_value not in PHASE_VALUES:
            raise JournalError("value_malformed")
        if raw_new_value not in PHASE_EDGES[old_value]:
            raise JournalError("transition_invalid")
        return old_value, raw_new_value
    return canonical_scalar(field, old_value), parse_new_scalar(field, raw_new_value)


def load_registration(path, token, writer):
    try:
        mode = os.stat(path, follow_symlinks=False).st_mode
        if not stat.S_ISREG(mode) or mode & 0o077:
            raise ValueError
        with open(path, "r", encoding="utf-8") as handle:
            wrapper = json.load(handle)
        registration = wrapper["registration"]
        digest = wrapper["digest"]
        if set(wrapper) != {"registration", "digest"}:
            raise ValueError
        if set(registration) != {"schema_version", "run_token", "writer_context", "issued_at"}:
            raise ValueError
        if registration.get("schema_version") != "1.0.0":
            raise ValueError
        if registration.get("run_token") != token or registration.get("writer_context") != writer:
            raise ValueError
        if canonical_timestamp(registration.get("issued_at")) != registration.get("issued_at"):
            raise ValueError
        if not re.fullmatch(r"[0-9a-f]{64}", digest or ""):
            raise ValueError
        if sha256(canonical_json(registration).encode("utf-8")) != digest:
            raise ValueError
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, JournalError):
        raise JournalError("run_token_unregistered")


def load_record(path, writer, registrations_dir):
    try:
        mode = os.stat(path, follow_symlinks=False).st_mode
        if not stat.S_ISREG(mode) or mode & 0o077:
            raise ValueError
        with open(path, "r", encoding="utf-8") as handle:
            wrapper = json.load(handle)
        record = wrapper["record"]
        digest = wrapper["digest"]
        intent_digest = wrapper["intent_digest"]
        expected_record_keys = {
            "schema_version", "story_id", "field", "old_value", "new_value",
            "source_commit", "source_blob", "writer_context", "run_token",
            "intent_digest", "sequence", "emitted_at",
        }
        if set(wrapper) != {"record", "intent_digest", "digest"} or set(record) != expected_record_keys:
            raise ValueError
        if record.get("schema_version") != "1.0.0":
            raise ValueError
        if record.get("writer_context") != writer:
            raise ValueError
        if (not STORY_RE.fullmatch(record.get("story_id") or "")
                or record.get("field") not in ALLOWED_FIELDS
                or not WRITER_RE.fullmatch(record.get("writer_context") or "")
                or not TOKEN_RE.fullmatch(record.get("run_token") or "")
                or not OBJECT_RE.fullmatch(record.get("source_commit") or "")
                or not OBJECT_RE.fullmatch(record.get("source_blob") or "")
                or canonical_timestamp(record.get("emitted_at")) != record.get("emitted_at")):
            raise ValueError
        if record.get("intent_digest") != intent_digest:
            raise ValueError
        if (isinstance(record.get("sequence"), bool)
                or not isinstance(record.get("sequence"), int)
                or record["sequence"] < 1):
            raise ValueError
        if not re.fullmatch(r"[0-9a-f]{64}", digest or ""):
            raise ValueError
        if not re.fullmatch(r"[0-9a-f]{64}", intent_digest or ""):
            raise ValueError
        if sha256(canonical_json(record).encode("utf-8")) != digest:
            raise ValueError
        try:
            if record["field"] in {"status", "phase_status"}:
                canonical_old, canonical_new = validate_policy(
                    record["field"], record["old_value"], record["new_value"]
                )
            else:
                canonical_old = canonical_scalar(record["field"], record["old_value"])
                canonical_new = canonical_scalar(record["field"], record["new_value"])
        except JournalError:
            raise ValueError
        if canonical_old != record["old_value"] or canonical_new != record["new_value"]:
            raise ValueError
        intent = {key: record[key] for key in (
            "schema_version", "story_id", "field", "old_value", "new_value",
            "source_commit", "source_blob", "writer_context", "run_token",
        )}
        if sha256(canonical_json(intent).encode("utf-8")) != intent_digest:
            raise ValueError
        expected_name = f"{record['sequence']:020d}-{intent_digest[:16]}.json"
        if os.path.basename(path) != expected_name:
            raise ValueError
        load_registration(
            os.path.join(registrations_dir, f"{record['run_token']}.json"),
            record["run_token"],
            writer,
        )
        return wrapper
    except JournalError as exc:
        if exc.reason == "run_token_unregistered":
            raise
        raise JournalError("digest_mismatch")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        raise JournalError("digest_mismatch")


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_sequence(writer_dir, sequence):
    sequence_path = os.path.join(writer_dir, ".sequence")
    temp_path = os.path.join(writer_dir, f".sequence.{os.getpid()}.tmp")
    try:
        fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            view = memoryview(f"{sequence}\n".encode("ascii"))
            while view:
                if os.environ.get("GAAI_BACKLOG_JOURNAL_FAULT") == "sequence_short_write":
                    written = 0
                else:
                    written = os.write(fd, view)
                if written <= 0:
                    raise OSError(errno.EIO, "short write")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp_path, sequence_path)
        fsync_dir(writer_dir)
    except PermissionError:
        raise JournalError("journal_storage_permissions", sequence=sequence)
    except OSError:
        raise JournalError("append_interrupted", sequence=sequence, attempt="recovery")


def publish_record(records_dir, sequence, intent_digest, payload, record_digest):
    final_path = os.path.join(records_dir, f"{sequence:020d}-{intent_digest[:16]}.json")
    temp_path = os.path.join(records_dir, f".{sequence:020d}-{intent_digest[:16]}.{os.getpid()}.tmp")
    try:
        fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError(errno.EIO, "short write")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        if os.environ.get("GAAI_BACKLOG_JOURNAL_FAULT") == "after_temp_fsync":
            raise JournalError("append_interrupted", sequence, "", record_digest, "recovery")
        os.link(temp_path, final_path)
        os.unlink(temp_path)
        fsync_dir(records_dir)
        return final_path
    except JournalError:
        raise
    except FileExistsError:
        raise JournalError("conflicting_duplicate", sequence, "", record_digest, "recovery")
    except PermissionError:
        raise JournalError("journal_storage_permissions", sequence, "", record_digest, "recovery")
    except OSError:
        raise JournalError("append_interrupted", sequence, "", record_digest, "recovery")


def run(backlog_file, story_id, field, raw_new_value, writer, token):
    if not backlog_file or not os.path.isfile(backlog_file):
        raise JournalError("backlog_missing")
    if not STORY_RE.fullmatch(story_id or ""):
        raise JournalError("story_missing")
    try:
        writer_bytes = writer.encode("ascii")
    except UnicodeError:
        raise JournalError("writer_context_invalid")
    if len(writer_bytes) > 64 or not WRITER_RE.fullmatch(writer or ""):
        raise JournalError("writer_context_invalid")
    if not TOKEN_RE.fullmatch(token or ""):
        raise JournalError("run_token_unregistered")
    if field not in ALLOWED_FIELDS:
        raise JournalError("field_not_allowed")

    backlog_abs = os.path.realpath(backlog_file)
    backlog_dir = os.path.dirname(backlog_abs)
    repo_root = os.path.realpath(git_output(["git", "-C", backlog_dir, "rev-parse", "--show-toplevel"]))
    try:
        if os.path.commonpath([repo_root, backlog_abs]) != repo_root:
            raise ValueError
    except ValueError:
        raise JournalError("source_unresolvable")
    source_ref = os.environ.get("GAAI_BACKLOG_JOURNAL_SOURCE_REF", "HEAD")
    if (not SOURCE_REF_RE.fullmatch(source_ref)
            or any(part in {"", ".", ".."} for part in source_ref.split("/"))
            or ".." in source_ref):
        raise JournalError("source_unresolvable")
    source_commit = git_output([
        "git", "-C", repo_root, "rev-parse", "--verify", "--end-of-options",
        f"{source_ref}^{{commit}}",
    ])
    relative_path = os.path.relpath(backlog_abs, repo_root)
    source_blob = git_output(["git", "-C", repo_root, "rev-parse", f"{source_commit}:{relative_path}"])
    if not OBJECT_RE.fullmatch(source_commit) or not OBJECT_RE.fullmatch(source_blob):
        raise JournalError("source_unresolvable")

    try:
        working_item, working_nodes, yaml = load_yaml_path(backlog_abs, story_id)
        source_text = git_content(["git", "-C", repo_root, "cat-file", "blob", source_blob])
        source_item, source_nodes, source_yaml = load_yaml_source(source_text, story_id)
        working_old = resolve_predecessor(field, working_item, working_nodes, yaml)
        source_old = resolve_predecessor(field, source_item, source_nodes, source_yaml)
        if working_old != source_old:
            raise JournalError("source_value_mismatch")
        old_value, new_value = validate_policy(field, working_old, raw_new_value)
        if old_value != source_old:
            raise JournalError("source_value_mismatch")
    except JournalError as exc:
        exc.source_digest = source_blob
        raise

    journal_input = os.environ.get(
        "GAAI_BACKLOG_JOURNAL_DIR",
        os.path.join(backlog_dir, ".delivery-locks", "journal"),
    )
    try:
        journal_root = normalize_storage_path(journal_input)
    except JournalError as exc:
        exc.source_digest = source_blob
        raise
    registration_path = os.path.join(journal_root, "registrations", f"{token}.json")
    try:
        load_registration(registration_path, token, writer)
    except JournalError as exc:
        exc.source_digest = source_blob
        raise

    writer_key = sha256(writer.encode("ascii"))
    writer_dir = os.path.join(journal_root, "writers", writer_key)
    records_dir = os.path.join(writer_dir, "records")
    applied_dir = os.path.join(writer_dir, "applied")
    try:
        os.makedirs(journal_root, mode=0o700, exist_ok=True)
        writers_dir = os.path.dirname(writer_dir)
        os.makedirs(writers_dir, mode=0o700, exist_ok=True)
        os.makedirs(writer_dir, mode=0o700, exist_ok=True)
        os.makedirs(records_dir, mode=0o700, exist_ok=True)
        os.makedirs(applied_dir, mode=0o700, exist_ok=True)
        if (os.stat(journal_root, follow_symlinks=False).st_mode & 0o077
                or os.stat(writers_dir, follow_symlinks=False).st_mode & 0o077
                or os.stat(writer_dir, follow_symlinks=False).st_mode & 0o077
                or os.stat(records_dir).st_mode & 0o077
                or os.stat(applied_dir).st_mode & 0o077):
            raise JournalError("journal_storage_permissions", source_digest=source_blob)
        lock_fd = os.open(os.path.join(writer_dir, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    except JournalError:
        raise
    except PermissionError:
        raise JournalError("journal_storage_permissions", source_digest=source_blob)
    except OSError:
        raise JournalError("journal_storage_unavailable", source_digest=source_blob)

    intent = {
        "schema_version": "1.0.0",
        "story_id": story_id,
        "field": field,
        "old_value": old_value,
        "new_value": new_value,
        "source_commit": source_commit,
        "source_blob": source_blob,
        "writer_context": writer,
        "run_token": token,
    }
    intent_digest = sha256(canonical_json(intent).encode("utf-8"))

    with os.fdopen(lock_fd, "a+", encoding="ascii") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        except OSError:
            raise JournalError("journal_storage_unavailable", source_digest=source_blob)

        temp_records = glob.glob(os.path.join(records_dir, ".*.tmp"))
        if temp_records:
            raise JournalError("append_interrupted", source_digest=source_blob, attempt="recovery")

        sequence_to_record = {}
        matching = []
        historical_paths = (
            glob.glob(os.path.join(records_dir, "*.json"))
            + glob.glob(os.path.join(applied_dir, "*.json"))
        )
        for path in sorted(historical_paths, key=lambda value: os.path.basename(value)):
            try:
                wrapper = load_record(path, writer, os.path.dirname(registration_path))
            except JournalError as exc:
                exc.source_digest = source_blob
                raise
            sequence = wrapper["record"]["sequence"]
            if sequence in sequence_to_record:
                raise JournalError("conflicting_duplicate", sequence, source_blob, attempt="recovery")
            sequence_to_record[sequence] = wrapper
            if wrapper["intent_digest"] == intent_digest:
                matching.append((path, wrapper))
        if len(matching) > 1:
            raise JournalError("conflicting_duplicate", matching[0][1]["record"]["sequence"], source_blob,
                               matching[0][1]["digest"], "recovery")

        max_record_sequence = max(sequence_to_record, default=0)
        if sequence_to_record and set(sequence_to_record) != set(range(1, max_record_sequence + 1)):
            raise JournalError("sequence_fork", max_record_sequence, source_blob, attempt="recovery")
        sequence_path = os.path.join(writer_dir, ".sequence")
        durable_sequence = 0
        if os.path.exists(sequence_path):
            try:
                sequence_mode = os.stat(sequence_path, follow_symlinks=False).st_mode
                if not stat.S_ISREG(sequence_mode) or sequence_mode & 0o077:
                    raise ValueError
                with open(sequence_path, "r", encoding="ascii") as handle:
                    raw_sequence = handle.read().strip()
                if not re.fullmatch(r"[1-9][0-9]*", raw_sequence):
                    raise ValueError
                durable_sequence = int(raw_sequence)
            except (OSError, UnicodeError, ValueError):
                raise JournalError("sequence_fork", source_digest=source_blob, attempt="recovery")
        if durable_sequence > max_record_sequence:
            raise JournalError("sequence_fork", durable_sequence, source_blob, attempt="recovery")
        recovered = durable_sequence < max_record_sequence
        if recovered:
            try:
                write_sequence(writer_dir, max_record_sequence)
            except JournalError as exc:
                exc.source_digest = source_blob
                raise
            durable_sequence = max_record_sequence

        if matching:
            path, wrapper = matching[0]
            record = wrapper["record"]
            return (
                "pending:replay", path, wrapper["digest"], record["sequence"], source_blob,
                "recovery" if recovered else "replay", "replay",
            )

        sequence = max(durable_sequence, max_record_sequence) + 1
        record = dict(intent)
        record.update({
            "intent_digest": intent_digest,
            "sequence": sequence,
            "emitted_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
        record_digest = sha256(canonical_json(record).encode("utf-8"))
        wrapper = {"record": record, "intent_digest": intent_digest, "digest": record_digest}
        payload = (canonical_json(wrapper) + "\n").encode("utf-8")
        try:
            final_path = publish_record(records_dir, sequence, intent_digest, payload, record_digest)
        except JournalError as exc:
            exc.source_digest = source_blob
            raise
        if os.environ.get("GAAI_BACKLOG_JOURNAL_FAULT") == "after_record_publish":
            raise JournalError("append_interrupted", sequence, source_blob, record_digest, "recovery")
        try:
            write_sequence(writer_dir, sequence)
        except JournalError as exc:
            exc.source_digest = source_blob
            exc.record_digest = record_digest
            raise
        if os.environ.get("GAAI_BACKLOG_JOURNAL_FAULT") == "after_sequence_update":
            raise JournalError("append_interrupted", sequence, source_blob, record_digest, "recovery")
        return "emitted", final_path, record_digest, sequence, source_blob, "initial", "none"


backlog_file, story_id, field, raw_new_value, writer, token = sys.argv[1:7]
try:
    outcome, path, record_digest, sequence, source_digest, attempt, reason = run(
        backlog_file, story_id, field, raw_new_value, writer, token
    )
    diagnostic(story_id, field, writer, sequence, source_digest, record_digest,
               attempt, outcome, reason)
    print(f"{outcome}\t{path}\t{record_digest}\t{sequence}\t{reason}")
    if outcome == "pending:replay":
        raise SystemExit(10)
except JournalError as exc:
    diagnostic(story_id, field, writer, exc.sequence, exc.source_digest,
               exc.record_digest, exc.attempt, "rejected", exc.reason)
    print(f"rejected\t-\t-\t{exc.sequence}\t{exc.reason}")
    raise SystemExit(1)
PY
  ); then
    rc=0
  else
    rc=$?
  fi

  IFS=$'\t' read -r BACKLOG_JOURNAL_OUTCOME BACKLOG_JOURNAL_RECORD_PATH \
    BACKLOG_JOURNAL_RECORD_DIGEST BACKLOG_JOURNAL_SEQUENCE BACKLOG_JOURNAL_REASON <<< "$result"
  if [[ "$BACKLOG_JOURNAL_RECORD_PATH" == "-" ]]; then
    BACKLOG_JOURNAL_RECORD_PATH=""
  fi
  if [[ "$BACKLOG_JOURNAL_RECORD_DIGEST" == "-" ]]; then
    BACKLOG_JOURNAL_RECORD_DIGEST=""
  fi
  return "$rc"
}

# Establish and validate the closed private container used by projection
# attempts. No symlinked or group/world-accessible journal root is accepted.
backlog_journal_prepare_projection_storage() {
  local journal_root="${1:-}"
  python3 - "$journal_root" <<'PY'
import os, re, stat, sys

root_input = os.path.abspath(sys.argv[1])
root = os.path.realpath(root_input)
allowed = {"registrations", "writers", "projections", "applied-projections"}

def private_dir(path):
    mode = os.stat(path, follow_symlinks=False).st_mode
    return stat.S_ISDIR(mode) and not stat.S_ISLNK(mode) and not mode & 0o077

def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try: os.fsync(fd)
    finally: os.close(fd)

try:
    if not root_input or root != root_input: raise ValueError
    parent = os.path.dirname(root)
    created_root = not os.path.exists(root)
    if created_root:
        os.mkdir(root, 0o700); fsync_dir(parent)
    if not private_dir(root): raise ValueError
    if any(name not in allowed for name in os.listdir(root)): raise ValueError
    for name in ("projections", "applied-projections"):
        path = os.path.join(root, name)
        created = not os.path.exists(path)
        if created:
            os.mkdir(path, 0o700); fsync_dir(root)
        if not private_dir(path): raise ValueError
        for entry in os.listdir(path):
            entry_path = os.path.join(path, entry)
            mode = os.stat(entry_path, follow_symlinks=False).st_mode
            if (not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\.json", entry)
                    or not stat.S_ISREG(mode) or mode & 0o077): raise ValueError
except (OSError, ValueError):
    print("[BACKLOG-PROJECTION] outcome=rejected reason=journal_storage_invalid applied=0 waiting=0 conflicted=0 invalid=1", file=sys.stderr)
    raise SystemExit(1)
PY
}

# Prepare a deterministic projection from an exact remote backlog snapshot.
# The manifest is path-free; record locators are derived only during finalization.
# Usage: backlog_journal_prepare_projection <fresh-backlog> <base-commit>
#        <canonical-backlog-rel> <projected-output> <manifest-output>
backlog_journal_prepare_projection() {
  local backlog_file="${1:-}" base_commit="${2:-}" backlog_rel="${3:-}"
  local projected_output="${4:-}" manifest_output="${5:-}"
  local YAML_RUNTIME_ROLE=journal
  yaml_runtime_run "$backlog_file" "$base_commit" "$backlog_rel" \
    "$projected_output" "$manifest_output" <<'PY'
import datetime, decimal, fcntl, glob, hashlib, json, os, re, stat, subprocess, sys

backlog_file, base_commit, backlog_rel, projected_output, manifest_output = sys.argv[1:6]
ALLOWED = {"status", "phase_status", "started_at", "completed_at", "blocked_reason",
           "pr_url", "pr_number", "pr_status", "cost_usd"}
STATUS = {"draft", "refined", "in_progress", "done", "failed", "blocked", "cancelled",
          "superseded", "escalated", "deferred"}
STATUS_EDGES = {
    "draft": {"refined", "cancelled", "superseded"},
    "refined": {"in_progress", "blocked", "cancelled", "superseded"},
    "in_progress": {"done", "failed", "blocked", "escalated", "cancelled", "superseded"},
    "failed": {"blocked", "cancelled", "superseded"},
    "escalated": {"blocked", "cancelled", "superseded"},
    "blocked": {"draft", "refined", "in_progress", "done", "cancelled", "superseded"},
    "done": {"cancelled", "superseded"},
    "deferred": {"cancelled", "superseded"},
    "cancelled": set(), "superseded": set(),
}
PHASE = {"not_started", "planned", "implemented", "qa_passed", "qa_failed", "qa_escalated",
         "commit_stalled", "done", "failed", "escalated"}
PHASE_EDGES = {
    "not_started": {"planned", "failed"},
    "planned": {"implemented", "failed"},
    "implemented": {"qa_passed", "qa_failed", "qa_escalated", "failed"},
    "qa_failed": {"not_started", "planned", "implemented", "qa_escalated", "failed"},
    "qa_passed": {"implemented", "commit_stalled", "done", "failed", "escalated"},
    "qa_escalated": set(), "commit_stalled": set(), "done": set(), "failed": set(),
    "escalated": set(),
}
PR_STATUS = {"merged", "pending_review", "open", "closed", "closed_superseded",
             "not_created_superseded", "created", "none"}
WRITER = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+){0,7}$")
STORY = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,63}$")
HEX = re.compile(r"^[0-9a-f]{64}$")
OBJ = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
TS = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
PR_URL = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$")
COST = re.compile(r"^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$")

def canon(value): return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
def digest_bytes(value): return hashlib.sha256(value).hexdigest()
def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, text=True).strip()
def reject(reason):
    print(f"[BACKLOG-PROJECTION] outcome=rejected reason={reason} applied=0 waiting=0 conflicted=0 invalid=0", file=sys.stderr)
    raise SystemExit(1)

def closed_exception(_kind, _value, _traceback):
    print("[BACKLOG-PROJECTION] outcome=rejected reason=projection_invalid applied=0 waiting=0 conflicted=0 invalid=1", file=sys.stderr)
sys.excepthook = closed_exception

# Attested and imported by the boundary before this program runs.
import yaml

try:
    raw = open(backlog_file, "rb").read()
    text = raw.decode("utf-8")
    repo = os.path.realpath(git("rev-parse", "--show-toplevel"))
    if not OBJ.fullmatch(base_commit) or git("-C", repo, "rev-parse", "--verify", f"{base_commit}^{{commit}}") != base_commit:
        reject("base_unresolvable")
    base_blob = git("-C", repo, "rev-parse", f"{base_commit}:{backlog_rel}")
except (OSError, UnicodeError, subprocess.CalledProcessError):
    reject("base_unresolvable")

journal_input = os.path.abspath(os.environ.get("GAAI_BACKLOG_JOURNAL_DIR",
    os.path.join(os.path.dirname(os.path.realpath(backlog_file)), ".delivery-locks", "journal")))
journal_root = os.path.realpath(journal_input)
writers_root = os.path.join(journal_root, "writers")
registrations = os.path.join(journal_root, "registrations")

def private_dir(path):
    mode = os.stat(path, follow_symlinks=False).st_mode
    return stat.S_ISDIR(mode) and not mode & 0o077

try:
    if journal_input != journal_root or not private_dir(journal_root): raise ValueError
    root_entries = set(os.listdir(journal_root))
    if not root_entries <= {"registrations", "writers", "projections", "applied-projections"}: raise ValueError
    if os.path.exists(registrations):
        if not private_dir(registrations): raise ValueError
        for name in os.listdir(registrations):
            path = os.path.join(registrations, name)
            mode = os.stat(path, follow_symlinks=False).st_mode
            if not re.fullmatch(r"[0-9a-f]{64}\.json", name) or not stat.S_ISREG(mode) or mode & 0o077: raise ValueError
    if os.path.exists(writers_root) and not private_dir(writers_root): raise ValueError
except (OSError, ValueError):
    reject("journal_storage_invalid")

def scalar_ok(field, value):
    if field == "status": return isinstance(value, str) and value in STATUS
    if field == "phase_status": return isinstance(value, str) and value in PHASE
    if value is None: return True
    if field in {"started_at", "completed_at"}:
        if not isinstance(value, str) or not TS.fullmatch(value): return False
        try: datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError: return False
        return True
    if field == "blocked_reason":
        return isinstance(value, str) and bool(value) and all(
            ord(c) > 31 and not 127 <= ord(c) <= 159 and not 0xD800 <= ord(c) <= 0xDFFF
            and ord(c) not in {0x2028, 0x2029} for c in value)
    if field == "pr_url": return isinstance(value, str) and bool(PR_URL.fullmatch(value))
    if field == "pr_number": return type(value) is int and value > 0
    if field == "pr_status": return isinstance(value, str) and value in PR_STATUS
    if field == "cost_usd":
        if not isinstance(value, str) or not COST.fullmatch(value): return False
        try: return decimal.Decimal(value).is_finite() and decimal.Decimal(value) >= 0
        except decimal.InvalidOperation: return False
    return False

def load_registration(token, writer):
    path = os.path.join(registrations, f"{token}.json")
    mode = os.stat(path, follow_symlinks=False).st_mode
    if not stat.S_ISREG(mode) or mode & 0o077: raise ValueError
    with open(path, encoding="utf-8") as handle: wrapper = json.load(handle)
    reg = wrapper["registration"]
    if set(wrapper) != {"registration", "digest"} or set(reg) != {"schema_version", "run_token", "writer_context", "issued_at"}: raise ValueError
    if (reg["schema_version"] != "1.0.0" or reg["run_token"] != token
            or reg["writer_context"] != writer or not TS.fullmatch(reg["issued_at"])
            or not HEX.fullmatch(wrapper["digest"])): raise ValueError
    if digest_bytes(canon(reg).encode()) != wrapper["digest"]: raise ValueError

def load_record(path, writer):
    mode = os.stat(path, follow_symlinks=False).st_mode
    if not stat.S_ISREG(mode) or mode & 0o077: raise ValueError
    with open(path, encoding="utf-8") as handle: wrapper = json.load(handle)
    record = wrapper["record"]
    keys = {"schema_version", "story_id", "field", "old_value", "new_value", "source_commit",
            "source_blob", "writer_context", "run_token", "intent_digest", "sequence", "emitted_at"}
    if set(wrapper) != {"record", "intent_digest", "digest"} or set(record) != keys: raise ValueError
    if record["schema_version"] != "1.0.0" or record["writer_context"] != writer: raise ValueError
    if not STORY.fullmatch(record["story_id"]) or record["field"] not in ALLOWED: raise ValueError
    if not WRITER.fullmatch(writer) or not HEX.fullmatch(record["run_token"]): raise ValueError
    if not OBJ.fullmatch(record["source_commit"]) or not OBJ.fullmatch(record["source_blob"]): raise ValueError
    if (type(record["sequence"]) is not int or record["sequence"] < 1
            or not TS.fullmatch(record["emitted_at"]) or not HEX.fullmatch(wrapper["digest"])
            or not HEX.fullmatch(record["intent_digest"])): raise ValueError
    if not scalar_ok(record["field"], record["old_value"]) or not scalar_ok(record["field"], record["new_value"]): raise ValueError
    if record["field"] == "status" and record["new_value"] not in STATUS_EDGES[record["old_value"]]: raise ValueError
    if record["field"] == "phase_status" and record["new_value"] not in PHASE_EDGES[record["old_value"]]: raise ValueError
    intent = {k: record[k] for k in ("schema_version", "story_id", "field", "old_value", "new_value",
              "source_commit", "source_blob", "writer_context", "run_token")}
    if digest_bytes(canon(intent).encode()) != record["intent_digest"] or record["intent_digest"] != wrapper["intent_digest"]: raise ValueError
    if digest_bytes(canon(record).encode()) != wrapper["digest"]: raise ValueError
    expected = f"{record['sequence']:020d}-{record['intent_digest'][:16]}.json"
    if os.path.basename(path) != expected: raise ValueError
    load_registration(record["run_token"], writer)
    subprocess.check_call(["git", "-C", repo, "merge-base", "--is-ancestor", record["source_commit"], base_commit],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if git("-C", repo, "rev-parse", f"{record['source_commit']}:{backlog_rel}") != record["source_blob"]: raise ValueError
    return {"record": record, "digest": wrapper["digest"]}

def document_state(source, story_id, field):
    try:
        tokens = yaml.scan(source)
        if any(isinstance(token, (yaml.tokens.AliasToken, yaml.tokens.AnchorToken)) for token in tokens):
            raise ValueError
        root = yaml.compose(source)
    except yaml.YAMLError:
        raise ValueError
    if not isinstance(root, yaml.MappingNode): raise ValueError
    items = [v for k, v in root.value if isinstance(k, yaml.ScalarNode) and k.value == "items"]
    if len(items) != 1 or not isinstance(items[0], yaml.SequenceNode): raise ValueError
    matches = []
    for item in items[0].value:
        if not isinstance(item, yaml.MappingNode): raise ValueError
        keys = [k.value for k, _ in item.value if isinstance(k, yaml.ScalarNode)]
        if len(keys) != len(item.value) or len(keys) != len(set(keys)) or "<<" in keys: raise ValueError
        ids = [v for k, v in item.value if k.value == "id"]
        if len(ids) == 1 and isinstance(ids[0], yaml.ScalarNode) and ids[0].value == story_id: matches.append(item)
    if len(matches) != 1: raise ValueError
    item = matches[0]; fields = [v for k, v in item.value if k.value == field]
    if len(fields) > 1 or (fields and not isinstance(fields[0], yaml.ScalarNode)): raise ValueError
    if not fields:
        if field in {"status", "phase_status"}: raise ValueError
        return None, item, None
    node = fields[0]
    if node.style in {"|", ">"}: raise ValueError
    allowed_tags = {
        "status": {"tag:yaml.org,2002:str"},
        "phase_status": {"tag:yaml.org,2002:str"},
        "started_at": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:str", "tag:yaml.org,2002:timestamp"},
        "completed_at": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:str", "tag:yaml.org,2002:timestamp"},
        "blocked_reason": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:str"},
        "pr_url": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:str"},
        "pr_number": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:int"},
        "pr_status": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:str"},
        "cost_usd": {"tag:yaml.org,2002:null", "tag:yaml.org,2002:int", "tag:yaml.org,2002:float"},
    }
    if node.tag not in allowed_tags[field]: raise ValueError
    value = node.value
    if field == "cost_usd" and node.tag != "tag:yaml.org,2002:null":
        value = node.value.rstrip("0").rstrip(".") if "." in node.value else node.value
    elif field == "pr_number" and node.tag != "tag:yaml.org,2002:null":
        if not re.fullmatch(r"[1-9][0-9]*", node.value): raise ValueError
        value = int(node.value)
    elif node.tag == "tag:yaml.org,2002:null": value = None
    if not scalar_ok(field, value): raise ValueError
    return value, item, node

def render(field, value):
    if value is None: return "null"
    if field in {"status", "phase_status", "pr_status", "pr_number", "cost_usd"}: return str(value)
    return json.dumps(value, ensure_ascii=False)

valid, invalid_groups, invalid_writers = [], set(), set()
if os.path.isdir(writers_root):
    for writer_name in sorted(os.listdir(writers_root)):
        writer_dir = os.path.join(writers_root, writer_name)
        if not HEX.fullmatch(writer_name) or not private_dir(writer_dir):
            reject("journal_storage_invalid")
        records_dir = os.path.join(writer_dir, "records")
        applied_dir = os.path.join(writer_dir, "applied")
        allowed_writer_entries = {"records", "applied", ".lock", ".sequence"}
        if not set(os.listdir(writer_dir)) <= allowed_writer_entries:
            invalid_writers.add(writer_name); continue
        for required_dir in (records_dir, applied_dir):
            if not os.path.exists(required_dir) or not private_dir(required_dir):
                invalid_writers.add(writer_name)
        for metadata_name in (".lock", ".sequence"):
            metadata_path = os.path.join(writer_dir, metadata_name)
            if os.path.exists(metadata_path):
                mode = os.stat(metadata_path, follow_symlinks=False).st_mode
                if not stat.S_ISREG(mode) or mode & 0o077: invalid_writers.add(writer_name)
        if writer_name in invalid_writers: continue
        paths = []
        unknown_sequences = []
        for directory, pending in ((applied_dir, False), (records_dir, True)):
            for name in os.listdir(directory):
                path = os.path.join(directory, name)
                if re.fullmatch(r"[0-9]{20}-[0-9a-f]{16}\.json", name):
                    paths.append((path, pending)); continue
                match = re.match(r"^\.?([0-9]{20})-", name)
                if pending and match and int(match.group(1)) > 0:
                    unknown_sequences.append(int(match.group(1))); continue
                invalid_writers.add(writer_name)
        if writer_name in invalid_writers: continue
        paths.sort(key=lambda entry: (os.path.basename(entry[0]), 1 if entry[1] else 0))
        writer_valid = []
        observed_sequences = set()
        invalid_cutoff = min(unknown_sequences) if unknown_sequences else None
        observed_sequences.update(unknown_sequences)
        for path, pending in paths:
            locator_trusted = False
            try:
                path_mode = os.stat(path, follow_symlinks=False).st_mode
                if not stat.S_ISREG(path_mode) or path_mode & 0o077: raise ValueError
                with open(path, encoding="utf-8") as handle: probe = json.load(handle)
                probe_record = probe.get("record", {})
                writer = probe_record.get("writer_context", "")
                story = probe_record.get("story_id", "")
                field = probe_record.get("field", "")
                sequence = probe_record.get("sequence")
                intent_digest = probe_record.get("intent_digest", "")
                locator_trusted = (bool(STORY.fullmatch(story or "")) and field in ALLOWED
                    and type(sequence) is int and sequence > 0 and bool(HEX.fullmatch(intent_digest or ""))
                    and os.path.basename(path) == f"{sequence:020d}-{intent_digest[:16]}.json")
                loaded = load_record(path, writer)
                if digest_bytes(writer.encode()) != os.path.basename(writer_dir): raise ValueError
                if sequence in observed_sequences:
                    if locator_trusted and pending:
                        invalid_groups.add((story, field))
                        invalid_cutoff = sequence if invalid_cutoff is None else min(invalid_cutoff, sequence)
                        continue
                    invalid_writers.add(writer_name); break
                observed_sequences.add(sequence)
                if pending: writer_valid.append(loaded)
            except Exception:
                if locator_trusted and pending:
                    invalid_groups.add((story, field)); observed_sequences.add(sequence)
                    invalid_cutoff = sequence if invalid_cutoff is None else min(invalid_cutoff, sequence)
                    continue
                invalid_writers.add(os.path.basename(writer_dir)); break
        if os.path.basename(writer_dir) not in invalid_writers:
            if observed_sequences and observed_sequences != set(range(1, max(observed_sequences) + 1)):
                invalid_writers.add(os.path.basename(writer_dir)); continue
            valid.extend(entry for entry in writer_valid
                         if invalid_cutoff is None or entry["record"]["sequence"] < invalid_cutoff)

queues = {}
for entry in valid:
    record = entry["record"]
    if (digest_bytes(record["writer_context"].encode()) in invalid_writers
            or (record["story_id"], record["field"]) in invalid_groups): continue
    queues.setdefault(record["writer_context"], []).append(entry)
for queue in queues.values(): queue.sort(key=lambda entry: entry["record"]["sequence"])

selected, waiting_ids, conflicted_ids, audit_edits = [], set(), set(), []
blocked_writers, processed_groups = set(), set()
working = text

def entry_id(entry):
    record = entry["record"]
    return (record["writer_context"], record["sequence"], record["intent_digest"])

while True:
    heads = [queue[0] for writer, queue in queues.items() if queue and writer not in blocked_writers]
    groups = {}
    for entry in heads:
        record = entry["record"]
        key = (record["story_id"], record["field"])
        if key not in processed_groups: groups.setdefault(key, []).append(entry)
    if not groups: break
    key = min(groups, key=lambda group: (group[0], group[1], min(e["digest"] for e in groups[group])))
    entries = sorted(groups[key], key=lambda entry: entry["digest"])
    try: current, _, _ = document_state(working, *key)
    except ValueError:
        invalid_groups.add(key)
        blocked_writers.update(entry["record"]["writer_context"] for entry in entries)
        processed_groups.add(key)
        continue
    eligible = [e for e in entries if e["record"]["old_value"] == current]
    if not eligible:
        conflicted_ids.update(entry_id(entry) for entry in entries)
        blocked_writers.update(entry["record"]["writer_context"] for entry in entries)
        processed_groups.add(key)
        continue
    if len(eligible) > 1:
        conflicted_ids.update(entry_id(entry) for entry in entries)
        blocked_writers.update(entry["record"]["writer_context"] for entry in entries)
        processed_groups.add(key)
        continue
    chosen = eligible[0]
    for entry in entries:
        if entry is chosen: continue
        if entry["record"]["old_value"] == chosen["record"]["new_value"]:
            waiting_ids.add(entry_id(entry))
        else:
            conflicted_ids.add(entry_id(entry))
        blocked_writers.add(entry["record"]["writer_context"])
    try:
        _, audit_item, audit_node = document_state(text, *key)
        replacement = render(key[1], chosen["record"]["new_value"])
        if audit_node is not None:
            audit_start, audit_end = audit_node.start_mark.index, audit_node.end_mark.index
            audit_replacement = replacement
        else:
            audit_last_end = max(value.end_mark.index for _, value in audit_item.value)
            audit_line_end = text.find("\n", audit_last_end)
            audit_start = len(text) if audit_line_end < 0 else audit_line_end + 1
            audit_end = audit_start
            audit_replacement = f"  {key[1]}: {replacement}\n"
        audit_edits.append((audit_start, audit_end, audit_replacement))
        _, item, node = document_state(working, *key)
        if node is not None:
            start, end = node.start_mark.index, node.end_mark.index
            before = working; working = before[:start] + replacement + before[end:]
            if working[:start] != before[:start] or working[start + len(replacement):] != before[end:]: raise ValueError
        else:
            last_end = max(v.end_mark.index for _, v in item.value)
            line_end = working.find("\n", last_end)
            insert_at = len(working) if line_end < 0 else line_end + 1
            insertion = f"  {key[1]}: {replacement}\n"
            before = working; working = before[:insert_at] + insertion + before[insert_at:]
            if working[:insert_at] != before[:insert_at] or working[insert_at + len(insertion):] != before[insert_at:]: raise ValueError
        new_state, _, _ = document_state(working, *key)
        if new_state != chosen["record"]["new_value"]: raise ValueError
    except ValueError:
        invalid_groups.add(key)
        blocked_writers.update(entry["record"]["writer_context"] for entry in entries)
        processed_groups.add(key)
        continue
    selected.append({"story_id": key[0], "field": key[1], "writer_context": chosen["record"]["writer_context"],
                     "sequence": chosen["record"]["sequence"], "intent_digest": chosen["record"]["intent_digest"],
                     "journal_digest": chosen["digest"]})
    queues[chosen["record"]["writer_context"]].pop(0)
    processed_groups.add(key)

selected_ids = {(entry["writer_context"], entry["sequence"], entry["intent_digest"]) for entry in selected}
for queue in queues.values():
    for entry in queue:
        identifier = entry_id(entry)
        if identifier not in selected_ids and identifier not in conflicted_ids:
            waiting_ids.add(identifier)

# Independently rebuild the only byte string authorized by the base-relative
# scalar spans. This catches any mutation outside the selected Story/field
# boundaries, including injected drift after the projection loop.
if os.environ.get("GAAI_BACKLOG_PROJECTION_FAULT") == "unrelated_byte":
    working += "# unauthorized projection drift\n"
grouped_edits = {}
for start, end, replacement in audit_edits:
    grouped_edits.setdefault((start, end), []).append(replacement)
cursor, expected_parts = 0, []
for (start, end), replacements in sorted(grouped_edits.items()):
    if start < cursor or end < start or (end > start and len(replacements) != 1):
        reject("byte_audit_failed")
    expected_parts.append(text[cursor:start])
    expected_parts.append("".join(replacements))
    cursor = end
expected_parts.append(text[cursor:])
if "".join(expected_parts) != working:
    reject("byte_audit_failed")

invalid = len(invalid_writers) + len(invalid_groups)
manifest = {"schema_version": "1.0.0", "base_commit": base_commit, "base_blob": base_blob,
            "result_digest": digest_bytes(working.encode()), "selected": selected,
            "counts": {"applied": len(selected), "waiting": len(waiting_ids),
                       "conflicted": len(conflicted_ids), "invalid": invalid}}
try:
    with open(projected_output, "wb") as handle: handle.write(working.encode()); handle.flush(); os.fsync(handle.fileno())
    with open(manifest_output, "w", encoding="utf-8") as handle: handle.write(canon(manifest) + "\n"); handle.flush(); os.fsync(handle.fileno())
except OSError: reject("output_write_failed")
print(f"[BACKLOG-PROJECTION] outcome=prepared reason=none applied={len(selected)} waiting={len(waiting_ids)} conflicted={len(conflicted_ids)} invalid={invalid}", file=sys.stderr)
PY
}

# Seal the path-free prepared manifest to an exact Git candidate.
backlog_journal_seal_projection() {
  local manifest="${1:-}" result_blob="${2:-}" candidate_commit="${3:-}"
  local candidate_tree="${4:-}" output="${5:-}"
  python3 - "$manifest" "$result_blob" "$candidate_commit" "$candidate_tree" "$output" <<'PY'
import hashlib, json, os, re, sys

def closed_exception(_kind, _value, _traceback):
    print("[BACKLOG-PROJECTION] outcome=rejected reason=seal_invalid applied=0 waiting=0 conflicted=0 invalid=1", file=sys.stderr)
sys.excepthook = closed_exception

manifest_path, result_blob, commit, tree, output = sys.argv[1:6]
hex_object = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
if not all(hex_object.fullmatch(v) for v in (result_blob, commit, tree)): raise ValueError
manifest = json.load(open(manifest_path, encoding="utf-8"))
attempt = dict(manifest); attempt.update({"result_blob": result_blob, "candidate_commit": commit,
    "candidate_tree": tree, "outcome": "sealed"})
canonical = json.dumps(attempt, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
wrapper = {"attempt": attempt, "digest": hashlib.sha256(canonical.encode()).hexdigest()}
payload = (json.dumps(wrapper, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
tmp = f"{output}.{os.getpid()}.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0: raise OSError("short write")
        view = view[written:]
    os.fsync(fd)
finally: os.close(fd)
os.replace(tmp, output)
directory_fd = os.open(os.path.dirname(os.path.realpath(output)), os.O_RDONLY)
try: os.fsync(directory_fd)
finally: os.close(directory_fd)
PY
}

# Retire only records proven by the sealed candidate and current remote history.
backlog_journal_finalize_projection() {
  local attempt_path="${1:-}" repo="${2:-}" backlog_rel="${3:-}" remote_commit="${4:-}"
  python3 - "$attempt_path" "$repo" "$backlog_rel" "$remote_commit" <<'PY'
import fcntl, hashlib, json, os, re, stat, subprocess, sys

def closed_exception(_kind, _value, _traceback):
    print("[BACKLOG-PROJECTION] outcome=rejected reason=finalization_invalid applied=0 waiting=0 conflicted=0 invalid=1", file=sys.stderr)
sys.excepthook = closed_exception

attempt_path, repo, backlog_rel, remote_commit = sys.argv[1:5]
OBJ = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
HEX = re.compile(r"^[0-9a-f]{64}$")
WRITER = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+){0,7}$")
STORY = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,63}$")
FIELD = {"status", "phase_status", "started_at", "completed_at", "blocked_reason",
         "pr_url", "pr_number", "pr_status", "cost_usd"}
attempt_mode = os.stat(attempt_path, follow_symlinks=False).st_mode
if not stat.S_ISREG(attempt_mode) or attempt_mode & 0o077: raise ValueError
with open(attempt_path, encoding="utf-8") as handle: wrapper = json.load(handle)
if set(wrapper) != {"attempt", "digest"} or not HEX.fullmatch(wrapper.get("digest", "")): raise ValueError
attempt = wrapper["attempt"]
attempt_keys = {"schema_version", "base_commit", "base_blob", "result_digest", "selected",
    "counts", "result_blob", "candidate_commit", "candidate_tree", "outcome"}
if set(attempt) != attempt_keys or attempt["schema_version"] != "1.0.0" or attempt["outcome"] != "sealed": raise ValueError
if (not all(OBJ.fullmatch(attempt[key]) for key in ("base_commit", "base_blob", "result_blob",
        "candidate_commit", "candidate_tree")) or not HEX.fullmatch(attempt["result_digest"])): raise ValueError
if (os.path.isabs(backlog_rel) or os.path.normpath(backlog_rel) != backlog_rel
        or backlog_rel == ".." or backlog_rel.startswith("../") or not OBJ.fullmatch(remote_commit)): raise ValueError
if set(attempt["counts"]) != {"applied", "waiting", "conflicted", "invalid"}: raise ValueError
if any(type(value) is not int or value < 0 for value in attempt["counts"].values()): raise ValueError
if not isinstance(attempt["selected"], list) or attempt["counts"]["applied"] != len(attempt["selected"]): raise ValueError
selected_keys = {"story_id", "field", "writer_context", "sequence", "intent_digest", "journal_digest"}
locators = set()
writer_sequences = {}
for selected in attempt["selected"]:
    if (set(selected) != selected_keys or not STORY.fullmatch(selected["story_id"])
            or selected["field"] not in FIELD or not WRITER.fullmatch(selected["writer_context"])
            or type(selected["sequence"]) is not int or selected["sequence"] < 1
            or not HEX.fullmatch(selected["intent_digest"]) or not HEX.fullmatch(selected["journal_digest"])): raise ValueError
    locator = (selected["writer_context"], selected["sequence"], selected["intent_digest"])
    if locator in locators: raise ValueError
    locators.add(locator)
    prior_sequence = writer_sequences.get(selected["writer_context"], 0)
    if selected["sequence"] <= prior_sequence: raise ValueError
    writer_sequences[selected["writer_context"]] = selected["sequence"]
canon = json.dumps(attempt, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
if hashlib.sha256(canon.encode()).hexdigest() != wrapper.get("digest"): raise ValueError
candidate = attempt["candidate_commit"]
subprocess.check_call(["git", "-C", repo, "merge-base", "--is-ancestor", candidate, remote_commit],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
commit_line = subprocess.check_output(["git", "-C", repo, "rev-list", "--parents", "-n", "1", candidate], text=True).split()
if len(commit_line) != 2 or commit_line[1] != attempt["base_commit"]: raise ValueError
tree = subprocess.check_output(["git", "-C", repo, "rev-parse", f"{candidate}^{{tree}}"], text=True).strip()
if tree != attempt["candidate_tree"]: raise ValueError
base_blob = subprocess.check_output(["git", "-C", repo, "rev-parse", f"{attempt['base_commit']}:{backlog_rel}"], text=True).strip()
if base_blob != attempt["base_blob"]: raise ValueError
blob = subprocess.check_output(["git", "-C", repo, "rev-parse", f"{candidate}:{backlog_rel}"], text=True).strip()
if blob != attempt["result_blob"]: raise ValueError
result = subprocess.check_output(["git", "-C", repo, "cat-file", "blob", blob])
if hashlib.sha256(result).hexdigest() != attempt["result_digest"]: raise ValueError
backlog_dir = os.path.dirname(os.path.realpath(os.path.join(repo, backlog_rel)))
root_input = os.path.abspath(os.environ.get("GAAI_BACKLOG_JOURNAL_DIR", os.path.join(backlog_dir, ".delivery-locks", "journal")))
root = os.path.realpath(root_input)
root_mode = os.stat(root_input, follow_symlinks=False).st_mode
if root != root_input or not stat.S_ISDIR(root_mode) or root_mode & 0o077: raise ValueError
for selected in attempt["selected"]:
    writer = selected["writer_context"]; writer_key = hashlib.sha256(writer.encode()).hexdigest()
    writers_dir = os.path.join(root, "writers")
    writer_dir = os.path.join(writers_dir, writer_key); records = os.path.join(writer_dir, "records")
    applied = os.path.join(writer_dir, "applied")
    if not os.path.exists(applied):
        os.mkdir(applied, 0o700)
        writer_fd = os.open(writer_dir, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try: os.fsync(writer_fd)
        finally: os.close(writer_fd)
    if any(not stat.S_ISDIR(os.stat(directory, follow_symlinks=False).st_mode)
           or os.stat(directory, follow_symlinks=False).st_mode & 0o077
           for directory in (writers_dir, writer_dir, records, applied)): raise ValueError
    name = f"{selected['sequence']:020d}-{selected['intent_digest'][:16]}.json"
    source = os.path.join(records, name); destination = os.path.join(applied, name)
    if os.environ.get("GAAI_BACKLOG_PROJECTION_FAULT") == "finalize_missing_record":
        source = f"{source}.missing"
    elif os.environ.get("GAAI_BACKLOG_PROJECTION_FAULT") == "finalize_malformed_record":
        source = attempt_path
    lock_fd = os.open(os.path.join(writer_dir, ".lock"), os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(lock_fd, "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if os.path.exists(destination):
            destination_mode = os.stat(destination, follow_symlinks=False).st_mode
            if not stat.S_ISREG(destination_mode) or destination_mode & 0o077: raise ValueError
            with open(destination, encoding="utf-8") as handle: data = json.load(handle)
        else:
            mode = os.stat(source, follow_symlinks=False).st_mode
            if not stat.S_ISREG(mode) or mode & 0o077: raise ValueError
            with open(source, encoding="utf-8") as handle: data = json.load(handle)
        if data.get("digest") != selected["journal_digest"] or data.get("intent_digest") != selected["intent_digest"]: raise ValueError
        record = data.get("record", {})
        if (record.get("story_id") != selected["story_id"] or record.get("field") != selected["field"]
                or record.get("writer_context") != writer or record.get("sequence") != selected["sequence"]): raise ValueError
        if not os.path.exists(destination):
            os.replace(source, destination)
        elif os.path.exists(source):
            with open(source, encoding="utf-8") as handle: source_data = json.load(handle)
            if source_data != data: raise ValueError
            os.unlink(source)
        for directory in (records, applied):
            directory_fd = os.open(directory, os.O_RDONLY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
print(f"[BACKLOG-PROJECTION] outcome=applied reason=none applied={len(attempt['selected'])} waiting={attempt['counts']['waiting']} conflicted={attempt['counts']['conflicted']} invalid={attempt['counts']['invalid']}", file=sys.stderr)
PY
}

# Archive a finalized sealed attempt and durably persist both directory entries.
backlog_journal_archive_projection() {
  local source="${1:-}" destination_dir="${2:-}"
  python3 - "$source" "$destination_dir" <<'PY'
import os, stat, sys
source, destination_dir = sys.argv[1:3]
try:
    source_dir = os.path.dirname(os.path.realpath(source))
    if os.path.realpath(source) != os.path.abspath(source): raise ValueError
    for directory in (source_dir, destination_dir):
        mode = os.stat(directory, follow_symlinks=False).st_mode
        if not stat.S_ISDIR(mode) or mode & 0o077: raise ValueError
    source_mode = os.stat(source, follow_symlinks=False).st_mode
    if not stat.S_ISREG(source_mode) or source_mode & 0o077: raise ValueError
    destination = os.path.join(destination_dir, os.path.basename(source))
    if os.path.exists(destination): raise ValueError
    if os.environ.get("GAAI_BACKLOG_PROJECTION_FAULT") == "archive_helper_failure":
        raise OSError
    os.replace(source, destination)
    for directory in (source_dir, destination_dir):
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try: os.fsync(fd)
        finally: os.close(fd)
except (OSError, ValueError):
    print("[BACKLOG-PROJECTION] outcome=rejected reason=archive_invalid applied=0 waiting=0 conflicted=0 invalid=1", file=sys.stderr)
    raise SystemExit(1)
PY
}
