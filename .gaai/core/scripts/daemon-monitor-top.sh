#!/usr/bin/env bash
# Monitor top pane: fixed banner (always visible) + scrolling daemon logs below

CONFIG_FILE="${1:-.gaai/project/contexts/backlog/.delivery-locks/.daemon-config}"
LOG_FILE="${2:-.gaai/project/contexts/backlog/.delivery-daemon.log}"

PROJECT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

# Read-only lifecycle observer (never daemon authority or evidence). Sourcing
# this file only defines functions — it is safe even though this script's own
# render loop below runs at source time with no BASH_SOURCE guard. A partial
# or absent install renders a fail-closed DAEMON AMBIGUOUS line rather than a
# broken pane.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/daemon-monitor-lifecycle.sh" 2>/dev/null || true
_gaai_mon_lifecycle_init "$PROJECT_DIR" 2>/dev/null || true

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true
LOCK_DIR="${PROJECT_DIR}/.gaai/project/contexts/backlog/.delivery-locks"
BACKLOG="${PROJECT_DIR}/.gaai/project/contexts/backlog/active.backlog.yaml"
ROUTING_LOG="${PROJECT_DIR}/.gaai/project/contexts/logs/runtime-routing.jsonl"

# Colors
CYAN='\033[0;36m'
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

