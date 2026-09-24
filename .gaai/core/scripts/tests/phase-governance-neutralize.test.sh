#!/usr/bin/env bash
# phase-governance-neutralize.test.sh — a phase agent cannot self-certify or
# publish through the story branch.
#
# A phase agent that COMMITS an edit to the daemon-owned backlog gets it past _restore_delivery_governance, which
# only reverts uncommitted edits. These cases drive the real admission functions
# against a temporary repository and a bare remote:
#
#   N1  a committed backlog edit is reverted to the merge-base content in the
#       pre-QA seal while a committed skills-index edit (a legitimate
#       deliverable) is kept; the reconcile with a moved target (whose
#       backlog also changed) succeeds; the operator line names paths + commits
#   N2  a branch that never touched governance is left exactly as it was
#   N3  an unreadable repository / merge-base fails closed, before the seal
#   N4  the final boundary (commit phase) reverts an edit a QA agent committed,
#       inside the commit that the final admission seals; and fails closed
#   N5  an open pull request before the commit phase is reported, never
#       mutated, and a failing gh is ignored
#   N8  without a bounded executor the advisory probe is skipped, never unbounded
#   N9  in wrapper context (no notifier loaded) the log lines remain the signal
#
# Hermetic: temp repos only, gh and node stubbed on PATH, nothing pushed to any
# real remote. Run: bash .gaai/core/scripts/tests/phase-governance-neutralize.test.sh

set -uo pipefail
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH="$SCRIPTS/daemon-dispatch.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/gaai-gov-neutralize-XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

unset GIT_EDITOR GAAI_PLAN_MODEL GAAI_QA_MODEL GAAI_IMPL_MODEL
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
git config --global user.email test@example.com
git config --global user.name "GAAI Test"
git config --global init.defaultBranch staging
git config --global core.hooksPath /dev/null

BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
NEIGHBOUR_REL=".gaai/project/contexts/backlog/notes.yaml"
CORE_IDX_REL=".gaai/core/skills/skills-index.yaml"
PROJ_IDX_REL=".gaai/project/skills/skills-index.yaml"

REMOTE="$SANDBOX/remote.git"
SEED="$SANDBOX/seed"
WT_BASE="$SANDBOX/worktrees"
STUB_BIN="$SANDBOX/bin"
GH_CALL_LOG="$SANDBOX/gh-calls.log"
ROUTE_CAPTURE="$SANDBOX/route-capture.log"
NOTIFY_CAPTURE="$SANDBOX/notify-capture.log"
ADMIT_CAPTURE="$SANDBOX/admit-capture.log"
mkdir -p "$WT_BASE" "$STUB_BIN" "$SANDBOX/locks"
: > "$GH_CALL_LOG"; : > "$ROUTE_CAPTURE"; : > "$NOTIFY_CAPTURE"; : > "$ADMIT_CAPTURE"

# ── Remote with a target branch carrying every governance file ──────────────
git init -q --bare "$REMOTE"
git init -q "$SEED"
mkdir -p "$SEED/$(dirname "$BACKLOG_REL")" "$SEED/$(dirname "$CORE_IDX_REL")" \
  "$SEED/$(dirname "$PROJ_IDX_REL")" "$SEED/src"
printf 'items:\n- id: TST-A\n  status: in_progress\n  phase_status: implemented\n- id: TST-OTHER\n  status: refined\n' \
  > "$SEED/$BACKLOG_REL"
printf 'notes: base\n' > "$SEED/$NEIGHBOUR_REL"
printf 'skills:\n- id: core-one\n' > "$SEED/$CORE_IDX_REL"
printf 'skills:\n- id: project-one\n' > "$SEED/$PROJ_IDX_REL"
printf 'base\n' > "$SEED/src/app.txt"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m base
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin staging
BASE_BACKLOG="$(cat "$SEED/$BACKLOG_REL")"
BASE_CORE_IDX="$(cat "$SEED/$CORE_IDX_REL")"
BASE_PROJ_IDX="$(cat "$SEED/$PROJ_IDX_REL")"

