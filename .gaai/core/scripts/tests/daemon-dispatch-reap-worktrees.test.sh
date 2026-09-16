#!/usr/bin/env bash
# ── daemon-dispatch-reap-worktrees.test.sh ────────────────────────────────────
# reap_orphaned_worktrees: reclaim ON-DISK worktree dirs whose delivery has
# concluded — the disk-leak guard that complements reconcile_done_merged_worktrees()
# (which only sees active-backlog `done` ids and so never reclaims archived-done /
# escalated / failed / branch-deleted worktrees).
#
# Builds a real git fixture (bare remote + worktrees) and stubs `gh`/`tmux` on PATH.
# `git` is never stubbed — removals are real `git worktree remove` calls.
#
# T1: PR MERGED + clean + not-live            → removed (even with divergent local commits)
# T2: HEAD already integrated (ancestor)      → removed (signal 2, no PR)
# T3: no PR + HEAD diverged (unmerged work)   → KEPT
# T4: PR MERGED but worktree dirty            → KEPT (data-safety guard wins)
# T5: PR MERGED but live tmux session         → KEPT (live guard wins)
# T6: PR MERGED but fresh heartbeat (<120s)   → KEPT (live guard wins)
# T7: throttle — fresh .wt-reap.last marker   → no-op (nothing removed)
# T8: PR MERGED in an EARLIER cycle (guard says stale) → KEPT (branch names recur)
# T9: PR CLOSED: current cycle → removed; earlier cycle → KEPT
# T10: cycle guard not loaded in this context   → KEPT (signal not trusted)
# T11: fetch of origin/<target> fails            → sweep skipped, nothing removed
# (concrete IDs are generic placeholders — this file is mirrored to public OSS)
#
# Run: bash .gaai/core/scripts/tests/daemon-dispatch-reap-worktrees.test.sh
# Exit 0 = all pass.

set -uo pipefail
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BACKLOG_FILE="/tmp/gaai-reapwt-test-backlog.yaml"
SCHEDULER="$(which true)"
export PROJECT_DIR BACKLOG_FILE SCHEDULER

# Source the library under test (defines reap_orphaned_worktrees). Tolerate the
# best-effort sub-source of worktree-integrity.sh exactly as the daemon does.
source "$SCRIPT_DIR/../daemon-dispatch.sh" 2>/dev/null || true

# Quiet log + neutral colours (delivery-daemon.sh normally provides these).
log() { :; }
CYAN=""; YELLOW=""; NC=""

# ── Fixture sandbox ───────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d /tmp/gaai-reapwt-XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

REMOTE="$SANDBOX/remote.git"
REPO="$SANDBOX/repo"
WTS="$SANDBOX/wts"
LOCK_DIR="$SANDBOX/locks"
mkdir -p "$WTS" "$LOCK_DIR"

git init --quiet --bare "$REMOTE"
git init --quiet "$REPO"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
git -C "$REPO" checkout -q -b staging
echo seed > "$REPO/seed.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m seed
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin staging
git -C "$REPO" fetch -q origin staging

# Override the globals reap_orphaned_worktrees reads.
PROJECT_DIR="$REPO"
TARGET_BRANCH="staging"
export GAAI_WORKTREES_BASE="$WTS"
export GAAI_WT_REAP_INTERVAL_SEC=0   # never throttle (except the explicit T7 case)

# ── Stub gh + tmux on PATH (git stays real) ──────────────────────────────────
STUB_BIN="$SANDBOX/bin"
GH_STATES="$SANDBOX/gh-states"     # one file per sid → its PR state
TMUX_LIVE="$SANDBOX/tmux-live"     # presence of file <sid> → has-session true
mkdir -p "$STUB_BIN" "$GH_STATES" "$TMUX_LIVE"

cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
sid=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--head" ]]; then shift; sid="${1#story/}"; fi
  shift
done
if [[ -n "$sid" && -f "$GH_STATES/$sid" ]]; then
  state="$(cat "$GH_STATES/$sid")"
  merged=null; closed=null
  [[ "$state" == MERGED ]] && merged='"2026-01-03T00:00:00Z"'
  [[ "$state" == CLOSED ]] && closed='"2026-01-03T00:00:00Z"'
  printf '[{"number":41,"state":"%s","createdAt":"2026-01-02T00:00:00Z","mergedAt":%s,"closedAt":%s}]' "$state" "$merged" "$closed"
else
  printf '[]'
fi
EOF
cat > "$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "has-session" ]]; then
  sid=""
  for a in "$@"; do case "$a" in gaai-deliver-*) sid="${a#gaai-deliver-}";; esac; done
  [[ -n "$sid" && -f "$TMUX_LIVE/$sid" ]] && exit 0 || exit 1
fi
exit 0
EOF
chmod +x "$STUB_BIN/gh" "$STUB_BIN/tmux"
export GH_STATES TMUX_LIVE
PATH="$STUB_BIN:$PATH"

# Cycle-guard fixture. The daemon defines _merged_pr_is_current_cycle in
# delivery-daemon.sh; the reaper must consult it before trusting a MERGED/CLOSED
# PR, because story branch names recur across cycles. Here it records its
# arguments and answers "not current cycle" when <sid>.stale exists.
GUARD_CALLS="$SANDBOX/guard-calls"; mkdir -p "$GUARD_CALLS"
_merged_pr_is_current_cycle() {
  printf '%s\n' "$*" > "$GUARD_CALLS/$1"
  [[ ! -f "$GH_STATES/$1.stale" ]]
}

# ── Helpers ───────────────────────────────────────────────────────────────────
mk_wt() {  # mk_wt <sid> : create a worktree on a fresh story/<sid> branch off staging
  git -C "$REPO" worktree add -q -b "story/$1" "$WTS/$1-workspace" origin/staging
}
diverge() { echo "extra-$1" > "$WTS/$1-workspace/extra.txt"; git -C "$WTS/$1-workspace" add -A; git -C "$WTS/$1-workspace" commit -q -m "diverge $1"; }
exists() { [[ -d "$WTS/$1-workspace" ]]; }

# ── Build scenarios ───────────────────────────────────────────────────────────
mk_wt MERGEDX;  diverge MERGEDX;  echo MERGED  > "$GH_STATES/MERGEDX"   # T1
mk_wt INTEGX;                       :           > /dev/null             # T2: HEAD == origin/staging (ancestor), no PR
mk_wt UNMERGX; diverge UNMERGX                                          # T3: diverged, no PR
mk_wt DIRTYX;   echo MERGED > "$GH_STATES/DIRTYX"; echo wip > "$WTS/DIRTYX-workspace/wip.txt"  # T4: dirty (untracked)
mk_wt LIVEX;    echo MERGED > "$GH_STATES/LIVEX";  : > "$TMUX_LIVE/LIVEX"                       # T5: live tmux
mk_wt HBX;      echo MERGED > "$GH_STATES/HBX";    touch "$LOCK_DIR/HBX.heartbeat"             # T6: fresh heartbeat

# ── Run the reaper ────────────────────────────────────────────────────────────
reap_orphaned_worktrees

# ── Assertions ────────────────────────────────────────────────────────────────
exists MERGEDX && fail "T1: MERGED+clean worktree should be removed" || pass "T1: MERGED+clean → removed (divergent local commits ignored)"
if [[ "$(cat "$GUARD_CALLS/MERGEDX" 2>/dev/null)" == "MERGEDX 2026-01-02T00:00:00Z 2026-01-03T00:00:00Z 41" ]]; then
  pass "T1b: the cycle guard received the PR's creation and merge instants and number"
else
  fail "T1b: cycle guard not consulted with the PR instants (got: $(cat "$GUARD_CALLS/MERGEDX" 2>/dev/null || echo none))"
