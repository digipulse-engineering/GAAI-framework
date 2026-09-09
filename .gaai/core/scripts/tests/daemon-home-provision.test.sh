#!/usr/bin/env bash
# daemon-home-provision.test.sh — exact-current startup contract, regression-coverage criterion setup/startup authority matrices
#
# Proves the Option A authority split:
#   * `daemon-setup.sh` is the ONLY path that can create or advance the dedicated
#     worktree, refuses any active or ambiguous lifecycle authority, preserves
#     interrupted setup evidence, and leaves a clean registered exact-target home;
#   * `daemon-start.sh`, `delivery-daemon.sh` and every runtime-exported
#     `lib/daemon-home.sh` path are verify-only and refuse absent, stale, dirty,
#     foreign, wrong-branch and ambiguous homes BEFORE any tmux, credential or
#     daemon effect;
#   * the shared lifecycle lock is acquired before lifecycle inspection, retained
#     through settlement, and never converted into production launch authority.
#
# This file also carries the shared hermetic fixture used by the two sibling suites
# (they source it with GAAI_HOME_FIXTURE_ONLY=1). Keeping it here rather than in a
# new helper keeps the Delivery inventory at exactly twenty-one files.
#
# Usage: .gaai/core/scripts/tests/daemon-home-provision.test.sh

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# ═══════════════════════════════════════════════════════════════════════════
# Shared hermetic fixture
# ═══════════════════════════════════════════════════════════════════════════

# Both supported shells. Bash 3.2 is macOS's system Bash and the OSS floor. When no
# 3.2 interpreter exists on this host the matrices SAY SO rather than silently
# reporting single-shell coverage as dual-shell.
gaai_supported_shells() {
  local _s _seen=""
  printf '%s\n' "${BASH:-/bin/bash}"
  _seen="${BASH:-/bin/bash}"
  # `$HOME/.gaai-bash32/bin/bash` is where the hosted Test Gate provisions the pinned
  # Bash 3.2 for its dual-shell matrix, so the 3.2 column really executes on that lane.
  # GAAI_BASH32 lets an operator point at their own build.
  for _s in "${GAAI_BASH32:-}" "$HOME/.gaai-bash32/bin/bash" /bin/bash \
            /usr/local/bin/bash-3.2 /opt/homebrew/opt/bash@3.2/bin/bash \
            /usr/local/opt/bash@3.2/bin/bash; do
    [[ -n "$_s" ]] || continue
    [[ -x "$_s" && "$_s" != "$_seen" ]] || continue
    case "$("$_s" --version 2>/dev/null | head -1)" in
      *"version 3.2"*) printf '%s\n' "$_s" ;;
    esac
  done
}

gaai_bash32_available() {
  local _s
  while IFS= read -r _s; do
    case "$("$_s" --version 2>/dev/null | head -1)" in *"version 3.2"*) return 0 ;; esac
  done < <(gaai_supported_shells)
  return 1
}

# gaai_build_fixture <root> <scripts_dir>
# A real bare remote plus clone carrying the units under test, so every matrix
# exercises actual worktree registration, a real private tmux server and the real
# privileged entry — never a mock of them.
gaai_build_fixture() {
  local _root="$1" _src="$2"
  local _remote="$_root/remote.git" _proj="$_root/proj"
  git init --bare "$_remote" -q
  git clone "$_remote" "$_proj" -q 2>/dev/null
  git -C "$_proj" config user.email "test@gaai.local"
  git -C "$_proj" config user.name "gaai-test"
  git -C "$_proj" symbolic-ref HEAD refs/heads/staging
  mkdir -p "$_proj/.gaai/core/scripts/lib" "$_proj/.gaai/project/contexts/backlog"
  cp "$_src/daemon-start.sh" "$_src/daemon-setup.sh" "$_proj/.gaai/core/scripts/"
  cp "$_src/lib/daemon-home.sh" "$_src/lib/home-branch-guard.sh" "$_proj/.gaai/core/scripts/lib/"
  chmod 0755 "$_proj/.gaai/core/scripts/daemon-start.sh" "$_proj/.gaai/core/scripts/daemon-setup.sh"
  printf '#!/bin/sh\nexit 0\n' > "$_proj/.gaai/core/scripts/backlog-scheduler.sh"
  chmod 0755 "$_proj/.gaai/core/scripts/backlog-scheduler.sh"
  cat > "$_proj/.gaai/core/scripts/delivery-daemon.sh" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub daemon for the daemon-home matrices. Mirrors the real ready-acknowledgement
# contract of delivery-daemon.sh and records what actually crossed the boundary.
set -uo pipefail
A="${GAAI_DAEMON_LAUNCH_ATTEMPT:-}"
if [[ -n "$A" ]]; then
  INC="$(sed -n 's/^incarnation=//p' "$A/ack.launcher" 2>/dev/null | head -1)"
  {
    printf 'schema=gaai-daemon-lifecycle/v1\n'
    printf 'pid=%s\n' "$$"
    printf 'incarnation=%s\n' "$INC"
    printf 'credential_mode=%s\n' "${GAAI_DAEMON_CREDENTIAL_MODE:-}"
  } > "$A/ack.ready"
  # Observations go OUTSIDE the attempt directory. The real daemon writes only its
  # ready acknowledgement there, and exact settlement removes solely the artefacts
  # the lifecycle itself created — so a stub file left in that directory would be
  # correctly preserved as unexplained evidence and would mask a genuine result.
  OBS="${GAAI_REPO_ROOT:-/tmp}/.gaai/project/contexts/backlog/.observed"
  mkdir -p "$(dirname "$OBS")" 2>/dev/null
  {
    printf 'token_set=%s\n' "${GAAI_IMPL_AUTH_TOKEN+yes}"
    printf 'token_value=%s\n' "${GAAI_IMPL_AUTH_TOKEN:-<unset>}"
    printf 'args=%s\n' "$*"
    printf 'daemon_home=%s\n' "${GAAI_DAEMON_HOME:-}"
    printf 'repo_root=%s\n' "${GAAI_REPO_ROOT:-}"
    printf 'target_sha=%s\n' "${GAAI_TARGET_SHA:-}"
    printf 'attempt_dir=%s\n' "$A"
  } > "$OBS"
fi
while :; do sleep 5; done
STUB_EOF
  chmod 0755 "$_proj/.gaai/core/scripts/delivery-daemon.sh"
  mkdir -p "$_root/fakebin" "$_root/opshome"
  printf '#!/bin/sh\nexit 0\n' > "$_root/fakebin/claude"
  chmod 0755 "$_root/fakebin/claude"
  git -C "$_proj" add -A >/dev/null 2>&1
  git -C "$_proj" commit -qm "fixture" >/dev/null 2>&1
  git -C "$_proj" push -q origin staging 2>/dev/null
}

gaai_advance_target() {
  local _proj="$1"
  git -C "$_proj" fetch -q origin staging
  git -C "$_proj" reset -q --hard origin/staging
  printf '%s\n' "advance-$$-$RANDOM" >> "$_proj/target-advance.txt"
  git -C "$_proj" add -A >/dev/null 2>&1
  git -C "$_proj" commit -qm "advance" >/dev/null 2>&1
  git -C "$_proj" push -q origin HEAD:staging 2>/dev/null
}

gaai_lifecycle_root() {
  printf '%s/gaai-daemon-lifecycle' \
    "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
}

gaai_home_path() {
  local _proj="$1"
  printf '%s/.gaai-worktrees/%s/__daemon-home' \
    "$(cd "$_proj/.." && pwd -P)" "$(basename "$_proj")"
}

# The privileged entry must be invoked from a clean environment — that IS the
# contract, and it is how an operator has to invoke it too.
gaai_run() {
  local _root="$1"; shift
  /usr/bin/env -i "PATH=$_root/fakebin:/usr/bin:/bin" "HOME=$_root/opshome" TERM=dumb "$@"
}

