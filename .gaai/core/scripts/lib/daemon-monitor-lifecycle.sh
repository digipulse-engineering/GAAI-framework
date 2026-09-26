#!/usr/bin/env bash
# lib/daemon-monitor-lifecycle.sh — read-only, presentation-side lifecycle
# observer sourced by the daemon's monitor panes.
#
# This is never daemon authority or evidence: it creates, mutates, signals and
# repairs nothing, and never invokes the privileged daemon entry or sources
# daemon-start.sh. It mirrors that entry's liveness prover conjunct for
# conjunct, in the same order, using the same portable identity helpers
# (lib/daemon-home.sh) so socket, label and incarnation can never diverge from
# the authority's own. Every outcome the authority does not explicitly reach —
# including any read failure — resolves to `ambiguous`, never to a liveness
# claim.
#
# Idempotency guard: safe to source multiple times.

[[ -n "${_GAAI_MON_LIFECYCLE_SH_SOURCED:-}" ]] && return 0
_GAAI_MON_LIFECYCLE_SH_SOURCED=1

# shellcheck source=daemon-home.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/daemon-home.sh"

_GAAI_MON_OWNER_FILE=""
_GAAI_MON_SOCKET=""
_GAAI_MON_SESSION=""
_GAAI_MON_INITIALIZED=0

_GAAI_MON_STATE=""
_GAAI_MON_VERDICT=""
_GAAI_MON_BANNER=""
_GAAI_MON_ATTEMPT=""
_GAAI_MON_DAEMON_PID=""
_GAAI_MON_ATTEMPT_DIR=""
_GAAI_MON_HOME=""

_GAAI_MON_CONFIG_ATTR=""

# _gaai_mon_field <file> <key> — same shape as the authority's own field
# reader; a missing or unreadable file yields nothing, never a guess.
_gaai_mon_field() {
  local _file="$1" _key="$2"
  [[ -r "$_file" ]] || return 1
  sed -n "s/^${_key}=//p" "$_file" 2>/dev/null | head -1
}

# _gaai_mon_mtime <path> — portable GNU/BSD mtime in epoch seconds. Empty
# output means unavailable evidence, never "old" or "new".
_gaai_mon_mtime() {
  local _path="$1"
  stat -c %Y "$_path" 2>/dev/null || stat -f %m "$_path" 2>/dev/null || printf ''
}

# _gaai_mon_lifecycle_init <repo_root> — resolve the identity a pane needs
# once. A pane still renders when this fails; every subsequent refresh then
# yields `ambiguous` because the socket/session stay empty.
_gaai_mon_lifecycle_init() {
  local _repo_root="$1" _common
  _common="$(_gaai_home_common_dir "$_repo_root" 2>/dev/null)" || return 1
  [[ -n "$_common" ]] || return 1
  _GAAI_MON_OWNER_FILE="$_common/gaai-daemon-lifecycle/owner"
  _GAAI_MON_SOCKET="$(_gaai_home_socket_path "$_common" 2>/dev/null)" || return 1
  local _label
  _label="$(_gaai_home_label "$_common" 2>/dev/null)" || return 1
  _GAAI_MON_SESSION="gaai-daemon-$_label"
  [[ -n "$_GAAI_MON_SOCKET" && -n "$_GAAI_MON_SESSION" ]] || return 1
  _GAAI_MON_INITIALIZED=1
  return 0
}

# _gaai_mon_tmux <args...> — the observer's own private-socket query. Called
# ONLY after the `-S` existence test on that exact socket has already
# succeeded, exactly as the authority does, so no probe can bring a server
# into existence.
_gaai_mon_tmux() { tmux -f /dev/null -S "$_GAAI_MON_SOCKET" "$@" 2>/dev/null; }

# _gaai_mon_state — the `_owner_state` mirror: unreadable record -> none;
# wrong schema or unknown state word -> corrupt; else the recorded word.
_gaai_mon_state() {
  local _schema _state
  [[ -r "$_GAAI_MON_OWNER_FILE" ]] || { printf 'none'; return 0; }
  _schema="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" schema)"
  _state="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" state)"
  if [[ "$_schema" != "$GAAI_HOME_SCHEMA" ]]; then printf 'corrupt'; return 0; fi
  case "$_state" in
    pending|bound|running) printf '%s' "$_state" ;;
    *) printf 'corrupt' ;;
  esac
}

