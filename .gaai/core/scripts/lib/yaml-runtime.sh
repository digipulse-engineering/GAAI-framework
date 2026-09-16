#!/usr/bin/env bash
# lib/yaml-runtime.sh — the only supported entry for an authority-bearing YAML
# program in this Framework.
#
# One selected, attested interpreter runs each YAML operation exactly once. The
# vendored runtime archive is opened without following links, verified against the
# manifest that ships beside it, and imported through the descriptor that was
# verified — never through a pathname that could be re-pointed in between. Nothing
# here downloads, installs, updates, invokes a package manager, or falls back to an
# ambient interpreter or an ambient parser.
#
# Public entries
#   yaml_runtime_run <argv...>              program on stdin, argv after it
#   yaml_runtime_run_c <program> <argv...>  program in argv, caller stdin preserved
#   yaml_runtime_validate_file <path>       fixed safe-load validation program
#   yaml_runtime_verify_tuple               interpreter + complete distributed tuple
#   yaml_runtime_normalize_vendor_modes <repo-root>
#   yaml_runtime_verify_worktree_tuple <repo-root>
#   yaml_runtime_main --validate <path> | --verify-tuple   (direct invocation only)
#
# The boundary's OWN diagnostics (_yr_diag) are one bounded stderr line and carry
# no YAML content, no parser text and no path of any kind:
#   [yaml-runtime] role=<role> action=<action> code=<code>
# That promise is about _yr_diag. The caller-program entries (run/run_c) pass the
# program's stdout, stderr and status through by contract, so what an explicit
# non-host interpreter prints on those streams is the caller's to see.
#
# Closed failure vocabulary and shell exit codes:
#   yaml_runtime_missing              30
#   yaml_runtime_interpreter_invalid  31   (adds mode=explicit|discovered)
#   yaml_runtime_manifest_invalid     32
#   yaml_runtime_asset_invalid        33
#   yaml_runtime_platform_unsupported 34
#   yaml_runtime_import_failed        35
#   yaml_runtime_semantic_mismatch    36
#
# The one non-diagnostic success status this file emits is
#   [yaml-runtime] role=normalize action=vendor_modes code=ok
# at exit 0, from the dedicated mode-normalization program only. It is never a
# failure code and never appears on a failure path.
#
# Trust model of the explicit override. GAAI_YAML_PYTHON names an interpreter
# the OPERATOR vouches for; the shell layer checks that it is an absolute,
# regular, executable, native-image file and that it is live (it reads its input
# and produces the expected output), and the bootstrap then checks version,
# implementation, executing image and isolation in-process. The shell layer
# cannot prove that an arbitrary operator-designated binary is CPython -- an
# untrusted process cannot attest itself -- so an operator who points this
# variable at a hostile compiled binary has already compromised the host. Default
# discovery, by contrast, admits only a fixed candidate list under an audited
# owner chain. Neither mode ever falls back to the other. Note that the hosted
# test matrix runs every cell with GAAI_YAML_PYTHON set, so all of its evidence
# is produced in the explicit mode this paragraph describes.
#
# Callers may set the shell variable YAML_RUNTIME_ROLE (a bounded lowercase token)
# before invoking an entry so diagnostics name the consumer. It is an ordinary
# shell variable, not an environment variable: this file needs no environment
# configuration in production.

if [ -n "${_YAML_RUNTIME_SH_SOURCED:-}" ]; then
  return 0
fi
_YAML_RUNTIME_SH_SOURCED=1

# ── Vendor resolution: one closed rule, derived from this file's own location ──
# There is deliberately no environment override and no fallback search: an override
# would be a production redirection seam able to aim the boundary at a matching
# hostile manifest/archive pair.
# `dirname` is the one external command in this resolution, so it is resolved
# from the pinned system path rather than the caller's: a `dirname` shim first on
# PATH would otherwise re-point _YR_VENDOR_DIR at a directory the caller owns,
# which is precisely the redirection seam the paragraph above refuses to expose
# as an environment override. `cd` and `pwd` are builtins and cannot be shimmed.
_yr_resolve_lib_dir() {
  # CDPATH is cleared, not just PATH. `cd` consults CDPATH for any path that does
  # not start with / ./ or ../ -- which is exactly the shape the README and the
  # pre-push hook's own remedy line use (`bash .gaai/core/scripts/lib/...`). A
  # hostile CDPATH redirects vendor resolution into a tree the caller owns; a
  # benign one (CDPATH=.:$HOME is a common shell setting) makes `cd` print the
  # resolved directory, so the substitution captures two lines and every relative
  # invocation fails with yaml_runtime_missing. Both are closed here.
  local PATH='/usr/bin:/bin:/usr/sbin:/sbin' CDPATH=''
  cd -- "$(dirname -- "$1")" >/dev/null && pwd -P
}
_YR_LIB_DIR="$(_yr_resolve_lib_dir "${BASH_SOURCE[0]}")"
_YR_CORE_DIR="$(cd "$_YR_LIB_DIR/../.." && pwd -P)"
_YR_VENDOR_DIR="$_YR_CORE_DIR/vendor/pyyaml/6.0.3"
_YR_ARCHIVE="$_YR_VENDOR_DIR/pyyaml-runtime.pyz"
_YR_MANIFEST="$_YR_VENDOR_DIR/PROVENANCE.json"
_YR_LICENCE="$_YR_VENDOR_DIR/LICENSE"

_YR_STAT_FLAVOUR=""
_YR_PY=""
_YR_TRUST=""
_YR_ATTESTED=""

_yr_role() {
  local value="${YAML_RUNTIME_ROLE:-}"
  if [ -z "$value" ]; then
    printf 'boundary'
    return 0
  fi
  if [ "${#value}" -gt 32 ]; then
    printf 'unknown'
    return 0
  fi
  case "$value" in
    *[!a-z0-9_]*) printf 'unknown' ;;
    [a-z]*) printf '%s' "$value" ;;
    *) printf 'unknown' ;;
  esac
}

# _yr_diag <action> <code> [<mode>] — one bounded, path-free stderr line.
_yr_diag() {
  local action="$1" code="$2" mode="${3:-}"
  if [ -n "$mode" ]; then
    printf '[yaml-runtime] role=%s action=%s code=%s mode=%s\n' \
      "$(_yr_role)" "$action" "$code" "$mode" >&2
  else
    printf '[yaml-runtime] role=%s action=%s code=%s\n' \
      "$(_yr_role)" "$action" "$code" >&2
  fi
}

_yr_code_for_exit() {
  case "$1" in
    30) printf 'yaml_runtime_missing' ;;
    31) printf 'yaml_runtime_interpreter_invalid' ;;
    32) printf 'yaml_runtime_manifest_invalid' ;;
    33) printf 'yaml_runtime_asset_invalid' ;;
    34) printf 'yaml_runtime_platform_unsupported' ;;
    35) printf 'yaml_runtime_import_failed' ;;
    36) printf 'yaml_runtime_semantic_mismatch' ;;
    *) printf '' ;;
  esac
}

# Map one bootstrap exit status onto the closed vocabulary. A status outside the
# reserved range is a caller-program status and passes through untouched.
_yr_report_exit() {
  local action="$1" status="$2" code
  code="$(_yr_code_for_exit "$status")"
  if [ -n "$code" ]; then
    if [ "$status" -eq 31 ]; then
      _yr_diag "$action" "$code" "$_YR_TRUST"
    else
      _yr_diag "$action" "$code"
    fi
  fi
  return "$status"
}

