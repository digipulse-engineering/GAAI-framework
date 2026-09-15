#!/usr/bin/env bash
# yaml-runtime.test.sh — reproducibility, purity, descriptor, semantic and
# platform matrices for the vendored offline YAML runtime and its invocation
# boundary.
#
# Two modes, both deterministic. The closed matrix never skips; the default
# host-smoke mode reports at most the tool-conditional legs as visible SKIPs.
#
#   host-smoke (default)         no configuration; discovers a supported
#                                interpreter through the production path and
#                                fails if none exists.
#   closed matrix                GAAI_YAML_TEST_MATRIX=1 with GAAI_YAML_PYTHON,
#                                GAAI_TEST_BASH, GAAI_YAML_TEST_PYTHON_EXPECT
#                                and GAAI_YAML_TEST_BASH_EXPECT. Any missing or
#                                invalid input is a FAIL, not a skip.
#
# GAAI_YAML_TEST_SDIST=<abs path> additionally enables the local rebuild
# assertions. Its absence in a continuous-integration context is a designed-out
# condition, never a skipped cell; at local admission time an unset value is a
# FAIL because the rebuild proof is mandatory there.
#
# Terminal contract: the last stdout line is always
#   YAML-RUNTIME-RESULT pass=<n> fail=<m> status=pass|fail
#
# Every positive support claim below executes the real interpreter and the
# complete semantic corpus. A mocked version probe proves rejection ordering
# only. No production fault seam exists or is accepted: faults are injected
# either externally (environment, declared path, caller-program action) against
# the production boundary, or into a private copy of the helper or the tree.

set -uo pipefail

# ── Closed-matrix re-exec (guarded, exactly once) ────────────────────────────
if [ "${GAAI_YAML_TEST_MATRIX:-0}" = "1" ] && [ -z "${GAAI_YAML_TEST_REEXEC:-}" ]; then
  if [ -z "${GAAI_TEST_BASH:-}" ] || [ ! -x "${GAAI_TEST_BASH:-/nonexistent}" ]; then
    echo "  FAIL: matrix mode requires an executable GAAI_TEST_BASH"
    echo "YAML-RUNTIME-RESULT pass=0 fail=1 status=fail"
    exit 1
  fi
  GAAI_YAML_TEST_REEXEC=1
  export GAAI_YAML_TEST_REEXEC
  exec "$GAAI_TEST_BASH" "$0" "$@"
fi

PASS_COUNT=0
FAIL_COUNT=0
ABORTED=1

pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaai-yaml-runtime-test.XXXXXX")"
chmod 700 "$TMP_ROOT"

_final() {
  local status=fail
  # Restore any mode a fault case removed so cleanup can complete, including
  # nested and deliberately hostile remnants.
  chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true
  case "${DISC_BASE:-}" in
    */.gaai-yaml-disc.*) chmod -R u+rwX "$DISC_BASE" 2>/dev/null || true; rm -rf "$DISC_BASE" 2>/dev/null || true ;;
  esac
  case "$TMP_ROOT" in
    "${TMPDIR:-/tmp}"/gaai-yaml-runtime-test.*) rm -rf "$TMP_ROOT" 2>/dev/null || true ;;
  esac
  # A floor, not a count: the terminal line used to report only what ran, so a
  # fixture regression that skipped assertions without recording a fail still
  # showed status=pass and CI (which greps status=pass$) stayed green. Raise
  # this number when assertions are added; never lower it to make a run pass.
  # 151 is the compiler-less interactive minimum; the closed matrix and local
  # admission turn every conditional executing-image negative into a FAIL rather
  # than a SKIP, so the floor never masks a vanished negative there (the rebuild
  # proof at 8.a stays gated on GAAI_YAML_TEST_SDIST, per the header).
  YAML_RUNTIME_PASS_FLOOR=151
  if [ "$FAIL_COUNT" -eq 0 ] && [ "$ABORTED" -eq 0 ] \
     && [ "$PASS_COUNT" -ge "$YAML_RUNTIME_PASS_FLOOR" ]; then
    status=pass
  elif [ "$FAIL_COUNT" -eq 0 ] && [ "$ABORTED" -eq 0 ]; then
    echo "  FAIL: pass count $PASS_COUNT is below the floor of $YAML_RUNTIME_PASS_FLOOR — assertions were skipped"
  fi
  echo "YAML-RUNTIME-RESULT pass=${PASS_COUNT} fail=${FAIL_COUNT} status=${status}"
  if [ "$status" != "pass" ]; then
    exit 1
  fi
  exit 0
}
trap _final EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CORE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LIB_PATH="$CORE_DIR/scripts/lib/yaml-runtime.sh"
VENDOR_DIR="$CORE_DIR/vendor/pyyaml/6.0.3"
BUILDER_PATH="$CORE_DIR/scripts/build-yaml-runtime.sh"

echo "yaml-runtime — offline attested runtime and boundary"
echo ""

if [ ! -f "$LIB_PATH" ]; then
  fail "boundary library is missing"
  exit 1
fi

# shellcheck source=../lib/yaml-runtime.sh
. "$LIB_PATH"

_mode_of() {
  if stat -f '%Lp' / >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1" 2>/dev/null
  else
    stat -c '%a' -- "$1" 2>/dev/null
  fi
}

# _call <helper> <fn> [args...] — run one boundary entry from a chosen helper.
_call() {
  local helper="$1"
  shift
  (
    set +e
    unset _YAML_RUNTIME_SH_SOURCED
    . "$helper" >/dev/null 2>&1 || exit 90
    "$@"
  )
}

# make_private_core <dst> — a private copy of just the boundary and the tuple,
# in the exact relative shape the single vendor-resolution rule expects.
make_private_core() {
  local dst="$1"
  mkdir -p "$dst/scripts/lib" "$dst/vendor/pyyaml/6.0.3"
  cp "$LIB_PATH" "$dst/scripts/lib/yaml-runtime.sh"
  cp "$VENDOR_DIR/pyyaml-runtime.pyz" "$VENDOR_DIR/PROVENANCE.json" \
     "$VENDOR_DIR/LICENSE" "$dst/vendor/pyyaml/6.0.3/"
  # cp without -p applies the current umask, so a restrictive umask would land
  # the copies at 0600. Fix the mode, then assert it: the deliberate umask 077
  # scenarios below are a different situation and must not be conflated with an
  # accidental one here.
  chmod 0644 "$dst/vendor/pyyaml/6.0.3/"pyyaml-runtime.pyz \
             "$dst/vendor/pyyaml/6.0.3/"PROVENANCE.json \
             "$dst/vendor/pyyaml/6.0.3/"LICENSE
  local f
  for f in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
    if [ "$(_mode_of "$dst/vendor/pyyaml/6.0.3/$f")" != "644" ]; then
      # A failure here is RECORDED, never silent. Every caller guards on the
      # returned path -- `|| true` followed by `if [ -n "$X" ]`, or `|| continue`,
      # or `|| return 1` inside fault_case, which alone runs 22 times. Without
      # this line an unbuildable fixture skips dozens of assertions while the
      # suite still prints status=pass, because the terminal line carries a
      # count, not a floor, so nothing downstream notices the shortfall.
      fail "fixture: make_private_core could not place $f at 0644 — assertions guarded by it are being skipped"
      return 1
    fi
  done
  printf '%s\n' "$dst/scripts/lib/yaml-runtime.sh"
}

# expect_code <label> <expected-exit> <captured-stderr-file> <actual-exit> <code>
expect_code() {
  local label="$1" want="$2" errfile="$3" got="$4" code="$5"
  if [ "$got" != "$want" ]; then
    fail "$label — expected exit $want, got $got"
    return 1
  fi
  if ! grep -q "code=${code}" "$errfile" 2>/dev/null; then
    fail "$label — expected code=${code} in the diagnostic"
    return 1
  fi
  pass "$label"
  return 0
}

# assert_path_free <label> <file> — every [yaml-runtime] line on a fault path
# must contain no '/' at all and must never be the success status.
assert_path_free() {
  local label="$1" file="$2"
  if grep '^\[yaml-runtime\]' "$file" 2>/dev/null | grep -q '/'; then
    fail "$label — a diagnostic leaked a path"
    return 1
  fi
  if grep -q 'code=ok' "$file" 2>/dev/null; then
    fail "$label — the success status appeared on a fault path"
    return 1
  fi
  pass "$label"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 0. Mode identity and lane assertions
# ══════════════════════════════════════════════════════════════════════════

if [ "${GAAI_YAML_TEST_MATRIX:-0}" = "1" ]; then
  for required in GAAI_YAML_PYTHON GAAI_TEST_BASH GAAI_YAML_TEST_PYTHON_EXPECT GAAI_YAML_TEST_BASH_EXPECT; do
    eval "value=\${$required:-}"
    if [ -z "$value" ]; then
      fail "matrix mode requires $required"
    fi
  done
  # The guard, not a convenience: GAAI_TEST_BASH may already be the running
  # shell, and an unguarded re-exec would fork forever.
  BASH_LANE="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if [ "${GAAI_YAML_TEST_BASH_EXPECT:-}" = "3.2" ]; then
    if [ "$BASH_LANE" != "3.2" ]; then
      fail "expected Bash 3.2, running $BASH_LANE"
    fi
  else
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
      fail "expected a current Bash, running $BASH_LANE"
    fi
  fi
  MATRIX_LINE="$(yaml_runtime_verify_tuple 2>"$TMP_ROOT/matrix.err")"
  MATRIX_RC=$?
  if [ "$MATRIX_RC" -ne 0 ]; then
    fail "matrix cell could not verify the runtime tuple"
    CELL_PY="unknown"
  else
    CELL_PY="$(printf '%s\n' "$MATRIX_LINE" | sed -n 's/^python=\([^ ]*\) .*/\1/p')"
  fi
  case "$CELL_PY" in
    "${GAAI_YAML_TEST_PYTHON_EXPECT:-none}".*) : ;;
    *) fail "expected CPython ${GAAI_YAML_TEST_PYTHON_EXPECT:-}, selected $CELL_PY" ;;
  esac
  echo "YAML-RUNTIME-CELL python=${CELL_PY} bash=${BASH_LANE} mode=matrix"
fi

# ══════════════════════════════════════════════════════════════════════════
# 1. Distributed tuple: manifest self-consistency and archive purity census
# ══════════════════════════════════════════════════════════════════════════
echo "1. distributed tuple"

for f in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
  if [ -f "$VENDOR_DIR/$f" ] && [ ! -L "$VENDOR_DIR/$f" ]; then
    pass "1.a $f is a regular file"
  else
    fail "1.a $f is missing or not a regular file"
  fi
  if [ "$(_mode_of "$VENDOR_DIR/$f")" = "644" ]; then
    pass "1.b $f is at exact 0644"
  else
    fail "1.b $f is not at exact 0644"
  fi
done

if yaml_runtime_verify_tuple >"$TMP_ROOT/verify.out" 2>"$TMP_ROOT/verify.err"; then
  pass "1.c the complete tuple verifies through the boundary"
else
  fail "1.c the complete tuple did not verify: $(cat "$TMP_ROOT/verify.err")"
fi
if grep -qE '^python=3\.(12|13|14)\.[0-9]+ trust=(explicit|discovered) runtime=6\.0\.3$' "$TMP_ROOT/verify.out"; then
  pass "1.d verification reports the selected version, trust mode and runtime version"
else
  fail "1.d verification report line is malformed: $(cat "$TMP_ROOT/verify.out")"
fi

# The manifest census is executed by the attested runtime itself, over the
# manifest and archive as they exist on disk.
cat > "$TMP_ROOT/census.py" <<'PY'
import hashlib, io, json, os, stat, sys, zipfile

manifest_path, archive_path, licence_path = sys.argv[1:4]
manifest = json.loads(open(manifest_path, "rb").read().decode("utf-8"))
problems = []

archive_bytes = open(archive_path, "rb").read()
if hashlib.sha256(archive_bytes).hexdigest() != manifest["output"]["sha256"]:
    problems.append("output-digest")
if len(archive_bytes) != manifest["output"]["size_bytes"]:
    problems.append("output-size")

licence_bytes = open(licence_path, "rb").read()
if hashlib.sha256(licence_bytes).hexdigest() != manifest["licence"]["sha256"]:
    problems.append("licence-digest")
if len(licence_bytes) != manifest["licence"]["size_bytes"]:
    problems.append("licence-size")

with zipfile.ZipFile(io.BytesIO(archive_bytes)) as zf:
    names = zf.namelist()
    declared = [m["path"] for m in manifest["archive"]["members"]]
    if names != declared:
        problems.append("member-census")
    if len(set(names)) != len(names):
        problems.append("duplicate-member")
    if names != sorted(names):
        problems.append("member-order")
    for member in manifest["archive"]["members"]:
        info = zf.getinfo(member["path"])
        if info.compress_type != zipfile.ZIP_STORED:
            problems.append("compression")
        if info.date_time != (1980, 1, 1, 0, 0, 0):
            problems.append("member-timestamp")
        if stat.S_IMODE(info.external_attr >> 16) != 0o644:
            problems.append("member-mode")
        if member["mode"] != "0644":
            problems.append("declared-member-mode")
        if hashlib.sha256(zf.read(member["path"])).hexdigest() != member["sha256"]:
            problems.append("member-digest")
        if info.extra:
            problems.append("member-extra")
    for name in names:
        if not name.startswith("yaml/") or not name.endswith(".py"):
            problems.append("impure-member")
        if name.endswith((".pyc", ".so", ".pyd", ".dylib")):
            problems.append("native-or-bytecode")

if manifest["rebuild"]["network_required"] is not False:
    problems.append("rebuild-network")
if manifest["framework"]["supported_cpython_minors"] != ["3.12", "3.13", "3.14"]:
    problems.append("support-boundary")
if manifest["upstream"]["requires_python"] != ">=3.8":
    problems.append("upstream-requires")

sys.stdout.write(",".join(sorted(set(problems))))
PY

CENSUS="$(yaml_runtime_run "$VENDOR_DIR/PROVENANCE.json" "$VENDOR_DIR/pyyaml-runtime.pyz" \
  "$VENDOR_DIR/LICENSE" < "$TMP_ROOT/census.py" 2>"$TMP_ROOT/census.err")"
if [ -z "$CENSUS" ]; then
  pass "1.e archive purity and manifest self-consistency census is clean"
else
  fail "1.e purity census reported: $CENSUS"
fi

