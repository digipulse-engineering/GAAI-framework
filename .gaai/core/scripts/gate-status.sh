#!/usr/bin/env bash
#
# gate-status.sh — is a local-admission gate holding a binding right now?
#
# A gate binds (base, head, policy, risk, environment) and then runs its selected
# commands for tens of minutes. Advancing the base inside that window invalidates
# the receipt and discards the delivery cycle, however well the commands did.
# Nothing published that a binding was live, so whoever was about to merge could
# not know what it would cost. This reads the advisory marker the gate writes for
# exactly as long as it holds one.
#
# Usage:
#   gate-status.sh [--quiet] [<state-dir>]
#
#   <state-dir>   directory holding the admission receipts. Defaults to
#                 .gaai/project/contexts/backlog/.delivery-locks/local-admission-receipts
#                 under the repository root.
#   --quiet       print nothing; use the exit status alone.
#
# Exit status:
#   0  no gate is bound — advancing the target is safe as far as admission goes
#   2  at least one gate is bound; merging now will discard that cycle
#   1  the state directory could not be read
#
# The marker is advisory. It grants no authority, gates nothing, and its absence
# is never permission: a gate that starts one second after this call binds a base
# this call could not have seen.

set -uo pipefail

QUIET=0
STATE_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) STATE_DIR="$1"; shift ;;
  esac
done

if [[ -z "$STATE_DIR" ]]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  [[ -n "$repo_root" ]] || { [[ "$QUIET" -eq 1 ]] || echo "not inside a repository and no state directory given" >&2; exit 1; }
  STATE_DIR="$repo_root/.gaai/project/contexts/backlog/.delivery-locks/local-admission-receipts"
fi

[[ -d "$STATE_DIR" ]] || { [[ "$QUIET" -eq 1 ]] || echo "no gate is bound"; exit 0; }

found=0
now=$(date -u +%s)
for marker in "$STATE_DIR"/.local-admission-*.inflight.json; do
  [[ -f "$marker" ]] || continue

  # A marker whose publisher is gone is residue from a killed gate, not a live
  # binding. Report it as residue rather than as a reason not to merge.
  read -r pid story boundary base started <<<"$(
    python3 - "$marker" <<'PY' 2>/dev/null || echo ""
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
print(d.get("pid", ""), d.get("story", ""), d.get("boundary", ""),
      (d.get("bound_base") or "")[:12], d.get("started_at", ""))
PY
  )"
  [[ -n "${story:-}" ]] || continue

  if [[ -n "${pid:-}" ]] && ! kill -0 "$pid" 2>/dev/null; then
    [[ "$QUIET" -eq 1 ]] || echo "residue: ${story} ${boundary} marker left by a gate that is no longer running (pid ${pid})"
    continue
  fi

  elapsed=""
  if [[ -n "${started:-}" ]]; then
    start_s=$(python3 - "$started" <<'PY' 2>/dev/null || echo ""
import sys, datetime
try:
    print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
              .replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception:
    raise SystemExit(1)
PY
    )
    [[ -n "$start_s" ]] && elapsed=" for $(( (now - start_s) / 60 ))m"
  fi

  found=1
  [[ "$QUIET" -eq 1 ]] || echo "BOUND: ${story} ${boundary} on base ${base}${elapsed} — merging to the target now discards this cycle"
done

if [[ "$found" -eq 1 ]]; then
  exit 2
fi

[[ "$QUIET" -eq 1 ]] || echo "no gate is bound"
exit 0
