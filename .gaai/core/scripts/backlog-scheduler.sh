#!/usr/bin/env bash
set -euo pipefail

############################################################
# Backlog Scheduler — GAAI
#
# Description:
#   Selects the next ready Story from the active backlog.
#   Reads active.backlog.yaml, finds items with status: refined
#   or ready, sorts by priority, checks dependencies, and returns
#   the first actionable item.
#
#   Also supports: listing all ready items, outputting ready
#   IDs, showing a dependency graph, detecting priority
#   conflicts, and updating story status in-place.
#
# Usage:
#   ./scripts/backlog-scheduler.sh [options] <backlog-active-yaml>
#   echo "$yaml" | ./scripts/backlog-scheduler.sh --stdin [options]
#
# Options:
#   --next          Select next ready item (default)
#   --list          List all ready items sorted by priority
#   --ready-ids     Output ready story IDs, one per line
#   --graph         Show dependency graph for all active items
#   --conflicts     Show priority conflicts (high-priority items
#                   blocked by lower-priority dependencies)
#   --set-status <id> <status>  Update a story's status in the
#                   YAML file. Requires file path (not --stdin).
#   --set-field <id> <field> <value>  Set any field on a backlog
#                   item. Updates if exists, inserts after delivery
#                   metadata fields if not. Numbers and null/true/
#                   false stay bare; safe flow-style sequences of
#                   plain scalars are normalized and stay bare;
#                   bracket-delimited values are interpreted as
#                   sequences, and other strings are auto-quoted.
#                   Requires file path (not --stdin).
#   --journal-set <id> <field> <value>  Mint or validate a run token,
#                   durably emit one policy-authorized lifecycle record,
#                   then apply the record's canonical typed value only for
#                   the unique emitted outcome. For blocked_reason, literal
#                   null means YAML null and json:<JSON-string> means text.
#                   Replay remains pending evidence.
#                   Requires file path (not --stdin).
#   --stdin         Read YAML from stdin instead of file
#
# Inputs:
#   positional — path to active.backlog.yaml (unless --stdin)
#
# Outputs:
#   stdout — ID of the next ready backlog item (--next),
#            ready IDs one per line (--ready-ids),
#            or formatted list/graph/conflicts report
#
# Exit codes:
#   0 — success
#   1 — usage error
#   2 — file not found
#   3 — python3 not available
#   4 — journal library unavailable
#   5 — journal policy rejected or evidence is ambiguous
#   6 — exact replay is pending and non-authorizing
############################################################

MODE="next"
BACKLOG_FILE=""
FROM_STDIN=false
SET_STATUS_ID=""
SET_STATUS_VAL=""
SET_FIELD_ID=""
SET_FIELD_NAME=""
SET_FIELD_VAL=""
SET_FIELD_FORCE_STRING="false"
JOURNAL_ID=""
JOURNAL_FIELD=""
JOURNAL_VAL=""
SET_PHASE_STATUS_ID=""
SET_PHASE_STATUS_VAL=""
SET_PIPELINE_ID=""
SET_PIPELINE_VAL=""
RESET_ID=""
RESET_CLEAR_RETRY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --next)       MODE="next";       shift ;;
    --list)       MODE="list";       shift ;;
    --ready-ids)  MODE="ready-ids";  shift ;;
    --graph)      MODE="graph";      shift ;;
    --conflicts)  MODE="conflicts";  shift ;;
    --set-status)
      MODE="set-status"
      SET_STATUS_ID="${2:-}"
      SET_STATUS_VAL="${3:-}"
      if [[ -z "$SET_STATUS_ID" || -z "$SET_STATUS_VAL" ]]; then
        >&2 echo "Error: --set-status requires <id> and <status>"
        >&2 echo "Usage: $0 --set-status <id> <status> <backlog-active-yaml>"
        exit 1
      fi
      shift 3
      ;;
    --set-field)
      MODE="set-field"
      SET_FIELD_ID="${2:-}"
      SET_FIELD_NAME="${3:-}"
      SET_FIELD_VAL="${4:-}"
      if [[ -z "$SET_FIELD_ID" || -z "$SET_FIELD_NAME" ]]; then
        >&2 echo "Error: --set-field requires <id> <field> <value>"
        >&2 echo "Usage: $0 --set-field <id> <field> <value> <backlog-active-yaml>"
        exit 1
      fi
      shift 4
      ;;
    --journal-set)
      MODE="journal-set"
      JOURNAL_ID="${2:-}"
      JOURNAL_FIELD="${3:-}"
      JOURNAL_VAL="${4:-}"
      if [[ -z "$JOURNAL_ID" || -z "$JOURNAL_FIELD" || -z "$JOURNAL_VAL" ]]; then
        >&2 echo "Error: --journal-set requires <id> <field> <value>"
        >&2 echo "Usage: $0 --journal-set <id> <field> <value> <backlog-active-yaml>"
        exit 1
      fi
      shift 4
      ;;
    --set-phase-status)
      MODE="set-phase-status"
      SET_PHASE_STATUS_ID="${2:-}"
      SET_PHASE_STATUS_VAL="${3:-}"
      if [[ -z "$SET_PHASE_STATUS_ID" || -z "$SET_PHASE_STATUS_VAL" ]]; then
        >&2 echo "Error: --set-phase-status requires <id> and <phase_status_value>"
        >&2 echo "Usage: $0 --set-phase-status <id> <phase_status_value> <backlog-active-yaml>"
        exit 1
      fi
      shift 3
      ;;
    --set-pipeline)
      MODE="set-pipeline"
      SET_PIPELINE_ID="${2:-}"
      SET_PIPELINE_VAL="${3:-}"
      if [[ -z "$SET_PIPELINE_ID" || -z "$SET_PIPELINE_VAL" ]]; then
        >&2 echo "Error: --set-pipeline requires <id> and <legacy|3phase>"
        >&2 echo "Usage: $0 --set-pipeline <id> <legacy|3phase> <backlog-active-yaml>"
        exit 1
      fi
      shift 3
      ;;
    --reset)
      MODE="reset"
      RESET_ID="${2:-}"
      if [[ -z "$RESET_ID" ]]; then
        >&2 echo "Error: --reset requires <id>"
        >&2 echo "Usage: $0 --reset <id> [--clear-retry-count] <backlog-active-yaml>"
        exit 1
      fi
      shift 2
      ;;
    --clear-retry-count)
      RESET_CLEAR_RETRY="true"
      shift
      ;;
    --stdin)      FROM_STDIN=true;   shift ;;
    -*)
      >&2 echo "Unknown option: $1"
      >&2 echo "Usage: $0 [--next|--list|--ready-ids|--graph|--conflicts|--set-status <id> <status>|--set-field <id> <field> <value>|--journal-set <id> <field> <value>|--set-phase-status <id> <phase_status_value>|--set-pipeline <id> <legacy|3phase>|--reset <id> [--clear-retry-count]] [--stdin] [<backlog-active-yaml>]"
      exit 1
      ;;
    *)
      BACKLOG_FILE="$1"
      shift
      ;;
  esac