# Advance the remote target by editing the backlog in the lines a self-certifying
# edit also touches, so an un-neutralized branch conflicts on reconcile.
advance_target_backlog() {
  git -C "$SEED" pull -q --no-rebase origin staging
  printf 'items:\n- id: TST-A\n  status: in_progress\n  phase_status: implemented\n  claimed_by: daemon\n- id: TST-OTHER\n  status: in_progress\n' \
    > "$SEED/$BACKLOG_REL"
  git -C "$SEED" commit -q -am "backlog: target moved"
  git -C "$SEED" push -q origin staging
}

# New story workspace: a clone on story/<sid> branched from the current target.
make_story() {
  local sid="$1" wt="$WT_BASE/$1-workspace"
  git clone -q "$REMOTE" "$wt"
  git -C "$wt" checkout -q -b "story/$sid" origin/staging
  printf '%s\n' "$wt"
}

# ── Stubs ───────────────────────────────────────────────────────────────────
cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALL_LOG"
if [[ "${GH_STUB_EXIT:-0}" != 0 ]]; then
  echo "gh-stub-stderr: HTTP 502 transport failure" >&2
  exit "$GH_STUB_EXIT"
fi
if [[ "${1:-} ${2:-}" == "pr list" ]]; then
  printf '%s\n' "${GH_STUB_OPEN_PR_URL:-}"
fi
exit 0
GHEOF
chmod +x "$STUB_BIN/gh"
cat > "$STUB_BIN/node" <<'NODEEOF'
#!/usr/bin/env bash
exit 0
NODEEOF
chmod +x "$STUB_BIN/node"
export PATH="$STUB_BIN:$PATH"
export GH_CALL_LOG GH_STUB_EXIT=0 GH_STUB_OPEN_PR_URL=""

export PROJECT_DIR="$SEED" BACKLOG_FILE="$SEED/$BACKLOG_REL" LOCK_DIR="$SANDBOX/locks"
export TARGET_BRANCH=staging GAAI_WORKTREES_BASE="$WT_BASE"
export SCHEDULER="$SCRIPTS/backlog-scheduler.sh"

# shellcheck source=../daemon-dispatch.sh
source "$DISPATCH" 2>/dev/null || true

# The real seal → neutralize → reconcile path runs; only the project command
# gate, the lifecycle journal and notifications are doubled.
_route_admission_block() { printf '%s|%s|%s\n' "$1" "$3" "$4" >> "$ROUTE_CAPTURE"; LOCAL_ADMISSION_OUTCOME="$4"; }
notify_escalation_inline() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$NOTIFY_CAPTURE"; }
# A deterministic bounded executor for the probe's positive paths, so the suite
# never depends on the host shipping timeout/gtimeout (the probe correctly skips
# itself without one — N8 exercises that). The stub drops the duration and runs
# the command; the bound itself is not what these cases test.
cat > "$STUB_BIN/stub-timeout" <<'TOEOF'
#!/usr/bin/env bash
shift
exec "$@"
TOEOF
chmod +x "$STUB_BIN/stub-timeout"
_resolve_timeout_cmd() { printf '%s\n' "$STUB_BIN/stub-timeout"; }
_local_admission_gate() {
  GAAI_ADMITTED_SHA=$(git -C "$4" rev-parse HEAD)
  GAAI_ADMITTED_BASE_SHA=$(git -C "$4" rev-parse "origin/${TARGET_BRANCH}")
  return 0
}

blob_at() { git -C "$1" show "$2:$3" 2>/dev/null; }
seal_of() { git -C "$1" log -1 --format=%H --grep='^\[gaai-local-admission:pre_qa\]$' 2>/dev/null; }

echo ""
echo "=== phase-governance-neutralize ==="

# ── N1: committed self-certification is neutralized before the pre-QA seal ──
echo "--- N1: committed backlog edit reverted, committed skills-index edit kept ---"
SID=TST-A
WT=$(make_story "$SID")
printf 'feature\n' > "$WT/src/app.txt"
printf 'notes: branch\n' > "$WT/$NEIGHBOUR_REL"
git -C "$WT" commit -q -am "feat($SID): implementation"
printf 'items:\n- id: TST-A\n  status: in_progress\n  phase_status: qa_passed\n  pr_status: pending_review\n  pr_url: https://example.invalid/pull/1\n- id: TST-OTHER\n  status: refined\n' \
  > "$WT/$BACKLOG_REL"
