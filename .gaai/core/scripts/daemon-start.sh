#!/bin/bash -p
# ═══════════════════════════════════════════════════════════════════════════
# GAAI Daemon Launcher — privileged, verify-only start/stop/status entry
# ═══════════════════════════════════════════════════════════════════════════
#
# Description:
#   The sole runtime lifecycle entry for the standalone GAAI delivery daemon.
#   It is VERIFY-ONLY with respect to the daemon home worktree: it proves one
#   clean, registered, exact-current home and one exact-target executable before
#   any launch effect, and it never creates, moves, removes, prunes, resets,
#   cleans or repairs that home. Provisioning belongs to `daemon-setup.sh` alone.
#
# Usage (direct privileged entry — this file is executable):
#   .gaai/core/scripts/daemon-start.sh [options]     Start the daemon
#   .gaai/core/scripts/daemon-start.sh --stop        Graceful shutdown (drains wrappers)
#   .gaai/core/scripts/daemon-start.sh --stop --no-drain
#   .gaai/core/scripts/daemon-start.sh --status      Read-only lifecycle status
#   .gaai/core/scripts/daemon-start.sh --monitor     Presentation UI (after status)
#   .gaai/core/scripts/daemon-start.sh --restart     Stop + start
#
#   Prefixing that path with a plain `bash` interpreter is NOT supported and is refused:
#   a non-privileged interpreter has already applied BASH_ENV and imported
#   exported functions before this script's first instruction. An absolute,
#   verified Bash invoked `--noprofile --norc -p <script>` is the only alternative.
#
# Options (recorded in the launch tuple, consumed by the daemon child):
#   --max-concurrent N     Parallel delivery slots
#   --interval N           Poll interval in seconds
#   --exit-when-idle [N]   Auto-stop after N consecutive idle polls
#   --dry-run              Show what would launch, don't execute
#
# Exit codes:
#   0  — success
#   1  — typed lifecycle refusal (reason + canonical action on stderr)
#   78 — entry_authority_invalid (contaminated or unsupported entry)
# ═══════════════════════════════════════════════════════════════════════════

GAAI_ENTRY_NAME="daemon-start"

# BEGIN GAAI-ENTRY-AUTHORITY (byte-identical in daemon-start.sh and daemon-setup.sh)
# ═══════════════════════════════════════════════════════════════════════════
# Privileged entry authority (exact-current startup contract) — FIRST INSTRUCTIONS
# ═══════════════════════════════════════════════════════════════════════════
#
# This block is deliberately inlined rather than sourced. A sourced helper runs
# only after the interpreter has already applied BASH_ENV, ENV, SHELLOPTS and
# exported-function import — by then an "exact" script is already contaminated.
# Only the privileged shebang plus these first instructions close that window, so
# `daemon-start.sh` and `daemon-setup.sh` each carry their own copy. Keep the two
# copies identical; `daemon-asset-home.test.sh` proves they have not drifted.
#
# This closes the pre-interpreter contamination path. It does NOT claim protection
# against a malicious principal running under the same OS UID, which can replace a
# user-owned file before the privileged interpreter opens it.

_gaai_entry_refuse() {
  printf '%s: reason=entry_authority_invalid action=none evidence=%s\n' \
    "$GAAI_ENTRY_NAME" "${1:-unspecified}" >&2
  exit 78
}

# 1. Privileged mode must be provably ON at the first instruction.
case "$-" in
  *p*) ;;
  *)   _gaai_entry_refuse "entry_role=privileged_mode_absent" ;;
esac
if [[ "$(set -o 2>/dev/null | while read -r _o _v; do [[ "$_o" == "privileged" ]] && printf '%s' "$_v"; done)" != "on" ]]; then
  _gaai_entry_refuse "entry_role=privileged_mode_unconfirmed"
fi

# 2. Builtin-only normalization. No external command has run yet, by construction.
set -euo pipefail
set +x +v
IFS=$' \t\n'
umask 022
LC_ALL=C; LANG=C; export LC_ALL LANG
unset -v CDPATH GLOBIGNORE BASH_XTRACEFD PS4 2>/dev/null || true
shopt -u expand_aliases 2>/dev/null || true

# 3. Hostile inherited entries. Privileged Bash already refuses to EXECUTE
#    BASH_ENV/ENV and refuses to IMPORT exported functions, but both remain
#    OBSERVABLE in the environment at this instruction — and an observable entry
#    must be refused, not merely neutralised.
_GAAI_HOSTILE_EXACT='BASH_ENV ENV SHELLOPTS BASHOPTS BASH_COMPAT BASH_XTRACEFD PS4
GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS
GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_PAGER GIT_EXTERNAL_DIFF GIT_DIFF_OPTS
GIT_PROXY_COMMAND GIT_TEMPLATE_DIR GIT_NAMESPACE GIT_ATTR_NOSYSTEM
GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_ALLOW_PROTOCOL
GIT_PROTOCOL_FROM_USER GIT_TRACE GIT_TRACE2 GIT_TRACE_PACKET GIT_TERMINAL_PROMPT
GIT_EXEC_PATH GIT_HOOKS_PATH GIT_INDEX_VERSION GIT_REPLACE_REF_BASE
PYTHONSTARTUP PYTHONPATH PYTHONHOME PYTHONEXECUTABLE PYTHONWARNINGS
PERL5LIB PERL5OPT PERLLIB PERL5DB
LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_ORIGIN_PATH
DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_ROOT_PATH'
# Ambient tmux entries are IGNORED rather than refused: the daemon child legitimately
# runs inside a pane of the private server, where tmux sets TMUX and TMUX_PANE itself.
# Dropping them means no ambient or inherited tmux context can ever select a server,
# a socket root or a pane for this lifecycle — those come from the digest-bound
# derivation alone.
unset -v TMUX TMUX_PANE TMUX_TMPDIR 2>/dev/null || true
export -n TMUX TMUX_PANE TMUX_TMPDIR 2>/dev/null || true
#    The test is INHERITANCE, not mere presence: `SHELLOPTS`, `BASHOPTS` and `PS4`
#    are maintained by every Bash whether or not anyone passed them, so only an
#    entry that arrived in the environment is hostile. At the first instruction the
#    exported set is exactly the inherited set.
#
# 4. The families are closed, not the list: any inherited member of them is equally
#    disqualifying even when it is not named above.
_GAAI_HOSTILE_FLAT=" ${_GAAI_HOSTILE_EXACT//$'\n'/ } "
for _gaai_name in $(compgen -e 2>/dev/null || true); do
  case "$_gaai_name" in
    GIT_*|LD_*|DYLD_*|PYTHON*|PERL5*|BASH_FUNC_*)
      _gaai_entry_refuse "entry_role=hostile_variable:${_gaai_name}" ;;
  esac
  case "$_GAAI_HOSTILE_FLAT" in
    *" $_gaai_name "*) _gaai_entry_refuse "entry_role=hostile_variable:${_gaai_name}" ;;
  esac
done
unset -v _gaai_name _gaai_bad

# 5. Exported-function entries. Privileged Bash did not import them, so
#    `declare -F` is clean; what still has to be proven is that the encoded
#    environment entry is absent too, and stays absent from every descendant.
for _gaai_fn in exec unset builtin command source eval export read printf cd set trap kill git tmux; do
  if declare -F "$_gaai_fn" >/dev/null 2>&1; then
    _gaai_entry_refuse "entry_role=hostile_function:${_gaai_fn}"
  fi
done
unset -v _gaai_fn
if [[ -r /proc/self/environ ]]; then
  while IFS= read -r -d '' _gaai_kv; do
    case "$_gaai_kv" in
      BASH_FUNC_*) _gaai_entry_refuse "entry_role=hostile_function_entry" ;;
    esac
  done < /proc/self/environ
  unset -v _gaai_kv
fi

# 6. Attested absolute-command allowlist. Resolution never consults the inherited
#    PATH or the current directory: only this closed set of roots is searched, and
#    every candidate plus each of its parent components must be owned by root or
#    this UID and be unwritable by anyone else.
_GAAI_CMD_ROOTS='/usr/bin /bin /usr/sbin /sbin /usr/local/bin /opt/homebrew/bin'
_GAAI_REQUIRED_CMDS='git tmux env stat id uname mkdir rmdir rm mv cp ln readlink cat sed awk cut tr head wc ps sync sleep mkfifo chmod grep dirname basename date'

# Owner must be root or this UID; group/other write bits are disqualifying.
_gaai_safe_owner_mode() {
  local _p="$1" _uid="${UID:-0}" _own _mode
  # -L: GNU stat lstat()s by default, and a symlink's own mode is always 0777. The
  # link itself cannot be hijacked by an untrusted principal because its containing
  # directory is attested in the same walk, so following to the target is the proof
  # that matters.
  _own="$(stat -L -c '%u' "$_p" 2>/dev/null || stat -L -f '%u' "$_p" 2>/dev/null || echo "")"
  _mode="$(stat -L -c '%a' "$_p" 2>/dev/null || stat -L -f '%Lp' "$_p" 2>/dev/null || echo "")"
  [[ -n "$_own" && -n "$_mode" ]] || return 1
  [[ "$_own" == "0" || "$_own" == "$_uid" ]] || return 1
  while [[ "${#_mode}" -lt 4 ]]; do _mode="0$_mode"; done
  local _grp="${_mode:2:1}" _oth="${_mode:3:1}"
  case "$_grp" in 2|3|6|7) return 1 ;; esac
  case "$_oth" in 2|3|6|7) return 1 ;; esac
  return 0
}

# Stricter than the above, for a file whose CONTENT is the secret rather than the
# path: unwritable by group and other is not enough, it must also be unreadable by
# them, and it must be owned by this principal — root ownership is not accepted for
# a credential this principal is expected to control and rotate.
_gaai_private_owner_mode() {
  local _p="$1" _uid="${UID:-0}" _own _mode
  _own="$(stat -L -c '%u' "$_p" 2>/dev/null || stat -L -f '%u' "$_p" 2>/dev/null || echo "")"
  _mode="$(stat -L -c '%a' "$_p" 2>/dev/null || stat -L -f '%Lp' "$_p" 2>/dev/null || echo "")"
  [[ -n "$_own" && -n "$_mode" ]] || return 1
  [[ "$_own" == "$_uid" ]] || return 1
  while [[ "${#_mode}" -lt 4 ]]; do _mode="0$_mode"; done
  [[ "${_mode:2:1}" == "0" && "${_mode:3:1}" == "0" ]] || return 1
  return 0
}

