#!/usr/bin/env bash
# id-reservation-guard.sh — refuse to publish an Epic or Story id that was not reserved
# GAAI framework (OSS). Project-agnostic — no project-specific references.
#
# Usage:
#   id-reservation-guard.sh pre-push <remote> [<url>]
#       Git pre-push mode: reads the push lines git writes on stdin and checks every branch
#       being pushed. Exit 0 = push may proceed, 1 = push refused.
#   id-reservation-guard.sh check --base <rev> --head <rev> --reservations <rev>
#                                 (--holder <token> | --any-holder)
#       Checks the ids <head> adds since its merge base with <base>, against the reservation
#       record in commit <reservations>. Exit 0 = accepted, 1 = refused, 2 = usage or read error.
#   id-reservation-guard.sh --help
#
# The rule. An Epic or Story id that a push ADDS must have been reserved through allocate-id.sh,
# which records every reservation in the shared record refs/gaai/reservations on the remote.
#   * Definitions are top-level `- id:` rows in any backlog YAML file and canonical artefact
#     files epics/<id>[-slug].epic.md, stories/<id>[-slug].story.md (any sub-directory except
#     archive/; dotted working copies such as <id>.preview.story.md do not count). Before the push means the
#     merge base with the integration branch, or the pushed branch's current remote tip. A row
#     and a file for one id are one id; editing, archiving or moving a definition adds nothing.
#   * A second definition of an id that already has one (before the push, or on the integration
#     tip unseen by this branch) is refused whoever reserved it: that is a collision. Exception:
#     the branch's own work already landed by squash merge (identical artefact files, or in the
#     hook a reservation held by this host) — rebase anyway.
#   * A new id must have a row in reservations.tsv. When that row names a holder (fourth
#     column, written by allocate-id.sh), the holder must be the pushing host's token; an id
#     reserved by another holder is refused. A three-column row predates holders and cannot be
#     attributed: it is accepted with a notice.
#   * A derived id (letter suffix, lettered epic) cannot be allocated by allocate-id.sh. It is
#     accepted when it has a reservation row of its own (holder rule applies) or when its anchor
#     (the numeric story or epic it extends) is defined before the push or accepted in it.
#
# Where it runs.
#   * Locally, as the pre-push hook hooks/pre-push.d/18-id-reservation-guard.sh. This is the only
#     preventive layer for a direct push to the integration branch: a hosted service cannot
#     refuse a direct push. It knows the pushing host, so it enforces the holder rule.
#   * In CI, in check mode with --any-holder: a runner is not the host that reserved the id, so
#     it requires a reservation and no second definition, but not its ownership.
#
# Inert (exit 0, nothing checked) when the remote has no refs/gaai/reservations (the project
# does not use the shared reservation backend) or no integration branch, or for pushes that are
# not branch updates (tags, deletions, the reservation ref itself). Fails CLOSED when the remote
# or a commit cannot be read; unrelated history is checked against the integration tip.
#
# Known limits.
#   * Two sessions on the SAME host share one holder token, so a same-host session that writes
#     an id a sibling session reserved is not detected (allocate-id.sh serialises same-host
#     sessions that use it, through the host ledger). GAAI_RESERVATION_HOLDER gives a session its
#     own token when that matters.
#   * Work moving between hosts: pushing to the branch that already carries another host's ids
#     is accepted (they are on the remote branch); creating a NEW branch from that work on
#     another host is refused for those ids until they land.
#   * Rows written before holders existed are accepted without an ownership check.
#   * Two sessions that both derive the same suffixed id from an existing anchor are not detected.
#   * A `- id:` that is not the first key of its row, or a flow-style row, is not seen.
#   * A push made with hooks disabled is only detected after the fact, by the CI run on the
#     integration branch. The ls-remote runs without a terminal: credentials must come from a
#     credential helper or an ssh agent.
#
# Env vars (all optional):
#   GAAI_ID_GUARD_TARGET_BRANCH  integration branch new ids are measured against (default: staging)
#   GAAI_ID_GUARD_TIMEOUT        seconds bounding each remote operation (default: 30)
#   GAAI_ID_GUARD_BACKLOG_DIR    repo-relative backlog directory
#                                (default: .gaai/project/contexts/backlog)
#   GAAI_ID_GUARD_ARTEFACTS_DIR  repo-relative artefacts directory
#                                (default: .gaai/project/contexts/artefacts)
#   GAAI_RESERVATION_HOLDER      this host's holder token (read through allocate-id.sh holder)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOCATOR="${SELF_DIR}/allocate-id.sh"