done

# ── Validate inputs ──────────────────────────────────────────
if [[ "$MODE" == "set-status" || "$MODE" == "set-field" || \
      "$MODE" == "journal-set" || \
      "$MODE" == "set-phase-status" || "$MODE" == "set-pipeline" || \
      "$MODE" == "reset" ]]; then
  # These modes always operate on a file (not stdin)
  if [[ -z "$BACKLOG_FILE" ]]; then
    >&2 echo "Error: --$MODE requires a backlog file path"
    >&2 echo "Usage: $0 --$MODE ... <backlog-active-yaml>"
    exit 1
  fi
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    >&2 echo "Error: backlog file '$BACKLOG_FILE' not found"
    exit 2
  fi
elif ! $FROM_STDIN; then
  if [[ -z "$BACKLOG_FILE" ]]; then
    >&2 echo "Usage: $0 [--next|--list|--ready-ids|--graph|--conflicts] [--stdin] [<backlog-active-yaml>]"
    >&2 echo "Example: $0 .gaai/project/contexts/backlog/active.backlog.yaml"
    exit 1
  fi
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    >&2 echo "Error: backlog file '$BACKLOG_FILE' not found"
    exit 2
  fi
fi

# This guard covers the stdlib-only Python modes (--list, --next, --ready-ids,
# --graph, --conflicts, --set-status, archive handling). They import no YAML and
# must keep working with nothing but python3, so neither the guard nor its exit
# code changes here.
if ! command -v python3 &>/dev/null; then
  >&2 echo "Error: python3 is required for backlog-scheduler.sh"
  exit 3
fi

# ── YAML-validating branches only ─────────────────────────────────────────────
# The four branches that parse YAML use the repository-controlled runtime
# boundary. The boundary is loaded inside those branches, never at file scope, so
# the stdlib-only modes above acquire no runtime-tuple dependency.
_scheduler_source_yaml_boundary() {
  if [[ -z "${_YAML_RUNTIME_SH_SOURCED:-}" ]]; then
    if ! source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/yaml-runtime.sh"; then
      >&2 echo "Error: YAML runtime boundary unavailable"
      return 30
    fi
  fi
  return 0
}

# Post-write validation of the file that was just written. The parse-error
# disposition is unchanged (a warning, existing exit code); an unavailable or
# untrusted runtime is now a hard error instead of a silent skip.
_scheduler_validate_after_write() {
  # This runs AFTER the mutation is on disk, so its status must not be read as
  # "the mutation failed". A caller that treats a non-zero exit that way will
  # re-drive a write that already happened, or report to a human that nothing
  # changed when something did.
  #
  # Two outcomes are therefore separated. A parse error (36) means the write
  # produced a document the boundary refuses -- that is about the file, and it is
  # already surfaced as a warning without claiming the write failed. Every other
  # non-zero status means the boundary itself could not run (missing tuple,
  # unusable interpreter, invalid manifest). The mutation still succeeded; only
  # the post-write check is unavailable. Saying so, and returning 0, keeps the
  # caller's contract honest: exit status describes the MUTATION, and a check
  # that could not run is reported on stderr rather than impersonating a failure.
  local file="$1" rc=0
  local YAML_RUNTIME_ROLE=scheduler
  if ! _scheduler_source_yaml_boundary; then
    >&2 echo "Warning: the YAML runtime is unavailable — the write completed but was not re-validated"
    return 0
  fi
  yaml_runtime_validate_file "$file" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 36 ]]; then
    >&2 echo "Warning: YAML validation after write reported a parse error"
    return 0
  fi
  >&2 echo "Warning: the YAML runtime could not validate after the write (code $rc) — the write itself completed"
  return 0
}