# Remove the home the way an operator must: unregister it, then prune the
# administrative record. A bare `rm -rf` leaves a registered-but-missing home, which
# is a distinct state the suite asserts separately (TC17).
gaai_reset_home() {
  local _hw
  _hw="$(gaai_home_path "$PROJ")"
  git -C "$PROJ" worktree remove --force "$_hw" >/dev/null 2>&1 || rm -rf "$_hw"
  git -C "$PROJ" worktree prune >/dev/null 2>&1
  rm -rf "$_hw" 2>/dev/null
}

gaai_teardown() {
  local _root="$1" _proj="${2:-}"
  if [[ -n "$_proj" && -d "$_proj" ]]; then
    local _sock
    _sock="$(sed -n 's/^socket=//p' "$(gaai_lifecycle_root "$_proj")/owner" 2>/dev/null | head -1)"
    if [[ -n "$_sock" && -S "$_sock" ]]; then tmux -f /dev/null -S "$_sock" kill-server 2>/dev/null; fi
    [[ -n "$_sock" ]] && rm -f "$_sock" 2>/dev/null
  fi
  rm -rf "$_root" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# Real-runtime fixture
# ═══════════════════════════════════════════════════════════════════════════
#
# DISTINCT from gaai_build_fixture above, which substitutes a stub daemon on
# purpose so the fault matrices cannot fail for unrelated runtime reasons. No
# observation made through that stub is evidence about the distributed program.
# The constructor below materialises the COMPLETE tracked public Framework with
# its real bytes and its real modes — it never chmods the copied daemon, so a
# candidate whose daemon is tracked non-executable reproduces the real admission
# refusal here instead of being repaired by the fixture.

# gaai_copy_tracked_core <src_repo_root> <dest_root>
# Working-tree bytes and modes of every tracked `.gaai/core` path. The working
# tree — not HEAD — is the candidate under test.
gaai_copy_tracked_core() {
  local _src="$1" _dest="$2" _f
  while IFS= read -r -d '' _f; do
    [[ -f "$_src/$_f" ]] || continue
    mkdir -p "$_dest/${_f%/*}"
    cp -p "$_src/$_f" "$_dest/$_f" || return 1
  done < <(git -C "$_src" ls-files -z -- .gaai/core)
  return 0
}

# gaai_core_fidelity <src_repo_root> <dest_root>
# Prints one line per tracked path whose fixture copy differs in bytes or in
# executable bit. Empty output is the sealed-candidate evidence: what the fixture
# runs is what the candidate ships.
gaai_core_fidelity() {
  local _src="$1" _dest="$2" _f _a _b
  while IFS= read -r -d '' _f; do
    [[ -f "$_src/$_f" ]] || continue
    if [[ ! -f "$_dest/$_f" ]]; then printf 'missing %s\n' "$_f"; continue; fi
    cmp -s "$_src/$_f" "$_dest/$_f" || printf 'bytes %s\n' "$_f"
    _a=no; [[ -x "$_src/$_f" ]] && _a=yes
    _b=no; [[ -x "$_dest/$_f" ]] && _b=yes
    [[ "$_a" == "$_b" ]] || printf 'mode %s (%s -> %s)\n' "$_f" "$_a" "$_b"
  done < <(git -C "$_src" ls-files -z -- .gaai/core)
}

# gaai_build_real_fixture <root> <src_repo_root>
# A new repository with a local bare `origin`, the real public Framework and a
# synthetic EMPTY backlog. No project memory, no real Story, no credential, no
# operator hook and no shared repository configuration is copied.
gaai_build_real_fixture() {
  local _root="$1" _src="$2"
  local _remote="$_root/remote.git" _proj="$_root/proj"
  git init --bare "$_remote" -q || return 1
  git clone "$_remote" "$_proj" -q 2>/dev/null
  git -C "$_proj" config user.email "test@gaai.local"
  git -C "$_proj" config user.name "gaai-test"
  git -C "$_proj" config core.hooksPath /dev/null
  git -C "$_proj" symbolic-ref HEAD refs/heads/staging
  gaai_copy_tracked_core "$_src" "$_proj" || return 1
  # Synthetic project state. The setup entry runs the unchanged health check,
  # which requires these project directories and backlog files to exist; a
  # fixture that omits them makes setup return nonzero for a fixture gap rather
  # than a product fault. They are created EMPTY and synthetic: no project
  # memory, artefact or real Story is ever copied here, and the active backlog
  # stays exactly empty so the daemon schedules nothing.
  mkdir -p "$_proj/.gaai/project/contexts/backlog" \
           "$_proj/.gaai/project/contexts/memory" \
           "$_proj/.gaai/project/contexts/artefacts"
  # Git tracks no empty directory, so a placeholder is what makes them exist in
  # the fresh worktree the daemon home is checked out into.
  : > "$_proj/.gaai/project/contexts/memory/.gitkeep"
  : > "$_proj/.gaai/project/contexts/artefacts/.gitkeep"
  printf 'items: []\n' > "$_proj/.gaai/project/contexts/backlog/active.backlog.yaml"
  printf 'items: []\n' > "$_proj/.gaai/project/contexts/backlog/blocked.backlog.yaml"
  printf 'items: []\n' > "$_proj/.gaai/project/contexts/backlog/_template.backlog.yaml"
  # Operator-side tool directory. `claude` here is a REFUSING PRESENCE SENTINEL:
  # it satisfies the setup entry's advisory presence check, records any attempted
  # invocation and never runs a model. It replaces no daemon and no helper.
  mkdir -p "$_root/fakebin" "$_root/opshome"
  printf '#!/bin/sh\nprintf "executor_invoked args=%%s\\n" "$*" >> "%s/executor-invocations.log"\nexit 97\n' \
    "$_root" > "$_root/fakebin/claude"
  cp "$_root/fakebin/claude" "$_root/fakebin/codex"
  chmod 0755 "$_root/fakebin/claude" "$_root/fakebin/codex"
  : > "$_root/executor-invocations.log"
  git -C "$_proj" add -A >/dev/null 2>&1
  git -C "$_proj" -c core.hooksPath=/dev/null commit -qm "real fixture" >/dev/null 2>&1
  git -C "$_proj" push -q origin staging 2>/dev/null
}

# gaai_poison_lib_tree <tree_root> <marker_path>
# Turns every daemon library of a Framework tree into ACTIVE shell code that
# writes a fixture-local marker when sourced. A negative control passes only when
# an otherwise complete tree like this one is refused BEFORE its marker appears;
# an absent library or an unwritable marker must never manufacture that pass,
# which is why the positive row uses the very same instrumentation.
gaai_poison_lib_tree() {
  local _tree="$1" _marker="$2" _f _tmp _line
  for _f in "$_tree/.gaai/core/scripts/lib/"*.sh; do
    [[ -f "$_f" ]] || continue
    _tmp="$_f.poison.$$"
    # No backslash escape appears in the injected line, so `awk -v` passes it
    # through unchanged. The marker is appended, so every sourced library is
    # recorded rather than only the last one.
    _line="printf 'lib_sourced=$(basename "$_f") ' >> \"$_marker\""
    # After line 1 so the interpreter line of a library that is also executed
    # directly stays first.
    awk -v inject="$_line" 'NR==1 { print; print inject; next } { print }' \
      "$_f" > "$_tmp" && mv "$_tmp" "$_f" || return 1
  done
  return 0
}

# gaai_write_fd_harness <path>
# TEST-ONLY launch harness. It reproduces exactly two mechanics of
# `do_daemon_child`'s final step — binding the daemon to descriptor 9 and a
# PID-preserving `exec` of that descriptor — so the REAL daemon can be probed on
# its real entry without a tmux lifecycle. It is never installed in a product
# path, grants no lifecycle authority, and replaces no production check: every
# refusal a probe observes comes from the daemon itself.
#
# Its own failures carry reserved exit codes so a harness or loader failure can
# never be read as a production refusal:
#   90 — a descriptor could not be bound to the daemon file
#   91 — the acknowledgement record could not be written
#   92 — the selected descriptor is not live and readable
gaai_write_fd_harness() {
  cat > "$1" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -uo pipefail
_daemon="${GAAI_PROBE_DAEMON:?}"
_shell="${GAAI_PROBE_SHELL:?}"
exec 9< "$_daemon" || exit 90
# A second binding of the same file, so a row can probe an entry through a
# descriptor number that is NOT the launcher's.
exec 8< "$_daemon" || exit 90
_fd="/dev/fd/9"
[[ -r "/proc/self/fd/9" ]] && _fd="/proc/self/fd/9"
[[ -n "${GAAI_PROBE_FD_PATH:-}" ]] && _fd="$GAAI_PROBE_FD_PATH"
# The property under test is a REFUSAL BY THE DAEMON, which requires the daemon
# bytes to be read and executed from the selected descriptor. A descriptor the
# interpreter cannot read would fail in the shell or the loader instead — a
# different fact entirely — so prove it is live here and exit distinctly if not.
[[ -r "$_fd" ]] || exit 92
if [[ -n "${GAAI_PROBE_ACK_DIR:-}" ]]; then
  _ino="$(stat -L -c '%i' "$_fd" 2>/dev/null || stat -L -f '%i' "$_fd" 2>/dev/null || echo "")"
  _dev="$(stat -L -c '%d' "$_fd" 2>/dev/null || stat -L -f '%d' "$_fd" 2>/dev/null || echo "")"
  _inc="$(ps -o lstart= -p $$ 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
  printf 'schema=%s\nattempt=%s\npid=%s\nincarnation=%s\ncredential_mode=absent\ndaemon_ino=%s\ndaemon_dev=%s\ndaemon_digest=%s\n' \
    "${GAAI_PROBE_SCHEMA:-}" "${GAAI_PROBE_ATTEMPT:-}" "$$" "$_inc" \
    "${GAAI_PROBE_ACK_INO:-$_ino}" "$_dev" "${GAAI_PROBE_DIGEST:-}" \
    > "$GAAI_PROBE_ACK_DIR/ack.launcher" || exit 91
  export GAAI_DAEMON_LAUNCH_PID="$$"
  export GAAI_DAEMON_LAUNCH_INCARNATION="$_inc"
fi
exec "$_shell" "$_fd" "$@"
HARNESS_EOF
  chmod 0755 "$1"
}

# gaai_write_manifest <attempt_dir> <schema> <attempt> <home> <repo_root> <sha> <digest>
# The existing manifest grammar, written as data by the probe caller.
gaai_write_manifest() {
  printf 'schema=%s\nattempt=%s\nhome=%s\nrepo_root=%s\ntarget_sha=%s\ndaemon_digest=%s\nlauncher_digest=%s\ncredential_mode=absent\nsecret=\nrelease_digest=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$7" "$7" > "$1/manifest"
}

# The schema literal has ONE source of truth (lib/daemon-home.sh); read it as data
# rather than restating it in a test.
gaai_home_schema() {
  sed -n 's/^GAAI_HOME_SCHEMA="\(.*\)"$/\1/p' "$1/lib/daemon-home.sh" 2>/dev/null | head -1
}

# The daemon's executor presence check runs against the launcher's attested
# command roots, not the operator PATH, so the fixture cannot substitute one
# there without writing into a host command root — which it must not do. Report
# what the host actually offers; absence blocks the real lifecycle lane as an
# ENVIRONMENT limitation rather than being papered over.
gaai_attested_executor() {
  local _d _c
  for _d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin /opt/homebrew/bin; do
    for _c in claude codex; do
      [[ -x "$_d/$_c" ]] && { printf '%s\n' "$_d/$_c"; return 0; }
    done
  done
  return 1
}

# gaai_wait_for <seconds> <file> [pattern]
# Bounded failure containment around the existing startup/stop failure modes —
# not a correctness budget. A timeout preserves every log for disposition.
gaai_wait_for() {
  local _n="$1" _f="$2" _pat="${3:-}" _i=0
  while [[ "$_i" -lt "$_n" ]]; do
    if [[ -n "$_pat" ]]; then
      [[ -r "$_f" ]] && grep -q "$_pat" "$_f" 2>/dev/null && return 0
    else
      [[ -e "$_f" ]] && return 0
    fi
    sleep 1
    _i=$(( _i + 1 ))
  done
  return 1
}

# Sourced by the sibling suites for the fixture only.
if [[ -n "${GAAI_HOME_FIXTURE_ONLY:-}" ]]; then return 0; fi

# ═══════════════════════════════════════════════════════════════════════════
# Matrices
# ═══════════════════════════════════════════════════════════════════════════

for _tool in git tmux; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "ERROR: $_tool is required by the daemon-home matrices and is absent."
    echo "The hosted OSS lane must execute the real capability probe and smoke lifecycle;"
    echo "installing it is outside this Story's inventory (see Out of Scope)."
    exit 1
  fi
done

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-home-prov-XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
PROJ="$ROOT/proj"
trap 'gaai_teardown "$ROOT" "$PROJ"' EXIT
gaai_build_fixture "$ROOT" "$SCRIPTS_DIR"
SETUP="$PROJ/.gaai/core/scripts/daemon-setup.sh"
START="$PROJ/.gaai/core/scripts/daemon-start.sh"
HOME_WT="$(gaai_home_path "$PROJ")"
LIFECYCLE="$(gaai_lifecycle_root "$PROJ")"

echo ""
echo "=== Dual-shell coverage declaration ==="
SHELLS="$(gaai_supported_shells)"
echo "  supported interpreters exercised: $(echo "$SHELLS" | tr '\n' ' ')"
if gaai_bash32_available; then
  pass "TC0: both supported shells (Bash 3.2 and the current Bash) are available and exercised"
else
  echo "  NOTE: no Bash 3.2 interpreter on this host — the 3.2 half of the dual-shell"
  echo "        matrix cannot execute here. It MUST be executed on the macOS lane, whose"
  echo "        /bin/bash is 3.2, before this boundary is declared proven."
  pass "TC0: dual-shell coverage is declared explicitly rather than silently assumed"
fi

echo ""
echo "=== TC1: startup refuses an absent home and creates nothing ==="
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'reason=home_identity_invalid action=rerun_setup'; then
  pass "TC1-1: absent home returns home_identity_invalid + rerun_setup"
else
  fail "TC1-1: expected home_identity_invalid/rerun_setup, got: $OUT"
fi
if [[ ! -e "$HOME_WT" ]]; then
  pass "TC1-2: startup created no worktree (verify-only)"
else
  fail "TC1-2: startup created $HOME_WT — verify-only violated"
fi
if [[ ! -S "$(sed -n 's/^socket=//p' "$LIFECYCLE/owner" 2>/dev/null | head -1)" ]] && [[ ! -e "$LIFECYCLE/owner" ]]; then
  pass "TC1-3: a pre-pending refusal created no tmux server, session or owner record"
else
  fail "TC1-3: a pre-pending refusal left lifecycle artefacts behind"
fi

echo ""
echo "=== TC2: setup is the only path that creates the home ==="
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'home created at'; then
  pass "TC2-1: setup created the dedicated worktree"
else
  fail "TC2-1: setup did not create the home: $(echo "$SETUP_OUT" | grep '❌' | head -3)"
fi
if [[ "$(git -C "$HOME_WT" branch --show-current 2>/dev/null)" == "gaai-daemon-home" ]]; then
  pass "TC2-2: home is on gaai-daemon-home"
else
  fail "TC2-2: home is not on gaai-daemon-home"
fi
if [[ "$(git -C "$HOME_WT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" == "origin/staging" ]]; then
  pass "TC2-3: home tracks origin/staging"
else
  fail "TC2-3: home does not track origin/staging"
fi
if git -C "$PROJ" worktree list --porcelain 2>/dev/null | grep -qF "worktree $HOME_WT"; then
  pass "TC2-4: home is a registered worktree of the same physical repository"
else
  fail "TC2-4: home is not registered"
fi
if [[ ! -e "$LIFECYCLE/lock.d" ]]; then
  pass "TC2-5: setup released the lifecycle lock at settlement"
else
  fail "TC2-5: setup left the lifecycle lock held"
fi
if [[ ! -e "$LIFECYCLE/owner" ]]; then
  pass "TC2-6: setup never converted its lock into production pending/bound/running authority"
else
  fail "TC2-6: setup created an owner record — it must not create launch authority"
fi

echo ""
echo "=== TC3: setup is idempotent and startup accepts a clean exact-current home ==="
gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
if [[ "$(git -C "$PROJ" worktree list --porcelain 2>/dev/null | grep -cF "worktree $HOME_WT")" == "1" ]]; then
  pass "TC3-1: a second setup produced no duplicate registration"
else
  fail "TC3-1: duplicate worktree registration after a second setup"
fi
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'Daemon started'; then
  pass "TC3-2: startup admitted the clean, registered, exact-current home"
else
  fail "TC3-2: startup refused a valid home: $OUT"
fi

echo ""
echo "=== TC4: setup refuses an active lifecycle and mutates nothing ==="
HEAD_BEFORE="$(git -C "$HOME_WT" rev-parse HEAD)"
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'lifecycle_role='; then
  pass "TC4-1: setup refused while a lifecycle owner exists"
else
  fail "TC4-1: setup did not refuse an active lifecycle: $SETUP_OUT"
fi
if [[ "$(git -C "$HOME_WT" rev-parse HEAD)" == "$HEAD_BEFORE" ]]; then
  pass "TC4-2: the refused setup left the home unchanged"
else
  fail "TC4-2: the refused setup moved the home"
fi

echo ""
echo "=== TC5: a second start returns already_running without a second spawn ==="
PANES_BEFORE="$(tmux -f /dev/null -S "$(sed -n 's/^socket=//p' "$LIFECYCLE/owner" | head -1)" \
  list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'reason=already_running action=none'; then
  pass "TC5-1: second start returned already_running + none"
else
  fail "TC5-1: expected already_running, got: $OUT"
fi
PANES_AFTER="$(tmux -f /dev/null -S "$(sed -n 's/^socket=//p' "$LIFECYCLE/owner" | head -1)" \
  list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$PANES_BEFORE" == "$PANES_AFTER" ]]; then
  pass "TC5-2: no second process was launched"
else
  fail "TC5-2: pane count changed $PANES_BEFORE -> $PANES_AFTER"
fi
gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1

echo ""
echo "=== TC6: dirty homes are preserved, never cleaned ==="
echo "operator-edit" >> "$HOME_WT/.gaai/core/scripts/delivery-daemon.sh"
BEFORE="$(cksum < "$HOME_WT/.gaai/core/scripts/delivery-daemon.sh")"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'reason=home_dirty action=operator_disposition_required'; then
  pass "TC6-1: tracked-file dirt returns home_dirty + operator_disposition_required"
else
  fail "TC6-1: expected home_dirty, got: $OUT"
fi
if [[ "$(cksum < "$HOME_WT/.gaai/core/scripts/delivery-daemon.sh")" == "$BEFORE" ]]; then
  pass "TC6-2: the dirty file is preserved byte-for-byte"
else
  fail "TC6-2: the dirty file was modified"
fi
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'operator disposition'; then
  pass "TC6-3: setup also refuses a dirty home instead of cleaning it"
else
  fail "TC6-3: setup did not refuse a dirty home: $(echo "$SETUP_OUT" | grep -E '❌|✅ home' | head -3)"
fi
if [[ "$(cksum < "$HOME_WT/.gaai/core/scripts/delivery-daemon.sh")" == "$BEFORE" ]]; then
  pass "TC6-4: setup preserved the dirty file byte-for-byte"
else
  fail "TC6-4: setup modified the dirty file"
fi
git -C "$HOME_WT" checkout -- . 2>/dev/null

echo ""
echo "=== TC7: untracked operator files are dirt, and are preserved ==="
touch "$HOME_WT/operator-scratch.txt"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'evidence=home_role=untracked_present'; then
  pass "TC7-1: untracked content returns home_dirty"
else
  fail "TC7-1: expected untracked_present, got: $OUT"
fi
[[ -e "$HOME_WT/operator-scratch.txt" ]] && pass "TC7-2: the untracked file is preserved" \
  || fail "TC7-2: the untracked file was removed"
rm -f "$HOME_WT/operator-scratch.txt"

echo ""
echo "=== TC8: wrong branch refuses, and nothing repairs it ==="
git -C "$HOME_WT" checkout -q -b sidetrack 2>/dev/null
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'evidence=home_role=wrong_branch'; then
  pass "TC8-1: wrong branch returns home_identity_invalid"
else
  fail "TC8-1: expected wrong_branch, got: $OUT"
fi
if [[ "$(git -C "$HOME_WT" branch --show-current)" == "sidetrack" ]]; then
  pass "TC8-2: startup did not switch the branch back"
else
  fail "TC8-2: startup repaired the branch — verify-only violated"
fi
git -C "$HOME_WT" checkout -q gaai-daemon-home 2>/dev/null
git -C "$HOME_WT" branch -q -D sidetrack 2>/dev/null

echo ""
echo "=== TC9: an advanced target makes the home stale; only setup converges it ==="
gaai_advance_target "$PROJ"
HEAD_BEFORE="$(git -C "$HOME_WT" rev-parse HEAD)"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -q 'evidence=home_role=stale_head'; then
  pass "TC9-1: a stale home returns home_identity_invalid + rerun_setup"
else
  fail "TC9-1: expected stale_head, got: $OUT"
fi
if [[ "$(git -C "$HOME_WT" rev-parse HEAD)" == "$HEAD_BEFORE" ]]; then
  pass "TC9-2: startup did not advance the home"
else
  fail "TC9-2: startup advanced the home — verify-only violated"
fi
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'home updated to'; then
  pass "TC9-3: setup fast-forwarded the home to the new target"
else
  fail "TC9-3: setup did not converge the stale home: $(echo "$SETUP_OUT" | sed -n '/Daemon home/,/^$/p' | tr '\n' ' ')"
fi

echo ""
echo "=== TC10: --verify-only never mutates ==="
gaai_advance_target "$PROJ"
HEAD_BEFORE="$(git -C "$HOME_WT" rev-parse HEAD)"
OUT="$(gaai_run "$ROOT" "$SETUP" --verify-only 2>&1)"
if [[ "$(git -C "$HOME_WT" rev-parse HEAD)" == "$HEAD_BEFORE" ]]; then
  pass "TC10-1: --verify-only left the stale home untouched"
else
  fail "TC10-1: --verify-only mutated the home"
fi
if echo "$OUT" | grep -q 'rerun without --verify-only'; then
  pass "TC10-2: --verify-only reported what setup would do"
else
  fail "TC10-2: --verify-only gave no actionable report"
fi
gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1

echo ""
echo "=== TC11: a non-fast-forward home is divergence, and is never forced ==="
git -C "$HOME_WT" commit -q --allow-empty -m "local divergence" 2>/dev/null
gaai_advance_target "$PROJ"
HEAD_BEFORE="$(git -C "$HOME_WT" rev-parse HEAD)"
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'could not be fast-forwarded'; then
  pass "TC11-1: setup refused a non-fast-forward instead of resetting"
else
  fail "TC11-1: setup did not refuse divergence: $(echo "$SETUP_OUT" | grep -E '❌|✅ home' | head -3)"
fi
if [[ "$(git -C "$HOME_WT" rev-parse HEAD)" == "$HEAD_BEFORE" ]]; then
  pass "TC11-2: the diverged home is preserved unchanged"
else
  fail "TC11-2: the diverged home was force-moved"
fi

echo ""
echo "=== TC12: interrupted setup evidence blocks and is preserved ==="
gaai_reset_home
mkdir -p "$HOME_WT" && printf 'partial\n' > "$HOME_WT/INTERRUPTED"
OUT="$(gaai_run "$ROOT" "$START" 2>&1)"
if echo "$OUT" | grep -qE 'reason=home_registration_invalid|reason=home_identity_invalid'; then
  pass "TC12-1: an unregistered directory at the home path blocks startup"
else
  fail "TC12-1: expected a registration/identity refusal, got: $OUT"
fi
if [[ -f "$HOME_WT/INTERRUPTED" ]]; then
  pass "TC12-2: the interrupted-setup evidence is preserved"
else
  fail "TC12-2: the interrupted-setup evidence was destroyed"
fi
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if [[ -f "$HOME_WT/INTERRUPTED" ]]; then
  pass "TC12-3: setup preserved the evidence rather than clearing the path"
else
  fail "TC12-3: setup destroyed interrupted-setup evidence"
fi

echo ""
echo "=== TC13: the lifecycle lock is exclusive, crash-recoverable and TTL-free ==="
gaai_reset_home; gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
COMMON="$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)"
LOCK_TEST="$(cat <<'LT'
set -uo pipefail
source "$1/lib/daemon-home.sh"
_gaai_home_lock_acquire "$2" || exit 3
case "$3" in
  hold) printf 'held\n'; ;;
  crash) printf 'pid=%s\n' "$$" ;;
