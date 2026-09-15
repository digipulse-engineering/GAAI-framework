#!/usr/bin/env bash
# delivery-routing.sh — bash surface over delivery-router.mjs.
#
# Sourceable library for daemon-dispatch.sh. Holds no policy of its own: every
# decision comes from the router, this file only marshals it into shell
# variables the phase handlers can act on.
#
# Caller must have PROJECT_DIR set. LOCK_DIR is used when present so provenance
# and harness state live with the rest of the daemon's durable state rather than
# inside a per-story worktree that gets reaped.
#
# Kill switch: GAAI_MODEL_ROUTING=0 disables routed selection entirely and the
# phase handlers keep their legacy fixed-model behaviour. That also forfeits the
# no-self-evaluation guarantee, so it is an explicit operator choice, never a
# fallback the daemon takes on its own — and it is the ONLY way to forfeit it.
# A per-phase model pin skips candidate ordering but is still checked against
# provenance; a pin naming a contributor stops the phase.

# ── Paths ──────────────────────────────────────────────────────────────────
_gaai_router_bin() {
  printf '%s' "${GAAI_ROUTER_BIN:-${PROJECT_DIR}/.gaai/core/scripts/lib/delivery-router.mjs}"
}

# Durable state roots. Explicit env always wins.
#
# Provenance has to satisfy two properties that pull in opposite directions, and
# getting one at the cost of the other is how this was wrong twice.
#
#   Durable   — the record of who wrote a story's artefacts must outlive the
#               worktree that produced it, or the audit trail dies with the story.
#   Untamperable — it certifies the independence of the QA agent, and that agent
#               runs inside the worktree with permissions skipped.
#
# Writing it beside the locks gave durability nothing (the state is transient).
# Writing it into the worktree gave tamper-resistance nothing: the evaluator could
# edit the very file attesting that it did not write the code it was judging.
#
# So the authoritative copy lives in daemon state, where no phase agent can reach
# it, and the commit phase PUBLISHES a copy into the worktree artefact tree after
# every agent has exited — durable because it is committed, trustworthy because
# the only writer was the daemon.
_gaai_routing_state_env() {
  if [[ -z "${GAAI_PROVENANCE_DIR:-}" ]]; then
    if [[ -n "${LOCK_DIR:-}" ]]; then
      export GAAI_PROVENANCE_DIR="${LOCK_DIR}/provenance"
    fi
  fi
  if [[ -z "${GAAI_HARNESS_STATUS_DIR:-}" && -n "${LOCK_DIR:-}" ]]; then
    export GAAI_HARNESS_STATUS_DIR="${LOCK_DIR}/harness-status"
  fi
}

# gaai_routing_bind_worktree <WORKTREE_PATH>
#
# Records which worktree this story is running in, for the commit-phase publish.
# It deliberately does NOT point provenance into that worktree — see above.
gaai_routing_bind_worktree() {
  local worktree_path="$1"
  [[ -n "$worktree_path" ]] || return 0
  export GAAI_ROUTING_WORKTREE="$worktree_path"
  # Re-derive on every bind: phases run back to back in one process, and a stale
  # provenance dir would file this story's record under the previous story.
  unset GAAI_PROVENANCE_DIR
  _gaai_routing_state_env
}

# gaai_provenance_publish <STORY_ID> <WORKTREE_PATH>
#
# Copies the authoritative record into the worktree so the commit phase stages it.
# Called after every phase agent has exited, so the only writer of the committed
# copy is the daemon. Overwrites any file an agent may have left at that path —
# the daemon's copy is the authority, and a pre-existing file there is at best
# noise and at worst an attempt to pre-empt this write.
# ── Tamper evidence across an agent spawn ──────────────────────────────────
#
# The authority record lives outside the worktree, which stops the codex harness
# reaching it (it runs under --sandbox workspace-write) but NOT the claude one,
# which runs as the same OS user with --dangerously-skip-permissions and no
# filesystem jail. Against that harness no file location is out of reach, so
# location alone is not a trust boundary and treating it as one was a mistake.
#
# The one boundary that does exist is the daemon's own memory: the daemon blocks
# on the phase agent, so a variable held across the spawn is unreachable by the
# child. The seal is kept there and nowhere else.
#
# This detects rather than prevents. That is sufficient for the invariant it
# guards: a tampered record fails its phase, so the outcome an agent could buy by
# editing its own provenance is a failed story, not a laundered verdict. The
# attack it does NOT distinguish is tampering that also makes verification look
# like infrastructure failure — "altered" versus "broken", not "altered" versus
# "intact".
#
# The seal spans EVERY agent spawn, not only QA. The realistic attack is not the
# evaluator erasing its own trace, it is the IMPL agent erasing its CODE entry so
# that QA routing sees no contributor and seats the implementer as its own judge.