# ── set-status mode: modify file in-place ────────────────────
if [[ "$MODE" == "set-status" ]]; then
  python3 -c "
import sys, re

file_path, target_id, new_status = sys.argv[1], sys.argv[2], sys.argv[3]

with open(file_path, 'r') as f:
    lines = f.readlines()

in_target = False
modified = False
target_block_start = None
target_block_end = None

for i, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r'-\s+id:\s+' + re.escape(target_id) + r'\s*$', stripped):
        in_target = True
        target_block_start = i
        continue
    if in_target:
        if re.match(r'-\s+id:\s+', stripped):
            target_block_end = i
            break
        m = re.match(r'^(\s+status:\s+)\S+', line)
        if m:
            lines[i] = m.group(1) + new_status + '\n'
            modified = True
            break

if not modified:
    print(f'Error: could not update status for {target_id}', file=sys.stderr)
    sys.exit(1)

# ── Hard-gate guard on draft → refined transition ──────────
# Refuse to promote a story to 'refined' if it has an invalid
# tier x impl_model combination that the Impl-phase daemon
# would reject. Catches the landmine at promotion time instead
# of at dispatch time.
if new_status == 'refined' and target_block_start is not None:
    end = target_block_end if target_block_end is not None else len(lines)
    block = lines[target_block_start:end]
    impl_model = None
    tier = None
    for bl in block:
        ms = re.match(r'^\s+impl_model:\s+([\w\-]+)', bl)
        if ms:
            impl_model = ms.group(1).strip()
        mt = re.match(r'^\s+tier:\s+([\w\-]+)', bl)
        if mt:
            try:
                tier = int(mt.group(1))
            except ValueError:
                pass
    if impl_model == 'secondary' and tier is not None and tier >= 2:
        print(
            f'Error: refusing to promote {target_id} to refined - '
            f'tier {tier} + impl_model: secondary is rejected by the '
            f'daemon Impl-phase hard gate.',
            file=sys.stderr)
        print(
            'Fix one of: (a) decompose to Tier 1 sub-stories per '
            'the story-scope-discipline pattern, (b) remove impl_model: '
            'secondary (the tier-aware default routes to primary), '
            'or (c) set impl_model: primary explicitly.',
            file=sys.stderr)
        sys.exit(2)

with open(file_path, 'w') as f:
    f.writelines(lines)

print(f'{target_id} -> {new_status}')
" "$BACKLOG_FILE" "$SET_STATUS_ID" "$SET_STATUS_VAL"
  exit $?
fi

# ── set-phase-status mode ────────────────────────────────────
if [[ "$MODE" == "set-phase-status" ]]; then
  python3 -c "
import sys, re

VALID = {'not_started','planned','implemented','qa_passed','qa_failed','qa_escalated',
         'commit_stalled','done','failed','escalated','deferred','cancelled','superseded'}

file_path, target_id, new_value = sys.argv[1], sys.argv[2], sys.argv[3]

if new_value not in VALID:
    print(f'Error: invalid phase_status value: {new_value}', file=sys.stderr)
    print(f'Valid values: {sorted(VALID)}', file=sys.stderr)
    sys.exit(1)

with open(file_path, 'r') as f:
    lines = f.readlines()

in_target = False
modified = False

for i, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r'-\s+id:\s+' + re.escape(target_id) + r'\s*$', stripped):
        in_target = True
        continue
    if in_target:
        if re.match(r'-\s+id:\s+', stripped):
            break
        m = re.match(r'^(\s+phase_status:\s+)\S+', line)
        if m:
            lines[i] = m.group(1) + new_value + '\n'
            modified = True
            break

if not modified:
    print(f'Error: phase_status field not found for {target_id}', file=sys.stderr)
    sys.exit(1)

with open(file_path, 'w') as f:
    f.writelines(lines)

print(f'{target_id} phase_status -> {new_value}')
" "$BACKLOG_FILE" "$SET_PHASE_STATUS_ID" "$SET_PHASE_STATUS_VAL"
  _SCHED_RC=$?
  if [[ "$_SCHED_RC" -eq 0 ]]; then
    _scheduler_validate_after_write "$BACKLOG_FILE" || exit $?
  fi
  exit "$_SCHED_RC"
fi

# ── set-pipeline mode ─────────────────────────────────────────
if [[ "$MODE" == "set-pipeline" ]]; then
  python3 -c "
import sys, re

VALID = {'legacy', '3phase'}

file_path, target_id, new_value = sys.argv[1], sys.argv[2], sys.argv[3]

if new_value not in VALID:
    print(f'Error: invalid delivery_pipeline value: {new_value}', file=sys.stderr)
    print(f'Valid values: {sorted(VALID)}', file=sys.stderr)
    sys.exit(1)

with open(file_path, 'r') as f:
    lines = f.readlines()

in_target = False
modified = False

