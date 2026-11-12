#!/usr/bin/env bash
# allocate-id.sh — flock-guarded epic/story/dec ID allocator
# GAAI framework (OSS). Project-agnostic — no project-specific references.
#
# Usage:
#   allocate-id.sh epic                   Return next Epic ID (e.g., E221)
#   allocate-id.sh story <epic_prefix>   Return next Story ID (e.g., {EPIC}S{NN})
#   allocate-id.sh dec                   Return next Decision ID (e.g., DEC-166)
#   allocate-id.sh --help                Show help
#
# Env vars (all optional):
#   GAAI_BACKLOG_PATH        path to active.backlog.yaml (default: auto-detect from git root);
#                            blocked.backlog.yaml and done/*.yaml are read from the same directory
#   GAAI_ARTEFACTS_PATH      path to the artefacts directory holding epics/ and stories/
#                            (default: auto-detect from git root)
#   GAAI_DECISIONS_PATH      path to decisions directory (default: auto-detect from git root)
#   GAAI_RESERVATION_LEDGER  ledger file path (default: ~/.gaai/reservations/<repo_id>.tsv)
#   GAAI_RESERVATION_TTL_H   abandoned-reservation TTL in hours (default: 72)
#   GAAI_SCAN_REMOTE         scan remote branches for in-flight IDs (default: 1; 0/false/no/off disables)
#   GAAI_REMOTE              remote name to scan (default: origin)
#   GAAI_REMOTE_TIMEOUT      seconds to bound the remote scan before falling back (default: 5)
#   GAAI_RESERVATION_BACKEND reservation backend (default: git-cas; valid: git-cas)
#
# The allocator serialises under an exclusive flock (Linux) or mkdir-spin (macOS) and computes
# next = max(backlog/artefacts/decisions-dir, ledger, remote-refs, CAS-reservation-ref) + 1,
# writes a reservation row before returning, and prunes stale/landed entries on each run.
#
# Landed epic/story IDs: an ID stays taken after its row is archived. The backlog source is the
# whole backlog family — active.backlog.yaml plus blocked.backlog.yaml and every done/*.yaml
# archive beside it, the same set the framework's backlog archiving rules resolve an ID across —
# and the epic/story artefact files (epics/E<n>*.epic.md, stories/E<n>S<nn>*.story.md), which
# outlive a deleted or never-merged backlog row.
#
# Cross-worktree visibility: the ledger lives under ~/.gaai/reservations/ (outside any git
# worktree) and is keyed by a 12-char hash of the repository's absolute, symlink-resolved
# common git directory (git rev-parse --git-common-dir, resolved via cd + pwd -P) — a value
# that is identical for the main checkout and every linked worktree, so all local worktrees of
# the same repo genuinely share the ledger and lock before any branch merges. Reservations
# recorded under the previous (per-worktree-path) key are migrated forward, on each run, from
# every worktree the repository's live `git worktree list` still reports — including entries
# marked prunable (directory gone, path still listed); reservations belonging to worktrees
# already fully removed from that list are not recoverable by this route and are accepted as
# lost.
#
# Cross-host visibility: the ledger is host-local and TTL-pruned, so it cannot see IDs reserved
# on another machine (a daemon host, a second clone, Cloud) nor an ID whose PR has stayed open
# past the TTL. Remote branch names are the only shared, durable record of an in-flight ID, so
# the allocator also scans `git ls-remote --heads <remote>` and folds the highest E<n>/E<n>S<nn>
# token found into the max. The same scan protects a still-on-a-branch ledger entry from being
# TTL-pruned. This augments — it does not replace — the ledger: a concurrent session that has
# not yet pushed a branch on another host remains invisible (irreducible without a shared backend).
#
# When GAAI_RESERVATION_BACKEND=git-cas (the default), reservations are additionally written to
# refs/gaai/reservations on origin via a compare-and-swap push (plain non-force push; the
# non-fast-forward rejection IS the lease), closing the residual cross-host/unpushed-branch gap.
# A CAS-pushed reservation is confirmed; an offline reservation is unconfirmed (explicit stderr
# warning) and is reconciled at the next successful push. Remote I/O is bounded by
# GAAI_REMOTE_TIMEOUT and performed outside the local flock so a slow remote never stalls local
# sessions.
#
# Graceful degradation: if flock/mkdir both fail, allocation proceeds with a stderr warning. If
# the ledger directory is unwritable, proceeds with backlog-only max and warns. If the remote
# scan fails or times out (and a remote IS configured), it warns and falls back to backlog+ledger;
# if no remote is configured (local-only repo), the scan is silently skipped.
#
# dec mode: uses the decisions directory (GAAI_DECISIONS_PATH) as its primary landed-signal
# source (DEC-<N>.md file presence) and the CAS ref as its cross-host reservation backend,
# exactly like epic/story. Remote-branch scan for dec-<N> tokens is best-effort (DEC branches
# are often not named with dec-N tokens); the CAS ref is authoritative.

set -euo pipefail

# ── Help ──────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
allocate-id.sh — flock-guarded GAAI ID allocator (OSS framework)

Usage:
  allocate-id.sh epic                   Return next Epic ID (e.g., E221)
  allocate-id.sh story <epic_prefix>   Return next Story ID (e.g., {EPIC}S{NN})
  allocate-id.sh dec                   Return next Decision ID (e.g., DEC-166)
  allocate-id.sh --help                Show this help

