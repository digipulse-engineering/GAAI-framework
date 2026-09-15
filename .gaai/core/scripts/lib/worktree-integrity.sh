#!/usr/bin/env bash
# lib/worktree-integrity.sh — worktree corruption detection + safe-base re-fetch
#
# Sourceable library. Public functions:
#   _check_worktree_integrity <worktree_path> <expected_base> [<sid>]
#     Returns: 0=clean, 1=corruption suspected, 2=unrecoverable (fsck failure)
#   _recover_worktree_safe_base <sid> <worktree_path> <expected_base>
#     Returns: 0=recovered cleanly, 1=cherry-pick conflicts, 2=unrecoverable
#   _worktree_branch_is_landed <sid> <branch>
#     Returns: 0=landed (safe to hard-delete), 1=not verifiably landed (fail-closed)
#   _worktree_branch_delete_or_preserve <sid> <branch> <caller_tag>
#     Returns: 0=branch handled (deleted, or already gone), 1=preserved by rename
#     Preservation replicates the tip to refs/gaai/preserved/<name> on origin
#     first. Replication never blocks the rename, but an unreplicated
#     preservation is recorded as replicated=no in the audit line and always
#     logged, outside the throttle.
#
# Env vars (all optional, have defaults):
#   GAAI_WORKTREE_COMMITS_AHEAD_MAX  — commits-ahead threshold (default 100)
#   GAAI_WORKTREE_BASE_LAG_MAX       — acceptable lag behind base (default 5)
#   GAAI_WORKTREE_DELETIONS_MAX      — phantom-deletion threshold (default 50)
#   GAAI_WORKTREE_RECOVERY_TIMEOUT_SEC — wall-clock recovery timeout (default 120)
#   PROJECT_DIR                      — repo root (required by _recover_worktree_safe_base
#                                       and the branch-guard functions)
#   LOCK_DIR                         — for audit log (optional, falls back to PROJECT_DIR)
#   TARGET_BRANCH                    — remote backlog branch checked by the landed test
#                                       (optional, defaults to staging)
#   BACKLOG_REL                      — repo-relative backlog path checked by the landed
#                                       test (optional, defaults to the standard path)

[[ -n "${_WORKTREE_INTEGRITY_SH_SOURCED:-}" ]] && return 0
_WORKTREE_INTEGRITY_SH_SOURCED=1

