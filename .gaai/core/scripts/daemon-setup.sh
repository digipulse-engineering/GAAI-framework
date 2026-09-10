#!/bin/bash -p
# ═══════════════════════════════════════════════════════════════════════════
# GAAI Daemon Setup — the SOLE explicit offline daemon-home provisioner
# ═══════════════════════════════════════════════════════════════════════════
#
# Description:
#   Validates the daemon prerequisites, runs the hermetic tmux capability probe,
#   auto-configures idempotent settings, and — uniquely in this framework — may
#   create or update the dedicated registered `gaai-daemon-home` worktree.
#
#   The exact-current startup contract moved ALL provisioning authority here. `daemon-start.sh`,
#   `delivery-daemon.sh` and every runtime path in `lib/daemon-home.sh` are
#   verify-only. The reason is empirical, not stylistic: Git's public linked-worktree
#   operations are pathname-based across a physical directory plus common-directory
#   administrative state, and cannot give a runtime repair the portable, crash-atomic,
#   no-overwrite transaction the earlier design assumed. An explicit offline owner
#   that runs while nothing else holds the lifecycle can.
#
#   This script cannot start, stop, attach to or create the production daemon
#   lifecycle. It proves that no lifecycle owner, private server, session, pane or
#   ambiguous launch evidence exists before it touches the worktree, and it holds the
#   same physical-common-dir lifecycle lock from that inspection through settlement.
#
# Usage (direct privileged entry — this file is executable):
#   .gaai/core/scripts/daemon-setup.sh              Verify prerequisites + converge the home
#   .gaai/core/scripts/daemon-setup.sh --verify-only  Never mutate; report what setup would do
#
#   Prefixing that path with a plain `bash` interpreter is NOT supported and is refused.
#
# Environment overrides:
#   GAAI_TARGET_BRANCH=develop    override default branch (default: staging)
#   GAAI_DAEMON_HOME=<path>       override the dedicated home worktree path
#
# Exit codes:
#   0  — prerequisites met and the home is provisioned, clean and exact-current
#   1  — a prerequisite failed, or a typed refusal (reason + canonical action)
#   78 — entry_authority_invalid (contaminated or unsupported entry)
# ═══════════════════════════════════════════════════════════════════════════

GAAI_ENTRY_NAME="daemon-setup"

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
_GAAI_REQUIRED_CMDS='git tmux env stat id uname mkdir rmdir rm mv cp ln cat sed awk cut tr head wc ps sync sleep mkfifo chmod grep dirname basename date'

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
for _gaai_sub in home xdg-config xdg-cache xdg-data tmp; do
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
#     is the property section 7 protects. Only a symlink is created — no token is
#     copied, and the operator's own configuration remains the single source. Both
#     legs are conditional and best-effort: a host without `gh`, or without an
#     operator GitHub configuration, keeps exactly today's behaviour, and a remote
#     that needs no credentials is unaffected.
#     Preferred route: a DEDICATED forge credential the operator provisions outside
#     the private root. It is read once here and nothing is copied to disk; the
#     operator's own tool configuration is never made reachable, so a credential
#     scoped to the repositories this daemon actually needs replaces one scoped to
#     everything the operator can reach. The file must be a regular file, not a
#     symlink, owned by this principal, with no group or other access. A file that
#     fails any of those is IGNORED rather than "repaired" — this entry never widens
#     permissions on an operator's secret.
#
#     Any inherited forge credential is dropped first. The environment must never be
#     able to choose the identity the daemon acts under, and this variable survives
#     the section 8 strip precisely so the value set HERE reaches the tools.
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_CONFIG_DIR GH_HOST
_gaai_forge_token_file="${GAAI_OPERATOR_HOME:-}/.gaai/forge-token"
if [[ -n "${GAAI_OPERATOR_HOME:-}" && -f "$_gaai_forge_token_file" \
      && ! -L "$_gaai_forge_token_file" ]] \
   && _gaai_private_owner_mode "$_gaai_forge_token_file"; then
  GH_TOKEN="$(tr -d '[:space:]' < "$_gaai_forge_token_file" 2>/dev/null || printf '')"
  if [[ -n "$GH_TOKEN" ]]; then export GH_TOKEN; else unset GH_TOKEN; fi