for i, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r'-\s+id:\s+' + re.escape(target_id) + r'\s*$', stripped):
        in_target = True
        continue
    if in_target:
        if re.match(r'-\s+id:\s+', stripped):
            break
        m = re.match(r'^(\s+delivery_pipeline:\s+)\S+', line)
        if m:
            lines[i] = m.group(1) + new_value + '\n'
            modified = True
            break

if not modified:
    print(f'Error: delivery_pipeline field not found for {target_id}', file=sys.stderr)
    sys.exit(1)

with open(file_path, 'w') as f:
    f.writelines(lines)

print(f'{target_id} pipeline -> {new_value}')
" "$BACKLOG_FILE" "$SET_PIPELINE_ID" "$SET_PIPELINE_VAL"
  _SCHED_RC=$?
  if [[ "$_SCHED_RC" -eq 0 ]]; then
    _scheduler_validate_after_write "$BACKLOG_FILE" || exit $?
  fi
  exit "$_SCHED_RC"
fi

# ── reset mode: atomically reset status + phase_status + started_at ─────────
if [[ "$MODE" == "reset" ]]; then
  python3 -c "
import sys, re, os

file_path   = sys.argv[1]
target_id   = sys.argv[2]
clear_retry = sys.argv[3] == 'true'

with open(file_path, 'r') as f:
    lines = f.readlines()

# Locate target block boundaries
block_start = -1
block_end   = len(lines)
for i, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r'-\s+id:\s+' + re.escape(target_id) + r'\s*$', stripped):
        block_start = i
        continue
    if block_start >= 0 and re.match(r'-\s+id:\s+', stripped):
        block_end = i
        break

if block_start < 0:
    print(f'Error: story {target_id} not found in backlog', file=sys.stderr)
    sys.exit(1)

block = lines[block_start:block_end]

# Idempotency check
cur_status       = None
cur_phase_status = None
for bl in block:
    ms = re.match(r'^\s+status:\s+(\S+)', bl)
    if ms:
        cur_status = ms.group(1).strip()
    mp = re.match(r'^\s+phase_status:\s+(\S+)', bl)
    if mp:
        cur_phase_status = mp.group(1).strip()

if cur_status == 'refined' and cur_phase_status == 'not_started':
    print(f'{target_id} already status:refined + phase_status:not_started — no-op', file=sys.stderr)
    sys.exit(0)

# Apply atomic edits
status_done = False
phase_done  = False
new_lines   = list(lines)

for i in range(block_start, block_end):
    line     = new_lines[i]
    stripped = line.strip()
    if not status_done:
        m = re.match(r'^(\s+status:\s+)\S+', line)
        if m:
            new_lines[i] = m.group(1) + 'refined\n'
            status_done = True
            continue
    if not phase_done:
        m = re.match(r'^(\s+phase_status:\s+)\S+', line)
        if m:
            new_lines[i] = m.group(1) + 'not_started\n'
            phase_done = True
            continue
    # Remove started_at line
    if re.match(r'^\s+started_at:', line):
        new_lines[i] = None
        continue

new_lines = [l for l in new_lines if l is not None]

if not status_done:
    print(f'Error: status field not found for {target_id}', file=sys.stderr)
    sys.exit(1)
if not phase_done:
    print(f'Error: phase_status field not found for {target_id}', file=sys.stderr)
    sys.exit(1)

with open(file_path, 'w') as f:
    f.writelines(new_lines)

# Handle --clear-retry-count
if clear_retry:
    retry_file = os.path.join(os.path.dirname(file_path), '.delivery-locks', '.retry-counts')
    if os.path.isfile(retry_file):
        with open(retry_file, 'r') as rf:
            retry_lines = rf.readlines()
        new_retry = [l for l in retry_lines if not l.startswith(target_id + '=')]
        with open(retry_file, 'w') as rf:
            rf.writelines(new_retry)
        cleared = len(retry_lines) - len(new_retry)
        if cleared > 0:
            print(f'{target_id} retry-count cleared')
    else:
        print(f'{target_id} retry-counts file not found — skipping retry-count clear', file=sys.stderr)

print(f'{target_id} reset: status->refined, phase_status->not_started, started_at removed')
" "$BACKLOG_FILE" "$RESET_ID" "$RESET_CLEAR_RETRY"
  _SCHED_RC=$?
  if [[ "$_SCHED_RC" -eq 0 ]]; then
    _scheduler_validate_after_write "$BACKLOG_FILE" || exit $?
  fi
  exit "$_SCHED_RC"
fi