TARGET_BRANCH="${GAAI_ID_GUARD_TARGET_BRANCH:-staging}"
REMOTE_TIMEOUT="${GAAI_ID_GUARD_TIMEOUT:-30}"
BACKLOG_DIR="${GAAI_ID_GUARD_BACKLOG_DIR:-.gaai/project/contexts/backlog}"
ARTEFACTS_DIR="${GAAI_ID_GUARD_ARTEFACTS_DIR:-.gaai/project/contexts/artefacts}"
RES_REF="refs/gaai/reservations"
RES_FILE="reservations.tsv"


PREFIX="id-reservation-guard"

_err() { printf '%s: %s\n' "$PREFIX" "$*" >&2; }

_usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

[[ "$REMOTE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || REMOTE_TIMEOUT=30

# ── Bounded command ───────────────────────────────────────────────────────────
# Runs "$@" with a wall-clock bound; stdout passes through. Returns the command's status, or 124
# on expiry. Uses timeout(1)/gtimeout(1) when present, else a background PID poll (stock macOS).
_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "${secs}s" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "${secs}s" "$@"; return $?; fi
  "$@" &
  local pid=$! ticks=0 limit=$(( secs * 10 ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( ticks >= limit )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  wait "$pid"
}

_utc() {
  date -u -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
    || date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
    || printf 'epoch %s' "$1"
}

# ── Id definitions in a commit ────────────────────────────────────────────────
# _defs_at <rev> <out>: writes one "<id>\t<kind>\t<location>\t<blob>" line per DEFINITION of an
# Epic/Story-like id at <rev>. Read from the commit, never from the working tree.
#   Kind R: a `- id:` row of a backlog YAML file (any file, any sub-directory; the template
#     excluded) at that file's top-level item indentation — the indentation of its first
#     `- id:` row — so nested lists of id objects (dependencies, children) are not definitions.
#     Location = the backlog file; blob = "-".
#   Kind F: a canonical epic/story artefact file: <id>.epic.md / <id>.story.md, optionally with a
#     -slug or _slug, anywhere under epics/ or stories/ except an archive/ directory. Dotted
#     variants (<id>.r1-candidate.story.md, <id>.preview.story.md) are working copies, not
#     definitions. Location = the path; blob = its object id.
# A row plus a file for one id is normal; two rows, or two canonical files, are two definitions.
# Returns 2 when the backlog cannot be read (a failed lazy blob fetch must not look like "no ids").
_defs_at() {
  local rev="$1" out="$2" grep_rc
  git grep -I -E '^[[:space:]]*-[[:space:]]+id:' "$rev" -- \
      "${BACKLOG_DIR}/*.yaml" "${BACKLOG_DIR}/*.yml" \
      ":(exclude)${BACKLOG_DIR}/_template.backlog.yaml" > "${out}.rows" 2>/dev/null
  grep_rc=$?
  if (( grep_rc > 1 )); then
    _err "cannot read the backlog at ${rev} (git grep status ${grep_rc})"
    rm -f "${out}.rows"
    return 2
  fi
  {
    # git grep <rev> prints "<rev>:<path>:<line>".
    awk '
      { i = index($0, ":"); rest = substr($0, i + 1); j = index(rest, ":")
        path = substr(rest, 1, j - 1); line = substr(rest, j + 1)
        match(line, /^[[:space:]]*/); ind = RLENGTH
        if (!(path in top)) top[path] = ind
        if (ind != top[path]) next
        sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", line)
        sub(/[[:space:]]*(#.*)?\r?$/, "", line)
        gsub(/^["\047]|["\047]$/, "", line)
        if (line ~ /^E[0-9][A-Za-z0-9]*$/) print line "\tR\t" path "\t-"
      }' "${out}.rows"
    local kind dir
    for kind in epic story; do
      case "$kind" in epic) dir="${ARTEFACTS_DIR}/epics" ;; story) dir="${ARTEFACTS_DIR}/stories" ;; esac
      git ls-tree -r "${rev}:${dir}" 2>/dev/null | awk -v kind="$kind" -v dir="$dir" -F'\t' '
        { split($1, m, " "); path = $2
          if (path ~ /(^|\/)archive\//) next
          n = split(path, parts, "/"); base = parts[n]
          suffix = "." kind ".md"
          if (substr(base, length(base) - length(suffix) + 1) != suffix) next
          stem = substr(base, 1, length(base) - length(suffix))
          if (stem !~ /^E[0-9][A-Za-z0-9]*([-_][^.]*)?$/) next
          match(stem, /^E[0-9][A-Za-z0-9]*/)
          print substr(stem, 1, RLENGTH) "\tF\t" dir "/" path "\t" m[3] }'
    done
  } > "$out"
  rm -f "${out}.rows"
  return 0
}

# ── Decision ──────────────────────────────────────────────────────────────────
# _decide <res> <fork> <remote> <tip> <head> <head-ids> <mode> <holder>
# prior = definitions before this push, per kind: the larger of the fork point and the pushed
# branch's current remote tip. tip = definitions on the target's current tip. For each id of
# <head-ids> (sorted, C locale, so an anchor precedes the ids derived from it):
#   - nothing added (no kind has more definitions than prior) → no decision;
#   - a kind gained a definition while that kind already existed before the push → duplicate;
#   - the id existed before the push in the other kind only → no decision;
#   - the id exists on the target tip but not before the push:
#       · every artefact file of the head is byte-identical to one on the tip, or (hook mode)
#         the reservation is this host's → no decision: the same work already landed (a squash
#         merge leaves the branch without its own commit in the target's history);
#       · otherwise → duplicate (a second definition: the founding collision);
#   - otherwise the id is new → reservation rules.
# Prints: ACCEPT <id> holder|reserved|derived [anchor] · NOTICE <id> unattributed <epoch> ·
#         REFUSE <id> duplicate <prior> <tip> | malformed | unreserved | foreign <holder> <epoch>
#                | anchor <anchor>
_decide() {
  LC_ALL=C awk -F'\t' -v mode="$7" -v me="$8" '
    function anchor_of(id) {
      if (match(id, /^E[0-9]+S[0-9]+/)) return substr(id, 1, RLENGTH)
      match(id, /^E[0-9]+/)
      return substr(id, 1, RLENGTH)
    }
    function mx(a, b) { return a > b ? a : b }
    FNR == 1 { file++ }
    file == 1 { if (!($1 in rseen)) { rseen[$1] = 1; rholder[$1] = $2; repoch[$1] = $3 }; next }
    file == 2 { fk[$1, $2]++; known[$1] = 1; next }
    file == 3 { rk[$1, $2]++; known[$1] = 1; next }
    file == 4 { tk[$1, $2]++; known[$1] = 1; if ($2 == "F") tblob[$1, $4] = 1; next }
    file == 5 { hk[$1, $2]++; if ($2 == "F") { hf[$1]++; if (($1, $4) in tblob) same[$1]++ }; next }
    {
      id = $1
      pR = mx(fk[id, "R"] + 0, rk[id, "R"] + 0); pF = mx(fk[id, "F"] + 0, rk[id, "F"] + 0)
      tR = tk[id, "R"] + 0; tF = tk[id, "F"] + 0
      addR = (hk[id, "R"] + 0 > pR); addF = (hk[id, "F"] + 0 > pF)
      if (!addR && !addF) next
      if ((addR && pR > 0) || (addF && pF > 0)) {
        print "REFUSE\t" id "\tduplicate\t" (pR + pF) "\t" (tR + tF); next
      }
      if (pR + pF > 0) next
      if (tR + tF > 0) {
        if (hf[id] > 0 && same[id] == hf[id]) next
        if (mode == "holder" && (id in rseen) && rholder[id] != "" && rholder[id] == me) next
        print "REFUSE\t" id "\tduplicate\t0\t" (tR + tF); next
      }
      if (id !~ /^E[0-9]+[A-Za-z]?(S[0-9]+[A-Za-z0-9]*)?$/) { print "REFUSE\t" id "\tmalformed"; next }
      if (id in rseen) {
        h = rholder[id]
        if (mode == "any") { ok[id] = 1; print "ACCEPT\t" id "\treserved"; next }
        if (h == "")       { ok[id] = 1; print "NOTICE\t" id "\tunattributed\t" repoch[id]; next }
        if (h == me)       { ok[id] = 1; print "ACCEPT\t" id "\tholder"; next }
        print "REFUSE\t" id "\tforeign\t" h "\t" repoch[id]
        next
      }
      if (id ~ /^E[0-9]+(S[0-9]+)?$/) { print "REFUSE\t" id "\tunreserved"; next }
      a = anchor_of(id)
      if ((a in known) || (a in ok)) { ok[id] = 1; print "ACCEPT\t" id "\tderived\t" a; next }
      print "REFUSE\t" id "\tanchor\t" a
    }
  ' "$1" "$2" "$3" "$4" "$5" "$6"
}

# ── Check one range ───────────────────────────────────────────────────────────
# _check <target-rev> <head-rev> <reservations-rev> <mode any|holder> <holder> <label> [<prior-rev>]
# <target-rev> is the integration branch tip; <prior-rev> (optional) is the pushed branch's current
# remote tip, whose definitions count as already published. Prints refusals (and notices) to
# stderr. Returns 0 accepted, 1 refused, 2 read error.
_check() {
  local base_rev="$1" head_rev="$2" res_rev="$3" mode="$4" me="$5" label="$6" prior_rev="${7:-}"
  local tmp rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gaai-id-guard.XXXXXX")" || { _err "cannot create a temp dir"; return 2; }

  local base_commit head_commit fork
  base_commit="$(git rev-parse --verify --quiet "${base_rev}^{commit}")" \
    || { _err "base ${base_rev} is not a commit"; rm -rf "$tmp"; return 2; }
  head_commit="$(git rev-parse --verify --quiet "${head_rev}^{commit}")" \
    || { _err "head ${head_rev} is not a commit"; rm -rf "$tmp"; return 2; }
  # Unrelated history is measured against the target tip itself, never skipped.
  fork="$(git merge-base "$base_commit" "$head_commit" 2>/dev/null)" || fork="$base_commit"

  if ! git show "${res_rev}:${RES_FILE}" > "$tmp/res.raw" 2>/dev/null; then
    _err "cannot read ${RES_FILE} from the reservation record ${res_rev}"
    rm -rf "$tmp"
    return 2
  fi
  # First row per id wins: it is the original reservation.
  awk -F'\t' '$1 !~ /^#/ && $1 != "" && !seen[$1]++ { print $1 "\t" $4 "\t" $3 }' \
    "$tmp/res.raw" > "$tmp/res.tsv"

  _defs_at "$fork" "$tmp/fork.defs" || { rm -rf "$tmp"; return 2; }
  _defs_at "$head_commit" "$tmp/head.defs" || { rm -rf "$tmp"; return 2; }
  _defs_at "$base_commit" "$tmp/tip.defs" || { rm -rf "$tmp"; return 2; }
  : > "$tmp/remote.defs"
  if [[ -n "$prior_rev" ]] && git cat-file -e "${prior_rev}^{commit}" 2>/dev/null; then
    _defs_at "$prior_rev" "$tmp/remote.defs" || { rm -rf "$tmp"; return 2; }
  fi
  cut -f1 "$tmp/head.defs" | LC_ALL=C sort -u > "$tmp/head.ids"

  # awk counts a file only once it has a first line: keep every input non-empty.
  local f
  for f in res.tsv fork.defs remote.defs tip.defs head.defs head.ids; do
    [[ -s "$tmp/$f" ]] || printf '#\t#\n' > "$tmp/$f"
  done
  _decide "$tmp/res.tsv" "$tmp/fork.defs" "$tmp/remote.defs" "$tmp/tip.defs" "$tmp/head.defs" \
    "$tmp/head.ids" "$mode" "$me" > "$tmp/decisions"

  local kind id reason d1 d2 refused=0
  while IFS=$'\t' read -r kind id reason d1 d2; do
    case "$kind" in
      NOTICE)
        printf '%s: notice: %s is reserved by a row without a holder (%s) — accepted without an ownership check\n' \
          "$PREFIX" "$id" "$(_utc "${d1:-0}")" >&2
        ;;
      REFUSE)
        if (( refused == 0 )); then
          printf '\n❌ %s: %s adds Epic/Story ids it may not publish — refused.\n' \
            "$PREFIX" "$label" >&2
        fi
        refused=$(( refused + 1 ))
        case "$reason" in
          duplicate)
            printf '     %-14s defined again: it already has a definition (%s before this push, %s on the target tip)\n' \
              "$id" "$d1" "$d2" >&2 ;;
          malformed)
            printf '     %-14s is not a valid Epic/Story id\n' "$id" >&2 ;;
          unreserved)
            printf '     %-14s not reserved in %s\n' "$id" "$RES_REF" >&2 ;;
          foreign)
            printf '     %-14s reserved by another holder (%s…, %s), not by this host\n' \
              "$id" "${d1:0:6}" "$(_utc "${d2:-0}")" >&2 ;;
          anchor)
            printf '     %-14s derives from %s, which is neither defined before this push nor accepted in it\n' \
              "$id" "$d1" >&2 ;;
        esac
        ;;
    esac
  done < "$tmp/decisions"

  if (( refused > 0 )); then
    cat >&2 <<EOF
   Every new Epic or Story id must come from .gaai/core/scripts/lib/allocate-id.sh, which
   records it in the shared reservation record (${RES_REF}).
   Not reserved: claim that exact id while it is still free (allocate-id.sh reserve <id>), or
   allocate a fresh one (allocate-id.sh epic | allocate-id.sh story <epic>) and renumber the
   artefact file and the backlog row.
   Reserved by another holder: the id belongs to another session. If this push carries that
   session's own unmerged work, push it to that session's branch; otherwise allocate a fresh id
   and renumber. Do not reuse it.
   Defined again: another definition of that id already exists. If it came from ${TARGET_BRANCH},
   rebase first; otherwise renumber yours.