git -C "$WT" commit -q -am "chore($SID): mark qa_passed"
N1_BACKLOG_SHA=$(git -C "$WT" rev-parse --short HEAD)
printf 'skills:\n- id: core-one\n- id: core-self-added\n' > "$WT/$CORE_IDX_REL"
git -C "$WT" commit -q -am "chore($SID): index"
N1_INDEX_SHA=$(git -C "$WT" rev-parse --short HEAD)
N1_BRANCH_IDX="$(cat "$WT/$CORE_IDX_REL")"
advance_target_backlog
TARGET_BACKLOG="$(cat "$SEED/$BACKLOG_REL")"
: > "$ROUTE_CAPTURE"; : > "$NOTIFY_CAPTURE"
N1_OUT=$(_prepare_pre_qa_admission "$SID" trace-n1 "$WT" 2>&1); N1_RC=$?
N1_SEAL=$(seal_of "$WT")

if [[ "$N1_RC" -eq 0 && ! -s "$ROUTE_CAPTURE" ]]; then
  pass "N1a: pre-QA admission succeeds (reconcile with the moved target does not conflict)"
else
  fail "N1a: rc=$N1_RC routed=$(tr '\n' ' ' < "$ROUTE_CAPTURE")"
fi
if [[ -n "$N1_SEAL" && "$(blob_at "$WT" "$N1_SEAL" "$BACKLOG_REL")" == "$BASE_BACKLOG" \
      && "$(blob_at "$WT" "$N1_SEAL" "$CORE_IDX_REL")" == "$N1_BRANCH_IDX" ]]; then
  pass "N1b: the seal carries the merge-base backlog and keeps the story's skills-index edit"
else
  fail "N1b: seal=${N1_SEAL:-none} backlog=$(blob_at "$WT" "${N1_SEAL:-HEAD}" "$BACKLOG_REL" | tr '\n' ' ')"
fi
if [[ "$(blob_at "$WT" HEAD "$BACKLOG_REL")" == "$TARGET_BACKLOG" \
      && -z "$(git -C "$WT" diff origin/staging HEAD -- "$BACKLOG_REL" "$PROJ_IDX_REL")" \
      && "$(blob_at "$WT" HEAD "$CORE_IDX_REL")" == "$N1_BRANCH_IDX" ]]; then
  pass "N1c: after reconcile the candidate carries the target's backlog and the story's own index edit"
else
  fail "N1c: governance diff vs target: $(git -C "$WT" diff --stat origin/staging HEAD -- "$BACKLOG_REL" "$CORE_IDX_REL" "$PROJ_IDX_REL" | tr '\n' ' ')"
fi
if [[ "$(blob_at "$WT" HEAD src/app.txt)" == feature && "$(blob_at "$WT" HEAD "$NEIGHBOUR_REL")" == "notes: branch" ]]; then
  pass "N1d: the implementation and a neighbouring non-governance file are untouched"
else
  fail "N1d: non-governance content changed"
fi
N1_LINE=$(printf '%s\n' "$N1_OUT" | grep '^\[GOVERNANCE-NEUTRALIZED\]' || true)
if [[ "$N1_LINE" == *"story=$SID"* && "$N1_LINE" == *"boundary=pre_qa"* \
      && "$N1_LINE" == *"$BACKLOG_REL"* && "$N1_LINE" != *"skills-index"* \
      && "$N1_LINE" == *"$N1_BACKLOG_SHA"* && "$N1_LINE" != *"$N1_INDEX_SHA"* ]]; then
  pass "N1e: one operator line names the story, boundary, the backlog and its commit only"
else
  fail "N1e: line='${N1_LINE}' (expected only commit $N1_BACKLOG_SHA)"
fi
if grep -q "^$SID|governance_neutralized|" "$NOTIFY_CAPTURE"; then
  pass "N1f: the operator is notified where a notifier is loaded (daemon context)"
else
  fail "N1f: no governance_neutralized notification"
fi