_gaai_digest() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
  else echo "NO_DIGEST_TOOL"; fi
}

# gaai_provenance_seal <STORY_ID>
# Capture the authority record's state into daemon memory. Call immediately
# before handing control to an agent.
gaai_provenance_seal() {
  local story_id="$1"
  _GAAI_PROVENANCE_SEAL=""
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  local f="${GAAI_PROVENANCE_DIR}/${story_id}.provenance.json"
  if [[ -s "$f" ]]; then
    _GAAI_PROVENANCE_SEAL="$(_gaai_digest "$f")"
  else
    # Absent is a state worth sealing: a record appearing during a spawn is as
    # much a tamper signal as one changing.
    _GAAI_PROVENANCE_SEAL="ABSENT"
  fi
  return 0
}

# gaai_provenance_verify_seal <STORY_ID>
# 0 = intact or nothing was sealed; 1 = the record changed while an agent held
# control. Call immediately after the agent exits, BEFORE the daemon makes its
# own writes (which legitimately change the file).
gaai_provenance_verify_seal() {
  local story_id="$1"
  [[ -n "${_GAAI_PROVENANCE_SEAL:-}" ]] || return 0
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  local f="${GAAI_PROVENANCE_DIR}/${story_id}.provenance.json" now
  if [[ -s "$f" ]]; then now="$(_gaai_digest "$f")"; else now="ABSENT"; fi
  if [[ "$now" == "NO_DIGEST_TOOL" || "$_GAAI_PROVENANCE_SEAL" == "NO_DIGEST_TOOL" ]]; then
    # No digest tool: say so rather than reporting an integrity check that never ran.
    echo "[WARN] ${story_id}: no sha256 tool available — provenance integrity was NOT verified" >&2
    return 0
  fi
  [[ "$now" == "$_GAAI_PROVENANCE_SEAL" ]]
}

gaai_provenance_publish() {
  local story_id="$1" worktree_path="$2"
  [[ -n "$story_id" && -d "$worktree_path" ]] || return 0
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  local src="${GAAI_PROVENANCE_DIR}/${story_id}.provenance.json"
  [[ -s "$src" ]] || return 0
  if ! gaai_provenance_verify_seal "$story_id"; then
    echo "[ERROR] ${story_id}: provenance changed since it was sealed — refusing to publish a record that may have been altered by an agent" >&2
    return 1
  fi
  local dst_dir="${worktree_path}/.gaai/project/contexts/artefacts/routing"
  mkdir -p "$dst_dir" || return 1
  if ! cp -f "$src" "${dst_dir}/${story_id}.provenance.json"; then
    echo "[ERROR] ${story_id}: provenance publish failed — the committed record would be missing" >&2
    return 1
  fi
  echo "[ROUTING] ${story_id}: provenance published to the worktree for commit"
  return 0
}

gaai_routing_enabled() {
  [[ "${GAAI_MODEL_ROUTING:-1}" != "0" ]]
}

