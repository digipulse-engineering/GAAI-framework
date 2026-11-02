#!/usr/bin/env bash
# backlog-scheduler-dependency-release.test.sh
# A done row whose pull request has not merged must not release the rows that
# depend on it. In the active backlog, done satisfies a dependency only when the
# row's own pr_status is absent, unquoted null (null or ~) or exactly merged;
# every other value, and every value the reader cannot read, holds. cancelled,
# superseded and archived rows keep satisfying dependencies as before.
#
# Usage: bash .gaai/core/scripts/tests/backlog-scheduler-dependency-release.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEDULER="$SCRIPT_DIR/../backlog-scheduler.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/dependency-release.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# One case per row: name | parent status | parent field lines (\n-separated,
# written verbatim under the parent) | ready or held | pr_status shown by --graph
# when held. A parent status of "archived" puts a done parent in done/ instead
# of the active backlog.
CASES=(
  'MERGED|done|pr_status: merged|ready|'
  'ABSENT|done||ready|'
  'NULL|done|pr_status: null|ready|'
  'TILDE|done|pr_status: ~|ready|'
  'UNQCOMMENT|done|pr_status: merged  # watcher|ready|'
  'QCOMMENT|done|pr_status: "merged" # landed|ready|'
  'SQUOTED|done|pr_status: '"'"'merged'"'"'|ready|'
  'PENDING|done|pr_status: pending_review|held|pending_review'
  'OPEN|done|pr_status: open|held|open'
  'CLOSED|done|pr_status: closed|held|closed'
  'EMPTY|done|pr_status:|held|""'
  'EMPTYQ|done|pr_status: ""|held|""'
  'UNKNOWN|done|pr_status: merged_direct|held|merged_direct'
  'UPPERNULL|done|pr_status: NULL|held|NULL'
  'QNULL|done|pr_status: "null"|held|null'
  'QTILDE|done|pr_status: '"'"'~'"'"'|held|~'
  'QHASH|done|pr_status: "merged # text"|held|merged # text'
  'UNMATCHED|done|pr_status: "merged|held|<unreadable>'
  'EMBEDDED|done|pr_status: "mer"ged"|held|<unreadable>'
  'TRAILING|done|pr_status: "merged"x|held|<unreadable>'
  'DUPLICATE|done|pr_status: merged\npr_status: merged|held|<unreadable>'
  'SPACEDKEY|done|pr_status : pending_review|held|<unreadable>'
  'QUOTEDKEY|done|"pr_status": pending_review|held|<unreadable>'
  'NESTED|done|meta:\n  pr_status: pending_review|ready|'
  'NESTEDHELD|done|pr_status: pending_review\nmeta:\n  pr_status: merged|held|pending_review'
  'CANCELLED|cancelled|pr_status: pending_review|ready|'
  'SUPERSEDED|superseded|pr_status: pending_review|ready|'
  'ARCHIVED|archived|pr_status: pending_review|ready|'
)

# write_case <dir> <status> <lines>: parent P and refined child C depending on it.
write_case() {
  local dir="$1" status="$2" lines="$3" parent_file="$1/active.backlog.yaml"
  mkdir -p "$dir/done"
  if [[ "$status" == archived ]]; then
    parent_file="$dir/done/archived.yaml"
    status=done
    echo "items:" > "$parent_file"
  fi
  {
    [[ "$parent_file" == "$dir/active.backlog.yaml" ]] && echo "items:"
    echo "- id: P"
    echo "  status: $status"
    [[ -n "$lines" ]] && printf '%b\n' "$lines" | sed 's/^/  /'
  } >> "$parent_file"
  [[ -f "$dir/active.backlog.yaml" ]] || echo "items:" > "$dir/active.backlog.yaml"
  printf -- '- id: C\n  status: refined\n  delivery_pipeline: 3phase\n  dependencies: [P]\n' \
    >> "$dir/active.backlog.yaml"
}

echo "=== each case through --ready-ids, --next and --graph ==="
for c in "${CASES[@]}"; do
  IFS='|' read -r name status lines want shown <<<"$c"
  dir="$SANDBOX/$name"
  write_case "$dir" "$status" "$lines"
  ready="$(bash "$SCHEDULER" --ready-ids "$dir/active.backlog.yaml" 2>/dev/null)"
  next="$(bash "$SCHEDULER" --next "$dir/active.backlog.yaml" 2>/dev/null)"
  graph="$(bash "$SCHEDULER" --graph "$dir/active.backlog.yaml" 2>/dev/null | grep 'depends on P ')"
  if [[ "$want" == ready ]]; then
    graph_status="$status"; [[ "$status" == archived ]] && graph_status=unknown
    expect_ready=C; expect_next=C
    expect_graph="✓ depends on P (status: $graph_status)"
  else
    expect_ready=""; expect_next=NO_ITEM_READY
    expect_graph="✗ depends on P (status: done, pr_status: $shown)"
  fi
  [[ "$ready" == "$expect_ready" ]] && pass "$name: --ready-ids ${expect_ready:-holds}" \
    || fail "$name: --ready-ids printed '$ready', expected '$expect_ready'"
  [[ "$next" == "$expect_next" ]] && pass "$name: --next prints $expect_next" \
    || fail "$name: --next printed '$next', expected '$expect_next'"
  [[ "$graph" == *"$expect_graph" ]] && pass "$name: --graph line" \
    || fail "$name: --graph line '$graph', expected '…$expect_graph'"
done

echo "=== --list and --conflicts ==="
LIST_HELD="$(bash "$SCHEDULER" --list "$SANDBOX/PENDING/active.backlog.yaml" 2>/dev/null)"
LIST_LANDED="$(bash "$SCHEDULER" --list "$SANDBOX/MERGED/active.backlog.yaml" 2>/dev/null)"
grep -q ' C ' <<<"$LIST_HELD" && fail "--list offered the dependant of an unmerged parent" \
  || pass "--list holds the dependant of an unmerged parent"
grep -q ' C ' <<<"$LIST_LANDED" && pass "--list offers the dependant of a merged parent" \
  || fail "--list dropped the dependant of a merged parent"
CONFLICTS="$(bash "$SCHEDULER" --conflicts "$SANDBOX/PENDING/active.backlog.yaml" 2>/dev/null)"
grep -q 'P listed as dependency of C but not found' <<<"$CONFLICTS" \
  && fail "--conflicts reports a held dependency as missing" \
  || pass "--conflicts does not report a held dependency as missing"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