# ── N2: a branch that never touched governance is unchanged ─────────────────
echo "--- N2: no governance edits ---"
SID=TST-B
WT=$(make_story "$SID")
printf 'other feature\n' > "$WT/src/app.txt"
git -C "$WT" commit -q -am "feat($SID): implementation"
N2_TREE=$(git -C "$WT" rev-parse 'HEAD^{tree}')
N2_DIRECT_OUT=$(_neutralize_committed_governance "$WT" "$SID" pre_qa 2>&1); N2_DIRECT_RC=$?
if [[ "$N2_DIRECT_RC" -eq 0 && -z "$N2_DIRECT_OUT" && -z "$(git -C "$WT" status --porcelain)" ]]; then
  pass "N2a: the helper returns 0, says nothing and leaves the tree clean"
else
  fail "N2a: rc=$N2_DIRECT_RC out='${N2_DIRECT_OUT}' status=$(git -C "$WT" status --porcelain | tr '\n' ' ')"
fi
: > "$ROUTE_CAPTURE"
N2_OUT=$(_prepare_pre_qa_admission "$SID" trace-n2 "$WT" 2>&1); N2_RC=$?
N2_SEAL=$(seal_of "$WT")
if [[ "$N2_RC" -eq 0 && -n "$N2_SEAL" && "$(git -C "$WT" rev-parse "${N2_SEAL}^{tree}")" == "$N2_TREE" \
      && "$N2_OUT" != *GOVERNANCE-NEUTRALIZED* ]]; then
  pass "N2b: the seal tree is exactly the implementation tree; no neutralization reported"
else
  fail "N2b: rc=$N2_RC seal=${N2_SEAL:-none} out=$(printf '%s' "$N2_OUT" | tr '\n' ' ')"
fi

# ── N3: unreadable repository or merge-base fails closed ────────────────────
echo "--- N3: fail closed ---"
mkdir -p "$SANDBOX/not-a-repo"
if _neutralize_committed_governance "$SANDBOX/not-a-repo" TST-X pre_qa >/dev/null 2>&1; then
  fail "N3a: a directory that is not a repository was accepted"
else
  pass "N3a: a directory that is not a repository returns non-zero"
fi
SID=TST-C
WT="$WT_BASE/$SID-workspace"
git clone -q "$REMOTE" "$WT"
git -C "$WT" checkout -q --orphan "story/$SID"
printf 'unrelated\n' > "$WT/src/app.txt"
printf 'items: []\n' > "$WT/$BACKLOG_REL"
git -C "$WT" add -A
git -C "$WT" commit -q -m "unrelated history"
N3_HEAD=$(git -C "$WT" rev-parse HEAD)
: > "$ROUTE_CAPTURE"
_prepare_pre_qa_admission "$SID" trace-n3 "$WT" >/dev/null 2>&1; N3_RC=$?
if [[ "$N3_RC" -ne 0 ]] && grep -q "^$SID|pre_qa|blocked:governance_neutralize_failed$" "$ROUTE_CAPTURE" \
    && [[ "$(git -C "$WT" rev-parse HEAD)" == "$N3_HEAD" ]]; then
  pass "N3b: no merge-base routes blocked:governance_neutralize_failed before any seal commit"
else
  fail "N3b: rc=$N3_RC routed=$(tr '\n' ' ' < "$ROUTE_CAPTURE") head_moved=$([[ "$(git -C "$WT" rev-parse HEAD)" != "$N3_HEAD" ]] && echo yes || echo no)"
fi