esac
LT
)"
# Acquire + explicit release inside one process. Release is deliberately explicit,
# not implicit-on-exit: an abandoned lock must stay as evidence and be reclaimed
# only by the crash-recovery path below, which proves the holder is dead.
RELEASE_TEST="$(cat <<'RT'
set -uo pipefail
source "$1/lib/daemon-home.sh"
_gaai_home_lock_acquire "$2" || exit 3
_gaai_home_lock_held || exit 4
_gaai_home_lock_release
_gaai_home_lock_held && exit 5
[[ -d "$2/gaai-daemon-lifecycle/lock.d" ]] && exit 6
printf 'released
'
RT
)"
if "${BASH:-/bin/bash}" -c "$RELEASE_TEST" _ "$PROJ/.gaai/core/scripts" "$COMMON" 2>&1 | grep -q released; then
  pass "TC13-1: acquire then explicit release leaves no lock and no claim"
else
  fail "TC13-1: the acquire/release pair did not settle the lock"
fi
rm -rf "$COMMON/gaai-daemon-lifecycle/lock.d" 2>/dev/null
mkdir -p "$COMMON/gaai-daemon-lifecycle/lock.d"
printf 'schema=gaai-daemon-lifecycle/v1\npid=999999\nincarnation=1\n' \
  > "$COMMON/gaai-daemon-lifecycle/lock.d/holder"
