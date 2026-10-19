#!/usr/bin/env bash
# manual-pipeline-guard.test.sh
# A row whose delivery_pipeline is manual is delivered by a human or another
# session, never by the daemon. The scheduler never offers it (--next,
# --ready-ids, --list), every other pipeline value is selected exactly as
# before, and the daemon logs each skip once per row and site.
#
# Usage: bash .gaai/core/scripts/tests/manual-pipeline-guard.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEDULER="$SCRIPT_DIR/../backlog-scheduler.sh"
DAEMON="$SCRIPT_DIR/../delivery-daemon.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/manual-pipeline-guard.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FIXTURE="$SANDBOX/active.backlog.yaml"

cat > "$FIXTURE" <<'YAML'
items:
- id: DEP-DONE
  status: done
  delivery_pipeline: 3phase
- id: MAN-READY
  status: refined
  priority: critical
  delivery_pipeline: manual
  dependencies: [DEP-DONE]
- id: MAN-QUOTED
  status: refined
  priority: critical
  delivery_pipeline: "manual"
  dependencies: []
- id: AUTO-READY
  status: refined
  priority: high
  delivery_pipeline: 3phase
  dependencies: [DEP-DONE]
- id: LEGACY-READY
  status: refined
  priority: medium
  delivery_pipeline: legacy
  dependencies: []
- id: LOOKALIKE-READY
  status: refined
  priority: medium
  delivery_pipeline: manual-review
  dependencies: []
- id: MAN-COMMENT
  status: refined
  priority: critical
  delivery_pipeline: manual  # delivered by another session
  dependencies: []
- id: MAN-TAB
  status: refined
  priority: critical
  delivery_pipeline: manual	# delivered by another session
  dependencies: []
- id: NOFIELD-READY
  status: refined
  priority: low
  dependencies: []
YAML

echo "=== ready-ids ==="
READY="$(/bin/bash "$SCHEDULER" --ready-ids "$FIXTURE" 2>/dev/null | sort | paste -sd, -)"
if [[ "$READY" == "AUTO-READY,LEGACY-READY,LOOKALIKE-READY,NOFIELD-READY" ]]; then
  pass "--ready-ids omits both manual rows and keeps every other pipeline value"
else
  fail "--ready-ids listed '$READY'"
fi

echo "=== next ==="
NEXT="$(/bin/bash "$SCHEDULER" --next "$FIXTURE" 2>/dev/null)"
if [[ "$NEXT" == "AUTO-READY" ]]; then
  pass "--next skips the higher-priority manual rows and offers the 3phase one"
else
  fail "--next offered '$NEXT'"
fi

echo "=== list ==="
LIST="$(/bin/bash "$SCHEDULER" --list "$FIXTURE" 2>/dev/null)"
if ! printf '%s\n' "$LIST" | grep -qE 'MAN-READY|MAN-QUOTED|MAN-COMMENT|MAN-TAB' \
    && printf '%s\n' "$LIST" | grep -q 'AUTO-READY'; then
  pass "--list never shows a manual row"
else
  fail "--list shows a manual row or lost the 3phase one"
fi

echo "=== only manual rows ready ==="
ONLY="$SANDBOX/only-manual.yaml"
printf 'items:\n- id: MAN-ONLY\n  status: refined\n  delivery_pipeline: manual\n  dependencies: []\n' > "$ONLY"
if [[ "$(/bin/bash "$SCHEDULER" --next "$ONLY" 2>/dev/null)" == "NO_ITEM_READY" ]] \
    && [[ -z "$(/bin/bash "$SCHEDULER" --ready-ids "$ONLY" 2>/dev/null)" ]]; then
  pass "a backlog whose only ready row is manual offers nothing"
else
  fail "a manual-only backlog still offers a row"
fi

echo "=== daemon log relay ==="
# The two helpers are extracted from the shipped daemon by name, not by line.
RELAY_LIB="$SANDBOX/relay.sh"
awk '/^_MANUAL_PIPELINE_LOGGED=/{print} /^_manual_pipeline_skip_log\(\)|^_manual_pipeline_relay\(\)/{on=1} on{print} on&&/^}/{on=0}' \
  "$DAEMON" > "$RELAY_LIB"
RELAY_LOG="$SANDBOX/relay.log"
RELAY_ERR="$SANDBOX/relay.err"
RELAY_IN="$SANDBOX/relay.in"
printf '%s\n' \
  '[MANUAL-PIPELINE] story=MAN-A skipped=recovery_scan' \
  'some other diagnostic' \
  '[MANUAL-PIPELINE] story=MAN-A skipped=recovery_scan' \
  '[MANUAL-PIPELINE] story=MAN-B skipped=recovery_scan' > "$RELAY_IN"
(
  log() { printf '%s\n' "$*" >> "$RELAY_LOG"; }
  # shellcheck source=/dev/null
  source "$RELAY_LIB"
  _manual_pipeline_relay "$RELAY_IN"
  _manual_pipeline_relay "$RELAY_IN"
  _manual_pipeline_skip_log MAN-A pr_watcher
  _manual_pipeline_skip_log MAN-A pr_watcher
) 2> "$RELAY_ERR"
if [[ "$(grep -c '^\[MANUAL-PIPELINE\] story=MAN-A skipped=recovery_scan' "$RELAY_LOG")" -eq 1 \
    && "$(grep -c '^\[MANUAL-PIPELINE\] story=MAN-B skipped=recovery_scan' "$RELAY_LOG")" -eq 1 \
    && "$(grep -c '^\[MANUAL-PIPELINE\] story=MAN-A skipped=pr_watcher' "$RELAY_LOG")" -eq 1 \
    && "$(wc -l < "$RELAY_LOG" | tr -d ' ')" -eq 3 ]]; then
  pass "each skip is logged once per row and site across repeated scans"
else
  fail "the skip log is not exactly once per row and site: $(tr '\n' '|' < "$RELAY_LOG")"
fi
if [[ "$(grep -c '^some other diagnostic$' "$RELAY_ERR")" -eq 2 ]] && ! grep -q 'MANUAL-PIPELINE' "$RELAY_ERR"; then
  pass "other classifier stderr passes through unchanged"
else
  fail "the relay swallowed or rerouted other stderr lines"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