# ── N4: the final boundary neutralizes what the QA phase committed ──────────
echo "--- N4: final boundary (commit phase) ---"
get_phase_status()             { echo qa_passed; }
get_story_title()              { echo "fixture story"; }
get_related_decs()             { :; }
_ensure_corepack_pnpm_intact() { return 0; }
_ensure_worktree_deps_fresh()  { return 0; }
_check_worktree_integrity()    { return 0; }
_emit_commit_routing_record()  { :; }
gaai_provenance_publish()      { return 0; }
REAL_ADMIT_DEF=$(declare -f _admit_current_candidate)
_admit_current_candidate() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$(git -C "$4" rev-parse HEAD)" \
    "$(git -C "$4" status --porcelain | wc -l | tr -d ' ')" >> "$ADMIT_CAPTURE"
  git -C "$4" show "HEAD:$BACKLOG_REL" > "$SANDBOX/admitted-backlog" 2>/dev/null
  git -C "$4" show "HEAD:$PROJ_IDX_REL" > "$SANDBOX/admitted-proj-idx" 2>/dev/null
  return 1   # stop before any publication
}
SID=TST-A
WT="$WT_BASE/$SID-workspace"
N4_MB_BACKLOG=$(git -C "$WT" show "$(git -C "$WT" merge-base HEAD origin/staging):$BACKLOG_REL")
printf 'items:\n- id: TST-A\n  status: done\n  phase_status: done\n' > "$WT/$BACKLOG_REL"
printf 'skills:\n- id: project-one\n- id: qa-added\n' > "$WT/$PROJ_IDX_REL"
git -C "$WT" commit -q -am "chore($SID): qa marks itself done"
N4_QA_SHA=$(git -C "$WT" rev-parse --short HEAD)
N4_QA_IDX="$(cat "$WT/$PROJ_IDX_REL")"
mkdir -p "$WT/.gaai/project/contexts/artefacts/qa-reports"
printf '## Verdict: PASS\n' > "$WT/.gaai/project/contexts/artefacts/qa-reports/$SID.qa-report.md"
: > "$ADMIT_CAPTURE"; : > "$ROUTE_CAPTURE"
N4_OUT=$(handle_commit_phase "$SID" trace-n4 2>&1); N4_RC=$?
N4_ADMIT=$(head -1 "$ADMIT_CAPTURE")
if [[ "$N4_ADMIT" == final\|"$SID"\|*\|0 && "$(cat "$SANDBOX/admitted-backlog")" == "$N4_MB_BACKLOG" \
      && "$(cat "$SANDBOX/admitted-proj-idx")" == "$N4_QA_IDX" ]]; then
  pass "N4a: the exact SHA handed to final admission carries the merge-base backlog and keeps the committed index edit, on a clean tree"
else
  fail "N4a: admit='${N4_ADMIT}' backlog=$(tr '\n' ' ' < "$SANDBOX/admitted-backlog" 2>/dev/null)"
fi
N4_ADMITTED_SHA=$(printf '%s' "$N4_ADMIT" | cut -d'|' -f3)
if [[ -n "$N4_ADMITTED_SHA" ]] \
    && git -C "$WT" show --name-only --format= "$N4_ADMITTED_SHA" | grep -qx ".gaai/project/contexts/artefacts/qa-reports/$SID.qa-report.md"; then
  pass "N4b: the revert rides in the commit phase's own commit, with the QA evidence"
else
  fail "N4b: the admitted commit does not carry the QA report"
fi
N4_LINE=$(printf '%s\n' "$N4_OUT" | grep '^\[GOVERNANCE-NEUTRALIZED\]' || true)
if [[ "$N4_LINE" == *"story=$SID"* && "$N4_LINE" == *"boundary=final"* \
      && "$N4_LINE" == *"$BACKLOG_REL"* && "$N4_LINE" != *"skills-index"* && "$N4_LINE" == *"$N4_QA_SHA"* ]]; then
  pass "N4c: the final-boundary line names the backlog only and the QA commit"
else
  fail "N4c: line='${N4_LINE}' (expected commit $N4_QA_SHA)"
fi
# Fail closed at the final boundary: no merge-base → routed, never admitted.
SID=TST-C
WT="$WT_BASE/$SID-workspace"
: > "$ADMIT_CAPTURE"; : > "$ROUTE_CAPTURE"
handle_commit_phase "$SID" trace-n4c >/dev/null 2>&1; N4C_RC=$?
if [[ "$N4C_RC" -ne 0 && ! -s "$ADMIT_CAPTURE" ]] \
    && grep -q "^$SID|final|blocked:governance_neutralize_failed$" "$ROUTE_CAPTURE"; then
  pass "N4d: an unreadable merge-base routes blocked:governance_neutralize_failed and never reaches admission"