# ── journal-set mode: durable emission is required before mutation ──────────
if [[ "$MODE" == "journal-set" ]]; then
  _JOURNAL_LIB_DIR=""
  if ! _JOURNAL_LIB_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd -P); then
    >&2 echo "Error: journal library unavailable"
    exit 4
  fi
  _JOURNAL_LIB="$_JOURNAL_LIB_DIR/backlog-journal.sh"
  if [[ ! -r "$_JOURNAL_LIB" ]] || ! source "$_JOURNAL_LIB"; then
    >&2 echo "Error: journal library unavailable"
    exit 4
  fi

  _JOURNAL_WRITER="${GAAI_BACKLOG_JOURNAL_WRITER_CONTEXT:-backlog-scheduler.journal-set}"
  _JOURNAL_TOKEN="${GAAI_BACKLOG_JOURNAL_RUN_TOKEN:-}"
  if [[ -z "$_JOURNAL_TOKEN" ]]; then
    if ! backlog_journal_begin_run "$BACKLOG_FILE" "$_JOURNAL_WRITER"; then
      >&2 echo "Error: ${BACKLOG_JOURNAL_OUTCOME:-rejected}:${BACKLOG_JOURNAL_REASON:-policy_invalid}"
      exit 5
    fi
    _JOURNAL_TOKEN="$BACKLOG_JOURNAL_RUN_TOKEN"
  fi

  _JOURNAL_RC=0
  backlog_journal_emit "$BACKLOG_FILE" "$JOURNAL_ID" "$JOURNAL_FIELD" "$JOURNAL_VAL" \
    "$_JOURNAL_WRITER" "$_JOURNAL_TOKEN" || _JOURNAL_RC=$?
  if [[ "$_JOURNAL_RC" -eq 10 && "$BACKLOG_JOURNAL_OUTCOME" == "pending:replay" ]]; then
    >&2 echo "Error: pending:replay"
    exit 6
  fi
  if [[ "$_JOURNAL_RC" -ne 0 || "$BACKLOG_JOURNAL_OUTCOME" != "emitted" ]]; then
    >&2 echo "Error: ${BACKLOG_JOURNAL_OUTCOME:-rejected}:${BACKLOG_JOURNAL_REASON:-policy_invalid}"
    exit 5
  fi

  _JOURNAL_MUTATION=""
  if ! _JOURNAL_MUTATION=$(python3 - "$BACKLOG_JOURNAL_RECORD_PATH" \
      "$JOURNAL_ID" "$JOURNAL_FIELD" <<'PY'
import json
import sys

path, story_id, field = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as handle:
        record = json.load(handle)["record"]
    if record.get("story_id") != story_id or record.get("field") != field:
        raise ValueError
    value = record["new_value"]
    if value is None:
        print("null\tnull")
    elif isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ValueError
    else:
        marker = "string" if isinstance(value, str) else "integer"
        print(f"{marker}\t{value}")
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
  ); then
    >&2 echo "Error: emitted journal record is unreadable"
    exit 5
  fi
  _JOURNAL_VALUE_TYPE=""
  _JOURNAL_CANONICAL_VALUE=""
  IFS=$'\t' read -r _JOURNAL_VALUE_TYPE _JOURNAL_CANONICAL_VALUE <<< "$_JOURNAL_MUTATION"
  if [[ -z "$_JOURNAL_VALUE_TYPE" || -z "$_JOURNAL_CANONICAL_VALUE" ]]; then
    >&2 echo "Error: emitted journal record is malformed"
    exit 5
  fi

  MODE="set-field"
  SET_FIELD_ID="$JOURNAL_ID"
  SET_FIELD_NAME="$JOURNAL_FIELD"
  SET_FIELD_VAL="$_JOURNAL_CANONICAL_VALUE"
  if [[ "$JOURNAL_FIELD" == "blocked_reason" && "$_JOURNAL_VALUE_TYPE" == "string" ]]; then
    SET_FIELD_FORCE_STRING="true"
  fi
fi

# ── set-field mode: set any field on a backlog item ──────────
# The validation here runs on the MODIFIED IN-MEMORY LINES before the file is
# written, so a path-level pre-write call would validate the wrong bytes and
# silently drop the guard. The whole program therefore runs through the boundary.
if [[ "$MODE" == "set-field" ]]; then
  _scheduler_source_yaml_boundary || exit $?
  YAML_RUNTIME_ROLE=scheduler
  yaml_runtime_run_c "
import sys, re

file_path, target_id, field_name, field_value, force_string = sys.argv[1:6]

with open(file_path, 'r') as f:
    lines = f.readlines()

# Find target item block boundaries
block_start = -1
block_end = len(lines)

for i, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r'-\s+id:\s+' + re.escape(target_id) + r'\s*$', stripped):
        block_start = i
        continue
    if block_start >= 0 and re.match(r'-\s+id:\s+', stripped):
        block_end = i
        break

if block_start < 0:
    print(f'Error: item {target_id} not found', file=sys.stderr)
    sys.exit(1)

# Format value: numbers stay bare, null/true/false/[] stay bare, safe
# flow-style sequences of plain scalars stay bare, simple snake_case
# identifiers stay bare (in_progress, refined, qa_passed, done...), and
# everything else gets quoted.
#
# Why bare identifiers matter: naive readers elsewhere in the daemon use
# .split(':',1)[1].strip() without quote-stripping. Quoted values like
# 'status: \"in_progress\"' compare-mismatch against unquoted Python literals
# 'in_progress', making the item invisible to the crash-recovery scan.
# Symmetric fix: writer emits canonical bare for simple identifiers (matches
# what --set-status produces + matches what yq -i + manual edits produce);
# readers strip quotes defensively. Postel's law applied to YAML.
def normalize_safe_flow_sequence(value):
    if not (value.startswith('[') and value.endswith(']')):
        return None

    inner = value[1:-1].strip()
    if not inner:
        return '[]'

    items = [item.strip() for item in inner.split(',')]
    safe_plain_scalar = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$')
    if any(not item or not safe_plain_scalar.fullmatch(item) for item in items):
        raise ValueError(
            'flow sequences accept only comma-separated plain scalars '
            'starting with a letter or digit, then using only letters, '
            'digits, dot, underscore, or hyphen'
        )
    return '[' + ', '.join(items) + ']'