# Every component of the literal path, so a hijacked intermediate directory is
# caught even when the leaf looks correct.
_gaai_attest_path() {
  local _p="$1" _acc="" _part
  [[ "$_p" == /* ]] || return 1
  local _saved_ifs="$IFS"; IFS='/'
  for _part in $_p; do
    [[ -z "$_part" ]] && continue
    _acc="$_acc/$_part"
    if [[ ! -e "$_acc" ]]; then IFS="$_saved_ifs"; return 1; fi
    if ! _gaai_safe_owner_mode "$_acc"; then IFS="$_saved_ifs"; return 1; fi
  done
  IFS="$_saved_ifs"
  return 0
}

# The operator's inherited PATH is preserved for ADVISORY presence checks only
# (`claude`, `jq`, `python3`, `timeout` — operator tooling, never lifecycle
# authority). No authority-bearing command is ever resolved through it.
GAAI_OPERATOR_PATH="${PATH:-}"
export GAAI_OPERATOR_PATH

# `stat` bootstraps the attestation, so it is located with builtin tests only and
# then re-attested with itself once available.
_gaai_stat_bootstrap=""
for _gaai_dir in $_GAAI_CMD_ROOTS; do
  if [[ -f "$_gaai_dir/stat" && -x "$_gaai_dir/stat" ]]; then _gaai_stat_bootstrap="$_gaai_dir/stat"; break; fi
done
[[ -n "$_gaai_stat_bootstrap" ]] || _gaai_entry_refuse "entry_role=tool_absent:stat"
PATH="${_gaai_stat_bootstrap%/stat}"
export PATH
_gaai_attest_path "$_gaai_stat_bootstrap" || _gaai_entry_refuse "entry_role=tool_untrusted:stat"

_GAAI_ATTESTED_ROOTS=""
for _gaai_dir in $_GAAI_CMD_ROOTS; do
  [[ -d "$_gaai_dir" ]] || continue
  _gaai_attest_path "$_gaai_dir" || continue
  _GAAI_ATTESTED_ROOTS="${_GAAI_ATTESTED_ROOTS}${_GAAI_ATTESTED_ROOTS:+ }$_gaai_dir"
done
[[ -n "$_GAAI_ATTESTED_ROOTS" ]] || _gaai_entry_refuse "entry_role=no_attested_command_root"

for _gaai_cmd in $_GAAI_REQUIRED_CMDS; do
  _gaai_found=""
  for _gaai_dir in $_GAAI_ATTESTED_ROOTS; do
    if [[ -f "$_gaai_dir/$_gaai_cmd" && -x "$_gaai_dir/$_gaai_cmd" ]] \
        && _gaai_attest_path "$_gaai_dir/$_gaai_cmd"; then
      _gaai_found="$_gaai_dir/$_gaai_cmd"; break
    fi
  done
  if [[ -z "$_gaai_found" ]]; then
    case "$_gaai_cmd" in
      # Optional on some hosts; their absence degrades a diagnostic, never authority.
      sync|grep) continue ;;
      *) _gaai_entry_refuse "entry_role=tool_absent_or_untrusted:${_gaai_cmd}" ;;
    esac
  fi
done
unset -v _gaai_cmd _gaai_dir _gaai_found _gaai_stat_bootstrap

# One digest tool is mandatory; either spelling is accepted, deterministically.
GAAI_DIGEST_CMD=""
for _gaai_dir in $_GAAI_ATTESTED_ROOTS; do
  if [[ -z "$GAAI_DIGEST_CMD" && -f "$_gaai_dir/shasum" && -x "$_gaai_dir/shasum" ]] \
      && _gaai_attest_path "$_gaai_dir/shasum"; then GAAI_DIGEST_CMD="$_gaai_dir/shasum"; fi
done
if [[ -z "$GAAI_DIGEST_CMD" ]]; then
  for _gaai_dir in $_GAAI_ATTESTED_ROOTS; do
    if [[ -z "$GAAI_DIGEST_CMD" && -f "$_gaai_dir/sha256sum" && -x "$_gaai_dir/sha256sum" ]] \
        && _gaai_attest_path "$_gaai_dir/sha256sum"; then GAAI_DIGEST_CMD="$_gaai_dir/sha256sum"; fi
  done
fi
[[ -n "$GAAI_DIGEST_CMD" ]] || _gaai_entry_refuse "entry_role=tool_absent_or_untrusted:sha256"
unset -v _gaai_dir

# The attested roots become the ONLY search path. No current directory, no
# inherited entry, no user-writable directory participates in a lookup.
PATH="$(printf '%s' "$_GAAI_ATTESTED_ROOTS" | sed 's/ /:/g')"
export PATH
GAAI_ENV_CMD=""
for _gaai_dir in $_GAAI_ATTESTED_ROOTS; do
  if [[ -z "$GAAI_ENV_CMD" && -x "$_gaai_dir/env" ]]; then GAAI_ENV_CMD="$_gaai_dir/env"; fi
done
unset -v _gaai_dir

# On a host without /proc, the function-import entries are proven absent with the
# attested `env` instead — the same refusal, one bootstrap step later.
if [[ ! -r /proc/self/environ ]]; then
  if "$GAAI_ENV_CMD" | sed -n 's/^\(BASH_FUNC_[^=]*\)=.*/\1/p' | head -1 | grep -q . 2>/dev/null; then
    _gaai_entry_refuse "entry_role=hostile_function_entry"
  fi
fi

# 7. Verified private HOME/XDG/TMP roots. No inherited root may redirect a tool's
#    config, cache or temporary state. These are also what every descendant gets.
GAAI_PRIVATE_ROOT="/tmp/.gaai-p-${UID:-0}"
mkdir -p "$GAAI_PRIVATE_ROOT" 2>/dev/null || _gaai_entry_refuse "entry_role=private_root_uncreatable"
chmod 0700 "$GAAI_PRIVATE_ROOT" 2>/dev/null || true
if [[ -L "$GAAI_PRIVATE_ROOT" ]] || ! _gaai_safe_owner_mode "$GAAI_PRIVATE_ROOT"; then
  _gaai_entry_refuse "entry_role=private_root_untrusted"
fi
for _gaai_sub in home xdg-config xdg-cache xdg-data tmp scope; do
  mkdir -p "$GAAI_PRIVATE_ROOT/$_gaai_sub" 2>/dev/null \
    || _gaai_entry_refuse "entry_role=private_root_uncreatable"
  chmod 0700 "$GAAI_PRIVATE_ROOT/$_gaai_sub" 2>/dev/null || true
done
unset -v _gaai_sub
GAAI_OPERATOR_HOME="${HOME:-}"
HOME="$GAAI_PRIVATE_ROOT/home"
XDG_CONFIG_HOME="$GAAI_PRIVATE_ROOT/xdg-config"
XDG_CACHE_HOME="$GAAI_PRIVATE_ROOT/xdg-cache"
XDG_DATA_HOME="$GAAI_PRIVATE_ROOT/xdg-data"
TMPDIR="$GAAI_PRIVATE_ROOT/tmp"
export HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME TMPDIR

# 7a. Exclusive per-invocation launch scope. Every invocation shares
#     $GAAI_PRIVATE_ROOT, so a forge identity or git configuration written there
#     would be visible to, and truncatable by, any other invocation on the account
#     (AC1/AC2/AC3/AC5). `mkdir` with no `-p` on a proposed leaf is the atomic
#     exclusivity proof: a collision means another invocation already claimed that
#     name, never that this one may reuse it. Bounded retry only widens the
#     candidate name, never the search space of shared state.
#
# Reclaimed on every normal exit. A crashed invocation's scope is instead reclaimed
# by the next `do_start` (settled path) or by `do_stop` settlement, from the
# durable owner record — this trap is not the only reclaim path because `exec`
# (the child's handoff into the long-running daemon) never runs it. Defined here,
# before the scope is claimed, so the trap can be armed the instant a scope
# directory exists — every refusal that can fire after that point must not leak it.
_gaai_launch_scope_cleanup() {
  if [[ -n "${GAAI_LAUNCH_SCOPE:-}" && -d "$GAAI_LAUNCH_SCOPE" && ! -L "$GAAI_LAUNCH_SCOPE" \
        && "$GAAI_LAUNCH_SCOPE" == "$GAAI_PRIVATE_ROOT/scope/"* ]]; then
    rm -rf "$GAAI_LAUNCH_SCOPE" 2>/dev/null || true
  fi
}

GAAI_LAUNCH_SCOPE=""
_gaai_scope_tries=0
while [[ -z "$GAAI_LAUNCH_SCOPE" ]]; do
  _gaai_scope_tries=$(( _gaai_scope_tries + 1 ))
  if [[ "$_gaai_scope_tries" -gt 20 ]]; then
    _gaai_entry_refuse "entry_role=launch_scope_uncreatable"
  fi
  _gaai_scope_candidate="$GAAI_PRIVATE_ROOT/scope/l.$$.$RANDOM"
  if mkdir "$_gaai_scope_candidate" 2>/dev/null; then
    GAAI_LAUNCH_SCOPE="$_gaai_scope_candidate"
  fi
done
unset -v _gaai_scope_tries _gaai_scope_candidate
trap '_gaai_launch_scope_cleanup' EXIT INT TERM
chmod 0700 "$GAAI_LAUNCH_SCOPE" 2>/dev/null || true
if [[ -L "$GAAI_LAUNCH_SCOPE" ]] || ! _gaai_safe_owner_mode "$GAAI_LAUNCH_SCOPE"; then
  _gaai_entry_refuse "entry_role=launch_scope_untrusted"
fi
export GAAI_LAUNCH_SCOPE
# TMPDIR moves into the launch scope too — HOME/XDG_* stay on the shared private
# root (agent project/session state is meant to persist across launches); only the
# forge/git identity surface below and this process's own temp files are launch-
# exclusive.
mkdir -p "$GAAI_LAUNCH_SCOPE/tmp" 2>/dev/null || _gaai_entry_refuse "entry_role=launch_scope_uncreatable"
chmod 0700 "$GAAI_LAUNCH_SCOPE/tmp" 2>/dev/null || true
TMPDIR="$GAAI_LAUNCH_SCOPE/tmp"
export TMPDIR

# 7b. Remote authentication for the private HOME. Replacing HOME above is what
#     makes the entry trustworthy, and it is also what removes every path Git has
#     to a credential helper: the operator's `~/.gitconfig` is unreachable, and the
#     macOS keychain helper cannot reach a login keychain non-interactively
#     ("could not read Username ... Device not configured"). Without this the very
#     first lifecycle operation — fetching the target branch — fails, and no start,
#     verify or canary can succeed against an authenticated remote.
#
#     The credential path is therefore PROVISIONED INSIDE the private root rather
#     than inherited: nothing from the environment redirects a tool's config, which
#     is the property section 7 protects. No symlink and no ambient `gh`
#     configuration is trusted here: an entry-owned helper script and `$HOME/.gitconfig`
#     are written unconditionally further below (7b), sourcing a credential only from
#     THIS launch's own admitted identity. A host with no admitted forge credential is
#     refused (AC4) rather than falling back to a prior launch's or the operator's own
#     configuration; a remote that needs no credentials is unaffected either way.
#     Preferred route: a DEDICATED forge credential the operator provisions outside
#     the private root. It is read once here and nothing is copied to disk; the
#     operator's own tool configuration is never made reachable, so a credential
#     scoped to the repositories this daemon actually needs replaces one scoped to
#     everything the operator can reach. The file must be a regular file, not a
#     symlink, owned by this principal, with no group or other access. A file that
#     fails any of those is IGNORED rather than "repaired" — this entry never widens
#     permissions on an operator's secret.
#
#     Any inherited forge credential or forge identity is dropped first. The
#     environment must never be able to choose the identity the daemon acts under.
#     The verdict and any admitted identity/token are held in NON-EXPORTED
#     variables so a later gate (do_start, before any tmux/credential/daemon
#     effect) can refuse a launch that admitted none, while this entry's OWN
#     fetch below may still use the exported form to prove the exact target
#     (permitted — proving the exact target is what requires it).
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_CONFIG_DIR GH_HOST GAAI_FORGE_IDENTITY GAAI_FORGE_TOKEN
_GAAI_FORGE_IDENTITY=""
_GAAI_FORGE_TOKEN=""
_GAAI_FORGE_VERDICT="unread"
# Deferred admission (AC3/AC5): this is a DEFINITION only. The credential is not
# read until a gate that has already proven single-owner/lifecycle authority for
# the target repository calls this function explicitly (do_start, daemon-setup.sh)
# — never at entry time, and never for a status query or a competing invocation
# that never reaches that gate. `unread` (not `absent`) is the verdict for "this
# invocation never called it": a real absent-token host still reaches `absent`,
# but only from inside the function, after the gate authorized the read.
_gaai_admit_forge_identity() {
  _gaai_forge_token_file="${GAAI_OPERATOR_HOME:-}/.gaai/forge-token"
  _GAAI_FORGE_VERDICT="absent"
  if [[ -n "${GAAI_OPERATOR_HOME:-}" && -e "$_gaai_forge_token_file" ]]; then
    if [[ -L "$_gaai_forge_token_file" ]]; then
      _GAAI_FORGE_VERDICT="symlink"
    elif [[ ! -f "$_gaai_forge_token_file" ]]; then
      _GAAI_FORGE_VERDICT="not_regular"
    elif ! _gaai_private_owner_mode "$_gaai_forge_token_file"; then
      _GAAI_FORGE_VERDICT="mode_or_owner_invalid"
    else
      _gaai_forge_size="$(stat -c '%s' "$_gaai_forge_token_file" 2>/dev/null \
        || stat -f '%z' "$_gaai_forge_token_file" 2>/dev/null || echo "")"
      if [[ -z "$_gaai_forge_size" ]] || (( _gaai_forge_size > 4096 )); then
        _GAAI_FORGE_VERDICT="oversized"
      else
        # Grammar: either one bare-token line (identity implied as the fixed forge
        # convention "x-access-token") or exactly "identity=<v>" / "token=<v>". No
        # shell evaluation — a bounded read loop, never `source`. A third line, an
        # unknown key or an unsafe scalar is refused, never guessed at.
        _gaai_forge_nlines=0 _gaai_forge_l1="" _gaai_forge_l2="" _gaai_forge_ln=""
        while IFS= read -r _gaai_forge_ln || [[ -n "$_gaai_forge_ln" ]]; do
          _gaai_forge_nlines=$(( _gaai_forge_nlines + 1 ))
          case "$_gaai_forge_nlines" in
            1) _gaai_forge_l1="$_gaai_forge_ln" ;;
            2) _gaai_forge_l2="$_gaai_forge_ln" ;;
          esac
          [[ "$_gaai_forge_nlines" -ge 3 ]] && break
        done < "$_gaai_forge_token_file" 2>/dev/null
        case "$_gaai_forge_nlines" in
          0) _GAAI_FORGE_VERDICT="empty" ;;
          1)
            if [[ "$_gaai_forge_l1" =~ ^[A-Za-z0-9._-]+$ ]]; then
              _GAAI_FORGE_IDENTITY="x-access-token"
              _GAAI_FORGE_TOKEN="$_gaai_forge_l1"
              _GAAI_FORGE_VERDICT="ok"
            else
              _GAAI_FORGE_VERDICT="charset_invalid"
            fi
            ;;
          2)
            if [[ "$_gaai_forge_l1" == identity=* && "$_gaai_forge_l2" == token=* ]]; then
              _gaai_forge_id="${_gaai_forge_l1#identity=}"
              _gaai_forge_tok="${_gaai_forge_l2#token=}"
              if [[ "$_gaai_forge_id" =~ ^[A-Za-z0-9._-]+$ && "$_gaai_forge_tok" =~ ^[A-Za-z0-9._-]+$ ]]; then
                _GAAI_FORGE_IDENTITY="$_gaai_forge_id"
                _GAAI_FORGE_TOKEN="$_gaai_forge_tok"
                _GAAI_FORGE_VERDICT="ok"
              else
                _GAAI_FORGE_VERDICT="charset_invalid"
              fi
            else
              _GAAI_FORGE_VERDICT="grammar_invalid"
            fi
            unset -v _gaai_forge_id _gaai_forge_tok
            ;;
          *) _GAAI_FORGE_VERDICT="grammar_invalid" ;;
        esac
        unset -v _gaai_forge_nlines _gaai_forge_l1 _gaai_forge_l2 _gaai_forge_ln
      fi
      unset -v _gaai_forge_size
    fi
  fi
  unset -v _gaai_forge_token_file
  if [[ "$_GAAI_FORGE_VERDICT" == "ok" ]]; then
    GH_TOKEN="$_GAAI_FORGE_TOKEN"
    GAAI_FORGE_IDENTITY="$_GAAI_FORGE_IDENTITY"
    GAAI_FORGE_TOKEN="$_GAAI_FORGE_TOKEN"
    export GH_TOKEN GAAI_FORGE_IDENTITY GAAI_FORGE_TOKEN
  fi
}
#     No ambient carrier: `gh`'s own configuration must never supply an identity
#     this launch did not itself admit. Redirecting `gh` at a fresh directory
#     inside this launch's own scope achieves that without touching the
#     account-shared `$XDG_CONFIG_HOME/gh` another invocation may be reading —
#     removing it outright, as an earlier revision did, was itself the AC2 shared-
#     state mutation this Story forbids.
mkdir -p "$GAAI_LAUNCH_SCOPE/gh" 2>/dev/null || _gaai_entry_refuse "entry_role=launch_scope_uncreatable"
chmod 0700 "$GAAI_LAUNCH_SCOPE/gh" 2>/dev/null || true
GH_CONFIG_DIR="$GAAI_LAUNCH_SCOPE/gh"
export GH_CONFIG_DIR
#     The delivery agent CLI's account state is the same class of problem and takes
#     the same shape: a private HOME hides the account binding the CLI keeps in the
#     home root, and without it the CLI reports itself logged out. Linking it is
#     necessary but, where the CLI holds its secret in the platform keychain, not
#     sufficient — section 7b's opening note applies to that keychain too, so such a
#     CLI stays unauthenticated here until it is given a file-backed credential, and
#     an executor whose credential IS file-backed is the supported route meanwhile.
#     Only a symlink is created
#     — nothing is copied, and the operator's file stays the single source. The same
#     conditions apply as above: a regular file, not a symlink, owned by this
#     principal, with no group or other access, and a host missing either the CLI or
#     the file keeps exactly today's behaviour. The destination sits inside the
#     entry-owned private root, so a stale stub an earlier run left there is replaced
#     rather than left to mask the link. Replacing is conditional now: an
#     already-correct link is a no-op, so no invocation redirects another's
#     executor credential even momentarily. These four links are account-shared
#     and are not the forge-identity channel this isolation boundary otherwise
#     anchors to; a fresh account where a later-failing launch already created
#     one of them is a known, accepted residual (see the isolation design notes).
_gaai_relink_if_stale() {
  local _src="$1" _dest="$2"
  if [[ -L "$_dest" ]]; then
    local _cur; _cur="$(readlink "$_dest" 2>/dev/null || echo "")"
    [[ "$_cur" == "$_src" ]] && return 0
    rm -f "$_dest" 2>/dev/null || true
    ln -s "$_src" "$_dest" 2>/dev/null || true
    return 0
  fi
  [[ -e "$_dest" ]] && return 0
  ln -s "$_src" "$_dest" 2>/dev/null || true
}
_gaai_agent_account_file="${GAAI_OPERATOR_HOME:-}/.claude.json"
if [[ -n "${GAAI_OPERATOR_HOME:-}" && -f "$_gaai_agent_account_file" \
      && ! -L "$_gaai_agent_account_file" ]] \
   && _gaai_private_owner_mode "$_gaai_agent_account_file" \
   && command -v claude >/dev/null 2>&1; then
  _gaai_relink_if_stale "$_gaai_agent_account_file" "$HOME/.claude.json"
fi
unset -v _gaai_agent_account_file
#     An executor CLI that keeps a file-backed credential needs only that file to be
#     reachable, which is the whole difference from the keychain case above. Link the
#     credential alone rather than the tool's directory: the daemon then authenticates
#     as the operator without its session state, history or caches being written back
#     into the operator's own. The conditions are the ones used throughout section 7b,
#     and a host without the credential keeps exactly today's behaviour.
_gaai_executor_auth_file="${GAAI_OPERATOR_HOME:-}/.codex/auth.json"
if [[ -n "${GAAI_OPERATOR_HOME:-}" && -f "$_gaai_executor_auth_file" \
      && ! -L "$_gaai_executor_auth_file" ]] \
   && _gaai_private_owner_mode "$_gaai_executor_auth_file" \
   && command -v codex >/dev/null 2>&1; then
  ( umask 077; mkdir -p "$HOME/.codex" ) 2>/dev/null || true
  if [[ -d "$HOME/.codex" ]]; then
    _gaai_relink_if_stale "$_gaai_executor_auth_file" "$HOME/.codex/auth.json"
  fi