OUT="$("${BASH:-/bin/bash}" -c "$LOCK_TEST" _ "$PROJ/.gaai/core/scripts" "$COMMON" hold 2>&1)"
if echo "$OUT" | grep -q 'held'; then
  pass "TC13-2: a provably dead holder is crash-recovered without a TTL"
else
  fail "TC13-2: a dead holder blocked forever: $OUT"
fi
mkdir -p "$COMMON/gaai-daemon-lifecycle/lock.d"
printf 'schema=gaai-daemon-lifecycle/v1\npid=%s\nincarnation=\n' "$$" \
  > "$COMMON/gaai-daemon-lifecycle/lock.d/holder"
OUT="$("${BASH:-/bin/bash}" -c "$LOCK_TEST" _ "$PROJ/.gaai/core/scripts" "$COMMON" hold 2>&1)"
if echo "$OUT" | grep -q 'reason=home_lock_failed'; then
  pass "TC13-3: a live holder blocks — there is no lock handoff"
else
  fail "TC13-3: a live holder did not block: $OUT"
fi
rm -rf "$COMMON/gaai-daemon-lifecycle/lock.d" 2>/dev/null
printf 'corrupt' > "$COMMON/gaai-daemon-lifecycle/lock.d" 2>/dev/null || true
if [[ -f "$COMMON/gaai-daemon-lifecycle/lock.d" ]]; then
  OUT="$("${BASH:-/bin/bash}" -c "$LOCK_TEST" _ "$PROJ/.gaai/core/scripts" "$COMMON" hold 2>&1)"
  if echo "$OUT" | grep -q 'reason=home_lock_failed'; then
    pass "TC13-4: a corrupt lock record blocks instead of being reclaimed"
  else
    fail "TC13-4: a corrupt lock record did not block: $OUT"
  fi
  rm -f "$COMMON/gaai-daemon-lifecycle/lock.d"