# The upstream compatibility metadata never lowers the Framework boundary.
if grep -q '"requires_python": ">=3.8"' "$VENDOR_DIR/PROVENANCE.json" \
  && grep -q '"3.12"' "$VENDOR_DIR/PROVENANCE.json"; then
  pass "1.f upstream metadata and the Framework allowlist are both recorded and distinct"
else
  fail "1.f the manifest does not record both the upstream metadata and the allowlist"
fi

# ══════════════════════════════════════════════════════════════════════════
# 2. Interpreter trust modes, discovery and the executing-image binding
# ══════════════════════════════════════════════════════════════════════════
echo "2. interpreter trust modes"

# 2.a default discovery executes against the production boundary. The
# expectation is computed by this suite as an independent oracle over the fixed
# candidate list, never read back out of the boundary.
oracle_first_qualifying_minor() {
  local minor dir cand target owner mode chain euid
  euid="$(id -u)"
  for minor in 3.14 3.13 3.12; do
    case "$(uname)" in
      Darwin) set -- /opt/homebrew/bin /usr/local/bin "/Library/Frameworks/Python.framework/Versions/$minor/bin" /usr/bin ;;
      *) set -- /usr/bin /bin /usr/local/bin ;;
    esac
    for dir in "$@"; do
      cand="$dir/python$minor"
      [ -e "$cand" ] || continue
      target="$(realpath -- "$cand" 2>/dev/null)" || continue
      [ -f "$target" ] || continue
      [ -x "$target" ] || continue
      chain="$target"
      local ok=1 p="$target"
      while :; do
        if stat -f '%Su:%Lp' / >/dev/null 2>&1; then
          owner="$(stat -f '%u' -- "$p" 2>/dev/null)"; mode="$(stat -f '%Lp' -- "$p" 2>/dev/null)"
        else
          owner="$(stat -c '%u' -- "$p" 2>/dev/null)"; mode="$(stat -c '%a' -- "$p" 2>/dev/null)"
        fi
        if [ -z "$owner" ] || [ -z "$mode" ]; then ok=0; break; fi
        if [ "$owner" != "0" ] && [ "$owner" != "$euid" ]; then ok=0; break; fi
        if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then ok=0; break; fi
        [ "$p" = "/" ] && break
        p="$(dirname -- "$p")"
      done
      if [ "$ok" -eq 1 ]; then
        printf '%s\n' "$minor"
        return 0
      fi
    done
  done
  return 1
}

EXPECTED_DISCOVERY_MINOR="$(oracle_first_qualifying_minor || true)"
DISCOVERY_OUT="$(env -u GAAI_YAML_PYTHON bash -c '. "$1"; yaml_runtime_verify_tuple' _ "$LIB_PATH" 2>"$TMP_ROOT/disc.err")"
DISCOVERY_RC=$?
if [ -n "$EXPECTED_DISCOVERY_MINOR" ]; then
  if [ "$DISCOVERY_RC" -eq 0 ] \
     && printf '%s\n' "$DISCOVERY_OUT" | grep -q "^python=${EXPECTED_DISCOVERY_MINOR}\." \
     && printf '%s\n' "$DISCOVERY_OUT" | grep -q 'trust=discovered'; then
    pass "2.a default discovery selects the first qualifying fixed candidate in mode=discovered"
  else
    fail "2.a default discovery did not select ${EXPECTED_DISCOVERY_MINOR}: rc=$DISCOVERY_RC out=$DISCOVERY_OUT"
  fi
else
  # No fixed candidate qualifies on this host. That is a contract-level gap, not
  # a passing condition: the boundary must reject, typed and path-free.
  if [ "$DISCOVERY_RC" -eq 31 ] && grep -q 'code=yaml_runtime_interpreter_invalid' "$TMP_ROOT/disc.err"; then
    fail "2.a no fixed default-discovery candidate qualifies on this host (typed rejection observed)"
  else
    fail "2.a no qualifying candidate and no typed rejection: rc=$DISCOVERY_RC"
  fi
fi

# 2.b an explicitly declared trust root is accepted end to end.
REAL_PY="${GAAI_YAML_PYTHON:-}"
if [ -z "$REAL_PY" ]; then
  REAL_PY="$(env -u GAAI_YAML_PYTHON bash -c '. "$1"; _yr_select_interpreter && printf "%s" "$_YR_PY"' _ "$LIB_PATH" 2>/dev/null)"
fi
if [ -n "$REAL_PY" ] && [ -x "$REAL_PY" ]; then
  if GAAI_YAML_PYTHON="$REAL_PY" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/explicit.err"; then
    pass "2.b an explicitly declared trust root is accepted"
  else
    fail "2.b an explicitly declared trust root was rejected: $(cat "$TMP_ROOT/explicit.err")"
  fi
else
  fail "2.b no interpreter could be selected for the explicit-mode assertions"
fi

# 2.d a shell shim is refused before it is ever executed, in BOTH trust modes.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/python3.13" <<'SH'
#!/bin/sh
exec /usr/bin/true "$@"
SH
chmod 0755 "$SHIM_DIR/python3.13"
GAAI_YAML_PYTHON="$SHIM_DIR/python3.13" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/shim.err"
SHIM_RC=$?
expect_code "2.d a shell shim is rejected in explicit mode at the magic-byte scan" \
  31 "$TMP_ROOT/shim.err" "$SHIM_RC" yaml_runtime_interpreter_invalid
assert_path_free "2.e the interpreter rejection diagnostic is path-free" "$TMP_ROOT/shim.err"

# 2.f the executing-image binding rejects an argv[0]-preserving re-exec (the
# executing-image binding decision).
# The negative is SYNTHETIC and uses no production seam: a native wrapper is
# compiled into the private TMP root from the source below and declared as the
# trust root. It passes the shell layer's magic-byte scan (it is a real native
# image) and then execv()s the real interpreter with argv[0] preserved, so
# sys.executable would still equal the declared path -- exactly the case a
# sys.executable comparison cannot see. The kernel-loaded image differs from
# the declared path, so the binding must reject it, typed and path-free. This
# case exists specifically to fail if the binding is ever weakened back to
# sys.executable. A C compiler is present on every governed lane
# (/usr/bin/cc). In the closed matrix and under local admission the negative
# is mandatory: a missing compiler or an unbuilt fixture is a FAIL. Only an
# interactive developer run reports it as a visible SKIP.
# Discrimination note: on Linux this fixture separates the kernel-image
# binding from a sys.executable comparison (argv[0] flows into sys.executable
# there). On Darwin CPython rewrites sys.executable to the real launcher, so
# both comparisons reject this fixture; the Darwin-side behavioural negative is
# 2.f4 below. 2.r is a call-site text tripwire, not a behavioural guard.
if [ -n "$REAL_PY" ] && [ -x "$REAL_PY" ]; then
  REAL_PY_REAL="$(realpath -- "$REAL_PY" 2>/dev/null || printf '%s' "$REAL_PY")"
  REEXEC_DIR="$TMP_ROOT/reexec"
  mkdir -p "$REEXEC_DIR"
  cat > "$REEXEC_DIR/reexec.c" <<'C'
