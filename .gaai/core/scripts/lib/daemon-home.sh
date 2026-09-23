#!/usr/bin/env bash
# lib/daemon-home.sh — verify-only daemon-home identity + portable lifecycle lock
#
# Exact-current startup contract (committed-on-target framework code, human-only
# admission and merge trust surfaces). This library carries NO provisioning authority.
# `daemon-setup.sh` is the sole explicit offline owner that may create or update the
# dedicated `gaai-daemon-home` worktree. Every runtime path exported here — used by
# `daemon-start.sh` and `delivery-daemon.sh` — is strictly verify-only: it never
# creates, moves, removes, prunes, resets, cleans or repairs the home. Absent, stale,
# dirty, foreign, wrong-branch or ambiguous evidence returns a typed refusal before
# any tmux, credential or daemon effect.
#
# The former `_gaai_provision_daemon_home` is deliberately gone: a runtime
# repair cannot portably bind the linked-worktree directory, its `.git` link and the
# common-directory administrative records into one crash-atomic, no-overwrite
# transaction with Git's public pathname-based worktree commands.
#
# Typed reasons (closed set, AC5) and their canonical actions are the only
# operator-visible diagnostics. Evidence carries path roles and digests — never a
# remote URL, credential, repository content, operator identity or token digest.
#
# Idempotency guard: safe to source multiple times.

[[ -n "${_GAAI_DAEMON_HOME_SH_SOURCED:-}" ]] && return 0
_GAAI_DAEMON_HOME_SH_SOURCED=1

# Schema identity. Bound into every lock label and socket label so an incompatible
# lifecycle can never share a lock, a socket or an owner record with this one.
GAAI_HOME_SCHEMA="gaai-daemon-lifecycle/v1"
GAAI_HOME_BRANCH="gaai-daemon-home"

# Closed reason set (AC5). Order is the diagnostic order, not a precedence.
GAAI_HOME_REASONS="entry_authority_invalid target_fetch_failed target_advanced home_lock_failed already_running home_identity_invalid home_dirty home_registration_invalid home_update_failed home_asset_invalid process_authority_invalid forge_identity_unadmitted"

# Last typed refusal — reason, canonical action, non-secret evidence.
GAAI_HOME_REASON=""
GAAI_HOME_ACTION=""
GAAI_HOME_EVIDENCE=""

# ── Diagnostics ─────────────────────────────────────────────────────────────

_gaai_home_reason_is_known() {
  case " $GAAI_HOME_REASONS " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# _gaai_home_action_for <reason> <ambiguous 0|1>
#
# Deterministic, tested reason -> action mapping (AC5). `rerun_setup` is emitted
# ONLY when no ambiguous lifecycle or worktree evidence exists AND a clean offline
# setup can safely converge the home. Anything corrupt, foreign, dirty,
# concurrently replaced or incompletely settled is `operator_disposition_required`.
# `none` means retrying setup cannot resolve the reason. An unavailable proof is
# never turned into authority.
_gaai_home_action_for() {
  local _reason="$1" _ambiguous="${2:-0}"
  if ! _gaai_home_reason_is_known "$_reason"; then
    printf 'operator_disposition_required'
    return 0
  fi
  if [[ "$_ambiguous" == "1" ]]; then
    case "$_reason" in
      entry_authority_invalid|target_fetch_failed|already_running) ;;
      *) printf 'operator_disposition_required'; return 0 ;;
    esac
  fi
  case "$_reason" in
    # Contaminated entry, unreachable target, an already-live daemon: a setup rerun
    # changes nothing about any of them.
    entry_authority_invalid|target_fetch_failed|already_running) printf 'none' ;;
    # A clean offline setup converges these when nothing ambiguous is present.
    target_advanced|home_identity_invalid|home_registration_invalid|home_asset_invalid) printf 'rerun_setup' ;;
    # Never auto-resolvable: preserve the evidence for an operator.
    home_dirty|home_lock_failed|home_update_failed|process_authority_invalid) printf 'operator_disposition_required' ;;
    # No identity was admitted for this launch — an operator action, not a setup
    # rerun (setup provisions the home, not the operator's forge credential).
    forge_identity_unadmitted) printf 'provision_forge_credential' ;;
    *) printf 'operator_disposition_required' ;;
  esac
}