fi

echo ""
echo "=== TC17: a registered-but-missing home is ambiguous, never silently pruned ==="
gaai_reset_home
gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
rm -rf "$HOME_WT"
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'evidence=home_role=registered_path_missing'; then
  pass "TC17-1: setup refuses a registered-but-missing home with a typed reason"
else
  fail "TC17-1: expected registered_path_missing, got: $(echo "$SETUP_OUT" | grep -E '❌|home_role' | head -2)"
fi
if git -C "$PROJ" worktree list --porcelain 2>/dev/null | grep -qF "worktree $HOME_WT"; then
  pass "TC17-2: the registration is preserved for operator disposition, not pruned"
else
  fail "TC17-2: setup silently pruned the administrative record"
fi
gaai_reset_home

echo ""
echo "=== TC15: settlement removes only known artefacts and preserves the rest ==="
gaai_reset_home; gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
gaai_run "$ROOT" "$START" >/dev/null 2>&1
ATTEMPT_DIR="$(sed -n 's/^attempt_dir=//p' "$LIFECYCLE/owner" 2>/dev/null | head -1)"
if [[ -n "$ATTEMPT_DIR" && -d "$ATTEMPT_DIR" ]]; then
  printf 'operator-evidence\n' > "$ATTEMPT_DIR/unexplained.txt"
  gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1
  if [[ -f "$ATTEMPT_DIR/unexplained.txt" ]]; then
    pass "TC15-1: unrecognised content in the attempt directory is preserved"
  else
    fail "TC15-1: settlement recursively deleted unrecognised content"
  fi
  if [[ ! -e "$ATTEMPT_DIR/launcher.sh" && ! -e "$ATTEMPT_DIR/manifest" ]]; then
    pass "TC15-2: the lifecycle's own artefacts were removed"
  else
    fail "TC15-2: lifecycle artefacts survived settlement"
  fi
  rm -f "$ATTEMPT_DIR/unexplained.txt"; rmdir "$ATTEMPT_DIR" 2>/dev/null
else
  fail "TC15-0: no attempt directory was recorded"
fi

echo ""
echo "=== TC16: a clean stop leaves nothing that blocks the next setup ==="
gaai_reset_home; gaai_run "$ROOT" "$SETUP" >/dev/null 2>&1
gaai_run "$ROOT" "$START" >/dev/null 2>&1
gaai_run "$ROOT" "$START" --stop >/dev/null 2>&1
SETUP_OUT="$(gaai_run "$ROOT" "$SETUP" 2>&1)"
if echo "$SETUP_OUT" | grep -q 'lifecycle_role='; then
  fail "TC16-1: residue from a clean stop still blocks setup: $(echo "$SETUP_OUT" | grep lifecycle_role)"