fi
exists INTEGX  && fail "T2: integrated (ancestor) worktree should be removed" || pass "T2: HEAD integrated → removed via ancestor signal"
exists UNMERGX || fail "T3: unmerged/no-PR worktree must be KEPT"; exists UNMERGX && pass "T3: unmerged + no PR → kept"
exists DIRTYX  || fail "T4: dirty worktree must be KEPT despite MERGED PR"; exists DIRTYX && pass "T4: dirty → kept (data-safety guard wins)"
exists LIVEX   || fail "T5: live-tmux worktree must be KEPT despite MERGED PR"; exists LIVEX && pass "T5: live tmux → kept"
exists HBX     || fail "T6: fresh-heartbeat worktree must be KEPT despite MERGED PR"; exists HBX && pass "T6: fresh heartbeat → kept"

# ── T7: throttle — a fresh marker short-circuits the whole sweep ──────────────
mk_wt THROTX; echo MERGED > "$GH_STATES/THROTX"; diverge THROTX
GAAI_WT_REAP_INTERVAL_SEC=1800
date +%s > "$LOCK_DIR/.wt-reap.last"
reap_orphaned_worktrees
exists THROTX && pass "T7: fresh throttle marker → sweep is a no-op" || fail "T7: throttle marker ignored — sweep ran when it should not have"

# ── T8: MERGED PR from an earlier cycle (guard says stale) ───────────────────
GAAI_WT_REAP_INTERVAL_SEC=0; rm -f "$LOCK_DIR/.wt-reap.last"
mk_wt STALEX; diverge STALEX; echo MERGED > "$GH_STATES/STALEX"; : > "$GH_STATES/STALEX.stale"
reap_orphaned_worktrees
exists STALEX && pass "T8: MERGED PR of an earlier cycle → kept" || fail "T8: a MERGED PR from an earlier cycle reaped a live cycle's worktree"

# ── T9: CLOSED PR — current cycle removes, earlier cycle keeps ───────────────
mk_wt CLOSEDX; diverge CLOSEDX; echo CLOSED > "$GH_STATES/CLOSEDX"
mk_wt CLOSEDOLDX; diverge CLOSEDOLDX; echo CLOSED > "$GH_STATES/CLOSEDOLDX"; : > "$GH_STATES/CLOSEDOLDX.stale"
reap_orphaned_worktrees
exists CLOSEDX && fail "T9a: CLOSED PR of the current cycle should remove the worktree" || pass "T9a: CLOSED PR of the current cycle → removed"
[[ "$(cat "$GUARD_CALLS/CLOSEDX" 2>/dev/null)" == "CLOSEDX 2026-01-02T00:00:00Z 2026-01-03T00:00:00Z 41" ]] \
  && pass "T9b: a CLOSED PR is judged on its closedAt instant" || fail "T9b: closedAt not passed to the guard for a CLOSED PR"
exists CLOSEDOLDX && pass "T9c: CLOSED PR of an earlier cycle → kept" || fail "T9c: an earlier cycle's CLOSED PR reaped a live worktree"

# ── T10: guard not loaded in this context → signal not trusted ───────────────
mk_wt NOGUARDX; diverge NOGUARDX; echo MERGED > "$GH_STATES/NOGUARDX"
_saved_guard=$(declare -f _merged_pr_is_current_cycle); unset -f _merged_pr_is_current_cycle
reap_orphaned_worktrees
eval "$_saved_guard"
exists NOGUARDX && pass "T10: cycle guard absent → MERGED signal ignored, kept" || fail "T10: reaped on a MERGED PR without a cycle guard"

# ── T11: fetch failure → sweep skipped ───────────────────────────────────────
mk_wt FETCHX; diverge FETCHX; echo MERGED > "$GH_STATES/FETCHX"
git -C "$REPO" remote set-url origin "$SANDBOX/does-not-exist.git"
reap_orphaned_worktrees
git -C "$REPO" remote set-url origin "$REMOTE"
exists FETCHX && pass "T11: failed fetch → sweep skipped, nothing removed" || fail "T11: reaped against a stale origin ref after a failed fetch"
reap_orphaned_worktrees
exists FETCHX && fail "T11b: with the fetch restored the same worktree should be removed" || pass "T11b: fetch restored → removed on the next sweep"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "  ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