fi
unset -v _gaai_executor_auth_file
#     Executor credentials the platform holds in a keychain rather than a file. macOS
#     resolves the login keychain from HOME, so the private root hides it outright and
#     an executor that keeps its secret there cannot authenticate at all: on that
#     platform the daemon is unusable the moment it is installed, which is not an
#     acceptable default for a framework meant to be started by anyone. Link the
#     operator's keychain directory so the executor finds it where the platform looks.
#
#     This does not widen what a delivery agent can reach. Such an agent already runs
#     under the operator's own account with permission prompts disabled: it can read
#     whatever the operator can read, and can set HOME for itself. What the private
#     root buys is that no inherited configuration silently redirects the ENTRY's own
#     tools, and that property is untouched here.
#
#     The keychain directory keeps the platform's own default mode, which is not the
#     no-group-and-other layout the file predicate demands, so the requirement here is
#     ownership plus the absence of group or other WRITE. An existing destination is
#     never replaced.
_gaai_keychain_dir="${GAAI_OPERATOR_HOME:-}/Library/Keychains"
if [[ -n "${GAAI_OPERATOR_HOME:-}" && -d "$_gaai_keychain_dir" \
      && ! -L "$_gaai_keychain_dir" && ! -e "$HOME/Library/Keychains" ]]; then
  _gaai_kc_own="$(stat -L -f '%u' "$_gaai_keychain_dir" 2>/dev/null \
    || stat -L -c '%u' "$_gaai_keychain_dir" 2>/dev/null || printf '')"
  _gaai_kc_mode="$(stat -L -f '%Lp' "$_gaai_keychain_dir" 2>/dev/null \
    || stat -L -c '%a' "$_gaai_keychain_dir" 2>/dev/null || printf '')"
  while [[ -n "$_gaai_kc_mode" && "${#_gaai_kc_mode}" -lt 4 ]]; do
    _gaai_kc_mode="0$_gaai_kc_mode"
  done
  if [[ -n "$_gaai_kc_own" && "$_gaai_kc_own" == "${UID:-0}" \
        && "$_gaai_kc_mode" =~ ^[0-7]{4}$ ]] \
     && (( (8#$_gaai_kc_mode & 8#0022) == 0 )); then
    ( umask 077; mkdir -p "$HOME/Library" ) 2>/dev/null || true
    [[ -d "$HOME/Library" ]] \
      && ln -s "$_gaai_keychain_dir" "$HOME/Library/Keychains" 2>/dev/null || true
  fi
fi
unset -v _gaai_keychain_dir _gaai_kc_own _gaai_kc_mode
#     An install that keeps the same executor's credential in a file instead needs only
#     that file, on the conditions used throughout this section.
_gaai_agent_cred_file="${GAAI_OPERATOR_HOME:-}/.claude/.credentials.json"
if [[ -n "${GAAI_OPERATOR_HOME:-}" && -f "$_gaai_agent_cred_file" \
      && ! -L "$_gaai_agent_cred_file" && ! -e "$HOME/.claude/.credentials.json" ]] \
   && _gaai_private_owner_mode "$_gaai_agent_cred_file"; then
  ( umask 077; mkdir -p "$HOME/.claude" ) 2>/dev/null || true
  [[ -d "$HOME/.claude" ]] \
    && ln -s "$_gaai_agent_cred_file" "$HOME/.claude/.credentials.json" 2>/dev/null || true
fi
unset -v _gaai_agent_cred_file
# The private root's git configuration is entry-owned and rewritten on EVERY
# entry, unconditionally: a stale chain cannot survive, and a launch that admits
# no identity gets no ambient rescue either. The leading empty helper resets the
# list accumulated from higher-level files: on this platform git reads an
# additional built-in system gitconfig that declares the platform keychain helper
# and that no environment variable can displace, so without the reset every
# successful fetch also runs a keychain store that cannot succeed under a private
# HOME. The installed helper reads a credential ONLY from this process's own
# GAAI_FORGE_IDENTITY / GAAI_FORGE_TOKEN — never from `gh`'s own configuration or
# a platform keychain — and refuses (exit 1, no output) when either is absent, so
# a process without this launch's identity gets no credential from it rather than
# someone else's. The helper string itself carries no secret.
#     The configuration itself lives in THIS launch's own scope, not `$HOME`: two
#     invocations writing `$HOME/.gitconfig` unconditionally is exactly the shared-
#     state truncation AC2/AC3/AC5 forbid, however byte-identical the content.
_gaai_cred_helper="$GAAI_LAUNCH_SCOPE/gaai-git-credential-helper.sh"
( umask 077
  cat > "$_gaai_cred_helper" <<'GAAI_HELPER_EOF'
#!/bin/bash
[[ "${1:-}" == "get" ]] || exit 0
[[ -n "${GAAI_FORGE_IDENTITY:-}" && -n "${GAAI_FORGE_TOKEN:-}" ]] || exit 1
printf 'username=%s\npassword=%s\n' "$GAAI_FORGE_IDENTITY" "$GAAI_FORGE_TOKEN"
GAAI_HELPER_EOF
  chmod 0700 "$_gaai_cred_helper"
  printf '[credential]\n\thelper =\n\thelper = !%s\n[gaai]\n\tlaunchscope = %s\n' \
    "$_gaai_cred_helper" "$$" > "$GAAI_LAUNCH_SCOPE/gitconfig"
  chmod 0600 "$GAAI_LAUNCH_SCOPE/gitconfig"
) 2>/dev/null || true
unset -v _gaai_cred_helper
GIT_CONFIG_GLOBAL="$GAAI_LAUNCH_SCOPE/gitconfig"
export GIT_CONFIG_GLOBAL
# Prove the redirection actually took effect on THIS git build before any fetch
# is attempted: a `GIT_CONFIG_GLOBAL` git silently ignored would leave every
# invocation sharing the account-wide config again — the exact defect the launch
# scope exists to prevent. Fails closed rather than degrading.
if [[ "$(git config --get gaai.launchscope 2>/dev/null || echo "")" != "$$" ]]; then
  _gaai_entry_refuse "entry_role=git_config_scope_unhonoured"
fi

# 7c. No interactive credential path, ever. The private HOME above leaves git with
#     no helper unless 7b provisioned one, and a pane of the private tmux server IS
#     a terminal: without this, an absent credential makes the very first
#     `git fetch` print `Username for 'https://github.com':` and wait forever. The
#     daemon then never completes a poll cycle, `--exit-when-idle` never fires, and
#     the log shows nothing past its startup lines because the prompt exists only
#     in the pane. Every credential-acquisition path is closed here instead, so an
#     absent credential fails IMMEDIATELY with a typed reason the daemon can log:
#       GIT_TERMINAL_PROMPT=0  git may not prompt on the controlling terminal
#       GIT_ASKPASS=''         an exported EMPTY value is not "unset": git then
#                              consults neither core.askPass nor SSH_ASKPASS
#                              (measured), so no askpass program can be reached
#       GH_PROMPT_DISABLED=1   gh never opens an interactive prompt
#     An inherited GIT_TERMINAL_PROMPT or GIT_ASKPASS was already refused in
#     section 4 as a GIT_* family member; an inherited GH_PROMPT_DISABLED is
#     overwritten here before anything can read it. The values set HERE are
#     entry-owned, and they survive the section 8 strip so they reach every
#     descendant — the daemon child, its git, and gh.
GIT_TERMINAL_PROMPT=0
GIT_ASKPASS=""
GH_PROMPT_DISABLED=1
export GIT_TERMINAL_PROMPT GIT_ASKPASS GH_PROMPT_DISABLED

# 8. Positive allowlist: every other exported configuration entry is dropped and
#    the survivors are rebuilt from validated scalar values. A value that is not a
#    single safe scalar is not "sanitised" — it is refused.
_GAAI_CONFIG_ALLOW='GAAI_TARGET_BRANCH GAAI_DAEMON_HOME GAAI_REPO_ROOT GAAI_STOP_DRAIN_TIMEOUT GAAI_STOP_AGENT_GRACE
GAAI_DAEMON_NO_MONITOR GAAI_CLAUDE_PROXY_BASE_URL GAAI_IMPL_BASE_URL GAAI_IMPL_MODEL
GAAI_IMPL_MODEL_FALLBACK GAAI_AUTO_MERGE_POLICY GAAI_AUTO_MERGE_ADMIN_FALLBACK
GAAI_DAEMON_EXECUTOR GAAI_CODEX_MODEL GAAI_CODEX_SANDBOX GAAI_CODEX_EPHEMERAL
GAAI_CODEX_IGNORE_USER_CONFIG GAAI_CI_TEST_GATE_TIMEOUT_SEC GAAI_CI_TEST_GATE_MATERIALIZE_SEC
GAAI_WORKTREES_BASE GAAI_STAGING_LOCK_TIMEOUT_SEC GAAI_MAX_TURNS GAAI_IMPL_MAX_TURNS GAAI_QA_MAX_TURNS GAAI_PLAN_MAX_TURNS
GAAI_NOTES_MAX_CHARS
GAAI_NOTIFICATION_WEBHOOK GAAI_DAEMON_WEBHOOK_SECRET GAAI_IMPL_AUTH_TOKEN'
# Presence is tested against the exported set rather than with an indirect
# expansion carrying a modifier (`${!name+set}`). Both forms are believed to work
# in Bash 3.2, but "believed" is not a proof, and on macOS `/bin/bash` — the real
# interpreter of this launcher's shebang — IS 3.2. Membership in `compgen -e` plus
# a PLAIN `${!name}` uses only constructs whose 3.2 support is not in question, and
# at the first instruction the exported set is exactly the inherited set, so the
# two tests are equivalent here. Plain indirection is also safe under `set -u`
# precisely because membership was proven first.
_GAAI_EXPORTED_SET=" $(compgen -e 2>/dev/null | tr '\n' ' ') "
for _gaai_key in $_GAAI_CONFIG_ALLOW; do
  case "$_GAAI_EXPORTED_SET" in
    *" $_gaai_key "*) ;;
    *) continue ;;
  esac
  _gaai_val="${!_gaai_key}"
  # A validated scalar: no newline, no NUL, no control character, bounded length.
  case "$_gaai_val" in
    *$'\n'*|*$'\r'*|*$'\t'*) _gaai_entry_refuse "entry_role=config_not_scalar:${_gaai_key}" ;;
  esac
  if [[ "${#_gaai_val}" -gt 4096 ]]; then
    _gaai_entry_refuse "entry_role=config_oversized:${_gaai_key}"
  fi
done
unset -v _gaai_key _gaai_val _GAAI_EXPORTED_SET
# The survivors after `_GAAI_CONFIG_ALLOW` are either interpreter/session identity
# or values this entry SET itself (sections 7, 7b, 7c). Naming one here never admits
# an environment value: every hostile inherited entry was refused in sections 3-5,
# and each entry-owned survivor was assigned unconditionally above.
for _gaai_name in $(compgen -e 2>/dev/null || true); do
  case " $_GAAI_CONFIG_ALLOW PATH HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME TMPDIR LC_ALL LANG SHELL TERM USER LOGNAME UID EUID PWD SHLVL GH_TOKEN GAAI_FORGE_IDENTITY GAAI_FORGE_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_CONFIG_DIR GH_HOST GIT_TERMINAL_PROMPT GIT_ASKPASS GH_PROMPT_DISABLED GIT_CONFIG_GLOBAL GAAI_LAUNCH_SCOPE " in
    *" $_gaai_name "*) ;;
    *) export -n "$_gaai_name" 2>/dev/null || true ;;
  esac
done
unset -v _gaai_name
# END GAAI-ENTRY-AUTHORITY

# ── Roots ─────────────────────────────────────────────────────────────────
#
# In child mode the launcher is a private copy living in the attempt directory, so
# its own location says nothing about where the framework assets are. The verified
# asset root is transmitted immutably in the attempt manifest and EVERY child-mode
# asset read is re-rooted there — never at the launcher's own path and never at the
# mutable main checkout.

_GAAI_CHILD_MODE=0
_GAAI_CHILD_ATTEMPT_DIR=""
if [[ "${1:-}" == "--daemon-child" ]]; then
  _GAAI_CHILD_MODE=1
  _GAAI_CHILD_ATTEMPT_DIR="${2:-}"
fi

if [[ "$_GAAI_CHILD_MODE" -eq 1 ]]; then
  if [[ -z "$_GAAI_CHILD_ATTEMPT_DIR" || ! -r "$_GAAI_CHILD_ATTEMPT_DIR/manifest" ]]; then
    printf 'daemon-start[child]: reason=process_authority_invalid action=operator_disposition_required evidence=manifest_absent\n' >&2
    exit 1
  fi
  _GAAI_CHILD_HOME="$(sed -n 's/^home=//p' "$_GAAI_CHILD_ATTEMPT_DIR/manifest" 2>/dev/null | head -1)"
  _GAAI_CHILD_REPO="$(sed -n 's/^repo_root=//p' "$_GAAI_CHILD_ATTEMPT_DIR/manifest" 2>/dev/null | head -1)"
  if [[ -z "$_GAAI_CHILD_HOME" || ! -d "$_GAAI_CHILD_HOME/.gaai/core/scripts" ]]; then
    printf 'daemon-start[child]: reason=home_asset_invalid action=operator_disposition_required evidence=asset_root_unresolved\n' >&2
    exit 1
  fi
  SCRIPT_DIR="$_GAAI_CHILD_HOME/.gaai/core/scripts"
  CORE_DIR="$_GAAI_CHILD_HOME/.gaai/core"
  GAAI_DIR="$_GAAI_CHILD_HOME/.gaai"
  PROJECT_ROOT="${_GAAI_CHILD_REPO:-$_GAAI_CHILD_HOME}"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
  GAAI_DIR="$(cd "$CORE_DIR/.." && pwd -P)"
  PROJECT_ROOT="$(cd "$GAAI_DIR/.." && pwd -P)"
fi
# The operator's real repo checkout. Exported so the daemon — even when its binary runs from
# GAAI_DAEMON_HOME (the dedicated daemon home worktree) — anchors BOTH the per-story worktree base
# (delivery-daemon.sh REPO_ROOT, else it falls back to PROJECT_DIR=home and nests) AND its
# operator-facing state (logs/locks/retry/drift), so the monitor + `--logs` keep working.
export GAAI_REPO_ROOT="$PROJECT_ROOT"

# Repository-scoped worktree root (#3176). Operators can keep worktrees outside the
# canonical checkout — and outside a synchronized folder — by setting this once. It
# is an allowlisted configuration entry, so an operator value survives the entry
# normalization above and is validated as a scalar like every other one.
if [[ -z "${GAAI_WORKTREES_BASE:-}" ]]; then
  GAAI_WORKTREES_BASE="$(cd "$PROJECT_ROOT/.." && pwd -P)/.gaai-worktrees/$(basename "$PROJECT_ROOT")"
fi
export GAAI_WORKTREES_BASE

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) printf 'daemon-start: reason=process_authority_invalid action=none evidence=platform_unsupported\n' >&2; exit 1 ;;
esac

# Operator-facing state stays in the operator's REAL checkout even when the daemon
# binary and assets come from the home, so the monitor and `--logs` keep working.
_STATE_GAAI_DIR="$PROJECT_ROOT/.gaai"
LOCK_DIR="$_STATE_GAAI_DIR/project/contexts/backlog/.delivery-locks"
PID_FILE="$LOCK_DIR/.daemon.pid"
LOG_FILE="$_STATE_GAAI_DIR/project/contexts/backlog/.delivery-daemon.log"
LOG_DIR="$_STATE_GAAI_DIR/project/contexts/backlog/.delivery-logs"
MONITOR_TOP="$SCRIPT_DIR/daemon-monitor-top.sh"
MONITOR_TAIL="$SCRIPT_DIR/daemon-monitor-tail.sh"

# Drain timeout for --stop. Wrappers may be mid-phase; the drain is a grace period
# after which we escalate to an exact, persisted-identity tmux kill.
STOP_DRAIN_TIMEOUT="${GAAI_STOP_DRAIN_TIMEOUT:-600}"
# Grace a TERMed phase agent gets before SIGKILL, and again for its wrapper to
# finish handling that exit (preserving the interrupted work) before the wrapper
# itself is escalated. 30s covers the agent chain's own TERM->KILL windows (the
# impl `timeout --kill-after` is 15s, the loop-breaker watchdog 10s) with margin
# for a final commit. A containment bound, not a quality gate: configurable.
STOP_AGENT_GRACE="${GAAI_STOP_AGENT_GRACE:-30}"
[[ "$STOP_AGENT_GRACE" =~ ^[0-9]+$ ]] || STOP_AGENT_GRACE=30
TARGET_BRANCH="${GAAI_TARGET_BRANCH:-staging}"
DAEMON_REL=".gaai/core/scripts/delivery-daemon.sh"
START_REL=".gaai/core/scripts/daemon-start.sh"