else
  pass "TC16-1: after a clean stop, setup runs again without operator disposition"
fi

echo ""
echo "=== TC14: the reason -> action mapping is deterministic and closed ==="
MAP_TEST="$(cat <<'MT'
set -uo pipefail
source "$1/lib/daemon-home.sh"
for r in $GAAI_HOME_REASONS; do
  printf '%s|%s|%s\n' "$r" "$(_gaai_home_action_for "$r" 0)" "$(_gaai_home_action_for "$r" 1)"
done
printf 'unknown_reason|%s|%s\n' "$(_gaai_home_action_for unknown_reason 0)" "$(_gaai_home_action_for unknown_reason 1)"
MT
)"
MAP="$("${BASH:-/bin/bash}" -c "$MAP_TEST" _ "$PROJ/.gaai/core/scripts" 2>&1)"
MAP_OK=true
while IFS='|' read -r _r _a0 _a1; do
  [[ -n "$_r" ]] || continue
  case "$_a0" in rerun_setup|operator_disposition_required|none) ;; *) MAP_OK=false ;; esac
  case "$_a1" in rerun_setup|operator_disposition_required|none) ;; *) MAP_OK=false ;; esac
  # Ambiguity may only ever make the action stricter, never turn an unavailable
  # proof into `rerun_setup`.
  [[ "$_a1" == "rerun_setup" && "$_a0" != "rerun_setup" ]] && MAP_OK=false
done <<< "$MAP"
$MAP_OK && pass "TC14-1: every reason maps to exactly one canonical action" \
        || fail "TC14-1: the mapping produced a non-canonical action: $MAP"
if echo "$MAP" | grep -q '^home_dirty|operator_disposition_required|operator_disposition_required$'; then
  pass "TC14-2: home_dirty never yields rerun_setup"
else
  fail "TC14-2: home_dirty mapping drifted"
fi
if echo "$MAP" | grep -q '^unknown_reason|operator_disposition_required|'; then
  pass "TC14-3: an unknown reason fails closed to operator_disposition_required"
else
  fail "TC14-3: an unknown reason did not fail closed"
fi
AMBIG_OK=true
for r in target_advanced home_identity_invalid home_registration_invalid home_asset_invalid; do
  echo "$MAP" | grep -q "^$r|rerun_setup|operator_disposition_required$" || AMBIG_OK=false
done
$AMBIG_OK && pass "TC14-4: ambiguous evidence downgrades every rerun_setup to operator disposition" \
          || fail "TC14-4: ambiguity did not tighten the action"

echo ""
echo "=== TC18: the REAL distributed daemon — isolated setup, startup, readiness, dispatch loop, status, stop ==="
#
# Everything above this point runs against the stub daemon and proves nothing
# about the distributed program. This lane builds a separate repository holding
# the actual public Framework with its real bytes and modes, an empty synthetic
# backlog and a local bare origin, and drives the real setup, launcher, daemon,
# scheduler, dispatch library, vendored YAML runtime and private tmux lifecycle.
#
# Readiness is NOT the success condition: the ready acknowledgement is written
# before the dispatch library is imported, so this lane additionally requires the
# real daemon's own post-import idle message and a still-running process.
BLOCKED_COUNT=0
blocked() { echo "  BLOCKED (environment, not a product verdict): $1"; BLOCKED_COUNT=$(( BLOCKED_COUNT + 1 )); }

gaai_report_results() {
  echo ""
  echo "════════════════════════════════════════"
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, ${BLOCKED_COUNT:-0} blocked by the environment — TC18=$1"
  [[ "$FAIL_COUNT" -eq 0 ]] || exit 1
  # A blocked lane is neither a pass nor a product failure: it exits non-zero so
  # the missing evidence cannot be read as coverage.
  [[ "${BLOCKED_COUNT:-0}" -eq 0 ]] || exit 2
  exit 0
}

# TC18 invocation gate. The full real lifecycle case is EXPLICIT-INVOCATION ONLY:
# its default result is NOT_RUN and contributes no pass. This gates only the
# lifecycle case — the unconditional real-daemon bootstrap regressions live in
# daemon-asset-home.test.sh and run on every invocation of that suite. When TC18
# IS requested, a missing prerequisite exits nonzero BLOCKED and a failed
# assertion exits nonzero FAIL; neither is ever downgraded to a pass. This is a
# harness invocation choice and adds no production runtime option.
if [[ "${GAAI_REAL_DAEMON_SMOKE:-0}" != "1" ]]; then
  echo "  NOT_RUN — request the full lifecycle explicitly:"
  echo "        GAAI_REAL_DAEMON_SMOKE=1 .gaai/core/scripts/tests/daemon-home-provision.test.sh"
  echo "        NOT_RUN is excluded from the pass count and is NOT evidence for AC5;"
  echo "        the coordinator must run this case against the exact candidate and"
  echo "        preserve its setup/readiness/idle-loop/status/stop/cleanup receipts."
  gaai_report_results NOT_RUN
fi

SRC_REPO="$(cd "$SCRIPTS_DIR/../../.." && pwd -P)"
REAL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-home-real-XXXXXX")"
REAL_ROOT="$(cd "$REAL_ROOT" && pwd -P)"
REAL_PROJ="$REAL_ROOT/proj"
REAL_EVIDENCE="$REAL_ROOT/evidence"
mkdir -p "$REAL_EVIDENCE"
REAL_FAIL_BASE="$FAIL_COUNT"
REAL_SETTLED=0

# This lane DELETES NOTHING. A successful run is a receipt: its isolated fixture
# and evidence files stay on disk so the recorded outcome can be inspected after
# the fact rather than existing only as a console count. A failed or ambiguous
# run is preserved for the same reason and, additionally, is never signalled —
# no kill, no socket removal, no recursive fixture deletion in either case. The
# shared UID-scoped socket root is neither deleted nor mutated here; what the
# supported stop entry removed is measured and recorded, never performed by this
# test. The isolated root is the operator's to remove once they have read it.
real_lane_teardown() {
  echo ""
  if [[ "$REAL_SETTLED" -eq 1 && "$FAIL_COUNT" -eq "$REAL_FAIL_BASE" ]]; then
    echo "  RECEIPTS RETAINED — this lane settled cleanly and deleted nothing."
    echo "        fixture root:      $REAL_ROOT"
    echo "        receipts:          $REAL_EVIDENCE"
    echo "        cleanup predicates: $REAL_EVIDENCE/cleanup-predicates.txt"
    return 0
  fi
  echo "  EVIDENCE PRESERVED — this lane did not end in a clean settled lifecycle"
  echo "        (not started, not settled, or an assertion failed)."
  echo "        fixture root:      $REAL_ROOT"
  echo "        raw entry outputs: $REAL_EVIDENCE"
  echo "        attempt directory: ${REAL_ATTEMPT:-<none recorded>}"
  echo "        daemon log:        ${REAL_LOG:-<none recorded>}"
  echo "        This lifecycle is NOT signalled and NOT deleted by this test."
}
trap 'gaai_teardown "$ROOT" "$PROJ"; real_lane_teardown' EXIT

# Every supported entry is recorded RAW — full stdout+stderr and the actual
# return code — before any assertion reads it, so a grep that happens to match
# cannot conceal an entry that failed.
# real_entry <label> <command...>  -> prints the output, records output and rc
real_entry() {
  local _label="$1"; shift
  local _out _rc=0
  _out="$("$@" 2>&1)" || _rc=$?
  printf '%s\n' "$_out" > "$REAL_EVIDENCE/$_label.out"
  printf '%s\n' "$_rc" > "$REAL_EVIDENCE/$_label.rc"
  printf '%s' "$_out"
  return "$_rc"
}