EOF
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# ── check subcommand ──────────────────────────────────────────────────────────
_cmd_check() {
  local base="" head="" res="" mode="" me=""
  while (( $# > 0 )); do
    case "$1" in
      --base)         base="${2:-}"; shift 2 ;;
      --head)         head="${2:-}"; shift 2 ;;
      --reservations) res="${2:-}"; shift 2 ;;
      --holder)       mode="holder"; me="${2:-}"; shift 2 ;;
      --any-holder)   mode="any"; shift ;;
      *) _err "unknown argument: $1"; return 2 ;;
    esac
  done
  if [[ -z "$base" || -z "$head" || -z "$res" || -z "$mode" ]]; then
    _err "check needs --base, --head, --reservations and one of --holder <token> / --any-holder"
    return 2
  fi
  _check "$base" "$head" "$res" "$mode" "$me" "$head"
}

# ── pre-push subcommand ───────────────────────────────────────────────────────
_cmd_pre_push() {
  local remote="${1:-}"
  if [[ -z "$remote" ]]; then
    _err "pre-push needs the remote name (git passes it as the first hook argument)"
    return 1
  fi

  # Keep only branch updates. Deletions, tags and other refs (the reservation ref itself, which
  # allocate-id.sh pushes) are not publications of backlog content and must cost nothing.
  local candidates="" local_ref local_sha remote_ref remote_sha
  while read -r local_ref local_sha remote_ref remote_sha; do
    [[ -n "${local_sha:-}" && -n "${remote_ref:-}" ]] || continue
    [[ "$local_sha" =~ ^0+$ ]] && continue
    case "$remote_ref" in refs/heads/*) ;; *) continue ;; esac
    [[ "${remote_sha:-}" =~ ^0*$ ]] && remote_sha="-"
    candidates="${candidates}${local_sha} ${remote_ref} ${remote_sha}"$'\n'
  done
  [[ -n "$candidates" ]] || return 0

  local adv
  if ! adv="$(GIT_TERMINAL_PROMPT=0 _bounded "$REMOTE_TIMEOUT" \
        git ls-remote "$remote" "$RES_REF" "refs/heads/${TARGET_BRANCH}" 2>/dev/null)"; then
    printf '\n❌ %s: cannot read %s from %s — push refused.\n' "$PREFIX" "$RES_REF" "$remote" >&2
    printf '   New ids cannot be verified without the shared reservation record. Retry the push.\n' >&2
    printf '   (The check runs without a terminal: credentials must come from a helper or agent.)\n\n' >&2
    return 1
  fi
  local res_sha target_sha
  res_sha="$(printf '%s\n' "$adv" | awk -v r="$RES_REF" '$2 == r { print $1; exit }')"
  target_sha="$(printf '%s\n' "$adv" | awk -v r="refs/heads/${TARGET_BRANCH}" '$2 == r { print $1; exit }')"
  # Inert: this remote does not use the shared reservation record, or has no integration branch.
  [[ -n "$res_sha" && -n "$target_sha" ]] || return 0

  if ! git cat-file -e "${res_sha}^{commit}" 2>/dev/null \
      || ! git cat-file -e "${target_sha}^{commit}" 2>/dev/null; then
    if ! GIT_TERMINAL_PROMPT=0 _bounded "$REMOTE_TIMEOUT" \
          git fetch --quiet --no-tags --no-write-fetch-head --refmap= "$remote" "$RES_REF" "refs/heads/${TARGET_BRANCH}" >/dev/null 2>&1 \
        || ! git cat-file -e "${res_sha}^{commit}" 2>/dev/null \
        || ! git cat-file -e "${target_sha}^{commit}" 2>/dev/null; then
      printf '\n❌ %s: cannot fetch %s and %s from %s — push refused. Retry the push.\n\n' \
        "$PREFIX" "$RES_REF" "$TARGET_BRANCH" "$remote" >&2
      return 1
    fi
  fi

  local me
  me="$(bash "$ALLOCATOR" holder 2>/dev/null)" || me=""

  local status=0 rc
  while read -r local_sha remote_ref remote_sha; do
    [[ -n "$local_sha" ]] || continue
    [[ "$remote_sha" == "-" ]] && remote_sha=""
    _check "$target_sha" "$local_sha" "$res_sha" holder "$me" "push to ${remote_ref#refs/heads/}" "$remote_sha"
    rc=$?
    if (( rc == 2 )); then
      printf '   %s: the push cannot be verified — refused.\n\n' "$PREFIX" >&2
      status=1
    elif (( rc != 0 )); then
      status=1
    fi
  done <<< "$candidates"
  return "$status"
}

case "${1:-}" in
  pre-push) shift; _cmd_pre_push "$@"; exit $? ;;
  check)    shift; _cmd_check "$@"; exit $? ;;
  -h|--help) _usage; exit 0 ;;
  *) _err "usage: id-reservation-guard.sh pre-push <remote> [<url>] | check ... | --help"; exit 2 ;;
esac