# _gaai_mon_verdict — the `_owner_verdict` mirror, conjunct for conjunct, in
# the authority's own order. Emits `live` only on the full conjunction and
# `settled` only under the authority's exact conditions; everything else,
# including every read failure, is `ambiguous`.
_gaai_mon_verdict() {
  local _state _sock _sess _srv_pid _srv_inc _now_inc _sessions
  local _seen_ours=0 _extra=0 _line _pane_pid _pane_inc _now_pane

  [[ "$_GAAI_MON_INITIALIZED" -eq 1 ]] || { printf 'ambiguous'; return 0; }

  _state="$(_gaai_mon_state)"
  case "$_state" in
    none)    printf 'settled'; return 0 ;;
    corrupt) printf 'ambiguous'; return 0 ;;
  esac

  _sock="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" socket)"
  _sess="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" session)"
  [[ "$_sock" == "$_GAAI_MON_SOCKET" && "$_sess" == "$_GAAI_MON_SESSION" ]] || { printf 'ambiguous'; return 0; }

  if [[ ! -S "$_sock" ]]; then
    [[ "$_state" == "pending" ]] && { printf 'settled'; return 0; }
    printf 'ambiguous'; return 0
  fi

  _srv_pid="$(_gaai_mon_tmux display-message -p '#{pid}')"
  [[ -n "$_srv_pid" ]] || { printf 'ambiguous'; return 0; }
  _srv_inc="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" server_incarnation)"
  if [[ -n "$_srv_inc" ]]; then
    _now_inc="$(_gaai_home_incarnation "$_srv_pid" 2>/dev/null || echo "")"
    [[ -n "$_now_inc" && "$_now_inc" == "$_srv_inc" ]] || { printf 'ambiguous'; return 0; }
  fi

  _sessions="$(_gaai_mon_tmux list-sessions -F '#{session_name}')"
  if [[ -z "$_sessions" ]]; then
    local _ee _re
    _ee="$(_gaai_mon_tmux show-options -g -v exit-empty)"
    _re="$(_gaai_mon_tmux show-options -g -v remain-on-exit)"
    [[ "$_ee" == "off" && "$_re" == "on" ]] || { printf 'ambiguous'; return 0; }
    printf 'settled'; return 0
  fi

  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    if [[ "$_line" == "$_sess" ]]; then _seen_ours=1; else _extra=1; fi
  done <<< "$_sessions"
  [[ "$_seen_ours" -eq 1 && "$_extra" -eq 0 ]] || { printf 'ambiguous'; return 0; }

  _pane_pid="$(_gaai_mon_tmux list-panes -t "=$_sess" -F '#{pane_pid}' | head -1)"
  [[ -n "$_pane_pid" ]] || { printf 'ambiguous'; return 0; }
  kill -0 "$_pane_pid" 2>/dev/null || { printf 'ambiguous'; return 0; }
  _pane_inc="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" pane_incarnation)"
  if [[ -n "$_pane_inc" ]]; then
    _now_pane="$(_gaai_home_incarnation "$_pane_pid" 2>/dev/null || echo "")"
    [[ -n "$_now_pane" && "$_now_pane" == "$_pane_inc" ]] || { printf 'ambiguous'; return 0; }
  fi

  printf 'live'
}

# _gaai_mon_lifecycle_refresh — per-frame read. Sets state/verdict/banner plus
# the fields the banner needs. An uninitialized observer still resolves
# through `_gaai_mon_verdict`'s own ambiguous/settled/none branches.
_gaai_mon_lifecycle_refresh() {
  _GAAI_MON_STATE="$(_gaai_mon_state)"
  _GAAI_MON_VERDICT="$(_gaai_mon_verdict)"
  case "$_GAAI_MON_VERDICT" in
    live)
      case "$_GAAI_MON_STATE" in
        running)      _GAAI_MON_BANNER="DAEMON RUNNING" ;;
        pending|bound) _GAAI_MON_BANNER="DAEMON STARTING" ;;
        *)            _GAAI_MON_BANNER="DAEMON AMBIGUOUS" ;;
      esac
      ;;
    settled)   _GAAI_MON_BANNER="DAEMON STOPPED" ;;
    *)         _GAAI_MON_BANNER="DAEMON AMBIGUOUS" ;;
  esac
  if [[ "$_GAAI_MON_STATE" != "none" && "$_GAAI_MON_STATE" != "corrupt" && -r "$_GAAI_MON_OWNER_FILE" ]]; then
    _GAAI_MON_ATTEMPT="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" attempt)"
    _GAAI_MON_DAEMON_PID="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" child_pid)"
    _GAAI_MON_ATTEMPT_DIR="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" attempt_dir)"
    _GAAI_MON_HOME="$(_gaai_mon_field "$_GAAI_MON_OWNER_FILE" home)"
  else
    _GAAI_MON_ATTEMPT="" _GAAI_MON_DAEMON_PID="" _GAAI_MON_ATTEMPT_DIR="" _GAAI_MON_HOME=""
  fi
}

# _gaai_mon_config_attribution <config_path> — deterministic, from evidence a
# pane can read, with no change to the config file's writer. `current` only
# under `live`+`running` with a readable, not-older `ack.ready`; every other
# readable case is `historical`; an absent file is `pending` while `live`, or
# `absent` otherwise.
_gaai_mon_config_attribution() {
  local _config="$1" _ready _cmtime _rmtime
  if [[ -r "$_config" ]]; then
    if [[ "$_GAAI_MON_VERDICT" == "live" && "$_GAAI_MON_STATE" == "running" && -n "$_GAAI_MON_ATTEMPT_DIR" ]]; then
      _ready="$_GAAI_MON_ATTEMPT_DIR/ack.ready"
      if [[ -r "$_ready" ]]; then
        _cmtime="$(_gaai_mon_mtime "$_config")"
        _rmtime="$(_gaai_mon_mtime "$_ready")"
        if [[ -n "$_cmtime" && -n "$_rmtime" && "$_cmtime" -ge "$_rmtime" ]]; then
          _GAAI_MON_CONFIG_ATTR="current"
          return 0
        fi
      fi
    fi
    _GAAI_MON_CONFIG_ATTR="historical"
  else
    if [[ "$_GAAI_MON_VERDICT" == "live" ]]; then
      _GAAI_MON_CONFIG_ATTR="pending"
    else
      _GAAI_MON_CONFIG_ATTR="absent"
    fi
  fi
}