# shellcheck source=lib/home-branch-guard.sh
[[ -z "${_GAAI_HOME_BRANCH_GUARD_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/home-branch-guard.sh" && _GAAI_HOME_BRANCH_GUARD_SH_SOURCED=1
# shellcheck source=lib/daemon-home.sh
[[ -z "${_GAAI_DAEMON_HOME_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/daemon-home.sh" && _GAAI_DAEMON_HOME_SH_SOURCED=1

if ! declare -F _gaai_home_verify >/dev/null 2>&1 \
    || ! declare -F _gaai_home_lock_acquire >/dev/null 2>&1; then
  printf 'daemon-start: reason=process_authority_invalid action=operator_disposition_required evidence=home_library_unavailable\n' >&2
  exit 1
fi
# The former runtime provisioner must not exist in this process. Its presence
# would mean a stale library is loaded and startup could still repair the home.
if declare -F _gaai_provision_daemon_home >/dev/null 2>&1; then
  printf 'daemon-start: reason=process_authority_invalid action=operator_disposition_required evidence=runtime_provisioner_present\n' >&2
  exit 1
fi

refuse() { _gaai_home_refuse "$@" || exit 1; }

# ── Durable lifecycle state ───────────────────────────────────────────────
#
# One owner record per physical repository, under the physical Git common
# directory, so a second checkout can never join or clobber this lifecycle. State
# advances pending -> bound -> running; every transition is written durably and
# reread before it is treated as fact.

LIFECYCLE_ROOT=""
OWNER_FILE=""
LAUNCH_ROOT=""

_lifecycle_init() {
  local _common_dir="$1"
  LIFECYCLE_ROOT="$_common_dir/gaai-daemon-lifecycle"
  OWNER_FILE="$LIFECYCLE_ROOT/owner"
  LAUNCH_ROOT="$LIFECYCLE_ROOT/launch"
}

_owner_field() {
  local _file="$1" _key="$2"
  [[ -r "$_file" ]] || return 1
  sed -n "s/^${_key}=//p" "$_file" 2>/dev/null | head -1
}

# A record is well-formed only with the current schema and a known state. Anything
# else is corrupt evidence, never an absent owner.
_owner_state() {
  local _schema _state
  [[ -r "$OWNER_FILE" ]] || { printf 'none'; return 0; }
  _schema="$(_owner_field "$OWNER_FILE" schema)"
  _state="$(_owner_field "$OWNER_FILE" state)"
  if [[ "$_schema" != "$GAAI_HOME_SCHEMA" ]]; then printf 'corrupt'; return 0; fi
  case "$_state" in
    pending|bound|running) printf '%s' "$_state" ;;
    *) printf 'corrupt' ;;
  esac
}

_owner_write() {
  _gaai_home_write_durable "$OWNER_FILE" "$1"
}

# ── Private tmux process authority ────────────────────────────────────────
#
# The ONLY authoritative process backend on macOS and Linux. The socket lives in a
# short, physical, host-stable root owned by this UID at mode 0700, derived from
# the physical common directory — never from the normalized child TMPDIR — and its
# complete physical path is length-checked before any tmux effect. Ambient TMUX,
# TMUX_PANE and TMUX_TMPDIR were already refused at entry.

TMUX_SOCKET=""
TMUX_SESSION=""

_tmux() { tmux -f /dev/null -S "$TMUX_SOCKET" "$@"; }

_socket_prepare() {
  local _common_dir="$1" _root
  _root="$(_gaai_home_socket_root)"
  if [[ -e "$_root" && -L "$_root" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "socket_role=root_symlink"; return 1
  fi
  mkdir -p "$_root" 2>/dev/null || { _gaai_home_refuse process_authority_invalid 1 "socket_role=root_uncreatable"; return 1; }
  chmod 0700 "$_root" 2>/dev/null || true
  _gaai_home_socket_root_ok "$_root" || return 1
  TMUX_SOCKET="$(_gaai_home_socket_path "$_common_dir")" || return 1
  TMUX_SESSION="gaai-daemon-$(_gaai_home_label "$_common_dir")"
  return 0
}

# The required options must hold on the private server BEFORE any session exists,
# and a server started empty with the default `exit-empty on` exits immediately —
# so the options cannot be applied after `start-server`. They are supplied as a
# fixed, private, non-injectable server config read at server start instead.
GAAI_TMUX_CONF_BODY='set -g exit-empty off
set -wg remain-on-exit on'

_tmux_write_conf() {
  local _path="$1"
  ( umask 077; printf '%s\n' "$GAAI_TMUX_CONF_BODY" > "$_path" ) 2>/dev/null || return 1
  chmod 0600 "$_path" 2>/dev/null || true
  return 0
}

# Start the private server and prove the required options hold on it, before any
# session is created. Returns non-zero without leaving a usable server otherwise.
_tmux_start_server_verified() {
  local _sock="$1" _conf="$2" _waited=0
  tmux -f "$_conf" -S "$_sock" start-server 2>/dev/null || return 1
  while [[ ! -S "$_sock" && "$_waited" -lt 10 ]]; do sleep 1; _waited=$(( _waited + 1 )); done
  [[ -S "$_sock" ]] || return 1
  [[ "$(tmux -f /dev/null -S "$_sock" show-options -g -v exit-empty 2>/dev/null)" == "off" ]] || return 1
  [[ "$(tmux -f /dev/null -S "$_sock" show-options -g -v remain-on-exit 2>/dev/null)" == "on" ]] || return 1
  return 0
}

# Real capability probe. The 3.2 floor is nominal; what admits the backend is that
# this tmux actually supports the options and formats the lifecycle depends on. The
# probe runs in an isolated namespace and leaves no production lifecycle artifact.
_tmux_capability_ok() {
  local _v _probe_sock _conf _rc=0
  _v="$(tmux -V 2>/dev/null || echo "")"
  [[ -n "$_v" ]] || { _gaai_home_refuse process_authority_invalid 0 "tmux_role=absent"; return 1; }
  _probe_sock="$GAAI_PRIVATE_ROOT/tmp/probe.$$"
  if [[ "${#_probe_sock}" -ge "$(_gaai_home_socket_limit)" ]]; then
    _gaai_home_refuse process_authority_invalid 0 "tmux_role=probe_path_too_long"; return 1
  fi
  _conf="$GAAI_PRIVATE_ROOT/tmp/probe-conf.$$"
  _tmux_write_conf "$_conf" || _rc=1
  [[ "$_rc" -eq 0 ]] && { _tmux_start_server_verified "$_probe_sock" "$_conf" || _rc=1; }
  if [[ "$_rc" -eq 0 ]]; then
    tmux -f /dev/null -S "$_probe_sock" new-session -d -s gaai-probe -e GAAI_PROBE=1 \
      'exec /bin/sh -c "exit 0"' 2>/dev/null || _rc=1
    tmux -f /dev/null -S "$_probe_sock" list-panes -t '=gaai-probe' \
      -F '#{pane_id} #{pane_pid} #{pane_dead}' >/dev/null 2>&1 || _rc=1
    tmux -f /dev/null -S "$_probe_sock" display-message -p '#{pid}' >/dev/null 2>&1 || _rc=1
  fi
  tmux -f /dev/null -S "$_probe_sock" kill-server 2>/dev/null || true
  rm -f "$_probe_sock" "$_conf" 2>/dev/null || true
  if [[ "$_rc" -ne 0 ]]; then
    _gaai_home_refuse process_authority_invalid 0 "tmux_role=capability_probe_failed"
    return 1
  fi
  return 0
}

_server_pid() {
  local _p
  _p="$(_tmux display-message -p '#{pid}' 2>/dev/null || echo "")"
  [[ -n "$_p" ]] || return 1
  printf '%s' "$_p"
}

# Exhaustive, no-create enumeration of the private server. `has-session` would
# create nothing but also tells us nothing about foreign sessions; the reconciler
# needs the whole list.
_server_sessions() {
  _tmux list-sessions -F '#{session_name}' 2>/dev/null || true
}

_pane_field() {
  local _field="$1"
  _tmux list-panes -t "=$TMUX_SESSION" -F "#{${_field}}" 2>/dev/null | head -1 || true
}

# ── Daemon child mode ─────────────────────────────────────────────────────
#
# Entered as `exec <env> -u <entry-owned names> <launcher> --daemon-child
# <attempt_dir>` from the fixed pane command. The launcher is a private, byte-exact
# materialization of the fetched target's own `daemon-start.sh`, so this code path
# is never sourced from mutable main-checkout bytes. Both `exec`s preserve the PID,
# which is why pane_pid == launcher_ack.pid == ready_ack.pid holds all the way to
# the daemon. The `env -u` strip exists because the parent entry exported its
# section 7c non-interactive git/gh values and this entry's section 4 would refuse
# them as inherited GIT_* members; the child re-sets them itself.

_child_refuse() {
  local _attempt_dir="$1" _evidence="$2"
  # A refusal reachable before the forge secret's own unlink step (:1013) must not
  # leave a 0600 plaintext credential behind in the attempt directory; this is
  # best-effort and safe to attempt unconditionally since the file may not exist.
  rm -f "$_attempt_dir/forge.cred" 2>/dev/null || true
  printf 'daemon-start[child]: reason=process_authority_invalid action=operator_disposition_required evidence=%s\n' \
    "$_evidence" >&2
  _gaai_home_write_durable "$_attempt_dir/ack.child_failed" "evidence=$_evidence" 2>/dev/null || true
  exit 1
}

# Bound-descriptor identity, per platform. Through /proc/self/fd/N (Linux) the
# magic link resolves to the open description's file, so inode AND device must
# both match the proven pathname. Through /dev/fd/N (Darwin's fdesc filesystem)
# stat(2) on the node reports the bound file's inode but fdesc's OWN device
# number, so the device is not comparable there by construction; identity is
# then the inode plus the digest read from the descriptor itself (daemon) or the
# inode plus the encoder round-trip of the sourced bytes (secret) — both of which
# the caller already requires. Measured on Darwin: /dev/fd/9 ino == file ino,
# /dev/fd/9 dev == fdesc dev != file dev.
_child_fd_identity_matches() {
  local _fd_path="$1" _f_ino="$2" _f_dev="$3" _p_ino="$4" _p_dev="$5"
  [[ "$_f_ino" == "$_p_ino" ]] || return 1
  case "$_fd_path" in
    /proc/*) [[ "$_f_dev" == "$_p_dev" ]] || return 1 ;;
    *)       [[ "$(uname -s)" == "Darwin" ]] || { [[ "$_f_dev" == "$_p_dev" ]] || return 1; } ;;
  esac
  return 0
}

do_daemon_child() {
  local _attempt_dir="${1:-}"
  [[ -n "$_attempt_dir" && -d "$_attempt_dir" ]] || _child_refuse "${_attempt_dir:-/nonexistent}" "attempt_dir_absent"

  local _manifest="$_attempt_dir/manifest"
  [[ -r "$_manifest" ]] || _child_refuse "$_attempt_dir" "manifest_absent"

  local _schema _attempt _home _daemon_digest _cred_mode _release _repo_root _target_sha _forge_mode _forge_secret _forge_manifest_identity
  _schema="$(_owner_field "$_manifest" schema)"
  _attempt="$(_owner_field "$_manifest" attempt)"
  _home="$(_owner_field "$_manifest" home)"
  _daemon_digest="$(_owner_field "$_manifest" daemon_digest)"
  _cred_mode="$(_owner_field "$_manifest" credential_mode)"
  _release="$(_owner_field "$_manifest" release_digest)"
  _forge_mode="$(_owner_field "$_manifest" forge_mode)"
  _forge_secret="$(_owner_field "$_manifest" forge_secret)"
  _forge_manifest_identity="$(_owner_field "$_manifest" forge_identity)"
  case "$_forge_mode" in present|absent) ;; *) _child_refuse "$_attempt_dir" "forge_role=mode_invalid" ;; esac
  local _LIFECYCLE_ROOT_FOR_TRACE; _LIFECYCLE_ROOT_FOR_TRACE="$(dirname "$(dirname "$_attempt_dir")")"
  _repo_root="$(_owner_field "$_manifest" repo_root)"
  _target_sha="$(_owner_field "$_manifest" target_sha)"
  [[ "$_schema" == "$GAAI_HOME_SCHEMA" ]] || _child_refuse "$_attempt_dir" "manifest_schema_mismatch"
  [[ -n "$_attempt" && -n "$_home" && -n "$_daemon_digest" && -n "$_release" ]] \
    || _child_refuse "$_attempt_dir" "manifest_incomplete"
  case "$_cred_mode" in absent|present) ;; *) _child_refuse "$_attempt_dir" "credential_mode_invalid" ;; esac

  local _pid=$$ _inc
  _inc="$(_gaai_home_incarnation "$_pid" 2>/dev/null || echo "")"
  [[ -n "$_inc" ]] || _child_refuse "$_attempt_dir" "incarnation_unprovable"

  # 1. Bind the long-running executable to a descriptor, refusing a symlink before
  #    the open so the descriptor can only ever be the proven regular file. The
  #    descriptor is low-numbered, so it survives the final exec by construction —
  #    bash does not set close-on-exec on fds it is told to open explicitly.
  local _daemon_path="$_home/$DAEMON_REL"
  [[ -L "$_daemon_path" ]] && _child_refuse "$_attempt_dir" "daemon_role=symlink"
  [[ -f "$_daemon_path" ]] || _child_refuse "$_attempt_dir" "daemon_role=absent"
  local _p_ino _p_dev
  _p_ino="$(_gaai_home_stat_field '%i' "$_daemon_path")" || _child_refuse "$_attempt_dir" "daemon_role=stat_unavailable"
  _p_dev="$(_gaai_home_stat_field '%d' "$_daemon_path")" || _child_refuse "$_attempt_dir" "daemon_role=stat_unavailable"
  exec 9< "$_daemon_path" || _child_refuse "$_attempt_dir" "daemon_role=unopenable"

  local _fd_path="/dev/fd/9"
  [[ -r "/proc/self/fd/9" ]] && _fd_path="/proc/self/fd/9"
  local _f_ino _f_dev _f_digest
  _f_ino="$(_gaai_home_stat_field '%i' "$_fd_path")" || _child_refuse "$_attempt_dir" "daemon_role=fd_stat_unavailable"
  _f_dev="$(_gaai_home_stat_field '%d' "$_fd_path")" || _child_refuse "$_attempt_dir" "daemon_role=fd_stat_unavailable"
  _child_fd_identity_matches "$_fd_path" "$_f_ino" "$_f_dev" "$_p_ino" "$_p_dev" \
    || _child_refuse "$_attempt_dir" "daemon_role=fd_identity_mismatch"
  _f_digest="$(_gaai_home_digest_file "$_fd_path")" || _child_refuse "$_attempt_dir" "daemon_role=fd_digest_unavailable"
  [[ "$_f_digest" == "$_daemon_digest" ]] || _child_refuse "$_attempt_dir" "daemon_role=fd_blob_mismatch"
  _gaai_home_trace "$_LIFECYCLE_ROOT_FOR_TRACE" "$_attempt" "daemon_digest_proven"

  # 2. Credential mode is explicit and immutable for the attempt.
  local _secret_ino="" _secret_dev="" _secret_bound=0 _secret_expected_word=""
  if [[ "$_cred_mode" == "present" ]]; then
    local _secret_path
    _secret_path="$(_owner_field "$_manifest" secret)"
    [[ -n "$_secret_path" ]] || _child_refuse "$_attempt_dir" "secret_path_absent"
    [[ -L "$_secret_path" ]] && _child_refuse "$_attempt_dir" "secret_role=symlink"
    [[ -f "$_secret_path" ]] || _child_refuse "$_attempt_dir" "secret_role=absent"
    local _s_ino _s_dev _s_mode
    _s_ino="$(_gaai_home_stat_field '%i' "$_secret_path")" || _child_refuse "$_attempt_dir" "secret_role=stat_unavailable"
    _s_dev="$(_gaai_home_stat_field '%d' "$_secret_path")" || _child_refuse "$_attempt_dir" "secret_role=stat_unavailable"
    _s_mode="$(_gaai_home_stat_field '%a' "$_secret_path")" || _child_refuse "$_attempt_dir" "secret_role=stat_unavailable"
    [[ "$_s_mode" == "600" ]] || _child_refuse "$_attempt_dir" "secret_role=mode_open"
    # Grammar-validate through the PATH before binding, so the bound descriptor is
    # never read here and its offset stays at zero for the later source. A source
    # that reads nothing cannot be mistaken for a successful one.
    local _lines _first
    _lines="$(wc -l < "$_secret_path" 2>/dev/null | tr -d ' ')"
    [[ "$_lines" == "1" ]] || _child_refuse "$_attempt_dir" "secret_role=grammar_line_count"
    _first="$(head -1 "$_secret_path" 2>/dev/null || echo "")"
    case "$_first" in
      "export GAAI_IMPL_AUTH_TOKEN="?*) ;;
      *) _child_refuse "$_attempt_dir" "secret_role=grammar_assignment" ;;
    esac
    # A raw-metacharacter scan would be WRONG here: the fixed encoder is
    # `printf %q`, whose output legitimately contains backslash-escaped `;`, `$(`
    # and backticks. What must be proven is that the remainder is exactly that
    # encoder's output for the value it assigns — which step 6 does exactly, after
    # the source, by re-encoding the sourced scalar and requiring byte equality.
    # Here we only reject what no %q output can ever contain.
    case "$_first" in
      *$'\x01'*|*$'\x02'*|*$'\x1b'*|*$'\r'*) _child_refuse "$_attempt_dir" "secret_role=grammar_control_character" ;;
    esac
    _secret_expected_word="${_first#export GAAI_IMPL_AUTH_TOKEN=}"
    [[ -n "$_secret_expected_word" ]] || _child_refuse "$_attempt_dir" "secret_role=grammar_empty_word"
    exec 8< "$_secret_path" || _child_refuse "$_attempt_dir" "secret_role=unopenable"
    local _sfd_path="/dev/fd/8"
    [[ -r "/proc/self/fd/8" ]] && _sfd_path="/proc/self/fd/8"
    local _sf_ino _sf_dev
    _sf_ino="$(_gaai_home_stat_field '%i' "$_sfd_path")" || _child_refuse "$_attempt_dir" "secret_role=fd_stat_unavailable"
    _sf_dev="$(_gaai_home_stat_field '%d' "$_sfd_path")" || _child_refuse "$_attempt_dir" "secret_role=fd_stat_unavailable"
    _child_fd_identity_matches "$_sfd_path" "$_sf_ino" "$_sf_dev" "$_s_ino" "$_s_dev" \
      || _child_refuse "$_attempt_dir" "secret_role=fd_identity_mismatch"
    # Unlink the pathname and fsync the parent: from here the token exists only as
    # this descriptor. Unlinked bytes are not claimed to be forensically erased.
    rm -f "$_secret_path" 2>/dev/null || _child_refuse "$_attempt_dir" "secret_role=unlink_failed"
    _gaai_home_fsync "$(dirname "$_secret_path")"
    [[ -e "$_secret_path" ]] && _child_refuse "$_attempt_dir" "secret_role=still_linked"
    _secret_ino="$_sf_ino"; _secret_dev="$_sf_dev"; _secret_bound=1
  else
    # Canonical absent mode: prove no credential entered this child at all.
    [[ -n "${GAAI_IMPL_AUTH_TOKEN+set}" ]] && _child_refuse "$_attempt_dir" "credential_role=absent_mode_variable_present"
    [[ -e "$_attempt_dir/secret.env" ]] && _child_refuse "$_attempt_dir" "credential_role=absent_mode_artefact_present"
  fi

  # 3. Open the release barrier BEFORE acknowledging, so the controller's write can
  #    never be lost between the ack and the wait.
  # The forge identity is validated and BOUND here, and consumed only after the
  # release record is matched below. Binding before the barrier is what lets the
  # file be unlinked while its bytes stay reachable through this descriptor alone.
  local _forge_bound=0 _forge_expected_identity="" _forge_expected_token_digest="" _forge_ino="" _forge_dev=""
  if [[ "$_forge_mode" == "present" ]]; then
    [[ -n "$_forge_secret" ]] || _child_refuse "$_attempt_dir" "forge_role=path_absent"
    [[ -L "$_forge_secret" ]] && _child_refuse "$_attempt_dir" "forge_role=symlink"
    [[ -f "$_forge_secret" ]] || _child_refuse "$_attempt_dir" "forge_role=absent"
    local _g_ino _g_dev _g_mode
    _g_ino="$(_gaai_home_stat_field '%i' "$_forge_secret")" || _child_refuse "$_attempt_dir" "forge_role=stat_unavailable"
    _g_dev="$(_gaai_home_stat_field '%d' "$_forge_secret")" || _child_refuse "$_attempt_dir" "forge_role=stat_unavailable"
    _g_mode="$(_gaai_home_stat_field '%a' "$_forge_secret")" || _child_refuse "$_attempt_dir" "forge_role=stat_unavailable"
    [[ "$_g_mode" == "600" ]] || _child_refuse "$_attempt_dir" "forge_role=mode_open"
    # Grammar/charset-validate through the PATH before binding — plain DATA, never
    # shell, never sourced — so the bound descriptor is never read here and its
    # offset stays at zero for the later, sole authoritative read (step 6b).
    local _gnlines=0 _gl1="" _gl2="" _gln=""
    while IFS= read -r _gln || [[ -n "$_gln" ]]; do
      _gnlines=$(( _gnlines + 1 ))
      case "$_gnlines" in 1) _gl1="$_gln" ;; 2) _gl2="$_gln" ;; esac
      [[ "$_gnlines" -ge 3 ]] && break
    done < "$_forge_secret" 2>/dev/null
    [[ "$_gnlines" == "2" ]] || _child_refuse "$_attempt_dir" "forge_role=grammar_line_count"
    case "$_gl1" in identity=*) ;; *) _child_refuse "$_attempt_dir" "forge_role=grammar_assignment" ;; esac
    case "$_gl2" in token=*) ;; *) _child_refuse "$_attempt_dir" "forge_role=grammar_assignment" ;; esac
    _forge_expected_identity="${_gl1#identity=}"
    local _gtoken="${_gl2#token=}"
    if [[ ! "$_forge_expected_identity" =~ ^[A-Za-z0-9._-]+$ || ! "$_gtoken" =~ ^[A-Za-z0-9._-]+$ ]]; then
      _child_refuse "$_attempt_dir" "forge_role=grammar_charset"
    fi
    [[ "$_forge_expected_identity" == "$_forge_manifest_identity" ]] \
      || _child_refuse "$_attempt_dir" "forge_role=manifest_identity_mismatch"
    _forge_expected_token_digest="$(_gaai_home_digest_string "$_gtoken")"
    unset -v _gnlines _gl1 _gl2 _gln _gtoken
    exec 5< "$_forge_secret" || _child_refuse "$_attempt_dir" "forge_role=unopenable"
    local _gfd_path="/dev/fd/5"
    [[ -r "/proc/self/fd/5" ]] && _gfd_path="/proc/self/fd/5"
    local _gf_ino _gf_dev
    _gf_ino="$(_gaai_home_stat_field '%i' "$_gfd_path")" || _child_refuse "$_attempt_dir" "forge_role=fd_stat_unavailable"
    _gf_dev="$(_gaai_home_stat_field '%d' "$_gfd_path")" || _child_refuse "$_attempt_dir" "forge_role=fd_stat_unavailable"
    _child_fd_identity_matches "$_gfd_path" "$_gf_ino" "$_gf_dev" "$_g_ino" "$_g_dev" \
      || _child_refuse "$_attempt_dir" "forge_role=fd_identity_mismatch"
    rm -f "$_forge_secret" 2>/dev/null || _child_refuse "$_attempt_dir" "forge_role=unlink_failed"
    _gaai_home_fsync "$(dirname "$_forge_secret")"
    [[ -e "$_forge_secret" ]] && _child_refuse "$_attempt_dir" "forge_role=still_linked"
    _forge_ino="$_gf_ino"; _forge_dev="$_gf_dev"; _forge_bound=1
    _gaai_home_trace "$_LIFECYCLE_ROOT_FOR_TRACE" "$_attempt" "forge_bound"
  fi

  exec 7< "$_attempt_dir/release.fifo" || _child_refuse "$_attempt_dir" "release_role=fifo_unopenable"

  # 4. Acknowledge the exact identities. Only now may the controller record `bound`.
  _gaai_home_write_durable "$_attempt_dir/ack.launcher" \
"schema=$GAAI_HOME_SCHEMA
attempt=$_attempt
pid=$_pid
incarnation=$_inc
credential_mode=$_cred_mode
forge_mode=$_forge_mode
forge_identity=$_forge_expected_identity
daemon_ino=$_f_ino
daemon_dev=$_f_dev
daemon_digest=$_f_digest
secret_ino=$_secret_ino
secret_dev=$_secret_dev
launch_scope=${GAAI_LAUNCH_SCOPE:-}" \
    || _child_refuse "$_attempt_dir" "ack_launcher_undurable"

  # 5. Block on the barrier. Invalid, partial, oversized or EOF data never releases.
  local _record=""
  IFS= read -r -t 300 _record <&7 || _child_refuse "$_attempt_dir" "release_role=read_failed_or_eof"
  exec 7<&-
  # RECOMPUTED from the manifest fields and matched against the controller's record,
  # never against the manifest's own release_digest: a writer that alters the admitted
  # home, the forge mode or any other bound field produces a value the record cannot
  # match. The record arrives over a FIFO this controller alone writes.
  local _recomputed
  _recomputed="$(_gaai_home_digest_string "${_schema}|${_attempt}|${_daemon_digest}|${_cred_mode}|${_forge_mode}|${_home}|${_forge_expected_identity}|${_forge_expected_token_digest}")" \
    || _child_refuse "$_attempt_dir" "release_role=digest_unavailable"
  [[ "$_record" == "release attempt=$_attempt digest=$_recomputed" ]] \
    || _child_refuse "$_attempt_dir" "release_role=record_mismatch"

  # 6. Source the bound secret descriptor — its first and only read, at offset zero.
  if [[ "$_secret_bound" -eq 1 ]]; then
    local _sfd_path="/dev/fd/8"
    [[ -r "/proc/self/fd/8" ]] && _sfd_path="/proc/self/fd/8"
    . "$_sfd_path" || _child_refuse "$_attempt_dir" "secret_role=source_failed"
    # A no-op source cannot pass: the variable must now hold a non-empty scalar.
    [[ -n "${GAAI_IMPL_AUTH_TOKEN:-}" ]] || _child_refuse "$_attempt_dir" "secret_role=source_noop"
    # Exactly-one-assignment proof: re-encoding the sourced scalar with the same
    # fixed encoder must reproduce the validated word byte for byte. A file holding
    # a second statement, an unquoted expansion or a different scalar cannot satisfy
    # this, so the assignment that ran is provably the one that was validated.
    if [[ "$(printf '%q' "$GAAI_IMPL_AUTH_TOKEN")" != "$_secret_expected_word" ]]; then
      unset -v GAAI_IMPL_AUTH_TOKEN
      _child_refuse "$_attempt_dir" "secret_role=encoder_round_trip_mismatch"
    fi
    export GAAI_IMPL_AUTH_TOKEN
    exec 8<&-
  fi

  # 6b. The forge identity, consumed only now — past the descriptor identity proof and
  #     past the controller's release record. Its first and only READ (never sourced,
  #     never eval'd) is at offset zero. The gitconfig helper the shared entry block
  #     already installed points at the fixed, secret-free helper script; it becomes
  #     correct the moment these two variables are exported, with no further write.
  if [[ "$_forge_bound" -eq 1 ]]; then
    local _gfd_path="/dev/fd/5"
    [[ -r "/proc/self/fd/5" ]] && _gfd_path="/proc/self/fd/5"
    local _rnlines=0 _rl1="" _rl2="" _rln=""
    while IFS= read -r _rln || [[ -n "$_rln" ]]; do
      _rnlines=$(( _rnlines + 1 ))
      case "$_rnlines" in 1) _rl1="$_rln" ;; 2) _rl2="$_rln" ;; esac
      [[ "$_rnlines" -ge 3 ]] && break
    done < "$_gfd_path" 2>/dev/null
    exec 5<&-
    [[ "$_rnlines" == "2" ]] || _child_refuse "$_attempt_dir" "forge_role=read_line_count"
    case "$_rl1" in identity=*) ;; *) _child_refuse "$_attempt_dir" "forge_role=read_grammar" ;; esac
    case "$_rl2" in token=*) ;; *) _child_refuse "$_attempt_dir" "forge_role=read_grammar" ;; esac
    local _r_identity="${_rl1#identity=}" _r_token="${_rl2#token=}"
    if [[ ! "$_r_identity" =~ ^[A-Za-z0-9._-]+$ || ! "$_r_token" =~ ^[A-Za-z0-9._-]+$ ]]; then
      _child_refuse "$_attempt_dir" "forge_role=read_charset"
    fi
    [[ "$_r_identity" == "$_forge_expected_identity" ]] \
      || _child_refuse "$_attempt_dir" "forge_role=identity_mismatch"
    # Exactly-one-assignment proof, adapted to plain data: the digest of what was
    # actually read must match the digest computed from the pre-bind grammar pass.
    if [[ "$(_gaai_home_digest_string "$_r_token")" != "$_forge_expected_token_digest" ]]; then
      unset -v _r_token
      _child_refuse "$_attempt_dir" "forge_role=token_digest_mismatch"
    fi
    GAAI_FORGE_IDENTITY="$_r_identity"
    GAAI_FORGE_TOKEN="$_r_token"
    GH_TOKEN="$_r_token"
    export GAAI_FORGE_IDENTITY GAAI_FORGE_TOKEN GH_TOKEN
    unset -v _r_identity _r_token _rl1 _rl2 _rln _rnlines
    _gaai_home_trace "$_LIFECYCLE_ROOT_FOR_TRACE" "$_attempt" "forge_released"
  fi

  # 7. Hand the exact identities to the daemon and execute the ALREADY-BOUND
  #    descriptor. No pathname is reopened: on Linux /proc/self/fd/9 resolves to the
  #    open description's inode, on Darwin /dev/fd/9 duplicates the descriptor, so a
  #    pathname replaced after step 1 cannot be what runs.
  export GAAI_DAEMON_LAUNCH_ATTEMPT="$_attempt_dir"
  export GAAI_DAEMON_LAUNCH_PID="$_pid"
  export GAAI_DAEMON_LAUNCH_INCARNATION="$_inc"
  export GAAI_DAEMON_CREDENTIAL_MODE="$_cred_mode"
  export GAAI_DAEMON_HOME="$_home"
  export GAAI_REPO_ROOT="$_repo_root"
  export GAAI_TARGET_SHA="$_target_sha"

  local _args_file="$_attempt_dir/args" _dargs=()
  if [[ -r "$_args_file" ]]; then
    while IFS= read -r _a; do [[ -n "$_a" ]] && _dargs+=("$_a"); done < "$_args_file"
  fi

  local _bash_abs="${BASH:-/bin/bash}"
  [[ -x "$_bash_abs" ]] || _child_refuse "$_attempt_dir" "daemon_role=interpreter_unavailable"
  _gaai_home_trace "$_LIFECYCLE_ROOT_FOR_TRACE" "$_attempt" "daemon_exec"
  exec "$_bash_abs" "$_fd_path" ${_dargs[@]+"${_dargs[@]}"}
}

if [[ "${1:-}" == "--daemon-child" ]]; then
  shift
  do_daemon_child "${1:-}"
  exit 1
fi

# ── Argument parsing ──────────────────────────────────────────────────────

ACTION="start"
NO_DRAIN=false
NO_MONITOR="${GAAI_DAEMON_NO_MONITOR:-}"
PASSTHROUGH_ARGS=()

_print_help() { sed -n '/^# Description:/,/^# ═══.*═══$/{ /^# ═══.*═══$/d; p; }' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)      ACTION="start";   shift ;;
    --stop)       ACTION="stop";    shift ;;
    --status)     ACTION="status";  shift ;;
    --monitor)    ACTION="monitor"; shift ;;
    --restart)    ACTION="restart"; shift ;;
    --no-drain)   NO_DRAIN=true;    shift ;;
    --no-monitor) NO_MONITOR=1;     shift ;;
    --help|-h)    _print_help; exit 0 ;;
    # A closed, validated passthrough grammar. These reach the daemon through the
    # attempt's `args` file, never through the fixed pane command, so no operator
    # input can extend or reshape what tmux executes.
    --max-concurrent|--interval|--exit-when-idle)
      case "${2:-}" in
        ''|*[!0-9]*) refuse process_authority_invalid 0 "arg_role=non_numeric:${1#--}" ;;
      esac
      PASSTHROUGH_ARGS+=("$1" "$2"); shift 2 ;;
    --dry-run)    PASSTHROUGH_ARGS+=("$1"); shift ;;
    *) refuse process_authority_invalid 0 "arg_role=unsupported" ;;
  esac
done

# ── Wrapper drain (unchanged authority; orthogonal to the home boundary) ──

_list_live_wrappers() {
  local lock pid sid
  [[ -d "$LOCK_DIR" ]] || return 0
  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    pid=$(head -1 "$lock" 2>/dev/null || echo "")
    [[ -z "$pid" || "$pid" == "pending" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    sid=$(basename "$lock" .lock)
    echo "${sid}|${pid}"
  done
}

# ── Phase-agent reaping ────────────────────────────────────────────────────
#
# A wrapper's phase agent does not die with the wrapper. `timeout` leads a
# process group of its own and the node spawner starts the model CLI in a new
# session, so neither the pane hangup of `tmux kill-session` nor a SIGKILL of the
# wrapper pid reaches it: the chain is reparented to init and keeps writing to
# the Story worktree after the stop has reported success.
#
# The dispatch library records each agent as `<sid>.agent.pid` (pid + start
# stamp). That record is the only way an agent is found here — never a command
# line pattern — and the stamp is re-proven immediately before every signal, so
# a reused pid is never signalled. A record that cannot be proven (no stamp, or
# the live stamp unreadable) is left in place and not acted on.

# Prints `sid|pid|stamp` for each recorded agent whose identity still holds.
# Records whose process provably ended (pid gone, or pid reused under another
# start stamp) are settled and removed.
_list_live_agents() {
  local rec sid apid astamp now
  [[ -d "$LOCK_DIR" ]] || return 0
  for rec in "$LOCK_DIR"/*.agent.pid; do
    [[ -f "$rec" ]] || continue
    sid=$(basename "$rec" .agent.pid)
    apid=$(head -1 "$rec" 2>/dev/null || echo "")
    astamp=$(sed -n 's/^incarnation=//p' "$rec" 2>/dev/null | head -1) || astamp=""
    [[ "$apid" =~ ^[1-9][0-9]*$ && "$apid" -gt 1 && "$apid" != "$$" ]] || continue
    if ! kill -0 "$apid" 2>/dev/null; then
      rm -f "$rec" 2>/dev/null || true
      continue
    fi
    [[ -n "$astamp" ]] || continue
    now=$(_gaai_home_incarnation_fixed "$apid" 2>/dev/null || echo "")
    [[ -n "$now" ]] || continue
    if [[ "$now" != "$astamp" ]]; then
      rm -f "$rec" 2>/dev/null || true
      continue
    fi
    printf '%s|%s|%s\n' "$sid" "$apid" "$astamp"
  done
  return 0
}

# _signal_agent <SIG> <pid> <stamp> — signal one recorded agent after re-proving
# its identity. An agent that leads its own process group (`timeout` does) is
# signalled as a group, which is exactly its own subtree; otherwise the pid alone
# is signalled, so a group shared with a wrapper is never hit.
_signal_agent() {
  local sig="$1" apid="$2" astamp="$3" now pgid
  now=$(_gaai_home_incarnation_fixed "$apid" 2>/dev/null || echo "")
  [[ -n "$now" && "$now" == "$astamp" ]] || return 1
  pgid=$(ps -o pgid= -p "$apid" 2>/dev/null | tr -d ' ') || pgid=""
  if [[ "$pgid" == "$apid" ]]; then
    kill -"$sig" -- "-$apid" 2>/dev/null || true
  else
    kill -"$sig" "$apid" 2>/dev/null || true
  fi
  return 0
}

# TERM every live recorded agent, give them STOP_AGENT_GRACE to exit on their
# own (the TERM path lets an agent finish its last write and lets its wrapper
# observe the executor exit), then SIGKILL whatever is still proven live.
_reap_phase_agents() {
  local entries sid apid astamp waited=0
  entries=$(_list_live_agents)
  [[ -n "$entries" ]] || return 0
  while IFS='|' read -r sid apid astamp; do
    [[ -n "$sid" && -n "$apid" ]] || continue
    echo "  SIGTERM phase agent of $sid (PID $apid)"
    _signal_agent TERM "$apid" "$astamp" || true
  done <<< "$entries"
  while (( waited < STOP_AGENT_GRACE )); do
    [[ -z "$(_list_live_agents)" ]] && { echo "  Phase agents exited after ${waited}s."; return 0; }
    sleep 1
    waited=$(( waited + 1 ))
  done
  entries=$(_list_live_agents)
  while IFS='|' read -r sid apid astamp; do
    [[ -n "$sid" && -n "$apid" ]] || continue
    echo "  SIGKILL phase agent of $sid (PID $apid) — no exit within ${STOP_AGENT_GRACE}s"
    _signal_agent KILL "$apid" "$astamp" || true
  done <<< "$entries"
}

_drain_wrappers() {
  local entries
  entries=$(_list_live_wrappers)
  if [[ -z "$entries" ]]; then
    echo "  No live wrappers to drain."
    # A wrapper that already died (crash, earlier kill) can have left its agent
    # running; with no wrapper left to wait for, it is reaped now.
    _reap_phase_agents
    return 0
  fi
  local count
  count=$(echo "$entries" | wc -l | tr -d ' ')
  echo "Draining $count in-flight wrapper(s) — SIGTERM, waiting up to ${STOP_DRAIN_TIMEOUT}s..."
  while IFS='|' read -r sid pid; do
    [[ -z "$sid" || -z "$pid" ]] && continue
    echo "  SIGTERM $sid (PID $pid)"
    kill -TERM "$pid" 2>/dev/null || true
  done <<< "$entries"
  local waited=0 step=5
  while (( waited < STOP_DRAIN_TIMEOUT )); do
    [[ -z "$(_list_live_wrappers)" ]] && { echo "  All wrappers exited cleanly after ${waited}s."; _reap_phase_agents; return 0; }
    sleep "$step"
    waited=$(( waited + step ))
  done
  # A wrapper's SIGTERM only asks it to stop after the current phase, and Bash
  # defers the trap until the phase's foreground command returns — a phase can
  # outlast the drain by hours. End the phase agents first, while their wrappers
  # are still alive: each wrapper then sees its executor exit and runs its normal
  # failure handling, which commits the interrupted work, and exits at the next
  # loop boundary because its interrupt flag is already set.
  echo "  Drain timeout (${STOP_DRAIN_TIMEOUT}s) reached. Ending in-flight phase agents first..."
  _reap_phase_agents
  waited=0
  while (( waited < STOP_AGENT_GRACE )); do
    [[ -z "$(_list_live_wrappers)" ]] && { echo "  All wrappers exited after their phase agent ended."; _reap_phase_agents; return 0; }
    sleep 1
    waited=$(( waited + 1 ))
  done
  echo "  Wrappers still live after ${STOP_AGENT_GRACE}s. Escalating to exact tmux kill-session..."
  local stragglers
  stragglers=$(_list_live_wrappers)
  while IFS='|' read -r sid pid; do
    [[ -z "$sid" || -z "$pid" ]] && continue
    if [[ -n "$TMUX_SOCKET" ]] && _tmux has-session -t "=gaai-deliver-${sid}" 2>/dev/null; then
      echo "  tmux kill-session gaai-deliver-${sid} (PID $pid)"
      _tmux kill-session -t "=gaai-deliver-${sid}" 2>/dev/null || true
    else
      echo "  SIGTERM PID $pid (no session for $sid on the private server)"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done <<< "$stragglers"
  sleep 30
  local final
  final=$(_list_live_wrappers)
  if [[ -n "$final" ]]; then
    while IFS='|' read -r sid pid; do
      [[ -z "$sid" || -z "$pid" ]] && continue
      echo "  SIGKILL $sid (PID $pid)"
      kill -KILL "$pid" 2>/dev/null || true
    done <<< "$final"
  fi
  # Anything a straggler launched after the first reap, or that survived it,
  # would otherwise outlive the wrapper that owned it.
  _reap_phase_agents
}

# ── Shared bootstrap: identity, lock, socket ──────────────────────────────
#
# A short-lived, read-only main-checkout bootstrap is explicitly permitted here —
# resolving the common directory, acquiring authority and materializing the
# exact-target child is all it does. It never coordinates, claims or invokes models.

COMMON_DIR=""
_bootstrap_identity() {
  COMMON_DIR="$(_gaai_home_common_dir "$PROJECT_ROOT" 2>/dev/null || echo "")"
  [[ -n "$COMMON_DIR" ]] || refuse home_identity_invalid 1 "common_dir_unresolved"
  _lifecycle_init "$COMMON_DIR"
  _socket_prepare "$COMMON_DIR" || exit 1
}

_release_and_exit() { _gaai_home_lock_release; exit "${1:-1}"; }

# Reclaim a launch scope named in the durable owner record — the settled/stopped
# side of the same invariant the entry-block trap enforces on a clean exit. Bounded
# to a path this repository's own record actually names, under this process's own
# private scope root; never a guess, never another lifecycle's directory.
#
# With an <expected_pid> argument, this is the ownership-gated form: a scope
# under the account-wide "$GAAI_PRIVATE_ROOT/scope/" is only ever removed when
# it is provably named by that expected invocation (see _owner_scope_state).
# With no argument, behavior is byte-identical to before — every existing
# unconditional caller is unaffected.
_gaai_reclaim_owner_scope() {
  local _expected_pid="${1:-}"
  [[ -r "$OWNER_FILE" ]] || return 0
  local _rec_scope
  _rec_scope="$(_owner_field "$OWNER_FILE" launch_scope 2>/dev/null || true)"
  if [[ -n "$_expected_pid" ]]; then
    case "$(_owner_scope_state "$_expected_pid" "$_rec_scope")" in
      owned) rm -rf "$_rec_scope" 2>/dev/null || true; return 0 ;;
      absent) return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [[ -n "$_rec_scope" && -d "$_rec_scope" && ! -L "$_rec_scope" \
        && "$_rec_scope" == "$GAAI_PRIVATE_ROOT/scope/"* ]]; then
    rm -rf "$_rec_scope" 2>/dev/null || true
  fi
  return 0
}

# Read-only scope-ownership prover. The account-wide scope root ($GAAI_PRIVATE_ROOT/scope, shared by every invocation on
# this UID) makes a bare textual-prefix test insufficient: a recorded launch_scope
# could name a directory another live invocation is using. The scope's own naming
# contract (`l.$$.$RANDOM`, entry block :323) is the ownership evidence — for a
# launched daemon, that $$ IS the recorded child_pid (proven at bind time, :1827).
#
# Prints exactly one of: absent | foreign | owned. Never mutates anything.
_owner_scope_state() {
  local _expected_pid="$1" _scope="$2"
  [[ -n "$_scope" ]] || { printf 'absent'; return 0; }
  [[ -d "$_scope" && ! -L "$_scope" ]] || { printf 'absent'; return 0; }
  case "$_scope" in
    "$GAAI_PRIVATE_ROOT/scope/"*) ;;
    *) printf 'foreign'; return 0 ;;
  esac
  local _base="${_scope##*/}"
  case "$_base" in
    l."$_expected_pid".*) printf 'owned' ;;
    *) printf 'foreign' ;;
  esac
}

# Revalidate a recorded owner from durable evidence alone. Prints the verdict:
#   live      — the exact socket/server/session/pane/incarnation all still hold
#   settled   — the record describes a lifecycle that provably ended
#   ambiguous — evidence is missing, partial or contradictory
_owner_verdict() {
  local _state _sock _sess _pane_pid _pane_inc _srv_pid _srv_inc
  _state="$(_owner_state)"
  case "$_state" in
    none)    printf 'settled'; return 0 ;;
    corrupt) printf 'ambiguous'; return 0 ;;
  esac
  _sock="$(_owner_field "$OWNER_FILE" socket)"
  _sess="$(_owner_field "$OWNER_FILE" session)"
  [[ "$_sock" == "$TMUX_SOCKET" && "$_sess" == "$TMUX_SESSION" ]] || { printf 'ambiguous'; return 0; }
  if [[ ! -S "$_sock" ]]; then
    # No server socket. A `pending` record with no server is a controller that died
    # before the first tmux effect — settled, and safely re-attemptable.
    [[ "$_state" == "pending" ]] && { printf 'settled'; return 0; }
    printf 'ambiguous'; return 0
  fi
  _srv_pid="$(_server_pid 2>/dev/null || echo "")"
  [[ -n "$_srv_pid" ]] || { printf 'ambiguous'; return 0; }
  _srv_inc="$(_owner_field "$OWNER_FILE" server_incarnation)"
  if [[ -n "$_srv_inc" ]]; then
    local _now_inc
    _now_inc="$(_gaai_home_incarnation "$_srv_pid" 2>/dev/null || echo "")"
    [[ -n "$_now_inc" && "$_now_inc" == "$_srv_inc" ]] || { printf 'ambiguous'; return 0; }
  fi
  local _sessions
  _sessions="$(_server_sessions)"
  if [[ -z "$_sessions" ]]; then
    # An EMPTY private server is admissible only once its exact socket, server
    # identity and required options have been validated.
    local _ee _re
    _ee="$(_tmux show-options -g -v exit-empty 2>/dev/null || echo "")"
    _re="$(_tmux show-options -g -v remain-on-exit 2>/dev/null || echo "")"
    [[ "$_ee" == "off" && "$_re" == "on" ]] || { printf 'ambiguous'; return 0; }
    printf 'settled'; return 0
  fi
  # The session set on the private server must be EXACTLY ours. This socket is
  # digest-bound to this physical repository and only this controller ever creates a
  # session on it, so an extra session is unexplained evidence — checking merely that
  # ours is present would let a foreign session sit alongside it unnoticed.
  local _seen_ours=0 _extra=0 _line
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    if [[ "$_line" == "$_sess" ]]; then _seen_ours=1; else _extra=1; fi
  done <<< "$_sessions"
  if [[ "$_seen_ours" -ne 1 || "$_extra" -ne 0 ]]; then
    printf 'ambiguous'; return 0
  fi
  _pane_pid="$(_pane_field pane_pid)"
  [[ -n "$_pane_pid" ]] || { printf 'ambiguous'; return 0; }
  kill -0 "$_pane_pid" 2>/dev/null || { printf 'ambiguous'; return 0; }
  _pane_inc="$(_owner_field "$OWNER_FILE" pane_incarnation)"
  if [[ -n "$_pane_inc" ]]; then
    local _now_pane
    _now_pane="$(_gaai_home_incarnation "$_pane_pid" 2>/dev/null || echo "")"
    [[ -n "$_now_pane" && "$_now_pane" == "$_pane_inc" ]] || { printf 'ambiguous'; return 0; }
  fi
  printf 'live'
}

