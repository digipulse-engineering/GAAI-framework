#!/usr/bin/env bash
# Helper: continuously shows human-readable status of active deliveries
# Parses stream-json NDJSON logs into readable summaries via jq

LOG_DIR="${1:-.gaai/project/contexts/backlog/.delivery-logs}"
# $2 (optional) = the daemon's dedicated home worktree. When the daemon coordinates in a
# home worktree, the LIVE backlog (in_progress marks) lives there, not in the operator's
# main checkout — so the active-deliveries enumeration must read the backlog from there.
# Logs/locks stay on the operator checkout (PROJECT_DIR) where deliveries write them.
DAEMON_HOME="${2:-}"
PROJECT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
BACKLOG="${DAEMON_HOME:-$PROJECT_DIR}/.gaai/project/contexts/backlog/active.backlog.yaml"
LOCK_DIR="${PROJECT_DIR}/.gaai/project/contexts/backlog/.delivery-locks"
# The daemon home sits directly under the worktree root, so the argument above names
# that root without any environment plumbing — and plumbing is exactly what cannot be
# relied on here: a pane created on an already-running tmux server inherits the
# SERVER's environment, not the invoking shell's, so exporting the root before this
# pane is created does not reach it. Deriving the root from the project directory
# instead answers for the default layout, which on any other layout is a path no
# delivery has ever written to; every per-phase log then resolves to nothing and a
# Story running normally is displayed as having no log at all.
if [[ -n "$DAEMON_HOME" && "$(basename "$DAEMON_HOME")" == "__daemon-home" ]]; then
  WORKTREE_BASE="$(dirname "$DAEMON_HOME")"
else
  WORKTREE_BASE="${GAAI_WORKTREES_BASE:-$(cd "$PROJECT_DIR/.." && pwd)/.gaai-worktrees/$(basename "$PROJECT_DIR")}"
fi

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true

# ANSI colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

format_duration() {
  local seconds="$1"
  if [[ $seconds -lt 60 ]]; then
    echo "${seconds}s"
  elif [[ $seconds -lt 3600 ]]; then
    echo "$(( seconds / 60 ))m$(( seconds % 60 ))s"
  else
    echo "$(( seconds / 3600 ))h$(( (seconds % 3600) / 60 ))m"
  fi
}

health_color() {
  local age_s="$1"
  if [[ $age_s -lt 30 ]]; then
    echo "$GREEN"
  elif [[ $age_s -lt 120 ]]; then
    echo "$YELLOW"
  else
    echo "$RED"
  fi
}

# Pass-through model id, filtering out sentinel values (n/a / null / empty)
# so callers can omit the field cleanly. Real model strings render as-is
# (claude-sonnet-4-6, glm-5.1, ...).
format_model() {
  case "$1" in
    n/a|null|"") echo "" ;;
    *)           echo "$1" ;;
  esac
}

PHASE_CACHE_DIR="${PROJECT_DIR}/.gaai/project/contexts/backlog/.delivery-locks/.phase-cache"

