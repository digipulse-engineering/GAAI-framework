#!/usr/bin/env bash
# ── delivery-routing-shim.test.sh ──────────────────────────────────────────
# Contract test for the bash surface the daemon actually calls, and for the
# dispatch-side seams the router drives (per-call harness override, kill
# switch, quota autodetection, provenance round-trip).
#
# The engine itself is covered by delivery-router.fixture.mjs; this file only
# asserts that bash and Node agree on the handoff.
#
# Run: bash .gaai/core/scripts/tests/delivery-routing-shim.test.sh
# Exit 0 = all pass.

set -uo pipefail
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SHIM="${PROJECT_DIR}/.gaai/core/scripts/lib/delivery-routing.sh"
DISPATCH="${PROJECT_DIR}/.gaai/core/scripts/daemon-dispatch.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic harness availability. The router probes PATH for each harness binary,
# so without this the suite silently tests "which vendor CLIs does this machine
# happen to have installed" — it passed on two developer machines and failed on
# every clean runner. Stub executables keep the real probe path under test while
# making its answer independent of the host. Env status pins are deliberately
# NOT used here: they would take precedence over the status file and break the
# quota-marking assertions further down, which are the point of that section.
mkdir -p "$TMP/bin"
for _harness in claude codex; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_harness"
  chmod +x "$TMP/bin/$_harness"
done
export PATH="$TMP/bin:$PATH"
export GAAI_PROVENANCE_DIR="${TMP}/provenance"
export GAAI_HARNESS_STATUS_DIR="${TMP}/harness-status"

# shellcheck source=../lib/delivery-routing.sh
source "$SHIM"

echo "── shim surface ──"
for fn in gaai_route_select gaai_route_export_effort gaai_provenance_record \
          gaai_harness_mark gaai_harness_autodetect gaai_qa_aggregate; do
  if declare -f "$fn" >/dev/null 2>&1; then pass "$fn is defined"; else fail "$fn is missing"; fi
done

echo "── provenance survives the worktree, and records what it must ──"
# Durability and tamper-resistance pull opposite ways. The first version of this
# block asserted the ledger lived INSIDE the worktree — which is durable and
# also writable by the very agent it clears. These assertions now encode both
# properties instead of trading one away.
unset GAAI_PROVENANCE_DIR
export LOCK_DIR="${TMP}/locks"
WT_A="${TMP}/wt-a"; WT_B="${TMP}/wt-b"; mkdir -p "$WT_A" "$WT_B"

gaai_routing_bind_worktree "$WT_A"
gaai_route_select PLAN_PRODUCER WT-STORY-A >/dev/null
gaai_provenance_record WT-STORY-A PLAN "$GAAI_ROUTE_MODEL_ID" PLAN_PRODUCER
LEDGER_A="${GAAI_PROVENANCE_DIR}/WT-STORY-A.provenance.json"
[[ -s "$LEDGER_A" ]] \
  && pass "the authoritative record is written to daemon state" \
  || fail "no authoritative record written"

grep -q '"effort"' "$LEDGER_A" \
  && pass "the record carries the effort each model ran at" \
  || fail "the record omits effort — raised effort would be unmeasurable after the fact"

gaai_provenance_publish WT-STORY-A "$WT_A" >/dev/null
[[ -s "$WT_A/.gaai/project/contexts/artefacts/routing/WT-STORY-A.provenance.json" ]] \
  && pass "the published copy lands where the commit phase stages it" \
  || fail "publish did not reach the worktree artefact tree"

# Phases run back to back in one process; a stale binding would file story B's
# record under story A.
gaai_routing_bind_worktree "$WT_B"
gaai_route_select IMPL WT-STORY-B >/dev/null
gaai_provenance_record WT-STORY-B CODE "$GAAI_ROUTE_MODEL_ID" IMPL
gaai_provenance_publish WT-STORY-B "$WT_B" >/dev/null
if [[ -s "$WT_B/.gaai/project/contexts/artefacts/routing/WT-STORY-B.provenance.json" ]] \
   && [[ ! -e "$WT_A/.gaai/project/contexts/artefacts/routing/WT-STORY-B.provenance.json" ]]; then
  pass "rebinding switches stories instead of accumulating"