fi
unset -v _gaai_forge_token_file
#     Fallback: the previous behaviour — link the operator's tool configuration — so
#     a host without a dedicated credential keeps working exactly as it did.
if [[ -z "${GH_TOKEN:-}" ]] \
   && [[ -n "$GAAI_OPERATOR_HOME" && -d "$GAAI_OPERATOR_HOME/.config/gh" \
         && ! -e "$XDG_CONFIG_HOME/gh" ]] && command -v gh >/dev/null 2>&1; then
  ln -s "$GAAI_OPERATOR_HOME/.config/gh" "$XDG_CONFIG_HOME/gh" 2>/dev/null || true
fi
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
#     rather than left to mask the link.
_gaai_agent_account_file="${GAAI_OPERATOR_HOME:-}/.claude.json"
if [[ -n "${GAAI_OPERATOR_HOME:-}" && -f "$_gaai_agent_account_file" \
      && ! -L "$_gaai_agent_account_file" && ! -d "$HOME/.claude.json" ]] \
   && _gaai_private_owner_mode "$_gaai_agent_account_file" \
   && command -v claude >/dev/null 2>&1; then
  rm -f "$HOME/.claude.json" 2>/dev/null || true
  ln -s "$_gaai_agent_account_file" "$HOME/.claude.json" 2>/dev/null || true
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
      && ! -L "$_gaai_executor_auth_file" && ! -d "$HOME/.codex/auth.json" ]] \
   && _gaai_private_owner_mode "$_gaai_executor_auth_file" \
   && command -v codex >/dev/null 2>&1; then
  ( umask 077; mkdir -p "$HOME/.codex" ) 2>/dev/null || true
  if [[ -d "$HOME/.codex" ]]; then
    rm -f "$HOME/.codex/auth.json" 2>/dev/null || true
    ln -s "$_gaai_executor_auth_file" "$HOME/.codex/auth.json" 2>/dev/null || true
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
# The private root's git configuration is entry-owned, so it is rewritten on every
# entry and a stale chain cannot survive. The leading empty helper resets the list
# accumulated from higher-level files: on this platform git reads an additional
# built-in system gitconfig that declares the platform keychain helper and that no
# environment variable can displace, so without the reset every successful fetch also
# runs a keychain store that cannot succeed under a private HOME.
if [[ -n "${GH_TOKEN:-}" || -L "$XDG_CONFIG_HOME/gh" ]]; then
  ( umask 077; printf '[credential]\n\thelper =\n\thelper = !gh auth git-credential\n' > "$HOME/.gitconfig" ) 2>/dev/null || true
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
_GAAI_CONFIG_ALLOW='GAAI_TARGET_BRANCH GAAI_DAEMON_HOME GAAI_REPO_ROOT GAAI_STOP_DRAIN_TIMEOUT
GAAI_DAEMON_NO_MONITOR GAAI_CLAUDE_PROXY_BASE_URL GAAI_IMPL_BASE_URL GAAI_IMPL_MODEL
GAAI_IMPL_MODEL_FALLBACK GAAI_AUTO_MERGE_POLICY GAAI_AUTO_MERGE_ADMIN_FALLBACK
GAAI_DAEMON_EXECUTOR GAAI_CODEX_MODEL GAAI_CODEX_SANDBOX GAAI_CODEX_EPHEMERAL
GAAI_CODEX_IGNORE_USER_CONFIG GAAI_CI_TEST_GATE_TIMEOUT_SEC GAAI_CI_TEST_GATE_MATERIALIZE_SEC
GAAI_WORKTREES_BASE
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
  case " $_GAAI_CONFIG_ALLOW PATH HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME TMPDIR LC_ALL LANG SHELL TERM USER LOGNAME UID EUID PWD SHLVL GH_TOKEN GIT_TERMINAL_PROMPT GIT_ASKPASS GH_PROMPT_DISABLED " in
    *" $_gaai_name "*) ;;
    *) export -n "$_gaai_name" 2>/dev/null || true ;;
  esac
done
unset -v _gaai_name
# END GAAI-ENTRY-AUTHORITY

# ── Roots ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GAAI_DIR="$(cd "$CORE_DIR/.." && pwd -P)"
PROJECT_ROOT="$(cd "$GAAI_DIR/.." && pwd -P)"

if [[ -d "$GAAI_DIR/project" ]]; then
  GAAI_PROJECT_DIR="$GAAI_DIR/project"
else
  GAAI_PROJECT_DIR="$GAAI_DIR/contexts"  # v1.x backwards compat
fi