# Read-only Phase-A prover for a settlement disposal decision. `_owner_verdict` above stays
# the single liveness prover `do_start`/`do_status` consume — this does NOT re-derive
# liveness, byte-identical, untouched. It proves only what a `settled` verdict does
# not: the recorded child is provably dead, the observed private server IS the
# recorded server (PID + incarnation, closing the two gaps `_owner_verdict` leaves —
# no server_pid comparison, incarnation checked only when recorded), and the
# attempt directory + launch scope are provably owned by the recorded attempt/child
# — never a guess, never another lifecycle's or another sibling attempt's evidence.
#
# Caller-guaranteed precondition (A0): called only when `_owner_state` is one of
# pending|bound|running AND `_owner_verdict` already returned `settled` — `none`
# (settled before any evidence is read) and `corrupt` never reach this function.
#
# Performs NO destructive action: the only `kill` is `kill -0`. Prints exactly one
# of `proven` or a failure token; every failure token is AC1/AC5(e) evidence that
# the caller passes to `_gaai_home_refuse process_authority_invalid` — no new
# refusal reason, no new action (always `operator_disposition_required`).
_settled_disposal_verdict() {
  local _sock _sess _child_pid _srv_pid_rec _srv_inc_rec _attempt _attempt_dir
  local _observed_pid _observed_inc _rec_scope

  # A1 — identity already proven equal by _owner_verdict's own settled path, but
  # re-checked here directly from evidence rather than trusting a string result.
  _sock="$(_owner_field "$OWNER_FILE" socket)"
  _sess="$(_owner_field "$OWNER_FILE" session)"
  [[ "$_sock" == "$TMUX_SOCKET" && "$_sess" == "$TMUX_SESSION" ]] \
    || { printf 'owner_role=identity_drift_at_stop'; return 0; }

  # A2 — recorded child_pid must be present and well-formed. A `pending` record
  # carries no child_pid at all (written only at the `bound` transition, :1879), so
  # this is what makes a pending-with-empty-server input refuse (founder F16).
  _child_pid="$(_owner_field "$OWNER_FILE" child_pid)"
  if [[ -z "$_child_pid" ]]; then
    printf 'settlement_role=child_evidence_absent'; return 0
  fi
  if [[ ! "$_child_pid" =~ ^[1-9][0-9]*$ ]]; then
    printf 'settlement_role=child_evidence_malformed'; return 0
  fi

  # A3 — the recorded child must be provably dead before anything is disposed of.
  if kill -0 "$_child_pid" 2>/dev/null; then
    printf 'settlement_role=child_persisted'; return 0
  fi

  # A4 — recorded server identity must be complete. Startup itself permits an empty
  # incarnation (:1764 in the pre-patch numbering), so this conjunct is what makes
  # that historical gap non-authorizing for disposal specifically.
  _srv_pid_rec="$(_owner_field "$OWNER_FILE" server_pid)"
  _srv_inc_rec="$(_owner_field "$OWNER_FILE" server_incarnation)"
  if [[ -z "$_srv_pid_rec" || ! "$_srv_pid_rec" =~ ^[1-9][0-9]*$ || -z "$_srv_inc_rec" ]]; then
    printf 'settlement_role=server_evidence_incomplete'; return 0
  fi

  # A5 — the observed server on the recorded socket must BE the recorded server.
  # `_owner_verdict` never makes this comparison; this closes that gap without
  # touching `_owner_verdict` itself.
  _observed_pid="$(_server_pid 2>/dev/null || echo "")"
  [[ -n "$_observed_pid" ]] || { printf 'settlement_role=server_unobservable'; return 0; }
  [[ "$_observed_pid" == "$_srv_pid_rec" ]] \
    || { printf 'settlement_role=server_identity_drift'; return 0; }

  # A6 — and its incarnation must match, unconditionally (not "only if recorded").
  _observed_inc="$(_gaai_home_incarnation "$_observed_pid" 2>/dev/null || echo "")"
  [[ -n "$_observed_inc" && "$_observed_inc" == "$_srv_inc_rec" ]] \
    || { printf 'settlement_role=server_identity_drift'; return 0; }

  # A7 — the attempt directory must be provably the exact one this record names,
  # never a sibling's. A bare textual-prefix test cannot distinguish a sibling
  # attempt under the same $LAUNCH_ROOT; exact-name equality can.
  _attempt="$(_owner_field "$OWNER_FILE" attempt)"
  _attempt_dir="$(_owner_field "$OWNER_FILE" attempt_dir)"
  if [[ -z "$_attempt" || "$_attempt" == *"/"* || "$_attempt" == "." || "$_attempt" == ".." ]]; then
    printf 'attempt_role=ownership_unproven'; return 0
  fi
  if [[ "$_attempt_dir" != "$LAUNCH_ROOT/$_attempt" ]]; then
    printf 'attempt_role=ownership_unproven'; return 0
  fi
  if [[ -e "$_attempt_dir" ]] && { [[ -L "$_attempt_dir" ]] || [[ ! -d "$_attempt_dir" ]]; }; then
    printf 'attempt_role=ownership_unproven'; return 0
  fi

  # A8 — the launch scope, if any, must be owned by the recorded child (never a
  # guess over the account-wide scope root shared by every invocation on this UID).
  _rec_scope="$(_owner_field "$OWNER_FILE" launch_scope)"
  case "$(_owner_scope_state "$_child_pid" "$_rec_scope")" in
    owned|absent) ;;
    *) printf 'scope_role=ownership_unproven'; return 0 ;;
  esac

  printf 'proven'
}