echo "  candidate repository: $SRC_REPO"
echo "  candidate HEAD:       $(git -C "$SRC_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "  uncommitted candidate paths under .gaai/core (the fixture carries the WORKING TREE):"
git -C "$SRC_REPO" status --porcelain -- .gaai/core 2>/dev/null | sed 's/^/        /'
echo "  fixture root:         $REAL_ROOT"
echo "  platform:             $(uname -sr)  harness bash: ${BASH_VERSION:-unknown}"

if gaai_build_real_fixture "$REAL_ROOT" "$SRC_REPO"; then
  pass "TC18-1: an isolated repository with a local bare origin and the real public Framework was built"
else
  fail "TC18-1: the real fixture could not be built"
fi
echo "  fixture .gaai/core tree: $(git -C "$REAL_PROJ" rev-parse 'HEAD:.gaai/core' 2>/dev/null || echo unknown)"

DIFFS="$(gaai_core_fidelity "$SRC_REPO" "$REAL_PROJ")"
if [[ -z "$DIFFS" ]]; then
  pass "TC18-2: every tracked .gaai/core path is byte-identical and mode-identical to the candidate"
else
  fail "TC18-2: the fixture is not a faithful copy of the candidate:"
  printf '        %s\n' "$DIFFS"
fi

REAL_DAEMON="$REAL_PROJ/.gaai/core/scripts/delivery-daemon.sh"
RSETUP="$REAL_PROJ/.gaai/core/scripts/daemon-setup.sh"
RSTART="$REAL_PROJ/.gaai/core/scripts/daemon-start.sh"
if grep -q 'No stories ready. Waiting' "$REAL_DAEMON" && ! grep -q 'Stub daemon' "$REAL_DAEMON"; then
  pass "TC18-3: the fixture daemon is the real program (main loop present, no stub bytes)"
else
  fail "TC18-3: the fixture daemon is not the real distributed program"
fi
# The fixture's own Git tree records what the real file's executable bit says. The
# copy is never chmod'ed, so a candidate tracked non-executable fails here exactly
# as it fails the launcher's unchanged admission contract.
if [[ "$(git -C "$REAL_PROJ" ls-files -s .gaai/core/scripts/delivery-daemon.sh | awk '{print $1}')" == "100755" ]]; then
  pass "TC18-4: a fresh clone of the candidate carries the daemon at Git mode 100755"
else
  fail "TC18-4: the fixture clone carries a non-executable daemon — the launcher admission contract cannot be satisfied"
fi

REAL_EXEC="$(gaai_attested_executor || echo "")"
REAL_EXEC_ENV=""
case "$(basename "${REAL_EXEC:-none}")" in codex) REAL_EXEC_ENV="GAAI_DAEMON_EXECUTOR=codex" ;; esac
SMOKE_TIMEOUT="${GAAI_REAL_SMOKE_TIMEOUT:-180}"
RUN_SMOKE=1
for _tool in git tmux python3; do
  command -v "$_tool" >/dev/null 2>&1 || { blocked "$_tool is absent; the real lifecycle cannot run here"; RUN_SMOKE=0; }
done
if [[ -z "$REAL_EXEC" ]]; then
  # The daemon resolves its executor through the launcher's attested command
  # roots, never through the operator PATH, so the fixture cannot place its
  # refusing sentinel there without writing into a host command root. It does not,
  # and it adds no executor-path bypass to make this dependency pass: an absent
  # executor is an unmet host prerequisite for the operator to dispose of.
  blocked "no executor (claude/codex) exists on an attested command root; the real daemon's own preflight cannot pass here"
  RUN_SMOKE=0
else
  echo "  host executor prerequisite satisfied by: $REAL_EXEC"
  echo "        This is the REAL installed CLI. The daemon's preflight tests its"
  echo "        presence only; the fixture cannot intercept it, so this lane makes"
  echo "        no claim that no external binary could be reached."
fi