Env vars (all optional):
  GAAI_BACKLOG_PATH        Path to active.backlog.yaml (default: auto-detect from git root);
                           blocked.backlog.yaml and done/*.yaml are read from the same directory
  GAAI_ARTEFACTS_PATH      Path to the artefacts directory holding epics/ and stories/
                           (default: auto-detect from git root)
  GAAI_DECISIONS_PATH      Path to decisions directory (default: auto-detect from git root)
  GAAI_RESERVATION_LEDGER  Ledger file (default: ~/.gaai/reservations/<repo_id>.tsv)
  GAAI_RESERVATION_TTL_H   Abandoned-reservation TTL in hours (default: 72)
  GAAI_SCAN_REMOTE         Scan remote for in-flight IDs and enable CAS (default: 1; 0/false/no/off off)
  GAAI_REMOTE              Remote name (default: origin)
  GAAI_REMOTE_TIMEOUT      Seconds to bound remote operations before fallback (default: 5)
  GAAI_RESERVATION_BACKEND Reservation backend (default: git-cas; valid: git-cas)

Ledger format (TSV):
  # GAAI ID reservation ledger — do not edit manually
  E221        epic    <epoch_secs>
  {EPIC}S{NN} story   <epoch_secs>
  DEC-166     dec     <epoch_secs>

The allocator computes next = max(highest-in-backlog/artefacts/decisions-dir, highest-in-ledger,
highest-on-remote, highest-in-CAS-ref) + 1, writes the new reservation to the ledger,
performs a compare-and-swap push to refs/gaai/reservations on origin (git-cas backend),
then prints the ID on stdout.
The remote branch source serialises against IDs on pushed-but-unmerged branches on other hosts;
the CAS ref serialises against IDs reserved but not yet pushed as branches on other hosts;
the ledger serialises local (not-yet-pushed) concurrent sessions on this host.

epic/story mode: the backlog source is active.backlog.yaml plus blocked.backlog.yaml and every
done/*.yaml archive in the same directory, so an archived ID is never re-issued. Epic and story
artefact files under GAAI_ARTEFACTS_PATH (epics/, stories/) count as taken IDs too.

dec mode: DEC-<N>.md file presence in the decisions directory is the landed-signal (replaces
backlog grep for epic/story). Remote-branch scan for dec-<N> tokens is best-effort; the CAS
ref is the authoritative cross-host serialiser for dec IDs.
EOF
  exit 0
fi

# ── Mode validation ───────────────────────────────────────────────────────────
MODE="${1:-}"
EPIC_PREFIX=""

if [[ "$MODE" == "epic" ]]; then
  : # ok
elif [[ "$MODE" == "story" ]]; then
  EPIC_PREFIX="${2:-}"
  if [[ -z "$EPIC_PREFIX" ]]; then
    echo "allocate-id.sh: 'story' mode requires <epic_prefix> argument (e.g. E220)" >&2
    exit 1
  fi
  if [[ ! "$EPIC_PREFIX" =~ ^E[0-9]+$ ]]; then
    echo "allocate-id.sh: epic prefix must match E[0-9]+ (got '${EPIC_PREFIX}')" >&2
    exit 1
  fi
elif [[ "$MODE" == "dec" ]]; then
  : # ok — no extra argument; dec IDs are plain integers (DEC-N, no zero-padding)
else
  echo "allocate-id.sh: unknown mode '${MODE:-<empty>}'. Use 'epic', 'story <prefix>', or 'dec'." >&2
  exit 1
fi

# ── Hashing helper (shared by the live key and the legacy-key recomputation during migration) ──
_hash12() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | cut -c1-12
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | cut -c1-12
  else
    printf '%s' "$input" | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | cut -c1-12
  fi
}

# ── Repo identity (stable key across all worktrees of the same repo) ──────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "allocate-id.sh: not inside a git repository" >&2
  exit 1
}

# ── Repository common git directory: identical from the main checkout and every linked
# worktree (unlike REPO_ROOT/--show-toplevel above, which returns each linked worktree's OWN
# path). This is the value the ledger/lock key is derived from below — kept in a SEPARATE
# variable so REPO_ROOT, and everything that derives from it (BACKLOG_PATH/DECISIONS_PATH
# defaults, further down), is left byte-for-byte unchanged. No --path-format=absolute flag
# (version-gated on newer git); cd + pwd -P achieves the same absolute, symlink-resolved result
# with no version floor.
RAW_GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" || {
  echo "allocate-id.sh: cannot resolve the repository's common git directory (git rev-parse --git-common-dir failed)" >&2
  exit 1
}

if [[ -z "$RAW_GIT_COMMON_DIR" ]]; then
  echo "allocate-id.sh: repository common git directory resolved to an empty value — refusing: an empty value would merge every repository on the host onto one reservation key" >&2
  exit 1
fi

REPO_COMMON_DIR="$(cd "$RAW_GIT_COMMON_DIR" 2>/dev/null && pwd -P)" || {
  echo "allocate-id.sh: cannot resolve the repository's common git directory to an absolute path (cd/pwd -P failed on '${RAW_GIT_COMMON_DIR}')" >&2
  exit 1
}

if [[ -z "$REPO_COMMON_DIR" || "${REPO_COMMON_DIR:0:1}" != "/" ]]; then
  echo "allocate-id.sh: repository common git directory resolved to a relative or empty value ('${REPO_COMMON_DIR}') — refusing: a relative or empty value would merge every repository on the host onto one reservation key" >&2
  exit 1
fi

REPO_ID="$(_hash12 "$REPO_COMMON_DIR")"

# ── Paths ─────────────────────────────────────────────────────────────────────
DEFAULT_BACKLOG="${REPO_ROOT}/.gaai/project/contexts/backlog/active.backlog.yaml"
BACKLOG_PATH="${GAAI_BACKLOG_PATH:-$DEFAULT_BACKLOG}"
# blocked.backlog.yaml and done/*.yaml sit beside the active backlog, so they follow an override.
BACKLOG_DIR="$(dirname "$BACKLOG_PATH")"

DEFAULT_ARTEFACTS="${REPO_ROOT}/.gaai/project/contexts/artefacts"
ARTEFACTS_PATH="${GAAI_ARTEFACTS_PATH:-$DEFAULT_ARTEFACTS}"

DEFAULT_DECISIONS="${REPO_ROOT}/.gaai/project/contexts/memory/decisions"
DECISIONS_PATH="${GAAI_DECISIONS_PATH:-$DEFAULT_DECISIONS}"

if [[ -n "${GAAI_RESERVATION_LEDGER:-}" ]]; then
  LEDGER_OVERRIDDEN=true
else
  LEDGER_OVERRIDDEN=false
fi
LEDGER_FILE="${GAAI_RESERVATION_LEDGER:-${HOME}/.gaai/reservations/${REPO_ID}.tsv}"
LOCK_FILE="${LEDGER_FILE}.lock"
LOCK_DIR="${LOCK_FILE}.d"
TTL_H="${GAAI_RESERVATION_TTL_H:-72}"

# ── Reservation backend seam ──────────────────────────────────────────────────
# GAAI_RESERVATION_BACKEND selects the cross-host coordination backend.
# Valid values: git-cas (default). An unknown value fails immediately with a clear error.
GAAI_RESERVATION_BACKEND="${GAAI_RESERVATION_BACKEND:-git-cas}"
case "$GAAI_RESERVATION_BACKEND" in
  git-cas) : ;;
  *)
    echo "allocate-id.sh: unknown GAAI_RESERVATION_BACKEND '${GAAI_RESERVATION_BACKEND}'. Valid options: git-cas" >&2
    exit 1
    ;;
esac

GIT_CAS_REF="refs/gaai/reservations"
GIT_CAS_FILE="reservations.tsv"

# ── Remote-scan configuration ─────────────────────────────────────────────────
GAAI_REMOTE="${GAAI_REMOTE:-origin}"
REMOTE_TIMEOUT="${GAAI_REMOTE_TIMEOUT:-5}"
SCAN_REMOTE=true
case "${GAAI_SCAN_REMOTE:-1}" in
  0|false|no|off|FALSE|NO|OFF) SCAN_REMOTE=false ;;
esac

# ── Scan remote branch names for in-flight IDs (read-only, runs BEFORE the lock) ──
# Cross-host serialisation primitive: a single `git ls-remote --heads` round-trip surfaces
# every ID that lives on a pushed-but-unmerged branch — the only shared, durable record an
# allocation on another host leaves behind. Kept outside the lock so a 5s network call never
# stalls a concurrent local allocator (the ledger read-modify-write under the lock stays fast).
REMOTE_HEADS_RAW=""

# Bounded `git ls-remote --heads <remote>` — prints "refs/heads/..." lines on success, returns
# non-zero on network failure/timeout. Prefer timeout(1)/gtimeout(1) when present: it kills the
# whole transport process group on expiry, so no orphaned git/transport-helper lingers. Otherwise
# fall back to backgrounding git DIRECTLY (not inside a pipe-subshell) so the bounded `kill "$pid"`
# targets the git process itself; awk runs afterwards in the foreground, leaving no grandchild to
# orphan. git's own exit status is captured via `wait`, so an empty-but-failed scan is never
# mistaken for "no branches" (which would silently drop the cross-host serialisation).
_ls_remote_heads() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/gaai_lsremote.XXXXXX" 2>/dev/null)" || return 1

  local tobin=""
  if   command -v timeout  >/dev/null 2>&1; then tobin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tobin="gtimeout"; fi

  if [[ -n "$tobin" ]]; then
    if "$tobin" "${REMOTE_TIMEOUT}s" git ls-remote --heads "$GAAI_REMOTE" >"$out_file" 2>/dev/null; then
      awk '{print $2}' "$out_file" 2>/dev/null || true
      rm -f "$out_file" 2>/dev/null || true
      return 0
    fi
    rm -f "$out_file" 2>/dev/null || true
    return 1
  fi

  # Fallback (no timeout(1), common on stock macOS): background git directly and bound it by PID.
  git ls-remote --heads "$GAAI_REMOTE" >"$out_file" 2>/dev/null &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
    if (( waited >= REMOTE_TIMEOUT )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out_file" 2>/dev/null || true
      return 1
    fi
  done
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  if (( rc != 0 )); then rm -f "$out_file" 2>/dev/null || true; return 1; fi
  awk '{print $2}' "$out_file" 2>/dev/null || true
  rm -f "$out_file" 2>/dev/null || true
  return 0
}

if [[ "$SCAN_REMOTE" == "true" ]] && git remote get-url "$GAAI_REMOTE" >/dev/null 2>&1; then
  if ! REMOTE_HEADS_RAW="$(_ls_remote_heads)"; then
    REMOTE_HEADS_RAW=""
    echo "allocate-id.sh: WARNING: remote scan of '${GAAI_REMOTE}' failed/timed out after ${REMOTE_TIMEOUT}s — falling back to backlog+ledger max; an unmerged ID reserved on another host may collide" >&2
  fi
fi

# ── Fetch CAS reservation ref from remote (outside lock — runs before flock) ─────
# Sets CAS_CONTENT as a side-effect. Uses force-fetch (+refspec) so a failed CAS push from a
# prior attempt does not leave the local ref ahead of the remote, blocking subsequent fetches.
# Returns 0 on success (ref exists and was fetched), 1 on timeout/network error/missing ref.
_fetch_cas_ref() {
  local tobin=""
  if   command -v timeout  >/dev/null 2>&1; then tobin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tobin="gtimeout"; fi

  if [[ -n "$tobin" ]]; then
    if "$tobin" "${REMOTE_TIMEOUT}s" \
        git fetch "$GAAI_REMOTE" "+${GIT_CAS_REF}:${GIT_CAS_REF}" 2>/dev/null; then
      CAS_CONTENT="$(git show "${GIT_CAS_REF}:${GIT_CAS_FILE}" 2>/dev/null || true)"
      return 0
    fi
    return 1
  fi

  # Fallback: background git with PID-bounded timeout (no timeout(1) available)
  git fetch "$GAAI_REMOTE" "+${GIT_CAS_REF}:${GIT_CAS_REF}" 2>/dev/null &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
    if (( waited >= REMOTE_TIMEOUT )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
  done
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  if (( rc != 0 )); then return 1; fi
  CAS_CONTENT="$(git show "${GIT_CAS_REF}:${GIT_CAS_FILE}" 2>/dev/null || true)"
  return 0
}

# Extract the highest epic number from the CAS reservation content (no I/O).
_cas_max_epic() {
  [[ -n "$CAS_CONTENT" ]] || { echo 0; return; }
  printf '%s\n' "$CAS_CONTENT" | awk -F'\t' '
    $1 !~ /^#/ && $2 == "epic" {
      sub(/^E/, "", $1); if ($1+0 > max) max = $1+0
    }
    $1 !~ /^#/ && $2 == "story" && $1 ~ /^E[0-9]+S[0-9]+$/ {
      e=$1; sub(/S[0-9]+$/, "", e); sub(/^E/, "", e); if (e+0 > max) max = e+0
    }
    END { print max+0 }' 2>/dev/null || echo 0
}

# Extract the highest story number for a given epic prefix from the CAS reservation content.
_cas_max_story() {
  local prefix="$1"
  [[ -n "$CAS_CONTENT" ]] || { echo 0; return; }
  printf '%s\n' "$CAS_CONTENT" | awk -F'\t' -v p="$prefix" '
    $1 !~ /^#/ && $2 == "story" && $1 ~ ("^"p"S[0-9]+$") {
      sub("^"p"S0*", "", $1); if ($1+0 > max) max = $1+0
    }
    END { print max+0 }' 2>/dev/null || echo 0
}

# Extract the highest DEC number from the CAS reservation content (no I/O).
_cas_max_dec() {
  [[ -n "$CAS_CONTENT" ]] || { echo 0; return; }
  printf '%s\n' "$CAS_CONTENT" | awk -F'\t' '
    $1 !~ /^#/ && $2 == "dec" {
      sub(/^DEC-/, "", $1); if ($1+0 > max) max = $1+0
    }
    END { print max+0 }' 2>/dev/null || echo 0
}

# Warn (to stderr) about any row in CAS_CONTENT that does not parse as a reservation (id present
# but kind or epoch field empty after tab-split). Read-only — never mutates CAS_CONTENT; the
# existing write path already forwards prior CAS content verbatim, so survival (AC5) requires no
# change there, only this warning.
_warn_malformed_cas_rows() {
  [[ -n "$CAS_CONTENT" ]] || return 0
  local raw_line c_id c_kind c_epoch
  while IFS= read -r raw_line; do
    [[ -z "$raw_line" || "$raw_line" == \#* ]] && continue
    IFS=$'\t' read -r c_id c_kind c_epoch <<< "$raw_line" || true
    if [[ -n "$c_id" && ( -z "$c_kind" || -z "$c_epoch" ) ]]; then
      echo "allocate-id.sh: WARNING: malformed row in shared reservation record (${GIT_CAS_REF} on ${GAAI_REMOTE}): '${raw_line}' — ignored for max computation, left unchanged in the record" >&2
    fi
  done <<< "$CAS_CONTENT"
}

# Fetch CAS ref before the lock. Gated on SCAN_REMOTE (both are remote operations; setting
# GAAI_SCAN_REMOTE=0 disables the branch scan AND the CAS to keep isolated / offline runs hermetic).
# Failure is silent — push will detect it via the unconfirmed path.
CAS_CONTENT=""
if [[ "$GAAI_RESERVATION_BACKEND" == "git-cas" && "$SCAN_REMOTE" == "true" ]] && \
    git remote get-url "$GAAI_REMOTE" >/dev/null 2>&1; then
  _fetch_cas_ref || true
  [[ -n "$CAS_CONTENT" ]] && _warn_malformed_cas_rows
fi

# ── Migrate legacy per-worktree-path-keyed ledgers into the shared common-git-dir-keyed ledger ──
# Only when the ledger path was NOT explicitly overridden (AC4: "with the ledger path override
# unset") — a caller-supplied ledger path is never touched by migration. Additive and idempotent:
# never deletes/renames a legacy ledger; a second run finds every id already migrated and adds
# nothing.
_migrate_legacy_worktree_ledger() {
  local wt_path="$1"
  [[ -n "$wt_path" ]] || return 0

  local old_id
  old_id="$(_hash12 "$wt_path")"
  [[ "$old_id" != "$REPO_ID" ]] || return 0   # already the live key — nothing to migrate

  local old_ledger="${HOME}/.gaai/reservations/${old_id}.tsv"
  [[ -f "$old_ledger" ]] || return 0

  local added=0
  local raw_line entry_id entry_kind entry_epoch
  while IFS= read -r raw_line; do
    [[ -z "$raw_line" || "$raw_line" == \#* ]] && continue
    IFS=$'\t' read -r entry_id entry_kind entry_epoch <<< "$raw_line" || true
    [[ -z "$entry_id" ]] && continue

    # id-existence check against the ledger content as migrated so far this run — avoids
    # inserting the same id twice even if it appears in more than one legacy ledger.
    if [[ -f "$LEDGER_FILE" ]] && awk -F'\t' -v id="$entry_id" '$1==id{f=1} END{exit !f}' "$LEDGER_FILE" 2>/dev/null; then
      continue
    fi

    {
      [[ -f "$LEDGER_FILE" ]] || printf '# GAAI ID reservation ledger — do not edit manually\n'
      printf '%s\n' "$raw_line"
    } >> "$LEDGER_FILE" 2>/dev/null || true
    added=$(( added + 1 ))
  done < "$old_ledger" || true

  if (( added > 0 )); then
    echo "allocate-id.sh: migrated ${added} reservation(s) from legacy ledger ${old_ledger} into ${LEDGER_FILE}" >&2
  fi
}

# Discover every worktree path the repository's worktree list still reports — including entries
# git marks 'prunable' (directory gone, path line still emitted) — and migrate each one's legacy
# ledger. Worktrees already fully removed via `git worktree remove` (no longer reported at all)
# are unrecoverable by this route — accepted as lost, per AC4.
_migrate_all_legacy_worktree_ledgers() {
  [[ "$LEDGER_WRITABLE" == "true" && "$LEDGER_OVERRIDDEN" == "false" ]] || return 0

  local wt_line wt_path
  while IFS= read -r wt_line; do
    case "$wt_line" in
      worktree\ *)
        wt_path="${wt_line#worktree }"
        _migrate_legacy_worktree_ledger "$wt_path"
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null) || true
}

# ── Ensure ledger directory exists ────────────────────────────────────────────
LEDGER_WRITABLE=true
if ! mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null; then
  echo "allocate-id.sh: WARNING: cannot create ledger dir $(dirname "$LEDGER_FILE") — ledger disabled" >&2
  LEDGER_WRITABLE=false
fi

# ── Acquire portable lock (Linux: flock fd, macOS: mkdir spin) ────────────────
# LOCK_TYPE tracks what cleanup is needed: "none" | "flock" | "mkdir"
LOCK_TYPE="none"

_release_lock() {
  case "$LOCK_TYPE" in
    flock) exec 9>&- 2>/dev/null || true ;;
    mkdir) rmdir "$LOCK_DIR" 2>/dev/null || true ;;
  esac
  LOCK_TYPE="none"
}
trap '_release_lock' EXIT INT TERM

if [[ "$LEDGER_WRITABLE" == "true" ]]; then
  if command -v flock >/dev/null 2>&1; then
    # Linux: fd 9-based exclusive flock (bash 3.x compatible — uses fixed fd, not {var}>)
    touch "$LOCK_FILE" 2>/dev/null || true
    exec 9>>"$LOCK_FILE"
    LOCK_TYPE="flock"  # mark fd open so _release_lock always closes it
    if ! flock -x -w 5 9 2>/dev/null; then
      echo "allocate-id.sh: WARNING: flock -w 5 timed out — allocation may not be atomic" >&2
    fi
  else
    # macOS: mkdir-based atomic spin (5 second timeout)
    WAITED=0
    WAIT_MAX=5
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
      sleep 1
      WAITED=$(( WAITED + 1 ))
      if (( WAITED >= WAIT_MAX )); then
        echo "allocate-id.sh: WARNING: mkdir lock timeout after ${WAIT_MAX}s — allocation may not be atomic" >&2
        break
      fi
    done
    LOCK_TYPE="mkdir"
  fi
else
  echo "allocate-id.sh: WARNING: flock unavailable — allocation not atomic across concurrent sessions" >&2
fi

# ── Migrate legacy per-worktree-path-keyed ledgers (must run under the lock, before the prune
# block below reads $LEDGER_FILE, so migrated rows are visible to this run's max computation) ──
_migrate_all_legacy_worktree_ledgers

# ── Prune stale and landed ledger entries ─────────────────────────────────────
NOW_EPOCH="$(date +%s 2>/dev/null)" || NOW_EPOCH="0"
TTL_SECS=$(( TTL_H * 3600 ))
LEDGER_KEPT=""

# An ID is "still live" if its exact token appears in a remote branch name. A fixed-string
# match is intentional: a false positive only keeps a reservation slightly longer (conservative,
# never causes a collision), whereas a false negative would re-open the TTL-prune collision hole.
_id_on_remote() {
  [[ -n "$REMOTE_HEADS_RAW" ]] || return 1
  printf '%s\n' "$REMOTE_HEADS_RAW" | grep -qF "$1"
}

if [[ -f "$LEDGER_FILE" ]]; then
  while IFS= read -r raw_line; do
    # Skip blank lines and comment/header lines
    [[ -z "$raw_line" || "$raw_line" == \#* ]] && continue

    IFS=$'\t' read -r entry_id entry_kind entry_epoch <<< "$raw_line" || true

    # Malformed row (AC5): id present but kind or epoch field missing after tab-split. Earlier
    # this shape was silently dropped by the rewrite below; now it is warned about and kept
    # verbatim, with no landed/TTL check (there is no reliable kind to branch on).
    if [[ -n "$entry_id" && ( -z "$entry_kind" || -z "$entry_epoch" ) ]]; then
      echo "allocate-id.sh: WARNING: malformed row in local ledger (${LEDGER_FILE}): '${raw_line}' — kept as-is, ignored for max computation" >&2
      LEDGER_KEPT="${LEDGER_KEPT}${raw_line}"$'\n'
      continue
    fi
    [[ -z "$entry_id" ]] && continue

    # Prune: landed check — kind-branch so each kind uses its own landed-signal.
    # dec entries: landed when DEC-<N>.md exists in the decisions directory.
    # epic/story entries: landed when they appear in the backlog (unchanged).
    # This is a strict if/elif/else branch — NOT an OR extension of the existing
    # backlog check, so an epic/story entry is never pruned by a coincidental DEC file.
    if [[ "$entry_kind" == "dec" ]]; then
      if [[ -f "${DECISIONS_PATH}/${entry_id}.md" ]]; then
        continue
      fi
    else
      if [[ -f "$BACKLOG_PATH" ]] && grep -q "id: ${entry_id}" "$BACKLOG_PATH" 2>/dev/null; then
        continue
      fi
    fi

    # Prune: reservation older than TTL (abandoned) — UNLESS the ID is still live on a remote
    # branch (an open PR that has simply outlived the TTL; pruning it would let the number be
    # re-allocated and collide when the PR merges).
    if [[ "$NOW_EPOCH" -gt 0 && "$entry_epoch" =~ ^[0-9]+$ ]]; then
      age=$(( NOW_EPOCH - entry_epoch ))
      if (( age > TTL_SECS )) && ! _id_on_remote "$entry_id"; then
        continue
      fi
    fi

    LEDGER_KEPT="${LEDGER_KEPT}${entry_id}	${entry_kind}	${entry_epoch}"$'\n'
  done < "$LEDGER_FILE" || true

  # Rewrite ledger without pruned entries
  if [[ "$LEDGER_WRITABLE" == "true" ]]; then
    {
      printf '# GAAI ID reservation ledger — do not edit manually\n'
      printf '%s' "$LEDGER_KEPT"
    } > "${LEDGER_FILE}.tmp.$$" && mv "${LEDGER_FILE}.tmp.$$" "$LEDGER_FILE" || true
  fi
fi

# ── Max-extraction helpers ────────────────────────────────────────────────────

# Every backlog file an epic/story ID can live in: the active backlog, the blocked backlog and each
# archive under done/. Archiving moves a row out of the active backlog without freeing its ID, so
# scanning the active file alone would re-issue every archived ID. Missing files are skipped. Kept
# as an array (not a word-split string) so a path containing spaces stays one argument.
BACKLOG_FILES=()
if [[ -f "$BACKLOG_PATH" ]]; then BACKLOG_FILES+=("$BACKLOG_PATH"); fi
if [[ -f "${BACKLOG_DIR}/blocked.backlog.yaml" ]]; then
  BACKLOG_FILES+=("${BACKLOG_DIR}/blocked.backlog.yaml")
fi
for _archive in "${BACKLOG_DIR}"/done/*.yaml; do
  if [[ -f "$_archive" ]]; then BACKLOG_FILES+=("$_archive"); fi
done

_backlog_max_epic() {
  (( ${#BACKLOG_FILES[@]} > 0 )) || { echo 0; return; }
  local result
  result="$(grep -ohE 'E[0-9]+' "${BACKLOG_FILES[@]}" 2>/dev/null \
    | sed 's/^E//' \
    | sort -n | tail -1)" || true
  # Force base-10 so a leading-zero value never octal-parses in a caller's $(( )).
  echo "$(( 10#${result:-0} ))"
}

_backlog_max_story() {
  local prefix="$1"
  (( ${#BACKLOG_FILES[@]} > 0 )) || { echo 0; return; }
  local result
  result="$(grep -ohE "${prefix}S[0-9]+" "${BACKLOG_FILES[@]}" 2>/dev/null \
    | grep -oE '[0-9]+$' \
    | sort -n | tail -1)" || true
  # Force base-10: story numbers are zero-padded (S08/S09 → "08"/"09"), which
  # bash arithmetic would otherwise reject as invalid octal.
  echo "$(( 10#${result:-0} ))"
}

# Basenames of the epic and story artefact files. A glob that matches nothing stays literal
# ("*.epic.md"), which the callers' anchored patterns reject, so a missing directory yields nothing.
_artefact_names() {
  local f
  for f in "${ARTEFACTS_PATH}"/epics/*.epic.md "${ARTEFACTS_PATH}"/stories/*.story.md; do
    printf '%s\n' "${f##*/}"
  done
}