else
  fail "N4d: rc=$N4C_RC admitted=$(tr '\n' ' ' < "$ADMIT_CAPTURE") routed=$(tr '\n' ' ' < "$ROUTE_CAPTURE")"
fi

# ── N5: an early pull request is reported, never mutated; gh failure ignored ──
echo "--- N5: early publication detection ---"
eval "$REAL_ADMIT_DEF"   # back to the real reconcile + (doubled) gate
new_story_with_change() {
  local sid="$1" wt
  wt=$(make_story "$sid")
  printf '%s\n' "$sid" > "$wt/src/app.txt"
  git -C "$wt" commit -q -am "feat($sid): implementation"
  printf '%s\n' "$wt"
}

SID=TST-D
WT=$(new_story_with_change "$SID")
: > "$GH_CALL_LOG"; : > "$NOTIFY_CAPTURE"; : > "$ROUTE_CAPTURE"
GH_STUB_OPEN_PR_URL="https://example.invalid/pull/42"
N5_OUT=$(_prepare_pre_qa_admission "$SID" trace-n5 "$WT" 2>&1); N5_RC=$?
GH_STUB_OPEN_PR_URL=""
if printf '%s\n' "$N5_OUT" | grep -qF "[PHASE-PUBLICATION] story=$SID pr=https://example.invalid/pull/42 — a pull request exists before the commit phase" \
    && grep -q "^$SID|phase_publication|" "$NOTIFY_CAPTURE"; then
  pass "N5a: an open pull request is reported and notified"
else
  fail "N5a: out=$(printf '%s' "$N5_OUT" | tr '\n' ' ') calls=$(tr '\n' ';' < "$GH_CALL_LOG")"
fi
if [[ "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" -eq 1 ]] \
    && grep -q "^gh pr list --head story/$SID --state open " "$GH_CALL_LOG" \
    && ! grep -qE 'gh pr (create|close|comment|edit|merge|ready)|gh api|--add-label' "$GH_CALL_LOG"; then
  pass "N5b: exactly one read-only query; nothing is closed, commented or labelled"
else
  fail "N5b: gh calls: $(tr '\n' ';' < "$GH_CALL_LOG")"
fi
if [[ "$N5_RC" -eq 0 && ! -s "$ROUTE_CAPTURE" ]]; then
  pass "N5c: detection never blocks the admission"
else
  fail "N5c: rc=$N5_RC routed=$(tr '\n' ' ' < "$ROUTE_CAPTURE")"
fi
SID=TST-E
WT=$(new_story_with_change "$SID")
: > "$GH_CALL_LOG"; : > "$NOTIFY_CAPTURE"; : > "$ROUTE_CAPTURE"
GH_STUB_EXIT=1
N5E_OUT=$(_prepare_pre_qa_admission "$SID" trace-n5e "$WT" 2>&1); N5E_RC=$?
GH_STUB_EXIT=0
if [[ "$N5E_RC" -eq 0 && ! -s "$ROUTE_CAPTURE" && ! -s "$NOTIFY_CAPTURE" ]] \
    && grep -q "^gh pr list --head story/$SID" "$GH_CALL_LOG" \
    && [[ "$N5E_OUT" != *PHASE-PUBLICATION* && "$N5E_OUT" != *gh-stub-stderr* ]]; then
  pass "N5d: a failing gh is queried once and ignored silently"
else
  fail "N5d: rc=$N5E_RC out=$(printf '%s' "$N5E_OUT" | tr '\n' ' ') calls=$(tr '\n' ';' < "$GH_CALL_LOG")"
fi

# ── N6: the neutralized set is exactly the backlog, within the restore set ──
# The skills indexes stay in the uncommitted restore but out of the committed
# neutralization: a Story that adds a skill ships its index edit legitimately.
echo "--- N6: neutralized path set ---"
N6_RESTORE=$(declare -f _restore_delivery_governance 2>/dev/null | grep -oE '\.gaai/[A-Za-z0-9_./-]+\.yaml' | sort -u)
N6_NEUTRAL=$(declare -f _neutralize_committed_governance 2>/dev/null | grep -oE '\.gaai/[A-Za-z0-9_./-]+\.yaml' | sort -u)
if [[ "$N6_NEUTRAL" == ".gaai/project/contexts/backlog/active.backlog.yaml" ]] \
    && grep -qxF "$N6_NEUTRAL" <<<"$N6_RESTORE"; then
  pass "N6: only the backlog is neutralized, and it is one of the restored paths"