# ── Selection ──────────────────────────────────────────────────────────────
# gaai_route_select <ROLE> <STORY_ID> [extra router flags...]
#
# On success sets, in the caller's shell:
#   GAAI_ROUTE_STATUS GAAI_ROUTE_MODEL_ID GAAI_ROUTE_MODEL GAAI_ROUTE_HARNESS
#   GAAI_ROUTE_CAPABILITY GAAI_ROUTE_EFFORT GAAI_ROUTE_EFFORT_ENV
#   GAAI_ROUTE_EFFORT_ARGS GAAI_ROUTE_BLOCKED_CLASS GAAI_ROUTE_REASON
#   GAAI_ROUTE_EXCLUDED GAAI_ROUTE_TRACE
#
# Returns 0 = SELECTED, 3 = BLOCKED_NO_ELIGIBLE_MODEL, 1 = routing disabled or
# the router could not run (caller decides; evaluation steps must fail closed).
gaai_route_select() {
  local role="$1" story_id="$2"; shift 2
  GAAI_ROUTE_STATUS=""; GAAI_ROUTE_MODEL_ID=""; GAAI_ROUTE_MODEL=""
  GAAI_ROUTE_HARNESS=""; GAAI_ROUTE_CAPABILITY=""; GAAI_ROUTE_EFFORT=""
  GAAI_ROUTE_EFFORT_ENV=""; GAAI_ROUTE_EFFORT_ARGS=""
  GAAI_ROUTE_WAIVED=""
  GAAI_ROUTE_BLOCKED_CLASS=""; GAAI_ROUTE_REASON=""; GAAI_ROUTE_EXCLUDED=""; GAAI_ROUTE_TRACE=""

  if ! gaai_routing_enabled; then
    GAAI_ROUTE_STATUS="DISABLED"
    GAAI_ROUTE_REASON="GAAI_MODEL_ROUTING=0"
    return 1
  fi
  _gaai_routing_state_env

  local bin out rc
  bin="$(_gaai_router_bin)"
  if [[ ! -f "$bin" ]]; then
    GAAI_ROUTE_STATUS="ROUTER_MISSING"
    GAAI_ROUTE_REASON="router not found at ${bin}"
    return 1
  fi

  out=$(node "$bin" select --role "$role" --story "$story_id" --format sh "$@" 2>/dev/null)
  rc=$?
  # rc 0 = SELECTED, 3 = BLOCKED_NO_ELIGIBLE_MODEL. Anything else (usage error,
  # unreadable config, node failure) is the router not running, which is a
  # different condition from the router refusing — callers must be able to tell
  # them apart.
  if [[ -z "$out" || ( "$rc" != "0" && "$rc" != "3" ) ]]; then
    GAAI_ROUTE_STATUS="ROUTER_ERROR"
    GAAI_ROUTE_REASON="router did not complete (rc=${rc})"
    return 1
  fi
  # Output is `KEY='single-quoted'` lines produced by the router's own quoter.
  eval "$out"
  return "$rc"
}

# Applies the selected model's reasoning-effort expression to the *current*
# shell, so the subsequent phase spawn inherits it. env-mode harnesses get
# exported variables; arg-mode harnesses get argv the caller appends.
# Word splitting on GAAI_ROUTE_EFFORT_ENV is intentional: the router emits
# space-separated KEY=VALUE pairs whose values never contain whitespace.
gaai_route_export_effort() {
  # Clear whatever the previous phase exported first. Phases run back to back in
  # one wrapper process, so a thinking budget set for a routed plan would
  # otherwise still be in the environment of an unrouted impl.
  local _k
  for _k in ${_GAAI_ROUTE_EFFORT_KEYS:-}; do unset "$_k"; done
  _GAAI_ROUTE_EFFORT_KEYS=""
  [[ -n "${GAAI_ROUTE_EFFORT_ENV:-}" ]] || return 0
  local _pair
  # shellcheck disable=SC2086
  for _pair in ${GAAI_ROUTE_EFFORT_ENV}; do
    export "${_pair?}"
    _GAAI_ROUTE_EFFORT_KEYS="${_GAAI_ROUTE_EFFORT_KEYS} ${_pair%%=*}"
  done
}

# ── Provenance ─────────────────────────────────────────────────────────────
# gaai_provenance_record <STORY_ID> <ARTIFACT> <MODEL_ID> [ROLE] [NOTE]
#
# Call this only once a step has actually contributed. A model that was selected
# and then died before producing anything is not a contributor, and recording it
# would retire an eligible model for no reason.
gaai_provenance_record() {
  local story_id="$1" artifact="$2" model_id="$3" role="${4:-}" note="${5:-}"
  local duration_ms="${6:-0}"
  # The routing decision's own details come from the select that chose this
  # model. Recorded now because they cannot be reconstructed later: a question
  # deferred is answerable from history, a field never written is not.
  local effort="${GAAI_ROUTE_EFFORT:-}" waived="${GAAI_ROUTE_WAIVED:-}" trace="${GAAI_ROUTE_TRACE:-}"
  # The attempt identity: distinct executions must not collapse into one row.
  local attempt="${GAAI_PROVENANCE_ATTEMPT:-${STORY_TRACE_ID:-}}"
  [[ -n "$model_id" ]] || return 0
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  node "$(_gaai_router_bin)" record \
    --story "$story_id" --artifact "$artifact" --model-id "$model_id" \
    --role "$role" --effort "$effort" --waived "$waived" --attempt "$attempt" \
    --duration-ms "$duration_ms" --trace "$trace" --note "$note" >/dev/null 2>&1 || {
      echo "[WARN] ${story_id}: provenance record failed (artifact=${artifact} model=${model_id})" >&2
      return 1
    }
  return 0
}