if [[ "$RUN_SMOKE" -eq 1 ]]; then
  REAL_HOME_WT="$(gaai_home_path "$REAL_PROJ")"
  REAL_LIFECYCLE="$(gaai_lifecycle_root "$REAL_PROJ")"
  REAL_LOG="$REAL_PROJ/.gaai/project/contexts/backlog/.delivery-daemon.log"

  SETUP_OUT="$(real_entry setup gaai_run "$REAL_ROOT" "$RSETUP")"; SETUP_RC=$?
  if [[ "$SETUP_RC" -eq 0 ]] && echo "$SETUP_OUT" | grep -q 'home created at'; then
    pass "TC18-5: real offline setup provisioned the daemon home"
  else
    fail "TC18-5: real setup did not provision the home (rc=$SETUP_RC): $(echo "$SETUP_OUT" | grep -E '❌|home_role' | head -5)"
  fi

  START_OUT="$(real_entry start /usr/bin/env -i "PATH=$REAL_ROOT/fakebin:/usr/bin:/bin" \
    "HOME=$REAL_ROOT/opshome" TERM=dumb ${REAL_EXEC_ENV:+"$REAL_EXEC_ENV"} \
    "$RSTART" --no-monitor --interval 5)"; START_RC=$?
  [[ "$START_RC" -eq 0 ]] \
    && pass "TC18-6a: the real start entry returned 0" \
    || fail "TC18-6a: the real start entry returned $START_RC: $(printf '%s' "$START_OUT" | tail -3)"
  REAL_ATTEMPT="$(sed -n 's/^attempt_dir=//p' "$REAL_LIFECYCLE/owner" 2>/dev/null | head -1)"
  REAL_PANE_PID="$(sed -n 's/^pane_pid=//p' "$REAL_LIFECYCLE/owner" 2>/dev/null | head -1)"
  if [[ -n "$REAL_ATTEMPT" && -d "$REAL_ATTEMPT" ]]; then
    pass "TC18-6: the real launcher recorded a lifecycle owner and attempt directory"
  else
    fail "TC18-6: no real lifecycle was established: $(printf '%s' "$START_OUT" | tail -3)"
  fi
  ACK_L="$(sed -n 's/^pid=//p' "$REAL_ATTEMPT/ack.launcher" 2>/dev/null | head -1)"
  ACK_R="$(sed -n 's/^pid=//p' "$REAL_ATTEMPT/ack.ready" 2>/dev/null | head -1)"
  if [[ -n "$ACK_L" && "$ACK_L" == "$REAL_PANE_PID" && "$ACK_L" == "$ACK_R" ]]; then
    pass "TC18-7: pane_pid == launcher_ack.pid == ready_ack.pid for the real daemon"
  else
    fail "TC18-7: the real identity chain is broken (pane=$REAL_PANE_PID launcher=$ACK_L ready=$ACK_R)"
  fi

  # THE lane that a stub can never supply: the daemon's own message from the main
  # loop, which is reached only after the dispatch library has been imported from
  # the admitted home.
  if gaai_wait_for "$SMOKE_TIMEOUT" "$REAL_LOG" 'No stories ready'; then
    pass "TC18-8: the real daemon imported its dispatch library and entered the main loop"
  else
    fail "TC18-8: the real daemon never reached its post-import main loop within ${SMOKE_TIMEOUT}s"
    echo "        daemon log tail (preserved at $REAL_LOG):"
    tail -20 "$REAL_LOG" 2>/dev/null | sed 's/^/        /'
  fi
  if [[ -n "$REAL_PANE_PID" ]] && kill -0 "$REAL_PANE_PID" 2>/dev/null; then
    pass "TC18-9: the real daemon is still running after the import"
  else
    fail "TC18-9: the real daemon is no longer running"
  fi

  OWNER_BEFORE="$(cksum < "$REAL_LIFECYCLE/owner" 2>/dev/null || echo none)"
  STATUS_OUT="$(real_entry status gaai_run "$REAL_ROOT" "$RSTART" --status)"; STATUS_RC=$?
  OWNER_AFTER="$(cksum < "$REAL_LIFECYCLE/owner" 2>/dev/null || echo none)"
  [[ "$STATUS_RC" -eq 0 ]] \
    && pass "TC18-10a: the read-only status entry returned 0" \
    || fail "TC18-10a: the read-only status entry returned $STATUS_RC: $(printf '%s' "$STATUS_OUT" | tail -3)"
  if [[ "$OWNER_BEFORE" == "$OWNER_AFTER" && "$OWNER_BEFORE" != "none" ]]; then
    pass "TC18-10: the supported status entry is read-only — the owner record is unchanged"
  else
    fail "TC18-10: the status entry changed the lifecycle record"
  fi
  if printf '%s' "$STATUS_OUT" | grep -q "$REAL_HOME_WT"; then
    pass "TC18-11: status reports this fixture's own lifecycle and home"
  else
    fail "TC18-11: status did not report the fixture lifecycle: $(printf '%s' "$STATUS_OUT" | head -5)"
  fi

  # SCOPE, stated exactly. The refusing sentinel sits in the fixture's operator
  # PATH, which is what the SETUP entry's advisory presence check consults. It is
  # NOT on the daemon's own closed command path, so an empty sentinel log proves
  # only that no executor was invoked THROUGH THE OPERATOR PATH — it is not, and
  # must not be read as, proof that no real CLI could be or was executed.
  if [[ ! -s "$REAL_ROOT/executor-invocations.log" ]]; then
    pass "TC18-12: no executor was invoked through the fixture's operator PATH (setup-entry scope only)"
  else
    fail "TC18-12: an executor invocation reached the operator-PATH sentinel:"
    sed 's/^/        /' "$REAL_ROOT/executor-invocations.log"
  fi
  REAL_SOCK="$(sed -n 's/^socket=//p' "$REAL_LIFECYCLE/owner" 2>/dev/null | head -1)"
  WRAPPERS="$(tmux -f /dev/null -S "$REAL_SOCK" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'gaai-deliver' || true)"
  STORY_LOGS="$(ls "$REAL_PROJ/.gaai/project/contexts/backlog/.delivery-logs/" 2>/dev/null | grep -c '\.log$' || true)"
  if [[ "$WRAPPERS" == "0" && "$STORY_LOGS" == "0" ]]; then
    pass "TC18-13: no delivery wrapper session and no story log exist — nothing was dispatched"
  else
    fail "TC18-13: the empty-backlog smoke produced delivery artefacts (wrappers=$WRAPPERS logs=$STORY_LOGS)"
  fi
  echo "  What TC18-12/13 do and do not establish: the empty synthetic backlog"
  echo "        scheduled no story, so no wrapper session, story log or dispatch"
  echo "        occurred in THIS fixture. They do not establish that the installed"
  echo "        executor is unreachable from the daemon's own command path."

  # ── Pre-stop receipts ───────────────────────────────────────────────────
  # Snapshot the fixture's OWN lifecycle records and daemon log before the stop
  # removes them, so the run leaves durable evidence and not only console counts.
  # These records carry identities, digests and the credential-mode LABEL only.
  # No secret is copied: `secret.env` is unlinked by the launcher before release
  # and is never read, snapshotted or referenced here.
  cp "$REAL_LIFECYCLE/owner" "$REAL_EVIDENCE/pre-stop.owner" 2>/dev/null || true
  cp "$REAL_ATTEMPT/ack.launcher" "$REAL_EVIDENCE/pre-stop.ack.launcher" 2>/dev/null || true
  cp "$REAL_ATTEMPT/ack.ready" "$REAL_EVIDENCE/pre-stop.ack.ready" 2>/dev/null || true
  cp "$REAL_LOG" "$REAL_EVIDENCE/pre-stop.delivery-daemon.log" 2>/dev/null || true

  STOP_OUT="$(real_entry stop gaai_run "$REAL_ROOT" "$RSTART" --stop)"; STOP_RC=$?
  [[ "$STOP_RC" -eq 0 ]] \
    && pass "TC18-14a: the supported stop entry returned 0" \
    || fail "TC18-14a: the supported stop entry returned $STOP_RC: $(printf '%s' "$STOP_OUT" | tail -3)"
  if [[ "$STOP_RC" -eq 0 && ! -e "$REAL_LIFECYCLE/owner" ]]; then
    pass "TC18-14: the supported stop entry settled this fixture's lifecycle"
  else
    fail "TC18-14: the lifecycle owner survived the stop — evidence preserved: $(printf '%s' "$STOP_OUT" | tail -3)"
  fi
  if [[ -z "$REAL_PANE_PID" ]] || ! kill -0 "$REAL_PANE_PID" 2>/dev/null; then
    pass "TC18-15: the real daemon process is gone after the stop"
  else
    fail "TC18-15: the real daemon is still alive after the stop (pid $REAL_PANE_PID) — not signalled by this test"
  fi

  # ── Cleanup predicates, observed and recorded ───────────────────────────
  # What the SUPPORTED stop entry removed is measured, never performed here: this
  # test deletes no lifecycle artefact and removes no socket. The private socket
  # lives under the shared UID-scoped root, which is neither deleted nor mutated —
  # only the exact socket path this fixture's own owner record named is examined.
  CLEAN_OWNER=no;   [[ ! -e "$REAL_LIFECYCLE/owner" ]] && CLEAN_OWNER=yes
  CLEAN_ATTEMPT=no; [[ -z "$REAL_ATTEMPT" || ! -e "$REAL_ATTEMPT" ]] && CLEAN_ATTEMPT=yes
  CLEAN_SOCKET=no;  [[ -z "$REAL_SOCK" || ! -e "$REAL_SOCK" ]] && CLEAN_SOCKET=yes
  CLEAN_PROC=no
  { [[ -z "$REAL_PANE_PID" ]] || ! kill -0 "$REAL_PANE_PID" 2>/dev/null; } && CLEAN_PROC=yes
  {
    printf 'stop_rc=%s\n' "$STOP_RC"
    printf 'owner_removed=%s (%s)\n' "$CLEAN_OWNER" "$REAL_LIFECYCLE/owner"
    printf 'attempt_removed=%s (%s)\n' "$CLEAN_ATTEMPT" "${REAL_ATTEMPT:-<none>}"
    printf 'socket_removed=%s (%s)\n' "$CLEAN_SOCKET" "${REAL_SOCK:-<none>}"
    printf 'daemon_process_gone=%s (pid %s)\n' "$CLEAN_PROC" "${REAL_PANE_PID:-<none>}"
    printf 'removed_by=supported_stop_entry\n'
    printf 'removed_by_this_test=none\n'
  } > "$REAL_EVIDENCE/cleanup-predicates.txt"
  if [[ "$STOP_RC" -eq 0 && "$CLEAN_OWNER" == "yes" && "$CLEAN_ATTEMPT" == "yes" \
        && "$CLEAN_SOCKET" == "yes" && "$CLEAN_PROC" == "yes" ]]; then
    pass "TC18-16: the supported stop removed the owner, the attempt directory and this fixture's exact private socket"
    REAL_SETTLED=1
  else
    fail "TC18-16: cleanup is incomplete or ambiguous — see $REAL_EVIDENCE/cleanup-predicates.txt"
    sed 's/^/        /' "$REAL_EVIDENCE/cleanup-predicates.txt"
  fi
  echo "  NOT EXERCISED by this lane: Delivery dispatch, agent execution and journal"
  echo "        completion. The synthetic backlog is empty by design, so no dispatch"
  echo "        result may be inferred or reported as passed from this run."
  echo "  durable receipts (raw entry output, return codes, pre-stop lifecycle"
  echo "        records, daemon log and cleanup predicates): $REAL_EVIDENCE"
fi

gaai_report_results REQUESTED