# ── Trusted lookup path for this boundary's own primitives ───────────────────
# Discovery reads the candidate set from a fixed list, but it decides what a
# candidate IS by shelling out to realpath/readlink/stat/od/tr/id/dirname/
# basename. Those were resolved through the CALLER's PATH, so the trust decision
# was caller-controlled even though the candidate set was not: a `realpath` shim
# first on PATH makes the boundary canonicalize a fixed candidate to any path the
# shim names, and every later check -- regular, executable, native magic, owner
# chain -- then passes against the ATTACKER's file, which the boundary executes
# as the attested interpreter. The pre-push YAML gates that consume this become
# fail-OPEN for anyone who can prepend a directory to PATH.
#
# Each helper below therefore pins `PATH` to the standard system locations for
# the duration of its own call. `local PATH=` is scoped: it never reaches the
# caller, and it never touches the interpreter the boundary ultimately runs
# (that path is validated, absolute and executed directly). Homebrew and other
# user-writable prefixes are deliberately excluded; where a primitive is absent
# from the pinned set the existing bounded fallback runs, itself pinned.
_YR_SAFE_PATH='/usr/bin:/bin:/usr/sbin:/sbin'

# ── Portable owner/mode reader ───────────────────────────────────────────────
_yr_stat_owner_mode() {
  local PATH="$_YR_SAFE_PATH"
  if [ -z "$_YR_STAT_FLAVOUR" ]; then
    if stat -f '%u %Lp' / >/dev/null 2>&1; then
      _YR_STAT_FLAVOUR=bsd
    elif stat -c '%u %a' / >/dev/null 2>&1; then
      _YR_STAT_FLAVOUR=gnu
    else
      _YR_STAT_FLAVOUR=none
    fi
  fi
  case "$_YR_STAT_FLAVOUR" in
    bsd) stat -f '%u %Lp' -- "$1" 2>/dev/null ;;
    gnu) stat -c '%u %a' -- "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# ── Canonicalization ─────────────────────────────────────────────────────────