# _gaai_home_refuse <reason> <ambiguous 0|1> [evidence]
# Records a typed refusal and prints one privacy-safe diagnostic line. Returns 1 so
# every call site can `return`/`exit` on it directly and fail closed.
_gaai_home_refuse() {
  local _reason="$1" _ambiguous="${2:-0}" _evidence="${3:-}"
  if ! _gaai_home_reason_is_known "$_reason"; then
    _reason="process_authority_invalid"
  fi
  GAAI_HOME_REASON="$_reason"
  GAAI_HOME_ACTION="$(_gaai_home_action_for "$_reason" "$_ambiguous")"
  GAAI_HOME_EVIDENCE="$_evidence"
  printf 'daemon-home: reason=%s action=%s%s\n' \
    "$GAAI_HOME_REASON" "$GAAI_HOME_ACTION" \
    "${_evidence:+ evidence=$_evidence}" >&2
  return 1
}

# ── Primitives ──────────────────────────────────────────────────────────────

# Deterministic digest helper. `shasum -a 256` exists on macOS and most Linux
# images; `sha256sum` is the GNU fallback. Selection order is fixed so two hosts
# never disagree about a label.
_gaai_home_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    return 1
  fi
}

_gaai_home_digest_string() { printf '%s' "$1" | _gaai_home_digest; }
# Readability, not regular-file-ness, is the right guard: this is also called on a
# bound descriptor's path, which is a /proc magic link on Linux and a character
# device on Darwin's fdesc filesystem — neither satisfies `-f`. The caller has
# already proven the descriptor's identity by fstat before asking for its digest.
_gaai_home_digest_file()   { [[ -r "$1" ]] || return 1; _gaai_home_digest < "$1"; }

# Physical (symlink-resolved) path, without creating anything.
_gaai_home_physical() {
  local _p="$1"
  [[ -d "$_p" ]] || { printf '%s' "$_p"; return 0; }
  ( cd "$_p" 2>/dev/null && pwd -P ) 2>/dev/null || printf '%s' "$_p"
}