_check_worktree_integrity() {
  local worktree_path="$1" expected_base="$2" sid="${3:-unknown}"
  local _base_branch _remote_ref _commits_ahead _deletions _threshold _fsck_out
  local _corruption_suspected=0

  local _commits_max="${GAAI_WORKTREE_COMMITS_AHEAD_MAX:-100}"
  local _deletions_max="${GAAI_WORKTREE_DELETIONS_MAX:-50}"

  echo "[WORKTREE-CHECK] ${sid} : verifying integrity (path=${worktree_path}, expected_base=${expected_base})"

  # First spawn: no worktree directory yet — nothing to check
  if [[ ! -d "$worktree_path" ]]; then
    echo "[WORKTREE-CHECK] ${sid} : no worktree directory — skipping (clean)"
    return 0
  fi

  # Normalize base: strip leading origin/ to get bare branch name
  _base_branch="${expected_base#origin/}"
  _remote_ref="origin/${_base_branch}"

  # Best-effort fetch — check still runs on stale refs if offline
  git -C "$worktree_path" --no-pager fetch origin "${_base_branch}" --quiet 2>/dev/null || true

  # Object corruption is unrecoverable — return 2 immediately.
  #
  # Scoped to THIS worktree's own HEAD on purpose. A bare `git fsck` walks the
  # shared object store AND every worktree's index cache-tree; a sibling worktree
  # that is mid-write (its cache-tree referencing objects not yet flushed to the
  # store) makes the bare fsck fail, and the failure is misattributed to the story
  # under check — parallel deliveries then stall each other's commit phase with a
  # false-positive corruption verdict. Passing an explicit object (HEAD) replaces
  # fsck's default reachability roots (refs + all worktree indexes) with just this
  # commit, so the check verifies only that this story's own reachable objects are
  # present. `--connectivity-only` confirms presence of every referenced tree/blob
  # without the (irrelevant here) full SHA re-hash.
  #
  # HEAD state must distinguish two cases that both make `rev-parse --verify HEAD`
  # fail, so a corrupt tip is never silently classified as clean:
  #   - genuinely unborn branch (HEAD symref → a ref that has no commit yet):
  #     nothing to validate — skip.
  #   - HEAD ref exists but its commit object is absent/unreadable (or detached at
  #     a missing commit): that IS corruption — return 2.
  if git -C "$worktree_path" --no-pager rev-parse --verify -q HEAD >/dev/null 2>&1; then
    # HEAD resolves to a present commit — run the scoped integrity check.
    if ! _fsck_out=$(git -C "$worktree_path" --no-pager fsck --connectivity-only --no-dangling HEAD 2>&1); then
      echo "[WORKTREE-CHECK] ${sid} : CORRUPTION SUSPECTED — commits_ahead=? deletions=? head-fsck=FAIL"
      echo "[WORKTREE-CHECK] ${sid} : head-fsck output: ${_fsck_out: -300}"
      return 2
    fi
  elif git -C "$worktree_path" --no-pager symbolic-ref -q HEAD >/dev/null 2>&1 \
       && ! git -C "$worktree_path" --no-pager show-ref -q --verify "$(git -C "$worktree_path" --no-pager symbolic-ref -q HEAD)" 2>/dev/null; then
    # Unborn branch — no commit yet, nothing to validate.
    echo "[WORKTREE-CHECK] ${sid} : unborn branch (no commit) — skipping fsck (clean)"
  else
    # HEAD ref present but its commit object is missing/unreadable — real corruption.
    echo "[WORKTREE-CHECK] ${sid} : CORRUPTION SUSPECTED — HEAD commit object missing/unreadable"
    return 2
  fi

  # Commits-ahead: wrapper producing >100 commits is almost certainly stuck on wrong base
  _commits_ahead=$(git -C "$worktree_path" --no-pager rev-list HEAD --not "${_remote_ref}" 2>/dev/null | wc -l | tr -d ' ')
  _commits_ahead="${_commits_ahead:-0}"

  # Phantom-deletes: files deleted in diff from remote base to HEAD
  _deletions=$(git -C "$worktree_path" --no-pager diff --diff-filter=D --name-only "${_remote_ref}...HEAD" 2>/dev/null | wc -l | tr -d ' ')
  _deletions="${_deletions:-0}"

  # Dynamic deletion threshold: max(50, 5 × story file count) if story is parseable
  _threshold="$_deletions_max"
  if [[ -n "$sid" && "$sid" != "unknown" ]]; then
    local _story_path="${worktree_path}/.gaai/project/contexts/artefacts/stories/${sid}.story.md"
    local _file_count
    _file_count=$(awk '/^## File Inventory/{found=1; next} found && /^\|.*\|/{count++} found && /^##/{exit} END{print count+0}' \
      "$_story_path" 2>/dev/null || echo 0)
    if [[ "${_file_count:-0}" -gt 0 ]]; then
      local _dynamic=$(( _file_count * 5 ))
      (( _dynamic > _threshold )) && _threshold="$_dynamic"
    fi
  fi

  if (( _commits_ahead > _commits_max )); then
    _corruption_suspected=1
  fi
  if (( _deletions > _threshold )); then
    _corruption_suspected=1
  fi

  if [[ "$_corruption_suspected" -eq 0 ]]; then
    echo "[WORKTREE-CHECK] ${sid} : clean (commits_ahead=${_commits_ahead}, deletions=${_deletions}, fsck=OK)"
    return 0
  else
    echo "[WORKTREE-CHECK] ${sid} : CORRUPTION SUSPECTED — commits_ahead=${_commits_ahead}, deletions=${_deletions}, fsck=OK"
    return 1
  fi
}