TARGET_BRANCH="${GAAI_TARGET_BRANCH:-staging}"
VERIFY_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=true; shift ;;
    --help|-h) sed -n '/^# Description:/,/^# ═══.*═══$/{ /^# ═══.*═══$/d; p; }' "$0"; exit 0 ;;
    *) printf 'daemon-setup: reason=process_authority_invalid action=none evidence=arg_role=unsupported\n' >&2; exit 1 ;;
  esac
done

case "$(uname -s)" in
  Darwin|Linux) ;;
  *)
    echo "ERROR: only macOS and Linux are supported. On Windows use WSL:" >&2
    echo "  wsl --install && wsl" >&2
    echo "  cd /mnt/c/path/to/project && .gaai/core/scripts/daemon-setup.sh" >&2
    exit 1
    ;;
esac

# shellcheck source=lib/daemon-home.sh
[[ -z "${_GAAI_DAEMON_HOME_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/daemon-home.sh" && _GAAI_DAEMON_HOME_SH_SOURCED=1
if ! declare -F _gaai_home_verify >/dev/null 2>&1; then
  printf 'daemon-setup: reason=process_authority_invalid action=operator_disposition_required evidence=home_library_unavailable\n' >&2
  exit 1
fi

# Advisory presence lookup. Deliberately separate from the attested allowlist: the
# operator's own tooling (claude, jq, python3, timeout) lives wherever they installed
# it, usually in a user-writable directory, and reporting on it is not authority. No
# lifecycle operation ever resolves a command this way.
_operator_which() {
  local _cmd="$1" _dir _saved_ifs="$IFS"
  IFS=':'
  for _dir in $GAAI_OPERATOR_PATH; do
    [[ -n "$_dir" ]] || continue
    if [[ -f "$_dir/$_cmd" && -x "$_dir/$_cmd" ]]; then IFS="$_saved_ifs"; printf '%s' "$_dir/$_cmd"; return 0; fi
  done
  IFS="$_saved_ifs"
  return 1
}

PASS=0; FAIL=0; WARN=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }
refuse() { _gaai_home_refuse "$@" || { _gaai_home_lock_release; exit 1; }; }

echo ""
echo "GAAI Daemon Setup"
echo "  project: $PROJECT_ROOT"
echo "  branch:  $TARGET_BRANCH"
echo "================================"

# ── 1. Prerequisites ─────────────────────────────────────────────────────

echo ""
echo "[ Prerequisites ]"

PYTHON3="$(_operator_which python3 || echo "")"
if [[ -n "$PYTHON3" ]]; then
  pass "python3 found ($("$PYTHON3" --version 2>&1 | head -1))"
else
  fail "python3 not found — install Python 3 (https://www.python.org/downloads/)"
fi

if _operator_which claude >/dev/null; then
  pass "claude CLI found"
else
  fail "claude CLI not found — install: npm install -g @anthropic-ai/claude-code"
fi

# tmux is the ONLY authoritative process backend on macOS and Linux. There is no
# Terminal.app or nohup fallback any more: a fallback launcher is precisely how
# process ownership used to be inferred from ambient state instead of proven.
if command -v tmux >/dev/null 2>&1; then
  pass "tmux found ($(tmux -V 2>&1))"
else
  fail "tmux not found — install: brew install tmux (macOS) / apt install tmux (Linux)"
fi

if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Inside a git repository"
else
  fail "Not inside a git repository — initialize: git init && git checkout -b $TARGET_BRANCH"
fi

if git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1 \
   || git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/heads/$TARGET_BRANCH" >/dev/null 2>&1; then
  pass "$TARGET_BRANCH branch exists"
else
  fail "$TARGET_BRANCH branch not found — create it, or set GAAI_TARGET_BRANCH"
fi

for _req in delivery-daemon.sh backlog-scheduler.sh daemon-start.sh; do
  if [[ -f "$CORE_DIR/scripts/$_req" ]]; then pass "$_req exists"; else fail "$_req not found in $CORE_DIR/scripts/"; fi
done
if [[ -x "$CORE_DIR/scripts/daemon-start.sh" ]]; then
  pass "daemon-start.sh carries the executable bit required by the privileged entry"
else
  fail "daemon-start.sh is not executable — the privileged entry contract requires it"
fi

if command -v git >/dev/null 2>&1; then
  pass "git found ($(git --version 2>&1 | head -1))"
else
  fail "git not found — install git (https://git-scm.com/downloads)"
fi
_operator_which jq >/dev/null && pass "jq found (optional — enriched monitoring)" \
  || warn "jq not found — monitor dashboard shows reduced info"
if _operator_which gtimeout >/dev/null || _operator_which timeout >/dev/null; then
  pass "timeout found (delivery hard timeout)"
else
  warn "Neither timeout nor gtimeout found — deliveries won't auto-timeout"
fi

# ── 2. Hermetic tmux capability probe ────────────────────────────────────
#
# The 3.2 version floor is nominal; this probe is the admission authority. It runs
# in an isolated namespace and leaves no production lifecycle artifact behind.

echo ""
echo "[ Process authority ]"

# A server started empty with tmux's default `exit-empty on` exits immediately, so
# the required options cannot be applied after `start-server`; they are supplied as
# a fixed, private, non-injectable server config read at server start.
GAAI_TMUX_CONF_BODY='set -g exit-empty off
set -wg remain-on-exit on'

_probe_capability() {
  local _sock="$GAAI_PRIVATE_ROOT/tmp/setup-probe.$$" _conf="$GAAI_PRIVATE_ROOT/tmp/setup-conf.$$" _rc=0 _waited=0
  if [[ "${#_sock}" -ge "$(_gaai_home_socket_limit)" ]]; then return 2; fi
  ( umask 077; printf '%s\n' "$GAAI_TMUX_CONF_BODY" > "$_conf" ) 2>/dev/null || return 1
  tmux -f "$_conf" -S "$_sock" start-server 2>/dev/null || _rc=1
  while [[ "$_rc" -eq 0 && ! -S "$_sock" && "$_waited" -lt 10 ]]; do sleep 1; _waited=$(( _waited + 1 )); done
  [[ "$_rc" -eq 0 && -S "$_sock" ]] || _rc=1
  if [[ "$_rc" -eq 0 ]]; then
    [[ "$(tmux -f /dev/null -S "$_sock" show-options -g -v exit-empty 2>/dev/null)" == "off" ]] || _rc=1
    [[ "$(tmux -f /dev/null -S "$_sock" show-options -g -v remain-on-exit 2>/dev/null)" == "on" ]] || _rc=1
    tmux -f /dev/null -S "$_sock" new-session -d -s gaai-setup-probe -e GAAI_PROBE=1 \
      'exec /bin/sh -c "exit 0"' 2>/dev/null || _rc=1
    tmux -f /dev/null -S "$_sock" list-panes -t '=gaai-setup-probe' \
      -F '#{pane_id} #{pane_pid} #{pane_dead}' >/dev/null 2>&1 || _rc=1
  fi
  tmux -f /dev/null -S "$_sock" kill-server 2>/dev/null || true
  rm -f "$_sock" "$_conf" 2>/dev/null || true
  return "$_rc"
}

if command -v tmux >/dev/null 2>&1; then
  _probe_rc=0
  _probe_capability || _probe_rc=$?
  case "$_probe_rc" in
    0) pass "tmux capability probe passed (server, exit-empty, remain-on-exit, -e, pane formats)" ;;
    2) fail "tmux probe socket path exceeds the platform limit — shorten TMPDIR-independent roots" ;;
    *) fail "tmux capability probe failed — the installed tmux cannot host the private lifecycle" ;;
  esac