# Returns story IDs — one per line — for all currently active deliveries.
# For legacy pipeline: active tmux sessions named gaai-deliver-{id}.
# For 3phase pipeline: .lock files in LOCK_DIR where backlog status=in_progress.
detect_active_stories() {
  local seen=()

  # Legacy: tmux sessions
  local tmux_ids
  tmux_ids=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | grep '^gaai-deliver-' \
    | sed 's/gaai-deliver-//' || true)
  for _id in $tmux_ids; do
    local _dp
    _dp=$(awk -v id="$_id" '
      $0 == "- id: " id { found=1; next }
      found && /^- id:/ { exit }
      found && /^[[:space:]]+delivery_pipeline:/ {
        gsub(/^[[:space:]]+delivery_pipeline:[[:space:]]*/, "")
        gsub(/[[:space:]]*/, ""); print; exit
      }
    ' "$BACKLOG" 2>/dev/null || true)
    # Strip scheduler --set-field auto-quotes (e.g. delivery_pipeline: "3phase").
    _dp="${_dp//\"/}"
    # Only emit + dedup-track when this is a LEGACY pipeline tmux. For 3phase
    # tmux sessions (created by launch_3phase_in_tmux post Option A), we let
    # the active-marker block below handle them — adding them to seen here
    # would cause that block to skip its own stories.
    if [[ "$_dp" != "3phase" ]]; then
      echo "$_id"
      seen+=("$_id")
    fi
  done

  # 3phase: enumerate by backlog status, then require ANY liveness signal
  # (tmux session OR `.active` marker) before display. Backlog-status alone
  # over-emits zombie stories whose wrapper exited without flipping status.
  # Marker alone under-emits live deliveries during wrapper→nested-claude-spawn
  # hand-off when the marker write was skipped. The OR is the honest gate.
  local _live_tmux
  _live_tmux=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | grep '^gaai-deliver-' \
    | sed 's/gaai-deliver-//' || true)
  awk '
    function emit() {
      if (current_id != "" && status == "in_progress" && dp == "3phase") {
        print current_id
      }
    }
    /^- id:/ {
      emit()
      gsub(/^- id:[[:space:]]*/, ""); current_id=$0; status=""; dp=""; next
    }
    /^[[:space:]]+status:/ {
      v=$0; gsub(/^[[:space:]]+status:[[:space:]]*/, "", v); gsub(/[[:space:]"]*/, "", v); status=v; next
    }
    /^[[:space:]]+delivery_pipeline:/ {
      v=$0; gsub(/^[[:space:]]+delivery_pipeline:[[:space:]]*/, "", v); gsub(/[[:space:]"]*/, "", v); dp=v; next
    }
    END { emit() }
  ' "$BACKLOG" 2>/dev/null | while IFS= read -r _sid; do
    [[ -z "$_sid" ]] && continue
    # Skip if already emitted via legacy tmux path
    local _dup=0
    for _s in "${seen[@]:-}"; do [[ "$_s" == "$_sid" ]] && _dup=1 && break; done
    [[ $_dup -eq 1 ]] && continue
    # Liveness gate: require tmux session OR any .active marker
    local _has_tmux=0
    if printf '%s\n' "$_live_tmux" | grep -qx "$_sid"; then _has_tmux=1; fi
    local _has_marker=0
    for _ph in plan impl qa commit; do
      [[ -f "${LOCK_DIR}/${_sid}.${_ph}.active" ]] && _has_marker=1 && break
    done
    [[ $_has_tmux -eq 0 && $_has_marker -eq 0 ]] && continue
    echo "$_sid"
  done
}

# Returns the canonical log path for the current active phase of a 3phase story.
# AC2: per-phase log at {worktree}/.delivery-logs/{id}.{phase}.log
# Falls back to [no log yet] sentinel string when log does not exist.
resolve_3phase_log() {
  local story_id="$1"
  local worktree="${WORKTREE_BASE}/${story_id}-workspace"

  # Determine active phase from markers (AC1 priority order)
  local active_phase=""
  for _ph in plan impl qa commit; do
    if [[ -f "${LOCK_DIR}/${story_id}.${_ph}.active" ]]; then
      active_phase="$_ph"
      break
    fi
  done

  if [[ -z "$active_phase" ]]; then
    # No marker — infer the in-flight phase from phase_status. phase_status names
    # the LAST COMPLETED phase (planned = Plan done, Impl in flight ; implemented
    # = Impl done, QA in flight ; qa_passed = QA done, commit in flight). Without
    # this inference, a missing marker during Impl hand-off pointed the log
    # resolver at .plan.log and the display showed "IDLE @ planned" while the
    # nested-claude-spawn was busy writing to .impl.log.
    local ps
    ps=$(awk -v id="$story_id" '
      $0 == "- id: " id { found=1; next }
      found && /^- id:/ { exit }
      found && /^[[:space:]]+phase_status:/ {
        gsub(/^[[:space:]]+phase_status:[[:space:]]*/, "")
        gsub(/[[:space:]]*/, ""); print; exit
      }
    ' "$BACKLOG" 2>/dev/null || true)
    case "$ps" in
      not_started)            active_phase="plan"   ;;
      planned)                active_phase="impl"   ;;
      implemented)            active_phase="qa"     ;;
      qa_passed)              active_phase="commit" ;;
      done)                   active_phase="commit" ;;
      qa_failed|qa_escalated) active_phase="qa"     ;;
      failed|escalated)       active_phase="impl"   ;;
      "")                     echo "[?]"; return    ;;
      *)                      echo "[?]"; return    ;;
    esac
  fi

  local log_path="${worktree}/.delivery-logs/${story_id}.${active_phase}.log"
  if [[ -f "$log_path" ]]; then
    echo "$log_path"
  else
    echo "[no log yet]"
  fi
}