# Highest epic number named by an artefact file: E<n>[suffix].epic.md, or E<n>S<nn>[suffix].story.md
# (a story file proves its epic exists). The digit run is closed by a non-digit, so E12 never reads
# as E1 and suffixed names (E<n>a, E<n>-name, E<n>S<nn>b) still count.
_artefacts_max_epic() {
  local result
  result="$(_artefact_names \
    | sed -nE 's/^E([0-9]+)([^0-9].*)?\.(epic|story)\.md$/\1/p' \
    | sort -n | tail -1)" || true
  echo "$(( 10#${result:-0} ))"
}

# Highest story number for <prefix> named by a story artefact file: <prefix>S<nn>[suffix].story.md.
_artefacts_max_story() {
  local prefix="$1"
  local result
  result="$(_artefact_names \
    | sed -nE "s/^${prefix}S([0-9]+)([^0-9].*)?\\.story\\.md\$/\\1/p" \
    | sort -n | tail -1)" || true
  echo "$(( 10#${result:-0} ))"
}

# Return the highest DEC number from DEC-<N>.md filenames and _log.md entries.
# Two sources are checked: the decisions directory (landed files) and the _log.md
# (records decisions by number even before their file is committed).
_decisions_max_dec() {
  local result_files=0 result_log=0
  if [[ -d "$DECISIONS_PATH" ]]; then
    local r
    r="$(ls "${DECISIONS_PATH}"/DEC-*.md 2>/dev/null \
      | grep -oE 'DEC-[0-9]+' | grep -oE '[0-9]+$' \
      | sort -n | tail -1)" || true
    result_files=$(( 10#${r:-0} ))
  fi
  if [[ -f "${DECISIONS_PATH}/_log.md" ]]; then
    local r
    r="$(grep -oE 'DEC-[0-9]+' "${DECISIONS_PATH}/_log.md" 2>/dev/null \
      | grep -oE '[0-9]+$' \
      | sort -n | tail -1)" || true
    result_log=$(( 10#${r:-0} ))
  fi
  echo "$(( result_files > result_log ? result_files : result_log ))"
}

_ledger_max_epic() {
  [[ -f "$LEDGER_FILE" ]] || { echo 0; return; }
  awk -F'\t' '
    $1 !~ /^#/ && $2=="epic" { sub(/^E/, "", $1); if ($1+0 > max) max=$1+0 }
    $1 !~ /^#/ && $2=="story" && $1 ~ /^E[0-9]+S[0-9]+$/ {
      e=$1; sub(/S[0-9]+$/, "", e); sub(/^E/, "", e); if (e+0 > max) max=e+0
    }
    END { print max+0 }' \
    "$LEDGER_FILE" 2>/dev/null || echo 0
}

_ledger_max_story() {
  local prefix="$1"
  [[ -f "$LEDGER_FILE" ]] || { echo 0; return; }
  awk -F'\t' -v p="$prefix" \
    '$1 !~ /^#/ && $2=="story" && $1 ~ ("^"p"S[0-9]+$") { sub("^"p"S0*", "", $1); if ($1+0 > max) max=$1+0 } END { print max+0 }' \
    "$LEDGER_FILE" 2>/dev/null || echo 0
}

_ledger_max_dec() {
  [[ -f "$LEDGER_FILE" ]] || { echo 0; return; }
  awk -F'\t' '$1 !~ /^#/ && $2=="dec" { sub(/^DEC-/, "", $1); if ($1+0 > max) max=$1+0 } END { print max+0 }' \
    "$LEDGER_FILE" 2>/dev/null || echo 0
}

# Remote-ref maxima — extract the highest epic / story-for-prefix token from the branch names
# captured before the lock. Empty REMOTE_HEADS_RAW (scan disabled, no remote, or scan failed)
# yields 0, so this source is simply a no-op in those cases.
_remote_max_epic() {
  [[ -n "$REMOTE_HEADS_RAW" ]] || { echo 0; return; }
  # Extract E<n> tokens but reject word-embedded false matches like `E2E-test-harness` (where the
  # E<n> is followed by another letter). A real epic token is followed by `S<digit>` (story branch),
  # a separator, or end-of-name. Direction-safe regardless: an over- or under-match only moves the
  # next ID forward, never causes a collision.
  printf '%s\n' "$REMOTE_HEADS_RAW" | awk '
    { s = $0
      while (match(s, /E[0-9]+/)) {
        tok  = substr(s, RSTART, RLENGTH)
        rest = substr(s, RSTART + RLENGTH)
        if (rest ~ /^S[0-9]/ || rest == "" || rest ~ /^[^0-9A-Za-z]/) {
          n = substr(tok, 2) + 0
          if (n > max) max = n
        }
        s = rest
      }
    } END { print max + 0 }' 2>/dev/null || echo 0
}

_remote_max_story() {
  local prefix="$1"
  [[ -n "$REMOTE_HEADS_RAW" ]] || { echo 0; return; }
  local result
  result="$(printf '%s\n' "$REMOTE_HEADS_RAW" | grep -oE "${prefix}S[0-9]+" 2>/dev/null \
    | grep -oE '[0-9]+$' \
    | sort -n | tail -1)" || true
  echo "$(( 10#${result:-0} ))"
}

# Remote-ref scan for dec is best-effort: DEC branches are often named discovery/E<n>S<nn>
# rather than dec-<N>, so this source yields 0 in most cases. The CAS ref is authoritative.
_remote_max_dec() {
  [[ -n "$REMOTE_HEADS_RAW" ]] || { echo 0; return; }
  local result
  result="$(printf '%s\n' "$REMOTE_HEADS_RAW" | grep -oiE 'dec-[0-9]+' 2>/dev/null \
    | grep -oE '[0-9]+$' | sort -n | tail -1)" || true
  echo "$(( 10#${result:-0} ))"
}

# ── Compute next ID ───────────────────────────────────────────────────────────
if [[ "$MODE" == "epic" ]]; then
  MAX_BACKLOG="$(_backlog_max_epic)"
  MAX_ARTEFACTS="$(_artefacts_max_epic)"
  MAX_LEDGER="$(_ledger_max_epic)"
  MAX_REMOTE="$(_remote_max_epic)"
  MAX_CAS="$(_cas_max_epic)"
  MAX_BACKLOG="${MAX_BACKLOG:-0}"; MAX_ARTEFACTS="${MAX_ARTEFACTS:-0}"; MAX_LEDGER="${MAX_LEDGER:-0}"
  MAX_REMOTE="${MAX_REMOTE:-0}"; MAX_CAS="${MAX_CAS:-0}"
  MAX=$(( MAX_BACKLOG > MAX_LEDGER ? MAX_BACKLOG : MAX_LEDGER ))
  MAX=$(( MAX > MAX_ARTEFACTS ? MAX : MAX_ARTEFACTS ))
  MAX=$(( MAX > MAX_REMOTE ? MAX : MAX_REMOTE ))
  MAX=$(( MAX > MAX_CAS ? MAX : MAX_CAS ))
  NEXT_NUM=$(( MAX + 1 ))
  NEW_ID="E${NEXT_NUM}"
elif [[ "$MODE" == "story" ]]; then
  MAX_BACKLOG="$(_backlog_max_story "$EPIC_PREFIX")"
  MAX_ARTEFACTS="$(_artefacts_max_story "$EPIC_PREFIX")"
  MAX_LEDGER="$(_ledger_max_story "$EPIC_PREFIX")"
  MAX_REMOTE="$(_remote_max_story "$EPIC_PREFIX")"
  MAX_CAS="$(_cas_max_story "$EPIC_PREFIX")"
  MAX_BACKLOG="${MAX_BACKLOG:-0}"; MAX_ARTEFACTS="${MAX_ARTEFACTS:-0}"; MAX_LEDGER="${MAX_LEDGER:-0}"
  MAX_REMOTE="${MAX_REMOTE:-0}"; MAX_CAS="${MAX_CAS:-0}"
  MAX=$(( MAX_BACKLOG > MAX_LEDGER ? MAX_BACKLOG : MAX_LEDGER ))
  MAX=$(( MAX > MAX_ARTEFACTS ? MAX : MAX_ARTEFACTS ))
  MAX=$(( MAX > MAX_REMOTE ? MAX : MAX_REMOTE ))
  MAX=$(( MAX > MAX_CAS ? MAX : MAX_CAS ))
  NEXT_NUM=$(( MAX + 1 ))
  NEXT_PADDED="$(printf '%02d' "$NEXT_NUM")"
  NEW_ID="${EPIC_PREFIX}S${NEXT_PADDED}"
else
  # dec mode
  MAX_BACKLOG="$(_decisions_max_dec)"
  MAX_LEDGER="$(_ledger_max_dec)"
  MAX_REMOTE="$(_remote_max_dec)"
  MAX_CAS="$(_cas_max_dec)"
  MAX_BACKLOG="${MAX_BACKLOG:-0}"; MAX_LEDGER="${MAX_LEDGER:-0}"
  MAX_REMOTE="${MAX_REMOTE:-0}"; MAX_CAS="${MAX_CAS:-0}"
  MAX=$(( MAX_BACKLOG > MAX_LEDGER ? MAX_BACKLOG : MAX_LEDGER ))
  MAX=$(( MAX > MAX_REMOTE ? MAX : MAX_REMOTE ))
  MAX=$(( MAX > MAX_CAS ? MAX : MAX_CAS ))
  NEXT_NUM=$(( MAX + 1 ))
  NEW_ID="DEC-${NEXT_NUM}"
fi

# ── Write reservation to ledger ───────────────────────────────────────────────
if [[ "$LEDGER_WRITABLE" == "true" ]]; then
  {
    if [[ ! -f "$LEDGER_FILE" ]]; then
      printf '# GAAI ID reservation ledger — do not edit manually\n'
    fi
    printf '%s\t%s\t%s\n' "$NEW_ID" "$MODE" "$NOW_EPOCH"
  } >> "$LEDGER_FILE" 2>/dev/null || {
    echo "allocate-id.sh: WARNING: cannot write reservation to ${LEDGER_FILE}" >&2
  }
fi

# ── Release lock before CAS I/O (remote must not stall local sessions) ────────
_release_lock

# ── git-CAS push (outside lock — serialises cross-host reservations) ──────────
# Mechanism: plain non-force push to refs/gaai/reservations; the non-fast-forward rejection
# IS the lease. On NFF loss, re-fetch CAS content, recompute NEW_ID, retry up to 3 times.
# Confirmed = CAS push succeeded. Unconfirmed = all retries exhausted (warns + reconciles at
# next successful push). No --force-with-lease: the plain push IS the CAS.
CAS_CONFIRMED=false
CAS_ATTEMPT=0
CAS_MAX_RETRIES=3

if [[ "$GAAI_RESERVATION_BACKEND" == "git-cas" && "$SCAN_REMOTE" == "true" ]] && \
    git remote get-url "$GAAI_REMOTE" >/dev/null 2>&1; then

  while (( CAS_ATTEMPT < CAS_MAX_RETRIES )); do

    # Build blob: existing CAS content (piped directly to preserve newlines) + new row.
    # Using a process substitution pipe avoids the $() trailing-newline stripping issue.
    _cas_new_blob="$({
      git show "${GIT_CAS_REF}:${GIT_CAS_FILE}" 2>/dev/null || true
      printf '%s\t%s\t%s\n' "$NEW_ID" "$MODE" "$NOW_EPOCH"
    } | git hash-object -w --stdin 2>/dev/null)" || {
      CAS_ATTEMPT=$(( CAS_ATTEMPT + 1 ))
      continue
    }

    # Build tree: one blob entry. TAB between SHA and filename is required by git mktree.
    _cas_new_tree="$(printf '100644 blob %s\t%s\n' "$_cas_new_blob" "$GIT_CAS_FILE" \
      | git mktree 2>/dev/null)" || {
      CAS_ATTEMPT=$(( CAS_ATTEMPT + 1 ))
      continue
    }

    # Get current parent (empty if ref does not exist yet — produces a root commit).
    # --verify ensures output is a real OID; plain rev-parse echoes the input when unresolvable.
    _cas_parent="$(git rev-parse --verify "$GIT_CAS_REF" 2>/dev/null || true)"

    # Build commit with stable author env so no identity configuration is required.
    if [[ -n "$_cas_parent" ]]; then
      _cas_new_commit="$(
        GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gaai}" \
        GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-gaai@localhost}" \
        GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gaai}" \
        GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-gaai@localhost}" \
        GIT_AUTHOR_DATE="${NOW_EPOCH} +0000" \
        GIT_COMMITTER_DATE="${NOW_EPOCH} +0000" \
        git commit-tree -m "reserve ${NEW_ID}" -p "$_cas_parent" "$_cas_new_tree" 2>/dev/null
      )" || { CAS_ATTEMPT=$(( CAS_ATTEMPT + 1 )); continue; }
    else
      _cas_new_commit="$(
        GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gaai}" \
        GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-gaai@localhost}" \
        GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gaai}" \
        GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-gaai@localhost}" \
        GIT_AUTHOR_DATE="${NOW_EPOCH} +0000" \
        GIT_COMMITTER_DATE="${NOW_EPOCH} +0000" \
        git commit-tree -m "reserve ${NEW_ID}" "$_cas_new_tree" 2>/dev/null
      )" || { CAS_ATTEMPT=$(( CAS_ATTEMPT + 1 )); continue; }
    fi

    # Update local ref to point at our commit.
    git update-ref "$GIT_CAS_REF" "$_cas_new_commit" 2>/dev/null || {
      CAS_ATTEMPT=$(( CAS_ATTEMPT + 1 ))
      continue
    }

    # Plain non-force push: NFF rejection = another session won the race → retry.
    if git push "$GAAI_REMOTE" "$GIT_CAS_REF" 2>/dev/null; then
      CAS_CONFIRMED=true
      break
    fi

    # NFF loss: force-fetch to reset local ref to winner's state, recompute NEW_ID.
    # MUST call the mode-specific _cas_max_* helper — using a different mode's helper
    # would use the wrong ID prefix/format (e.g. _cas_max_epic uses EPIC_PREFIX="" for
    # epic mode, which is wrong for dec and would yield incorrect low IDs).
    CAS_CONTENT=""
    _fetch_cas_ref || true

    if [[ "$MODE" == "epic" ]]; then
      _cas_retry_max="$(_cas_max_epic)"
      _cas_retry_max="${_cas_retry_max:-0}"
      _cas_floor=$(( MAX > _cas_retry_max ? MAX : _cas_retry_max ))
      NEXT_NUM=$(( _cas_floor + 1 ))
      NEW_ID="E${NEXT_NUM}"
    elif [[ "$MODE" == "story" ]]; then
      _cas_retry_max="$(_cas_max_story "$EPIC_PREFIX")"
      _cas_retry_max="${_cas_retry_max:-0}"
      _cas_floor=$(( MAX > _cas_retry_max ? MAX : _cas_retry_max ))
      NEXT_NUM=$(( _cas_floor + 1 ))
      NEW_ID="${EPIC_PREFIX}S$(printf '%02d' "$NEXT_NUM")"
    else
      # dec mode: MUST use _cas_max_dec (not _cas_max_epic/_cas_max_story)
      _cas_retry_max="$(_cas_max_dec)"
      _cas_retry_max="${_cas_retry_max:-0}"
      _cas_floor=$(( MAX > _cas_retry_max ? MAX : _cas_retry_max ))
      NEXT_NUM=$(( _cas_floor + 1 ))
      NEW_ID="DEC-${NEXT_NUM}"
    fi

    # Append updated ID to local ledger so concurrent local sessions see it.
    if [[ "$LEDGER_WRITABLE" == "true" ]]; then
      printf '%s\t%s\t%s\n' "$NEW_ID" "$MODE" "$NOW_EPOCH" >> "$LEDGER_FILE" 2>/dev/null || true
    fi

    CAS_ATTEMPT=$(( CAS_ATTEMPT + 1 ))
  done

  if [[ "$CAS_CONFIRMED" == "false" ]]; then
    echo "allocate-id.sh: WARNING: git-CAS reservation UNCONFIRMED — ID ${NEW_ID} may collide with a concurrent unmerged reservation on another host. Reconciliation (re-allocation on detected collision) will occur at the next successful push." >&2
  fi
fi

# ── Output ────────────────────────────────────────────────────────────────────
printf '%s\n' "$NEW_ID"