fi

# ── 3. Daemon home provisioning (the sole mutation authority) ────────────

echo ""
echo "[ Daemon home ]"

COMMON_DIR="$(_gaai_home_common_dir "$PROJECT_ROOT" 2>/dev/null || echo "")"
[[ -n "$COMMON_DIR" ]] || { fail "cannot resolve the physical git common directory"; COMMON_DIR=""; }

# The same repository-scoped worktree root the launcher uses (#3176), so setup
# provisions the home exactly where startup will look for it.
if [[ -z "${GAAI_WORKTREES_BASE:-}" ]]; then
  GAAI_WORKTREES_BASE="$(cd "$PROJECT_ROOT/.." && pwd -P)/.gaai-worktrees/$(basename "$PROJECT_ROOT")"
fi
export GAAI_WORKTREES_BASE
GAAI_DAEMON_HOME="${GAAI_DAEMON_HOME:-${GAAI_WORKTREES_BASE}/__daemon-home}"

_lifecycle_absent() {
  # No daemon lifecycle owner, private server, session, pane or ambiguous launch
  # evidence may exist under the same physical-repository authority. This is checked
  # UNDER the lock and the lock is retained through every mutation and settlement,
  # so no observation made here can go stale before it is used.
  local _root _owner
  _root="$COMMON_DIR/gaai-daemon-lifecycle"
  _owner="$_root/owner"
  if [[ -e "$_owner" ]]; then
    local _state
    _state="$(sed -n 's/^state=//p' "$_owner" 2>/dev/null | head -1)"
    printf 'owner_record:%s' "${_state:-corrupt}"
    return 1
  fi
  if [[ -d "$_root/launch" ]]; then
    local _leftover
    _leftover="$(ls -1 "$_root/launch" 2>/dev/null | head -1 || echo "")"
    if [[ -n "$_leftover" ]]; then printf 'launch_evidence'; return 1; fi
  fi
  local _sock
  _sock="$(_gaai_home_socket_path "$COMMON_DIR" 2>/dev/null || echo "")"
  if [[ -n "$_sock" && -S "$_sock" ]]; then
    if tmux -f /dev/null -S "$_sock" list-sessions >/dev/null 2>&1; then printf 'private_server_live'; return 1; fi
    printf 'private_socket_residual'; return 1
  fi
  return 0
}