#include <unistd.h>
#ifndef REAL
#error "REAL must name the real interpreter"
#endif
int main(int argc, char **argv) {
  (void)argc;
  execv(REAL, argv);  /* argv[0] preserved: sys.executable == declared path */
  return 127;
}
C
  REEXEC_BIN=""
  if command -v cc >/dev/null 2>&1 \
      && cc -DREAL="\"$REAL_PY_REAL\"" -o "$REEXEC_DIR/python3" "$REEXEC_DIR/reexec.c" >/dev/null 2>&1 \
      && [ -x "$REEXEC_DIR/python3" ]; then
    REEXEC_BIN="$REEXEC_DIR/python3"
  fi
  if [ -n "$REEXEC_BIN" ]; then
    # Control: the wrapper really re-executes the real interpreter (argv[0]
    # preserved), so a rejection below is the binding's, not a broken fixture.
    if "$REEXEC_BIN" -I -S -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
      GAAI_YAML_PYTHON="$REEXEC_BIN" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/reexec.err"
      REEXEC_RC=$?
      expect_code "2.f an argv[0]-preserving native re-exec is rejected by the executing-image binding" \
        31 "$TMP_ROOT/reexec.err" "$REEXEC_RC" yaml_runtime_interpreter_invalid
      assert_path_free "2.f2 the re-exec rejection diagnostic is path-free" "$TMP_ROOT/reexec.err"
    else
      fail "2.f the synthetic re-exec fixture does not execute the real interpreter"
    fi
  elif [ "${GAAI_YAML_TEST_LOCAL_ADMISSION:-0}" = "1" ] || [ "${GAAI_YAML_TEST_MATRIX:-0}" = "1" ]; then
    fail "2.f the executing-image negative is mandatory in the closed matrix and under local admission; no C compiler or the fixture did not build"
  else
    echo "  SKIP: 2.f executing-image negative not run (no C compiler or the fixture did not build; mandatory in the closed matrix and under local admission)"
  fi

  # 2.f4 Darwin behavioural negative for the same binding. A copy of the
  # framework launcher placed outside its Python.framework root boots (the
  # launcher re-executes the framework's real image) and reports
  # sys.executable EQUAL to the declared copy path, while the kernel-loaded
  # image lives under the framework root the copy does not share. A binding
  # weakened to sys.executable admits it; the real binding rejects it, typed.
  # Not applicable off Darwin or when the selected interpreter is not a
  # framework launcher (a plain copy of a monolithic binary is a real
  # interpreter and is correctly admitted).
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    case "$REAL_PY_REAL" in
      */Python.framework/Versions/*/bin/*)
        STUB_DIR="$TMP_ROOT/stubcopy"
        mkdir -p "$STUB_DIR"
        STUB_EXE=""
        if cp -- "$REAL_PY_REAL" "$STUB_DIR/python3" 2>/dev/null && chmod 0755 "$STUB_DIR/python3"; then
          STUB_EXE="$("$STUB_DIR/python3" -I -S -c 'import sys; sys.stdout.write(sys.executable)' 2>/dev/null || true)"
        fi
        if [ -z "$STUB_EXE" ]; then
          fail "2.f4 the launcher copy could not be created or did not boot"
        elif [ "$(realpath -- "$STUB_EXE" 2>/dev/null)" != "$(realpath -- "$STUB_DIR/python3" 2>/dev/null)" ]; then
          fail "2.f4 the launcher copy booted but sys.executable is not the declared path"
        else
          GAAI_YAML_PYTHON="$STUB_DIR/python3" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/stubcopy.err"
          STUB_RC=$?
          expect_code "2.f4 a launcher copy outside its framework root is rejected although sys.executable equals the declared path" \
            31 "$TMP_ROOT/stubcopy.err" "$STUB_RC" yaml_runtime_interpreter_invalid
        fi
        ;;
      *)
        echo "  NOTE: 2.f4 not applicable (the selected interpreter is not a framework launcher)"
        ;;
    esac
  else
    echo "  NOTE: 2.f4 not applicable off Darwin (2.f discriminates on Linux)"
  fi

  # 2.f3 a DIFFERING real interpreter is judged on its own merits, not by
  # comparison with the selected one: a supported final CPython is admitted as
  # its own explicit trust root; an unsupported one is rejected, typed. (An
  # earlier revision expected every differing interpreter to be rejected, which
  # only held on hosts whose system python3 happens to be unsupported.)
  OTHER_PY=""
  for cand in /usr/bin/python3 /bin/python3 /usr/local/bin/python3; do
    if [ -x "$cand" ]; then
      CAND_REAL="$(realpath -- "$cand" 2>/dev/null || printf '%s' "$cand")"
      if [ "$CAND_REAL" != "$REAL_PY_REAL" ]; then
        OTHER_PY="$cand"
        break
      fi
    fi
  done
  if [ -n "$OTHER_PY" ]; then
    OTHER_MINOR="$("$OTHER_PY" -I -S -c 'import sys; sys.stdout.write("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    GAAI_YAML_PYTHON="$OTHER_PY" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/other.err"
    OTHER_RC=$?
    case "$OTHER_MINOR" in
      3.12|3.13|3.14)
        if [ "$OTHER_RC" -eq 0 ]; then
          pass "2.f3 a differing but supported real interpreter is admitted as its own trust root"
        else
          fail "2.f3 a differing but supported real interpreter was rejected (exit $OTHER_RC): $(cat "$TMP_ROOT/other.err")"
        fi
        ;;
      *)
        expect_code "2.f3 a differing unsupported interpreter is rejected, typed" \
          31 "$TMP_ROOT/other.err" "$OTHER_RC" yaml_runtime_interpreter_invalid
        ;;
    esac
  else
    pass "2.f3 no second interpreter present to contrast (single-interpreter host)"
  fi
fi

# 2.g the real platform positive: the selected interpreter's real image is
# admitted. On Darwin that is the same-framework-root branch for a genuine
# framework build; on Linux it is plain equality with the canonical path.
if yaml_runtime_verify_tuple >/dev/null 2>&1; then
  pass "2.g the platform's real executing image is admitted by the binding"
else
  fail "2.g the platform's real executing image was not admitted"
fi

# 2.h-2.n The discovery predicate itself, exercised in a private helper copy
# whose fixed candidate directories are a private root. Canonicalization by
# design leaves any symlink to a system interpreter outside a private root, so
# these cases assert the *selection* layer — which is exactly the predicate under
# test — with a native regular executable standing in as the candidate. End-to-end
# execution of a genuinely selected interpreter is proved by 2.a and 2.g against
# the production boundary. No production seam exists.
# The discovery predicate refuses any ancestor with group/other write, and it is
# right to. That makes TMP_ROOT unusable as a discovery root wherever TMPDIR
# resolves under /tmp (1777) -- which is the hosted Linux runner, where TMPDIR is
# not set at all. So the discovery fixtures live under a private root whose whole
# chain the suite controls: $HOME by preference, TMP_ROOT only as a last resort.
# The predicate is never weakened to fit the harness.
# The root is chosen by the predicate under test, not by writability: a 0700
# directory under a world-writable ancestor is still refused by the ancestor
# audit, so each candidate is probed with the boundary's own
# _yr_audit_owner_chain before it is used. If no candidate qualifies, that is a
# harness-environment fault and is reported as one -- never allowed to surface
# as a false 2.i rejection that blames the selection predicate.
DISC_BASE=""; DISC_ROOT_OK=1
# RUNNER_TEMP is a candidate for direct hosted runs; the closed-matrix lane
# runs under `env -i` and does not pass it, and is saved by HOME instead.
# Last resort: the repository's git common directory. Under the delivery
# daemon HOME and TMPDIR both live beneath /tmp — a world-writable ancestor —
# so none of the roots above can qualify there, while .git/ sits on the
# operator's own path and is never part of the working tree.
_yr_git_scratch=""
if command -v git >/dev/null 2>&1; then
  _yr_git_scratch="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || _yr_git_scratch=""
  if [ -n "$_yr_git_scratch" ] && [ -d "$_yr_git_scratch" ]; then
    _yr_git_scratch="$(cd "$_yr_git_scratch" && pwd -P)/gaai"
    mkdir -p "$_yr_git_scratch" 2>/dev/null || _yr_git_scratch=""
  else
    _yr_git_scratch=""
  fi
fi
for cand in "${HOME:-}" "${RUNNER_TEMP:-}" "$TMP_ROOT" "$_yr_git_scratch"; do
  [ -n "$cand" ] && [ -d "$cand" ] && [ -w "$cand" ] || continue
  probe="$(mktemp -d "$cand/.gaai-yaml-disc.XXXXXX" 2>/dev/null)" || continue
  chmod 0700 "$probe"
  # Audit what the runtime will audit: it resolves a candidate before walking
  # its ancestors, and on macOS /tmp is a symlink into /private/tmp (1777) that
  # lstat reports as 0755. Auditing the unresolved path accepts a root the
  # runtime must then refuse, and 2.i blames the predicate for the harness.
  probe_real="$(cd "$probe" 2>/dev/null && pwd -P)" || probe_real="$probe"
  if _yr_audit_owner_chain "$probe_real" 2>/dev/null; then
    DISC_BASE="$probe"
    break
  fi
  rm -rf "$probe" 2>/dev/null || true
done
if [ -z "$DISC_BASE" ]; then
  fail "harness: no discovery root with a clean owner chain is available (HOME, RUNNER_TEMP and TMPDIR all sit under a group/other-writable ancestor); the 2.h-2.n selection cases cannot be evaluated here"
  DISC_ROOT_OK=0
  DISC_BASE="$TMP_ROOT/disc-base"
  mkdir -p "$DISC_BASE"; chmod 0700 "$DISC_BASE"
fi
DISC_ROOT="$DISC_BASE/disc-root"
mkdir -p "$DISC_ROOT/bin"
chmod 0755 "$DISC_ROOT" "$DISC_ROOT/bin"
NATIVE_SAMPLE=""
for cand in /bin/ls /usr/bin/env /bin/cat; do
  if [ -f "$cand" ] && [ -x "$cand" ]; then
    NATIVE_SAMPLE="$cand"
    break
  fi
done
PRIV_DISC="$(make_private_core "$DISC_BASE/disc-core")" || PRIV_DISC=""

_select_in() {
  # _select_in <helper> — prints "<rc> <selected path>"
  env -u GAAI_YAML_PYTHON bash -c \
    '. "$1" >/dev/null 2>&1; _yr_select_interpreter; rc=$?; printf "%s %s" "$rc" "${_YR_PY:-}"' \
    _ "$1" 2>/dev/null
}

if [ "$DISC_ROOT_OK" != 1 ]; then
  echo "  SKIP: 2.h-2.n selection cases not evaluable in this environment (reported as a harness failure above)"
elif [ -n "$PRIV_DISC" ] && [ -n "$NATIVE_SAMPLE" ]; then
  sed -e "s|dirs=\"/opt/homebrew/bin.*\" ;;|dirs=\"$DISC_ROOT/bin\" ;;|" \
      -e "s|dirs=\"/usr/bin /bin /usr/local/bin\" ;;|dirs=\"$DISC_ROOT/bin\" ;;|" \
      "$PRIV_DISC" > "$PRIV_DISC.tmp" && mv "$PRIV_DISC.tmp" "$PRIV_DISC"
  if grep -q "$DISC_ROOT/bin" "$PRIV_DISC"; then
    pass "2.h a private discovery root is installed in the helper copy"
  else
    fail "2.h could not rewrite the private helper's fixed candidate list"
  fi

  CAND="$DISC_ROOT/bin/python3.14"
  cp "$NATIVE_SAMPLE" "$CAND"
  chmod 0755 "$CAND"

  SEL="$(_select_in "$PRIV_DISC")"
  EXPECTED_CAND="$(_call "$PRIV_DISC" _yr_canonicalize "$CAND" 2>/dev/null)"
  if [ "${SEL%% *}" = "0" ] && [ "${SEL#* }" = "$EXPECTED_CAND" ]; then
    pass "2.i a qualifying candidate in the private root is selected — the rejections below are the predicate, not the harness"
  else
    fail "2.i a qualifying private candidate was not selected: $SEL"
  fi

  chmod 0775 "$DISC_ROOT/bin"
  SEL="$(_select_in "$PRIV_DISC")"
  if [ "${SEL%% *}" = "31" ]; then
    pass "2.j a group-writable canonical ancestor is rejected in discovery mode"
  else
    fail "2.j a group-writable ancestor was not rejected: $SEL"
  fi
  chmod 0755 "$DISC_ROOT/bin"

  chmod 0757 "$CAND"
  SEL="$(_select_in "$PRIV_DISC")"
  if [ "${SEL%% *}" = "31" ]; then
    pass "2.k a candidate at mode 0757 is rejected in discovery mode"
  else
    fail "2.k an other-writable candidate was not rejected: $SEL"
  fi
  chmod 0755 "$CAND"

  cp "$SHIM_DIR/python3.13" "$CAND"
  chmod 0755 "$CAND"
  SEL="$(_select_in "$PRIV_DISC")"
  if [ "${SEL%% *}" = "31" ]; then
    pass "2.l a shell shim in the discovery root is rejected at the magic-byte scan"
  else
    fail "2.l a shell shim was not rejected: $SEL"
  fi
  cp "$NATIVE_SAMPLE" "$CAND"
  chmod 0755 "$CAND"

  # owned by neither root nor the effective UID — injected deterministically
  # without root by falsifying the copy's own effective-UID comparison.
  OWNER_DISC="$TMP_ROOT/disc-owner.sh"
  sed 's|  euid="$(id -u 2>/dev/null)" \|\| return 1|  euid="$(( $(id -u) + 1 ))"|' \
    "$PRIV_DISC" > "$OWNER_DISC"
  if ! grep -q 'euid="$(( $(id -u) + 1 ))"' "$OWNER_DISC"; then
    # portable fallback for sed dialects that treat the alternation differently
    awk '{ if ($0 ~ /euid="\$\(id -u 2>\/dev\/null\)"/) print "  euid=\"$(( $(id -u) + 1 ))\""; else print }' \
      "$PRIV_DISC" > "$OWNER_DISC"
  fi
  SEL="$(_select_in "$OWNER_DISC")"
  if [ "${SEL%% *}" = "31" ]; then
    pass "2.m a candidate owned by neither root nor the effective UID is rejected"
  else
    fail "2.m a foreign-owner candidate was not rejected: $SEL"
  fi

  # explicit mode applies no ancestor audit — the hosted toolcache shape. The
  # same candidate under a world-writable ancestor, at a world-writable mode, is
  # SELECTED when declared, and rejected only by the in-process attestation.
  chmod 0777 "$DISC_ROOT/bin"
  EXPLICIT_SEL="$(GAAI_YAML_PYTHON="$CAND" bash -c \
    '. "$1" >/dev/null 2>&1; _yr_select_interpreter; rc=$?; printf "%s %s %s" "$rc" "${_YR_TRUST:-}" "${_YR_PY:-}"' \
    _ "$PRIV_DISC" 2>/dev/null)"
  case "$EXPLICIT_SEL" in
    "0 explicit $CAND")
      pass "2.n an explicit trust root under a world-writable ancestor is selected — the ancestor audit is discovery-scoped" ;;
    *)
      fail "2.n explicit mode applied a discovery-scoped audit: $EXPLICIT_SEL" ;;
  esac
  chmod 0755 "$DISC_ROOT/bin"
else
  fail "2.h the private discovery fixtures could not be prepared"
fi

# 2.o mocked version probes prove rejection ordering only.
for MOCK in "3, 11" "3, 15"; do
  MOCK_CORE="$TMP_ROOT/mock-$(printf '%s' "$MOCK" | tr -d ' ,')"
  MOCK_HELPER="$(make_private_core "$MOCK_CORE")" || continue
  sed "s/if sys.version_info\[:2\] not in SUPPORTED_MINORS:/if ($MOCK) not in SUPPORTED_MINORS:/" \
    "$MOCK_HELPER" > "$MOCK_HELPER.tmp" && mv "$MOCK_HELPER.tmp" "$MOCK_HELPER"
  _call "$MOCK_HELPER" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/mock.err"
  MOCK_RC=$?
  expect_code "2.o a non-allowlisted minor ($MOCK) is rejected" \
    31 "$TMP_ROOT/mock.err" "$MOCK_RC" yaml_runtime_interpreter_invalid
done

MOCK_CORE="$TMP_ROOT/mock-prerelease"
MOCK_HELPER="$(make_private_core "$MOCK_CORE")" || true
if [ -n "${MOCK_HELPER:-}" ]; then
  sed 's/if sys.version_info.releaselevel != "final":/if "candidate" != "final":/' \
    "$MOCK_HELPER" > "$MOCK_HELPER.tmp" && mv "$MOCK_HELPER.tmp" "$MOCK_HELPER"
  _call "$MOCK_HELPER" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/pre.err"
  PRE_RC=$?
  expect_code "2.p a pre-release build is rejected" \
    31 "$TMP_ROOT/pre.err" "$PRE_RC" yaml_runtime_interpreter_invalid
fi

MOCK_CORE="$TMP_ROOT/mock-impl"
MOCK_HELPER="$(make_private_core "$MOCK_CORE")" || true
if [ -n "${MOCK_HELPER:-}" ]; then
  sed 's/if sys.implementation.name != "cpython":/if "other" != "cpython":/' \
    "$MOCK_HELPER" > "$MOCK_HELPER.tmp" && mv "$MOCK_HELPER.tmp" "$MOCK_HELPER"
  _call "$MOCK_HELPER" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/impl.err"
  IMPL_RC=$?
  expect_code "2.q a non-CPython implementation is rejected" \
    31 "$TMP_ROOT/impl.err" "$IMPL_RC" yaml_runtime_interpreter_invalid
fi

# 2.r an unresolvable executing image is a rejection, never a downgrade to
# sys.executable.
MOCK_CORE="$TMP_ROOT/mock-image"
MOCK_HELPER="$(make_private_core "$MOCK_CORE")" || true
if [ -n "${MOCK_HELPER:-}" ]; then
  awk '{ if ($0 ~ /^    image = real_executing_image\(\)$/ && !done) { print "    image = None"; done=1 } else print }' \
    "$MOCK_HELPER" > "$MOCK_HELPER.tmp" && mv "$MOCK_HELPER.tmp" "$MOCK_HELPER"
  _call "$MOCK_HELPER" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/image.err"
  IMAGE_RC=$?
  expect_code "2.r an unresolvable executing image is rejected, not downgraded" \
    31 "$TMP_ROOT/image.err" "$IMAGE_RC" yaml_runtime_interpreter_invalid
fi

# 2.s ambient influence cannot reach the runtime.
mkdir -p "$TMP_ROOT/hostile"
cat > "$TMP_ROOT/hostile/sitecustomize.py" <<PY
open("$TMP_ROOT/hostile/marker", "w").write("reached")
PY
cat > "$TMP_ROOT/hostile/yaml.py" <<'PY'
__version__ = "0.0.0"
def safe_load(*_a, **_k):
    raise RuntimeError("ambient parser reached")
PY
printf 'import yaml, sys\nsys.stdout.write(yaml.__version__)\n' > "$TMP_ROOT/hostile/prog.py"
HOSTILE_OUT="$(PYTHONPATH="$TMP_ROOT/hostile" PYTHONSTARTUP="$TMP_ROOT/hostile/sitecustomize.py" \
  PYTHONHOME="" yaml_runtime_run < "$TMP_ROOT/hostile/prog.py" 2>"$TMP_ROOT/hostile.err")"
if [ "$HOSTILE_OUT" = "6.0.3" ] && [ ! -f "$TMP_ROOT/hostile/marker" ]; then
  pass "2.s hostile PYTHONPATH/startup/user-site cannot reach the runtime"
else
  fail "2.s ambient influence was observable: out=$HOSTILE_OUT marker=$( [ -f "$TMP_ROOT/hostile/marker" ] && echo present || echo absent)"
fi

# ══════════════════════════════════════════════════════════════════════════
# 3. Descriptor fault matrix
# ══════════════════════════════════════════════════════════════════════════
echo "3. descriptor faults"

fault_case() {
  # fault_case <label> <expected-exit> <expected-code> <mutate-fn>
  local label="$1" want="$2" code="$3" mutate="$4"
  local root="$TMP_ROOT/f$(printf '%s' "$label" | tr -cd '0-9a-zA-Z')"
  local helper
  helper="$(make_private_core "$root")" || return 1
  "$mutate" "$root" "$helper" || { fail "$label — fault injection failed"; return 1; }
  _call "$helper" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/fault.err"
  local rc=$?
  expect_code "$label" "$want" "$TMP_ROOT/fault.err" "$rc" "$code"
  assert_path_free "$label (path-free diagnostic)" "$TMP_ROOT/fault.err"
}

m_archive_absent() { rm -f "$1/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"; }
m_archive_corrupt() {
  local a="$1/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
  printf 'X' | dd of="$a" bs=1 seek=64 conv=notrunc 2>/dev/null
}
m_archive_swapped() {
  local a="$1/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
  head -c "$(wc -c < "$a")" /dev/zero > "$a.new" && mv "$a.new" "$a" && chmod 0644 "$a"
}
m_archive_mode_664() { chmod 0664 "$1/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"; }
m_archive_mode_600() { chmod 0600 "$1/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"; }
m_archive_mode_755() { chmod 0755 "$1/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"; }
m_archive_symlink() {
  local d="$1/vendor/pyyaml/6.0.3"
  mv "$d/pyyaml-runtime.pyz" "$d/real.pyz" && ln -s "$d/real.pyz" "$d/pyyaml-runtime.pyz"
}
m_archive_owner() {
  sed 's/        if info.st_uid != os.geteuid():/        if info.st_uid != os.geteuid() + (1 if code == ASSET else 0):/' \
    "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}
m_manifest_owner() {
  sed 's/        if info.st_uid != os.geteuid():/        if info.st_uid != os.geteuid() + (1 if code == MANIFEST else 0):/' \
    "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}
m_manifest_absent() { rm -f "$1/vendor/pyyaml/6.0.3/PROVENANCE.json"; }
m_manifest_unknown_key() {
  local m="$1/vendor/pyyaml/6.0.3/PROVENANCE.json"
  awk 'NR==1{print; print "  \"unexpected_key\": 1,"; next} {print}' "$m" \
    > "$m.tmp" && mv "$m.tmp" "$m" && chmod 0644 "$m"
}
m_manifest_size_disagree() {
  local m="$1/vendor/pyyaml/6.0.3/PROVENANCE.json"
  sed 's/"size_bytes": \([0-9]*\)/"size_bytes": 1/' "$m" > "$m.tmp" && mv "$m.tmp" "$m" && chmod 0644 "$m"
}
m_manifest_symlink() {
  local d="$1/vendor/pyyaml/6.0.3"
  mv "$d/PROVENANCE.json" "$d/real.json" && ln -s "$d/real.json" "$d/PROVENANCE.json"
}
m_manifest_mode_664() { chmod 0664 "$1/vendor/pyyaml/6.0.3/PROVENANCE.json"; }
m_manifest_mode_755() { chmod 0755 "$1/vendor/pyyaml/6.0.3/PROVENANCE.json"; }
m_manifest_oversize() {
  local m="$1/vendor/pyyaml/6.0.3/PROVENANCE.json"
  head -c $((1100 * 1000)) /dev/zero | tr '\0' ' ' >> "$m" && chmod 0644 "$m"
}
m_licence_absent() { rm -f "$1/vendor/pyyaml/6.0.3/LICENSE"; }
m_licence_truncated() {
  local l="$1/vendor/pyyaml/6.0.3/LICENSE"
  head -c 8 "$l" > "$l.tmp" && mv "$l.tmp" "$l" && chmod 0644 "$l"
}
m_licence_mode_755() { chmod 0755 "$1/vendor/pyyaml/6.0.3/LICENSE"; }
# The read loop is shared by the manifest and the archive, so both truncating
# faults are scoped to the archive by the code the caller already passes in.
m_short_read() {
  sed 's/            chunk = os.read(fd, 1 << 20)/            chunk = os.read(fd, 16)[:8] if code == ASSET else os.read(fd, 1 << 20)/' \
    "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}
m_zero_read() {
  sed 's/            chunk = os.read(fd, 1 << 20)/            chunk = b"" if code == ASSET else os.read(fd, 1 << 20)/' \
    "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}
m_replace_before_open() {
  local d="$1/vendor/pyyaml/6.0.3"
  head -c "$(wc -c < "$d/pyyaml-runtime.pyz")" /dev/zero > "$d/other.pyz"
  mv "$d/other.pyz" "$d/pyyaml-runtime.pyz"
  chmod 0644 "$d/pyyaml-runtime.pyz"
}

fault_case "3.a archive absent"                   30 yaml_runtime_missing            m_archive_absent
fault_case "3.b archive corrupt"                  33 yaml_runtime_asset_invalid      m_archive_corrupt
fault_case "3.c archive swapped"                  33 yaml_runtime_asset_invalid      m_archive_swapped
fault_case "3.d archive mode 0664"                33 yaml_runtime_asset_invalid      m_archive_mode_664
fault_case "3.e archive mode 0600"                33 yaml_runtime_asset_invalid      m_archive_mode_600
fault_case "3.f archive mode 0755"                33 yaml_runtime_asset_invalid      m_archive_mode_755
fault_case "3.g archive is a symlink"             33 yaml_runtime_asset_invalid      m_archive_symlink
fault_case "3.h archive owned by another uid"     33 yaml_runtime_asset_invalid      m_archive_owner
fault_case "3.i manifest absent"                  30 yaml_runtime_missing            m_manifest_absent
fault_case "3.j manifest unknown key"             32 yaml_runtime_manifest_invalid   m_manifest_unknown_key
fault_case "3.k manifest size disagreement"       32 yaml_runtime_manifest_invalid   m_manifest_size_disagree
fault_case "3.l manifest is a symlink"            32 yaml_runtime_manifest_invalid   m_manifest_symlink
fault_case "3.m manifest mode 0664"               32 yaml_runtime_manifest_invalid   m_manifest_mode_664
fault_case "3.n manifest mode 0755"               32 yaml_runtime_manifest_invalid   m_manifest_mode_755
fault_case "3.o manifest owned by another uid"    32 yaml_runtime_manifest_invalid   m_manifest_owner
fault_case "3.p manifest beyond the size bound"   32 yaml_runtime_manifest_invalid   m_manifest_oversize
fault_case "3.q licence absent"                   33 yaml_runtime_asset_invalid      m_licence_absent
fault_case "3.r licence truncated"                33 yaml_runtime_asset_invalid      m_licence_truncated
fault_case "3.s licence mode 0755"                33 yaml_runtime_asset_invalid      m_licence_mode_755
fault_case "3.t short read"                       33 yaml_runtime_asset_invalid      m_short_read
fault_case "3.u zero-byte read"                   33 yaml_runtime_asset_invalid      m_zero_read
fault_case "3.v replacement before open"          33 yaml_runtime_asset_invalid      m_replace_before_open

# 3.w a synthetic archive with a duplicate member name, internally consistent
# with a rewritten manifest, is still refused by the declared-member census.
DUP_ROOT="$TMP_ROOT/dup"
DUP_HELPER="$(make_private_core "$DUP_ROOT")" || true
if [ -n "${DUP_HELPER:-}" ]; then
  cat > "$TMP_ROOT/mkdup.py" <<'PY'
import hashlib, json, os, sys, zipfile

vendor = sys.argv[1]
archive = os.path.join(vendor, "pyyaml-runtime.pyz")
manifest_path = os.path.join(vendor, "PROVENANCE.json")
manifest = json.loads(open(manifest_path, "rb").read().decode("utf-8"))
payload = b"# duplicate\n"
with zipfile.ZipFile(archive, "a", compression=zipfile.ZIP_STORED) as zf:
    info = zipfile.ZipInfo("yaml/__init__.py", date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = 0o644 << 16
    info.compress_type = zipfile.ZIP_STORED
    zf.writestr(info, payload)
data = open(archive, "rb").read()
manifest["output"]["size_bytes"] = len(data)
manifest["output"]["sha256"] = hashlib.sha256(data).hexdigest()
open(manifest_path, "w").write(
    json.dumps(manifest, sort_keys=True, indent=2, separators=(",", ": "),
               ensure_ascii=True) + "\n")
os.chmod(archive, 0o644)
os.chmod(manifest_path, 0o644)
PY
  yaml_runtime_run "$DUP_ROOT/vendor/pyyaml/6.0.3" < "$TMP_ROOT/mkdup.py" >/dev/null 2>&1
  _call "$DUP_HELPER" yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/dup.err"
  DUP_RC=$?
  expect_code "3.w a duplicate/undeclared archive member is refused" \
    33 "$TMP_ROOT/dup.err" "$DUP_RC" yaml_runtime_asset_invalid
fi

# 3.x replacement AFTER the digest and BEFORE the import cannot change the
# executed bytes: the import runs from the retained descriptor.
POST_ROOT="$TMP_ROOT/postdigest"
POST_HELPER="$(make_private_core "$POST_ROOT")" || true
if [ -n "${POST_HELPER:-}" ]; then
  awk -v repl="$POST_ROOT/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" '
    /^archive_fd = verify_archive\(archive_path, manifest\)$/ {
      print
      print "replacement = " "\"" repl ".replacement\""
      print "open(replacement, \"wb\").write(b\"swapped\")"
      print "os.chmod(replacement, 0o644)"
      print "os.replace(replacement, " "\"" repl "\"" ")"
      next
    }
    { print }
  ' "$POST_HELPER" > "$POST_HELPER.tmp" && mv "$POST_HELPER.tmp" "$POST_HELPER"
  printf 'import yaml, sys\nsys.stdout.write(yaml.__version__)\n' > "$TMP_ROOT/ver.py"
  POST_OUT="$(_call "$POST_HELPER" yaml_runtime_run < "$TMP_ROOT/ver.py" 2>"$TMP_ROOT/post.err")"
  if [ "$POST_OUT" = "6.0.3" ]; then
    pass "3.x replacement after digest and before import cannot change the executed bytes"
  else
    fail "3.x retained-descriptor import did not hold: out=$POST_OUT err=$(cat "$TMP_ROOT/post.err")"
  fi
fi

# 3.y replacement AFTER import, driven by a caller program against the
# production boundary: parsing still succeeds from the retained descriptor.
POST2_ROOT="$TMP_ROOT/postimport"
POST2_HELPER="$(make_private_core "$POST2_ROOT")" || true
if [ -n "${POST2_HELPER:-}" ]; then
  cat > "$TMP_ROOT/postimport.py" <<'PY'
import os, sys, yaml
target = sys.argv[1]
os.replace(sys.argv[2], target)
sys.stdout.write(str(yaml.safe_load("a: 1")))
PY
  head -c 32 /dev/zero > "$POST2_ROOT/decoy"
  POST2_OUT="$(_call "$POST2_HELPER" yaml_runtime_run \
    "$POST2_ROOT/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz" "$POST2_ROOT/decoy" \
    < "$TMP_ROOT/postimport.py" 2>"$TMP_ROOT/post2.err")"
  if [ "$POST2_OUT" = "{'a': 1}" ]; then
    pass "3.y replacement after import leaves the attested parser in place"
  else
    fail "3.y post-import replacement changed behaviour: out=$POST2_OUT"
  fi
fi

# 3.z a caller's own data file replaced after the caller opens it is rejected by
# the caller's descriptor/blob binding — the boundary shape row 21 relies on.
cat > "$TMP_ROOT/postopen.py" <<'PY'
import os, stat, sys, yaml

path, replacement = sys.argv[1:3]
real_open = os.open
def hooked(*args, **kwargs):
    fd = real_open(*args, **kwargs)
    if args and args[0] == path:
        os.replace(replacement, path)
    return fd
os.open = hooked

before = os.lstat(path)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    opened = os.fstat(fd)
    data = os.read(fd, 1 << 20)
finally:
    os.close(fd)
after = os.lstat(path)
if (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino):
    raise SystemExit(1)
sys.stdout.write(str(yaml.safe_load(data.decode("utf-8"))))
PY
printf 'a: 1\n' > "$TMP_ROOT/snapshot.yaml"
printf 'a: 2\n' > "$TMP_ROOT/replacement.yaml"
POSTOPEN_OUT="$(yaml_runtime_run "$TMP_ROOT/snapshot.yaml" "$TMP_ROOT/replacement.yaml" \
  < "$TMP_ROOT/postopen.py" 2>"$TMP_ROOT/postopen.err")"
POSTOPEN_RC=$?
if [ "$POSTOPEN_RC" -ne 0 ] && [ -z "$POSTOPEN_OUT" ] && [ ! -s "$TMP_ROOT/postopen.err" ]; then
  pass "3.z a post-open data replacement is rejected with zero stdout and zero stderr leak"
else
  fail "3.z post-open replacement was not rejected cleanly: rc=$POSTOPEN_RC out=$POSTOPEN_OUT"
fi

# ══════════════════════════════════════════════════════════════════════════
# 4. Restrictive-umask normalization (the mode repair) and its narrowness
# ══════════════════════════════════════════════════════════════════════════
echo "4. restrictive-umask normalization"

make_umask_worktree() {
  # make_umask_worktree <dst> — a private repository whose worktree is created
  # under umask 077, so the three vendor files land at 0600 by construction.
  local dst="$1"
  local src="$dst/src" wt="$dst/wt"
  mkdir -p "$src/.gaai/core/scripts/lib" "$src/.gaai/core/vendor/pyyaml/6.0.3"
  cp "$LIB_PATH" "$src/.gaai/core/scripts/lib/yaml-runtime.sh"
  cp "$VENDOR_DIR/pyyaml-runtime.pyz" "$VENDOR_DIR/PROVENANCE.json" \
     "$VENDOR_DIR/LICENSE" "$src/.gaai/core/vendor/pyyaml/6.0.3/"
  chmod 0644 "$src/.gaai/core/vendor/pyyaml/6.0.3/"* "$src/.gaai/core/scripts/lib/yaml-runtime.sh"
  git -C "$src" init -q 2>/dev/null
  git -C "$src" config user.email test@example.invalid
  git -C "$src" config user.name yaml-runtime-test
  git -C "$src" add -A >/dev/null 2>&1
  git -C "$src" commit -qm base >/dev/null 2>&1
  ( umask 077; git -C "$src" worktree add "$wt" -b umask-lane >/dev/null 2>&1 )
  printf '%s\n' "$wt"
}

UMASK_WT="$(make_umask_worktree "$TMP_ROOT/umask1")"
if [ -d "$UMASK_WT" ]; then
  PRE_MODE="$(_mode_of "$UMASK_WT/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz")"
  if [ "$PRE_MODE" = "600" ]; then
    pass "4.a a worktree created under umask 077 materializes the vendor tuple at 0600"
  else
    fail "4.a expected 0600 before normalization, observed $PRE_MODE"
  fi

  # The tuple the ordinary boundary refuses is exactly the tuple the normalizer
  # must repair. Prove the refusal first, so a normalizer routed through the
  # bootstrap could not pass this pair.
  _call "$UMASK_WT/.gaai/core/scripts/lib/yaml-runtime.sh" yaml_runtime_verify_tuple \
    >/dev/null 2>"$TMP_ROOT/umask-pre.err"
  UMASK_PRE_RC=$?
  if [ "$UMASK_PRE_RC" -eq 32 ] || [ "$UMASK_PRE_RC" -eq 33 ]; then
    pass "4.b the bootstrap genuinely refuses the 0600 tuple (exit $UMASK_PRE_RC)"
  else
    fail "4.b the bootstrap did not refuse the 0600 tuple: rc=$UMASK_PRE_RC"
  fi

  yaml_runtime_normalize_vendor_modes "$UMASK_WT" 2>"$TMP_ROOT/norm.err"
  NORM_RC=$?
  if [ "$NORM_RC" -eq 0 ] && grep -qx '\[yaml-runtime\] role=normalize action=vendor_modes code=ok' "$TMP_ROOT/norm.err"; then
    pass "4.c normalization succeeds and emits exactly the success status at exit 0"
  else
    fail "4.c normalization did not report success: rc=$NORM_RC err=$(cat "$TMP_ROOT/norm.err")"
  fi
  if [ "$(grep -c 'code=ok' "$TMP_ROOT/norm.err")" -eq 1 ]; then
    pass "4.d exactly one success status is emitted"
  else
    fail "4.d the success status was emitted more than once"
  fi
  if grep '^\[yaml-runtime\]' "$TMP_ROOT/norm.err" | grep -q '/'; then
    fail "4.e the success status leaked a path"
  else
    pass "4.e the success status is path-free and content-free"
  fi

  NORM_OK=1
  for f in pyyaml-runtime.pyz PROVENANCE.json LICENSE; do
    if [ "$(_mode_of "$UMASK_WT/.gaai/core/vendor/pyyaml/6.0.3/$f")" != "644" ]; then
      NORM_OK=0
    fi
  done
  if [ "$NORM_OK" -eq 1 ]; then
    pass "4.f all three vendor files are at exact 0644 after normalization"
  else
    fail "4.f normalization did not reach exact 0644 on every vendor file"
  fi
  if [ "$(_mode_of "$UMASK_WT/.gaai/core/scripts/lib/yaml-runtime.sh")" = "600" ]; then
    pass "4.g the boundary library's own mode is untouched (nothing reads it)"
  else
    fail "4.g normalization altered a file outside the three vendor paths"
  fi

  _call "$UMASK_WT/.gaai/core/scripts/lib/yaml-runtime.sh" yaml_runtime_verify_tuple \
    >/dev/null 2>"$TMP_ROOT/umask-post.err"
  if [ $? -eq 0 ]; then
    pass "4.h the tuple verifies after normalization and a real consumer can run"
  else
    fail "4.h the tuple still did not verify after normalization"
  fi

  yaml_runtime_verify_worktree_tuple "$UMASK_WT" 2>"$TMP_ROOT/wtverify.err"
  if [ $? -eq 0 ] && [ "${YAML_RUNTIME_TUPLE_STATE:-}" = "verified" ]; then
    pass "4.i the worktree-local exact blob/mode verification passes on the normalized state"
  else
    fail "4.i worktree-local verification failed after normalization"
  fi

  # Idempotence: a second run on an already-0644 tuple is a no-op that still
  # re-proves type, owner, identity and exact mode.
  yaml_runtime_normalize_vendor_modes "$UMASK_WT" 2>"$TMP_ROOT/norm2.err"
  if [ $? -eq 0 ] && grep -q 'code=ok' "$TMP_ROOT/norm2.err"; then
    pass "4.j normalization is idempotent on an already-correct tuple"
  else
    fail "4.j idempotent normalization failed"
  fi
fi

# 4.k normalization never trusts, parses or repairs the manifest's content.
INCONSISTENT="$(make_umask_worktree "$TMP_ROOT/umask-inconsistent")"
if [ -d "$INCONSISTENT" ]; then
  sed 's/"sha256": "[0-9a-f]*"/"sha256": "0000000000000000000000000000000000000000000000000000000000000000"/' \
    "$INCONSISTENT/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json" > "$TMP_ROOT/incons.json"
  cp "$TMP_ROOT/incons.json" "$INCONSISTENT/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json"
  chmod 0600 "$INCONSISTENT/.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json"
  yaml_runtime_normalize_vendor_modes "$INCONSISTENT" 2>"$TMP_ROOT/incons.err"
  INCONS_RC=$?
  _call "$INCONSISTENT/.gaai/core/scripts/lib/yaml-runtime.sh" yaml_runtime_verify_tuple \
    >/dev/null 2>"$TMP_ROOT/incons-verify.err"
  INCONS_VERIFY_RC=$?
  if [ "$INCONS_RC" -eq 0 ] && grep -q 'code=ok' "$TMP_ROOT/incons.err" \
     && [ "$INCONS_VERIFY_RC" -ne 0 ]; then
    pass "4.k normalization repairs modes without a parsable manifest, and cannot mask a content tamper"
  else
    fail "4.k inconsistent-manifest behaviour was wrong: norm=$INCONS_RC verify=$INCONS_VERIFY_RC"
  fi
fi

# 4.l/4.m/4.n/4.o refusals — the normalizer only repairs mode, never content.
SWAPPED="$(make_umask_worktree "$TMP_ROOT/umask-swapped")"
if [ -d "$SWAPPED" ]; then
  head -c 128 /dev/zero > "$SWAPPED/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
  yaml_runtime_normalize_vendor_modes "$SWAPPED" 2>"$TMP_ROOT/swap.err"
  yaml_runtime_verify_worktree_tuple "$SWAPPED" 2>>"$TMP_ROOT/swap.err"
  SWAP_RC=$?
  expect_code "4.l a swapped archive is refused by the verification that follows normalization" \
    33 "$TMP_ROOT/swap.err" "$SWAP_RC" yaml_runtime_asset_invalid
fi

SYMLINKED="$(make_umask_worktree "$TMP_ROOT/umask-symlink")"
if [ -d "$SYMLINKED" ]; then
  OUTSIDE="$TMP_ROOT/outside-target"
  cp "$VENDOR_DIR/pyyaml-runtime.pyz" "$OUTSIDE"
  chmod 0600 "$OUTSIDE"
  rm -f "$SYMLINKED/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
  ln -s "$OUTSIDE" "$SYMLINKED/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
  yaml_runtime_normalize_vendor_modes "$SYMLINKED" 2>"$TMP_ROOT/symlink.err"
  SYM_RC=$?
  expect_code "4.m a symlinked vendor path is refused at the no-follow relative open" \
    33 "$TMP_ROOT/symlink.err" "$SYM_RC" yaml_runtime_asset_invalid
  if [ "$(_mode_of "$OUTSIDE")" = "600" ]; then
    pass "4.n the symlink target's mode is unchanged — nothing outside the vendor directory is touched"
  else
    fail "4.n the symlink target's mode changed"
  fi
fi

OWNER_WT="$(make_umask_worktree "$TMP_ROOT/umask-owner")"
if [ -d "$OWNER_WT" ]; then
  sed 's/                if before.st_uid != os.geteuid():/                if before.st_uid != os.geteuid() + 1:/' \
    "$OWNER_WT/.gaai/core/scripts/lib/yaml-runtime.sh" > "$TMP_ROOT/owner-helper.sh"
  cp "$TMP_ROOT/owner-helper.sh" "$OWNER_WT/.gaai/core/scripts/lib/yaml-runtime.sh"
  _call "$OWNER_WT/.gaai/core/scripts/lib/yaml-runtime.sh" \
    yaml_runtime_normalize_vendor_modes "$OWNER_WT" 2>"$TMP_ROOT/owner.err"
  OWNER_RC=$?
  expect_code "4.o a wrong-owner vendor file is refused before any mode change" \
    33 "$TMP_ROOT/owner.err" "$OWNER_RC" yaml_runtime_asset_invalid
  if [ "$(_mode_of "$OWNER_WT/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz")" = "600" ]; then
    pass "4.p no mode change was attempted on the refused tuple"
  else
    fail "4.p a mode change was applied despite the owner refusal"
  fi
fi

# A failing descriptor mode change. `fchmod` needs ownership of the file, not
# write permission on its directory, so a read-only parent does NOT produce this
# fault — it is injected into a private copy of the helper instead, which is the
# only way to reach it deterministically without root.
FCHMOD_WT="$(make_umask_worktree "$TMP_ROOT/umask-fchmod")"
if [ -d "$FCHMOD_WT" ]; then
  awk '{ if ($0 ~ /^                    os\.fchmod\(fd, EXACT_FILE_MODE\)$/) print "                    raise OSError(13, \"forced\")"; else print }' \
    "$FCHMOD_WT/.gaai/core/scripts/lib/yaml-runtime.sh" > "$TMP_ROOT/fchmod-helper.sh"
  if grep -q 'raise OSError(13, "forced")' "$TMP_ROOT/fchmod-helper.sh"; then
    cp "$TMP_ROOT/fchmod-helper.sh" "$FCHMOD_WT/.gaai/core/scripts/lib/yaml-runtime.sh"
    _call "$FCHMOD_WT/.gaai/core/scripts/lib/yaml-runtime.sh" \
      yaml_runtime_normalize_vendor_modes "$FCHMOD_WT" 2>"$TMP_ROOT/fchmod.err"
    FCHMOD_RC=$?
    expect_code "4.q a failing descriptor mode change is a typed refusal, never a silent continue" \
      33 "$TMP_ROOT/fchmod.err" "$FCHMOD_RC" yaml_runtime_asset_invalid
    if [ "$(_mode_of "$FCHMOD_WT/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz")" = "600" ]; then
      pass "4.r the tuple is left unrepaired, so no consumer can run against a half-repaired state"
    else
      fail "4.r a refused normalization still changed a mode"
    fi
  else
    fail "4.q the descriptor mode-change fault could not be injected into the private helper copy"
  fi
fi

# 4.s the normalization program is structurally what it claims to be.
NORM_BLOCK="$(awk '/^read -r -d .. _YR_NORMALIZE/,/^PYEOF$/' "$LIB_PATH")"
NORM_PROBLEMS=""
printf '%s\n' "$NORM_BLOCK" | grep -qE '(^|[^_a-zA-Z])import yaml|from yaml' && NORM_PROBLEMS="$NORM_PROBLEMS import"
printf '%s\n' "$NORM_BLOCK" | grep -q '/dev/fd' && NORM_PROBLEMS="$NORM_PROBLEMS devfd"
printf '%s\n' "$NORM_BLOCK" | grep -q '/proc/self/fd' && NORM_PROBLEMS="$NORM_PROBLEMS procfd"
printf '%s\n' "$NORM_BLOCK" | grep -qE 'os\.chmod\(|os\.lstat\(' && NORM_PROBLEMS="$NORM_PROBLEMS pathmode"
printf '%s\n' "$NORM_BLOCK" | grep -q 'sys.path.insert' && NORM_PROBLEMS="$NORM_PROBLEMS syspath"
if [ -z "$NORM_PROBLEMS" ]; then
  pass "4.s the normalization program imports no parser, inserts no descriptor path and uses no path-based mode call"
else
  fail "4.s normalization-program purity violated:$NORM_PROBLEMS"
fi
if [ "$(grep -c -- '-c "\$_YR_NORMALIZE"' "$LIB_PATH")" -eq 1 ]; then
  pass "4.t the normalization entry executes the selected interpreter exactly once"
else
  fail "4.t the normalization entry does not have exactly one interpreter invocation"
fi
if grep -vE '^[[:space:]]*#' "$LIB_PATH" | grep -q 'python3'; then
  fail "4.u the boundary spells an ambient interpreter name"
else
  pass "4.u the boundary never spells an ambient interpreter name"
fi

# 4.v no ordinary boundary entry emits a success status.
yaml_runtime_verify_tuple >/dev/null 2>"$TMP_ROOT/ok-check.err"
yaml_runtime_validate_file "$TMP_ROOT/snapshot.yaml" >/dev/null 2>>"$TMP_ROOT/ok-check.err"
if grep -q 'code=ok' "$TMP_ROOT/ok-check.err"; then
  fail "4.v an ordinary YAML operation emitted the success status"
else
  pass "4.v ordinary YAML operations emit no success status"
fi

# ══════════════════════════════════════════════════════════════════════════
# 5. Semantic and identity corpus
# ══════════════════════════════════════════════════════════════════════════
echo "5. semantic corpus"

# The expectations below are the pinned contract of the vendored parser version.
# They are written independently of the boundary under test — never read back out
# of it — and are the same facts the pre-edit baseline capture records.
cat > "$TMP_ROOT/corpus.py" <<'PY'
import datetime
import math
import sys
import yaml

out = []


def emit(name, value):
    out.append("%s=%s" % (name, value))


def raises(fn):
    try:
        fn()
    except Exception as exc:
        return type(exc).__name__
    return "no-error"


# safe construction
emit("construct", yaml.safe_load("a: 1\nb:\n  - 1\n  - 2\n"))

# duplicate keys at document, item and nested level (safe_load: last wins)
emit("dup_doc", yaml.safe_load("a: 1\na: 2\n"))
emit("dup_item", yaml.safe_load("items:\n- id: x\n  id: y\n")["items"][0])
emit("dup_nested", yaml.safe_load("outer:\n  k: 1\n  k: 2\n")["outer"])


# the strict loader the classifier and dispatcher use
class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
emit("dup_strict", raises(lambda: yaml.load("a: 1\na: 2\n", Loader=UniqueLoader)))
emit("dup_strict_nested",
     raises(lambda: yaml.load("o:\n  k: 1\n  k: 2\n", Loader=UniqueLoader)))

# non-scalar keys
emit("seq_key", raises(lambda: yaml.safe_load("? [1, 2]\n: v\n")))
emit("map_key", raises(lambda: yaml.safe_load("? {a: 1}\n: v\n")))

# YAML 1.1 implicit scalars
for token in ("yes", "no", "on", "off", "y", "n", "012", "1_000", "12:30"):
    emit("scalar_%s" % token.replace(":", "_"), repr(yaml.safe_load("v: %s" % token)["v"]))
inf_value = yaml.safe_load("v: .inf")["v"]
nan_value = yaml.safe_load("v: .nan")["v"]
emit("scalar_inf", math.isinf(inf_value) and inf_value > 0)
emit("scalar_nan", math.isnan(nan_value))
date_value = yaml.safe_load("v: 1997-07-16")["v"]
emit("scalar_date", isinstance(date_value, datetime.date) and str(date_value))

# tags
emit("tag_str", repr(yaml.safe_load("v: !!str 123")["v"]))
emit("tag_unknown", raises(lambda: yaml.safe_load("v: !Foo bar")))

# anchors, aliases, merge keys
emit("anchor", yaml.safe_load("base: &b\n  a: 1\nchild:\n  <<: *b\n  b: 2\n")["child"])

# unicode and source marks
node = yaml.compose("a: 1\nb: 2\n")
value_node = node.value[1][1]
emit("mark_line", value_node.start_mark.line)
emit("mark_column", value_node.start_mark.column)
uni = yaml.compose("\u00e9: 1\n")
emit("mark_unicode_column", uni.value[0][1].start_mark.column)
emit("unicode_value", yaml.safe_load("k: caf\u00e9")["k"])

# flow versus block
emit("flow_block_equal",
     yaml.safe_load("a: [1, 2]") == yaml.safe_load("a:\n  - 1\n  - 2\n"))

# scan token trail shape
tokens = [type(t).__name__ for t in yaml.scan("a: 1\n")]
emit("scan_trail", ",".join(tokens))

# malformed input
emit("bad_tab", raises(lambda: yaml.safe_load("a:\n\t- 1\n")))
emit("bad_escape", raises(lambda: yaml.safe_load('k: "\\$"\n')))
emit("bad_bracket", raises(lambda: yaml.safe_load("a: [1, 2\n")))

# deterministic dump bytes
emit("dump", repr(yaml.safe_dump({"b": 1, "a": 2}, sort_keys=True,
                                 allow_unicode=True, default_flow_style=False,
                                 width=4096)))
emit("dump_unicode", repr(yaml.safe_dump({"k": "caf\u00e9"}, sort_keys=True,
                                         allow_unicode=True,
                                         default_flow_style=False, width=4096)))
emit("dump_nested", repr(yaml.safe_dump({"z": {"b": [1, 2], "a": None}},
                                        sort_keys=True, allow_unicode=True,
                                        default_flow_style=False, width=4096)))

emit("version", yaml.__version__)
sys.stdout.write("\n".join(out) + "\n")
PY

CORPUS_OUT="$TMP_ROOT/corpus.out"
yaml_runtime_run < "$TMP_ROOT/corpus.py" > "$CORPUS_OUT" 2>"$TMP_ROOT/corpus.err"
CORPUS_RC=$?
if [ "$CORPUS_RC" -ne 0 ]; then
  fail "5.a the semantic corpus could not run: $(cat "$TMP_ROOT/corpus.err")"
else
  pass "5.a the semantic corpus executed through the boundary"
fi

cat > "$TMP_ROOT/corpus.expected" <<'EXPECTED'
construct={'a': 1, 'b': [1, 2]}
dup_doc={'a': 2}
dup_item={'id': 'y'}
dup_nested={'k': 2}
dup_strict=ValueError
dup_strict_nested=ValueError
seq_key=ConstructorError
map_key=ConstructorError
scalar_yes=True
scalar_no=False
scalar_on=True
scalar_off=False
scalar_y='y'
scalar_n='n'
scalar_012=10
scalar_1_000=1000
scalar_12_30=750
scalar_inf=True
scalar_nan=True
scalar_date=1997-07-16
tag_str='123'
tag_unknown=ConstructorError
anchor={'a': 1, 'b': 2}
mark_line=1
mark_column=3
mark_unicode_column=3
unicode_value=café
flow_block_equal=True
scan_trail=StreamStartToken,BlockMappingStartToken,KeyToken,ScalarToken,ValueToken,ScalarToken,BlockEndToken,StreamEndToken
bad_tab=ScannerError
bad_escape=ScannerError
bad_bracket=ParserError
dump='a: 2\nb: 1\n'
dump_unicode='k: café\n'
dump_nested='z:\n  a: null\n  b:\n  - 1\n  - 2\n'
version=6.0.3
EXPECTED

if diff -u "$TMP_ROOT/corpus.expected" "$CORPUS_OUT" > "$TMP_ROOT/corpus.diff" 2>&1; then
  pass "5.b every corpus expectation matches the pinned parser contract"
else
  fail "5.b corpus divergence:"
  sed 's/^/      /' "$TMP_ROOT/corpus.diff"
fi

# 5.c unrelated bytes and comments survive a read that does not rewrite the file
cat > "$TMP_ROOT/comments.yaml" <<'YAML'
# leading comment
items:
- id: A   # trailing comment
  status: refined

# trailing block
YAML
BEFORE_DIGEST="$(git hash-object "$TMP_ROOT/comments.yaml" 2>/dev/null || cksum < "$TMP_ROOT/comments.yaml")"
yaml_runtime_validate_file "$TMP_ROOT/comments.yaml" >/dev/null 2>&1
VALIDATE_RC=$?
AFTER_DIGEST="$(git hash-object "$TMP_ROOT/comments.yaml" 2>/dev/null || cksum < "$TMP_ROOT/comments.yaml")"
if [ "$VALIDATE_RC" -eq 0 ] && [ "$BEFORE_DIGEST" = "$AFTER_DIGEST" ]; then
  pass "5.c validation preserves comments and every unrelated byte"
else
  fail "5.c validation altered the document or refused a valid one"
fi

# 5.d a malformed document is a semantic mismatch, not a runtime fault
printf 'k: "\\$"\n' > "$TMP_ROOT/bad.yaml"
yaml_runtime_validate_file "$TMP_ROOT/bad.yaml" >/dev/null 2>"$TMP_ROOT/bad.err"
BAD_RC=$?
expect_code "5.d a malformed document is a typed semantic mismatch" \
  36 "$TMP_ROOT/bad.err" "$BAD_RC" yaml_runtime_semantic_mismatch
assert_path_free "5.e the semantic diagnostic leaks no parser text or path" "$TMP_ROOT/bad.err"

# 5.f-5.k duplicate mapping keys are refused, and ONLY those.
#
# safe_load resolves a repeated key silently under last-key-wins, so validation
# built on it accepts documents that every duplicate-rejecting consumer refuses
# outright -- and those consumers refuse the whole document, for every entry in
# it. The paired cases below falsify in both directions: a duplicate must be
# refused (5.f, 5.h, 5.j), and the constructs that merely LOOK like duplicates
# must still be accepted (5.i, 5.k), so the check cannot be passed by a loader
# that simply rejects more.

printf 'key: first\nkey: second\nother: x\n' > "$TMP_ROOT/dup-doc.yaml"
yaml_runtime_validate_file "$TMP_ROOT/dup-doc.yaml" >/dev/null 2>"$TMP_ROOT/dup-doc.err"
DUP_DOC_RC=$?
expect_code "5.f a repeated document-level key is a typed semantic mismatch" \
  36 "$TMP_ROOT/dup-doc.err" "$DUP_DOC_RC" yaml_runtime_semantic_mismatch

if grep -q 'key' "$TMP_ROOT/dup-doc.err" 2>/dev/null; then
  fail "5.g the refusal echoed the offending key name (document content leak)"
else
  pass "5.g the refusal names no key: the diagnostic stays content-free"
fi

# The exact shape that was live on staging: a repeated key inside a list item.
printf 'items:\n- id: A\n  started_at: "1"\n  note: x\n  started_at: "2"\n' \
  > "$TMP_ROOT/dup-item.yaml"
yaml_runtime_validate_file "$TMP_ROOT/dup-item.yaml" >/dev/null 2>"$TMP_ROOT/dup-item.err"
DUP_ITEM_RC=$?
expect_code "5.h a repeated key nested in a list item is refused too" \
  36 "$TMP_ROOT/dup-item.err" "$DUP_ITEM_RC" yaml_runtime_semantic_mismatch

# Same document, one occurrence removed: it must now pass. Without this leg,
# 5.h would also be satisfied by a validator that refuses the shape outright.
printf 'items:\n- id: A\n  note: x\n  started_at: "2"\n' > "$TMP_ROOT/dedup-item.yaml"
if yaml_runtime_validate_file "$TMP_ROOT/dedup-item.yaml" >/dev/null 2>&1; then
  pass "5.i the same document with one occurrence removed is accepted"
else
  fail "5.i removing the duplicate did not make the document acceptable"
fi

# A merge key whose explicit member overrides an inherited one is VALID YAML.
# The check therefore reads raw key nodes before flatten_mapping expands `<<`;
# checking after the expansion would refuse this document.
printf 'base: &b\n  a: 1\n  b: 2\nmerged:\n  <<: *b\n  b: 3\n' > "$TMP_ROOT/merge.yaml"
if yaml_runtime_validate_file "$TMP_ROOT/merge.yaml" >/dev/null 2>&1; then
  pass "5.j a merge key overriding an inherited key is still accepted"
else
  fail "5.j merge-key semantics were broken by the duplicate-key check"
fi

# A repeated merge key is itself a duplicate: YAML allows only one per mapping.
printf 'base: &b\n  a: 1\nother: &o\n  c: 2\nm:\n  <<: *b\n  <<: *o\n' \
  > "$TMP_ROOT/dup-merge.yaml"
yaml_runtime_validate_file "$TMP_ROOT/dup-merge.yaml" >/dev/null 2>"$TMP_ROOT/dup-merge.err"
DUP_MERGE_RC=$?
expect_code "5.k a repeated merge key is refused like any other duplicate" \
  36 "$TMP_ROOT/dup-merge.err" "$DUP_MERGE_RC" yaml_runtime_semantic_mismatch

# 5.l-5.p Two keys are the same when the parser loses a row, not when the bytes
# match. `yes:` and `true:` are different source text and one resolved key, so
# safe_load silently drops an entry -- the exact failure this validation exists to
# stop -- and a consumer comparing resolved keys refuses the whole document. A
# check that compared only raw tokens would stay permissive in precisely the way
# that motivates it, so the resolved object is compared too.
_expect_dup_refusal() {   # <label> <file> <yaml-bytes>
  local label="$1" file="$2" body="$3" rc
  printf '%s' "$body" > "$TMP_ROOT/$file"
  yaml_runtime_validate_file "$TMP_ROOT/$file" >/dev/null 2>"$TMP_ROOT/$file.err"
  rc=$?
  expect_code "$label" 36 "$TMP_ROOT/$file.err" "$rc" yaml_runtime_semantic_mismatch
}

_expect_dup_refusal "5.l a bool-resolving key pair (yes/true) is refused" \
  dup-bool.yaml 'yes: 1
true: 2
'
_expect_dup_refusal "5.m an int-resolving key pair (1/01) is refused" \
  dup-int.yaml '1: a
01: b
'
_expect_dup_refusal "5.n a null-resolving key pair (~/null) is refused" \
  dup-null.yaml '~: a
null: b
'
# flatten_mapping splices a merge SOURCE's pairs into the parent without ever
# passing that source through construct_mapping, so a duplicate living inside the
# merge value is invisible to a parent-only scan.
_expect_dup_refusal "5.o a duplicate inside an inline merge source is refused" \
  dup-merge-inline.yaml 'merged:
  <<:
    a: 1
    a: 2
  z: 3
'
_expect_dup_refusal "5.p a duplicate inside a merge source list is refused" \
  dup-merge-seq.yaml 'anchor: &anchor
  q: 1
m:
  <<: [*anchor, {b: 1, b: 2}]
'

# 5.u-5.w Exiting 0 is not liveness.
#
# What these legs establish is bounded and stated exactly: an INERT native
# binary -- one that exits 0 without reading its input or producing output --
# is refused by every entry. They do NOT establish that a purpose-built native
# forger is refused: the token is handed to the process it checks, so a binary
# that reads argv/environment can echo it. That case is the explicit override's
# operator trust root by design (see the boundary header) and is not claimed.
#
# Every pre-execution check describes the FILE — absolute, regular, executable,
# native magic, owner chain. None describes what the file DOES. A stock system
# binary satisfies all of them, so an explicit interpreter override used to make
# `verify_tuple` report a verified tuple and `validate` report success on
# malformed YAML: the gates reported success with no parser ever loaded. The
# boundary now requires the bootstrap to echo a fresh per-call token that it
# emits only after the archive is verified and the runtime imported.
_ATTEST_DECOY=""
for _c in /usr/bin/true /bin/true; do
  [ -x "$_c" ] && { _ATTEST_DECOY="$_c"; break; }
done
if [ -z "$_ATTEST_DECOY" ]; then
  fail "5.u no stock native no-op binary available to attack the boundary with"
else
  ATTEST_RC=0
  ( GAAI_YAML_PYTHON="$_ATTEST_DECOY"; export GAAI_YAML_PYTHON
    yaml_runtime_verify_tuple >/dev/null 2>&1 ) || ATTEST_RC=$?
  if [ "$ATTEST_RC" -eq 31 ]; then
    pass "5.u an inert native binary (exits 0, ignores input) fails the liveness check"
  else
    fail "5.u an inert binary passed the liveness check (rc=$ATTEST_RC)"
  fi

  printf 'k: "\\$"\n' > "$TMP_ROOT/attest-bad.yaml"
  GATE_RC=0
  ( GAAI_YAML_PYTHON="$_ATTEST_DECOY"; export GAAI_YAML_PYTHON
    yaml_runtime_validate_file "$TMP_ROOT/attest-bad.yaml" >/dev/null 2>&1 ) || GATE_RC=$?
  if [ "$GATE_RC" -ne 0 ]; then
    pass "5.v validate does not report success through an inert interpreter"
  else
    fail "5.v the gate reported success on malformed YAML through a no-op interpreter"
  fi
fi

# The control: attestation must not have broken the legitimate override. Without
# this leg, 5.u/5.v would also pass against a boundary that refuses every
# explicit interpreter.
REAL_PY_FOR_ATTEST="$(env -u GAAI_YAML_PYTHON "${GAAI_TEST_BASH:-${BASH:-/bin/bash}}" -c \
  '. "$1"; _yr_select_interpreter >/dev/null 2>&1 && printf "%s" "$_YR_PY"' _ "$LIB_PATH" 2>/dev/null)"
if [ -z "$REAL_PY_FOR_ATTEST" ]; then
  fail "5.w no interpreter could be selected, so the attestation control cannot run"
else
  CTRL_RC=0
  ( GAAI_YAML_PYTHON="$REAL_PY_FOR_ATTEST"; export GAAI_YAML_PYTHON
    yaml_runtime_verify_tuple >/dev/null 2>&1 ) || CTRL_RC=$?
  if [ "$CTRL_RC" -eq 0 ]; then
    pass "5.w a real interpreter is still accepted through the explicit override"
  else
    fail "5.w attestation broke the legitimate explicit override (rc=$CTRL_RC)"
  fi
fi

# 5.x The caller-program entries carry the same liveness check, delivered on an
# inherited descriptor (fd 3) rather than through a file, so there is no path to
# race and no external command to shim. Without it an inert override returned
# rc=0 with empty output: the dependency-integrity gate then passed a dangling
# reference, and --set-field reported a write that never happened.
if [ -n "$_ATTEST_DECOY" ]; then
  RUN_RC=0; RUNC_RC=0
  ( GAAI_YAML_PYTHON="$_ATTEST_DECOY"; export GAAI_YAML_PYTHON
    printf 'import sys\nsys.stdout.write("RAN")\n' | yaml_runtime_run >/dev/null 2>&1 ) || RUN_RC=$?
  ( GAAI_YAML_PYTHON="$_ATTEST_DECOY"; export GAAI_YAML_PYTHON
    yaml_runtime_run_c 'import sys' >/dev/null 2>&1 ) || RUNC_RC=$?
  if [ "$RUN_RC" -eq 31 ] && [ "$RUNC_RC" -eq 31 ]; then
    pass "5.x run and run_c refuse an inert interpreter with the typed 31"
  else
    fail "5.x run/run_c accepted an inert interpreter (run=$RUN_RC run_c=$RUNC_RC)"
  fi
  # control: a real program through run/run_c still returns its own output
  RUN_OUT="$(printf 'import sys\nsys.stdout.write("RAN")\n' | yaml_runtime_run 2>/dev/null)"
  if [ "$RUN_OUT" = "RAN" ]; then
    pass "5.x-ctl the liveness descriptor leaves caller stdout untouched"
  else
    fail "5.x-ctl caller stdout was altered by the liveness check: [$RUN_OUT]"
  fi
fi

# 5.y F3: `absent` is a claim about the working tree, not only about HEAD. A
# tuple that is on disk but untracked (partial checkout, gitignored .gaai/, a
# planted archive) was reported absent, skipped normalization and verification,
# and was consumed anyway because both callers treat absent as "proceed".
F3_ROOT="$TMP_ROOT/f3-untracked"
mkdir -p "$F3_ROOT/.gaai/core/vendor/pyyaml/6.0.3"
git -C "$F3_ROOT" init -q >/dev/null 2>&1
git -C "$F3_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base >/dev/null 2>&1
printf 'x' > "$F3_ROOT/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
F3_RC=0; F3_STATE=""
F3_STATE="$( ( yaml_runtime_repair_and_verify_tree "$F3_ROOT" >/dev/null 2>&1; printf '%s:%s' "$?" "${YAML_RUNTIME_TUPLE_STATE:-}" ) )"
case "$F3_STATE" in
  33:*) pass "5.y an untracked tuple on disk is the typed asset refusal, never absent" ;;
  *)    fail "5.y an untracked tuple was classified [$F3_STATE] instead of 33" ;;
esac

# 5.y2-5.y4 The public sibling and the validate open path had no regression:
# each of these guards could be reverted with the suite fully green.
#
# 5.y2 git usable for HEAD but unable to list the tree (object store gone).
F3B_ROOT="$TMP_ROOT/f3-broken-objects"
mkdir -p "$F3B_ROOT"
git -C "$F3B_ROOT" init -q >/dev/null 2>&1
git -C "$F3B_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base >/dev/null 2>&1
rm -rf "$F3B_ROOT/.git/objects"/??
# Precondition, not part of the assertion: without a HEAD the earlier rev-parse
# guard returns 33 on its own and this leg would pass without reaching the
# guard it exists to test.
if git -C "$F3B_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  F3B="$( ( yaml_runtime_verify_worktree_tuple "$F3B_ROOT" >/dev/null 2>&1; printf '%s:%s' "$?" "${YAML_RUNTIME_TUPLE_STATE:-}" ) )"
  case "$F3B" in
    33:) pass "5.y2 verify_worktree_tuple: a failing git ls-tree is the typed 33, never absent" ;;
    *)   fail "5.y2 verify_worktree_tuple classified a broken git as [$F3B] instead of 33" ;;
  esac
else
  fail "5.y2 fixture: git did not produce a repository with a HEAD — the guard under test was never reached"
fi

# 5.y3 HEAD declares none of the tuple, one tuple file untracked on disk.
F3C_ROOT="$TMP_ROOT/f3-untracked-public"
mkdir -p "$F3C_ROOT/.gaai/core/vendor/pyyaml/6.0.3"
git -C "$F3C_ROOT" init -q >/dev/null 2>&1
git -C "$F3C_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base >/dev/null 2>&1
printf 'x' > "$F3C_ROOT/.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
if git -C "$F3C_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  F3C="$( ( yaml_runtime_verify_worktree_tuple "$F3C_ROOT" >/dev/null 2>&1; printf '%s:%s' "$?" "${YAML_RUNTIME_TUPLE_STATE:-}" ) )"
  case "$F3C" in
    33:) pass "5.y3 verify_worktree_tuple: an untracked tuple on disk is the typed 33, never absent" ;;
    *)   fail "5.y3 verify_worktree_tuple classified an untracked tuple as [$F3C] instead of 33" ;;
  esac
else
  fail "5.y3 fixture: git did not produce a repository with a HEAD — the guard under test was never reached"
fi

# 5.y4 an unreadable document is an asset fault (33), not a parse fault (36).
printf 'k: 1\n' > "$TMP_ROOT/unreadable.yaml"
chmod 000 "$TMP_ROOT/unreadable.yaml"
if [ -r "$TMP_ROOT/unreadable.yaml" ] && [ "$(id -u)" -eq 0 ]; then
  # Root bypasses mode bits, so the open guard cannot be reached at uid 0. That
  # is a verified property of THIS uid, not an inference from readability, and
  # it is not a skipped proof: the leg passes with the cause in its label.
  pass "5.y4 not evaluable at uid 0: root bypasses mode bits, the open guard cannot be reached"
elif [ -r "$TMP_ROOT/unreadable.yaml" ]; then
  # Readable at a non-root uid means the filesystem ignored chmod 000 (a bind
  # mount, virtiofs/9p, vfat/exfat, CAP_DAC_OVERRIDE). The guard under test was
  # never reached; a pass here would pad the floor silently.
  fail "5.y4 fixture: chmod 000 did not make the file unreadable at uid $(id -u) — the open guard under test was never reached"
else
  yaml_runtime_validate_file "$TMP_ROOT/unreadable.yaml" >/dev/null 2>"$TMP_ROOT/unreadable.err"
  UNREAD_RC=$?
  expect_code "5.y4 an unreadable document is the typed asset refusal, not invalid YAML" \
    33 "$TMP_ROOT/unreadable.err" "$UNREAD_RC" yaml_runtime_asset_invalid
fi
chmod 600 "$TMP_ROOT/unreadable.yaml" 2>/dev/null || true

# 5.z F4: a non-host as the explicit interpreter must stay inside the closed
# vocabulary and leak nothing. /bin/sh exits 2 and writes its own stderr,
# which used to pass straight through as an untyped status carrying a path.
F4_RC=0
F4_ERR="$( ( GAAI_YAML_PYTHON=/bin/sh; export GAAI_YAML_PYTHON
  yaml_runtime_validate_file "$TMP_ROOT/attest-bad.yaml" >/dev/null 2>&1 ) 2>&1 )" || F4_RC=$?
( GAAI_YAML_PYTHON=/bin/sh; export GAAI_YAML_PYTHON
  yaml_runtime_validate_file "$TMP_ROOT/attest-bad.yaml" >/dev/null 2>"$TMP_ROOT/f4.err" ) || F4_RC=$?
if [ "$F4_RC" -eq 31 ] \
   && [ "$(grep -c '^\[yaml-runtime\]' "$TMP_ROOT/f4.err")" -eq 1 ] \
   && [ "$(grep -vc '^\[yaml-runtime\]' "$TMP_ROOT/f4.err")" -eq 0 ]; then
  pass "5.z a non-host explicit interpreter yields typed 31 and exactly one bounded diagnostic"
else
  fail "5.z non-host leaked through (rc=$F4_RC): $(tr '\n' '|' < "$TMP_ROOT/f4.err" | cut -c1-120)"
fi
assert_path_free "5.z-priv the non-host diagnostic carries no path" "$TMP_ROOT/f4.err"

# 5.z2 A caller that closed its stdout must get the typed refusal and nothing
# else. The run/run_c entries dup the caller's stdout onto fd 5; with stdout
# closed that dup fails inside bash, which undoes the redirection and prints
# ITS OWN error -- carrying this library's absolute path -- before any typed
# diagnostic. The boundary now probes the dup in a subshell whose stderr the
# parent discards, and refuses with 31 first. This leg reverts silently
# otherwise: the suite never closes stdout on its own.
CLOSED_ERR="$( ( yaml_runtime_run_c 'print(1)' 1>&- ) 2>&1 )"
CLOSED_RC=0
# `1>&-` must be the LAST word on the call: a later `>/dev/null` would reopen
# stdout and the boundary would rightly succeed. Stderr is dropped one level up.
( yaml_runtime_run_c 'print(1)' 1>&- ) 2>/dev/null || CLOSED_RC=$?
if [ "$CLOSED_RC" -eq 31 ] \
   && [ "$(printf '%s\n' "$CLOSED_ERR" | grep -c '^\[yaml-runtime\]')" -eq 1 ] \
   && [ "$(printf '%s\n' "$CLOSED_ERR" | grep -vc '^\[yaml-runtime\]')" -eq 0 ]; then
  pass "5.z2 a closed caller stdout is the typed 31 with exactly one bounded diagnostic"
else
  fail "5.z2 closed stdout leaked or mis-typed (rc=$CLOSED_RC): $(printf '%s' "$CLOSED_ERR" | tr '\n' '|' | cut -c1-120)"
fi
# The leaked line, when it leaks, is BASH's own error -- not a [yaml-runtime]
# line -- so assert_path_free (which inspects only diagnostic lines) cannot see
# it. The privacy leg therefore inspects every byte of stderr: the sole allowed
# line carries no slash, so any slash anywhere is a leaked path.
if [ "$(printf '%s\n' "$CLOSED_ERR" | grep -c '/')" -eq 0 ]; then
  pass "5.z2-priv the closed-stdout stderr contains no path anywhere"
else
  fail "5.z2-priv a path reached the caller's stderr: $(printf '%s' "$CLOSED_ERR" | grep '/' | head -1 | cut -c1-100)"
fi

# 5.z3 The same leg for the pipe entry. 5.z2 covers run_c only; without this,
# the probe could be dropped from yaml_runtime_run alone -- the entry the
# backlog validator actually uses -- with the suite fully green.
CLOSED3_ERR="$( ( printf 'print(1)\n' | yaml_runtime_run 1>&- ) 2>&1 )"
CLOSED3_RC=0
( printf 'print(1)\n' | yaml_runtime_run 1>&- ) 2>/dev/null || CLOSED3_RC=$?
if [ "$CLOSED3_RC" -eq 31 ] \
   && [ "$(printf '%s\n' "$CLOSED3_ERR" | grep -c '^\[yaml-runtime\]')" -eq 1 ] \
   && [ "$(printf '%s\n' "$CLOSED3_ERR" | grep -vc '^\[yaml-runtime\]')" -eq 0 ]; then
  pass "5.z3 run: a closed caller stdout is the typed 31 with exactly one bounded diagnostic"
else
  fail "5.z3 run: closed stdout leaked or mis-typed (rc=$CLOSED3_RC): $(printf '%s' "$CLOSED3_ERR" | tr '\n' '|' | cut -c1-120)"
fi
if [ "$(printf '%s\n' "$CLOSED3_ERR" | grep -c '/')" -eq 0 ]; then
  pass "5.z3-priv run: the closed-stdout stderr contains no path anywhere"
else
  fail "5.z3-priv run: a path reached the caller's stderr: $(printf '%s' "$CLOSED3_ERR" | grep '/' | head -1 | cut -c1-100)"
fi

# 5.s-5.t The anti-false-positive legs for merge composition.
#
# `flatten_mapping` REWRITES node.value in place, prepending a merge source's
# pairs to the parent. A scan that reaches an anchored node again, after some
# other mapping merged it, therefore sees merge-DERIVED pairs and would report
# them as authored duplicates -- refusing a composition that contains no repeated
# key at all, with a diagnostic that sends the author hunting for a key that does
# not exist. 5.s is the textbook shape (`defaults` merged into two children, both
# merged into a third); 5.t is the self-referential merge, which must terminate
# rather than recurse. Both load losslessly under safe_load, so both must pass.
_expect_accepted() {   # <label> <file> <yaml-bytes>
  local label="$1" file="$2" body="$3"
  printf '%s' "$body" > "$TMP_ROOT/$file"
  if yaml_runtime_validate_file "$TMP_ROOT/$file" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label (refused a document that loses no data under safe_load)"
  fi
}

_expect_accepted "5.s a multi-level anchor/merge composition is accepted" \
  merge-composition.yaml 'defaults: &defaults
  retries: 3
dev: &dev
  <<: *defaults
  host: dev
prod: &prod
  <<: *defaults
  host: prod
both: &both
  <<: [*dev, *prod]
final:
  <<: *both
'
_expect_accepted "5.t a self-referential merge terminates and is accepted" \
  merge-self.yaml 'x: &a
  <<: *a
'

# 5.q Discovery must not be steerable through the caller's PATH.
#
# The candidate SET is a fixed list, but the boundary decides what a candidate IS
# by shelling out to realpath/readlink/dirname/basename. Resolved through the
# caller's PATH, a five-line `realpath` shim makes the boundary canonicalize a
# fixed candidate to any path the shim names and then execute THAT file as the
# attested interpreter -- which turns every gate built on this boundary from
# fail-closed into fail-open. The assertion is equality of the selected path
# under a clean and a hostile PATH: a refusal would also be acceptable, but
# silently selecting something else is not.
mkdir -p "$TMP_ROOT/hostile-bin" "$TMP_ROOT/decoy"
printf '#!/bin/sh\necho "%s/decoy/python3.14"\n' "$TMP_ROOT" > "$TMP_ROOT/hostile-bin/realpath"
cp "$TMP_ROOT/hostile-bin/realpath" "$TMP_ROOT/hostile-bin/readlink"
printf '#!/bin/sh\necho "%s/decoy"\n' "$TMP_ROOT" > "$TMP_ROOT/hostile-bin/dirname"
printf '#!/bin/sh\necho python3.14\n' > "$TMP_ROOT/hostile-bin/basename"
chmod 0755 "$TMP_ROOT/hostile-bin/"*
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/decoy/python3.14"
chmod 0755 "$TMP_ROOT/decoy/python3.14"

SELECT_PROBE="$TMP_ROOT/select-probe.sh"
printf '%s\n' \
  '#!/bin/bash' \
  'set -u' \
  '. "$1" || exit 1' \
  '_yr_select_interpreter 2>/dev/null || { printf "REFUSED\n"; exit 0; }' \
  'printf "%s\n" "$_YR_PY"' > "$SELECT_PROBE"
chmod 0755 "$SELECT_PROBE"

SELECT_BASH="${GAAI_TEST_BASH:-${BASH:-/bin/bash}}"
SELECT_CLEAN="$(env -u GAAI_YAML_PYTHON PATH="/usr/bin:/bin" \
  "$SELECT_BASH" "$SELECT_PROBE" "$LIB_PATH" 2>/dev/null)"
SELECT_HOSTILE="$(env -u GAAI_YAML_PYTHON PATH="$TMP_ROOT/hostile-bin:/usr/bin:/bin" \
  "$SELECT_BASH" "$SELECT_PROBE" "$LIB_PATH" 2>/dev/null)"

# The control comes first and is not optional. Both probes previously ran through
# an UNSET variable, so both substitutions aborted, both results were empty, and
# 5.q's comparison became [ "" = "" ] -- it passed against a boundary that was
# fully steerable. An empty clean probe is now a failure, not a silent pass.
if [ -n "$SELECT_CLEAN" ] && [ "$SELECT_CLEAN" != "REFUSED" ]; then
  pass "5.q-pre the clean-PATH control actually selected an interpreter"
else
  fail "5.q-pre the clean-PATH control produced no selection: [$SELECT_CLEAN]"
fi

if [ -z "$SELECT_CLEAN" ]; then
  fail "5.q cannot be evaluated: the control probe produced nothing"
elif [ "$SELECT_HOSTILE" = "$SELECT_CLEAN" ] || [ "$SELECT_HOSTILE" = "REFUSED" ]; then
  pass "5.q a PATH shim cannot steer interpreter discovery"
else
  fail "5.q PATH shim steered discovery: clean=$SELECT_CLEAN hostile=$SELECT_HOSTILE"
fi
if [ -z "$SELECT_CLEAN" ] || [ "$SELECT_HOSTILE" = "$TMP_ROOT/decoy/python3.14" ]; then
  fail "5.r the boundary selected the shim's decoy as the attested interpreter"
else
  pass "5.r the shim's decoy is never selected as the attested interpreter"
fi

# ══════════════════════════════════════════════════════════════════════════
# 6. Invocation contract: argv, stdin, exit codes, privacy
# ══════════════════════════════════════════════════════════════════════════
echo "6. invocation contract"

printf 'import sys\nsys.stdout.write("|".join(sys.argv))\n' > "$TMP_ROOT/argv.py"
ARGV_OUT="$(yaml_runtime_run one two three < "$TMP_ROOT/argv.py" 2>/dev/null)"
if [ "$ARGV_OUT" = "<gaai-yaml-runtime>|one|two|three" ]; then
  pass "6.a caller argv is preserved with the boundary program name at argv[0]"
else
  fail "6.a argv contract broken: $ARGV_OUT"
fi

RUNC_OUT="$(printf 'payload\n' | yaml_runtime_run_c 'import sys; sys.stdout.write(sys.stdin.read().strip() + "/" + sys.argv[1])' alpha 2>/dev/null)"
if [ "$RUNC_OUT" = "payload/alpha" ]; then
  pass "6.b run_c preserves caller stdin for data and passes argv"
else
  fail "6.b run_c stdin/argv contract broken: $RUNC_OUT"
fi

for CODE in 0 1 2 7 64; do
  yaml_runtime_run_c "raise SystemExit($CODE)" >/dev/null 2>&1
  GOT=$?
  if [ "$GOT" -eq "$CODE" ]; then
    pass "6.c caller exit $CODE passes through unchanged"
  else
    fail "6.c caller exit $CODE became $GOT"
  fi
done

# No inventoried caller program may exit in the reserved range.
RESERVED_HITS="$(grep -rnE 'SystemExit\(3[0-6]\)|exit 3[0-6]$' \
  "$CORE_DIR/scripts/lib/stuck-classifier.sh" \
  "$CORE_DIR/scripts/lib/backlog-journal.sh" \
  "$CORE_DIR/scripts/daemon-dispatch.sh" \
  "$CORE_DIR/scripts/backlog-scheduler.sh" \
  "$CORE_DIR/scripts/migrate-backlog-phase-schema.sh" 2>/dev/null \
  | grep -v 'return .*|| exit 3[0-6]$' \
  | wc -l | tr -d ' ')"
if [ "$RESERVED_HITS" = "0" ]; then
  pass "6.d no migrated caller program exits in the reserved range"
else
  fail "6.d a caller program uses the reserved exit range"
fi

# Consumer failure propagates rather than being absorbed.
MISSING_CORE="$TMP_ROOT/nomanifest"
MISSING_HELPER="$(make_private_core "$MISSING_CORE")" || true
if [ -n "${MISSING_HELPER:-}" ]; then
  rm -f "$MISSING_CORE/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz"
  _call "$MISSING_HELPER" yaml_runtime_validate_file "$TMP_ROOT/snapshot.yaml" \
    >/dev/null 2>"$TMP_ROOT/propagate.err"
  PROP_RC=$?
  expect_code "6.e a missing tuple propagates as a typed failure, never an ambient fallback" \
    30 "$TMP_ROOT/propagate.err" "$PROP_RC" yaml_runtime_missing
fi

# Privacy census over every diagnostic captured on a fault path in this run.
cat "$TMP_ROOT"/*.err > "$TMP_ROOT/all-diagnostics" 2>/dev/null || true
LEAKS="$(grep '^\[yaml-runtime\]' "$TMP_ROOT/all-diagnostics" 2>/dev/null | grep -c '/' | tr -d ' ')"
if [ "${LEAKS:-0}" = "0" ]; then
  pass "6.f no boundary diagnostic in this run contains a path of any kind"
else
  fail "6.f $LEAKS boundary diagnostics contained a path"
fi
BAD_OK="$(grep '^\[yaml-runtime\]' "$TMP_ROOT/all-diagnostics" 2>/dev/null \
  | grep 'code=ok' | grep -cv 'role=normalize action=vendor_modes' | tr -d ' ')"
if [ "${BAD_OK:-0}" = "0" ]; then
  pass "6.g the success status appears only as the normalizer's own status"
else
  fail "6.g a success status appeared outside the normalizer"
fi

# ══════════════════════════════════════════════════════════════════════════
# 7. Bounded settlement cleanup
# ══════════════════════════════════════════════════════════════════════════
echo "7. settlement cleanup"

SETTLE_ROOT="$TMP_ROOT/settle"
mkdir -p "$SETTLE_ROOT/state/local-admission-receipts" "$SETTLE_ROOT/state/external-merge-settlements"
chmod 700 "$SETTLE_ROOT/state" "$SETTLE_ROOT/state/local-admission-receipts" \
  "$SETTLE_ROOT/state/external-merge-settlements"
SETTLE_REPO="$SETTLE_ROOT/repo"
SETTLE_ORIGIN="$SETTLE_ROOT/origin.git"
mkdir -p "$SETTLE_REPO/.gaai/core/scripts/lib" "$SETTLE_REPO/.gaai/core/vendor/pyyaml/6.0.3" \
  "$SETTLE_REPO/.gaai/project/ci" "$SETTLE_REPO/.gaai/project/contexts/backlog"
cp "$CORE_DIR/scripts/delivery-daemon.sh" "$SETTLE_REPO/.gaai/core/scripts/"
cp "$CORE_DIR/scripts/backlog-scheduler.sh" "$SETTLE_REPO/.gaai/core/scripts/"
cp "$CORE_DIR/scripts/lib/local-admission-executor.mjs" "$SETTLE_REPO/.gaai/core/scripts/lib/" 2>/dev/null || true
cp "$LIB_PATH" "$SETTLE_REPO/.gaai/core/scripts/lib/"
cp "$VENDOR_DIR/pyyaml-runtime.pyz" "$VENDOR_DIR/PROVENANCE.json" "$VENDOR_DIR/LICENSE" \
  "$SETTLE_REPO/.gaai/core/vendor/pyyaml/6.0.3/"
chmod 0644 "$SETTLE_REPO/.gaai/core/vendor/pyyaml/6.0.3/"*
printf '{"repository":{"project_id":"x/y","remote":"%s","base_ref":"staging"},"limits":{"max_receipt_bytes":65536},"policy_version":"test"}\n' \
  "$SETTLE_ORIGIN" > "$SETTLE_REPO/.gaai/project/ci/local-admission.json"
printf 'items:\n- id: TSTS01\n  status: in_progress\n  phase_status: qa_passed\n  pr_status: pending_review\n  pr_url: https://github.com/x/y/pull/1\n  started_at: "2000-01-01T00:00:00Z"\n' \
  > "$SETTLE_REPO/.gaai/project/contexts/backlog/active.backlog.yaml"
git init -q --bare "$SETTLE_ORIGIN" 2>/dev/null
git -C "$SETTLE_REPO" init -q -b staging 2>/dev/null || git -C "$SETTLE_REPO" init -q 2>/dev/null
git -C "$SETTLE_REPO" config user.email test@example.invalid
git -C "$SETTLE_REPO" config user.name yaml-runtime-test
git -C "$SETTLE_REPO" add -A >/dev/null 2>&1
git -C "$SETTLE_REPO" commit -qm base >/dev/null 2>&1
git -C "$SETTLE_REPO" remote add origin "$SETTLE_ORIGIN" 2>/dev/null
git -C "$SETTLE_REPO" push -q origin HEAD:refs/heads/staging >/dev/null 2>&1

# hostile sibling remnants: they live beside the settlement root and must be
# untouched by a removal that is scoped to the root the run itself created.
mkdir -p "$SETTLE_ROOT/state/external-merge-settlements/sibling"
ln -s "$TMP_ROOT/outside-sentinel" "$SETTLE_ROOT/state/external-merge-settlements/dangling" 2>/dev/null || true
printf 'sentinel\n' > "$TMP_ROOT/outside-sentinel"

( cd "$SETTLE_REPO" && GAAI_TARGET_BRANCH=staging bash "$SETTLE_REPO/.gaai/core/scripts/delivery-daemon.sh" \
    --watch-once-story TSTS01 --operator-state-root "$SETTLE_ROOT/state" ) \
  > "$TMP_ROOT/watch.out" 2>&1
WATCH_OUTCOME="$(sed -n 's/.*outcome=\([a-z_]*\).*/\1/p' "$TMP_ROOT/watch.out" | head -1)"
SURVIVORS="$(find "$SETTLE_ROOT/state/external-merge-settlements" -maxdepth 1 -name '.watch-once-*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$SURVIVORS" = "0" ]; then
  pass "7.a no settlement helper directory survives the run (outcome=${WATCH_OUTCOME:-none}), mirrored subdirectories included"