_recover_worktree_safe_base() {
  local sid="$1" worktree_path="$2" expected_base="$3"
  local _ts_start _elapsed _duration
  local _stash_out _stash_rc _stash_created=false _stash_label
  local _base_branch _remote_ref
  local _commits=() _sha _cp_out _cp_rc

  local _recovery_timeout="${GAAI_WORKTREE_RECOVERY_TIMEOUT_SEC:-120}"
  local _project_dir="${PROJECT_DIR:-}"
  local _lock_dir="${LOCK_DIR:-${_project_dir}/.gaai/project/contexts/backlog/.delivery-locks}"
  local _audit_log="${_lock_dir}/.cleanup-pending.audit"

  _ts_start=$(date +%s)
  _base_branch="${expected_base#origin/}"
  _remote_ref="origin/${_base_branch}"

  echo "[WORKTREE-RECOVER] ${sid} : starting safe-base re-fetch (path=${worktree_path}, base=${_base_branch})"

  # ── Step 1: Stash working tree + index + untracked (--include-untracked) ──
  # CRITICAL: stash before any destructive operation. If stash fails (non-empty
  # working tree with error), ABORT to prevent data loss.
  _stash_label="gaai-recovery-${sid}-$(date -u +%Y%m%dT%H%M%SZ)"
  _stash_out=$(git -C "$worktree_path" --no-pager stash push --include-untracked -m "$_stash_label" 2>&1)
  _stash_rc=$?

  if echo "$_stash_out" | grep -q "No local changes to save"; then
    _stash_created=false
    echo "[WORKTREE-RECOVER] ${sid} : nothing to stash — continuing"
  elif [[ $_stash_rc -ne 0 ]]; then
    echo "[WORKTREE-RECOVER] ${sid} : stash push FAILED (rc=${_stash_rc}): ${_stash_out: -300} — aborting recovery to prevent data loss"
    printf '%s|%s|worktree-recovery|failed-stash|0\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" >> "$_audit_log" 2>/dev/null || true
    return 2
  else
    _stash_created=true
    echo "[WORKTREE-RECOVER] ${sid} : stash created: ${_stash_label}"
  fi

  # ── Step 2: Capture wrapper's commits BEFORE worktree remove ──────────────
  # --reverse: oldest-first order is required for cherry-pick replay.
  # Objects survive worktree removal (shared object store in main repo .git).
  while IFS= read -r _sha; do
    [[ -n "$_sha" ]] && _commits+=("$_sha")
  done < <(git -C "$worktree_path" --no-pager log --reverse "${_remote_ref}..story/${sid}" --format=%H 2>/dev/null)

  echo "[WORKTREE-RECOVER] ${sid} : captured ${#_commits[@]} commits to cherry-pick"

  # ── Step 3: Remove worktree (destructive — stash in step 1 captured everything) ──
  git -C "$_project_dir" --no-pager worktree remove --force "$worktree_path" 2>&1 || true
  git -C "$_project_dir" --no-pager worktree prune 2>/dev/null || true
  # Defensive: remove lingering directory if worktree remove left it
  rm -rf "$worktree_path" 2>/dev/null || true

  # ── Step 4: Recreate worktree from current origin/<base> (clean base) ─────
  git -C "$_project_dir" --no-pager fetch origin "${_base_branch}" --quiet 2>/dev/null || true
  # Landed-or-preserved guard (orchestration.rules.md §Branch Rules → Worktree
  # lifecycle & cleanup): by construction this tip is mid-recovery and usually
  # unpushed, so this call legitimately preserves-by-rename on most safe-base
  # recoveries — expected, not a defect (the guard's own log throttle bounds
  # the operator-visible noise). Never special-case this site to hard-delete.
  _worktree_branch_delete_or_preserve "$sid" "story/${sid}" "worktree-recovery" || true
  local _wt_add_out
  if ! _wt_add_out=$(git -C "$_project_dir" --no-pager worktree add "$worktree_path" \
      -b "story/${sid}" "${_remote_ref}" 2>&1); then
    echo "[WORKTREE-RECOVER] ${sid} : FAILED to recreate worktree: ${_wt_add_out} — unrecoverable"
    printf '%s|%s|worktree-recovery|unrecoverable-recreate|%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "${#_commits[@]}" \
      >> "$_audit_log" 2>/dev/null || true
    return 2
  fi

  # ── Step 5: Cherry-pick each captured commit (timeout-guarded) ────────────
  # Use -c core.hooksPath=/dev/null so pre-commit/commit-msg hooks (e.g. linting)
  # don't block replay of already-validated commits. Genuine conflicts still fail.
  for _sha in "${_commits[@]}"; do
    _elapsed=$(( $(date +%s) - _ts_start ))
    if (( _elapsed > _recovery_timeout )); then
      git -C "$worktree_path" --no-pager cherry-pick --abort 2>/dev/null || true
      echo "[WORKTREE-RECOVER] ${sid} : TIMEOUT after ${_elapsed}s — recovery aborted"
      printf '%s|%s|worktree-recovery|timeout|%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "${#_commits[@]}" \
        >> "$_audit_log" 2>/dev/null || true
      return 2
    fi
    _cp_out=$(git -C "$worktree_path" --no-pager -c core.hooksPath=/dev/null cherry-pick "$_sha" 2>&1)
    _cp_rc=$?
    if [[ $_cp_rc -ne 0 ]]; then
      git -C "$worktree_path" --no-pager cherry-pick --abort 2>/dev/null || true
      echo "[WORKTREE-RECOVER] ${sid} : cherry-pick conflict on ${_sha} — recovery failed (operator must intervene)"
      echo "[WORKTREE-RECOVER] ${sid} : output: ${_cp_out: -400}"
      printf '%s|%s|worktree-recovery|failed-conflicts|%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "${#_commits[@]}" \
        >> "$_audit_log" 2>/dev/null || true
      return 1
    fi
  done

  # ── Step 6: Re-apply stash (best-effort — leave for operator on conflict) ──
  if [[ "$_stash_created" == "true" ]]; then
    if ! git -C "$worktree_path" --no-pager stash pop 2>&1; then
      echo "[WORKTREE-RECOVER] ${sid} : stash pop failed — stash preserved for operator (${_stash_label})"
    fi
  fi

  # ── Step 7: Audit log + success ───────────────────────────────────────────
  _duration=$(( $(date +%s) - _ts_start ))
  printf '%s|%s|worktree-recovery|success|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "${#_commits[@]}" \
    >> "$_audit_log" 2>/dev/null || true
  echo "[WORKTREE-RECOVER] ${sid} : recovery success in ${_duration}s — commits_recovered=${#_commits[@]}"
  return 0
}