# Returns the display phase label for a 3phase story using authoritative markers.
# AC1: markers take priority over phase_status for in-progress display.
detect_phase_3phase() {
  local story_id="$1"

  # Active marker check (highest priority)
  for _ph in plan impl qa commit; do
    if [[ -f "${LOCK_DIR}/${story_id}.${_ph}.active" ]]; then
      case "$_ph" in
        plan)   echo "PLAN"   ;;
        impl)   echo "IMPL"   ;;
        qa)     echo "QA"     ;;
        commit) echo "COMMIT" ;;
      esac
      return
    fi
  done

  # No active marker: read phase_status for terminal / idle display
  local ps
  ps=$(awk -v id="$story_id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+phase_status:/ {
      gsub(/^[[:space:]]+phase_status:[[:space:]]*/, "")
      gsub(/[[:space:]]*/, ""); print; exit
    }
  ' "$BACKLOG" 2>/dev/null || true)

  # phase_status names the LAST COMPLETED phase — the IN-FLIGHT phase is the
  # next one. Without this, "phase_status: planned" rendered as "IDLE @ planned"
  # while the nested-claude-spawn was busy in Impl on the secondary route.
  case "$ps" in
    done)                   echo "DONE"              ;;
    failed|escalated)       echo "FAILED"            ;;
    qa_failed)              echo "QA_FAILED"         ;;
    qa_escalated)           echo "QA_ESCALATED"      ;;
    not_started)            echo "PLAN"              ;;
    planned)                echo "IMPL"              ;;
    implemented)            echo "QA"                ;;
    qa_passed)              echo "COMMIT"            ;;
    "")                     echo "[?]"               ;;
    *)                      echo "[?]"               ;;
  esac
}