if [[ -n "$COMMON_DIR" && "$FAIL" -eq 0 ]]; then
  if ! _gaai_home_lock_acquire "$COMMON_DIR"; then
    fail "lifecycle lock unavailable — reason=$GAAI_HOME_REASON action=$GAAI_HOME_ACTION"
  else
    trap '_gaai_home_lock_release' EXIT INT TERM
    _evidence=""
    if ! _evidence="$(_lifecycle_absent)"; then
      _gaai_home_refuse process_authority_invalid 1 "lifecycle_role=${_evidence}" || true
      fail "a daemon lifecycle is present or unsettled — stop it and dispose of the evidence first"
    else
      _sha="$(_gaai_home_fetch_target "$PROJECT_ROOT" "$TARGET_BRANCH")" || _sha=""
      if [[ -z "$_sha" ]]; then
        fail "cannot fetch origin/$TARGET_BRANCH — reason=$GAAI_HOME_REASON action=$GAAI_HOME_ACTION"
      elif _gaai_home_verify "$GAAI_DAEMON_HOME" "$TARGET_BRANCH" "$PROJECT_ROOT" "$_sha" 2>/dev/null; then
        pass "home is registered, clean and exact-current at ${_sha:0:12}"
      elif $VERIFY_ONLY; then
        fail "home is not exact-current (reason=$GAAI_HOME_REASON) — rerun without --verify-only"
      else
        _reason="$GAAI_HOME_REASON"
        _action="$GAAI_HOME_ACTION"
        if [[ "$_action" != "rerun_setup" ]]; then
          # Dirty, foreign, concurrently replaced or incompletely settled state is
          # PRESERVED byte-for-byte and requires an explicit operator decision. Setup
          # converges a home; it never destroys evidence to do so.
          fail "home requires operator disposition (reason=$_reason) — nothing was changed"
        elif [[ ! -e "$GAAI_DAEMON_HOME" ]] \
             && git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
                | grep -qF "worktree $GAAI_DAEMON_HOME"; then
          # Registered but the path is gone. AC1 admits exactly two shapes: create when
          # path AND registration are both absent, or update an already registered,
          # clean, correctly branched home. This is neither. Pruning the registration
          # here would be a silent repair of administrative state whose cause we cannot
          # see — the operator decides (`git worktree prune`, or restore the path).
          _gaai_home_refuse home_registration_invalid 1 "home_role=registered_path_missing" || true
          fail "the home path is missing but still registered — resolve the registration first"
        elif [[ ! -e "$GAAI_DAEMON_HOME" ]]; then
          # Absent: create. `worktree add` is refused by git if the path exists, so an
          # interrupted create leaves either nothing or a registration an operator can see.
          if git -C "$PROJECT_ROOT" worktree add -B "$GAAI_HOME_BRANCH" \
               "$GAAI_DAEMON_HOME" "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
             && git -C "$GAAI_DAEMON_HOME" branch --set-upstream-to="origin/$TARGET_BRANCH" \
                  "$GAAI_HOME_BRANCH" >/dev/null 2>&1; then
            pass "home created at $GAAI_DAEMON_HOME (${_sha:0:12})"
          else
            _gaai_home_refuse home_update_failed 1 "home_role=create_interrupted" || true
            fail "home creation failed or was interrupted — the observable state is preserved"
          fi
        else
          # Present, registered, clean, correctly branched but behind: fast-forward only.
          # A non-fast-forward is divergence, not staleness, and is never forced.
          if git -C "$GAAI_DAEMON_HOME" merge --ff-only "origin/$TARGET_BRANCH" >/dev/null 2>&1; then
            pass "home updated to ${_sha:0:12}"
          else
            _gaai_home_refuse home_update_failed 1 "home_role=update_not_fast_forward" || true
            fail "home could not be fast-forwarded — the working tree is preserved unchanged"
          fi
        fi
        if [[ "$FAIL" -eq 0 ]] && ! _gaai_home_verify "$GAAI_DAEMON_HOME" "$TARGET_BRANCH" "$PROJECT_ROOT" "$_sha"; then
          fail "home did not settle into an exact-current, clean, registered state"
        fi
      fi
    fi
  fi