# ── Landed-or-preserved branch guard ────────────────────────────────────────
# Squash-merge means commit-SHA ancestry from origin/<target> is NEVER a valid
# "is this branch's work safe to lose" test (squashed branches are never
# reachable). The correct test is: is the work landed (PR merged, or the
# story reconciled to done on the remote backlog), or does a remote copy of
# this exact branch exist (pushed-but-not-yet-merged)? Any check that cannot
# be verified (network/gh/remote-read failure) simply does not affirm —
# the predicate naturally fails closed if nothing confirms landed.
#
# Every affirmation is bound to the branch's CURRENT TIP OBJECT, never to its
# name. story/<sid> is reused across delivery cycles, so a name proves nothing
# about which work the ref holds today.
_worktree_branch_is_landed() {
  local sid="$1" branch="$2"
  local _project_dir="${PROJECT_DIR:-}"
  local _target="${TARGET_BRANCH:-staging}"
  local _backlog_rel="${BACKLOG_REL:-.gaai/project/contexts/backlog/active.backlog.yaml}"

  # (a1) remote backlog status:done — read from origin so an uncommitted
  # local edit can never mask a still-in_progress story on origin.
  local _remote_backlog_tmp _remote_status
  _remote_backlog_tmp=$(mktemp)
  if git -C "$_project_dir" show "origin/${_target}:${_backlog_rel}" > "$_remote_backlog_tmp" 2>/dev/null; then
    if [[ -z "${_BACKLOG_YAML_SH_SOURCED:-}" ]]; then
      local _wti_dir
      _wti_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      # shellcheck source=backlog-yaml.sh
      source "${_wti_dir}/backlog-yaml.sh" && _BACKLOG_YAML_SH_SOURCED=1
    fi
    _remote_status=$(backlog_status "$sid" "$_remote_backlog_tmp" 2>/dev/null || echo "")
    if [[ "$_remote_status" == "done" ]]; then
      rm -f "$_remote_backlog_tmp" 2>/dev/null || true
      return 0
    fi
  fi
  rm -f "$_remote_backlog_tmp" 2>/dev/null || true

  # The exact object this local ref currently points at. Both remaining checks
  # are bound to it: a branch NAME is not an identity here, because story/<sid>
  # is reused across delivery cycles for the same Story.
  local _local_tip _remote_tip
  _local_tip=$(git -C "$_project_dir" rev-parse --verify -q "$branch" 2>/dev/null || echo "")

  # (a2) A merged PR affirms only when it merged THIS EXACT TIP.
  #
  # Matching on `--head <branch>` alone was a data-loss path. story/<sid> is
  # reused whenever a Story is re-delivered, and GitHub retains headRefName on
  # merged PRs forever, so a merged PR from an EARLIER cycle kept affirming
  # "landed" for a branch whose current tip was unrelated, unpushed work — and
  # the caller then ran `branch -D` on it. Comparing headRefOid to the current
  # tip makes the affirmation about the object rather than the name: a reused
  # branch that has moved on no longer matches, and fails closed to preserve.
  #
  # `--state merged` rather than `--state all` because only a merged PR can
  # affirm, and a reused branch legitimately carries several PRs across cycles
  # — the old `--limit 1` over all states could return any one of them.
  # Absent, unauthenticated or failing gh yields empty output, which matches
  # nothing and therefore does not affirm.
  if [[ -n "$_local_tip" ]]; then
    local _merged_oids
    _merged_oids=$(gh pr list --state merged --head "$branch" \
      --json headRefOid --limit 20 --jq '.[].headRefOid' 2>/dev/null || echo "")
    if [[ -n "$_merged_oids" ]] \
        && printf '%s\n' "$_merged_oids" | grep -qxF "$_local_tip"; then
      return 0
    fi
  fi

  # (b) local branch tip present on a remote ref (pushed-but-not-yet-merged
  # is also safe to drop the LOCAL ref for — a remote copy still exists).
  # ls-remote queries live remote state directly, no local fetch required.
  _remote_tip=$(git -C "$_project_dir" ls-remote origin "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')
  if [[ -n "$_local_tip" && -n "$_remote_tip" && "$_local_tip" == "$_remote_tip" ]]; then
    return 0
  fi

  return 1
}

# Deletes a story branch if its work is landed-or-preserved (see
# _worktree_branch_is_landed); otherwise preserves it by rename so the
# commits are never destroyed. Preservation frees the original branch name
# for the retry path (a fresh story/<sid> can be created without silently
# resurrecting failed-attempt state) while keeping the old tip inspectable.
# caller_tag is a free-text label recorded in the audit trail (which call
# site triggered this) — not used for branching logic.
# Returns: 0 = branch handled (deleted, or was already gone), 1 = preserved.
_worktree_branch_delete_or_preserve() {
  local sid="$1" branch="$2" caller_tag="${3:-unknown}"
  local _project_dir="${PROJECT_DIR:-}"
  local _lock_dir="${LOCK_DIR:-${_project_dir}/.gaai/project/contexts/backlog/.delivery-locks}"
  local _audit_log="${_lock_dir}/.branch-preserved.audit"

  # Already gone (deleted by a concurrent path, or never existed) — no-op,
  # matches the pre-existing "|| true" semantics at every call site.
  if ! git -C "$_project_dir" rev-parse --verify -q "$branch" >/dev/null 2>&1; then
    return 0
  fi

  if _worktree_branch_is_landed "$sid" "$branch"; then
    git -C "$_project_dir" branch -D "$branch" 2>/dev/null || true
    return 0
  fi

  # Not verifiably landed — preserve by rename, never destroy.
  local _tip _preserved_name
  _tip=$(git -C "$_project_dir" rev-parse "$branch" 2>/dev/null || echo "unknown")
  _preserved_name="${branch}-preserved-$(date -u +%Y%m%dT%H%M%SZ)"

  # Replicate the tip before the local ref moves.
  #
  # A rename preserves nothing durable on its own. The renamed ref lives in one
  # object store, nothing pushes it, and when that store loses the object the
  # work is unrecoverable while the ref name survives — so the audit trail below
  # goes on describing a preservation that no longer has a commit behind it.
  # That is not hypothetical: it is the observed state of several preserved refs
  # in a real repository, discovered only because an unrelated fetch broke on
  # them. The name outliving the commit is the quietest possible failure.
  #
  # The push therefore happens BEFORE the rename, into a private namespace so a
  # preserved tip never appears in the branch list of a collaborator's clone.
  # That namespace is already proven to round-trip on a hosted forge by the id
  # allocator, which uses the same prefix.
  #
  # Replication is NOT allowed to block preservation. Offline, unauthenticated
  # and read-only-remote are all normal, and refusing to rename in those cases
  # would convert a network condition into a stalled delivery for no data-safety
  # gain — nothing is destroyed either way. What must never happen is a silent
  # unreplicated preservation, so the outcome is recorded in the audit line and
  # an unreplicated one bypasses the operator-log throttle entirely.
  local _preserved_ref="refs/gaai/preserved/${_preserved_name}"
  local _replicated=no _remote_tip=""
  if [[ "$_tip" =~ ^[0-9a-f]{40}$ || "$_tip" =~ ^[0-9a-f]{64}$ ]]; then
    if git -C "$_project_dir" push --quiet origin "${_tip}:${_preserved_ref}" 2>/dev/null; then
      # Judge by what the remote actually holds, not by the push's exit status.
      _remote_tip=$(git -C "$_project_dir" ls-remote origin "$_preserved_ref" 2>/dev/null \
        | awk '{print $1}')
      [[ "$_remote_tip" == "$_tip" ]] && _replicated=yes
    fi
  fi

  git -C "$_project_dir" branch -m "$branch" "$_preserved_name" 2>/dev/null || true

  mkdir -p "$_lock_dir" 2>/dev/null || true
  # Sixth field appended; the first five keep their positions and meaning so
  # existing readers are unaffected.
  printf '%s|%s|%s|%s|%s|replicated=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "$_preserved_name" "$_tip" "$caller_tag" \
    "$_replicated" \
    >> "$_audit_log" 2>/dev/null || true

  # An unreplicated preservation is a data-safety event, not routine progress:
  # say so every time, outside the throttle, and name what to do about it.
  if [[ "$_replicated" != yes ]]; then
    echo "[WORKTREE-GUARD] ${sid} : branch ${branch} preserved LOCALLY ONLY as ${_preserved_name} (tip=${_tip}) — replication to ${_preserved_ref} did not land; this work exists in exactly one object store. Push it or copy it out before that store is pruned, re-cloned or lost." >&2
  fi

  # AC4: single-fire log throttle per sid (mirrors the reconcile-sweep
  # unmerged-marker pattern) — the audit line above is always written (every
  # preservation is a distinct, real data-safety event); only the
  # operator-facing log line is rate-limited.
  local _throttle_marker="${_lock_dir}/.branch-preserve-log.${sid}"
  local _now_ts _last_ts
  _now_ts=$(date +%s)
  _last_ts=0
  [[ -f "$_throttle_marker" ]] && _last_ts=$(cat "$_throttle_marker" 2>/dev/null || echo 0)
  [[ "$_last_ts" =~ ^[0-9]+$ ]] || _last_ts=0
  if (( _now_ts - _last_ts >= 3600 )); then
    echo "[WORKTREE-GUARD] ${sid} : branch ${branch} not verifiably landed — preserved as ${_preserved_name} (caller=${caller_tag})"
    echo "$_now_ts" > "$_throttle_marker" 2>/dev/null || true
  fi

  return 1
}