try:
    flow_sequence = normalize_safe_flow_sequence(field_value)
except ValueError as exc:
    print(f'Error: unsafe --set-field flow sequence: {exc}', file=sys.stderr)
    sys.exit(1)

def quoted_string(value):
    return '\"' + value.replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"') + '\"'

if force_string == 'true':
    # Journal mode passes the durable record's canonical type explicitly.
    # Direct --set-field calls keep their historical formatting behavior.
    formatted = quoted_string(field_value)
    flow_sequence = None
else:
    try:
        float(field_value)
        formatted = field_value
    except ValueError:
        if field_value in ('null', 'true', 'false', '[]'):
            formatted = field_value
        elif re.match(r'^[a-z][a-z0-9_]*$', field_value):
            # Simple snake_case identifier — safe as bare YAML scalar.
            # Examples: in_progress, refined, qa_passed, done, merged, primary.
            formatted = field_value
        else:
            # Anything else (timestamps with ':', URLs, free-text, mixed case,
            # leading non-alpha) — escape inner double quotes and wrap.
            formatted = quoted_string(field_value)

if flow_sequence is not None:
    formatted = flow_sequence

# Look for existing field within the block
field_found = False
for i in range(block_start + 1, block_end):
    m = re.match(
        r'^([ \t]+)' + re.escape(field_name) + r':[ \t]*(.*?)(?:\r?\n)?$',
        lines[i],
    )
    if m:
        indent = m.group(1)
        existing_value = m.group(2)
        block_scalar_header = re.fullmatch(r'[|>][1-9+-]{0,2}', existing_value)
        if block_scalar_header:
            print(
                f'Error: {target_id}.{field_name} uses block-style YAML; '
                'refusing a partial --set-field rewrite',
                file=sys.stderr,
            )
            sys.exit(1)
        if not existing_value:
            field_indent = len(indent)
            for following in lines[i + 1:block_end]:
                if not following.strip():
                    continue
                if following.lstrip().startswith('#'):
                    continue
                following_indent = len(following) - len(following.lstrip(' \t'))
                same_indent_sequence = (
                    following_indent == field_indent
                    and following.strip().startswith('- ')
                )
                if following_indent > field_indent or same_indent_sequence:
                    print(
                        f'Error: {target_id}.{field_name} uses block-style YAML; '
                        'refusing a partial --set-field rewrite',
                        file=sys.stderr,
                    )
                    sys.exit(1)
                break
        lines[i] = f'{indent}{field_name}: {formatted}\n'
        field_found = True
        break

if not field_found:
    # Determine indentation from existing fields
    indent = '    '
    for i in range(block_start + 1, block_end):
        m2 = re.match(r'^(\s+)\w', lines[i])
        if m2:
            indent = m2.group(1)
            break

    # Insertion order: after the last delivery-metadata field present,
    # or after status: if none exist
    DELIVERY_FIELDS = ['status', 'cost_usd', 'human_md_estimate', 'human_cost_usd', 'started_at', 'completed_at', 'pr_url', 'pr_number', 'pr_status']
    insert_after = -1
    for i in range(block_start + 1, block_end):
        fm = re.match(r'^\s+(\w+):', lines[i])
        if fm and fm.group(1) in DELIVERY_FIELDS:
            insert_after = i

    if insert_after < 0:
        # Fallback: insert after the id line
        insert_after = block_start

    new_line = f'{indent}{field_name}: {formatted}\n'
    lines.insert(insert_after + 1, new_line)

import yaml
try:
    yaml.safe_load(''.join(lines))
except Exception as exc:
    print(f'Error: --set-field would produce invalid YAML: {exc}', file=sys.stderr)
    sys.exit(1)

with open(file_path, 'w') as f:
    f.writelines(lines)

print(f'{target_id}.{field_name} = {formatted}')
" "$BACKLOG_FILE" "$SET_FIELD_ID" "$SET_FIELD_NAME" "$SET_FIELD_VAL" "$SET_FIELD_FORCE_STRING"
  exit $?
fi

# ── Read backlog content ─────────────────────────────────────
if $FROM_STDIN; then
  BACKLOG_CONTENT=$(cat)
  # Fallback: if stdin parsing fails, create temp file
  FROM_STDIN_BACKUP=true
else
  BACKLOG_CONTENT=$(cat "$BACKLOG_FILE")
  FROM_STDIN_BACKUP=false
fi

# ── Collect done IDs from done/ archive ──────────────────────
# Stories archived out of the active backlog still count as resolved
# dependencies. Scan done/*.yaml for their IDs.
DONE_DIR=""
if [[ -n "$BACKLOG_FILE" ]]; then
  DONE_DIR="$(dirname "$BACKLOG_FILE")/done"