# The physical Git common directory — the one identity every worktree of a single
# physical repository shares. Lock and socket labels derive from it, so a second
# checkout of the same project can never collide with, or silently join, this one.
_gaai_home_common_dir() {
  local _repo_root="$1" _cd
  _cd="$(git -C "$_repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")"
  if [[ -z "$_cd" ]]; then
    # Older git without --path-format: resolve the relative answer against the root.
    _cd="$(git -C "$_repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    [[ -z "$_cd" ]] && return 1
    case "$_cd" in /*) ;; *) _cd="$_repo_root/$_cd" ;; esac
  fi
  _gaai_home_physical "$_cd"
}

# Schema-bound short label for a physical common directory. Used for the lock
# record, the private tmux socket and the owner record so all three are provably
# about the same repository and the same lifecycle contract.
_gaai_home_label() {
  local _common_dir="$1" _d
  _d="$(_gaai_home_digest_string "${GAAI_HOME_SCHEMA}|${_common_dir}")" || return 1
  printf '%s' "${_d:0:16}"
}

# Process incarnation: PID alone is reusable, so every durable identity carries the
# process start stamp too. Empty output means "cannot prove" — callers treat that as
# unavailable evidence, never as absence.
_gaai_home_incarnation() {
  local _pid="$1"
  [[ -n "$_pid" ]] || return 1
  case "$(uname -s)" in
    Linux)
      [[ -r "/proc/$_pid/stat" ]] || return 1
      # Field 22 (starttime) counted after the comm field, which may contain spaces.
      local _stat _rest
      _stat="$(cat "/proc/$_pid/stat" 2>/dev/null)" || return 1
      _rest="${_stat#*) }"
      printf '%s' "$_rest" | awk '{print $20}'
      ;;
    *)
      ps -o lstart= -p "$_pid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'
      ;;
  esac
}

# Best-effort durability. Bash has no fsync builtin; `sync <file>` (GNU) is exact,
# plain `sync` is the portable superset. Neither is claimed to survive power loss.
_gaai_home_fsync() {
  local _p="$1"
  sync "$_p" 2>/dev/null || sync 2>/dev/null || true
}

# Durable write: temp -> fsync -> rename -> fsync dir -> reread. The reread is the
# proof; a caller that does not reread has not written durably.
_gaai_home_write_durable() {
  local _path="$1" _content="$2" _tmp
  _tmp="${_path}.tmp.$$"
  printf '%s\n' "$_content" > "$_tmp" 2>/dev/null || return 1
  _gaai_home_fsync "$_tmp"
  mv -f "$_tmp" "$_path" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
  _gaai_home_fsync "$(dirname "$_path")"
  [[ -f "$_path" ]] || return 1
  local _back
  _back="$(cat "$_path" 2>/dev/null)" || return 1
  [[ "$_back" == "$_content" ]]
}

# Append-only, best-effort, non-secret lifecycle trace (AC2 ordering evidence).
# Fixed event vocabulary only — never an identity value, a digest, a pathname or
# a remote URL. Missing directory or write failure is never fatal: the trace is
# diagnostic evidence, not lifecycle authority.
_gaai_home_trace() {
  local _root="$1" _attempt="$2" _event="$3"
  [[ -n "$_root" ]] || return 0
  mkdir -p "$_root" 2>/dev/null || return 0
  chmod 0700 "$_root" 2>/dev/null || true
  printf 'attempt=%s event=%s\n' "$_attempt" "$_event" >> "$_root/trace" 2>/dev/null || true
}

# ── Lifecycle lock ──────────────────────────────────────────────────────────
#
# One portable, crash-recoverable, host-stable exclusive daemon-home/lifecycle lock
# derived from the physical Git common directory. `mkdir` is the atomic primitive on
# every supported filesystem; the durable owner record plus a hard-link claim make
# the holder identifiable, so a crashed holder is recoverable WITHOUT a TTL and
# without any lock handoff. A present-but-unprovable holder blocks.

_GAAI_HOME_LOCK_DIR=""
_GAAI_HOME_LOCK_CLAIM=""

_gaai_home_lock_root() { printf '%s/gaai-daemon-lifecycle' "$1"; }

# _gaai_home_lock_owner_pid <lock_root> — prints the recorded holder pid, if any.
_gaai_home_lock_owner_pid() {
  local _rec="$1/lock.d/holder"
  [[ -r "$_rec" ]] || return 1
  local _pid
  _pid="$(sed -n 's/^pid=//p' "$_rec" 2>/dev/null | head -1)"
  [[ -n "$_pid" ]] || return 1
  printf '%s' "$_pid"
}

# Is the recorded holder still the live process that took the lock?
_gaai_home_lock_holder_alive() {
  local _rec="$1/lock.d/holder" _pid _inc _now
  [[ -r "$_rec" ]] || return 1
  _pid="$(sed -n 's/^pid=//p' "$_rec" 2>/dev/null | head -1)"
  _inc="$(sed -n 's/^incarnation=//p' "$_rec" 2>/dev/null | head -1)"
  [[ -n "$_pid" ]] || return 1
  kill -0 "$_pid" 2>/dev/null || return 1
  # PID is live. Without a recorded incarnation the identity is unprovable, so the
  # holder counts as alive (fail closed) rather than reclaimable.
  [[ -n "$_inc" ]] || return 0
  _now="$(_gaai_home_incarnation "$_pid" 2>/dev/null || echo "")"
  [[ -z "$_now" ]] && return 0
  [[ "$_now" == "$_inc" ]]
}

# _gaai_home_lock_acquire <common_dir> [attempts]
# Acquires the lifecycle lock. No TTL, no handoff: the only way a held lock is
# reclaimed is a proven-dead holder (crash recovery).
_gaai_home_lock_acquire() {
  local _common_dir="$1" _attempts="${2:-1}" _root _label _i
  _root="$(_gaai_home_lock_root "$_common_dir")"
  _label="$(_gaai_home_label "$_common_dir")" \
    || { _gaai_home_refuse home_lock_failed 1 "digest_unavailable"; return 1; }

  mkdir -p "$_root" 2>/dev/null \
    || { _gaai_home_refuse home_lock_failed 1 "lock_root_uncreatable"; return 1; }
  chmod 0700 "$_root" 2>/dev/null || true

  _i=0
  while :; do
    if mkdir "$_root/lock.d" 2>/dev/null; then
      _GAAI_HOME_LOCK_DIR="$_root/lock.d"
      local _inc
      _inc="$(_gaai_home_incarnation "$$" 2>/dev/null || echo "")"
      if ! _gaai_home_write_durable "$_root/lock.d/holder" \
          "schema=${GAAI_HOME_SCHEMA}
label=${_label}
pid=$$
incarnation=${_inc}"; then
        rmdir "$_root/lock.d" 2>/dev/null || true
        _GAAI_HOME_LOCK_DIR=""
        _gaai_home_refuse home_lock_failed 1 "holder_record_undurable"
        return 1
      fi
      # Hard-link claim: `ln` refuses an existing target on every POSIX filesystem,
      # so the claim is a second, independent atomic witness of this holder.
      _GAAI_HOME_LOCK_CLAIM="$_root/claim.$$"
      : > "$_GAAI_HOME_LOCK_CLAIM" 2>/dev/null || true
      if ! ln "$_GAAI_HOME_LOCK_CLAIM" "$_root/lock.d/claim" 2>/dev/null; then
        rm -f "$_GAAI_HOME_LOCK_CLAIM" 2>/dev/null || true
        rm -f "$_root/lock.d/holder" 2>/dev/null || true
        rmdir "$_root/lock.d" 2>/dev/null || true
        _GAAI_HOME_LOCK_DIR=""
        _GAAI_HOME_LOCK_CLAIM=""
        _gaai_home_refuse home_lock_failed 1 "claim_link_unavailable"
        return 1
      fi
      return 0
    fi

    # Held. Recover only from a provably dead holder.
    if [[ ! -r "$_root/lock.d/holder" ]]; then
      _gaai_home_refuse home_lock_failed 1 "holder_record_absent"
      return 1
    fi
    if _gaai_home_lock_holder_alive "$_root"; then
      _i=$(( _i + 1 ))
      if [[ "$_i" -ge "$_attempts" ]]; then
        local _pid
        _pid="$(_gaai_home_lock_owner_pid "$_root" 2>/dev/null || echo "")"
        _gaai_home_refuse home_lock_failed 0 "held_by_live_holder${_pid:+:pid=$_pid}"
        return 1
      fi
      sleep 1
      continue
    fi
    # Crash recovery: the recorded holder is provably gone. Release its records and
    # retry the atomic acquisition — never hand the lock over in place.
    rm -f "$_root/lock.d/holder" "$_root/lock.d/claim" 2>/dev/null || true
    if ! rmdir "$_root/lock.d" 2>/dev/null; then
      _gaai_home_refuse home_lock_failed 1 "stale_lock_unrecoverable"
      return 1
    fi
    _i=$(( _i + 1 ))
    if [[ "$_i" -gt 3 ]]; then
      _gaai_home_refuse home_lock_failed 1 "lock_contention_unresolved"
      return 1
    fi
  done
}

_gaai_home_lock_release() {
  [[ -n "$_GAAI_HOME_LOCK_DIR" ]] || return 0
  rm -f "$_GAAI_HOME_LOCK_DIR/holder" "$_GAAI_HOME_LOCK_DIR/claim" 2>/dev/null || true
  rmdir "$_GAAI_HOME_LOCK_DIR" 2>/dev/null || true
  [[ -n "$_GAAI_HOME_LOCK_CLAIM" ]] && rm -f "$_GAAI_HOME_LOCK_CLAIM" 2>/dev/null
  _GAAI_HOME_LOCK_DIR=""
  _GAAI_HOME_LOCK_CLAIM=""
  return 0
}

_gaai_home_lock_held() { [[ -n "$_GAAI_HOME_LOCK_DIR" && -d "$_GAAI_HOME_LOCK_DIR" ]]; }

# ── Target observation (read-only) ──────────────────────────────────────────

# _gaai_home_fetch_target <repo_root> <target_branch>
# Fetches and prints the resolved remote tip SHA. A failed fetch is a typed refusal,
# never a silent fall back to a cached ref: swallowing it is exactly how missing
# evidence became launch authority under the former model.
_gaai_home_fetch_target() {
  local _repo_root="$1" _target="$2" _sha
  if ! git -C "$_repo_root" fetch --quiet origin "$_target" 2>/dev/null; then
    _gaai_home_refuse target_fetch_failed 0 "branch_role=target"
    return 1
  fi
  _sha="$(git -C "$_repo_root" rev-parse --verify --quiet "refs/remotes/origin/$_target^{commit}" 2>/dev/null || echo "")"
  if [[ -z "$_sha" ]]; then
    _gaai_home_refuse target_fetch_failed 0 "target_ref_unresolved"
    return 1
  fi
  printf '%s' "$_sha"
}

# ── Verify-only home identity ───────────────────────────────────────────────

# _gaai_home_verify <home_path> <target_branch> <repo_root> <expected_sha>
#
# Strict, non-mutating proof that a PRE-PROVISIONED home is usable: registered as a
# worktree of this physical repository, physically identical to the recorded
# registration, clean (worktree, index and untracked), on `gaai-daemon-home`, and
# exact-current at <expected_sha>. Anything else returns a typed refusal. This
# function performs no create, move, remove, prune, reset, clean or repair.
_gaai_home_verify() {
  local _home="$1" _target="$2" _repo_root="$3" _expected="$4"

  [[ -n "$_home" ]]      || { _gaai_home_refuse home_identity_invalid 0 "home_path_empty"; return 1; }
  [[ -n "$_repo_root" ]] || { _gaai_home_refuse home_identity_invalid 0 "repo_root_empty"; return 1; }
  [[ -n "$_target" ]]    || { _gaai_home_refuse home_identity_invalid 0 "target_branch_empty"; return 1; }
  [[ -n "$_expected" ]]  || { _gaai_home_refuse home_identity_invalid 0 "expected_sha_empty"; return 1; }

  if [[ -L "$_home" ]]; then
    _gaai_home_refuse home_identity_invalid 1 "home_role=symlink"
    return 1
  fi
  if [[ ! -d "$_home" ]]; then
    _gaai_home_refuse home_identity_invalid 0 "home_role=absent"
    return 1
  fi

  local _home_real
  _home_real="$(_gaai_home_physical "$_home")"

  # Registration: the physical path must appear in this repository's worktree list.
  local _listed=""
  _listed="$(git -C "$_repo_root" worktree list --porcelain 2>/dev/null || echo "")"
  if [[ -z "$_listed" ]]; then
    _gaai_home_refuse home_registration_invalid 1 "worktree_list_unavailable"
    return 1
  fi
  case "
$_listed" in
    *"
worktree $_home_real"*) ;;
    *) _gaai_home_refuse home_registration_invalid 0 "home_role=unregistered"; return 1 ;;
  esac

  # The home's own view must agree that it belongs to the same physical repository.
  local _home_common _repo_common
  _home_common="$(_gaai_home_common_dir "$_home" 2>/dev/null || echo "")"
  _repo_common="$(_gaai_home_common_dir "$_repo_root" 2>/dev/null || echo "")"
  if [[ -z "$_home_common" || -z "$_repo_common" ]]; then
    _gaai_home_refuse home_identity_invalid 1 "common_dir_unresolved"
    return 1
  fi
  if [[ "$_home_common" != "$_repo_common" ]]; then
    _gaai_home_refuse home_identity_invalid 1 "home_role=foreign_repository"
    return 1
  fi

  # Branch.
  local _branch
  _branch="$(git -C "$_home" branch --show-current 2>/dev/null || echo "")"
  if [[ "$_branch" != "$GAAI_HOME_BRANCH" ]]; then
    _gaai_home_refuse home_identity_invalid 0 "home_role=wrong_branch"
    return 1
  fi

  # Upstream: `gaai-daemon-home` must track origin/<target>.
  local _upstream
  _upstream="$(git -C "$_home" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")"
  if [[ "$_upstream" != "origin/$_target" ]]; then
    _gaai_home_refuse home_identity_invalid 0 "home_role=wrong_upstream"
    return 1
  fi

  # Cleanliness: worktree, index and untracked all clean. Dirty is preserved, never
  # cleaned — an operator's uncommitted state is evidence, not garbage.
  if ! git -C "$_home" diff --quiet 2>/dev/null; then
    _gaai_home_refuse home_dirty 1 "home_role=worktree_dirty"
    return 1
  fi
  if ! git -C "$_home" diff --cached --quiet 2>/dev/null; then
    _gaai_home_refuse home_dirty 1 "home_role=index_dirty"
    return 1
  fi
  local _untracked
  _untracked="$(git -C "$_home" ls-files --others --exclude-standard 2>/dev/null | head -1 || echo "")"
  if [[ -n "$_untracked" ]]; then
    _gaai_home_refuse home_dirty 1 "home_role=untracked_present"
    return 1
  fi

  # Exact-current: HEAD must equal the fetched target commit.
  local _head
  _head="$(git -C "$_home" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || echo "")"
  if [[ -z "$_head" ]]; then
    _gaai_home_refuse home_identity_invalid 1 "home_role=head_unresolved"
    return 1
  fi
  if [[ "$_head" != "$_expected" ]]; then
    _gaai_home_refuse home_identity_invalid 0 "home_role=stale_head"
    return 1
  fi
  return 0
}

# _gaai_home_verify_asset <home_path> <relative_path> <expected_sha> [expected_mode]
#
# Proves one tracked home asset is a regular, non-symlink file carrying the expected
# Git mode and byte-identical to the exact target blob. Used for the long-running
# executable and for the launcher source before either can be materialised or run.
_gaai_home_verify_asset() {
  local _home="$1" _rel="$2" _expected="$3" _want_mode="${4:-100755}"
  local _abs="$_home/$_rel"

  if [[ -L "$_abs" ]]; then
    _gaai_home_refuse home_asset_invalid 1 "asset_role=symlink"
    return 1
  fi
  if [[ ! -f "$_abs" ]]; then
    _gaai_home_refuse home_asset_invalid 0 "asset_role=absent"
    return 1
  fi

  local _entry _mode _blob
  _entry="$(git -C "$_home" ls-tree "$_expected" -- "$_rel" 2>/dev/null || echo "")"
  if [[ -z "$_entry" ]]; then
    _gaai_home_refuse home_asset_invalid 0 "asset_role=untracked_at_target"
    return 1
  fi
  _mode="${_entry%% *}"
  _blob="$(printf '%s' "$_entry" | awk '{print $3}')"
  if [[ "$_mode" != "$_want_mode" ]]; then
    _gaai_home_refuse home_asset_invalid 0 "asset_role=mode_mismatch"
    return 1
  fi
  if [[ ! -x "$_abs" ]]; then
    _gaai_home_refuse home_asset_invalid 0 "asset_role=not_executable"
    return 1
  fi

  local _want_digest _have_digest
  _want_digest="$(git -C "$_home" cat-file blob "$_blob" 2>/dev/null | _gaai_home_digest)" || {
    _gaai_home_refuse home_asset_invalid 1 "asset_role=blob_unreadable"; return 1; }
  _have_digest="$(_gaai_home_digest_file "$_abs")" || {
    _gaai_home_refuse home_asset_invalid 1 "asset_role=digest_unavailable"; return 1; }
  if [[ "$_want_digest" != "$_have_digest" ]]; then
    _gaai_home_refuse home_asset_invalid 0 "asset_role=blob_mismatch"
    return 1
  fi
  printf '%s' "$_want_digest"
}

# ── Private process-authority roots (verify-only) ───────────────────────────

# Socket roots are derived from the physical common directory and the real UID —
# never from an ambient or normalized TMPDIR, so a hostile TMPDIR cannot move the
# authority. The root is short by construction because the platform sun_path limit
# (104 on Darwin, 108 on Linux) applies to the COMPLETE physical socket path.
_gaai_home_socket_limit() {
  case "$(uname -s)" in
    Darwin) printf '104' ;;
    *)      printf '108' ;;
  esac
}

# The root lives under the physical /tmp so a symlinked /tmp (Darwin) still yields a
# stable, short, physical path — the sun_path limit applies to the physical form.
_gaai_home_socket_root() {
  local _tmp
  _tmp="$(_gaai_home_physical /tmp)"
  [[ -n "$_tmp" ]] || _tmp=/tmp
  printf '%s/.gaai-d-%s' "$_tmp" "$(id -u)"
}

# _gaai_home_socket_path <common_dir> — the complete physical socket path, verified
# against the platform limit. Emits nothing and fails when the root is unusable.
_gaai_home_socket_path() {
  local _common_dir="$1" _root _label _path _limit
  _root="$(_gaai_home_socket_root)"
  _label="$(_gaai_home_label "$_common_dir")" || {
    _gaai_home_refuse process_authority_invalid 1 "socket_label_unavailable"; return 1; }
  _path="$_root/$_label"
  _limit="$(_gaai_home_socket_limit)"
  if [[ "${#_path}" -ge "$_limit" ]]; then
    _gaai_home_refuse process_authority_invalid 0 "socket_role=path_too_long"
    return 1
  fi
  printf '%s' "$_path"
}

# _gaai_home_socket_root_ok <root> — ownership/mode/type proof for an EXISTING root.
# Creation belongs to the caller that is allowed to create it; this is verify-only.
_gaai_home_socket_root_ok() {
  local _root="$1" _uid _owner _mode
  [[ -e "$_root" ]] || { _gaai_home_refuse process_authority_invalid 0 "socket_role=root_absent"; return 1; }
  if [[ -L "$_root" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "socket_role=root_symlink"
    return 1
  fi
  [[ -d "$_root" ]] || { _gaai_home_refuse process_authority_invalid 1 "socket_role=root_not_directory"; return 1; }
  _uid="$(id -u)"
  _owner="$(_gaai_home_stat_field '%u' "$_root")" || {
    _gaai_home_refuse process_authority_invalid 1 "socket_role=root_stat_unavailable"; return 1; }
  if [[ "$_owner" != "$_uid" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "socket_role=root_foreign_owner"
    return 1
  fi
  _mode="$(_gaai_home_stat_field '%a' "$_root")" || {
    _gaai_home_refuse process_authority_invalid 1 "socket_role=root_stat_unavailable"; return 1; }
  if [[ "$_mode" != "700" ]]; then
    _gaai_home_refuse process_authority_invalid 1 "socket_role=root_mode_open"
    return 1
  fi
  return 0
}

# stat(1) is not portable between GNU and BSD; ask for one field with both spellings.
# '%u' -> numeric owner uid, '%a' -> octal permission bits.
_gaai_home_stat_field() {
  local _fmt="$1" _path="$2" _out
  # -L is mandatory, not cosmetic: GNU stat lstat()s by default, so without it a
  # magic link such as /proc/self/fd/N reports the link's own inode instead of the
  # bound file's, and every symlinked tool path reports the meaningless 0777 of the
  # link. Callers that need no-follow semantics reject the symlink BEFORE calling.
  case "$_fmt" in
    '%u') _out="$(stat -L -c '%u' "$_path" 2>/dev/null || stat -L -f '%u' "$_path" 2>/dev/null || echo "")" ;;
    '%a') _out="$(stat -L -c '%a' "$_path" 2>/dev/null || stat -L -f '%Lp' "$_path" 2>/dev/null || echo "")" ;;
    '%i') _out="$(stat -L -c '%i' "$_path" 2>/dev/null || stat -L -f '%i' "$_path" 2>/dev/null || echo "")" ;;
    '%d') _out="$(stat -L -c '%d' "$_path" 2>/dev/null || stat -L -f '%d' "$_path" 2>/dev/null || echo "")" ;;
    *)    return 1 ;;
  esac
  [[ -n "$_out" ]] || return 1
  printf '%s' "$_out"
}