else
  fail "7.a $SURVIVORS settlement helper directories survived (outcome=${WATCH_OUTCOME:-none})"
fi
# The behavioural assertion above is vacuous if the run halted before the helper
# directory was ever materialized, so the structural half is asserted too: the
# flat one-level removal cannot survive the mirrored layout it now has to clear.
if grep -q 'for child in helper_dir.iterdir(): child.unlink()' "$CORE_DIR/scripts/delivery-daemon.sh"; then
  fail "7.c the settlement cleanup is still the flat one-level removal"
else
  pass "7.c the settlement cleanup is no longer a flat one-level removal"
fi
if [ -f "$TMP_ROOT/outside-sentinel" ] && [ -d "$SETTLE_ROOT/state/external-merge-settlements/sibling" ]; then
  pass "7.b removal is scoped: an out-of-root target and a sibling directory are untouched"
else
  fail "7.b removal was not scoped to the created settlement root"
fi

# ══════════════════════════════════════════════════════════════════════════
# 8. Local rebuild gate (admission-mandatory locally, designed out in CI)
# ══════════════════════════════════════════════════════════════════════════
echo "8. offline rebuild"

if [ -n "${GAAI_YAML_TEST_SDIST:-}" ]; then
  if [ ! -f "$GAAI_YAML_TEST_SDIST" ]; then
    fail "8.a GAAI_YAML_TEST_SDIST does not name a readable file"
  else
    RELTS="$(sed -n 's/.*"release_timestamp": "\([^"]*\)".*/\1/p' "$VENDOR_DIR/PROVENANCE.json" | head -1)"
    BUILD_PY="${GAAI_YAML_BUILDER_PYTHON:-${GAAI_YAML_PYTHON:-}}"
    if [ -z "$BUILD_PY" ]; then
      fail "8.a the rebuild gate requires a declared builder interpreter"
    else
      R1="$TMP_ROOT/rebuild1"; R2="$TMP_ROOT/rebuild2"
      mkdir -p "$R1/home" "$R1/tmp" "$R2/home" "$R2/tmp"
      REBUILD_OK=1
      for R in "$R1" "$R2"; do
        env -i HOME="$R/home" TMPDIR="$R/tmp" PATH=/usr/bin:/bin \
          GAAI_YAML_PYTHON="$BUILD_PY" \
          /bin/bash "$BUILDER_PATH" --sdist "$GAAI_YAML_TEST_SDIST" \
            --release-timestamp "$RELTS" --out "$R/out" >/dev/null 2>"$R/err" || REBUILD_OK=0
      done
      if [ "$REBUILD_OK" -eq 1 ]; then
        DIFFS=0
        for f in pyyaml-runtime.pyz LICENSE PROVENANCE.json; do
          cmp -s "$R1/out/$f" "$R2/out/$f" || DIFFS=$(( DIFFS + 1 ))
          cmp -s "$R1/out/$f" "$VENDOR_DIR/$f" || DIFFS=$(( DIFFS + 1 ))
        done
        if [ "$DIFFS" -eq 0 ]; then
          pass "8.a two clean offline rebuilds reproduce the checked-in tuple byte-identically"
        else
          fail "8.a $DIFFS byte differences across the two rebuilds and the checked-in tuple"
        fi
      else
        fail "8.a a clean offline rebuild did not complete"
      fi
    fi
  fi
elif [ "${GAAI_YAML_TEST_LOCAL_ADMISSION:-0}" = "1" ]; then
  # Local admission is where the rebuild proof is mandatory; there an unset
  # source distribution is a failure, not a lane property.
  fail "8.a local admission requires GAAI_YAML_TEST_SDIST: the rebuild proof was not run"
else
  # CI has no source distribution by design. This is a skip and is recorded as
  # one: it does not add to the pass count, so the floor cannot be met by it.
  echo "  SKIP: 8.a rebuild proof not run (no source distribution supplied; set GAAI_YAML_TEST_SDIST, or GAAI_YAML_TEST_LOCAL_ADMISSION=1 to require it)"
fi

if [ -f "$BUILDER_PATH" ]; then
  if grep -nE '(^|[^[:alnum:]_])(curl|wget|apt-get|apt|brew|ensurepip)([^[:alnum:]_]|$)' "$BUILDER_PATH" >/dev/null 2>&1; then
    fail "8.b the builder contains a network or package-manager token"
  else
    pass "8.b the builder contains no network or package-manager token"
  fi
  if grep -nE 'pip[0-9]? +(install|download)' "$BUILDER_PATH" >/dev/null 2>&1; then
    fail "8.c the builder names an installation command"
  else
    pass "8.c the builder names no installation command"
  fi
else
  fail "8.b the builder is missing"
fi

ABORTED=0