render_banner() {
  _gaai_mon_lifecycle_refresh 2>/dev/null || true
  _gaai_mon_config_attribution "$CONFIG_FILE" 2>/dev/null || true

  case "${_GAAI_MON_BANNER:-}" in
    "DAEMON RUNNING")
      echo -e "  ${GREEN}${BOLD}DAEMON RUNNING${NC}  daemon pid ${_GAAI_MON_DAEMON_PID}  attempt ${_GAAI_MON_ATTEMPT}"
      ;;
    "DAEMON STARTING")
      echo -e "  ${YELLOW}${BOLD}DAEMON STARTING${NC}  attempt ${_GAAI_MON_ATTEMPT}"
      ;;
    "DAEMON STOPPED")
      echo -e "  ${DIM}${BOLD}DAEMON STOPPED${NC}"
      ;;
    *)
      echo -e "  ${YELLOW}${BOLD}DAEMON AMBIGUOUS${NC}  process_authority_invalid  operator_disposition_required"
      ;;
  esac
  echo ""

  # The ten names are unset unconditionally on every frame — this pane is a
  # long-running loop, and a value sourced while the file was current must not
  # persist into a later frame after that lifecycle ended (the defect AC1
  # closes). Only a `current`-attributed file is then sourced.
  unset BRANCH MODEL INTERVAL LAUNCHER CONCURRENT SKIP_PERMS MAX_TURNS HEARTBEAT TIMEOUT DRY_RUN
  case "${_GAAI_MON_CONFIG_ATTR:-}" in
    current)    echo -e "  ${DIM}Config: current attempt${NC}" ;;
    historical) echo -e "  ${DIM}Config: previous lifecycle's file (not current)${NC}" ;;
    pending)    echo -e "  ${DIM}Config: pending for this attempt${NC}" ;;
    *)          echo -e "  ${DIM}Config: none on disk${NC}" ;;
  esac
  [[ "${_GAAI_MON_CONFIG_ATTR:-}" == "current" ]] && source "$CONFIG_FILE" 2>/dev/null
  echo ""

  # 2-column banner (28 │ 29 = 58 inner width)
  local W=58

  banner_row() {
    local l1="$1" v1="$2" l2="$3" v2="$4"
    local left_pad=$(( 14 - ${#v1} ))
    local right_pad=$(( 15 - ${#v2} ))
    [[ $left_pad -lt 0 ]] && left_pad=0
    [[ $right_pad -lt 0 ]] && right_pad=0
    local lsp rsp
    printf -v lsp '%*s' "$left_pad" ''
    printf -v rsp '%*s' "$right_pad" ''
    echo -e "  ║${NC}${CYAN}  $(printf '%-12s' "$l1")${BOLD}${v1}${NC}${CYAN}${lsp}│  $(printf '%-12s' "$l2")${BOLD}${v2}${NC}${CYAN}${rsp}║"
  }

  echo -e "${CYAN}${BOLD}"
  echo "  ╔$(printf '═%.0s' $(seq 1 $W))╗"
  local TITLE="GAAI Delivery Daemon"
  local TITLE_LEN=${#TITLE}
  printf "  ║%*s%s%*s║\n" $(( (W - TITLE_LEN) / 2 )) "" "$TITLE" $(( (W - TITLE_LEN + 1) / 2 )) ""
  echo "  ╠$(printf '═%.0s' $(seq 1 $W))╣"
  banner_row "Branch:"      "${BRANCH:-?}"      "Model:"       "${MODEL:-?}"
  banner_row "Interval:"    "${INTERVAL:-?}s"   "Launcher:"    "${LAUNCHER:-?}"
  banner_row "Concurrent:"  "${CONCURRENT:-?}"  "Skip perms:"  "${SKIP_PERMS:-?}"
  banner_row "Max turns:"   "${MAX_TURNS:-?}"   "Heartbeat:"   "${HEARTBEAT:-?}s"
  banner_row "Timeout:"     "${TIMEOUT:-?}s"    "Dry run:"     "${DRY_RUN:-?}"
  echo -e "  ${BOLD}╚$(printf '═%.0s' $(seq 1 $W))╝${NC}"
  echo ""
}

render_phase_metrics() {
  # Bail gracefully if routing log absent (AC5)
  if [[ ! -f "$ROUTING_LOG" ]]; then
    echo -e "  ${DIM}(no routing log yet)${NC}"
    return
  fi

  # Bounded read — never full scan (AC3)
  local raw
  raw=$(tail -n 500 "$ROUTING_LOG" 2>/dev/null || true)
  [[ -z "$raw" ]] && return

  # Extract in_progress story IDs from backlog
  local in_progress_ids
  in_progress_ids=$(awk '
    /^[[:space:]]+status:[[:space:]]*"?in_progress"?/ { if (current_id != "") print current_id }
    /^- id:/ { gsub(/^- id:[[:space:]]*/, ""); current_id=$0 }
  ' "$BACKLOG" 2>/dev/null || true)

  [[ -z "$in_progress_ids" ]] && return

  echo -e "${BOLD}Per-phase metrics (in_progress):${NC}"

  while IFS= read -r story_id; do
    [[ -z "$story_id" ]] && continue

    local plan_dur plan_ok impl_dur impl_model impl_ok qa_dur qa_ok
    plan_dur="" plan_ok="" impl_dur="" impl_model="" impl_ok="" qa_dur="" qa_ok=""

    while IFS= read -r rec; do
      local phase prov dur model
      if $HAS_JQ; then
        phase=$(printf '%s' "$rec" | jq -r '.phase // empty' 2>/dev/null || true)
        prov=$(printf '%s'  "$rec" | jq -r '.provider // empty' 2>/dev/null || true)
        dur=$(printf '%s'   "$rec" | jq -r '.duration_ms // 0' 2>/dev/null || true)
        model=$(printf '%s' "$rec" | jq -r '.model // empty' 2>/dev/null || true)
      else
        phase=$(printf '%s' "$rec" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('phase',''))" 2>/dev/null || true)
        prov=$(printf '%s'  "$rec" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('provider',''))" 2>/dev/null || true)
        dur=$(printf '%s'   "$rec" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('duration_ms',0))" 2>/dev/null || true)
        model=$(printf '%s' "$rec" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('model',''))" 2>/dev/null || true)
      fi

      local dur_s=""
      if [[ "$dur" =~ ^[0-9]+$ ]] && [[ "$dur" -gt 0 ]]; then
        dur_s=$(LC_ALL=C awk "BEGIN { printf \"%.1f\", $dur/1000 }")
      fi

      case "$phase" in
        plan)
          plan_dur="${dur_s:-?}"
          [[ "$prov" == "primary" ]] && plan_ok="✓" || plan_ok="✗"
          ;;
        impl)
          impl_dur="${dur_s:-?}"
          impl_model="${model:-?}"
          [[ "$prov" == "primary" || "$prov" == "secondary" ]] && impl_ok="✓" || impl_ok="✗"
          ;;
        qa)
          qa_dur="${dur_s:-?}"
          [[ "$prov" == "primary" ]] && qa_ok="✓" || qa_ok="✗"
          ;;
      esac
    done < <(printf '%s\n' "$raw" | grep "\"story_id\":\"${story_id}\"" 2>/dev/null || true)

    # Check for in-progress phase (running duration from active marker mtime).
    # A marker's presence is not, on its own, evidence that the daemon is
    # still running it — under any banner other than DAEMON RUNNING this
    # function is dormant in the render loop, but stays fail-closed here too
    # if it is ever called directly.
    local running_phase="" running_dur=""
    if [[ "${_GAAI_MON_BANNER:-}" == "DAEMON RUNNING" ]]; then
    for _ph in plan impl qa commit; do
      if [[ -f "${LOCK_DIR}/${story_id}.${_ph}.active" ]]; then
        running_phase="$_ph"
        if [[ "$(uname)" == "Darwin" ]]; then
          _mtime=$(stat -c %Y "${LOCK_DIR}/${story_id}.${_ph}.active" 2>/dev/null || stat -f %m "${LOCK_DIR}/${story_id}.${_ph}.active" 2>/dev/null || echo 0)
        else
          _mtime=$(stat -c %Y "${LOCK_DIR}/${story_id}.${_ph}.active" 2>/dev/null || echo 0)
        fi
        local _now
        _now=$(date +%s)
        running_dur=$(LC_ALL=C awk "BEGIN { printf \"%.1f\", $((_now - _mtime)) }")
        break
      fi
    done
    fi

    # When a phase is currently running, "running" takes priority over any
    # historical routing record (which may be stale from a prior failed attempt
    # — e.g., yesterday's PLAN_PHASE_FAILED leaves provider=error in routing.jsonl
    # while today's fresh attempt is in flight). Render running first, completed
    # second.
    local parts=()
    if [[ "$running_phase" == "plan" ]]; then
      parts+=("PLAN ${running_dur}s…")
    elif [[ -n "$plan_dur" ]]; then
      parts+=("PLAN ${plan_dur}s ${plan_ok}")
    fi
    if [[ "$running_phase" == "impl" ]]; then
      parts+=("IMPL ${running_dur}s…")
    elif [[ -n "$impl_dur" ]]; then
      local impl_part="IMPL ${impl_dur}s"
      [[ -n "$impl_model" && "$impl_model" != "?" ]] && impl_part="${impl_part} ${impl_model}"
      impl_part="${impl_part} ${impl_ok}"
      parts+=("$impl_part")
    fi
    if [[ "$running_phase" == "qa" ]]; then
      parts+=("QA ${running_dur}s…")
    elif [[ -n "$qa_dur" ]]; then
      parts+=("QA ${qa_dur}s ${qa_ok}")
    fi
    if [[ "$running_phase" == "commit" ]]; then
      parts+=("COMMIT ${running_dur}s…")
    fi

    local metric_line
    if [[ ${#parts[@]} -gt 0 ]]; then
      metric_line=$(printf ' | %s' "${parts[@]}")
      metric_line="${metric_line:3}"  # strip leading ' | '
      echo -e "  ${CYAN}${story_id}${NC} ${DIM}[${metric_line}]${NC}"
    else
      echo -e "  ${CYAN}${story_id}${NC} ${DIM}[no phase records yet]${NC}"
    fi

  done <<< "$in_progress_ids"
  echo ""
}

_bound_attempt=""
while true; do
  clear
  render_banner

  # AC4: drift detection banner — shown while .drift-detected.audit marker exists
  if [[ -f "$LOCK_DIR/.drift-detected.audit" ]]; then
    echo -e "  ${YELLOW}⚠ working-tree drift detected (recovery/commits paused) — commit or stash your edits${NC}"
    echo ""
  fi

  # rebase-conflict banner — shown while .rebase-conflict.audit marker exists
  if [[ -f "$LOCK_DIR/.rebase-conflict.audit" ]]; then
    echo -e "  ${YELLOW}⚠ rebase conflict detected (push-race recovery failed) — manual operator intervention required${NC}"
    echo ""
  fi

  # PR watcher status line (variables scoped to while-loop iteration, no `local` needed at top level)
  # The status word follows the lifecycle banner: `active` is a liveness claim
  # and must never be shown for a daemon that is not DAEMON RUNNING.
  case "${_GAAI_MON_BANNER:-}" in
    "DAEMON RUNNING")  pr_watcher_status="active" ;;
    "DAEMON STOPPED")  pr_watcher_status="stopped" ;;
    "DAEMON STARTING") pr_watcher_status="starting" ;;
    *)                 pr_watcher_status="unverified" ;;
  esac
  pr_watcher_last="?"
  pr_watcher_tracked=0
  if [[ "${GAAI_PR_WATCHER_DISABLED:-}" == "1" ]]; then
    pr_watcher_status="disabled"
  elif [[ -f "$LOCK_DIR/.pr-watcher.gh-warning-emitted" ]]; then
    pr_watcher_status="no gh"
  fi
  if [[ -f "$LOCK_DIR/.pr-watcher.last-poll" ]]; then
    last_poll=$(cat "$LOCK_DIR/.pr-watcher.last-poll" 2>/dev/null || echo 0)
    _now=$(date +%s)
    pr_watcher_last="$(( _now - last_poll ))s ago"
  fi
  if [[ -f "$BACKLOG" ]]; then
    pr_watcher_tracked=$(awk '
      /^- id:/ { if (has_pr && !pr_merged && is_active) count++; has_pr=0; pr_merged=0; is_active=0 }
      /^[[:space:]]+pr_url:/ { has_pr=1 }
      /^[[:space:]]+pr_status:[[:space:]]*"?merged"?/ { pr_merged=1 }
      /^[[:space:]]+status:[[:space:]]*"?(in_progress|escalated|blocked|refined)"?/ { is_active=1 }
      END { if (has_pr && !pr_merged && is_active) count++; print count+0 }
    ' "$BACKLOG" 2>/dev/null || echo 0)
  fi
  echo -e "  ${CYAN}🔄 PR watcher : ${BOLD}${pr_watcher_tracked}${NC}${CYAN} stories tracked, last poll ${pr_watcher_last} [${pr_watcher_status}]${NC}"
  echo ""

  if [[ -f "$LOG_FILE" ]]; then
    # Calculate available lines for logs (banner takes ~11 lines)
    term_lines=$(tput lines 2>/dev/null || echo 24)
    log_lines=$(( term_lines - 12 ))
    [[ $log_lines -lt 5 ]] && log_lines=5
    if [[ "${_GAAI_MON_BANNER:-}" == "DAEMON RUNNING" ]]; then
      echo -e "  ${DIM}Log: live daemon output${NC}"
    else
      echo -e "  ${DIM}Log: last lifecycle's output (not live)${NC}"
    fi
    # Filter raw NDJSON lines that nested-claude-spawn writes via --log-file when
    # orchestrators pass the daemon log path (instead of per-story). Keeps the top
    # banner human-readable without changing the underlying log pollution.
    tail -n $(( log_lines * 4 )) "$LOG_FILE" | grep -v '^{' | tail -n "$log_lines"
  else
    echo -e "  ${DIM}(waiting for daemon log...)${NC}"
  fi

  # Self-termination: mirrors the tail pane's own state machine (duplicated,
  # not shared, per the Story's File Inventory — the observer is consumed,
  # not changed, here). Bind to the attempt while live or starting; once a
  # bound attempt's daemon settles, this frame has already rendered
  # DAEMON STOPPED above, so end the loop. DAEMON AMBIGUOUS never terminates.
  case "${_GAAI_MON_BANNER:-}" in
    "DAEMON RUNNING"|"DAEMON STARTING") _bound_attempt="${_GAAI_MON_ATTEMPT:-unknown}" ;;
    "DAEMON STOPPED") [[ -n "${_bound_attempt:-}" ]] && exit 0 ;;
  esac

  sleep 2
done