# realpath(1) where available, otherwise a bounded symlink-resolution loop with
# the same meaning. This is pure path resolution: the resolved target is audited
# afterwards either way, so no trust decision depends on which primitive ran.
_yr_canonicalize() {
  local PATH="$_YR_SAFE_PATH"
  local target="$1" dir base link depth=0
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$target" 2>/dev/null
    return $?
  fi
  while [ "$depth" -lt 32 ]; do
    dir="$(dirname -- "$target")"
    base="$(basename -- "$target")"
    dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 1
    target="$dir/$base"
    if [ -L "$target" ]; then
      link="$(readlink -- "$target" 2>/dev/null)" || return 1
      case "$link" in
        /*) target="$link" ;;
        *) target="$dir/$link" ;;
      esac
      depth=$(( depth + 1 ))
      continue
    fi
    printf '%s\n' "$target"
    return 0
  done
  return 1
}

# ── Native-executable magic scan ─────────────────────────────────────────────
# Refuses a `#!` shim or shell wrapper before it is ever executed. The byte pairs
# are kept space-separated exactly as od(1) prints them.
_yr_native_magic() {
  local PATH="$_YR_SAFE_PATH"
  local head
  head="$(LC_ALL=C od -An -tx1 -N4 -- "$1" 2>/dev/null)" || return 1
  head="$(printf '%s' "$head" | tr -s '[:space:]' ' ')"
  head="${head# }"
  head="${head% }"
  case "$head" in
    "7f 45 4c 46") return 0 ;;
    "cf fa ed fe") return 0 ;;
    "ca fe ba be") return 0 ;;
    "ca fe ba bf") return 0 ;;
    *) return 1 ;;
  esac
}

# ── Discovery-mode ownership / writability audit ─────────────────────────────
# owner in {root, euid} and no group/other write, on the canonical target and on
# every canonical ancestor directory up to the root.
# The chain is resolved HERE, not by the caller. The verdict has to be a
# property of the object on disk, never of the spelling a caller chose: an
# lstat walk over an unresolved path reads a symlink component's own owner and
# mode, and where links are created 0755 a link into a world-writable tree
# passes every step that its real ancestors would fail. The in-process
# predicate resolves before it walks (owner_chain_ok on os.path.realpath), so
# this audit does the same and the two verdicts cannot part on a symlinked
# ancestor. Resolution reads link targets only -- nothing is opened or run --
# and is bounded (realpath(1), or the 32-hop fallback); a chain that resolves
# into a tree this audit refuses is refused for what it is, which is the
# point. The verdict is about the object the path resolves to, exactly as the
# in-process predicate's is; the binding of the executing image in-process is
# what closes the window between this audit and the exec, as before.
# Selection hands in a canonical path already, so there resolution is the
# identity and the verdict is unchanged. An empty or relative argument is
# refused before resolution: resolving it would answer about the working
# directory (or, in the fallback resolver, about wherever `cd` is sent), an
# object the caller never named. It also ends the walk's dependence on the
# input reaching "/", which a relative input never did.
_yr_audit_owner_chain() {
  local PATH="$_YR_SAFE_PATH"
  local path="$1" euid owner mode reading
  local IFS=$' \t\n'
  euid="$(id -u 2>/dev/null)" || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  reading="$(_yr_canonicalize "$path")" || return 1
  case "$reading" in
    /*) ;;
    *) return 1 ;;
  esac
  while :; do
    owner=""
    mode=""
    read -r owner mode <<< "$(_yr_stat_owner_mode "$reading")" || true
    if [ -z "$owner" ] || [ -z "$mode" ]; then
      return 1
    fi
    if [ "$owner" != "0" ] && [ "$owner" != "$euid" ]; then
      return 1
    fi
    if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then
      return 1
    fi
    if [ "$reading" = "/" ]; then
      break
    fi
    reading="$(dirname -- "$reading")"
  done
  return 0
}

# ── Interpreter selection: two disjoint trust modes ──────────────────────────
# Sets _YR_PY (the canonical target that is actually executed and declared) and
# _YR_TRUST (explicit | discovered). Returns 31 when nothing qualifies.
# A fresh token per call for the LIVENESS check below. It is not an attestation:
# it is handed, as argv or environment, to the very process it checks, so any
# binary that reads its arguments can echo it back. What it does establish is that
# the process is not inert -- it did read its input and did produce output -- which
# is the realistic misconfiguration (`GAAI_YAML_PYTHON=/usr/bin/true`, a stale
# wrapper, an interpreter that ignores -c) that previously made every gate report
# success with no parser loaded. Against a purpose-built native forger the
# explicit override is an operator trust root by design; see the header.
# The two fixed-program entries publish a closed status vocabulary and a stderr
# that carries no path. A candidate that is not a bootstrap host (`/bin/sh`,
# `/usr/bin/env`, `cat` ...) exits 1 or 2 and writes its own stderr, which used to
# pass straight through both promises. Its stderr is now discarded and any
# non-zero status outside the reserved range is what it means: not a bootstrap
# host, 31. `run`/`run_c` are deliberately excluded -- caller-status passthrough
# is their contract.
_yr_typed_status() {
  case "$1" in
    0|30|31|32|33|34|35|36) printf '%s' "$1" ;;
    *) printf '31' ;;
  esac
}

_yr_nonce() {
  local PATH="$_YR_SAFE_PATH" n
  n="$(LC_ALL=C od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$n" ] || n="$$-$(date +%s 2>/dev/null)-${RANDOM:-0}${RANDOM:-0}"
  printf '%s' "$n"
}


_yr_select_interpreter() {
  local PATH="$_YR_SAFE_PATH"
  local candidate canonical minor dir
  local IFS=$' \t\n'

  _YR_PY=""
  _YR_TRUST=""

  if [ -n "${GAAI_YAML_PYTHON:-}" ]; then
    # Explicit trust root: the operator declared the anchor. The shell layer
    # checks only what must be known before execution; implementation, version,
    # release level, executing-image identity and isolation are earned in-process.
    _YR_TRUST="explicit"
    candidate="$GAAI_YAML_PYTHON"
    case "$candidate" in
      /*) ;;
      *) return 31 ;;
    esac
    [ -f "$candidate" ] || return 31
    [ -x "$candidate" ] || return 31
    _yr_native_magic "$candidate" || return 31
    _YR_PY="$candidate"
    return 0
  fi

  # Default discovery over a fixed ordered candidate set. Never PATH, never a
  # glob, never a shim directory.
  _YR_TRUST="discovered"
  local dirs
  for minor in 3.14 3.13 3.12; do
    case "$(uname 2>/dev/null)" in
      Darwin)
        dirs="/opt/homebrew/bin /usr/local/bin /Library/Frameworks/Python.framework/Versions/$minor/bin /usr/bin" ;;
      *)
        dirs="/usr/bin /bin /usr/local/bin" ;;
    esac
    for dir in $dirs; do
      candidate="$dir/python$minor"
      [ -e "$candidate" ] || continue
      canonical="$(_yr_canonicalize "$candidate")" || continue
      [ -n "$canonical" ] || continue
      [ -f "$canonical" ] || continue
      [ -x "$canonical" ] || continue
      _yr_native_magic "$canonical" || continue
      _yr_audit_owner_chain "$canonical" || continue
      # The canonical target — not the front door — is what is executed and what
      # is passed as the declared identity, so the symlink cannot be re-pointed
      # between the audit and the exec and the in-process binding compares like
      # with like.
      _YR_PY="$canonical"
      return 0
    done
  done
  return 31
}

_yr_require_tuple_present() {
  [ -f "$_YR_ARCHIVE" ] || return 30
  [ -f "$_YR_MANIFEST" ] || return 30
  return 0
}

# ── The single-process bootstrap ─────────────────────────────────────────────
read -r -d '' _YR_BOOTSTRAP <<'PYEOF' || true
import hashlib
import io
import json
import os
import stat
import sys
import zipfile

MISSING = 30
INTERPRETER = 31
MANIFEST = 32
ASSET = 33
PLATFORM = 34
IMPORT_FAILED = 35
SEMANTIC = 36

SUPPORTED_MINORS = ((3, 12), (3, 13), (3, 14))
SUPPORTED_LABELS = ["3.12", "3.13", "3.14"]
EXACT_FILE_MODE = 0o644
MANIFEST_MAX_BYTES = 1 << 20  # 1 MiB; spelled as a shift so no digit run resembles an identifier
RUNTIME_VERSION = "6.0.3"
PROGRAM_NAME = "<gaai-yaml-runtime>"

TOP_KEYS = {
    "schema_version", "upstream", "framework", "licence", "builder", "archive",
    "output", "rebuild",
}
UPSTREAM_KEYS = {
    "name", "version", "license", "canonical_source_url", "source_filename",
    "sdist_sha256", "sdist_size_bytes", "release_timestamp", "requires_python",
}
FRAMEWORK_KEYS = {
    "supported_cpython_minors", "support_boundary_note", "builder_cpython",
}
FILE_BLOCK_KEYS = {"path", "sha256", "size_bytes", "mode"}
ARCHIVE_KEYS = {
    "format", "compression", "member_order", "member_timestamp", "member_mode",
    "members", "excluded_classes",
}
MEMBER_KEYS = {"path", "size_bytes", "mode", "sha256"}
OUTPUT_KEYS = {"path", "size_bytes", "sha256", "mode"}
REBUILD_KEYS = {"command", "network_required"}

HEX = frozenset("abcdef") | frozenset(str(digit) for digit in range(10))


def fail(code):
    raise SystemExit(code)


def is_digest(value):
    return (isinstance(value, str) and len(value) == 64
            and all(char in HEX for char in value))


def is_size(value):
    return type(value) is int and value >= 0


def real_executing_image():
    if sys.platform == "darwin":
        try:
            import ctypes

            libc = ctypes.CDLL(None)
            get_path = libc._NSGetExecutablePath
            size = ctypes.c_uint32(1024)
            buf = ctypes.create_string_buffer(size.value)
            if get_path(buf, ctypes.byref(size)) != 0:
                if size.value <= 0 or size.value > 65536:
                    return None
                buf = ctypes.create_string_buffer(size.value)
                if get_path(buf, ctypes.byref(size)) != 0:
                    return None
            raw = buf.value
            if not raw:
                return None
            return os.path.realpath(os.fsdecode(raw))
        except Exception:
            return None
    try:
        return os.path.realpath(os.readlink("/proc/self/exe"))
    except OSError:
        return None


def framework_root(path):
    parts = path.split(os.sep)
    for index, part in enumerate(parts):
        if (part == "Python.framework" and index + 2 < len(parts)
                and parts[index + 1] == "Versions"):
            return os.sep.join(parts[:index + 3])
    return None


def native_magic(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(4)
    except OSError:
        return False
    return head in (
        b"\x7fELF",
        b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
    )


def owner_chain_ok(path):
    euid = os.geteuid()
    current = path
    while True:
        try:
            info = os.stat(current, follow_symlinks=False)
        except OSError:
            return False
        if info.st_uid not in (0, euid):
            return False
        if stat.S_IMODE(info.st_mode) & 0o022:
            return False
        if current == os.sep:
            return True
        parent = os.path.dirname(current)
        if parent == current:
            return True
        current = parent


def attest_interpreter(declared, trust):
    # 1. implementation, supported final minor
    if sys.implementation.name != "cpython":
        fail(INTERPRETER)
    if sys.version_info[:2] not in SUPPORTED_MINORS:
        fail(INTERPRETER)
    if sys.version_info.releaselevel != "final":
        fail(INTERPRETER)

    # 2. executing-image binding — the image the kernel loaded, not sys.executable
    image = real_executing_image()
    if image is None:
        fail(INTERPRETER)
    declared_real = os.path.realpath(declared)
    if image != declared_real:
        root = framework_root(declared_real)
        if (sys.platform != "darwin" or root is None
                or framework_root(image) != root
                or not os.path.isfile(image)
                or os.path.islink(image)
                or not native_magic(image)):
            fail(INTERPRETER)

    # 3. ownership / mode audit — discovered mode only, per the contract's scope
    if trust == "discovered":
        if not owner_chain_ok(declared_real) or not owner_chain_ok(image):
            fail(INTERPRETER)

    # 4. no virtual environment, no third-party path entry, no preloaded parser
    if sys.prefix != sys.base_prefix:
        fail(INTERPRETER)
    for entry in sys.path:
        base = os.path.basename(entry.rstrip(os.sep))
        if base in ("site-packages", "dist-packages"):
            fail(INTERPRETER)
    if "yaml" in sys.modules:
        fail(INTERPRETER)


def open_verified(path, code, expected_size=None, max_size=None):
    """Open no-follow, prove type/owner/exact mode/size and descriptor identity."""
    try:
        before = os.lstat(path)
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        fail(code)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            fail(code)
        if info.st_uid != os.geteuid():
            fail(code)
        if stat.S_IMODE(info.st_mode) != EXACT_FILE_MODE:
            fail(code)
        identity = (info.st_dev, info.st_ino)
        if identity != (before.st_dev, before.st_ino):
            fail(code)
        if expected_size is not None and info.st_size != expected_size:
            fail(code)
        if max_size is not None and info.st_size > max_size:
            fail(code)
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
        data = b"".join(chunks)
        if len(data) != info.st_size:
            fail(code)
        after = os.lstat(path)
        if identity != (after.st_dev, after.st_ino):
            fail(code)
        return fd, data
    except SystemExit:
        os.close(fd)
        raise
    except OSError:
        os.close(fd)
        fail(code)


def load_manifest(manifest_path):
    fd, data = open_verified(
        manifest_path, MANIFEST, max_size=MANIFEST_MAX_BYTES,
    )
    os.close(fd)
    try:
        manifest = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        fail(MANIFEST)
    if not isinstance(manifest, dict) or set(manifest) != TOP_KEYS:
        fail(MANIFEST)
    if manifest["schema_version"] != "1.0.0":
        fail(MANIFEST)
    for key, expected in (
        ("upstream", UPSTREAM_KEYS), ("framework", FRAMEWORK_KEYS),
        ("licence", FILE_BLOCK_KEYS), ("builder", FILE_BLOCK_KEYS),
        ("archive", ARCHIVE_KEYS), ("output", OUTPUT_KEYS),
        ("rebuild", REBUILD_KEYS),
    ):
        block = manifest[key]
        if not isinstance(block, dict) or set(block) != expected:
            fail(MANIFEST)

    upstream = manifest["upstream"]
    if upstream["name"] != "PyYAML" or upstream["version"] != RUNTIME_VERSION:
        fail(MANIFEST)
    if not is_digest(upstream["sdist_sha256"]) or not is_size(upstream["sdist_size_bytes"]):
        fail(MANIFEST)
    for key in ("license", "canonical_source_url", "source_filename",
                "release_timestamp", "requires_python"):
        if not isinstance(upstream[key], str) or not upstream[key]:
            fail(MANIFEST)

    framework = manifest["framework"]
    if framework["supported_cpython_minors"] != SUPPORTED_LABELS:
        fail(MANIFEST)
    if not isinstance(framework["support_boundary_note"], str) \
            or not isinstance(framework["builder_cpython"], str):
        fail(MANIFEST)

    for key in ("licence", "builder"):
        block = manifest[key]
        if not is_digest(block["sha256"]) or not is_size(block["size_bytes"]):
            fail(MANIFEST)
        if not isinstance(block["path"], str) or not block["path"]:
            fail(MANIFEST)
        if not isinstance(block["mode"], str) or not block["mode"]:
            fail(MANIFEST)
    if manifest["licence"]["mode"] != "0644":
        fail(MANIFEST)

    archive = manifest["archive"]
    if archive["format"] != "zip" or archive["compression"] != "stored":
        fail(MANIFEST)
    if archive["member_order"] != "sorted-by-name" or archive["member_mode"] != "0644":
        fail(MANIFEST)
    if not isinstance(archive["member_timestamp"], str) or not archive["member_timestamp"]:
        fail(MANIFEST)
    if not isinstance(archive["excluded_classes"], list) \
            or not all(isinstance(item, str) for item in archive["excluded_classes"]):
        fail(MANIFEST)
    members = archive["members"]
    if not isinstance(members, list) or not members:
        fail(MANIFEST)
    seen = set()
    previous = ""
    for member in members:
        if not isinstance(member, dict) or set(member) != MEMBER_KEYS:
            fail(MANIFEST)
        path = member["path"]
        if not isinstance(path, str) or not path or path in seen:
            fail(MANIFEST)
        if path < previous:
            fail(MANIFEST)
        previous = path
        seen.add(path)
        if member["mode"] != "0644" or not is_size(member["size_bytes"]) \
                or not is_digest(member["sha256"]):
            fail(MANIFEST)

    output = manifest["output"]
    if not is_digest(output["sha256"]) or not is_size(output["size_bytes"]):
        fail(MANIFEST)
    if output["mode"] != "0644" or not isinstance(output["path"], str) or not output["path"]:
        fail(MANIFEST)
    # Internal consistency: a stored archive can never be smaller than the sum of
    # the member payloads it declares.
    if output["size_bytes"] < sum(member["size_bytes"] for member in members):
        fail(MANIFEST)

    rebuild = manifest["rebuild"]
    if rebuild["network_required"] is not False:
        fail(MANIFEST)
    if not isinstance(rebuild["command"], str) or not rebuild["command"]:
        fail(MANIFEST)
    return manifest


def verify_archive(archive_path, manifest):
    output = manifest["output"]
    fd, data = open_verified(archive_path, ASSET, expected_size=output["size_bytes"])
    try:
        if hashlib.sha256(data).hexdigest() != output["sha256"]:
            fail(ASSET)
        # Declared-versus-actual member census: an archive whose contents do not
        # match the manifest exactly is refused even when its own bytes are
        # internally consistent.
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                names = zf.namelist()
                declared = [member["path"] for member in manifest["archive"]["members"]]
                if names != declared or len(set(names)) != len(names):
                    fail(ASSET)
                for member in manifest["archive"]["members"]:
                    info = zf.getinfo(member["path"])
                    if info.compress_type != zipfile.ZIP_STORED:
                        fail(ASSET)
                    if info.file_size != member["size_bytes"]:
                        fail(ASSET)
                    if stat.S_IMODE(info.external_attr >> 16) != EXACT_FILE_MODE:
                        fail(ASSET)
                    if hashlib.sha256(zf.read(member["path"])).hexdigest() != member["sha256"]:
                        fail(ASSET)
        except SystemExit:
            raise
        except Exception:
            fail(ASSET)
    except SystemExit:
        os.close(fd)
        raise
    return fd


def verify_licence(manifest_path, manifest):
    block = manifest["licence"]
    licence_path = os.path.join(
        os.path.dirname(manifest_path), os.path.basename(block["path"]),
    )
    fd, data = open_verified(licence_path, ASSET, expected_size=block["size_bytes"])
    os.close(fd)
    if hashlib.sha256(data).hexdigest() != block["sha256"]:
        fail(ASSET)


def import_runtime(fd):
    if sys.platform == "darwin":
        fd_path = "/dev/fd/%d" % fd
    elif sys.platform.startswith("linux"):
        fd_path = "/proc/self/fd/%d" % fd
    else:
        fail(PLATFORM)
    try:
        probe = os.stat(fd_path)
        if not stat.S_ISREG(probe.st_mode):
            fail(PLATFORM)
    except SystemExit:
        raise
    except OSError:
        fail(PLATFORM)
    cwd = os.getcwd()
    sys.path[:] = [
        entry for entry in sys.path if entry not in ("", ".", cwd)
    ]
    sys.path.insert(0, fd_path)
    try:
        import yaml
    except Exception:
        fail(IMPORT_FAILED)
    if getattr(yaml, "__version__", None) != RUNTIME_VERSION:
        fail(IMPORT_FAILED)
    if not str(getattr(yaml, "__file__", "")).startswith(fd_path):
        fail(IMPORT_FAILED)
    return yaml


def run_program(yaml, source, argv):
    try:
        code = compile(source, PROGRAM_NAME, "exec")
    except (SyntaxError, ValueError):
        fail(SEMANTIC)
    globals_map = {
        "__name__": "__main__",
        "__file__": PROGRAM_NAME,
        "__builtins__": __builtins__,
        "yaml": yaml,
    }
    sys.argv = [PROGRAM_NAME] + list(argv)
    exec(code, globals_map)


declared, trust, archive_path, manifest_path, mode = sys.argv[1:6]
caller = sys.argv[6:]

attest_interpreter(declared, trust)
manifest = load_manifest(manifest_path)
archive_fd = verify_archive(archive_path, manifest)
yaml_module = import_runtime(archive_fd)

if mode == "verify":
    verify_licence(manifest_path, manifest)
    # An optional caller-supplied token is echoed back here, after the manifest,
    # archive and import steps. It is a LIVENESS token, not proof of those steps:
    # the shell hands it to this very process, so a forger can echo it too. It
    # distinguishes a bootstrap that ran from a binary that merely exited 0.
    attest = (" attest=%s" % caller[0]) if caller else ""
    sys.stdout.write(
        "python=%s trust=%s runtime=%s%s\n"
        % (".".join(str(part) for part in sys.version_info[:3]), trust,
           yaml_module.__version__, attest)
    )
elif mode == "validate":
    # argv[1] is the optional LIVENESS token. It is echoed at the very end,
    # after the document has actually been parsed, so the shell can tell a real
    # validation from a binary that merely exited 0.
    if len(caller) not in (1, 2):
        fail(SEMANTIC)
    validate_nonce = caller[1] if len(caller) == 2 else None

    MERGE_TAG = "tag:yaml.org,2002:merge"

    class StrictLoader(yaml_module.SafeLoader):
        # A mapping key that appears twice is a defect, not a value choice.
        # safe_load resolves it silently under last-key-wins -- one entry is
        # dropped and nothing says so -- while every consumer that parses with a
        # duplicate-rejecting loader refuses the WHOLE document, for every entry
        # in it. Validation more permissive than its consumers is not validation.
        #
        # Two keys count as the same, because safe_load loses a row in both cases:
        #
        #   1. the same source text twice          `k: 1` / `k: 1`
        #   2. different text, one resolved key    `yes:` / `true:`, `1:` / `01:`,
        #                                          `~:` / `null:`, `0x10:` / `16:`
        #
        # Case 2 is why the resolved object is compared and not only the raw
        # token: the consumers compare resolved keys, so checking only raw text
        # would leave this validation permissive in exactly the way that motivates
        # it. A key that cannot be constructed or is unhashable is skipped here and
        # left to the base constructor, which rejects it on its own terms.
        #
        # The scan reads RAW key nodes, before flatten_mapping expands a merge key.
        # That ordering is deliberate: YAML merge semantics let an explicit key
        # legitimately override an inherited one, so scanning after the expansion
        # would refuse valid `<<` documents. But flatten_mapping splices a merge
        # SOURCE's pairs into the parent without ever passing that source through
        # construct_mapping, so a duplicate living inside the merge value would
        # never be seen -- hence the explicit descent into it.
        def _scan_duplicate_keys(self, node):
            # Scan each node once, by identity. `flatten_mapping` REWRITES
            # node.value in place -- it prepends the merge source's pairs to the
            # parent -- so an anchored node reached again as a merge source would
            # otherwise be scanned in its post-flatten state and its
            # merge-DERIVED pairs reported as authored duplicates. That refuses
            # ordinary compositions: a `defaults` anchor merged into `dev` and
            # `prod`, both merged into a third mapping, contains no repeated key
            # and must load. Scanning once, before anything flattens that node,
            # is what keeps the check about the source text. It also terminates a
            # self-referential merge (`x: &a {<<: *a}`) instead of recursing.
            scanned = self.__dict__.setdefault("_gaai_scanned_nodes", set())
            if id(node) in scanned:
                return
            scanned.add(id(node))
            seen_raw = set()
            seen_resolved = set()
            for key_node, value_node in node.value:
                if not isinstance(key_node, yaml_module.ScalarNode):
                    continue
                raw = (key_node.tag, key_node.value)
                if raw in seen_raw:
                    raise ValueError("duplicate mapping key")
                seen_raw.add(raw)
                # A merge key is a directive, not a value-carrying key: it is
                # descended into, never compared as a resolved key. YAML 1.1
                # allows one `<<` per mapping, so a repeated one is still caught
                # by the raw check above; several sources use `<<: [a, b]`.
                if key_node.tag == MERGE_TAG:
                    self._scan_merge_source(value_node)
                    continue
                try:
                    resolved = self.construct_object(key_node, deep=False)
                    if resolved in seen_resolved:
                        raise ValueError("duplicate mapping key")
                    seen_resolved.add(resolved)
                except ValueError:
                    raise
                except Exception:
                    pass

        def _scan_merge_source(self, node):
            if isinstance(node, yaml_module.MappingNode):
                self._scan_duplicate_keys(node)
            elif isinstance(node, yaml_module.SequenceNode):
                for child in node.value:
                    self._scan_merge_source(child)

        def construct_mapping(self, node, deep=False):
            self._scan_duplicate_keys(node)
            return super().construct_mapping(node, deep=deep)

    try:
        with open(caller[0], "rb") as handle:
            document_bytes = handle.read()
    except OSError:
        fail(ASSET)
    try:
        yaml_module.load(document_bytes.decode("utf-8"), Loader=StrictLoader)
    except SystemExit:
        raise
    except Exception:
        fail(SEMANTIC)
    if validate_nonce is not None:
        sys.stdout.write("attest=%s" % validate_nonce)
elif mode in ("run", "run_c"):
    # Liveness token for the caller-program entries, written before the caller
    # program runs so that its own stdout and status are untouched. See the
    # shell side: this proves the bootstrap executed, not that it was trusted.
    # On an inherited descriptor, never a path: fd 3 is opened by the shell
    # layer as its capture pipe. A missing fd 3 with a token requested is a
    # caller contract error and fails closed.
    live_nonce = os.environ.get("GAAI_YAML_LIVENESS_NONCE")
    if live_nonce:
        try:
            os.write(3, ("attest=%s" % live_nonce).encode("ascii"))
        except OSError:
            fail(INTERPRETER)
    if mode == "run":
        run_program(yaml_module, sys.stdin.read(), caller)
    else:
        if not caller:
            fail(SEMANTIC)
        run_program(yaml_module, caller[0], caller[1:])
else:
    fail(SEMANTIC)
PYEOF

# ── The dedicated mode-normalization program ─────────────────────────────────
# It repairs exactly the tuple the bootstrap refuses, so it deliberately runs
# neither through the bootstrap nor through any YAML entry: it opens no manifest,
# opens and digests no archive, inserts no retained-descriptor path entry and
# never imports the parser. Its only imports are standard library.
read -r -d '' _YR_NORMALIZE <<'PYEOF' || true
import os
import stat
import sys

INTERPRETER = 31
ASSET = 33
EXACT_FILE_MODE = 0o644
VENDOR_REL = os.path.join(
    ".gaai", "core", "vendor", "pyyaml", "6.0.3",
)
TARGETS = ("pyyaml-runtime.pyz", "PROVENANCE.json", "LICENSE")

SUPPORTED_MINORS = ((3, 12), (3, 13), (3, 14))


def fail(code):
    raise SystemExit(code)


def real_executing_image():
    if sys.platform == "darwin":
        try:
            import ctypes

            libc = ctypes.CDLL(None)
            get_path = libc._NSGetExecutablePath
            size = ctypes.c_uint32(1024)
            buf = ctypes.create_string_buffer(size.value)
            if get_path(buf, ctypes.byref(size)) != 0:
                if size.value <= 0 or size.value > 65536:
                    return None
                buf = ctypes.create_string_buffer(size.value)
                if get_path(buf, ctypes.byref(size)) != 0:
                    return None
            raw = buf.value
            if not raw:
                return None
            return os.path.realpath(os.fsdecode(raw))
        except Exception:
            return None
    try:
        return os.path.realpath(os.readlink("/proc/self/exe"))
    except OSError:
        return None


def framework_root(path):
    parts = path.split(os.sep)
    for index, part in enumerate(parts):
        if (part == "Python.framework" and index + 2 < len(parts)
                and parts[index + 1] == "Versions"):
            return os.sep.join(parts[:index + 3])
    return None


def native_magic(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(4)
    except OSError:
        return False
    return head in (
        b"\x7fELF",
        b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
    )


def owner_chain_ok(path):
    euid = os.geteuid()
    current = path
    while True:
        try:
            info = os.stat(current, follow_symlinks=False)
        except OSError:
            return False
        if info.st_uid not in (0, euid):
            return False
        if stat.S_IMODE(info.st_mode) & 0o022:
            return False
        if current == os.sep:
            return True
        parent = os.path.dirname(current)
        if parent == current:
            return True
        current = parent


def attest_interpreter(declared, trust):
    if sys.implementation.name != "cpython":
        fail(INTERPRETER)
    if sys.version_info[:2] not in SUPPORTED_MINORS:
        fail(INTERPRETER)
    if sys.version_info.releaselevel != "final":
        fail(INTERPRETER)
    image = real_executing_image()
    if image is None:
        fail(INTERPRETER)
    declared_real = os.path.realpath(declared)
    if image != declared_real:
        root = framework_root(declared_real)
        if (sys.platform != "darwin" or root is None
                or framework_root(image) != root
                or not os.path.isfile(image)
                or os.path.islink(image)
                or not native_magic(image)):
            fail(INTERPRETER)
    if trust == "discovered":
        if not owner_chain_ok(declared_real) or not owner_chain_ok(image):
            fail(INTERPRETER)
    if sys.prefix != sys.base_prefix:
        fail(INTERPRETER)
    for entry in sys.path:
        base = os.path.basename(entry.rstrip(os.sep))
        if base in ("site-packages", "dist-packages"):
            fail(INTERPRETER)
    if "yaml" in sys.modules:
        fail(INTERPRETER)


def normalize(repo_root):
    vendor = os.path.join(repo_root, VENDOR_REL)
    try:
        parent_fd = os.open(
            vendor,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError:
        fail(ASSET)
    try:
        parent = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid():
            fail(ASSET)
        for name in TARGETS:
            try:
                fd = os.open(
                    name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=parent_fd,
                )
            except OSError:
                fail(ASSET)
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode):
                    fail(ASSET)
                if before.st_uid != os.geteuid():
                    fail(ASSET)
                try:
                    os.fchmod(fd, EXACT_FILE_MODE)
                except OSError:
                    fail(ASSET)
                after = os.fstat(fd)
                if stat.S_IMODE(after.st_mode) != EXACT_FILE_MODE:
                    fail(ASSET)
                if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
                    fail(ASSET)
                try:
                    os.fsync(fd)
                except OSError:
                    pass
            finally:
                os.close(fd)
        try:
            os.fsync(parent_fd)
        except OSError:
            pass
    finally:
        os.close(parent_fd)


declared, trust, repo_root = sys.argv[1:4]
attest_interpreter(declared, trust)
normalize(repo_root)
# Emitted only after every retained-descriptor check on all three files has
# completed. It is a status, not a diagnostic, and never a failure code.
sys.stderr.write("[yaml-runtime] role=normalize action=vendor_modes code=ok\n")
PYEOF

# ── Public entries ───────────────────────────────────────────────────────────

# _yr_prepare <action> — tuple presence + interpreter selection.
_yr_prepare() {
  local action="$1" status=0
  _yr_require_tuple_present || status=$?
  if [ "$status" -ne 0 ]; then
    _yr_report_exit "$action" "$status" || true
    return "$status"
  fi
  _yr_select_interpreter || status=$?
  if [ "$status" -ne 0 ]; then
    _yr_report_exit select_interpreter "$status" || true
    return "$status"
  fi
  return 0
}

# yaml_runtime_run <argv...> — caller program is read from stdin.
yaml_runtime_run() {
  local status=0
  _yr_prepare run_program || return $?
  # Liveness for the caller-program entries. The caller's stdin/stdout/status are
  # theirs by contract, so the token travels through a private file: the
  # bootstrap writes it there immediately before the caller program runs. A
  # binary that exits 0 without touching it -- the no-op override -- can no
  # longer return "success" for a program that never executed, which previously
  # let a dependency gate pass on a dangling reference and made --set-field
  # report a write that was never made.
  # The token travels on an inherited descriptor, never through a path: fd 3
  # is the capture pipe, fd 5 is the caller's real stdout, restored for the
  # program. No temporary file means no symlink target, no TMPDIR to steer,
  # nothing to leak on a signal, and no external command to shim.
  local nonce token=""
  # fd 5 is dup'd from the caller's stdout below. If the caller closed stdout,
  # that dup fails inside bash itself, which then prints its own error -- with
  # this file's absolute path -- on stderr before any typed diagnostic can. So a
  # closed stdout is detected first and refused with the typed code instead.
  # `>&1` on a closed fd 1 is a no-op that succeeds, so the probe performs the
  # exact operation that fails: dup'ing fd 1 onto fd 5. On a failed redirection
  # bash UNDOES the command's own redirections before printing its error, so no
  # `2>/dev/null` on the same command can silence it -- the message would carry
  # this file's path onto the caller's stderr. The dup is therefore attempted in
  # a subshell whose stderr the parent has already discarded.
  if ! ( exec 5>&1 ) 2>/dev/null; then
    _yr_diag run_program yaml_runtime_interpreter_invalid "$_YR_TRUST"
    return 31
  fi
  nonce="$(_yr_nonce)"
  { token="$(GAAI_YAML_LIVENESS_NONCE="$nonce" \
    "$_YR_PY" -I -S -B -c "$_YR_BOOTSTRAP" \
      "$_YR_PY" "$_YR_TRUST" "$_YR_ARCHIVE" "$_YR_MANIFEST" run "$@" 3>&1 1>&5)" || status=$?; } 5>&1
  if [ "$status" -eq 0 ] && [ "$token" != "attest=$nonce" ]; then
    _yr_diag run_program yaml_runtime_interpreter_invalid "$_YR_TRUST"
    return 31
  fi
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  _yr_report_exit run_program "$status" || true
  return "$status"
}

# yaml_runtime_run_c <program> <argv...> — caller stdin stays available for data.
yaml_runtime_run_c() {
  local status=0
  if [ "$#" -lt 1 ]; then
    _yr_diag run_program yaml_runtime_semantic_mismatch
    return 36
  fi
  _yr_prepare run_program || return $?
  # Liveness for the caller-program entries. The caller's stdin/stdout/status are
  # theirs by contract, so the token travels through a private file: the
  # bootstrap writes it there immediately before the caller program runs. A
  # binary that exits 0 without touching it -- the no-op override -- can no
  # longer return "success" for a program that never executed, which previously
  # let a dependency gate pass on a dangling reference and made --set-field
  # report a write that was never made.
  # The token travels on an inherited descriptor, never through a path: fd 3
  # is the capture pipe, fd 5 is the caller's real stdout, restored for the
  # program. No temporary file means no symlink target, no TMPDIR to steer,
  # nothing to leak on a signal, and no external command to shim.
  local nonce token=""
  # fd 5 is dup'd from the caller's stdout below. If the caller closed stdout,
  # that dup fails inside bash itself, which then prints its own error -- with
  # this file's absolute path -- on stderr before any typed diagnostic can. So a
  # closed stdout is detected first and refused with the typed code instead.
  # `>&1` on a closed fd 1 is a no-op that succeeds, so the probe performs the
  # exact operation that fails: dup'ing fd 1 onto fd 5. On a failed redirection
  # bash UNDOES the command's own redirections before printing its error, so no
  # `2>/dev/null` on the same command can silence it -- the message would carry
  # this file's path onto the caller's stderr. The dup is therefore attempted in
  # a subshell whose stderr the parent has already discarded.
  if ! ( exec 5>&1 ) 2>/dev/null; then
    _yr_diag run_program yaml_runtime_interpreter_invalid "$_YR_TRUST"
    return 31
  fi
  nonce="$(_yr_nonce)"
  { token="$(GAAI_YAML_LIVENESS_NONCE="$nonce" \
    "$_YR_PY" -I -S -B -c "$_YR_BOOTSTRAP" \
      "$_YR_PY" "$_YR_TRUST" "$_YR_ARCHIVE" "$_YR_MANIFEST" run_c "$@" 3>&1 1>&5)" || status=$?; } 5>&1
  if [ "$status" -eq 0 ] && [ "$token" != "attest=$nonce" ]; then
    _yr_diag run_program yaml_runtime_interpreter_invalid "$_YR_TRUST"
    return 31
  fi
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  _yr_report_exit run_program "$status" || true
  return "$status"
}

# yaml_runtime_validate_file <path> — fixed safe-load validation program.
yaml_runtime_validate_file() {
  local status=0
  if [ "$#" -ne 1 ]; then
    _yr_diag validate_file yaml_runtime_semantic_mismatch
    return 36
  fi
  _yr_prepare validate_file || return $?
  local nonce token
  nonce="$(_yr_nonce)"
  token="$("$_YR_PY" -I -S -B -c "$_YR_BOOTSTRAP" \
    "$_YR_PY" "$_YR_TRUST" "$_YR_ARCHIVE" "$_YR_MANIFEST" validate "$1" "$nonce" </dev/null 2>/dev/null)" || status=$?
  status="$(_yr_typed_status "$status")"
  if [ "$status" -eq 0 ]; then
    # Same reasoning as verify_tuple: a gate that reports "valid" because a no-op
    # binary exited 0 is a gate that has validated nothing.
    if [ "$token" = "attest=$nonce" ]; then
      return 0
    fi
    _yr_diag validate_file yaml_runtime_interpreter_invalid "$_YR_TRUST"
    return 31
  fi
  _yr_report_exit validate_file "$status" || true
  return "$status"
}

# yaml_runtime_verify_tuple — interpreter + manifest + licence + archive + import.
# Prints "python=<X.Y.Z> trust=<mode> runtime=<version>" on success.
yaml_runtime_verify_tuple() {
  local status=0
  _yr_prepare verify_tuple || return $?
  local nonce line
  nonce="$(_yr_nonce)"
  line="$("$_YR_PY" -I -S -B -c "$_YR_BOOTSTRAP" \
    "$_YR_PY" "$_YR_TRUST" "$_YR_ARCHIVE" "$_YR_MANIFEST" verify "$nonce" </dev/null 2>/dev/null)" || status=$?
  status="$(_yr_typed_status "$status")"
  if [ "$status" -eq 0 ]; then
    # Exit 0 alone proves nothing: any native binary can produce it, so an
    # explicit interpreter override used to make this function report a verified
    # tuple with no parser ever loaded. The bootstrap echoes this token only
    # after the manifest, the archive and the import have all been verified.
    case "$line" in
      "python="*" trust="*" runtime="*" attest=$nonce")
        printf '%s\n' "${line% attest=*}"
        return 0 ;;
    esac
    _yr_diag verify_tuple yaml_runtime_interpreter_invalid "$_YR_TRUST"
    return 31
  fi
  _yr_report_exit verify_tuple "$status" || true
  return "$status"
}

# yaml_runtime_normalize_vendor_modes <repo-root>
# Restrictive-umask repair of exactly the three vendor files in another tree, by
# retained parent/file descriptors, following no symlink. It is a dedicated
# non-YAML operation with its own single process; it can therefore act on the
# very tuple the bootstrap refuses.
yaml_runtime_normalize_vendor_modes() {
  local status=0 role_saved="${YAML_RUNTIME_ROLE:-}"
  YAML_RUNTIME_ROLE=normalize
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    _yr_diag vendor_modes yaml_runtime_asset_invalid
    YAML_RUNTIME_ROLE="$role_saved"
    return 33
  fi
  _yr_select_interpreter || {
    status=$?
    _yr_report_exit vendor_modes "$status" || true
    YAML_RUNTIME_ROLE="$role_saved"
    return "$status"
  }
  "$_YR_PY" -I -S -B -c "$_YR_NORMALIZE" \
    "$_YR_PY" "$_YR_TRUST" "$1" </dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    _yr_report_exit vendor_modes "$status" || true
    YAML_RUNTIME_ROLE="$role_saved"
    return "$status"
  fi
  YAML_RUNTIME_ROLE="$role_saved"
  return 0
}

# yaml_runtime_verify_worktree_tuple <repo-root>
# The worktree-local exact verification of the four tuple paths against that
# tree's own HEAD tree: regular non-symlink file, tree mode 100644, blob equal to
# the tree blob, and exact 0644 on the three vendor files. It parses no YAML and
# needs no interpreter, so it is safe to run before any consumer executes.
#
# Sets YAML_RUNTIME_TUPLE_STATE to "verified" or "absent". A tree that declares
# some but not all four paths is the typed failure; a tree that declares none of
# them (a base predating the tuple) is "absent" with nothing to verify.
yaml_runtime_verify_worktree_tuple() {
  local PATH="$_YR_SAFE_PATH"
  local root="${1:-}" rel entry tree_mode tree_blob local_blob
  local declared=0 missing=0 owner mode verdict=0
  local role_saved="${YAML_RUNTIME_ROLE:-}"
  local IFS=$' \t\n'
  YAML_RUNTIME_ROLE=verify
  YAML_RUNTIME_TUPLE_STATE=""

  local paths="
.gaai/core/scripts/lib/yaml-runtime.sh
.gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz
.gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json
.gaai/core/vendor/pyyaml/6.0.3/LICENSE
"

  if [ -z "$root" ] || [ ! -d "$root" ]; then
    verdict=33
  elif ! git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    verdict=33
  else
    for rel in $paths; do
      # git must be asked whether it succeeded, separately from what it printed
      # (see repair_and_verify): a failing git is the typed asset failure, never
      # "not declared".
      if ! entry="$(git -C "$root" ls-tree HEAD -- "$rel" 2>/dev/null)"; then
        verdict=33
        break
      fi
      if [ -z "$entry" ]; then
        missing=$(( missing + 1 ))
        continue
      fi
      declared=$(( declared + 1 ))
      tree_mode="$(printf '%s\n' "$entry" | awk 'NR==1{print $1}')"
      tree_blob="$(printf '%s\n' "$entry" | awk 'NR==1{print $3}')"
      if [ "$tree_mode" != "100644" ]; then
        verdict=33
        break
      fi
      if [ -L "$root/$rel" ] || [ ! -f "$root/$rel" ]; then
        verdict=33
        break
      fi
      local_blob="$(git -C "$root" hash-object --no-filters -- "$root/$rel" 2>/dev/null)" || local_blob=""
      if [ -z "$local_blob" ] || [ "$local_blob" != "$tree_blob" ]; then
        verdict=33
        break
      fi
      case "$rel" in
        .gaai/core/vendor/pyyaml/6.0.3/*)
          owner=""
          mode=""
          read -r owner mode <<< "$(_yr_stat_owner_mode "$root/$rel")" || true
          if [ -z "$owner" ] || [ "$mode" != "644" ]; then
            verdict=33
            break
          fi
          ;;
      esac
    done
    if [ "$verdict" -eq 0 ]; then
      if [ "$declared" -eq 0 ]; then
        # "absent" is a claim about the working tree too: an untracked tuple on
        # disk is the typed asset failure, exactly as in repair_and_verify.
        for rel in $paths; do
          if [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; then
            verdict=33
            break
          fi
        done
        [ "$verdict" -eq 0 ] && YAML_RUNTIME_TUPLE_STATE="absent"
      elif [ "$missing" -ne 0 ]; then
        verdict=33
      else
        YAML_RUNTIME_TUPLE_STATE="verified"
      fi
    fi
  fi

  YAML_RUNTIME_ROLE=verify
  if [ "$verdict" -ne 0 ]; then
    _yr_diag worktree_tuple yaml_runtime_asset_invalid
  fi
  YAML_RUNTIME_ROLE="$role_saved"
  return "$verdict"
}

# yaml_runtime_repair_and_verify_tree <root>
# The restrictive-umask ordering in one place, so both shell callers implement
# one rule and not two: checkout (or recovery re-creation) -> normalize ->
# worktree-local exact verification -> only then may a consumer execute, an
# admission run, a retry or a spawn proceed.
#
# A tree whose HEAD declares none of the four tuple paths (a base predating the
# tuple) is reported through YAML_RUNTIME_TUPLE_STATE=absent and needs neither
# step; a tree declaring some but not all four is the typed failure.
yaml_runtime_repair_and_verify_tree() {
  local PATH="$_YR_SAFE_PATH"
  local root="${1:-}" declared status=0
  local role_saved="${YAML_RUNTIME_ROLE:-}"
  YAML_RUNTIME_TUPLE_STATE=""
  if [ -z "$root" ] || [ ! -d "$root" ] \
     || ! git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    YAML_RUNTIME_ROLE=verify
    _yr_diag worktree_tuple yaml_runtime_asset_invalid
    YAML_RUNTIME_ROLE="$role_saved"
    return 33
  fi
  # `git` must be asked whether it succeeded, separately from what it printed.
  # Piping straight into `wc -l` reports the pipeline's status, not git's, so a
  # git that failed for any reason -- shimmed, absent, a broken repository --
  # produced zero lines, was read as "this tree declares none of the tuple", and
  # returned 0 with state=absent. Both callers treat that as "base predates the
  # tuple, nothing to verify" and continue, so the git-to-HEAD binding, the only
  # thing tying the vendor bytes to committed content, was skipped silently. An
  # unusable git is now the typed asset failure it always was.
  local tree_entries
  if ! tree_entries="$(git -C "$root" ls-tree HEAD -- \
      .gaai/core/scripts/lib/yaml-runtime.sh \
      .gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz \
      .gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json \
      .gaai/core/vendor/pyyaml/6.0.3/LICENSE 2>/dev/null)"; then
    YAML_RUNTIME_ROLE=verify
    _yr_diag worktree_tuple yaml_runtime_asset_invalid
    YAML_RUNTIME_ROLE="$role_saved"
    return 33
  fi
  if [ -z "$tree_entries" ]; then
    declared=0
  else
    declared="$(printf '%s\n' "$tree_entries" | wc -l | tr -d ' ')"
  fi
  if [ "${declared:-0}" = "0" ]; then
    # HEAD declares none of the tuple. That is only "nothing to verify" if the
    # working tree agrees: an UNTRACKED tuple on disk -- a partial checkout, a
    # downstream install that gitignores .gaai/, a planted archive -- would
    # otherwise be reported absent, skip normalization and verification, and be
    # consumed anyway by both callers, which treat absent as "proceed".
    local on_disk
    for on_disk in .gaai/core/scripts/lib/yaml-runtime.sh \
                   .gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz \
                   .gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json \
                   .gaai/core/vendor/pyyaml/6.0.3/LICENSE; do
      if [ -e "$root/$on_disk" ] || [ -L "$root/$on_disk" ]; then
        YAML_RUNTIME_ROLE=verify
        _yr_diag worktree_tuple yaml_runtime_asset_invalid
        YAML_RUNTIME_ROLE="$role_saved"
        return 33
      fi
    done
    YAML_RUNTIME_TUPLE_STATE="absent"
    return 0
  fi
  yaml_runtime_normalize_vendor_modes "$root" || status=$?
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  yaml_runtime_verify_worktree_tuple "$root" || status=$?
  return "$status"
}

# ── Direct invocation front-end ──────────────────────────────────────────────
# This exists so exactly one governed command string can be quoted verbatim in
# human-facing instructions. Consumer code never uses it.
yaml_runtime_main() {
  case "${1:-}" in
    --validate)
      [ "$#" -eq 2 ] || { printf 'usage: --validate <path>\n' >&2; return 64; }
      yaml_runtime_validate_file "$2"
      ;;
    --verify-tuple)
      [ "$#" -eq 1 ] || { printf 'usage: --verify-tuple\n' >&2; return 64; }
      yaml_runtime_verify_tuple
      ;;
    *)
      printf 'usage: yaml-runtime.sh --validate <path> | --verify-tuple\n' >&2
      return 64
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  yaml_runtime_main "$@"
  exit $?
fi