else
  # When using --stdin, infer done/ from script location
  SCRIPT_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
  INFERRED_BACKLOG_DIR="$(cd "$SCRIPT_SELF_DIR/../../project/contexts/backlog" 2>/dev/null && pwd)" || true
  if [[ -n "$INFERRED_BACKLOG_DIR" && -d "$INFERRED_BACKLOG_DIR/done" ]]; then
    DONE_DIR="$INFERRED_BACKLOG_DIR/done"
  fi
fi

ARCHIVED_DONE_IDS=""
if [[ -n "$DONE_DIR" && -d "$DONE_DIR" ]]; then
  ARCHIVED_DONE_IDS=$(python3 -c "
import sys, re, os, glob

done_dir = sys.argv[1]
ids = set()
for f in glob.glob(os.path.join(done_dir, '*.yaml')):
    with open(f) as fh:
        current_id = None
        for line in fh:
            stripped = line.strip()
            if stripped.startswith('- id:'):
                current_id = stripped.split(':', 1)[1].strip()
            elif current_id and stripped.startswith('status:'):
                status = stripped.split(':', 1)[1].strip().strip('\"\\\"')
                if status in ('done', 'cancelled', 'superseded'):
                    ids.add(current_id)
                current_id = None
for i in sorted(ids):
    print(i)
" "$DONE_DIR" 2>/dev/null) || ARCHIVED_DONE_IDS=""
fi

# ── Python parser + all read modes ───────────────────────────
# The Python script is stored in a variable to avoid quoting issues
# with python3 -c. Content is piped via stdin, mode via argv.
read -r -d '' PYTHON_PARSER << 'PYEOF' || true
import sys
import re

mode = sys.argv[1]
archived_done_ids_raw = sys.argv[2] if len(sys.argv) > 2 else ""
content = sys.stdin.read()

# -- YAML block parser (indent-aware) --
# Item starts: "- id:" at the top-level item indent (locked from the first item seen).
# Item fields: keys at exactly item_indent + 2. Anything deeper (nested objects like
# `supersession_analysis: { ... status: ... }`) is ignored — without this guard,
# nested `status:`/`title:`/`priority:` keys silently overwrite the parent item's fields.
items = []
current = None
item_indent = -1
field_indent = -1
in_depends = False

def _line_indent(s):
    return len(s) - len(s.lstrip(' '))

for line in content.splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = _line_indent(line)
    stripped = line.strip()

    if stripped.startswith("- id:") and (item_indent == -1 or indent == item_indent):
        if current:
            items.append(current)
        current = {
            "id": stripped.split(":", 1)[1].strip(),
            "title": "",
            "status": "draft",
            "priority": "low",
            "complexity": 1,
            "depends_on": [],
            "epic": "",
            "delivery_pipeline": "",
        }
        item_indent = indent
        field_indent = indent + 2
        in_depends = False
        continue

    if current is None or indent != field_indent:
        # Either before the first item, or nested deeper than item fields.
        # Reset depends-list mode so nested "- " entries don't leak into depends_on.
        if indent < field_indent:
            in_depends = False
        continue

    if stripped.startswith("title:"):
        current["title"] = stripped.split(":", 1)[1].strip().strip("\"'")
        in_depends = False
    elif stripped.startswith("status:"):
        current["status"] = stripped.split(":", 1)[1].strip().strip('"\'')
        in_depends = False
    elif stripped.startswith("priority:"):
        current["priority"] = stripped.split(":", 1)[1].strip()
        in_depends = False
    elif stripped.startswith("complexity:"):
        try:
            current["complexity"] = int(stripped.split(":", 1)[1].strip())
        except ValueError:
            pass
        in_depends = False
    elif stripped.startswith("delivery_pipeline:"):
        current["delivery_pipeline"] = re.split(r"\s+#", stripped.split(":", 1)[1], maxsplit=1)[0].strip().strip("\"'")
        in_depends = False
    elif stripped.startswith("epic:"):
        # Extracted so is_ready() can detect epic self-references (id == epic)
        # and skip epic rows from delivery queues.
        current["epic"] = stripped.split(":", 1)[1].strip().strip("\"'")
        in_depends = False
    elif stripped.startswith("depends_on:") or stripped.startswith("dependencies:"):
        val = stripped.split(":", 1)[1].strip()
        if val and val not in ("[]", ""):
            ids = re.findall(r"[\w-]+", val)
            current["depends_on"].extend(ids)
            in_depends = False
        else:
            in_depends = True
    elif in_depends and stripped.startswith("- "):
        dep = stripped[2:].strip()
        if dep:
            current["depends_on"].append(dep)
    elif not stripped.startswith("- "):
        in_depends = False

if current:
    items.append(current)

# -- Helpers --
priority_order = {"critical": -1, "high": 0, "medium": 1, "low": 2}
done_ids = {i["id"] for i in items if i.get("status") in ("done", "cancelled", "superseded")}
# Merge archived done IDs (stories moved out of active backlog)
if archived_done_ids_raw:
    done_ids.update(archived_done_ids_raw.split("\n"))

def is_ready(item):
    if item.get("status") not in ("refined", "ready"):
        return False
    # Skip epics. An epic's row is detected by self-reference (id == epic) and
    # is a container, never a delivery unit. Previously the daemon would pick
    # the epic row up as a "ready story", fail to spawn a wrapper, increment
    # the retry counter, and eventually spam "exceeded 3 retries. Skipping
    # (restart daemon to reset)" every poll cycle.
    if item.get("id") and item.get("id") == item.get("epic"):
        return False
    # A manual row is delivered by a human or another session, never by the
    # daemon: it is not offered by --next, --ready-ids or --list.
    if item.get("delivery_pipeline") == "manual":
        return False
    return all(d in done_ids for d in item.get("depends_on", []) if d)

def unresolved_deps(item):
    return [d for d in item.get("depends_on", []) if d and d not in done_ids]

def sort_key(item):
    return (priority_order.get(item.get("priority", "low"), 2), item.get("complexity", 1))

ready_items = sorted([i for i in items if is_ready(i)], key=sort_key)

# -- Mode: next --
if mode == "next":
    if ready_items:
        print(ready_items[0]["id"])
    else:
        print("NO_ITEM_READY")
    sys.exit(0)

# -- Mode: ready-ids --
if mode == "ready-ids":
    for item in ready_items:
        print(item["id"])
    sys.exit(0)

# -- Mode: list --
if mode == "list":
    if not ready_items:
        print("No items ready. Check backlog for refined items with resolved dependencies.")
        sys.exit(0)
    print(f"Ready items ({len(ready_items)}):")
    print()
    for item in ready_items:
        priority = item.get("priority", "low").upper()
        complexity = item.get("complexity", "?")
        title = item.get("title", "(no title)")
        print(f'  [{priority}] {item["id"]} \u2014 {title} (complexity: {complexity})')
    sys.exit(0)

# -- Mode: graph --
if mode == "graph":
    active_items = [i for i in items if i.get("status") not in ("done", "cancelled")]
    if not active_items:
        print("No active items.")
        sys.exit(0)
    print("Dependency graph (active items):")
    print()
    for item in sorted(active_items, key=sort_key):
        status   = item.get("status", "?")
        priority = item.get("priority", "low")
        title    = item.get("title", "(no title)")
        deps     = item.get("depends_on", [])

        if is_ready(item):
            indicator = "\u2705"
        elif status in ("in_progress", "in-progress"):
            indicator = "\U0001f504"
        elif deps:
            indicator = "\U0001f512"
        else:
            indicator = "\u23f3"

        print(f'  {indicator} {item["id"]} [{priority}] \u2014 {title}')
        for dep in deps:
            dep_status = next((i.get("status","?") for i in items if i["id"] == dep), "unknown")
            resolved = "\u2713" if dep in done_ids else "\u2717"
            print(f'       \u2514\u2500 {resolved} depends on {dep} (status: {dep_status})')
    print()
    print("Legend: \u2705 ready  \U0001f504 in-progress  \U0001f512 blocked  \u23f3 not yet refined/ready")
    sys.exit(0)

# -- Mode: conflicts --
if mode == "conflicts":
    conflicts = []
    active_items = [i for i in items if i.get("status") not in ("done", "cancelled")]

    for item in active_items:
        if item.get("status") not in ("refined", "ready"):
            continue
        unres = unresolved_deps(item)
        if not unres:
            continue
        item_prio = priority_order.get(item.get("priority", "low"), 2)
        for dep_id in unres:
            dep = next((i for i in items if i["id"] == dep_id), None)
            if dep is None:
                conflicts.append({
                    "dep_id": dep_id,
                    "item_id": item["id"],
                    "type": "missing",
                    "detail": f'{dep_id} listed as dependency of {item["id"]} but not found in backlog'
                })
                continue
            dep_prio = priority_order.get(dep.get("priority", "low"), 2)
            if dep_prio > item_prio:
                conflicts.append({
                    "dep_id": dep_id,
                    "item_id": item["id"],
                    "type": "priority_inversion",
                    "detail": f'{item["id"]} ({item.get("priority")}) is blocked by {dep_id} ({dep.get("priority")})'
                })

    if not conflicts:
        print("No priority conflicts detected.")
        sys.exit(0)

    print(f"Priority conflicts ({len(conflicts)}):")
    print()
    for c in conflicts:
        print(f'  \u26a0\ufe0f  {c["detail"]}')
        if c["type"] == "priority_inversion":
            print(f'      \u2192 Consider raising priority of {c["dep_id"]} or lowering {c["item_id"]}')
        elif c["type"] == "missing":
            print(f'      \u2192 {c["dep_id"]} is listed as a dependency but not found in backlog')
    sys.exit(0)
PYEOF

# ── Execute parser with temp file fallback ───────────────────
# Using temp file is more reliable than piping through echo,
# which can lose data or break on special characters in YAML
TEMP_BACKLOG=$(mktemp)
trap "rm -f $TEMP_BACKLOG" EXIT

echo "$BACKLOG_CONTENT" > "$TEMP_BACKLOG"

# Verify content was written successfully
if [[ ! -s "$TEMP_BACKLOG" ]]; then
  >&2 echo "Error: failed to write backlog content to temp file"
  exit 1
fi

# Execute with stdin redirected from temp file (more reliable)
python3 -c "$PYTHON_PARSER" "$MODE" "$ARCHIVED_DONE_IDS" < "$TEMP_BACKLOG"