# gaai_provenance_blocked <STORY_ID> <ROLE>
#
# Records a step that could not be routed. A block leaves no contributor, so
# without this it leaves no trace at all — and blocks are the rarest and most
# interesting routing events.
gaai_provenance_blocked() {
  local story_id="$1" role="$2"
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  node "$(_gaai_router_bin)" record-blocked \
    --story "$story_id" --role "$role" \
    --blocked-class "${GAAI_ROUTE_BLOCKED_CLASS:-}" \
    --reason "${GAAI_ROUTE_REASON:-}" \
    --trace "${GAAI_ROUTE_TRACE:-}" >/dev/null 2>&1 || return 1
  return 0
}

# gaai_pin_is_independent <STORY_ID> <ROLE> <CONCRETE_MODEL>
#
# An operator pin skips candidate ordering; it may not skip the independence
# gate. Returns 0 when the pinned model did not contribute to what this step
# evaluates, non-zero when it did — or when independence cannot be proven.
gaai_pin_is_independent() {
  local story_id="$1" role="$2" model="$3"
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  node "$(_gaai_router_bin)" check-independent \
    --story "$story_id" --role "$role" --concrete-model "$model" >/dev/null 2>&1
}

# ── Harness availability ───────────────────────────────────────────────────
# gaai_harness_mark <HARNESS> <STATUS> [REASON] [TTL_SEC]
gaai_harness_mark() {
  local harness="$1" status="$2" reason="${3:-}" ttl="${4:-}"
  [[ -n "$harness" ]] || return 0
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  local args=(harness-status set --harness "$harness" --status "$status" --reason "$reason")
  [[ -n "$ttl" ]] && args+=(--ttl-sec "$ttl")
  node "$(_gaai_router_bin)" "${args[@]}" >/dev/null 2>&1 || return 1
  return 0
}

# gaai_harness_autodetect <HARNESS> <LOG_PATH>
#
# Call after a FAILED phase. Parks the harness on structured evidence only —
# how the session ended, the provider's last rate-limit verdict, the last error
# the harness raised (a structured code first, then a known message) — else once
# it has failed enough times in a row that the reason stops mattering. Free text
# in the transcript never counts: a story about rate limiting mentions every
# signature word without the provider refusing a single request. A session that
# ended on its own turn or spend cap is not evidence about the harness at all.
# Every layer is configuration, and the last one is what makes the others
# optional: a provider can reword its error, ship it localised, or fail in a way
# nobody anticipated, and a harness that keeps failing is unusable whether or
# not we can explain why.
#
# Returns 0 when the harness was parked, 1 when it was left in rotation.
gaai_harness_autodetect() {
  local harness="$1" log_path="$2"
  [[ -n "$harness" && -s "$log_path" ]] || return 1
  gaai_routing_enabled || return 1
  _gaai_routing_state_env

  local out
  if out=$(node "$(_gaai_router_bin)" harness-observe --harness "$harness" --log "$log_path" 2>/dev/null); then
    local until_at via
    until_at=$(sed -n 's/.*"until": *"\([^"]*\)".*/\1/p' <<<"$out" | head -1)
    via=$(sed -n 's/.*"via": *"\([^"]*\)".*/\1/p' <<<"$out" | head -1)
    echo "[ROUTING] harness=${harness} marked QUOTA_EXHAUSTED until ${until_at:-<backoff>} (out-of-budget ${via:-evidence} in ${log_path##*/})"
    return 0
  fi
  return 1
}

# gaai_harness_success <HARNESS>
#
# Call after a phase that completed. Clears the consecutive-failure count, so
# the circuit breaker only ever fires on a genuine run of failures rather than
# on a tally accumulated across unrelated stories.
gaai_harness_success() {
  local harness="$1"
  [[ -n "$harness" ]] || return 0
  gaai_routing_enabled || return 0
  _gaai_routing_state_env
  node "$(_gaai_router_bin)" harness-success --harness "$harness" >/dev/null 2>&1 || true
  return 0
}

# ── Verdict aggregation ────────────────────────────────────────────────────
# gaai_qa_aggregate LANE=VERDICT [LANE=VERDICT ...]
# Sets GAAI_QA_VERDICT, GAAI_QA_VERDICT_REASON, GAAI_QA_MISSING_LANES.
gaai_qa_aggregate() {
  GAAI_QA_VERDICT=""; GAAI_QA_VERDICT_REASON=""; GAAI_QA_MISSING_LANES=""
  _gaai_routing_state_env
  local args=(aggregate --format sh) lane
  for lane in "$@"; do args+=(--lane "$lane"); done
  local out
  out=$(node "$(_gaai_router_bin)" "${args[@]}" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  eval "$out"
  [[ "$GAAI_QA_VERDICT" == "PASS" ]]
}