else
  fail "N6: restore=[$(printf '%s' "$N6_RESTORE" | tr '\n' ' ')] neutralize=[$(printf '%s' "$N6_NEUTRAL" | tr '\n' ' ')]"
fi

# ── N7: both helpers are safe under the daemon's `set -euo pipefail` ────────
echo "--- N7: set -e compatibility ---"
SID=TST-F
WT=$(new_story_with_change "$SID")
printf 'items: []\n' > "$WT/$BACKLOG_REL"
git -C "$WT" commit -q -am "chore($SID): backlog"
N7_OUT=$(
  set -euo pipefail
  GH_STUB_EXIT=1 _detect_phase_publication "$WT" "$SID"
  _neutralize_committed_governance "$WT" "$SID" pre_qa
  git -C "$WT" commit -q -m "seal"
  _neutralize_committed_governance "$WT" "$SID" pre_qa   # after the commit: nothing left to do
  echo reached-end
) ; N7_RC=$?
if [[ "$N7_RC" -eq 0 && "$N7_OUT" == *reached-end* \
      && "$(printf '%s\n' "$N7_OUT" | grep -c '^\[GOVERNANCE-NEUTRALIZED\]')" -eq 1 ]]; then
  pass "N7: under set -e both helpers run to completion; the second pass is a silent no-op"
else
  fail "N7: rc=$N7_RC out=$(printf '%s' "$N7_OUT" | tr '\n' ' ')"
fi

# ── N8: without a bounded executor the advisory probe never runs ────────────
# A gh call that hangs must not stall admission: with no timeout/gtimeout the
# probe is skipped entirely rather than run unbounded.
echo "--- N8: no bounded executor → probe skipped ---"
SID=TST-G
WT=$(new_story_with_change "$SID")
: > "$GH_CALL_LOG"
N8_OUT=$(
  _resolve_timeout_cmd() { return 1; }
  GH_STUB_OPEN_PR_URL="https://example.invalid/pull/43" _detect_phase_publication "$WT" "$SID"; echo "rc=$?"
)
if [[ "$N8_OUT" == *"rc=0"* && "$N8_OUT" != *"[PHASE-PUBLICATION]"* && ! -s "$GH_CALL_LOG" ]]; then
  pass "N8: no timeout utility → no gh call, no stall, rc=0"
else
  fail "N8: out=$(printf '%s' "$N8_OUT" | tr '\n' ' ') calls=$(tr '\n' ';' < "$GH_CALL_LOG")"
fi

# ── N9: in the phase wrapper no notifier is loaded; the log line is the signal ──
# The wrapper sources only daemon-dispatch.sh, where notify_escalation_inline is
# not defined. Both helpers must still emit their operator line and succeed.
echo "--- N9: no notifier loaded (wrapper context) ---"
SID=TST-H
WT=$(new_story_with_change "$SID")
printf 'items: []\n' > "$WT/$BACKLOG_REL"
git -C "$WT" commit -q -am "chore($SID): backlog"
: > "$NOTIFY_CAPTURE"
N9_OUT=$(
  unset -f notify_escalation_inline
  _neutralize_committed_governance "$WT" "$SID" pre_qa; echo "n_rc=$?"
  GH_STUB_OPEN_PR_URL="https://example.invalid/pull/44" _detect_phase_publication "$WT" "$SID"; echo "p_rc=$?"
)
if [[ "$N9_OUT" == *"n_rc=0"* && "$N9_OUT" == *"p_rc=0"* \
      && "$N9_OUT" == *"[GOVERNANCE-NEUTRALIZED] story=$SID"* \
      && "$N9_OUT" == *"[PHASE-PUBLICATION] story=$SID"* && ! -s "$NOTIFY_CAPTURE" ]]; then
  pass "N9: without a notifier both operator lines are still emitted and nothing fails"
else
  fail "N9: out=$(printf '%s' "$N9_OUT" | tr '\n' ' ')"
fi

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