# ── Start ─────────────────────────────────────────────────────────────────

do_start() {
  _bootstrap_identity
  _gaai_home_lock_acquire "$COMMON_DIR" || exit 1
  trap '_gaai_home_lock_release; _gaai_launch_scope_cleanup' EXIT INT TERM

  # A second start under the same lock revalidates the persisted identities and
  # returns `already_running` without mutating the home or launching anything.
  local _verdict
  _verdict="$(_owner_verdict)"
  case "$_verdict" in
    live)
      _gaai_home_refuse already_running 0 "session_role=live" || true
      _release_and_exit 1 ;;
    ambiguous)
      _gaai_home_refuse process_authority_invalid 1 "owner_role=ambiguous" || true
      _release_and_exit 1 ;;
    settled)
      # A settled record may still name a launch scope from a controller or child
      # that crashed before its own EXIT trap (or, for the child, before its exec
      # handoff ever had a trap to run) could reclaim it. Reclaim is bounded to the
      # exact recorded path under this repository's own private scope root — never
      # a guess, never another lifecycle's evidence.
      _gaai_reclaim_owner_scope ;;
  esac

  # Forge identity gate. A launch admits its own operator identity HERE, only after
  # the single-owner verdict above has already ruled out `live` and `ambiguous` —
  # never at entry time (section 7b only DEFINES _gaai_admit_forge_identity; see
  # that function's own comment). This is before tmux capability, before any home
  # fetch, before an attempt directory, launcher, session or daemon exists, so no
  # target-selected code ever starts and no remote operation is ever attempted
  # without it — and no other invocation on the account ever reaches this call.
  # `absent` refuses like every other non-`ok` verdict: a host whose only forge
  # credential is an interactive CLI login has none to admit (Story Notes — an
  # accepted outcome, not a regression). The diagnostic carries the verdict alone,
  # never a token, a token digest, a credential pathname or a remote URL.
  _gaai_admit_forge_identity
  _gaai_home_trace "$LIFECYCLE_ROOT" "-" "forge_admitted"
  if [[ "${_GAAI_FORGE_VERDICT:-absent}" != "ok" ]]; then
    mkdir -p "$LIFECYCLE_ROOT" 2>/dev/null || true
    chmod 0700 "$LIFECYCLE_ROOT" 2>/dev/null || true
    _gaai_home_write_durable "$LIFECYCLE_ROOT/refusal" \