fi

# ── 4. Auto-configure (idempotent) ───────────────────────────────────────

echo ""
echo "[ Configuration ]"

# Required for headless daemon mode: without it, permission prompts hang forever.
# It does NOT affect normal interactive Claude Code sessions.
CLAUDE_SETTINGS="${GAAI_OPERATOR_HOME:-$HOME}/.claude/settings.json"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")" 2>/dev/null || true
if [[ -n "$PYTHON3" ]] && [[ -f "$CLAUDE_SETTINGS" ]] && CLAUDE_SETTINGS="$CLAUDE_SETTINGS" "$PYTHON3" -c "
import json, sys, os
with open(os.environ['CLAUDE_SETTINGS']) as f:
    d = json.load(f)
sys.exit(0 if d.get('skipDangerousModePermissionPrompt') == True else 1)
" 2>/dev/null; then
  pass "skipDangerousModePermissionPrompt already set"
elif [[ -n "$PYTHON3" && -f "$CLAUDE_SETTINGS" ]]; then
  CLAUDE_SETTINGS="$CLAUDE_SETTINGS" "$PYTHON3" -c "
import json, os
p = os.environ['CLAUDE_SETTINGS']
with open(p) as f:
    d = json.load(f)
d['skipDangerousModePermissionPrompt'] = True
with open(p, 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null && pass "skipDangerousModePermissionPrompt added" || fail "Could not update $CLAUDE_SETTINGS"
else
  echo '{ "skipDangerousModePermissionPrompt": true }' > "$CLAUDE_SETTINGS" \
    && pass "Created $CLAUDE_SETTINGS with skipDangerousModePermissionPrompt" \
    || fail "Could not create $CLAUDE_SETTINGS"
fi

if [[ -d "$PROJECT_ROOT/.githooks" ]]; then
  if [[ "$(git -C "$PROJECT_ROOT" config --get core.hooksPath 2>/dev/null || echo "")" == ".githooks" ]]; then
    pass "git core.hooksPath already set to .githooks"
  else
    git -C "$PROJECT_ROOT" config core.hooksPath .githooks && pass "Set git core.hooksPath to .githooks"
  fi
else
  warn "No .githooks/ directory — pre-push safety hook not active"
fi

BACKLOG_DIR="$GAAI_PROJECT_DIR/contexts/backlog"
mkdir -p "$BACKLOG_DIR/.delivery-locks" && pass ".delivery-locks/ directory ready"
mkdir -p "$BACKLOG_DIR/.delivery-logs" && pass ".delivery-logs/ directory ready"

# ── 5. Health check ──────────────────────────────────────────────────────

echo ""
echo "[ Health Check ]"
HEALTH_SCRIPT="$CORE_DIR/scripts/health-check.sh"
if [[ -f "$HEALTH_SCRIPT" ]]; then
  if bash "$HEALTH_SCRIPT" --core-dir "$CORE_DIR" --project-dir "$GAAI_PROJECT_DIR" >/dev/null 2>&1; then
    pass "health-check.sh passed"
  else
    fail "health-check.sh reported issues — run directly for details"
  fi
else
  warn "health-check.sh not found — skipping"
fi

# ── Summary ──────────────────────────────────────────────────────────────

_gaai_home_lock_release
trap - EXIT INT TERM

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo "❌ Setup incomplete — fix the failures above before starting the daemon."
  exit 1
fi
echo "✅ Daemon setup complete. Start with:"
echo ""
echo "  .gaai/core/scripts/daemon-start.sh"
echo ""
echo "  (invoke it directly — a plain \`bash <script>\` entry is refused)"
exit 0