parse_log() {
  local log_file="$1"
  local story_id="$2"
  local pipeline="${3:-legacy}"       # "3phase" or "legacy"
  local phase_override="${4:-}"       # pre-computed phase label (3phase only)

  if [[ ! -f "$log_file" ]]; then
    echo -e "  ${DIM}(log not yet created)${NC}"
    return
  fi

  local size
  size=$(wc -c < "$log_file" | tr -d ' ')
  if [[ "$size" -eq 0 ]]; then
    echo -e "  ${DIM}(waiting for output...)${NC}"
    return
  fi

  # ── Log age & health ──
  local mod_time now age_s age_label color
  if [[ "$(uname)" == "Darwin" ]]; then
    mod_time=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0)
  else
    mod_time=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
  fi
  now=$(date +%s)
  age_s=$(( now - mod_time ))
  age_label=$(format_duration $age_s)
  color=$(health_color $age_s)

  # ── Duration (time since delivery started) ──
  local started_at duration_label=""
  started_at=$(grep -A 15 "id: $story_id" "$BACKLOG" 2>/dev/null | grep 'started_at:' | head -1 | sed 's/.*started_at: *"//;s/".*//' || true)
  if [[ -n "$started_at" ]]; then
    local start_epoch
    if [[ "$(uname)" == "Darwin" ]]; then
      start_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || echo 0)
    else
      start_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo 0)
    fi
    if [[ "$start_epoch" -gt 0 ]]; then
      duration_label=$(format_duration $(( now - start_epoch )))
    fi
  fi

  # ── Tool call count ──
  # Claude stream-json uses assistant.message.content[].tool_use.
  # Codex exec --json uses item.started/item.completed with item.type=command_execution.
  local tool_count=0
  if $HAS_JQ; then
    local claude_tool_count codex_tool_count
    claude_tool_count=$(jq -Rrc 'fromjson? | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")' "$log_file" 2>/dev/null | wc -l | tr -d ' ')
    codex_tool_count=$(jq -Rrc 'fromjson? | select(.type=="item.started" and (.item.type=="command_execution"))' "$log_file" 2>/dev/null | wc -l | tr -d ' ')
    tool_count=$(( ${claude_tool_count:-0} + ${codex_tool_count:-0} ))
  else
    local claude_tool_count codex_tool_count
    claude_tool_count=$(grep -c '"type":"tool_use"' "$log_file" 2>/dev/null || true)
    codex_tool_count=$(grep -c '"type":"item.started".*"type":"command_execution"' "$log_file" 2>/dev/null || true)
    tool_count=$(( ${claude_tool_count:-0} + ${codex_tool_count:-0} ))
  fi

  # ── Last activity (single line — whichever of main or sub-agent was most recent) ──
  # Sub-agent origin = either (a) Task tool sub-agent: same session, parent_tool_use_id != null,
  # or (b) nested `claude -p` (Implement Agent via nested-claude-spawn.js --log-file):
  #         DIFFERENT session_id than the root delivery session.
  # Root session_id = first session_id seen in the log (init event).
  local last_event="" last_origin="" last_text="" last_model="" root_sid=""
  local phase_label="" phase_origin=""
  if $HAS_JQ; then
    root_sid=$(head -5 "$log_file" 2>/dev/null \
      | jq -r '.session_id // empty' 2>/dev/null \
      | head -1 || true)
    last_event=$(tail -500 "$log_file" 2>/dev/null \
      | jq -Rr --arg root_sid "$root_sid" '
        fromjson? |
        def clean: tostring | gsub("\n"; " ") | gsub("  +"; " ");
        def arg:
          if .name == "Bash" then (.input.command // "" | clean)
          elif .name == "Grep" then (.input.pattern // "" | clean)
          elif (.name == "Read" or .name == "Edit" or .name == "Write" or .name == "NotebookEdit") then ((.input.file_path // "" | clean) | split("/") | .[-1] // "")
          elif .name == "Task" then (.input.description // "" | clean)
          elif .name == "TodoWrite" then "(todos updated)"
          else ((.input.description // .input.file_path // .input.command // .input.query // "") | clean) end;
        . as $m |
        (if (($m.parent_tool_use_id // null) == null) and (($m.session_id // "") == $root_sid) then "MAIN" else "SUB" end) as $origin |
        (($m.message.model // "") | tostring) as $model |
        if ($m.type=="system" and $m.subtype=="task_progress") then
          $origin + "\t" + ($m.description // "") + "\t"
        elif $m.type=="assistant" then
          $m.message.content[]? | select(.type=="tool_use") | $origin + "\t" + .name + " " + arg + "\t" + $model
        else empty end' 2>/dev/null \
      | tail -1 || true)
    # Three tab-separated fields: origin <TAB> text <TAB> model
    last_origin=$(printf '%s' "$last_event" | awk -F'\t' '{print $1}')
    last_text=$(printf   '%s' "$last_event" | awk -F'\t' '{print $2}')
    last_model=$(printf  '%s' "$last_event" | awk -F'\t' '{print $3}')

    # Codex exec --json fallback: show the latest command_execution item when no
    # Claude-style tool_use event exists in this phase log.
    if [[ -z "$last_text" ]]; then
      local codex_event
      codex_event=$(tail -500 "$log_file" 2>/dev/null \
        | jq -Rr '
          fromjson? |
          def clean: tostring | gsub("\n"; " ") | gsub("  +"; " ");
          select((.type=="item.started" or .type=="item.completed") and (.item.type=="command_execution"))
          | "MAIN" + "\t" + (.item.command // "" | clean) + "\t" + "codex"
        ' 2>/dev/null \
        | tail -1 || true)
      last_origin=$(printf '%s' "$codex_event" | awk -F'\t' '{print $1}')
      last_text=$(printf   '%s' "$codex_event" | awk -F'\t' '{print $2}')
      last_model=$(printf  '%s' "$codex_event" | awk -F'\t' '{print $3}')
    fi

    # ── Daemon-log fallback for nested-spawn events ──
    # When the orchestrator passed `--log-file <daemon log>` to nested-claude-spawn
    # (observed empirically — orchestrator substitutes $GAAI_DELIVERY_LOG_FILE for
    # daemon log path), the GLM/secondary subprocess writes its stream-json events
    # to the daemon log instead of the per-story log. The per-story panel here
    # would display stale orchestrator model unless we also peek at the daemon log.
    # Rule per founder 2026-04-30 19:08 BEL : sub-agent / spawned model always wins
    # over orchestrator in the display.
    local daemon_log="$PROJECT_DIR/.gaai/project/contexts/backlog/.delivery-daemon.log"
    if [[ -f "$daemon_log" ]]; then
      local daemon_event
      daemon_event=$(tail -400 "$daemon_log" 2>/dev/null \
        | grep '^{"type":"assistant"' 2>/dev/null \
        | jq -Rr '
            fromjson? |
            def clean: tostring | gsub("\n"; " ") | gsub("  +"; " ");
            def arg:
              if .name == "Bash" then (.input.command // "" | clean)
              elif .name == "Grep" then (.input.pattern // "" | clean)
              elif (.name == "Read" or .name == "Edit" or .name == "Write") then ((.input.file_path // "" | clean) | split("/") | .[-1] // "")
              elif .name == "Task" then (.input.description // "" | clean)
              elif .name == "TodoWrite" then "(todos updated)"
              else ((.input.description // .input.file_path // .input.command // "") | clean) end;
            . as $m |
            (($m.message.model // "") | tostring) as $model |
            $m.message.content[]? | select(.type=="tool_use") | "SUB" + "\t" + .name + " " + arg + "\t" + $model
          ' 2>/dev/null | tail -1 || true)
      local daemon_model
      daemon_model=$(printf '%s' "$daemon_event" | awk -F'\t' '{print $3}')
      # Override main display when daemon log's most recent event is from a
      # different (non-orchestrator) model AND the daemon log was touched more
      # recently than the per-story log. Sub-agent / spawned model wins.
      if [[ -n "$daemon_model" ]] && [[ "$daemon_model" != "$last_model" ]]; then
        local daemon_mtime story_mtime
        if [[ "$(uname)" == "Darwin" ]]; then
          daemon_mtime=$(stat -c %Y "$daemon_log" 2>/dev/null || stat -f %m "$daemon_log" 2>/dev/null || echo 0)
          story_mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0)
        else
          daemon_mtime=$(stat -c %Y "$daemon_log" 2>/dev/null || echo 0)
          story_mtime=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
        fi
        if [[ "$daemon_mtime" -ge "$story_mtime" ]]; then
          last_origin="SUB"
          last_text=$(printf '%s' "$daemon_event" | awk -F'\t' '{print $2}')
          last_model="$daemon_model"
        fi
      fi
    fi

    # ── Phase detection ──
    if [[ "$pipeline" == "3phase" && -n "$phase_override" ]]; then
      # 3phase: use authoritative marker-derived label (AC1)
      phase_label="$phase_override"
      phase_origin=""
    else
    # Legacy pipeline: existing log-content heuristic (unchanged)
    # Walk recent events, classify each Bash command / Write target into a phase tag,
    # keep the LAST non-empty classification — that's the current phase.
    # Origin is captured from the same event so we can show e.g. "IMPL (sub)" when
    # the nested claude -p subprocess is the most recent actor.
    local phase_event
    phase_event=$(tail -1500 "$log_file" 2>/dev/null \
      | jq -Rr --arg root_sid "$root_sid" '
        fromjson? |
        def signal:
          if .name == "Bash" then (.input.command // "" | tostring)
          elif (.name == "Write" or .name == "Edit") then (.input.file_path // "" | tostring)
          else "" end;
        def classify($s):
          if   ($s | test("gh pr merge"))                          then "DONE"
          elif ($s | test("Mark Story done|chore.*: done"))        then "DONE"
          elif ($s | test("ci-watch-and-fix|gh pr checks|ci_watch")) then "CI"
          elif ($s | test("gh pr create"))                         then "PR"
          elif ($s | test("--phase qa"))                           then "QA→PR"
          elif ($s | test("qa-report\\.md"))                       then "QA"
          elif ($s | test("--phase impl"))                         then "IMPL→QA"
          # Match only actual node invocations of the nested wrapper, NOT mentions
          # in research / grep / cat / vim. False positive observed on E131S04
          # where the agent was studying the module file itself.
          # Post-E131S02: the module is always invoked for Tier 2 (routing is not
          # opt-in from the agent). IMPL(nested) fires while the subprocess runs.
          # After the module returns, the agent collects impl-report.md — the Read
          # event matches the pattern below (rank 4, same as IMPL(nested)) and
          # stable-sort tail-1 advances the display to IMPL regardless of provider
          # (primary opt-out and universal-fallback both resolve to IMPL this way).
          # The IMPL(nested) signal remains useful for the legacy-degenerate case:
          # if the wrapper crashes before agent spawn, IMPL(nested) is never seen
          # and the operator observes WORKING — a valid anomaly signal. (E131S06)
          elif ($s | test("node[^|]+nested-claude-spawn\\.js"))    then "IMPL(nested)"
          elif ($s | test("impl-report\\.md"))                     then "IMPL"
          elif ($s | test("--phase plan"))                         then "PLAN→IMPL"
          elif ($s | test("execution-plan\\.md"))                  then "PLAN"
          elif ($s | test("git worktree add|Mark in_progress|in_progress \\[delivery\\]|routing-logger.*preflight")) then "PREFLIGHT"
          # Catch-all for non-specific Bash commands / Write/Edit file_paths after
          # PREFLIGHT — visible signal that the agent is actively working even when
          # no phase-specific marker fires (typical for Tier 1 MicroDelivery, where
          # plan+impl+qa run in a single sub-agent and produce no execution-plan.md).
          # More-specific phases above (PLAN/IMPL/QA/PR/CI/DONE) still take priority.
          elif ($s | test(".+"))                                   then "WORKING"
          else "" end;
        . as $m |
        # Monotone state machine — every event emits its phase rank as the FIRST
        # column. We then sort by rank in bash and take the highest one observed
        # in the recent window. This prevents WORKING (rank 2) from overriding
        # PLAN/IMPL/QA (rank 3-5) when the agent does generic Bash/Edit between
        # the artefact-write events that mark phase transitions. PREFLIGHT (rank 1)
        # similarly cannot regress once a higher phase has been observed.
        def rank_of($p):
          if   $p == "DONE"                          then 8
          elif $p == "CI"                            then 7
          elif $p == "PR"                            then 6
          elif ($p | startswith("QA"))               then 5
          elif ($p | startswith("IMPL"))             then 4
          elif ($p | startswith("PLAN"))             then 3
          elif $p == "WORKING"                       then 2
          elif $p == "PREFLIGHT"                     then 1
          else 0 end;
        (if (($m.parent_tool_use_id // null) == null) and (($m.session_id // "") == $root_sid) then "main" else "sub" end) as $origin |
        if $m.type=="assistant" then
          $m.message.content[]? | select(.type=="tool_use")
            | classify(signal) as $p
            | select($p != "")
            | (rank_of($p) | tostring) + "\t" + $p + "\t" + $origin
        else empty end' 2>/dev/null \
      | sort -t$'\t' -k1n -s \
      | tail -1 || true)
    # Three tab-separated fields: rank <TAB> phase_label <TAB> origin
    phase_label=$(printf  '%s' "$phase_event" | awk -F'\t' '{print $2}')
    phase_origin=$(printf '%s' "$phase_event" | awk -F'\t' '{print $3}')
    [[ "$phase_label" == "$phase_origin" ]] && phase_origin=""

    # ── Phase cache: persist the highest rank seen so far across tail-window refreshes ──
    # Prevents regression when early-session phase markers (PLAN/IMPL writes) scroll past
    # the tail-1500 window in long-running stories. One file per story; invalidated when
    # the log file is newer than the cache (i.e., story was re-delivered and log recreated).
    local cache_file="${PHASE_CACHE_DIR}/${story_id}"
    mkdir -p "$PHASE_CACHE_DIR" 2>/dev/null || true
    local cached_rank=0 cached_label="" cached_origin=""
    if [[ -f "$cache_file" ]]; then
      # Cache stale when log was recreated after cache was written (new delivery run)
      local cache_mtime log_mtime
      if [[ "$(uname)" == "Darwin" ]]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0)
      else
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
      fi
      # Allow a 10s grace window so a cache written during a previous refresh
      # of the same log is not immediately discarded if timestamps are close.
      if [[ $(( log_mtime - cache_mtime )) -gt 10 ]] && [[ "$log_mtime" -gt "$cache_mtime" ]]; then
        rm -f "$cache_file" 2>/dev/null || true
      else
        local cached_event
        cached_event=$(cat "$cache_file" 2>/dev/null || true)
        cached_rank=$(printf '%s' "$cached_event" | awk -F'\t' '{print $1}')
        cached_label=$(printf '%s' "$cached_event" | awk -F'\t' '{print $2}')
        cached_origin=$(printf '%s' "$cached_event" | awk -F'\t' '{print $3}')
        cached_rank="${cached_rank:-0}"
      fi
    fi
    local cur_rank
    cur_rank=$(printf '%s' "$phase_event" | awk -F'\t' '{print $1}')
    cur_rank="${cur_rank:-0}"
    if [[ -n "$cached_label" ]] && [[ "$cached_rank" -gt "$cur_rank" ]]; then
      # Cache wins: a higher-rank phase was seen in an earlier tail window
      phase_label="$cached_label"
      phase_origin="$cached_origin"
    elif [[ -n "$phase_label" ]] && [[ "$cur_rank" -gt "$cached_rank" ]]; then
      # Current window advanced: write updated winner back to cache
      printf '%s\t%s\t%s\n' "$cur_rank" "$phase_label" "$phase_origin" > "$cache_file" 2>/dev/null || true
    fi
    fi  # close: if [[ 3phase ]] ... else (legacy heuristic) ... fi
  else
    last_text=$(tail -200 "$log_file" 2>/dev/null \
      | grep -o '"type":"tool_use"[^}]*"name":"[^"]*"' \
      | tail -1 \
      | sed 's/.*"name":"\([^"]*\)".*/\1/' 2>/dev/null || true)
    last_origin="MAIN"
  fi

  # ── Cost ──
  local cost=""
  if $HAS_JQ; then
    cost=$(tail -100 "$log_file" 2>/dev/null \
      | jq -Rr 'fromjson? | select(.costUSD) | .costUSD' 2>/dev/null \
      | tail -1 || true)
  fi

  # ── Output ──
  local health_icon
  if [[ $age_s -lt 30 ]]; then health_icon="●"
  elif [[ $age_s -lt 120 ]]; then health_icon="◐"
  else health_icon="○"
  fi

  # ── Phase + model resolution (used in combined header line below) ──
  # Phase tags ending in "→X" mean "phase X just completed, next phase starting".
  local phase_display="" phase_color="$YELLOW"
  if [[ -n "$phase_label" ]]; then
    case "$phase_label" in
      PREFLIGHT)    phase_display="Preflight" ; phase_color="$DIM"    ;;
      WORKING)      phase_display="Working"   ; phase_color="$YELLOW" ;;
      PLAN|PLAN→*)  phase_display="Plan"      ; phase_color="$YELLOW" ;;
      IMPL|IMPL→*|"IMPL(nested)") phase_display="Impl" ; phase_color="$YELLOW" ;;
      QA|QA→*)      phase_display="QA"        ; phase_color="$YELLOW" ;;
      PR)           phase_display="PR"        ; phase_color="$GREEN"  ;;
      CI)           phase_display="CI"        ; phase_color="$GREEN"  ;;
      DONE)         phase_display="Done"      ; phase_color="$GREEN"  ;;
      *)            phase_display="$phase_label" ;;
    esac
  fi
  # Append "(sub)" when the most-recent phase signal came from a sub-agent /
  # nested claude session — main is the implicit default and would just add noise.
  local origin_suffix=""
  [[ "$phase_origin" == "sub" ]] && origin_suffix=" (sub)"
  # Resolve model from the most recent tool_use event (the provider doing the
  # work right now : claude-sonnet-4-6, glm-5.1, claude-haiku-4-5, …). SUB origin
  # = Task tool sub-agent (typically Haiku) or nested-claude-spawn subprocess —
  # annotate explicitly so a smaller/different model flashing by isn't surprising.
  local model_label model_suffix=""
  model_label=$(format_model "$last_model")
  if [[ -n "$model_label" ]]; then
    if [[ "$last_origin" == "SUB" ]]; then
      model_suffix=" | Model: ${model_label} (sub)"
    else
      model_suffix=" | Model: ${model_label}"
    fi
  fi

  # ── Resolve story title from backlog YAML (single canonical source) ──
  # Adds operator context : "what is this story about ?" without lookup.
  local story_title
  story_title=$(awk -v id="$story_id" '
    $0 == "- id: " id { found=1; next }
    found && /^- id:/ { exit }
    found && /^[[:space:]]+title:/ {
      gsub(/^[[:space:]]+title:[[:space:]]*"?/, "")
      gsub(/"[[:space:]]*$/, "")
      gsub(/[[:space:]]*$/, "")
      print
      exit
    }
  ' "$BACKLOG" 2>/dev/null || true)

  # ── Story header line : "{id} — {title}" ──
  if [[ -n "$story_title" ]]; then
    printf '%b%s%b — %s\n' "$CYAN" "$story_id" "$NC" "$story_title"
  else
    printf '%b%s%b\n' "$CYAN" "$story_id" "$NC"
  fi

  # ── Phase + model line ──
  # "Model:" label rendered in default terminal color (no DIM dimming) —
  # keeps the data line as a peer to "Phase:" instead of subdued.
  if [[ -n "$phase_display" ]]; then
    printf '  Phase: %b%s%b%s%s\n' \
      "$phase_color" "$phase_display" "$NC" "$origin_suffix" \
      "$model_suffix"
  elif [[ -n "$model_suffix" ]]; then
    # Legacy pipeline (no phase label) : just model line (if known).
    printf '  %s\n' "${model_suffix# | }"
  fi

  # ── Stats line ──
  echo -e "  ${color}${health_icon}${NC} ${tool_count} tools | Last-update: ${color}${age_label} ago${NC}${duration_label:+ | Running: ${duration_label}}${cost:+ | \$${cost}}"

  # Single activity line — prefix switches based on origin (main delivery vs nested sub-agent).
  # printf %s keeps literal "\n" in Bash commands literal (echo -e would interpret them).
  # Cap at ~280 chars: typical multi-flag commands fit, but pathological heredocs
  # (cat <<EOF with multi-paragraph payload) no longer flood the monitor and push
  # other active stories off-screen. Truncation indicator is "…" suffix.
  if [[ -n "$last_text" ]]; then
    local activity_max=280
    if [[ ${#last_text} -gt $activity_max ]]; then
      last_text="${last_text:0:$activity_max}…"
    fi
    if [[ "$last_origin" == "SUB" ]]; then
      printf '  %b↳ %s%b\n' "$DIM" "$last_text" "$NC"
    else
      printf '  %b→ %s%b\n' "$DIM" "$last_text" "$NC"
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
while true; do
  clear
  # In tmux: clear scrollback left by `clear` so prior refresh doesn't ghost below
  [[ -n "${TMUX:-}" ]] && tmux clear-history 2>/dev/null || true
  echo "═══ Active Deliveries (refreshes every 5s) ═══"
  echo ""

  # Read active stories (3phase from locks + legacy from tmux)
  active_ids=()
  while IFS= read -r _id; do
    [[ -n "$_id" ]] && active_ids+=("$_id")
  done < <(detect_active_stories)

  if [[ ${#active_ids[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No active deliveries. Use /gaai-discover to create stories for the backlog.${NC}"
    sleep 5
    continue
  fi

  for story_id in "${active_ids[@]}"; do
    # Determine pipeline
    pipeline=$(awk -v id="$story_id" '
      $0 == "- id: " id { found=1; next }
      found && /^- id:/ { exit }
      found && /^[[:space:]]+delivery_pipeline:/ {
        gsub(/^[[:space:]]+delivery_pipeline:[[:space:]]*/, "")
        gsub(/[[:space:]]*/, ""); print; exit
      }
    ' "$BACKLOG" 2>/dev/null || true)

    if [[ "$pipeline" == "3phase" ]]; then
      # AC1: marker-based phase detection
      phase_label=$(detect_phase_3phase "$story_id")
      # AC2: per-phase log path resolution
      log_path=$(resolve_3phase_log "$story_id")
      if [[ "$log_path" == "[no log yet]" || "$log_path" == "[?]" ]]; then
        # No log yet — render minimal header (parse_log won't run on missing file)
        # Note: NOT inside a function here (we're in main script body) — no `local` keyword
        _title=$(awk -v id="$story_id" '
          $0 == "- id: " id { found=1; next }
          found && /^- id:/ { exit }
          found && /^[[:space:]]+title:/ {
            gsub(/^[[:space:]]+title:[[:space:]]*"?/, "")
            gsub(/"[[:space:]]*$/, "")
            gsub(/[[:space:]]*$/, "")
            print; exit
          }
        ' "$BACKLOG" 2>/dev/null || true)
        if [[ -n "$_title" ]]; then
          printf '%b%s%b — %s\n' "$CYAN" "$story_id" "$NC" "$_title"
        else
          printf '%b%s%b\n' "$CYAN" "$story_id" "$NC"
        fi
        printf '  Phase: %b%s%b\n' "$YELLOW" "$phase_label" "$NC"
        echo -e "  ${DIM}${log_path}${NC}"
        echo ""
        continue
      fi
      parse_log "$log_path" "$story_id" "3phase" "$phase_label"
    else
      # Legacy: unchanged path
      log_path="$LOG_DIR/${story_id}.log"
      parse_log "$log_path" "$story_id" "legacy" ""
    fi
    echo ""
  done

  sleep 5
done
fi