"reason=forge_identity_unadmitted
action=provision_forge_credential
evidence=forge_role=${_GAAI_FORGE_VERDICT:-absent}" 2>/dev/null || true
    _gaai_home_refuse forge_identity_unadmitted 0 "forge_role=${_GAAI_FORGE_VERDICT:-absent}" || true
    _release_and_exit 1
  fi

  _tmux_capability_ok || _release_and_exit 1

  GAAI_DAEMON_HOME="${GAAI_DAEMON_HOME:-${GAAI_WORKTREES_BASE}/__daemon-home}"
  export GAAI_DAEMON_HOME

  # Observation 1 — the target SHA observed during provisioning (AC1/AC3). This is
  # runtime observation evidence only; it grants no provision or update authority.
  local _sha1
  _sha1="$(_gaai_home_fetch_target "$PROJECT_ROOT" "$TARGET_BRANCH")" || _release_and_exit 1

  _gaai_home_verify "$GAAI_DAEMON_HOME" "$TARGET_BRANCH" "$PROJECT_ROOT" "$_sha1" || _release_and_exit 1

  local _daemon_digest _launcher_digest
  _daemon_digest="$(_gaai_home_verify_asset "$GAAI_DAEMON_HOME" "$DAEMON_REL" "$_sha1")" || _release_and_exit 1
  _launcher_digest="$(_gaai_home_verify_asset "$GAAI_DAEMON_HOME" "$START_REL" "$_sha1")" || _release_and_exit 1

  # Observation 2 — immediately before the first new runtime effect for this
  # attempt. A target that advanced between the two reads is a race, not a
  # refresh: nothing is launched against a home that is no longer exact-current.
  local _sha2
  _sha2="$(_gaai_home_fetch_target "$PROJECT_ROOT" "$TARGET_BRANCH")" || _release_and_exit 1
  if [[ "$_sha2" != "$_sha1" ]]; then
    _gaai_home_refuse target_advanced 0 "target_role=advanced_between_observations" || true
    _release_and_exit 1
  fi
  _gaai_home_verify "$GAAI_DAEMON_HOME" "$TARGET_BRANCH" "$PROJECT_ROOT" "$_sha1" || _release_and_exit 1
  _gaai_home_verify_asset "$GAAI_DAEMON_HOME" "$DAEMON_REL" "$_sha1" >/dev/null || _release_and_exit 1

  # Credential mode: explicit, immutable for the attempt, and canonical when the
  # token is absent — the public OSS default creates no secret path, file,
  # descriptor or assignment and leaves the variable unset in every descendant.
  local _cred_mode="absent"
  [[ -n "${GAAI_IMPL_AUTH_TOKEN:-}" ]] && _cred_mode="present"

  # Forge identity mode. The gate above already called _gaai_admit_forge_identity
  # and refused any launch whose verdict was not `ok`, resolving the operator's
  # dedicated forge credential under the OPERATOR's home, which only this
  # controller has. The child re-runs the entry block under the private home and
  # never calls that function itself (it would find nothing there by construction
  # even if it did), so the identity has to travel this attempt's own bound
  # channel — never re-derived, always the exact identity admitted above for THIS
  # launch.
  local _forge_mode="present"
  local _forge_identity="$_GAAI_FORGE_IDENTITY"

  local _attempt _attempt_dir
  _attempt="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  _attempt_dir="$LAUNCH_ROOT/$_attempt"
  _gaai_home_trace "$LIFECYCLE_ROOT" "$_attempt" "entry_credential_admitted"
  local _forge_token_digest
  _forge_token_digest="$(_gaai_home_digest_string "$_GAAI_FORGE_TOKEN")"
  local _release_digest
  # The admitted home, forge mode, forge identity and a digest of the forge token
  # join the digest — never the token itself. A writer of the attempt directory
  # that rewrites the home, either forge field or the token produces a value this
  # controller's release record cannot match, and the child recomputes rather
  # than trusting the file. The token digest exists only in this process's
  # memory and in the release record below — it is never written to the
  # manifest, the owner record, an ack, the trace or a diagnostic.
  _release_digest="$(_gaai_home_digest_string "${GAAI_HOME_SCHEMA}|${_attempt}|${_daemon_digest}|${_cred_mode}|${_forge_mode}|${GAAI_DAEMON_HOME}|${_forge_identity}|${_forge_token_digest}")"
  _gaai_home_trace "$LIFECYCLE_ROOT" "$_attempt" "target_proven"

  # `pending` is durable BEFORE any launch directory, credential file or launcher
  # exists, so a controller crash here can never leave an unexplained artefact.
  mkdir -p "$LIFECYCLE_ROOT" 2>/dev/null || refuse home_lock_failed 1 "lifecycle_root_uncreatable"
  chmod 0700 "$LIFECYCLE_ROOT" 2>/dev/null || true
  if [[ -e "$_attempt_dir" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "attempt_role=directory_present" || true
    _release_and_exit 1
  fi
  _owner_write "schema=$GAAI_HOME_SCHEMA
state=pending
attempt=$_attempt
label=$(_gaai_home_label "$COMMON_DIR")
socket=$TMUX_SOCKET
session=$TMUX_SESSION
target_sha=$_sha1
home=$GAAI_DAEMON_HOME
daemon_digest=$_daemon_digest
launcher_digest=$_launcher_digest
credential_mode=$_cred_mode" || { _gaai_home_refuse home_lock_failed 1 "pending_undurable" || true; _release_and_exit 1; }
  [[ "$(_owner_state)" == "pending" ]] || { _gaai_home_refuse home_lock_failed 1 "pending_reread_failed" || true; _release_and_exit 1; }

  # Only now: the private 0700 launch directory and the exact-target launcher.
  ( umask 077; mkdir -p "$_attempt_dir" ) 2>/dev/null \
    || { _gaai_home_refuse process_authority_invalid 1 "attempt_role=uncreatable" || true; _release_and_exit 1; }
  chmod 0700 "$_attempt_dir" 2>/dev/null || true

  local _launcher="$_attempt_dir/launcher.sh"
  local _blob
  _blob="$(git -C "$GAAI_DAEMON_HOME" rev-parse "$_sha1:$START_REL" 2>/dev/null || echo "")"
  [[ -n "$_blob" ]] || { _gaai_home_refuse home_asset_invalid 0 "launcher_role=blob_unresolved" || true; _release_and_exit 1; }
  ( umask 077; git -C "$GAAI_DAEMON_HOME" cat-file blob "$_blob" > "$_launcher" ) 2>/dev/null \
    || { _gaai_home_refuse home_asset_invalid 1 "launcher_role=materialization_failed" || true; _release_and_exit 1; }
  chmod 0500 "$_launcher" 2>/dev/null || true
  local _have
  _have="$(_gaai_home_digest_file "$_launcher")" || { _gaai_home_refuse home_asset_invalid 1 "launcher_role=digest_unavailable" || true; _release_and_exit 1; }
  if [[ "$_have" != "$_launcher_digest" ]]; then
    _gaai_home_refuse home_asset_invalid 1 "launcher_role=materialized_mismatch" || true
    _release_and_exit 1
  fi
  _gaai_home_trace "$LIFECYCLE_ROOT" "$_attempt" "launcher_materialized"

  mkfifo -m 0600 "$_attempt_dir/release.fifo" 2>/dev/null \
    || { _gaai_home_refuse process_authority_invalid 1 "release_role=fifo_uncreatable" || true; _release_and_exit 1; }
  # Read-write open never blocks, so the child's own open succeeds immediately and
  # the barrier is the child's `read`, not its `open`.
  exec 6<> "$_attempt_dir/release.fifo" \
    || { _gaai_home_refuse process_authority_invalid 1 "release_role=fifo_unopenable" || true; _release_and_exit 1; }

  local _secret_path=""
  if [[ "$_cred_mode" == "present" ]]; then
    _secret_path="$_attempt_dir/secret.env"
    # O_EXCL via noclobber, 0600 via umask, no-follow because the private 0700
    # directory was just created empty and nothing else may write into it.
    ( set -C; umask 077; printf 'export GAAI_IMPL_AUTH_TOKEN=%q\n' "$GAAI_IMPL_AUTH_TOKEN" > "$_secret_path" ) 2>/dev/null \
      || { _gaai_home_refuse process_authority_invalid 1 "secret_role=uncreatable" || true; _release_and_exit 1; }
    chmod 0600 "$_secret_path" 2>/dev/null || true
  fi
  # The forge identity travels as plain, non-shell DATA — never a shell
  # assignment, never `source`d. O_EXCL through noclobber, 0600 through umask,
  # inside the 0700 directory just created empty.
  local _forge_path="$_attempt_dir/forge.cred"
  ( set -C; umask 077
    printf 'identity=%s\ntoken=%s\n' "$_forge_identity" "$_GAAI_FORGE_TOKEN" > "$_forge_path"
  ) 2>/dev/null \
    || { _gaai_home_refuse process_authority_invalid 1 "forge_role=uncreatable" || true; _release_and_exit 1; }
  chmod 0600 "$_forge_path" 2>/dev/null || true

  printf '%s\n' "schema=$GAAI_HOME_SCHEMA
attempt=$_attempt
home=$GAAI_DAEMON_HOME
repo_root=$PROJECT_ROOT
target_sha=$_sha1
daemon_digest=$_daemon_digest
launcher_digest=$_launcher_digest
credential_mode=$_cred_mode
secret=$_secret_path
forge_mode=$_forge_mode
forge_identity=$_forge_identity
forge_secret=$_forge_path
release_digest=$_release_digest" > "$_attempt_dir/manifest"
  : > "$_attempt_dir/args"
  local _a
  for _a in ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}; do printf '%s\n' "$_a" >> "$_attempt_dir/args"; done
  _gaai_home_fsync "$_attempt_dir"

  _owner_write "schema=$GAAI_HOME_SCHEMA
state=pending
attempt=$_attempt
label=$(_gaai_home_label "$COMMON_DIR")
socket=$TMUX_SOCKET
session=$TMUX_SESSION
target_sha=$_sha1
home=$GAAI_DAEMON_HOME
daemon_digest=$_daemon_digest
launcher_digest=$_launcher_digest
credential_mode=$_cred_mode
attempt_dir=$_attempt_dir
launcher=$_launcher" || { _gaai_home_refuse home_lock_failed 1 "pending_enrich_undurable" || true; _release_and_exit 1; }
  [[ "$(_owner_field "$OWNER_FILE" attempt_dir)" == "$_attempt_dir" ]] \
    || { _gaai_home_refuse home_lock_failed 1 "pending_enrich_reread_failed" || true; _release_and_exit 1; }

  echo "Starting GAAI Delivery Daemon..."
  echo "  Home:   $GAAI_DAEMON_HOME (exact at ${_sha1:0:12})"
  echo "  Log:    $LOG_FILE"
  mkdir -p "$LOG_DIR" "$LOCK_DIR" 2>/dev/null || true

  # First new tmux effect for this attempt. The required options are proven on the
  # exact private server before a session exists.
  local _tconf="$_attempt_dir/tmux.conf"
  _tmux_write_conf "$_tconf" || { _gaai_home_refuse process_authority_invalid 1 "tmux_role=conf_uncreatable" || true; _release_and_exit 1; }
  if ! _tmux_start_server_verified "$TMUX_SOCKET" "$_tconf"; then
    _gaai_home_refuse process_authority_invalid 0 "tmux_role=server_unstartable_or_options_unset" || true
    _release_and_exit 1
  fi
  local _srv_pid _srv_inc
  _srv_pid="$(_server_pid)" || { _gaai_home_refuse process_authority_invalid 1 "tmux_role=server_pid_unavailable" || true; _release_and_exit 1; }
  _srv_inc="$(_gaai_home_incarnation "$_srv_pid" 2>/dev/null || echo "")"

  # Non-secret session environment only. GAAI_IMPL_AUTH_TOKEN is never passed via
  # `-e`: that would place the token in the tmux client argv, visible to `ps`.
  local tmux_env_args=()
  [[ -n "${GAAI_CLAUDE_PROXY_BASE_URL:-}" ]] && tmux_env_args+=(-e "GAAI_CLAUDE_PROXY_BASE_URL=${GAAI_CLAUDE_PROXY_BASE_URL}")
  [[ -n "${GAAI_IMPL_BASE_URL:-}"   ]] && tmux_env_args+=(-e "GAAI_IMPL_BASE_URL=${GAAI_IMPL_BASE_URL}")
  [[ -n "${GAAI_IMPL_MODEL:-}"      ]] && tmux_env_args+=(-e "GAAI_IMPL_MODEL=${GAAI_IMPL_MODEL}")
  [[ -n "${GAAI_IMPL_MODEL_FALLBACK:-}" ]] && tmux_env_args+=(-e "GAAI_IMPL_MODEL_FALLBACK=${GAAI_IMPL_MODEL_FALLBACK}")
  [[ -n "${GAAI_AUTO_MERGE_POLICY:-}" ]] && tmux_env_args+=(-e "GAAI_AUTO_MERGE_POLICY=${GAAI_AUTO_MERGE_POLICY}")
  [[ -n "${GAAI_AUTO_MERGE_ADMIN_FALLBACK:-}" ]] && tmux_env_args+=(-e "GAAI_AUTO_MERGE_ADMIN_FALLBACK=${GAAI_AUTO_MERGE_ADMIN_FALLBACK}")
  [[ -n "${GAAI_DAEMON_EXECUTOR:-}" ]] && tmux_env_args+=(-e "GAAI_DAEMON_EXECUTOR=${GAAI_DAEMON_EXECUTOR}")
  [[ -n "${GAAI_CODEX_MODEL:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_MODEL=${GAAI_CODEX_MODEL}")
  [[ -n "${GAAI_CODEX_SANDBOX:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_SANDBOX=${GAAI_CODEX_SANDBOX}")
  [[ -n "${GAAI_CODEX_EPHEMERAL:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_EPHEMERAL=${GAAI_CODEX_EPHEMERAL}")
  [[ -n "${GAAI_CODEX_IGNORE_USER_CONFIG:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_IGNORE_USER_CONFIG=${GAAI_CODEX_IGNORE_USER_CONFIG}")
  [[ -n "${GAAI_DAEMON_HOME:-}" ]] && tmux_env_args+=(-e "GAAI_DAEMON_HOME=${GAAI_DAEMON_HOME}")
  [[ -n "${GAAI_REPO_ROOT:-}" ]] && tmux_env_args+=(-e "GAAI_REPO_ROOT=${GAAI_REPO_ROOT}")
  [[ -n "${GAAI_WORKTREES_BASE:-}" ]] && tmux_env_args+=(-e "GAAI_WORKTREES_BASE=${GAAI_WORKTREES_BASE}")
  [[ -n "${GAAI_CI_TEST_GATE_TIMEOUT_SEC:-}" ]] && tmux_env_args+=(-e "GAAI_CI_TEST_GATE_TIMEOUT_SEC=${GAAI_CI_TEST_GATE_TIMEOUT_SEC}")
  [[ -n "${GAAI_CI_TEST_GATE_MATERIALIZE_SEC:-}" ]] && tmux_env_args+=(-e "GAAI_CI_TEST_GATE_MATERIALIZE_SEC=${GAAI_CI_TEST_GATE_MATERIALIZE_SEC}")

  # The pane command is fixed. Operator input never reaches it.
  #
  # The child is this same privileged entry, and its section 4 refuses ANY inherited
  # GIT_* member — including the non-interactive values this process exported in
  # section 7c, which the private server hands to every pane it spawns (measured).
  # They are stripped through the attested `env` so the child observes no inherited
  # member and sets its own entry-owned copies. `env` execs the launcher, so
  # pane_pid == launcher_ack.pid still holds; nothing else in the pane changes.
  if ! _tmux new-session -d -s "$TMUX_SESSION" ${tmux_env_args[@]+"${tmux_env_args[@]}"} \
      "exec '$GAAI_ENV_CMD' -u GIT_TERMINAL_PROMPT -u GIT_ASKPASS -u GH_PROMPT_DISABLED -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GH_CONFIG_DIR -u GH_HOST -u GAAI_FORGE_IDENTITY -u GAAI_FORGE_TOKEN -u GIT_CONFIG_GLOBAL -u GAAI_LAUNCH_SCOPE '$_launcher' --daemon-child '$_attempt_dir'" 2>/dev/null; then
    _gaai_home_refuse process_authority_invalid 1 "tmux_role=session_uncreatable" || true
    _release_and_exit 1
  fi

  local _pane_id _pane_pid
  _pane_id="$(_pane_field pane_id)"
  _pane_pid="$(_pane_field pane_pid)"
  if [[ -z "$_pane_id" || -z "$_pane_pid" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "pane_role=identity_unavailable" || true
    _release_and_exit 1
  fi
  _gaai_home_trace "$LIFECYCLE_ROOT" "$_attempt" "child_started"

  # Wait for the child's exact acknowledgement. A missing or failed ack is never
  # retried with a second spawn — the evidence is preserved for reconciliation.
  local _waited=0 _ack="$_attempt_dir/ack.launcher"
  while [[ ! -f "$_ack" && "$_waited" -lt 60 ]]; do
    [[ -f "$_attempt_dir/ack.child_failed" ]] && break
    sleep 1; _waited=$(( _waited + 1 ))
  done
  if [[ ! -f "$_ack" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=launcher_absent" || true
    _release_and_exit 1
  fi
  local _ack_pid _ack_inc _ack_mode _ack_digest
  _ack_pid="$(_owner_field "$_ack" pid)"
  _ack_inc="$(_owner_field "$_ack" incarnation)"
  _ack_mode="$(_owner_field "$_ack" credential_mode)"
  local _ack_forge; _ack_forge="$(_owner_field "$_ack" forge_mode)"
  _ack_digest="$(_owner_field "$_ack" daemon_digest)"
  local _ack_scope; _ack_scope="$(_owner_field "$_ack" launch_scope)"
  if [[ "$_ack_pid" != "$_pane_pid" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=pane_pid_mismatch" || true
    _release_and_exit 1
  fi
  # Present-to-absent downgrade and absent-to-present fabrication both fail closed.
  if [[ "$_ack_mode" != "$_cred_mode" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=credential_mode_mismatch" || true
    _release_and_exit 1
  fi
  if [[ "$_ack_forge" != "$_forge_mode" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=forge_mode_mismatch" || true
    _release_and_exit 1
  fi
  if [[ "$_ack_digest" != "$_daemon_digest" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=daemon_digest_mismatch" || true
    _release_and_exit 1
  fi
  # The child's OWN scope (distinct from this launcher's, which its own trap
  # reclaims on exit) has no prior value here to match — only shape is provable:
  # it must be a real, non-symlink directory this repository's private root owns.
  if [[ -z "$_ack_scope" || ! -d "$_ack_scope" || -L "$_ack_scope" \
        || "$_ack_scope" != "$GAAI_PRIVATE_ROOT/scope/"* ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=launch_scope_invalid" || true
    _release_and_exit 1
  fi

  local _pane_inc
  _pane_inc="$(_gaai_home_incarnation "$_pane_pid" 2>/dev/null || echo "")"
  if [[ -n "$_pane_inc" && -n "$_ack_inc" && "$_pane_inc" != "$_ack_inc" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=incarnation_mismatch" || true
    _release_and_exit 1
  fi

  _owner_write "schema=$GAAI_HOME_SCHEMA
state=bound
attempt=$_attempt
label=$(_gaai_home_label "$COMMON_DIR")
socket=$TMUX_SOCKET
session=$TMUX_SESSION
target_sha=$_sha1
home=$GAAI_DAEMON_HOME
daemon_digest=$_daemon_digest
launcher_digest=$_launcher_digest
credential_mode=$_cred_mode
attempt_dir=$_attempt_dir
launcher=$_launcher
launch_scope=$_ack_scope
server_pid=$_srv_pid
server_incarnation=$_srv_inc
pane_id=$_pane_id
pane_pid=$_pane_pid
pane_incarnation=$_pane_inc
child_pid=$_ack_pid
child_incarnation=$_ack_inc" || { _gaai_home_refuse home_lock_failed 1 "bound_undurable" || true; _release_and_exit 1; }
  [[ "$(_owner_state)" == "bound" ]] || { _gaai_home_refuse home_lock_failed 1 "bound_reread_failed" || true; _release_and_exit 1; }

  # One verified release record, no larger than PIPE_BUF, on the authenticated FIFO
  # descriptor. FIFO durability is not claimed and the FIFO is never fsynced; the
  # record may be re-emitted idempotently after a durable `bound`.
  printf 'release attempt=%s digest=%s\n' "$_attempt" "$_release_digest" >&6
  exec 6>&-

  # `running` only after the daemon's own ready acknowledgement, from the same PID,
  # incarnation and credential mode.
  local _ready="$_attempt_dir/ack.ready"
  _waited=0
  while [[ ! -f "$_ready" && "$_waited" -lt 120 ]]; do
    [[ -f "$_attempt_dir/ack.child_failed" ]] && break
    sleep 1; _waited=$(( _waited + 1 ))
  done
  if [[ ! -f "$_ready" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=ready_absent" || true
    _release_and_exit 1
  fi
  local _r_pid _r_inc _r_mode
  _r_pid="$(_owner_field "$_ready" pid)"
  _r_inc="$(_owner_field "$_ready" incarnation)"
  _r_mode="$(_owner_field "$_ready" credential_mode)"
  if [[ "$_r_pid" != "$_ack_pid" || "$_r_mode" != "$_cred_mode" ]] \
      || { [[ -n "$_ack_inc" && -n "$_r_inc" ]] && [[ "$_r_inc" != "$_ack_inc" ]]; }; then
    _gaai_home_refuse process_authority_invalid 1 "ack_role=ready_identity_mismatch" || true
    _release_and_exit 1
  fi

  _owner_write "$(sed 's/^state=bound$/state=running/' "$OWNER_FILE")" \
    || { _gaai_home_refuse home_lock_failed 1 "running_undurable" || true; _release_and_exit 1; }
  [[ "$(_owner_state)" == "running" ]] || { _gaai_home_refuse home_lock_failed 1 "running_reread_failed" || true; _release_and_exit 1; }

  printf '%s\n' "$_ack_pid" > "$PID_FILE" 2>/dev/null || true
  echo "  PID:    $_ack_pid (private tmux session: $TMUX_SESSION)"
  echo "  Socket: $TMUX_SOCKET"
  echo "  Creds:  $_cred_mode"
  echo ""
  echo "✅ Daemon started."
  echo ""
  echo "  Status:  $SCRIPT_DIR/daemon-start.sh --status"
  echo "  Stop:    $SCRIPT_DIR/daemon-start.sh --stop"
  _launch_monitor
  _gaai_home_lock_release
  # Clear the lock-release trap (the lock is already released) but keep this
  # launcher's OWN scope reclaimed on exit — clearing the trap outright, as
  # before, would leak it silently.
  trap '_gaai_launch_scope_cleanup' EXIT INT TERM
  return 0
}

# ── Presentation UI (never authority, never evidence) ─────────────────────
#
# The monitor lives in a DISTINCT namespace — its own socket and session — so no
# presentation surface can ever be mistaken for, or interfere with, the private
# lifecycle server.

_monitor_socket() { printf '%s/%s-mon' "$(_gaai_home_socket_root)" "$(_gaai_home_label "$COMMON_DIR")"; }
_monitor_session() { printf 'gaai-monitor-%s' "$(_gaai_home_label "$COMMON_DIR")"; }

_launch_monitor() {
  if [[ "${NO_MONITOR:-}" == "true" || "${NO_MONITOR:-}" == "1" ]]; then
    echo "  Monitor: (auto-launch skipped — $SCRIPT_DIR/daemon-start.sh --monitor to attach manually)"
    return 0
  fi
  echo "  Monitor: $SCRIPT_DIR/daemon-start.sh --monitor"
  return 0
}

do_monitor() {
  _bootstrap_identity
  # The read-only lifecycle subprotocol completes FIRST; only then may a
  # presentation UI exist.
  do_status || true
  local _msock _msess
  _msock="$(_monitor_socket)"
  _msess="$(_monitor_session)"
  if [[ "${#_msock}" -ge "$(_gaai_home_socket_limit)" ]]; then
    refuse process_authority_invalid 0 "monitor_role=socket_path_too_long"
  fi
  if [[ ! -t 1 ]]; then
    echo "  (no terminal attached — presentation UI not created)"
    return 0
  fi
  if tmux -f /dev/null -S "$_msock" has-session -t "=$_msess" 2>/dev/null; then
    exec tmux -f /dev/null -S "$_msock" attach -t "=$_msess"
  fi
  local _config_file="$LOCK_DIR/.daemon-config"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  tmux -f /dev/null -S "$_msock" new-session -d -s "$_msess" \
    "'$MONITOR_TOP' '$_config_file' '$LOG_FILE'" 2>/dev/null || {
      echo "  (presentation UI unavailable)"; return 0; }
  # Resolve the home the pane should read from the same repository-scoped root, so
  # `--monitor` without a running daemon still finds the live backlog (#3176).
  local _monitor_home="${GAAI_DAEMON_HOME:-}"
  # Prefer the proven home recorded by a live lifecycle over any derived path.
  if [[ -z "$_monitor_home" && -n "${OWNER_FILE:-}" && -r "$OWNER_FILE" ]]; then
    local _owner_home
    _owner_home="$(_owner_field "$OWNER_FILE" home 2>/dev/null || echo "")"
    # A recorded home is only preferred while it still exists; a leftover record
    # naming a deleted path falls through to the guarded derivation below.
    [[ -n "$_owner_home" && -d "$_owner_home/.gaai/project/contexts/backlog" ]] && _monitor_home="$_owner_home"
  fi
  if [[ -z "$_monitor_home" && -d "${GAAI_WORKTREES_BASE}/__daemon-home/.gaai/project/contexts/backlog" ]]; then
    _monitor_home="${GAAI_WORKTREES_BASE}/__daemon-home"
  fi
  # The proven home also names the worktree root the live lifecycle actually used, and
  # the tail pane needs that root to resolve per-phase logs. It is NOT passed through
  # the environment: a pane created on an already-running tmux server inherits the
  # server's environment rather than this shell's, so an export here would not reach
  # it. The home is already an argument to that pane, and the pane derives the root
  # from it directly.
  tmux -f /dev/null -S "$_msock" split-window -t "=${_msess}:0" -v -p 60 \
    "'$MONITOR_TAIL' '$LOG_DIR' '$_monitor_home'" 2>/dev/null || true
  tmux -f /dev/null -S "$_msock" set-option -t "=$_msess" mouse on >/dev/null 2>&1 || true
  tmux -f /dev/null -S "$_msock" set-option -t "=$_msess" status-style "bg=colour236,fg=colour248" >/dev/null 2>&1 || true
  tmux -f /dev/null -S "$_msock" set-option -t "=$_msess" status-left "#[fg=colour214,bold] GAAI Delivery Monitor " >/dev/null 2>&1 || true
  exec tmux -f /dev/null -S "$_msock" attach -t "=$_msess"
}

# ── Status (read-only) ────────────────────────────────────────────────────

do_status() {
  [[ -n "$COMMON_DIR" ]] || _bootstrap_identity
  local _state _verdict
  _state="$(_owner_state)"
  _verdict="$(_owner_verdict)"
  echo "GAAI daemon lifecycle"
  echo "  repository:  $PROJECT_ROOT"
  echo "  socket:      $TMUX_SOCKET"
  echo "  session:     $TMUX_SESSION"
  echo "  state:       $_state"
  echo "  verdict:     $_verdict"
  if [[ "$_state" != "none" ]]; then
    echo "  attempt:     $(_owner_field "$OWNER_FILE" attempt)"
    echo "  target:      $(_owner_field "$OWNER_FILE" target_sha)"
    echo "  home:        $(_owner_field "$OWNER_FILE" home)"
    echo "  credentials: $(_owner_field "$OWNER_FILE" credential_mode)"
    echo "  daemon pid:  $(_owner_field "$OWNER_FILE" child_pid)"
  fi
  case "$_verdict" in
    live)      echo "  ✅ running" ;;
    settled)   echo "  ⏹  not running" ;;
    ambiguous) echo "  ⚠️  ambiguous — reason=process_authority_invalid action=operator_disposition_required" ;;
  esac
  return 0
}

# ── Stop ──────────────────────────────────────────────────────────────────
#
# Exact settlement. Cleanup targets ONLY the persisted socket/server/session and
# path-role identities — never an ambient or default tmux server. Kill or
# settlement uncertainty preserves the owner record, the session and the evidence,
# and blocks another launch rather than guessing.

# Phase B — acts ONLY after `_settled_disposal_verdict` has already
# returned `proven`; never re-derives any of its conjuncts. Mirrors the full
# live-stop path's own disposal ordering below (attempt artefacts by name -> rmdir
# proof -> scope reclaim -> owner/pid removal -> kill-server -> exact socket unlink
# -> rmdir LAUNCH_ROOT), with one deliberate omission: it never truncates
# $LOG_FILE (AC5d) — that would destroy the incident evidence that makes a
# settled-but-undisposed lifecycle diagnosable. Prints its own success/incomplete
# report and returns 0 (complete) or 1 (incomplete — evidence preserved, not a
# claim of success).
_dispose_settled_lifecycle() {
  local _sock _child_pid _attempt_dir _incomplete=0

  $NO_DRAIN || _drain_wrappers

  _attempt_dir="$(_owner_field "$OWNER_FILE" attempt_dir)"
  # Identical by-name artefact list to the full path below — never recursive; the
  # `rmdir` is the proof nothing unexplained was left behind (AC5f).
  if [[ -n "$_attempt_dir" && "$_attempt_dir" == "$LAUNCH_ROOT/"* && -d "$_attempt_dir" && ! -L "$_attempt_dir" ]]; then
    rm -f "$_attempt_dir"/launcher.sh "$_attempt_dir"/release.fifo "$_attempt_dir"/secret.env \
          "$_attempt_dir"/manifest "$_attempt_dir"/args "$_attempt_dir"/tmux.conf \
          "$_attempt_dir"/ack.launcher "$_attempt_dir"/ack.ready "$_attempt_dir"/ack.child_failed \
          "$_attempt_dir"/forge.cred \
          2>/dev/null || true
    if ! rmdir "$_attempt_dir" 2>/dev/null; then
      echo "  note: $_attempt_dir still holds unrecognised content and is preserved for inspection"
      _incomplete=1
    fi
  fi

  # Ownership-gated reclaim (the step-1 optional-argument form) — never the bare,
  # unconditional form the full path below still uses for ITS OWN distinct scope.
  _child_pid="$(_owner_field "$OWNER_FILE" child_pid)"
  _gaai_reclaim_owner_scope "$_child_pid"

  _sock="$(_owner_field "$OWNER_FILE" socket)"
  rm -f "$OWNER_FILE" 2>/dev/null || true
  rm -f "$PID_FILE" 2>/dev/null || true
  _tmux kill-server 2>/dev/null || true
  if [[ -n "$_sock" && "$_sock" == "$TMUX_SOCKET" && -e "$_sock" && ! -d "$_sock" ]]; then
    rm -f "$_sock" 2>/dev/null || true
  fi
  rmdir "$LAUNCH_ROOT" 2>/dev/null || true
  # $LOG_FILE is deliberately left alone on this path (AC5d) — no truncation here.

  if [[ "$_incomplete" -eq 1 ]]; then
    echo "  Settled lifecycle disposed of; attempt directory preserved for inspection. Log preserved."
    _gaai_home_refuse process_authority_invalid 1 "settlement_role=attempt_residual" || true
    return 1
  fi
  echo "✅ Settled lifecycle disposed of. Log preserved."
  return 0
}

do_stop() {
  _bootstrap_identity
  _gaai_home_lock_acquire "$COMMON_DIR" || exit 1
  trap '_gaai_home_lock_release; _gaai_launch_scope_cleanup' EXIT INT TERM

  local _state _verdict
  _state="$(_owner_state)"
  _verdict="$(_owner_verdict)"

  # A corrupt record names no settlement target, so there is nothing bounded to act
  # on; anything else — including an ambiguous or failed launch — is exactly what
  # `--stop` exists to dispose of, bounded to the persisted identities checked below.
  if [[ "$_state" == "corrupt" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "owner_role=corrupt_record" || true
    _release_and_exit 1
  fi

  # `state=none`: `_owner_verdict` returns `settled` here before reading anything
  # (socket/session/identity/options), so it proves nothing about a lifecycle ever
  # having existed. This path is untouched, byte-for-byte, by the disposal below.
  if [[ "$_state" == "none" ]]; then
    echo "No daemon running."
    rm -f "$PID_FILE" 2>/dev/null || true
    $NO_DRAIN || _drain_wrappers
    _gaai_home_lock_release; trap '_gaai_launch_scope_cleanup' EXIT INT TERM
    return 0
  fi

  # `state` is pending|bound|running (state=corrupt already returned above) and
  # `_owner_verdict` returned `settled` — a lifecycle that provably ended. Dispose
  # of it only once `_settled_disposal_verdict` has proven every conjunct
  # `_owner_verdict` does not cover; any other input preserves everything with a
  # typed `operator_disposition_required` refusal instead of the prior
  # "No daemon running." — a settled-but-undisposed lifecycle is not "no daemon".
  if [[ "$_verdict" == "settled" ]]; then
    local _dv
    _dv="$(_settled_disposal_verdict)"
    if [[ "$_dv" != "proven" ]]; then
      _gaai_home_refuse process_authority_invalid 1 "$_dv" || true
      _release_and_exit 1
    fi
    local _rc=0
    _dispose_settled_lifecycle || _rc=$?
    _gaai_home_lock_release; trap '_gaai_launch_scope_cleanup' EXIT INT TERM
    return "$_rc"
  fi

  local _sock _sess _pid
  _sock="$(_owner_field "$OWNER_FILE" socket)"
  _sess="$(_owner_field "$OWNER_FILE" session)"
  _pid="$(_owner_field "$OWNER_FILE" child_pid)"
  if [[ "$_sock" != "$TMUX_SOCKET" || "$_sess" != "$TMUX_SESSION" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "owner_role=identity_drift_at_stop" || true
    _release_and_exit 1
  fi

  $NO_DRAIN || _drain_wrappers

  echo "Stopping daemon (session $_sess)..."
  # The exact persisted session is the settlement target. No failure path signals
  # the daemon PID directly: the pane is the authority we recorded.
  _tmux kill-session -t "=$_sess" 2>/dev/null || true

  local _waited=0
  while [[ "$_waited" -lt 30 ]]; do
    _tmux has-session -t "=$_sess" 2>/dev/null || break
    sleep 1; _waited=$(( _waited + 1 ))
  done
  if _tmux has-session -t "=$_sess" 2>/dev/null; then
    _gaai_home_refuse process_authority_invalid 1 "settlement_role=session_persisted" || true
    _release_and_exit 1
  fi
  if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
    _gaai_home_refuse process_authority_invalid 1 "settlement_role=child_persisted" || true
    _release_and_exit 1
  fi

  local _attempt_dir
  _attempt_dir="$(_owner_field "$OWNER_FILE" attempt_dir)"
  # Only the exact persisted, proven-private attempt directory is removed. An
  # unproven path is never cleaned.
  if [[ -n "$_attempt_dir" && "$_attempt_dir" == "$LAUNCH_ROOT/"* && -d "$_attempt_dir" && ! -L "$_attempt_dir" ]]; then
    # Exactly the artefacts this lifecycle is known to create, by name. A recursive
    # removal is never used: anything else inside is unexplained evidence, and the
    # `rmdir` below is what proves nothing unexplained was left behind.
    rm -f "$_attempt_dir"/launcher.sh "$_attempt_dir"/release.fifo "$_attempt_dir"/secret.env \
          "$_attempt_dir"/manifest "$_attempt_dir"/args "$_attempt_dir"/tmux.conf \
          "$_attempt_dir"/ack.launcher "$_attempt_dir"/ack.ready "$_attempt_dir"/ack.child_failed \
          "$_attempt_dir"/forge.cred \
          2>/dev/null || true
    if ! rmdir "$_attempt_dir" 2>/dev/null; then
      echo "  note: $_attempt_dir still holds unrecognised content and is preserved for inspection"
    fi
  fi
  # The stopped daemon's OWN scope (recorded by its child, distinct from this
  # `--stop` invocation's own) is reclaimed here, from the durable record — its
  # own EXIT trap never ran this because it exec'd into the long-running daemon.
  _gaai_reclaim_owner_scope
  rm -f "$OWNER_FILE" 2>/dev/null || true
  rm -f "$PID_FILE" 2>/dev/null || true
  _tmux kill-server 2>/dev/null || true
  # Settlement is not complete while the socket file survives: a residual socket is
  # unexplained process-authority evidence that correctly blocks the next setup, so
  # exact settlement must remove the EXACT persisted socket path — never an ambient
  # or default one.
  if [[ "$_sock" == "$TMUX_SOCKET" && -e "$_sock" && ! -d "$_sock" ]]; then
    rm -f "$_sock" 2>/dev/null || true
  fi
  # The launch root is only removed when it is provably empty; a leftover attempt
  # from another failed launch stays as evidence.
  rmdir "$LAUNCH_ROOT" 2>/dev/null || true
  [[ -f "$LOG_FILE" ]] && : > "$LOG_FILE"
  echo "✅ Daemon stopped. Log truncated."
  _gaai_home_lock_release
  trap '_gaai_launch_scope_cleanup' EXIT INT TERM
  return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "$ACTION" in
  start)   do_start   ;;
  stop)    do_stop    ;;
  status)  do_status  ;;
  monitor) do_monitor ;;
  restart) do_stop; do_start ;;
esac