else
  fail "a stale binding filed one story's record under another"
fi

gaai_harness_mark claude AVAILABLE "placement check" >/dev/null
if find "$WT_A" "$WT_B" -name 'claude.json' 2>/dev/null | grep -q .; then
  fail "harness state leaked into a story's artefact tree"
else
  pass "harness state stays in daemon state, out of the commit"
fi
unset GAAI_ROUTING_WORKTREE GAAI_PROVENANCE_DIR
export GAAI_PROVENANCE_DIR="${TMP}/provenance"

echo "── the evaluator cannot reach the record that clears it ──"
# The QA agent runs inside the worktree with permissions skipped. If the
# authoritative ledger lived there, the evaluator could delete the CODE entry
# attesting that it did not write the code it is judging.
unset GAAI_PROVENANCE_DIR
export LOCK_DIR="${TMP}/locks"
WT_TAMPER="${TMP}/wt-tamper"; mkdir -p "$WT_TAMPER"
gaai_routing_bind_worktree "$WT_TAMPER"
case "$GAAI_PROVENANCE_DIR" in
  "$WT_TAMPER"/*) fail "the authoritative ledger sits inside the agent-writable worktree" ;;
  *) pass "the authoritative ledger is outside the worktree the agent can write" ;;
esac

gaai_route_select IMPL TAMPER-1 >/dev/null
gaai_provenance_record TAMPER-1 CODE "$GAAI_ROUTE_MODEL_ID" IMPL
if gaai_provenance_publish TAMPER-1 "$WT_TAMPER" >/dev/null; then
  [[ -s "$WT_TAMPER/.gaai/project/contexts/artefacts/routing/TAMPER-1.provenance.json" ]] \
    && pass "the commit phase publishes a daemon-authored copy for staging" \
    || fail "publish reported success but wrote nothing"
else
  fail "provenance publish failed"
fi

# An agent that pre-empts the path must not win: the daemon's copy is authority.
echo '{"tampered":true}' > "$WT_TAMPER/.gaai/project/contexts/artefacts/routing/TAMPER-1.provenance.json"
gaai_provenance_publish TAMPER-1 "$WT_TAMPER" >/dev/null
if grep -q '"tampered"' "$WT_TAMPER/.gaai/project/contexts/artefacts/routing/TAMPER-1.provenance.json"; then
  fail "an agent-planted file survived the daemon publish"
else
  pass "a pre-planted file is overwritten by the daemon's copy"
fi
unset GAAI_ROUTING_WORKTREE GAAI_PROVENANCE_DIR
export GAAI_PROVENANCE_DIR="${TMP}/provenance"

grep -q 'PROVENANCE_WRITE_FAILED' "$DISPATCH" \
  && pass "an unrecordable author fails the impl phase instead of advancing it" \
  || fail "a failed provenance write is still swallowed"

echo "── selection handoff ──"
if gaai_route_select PLAN_PRODUCER TESTS01; then
  [[ -n "$GAAI_ROUTE_MODEL_ID" ]] && pass "select exports GAAI_ROUTE_MODEL_ID (${GAAI_ROUTE_MODEL_ID})" \
    || fail "select left GAAI_ROUTE_MODEL_ID empty"
  [[ -n "$GAAI_ROUTE_MODEL" ]] && pass "select exports the concrete model (${GAAI_ROUTE_MODEL})" \
    || fail "select left GAAI_ROUTE_MODEL empty"
  [[ "$GAAI_ROUTE_EFFORT" == "high" ]] && pass "default effort is high" \
    || fail "default effort was '${GAAI_ROUTE_EFFORT}', expected high"
else
  fail "select PLAN_PRODUCER returned $? (expected 0)"
fi

if gaai_route_select PLAN_PRODUCER TESTS01 --high-risk && [[ "$GAAI_ROUTE_EFFORT" == "xhigh" ]]; then
  pass "--high-risk escalates effort to xhigh"
else
  fail "--high-risk did not escalate effort (got '${GAAI_ROUTE_EFFORT:-}')"
fi

echo "── provenance round-trip through bash ──"
gaai_route_select PLAN_PRODUCER TESTS02 >/dev/null
PRODUCER="$GAAI_ROUTE_MODEL_ID"
if gaai_provenance_record TESTS02 PLAN "$PRODUCER" PLAN_PRODUCER; then
  pass "provenance record wrote the PLAN contributor"
else
  fail "provenance record failed"
fi
if gaai_route_select PLAN_REVIEWER TESTS02 && [[ "$GAAI_ROUTE_MODEL_ID" != "$PRODUCER" ]]; then
  pass "reviewer is not the producer (${GAAI_ROUTE_MODEL_ID} != ${PRODUCER})"
else
  fail "reviewer selection returned the producer ${PRODUCER}"
fi

echo "── effort reaches both harness command lines ──"
if grep -qE 'agent_cmd=\(claude -p "\$@" \$\{_effort_argv' "$DISPATCH"; then
  pass "the claude invocation carries the routed effort flag"
else
  fail "the claude invocation drops the routed effort flag"
fi
grep -q '_impl_effort_extra' "$DISPATCH" \
  && pass "impl passes effort through nested-claude-spawn's --extra-arg" \
  || fail "impl drops the routed effort on the claude harness"

echo "── harness features ──"
if gaai_route_select PLAN_PRODUCER TESTS08 --require-feature mcp; then
  [[ "$GAAI_ROUTE_HARNESS" == "claude" ]] \
    && pass "--require-feature mcp routes to an MCP-capable harness (${GAAI_ROUTE_HARNESS})" \
    || fail "--require-feature mcp routed to ${GAAI_ROUTE_HARNESS}, which does not declare mcp"
else
  fail "--require-feature mcp found no candidate"
fi
grep -q 'require-feature mcp' "$DISPATCH" \
  && pass "phases that carry an MCP config require an MCP-capable harness" \
  || fail "phases can be routed to a harness that drops their MCP config"

echo "── an operator pin cannot seat the author ──"
gaai_route_select IMPL PIN-STORY >/dev/null
gaai_provenance_record PIN-STORY CODE "$GAAI_ROUTE_MODEL_ID" IMPL
PIN_IMPL_MODEL="$GAAI_ROUTE_MODEL"
if gaai_pin_is_independent PIN-STORY QA_PLAN "$PIN_IMPL_MODEL"; then
  fail "a pin naming the implementer was accepted for QA"
else
  pass "a pin naming the implementer is refused for QA (${PIN_IMPL_MODEL})"
fi
gaai_route_select QA_PLAN PIN-STORY >/dev/null
if gaai_pin_is_independent PIN-STORY QA_PLAN "$GAAI_ROUTE_MODEL"; then
  pass "a pin naming an independent model is accepted"
else
  fail "an independent pin was refused"
fi
# The gate must see the implementer under every spelling an operator might use —
# the CLI short name is the likeliest, and it was the one that got through.
for _sp in "$PIN_IMPL_MODEL" sonnet claude_worker; do
  if gaai_pin_is_independent PIN-STORY QA_PLAN "$_sp"; then
    fail "pin spelling '${_sp}' walked past the independence gate"
  else
    pass "pin spelling '${_sp}' is refused"
  fi
done
if gaai_pin_is_independent PIN-STORY QA_PLAN "a-model-nobody-declared"; then
  fail "an unresolvable pin was treated as independent — the gate fails OPEN"
else
  pass "an unresolvable pin fails closed (a gate can only clear what it can identify)"
fi

# A pin that cannot be CHECKED is as dangerous as one that is ineligible:
# "pin the evaluator" composed with "remove the library" would otherwise seat the
# author as its own judge without ever touching the documented switch.
grep -q 'QA_PIN_UNVERIFIABLE' "$DISPATCH" \
  && pass "an unverifiable pin (substrate absent) fails the phase rather than proceeding" \
  || fail "a pin proceeds unchecked when the routing substrate is absent"

if awk '
  /^[[:space:]]*#/ { next }
  index($0, "_plan_resolve_ledger_path _plan_ledger_path \"$story_id\"") { resolved=1 }
  index($0, "_plan_record_contribution_direct \"$_plan_ledger_path\" \"$story_id\"") { recorded=1 }
  END { exit !(resolved && recorded) }
' "$DISPATCH"; then
  pass "PLAN contribution resolves one authoritative ledger and records the captured tuple directly"
else
  fail "PLAN contribution is not bound to the resolver-authoritative ledger path"
fi

grep -q 'QA_PIN_NOT_INDEPENDENT' "$DISPATCH" \
  && pass "the daemon fails the phase on a non-independent pin rather than warning" \
  || fail "the daemon still only warns on a non-independent pin"

echo "── kill switch ──"
(
  export GAAI_MODEL_ROUTING=0
  gaai_route_select PLAN_PRODUCER TESTS03
  rc=$?
  [[ "$rc" == "1" && "$GAAI_ROUTE_STATUS" == "DISABLED" ]]
) && pass "GAAI_MODEL_ROUTING=0 reports DISABLED and rc=1" \
  || fail "kill switch did not report DISABLED/rc=1"

echo "── a router that cannot run is not a router that refused ──"
(
  export GAAI_ROUTING_CONFIG="${TMP}/nonexistent-config.json"
  gaai_route_select QA_PLAN TESTS06
  [[ "$GAAI_ROUTE_STATUS" == "ROUTER_ERROR" && -z "$GAAI_ROUTE_BLOCKED_CLASS" ]]
) && pass "an unreadable config reports ROUTER_ERROR, not a blocked route" \
  || fail "an unreadable config was reported as a blocked route"

grep -q 'ROUTER_MISSING' "$DISPATCH" \
  && pass "QA distinguishes routing-unavailable from routing-refused" \
  || fail "QA treats routing-unavailable the same as routing-refused"

echo "── effort env does not leak between phases ──"
(
  gaai_route_select PLAN_PRODUCER TESTS07 >/dev/null
  # Force an env-mode effort expression so there is something to leak.
  GAAI_ROUTE_EFFORT_ENV="GAAI_TEST_THINK=42" gaai_route_export_effort
  [[ "${GAAI_TEST_THINK:-}" == "42" ]] || exit 1
  GAAI_ROUTE_EFFORT_ENV="" gaai_route_export_effort
  [[ -z "${GAAI_TEST_THINK:-}" ]]
) && pass "a later unrouted phase does not inherit the previous phase's effort budget" \
  || fail "effort env leaked across phases"

echo "── harness availability ──"
gaai_harness_mark claude QUOTA_EXHAUSTED "shim test" 600
if gaai_route_select PLAN_PRODUCER TESTS04; then
  if [[ "$GAAI_ROUTE_HARNESS" != "claude" ]]; then
    pass "a quota-exhausted harness is skipped (routed to ${GAAI_ROUTE_HARNESS})"
  else
    fail "routed to claude despite QUOTA_EXHAUSTED"
  fi
else
  # Legitimate when claude is the only harness with a FRONTIER candidate up.
  [[ "$GAAI_ROUTE_BLOCKED_CLASS" == "AVAILABILITY" ]] \
    && pass "quota exhaustion blocked with class=AVAILABILITY" \
    || fail "blocked with unexpected class '${GAAI_ROUTE_BLOCKED_CLASS}'"
fi
gaai_harness_mark claude AVAILABLE "shim test reset"

# Fixtures carry a real provider's out-of-budget wording verbatim. Detection was
# first written against imagined phrasing and missed the real message entirely,
# which left a spent harness in rotation burning one spawn per phase.
QUOTA_FIXTURE="${SCRIPT_DIR}/fixtures/harness-quota-exhausted.log"
TRANSIENT_FIXTURE="${SCRIPT_DIR}/fixtures/harness-transient-failure.log"

if gaai_harness_autodetect claude "$QUOTA_FIXTURE" >/dev/null; then
  pass "autodetect parks a harness on a real out-of-budget message"
else
  fail "autodetect missed a real out-of-budget message"
fi

if [[ -f "${GAAI_HARNESS_STATUS_DIR}/claude.json" ]] \
   && grep -q '"status": *"QUOTA_EXHAUSTED"' "${GAAI_HARNESS_STATUS_DIR}/claude.json" \
   && grep -q '"until": *"[0-9]' "${GAAI_HARNESS_STATUS_DIR}/claude.json"; then
  pass "the park carries an expiry, so it heals without an operator"
else
  fail "the park has no expiry"
fi

if grep -q 'resumes' "${GAAI_HARNESS_STATUS_DIR}/claude.json"; then
  pass "the park honours the provider's own stated resume time"
else
  fail "the park ignored the provider's stated resume time"
fi

# A blocked harness must not be routed to, whatever the role asks for.
if gaai_route_select QA_PLAN TESTS09; then
  [[ "$GAAI_ROUTE_HARNESS" != "claude" ]] \
    && pass "a parked harness is out of rotation for every role" \
    || fail "routed to a parked harness"
else
  [[ "$GAAI_ROUTE_BLOCKED_CLASS" == "AVAILABILITY" ]] \
    && pass "a parked harness blocks with class=AVAILABILITY (retryable, not failed)" \
    || fail "unexpected block class '${GAAI_ROUTE_BLOCKED_CLASS}'"
fi
gaai_harness_mark claude AVAILABLE "shim test reset"

if gaai_harness_autodetect claude "$TRANSIENT_FIXTURE" >/dev/null; then
  fail "autodetect parked a harness on a transient failure"
else
  pass "autodetect ignores transient failures"
fi

echo "── resilience when the message is unrecognisable ──"
printf '{"type":"error","message":"entirely unrecognised failure text"}\n' > "${TMP}/weird.log"
gaai_harness_mark claude AVAILABLE "reset" >/dev/null
node "$(_gaai_router_bin)" harness-success --harness claude >/dev/null 2>&1
CB_THRESHOLD=$(python3 -c "import json;print(json.load(open('${PROJECT_DIR}/.gaai/core/config/delivery-routing.json'))['quota_detection']['circuit_breaker']['consecutive_failures'])")
parked=""
for i in $(seq 1 "$CB_THRESHOLD"); do
  if gaai_harness_autodetect claude "${TMP}/weird.log" >/dev/null; then parked="$i"; break; fi
done
[[ -n "$parked" ]] \
  && pass "an unrecognised failure still parks the harness after ${parked} tries (detection is not load-bearing)" \
  || fail "an unrecognised failure never parks the harness — it would bleed a spawn per phase forever"

if grep -q '"until": *"[0-9]' "${GAAI_HARNESS_STATUS_DIR}/claude.json"; then
  pass "the breaker's park expires on its own"
else
  fail "the breaker's park has no expiry"
fi

gaai_harness_success claude
gaai_harness_mark claude AVAILABLE "reset" >/dev/null
gaai_harness_autodetect claude "${TMP}/weird.log" >/dev/null
if gaai_harness_autodetect claude "${TMP}/weird.log" >/dev/null; then
  fail "a success did not reset the failure count"
else
  pass "a success resets the count, so unrelated stories do not accumulate"
fi
gaai_harness_mark claude AVAILABLE "reset" >/dev/null
node "$(_gaai_router_bin)" harness-success --harness claude >/dev/null 2>&1

grep -q 'gaai_harness_success' "$DISPATCH" \
  && pass "the daemon reports phase successes, so the count reflects reality" \
  || fail "the daemon never reports success — the count would only ever climb"

echo "── an agent cannot erase its way into the evaluator seat ──"
# The realistic attack is not the evaluator erasing its own trace: it is the
# IMPL agent erasing its CODE entry so QA routing sees no contributor and seats
# the implementer as its own judge. It only bites when the implementer is also a
# QA candidate, so the fixture forces that case rather than assuming it.
SEAL_DIR="${TMP}/seal"; mkdir -p "$SEAL_DIR"
( export GAAI_PROVENANCE_DIR="$SEAL_DIR" GAAI_MODEL_DISABLE=claude_worker
  gaai_route_select IMPL SEAL-STORY >/dev/null
  impl="$GAAI_ROUTE_MODEL_ID"
  gaai_provenance_record SEAL-STORY CODE "$impl" IMPL
  gaai_route_select QA_PLAN SEAL-STORY >/dev/null
  [[ "$GAAI_ROUTE_MODEL_ID" != "$impl" ]] || exit 1        # intact: implementer excluded
  gaai_provenance_seal SEAL-STORY
  python3 -c "
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['contributions']=[c for c in d['contributions'] if c['artifact']!='CODE']
json.dump(d,open(p,'w'))" "$SEAL_DIR/SEAL-STORY.provenance.json"
  gaai_route_select QA_PLAN SEAL-STORY >/dev/null
  [[ "$GAAI_ROUTE_MODEL_ID" == "$impl" ]] || exit 2         # erasure did re-seat the author
  gaai_provenance_verify_seal SEAL-STORY && exit 3          # seal must catch it
  exit 0                                                     # the failing verify is the PASS here
) && pass "erasing a CODE entry mid-spawn is detected before the routing it would corrupt" \
  || fail "the seal did not catch an erasure that re-seats the implementer as judge"

( export GAAI_PROVENANCE_DIR="${TMP}/seal-clean"
  mkdir -p "$GAAI_PROVENANCE_DIR"
  gaai_route_select PLAN_PRODUCER SEAL-CLEAN >/dev/null
  gaai_provenance_record SEAL-CLEAN PLAN "$GAAI_ROUTE_MODEL_ID" PLAN_PRODUCER
  gaai_provenance_seal SEAL-CLEAN
  gaai_provenance_verify_seal SEAL-CLEAN
) && pass "an untouched record verifies clean (no false positive on every phase)" \
  || fail "the seal reports tampering on an untouched record"

( export GAAI_PROVENANCE_DIR="${TMP}/seal-new"
  mkdir -p "$GAAI_PROVENANCE_DIR"
  gaai_provenance_seal SEAL-NEW                              # sealed while absent
  gaai_provenance_record SEAL-NEW PLAN claude_strong PLAN_PRODUCER
  gaai_provenance_verify_seal SEAL-NEW && exit 1
  exit 0
) && pass "a record that APPEARS during a spawn is a tamper signal too" \
  || fail "a record appearing mid-spawn went undetected"

grep -q 'PROVENANCE_TAMPERED' "$DISPATCH" \
  && pass "the daemon fails the phase on a tampered record rather than continuing" \
  || fail "the daemon does not act on a tampered record"

if awk '
  /^[[:space:]]*#/ { next }
  index($0, "_plan_provenance_seal_path _plan_ledger_seal \"$_plan_ledger_path\"") { sealed=1 }
  index($0, "_plan_provenance_path_matches_seal \"$_plan_ledger_path\" \"$_plan_ledger_seal\"") { verified=1 }
  END { exit !(sealed && verified) }
' "$DISPATCH"; then
  pass "PLAN seals and verifies the resolver-authoritative ledger path"
else
  fail "PLAN does not jointly seal and verify its resolver-authoritative ledger path"
fi

SEAL_COUNTS=$(awk '
  function starts_function(line) {
    return line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/
  }
  starts_function($0) {
    if ($0 ~ /^handle_impl_phase\(\) \{/) current="impl"
    else if ($0 ~ /^handle_qa_phase\(\) \{/) current="qa"
    else current="other"
  }
  /^[[:space:]]*#/ { next }
  index($0, "gaai_provenance_seal \"$story_id\"") {
    total++
    if (current == "impl") impl++
    if (current == "qa") qa++
  }
  END { printf "%d %d %d\n", total, impl, qa }
' "$DISPATCH")
read -r SEAL_POINTS IMPL_SEAL_POINTS QA_SEAL_POINTS <<< "$SEAL_COUNTS"
if [[ "$SEAL_POINTS" -eq 2 && "$IMPL_SEAL_POINTS" -eq 1 && "$QA_SEAL_POINTS" -eq 1 ]]; then
  pass "generic provenance seals remain executable only in IMPL and QA"
else
  fail "generic seal placement drifted (total=${SEAL_POINTS}, impl=${IMPL_SEAL_POINTS}, qa=${QA_SEAL_POINTS})"
fi

echo "── verdict aggregation ──"
gaai_qa_aggregate QA_CODE=PASS QA_REQUIREMENTS=PASS QA_PLAN=PASS \
  && pass "all-PASS aggregates to PASS" || fail "all-PASS did not aggregate to PASS"
gaai_qa_aggregate QA_CODE=PASS QA_REQUIREMENTS=FAIL QA_PLAN=ESCALATE
[[ "$GAAI_QA_VERDICT" == "FAIL" ]] && pass "FAIL outranks ESCALATE" || fail "expected FAIL, got ${GAAI_QA_VERDICT}"
gaai_qa_aggregate QA_CODE=PASS QA_REQUIREMENTS=PASS
[[ "$GAAI_QA_VERDICT" == "ESCALATE" ]] && pass "a missing lane escalates" || fail "expected ESCALATE, got ${GAAI_QA_VERDICT}"

echo "── config health is checkable before a story runs ──"
DOCTOR=$(node "$(_gaai_router_bin)" doctor 2>/dev/null)
if [[ -n "$DOCTOR" ]] && python3 -c "
import json,sys
d=json.loads(sys.argv[1])
sys.exit(0 if not d['errors'] else 1)" "$DOCTOR"; then
  pass "doctor reports a valid registry"
else
  fail "doctor reports config errors"
fi

if python3 -c "
import json,sys
d=json.loads(sys.argv[1])
r=d.get('resilience') or {}
bad=[k for k,v in r.items() if v['blocked']]
sys.exit(0 if r and not bad else 1)" "$DOCTOR"; then
  pass "every single-provider outage still serves the whole pipeline"
else
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
for k,v in (d.get('resilience') or {}).items():
    if v['blocked']: print('     ', k, '->', ', '.join(v['blocked']))" "$DOCTOR"
  fail "a single-provider outage leaves roles unservable"
fi

echo "── dispatch integration ──"
grep -q 'delivery-routing.sh' "$DISPATCH" \
  && pass "daemon-dispatch.sh sources the routing shim" \
  || fail "daemon-dispatch.sh does not source the routing shim"

if grep -q 'GAAI_PHASE_HARNESS' "$DISPATCH"; then
  pass "daemon-dispatch.sh honours a per-call harness"
else
  fail "daemon-dispatch.sh has no per-call harness override"
fi

# The override must actually reach the executor switch, not just be exported.
(
  BACKLOG_FILE=/dev/null SCHEDULER=/bin/true
  # shellcheck source=../daemon-dispatch.sh
  source "$DISPATCH" >/dev/null 2>&1
  out=$(GAAI_PHASE_HARNESS=not-a-harness GAAI_DAEMON_EXECUTOR=claude \
    _run_claude_with_loop_breaker TESTS05 plan /dev/null /dev/null "$TMP" 2>&1)
  [[ "$out" == *"unsupported GAAI_DAEMON_EXECUTOR=not-a-harness"* ]]
) && pass "GAAI_PHASE_HARNESS wins over GAAI_DAEMON_EXECUTOR at the executor switch" \
  || fail "GAAI_PHASE_HARNESS did not reach the executor switch"

echo
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
