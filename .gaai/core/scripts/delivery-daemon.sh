#!/usr/bin/env bash
set -euo pipefail

# Targeted external-merge reconciliation is dispatched before project-root
# discovery, repo-local sources, launcher selection, executor checks, signal
# traps, recovery and the Delivery loop. Until every proof and settlement edge
# succeeds, this entrypoint is fail-closed and has no lifecycle authority.
_gaai_watch_once_result() {
  local sid="$1" reason="$2" fields="${3:-}"
  # Usage errors can be reached before the Story identifier is validated.
  # Never reflect arbitrary argv into the public diagnostic channel: a newline
  # or control-bearing value could forge an additional lifecycle-looking line.
  [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] || sid="invalid"
  if [[ -n "$fields" ]]; then
    printf 'watch_once story=%s outcome=%s fields=%s\n' "$sid" "$reason" "$fields"
  else
    printf 'watch_once story=%s outcome=%s\n' "$sid" "$reason"
  fi
}

_gaai_watch_once_entry() {
  local sid="" state_root="" seen_sid=0 seen_root=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watch-once-story)
        (( seen_sid == 0 )) || { _gaai_watch_once_result "${sid:-invalid}" usage_invalid; return 64; }
        [[ $# -ge 2 && -n "$2" ]] || { _gaai_watch_once_result invalid usage_invalid; return 64; }
        sid="$2"; seen_sid=1; shift 2
        ;;
      --operator-state-root)
        (( seen_root == 0 )) || { _gaai_watch_once_result "${sid:-invalid}" usage_invalid; return 64; }
        [[ $# -ge 2 && -n "$2" ]] || { _gaai_watch_once_result "${sid:-invalid}" usage_invalid; return 64; }
        state_root="$2"; seen_root=1; shift 2
        ;;
      *)
        _gaai_watch_once_result "${sid:-invalid}" usage_invalid
        return 64
        ;;
    esac
  done
  if (( seen_sid != 1 || seen_root != 1 )) \
      || [[ ! "$sid" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] \
      || [[ "$state_root" != /* || "$state_root" == / || "$state_root" == *$'\n'* ]]; then
    _gaai_watch_once_result "${sid:-invalid}" usage_invalid
    return 64
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    _gaai_watch_once_result "$sid" authority_unavailable
    return 4
  fi

  # Python isolation ignores ambient PYTHON* configuration. Every subprocess
  # below receives an allowlisted environment and has stdout/stderr captured.
  # No receipt or GitHub value is ever copied into the public diagnostic.
  python3 -I - "$sid" "$state_root" "$0" "${GAAI_TARGET_BRANCH:-staging}" \
    "${GAAI_WATCH_ONCE_LOCK_TIMEOUT:-60}" "${GAAI_GITHUB_API_TIMEOUT:-30}" <<'PY'
import fcntl, hashlib, json, os, re, shutil, stat, subprocess, sys, tempfile, time
from datetime import datetime
from pathlib import Path

sid, state_arg, entry_arg, target, lock_raw, api_raw = sys.argv[1:]
BACKLOG = '.gaai/project/contexts/backlog/active.backlog.yaml'
POLICY = '.gaai/project/ci/local-admission.json'
SCHEDULER = '.gaai/core/scripts/backlog-scheduler.sh'
CANON = '.gaai/core/scripts/lib/local-admission-executor.mjs'
DAEMON = '.gaai/core/scripts/delivery-daemon.sh'
YAML_BOUNDARY = '.gaai/core/scripts/lib/yaml-runtime.sh'
VENDOR_DIR = '.gaai/core/vendor/pyyaml/6.0.3'
VENDOR_ARCHIVE = VENDOR_DIR + '/pyyaml-runtime.pyz'
VENDOR_MANIFEST = VENDOR_DIR + '/PROVENANCE.json'
VENDOR_LICENCE = VENDOR_DIR + '/LICENSE'
VENDOR_FILES = (VENDOR_ARCHIVE, VENDOR_MANIFEST, VENDOR_LICENCE)
RUNTIME_TUPLE = (YAML_BOUNDARY,) + VENDOR_FILES
EXACT_VENDOR_MODE = 0o644
HEX40 = re.compile(r'^[0-9a-f]{40}$')
HEX64 = re.compile(r'^[0-9a-f]{64}$')
MAX_SAFE_INTEGER = (1 << 53) - 1
RECEIPT_KEYS = {'schema_version','boundary','story_id','candidate','binding_digest',
  'selected_surface_ids','selected_command_ids','results','outcome','publication_admitted',
  'created_at','receipt_digest'}
BINDING_KEYS = {'project_id','repository_digest','base_ref','base_sha','head_sha',
  'normalized_diff_digest','dependency_digest','risk_digest','policy_version','policy_digest',
  'selector_digest','environment_digest','command_digests'}
RESULT_KEYS = {'command_id','descriptor_digest','configuration_digest','outcome','exit_code',
  'signal','duration_ms','stdout_bytes','stderr_bytes','stdout_truncated','stderr_truncated'}
SETTLEMENT_KEYS = {'schema_version','story_id','target_ref','parent_sha','tree_sha','commit_sha',
  'backlog_blob','backlog_bytes_b64','commit_object_b64','story_delta_digest','receipt_digest',
  'pr_tuple_digest','origin_endpoint_digest','settlement_digest'}

class Halt(Exception):
  def __init__(self, rc, reason, fields=''):
    self.rc, self.reason, self.fields = rc, reason, fields

def halt(rc, reason, fields=''):
  raise Halt(rc, reason, fields)

def canonical(value):
  if isinstance(value, list): return '[' + ','.join(canonical(v) for v in value) + ']'
  if isinstance(value, dict):
    return '{' + ','.join(json.dumps(k,ensure_ascii=False,separators=(',',':')) + ':' + canonical(value[k]) for k in sorted(value)) + '}'
  if value is True: return 'true'
  if value is False: return 'false'
  if value is None: return 'null'
  return json.dumps(value,ensure_ascii=False,separators=(',',':'))

def digest(value):
  if isinstance(value,str): value=value.encode()
  return hashlib.sha256(value).hexdigest()

SAFE_ENV = {k:v for k,v in os.environ.items() if not (k.startswith('GIT_') or k.startswith('PYTHON')
  or k in ('GH_DEBUG','NODE_OPTIONS','BASH_ENV','ENV','CDPATH'))}
SAFE_ENV['LC_ALL']='C'; SAFE_ENV['LANG']='C'
SAFE_ENV['GIT_TERMINAL_PROMPT']='0'; SAFE_ENV['GCM_INTERACTIVE']='never'
SAFE_ENV['SSH_ASKPASS_REQUIRE']='never'

# Every Git process in watcher-only mode crosses the same non-interactive,
# no-hook boundary.  Repository/global configuration remains available for
# transport basics, but executable config surfaces are overridden explicitly.
GIT_HARDENED=['git','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null',
  '-c','credential.helper=','-c','credential.helper=!gh auth git-credential',
  '-c','credential.interactive=never','-c','core.askPass=',
  '-c','push.followTags=false','-c','push.gpgSign=false','-c','push.autoSetupRemote=false',
  '-c','remote.origin.mirror=false']

def git_argv(repo,*args):
  return [*GIT_HARDENED,'-C',str(repo),*args]

def command(argv,cwd=None,input_bytes=None,timeout=30,rc=4,env=None):
  try:
    result=subprocess.run(argv,cwd=cwd,input=input_bytes,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
      timeout=timeout,check=False,env=env or SAFE_ENV)
  except (OSError,subprocess.TimeoutExpired): halt(rc,'authority_unavailable')
  if result.returncode: halt(rc,'authority_unavailable')
  return result.stdout

def git(repo,*args,input_bytes=None,timeout=30,rc=4,env=None):
  return command(git_argv(repo,*args),cwd=repo,input_bytes=input_bytes,
    timeout=timeout,rc=rc,env=env).decode().strip()

transport_dir=None
transport_git_dir=None
transport_env=None
bound_endpoint=None

def config_values(repo,key):
  try:
    result=subprocess.run(git_argv(repo,'config','--get-all',key),cwd=repo,stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,timeout=api_timeout,check=False,env=SAFE_ENV)
  except (OSError,subprocess.TimeoutExpired): halt(4,'authority_unavailable')
  if result.returncode==1: return []
  if result.returncode: halt(4,'authority_unavailable')
  try: values=result.stdout.decode().splitlines()
  except UnicodeDecodeError: halt(3,'proof_invalid')
  if not values or any(not value or '\x00' in value or '\n' in value for value in values): halt(3,'proof_invalid')
  return values

def bind_origin(repo):
  fetch_urls=config_values(repo,'remote.origin.url')
  push_urls=config_values(repo,'remote.origin.pushurl')
  if len(fetch_urls)!=1 or len(push_urls)>1: halt(3,'proof_invalid')
  endpoint=fetch_urls[0]
  if push_urls and push_urls[0]!=endpoint: halt(3,'proof_invalid')
  # Bind every local filesystem spelling to one strict physical endpoint.
  # The raw spelling remains receipt/policy authority, while re-resolving the
  # physical endpoint at each effect-edge rebind detects symlink replacement.
  # URI/scp-like spellings stay literal.  file:// is rejected rather than
  # partially parsed, and '~' is never shell-expanded.
  if endpoint.startswith('~') or endpoint.lower().startswith('file://'): halt(3,'proof_invalid')
  is_uri=bool(re.fullmatch(r'[A-Za-z][A-Za-z0-9+.-]*://[^\s]+',endpoint))
  is_scp=bool(re.fullmatch(r'(?:[^@/\s]+@)?[^:/\s]+:[^\s]+',endpoint))
  if is_uri or is_scp: effect_endpoint=endpoint
  else:
    local_path=Path(endpoint) if Path(endpoint).is_absolute() else repo/endpoint
    try: effect_endpoint=str(local_path.resolve(strict=True))
    except OSError: halt(3,'proof_invalid')
  return endpoint,effect_endpoint

def init_transport(repo,state_root):
  global transport_dir,transport_git_dir,transport_env
  transport_dir=Path(tempfile.mkdtemp(prefix='.watch-transport-',dir=state_root/'external-merge-settlements'))
  os.chmod(transport_dir,0o700); transport_git_dir=transport_dir/'transport.git'
  isolated=dict(SAFE_ENV); isolated['GIT_CONFIG_NOSYSTEM']='1'; isolated['GIT_CONFIG_GLOBAL']='/dev/null'
  # Preserve HOME/XDG for the fixed gh credential helper and SSH transport.
  # Git configuration remains isolated independently by the two overrides.
  command([*GIT_HARDENED,'init','--bare',str(transport_git_dir),'--quiet'],cwd=repo,timeout=api_timeout,env=isolated)
  objects=Path(git(repo,'rev-parse','--git-path','objects'))
  if not objects.is_absolute(): objects=(repo/objects).resolve(strict=True)
  else: objects=objects.resolve(strict=True)
  transport_env=dict(isolated); transport_env['GIT_OBJECT_DIRECTORY']=str(objects)

def transport_git(*args,input_bytes=None,timeout=None,rc=4):
  if transport_git_dir is None or transport_env is None: halt(4,'authority_unavailable')
  return command([*GIT_HARDENED,'--git-dir',str(transport_git_dir),*args],cwd=transport_dir,
    input_bytes=input_bytes,timeout=timeout or api_timeout,rc=rc,env=transport_env).decode().strip()

def ensure_commit(repo,oid):
  present=subprocess.run(git_argv(repo,'cat-file','-e',f'{oid}^{{commit}}'),cwd=repo,
    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=api_timeout,check=False,env=SAFE_ENV)
  if present.returncode:
    transport_git('fetch','--upload-pack=git-upload-pack',bound_endpoint,oid,'--quiet',rc=3)
  if git(repo,'cat-file','-t',oid,rc=3)!='commit': halt(3,'proof_invalid')

def secure_dir(path):
  try: st=os.lstat(path)
  except OSError: halt(4,'authority_unavailable')
  if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid!=os.geteuid() or stat.S_IMODE(st.st_mode)!=0o700:
    halt(4,'authority_unavailable')

def secure_state(root):
  secure_dir(root); secure_dir(root/'local-admission-receipts'); secure_dir(root/'external-merge-settlements')

def lock_identity(path,fd):
  try: opened=os.fstat(fd); named=os.lstat(path)
  except OSError: halt(4,'authority_unavailable')
  identity=(opened.st_dev,opened.st_ino,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_nlink)
  named_identity=(named.st_dev,named.st_ino,named.st_uid,stat.S_IMODE(named.st_mode),named.st_nlink)
  if identity!=named_identity or not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(named.st_mode) \
      or opened.st_uid!=os.geteuid() or stat.S_IMODE(opened.st_mode)!=0o600 or opened.st_nlink!=1:
    halt(4,'authority_unavailable')
  return identity

def revalidate_lock(path,fd,identity):
  if lock_identity(path,fd)!=identity: halt(4,'authority_unavailable')

def read_bound(path,max_bytes):
  try:
    before=os.lstat(path)
    fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0))
  except OSError: halt(3,'proof_invalid')
  try:
    opened=os.fstat(fd)
    identity=(opened.st_dev,opened.st_ino,opened.st_size,opened.st_uid,stat.S_IMODE(opened.st_mode),opened.st_mtime_ns)
    if not stat.S_ISREG(opened.st_mode) or (before.st_dev,before.st_ino)!=(opened.st_dev,opened.st_ino) \
        or opened.st_uid!=os.geteuid() or stat.S_IMODE(opened.st_mode)!=0o600 or opened.st_nlink!=1 \
        or opened.st_size<2 or opened.st_size>max_bytes:
      halt(3,'proof_invalid')
    chunks=[]; total=0
    while True:
      part=os.read(fd,min(65536,max_bytes+1-total))
      if not part: break
      chunks.append(part); total+=len(part)
      if total>max_bytes: halt(3,'proof_invalid')
    after=os.fstat(fd); named=os.lstat(path)
    after_id=(after.st_dev,after.st_ino,after.st_size,after.st_uid,stat.S_IMODE(after.st_mode),after.st_mtime_ns)
    if after_id!=identity or (named.st_dev,named.st_ino,named.st_size,named.st_uid,stat.S_IMODE(named.st_mode),named.st_mtime_ns)!=identity:
      halt(3,'proof_invalid')
    return b''.join(chunks),identity
  finally: os.close(fd)

def revalidate_name(path,identity):
  try: st=os.lstat(path)
  except OSError: halt(3,'proof_invalid')
  current=(st.st_dev,st.st_ino,st.st_size,st.st_uid,stat.S_IMODE(st.st_mode),st.st_mtime_ns)
  if current!=identity or not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): halt(3,'proof_invalid')

def parse_time(value):
  if not isinstance(value,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})',value):
    halt(3,'proof_invalid')
  try: parsed=datetime.fromisoformat(value[:-1]+'+00:00' if value.endswith('Z') else value)
  except ValueError: halt(3,'proof_invalid')
  if parsed.tzinfo is None: halt(3,'proof_invalid')
  return parsed

def fetch(repo,endpoint):
  transport_git('fetch','--upload-pack=git-upload-pack',endpoint,
    f'+refs/heads/{target}:refs/heads/{target}','--quiet')
  return transport_git('rev-parse',f'refs/heads/{target}')

def in_progress(repo):
  for marker in ('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','BISECT_LOG','rebase-merge','rebase-apply'):
    marker_path=Path(git(repo,'rev-parse','--git-path',marker))
    if not marker_path.is_absolute(): marker_path=repo/marker_path
    if marker_path.exists(): return True
  return False

def target_blob(repo,revision,rel):
  return command(git_argv(repo,'show',f'{revision}:{rel}'),cwd=repo,timeout=api_timeout,rc=3)

def normalize_vendor_modes(repo):
  # The same narrow, descriptor-bound repair the shell entry performs, inline
  # because a closed program cannot call a shell function. A checkout made under
  # a restrictive umask materializes the three vendor files at 0600, which the
  # runtime boundary refuses on its exact-mode check; this moves exactly those
  # three back to 0644 and touches nothing else. It reads no content and can
  # never mask a swap, a symlink or a wrong owner — each is refused here, and
  # independently by the blob verification that follows.
  try:
    parent_fd=os.open(str(repo/VENDOR_DIR),os.O_RDONLY|getattr(os,'O_DIRECTORY',0)|getattr(os,'O_NOFOLLOW',0))
  except OSError: halt(4,'authority_unavailable')
  try:
    parent=os.fstat(parent_fd)
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.geteuid(): halt(4,'authority_unavailable')
    for name in ('pyyaml-runtime.pyz','PROVENANCE.json','LICENSE'):
      try: fd=os.open(name,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0),dir_fd=parent_fd)
      except OSError: halt(4,'authority_unavailable')
      try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid(): halt(4,'authority_unavailable')
        try: os.fchmod(fd,EXACT_VENDOR_MODE)
        except OSError: halt(4,'authority_unavailable')
        after=os.fstat(fd)
        if stat.S_IMODE(after.st_mode)!=EXACT_VENDOR_MODE \
            or (after.st_dev,after.st_ino)!=(before.st_dev,before.st_ino):
          halt(4,'authority_unavailable')
        try: os.fsync(fd)
        except OSError: pass
      finally: os.close(fd)
    try: os.fsync(parent_fd)
    except OSError: pass
  finally: os.close(parent_fd)

def prove_checkout(repo,endpoint,expected=None):
  remote=fetch(repo,endpoint)
  if expected and remote!=expected: halt(4,'authority_changed')
  if git(repo,'rev-parse','HEAD')!=remote or in_progress(repo) or git(repo,'status','--porcelain=v1','--untracked-files=all'):
    halt(4,'authority_unavailable')
  # A tree predating the vendored runtime declares none of the tuple and needs
  # neither the repair nor the extra verification; one declaring some but not all
  # of it is refused. Normalization runs BEFORE the verification below, so the
  # verification always judges the final on-disk state.
  declared=[rel for rel in RUNTIME_TUPLE if git(repo,'ls-tree','--name-only',remote,'--',rel)]
  if declared and len(declared)!=len(RUNTIME_TUPLE): halt(4,'authority_unavailable')
  if declared: normalize_vendor_modes(repo)
  for rel in (DAEMON,SCHEDULER,CANON)+(RUNTIME_TUPLE if declared else ()):
    path=repo/rel
    try: fs=os.lstat(path)
    except OSError: halt(4,'authority_unavailable')
    row=git(repo,'ls-tree',remote,'--',rel).split()
    if not stat.S_ISREG(fs.st_mode) or stat.S_ISLNK(fs.st_mode) or len(row)<3 or row[1]!='blob' or row[0] not in ('100644','100755'):
      halt(4,'authority_unavailable')
    if bool(fs.st_mode&0o111)!=(row[0]=='100755') or git(repo,'hash-object','--no-filters','--',str(path))!=row[2]:
      halt(4,'authority_unavailable')
    if rel in VENDOR_FILES and stat.S_IMODE(fs.st_mode)!=EXACT_VENDOR_MODE:
      halt(4,'authority_unavailable')
  return remote

def policy_from(repo,revision):
  try: value=json.loads(target_blob(repo,revision,POLICY))
  except Exception: halt(3,'proof_invalid')
  if not isinstance(value,dict) or not isinstance(value.get('repository'),dict) or not isinstance(value.get('limits'),dict):
    halt(3,'proof_invalid')
  return value

def immutable_helpers(repo,revision,state_root):
  # The complete tuple is materialized together, in the same relative shape as
  # the repository, so the boundary's single vendor-resolution rule resolves from
  # the materialized helper with no second candidate. The scheduler moves into
  # that mirrored path for the same reason: it resolves its libraries relative to
  # its own location, so a flat copy would look for a lib/ directory that the
  # mirrored layout does not create there.
  directory=Path(tempfile.mkdtemp(prefix='.watch-once-',dir=state_root/'external-merge-settlements'))
  os.chmod(directory,0o700)
  result={}
  layout=((SCHEDULER,'core/scripts/backlog-scheduler.sh',0o700),
          (CANON,'canonicalizer.mjs',0o600),
          (YAML_BOUNDARY,'core/scripts/lib/yaml-runtime.sh',0o600),
          (VENDOR_ARCHIVE,'core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz',EXACT_VENDOR_MODE),
          (VENDOR_MANIFEST,'core/vendor/pyyaml/6.0.3/PROVENANCE.json',EXACT_VENDOR_MODE),
          (VENDOR_LICENCE,'core/vendor/pyyaml/6.0.3/LICENSE',EXACT_VENDOR_MODE))
  for rel,name,mode in layout:
    data=target_blob(repo,revision,rel); path=directory/name
    if path.parent!=directory:
      path.parent.mkdir(parents=True,exist_ok=True)
      current=path.parent
      while current!=directory:
        os.chmod(current,0o700); current=current.parent
    fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),mode)
    try:
      os.write(fd,data); os.fsync(fd)
      # Mode is applied and re-read on the retained write descriptor, so the mode
      # a caller later trusts is the mode of the object that was written and not
      # of whatever a re-resolved pathname points at.
      os.fchmod(fd,mode)
      info=os.fstat(fd)
      if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode)!=mode or info.st_size!=len(data):
        halt(4,'authority_unavailable')
      os.lseek(fd,0,0)
      if os.read(fd,len(data)+1)!=data: halt(4,'authority_unavailable')
    finally: os.close(fd)
    result[rel]=path
  return directory,result

def cleanup_helper_dir(root):
  # Bounded, post-order, no-symlink-following removal scoped to exactly the
  # mkdtemp root this run created. The mirrored layout introduces
  # subdirectories, so a flat one-level unlink would raise, be swallowed, and
  # leave every settlement directory behind. Entries are classified by lstat and
  # never by which os.walk list they arrived in: followlinks=False stops the walk
  # from descending into a symlinked directory but still reports it as a
  # directory, and a dirnames-means-rmdir assumption reintroduces exactly the
  # swallowed failure this replaces.
  try: info=os.lstat(root)
  except OSError: return
  if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode): return
  if not root.name.startswith('.watch-once-') or root.parent.name!='external-merge-settlements': return
  entries=0
  for current,dirnames,filenames in os.walk(root,topdown=False,followlinks=False):
    if len(Path(current).relative_to(root).parts)>8: raise RuntimeError('settlement depth bound')
    for name in list(dirnames)+list(filenames):
      entries+=1
      if entries>4096: raise RuntimeError('settlement entry bound')
      target=os.path.join(current,name)
      try: child=os.lstat(target)
      except OSError: continue
      if stat.S_ISLNK(child.st_mode) or not stat.S_ISDIR(child.st_mode): os.unlink(target)
      else: os.rmdir(target)
  os.rmdir(root)

def node_canonical(helper,raw):
  code="""import fs from'node:fs';import{pathToFileURL}from'node:url';const m=await import(pathToFileURL(process.argv[2]).href);const r=JSON.parse(fs.readFileSync(0,'utf8'));const d=r.receipt_digest;delete r.receipt_digest;process.stdout.write(m.canonicalJson(r)+'\\n'+d);"""
  # Keep the imported module out of process.argv[1]; its direct-invocation guard
  # uses that slot to decide whether to run its CLI main().
  out=command(['node','--input-type=module','-e',code,'watch-once',str(helper)],input_bytes=raw,timeout=api_timeout,rc=3).decode()
  try: return out.rsplit('\n',1)
  except ValueError: halt(3,'proof_invalid')

def validate_receipt(repo,raw,remote_url,canon_helper):
  try: receipt=json.loads(raw.decode())
  except Exception: halt(3,'proof_invalid')
  if not isinstance(receipt,dict) or set(receipt)!=RECEIPT_KEYS: halt(3,'proof_invalid')
  body,claimed=node_canonical(canon_helper,raw)
  if not HEX64.fullmatch(claimed or '') or digest(body)!=claimed or receipt['receipt_digest']!=claimed \
      or raw!=(canonical(receipt)+'\n').encode(): halt(3,'proof_invalid')
  candidate=receipt.get('candidate')
  if not isinstance(candidate,dict) or set(candidate)!=BINDING_KEYS or receipt['schema_version']!='1.0.0' \
      or receipt['boundary']!='final' or receipt['story_id']!=sid or receipt['outcome']!='pass' \
      or receipt['publication_admitted'] is not True or receipt['binding_digest']!=digest(canonical(candidate)):
    halt(3,'proof_invalid')
  if candidate['base_ref']!=target or not HEX40.fullmatch(candidate['base_sha']) or not HEX40.fullmatch(candidate['head_sha']) \
      or candidate['base_sha']==candidate['head_sha'] or not isinstance(candidate.get('project_id'),str) \
      or not isinstance(candidate.get('policy_version'),str) or not candidate['policy_version'] \
      or candidate['repository_digest']!=digest(remote_url): halt(3,'proof_invalid')
  for key in ('normalized_diff_digest','dependency_digest','risk_digest','policy_digest','selector_digest','environment_digest'):
    if not HEX64.fullmatch(candidate.get(key,'')): halt(3,'proof_invalid')
  commands=candidate.get('command_digests'); surfaces=receipt.get('selected_surface_ids'); selected=receipt.get('selected_command_ids'); results=receipt.get('results')
  if not isinstance(commands,list) or not commands or not all(isinstance(x,list) for x in (surfaces,selected,results)) \
      or not surfaces or not selected \
      or len(surfaces)!=len(set(surfaces)) or len(selected)!=len(set(selected)) \
      or not all(isinstance(x,str) and x for x in surfaces+selected) \
      or any(set(c or {})!={'id','descriptor_digest','configuration_digest'} for c in commands) \
      or any(not isinstance(c.get('id'),str) or not c['id'] or not HEX64.fullmatch(c.get('descriptor_digest','')) \
        or not HEX64.fullmatch(c.get('configuration_digest','')) for c in commands) \
      or selected!=[c['id'] for c in commands] or selected!=[r.get('command_id') for r in results]: halt(3,'proof_invalid')
  for index,result in enumerate(results):
    command_entry=commands[index]
    if set(result or {})!=RESULT_KEYS or result.get('outcome')!='passed' \
        or result.get('command_id')!=command_entry['id'] \
        or result.get('descriptor_digest')!=command_entry['descriptor_digest'] \
        or result.get('configuration_digest')!=command_entry['configuration_digest'] \
        or result.get('exit_code')!=0 or result.get('signal') is not None \
        or not isinstance(result.get('duration_ms'),int) or isinstance(result.get('duration_ms'),bool) \
        or not 0<=result['duration_ms']<=MAX_SAFE_INTEGER \
        or any(not isinstance(result.get(name),int) or isinstance(result.get(name),bool) or result[name]<0 \
          or result[name]>MAX_SAFE_INTEGER for name in ('stdout_bytes','stderr_bytes')) \
        or any(not isinstance(result.get(name),bool) for name in ('stdout_truncated','stderr_truncated')):
      halt(3,'proof_invalid')
  created=parse_time(receipt['created_at']); base=candidate['base_sha']; head=candidate['head_sha']
  base_policy=policy_from(repo,base); configured=base_policy['repository']
  if configured.get('project_id')!=candidate.get('project_id') or configured.get('remote')!=remote_url \
      or configured.get('base_ref')!=target or base_policy.get('policy_version')!=candidate.get('policy_version') \
      or digest(canonical(base_policy))!=candidate['policy_digest']:
    halt(3,'proof_invalid')
  ensure_commit(repo,base); ensure_commit(repo,head)
  git(repo,'merge-base','--is-ancestor',base,head,rc=3)
  return receipt,candidate,claimed,created,base_policy

def story_block(raw):
  try: text=raw.decode()
  except UnicodeDecodeError: halt(3,'proof_invalid')
  starts=list(re.finditer(r'(?m)^\s*- id:\s*["\']?'+re.escape(sid)+r'["\']?\s*$',text))
  if len(starts)!=1: halt(3,'proof_invalid')
  start=starts[0].start(); following=re.search(r'(?m)^\s*- id:\s*',text[starts[0].end():]); end=starts[0].end()+(following.start() if following else len(text)-starts[0].end())
  return text,start,end,text[start:end]

def field(block,name):
  values=re.findall(r'(?m)^\s+'+re.escape(name)+r':\s*(.*?)\s*$',block)
  if len(values)!=1: halt(3,'proof_invalid',name)
  value=values[0].strip()
  if len(value)>=2 and value[0]==value[-1] and value[0] in "'\"": value=value[1:-1]
  return value

def backlog_state(raw):
  block=story_block(raw)[3]
  return {name:field(block,name) for name in ('status','phase_status','pr_status','pr_url','started_at')}

def github(repo_id,pr_url):
  query='url,number,state,createdAt,mergedAt,baseRefName,headRefOid,headRepository,isCrossRepository,mergeCommit'
  try: result=subprocess.run(['gh','pr','view',pr_url,'--repo',repo_id,'--json',query],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=api_timeout,env=SAFE_ENV,check=False)
  except (OSError,subprocess.TimeoutExpired): halt(4,'authority_unavailable')
  if result.returncode: halt(4,'authority_unavailable')
  try: value=json.loads(result.stdout)
  except Exception: halt(3,'proof_invalid')
  return value

def validate_github(repo,value,repo_id,pr_url,candidate,started,receipt_created):
  if value.get('state') in ('OPEN','CLOSED') and not value.get('mergedAt'): halt(2,'not_merged')
  url=re.fullmatch(r'https://github\.com/([^/]+/[^/]+)/pull/([1-9][0-9]*)',pr_url)
  merge=value.get('mergeCommit') or {}; head_repo=value.get('headRepository') or {}
  if not url or url.group(1).lower()!=repo_id.lower() or value.get('url')!=pr_url \
      or value.get('number')!=int(url.group(2)) or value.get('state')!='MERGED' \
      or value.get('baseRefName')!=target or value.get('headRefOid')!=candidate['head_sha'] \
      or value.get('isCrossRepository') is not False or head_repo.get('nameWithOwner','').lower()!=repo_id.lower() \
      or not HEX40.fullmatch(merge.get('oid','')): halt(3,'proof_invalid')
  created=parse_time(value.get('createdAt')); merged=parse_time(value.get('mergedAt'))
  if not (started<=receipt_created<=merged and created<=merged): halt(3,'proof_invalid')
  merge_sha=merge['oid']; parents=git(repo,'show','-s','--format=%P',merge_sha,rc=3).split()
  if parents!=[candidate['base_sha']] or git(repo,'rev-parse',f'{merge_sha}^{{tree}}',rc=3)!=git(repo,'rev-parse',f"{candidate['head_sha']}^{{tree}}",rc=3):
    halt(3,'proof_invalid')
  return merge_sha,canonical({k:value.get(k) for k in ('url','number','state','createdAt','mergedAt','baseRefName','headRefOid','headRepository','isCrossRepository','mergeCommit')})

def decode_b64(value):
  import base64
  if not isinstance(value,str) or not re.fullmatch(r'[A-Za-z0-9+/]*={0,2}',value): halt(3,'proof_invalid')
  try: return base64.b64decode(value,validate=True)
  except Exception: halt(3,'proof_invalid')

def encode_b64(value):
  import base64
  return base64.b64encode(value).decode()

def read_settlement(path):
  raw,identity=read_bound(path,4*1024*1024)
  try: value=json.loads(raw.decode())
  except Exception: halt(3,'proof_invalid')
  if not isinstance(value,dict) or set(value)!=SETTLEMENT_KEYS: halt(3,'proof_invalid')
  claimed=value.get('settlement_digest'); unsigned=dict(value); unsigned.pop('settlement_digest',None)
  if not HEX64.fullmatch(claimed or '') or claimed!=digest(canonical(unsigned)) or raw!=(canonical(value)+'\n').encode():
    halt(3,'proof_invalid')
  for name in ('parent_sha','tree_sha','commit_sha','backlog_blob'):
    if not HEX40.fullmatch(value.get(name,'')): halt(3,'proof_invalid')
  for name in ('story_delta_digest','receipt_digest','pr_tuple_digest'):
    if not HEX64.fullmatch(value.get(name,'')): halt(3,'proof_invalid')
  return value,identity

def install_settlement(path,payload):
  directory=path.parent
  tmp=directory/('.settlement-'+digest(payload+os.urandom(16))[:24])
  flags=os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0)
  fd=os.open(tmp,flags,0o600)
  try:
    view=memoryview(payload); offset=0
    while offset<len(view):
      written=os.write(fd,view[offset:])
      if written<=0: halt(4,'authority_unavailable')
      offset+=written
    os.fsync(fd)
  finally: os.close(fd)
  installed=False
  try:
    os.link(tmp,path,follow_symlinks=False); installed=True
    dirfd=os.open(directory,os.O_RDONLY|getattr(os,'O_DIRECTORY',0))
    try: os.fsync(dirfd)
    finally: os.close(dirfd)
  except FileExistsError: pass
  finally:
    try: os.unlink(tmp)
    except OSError: pass
  return installed

def field_optional(block,name):
  values=re.findall(r'(?m)^\s+'+re.escape(name)+r':\s*(.*?)\s*$',block)
  if len(values)>1: halt(3,'proof_invalid',name)
  if not values: return None
  value=values[0].strip()
  if len(value)>=2 and value[0]==value[-1] and value[0] in "'\"": value=value[1:-1]
  return value

def is_terminal(raw,merged_at,story_digest=None):
  try: block=story_block(raw)[3]
  except Halt: return False
  values={name:field_optional(block,name) for name in ('status','phase_status','pr_status','completed_at')}
  if values!={'status':'done','phase_status':'done','pr_status':'merged','completed_at':merged_at}: return False
  return story_digest is None or digest(block)==story_digest

def validate_projection(before,after,merged_at,story_digest=None):
  old_text,old_start,old_end,old_block=story_block(before)
  new_text,new_start,new_end,new_block=story_block(after)
  if field_optional(old_block,'completed_at') is not None: halt(3,'proof_invalid','completed_at')
  if old_text[:old_start]!=new_text[:new_start] or old_text[old_end:]!=new_text[new_end:]: halt(3,'proof_invalid')
  strip=lambda block: re.sub(r'(?m)^\s+(?:status|phase_status|pr_status|completed_at):.*(?:\n|$)','',block)
  if strip(old_block)!=strip(new_block) or not is_terminal(after,merged_at): halt(3,'proof_invalid')
  projected=digest(new_block)
  if story_digest is not None and projected!=story_digest: halt(3,'proof_invalid')
  return projected

def materialize_objects(repo,settlement,merged_at=None):
  backlog_bytes=decode_b64(settlement['backlog_bytes_b64'])
  commit_object=decode_b64(settlement['commit_object_b64'])
  if merged_at is not None:
    parent_backlog=target_blob(repo,settlement['parent_sha'],BACKLOG)
    validate_projection(parent_backlog,backlog_bytes,merged_at,settlement['story_delta_digest'])
  blob=git(repo,'hash-object','-w','--stdin',input_bytes=backlog_bytes)
  if blob!=settlement['backlog_blob']: halt(3,'proof_invalid')
  with tempfile.TemporaryDirectory(prefix='gaai-watch-index-') as tmp:
    env=dict(SAFE_ENV); env['GIT_INDEX_FILE']=str(Path(tmp)/'index')
    git(repo,'read-tree',settlement['parent_sha'],env=env,rc=3)
    git(repo,'update-index','--add','--cacheinfo','100644',blob,BACKLOG,env=env,rc=3)
    tree=git(repo,'write-tree',env=env,rc=3)
  if tree!=settlement['tree_sha']: halt(3,'proof_invalid')
  commit=git(repo,'hash-object','-t','commit','-w','--stdin',input_bytes=commit_object,rc=3)
  if commit!=settlement['commit_sha']: halt(3,'proof_invalid')
  if git(repo,'show','-s','--format=%P',commit,rc=3)!=settlement['parent_sha'] \
      or git(repo,'rev-parse',f'{commit}^{{tree}}',rc=3)!=tree: halt(3,'proof_invalid')
  if merged_at is not None:
    epoch=int(parse_time(merged_at).timestamp())
    expected=(f'tree {tree}\nparent {settlement["parent_sha"]}\nauthor GAAI Framework <delivery@gaai.local> {epoch} +0000\n'
      f'committer GAAI Framework <delivery@gaai.local> {epoch} +0000\n\nchore({sid}): reconcile external merge\n').encode()
    if commit_object!=expected: halt(3,'proof_invalid')
  changed=git(repo,'diff-tree','--no-commit-id','--name-only','-r',commit,rc=3).splitlines()
  if changed!=[BACKLOG]: halt(3,'proof_invalid')
  return backlog_bytes

def make_settlement(repo,scheduler,parent,before,merged_at,receipt_digest,tuple_digest,endpoint):
  with tempfile.TemporaryDirectory(prefix='gaai-watch-project-') as tmp:
    snapshot=Path(tmp)/'active.backlog.yaml'; snapshot.write_bytes(before)
    for name,value in (('status','done'),('phase_status','done'),('pr_status','merged'),('completed_at',merged_at)):
      command(['/bin/bash',str(scheduler),'--set-field',sid,name,value,str(snapshot)],cwd=repo,timeout=api_timeout,rc=4)
    after=snapshot.read_bytes()
  try: story_delta=validate_projection(before,after,merged_at)
  except Halt: halt(4,'authority_unavailable')
  blob=git(repo,'hash-object','-w','--stdin',input_bytes=after)
  with tempfile.TemporaryDirectory(prefix='gaai-watch-index-') as tmp:
    env=dict(SAFE_ENV); env['GIT_INDEX_FILE']=str(Path(tmp)/'index')
    git(repo,'read-tree',parent,env=env); git(repo,'update-index','--add','--cacheinfo','100644',blob,BACKLOG,env=env)
    tree=git(repo,'write-tree',env=env)
  epoch=int(parse_time(merged_at).timestamp())
  message=f'chore({sid}): reconcile external merge\n'
  raw=(f'tree {tree}\nparent {parent}\nauthor GAAI Framework <delivery@gaai.local> {epoch} +0000\n'
       f'committer GAAI Framework <delivery@gaai.local> {epoch} +0000\n\n{message}').encode()
  commit=git(repo,'hash-object','-t','commit','-w','--stdin',input_bytes=raw)
  settlement={'schema_version':'1.0.0','story_id':sid,'target_ref':target,'parent_sha':parent,
    'tree_sha':tree,'commit_sha':commit,'backlog_blob':blob,'backlog_bytes_b64':encode_b64(after),
    'commit_object_b64':encode_b64(raw),'story_delta_digest':story_delta,
    'receipt_digest':receipt_digest,'pr_tuple_digest':tuple_digest,
    'origin_endpoint_digest':digest(endpoint)}
  settlement['settlement_digest']=digest(canonical(settlement))
  materialize_objects(repo,settlement,merged_at)
  return settlement

def settlement_matches(settlement,receipt_digest,tuple_digest,endpoint):
  return settlement.get('schema_version')=='1.0.0' and settlement.get('story_id')==sid \
    and settlement.get('target_ref')==target and settlement.get('receipt_digest')==receipt_digest \
    and settlement.get('pr_tuple_digest')==tuple_digest \
    and settlement.get('origin_endpoint_digest')==digest(endpoint)

def observe_target(repo,settlement,merged_at,endpoint):
  observed=fetch(repo,endpoint); commit=settlement['commit_sha']
  try: landed=(git(repo,'merge-base','--is-ancestor',commit,observed,rc=4)=='')
  except Halt: landed=False
  if landed:
    target_backlog=target_blob(repo,observed,BACKLOG)
    if not is_terminal(target_backlog,merged_at,settlement['story_delta_digest']): halt(3,'proof_invalid')
    return 0
  return 4

def push_settlement(repo,settlement,merged_at,endpoint):
  # The settlement is already durable before this function is entered.  Always
  # rematerialize its exact objects so a later invocation from a fresh target
  # clone retries the identical commit rather than regenerating ambient state.
  materialize_objects(repo,settlement,merged_at)
  ref=f'refs/heads/{target}'
  argv=[*GIT_HARDENED,'--git-dir',str(transport_git_dir),'push','--no-verify','--porcelain',
    '--receive-pack=git-receive-pack',
    f'--force-with-lease={ref}:{settlement["parent_sha"]}',endpoint,f'{settlement["commit_sha"]}:{ref}']
  try:
    attempted=subprocess.run(argv,cwd=transport_dir,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
      timeout=api_timeout,check=False,env=transport_env)
  except (OSError,subprocess.TimeoutExpired):
    # Once a push was attempted, lack of an authoritative observation is an
    # unknown settlement, never a known failure or success.
    halt(75,'settlement_unknown')
  try:
    observed=observe_target(repo,settlement,merged_at,endpoint)
  except Halt as stopped:
    if stopped.rc==4: halt(75,'settlement_unknown')
    raise
  if observed==0: return
  # A reliable fetch which does not contain the exact generated commit closes
  # the uncertainty.  This covers a rejected lease, rejected push, and a
  # concurrent unrelated target advance without rebasing or rewriting.
  halt(4,'authority_changed')

helper_dir=None
try:
  if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,127}',target) or '..' in target: halt(64,'usage_invalid')
  try: lock_timeout=int(lock_raw); api_timeout=int(api_raw)
  except ValueError: halt(64,'usage_invalid')
  if not 1<=lock_timeout<=3600 or not 1<=api_timeout<=600: halt(64,'usage_invalid')
  entry=Path(entry_arg)
  if entry.is_symlink(): halt(4,'authority_unavailable')
  entry=entry.resolve(strict=True); repo=Path(git(entry.parent,'rev-parse','--show-toplevel')).resolve(strict=True)
  state_input=Path(state_arg)
  try: state_input_stat=os.lstat(state_input)
  except OSError: halt(4,'authority_unavailable')
  if stat.S_ISLNK(state_input_stat.st_mode): halt(64,'usage_invalid')
  state_root=state_input.resolve(strict=True)
  common=os.path.commonpath((str(repo),str(state_root)))
  if common in (str(repo),str(state_root)): halt(64,'usage_invalid')
  secure_state(state_root); bound_remote_url,bound_endpoint=bind_origin(repo); init_transport(repo,state_root)
  outer=prove_checkout(repo,bound_endpoint)
  lock_path=state_root/'.staging.lock'; lock_fd=os.open(lock_path,os.O_RDWR|os.O_CREAT|getattr(os,'O_NOFOLLOW',0),0o600)
  try:
    lock_bound=lock_identity(lock_path,lock_fd)
    deadline=time.monotonic()+lock_timeout
    while True:
      try: fcntl.flock(lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB); break
      except BlockingIOError:
        if time.monotonic()>=deadline: halt(4,'authority_unavailable')
        time.sleep(.05)
    revalidate_lock(lock_path,lock_fd,lock_bound)
    if bind_origin(repo)!=(bound_remote_url,bound_endpoint): halt(3,'proof_invalid')
    current=prove_checkout(repo,bound_endpoint,outer); remote_url=bound_remote_url
    current_policy=policy_from(repo,current); max_bytes=current_policy['limits'].get('max_receipt_bytes')
    if not isinstance(max_bytes,int) or isinstance(max_bytes,bool) or max_bytes<1: halt(3,'proof_invalid')
    helper_dir,helpers=immutable_helpers(repo,current,state_root)
    receipt_path=state_root/'local-admission-receipts'/f'.local-admission-{sid}-final.json'
    receipt_raw,receipt_identity=read_bound(receipt_path,max_bytes)
    receipt,candidate,receipt_digest,receipt_created,base_policy=validate_receipt(repo,receipt_raw,remote_url,helpers[CANON])
    backlog=target_blob(repo,current,BACKLOG); state=backlog_state(backlog)
    pending=(state['status'],state['phase_status'],state['pr_status'])==('in_progress','qa_passed','pending_review')
    terminal=(state['status'],state['phase_status'],state['pr_status'])==('done','done','merged')
    if not pending and not terminal: halt(3,'proof_invalid','status,phase_status,pr_status')
    started=parse_time(state['started_at']); repo_id=base_policy['repository']['project_id']; pr_url=state['pr_url']
    gh1=github(repo_id,pr_url); merge_sha,gh_tuple=validate_github(repo,gh1,repo_id,pr_url,candidate,started,receipt_created)
    git(repo,'merge-base','--is-ancestor',merge_sha,current,rc=3)
    # Effect-edge revalidation binds the retained descriptor read, target-held
    # helpers, backlog bytes and GitHub tuple immediately before settlement.
    if bind_origin(repo)!=(bound_remote_url,bound_endpoint): halt(3,'proof_invalid')
    edge=prove_checkout(repo,bound_endpoint,current); revalidate_name(receipt_path,receipt_identity)
    gh2=github(repo_id,pr_url); merge2,tuple2=validate_github(repo,gh2,repo_id,pr_url,candidate,started,receipt_created)
    if bind_origin(repo)!=(bound_remote_url,bound_endpoint): halt(3,'proof_invalid')
    final_edge=prove_checkout(repo,bound_endpoint,current); edge_backlog=target_blob(repo,final_edge,BACKLOG)
    revalidate_name(receipt_path,receipt_identity)
    revalidate_lock(lock_path,lock_fd,lock_bound)
    if edge!=current or final_edge!=current or edge_backlog!=backlog or merge2!=merge_sha or tuple2!=gh_tuple:
      halt(3,'proof_invalid')

    settlement_path=state_root/'external-merge-settlements'/f'.external-merge-{sid}.json'
    settlement_identity=None
    try: settlement,settlement_identity=read_settlement(settlement_path)
    except Halt as missing:
      if missing.rc!=3 or settlement_path.exists() or settlement_path.is_symlink(): raise
      if not pending: halt(3,'proof_invalid','status,phase_status,pr_status')
      settlement=make_settlement(repo,helpers[SCHEDULER],current,backlog,gh2['mergedAt'],receipt_digest,digest(gh_tuple),bound_endpoint)
      payload=(canonical(settlement)+'\n').encode()
      if install_settlement(settlement_path,payload):
        settlement,settlement_identity=read_settlement(settlement_path)
      else:
        settlement,settlement_identity=read_settlement(settlement_path)

    if not settlement_matches(settlement,receipt_digest,digest(gh_tuple),bound_endpoint) or settlement['story_id']!=sid:
      halt(3,'proof_invalid')
    git(repo,'merge-base','--is-ancestor',merge_sha,settlement['parent_sha'],rc=3)
    revalidate_name(settlement_path,settlement_identity)
    materialize_objects(repo,settlement,gh2['mergedAt'])

    # An already-landed exact settlement is idempotent, including when unrelated
    # later target commits exist.  Otherwise only the exact recorded parent may
    # be retried; no target advance is rebased or regenerated.
    observed=observe_target(repo,settlement,gh2['mergedAt'],bound_endpoint)
    if observed==0:
      print(f'watch_once story={sid} outcome=reconciled fields=status,phase_status,pr_status,completed_at')
      sys.exit(0)
    if bind_origin(repo)!=(bound_remote_url,bound_endpoint): halt(3,'proof_invalid')
    latest=fetch(repo,bound_endpoint)
    if latest!=settlement['parent_sha']: halt(4,'authority_changed')
    revalidate_lock(lock_path,lock_fd,lock_bound)
    if bind_origin(repo)!=(bound_remote_url,bound_endpoint): halt(3,'proof_invalid')
    push_settlement(repo,settlement,gh2['mergedAt'],bound_endpoint)
    print(f'watch_once story={sid} outcome=reconciled fields=status,phase_status,pr_status,completed_at')
    sys.exit(0)
  finally: os.close(lock_fd)
except Halt as stopped:
  suffix=f' fields={stopped.fields}' if stopped.fields else ''
  print(f'watch_once story={sid} outcome={stopped.reason}{suffix}')
  sys.exit(stopped.rc)
except Exception:
  print(f'watch_once story={sid} outcome=authority_unavailable')
  sys.exit(4)
finally:
  if helper_dir:
    # This runs after the exit code is already decided, so it never converts a
    # successful settlement into a failure and never masks an earlier halt — it
    # only makes an incomplete removal observable instead of invisible.
    try:
      cleanup_helper_dir(helper_dir)
    except Exception:
      print(f'watch_once story={sid} outcome=settlement_cleanup_incomplete',file=sys.stderr)
  if transport_dir:
    try: shutil.rmtree(transport_dir)
    except Exception: pass
PY
}

_gaai_watch_requested=false
for _gaai_arg in "$@"; do
  case "$_gaai_arg" in
    --watch-once-story|--operator-state-root) _gaai_watch_requested=true ;;
  esac
done
if $_gaai_watch_requested; then
  _gaai_watch_rc=0
  _gaai_watch_once_entry "$@" || _gaai_watch_rc=$?
  exit "$_gaai_watch_rc"
fi

# ═══════════════════════════════════════════════════════════════════════════
# GAAI Delivery Daemon — Autonomous story delivery loop
# ═══════════════════════════════════════════════════════════════════════════
#
# Description:
#   Polls the active backlog on the staging branch and auto-launches Claude
#   Code delivery sessions for stories that are ready (status: refined, all
#   dependencies done). Prevents double-launching via git-committed
#   in_progress status + PID-based lock files + retry tracking.
#
# Branch model:
#   staging    ←── AI works here (read backlog, create worktrees, merge, push)
#   production ←── Human only. Promote via GitHub PR: staging → production.
#   The AI NEVER interacts with the production branch.
#
# Cross-device coordination:
#   Before launching, the daemon commits status: in_progress to staging and
#   pushes. Other daemons (on other VPS or Mac) see the update via git fetch.
#   PID-based lock files are a local-only backup for same-machine dedup.
#
# Permissions:
#   --dangerously-skip-permissions is always enabled (required for -p mode).
#   Without it, permission prompts hang forever in headless mode.
#   Override with GAAI_SKIP_PERMISSIONS=false to force interactive (not recommended).
#
# Usage:
#   .gaai/core/scripts/delivery-daemon.sh                     # defaults: 30s, 3 slots
#   .gaai/core/scripts/delivery-daemon.sh --interval 15       # poll every 15s
#   .gaai/core/scripts/delivery-daemon.sh --max-concurrent 2  # parallel deliveries
#   .gaai/core/scripts/delivery-daemon.sh --dry-run           # show what would launch
#   .gaai/core/scripts/delivery-daemon.sh --status            # show active/ready/exceeded
#   .gaai/core/scripts/delivery-daemon.sh --exit-when-idle    # auto-stop after 5 idle polls
#   .gaai/core/scripts/delivery-daemon.sh --exit-when-idle 10 # auto-stop after 10 idle polls
#
# Environment overrides:
#   GAAI_POLL_INTERVAL=15            poll every 15s
#   GAAI_MAX_CONCURRENT=2            allow 2 parallel deliveries
#   GAAI_EXIT_WHEN_IDLE=5            auto-stop after N consecutive idle polls (0 = disabled)
#   GAAI_COMMIT_PHASE_RETRY_THRESHOLD=3
#                                    identical outcome/content cycles before operator stall;
#                                    cost containment only, never a Story-quality verdict
#   GAAI_TARGET_BRANCH=staging       target branch (default: staging)
#   GAAI_DELIVERY_TIMEOUT=14400      hard kill timeout in seconds (default: 4h, last resort)
#   GAAI_MAX_TURNS=200               max claude tool-call turns per delivery (primary safety)
#   GAAI_HEARTBEAT_STALE=900         seconds without log output before killing (default: 15min)
#   GAAI_CLAUDE_MODEL=sonnet         claude model to use (default: sonnet)
#   GAAI_STALENESS_THRESHOLD=15000   seconds before orphan in_progress is stale (default: timeout+10min)
#   GAAI_SKIP_PERMISSIONS=true       force --dangerously-skip-permissions
#   GAAI_SKIP_PERMISSIONS=false      force interactive mode (even on VPS)
#   GAAI_NOTIFICATION_WEBHOOK=<url>  Optional operator-supplied endpoint that receives
#                                    escalation/resolution notifications. Unset = notifications
#                                    off; no default destination is shipped.
#   GAAI_DAEMON_WEBHOOK_SECRET=<hex> Optional operator-supplied HMAC-SHA256 secret for signing
#                                    outgoing webhook POSTs. Generate: openssl rand -hex 32
#                                    The receiver configures the same secret and verifies the
#                                    request via the X-Hub-Signature-256: sha256=<hex> header
#                                    over the raw request body, comparing in constant time
#                                    (e.g. crypto.timingSafeEqual, never a plain ==).
#                                    When unset, POSTs are sent unsigned; acceptance of an
#                                    unsigned request is the receiver's own policy.
#                                    Notifications are advisory only — they are never phase,
#                                    acceptance, merge or retry authority.
#
# Session env (DEC-75 §6 — injected into every spawned claude -p subprocess):
#   GAAI_WORKSPACE_ID=<uuid>         workspace UUIDv4; if unset at daemon start, read from
#                                    .gaai/local/workspace-preference.json hint file (E99S11)
#   GAAI_ORG_ID=<uuid>               org UUIDv4; same fallback as GAAI_WORKSPACE_ID
#   GAAI_CLAUDE_PROXY_BASE_URL=<url> daemon-scoped Claude CLI transport proxy.
#                                    When set, daemon-launched claude -p receives
#                                    ANTHROPIC_BASE_URL with this value.
#   GAAI_IMPL_BASE_URL=<url>         secondary impl provider base URL (DEC-72)
#   GAAI_IMPL_AUTH_TOKEN=<token>     secondary impl provider auth token (DEC-72)
#   GAAI_IMPL_MODEL=<model>          secondary impl provider model name (DEC-72)
#   Subprocess fallback: if env unresolved after hint read, E99S05 AC5 surfaces
#   "session binding unresolved" to the user (daemon itself never aborts — AC5).
#
# Requirements:
#   - python3 (macOS built-in, or apt install python3 on VPS)
#   - claude CLI in PATH
#   - Terminal.app (macOS) or tmux (VPS/headless)
#   - gtimeout (macOS: brew install coreutils) — optional; preferred dispatch
#     wall-clock timeout; falls back to BSD timeout, then MAX_TURNS + heartbeat watchdog.
#
# VPS setup:
#   git clone <repo> && cd <repo>
#   git checkout staging
#   git config core.hooksPath .githooks     # activate pre-push hook
#   npm install                              # dependencies
#   .gaai/core/scripts/daemon-setup.sh       # privileged direct entry: prerequisites,
#                                            # daemon home, secrets file
#
# Required: suppress the --dangerously-skip-permissions warning dialog:
#   mkdir -p ~/.claude && cat > ~/.claude/settings.json << 'EOF'
#   { "skipDangerousModePermissionPrompt": true }
#   EOF
#
# Run daemon:
#   tmux new-session -d -s gaai-daemon '.gaai/core/scripts/delivery-daemon.sh --max-concurrent 3'
#   tmux attach -t gaai-daemon
#
# Observability:
#   .gaai/core/scripts/delivery-daemon.sh --status
#   tail -f .gaai/project/contexts/backlog/.delivery-logs/E06S11.log
#   tmux attach -t gaai-deliver-E06S11
#   tmux ls | grep gaai-deliver
#
# Promote to production (from GitHub):
#   Create PR: staging → production
#   Review changes, merge, GitHub Actions deploys
#
# Exit codes:
#   0 — clean shutdown (Ctrl+C)
#   1 — missing dependency or config error
# ═══════════════════════════════════════════════════════════════════════════

# ── Resolve project root + auto-detect core/project layout ────────────
#
# The supported production entry executes an ALREADY-BOUND descriptor
# (`daemon-start.sh` binds fd 9 to the verified home asset and execs it), so `$0`
# is that descriptor's command-file name — `/dev/fd/9`, or `/proc/self/fd/9`
# where the platform provides it — and NEVER a filesystem location beside this
# program's Framework libraries. Deriving the asset root from `$0` there yields
# `/dev/fd` and no library resolves. The asset root is therefore the home the
# launcher already admitted and exported, taken only AFTER the inherited launch
# evidence has been checked below as data.
#
# What this gate does not do: it never execs, sources or rereads the main daemon
# by its home pathname, never provisions or repairs anything, and never relaxes
# the launch-tuple validation performed at the ready acknowledgement further
# down — it runs earlier, so that no library from an unproven home can execute
# before the authority that selected it has been proven.
_gaai_boot_refuse() {
  printf 'ERROR: daemon bootstrap invalid — reason=process_authority_invalid action=operator_disposition_required evidence=%s\n' \
    "$1" >&2
  exit 1
}

# Launch records are read as DATA. Never `source`/`eval` here: these bytes come
# from a home whose authority is exactly what is still being established.
_gaai_boot_field() {
  [[ -r "$1" ]] || return 1
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1
}

# The launcher's own platform rule for a bound descriptor, applied here to the
# descriptor this process inherited: through a /proc magic link the node resolves
# to the open description's file, so inode AND device must match the home asset;
# through Darwin's fdesc /dev/fd node stat(2) reports the bound file's inode but
# fdesc's OWN device, so the device is not comparable there by construction.
_gaai_boot_fd_identity_matches() {
  local _fd_path="$1" _f_ino="$2" _f_dev="$3" _p_ino="$4" _p_dev="$5"
  [[ "$_f_ino" == "$_p_ino" ]] || return 1
  case "$_fd_path" in
    /proc/*) [[ "$_f_dev" == "$_p_dev" ]] || return 1 ;;
    *)       [[ "$(uname -s)" == "Darwin" ]] || { [[ "$_f_dev" == "$_p_dev" ]] || return 1; } ;;
  esac
  return 0
}

_gaai_boot_fd=0
case "$0" in
  /dev/fd/9|/proc/self/fd/9) _gaai_boot_fd=1 ;;
  # Any other descriptor spelling is not the launcher's, so no launch authority
  # can be derived from it.
  /dev/fd/*|/proc/self/fd/*|/proc/[0-9]*/fd/*) _gaai_boot_refuse "daemon_role=descriptor_unsupported" ;;
esac

if [[ "$_gaai_boot_fd" -eq 1 ]]; then
  _gaai_boot_attempt_dir="${GAAI_DAEMON_LAUNCH_ATTEMPT:-}"
  _gaai_boot_home="${GAAI_DAEMON_HOME:-}"
  [[ -n "$_gaai_boot_attempt_dir" ]] || _gaai_boot_refuse "launch_role=authority_absent"
  [[ -d "$_gaai_boot_attempt_dir" ]] || _gaai_boot_refuse "launch_role=attempt_dir_absent"
  [[ -n "$_gaai_boot_home" ]] || _gaai_boot_refuse "home_role=absent"
  [[ "$_gaai_boot_home" == /* && "$_gaai_boot_home" != "/" && "$_gaai_boot_home" != *$'\n'* ]] \
    || _gaai_boot_refuse "home_role=malformed"
  [[ -d "$_gaai_boot_home" ]] || _gaai_boot_refuse "home_role=absent"
  # A descriptor that cannot even be stat'd is not evidence of anything. Nothing
  # here READS it: this program's own bytes are being read from that same open
  # description, and consuming its offset would truncate the running image.
  [[ -r "$0" ]] || _gaai_boot_refuse "daemon_role=descriptor_unreadable"

  _gaai_boot_manifest="$_gaai_boot_attempt_dir/manifest"
  _gaai_boot_ack="$_gaai_boot_attempt_dir/ack.launcher"
  [[ -r "$_gaai_boot_manifest" ]] || _gaai_boot_refuse "launch_role=manifest_absent"
  [[ -r "$_gaai_boot_ack" ]] || _gaai_boot_refuse "launch_role=ack_launcher_absent"

  _gaai_boot_m_schema="$(_gaai_boot_field "$_gaai_boot_manifest" schema || echo "")"
  _gaai_boot_m_attempt="$(_gaai_boot_field "$_gaai_boot_manifest" attempt || echo "")"
  _gaai_boot_m_home="$(_gaai_boot_field "$_gaai_boot_manifest" home || echo "")"
  _gaai_boot_m_sha="$(_gaai_boot_field "$_gaai_boot_manifest" target_sha || echo "")"
  _gaai_boot_m_digest="$(_gaai_boot_field "$_gaai_boot_manifest" daemon_digest || echo "")"
  _gaai_boot_a_schema="$(_gaai_boot_field "$_gaai_boot_ack" schema || echo "")"
  _gaai_boot_a_attempt="$(_gaai_boot_field "$_gaai_boot_ack" attempt || echo "")"
  _gaai_boot_a_pid="$(_gaai_boot_field "$_gaai_boot_ack" pid || echo "")"
  _gaai_boot_a_inc="$(_gaai_boot_field "$_gaai_boot_ack" incarnation || echo "")"
  _gaai_boot_a_ino="$(_gaai_boot_field "$_gaai_boot_ack" daemon_ino || echo "")"
  _gaai_boot_a_digest="$(_gaai_boot_field "$_gaai_boot_ack" daemon_digest || echo "")"

  # The two existing records must agree with each other AND carry the existing
  # canonical lifecycle schema. Agreement alone is not authority: an unproven tree
  # supplies both records, so it can make any value agree with itself. The
  # canonical value cannot be read from that tree either — `lib/daemon-home.sh` is
  # exactly the library this gate exists to keep from executing — so the constant
  # is restated here and pinned to `GAAI_HOME_SCHEMA` by a regression assertion in
  # daemon-asset-home.test.sh. This introduces no new schema and does not weaken
  # the identical check the ready acknowledgement still performs below.
  _gaai_boot_schema="gaai-daemon-lifecycle/v1"
  [[ -n "$_gaai_boot_m_schema" && "$_gaai_boot_m_schema" == "$_gaai_boot_a_schema" ]] \
    || _gaai_boot_refuse "launch_role=schema_disagreement"
  [[ "$_gaai_boot_m_schema" == "$_gaai_boot_schema" ]] \
    || _gaai_boot_refuse "launch_role=manifest_schema_mismatch"
  [[ -n "$_gaai_boot_m_attempt" && "$_gaai_boot_m_attempt" == "$_gaai_boot_a_attempt" ]] \
    || _gaai_boot_refuse "launch_role=attempt_disagreement"
  [[ "$_gaai_boot_attempt_dir" == *"/$_gaai_boot_m_attempt" ]] \
    || _gaai_boot_refuse "launch_role=attempt_path_mismatch"
  [[ -n "$_gaai_boot_m_home" && "$_gaai_boot_m_home" == "$_gaai_boot_home" ]] \
    || _gaai_boot_refuse "home_role=identity_mismatch"
  [[ -n "$_gaai_boot_m_sha" && "$_gaai_boot_m_sha" == "${GAAI_TARGET_SHA:-}" ]] \
    || _gaai_boot_refuse "launch_role=target_disagreement"
  [[ -n "$_gaai_boot_m_digest" && "$_gaai_boot_m_digest" == "$_gaai_boot_a_digest" ]] \
    || _gaai_boot_refuse "daemon_role=digest_disagreement"
  # `exec` preserved the PID across the launcher, so this is an identity the
  # daemon can check rather than infer.
  [[ -n "$_gaai_boot_a_pid" && "$_gaai_boot_a_pid" == "$$" \
     && "$_gaai_boot_a_pid" == "${GAAI_DAEMON_LAUNCH_PID:-}" ]] \
    || _gaai_boot_refuse "launch_role=pid_identity_mismatch"
  # The incarnation is REQUIRED evidence here, not an optional refinement. The
  # launcher refuses to bind at all without a provable incarnation, writes it to
  # the acknowledgement and exports it immediately before its exec, so a
  # supported launch always carries both. Treating an absent value as agreement
  # would let a tuple with no process-identity evidence reach the first
  # repository source, which is exactly what this gate exists to prevent: both
  # must be present and equal.
  [[ -n "$_gaai_boot_a_inc" \
     && "$_gaai_boot_a_inc" == "${GAAI_DAEMON_LAUNCH_INCARNATION:-}" ]] \
    || _gaai_boot_refuse "launch_role=incarnation_mismatch"

  # The inherited descriptor must be the daemon asset OF THAT ADMITTED HOME. A
  # matching basename, an existing directory or an environment value is not
  # admission: the proof is the descriptor's own identity against the home path
  # the launcher acknowledged binding.
  _gaai_boot_asset="$_gaai_boot_home/.gaai/core/scripts/delivery-daemon.sh"
  [[ -L "$_gaai_boot_asset" ]] && _gaai_boot_refuse "daemon_role=symlink"
  [[ -f "$_gaai_boot_asset" ]] || _gaai_boot_refuse "daemon_role=absent"
  _gaai_boot_stat_field() {
    local _fmt="$1" _path="$2" _out
    case "$_fmt" in
      '%i') _out="$(stat -L -c '%i' "$_path" 2>/dev/null || stat -L -f '%i' "$_path" 2>/dev/null || echo "")" ;;
      '%d') _out="$(stat -L -c '%d' "$_path" 2>/dev/null || stat -L -f '%d' "$_path" 2>/dev/null || echo "")" ;;
      *)    return 1 ;;
    esac
    [[ -n "$_out" ]] || return 1
    printf '%s' "$_out"
  }
  _gaai_boot_p_ino="$(_gaai_boot_stat_field '%i' "$_gaai_boot_asset")" \
    || _gaai_boot_refuse "daemon_role=stat_unavailable"
  _gaai_boot_p_dev="$(_gaai_boot_stat_field '%d' "$_gaai_boot_asset")" \
    || _gaai_boot_refuse "daemon_role=stat_unavailable"
  _gaai_boot_f_ino="$(_gaai_boot_stat_field '%i' "$0")" \
    || _gaai_boot_refuse "daemon_role=fd_stat_unavailable"
  _gaai_boot_f_dev="$(_gaai_boot_stat_field '%d' "$0")" \
    || _gaai_boot_refuse "daemon_role=fd_stat_unavailable"
  _gaai_boot_fd_identity_matches "$0" \
    "$_gaai_boot_f_ino" "$_gaai_boot_f_dev" "$_gaai_boot_p_ino" "$_gaai_boot_p_dev" \
    || _gaai_boot_refuse "daemon_role=fd_identity_mismatch"
  [[ -n "$_gaai_boot_a_ino" && "$_gaai_boot_a_ino" == "$_gaai_boot_f_ino" ]] \
    || _gaai_boot_refuse "daemon_role=fd_identity_unacknowledged"

  # Admitted. The home selected for a descriptor launch has NO fallback to the
  # operator checkout.
  SCRIPT_DIR="$(cd "$_gaai_boot_home/.gaai/core/scripts" 2>/dev/null && pwd)" \
    || _gaai_boot_refuse "home_role=scripts_root_unresolvable"
  unset -f _gaai_boot_stat_field
  unset -v _gaai_boot_attempt_dir _gaai_boot_home _gaai_boot_manifest _gaai_boot_ack \
           _gaai_boot_m_schema _gaai_boot_m_attempt _gaai_boot_m_home _gaai_boot_m_sha \
           _gaai_boot_m_digest _gaai_boot_a_schema _gaai_boot_a_attempt _gaai_boot_a_pid \
           _gaai_boot_a_inc _gaai_boot_a_ino _gaai_boot_a_digest _gaai_boot_asset \
           _gaai_boot_p_ino _gaai_boot_p_dev _gaai_boot_f_ino _gaai_boot_f_dev \
           _gaai_boot_schema
else
  # Pathname invocation — the supported diagnostic/test compatibility path, which
  # carries no lifecycle authority. A pathname entry that CLAIMS a launch is
  # refused rather than admitted as an alternative lifecycle entry.
  [[ -z "${GAAI_DAEMON_LAUNCH_ATTEMPT:-}" ]] || _gaai_boot_refuse "daemon_role=descriptor_required"
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
unset -f _gaai_boot_refuse _gaai_boot_field _gaai_boot_fd_identity_matches
unset -v _gaai_boot_fd
GAAI_CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$GAAI_CORE_DIR/../.." && pwd)"
# Real repo root — paths that must stay anchored to the operator's main checkout
# (per-story worktree-base derivation, realpath safety guard).
# Defaults to PROJECT_DIR; override with GAAI_REPO_ROOT for future flexibility.
# Coordination git-ops and asset reads stay on PROJECT_DIR and are redirected
# separately when the daemon coordination home is provisioned.
REPO_ROOT="${GAAI_REPO_ROOT:-${PROJECT_DIR}}"
# Redirect coordination git-ops and asset reads to the daemon home worktree when
# provisioned (coordination-git-home axis). REPO_ROOT stays anchored to the original
# PROJECT_DIR (the real repo checkout) for per-story worktree-base derivation and the
# realpath safety guard. GAAI_PROJECT_DIR (derived from GAAI_CORE_DIR / SCRIPT_DIR below,
# not PROJECT_DIR) is unaffected — LOCK_DIR/LOG_DIR/LOG_FILE stay on the operator's
# checkout intentionally (daemon state files live where the monitor reads them).
PROJECT_DIR="${GAAI_DAEMON_HOME:-$PROJECT_DIR}"

# Auto-detect project directory (v2.x core/project split vs v1.x flat)
if [[ -d "$GAAI_CORE_DIR/../project" ]]; then
  GAAI_PROJECT_DIR="$GAAI_CORE_DIR/../project"
else
  GAAI_PROJECT_DIR="$GAAI_CORE_DIR/contexts"  # backwards compat v1.x
fi

# ── Configuration ─────────────────────────────────────────────────────────
POLL_INTERVAL="${GAAI_POLL_INTERVAL:-30}"
MAX_CONCURRENT="${GAAI_MAX_CONCURRENT:-3}"
TARGET_BRANCH="${GAAI_TARGET_BRANCH:-staging}"
# Auto-stop when fully idle (no ready stories + zero in-flight deliveries) for
# this many consecutive polls. 0 = disabled (default ; daemon polls forever).
# Set via --exit-when-idle [N] CLI flag or GAAI_EXIT_WHEN_IDLE env var.
EXIT_WHEN_IDLE_THRESHOLD="${GAAI_EXIT_WHEN_IDLE:-0}"
# Three identical observations allow two transient rechecks while bounding the
# hosted-cost loop. Operators may tune containment; this is not a quality gate.
COMMIT_PHASE_RETRY_THRESHOLD="${GAAI_COMMIT_PHASE_RETRY_THRESHOLD:-3}"
if [[ ! "$COMMIT_PHASE_RETRY_THRESHOLD" =~ ^[1-9][0-9]*$ ]]; then
  COMMIT_PHASE_RETRY_THRESHOLD=3
fi
(( COMMIT_PHASE_RETRY_THRESHOLD > 1000 )) && COMMIT_PHASE_RETRY_THRESHOLD=1000
DELIVERY_TIMEOUT="${GAAI_DELIVERY_TIMEOUT:-14400}"   # 4h hard kill (last resort)
MAX_TURNS="${GAAI_MAX_TURNS:-200}"                    # primary safety net
CLAUDE_MODEL="${GAAI_CLAUDE_MODEL:-sonnet}"           # model (sonnet = cost-effective)
HEARTBEAT_STALE="${GAAI_HEARTBEAT_STALE:-1800}"       # 30min no output = stuck (allows long MCP calls like deep research)
STALENESS_THRESHOLD="${GAAI_STALENESS_THRESHOLD:-}"   # auto-computed below
# Default 1200s (20min). The log-mtime detector only monitors the plan/impl/qa
# phase logs; during the COMMIT phase (a wrapper resumed at qa_passed) all three
# are frozen at their last-phase mtime while the deterministic differential
# test-gate runs the affected suite twice (HEAD + detached baseline). For a
# large suite that quiet stretch exceeds the old 480s, so the detector fired a
# false "hang" mid-gate and SIGKILLed the wrapper every 8min — an unkillable
# re-launch loop for any story whose commit-phase test-gate runs long. 1200s
# covers the double-run with margin; genuine "alive but stuck" agents are still
# caught here (and a fully-dead agent by the 1800s heartbeat-stale detector).
# The precise fix (a commit-phase liveness signal the detector can see) is a
# tracked follow-up; this raises the blanket bound to stop the loop safely.
AGENT_HANG_THRESHOLD_SEC="${GAAI_AGENT_HANG_THRESHOLD_SEC:-1200}"
if (( AGENT_HANG_THRESHOLD_SEC < 60 )); then AGENT_HANG_THRESHOLD_SEC=60; fi
# Suspend/resume robustness: a poll cycle whose wall-clock gap exceeds this is
# treated as a host suspend (or daemon pause), not a normal tick. Liveness
# detectors (heartbeat staleness, agent-activity staleness) measure
# now-minus-mtime in wall-clock seconds; after a long suspend those ages are
# inflated by the suspend duration, not by real inactivity, so killing on them
# is a false positive. On a detected jump the daemon grants a grace window
# during which both detectors stand down, letting wrappers prove liveness again.
SUSPEND_JUMP_THRESHOLD_SEC="${GAAI_SUSPEND_JUMP_THRESHOLD_SEC:-300}"
if (( SUSPEND_JUMP_THRESHOLD_SEC < 120 )); then SUSPEND_JUMP_THRESHOLD_SEC=120; fi
POST_RESUME_GRACE_SEC="${GAAI_POST_RESUME_GRACE_SEC:-$AGENT_HANG_THRESHOLD_SEC}"
# Epoch until which liveness kills are suppressed after a detected time jump.
# Updated by the main loop; read by check_heartbeats + check_agent_activity_stale.
SUSPEND_GRACE_UNTIL=0
RECOVERY_SCAN_INTERVAL="${GAAI_RECOVERY_SCAN_INTERVAL:-$(( POLL_INTERVAL * 10 ))}"
ORPHAN_SCAN_INTERVAL_TICKS="${GAAI_ORPHAN_SCAN_INTERVAL_TICKS:-10}"
ORPHAN_SCAN_MAX_DURATION_SEC="${GAAI_ORPHAN_SCAN_MAX_DURATION_SEC:-30}"
DRY_RUN=false
STATUS_MODE=false

BACKLOG_REL=".gaai/project/contexts/backlog/active.backlog.yaml"
BACKLOG="$PROJECT_DIR/$BACKLOG_REL"
BACKLOG_FILE="$BACKLOG"   # alias for daemon-dispatch.sh library (E134S02)
SCHEDULER="$SCRIPT_DIR/backlog-scheduler.sh"
# Operator-facing daemon state (logs / locks / retry / drift markers) resolves to the
# operator's REAL checkout (GAAI_REPO_ROOT), NOT the GAAI_DAEMON_HOME the daemon binary
# may run from (the dedicated daemon home worktree). This keeps the monitor + `--logs` working (they read
# the operator checkout) and the state surviving the home's per-cycle reset --hard.
# Falls back to GAAI_PROJECT_DIR when GAAI_REPO_ROOT is unset (no-home / direct run) — no
# behavior change in that case. Note: BACKLOG (above) deliberately stays on PROJECT_DIR
# (the home) — it is coordination/committed state, not operator-facing ephemeral state.
_STATE_PROJECT_DIR="${GAAI_REPO_ROOT:+$GAAI_REPO_ROOT/.gaai/project}"
_STATE_PROJECT_DIR="${_STATE_PROJECT_DIR:-$GAAI_PROJECT_DIR}"
LOCK_DIR="$_STATE_PROJECT_DIR/contexts/backlog/.delivery-locks"
DRIFT_MARKER="$LOCK_DIR/.drift-detected.audit"
REBASE_CONFLICT_MARKER="$LOCK_DIR/.rebase-conflict.audit"
AGENT_HANG_AUDIT="$LOCK_DIR/.agent-hang.audit"
CRASH_DRIFT_RECONCILE_AUDIT="$LOCK_DIR/.crash-drift-reconcile.audit"
LOG_DIR="$_STATE_PROJECT_DIR/contexts/backlog/.delivery-logs"
STAGING_LOCK="$LOCK_DIR/.staging.lock"
RETRY_FILE="$LOCK_DIR/.retry-counts"
RESOLUTION_TRACKING="$LOCK_DIR/.resolution-tracking"
LOG_FILE="$_STATE_PROJECT_DIR/contexts/backlog/.delivery-daemon.log"
MAX_RETRIES=3

# Source chore-commit helper (Option B' flock+yq — E134S16)
# shellcheck source=lib/chore-commit.sh
BACKLOG_FILE="$BACKLOG"
source "$SCRIPT_DIR/lib/chore-commit.sh"
# shellcheck source=lib/backlog-yaml.sh
[[ -z "${_BACKLOG_YAML_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/backlog-yaml.sh" && _BACKLOG_YAML_SH_SOURCED=1
# shellcheck source=lib/worktree-integrity.sh
[[ -z "${_WORKTREE_INTEGRITY_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/worktree-integrity.sh" && _WORKTREE_INTEGRITY_SH_SOURCED=1
# shellcheck source=lib/yaml-runtime.sh
[[ -z "${_YAML_RUNTIME_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/yaml-runtime.sh"
if ! declare -F yaml_runtime_repair_and_verify_tree >/dev/null 2>&1; then
  echo "ERROR: the repository-controlled YAML runtime boundary is unavailable in this process" >&2
  echo "Expected lib/yaml-runtime.sh to define the runtime entries — check it exists and is readable" >&2
  exit 1
fi
# shellcheck source=lib/stuck-classifier.sh
[[ -z "${_STUCK_CLASSIFIER_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/stuck-classifier.sh" && _STUCK_CLASSIFIER_SH_SOURCED=1
# shellcheck source=lib/home-branch-guard.sh
[[ -z "${_GAAI_HOME_BRANCH_GUARD_SH_SOURCED:-}" ]] && source "$SCRIPT_DIR/lib/home-branch-guard.sh" && _GAAI_HOME_BRANCH_GUARD_SH_SOURCED=1
# daemon-start.sh sources lib/daemon-home.sh too, but that is a separate process —
# shell functions do not cross a process boundary, so _per_cycle_home_check (below)
# needs its own load here. The helper owns its own idempotent source guard.
# Fail closed before any poll/coordination/spawn, instead of a repeated
# "command not found" once the per-cycle check hits home drift.
# shellcheck source=lib/daemon-home.sh
if [[ -r "$SCRIPT_DIR/lib/daemon-home.sh" ]]; then
  source "$SCRIPT_DIR/lib/daemon-home.sh"
fi
if ! declare -F _gaai_home_verify >/dev/null 2>&1; then
  echo "ERROR: the verify-only daemon-home boundary is unavailable in this process" >&2
  echo "Expected lib/daemon-home.sh to define _gaai_home_verify — check it exists and is readable" >&2
  exit 1
fi
# Exact-current startup contract: the live daemon holds NO provisioning authority. A library still
# carrying the retired runtime provisioner means a stale asset is loaded and this
# process could repair the home mid-cycle — refuse before any coordination.
if declare -F _gaai_provision_daemon_home >/dev/null 2>&1; then
  echo "ERROR: a retired runtime home provisioner is present in this process" >&2
  echo "reason=process_authority_invalid action=operator_disposition_required" >&2
  exit 1
fi
NOTIFICATION_WEBHOOK="${GAAI_NOTIFICATION_WEBHOOK:-}"
WEBHOOK_SECRET="${GAAI_DAEMON_WEBHOOK_SECRET:-}"

# Staleness: stories in_progress for longer than this are considered orphaned
# Default: delivery timeout + 10 min buffer
if [[ -z "$STALENESS_THRESHOLD" ]]; then
  STALENESS_THRESHOLD=$(( DELIVERY_TIMEOUT + 600 ))
fi

# ── Platform detection ──────────────────────────────────────────────────
PLATFORM="$(uname)"
case "$PLATFORM" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    echo -e "${RED:-}ERROR: Native Windows (Git Bash/MSYS2) is not supported.${NC:-}"
    echo "Use WSL (Windows Subsystem for Linux) instead:"
    echo "  wsl --install && wsl"
    echo "  cd /mnt/c/path/to/project && .gaai/core/scripts/delivery-daemon.sh"
    exit 1
    ;;
  *)
    echo -e "${RED:-}WARNING: Untested platform '$PLATFORM' — proceeding with Linux defaults${NC:-}"
    ;;
esac

# --dangerously-skip-permissions: required for -p mode (headless).
# Without it, permission prompts hang forever since there's no interactive input.
# Override with GAAI_SKIP_PERMISSIONS=false to force interactive (not recommended for -p).
if [[ -n "${GAAI_SKIP_PERMISSIONS:-}" ]]; then
  SKIP_PERMISSIONS="$GAAI_SKIP_PERMISSIONS"
else
  SKIP_PERMISSIONS=true
fi

# Launcher: prefer tmux (background, robust, cross-platform), fallback to Terminal.app on macOS
if command -v tmux &>/dev/null; then
  LAUNCHER="tmux"
elif [[ "$PLATFORM" == "Darwin" ]] && command -v osascript &>/dev/null; then
  LAUNCHER="terminal-app"
else
  echo -e "${RED:-}ERROR: Neither tmux nor Terminal.app available. Install tmux: brew install tmux (macOS) / apt install tmux (Linux)${NC:-}"
  exit 1
fi

# Claude flags (expanded into wrapper scripts at generation time)
# --output-format stream-json: streams NDJSON events in real-time (tool calls, text)
#   instead of buffering everything until completion. This gives:
#   1. Real-time observability via tail -f on the log file
#   2. Natural heartbeat (log mtime updates continuously)
CLAUDE_FLAGS="--model $CLAUDE_MODEL --max-turns $MAX_TURNS --output-format stream-json --verbose"
if [[ "$SKIP_PERMISSIONS" == "true" ]]; then
  CLAUDE_FLAGS="--dangerously-skip-permissions $CLAUDE_FLAGS"
fi

# Cross-platform: file modification time (epoch seconds)
file_mtime() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "0"
  else
    stat -c %Y "$1" 2>/dev/null || echo "0"
  fi
}

# Cross-platform: sed in-place
sed_inplace() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ── HMAC signing helper for outgoing webhook POSTs (AC1 — E101S07a) ──────────
# Returns lowercase-hex HMAC-SHA256. Emits a warning and returns "" when
# openssl or xxd is unavailable — callers skip the X-Hub-Signature-256 header.
compute_webhook_hmac() {
  local json="$1" secret="$2"
  if ! command -v openssl &>/dev/null || ! command -v xxd &>/dev/null; then
    log "${YELLOW}[NOTIFY] openssl or xxd not found — webhook sent unsigned (install openssl+xxd for HMAC signing)${NC}"
    echo ""
    return 0
  fi
  printf '%s' "$json" | openssl dgst -sha256 -mac HMAC -macopt "key:$secret" -binary | xxd -p -c 256 | tr -d '\n'
}

# ── Escalation notifications (daemon scope — staleness detection) ─────────
notify_escalation() {
  local story_id="$1"
  local reason="$2"
  local remediation="$3"

  # AC1: terminal bell in daemon's session
  printf '\a'

  # AC2 / AC-ERR: OS-level notification on macOS only
  if [[ "$PLATFORM" == "Darwin" ]]; then
    osascript -e "display notification \"${remediation}\" with title \"GAAI Escalation: ${story_id}\" subtitle \"${reason}\"" 2>/dev/null || true
  fi

  # AC3 / AC4 / AC2(E101S07a): webhook POST (best-effort, never blocks daemon)
  if [[ -n "$NOTIFICATION_WEBHOOK" ]]; then
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local json="{\"story_id\":\"${story_id}\",\"reason\":\"${reason}\",\"remediation\":\"${remediation}\",\"timestamp\":\"${ts}\"}"
    local hmac_hex=""
    if [[ -n "$WEBHOOK_SECRET" ]]; then
      hmac_hex="$(compute_webhook_hmac "$json" "$WEBHOOK_SECRET")"
    else
      log "${YELLOW}[NOTIFY] GAAI_DAEMON_WEBHOOK_SECRET unset — sending webhook unsigned${NC}"
    fi
    local -a hmac_args=()
    [[ -n "$hmac_hex" ]] && hmac_args=(-H "X-Hub-Signature-256: sha256=$hmac_hex" -H "X-Webhook-Source: gaai-daemon")
    if ! curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        "${hmac_args[@]}" \
        -d "$json" \
        "$NOTIFICATION_WEBHOOK" 2>/dev/null | grep -qE '^2'; then
      log "${YELLOW}[NOTIFY] Webhook failed for $story_id (warning only)${NC}"
    fi
  fi
}

# ── Resolution notifications (daemon scope — escalated/failed → done) ────
notify_resolution() {
  local story_id="$1"
  local prior_status="$2"
  local pr_url="${3:-}"   # may be empty — callers pass "" when absent

  # AC1: terminal bell in daemon's session
  printf '\a'

  # AC2 / AC-ERR1: OS-level notification on macOS only
  if [[ "$PLATFORM" == "Darwin" ]]; then
    local subtitle="Story ${story_id} resolved from ${prior_status} to done"
    if [[ -n "$pr_url" ]]; then
      subtitle="${subtitle} — ${pr_url}"
    fi
    osascript -e "display notification \"${subtitle}\" with title \"GAAI Resolved: ${story_id}\"" 2>/dev/null || true
  fi

  # AC3 / AC4 / AC2(E101S07a): webhook POST (best-effort, never blocks daemon)
  if [[ -n "$NOTIFICATION_WEBHOOK" ]]; then
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # AC3: pr_url omitted from payload when absent — not null, not empty string
    local json
    if [[ -n "$pr_url" ]]; then
      json="{\"story_id\":\"${story_id}\",\"resolution\":\"done\",\"prior_status\":\"${prior_status}\",\"pr_url\":\"${pr_url}\",\"timestamp\":\"${ts}\"}"
    else
      json="{\"story_id\":\"${story_id}\",\"resolution\":\"done\",\"prior_status\":\"${prior_status}\",\"timestamp\":\"${ts}\"}"
    fi
    local hmac_hex=""
    if [[ -n "$WEBHOOK_SECRET" ]]; then
      hmac_hex="$(compute_webhook_hmac "$json" "$WEBHOOK_SECRET")"
    else
      log "${YELLOW}[NOTIFY] GAAI_DAEMON_WEBHOOK_SECRET unset — sending webhook unsigned${NC}"
    fi
    local -a hmac_args=()
    [[ -n "$hmac_hex" ]] && hmac_args=(-H "X-Hub-Signature-256: sha256=$hmac_hex" -H "X-Webhook-Source: gaai-daemon")
    if ! curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        "${hmac_args[@]}" \
        -d "$json" \
        "$NOTIFICATION_WEBHOOK" 2>/dev/null | grep -qE '^2'; then
      log "${YELLOW}[NOTIFY] Resolution webhook failed for $story_id (warning only)${NC}"
    fi
  fi
}

# ── Resolution tracking ──────────────────────────────────────────────────
# Persistent file: $RESOLUTION_TRACKING ($LOCK_DIR/.resolution-tracking)
# Format: one line per tracked story: story_id|prior_status
# Semantics:
#   - Written when daemon observes escalated or failed status
#   - Removed when resolution notification fires
#   - Survives daemon restart (persistent, not in-memory)

track_for_resolution() {
  local story_id="$1"
  local status="$2"   # escalated or failed

  # Only track escalated/failed (guard against accidental calls)
  [[ "$status" == "escalated" || "$status" == "failed" ]] || return 0

  # Idempotent write: only add if not already tracked for this story
  # Preserves original prior_status across daemon restarts
  if [[ -f "$RESOLUTION_TRACKING" ]] && grep -q "^${story_id}|" "$RESOLUTION_TRACKING" 2>/dev/null; then
    return 0
  fi

  echo "${story_id}|${status}" >> "$RESOLUTION_TRACKING"
}

untrack_resolved() {
  local story_id="$1"
  [[ -f "$RESOLUTION_TRACKING" ]] || return 0
  # Atomic removal via temp file on same filesystem (avoids partial read during sed)
  local tmp
  tmp=$(mktemp "${RESOLUTION_TRACKING}.XXXXXX")
  grep -v "^${story_id}|" "$RESOLUTION_TRACKING" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$RESOLUTION_TRACKING"
}

scan_and_track_escalated_failed() {
  local backlog_content
  backlog_content=$(fetch_and_read_backlog)
  [[ -z "$backlog_content" ]] && return 0

  local _bl_tmp1; _bl_tmp1=$(mktemp)
  printf '%s\n' "$backlog_content" > "$_bl_tmp1"
  local esc_ids failed_ids
  esc_ids=$(backlog_ids_by_status "escalated" "$_bl_tmp1" 2>/dev/null || true)
  failed_ids=$(backlog_ids_by_status "failed" "$_bl_tmp1" 2>/dev/null || true)
  rm -f "$_bl_tmp1"

  [[ -z "$esc_ids" && -z "$failed_ids" ]] && return 0

  while IFS= read -r _sid; do
    [[ -z "$_sid" ]] && continue
    track_for_resolution "$_sid" "escalated"
  done <<< "$esc_ids"
  while IFS= read -r _sid; do
    [[ -z "$_sid" ]] && continue
    track_for_resolution "$_sid" "failed"
  done <<< "$failed_ids"
}

check_resolution_notifications() {
  [[ -f "$RESOLUTION_TRACKING" ]] || return 0
  [[ -s "$RESOLUTION_TRACKING" ]] || return 0

  local backlog_content
  backlog_content=$(fetch_and_read_backlog)
  [[ -z "$backlog_content" ]] && return 0

  # Read tracking file into array (avoids subshell variable scope issues)
  local -a tracked_entries=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    tracked_entries+=("$entry")
  done < "$RESOLUTION_TRACKING"

  local _bl_tmp2; _bl_tmp2=$(mktemp)
  printf '%s\n' "$backlog_content" > "$_bl_tmp2"

  local entry
  for entry in "${tracked_entries[@]}"; do
    local tracked_id tracked_prior
    tracked_id="${entry%%|*}"
    tracked_prior="${entry##*|}"
    [[ -z "$tracked_id" || -z "$tracked_prior" ]] && continue

    # Extract current status for this story from backlog
    local current_status
    current_status=$(backlog_status "$tracked_id" "$_bl_tmp2" 2>/dev/null || true)

    [[ -z "$current_status" ]] && continue
    [[ "$current_status" != "done" ]] && continue

    # Story transitioned to done — extract pr_url if present
    local pr_url
    pr_url=$(echo "$backlog_content" | python3 -c "
import sys
content = sys.stdin.read()
in_story = False
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('- id:'):
        in_story = stripped.split(':', 1)[1].strip() == '${tracked_id}'
    elif in_story and stripped.startswith('pr_url:'):
        val = stripped.split(':', 1)[1].strip().strip('\"').strip(\"'\")
        if val:
            print(val)
        break
    elif in_story and stripped.startswith('- id:'):
        break
" 2>/dev/null) || pr_url=""

    log "${GREEN}[RESOLVE] ${tracked_id} transitioned from ${tracked_prior} to done — firing resolution notification${NC}"
    notify_resolution "$tracked_id" "$tracked_prior" "$pr_url"
    untrack_resolved "$tracked_id"
  done
  rm -f "$_bl_tmp2"
}

# ── Parse CLI args ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)       POLL_INTERVAL="$2"; shift 2 ;;
    --max-concurrent) MAX_CONCURRENT="$2"; shift 2 ;;
    --exit-when-idle)
      # Optional N — if next arg is a positive integer, use it ; else default 5.
      if [[ -n "${2:-}" && "$2" =~ ^[1-9][0-9]*$ ]]; then
        EXIT_WHEN_IDLE_THRESHOLD="$2"
        shift 2
      else
        EXIT_WHEN_IDLE_THRESHOLD=5
        shift
      fi
      ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --status)         STATUS_MODE=true; shift ;;
    --help|-h)
      sed -n '/^# Description:/,/^# ═══.*═══$/{ /^# ═══.*═══$/d; p; }' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1. Use --help for usage."
      exit 1
      ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ── Logging ───────────────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo -e "$msg"
  local ESC=$'\033'
  echo -e "$msg" | sed "s/${ESC}\[[0-9;]*m//g" >> "$LOG_FILE"
}

# ── AC4: Drift marker helpers ─────────────────────────────────────────────
# Single-slot file: last-write wins. Cleared when working tree is clean again.
_write_drift_marker() {
  local context="$1" reason="$2"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  printf '%s|%s|%s\n' "$ts" "$context" "$reason" > "$DRIFT_MARKER" 2>/dev/null || true
  log "${YELLOW}[DRIFT] working-tree drift detected ($context): $reason${NC}"
}

_clear_drift_marker_if_clean() {
  if git -C "$PROJECT_DIR" diff --quiet HEAD -- "$BACKLOG_REL" 2>/dev/null; then
    rm -f "$DRIFT_MARKER"
  fi
}

# Per-cycle home verification (exact-current startup contract). VERIFY-ONLY: the live daemon proves the
# pre-provisioned home is still the exact-current, clean, registered tree its launch
# tuple named, and fails closed before any coordination git-state operation. It never
# creates, moves, removes, prunes, resets, cleans or repairs the home — that authority
# belongs to the explicit offline `daemon-setup.sh` alone, and only while no lifecycle
# owner exists. A cycle that cannot prove the home stops the cycle; it never converts
# missing evidence into permission to continue.
#
# Returns 0 to continue the cycle, 1 to skip it.
_per_cycle_home_check() {
  # No coordination home set: daemon running direct (GAAI_DAEMON_HOME unset) — the
  # home boundary does not apply and there is nothing to verify.
  [[ -z "${GAAI_DAEMON_HOME:-}" ]] && return 0

  # The launch tuple is immutable for the life of this process. `GAAI_TARGET_SHA` is
  # the exact commit `daemon-start.sh` proved twice before releasing this daemon, so
  # the per-cycle test is equality with it — not with whatever origin says now. A
  # target that advanced mid-run is picked up by the next authorized restart, exactly
  # as the committed-on-target model has always required.
  local _expected="${GAAI_TARGET_SHA:-}"
  if [[ -z "$_expected" ]]; then
    _expected="$(git -C "$PROJECT_DIR" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || echo "")"
    if [[ -z "$_expected" ]]; then
      log "${RED}[HOME-INTEGRITY] reason=home_identity_invalid action=operator_disposition_required evidence=home_role=head_unresolved${NC}"
      return 1
    fi
  fi

  local _repo_root
  _repo_root="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$REPO_ROOT")"
  if ! _gaai_home_verify "$GAAI_DAEMON_HOME" "$TARGET_BRANCH" "$_repo_root" "$_expected"; then
    log "${RED}[HOME-INTEGRITY] reason=${GAAI_HOME_REASON} action=${GAAI_HOME_ACTION} evidence=${GAAI_HOME_EVIDENCE}${NC}"
    log "${RED}[HOME-INTEGRITY] the home is preserved unchanged; this cycle is skipped${NC}"
    return 1
  fi

  # The vendored YAML runtime tuple is verified — never repaired — from here. A tree
  # that cannot present a verifiable tuple is not a tree this daemon may coordinate
  # from, and repairing it would be exactly the runtime mutation this Story removes.
  if ! declare -F _daemon_repair_tuple >/dev/null 2>&1; then
    log "${RED}[HOME-INTEGRITY] the vendored YAML runtime verification pair is unavailable in this process${NC}"
    exit 1
  fi
  if ! _daemon_repair_tuple "verified daemon home" "$PROJECT_DIR"; then
    log "${RED}[HOME-INTEGRITY] reason=home_asset_invalid action=rerun_setup evidence=asset_role=yaml_runtime_tuple${NC}"
    return 1
  fi
  return 0
}

# The restrictive-umask repair and its verification, in the order the contract
# requires: normalize, then the worktree-local exact blob/mode verification of the
# four tuple paths against that tree's own HEAD tree, before any consumer,
# admission, retry or spawn. A tree whose HEAD predates the tuple declares none of
# it and needs neither step.
_daemon_repair_tuple() {
  local label="$1" root="$2" rc=0
  local YAML_RUNTIME_ROLE=daemon
  yaml_runtime_repair_and_verify_tree "$root" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi
  if [[ "${YAML_RUNTIME_TUPLE_STATE:-}" == "absent" ]]; then
    echo "[INFO] ${label}: tree predates the vendored runtime tuple — nothing to normalize or verify"
  fi
  return 0
}

# ── Preflight checks ─────────────────────────────────────────────────────
mkdir -p "$LOCK_DIR" "$LOG_DIR"

# Unconditional normalization + verification of the effective daemon home, ahead
# of every other dependency check and before the first YAML boundary consumer,
# the recovery scan, any wrapper launch, any retry and any spawn.
#
# It is unconditional because this process cannot observe which process
# materialized the tree it is running from, nor under which umask: the normal
# home provisioning happens in a separate starter process that then executes the
# home copy of this file. Under a 022 umask this is a no-op that still
# re-verifies; under a restrictive one (a service unit with a restrictive UMask,
# a hardened service account, an operator who set one) it is the repair.
#
# Consequence, disclosed rather than discovered: an effective home that is not a
# verifiable tree — for example an exported daemon home whose provisioning
# failed — now takes this typed refusal instead of continuing in a degraded
# state, and there is no fallback to the main checkout.
if ! _daemon_repair_tuple "daemon home" "$PROJECT_DIR"; then
  echo -e "${RED}ERROR: the vendored YAML runtime tuple of the effective daemon home could not be repaired and verified${NC}"
  echo "Verify it with: bash .gaai/core/scripts/lib/yaml-runtime.sh --verify-tuple"
  echo "See the restrictive-umask checkout section of .gaai/core/README.md"
  exit 1
fi

# ── Launch-tuple validation + ready acknowledgement (startup contract) ─────
#
# When this daemon was released by `daemon-start.sh`, it validates the immutable
# launch tuple it was handed and acknowledges readiness from its OWN pid and
# incarnation. `exec` preserved both across the launcher, so
# pane_pid == launcher_ack.pid == ready_ack.pid is an identity the controller can
# check rather than infer. Only after this acknowledgement may the controller
# record `running`. A tuple that does not validate never acknowledges, so the
# controller fails closed instead of promoting an unproven daemon.
if [[ -n "${GAAI_DAEMON_LAUNCH_ATTEMPT:-}" ]]; then
  _lt_dir="$GAAI_DAEMON_LAUNCH_ATTEMPT"
  _lt_fail() {
    echo -e "${RED}ERROR: launch tuple invalid — reason=process_authority_invalid action=operator_disposition_required evidence=$1${NC}" >&2
    exit 1
  }
  [[ -d "$_lt_dir" && -r "$_lt_dir/manifest" ]] || _lt_fail "manifest_absent"
  _lt_schema="$(sed -n 's/^schema=//p' "$_lt_dir/manifest" | head -1)"
  _lt_home="$(sed -n 's/^home=//p' "$_lt_dir/manifest" | head -1)"
  _lt_mode="$(sed -n 's/^credential_mode=//p' "$_lt_dir/manifest" | head -1)"
  [[ "$_lt_schema" == "$GAAI_HOME_SCHEMA" ]] || _lt_fail "manifest_schema_mismatch"
  [[ -n "${GAAI_DAEMON_HOME:-}" && "$_lt_home" == "$GAAI_DAEMON_HOME" ]] || _lt_fail "home_identity_mismatch"
  [[ "$_lt_mode" == "${GAAI_DAEMON_CREDENTIAL_MODE:-}" ]] || _lt_fail "credential_mode_mismatch"
  # Present-to-absent downgrade and absent-to-present fabrication both fail closed.
  case "$_lt_mode" in
    present) [[ -n "${GAAI_IMPL_AUTH_TOKEN:-}" ]] || _lt_fail "credential_downgrade" ;;
    absent)  [[ -z "${GAAI_IMPL_AUTH_TOKEN:-}" ]] || _lt_fail "credential_fabrication" ;;
    *)       _lt_fail "credential_mode_invalid" ;;
  esac
  [[ "$$" == "${GAAI_DAEMON_LAUNCH_PID:-}" ]] || _lt_fail "pid_identity_mismatch"
  _lt_inc="$(_gaai_home_incarnation "$$" 2>/dev/null || echo "")"
  if [[ -n "$_lt_inc" && -n "${GAAI_DAEMON_LAUNCH_INCARNATION:-}" \
        && "$_lt_inc" != "$GAAI_DAEMON_LAUNCH_INCARNATION" ]]; then
    _lt_fail "incarnation_mismatch"
  fi
  _gaai_home_write_durable "$_lt_dir/ack.ready" \
"schema=$GAAI_HOME_SCHEMA
pid=$$
incarnation=${GAAI_DAEMON_LAUNCH_INCARNATION:-$_lt_inc}
credential_mode=$_lt_mode" || _lt_fail "ready_ack_undurable"
  unset -f _lt_fail
  unset -v _lt_dir _lt_schema _lt_home _lt_mode _lt_inc
fi

if ! command -v python3 &>/dev/null; then
  echo -e "${RED}ERROR: python3 is required${NC}"
  exit 1
fi

case "${GAAI_DAEMON_EXECUTOR:-claude}" in
  claude)
    if ! command -v claude &>/dev/null; then
      echo -e "${RED}ERROR: claude CLI not found in PATH${NC}"
      echo "Install: https://docs.anthropic.com/en/docs/claude-code"
      exit 1
    fi
    ;;
  codex)
    if ! command -v codex &>/dev/null; then
      echo -e "${RED}ERROR: codex CLI not found in PATH${NC}"
      exit 1
    fi
    ;;
  *)
    echo -e "${RED}ERROR: unknown GAAI_DAEMON_EXECUTOR='${GAAI_DAEMON_EXECUTOR:-}' (expected claude or codex)${NC}"
    exit 1
    ;;
esac

if [[ ! -f "$SCHEDULER" ]]; then
  echo -e "${RED}ERROR: backlog-scheduler.sh not found at $SCHEDULER${NC}"
  exit 1
fi

if [[ "$LAUNCHER" == "tmux" ]] && ! command -v tmux &>/dev/null; then
  echo -e "${RED}ERROR: tmux is required on Linux/VPS (apt install tmux)${NC}"
  exit 1
fi

# ── tmux pipe-pane capability detection ──────────────────────────────────
TMUX_PIPE_PANE_AVAILABLE=false
if [[ "$LAUNCHER" == "tmux" ]] && command -v tmux &>/dev/null; then
  _tmux_ver_raw=$(tmux -V 2>/dev/null || true)
  _tmux_major=0; _tmux_minor=0
  if [[ "$_tmux_ver_raw" =~ tmux[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
    _tmux_major="${BASH_REMATCH[1]}"
    _tmux_minor="${BASH_REMATCH[2]}"
  fi
  if (( _tmux_major > 2 || ( _tmux_major == 2 && _tmux_minor >= 6 ) )); then
    TMUX_PIPE_PANE_AVAILABLE=true
  else
    echo "[WARN] tmux_version_below_pipe_pane_threshold version=${_tmux_ver_raw} required=2.6 — wrapper_output_capture_disabled"
  fi
fi

# ── Portable flock wrapper ───────────────────────────────────────────────
# Uses flock on Linux, mkdir-based atomic lock on macOS
with_staging_lock() {
  if command -v flock &>/dev/null; then
    flock "$STAGING_LOCK" "$@"
  else
    # macOS fallback: mkdir is atomic on all filesystems
    local lockdir="${STAGING_LOCK}.d"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      sleep 1
      ((waited++)) || true
      if (( waited >= 60 )); then
        log "${RED}Staging lock timeout after 60s${NC}"
        return 1
      fi
    done
    "$@"
    local rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return $rc
  fi
}

# ── Backlog reading (via git fetch + scheduler) ──────────────────────────
fetch_and_read_backlog() {
  # Fetch latest remote state (does not touch working tree). A failed fetch is
  # logged with a typed reason by the wrapper; the read below then falls back to
  # the last fetched ref, exactly as before.
  _fetch_target_branch || true

  # Read backlog from remote ref (always latest committed state)
  local content
  content=$(git -C "$PROJECT_DIR" show "origin/${TARGET_BRANCH}:${BACKLOG_REL}" 2>/dev/null) && {
    echo "$content"
    return
  }

  # Fallback: read from local filesystem
  if [[ -f "$BACKLOG" ]]; then
    cat "$BACKLOG"
  fi
}

find_ready_stories() {
  local backlog_content
  backlog_content=$(fetch_and_read_backlog)
  [[ -z "$backlog_content" ]] && return

  echo "$backlog_content" | "$SCHEDULER" --ready-ids --stdin
}

# ── Lock management ──────────────────────────────────────────────────────
clean_stale_locks() {
  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    local pid
    pid=$(head -1 "$lock" 2>/dev/null || echo "")
    if [[ -z "$pid" || "$pid" == "pending" ]]; then
      # Placeholder lock older than 60s is stale
      local age
      age=$(( $(date +%s) - $(file_mtime "$lock") ))
      if (( age > 60 )); then
        local sid
        sid=$(basename "$lock" .lock)
        log "${YELLOW}Stale placeholder lock removed: $sid${NC}"
        rm -f "$lock"
      fi
      continue
    fi
    # Numeric dead-PID locks are recovery evidence.  The forward coordinator
    # retires the exact descriptor-bound lock only at the spawn boundary.
  done
}

# ── Cycle-time orphan-lock scan ──────────────────────────────────────────
# Dead locks remain evidence until the forward coordinator authorizes one
# exact relaunch.  A failed classification/projection leaves the lock intact.
cycle_orphan_lock_scan() {
  local scan_start_ts lock sid row rc state pid overall=0
  scan_start_ts=$(date +%s)
  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    if (( $(date +%s) - scan_start_ts >= ORPHAN_SCAN_MAX_DURATION_SEC )); then
      log "${YELLOW}[CYCLE-ORPHAN] bounded scan window reached — retrying next cycle${NC}"
      return 1
    fi
    sid=$(basename "$lock" .lock)
    if ! [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]]; then
      log "${YELLOW}[CYCLE-ORPHAN] invalid lock identity — preserving evidence${NC}"
      overall=1
      continue
    fi
    rc=0
    row=$(_forward_lock_state "$sid") || rc=$?
    IFS=$'\t' read -r state pid <<< "$row"
    if [[ "$rc" -ne 0 || "$state" == unknown ]]; then
      if ! _forward_evidence "$sid" blocked invalid_record none \
          0000000000000000000000000000000000000000000000000000000000000000 \
          0000000000000000000000000000000000000000000000000000000000000000 \
          none; then
        return 4
      fi
      overall=1
      continue
    fi
    [[ "$state" == dead ]] || continue
    rc=0
    forward_recovery_scan --only-sid "$sid" || rc=$?
    case "$rc" in
      0) ;;
      4) return 4 ;;
      *) overall=1 ;;
    esac
  done
  return "$overall"
}
# ── Heartbeat monitoring ─────────────────────────────────────────────────
# Liveness signal is decoupled from claude -p log output: the wrapper runs a
# background loop that touches $LOCK_DIR/<sid>.heartbeat every 30s for the
# entire wrapper lifetime. This covers commit-phase (pure bash, writes no
# claude log) which previously triggered false-positive kills during long
# `gh pr merge` retry waits.
#
# Fallback: if no .heartbeat file exists yet (wrapper still bootstrapping),
# fall back to lock file mtime within the grace period; outside that window,
# legacy log mtime is consulted as a last resort for legacy pipeline wrappers.
check_heartbeats() {
  local now
  now=$(date +%s)

  # Post-resume grace: after a detected host suspend / daemon pause, heartbeat
  # mtimes are stale purely because wall-clock advanced during the freeze. The
  # wrapper's heartbeat loop re-touches within its interval; stand down until
  # then so we don't SIGTERM a live wrapper on a suspend artifact.
  if (( now < SUSPEND_GRACE_UNTIL )); then
    return 0
  fi

  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    local sid pid
    sid=$(basename "$lock" .lock)
    pid=$(head -1 "$lock" 2>/dev/null || echo "")
    [[ -z "$pid" || "$pid" == "pending" ]] && continue

    # Check if process is still alive
    if ! kill -0 "$pid" 2>/dev/null; then
      continue  # Will be cleaned by clean_stale_locks
    fi

    # Grace period: skip heartbeat for recently-launched sessions.
    local lock_age=$(( now - $(file_mtime "$lock") ))
    if (( lock_age < HEARTBEAT_STALE )); then
      continue
    fi

    # ── Primary: dedicated heartbeat file written by wrapper ────────────────
    local hb_file="$LOCK_DIR/${sid}.heartbeat"
    if [[ -f "$hb_file" ]]; then
      local hb_age=$(( now - $(file_mtime "$hb_file") ))
      if (( hb_age > HEARTBEAT_STALE )); then
        log "${RED}HEARTBEAT: $sid — heartbeat stale ($(( hb_age / 60 ))min) — sending SIGTERM to PID $pid${NC}"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 30
        if kill -0 "$pid" 2>/dev/null; then
          log "${RED}HEARTBEAT: $sid — SIGKILL PID $pid (did not respond to SIGTERM)${NC}"
          kill -KILL "$pid" 2>/dev/null || true
        fi
      fi
      continue
    fi

    # No heartbeat, no log — wrapper is past grace and produced nothing.
    log "${RED}HEARTBEAT: $sid has no heartbeat or log after ${lock_age}s — killing PID $pid${NC}"
    kill -TERM "$pid" 2>/dev/null || true
  done
}

# ── Agent-activity stale detector ─────────────────────────────────────────
# Complementary to check_heartbeats: heartbeat proves wrapper alive, but does
# NOT prove claude -p is making progress. This function checks impl.log mtime.
# If mtime stale > AGENT_HANG_THRESHOLD_SEC AND heartbeat is fresh → agent hung
# in a synchronous tool call (e.g. infinite bash loop, blocked gh command).
# Composes with the reconcile-in-progress mutex: skips if reconcile marker fresh.
check_agent_activity_stale() {
  local now
  now=$(date +%s)

  # Post-resume grace: after a detected host suspend / daemon pause, impl.log
  # mtime age is inflated by the freeze duration (the agent was not running),
  # so the stale-log heuristic would mis-fire. Stand down for the grace window;
  # a genuinely hung agent is still caught on the next normal cycle.
  if (( now < SUSPEND_GRACE_UNTIL )); then
    return 0
  fi

  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    local sid pid
    sid=$(basename "$lock" .lock)
    pid=$(head -1 "$lock" 2>/dev/null || echo "")
    [[ -z "$pid" || "$pid" == "pending" ]] && continue

    # Only act on live wrappers (dead ones handled by clean_stale_locks)
    kill -0 "$pid" 2>/dev/null || continue

    # Grace period: skip if lock younger than threshold (wrapper still bootstrapping)
    local lock_age=$(( now - $(file_mtime "$lock") ))
    (( lock_age < AGENT_HANG_THRESHOLD_SEC )) && continue

    # AC6: skip if reconcile-in-progress marker is fresh (wrapper in EXIT trap)
    local _rip_marker="$LOCK_DIR/${sid}.reconcile-in-progress"
    local _rip_ttl="${GAAI_RECONCILE_GRACE_SEC:-90}"
    if [[ -f "$_rip_marker" ]]; then
      local _rip_mtime
      _rip_mtime=$(file_mtime "$_rip_marker")
      local _rip_age=$(( now - _rip_mtime ))
      if (( _rip_age <= _rip_ttl )); then
        continue
      fi
    fi

    # AC6: skip if heartbeat is stale — check_heartbeats owns that case
    local hb_file="$LOCK_DIR/${sid}.heartbeat"
    [[ -f "$hb_file" ]] || continue
    local hb_age=$(( now - $(file_mtime "$hb_file") ))
    (( hb_age > HEARTBEAT_STALE )) && continue

    # Resolve worktree phase-log paths (mirrors handle_*_phase in daemon-dispatch.sh).
    # The wrapper writes to whichever log corresponds to its CURRENT phase
    # (plan/impl/qa), so a resumed wrapper at QA writes qa.log while impl.log
    # mtime stays frozen at its prior-phase value. Using only impl.log produces
    # false-positive hangs on every resumed-from-implemented wrapper. Track the
    # max mtime across all phase logs as the true "agent activity" signal.
    #
    # COMMIT phase is not one of plan/impl/qa: handle_commit_phase (daemon-
    # dispatch.sh) writes its differential-test-gate output straight into the
    # wrapper's own persistent log ($LOG_DIR/${sid}.wrapper.log), not into a
    # worktree phase-log. Without tracking that file too, plan/impl/qa mtimes
    # stay frozen at whatever they were when QA finished, so every commit-phase
    # attempt gets killed once it runs past AGENT_HANG_THRESHOLD_SEC — even one
    # that is actively running a long differential test suite — producing a
    # repeat 20-ish-minute kill/relaunch loop until COMMIT_PHASE_REPEATED_FAILURE
    # stalls the story (observed in practice on a story with a long
    # differential test suite).
    local worktree_path
    worktree_path=$(_forward_resolve_worktree "$sid")
    local impl_log="${worktree_path}/.delivery-logs/${sid}.impl.log"
    local plan_log="${worktree_path}/.delivery-logs/${sid}.plan.log"
    local qa_log="${worktree_path}/.delivery-logs/${sid}.qa.log"
    local wrapper_log="${LOG_DIR}/${sid}.wrapper.log"

    local _latest_log=""
    local _latest_mtime=0
    local _phase_log _m
    for _phase_log in "$plan_log" "$impl_log" "$qa_log" "$wrapper_log"; do
      [[ -f "$_phase_log" ]] || continue
      _m=$(file_mtime "$_phase_log")
      if (( _m > _latest_mtime )); then
        _latest_mtime=$_m
        _latest_log="$_phase_log"
      fi
    done

    # Check for resolved hang: previous marker + at least one phase log now fresh
    local hang_marker="$LOCK_DIR/${sid}.agent-hang.marker"
    if [[ -f "$hang_marker" && $_latest_mtime -gt 0 ]]; then
      local _fresh_age=$(( now - _latest_mtime ))
      if (( _fresh_age < AGENT_HANG_THRESHOLD_SEC )); then
        log "[AGENT_HANG_RESOLVED] $sid"
        rm -f "$hang_marker" 2>/dev/null || true
        continue
      fi
    fi

    # No phase logs yet: agent hasn't started writing — skip
    (( _latest_mtime == 0 )) && continue

    local log_age=$(( now - _latest_mtime ))

    # Agent healthy: at least one phase log was updated recently
    (( log_age <= AGENT_HANG_THRESHOLD_SEC )) && continue

    # Hang detected — use the most-recent phase log for size telemetry
    local log_size=0
    log_size=$(wc -c < "$_latest_log" 2>/dev/null | tr -d ' ' || echo 0)

    # Prefer killing agent subprocess over wrapper: killing the agent closes the
    # fifo write-end, unblocking the wrapper's read loop so its EXIT reconcile
    # trap runs. Sidecar written by daemon-dispatch.sh at agent spawn time.
    # Fallback: kill wrapper if sidecar absent or agent already dead.
    local _agent_pid_sidecar="$LOCK_DIR/${sid}.agent.pid"
    local _kill_pid="$pid"
    local _pid_kind="wrapper"
    if [[ -f "$_agent_pid_sidecar" ]]; then
      local _agent_pid
      _agent_pid=$(head -1 "$_agent_pid_sidecar" 2>/dev/null || echo "")
      if [[ -n "$_agent_pid" ]] && kill -0 "$_agent_pid" 2>/dev/null; then
        _kill_pid="$_agent_pid"
        _pid_kind="agent"
      fi
    fi

    log "${RED}[AGENT_HANG_DETECTED] $sid — log-mtime stale ($(( log_age / 60 ))min) heartbeat-fresh ($(( hb_age / 60 ))min) — SIGTERM ${_pid_kind} PID ${_kill_pid}${NC}"

    # Extend audit record with kill_pid + pid_kind (additive — existing consumers unaffected)
    local _audit_ts
    _audit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"event":"agent_hang_detected","ts":"%s","story_id":"%s","wrapper_pid":%s,"kill_pid":%s,"pid_kind":"%s","log_mtime_age_sec":%s,"heartbeat_age_sec":%s,"last_log_size_bytes":%s}\n' \
      "$_audit_ts" "$sid" "$pid" "$_kill_pid" "$_pid_kind" "$log_age" "$hb_age" "$log_size" \
      >> "$AGENT_HANG_AUDIT" 2>/dev/null || true

    # Write hang marker so AGENT_HANG_RESOLVED can be emitted on recovery
    touch "$hang_marker" 2>/dev/null || true

    kill -TERM "$_kill_pid" 2>/dev/null || true
    sleep 30
    if kill -0 "$_kill_pid" 2>/dev/null; then
      log "${RED}[AGENT_HANG_SIGKILL] $sid ${_pid_kind} PID ${_kill_pid} did not respond to SIGTERM${NC}"
      kill -KILL "$_kill_pid" 2>/dev/null || true
    fi
  done
}

active_count() {
  local count=0 sid row state pid rc
  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    sid=$(basename "$lock" .lock)
    _forward_sid_valid "$sid" || return 1
    rc=0
    row=$(_forward_lock_state "$sid") || rc=$?
    IFS=$'\t' read -r state pid <<< "$row"
    [[ "$rc" -eq 0 && "$state" != unknown ]] || return 1
    [[ "$state" == live ]] && count=$(( count + 1 ))
  done
  echo "$count"
}

active_stories() {
  for lock in "$LOCK_DIR"/*.lock; do
    [[ -f "$lock" ]] || continue
    local sid pid age_s age_min
    sid=$(basename "$lock" .lock)
    pid=$(head -1 "$lock" 2>/dev/null || echo "?")
    age_s=$(( $(date +%s) - $(file_mtime "$lock") ))
    age_min=$(( age_s / 60 ))
    echo "$sid (PID $pid, ${age_min}min)"
  done
}

is_locked() {
  [[ -f "$LOCK_DIR/$1.lock" ]]
}

# ── Retry tracking ────────────────────────────────────────────────────────
# Tracks launch count per story. Resets on daemon restart (intentional).
get_retry_count() {
  local story_id="$1"
  if [[ -f "$RETRY_FILE" ]]; then
    local count
    count=$(grep "^${story_id}=" "$RETRY_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    echo "${count:-0}"
  else
    echo "0"
  fi
}

increment_retry() {
  local story_id="$1"
  local current next
  current=$(get_retry_count "$story_id")
  next=$(( current + 1 ))
  if [[ -f "$RETRY_FILE" ]]; then
    if grep -q "^${story_id}=" "$RETRY_FILE" 2>/dev/null; then
      sed_inplace "s/^${story_id}=.*/${story_id}=${next}/" "$RETRY_FILE"
    else
      echo "${story_id}=${next}" >> "$RETRY_FILE"
    fi
  else
    echo "${story_id}=${next}" > "$RETRY_FILE"
  fi
}

has_exceeded_retries() {
  local story_id="$1"
  local count
  count=$(get_retry_count "$story_id")
  (( count >= MAX_RETRIES ))
}

# ── Forward-only recovery coordinator ────────────────────────────────────
# Recovery decisions are made from one fetched target object.  None of these
# helpers reads the mutable daemon-home backlog as authority.
_forward_sha256() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

# The target-branch fetch primitive lives HERE, inside this coordinator's helper
# set, rather than beside the poll loop that also calls it. Two reasons, both
# deliberate. It is the operation by which "one fetched target object" — the
# premise of this whole section — is obtained, so it belongs to the same unit.
# And the harnesses that test this coordinator extract it as a contiguous range
# from `_forward_sha256()` to `exceeded_stories()`; a dependency defined outside
# that range would have to be stubbed in every one of them, and those tests would
# then no longer exercise the real fetch path at all. Bash resolves calls at
# runtime, so the earlier `fetch_and_read_backlog` reaches it regardless of order.
# ── Target-branch fetch (typed failure, never interactive) ────────────────
#
# Every fetch of origin/${TARGET_BRANCH} issued by the daemon process itself goes
# through here. The launcher's privileged entry closes every interactive credential
# path (GIT_TERMINAL_PROMPT=0, GIT_ASKPASS='', GH_PROMPT_DISABLED=1), so an absent
# credential now fails at once with "could not read Username ...: terminal prompts
# disabled" instead of blocking the poll loop on a pane prompt nobody sees. That
# only helps an operator if the failure is VISIBLE: a `fatal:` swallowed by
# `2>/dev/null` leaves a cycle that produced nothing and a log that says nothing.
# This wrapper captures git's stderr, classifies it, and writes ONE typed line per
# failed fetch. The return value is git's, so every caller keeps its own `|| true`
# or `|| return 1` semantics; only the diagnostics change.
#
# Reasons and their canonical actions:
#   credential_absent    no usable credential reached git — provision the dedicated
#                        forge credential the entry consumes (`~/.gaai/forge-token`,
#                        regular file, 0600) or an operator gh login
#   credential_rejected  a credential was presented and refused — rotate it
#   remote_unreachable   DNS/TCP/TLS failure — check the network, not the daemon
#   ref_absent           origin has no such branch — check the configured target
#   fetch_failed         anything else — the evidence line carries git's own words

# _classify_fetch_failure <git stderr>  →  one typed reason on stdout
_classify_fetch_failure() {
  local err="$1"
  case "$err" in
    *"terminal prompts disabled"*|*"could not read Username"*|*"could not read Password"*)
      printf 'credential_absent' ;;
    *"Authentication failed"*|*"Invalid username or"*|*"Permission denied"*|*"HTTP 403"*|*"403 Forbidden"*)
      printf 'credential_rejected' ;;
    *"Could not resolve host"*|*"unable to access"*|*"Connection refused"*|*"timed out"*|*"Network is unreachable"*|*"Failed to connect"*|*"Could not read from remote repository"*)
      printf 'remote_unreachable' ;;
    *"couldn't find remote ref"*|*"Remote branch"*"not found"*|*"invalid refspec"*)
      printf 'ref_absent' ;;
    *) printf 'fetch_failed' ;;
  esac
}

# _fetch_target_branch [branch]  →  git's exit status; one [FETCH] line on failure
_FETCH_LAST_REASON=""
_fetch_target_branch() {
  local branch="${1:-$TARGET_BRANCH}" err rc=0 reason action evidence
  err=$(git -C "$PROJECT_DIR" fetch origin "$branch" --quiet 2>&1) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    _FETCH_LAST_REASON=""
    return 0
  fi
  reason=$(_classify_fetch_failure "$err")
  _FETCH_LAST_REASON="$reason"
  case "$reason" in
    credential_absent)   action=provision_forge_credential ;;
    credential_rejected) action=rotate_forge_credential ;;
    remote_unreachable)  action=check_network ;;
    ref_absent)          action=check_target_branch ;;
    *)                   action=operator_disposition_required ;;
  esac
  # git's own `fatal:` line when there is one, else its first line; printable
  # characters only and bounded — the log is a plain-text operator surface, not a
  # place for remote-controlled bytes, and `log` expands escapes.
  evidence=$(printf '%s\n' "$err" | grep -m1 '^fatal:' 2>/dev/null || true)
  [[ -n "$evidence" ]] || evidence=$(printf '%s\n' "$err" | head -1)
  evidence=$(printf '%s' "$evidence" | sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g" \
    | tr -cd '[:print:]' | tr -d '\\' | cut -c1-200)
  # Colours are defaulted, not assumed. The daemon runs under `set -euo pipefail`,
  # so a bare unset ${RED} here would abort the process at the exact moment it is
  # trying to report why a fetch failed — reinstating the silence this line exists
  # to remove. A diagnostic must never be able to fail louder than what it reports.
  log "${RED:-}[FETCH] reason=${reason} action=${action} target=origin/${branch} rc=${rc} evidence=${evidence:-none}${NC:-}"
  return "$rc"
}

_forward_sid_valid() {
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]]
}

_forward_evidence_fatal() {
  _daemon_evidence_fatal=true
  return 1
}

_forward_evidence() {
  local sid="$1" outcome="$2" reason="$3" attempt="$4"
  local source_digest="$5" record_digest="$6" fields="${7:-none}"
  _forward_sid_valid "$sid" || { _forward_evidence_fatal; return 1; }
  case "$outcome" in
    accepted|blocked|conflict|failure|held|launched|noop|retryable) ;;
    *) _forward_evidence_fatal; return 1 ;;
  esac
  case "$reason" in
    already_current|caller_untrusted|context_invalid|effect_inhibited|empty_run_state|integrity_unverified|invalid_record|merge_terminal_owned|none|not_actionable|pending_run|policy_stall|projection_failed|remote_changed|required_plan_absent|resumable|runner_live|source_unavailable|terminal_projection|worktree_unrecoverable) ;;
    *) _forward_evidence_fatal; return 1 ;;
  esac
  [[ "$attempt" == none || "$attempt" =~ ^[0-9a-f]{64}$ ]] \
    || { _forward_evidence_fatal; return 1; }
  [[ "$source_digest" =~ ^[0-9a-f]{64}$ ]] \
    || { _forward_evidence_fatal; return 1; }
  [[ "$record_digest" =~ ^[0-9a-f]{64}$ ]] \
    || { _forward_evidence_fatal; return 1; }
  case "$fields" in
    none|phase_status|phase_status,status|status) ;;
    *) _forward_evidence_fatal; return 1 ;;
  esac
  [[ "$fields" != *"="* ]] || { _forward_evidence_fatal; return 1; }
  printf '[FORWARD-RECOVERY] story=%s writer=recovery.scan outcome=%s reason=%s attempt=%s source_digest=%s record_digest=%s fields=%s\n' \
    "$sid" "$outcome" "$reason" "$attempt" "$source_digest" "$record_digest" \
    "$fields" >&2 || { _forward_evidence_fatal; return 1; }
}

# Context intentions stay value-bound for exact settlement. Observability is a
# separate public surface and exposes only the names of affected fields.
_forward_evidence_for_intention() {
  local sid="$1" outcome="$2" reason="$3" attempt="$4"
  local source_digest="$5" record_digest="$6" intention="${7:-none}" fields
  case "$intention" in
    none) fields=none ;;
    phase_status=commit_stalled) fields=phase_status ;;
    phase_status=failed,status=failed) fields=phase_status,status ;;
    status=failed|status=escalated) fields=status ;;
    *) _forward_evidence_fatal; return 1 ;;
  esac
  _forward_evidence "$sid" "$outcome" "$reason" "$attempt" \
    "$source_digest" "$record_digest" "$fields"
}

# Main-loop deferrals expose a fixed reason and identity digests only. Missing
# authority is represented by the zero digest rather than by ambient values.
_forward_main_hold() {
  local sid="$1" reason="$2"
  local zero="0000000000000000000000000000000000000000000000000000000000000000"
  local source_digest="${3:-$zero}"
  local record_digest="${4:-$zero}"
  [[ "$source_digest" =~ ^[0-9a-f]{64}$ ]] || source_digest="$zero"
  [[ "$record_digest" =~ ^[0-9a-f]{64}$ ]] || record_digest="$zero"
  _forward_evidence "$sid" held "$reason" none "$source_digest" \
    "$record_digest" none
}

_forward_resolve_worktree() {
  local sid="$1" repo_name
  _forward_sid_valid "$sid" || return 1
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    printf '%s\n' "${GAAI_WORKTREES_BASE}/${sid}-workspace"
    return 0
  fi
  repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
  printf '%s\n' "$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${sid}-workspace"
}

_forward_plan_present() {
  local sid="$1" wt="$2"
  [[ -s "$wt/.gaai/project/contexts/artefacts/plans/${sid}.execution-plan.md" ]]
}

# Emits verified, recoverable, unrecoverable, unknown or absent_new without
# mutating the worktree. Exact-source repair is a separate authority-bound
# operation performed only after a canonical target record has been admitted.
_forward_worktree_state() {
  local sid="$1" allow_absent="${2:-false}" wt rc=0 check_log porcelain
  _forward_sid_valid "$sid" || { printf '%s\n' unknown; return 1; }
  wt=$(_forward_resolve_worktree "$sid") || { printf '%s\n' unknown; return 1; }
  if [[ ! -d "$wt" ]]; then
    if [[ "$allow_absent" == true ]]; then
      printf '%s\n' absent_new
      return 0
    fi
    printf '%s\n' unknown
    return 1
  fi
  # Unborn/null/corrupt metadata and all dirty/untracked evidence are
  # preservation states, never inputs to the destructive safe-base helper.
  git -C "$wt" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    printf '%s\n' unknown; return 1; }
  porcelain=$(git -C "$wt" status --porcelain 2>/dev/null) || {
    printf '%s\n' unknown; return 1; }
  if [[ -n "$porcelain" ]]; then
    printf '%s\n' unknown
    return 1
  fi
  check_log=$(mktemp "$LOCK_DIR/.integrity-XXXXXX" 2>/dev/null) || {
    printf '%s\n' unknown; return 1; }
  _check_worktree_integrity "$wt" "$TARGET_BRANCH" "$sid" >"$check_log" 2>&1 || rc=$?
  case "$rc" in
    0) rm -f "$check_log"; printf '%s\n' verified; return 0 ;;
    1) rm -f "$check_log"; printf '%s\n' recoverable; return 1 ;;
    2) rm -f "$check_log"; printf '%s\n' unrecoverable; return 2 ;;
    *) rm -f "$check_log"; printf '%s\n' unknown; return 1 ;;
  esac
}

# Repair one typed recoverable worktree against a private remote-tracking ref
# pinned to the already-admitted target object. The shared recovery helper is
# unchanged; this coordinator supplies its immutable base.
_forward_repair_worktree_exact() {
  local sid="$1" expected_source="$2" wt live private_branch private_ref
  local repair_log repair_rc=0 cleanup_rc=0
  _forward_sid_valid "$sid" || return 1
  [[ "$expected_source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
  wt=$(_forward_resolve_worktree "$sid") || return 1
  [[ -d "$wt" ]] || return 1
  _fetch_target_branch || return 1
  live=$(git -C "$PROJECT_DIR" rev-parse "origin/${TARGET_BRANCH}" 2>/dev/null) \
    || return 1
  [[ "$live" == "$expected_source" ]] || return 1
  private_branch="gaai-forward-${sid}-$$-${RANDOM}"
  private_ref="refs/remotes/origin/${private_branch}"
  git -C "$PROJECT_DIR" check-ref-format "$private_ref" >/dev/null 2>&1 || return 1
  git -C "$PROJECT_DIR" update-ref "$private_ref" "$expected_source" "" || return 1
  repair_log=$(mktemp "$LOCK_DIR/.forward-repair-XXXXXX" 2>/dev/null) || {
    git -C "$PROJECT_DIR" update-ref -d "$private_ref" "$expected_source" 2>/dev/null
    return 1
  }
  chmod 600 "$repair_log" 2>/dev/null || {
    rm -f "$repair_log"
    git -C "$PROJECT_DIR" update-ref -d "$private_ref" "$expected_source" 2>/dev/null
    return 1
  }
  _recover_worktree_safe_base "$sid" "$wt" "$private_branch" \
    >"$repair_log" 2>&1 || repair_rc=$?
  git -C "$PROJECT_DIR" update-ref -d "$private_ref" "$expected_source" \
    2>/dev/null || cleanup_rc=$?
  rm -f "$repair_log"
  [[ "$cleanup_rc" -eq 0 ]] || return 1
  _fetch_target_branch || return 1
  live=$(git -C "$PROJECT_DIR" rev-parse "origin/${TARGET_BRANCH}" 2>/dev/null) \
    || return 1
  [[ "$live" == "$expected_source" ]] || return 1
  # The shared recovery helper removes and re-creates the worktree with its own
  # checkout under whatever umask this process inherited, so a successful repair
  # hands back a tree whose vendored runtime is at 0600 again whenever that umask
  # is restrictive — even if the pre-recovery tree had already been normalized.
  # The helper itself is unchanged; the repair belongs here, before the fresh
  # state verdict, before any admission, retry or spawn, and before any consumer
  # reads that tree.
  if [[ "$repair_rc" -eq 0 ]]; then
    if ! _daemon_repair_tuple "$sid" "$wt"; then
      return 1
    fi
  fi
  case "$repair_rc" in
    0) return 0 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

# Probe, optionally repair one typed recoverable state, and then require a
# fresh non-mutating verdict. Callers must already have admitted the source.
_forward_prepare_worktree() {
  local sid="$1" expected_source="$2" allow_absent="${3:-false}"
  local state rc=0
  state=$(_forward_worktree_state "$sid" "$allow_absent") || rc=$?
  case "$rc:$state" in
    0:verified|0:absent_new) printf '%s\n' "$state"; return 0 ;;
    1:recoverable)
      _forward_repair_worktree_exact "$sid" "$expected_source" || return $?
      rc=0
      state=$(_forward_worktree_state "$sid" false) || rc=$?
      [[ "$rc:$state" == 0:verified ]] || return 1
      printf '%s\n' verified
      return 0
      ;;
    2:unrecoverable) printf '%s\n' unrecoverable; return 2 ;;
    *) printf '%s\n' unknown; return 1 ;;
  esac
}

# Populates the _FORWARD_* globals from one exact origin/${TARGET_BRANCH}
# backlog object and one descriptor-bound classifier read.
_forward_classify() {
  local sid="$1" scope="$2" integrity="$3" plan_present="$4"
  local snapshot source blob facts
  snapshot=$(mktemp "$LOCK_DIR/.forward-snapshot-XXXXXX" 2>/dev/null) || return 1
  chmod 600 "$snapshot" 2>/dev/null || { rm -f "$snapshot"; return 1; }
  if ! _fetch_target_branch \
      || ! source=$(git -C "$PROJECT_DIR" rev-parse "origin/${TARGET_BRANCH}" 2>/dev/null) \
      || ! [[ "$source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
      || ! blob=$(git -C "$PROJECT_DIR" rev-parse "${source}:${BACKLOG_REL}" 2>/dev/null) \
      || ! [[ "$blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
      || ! git -C "$PROJECT_DIR" show "${source}:${BACKLOG_REL}" > "$snapshot" 2>/dev/null \
      || ! facts=$(forward_classify_snapshot "$sid" "$snapshot" "$source" "$blob" \
           "$scope" "$integrity" "$plan_present"); then
    rm -f "$snapshot"
    return 1
  fi
  IFS=$'\t' read -r _FORWARD_ACTION _FORWARD_REASON _FORWARD_STATUS \
    _FORWARD_PHASE _FORWARD_STARTED _FORWARD_RECORD_DIGEST \
    _FORWARD_SOURCE _FORWARD_BLOB <<< "$facts"
  _FORWARD_SNAPSHOT="$snapshot"
  _FORWARD_SOURCE_DIGEST=$(_forward_sha256 "$_FORWARD_SOURCE") || {
    rm -f "$snapshot"; return 1; }
  return 0
}

# A preliminary main-loop classification admits target identity only. It must
# be the integrity-blocked shape of the lifecycle stage that the loop itself
# is about to advance; invalid, terminal and no-effect rows cannot authorize a
# worktree repair.
_forward_main_record_admitted() {
  case "${1:-}:$_FORWARD_ACTION:$_FORWARD_REASON:$_FORWARD_STATUS:$_FORWARD_PHASE" in
    pre:block_integrity:integrity_unverified:refined:not_started) return 0 ;;
    post:block_integrity:integrity_unverified:in_progress:not_started|\
    post:block_integrity:integrity_unverified:in_progress:planned|\
    post:block_integrity:integrity_unverified:in_progress:implemented|\
    post:block_integrity:integrity_unverified:in_progress:qa_failed|\
    post:block_integrity:integrity_unverified:in_progress:qa_passed) return 0 ;;
    *) return 1 ;;
  esac
}

# Re-establish final authority after Story-file reconciliation. Both recovery
# and post-claim launch paths use this same boundary before context, retry or
# spawn effects. The successful caller owns _FORWARD_SNAPSHOT and must remove
# it after consuming the verified facts.
_forward_revalidate_after_reconcile() {
  local sid="$1" expected_source="$2" expected_blob="$3" expected_record="$4"
  local scope="$5" allow_absent="${6:-false}" wt integrity plan=false
  integrity=$(_forward_prepare_worktree "$sid" "$expected_source" "$allow_absent") \
    || return 1
  if [[ "$scope" == recovery && "$integrity" != verified ]]; then
    return 1
  fi
  wt=$(_forward_resolve_worktree "$sid") || return 1
  _forward_plan_present "$sid" "$wt" && plan=true
  _forward_classify "$sid" "$scope" "$integrity" "$plan" || return 1
  if [[ "$_FORWARD_SOURCE" != "$expected_source" \
      || "$_FORWARD_BLOB" != "$expected_blob" \
      || "$_FORWARD_RECORD_DIGEST" != "$expected_record" \
      || "$_FORWARD_ACTION:$_FORWARD_REASON" != resume:resumable ]]; then
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  fi
  _FORWARD_FINAL_INTEGRITY="$integrity"
}

# Final effect-edge authority check. Unlike the reconciliation guard above it
# is deliberately read-only: no worktree repair may occur after temporary
# inhibitors have cleared and before retry/spawn authority is consumed.
_forward_last_edge_guard() {
  local sid="$1" expected_source="$2" expected_blob="$3" expected_record="$4"
  local scope="$5" allow_absent="${6:-false}" wt integrity plan=false rc=0
  [[ "$scope" == postclaim || "$scope" == recovery ]] || return 1
  wt=$(_forward_resolve_worktree "$sid") || return 1
  integrity=$(_forward_worktree_state "$sid" "$allow_absent") || rc=$?
  case "$scope:$rc:$integrity" in
    recovery:0:verified|postclaim:0:verified|postclaim:0:absent_new) ;;
    *) return 1 ;;
  esac
  _forward_plan_present "$sid" "$wt" && plan=true
  _forward_classify "$sid" "$scope" "$integrity" "$plan" || return 1
  if [[ "$_FORWARD_SOURCE" != "$expected_source" \
      || "$_FORWARD_BLOB" != "$expected_blob" \
      || "$_FORWARD_RECORD_DIGEST" != "$expected_record" \
      || "$_FORWARD_ACTION:$_FORWARD_REASON" != resume:resumable ]]; then
    return 1
  fi
}

_forward_context_path() {
  local sid="$1" parent="$LOCK_DIR/.recovery-contexts"
  _forward_sid_valid "$sid" || return 1
  ( umask 077; mkdir -p "$parent" ) 2>/dev/null || return 1
  printf '%s\n' "$parent/recovery.scan.${sid}.json"
}

# A missing post-claim worktree is recoverable only when an immutable context
# from the same target record proves that this exact cycle was bound as
# absent_new. This read grants no effect; it only selects the safe probe mode.
_forward_absent_context_admitted() {
  local sid="$1" source="$2" blob="$3" record="$4" context row
  local c_story c_source c_blob c_record c_attempt c_attempt_digest
  local c_retained c_records c_event c_state c_integrity c_action c_reason
  local c_fields c_digest
  context=$(_forward_context_path "$sid") || return 1
  [[ -e "$context" && ! -L "$context" ]] || return 1
  row=$(forward_context_read "$context") || return 1
  IFS=$'\t' read -r c_story c_source c_blob c_record c_attempt c_attempt_digest \
    c_retained c_records c_event c_state c_integrity c_action c_reason \
    c_fields c_digest <<< "$row"
  [[ "$c_story:$c_source:$c_blob:$c_record" == "$sid:$source:$blob:$record" \
      && "$c_attempt:$c_attempt_digest:$c_retained:$c_records" == \
        none:none:none:none \
      && "$c_event:$c_state:$c_integrity:$c_action:$c_reason:$c_fields" == \
        none:none:absent_new:resume:resumable:none \
      && "$c_digest" =~ ^[0-9a-f]{64}$ ]]
}

_forward_bind_context() {
  local path="$1"
  shift
  local expected actual
  expected=$(IFS=$'\t'; printf '%s' "$*")
  if forward_context_install "$path" "$@"; then
    forward_context_read "$path"
    return $?
  fi
  actual=$(forward_context_read "$path") || return 1
  [[ "${actual%$'\t'*}" == "$expected" ]] || return 1
  printf '%s\n' "$actual"
}

# Restore only the exact validated context row that this cycle CAS-retired.
# This is used when retry persistence fails before any spawn was attempted.
_forward_restore_context_row() {
  [[ "$#" -eq 2 ]] || return 1
  local path="$1" row="$2" actual
  local story source blob record attempt attempt_digest retained records
  local event state integrity action reason fields digest
  IFS=$'\t' read -r story source blob record attempt attempt_digest retained \
    records event state integrity action reason fields digest <<< "$row"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  forward_context_install "$path" "$story" "$source" "$blob" "$record" \
    "$attempt" "$attempt_digest" "$retained" "$records" "$event" "$state" \
    "$integrity" "$action" "$reason" "$fields" || return 1
  actual=$(forward_context_read "$path") || return 1
  [[ "$actual" == "$row" ]]
}

_forward_manifest_args() {
  local manifest="$1" rows field _name _digest value _location
  _FORWARD_INTENDED=none
  _FORWARD_JOURNAL_ARGS=()
  [[ "$manifest" == *$'\n'* ]] || return 1
  rows=${manifest#*$'\n'}
  while IFS=$'\t' read -r field _name _digest value _location; do
    [[ -n "$field" ]] || continue
    case "$field" in phase_status|status) ;; *) return 1 ;; esac
    _FORWARD_JOURNAL_ARGS+=("$field" "$value")
  done <<< "$rows"
  (( ${#_FORWARD_JOURNAL_ARGS[@]} >= 2 )) || return 1
  if [[ "${_FORWARD_JOURNAL_ARGS[*]}" == "phase_status failed status failed" ]]; then
    _FORWARD_INTENDED="phase_status=failed,status=failed"
  elif [[ "${_FORWARD_JOURNAL_ARGS[*]}" == "phase_status commit_stalled" ]]; then
    _FORWARD_INTENDED="phase_status=commit_stalled"
  elif [[ "${_FORWARD_JOURNAL_ARGS[*]}" == "status failed" ]]; then
    _FORWARD_INTENDED="status=failed"
  elif [[ "${_FORWARD_JOURNAL_ARGS[*]}" == "status escalated" ]]; then
    _FORWARD_INTENDED="status=escalated"
  else
    return 1
  fi
}

_forward_project() {
  local sid="$1" expected_source="$2"
  shift 2
  GAAI_LIFECYCLE_CALLER_ASSET=".gaai/core/scripts/delivery-daemon.sh" \
  GAAI_LIFECYCLE_EXPECTED_SOURCE_SHA="$expected_source" \
    _journal_persist_lifecycle "$sid" recovery.scan "$@"
}

# A repeated commit-phase outcome is a durable forward policy stall, never a
# phase rewind or permission to buy another hosted attempt.  The observation
# helper ignores daemon-authored bookkeeping and binds the decision to the
# current candidate content.  Return 0 to permit the existing resume path, 2
# after a verified commit_stalled projection, 1 on ambiguous evidence, and 4
# when mandatory evidence cannot be persisted.
_forward_commit_retry_guard() {
  local sid="$1" wt="$2" integrity="$3" plan="$4"
  [[ "$_FORWARD_ACTION:$_FORWARD_REASON:$_FORWARD_PHASE" == \
      "resume:resumable:qa_passed" ]] || return 0
  local observation snapshot _cd_new _cd_outcome _cd_progress
  local _cd_state_count _cd_state_outcome _cd_state_progress
  local _cd_event_digest _cd_state_digest
  local _cd_threshold="${COMMIT_PHASE_RETRY_THRESHOLD:-3}"
  observation=$(_commit_retry_observe "$sid" "$wt" \
    "origin/${TARGET_BRANCH}" "$_cd_threshold") || return 1
  IFS='|' read -r _cd_new _cd_outcome _cd_progress <<< "$observation"
  [[ "$_cd_new" =~ ^[1-9][0-9]*$ && -n "$_cd_outcome" ]] || return 1
  snapshot=$(_commit_retry_state_snapshot "$sid") || return 1
  IFS='|' read -r _cd_state_count _cd_state_outcome _cd_state_progress \
    _cd_event_digest _cd_state_digest <<< "$snapshot"
  [[ "$_cd_state_count:$_cd_state_outcome:$_cd_state_progress" == \
      "$_cd_new:$_cd_outcome:$_cd_progress" \
      && "$_cd_event_digest" =~ ^[0-9a-f]{64}$ \
      && "$_cd_state_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  if (( _cd_new < _cd_threshold )); then
    log "${GREEN}[FORWARD-RECOVERY] ${sid} commit outcome remains below containment policy — resume remains eligible${NC}"
    return 0
  fi

  local context row context_digest
  context=$(_forward_context_path "$sid") || return 1
  row=$(_forward_bind_context "$context" "$sid" "$_FORWARD_SOURCE" \
    "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" none none none none \
    "$_cd_event_digest" "$_cd_state_digest" "$integrity" \
    forward_commit_stall stall_pending phase_status=commit_stalled) || return 1
  context_digest=${row##*$'\t'}
  _forward_resume_policy_stall "$sid" "$wt" "$context" "$context_digest" \
    "$_FORWARD_SOURCE" "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" \
    "$_cd_event_digest" "$_cd_state_digest" || return $?
  return 2
}

# Resume a policy-stall context created before its journal run-state.  The
# context carries one fixed intention; a restart may create/resume only that
# transition after proving the original qa_passed object is still exact.  The
# same path also finalizes a post-projector context whose remote field is
# already current.
_forward_resume_policy_stall() {
  local sid="$1" wt="$2" context="$3" context_digest="$4"
  local bound_source="$5" bound_blob="$6" bound_record="$7"
  local expected_event="${8:-none}" expected_state="${9:-none}"
  local retained_manifest="${10:-}" attempt_evidence=none
  local retained_state_digest=none retained_rows=""
  local observation snapshot _cd_new _cd_outcome _cd_progress
  local _cd_state_count _cd_state_outcome _cd_state_progress
  local _cd_event_digest _cd_state_digest
  local _cd_threshold="${COMMIT_PHASE_RETRY_THRESHOLD:-3}"
  observation=$(_commit_retry_observe "$sid" "$wt" \
    "origin/${TARGET_BRANCH}" "$_cd_threshold") || return 1
  IFS='|' read -r _cd_new _cd_outcome _cd_progress <<< "$observation"
  snapshot=$(_commit_retry_state_snapshot "$sid") || return 1
  IFS='|' read -r _cd_state_count _cd_state_outcome _cd_state_progress \
    _cd_event_digest _cd_state_digest <<< "$snapshot"
  [[ "$_cd_new" =~ ^[1-9][0-9]*$ && -n "$_cd_outcome" \
      && "$_cd_progress" == stall_pending \
      && "$_cd_state_count:$_cd_state_outcome:$_cd_state_progress" == \
        "$_cd_new:$_cd_outcome:$_cd_progress" \
      && "$_cd_event_digest" =~ ^[0-9a-f]{64}$ \
      && "$_cd_state_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$expected_event" == none || "$expected_event" == "$_cd_event_digest" ]] \
    || return 1
  [[ "$expected_state" == none || "$expected_state" == "$_cd_state_digest" ]] \
    || return 1
  (( _cd_new >= _cd_threshold )) || return 1

  if [[ -n "$retained_manifest" ]]; then
    _forward_manifest_args "$retained_manifest" || return 1
    [[ "$_FORWARD_INTENDED" == phase_status=commit_stalled ]] || return 1
    local retained_token retained_source retained_token_digest retained_records_digest
    local retained_header="" retained_line
    retained_rows=""
    while IFS= read -r retained_line; do
      if [[ -z "$retained_header" ]]; then
        retained_header="$retained_line"
      else
        retained_rows="${retained_rows}${retained_rows:+$'\n'}${retained_line}"
      fi
    done <<< "$retained_manifest"
    [[ -n "$retained_header" && -n "$retained_rows" ]] || return 1
    IFS=$'\t' read -r retained_token retained_source retained_token_digest \
      retained_state_digest retained_records_digest \
      <<< "$retained_header"
    [[ "$retained_token" =~ ^[0-9a-f]{64}$ \
        && "$retained_token_digest" =~ ^[0-9a-f]{64}$ \
        && "$retained_state_digest" =~ ^[0-9a-f]{64}$ \
        && "$retained_records_digest" =~ ^[0-9a-f]{64}$ \
        && "$retained_source" == "$bound_source" ]] || return 1
    attempt_evidence="$retained_token_digest"
  fi

  case "$_FORWARD_ACTION:$_FORWARD_REASON:$_FORWARD_PHASE" in
    resume:resumable:qa_passed)
      [[ "$bound_source" == "$_FORWARD_SOURCE" \
          && "$bound_blob" == "$_FORWARD_BLOB" \
          && "$bound_record" == "$_FORWARD_RECORD_DIGEST" ]] || return 1
      _forward_project "$sid" "$_FORWARD_SOURCE" phase_status commit_stalled \
        || return 1
      ;;
    hold_operator:policy_stall:commit_stalled)
      if [[ "$retained_state_digest" != none ]]; then
        local _field _name _digest _value location
        while IFS=$'\t' read -r _field _name _digest _value location; do
          [[ -n "$_field" && "$location" == applied ]] || return 1
        done <<< "$retained_rows"
        _journal_retire_accepted_lifecycle "$sid" recovery.scan \
          "$retained_state_digest" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  rm -f "$_FORWARD_SNAPSHOT"

  local current_integrity=unknown current_plan=false
  current_integrity=$(_forward_worktree_state "$sid" false) || return 1
  _forward_plan_present "$sid" "$wt" && current_plan=true
  _forward_classify "$sid" recovery "$current_integrity" "$current_plan" || return 1
  if [[ "$_FORWARD_ACTION:$_FORWARD_REASON:$_FORWARD_PHASE" != \
      "hold_operator:policy_stall:commit_stalled" ]] \
      || ! _lifecycle_snapshot_matches "$_FORWARD_SNAPSHOT" "$sid" \
        phase_status commit_stalled; then
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  fi
  forward_context_remove "$context" "$context_digest" || {
    rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  _commit_retry_clear "$sid" "$_cd_state_digest" || {
    rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  _forward_evidence_for_intention "$sid" accepted policy_stall "$attempt_evidence" \
    "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
    phase_status=commit_stalled || return 4
  log "[$(date '+%Y-%m-%dT%H:%M:%SZ')] ${sid} repeated commit outcome reached containment; phase field updated, relaunch inhibited"
  notify_escalation "$sid" "Commit-phase repeated failure — stalled" \
    "Repeated commit-phase failure reached containment; inspect candidate progress before an operator-owned reset"
  rm -f "$_FORWARD_SNAPSHOT"
}

_forward_runner_state() {
  local sid="$1" handles live
  command -v node >/dev/null 2>&1 || return 1
  handles=$(node "$PROJECT_DIR/.gaai/core/adapters/claude-code/nested-claude-spawn.js" \
    --reconcile-handles 2>/dev/null) || return 1
  live=$(python3 - "$sid" "$handles" <<'PY'
import json, re, sys
sid, raw = sys.argv[1:]
try:
    report = json.loads(raw)
    if not isinstance(report, dict):
        raise ValueError
    for key in ("live", "stale", "expired", "unreadable"):
        if not isinstance(report.get(key), list):
            raise ValueError
    if report["unreadable"]:
        raise ValueError
    def identity(item):
        if not isinstance(item, dict):
            raise ValueError
        story_id = item.get("story_id")
        pid = item.get("pid")
        state = item.get("state")
        if (not isinstance(story_id, str)
                or re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", story_id) is None
                or isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0
                or state not in ("running", "polling", "killed")):
            raise ValueError
        return story_id
    live_ids = [identity(item) for item in report["live"]]
    stale_ids = [identity(item) for item in report["stale"]]
    expired_ids = [identity(item) for item in report["expired"]]
    found = sid in live_ids or sid in expired_ids
except (ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
print("1" if found else "0")
PY
  ) || return 1
  case "$live" in
    0) printf 'clear\n' ;;
    1) printf 'live\n' ;;
    *) return 1 ;;
  esac
}

_forward_runner_clear() {
  [[ "$(_forward_runner_state "$1")" == clear ]]
}

_forward_active_markers_clear() {
  local sid="$1" marker
  for marker in "$LOCK_DIR/${sid}.plan.active" "$LOCK_DIR/${sid}.impl.active" \
      "$LOCK_DIR/${sid}.qa.active" "$LOCK_DIR/${sid}.commit.active"; do
    [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
  done
}

_forward_lock_state() {
  local sid="$1" lock pid
  _forward_sid_valid "$sid" || return 1
  lock="$LOCK_DIR/$sid.lock"
  if [[ ! -e "$lock" && ! -L "$lock" ]]; then
    printf 'absent\tnone\n'
    return 0
  fi
  pid=$(python3 - "$lock" <<'PY'
import os, stat, sys
path = sys.argv[1]
fd = None
try:
    before = os.lstat(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(fd)
    after = os.lstat(path)
    if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino)):
        raise ValueError
    raw = b""
    while True:
        chunk = os.read(fd, 1024)
        if not chunk:
            break
        raw += chunk
    value = raw.decode("ascii").strip()
    if not value.isdigit() or int(value) < 1:
        raise ValueError
    print(value)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)
PY
  ) || { printf 'unknown\tnone\n'; return 1; }
  if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
    printf 'live\t%s\n' "$pid"
  else
    printf 'dead\t%s\n' "$pid"
  fi
}

_forward_retire_dead_lock() {
  local sid="$1" expected_pid="$2" lock
  _forward_sid_valid "$sid" || return 1
  [[ "$expected_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  lock="$LOCK_DIR/$sid.lock"
  python3 - "$lock" "$expected_pid" <<'PY'
import errno, fcntl, os, secrets, stat, sys
path, expected = sys.argv[1:]
parent, name = os.path.split(path)
dir_fd = fd = None
quarantine = None
try:
    parent_before = os.lstat(parent)
    dir_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
    parent_opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(parent_opened.st_mode)
            or parent_opened.st_uid != os.geteuid()
            or parent_opened.st_mode & 0o077
            or (parent_opened.st_dev, parent_opened.st_ino)
               != (parent_before.st_dev, parent_before.st_ino)):
        raise ValueError
    before = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
    # Serialize claim of this exact inode. A competing reader may already
    # have opened it, but after acquiring the inode lock it must re-stat the
    # directory entry and observe either absence or a successor identity.
    fcntl.flock(fd, fcntl.LOCK_EX)
    parent_current = os.lstat(parent)
    if ((parent_current.st_dev, parent_current.st_ino)
            != (parent_opened.st_dev, parent_opened.st_ino)
            or parent_current.st_uid != os.geteuid()
            or parent_current.st_mode & 0o077):
        raise ValueError
    opened = os.fstat(fd)
    after = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    identity = (opened.st_dev, opened.st_ino)
    if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or identity != (before.st_dev, before.st_ino)
            or identity != (after.st_dev, after.st_ino)):
        raise ValueError
    raw = b""
    while True:
        chunk = os.read(fd, 1024)
        if not chunk:
            break
        raw += chunk
    if raw.decode("ascii").strip() != expected:
        raise ValueError
    # PID observations made before this inode lock may be stale through PID
    # reuse. Only an immediate ESRCH proves that the exact numeric owner is
    # still absent; live, inaccessible and ambiguous results all preserve it.
    try:
        os.kill(int(expected), 0)
    except OSError as error:
        if error.errno != errno.ESRCH:
            raise ValueError
    else:
        raise ValueError
    quarantine = ".%s.%s.retire" % (name, secrets.token_hex(12))
    os.rename(name, quarantine, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    moved = os.stat(quarantine, dir_fd=dir_fd, follow_symlinks=False)
    if identity != (moved.st_dev, moved.st_ino):
        # A non-cooperating successor replaced the name after validation.
        # Restore that successor only when the destination is still absent;
        # never overwrite a newer entry and never unlink the current name.
        os.link(
            quarantine, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd,
            follow_symlinks=False,
        )
        os.fsync(dir_fd)
        os.unlink(quarantine, dir_fd=dir_fd)
        quarantine = None
        os.fsync(dir_fd)
        raise ValueError
    os.fsync(dir_fd)
    os.unlink(quarantine, dir_fd=dir_fd)
    quarantine = None
    os.fsync(dir_fd)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if fd is not None:
        os.close(fd)
    if dir_fd is not None:
        os.close(dir_fd)
PY
}

# Last-moment relaunch: every mutable precondition is re-read after the
# context is bound. The context is retired only immediately before spawn.
_forward_relaunch() {
  local sid="$1" context="$2" expected_context_digest="$3"
  local wt integrity plan=false row c_story c_source c_blob c_record c_attempt
  local c_attempt_digest c_retained c_records c_event c_state
  local c_integrity c_action c_reason c_fields c_digest
  _forward_sid_valid "$sid" || return 1
  wt=$(_forward_resolve_worktree "$sid") || return 1
  _forward_plan_present "$sid" "$wt" && plan=true
  _forward_classify "$sid" recovery unknown "$plan" || return 1
  row=$(forward_context_read "$context") || { rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  IFS=$'\t' read -r c_story c_source c_blob c_record c_attempt c_attempt_digest \
    c_retained c_records c_event c_state c_integrity c_action c_reason c_fields \
    c_digest <<< "$row"
  if [[ "$c_digest" != "$expected_context_digest" || "$c_story" != "$sid" \
      || "$c_source" != "$_FORWARD_SOURCE" || "$c_blob" != "$_FORWARD_BLOB" \
      || "$c_record" != "$_FORWARD_RECORD_DIGEST" || "$c_action" != resume \
      || "$c_reason" != resumable || "$c_fields" != none \
      || "$c_event:$c_state" != none:none ]]; then
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  fi
  rm -f "$_FORWARD_SNAPSHOT"
  local bound_scope=recovery bound_allow_absent=false
  if [[ "$c_integrity" == absent_new ]]; then
    bound_scope=postclaim
    bound_allow_absent=true
  elif [[ "$c_integrity" != verified ]]; then
    return 1
  fi
  local pending_rc=0
  _journal_inspect_pending_lifecycle "$sid" recovery.scan >/dev/null 2>&1 || pending_rc=$?
  [[ "$pending_rc" -eq 2 ]] || return 1
  _forward_revalidate_after_reconcile "$sid" "$c_source" "$c_blob" \
    "$c_record" "$bound_scope" "$bound_allow_absent" || return 1
  rm -f "$_FORWARD_SNAPSHOT"
  local lock_state lock_pid=""
  IFS=$'\t' read -r lock_state lock_pid < <(_forward_lock_state "$sid") || return 1
  [[ "$lock_state" != unknown ]] || return 1
  [[ "$lock_state" != live ]] || return 2
  _forward_active_markers_clear "$sid" || return 1
  local runner_state
  runner_state=$(_forward_runner_state "$sid") || return 1
  [[ "$runner_state" != live ]] || return 2
  ! tmux has-session -t "gaai-deliver-${sid}" 2>/dev/null || return 2
  local active_now
  active_now=$(active_count) || return 1
  (( active_now < MAX_CONCURRENT )) || return 2
  ! has_exceeded_retries "$sid" || return 1
  local reconcile_rc=0
  _reconcile_story_file_from_staging "$sid" "$wt" "$c_source" \
    "$bound_allow_absent" || reconcile_rc=$?
  [[ "$reconcile_rc" -le 1 ]] || return 1
  _forward_revalidate_after_reconcile "$sid" "$c_source" "$c_blob" \
    "$c_record" "$bound_scope" "$bound_allow_absent" || return 1
  rm -f "$_FORWARD_SNAPSHOT"
  local trace_id
  trace_id=$(node -e "import('node:crypto').then(m=>process.stdout.write(m.randomUUID()))" 2>/dev/null \
    || python3 -c "import uuid; print(str(uuid.uuid4()),end='')") || return 1
  if ! _forward_last_edge_guard "$sid" "$c_source" "$c_blob" "$c_record" \
      "$bound_scope" "$bound_allow_absent"; then
    if ! _forward_evidence "$sid" blocked remote_changed "$c_attempt_digest" \
        "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
      rm -f "${_FORWARD_SNAPSHOT:-}"
      return 4
    fi
    rm -f "${_FORWARD_SNAPSHOT:-}"
    return 1
  fi
  rm -f "$_FORWARD_SNAPSHOT"
  if [[ "$lock_state" == dead ]]; then
    _forward_retire_dead_lock "$sid" "$lock_pid" || return 1
    # Retiring an exact dead owner changes the execution-authority snapshot.
    # Preserve the context and retry budget; a fresh cycle must re-admit every
    # last-edge precondition before it can spawn.
    return 2
  fi
  forward_context_remove "$context" "$expected_context_digest" || return 1
  if ! increment_retry "$sid"; then
    if ! _forward_restore_context_row "$context" "$row"; then
      _forward_evidence "$sid" blocked context_invalid "$c_attempt_digest" \
        "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none || return 4
    fi
    return 1
  fi
  launch_3phase_in_tmux "$sid" "$trace_id" "$c_source" "$c_blob" "$c_record"
  return $?
}

_forward_retained_settle() {
  local sid="$1" manifest="$2" context="$3" context_digest="$4"
  local header rows token retained_source token_digest state_digest records_digest
  header=${manifest%%$'\n'*}
  rows=${manifest#*$'\n'}
  IFS=$'\t' read -r token retained_source token_digest state_digest records_digest <<< "$header"
  [[ "$token" =~ ^[0-9a-f]{64}$ && "$token_digest" =~ ^[0-9a-f]{64}$ \
      && "$state_digest" =~ ^[0-9a-f]{64}$ && "$records_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  local accepted_before=false
  if _lifecycle_snapshot_matches "$_FORWARD_SNAPSHOT" "$sid" "${_FORWARD_JOURNAL_ARGS[@]}"; then
    accepted_before=true
    local _field _name _digest _value location
    while IFS=$'\t' read -r _field _name _digest _value location; do
      [[ "$location" == applied ]] || return 1
    done <<< "$rows"
  else
    _forward_project "$sid" "$_FORWARD_SOURCE" "${_FORWARD_JOURNAL_ARGS[@]}" || return 1
  fi
  rm -f "$_FORWARD_SNAPSHOT"

  local verify_integrity=unknown verify_plan=false wt refreshed refreshed_rows pending_rc=0
  if ! verify_integrity=$(_forward_worktree_state "$sid" false); then
    rm -f "${_FORWARD_SNAPSHOT:-}"
    return 2
  fi
  if [[ "$verify_integrity" != verified ]]; then
    rm -f "${_FORWARD_SNAPSHOT:-}"
    return 2
  fi
  wt=$(_forward_resolve_worktree "$sid") || return 1
  _forward_plan_present "$sid" "$wt" && verify_plan=true
  if ! _forward_classify "$sid" recovery "$verify_integrity" "$verify_plan"; then
    rm -f "${_FORWARD_SNAPSHOT:-}"
    return 3
  fi
  _lifecycle_snapshot_matches "$_FORWARD_SNAPSHOT" "$sid" "${_FORWARD_JOURNAL_ARGS[@]}" || {
    rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  if [[ "$accepted_before" == true ]]; then
    refreshed=$(_journal_inspect_pending_lifecycle "$sid" recovery.scan) || {
      rm -f "$_FORWARD_SNAPSHOT"; return 1; }
    refreshed_rows=${refreshed#*$'\n'}
    local _field _name _digest _value location
    while IFS=$'\t' read -r _field _name _digest _value location; do
      [[ "$location" == applied ]] || { rm -f "$_FORWARD_SNAPSHOT"; return 1; }
    done <<< "$refreshed_rows"
    # Remove the decision context first. If state retirement then fails, the
    # exact retained attempt remains sufficient to bind a fresh context.
    forward_context_remove "$context" "$context_digest" || {
      rm -f "$_FORWARD_SNAPSHOT"; return 1; }
    _journal_retire_accepted_lifecycle "$sid" recovery.scan "$state_digest" || {
      rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  else
    # A successful projector verifies the remote bytes and retires its own
    # run-state. Absence is therefore the success proof here; attempting a
    # second retirement turns success into a permanent retry loop.
    _journal_inspect_pending_lifecycle "$sid" recovery.scan >/dev/null 2>&1 || pending_rc=$?
    [[ "$pending_rc" -eq 2 ]] || { rm -f "$_FORWARD_SNAPSHOT"; return 1; }
    forward_context_remove "$context" "$context_digest" || {
      rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  fi
  rm -f "$_FORWARD_SNAPSHOT"
}

_forward_recovery_one() {
  local sid="$1" integrity=unknown wt plan=false manifest manifest_rc=0
  local context context_row context_digest intended=none
  local admitted_source admitted_blob admitted_record admitted_source_digest
  local recovery_allow_absent=false recovery_scope=recovery
  _forward_sid_valid "$sid" || return 1
  wt=$(_forward_resolve_worktree "$sid") || return 1
  _forward_plan_present "$sid" "$wt" && plan=true
  if ! _forward_classify "$sid" recovery unknown "$plan"; then
    local zero_digest="0000000000000000000000000000000000000000000000000000000000000000"
    _forward_evidence "$sid" blocked source_unavailable none "$zero_digest" \
      "$zero_digest" none || return 4
    return 1
  fi
  admitted_source="$_FORWARD_SOURCE"
  admitted_blob="$_FORWARD_BLOB"
  admitted_record="$_FORWARD_RECORD_DIGEST"
  admitted_source_digest="$_FORWARD_SOURCE_DIGEST"
  if [[ "$_FORWARD_ACTION" == block_invalid_record ]]; then
    _forward_evidence "$sid" blocked invalid_record none "$admitted_source_digest" \
      "$admitted_record" none || return 4
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  fi
  if _forward_absent_context_admitted "$sid" "$admitted_source" \
      "$admitted_blob" "$admitted_record"; then
    recovery_allow_absent=true
    recovery_scope=postclaim
  fi

  manifest=$(_journal_inspect_pending_lifecycle "$sid" recovery.scan) || manifest_rc=$?
  case "$manifest_rc" in
    0|2) ;;
    1)
    _forward_evidence "$sid" blocked invalid_record none "$_FORWARD_SOURCE_DIGEST" \
      "$_FORWARD_RECORD_DIGEST" none || return 4
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
      ;;
    *)
      _forward_evidence "$sid" blocked invalid_record none "$_FORWARD_SOURCE_DIGEST" \
        "$_FORWARD_RECORD_DIGEST" none || return 4
      rm -f "$_FORWARD_SNAPSHOT"
      return 1
      ;;
  esac

  # Crash window: the projector may have verified the remote projection and
  # retired run-state before the coordinator removed its retained context.
  # Adopt only that exact digest-bound context, require its source to be an
  # ancestor of the freshly pinned target, and retire it only when the exact
  # intended fields are already current. Any ambiguity preserves the context.
  if [[ "$manifest_rc" -eq 2 ]]; then
    context=$(_forward_context_path "$sid") || { rm -f "$_FORWARD_SNAPSHOT"; return 1; }
    if [[ -e "$context" || -L "$context" ]]; then
      local stale_row s_story s_source s_blob s_record s_attempt s_attempt_digest
      local s_retained s_records s_event s_state s_integrity s_action s_reason
      local s_fields s_digest stale_context_superseded=false
      stale_row=$(forward_context_read "$context") || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      IFS=$'\t' read -r s_story s_source s_blob s_record s_attempt s_attempt_digest \
        s_retained s_records s_event s_state s_integrity s_action s_reason \
        s_fields s_digest <<< "$stale_row"
      if [[ "$s_story" != "$sid" ]]; then
        rm -f "$_FORWARD_SNAPSHOT"
        return 1
      fi
      case "$s_attempt:$s_action:$s_reason:$s_fields" in
        none:resume:resumable:none)
          [[ "$s_attempt_digest:$s_records:$s_retained" == none:none:none \
              && "$s_event:$s_state" == none:none \
              && ( "$s_integrity" == verified || "$s_integrity" == absent_new ) ]] || {
            rm -f "$_FORWARD_SNAPSHOT"; return 1; }
          ;;
        retained:forward_terminal:terminal_projection:status=failed|\
        retained:forward_terminal:terminal_projection:status=escalated|\
        retained:forward_terminal:terminal_projection:phase_status=failed,status=failed)
          [[ "$s_attempt_digest" =~ ^[0-9a-f]{64}$ \
              && "$s_records" =~ ^[0-9a-f]{64}$ \
              && "$s_retained" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || {
            rm -f "$_FORWARD_SNAPSHOT"; return 1; }
          ;;
        none:forward_commit_stall:stall_pending:phase_status=commit_stalled)
          [[ "$s_attempt_digest:$s_records:$s_retained" == none:none:none \
              && "$s_event" =~ ^[0-9a-f]{64}$ \
              && "$s_state" =~ ^[0-9a-f]{64}$ ]] || {
            rm -f "$_FORWARD_SNAPSHOT"; return 1; }
          ;;
        *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
      esac
      if ! git -C "$PROJECT_DIR" merge-base --is-ancestor \
          "$s_source" "$_FORWARD_SOURCE" 2>/dev/null; then
        rm -f "$_FORWARD_SNAPSHOT"
        return 1
      fi
      # Bind the orphan context to the immutable backlog object and Story
      # record it names. An ancestor relation alone would allow a fabricated
      # context to borrow an unrelated old source.
      local stale_snapshot stale_blob stale_facts stale_record
      stale_snapshot=$(mktemp "$LOCK_DIR/.forward-stale-XXXXXX" 2>/dev/null) || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      chmod 600 "$stale_snapshot" 2>/dev/null || {
        rm -f "$stale_snapshot" "$_FORWARD_SNAPSHOT"; return 1; }
      stale_blob=$(git -C "$PROJECT_DIR" rev-parse \
        "${s_source}:${BACKLOG_REL}" 2>/dev/null) || {
        rm -f "$stale_snapshot" "$_FORWARD_SNAPSHOT"; return 1; }
      if [[ "$stale_blob" != "$s_blob" ]] \
          || ! git -C "$PROJECT_DIR" show "${s_source}:${BACKLOG_REL}" \
            > "$stale_snapshot" 2>/dev/null \
          || ! stale_facts=$(forward_classify_snapshot "$sid" "$stale_snapshot" \
            "$s_source" "$s_blob" recovery unknown false); then
        rm -f "$stale_snapshot" "$_FORWARD_SNAPSHOT"
        return 1
      fi
      IFS=$'\t' read -r _ _ _ _ _ stale_record _ _ <<< "$stale_facts"
      rm -f "$stale_snapshot"
      if [[ "$stale_record" != "$s_record" ]]; then
        rm -f "$_FORWARD_SNAPSHOT"
        return 1
      fi
      if [[ "$s_attempt:$s_action:$s_reason:$s_fields" == \
          none:resume:resumable:none ]]; then
        local stale_relaunch_rc=0 stale_source_digest
        stale_source_digest=$(_forward_sha256 "$s_source") || {
          rm -f "$_FORWARD_SNAPSHOT"; return 1; }
        if [[ "$s_source:$s_blob:$s_record" != \
            "$_FORWARD_SOURCE:$_FORWARD_BLOB:$_FORWARD_RECORD_DIGEST" ]]; then
          case "$_FORWARD_STATUS:$_FORWARD_PHASE" in
            in_progress:not_started|in_progress:planned|in_progress:implemented|\
            in_progress:qa_failed|in_progress:qa_passed) ;;
            *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
          esac
          _forward_evidence "$sid" retryable remote_changed none \
            "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none || return 4
          forward_context_remove "$context" "$s_digest" || {
            rm -f "$_FORWARD_SNAPSHOT"; return 1; }
          stale_context_superseded=true
          # The current pinned snapshot remains live. The ordinary rc2 path
          # below now performs typed repair, reclassification and a fresh
          # context bind against B; its final repin still blocks A->B->C.
        else
          rm -f "$_FORWARD_SNAPSHOT"
          _forward_relaunch "$sid" "$context" "$s_digest" || stale_relaunch_rc=$?
          case "$stale_relaunch_rc" in
            0)
              _forward_evidence "$sid" launched resumable none \
                "$stale_source_digest" "$s_record" none || return 4
              return 0
              ;;
            2)
              _forward_evidence "$sid" held effect_inhibited none \
                "$stale_source_digest" "$s_record" none || return 4
              return 2
              ;;
            4) return 4 ;;
            *)
              _forward_evidence "$sid" blocked effect_inhibited none \
                "$stale_source_digest" "$s_record" none || return 4
              return 1
              ;;
          esac
        fi
      fi
      if [[ "$stale_context_superseded" != true ]]; then
        if [[ "$s_attempt:$s_action:$s_reason:$s_fields" == \
            none:forward_commit_stall:stall_pending:phase_status=commit_stalled ]]; then
          local stale_policy_rc=0 stale_policy_source_digest
          if ! stale_policy_source_digest=$(_forward_sha256 "$s_source"); then
            local stale_policy_zero_digest="0000000000000000000000000000000000000000000000000000000000000000"
            rm -f "$_FORWARD_SNAPSHOT"
            _forward_evidence_for_intention "$sid" retryable source_unavailable \
              none "$stale_policy_zero_digest" "$s_record" \
              phase_status=commit_stalled || return 4
            return 1
          fi
          _forward_resume_policy_stall "$sid" "$wt" "$context" "$s_digest" \
            "$s_source" "$s_blob" "$s_record" "$s_event" "$s_state" \
            || stale_policy_rc=$?
          if [[ "$stale_policy_rc" -ne 0 ]]; then
            rm -f "$_FORWARD_SNAPSHOT" 2>/dev/null || true
            [[ "$stale_policy_rc" -eq 4 ]] && return 4
            _forward_evidence_for_intention "$sid" retryable policy_stall none \
              "$stale_policy_source_digest" "$s_record" \
              phase_status=commit_stalled || return 4
            return 1
          fi
          return 0
        fi
        local accepted_args=()
        case "$s_fields" in
          phase_status=commit_stalled) accepted_args=(phase_status commit_stalled) ;;
          phase_status=failed,status=failed) accepted_args=(phase_status failed status failed) ;;
          status=failed) accepted_args=(status failed) ;;
          status=escalated) accepted_args=(status escalated) ;;
          *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
        esac
        _lifecycle_snapshot_matches "$_FORWARD_SNAPSHOT" "$sid" "${accepted_args[@]}" || {
          rm -f "$_FORWARD_SNAPSHOT"; return 1; }
        forward_context_remove "$context" "$s_digest" || {
          rm -f "$_FORWARD_SNAPSHOT"; return 1; }
        _forward_evidence_for_intention "$sid" accepted already_current \
          "$s_attempt_digest" "$_FORWARD_SOURCE_DIGEST" \
          "$_FORWARD_RECORD_DIGEST" "$s_fields" || return 4
      fi
    elif [[ "$_FORWARD_ACTION:$_FORWARD_REASON:$_FORWARD_PHASE" == \
        hold_operator:policy_stall:commit_stalled ]]; then
      # Crash window after context retirement but before exact helper-state
      # retirement. Re-adopt only the still-current content-bound stall state;
      # absence or ambiguity remains fail-closed.
      local adopted_observation adopted_snapshot adopted_count adopted_outcome
      local adopted_progress adopted_state_count adopted_state_outcome
      local adopted_state_progress adopted_event adopted_state
      adopted_observation=$(_commit_retry_observe "$sid" "$wt" \
        "origin/${TARGET_BRANCH}" "${COMMIT_PHASE_RETRY_THRESHOLD:-3}") || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      IFS='|' read -r adopted_count adopted_outcome adopted_progress \
        <<< "$adopted_observation"
      adopted_snapshot=$(_commit_retry_state_snapshot "$sid") || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      IFS='|' read -r adopted_state_count adopted_state_outcome \
        adopted_state_progress adopted_event adopted_state <<< "$adopted_snapshot"
      [[ "$adopted_count:$adopted_outcome:$adopted_progress" == \
          "$adopted_state_count:$adopted_state_outcome:$adopted_state_progress" \
          && "$adopted_progress" == stall_pending \
          && "$adopted_event" =~ ^[0-9a-f]{64}$ \
          && "$adopted_state" =~ ^[0-9a-f]{64}$ ]] || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      context_row=$(_forward_bind_context "$context" "$sid" "$_FORWARD_SOURCE" \
        "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" none none none none \
        "$adopted_event" "$adopted_state" "$integrity" \
        forward_commit_stall stall_pending phase_status=commit_stalled) || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      context_digest=${context_row##*$'\t'}
      local adopted_policy_rc=0
      local adopted_policy_source_digest="$_FORWARD_SOURCE_DIGEST"
      local adopted_policy_record_digest="$_FORWARD_RECORD_DIGEST"
      _forward_resume_policy_stall "$sid" "$wt" "$context" "$context_digest" \
        "$_FORWARD_SOURCE" "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" \
        "$adopted_event" "$adopted_state" || adopted_policy_rc=$?
      if [[ "$adopted_policy_rc" -ne 0 ]]; then
        rm -f "$_FORWARD_SNAPSHOT"
        [[ "$adopted_policy_rc" -eq 4 ]] && return 4
        _forward_evidence_for_intention "$sid" retryable policy_stall none \
          "$adopted_policy_source_digest" "$adopted_policy_record_digest" \
          phase_status=commit_stalled || return 4
        return 1
      fi
      return 0
    fi
  fi

  # With no retained run left to settle, the pinned target may now authorize
  # a typed repair. Journal evidence is always authenticated before this
  # first potentially mutating boundary.
  if [[ "$manifest_rc" -eq 2 ]]; then
    rm -f "$_FORWARD_SNAPSHOT"
    integrity=$(_forward_prepare_worktree "$sid" "$admitted_source" \
      "$recovery_allow_absent") || integrity=unknown
    plan=false
    _forward_plan_present "$sid" "$wt" && plan=true
    if ! _forward_classify "$sid" "$recovery_scope" "$integrity" "$plan" \
        || [[ "$_FORWARD_SOURCE" != "$admitted_source" \
            || "$_FORWARD_BLOB" != "$admitted_blob" \
            || "$_FORWARD_RECORD_DIGEST" != "$admitted_record" ]]; then
      _forward_evidence "$sid" blocked remote_changed none \
        "$admitted_source_digest" "$admitted_record" none || return 4
      rm -f "${_FORWARD_SNAPSHOT:-}"
      return 1
    fi
  fi

  if [[ "$manifest_rc" -eq 0 ]]; then
    _forward_manifest_args "$manifest" || {
      _forward_evidence "$sid" blocked invalid_record none "$_FORWARD_SOURCE_DIGEST" \
        "$_FORWARD_RECORD_DIGEST" none || return 4
      rm -f "$_FORWARD_SNAPSHOT"
      return 1
    }
    local token retained_source token_digest state_digest records_digest
    local retained_action retained_reason
    IFS=$'\t' read -r token retained_source token_digest state_digest records_digest \
      <<< "${manifest%%$'\n'*}"
    if [[ "$_FORWARD_INTENDED" == phase_status=commit_stalled ]]; then
      context=$(_forward_context_path "$sid") || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      [[ -e "$context" && ! -L "$context" ]] || {
        _forward_evidence_for_intention "$sid" blocked context_invalid "$token_digest" \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
          phase_status=commit_stalled || return 4
        rm -f "$_FORWARD_SNAPSHOT"
        return 1
      }
      local stall_row stall_story stall_source stall_blob stall_record
      local stall_attempt stall_attempt_digest stall_retained stall_records
      local stall_event stall_state stall_integrity stall_action stall_reason
      local stall_fields stall_context_digest
      stall_row=$(forward_context_read "$context") || {
        rm -f "$_FORWARD_SNAPSHOT"; return 1; }
      IFS=$'\t' read -r stall_story stall_source stall_blob stall_record \
        stall_attempt stall_attempt_digest stall_retained stall_records \
        stall_event stall_state stall_integrity stall_action stall_reason \
        stall_fields stall_context_digest <<< "$stall_row"
      [[ "$stall_story" == "$sid" && "$stall_source" == "$retained_source" \
          && "$stall_attempt:$stall_attempt_digest:$stall_retained:$stall_records" == \
            none:none:none:none \
          && "$stall_event" =~ ^[0-9a-f]{64}$ \
          && "$stall_state" =~ ^[0-9a-f]{64}$ \
          && "$stall_action:$stall_reason:$stall_fields" == \
            forward_commit_stall:stall_pending:phase_status=commit_stalled ]] || {
        _forward_evidence_for_intention "$sid" blocked context_invalid "$token_digest" \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
          phase_status=commit_stalled || return 4
        rm -f "$_FORWARD_SNAPSHOT"
        return 1
      }
      local retained_policy_rc=0
      local retained_policy_source_digest="$_FORWARD_SOURCE_DIGEST"
      local retained_policy_record_digest="$_FORWARD_RECORD_DIGEST"
      _forward_resume_policy_stall "$sid" "$wt" "$context" \
        "$stall_context_digest" "$stall_source" "$stall_blob" "$stall_record" \
        "$stall_event" "$stall_state" "$manifest" || retained_policy_rc=$?
      if [[ "$retained_policy_rc" -ne 0 ]]; then
        rm -f "$_FORWARD_SNAPSHOT"
        [[ "$retained_policy_rc" -eq 4 ]] && return 4
        _forward_evidence_for_intention "$sid" retryable policy_stall \
          "$token_digest" "$retained_policy_source_digest" \
          "$retained_policy_record_digest" phase_status=commit_stalled || return 4
        return 1
      fi
      return 0
    fi
    case "$_FORWARD_INTENDED" in
      phase_status=failed,status=failed)
        retained_action=forward_terminal
        retained_reason=terminal_projection
        ;;
      status=failed|status=escalated)
        retained_action=forward_terminal
        retained_reason=terminal_projection
        ;;
      *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
    esac
    context=$(_forward_context_path "$sid") || { rm -f "$_FORWARD_SNAPSHOT"; return 1; }
    context_row=$(_forward_bind_context "$context" "$sid" "$_FORWARD_SOURCE" \
      "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" retained "$token_digest" \
      "$retained_source" "$records_digest" none none "$integrity" "$retained_action" \
      "$retained_reason" "$_FORWARD_INTENDED") || {
      _forward_evidence_for_intention "$sid" blocked context_invalid "$token_digest" \
        "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
        "$_FORWARD_INTENDED" || return 4
      rm -f "$_FORWARD_SNAPSHOT"
      return 1
    }
    context_digest=${context_row##*$'\t'}
    local retained_settle_rc=0
    local retained_evidence_source_digest="$_FORWARD_SOURCE_DIGEST"
    local retained_evidence_record_digest="$_FORWARD_RECORD_DIGEST"
    local retained_evidence_intended="$_FORWARD_INTENDED"
    _forward_retained_settle "$sid" "$manifest" "$context" "$context_digest" \
      || retained_settle_rc=$?
    if [[ "$retained_settle_rc" -ne 0 ]]; then
      [[ "$retained_settle_rc" -eq 4 ]] && return 4
      local retained_failure_reason=projection_failed
      case "$retained_settle_rc" in
        2) retained_failure_reason=integrity_unverified ;;
        3) retained_failure_reason=source_unavailable ;;
      esac
      _forward_evidence_for_intention "$sid" retryable \
        "$retained_failure_reason" "$token_digest" \
        "$retained_evidence_source_digest" "$retained_evidence_record_digest" \
        "$retained_evidence_intended" || return 4
      rm -f "$_FORWARD_SNAPSHOT" 2>/dev/null || true
      return 1
    fi
    local settled_source_digest="$_FORWARD_SOURCE_DIGEST"
    local settled_record_digest="$_FORWARD_RECORD_DIGEST"
    local settled_intended="$_FORWARD_INTENDED"
    _forward_evidence_for_intention "$sid" accepted already_current \
      "$token_digest" "$settled_source_digest" "$settled_record_digest" \
      "$settled_intended" || {
      rm -f "${_FORWARD_SNAPSHOT:-}"
      return 4
    }
    rm -f "${_FORWARD_SNAPSHOT:-}"
    return 0
  fi

  if [[ "$_FORWARD_ACTION:$_FORWARD_REASON:$_FORWARD_PHASE" == \
      "resume:resumable:qa_passed" ]]; then
    local retry_guard_rc=0
    _forward_commit_retry_guard "$sid" "$wt" "$integrity" "$plan" \
      || retry_guard_rc=$?
    case "$retry_guard_rc" in
      0) ;;
      2) return 0 ;;
      4) return 4 ;;
      *)
        _forward_evidence "$sid" blocked effect_inhibited none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none || return 4
        rm -f "$_FORWARD_SNAPSHOT" 2>/dev/null || true
        return 1
        ;;
    esac
  fi

  case "$_FORWARD_ACTION:$_FORWARD_REASON" in
    resume:resumable) intended=none ;;
    forward_fail:required_plan_absent|forward_fail:worktree_unrecoverable)
      intended="phase_status=failed,status=failed" ;;
    forward_terminal:terminal_projection)
      case "$_FORWARD_PHASE" in
        failed) intended="status=failed" ;;
        escalated|qa_escalated) intended="status=escalated" ;;
        *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
      esac
      ;;
    hold_downstream:merge_terminal_owned)
      _forward_evidence "$sid" held merge_terminal_owned none \
        "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none || return 4
      rm -f "$_FORWARD_SNAPSHOT"; return 0 ;;
    hold_operator:policy_stall)
      _forward_evidence "$sid" held policy_stall none "$_FORWARD_SOURCE_DIGEST" \
        "$_FORWARD_RECORD_DIGEST" none || return 4
      rm -f "$_FORWARD_SNAPSHOT"; return 0 ;;
    no_effect:not_actionable)
      _forward_evidence "$sid" noop not_actionable none "$_FORWARD_SOURCE_DIGEST" \
        "$_FORWARD_RECORD_DIGEST" none || return 4
      rm -f "$_FORWARD_SNAPSHOT"; return 0 ;;
    block_integrity:integrity_unverified|block_invalid_record:*)
      _forward_evidence "$sid" blocked integrity_unverified none \
        "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none || return 4
      rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
    *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
  esac

  context=$(_forward_context_path "$sid") || { rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  context_row=$(_forward_bind_context "$context" "$sid" "$_FORWARD_SOURCE" \
    "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" none none none none \
    none none "$integrity" "$_FORWARD_ACTION" "$_FORWARD_REASON" "$intended") || {
    _forward_evidence_for_intention "$sid" blocked context_invalid none \
      "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
      "$intended" || return 4
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  }
  context_digest=${context_row##*$'\t'}

  if [[ "$_FORWARD_ACTION" == resume ]]; then
    local relaunch_rc=0 relaunch_source_digest="$_FORWARD_SOURCE_DIGEST"
    local relaunch_record_digest="$_FORWARD_RECORD_DIGEST"
    rm -f "$_FORWARD_SNAPSHOT"
    _forward_relaunch "$sid" "$context" "$context_digest" || relaunch_rc=$?
    case "$relaunch_rc" in
      0)
        _forward_evidence "$sid" launched resumable none \
          "$relaunch_source_digest" "$relaunch_record_digest" none || return 4
        return 0
        ;;
      2)
        _forward_evidence "$sid" held effect_inhibited none \
          "$relaunch_source_digest" "$relaunch_record_digest" none || return 4
        return 2
        ;;
      4) return 4 ;;
      *)
        _forward_evidence "$sid" blocked effect_inhibited none \
          "$relaunch_source_digest" "$relaunch_record_digest" none || return 4
        return 1
        ;;
    esac
  fi

  local args=()
  case "$intended" in
    phase_status=failed,status=failed) args=(phase_status failed status failed) ;;
    status=failed) args=(status failed) ;;
    status=escalated) args=(status escalated) ;;
    *) rm -f "$_FORWARD_SNAPSHOT"; return 1 ;;
  esac
  local projected_source_digest="$_FORWARD_SOURCE_DIGEST"
  local projected_record_digest="$_FORWARD_RECORD_DIGEST"
  _forward_project "$sid" "$_FORWARD_SOURCE" "${args[@]}" || {
    _forward_evidence_for_intention "$sid" retryable projection_failed none \
      "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
      "$intended" || return 4
    rm -f "$_FORWARD_SNAPSHOT"; return 1; }
  rm -f "$_FORWARD_SNAPSHOT"
  integrity=$(_forward_worktree_state "$sid" false) || integrity=unknown
  _forward_plan_present "$sid" "$wt" && plan=true || plan=false
  if ! _forward_classify "$sid" recovery "$integrity" "$plan"; then
    _forward_evidence_for_intention "$sid" retryable source_unavailable none \
      "$projected_source_digest" "$projected_record_digest" \
      "$intended" || return 4
    rm -f "${_FORWARD_SNAPSHOT:-}"
    return 1
  fi
  local reclassified_source_digest="$_FORWARD_SOURCE_DIGEST"
  local reclassified_record_digest="$_FORWARD_RECORD_DIGEST"
  if ! _lifecycle_snapshot_matches "$_FORWARD_SNAPSHOT" "$sid" "${args[@]}"; then
    _forward_evidence_for_intention "$sid" conflict remote_changed none \
      "$reclassified_source_digest" "$reclassified_record_digest" \
      "$intended" || return 4
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  fi
  if ! forward_context_remove "$context" "$context_digest"; then
    _forward_evidence_for_intention "$sid" retryable context_invalid none \
      "$reclassified_source_digest" "$reclassified_record_digest" \
      "$intended" || return 4
    rm -f "$_FORWARD_SNAPSHOT"
    return 1
  fi
  _forward_evidence_for_intention "$sid" accepted terminal_projection none \
    "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" \
    "$intended" || return 4
  rm -f "$_FORWARD_SNAPSHOT"
}

forward_recovery_scan() {
  local only_sid=""
  if [[ "${1:-}" == --only-sid ]]; then
    [[ -n "${2:-}" ]] || return 1
    only_sid="$2"
  fi
  local index ids sid source blob overall=0 recovery_rc
  index=$(mktemp "$LOCK_DIR/.forward-index-XXXXXX" 2>/dev/null) || return 1
  chmod 600 "$index" 2>/dev/null || { rm -f "$index"; return 1; }
  if ! _fetch_target_branch \
      || ! source=$(git -C "$PROJECT_DIR" rev-parse "origin/${TARGET_BRANCH}" 2>/dev/null) \
      || ! [[ "$source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
      || ! blob=$(git -C "$PROJECT_DIR" rev-parse "${source}:${BACKLOG_REL}" 2>/dev/null) \
      || ! [[ "$blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
      || ! git -C "$PROJECT_DIR" show "${source}:${BACKLOG_REL}" > "$index" 2>/dev/null; then
    rm -f "$index"; return 1
  fi
  if [[ -n "$only_sid" ]]; then
    ids=$(forward_enumerate_snapshot "$index" "$source" "$blob" "$only_sid") \
      || { rm -f "$index"; return 1; }
  else
    ids=$(forward_enumerate_snapshot "$index" "$source" "$blob") \
      || { rm -f "$index"; return 1; }
  fi
  rm -f "$index"
  [[ -z "$ids" ]] && return 0
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    recovery_rc=0
    _forward_recovery_one "$sid" || recovery_rc=$?
    case "$recovery_rc" in
      0|2|3) ;;
      4) return 4 ;;
      *) overall=1 ;;
    esac
  done <<< "$ids"
  return "$overall"
}


exceeded_stories() {
  [[ -f "$RETRY_FILE" ]] || return 0
  while IFS='=' read -r sid count; do
    if (( count >= MAX_RETRIES )); then
      echo "$sid ($count retries)"
    fi
  done < "$RETRY_FILE"
  return 0
}

# ── Pre-spawn story.md reconcile from origin/staging ──────────────────────────
# Ensures wrapper reads operator amendments committed to staging but not yet in
# the worktree branch. Also invalidates the prior cycle's qa-report when
# story.md drifts, preventing cross-cycle injection against stale AC numbers.
# Args : <sid> <wt_path> <expected-source> [<allow-absent>]
# Returns : 0 (in-sync, no action), 1 (refreshed + qa-report deleted), 2 (staging missing → skip spawn)
_reconcile_story_file_from_staging() {
  local sid="$1"
  local wt_path="$2"
  local expected_source="$3"
  local allow_absent="${4:-false}"
  local story_path=".gaai/project/contexts/artefacts/stories/${sid}.story.md"
  local abs_story="${wt_path}/${story_path}"
  local qa_report="${wt_path}/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md"
  local tag="[STORY-FILE-RECONCILE]"

  [[ "$expected_source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 2
  local live_source
  if ! _fetch_target_branch \
      || ! live_source=$(git -C "$PROJECT_DIR" rev-parse \
        "origin/${TARGET_BRANCH}" 2>/dev/null) \
      || [[ "$live_source" != "$expected_source" ]]; then
    log "${tag} ${sid} : configured target changed — skipping spawn"
    return 2
  fi

  # Pre-flight : worktree may not exist yet on fresh-pickup dispatch path.
  # The worktree is created by handle_plan_phase inside the wrapper, which
  # runs AFTER this reconcile call. In that case there is no local copy that
  # could be stale — the wrapper will populate the worktree from the
  # story/<sid> branch (itself based on staging), so story.md is in-sync at
  # branch-creation time. Without this guard, `git -C <missing-dir>` calls
  # fail silently (2>/dev/null) and surface misleading "fetch failed" +
  # "staging copy MISSING" messages, triggering spurious escalations that
  # block delivery of every fresh story.
  if [[ ! -d "$wt_path" ]]; then
    if [[ "$allow_absent" == true ]]; then
      log "${tag} ${sid} : exact pre-claim absent_new binding — wrapper will create worktree"
      return 0
    fi
    log "${tag} ${sid} : worktree absent outside bound first claim — skipping spawn"
    return 2
  fi

  # Guard: an existing worktree whose branch was deleted out from under it (re-delivery
  # churn) has a null/unborn HEAD. The git diff/commit below would then run against a
  # null HEAD and, under `set -euo pipefail`, a fatal git status takes down the ENTIRE
  # daemon main loop before the wrapper ever spawns. Detect it, prune the corrupt
  # worktree, and treat as a fresh pickup so the wrapper recreates it cleanly.
  if ! git -C "$wt_path" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    log "${tag} ${sid} : worktree has null/unborn HEAD — preserving evidence and skipping spawn"
    return 2
  fi

  log "${tag} ${sid} : checking story.md against configured target (wt=${wt_path})"

  # Overwrite WT file + stage from the exact source admitted by the caller.
  local checkout_err
  if ! checkout_err=$(git -C "$wt_path" checkout "$expected_source" -- "$story_path" 2>&1); then
    log "${tag} ${sid} : configured-target copy MISSING — escalating, skipping spawn"
    return 2
  fi

  # Treat zero-byte result as missing (defensive guard)
  if [[ ! -s "$abs_story" ]]; then
    log "${tag} ${sid} : configured-target copy MISSING (empty file) — escalating, skipping spawn"
    return 2
  fi

  # Compare staged content to HEAD — exit 0 means no diff (in-sync)
  if git -C "$wt_path" diff --cached --quiet -- "$story_path" 2>/dev/null; then
    log "${tag} ${sid} : in-sync (no drift detected)"
    return 0
  fi

  # Drift detected — commit only the story.md path, preserve HEAD pointer on story/<sid>
  local commit_sha
  if ! git -C "$wt_path" commit \
      -m "chore(${sid}): refresh story.md from configured target [daemon:story-file-drift]" \
      -- "$story_path" 2>/dev/null; then
    log "${tag} ${sid} : configured-target refresh commit failed — skipping spawn"
    return 2
  fi
  commit_sha=$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  log "${tag} ${sid} : DRIFT DETECTED — refreshed via git checkout, commit=${commit_sha} on story/${sid}"

  # Invalidate prior qa-report so cross-cycle injection silent-skips instead of
  # injecting against potentially-renumbered ACs (joint contract with qa-report injection helper)
  rm -f "$qa_report" 2>/dev/null || true
  log "${tag} ${sid} : prior qa-report deleted at ${qa_report} (joint contract with cross-cycle qa-report injection)"

  return 1
}

# ── PR merge watcher + reconcile helpers ────────────────────────────────────

# Retries pending worktree/branch cleanup entries from .cleanup-pending.audit.
# Called each main-loop cycle. Idempotent: entries cleared on success, kept on failure.
sweep_cleanup_pending() {
  local marker="$LOCK_DIR/.cleanup-pending.audit"
  [[ -f "$marker" ]] || return 0

  local tmp_remaining
  tmp_remaining=$(mktemp "$LOCK_DIR/.cleanup-pending-tmp-XXXXXX" 2>/dev/null) || {
    log "${RED}[PR-WATCHER] cleanup audit temporary file creation failed${NC}"
    return 1
  }
  local cleaned=0 kept=0

  while IFS='|' read -r ts sid marker_type; do
    [[ -z "$sid" ]] && continue
    [[ "$marker_type" != "cleanup-pending" ]] && continue

    local worktree_path
    if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
      worktree_path="${GAAI_WORKTREES_BASE}/${sid}-workspace"
    else
      local repo_name
      repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
      worktree_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${sid}-workspace"
    fi

    local wt_ok=true
    if [[ -d "$worktree_path" ]]; then
      git -C "$PROJECT_DIR" worktree remove "$worktree_path" --force 2>/dev/null || wt_ok=false
    fi
    _worktree_branch_delete_or_preserve "$sid" "story/$sid" "cleanup-pending-sweep" || true

    if $wt_ok; then
      log "${GREEN}[PR-WATCHER] sweep: cleaned pending worktree/branch for $sid${NC}"
      (( cleaned++ )) || true
    else
      printf '%s|%s|cleanup-pending\n' "$ts" "$sid" >> "$tmp_remaining"
      (( kept++ )) || true
    fi
  done < "$marker"

  if [[ $kept -eq 0 ]]; then
    rm -f "$marker" "$tmp_remaining" 2>/dev/null || true
  else
    mv "$tmp_remaining" "$marker" 2>/dev/null || rm -f "$tmp_remaining" 2>/dev/null || true
  fi
}

# Reconciliation sweep: removes worktrees of done+merged stories.
# Targets the residual gap: story status flips to done at PR-creation time (before the
# operator merges), so watch_pr_merge_status() no longer tracks it by the time the merge
# lands. This sweep detects the merge post-hoc via git branch --merged.
# Idempotent: safe to run N times with the same outcome as once.
reconcile_done_merged_worktrees() {
  local done_ids
  done_ids=$(backlog_ids_by_status done "$BACKLOG" 2>/dev/null || true)
  [[ -z "$done_ids" ]] && return 0

  local effective_target="${TARGET_BRANCH:-staging}"

  # Fetch origin to keep the merged check current (otherwise at most 1 cycle stale).
  _fetch_target_branch "$effective_target" || true

  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue

    local wt_path
    if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
      wt_path="${GAAI_WORKTREES_BASE}/${sid}-workspace"
    else
      local repo_name
      repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
      wt_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${sid}-workspace"
    fi

    # Skip if worktree directory does not exist (already cleaned — idempotent no-op).
    [[ -d "$wt_path" ]] || continue

    # Safety guard: never remove REPO_ROOT (the operator's real repo checkout) itself.
    local wt_real proj_real
    wt_real=$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")
    proj_real=$(realpath "${REPO_ROOT:-$PROJECT_DIR}" 2>/dev/null || echo "${REPO_ROOT:-$PROJECT_DIR}")
    if [[ "$wt_real" == "$proj_real" ]]; then
      log "[RECONCILE-SWEEP] $sid: skipped:safety-guard path=$wt_path (resolved to REPO_ROOT)"
      continue
    fi

    # Merged signal — two authoritative sources, in priority order :
    #   1. backlog pr_status ∈ {merged, closed_superseded, not_created_superseded}
    #      → PR-level reconciliation is the source of truth. The local story/sid
    #        branch may carry orphan chore-only commits (daemon writes that were
    #        never merged) — those are not load-bearing, the actual work is on
    #        origin/$effective_target via the PR's own merge commit.
    #   2. git branch --merged origin/$effective_target
    #      → fallback when pr_status is absent or "none" (manual reconciliation,
    #        no-PR flow, or legacy entries).
    # Rate-limit the "skipped:unmerged" log to once per hour per story (was once
    # per poll — spammed the log when chore-only branches lingered indefinitely).
    local branch_name="story/$sid"
    local pr_status_val
    pr_status_val=$(backlog_pr_status "$sid" "$BACKLOG" 2>/dev/null || echo "")

    local pr_authoritative=0
    case "$pr_status_val" in
      merged|closed_superseded|not_created_superseded)
        pr_authoritative=1
        ;;
    esac

    if (( pr_authoritative == 0 )); then
      local is_merged
      is_merged=$(git -C "$PROJECT_DIR" branch --merged "origin/${effective_target}" \
                      --list "$branch_name" 2>/dev/null || echo "")
      if [[ -z "$is_merged" ]]; then
        # Rate-limit : touch a marker file ; skip log if last log < 3600s ago.
        local _unmerged_marker="$LOCK_DIR/.reconcile-sweep.unmerged.${sid}"
        local _now_ts _last_ts _quiet_for
        _now_ts=$(date +%s)
        _last_ts=0
        [[ -f "$_unmerged_marker" ]] && _last_ts=$(cat "$_unmerged_marker" 2>/dev/null || echo 0)
        _quiet_for=$(( _now_ts - _last_ts ))
        if (( _quiet_for >= 3600 )); then
          log "[RECONCILE-SWEEP] $sid: skipped:unmerged path=$wt_path (${branch_name} not in --merged origin/${effective_target}, pr_status=${pr_status_val:-unset} — log throttled 1h)"
          echo "$_now_ts" > "$_unmerged_marker"
        fi
        continue
      fi
    fi

    # Dirty check: do NOT remove if any modification is present (AC2 — data safety).
    local porcelain_out git_status_rc
    porcelain_out=$(git -C "$wt_path" status --porcelain 2>/dev/null)
    git_status_rc=$?
    if [[ $git_status_rc -ne 0 ]]; then
      log "[WARN][RECONCILE-SWEEP] $sid: skipped:dirty path=$wt_path (git status failed rc=$git_status_rc — safe)"
      continue
    fi
    if [[ -n "$porcelain_out" ]]; then
      log "[WARN][RECONCILE-SWEEP] $sid: skipped:dirty path=$wt_path — worktree has uncommitted/untracked content:"
      local _line_count=0
      while IFS= read -r _dirty_line && (( _line_count < 5 )); do
        log "  [RECONCILE-SWEEP]   ${_dirty_line}"
        (( _line_count++ )) || true
      done <<< "$porcelain_out"
      continue
    fi

    # Remove the worktree (AC1). --force required: branch still exists in git's ref store.
    local _auth_reason
    if (( pr_authoritative == 1 )); then
      _auth_reason="pr_status=${pr_status_val} authority"
    else
      _auth_reason="done+merged into ${effective_target}, clean"
    fi
    if git -C "$PROJECT_DIR" worktree remove --force "$wt_path" 2>/dev/null; then
      log "[INFO][RECONCILE-SWEEP] $sid: removed path=$wt_path (${_auth_reason})"
      # Clear any rate-limit marker — story is now reconciled.
      rm -f "$LOCK_DIR/.reconcile-sweep.unmerged.${sid}" 2>/dev/null || true
      # Best-effort: also drop the local story branch (no longer needed — work is on staging via PR).
      # Guard is defense-in-depth: this site already gated on pr_authoritative/--merged
      # above, so the guard should independently resolve landed here too.
      _worktree_branch_delete_or_preserve "$sid" "$branch_name" "reconcile-sweep" || true
      # AC4: update pr_status=merged for audit-attribution closure (best-effort).
      # Skip if pr_status already authoritative (no-op).
      if (( pr_authoritative == 0 )); then
        chore_commit_field "$sid" pr_status merged \
          "chore($sid): pr_status=merged [reconcile-sweep]" 2>/dev/null \
          || log "[WARN][RECONCILE-SWEEP] $sid: pr_status update skipped (chore-commit unavailable/drift)"
      fi
    else
      log "[WARN][RECONCILE-SWEEP] $sid: remove failed path=$wt_path (git lock contention?) — will retry next cycle"
    fi

  done <<< "$done_ids"

  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
}

# PR merge watcher — polls GitHub for merged PRs on every daemon cycle.
# Daemon is sole coordinator: phase_status transitions are daemon-owned, never agent-owned.
# Watcher is read-only: observes operator merges, never auto-merges itself (trust arc).
# Auto-merge IS active for staging_only by default (DEC-76 v5 §11 amended 2026-05-14) ; main/prod stay manual.
# Requires chore-commit infrastructure; falls back to inline scheduler if lib/chore-commit.sh absent.
#
# @see governance:3-phase-pipeline — phase_status semantics, daemon owns transitions.
# @see governance:trust-arc-auto-merge — staging_only baseline (DEC-76 v5 §11 amended) ; main/prod stay manual ; watcher observes operator merges.
watch_pr_merge_status() {
  # AC4: opt-out env var
  if [[ "${GAAI_PR_WATCHER_DISABLED:-}" == "1" ]]; then
    return 0
  fi

  # Rate-limit guard: skip if last poll was < 60s ago (silent)
  local poll_ts_file="$LOCK_DIR/.pr-watcher.last-poll"
  if [[ -f "$poll_ts_file" ]]; then
    local last_poll now_ts
    last_poll=$(cat "$poll_ts_file" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    if (( now_ts - last_poll < 60 )); then
      return 0
    fi
  fi

  # gh availability check (warn once per daemon session)
  local gh_warn_flag="$LOCK_DIR/.pr-watcher.gh-warning-emitted"
  if ! command -v gh &>/dev/null; then
    if [[ ! -f "$gh_warn_flag" ]]; then
      log "${YELLOW}[PR-WATCHER] gh CLI not found — PR merge watcher disabled. Install gh to enable.${NC}"
      touch "$gh_warn_flag" 2>/dev/null || true
    fi
    return 0
  fi
  if ! gh auth status &>/dev/null 2>&1; then
    if [[ ! -f "$gh_warn_flag" ]]; then
      log "${YELLOW}[PR-WATCHER] gh CLI not authenticated — PR merge watcher disabled. Run: gh auth login${NC}"
      touch "$gh_warn_flag" 2>/dev/null || true
    fi
    return 0
  fi
  # gh available + authenticated — clear stale warning flag
  rm -f "$gh_warn_flag" 2>/dev/null || true

  # Update rate-limit timestamp
  date +%s > "$poll_ts_file" 2>/dev/null || true

  # Read backlog from origin (avoids working-tree drift)
  local backlog_content
  backlog_content=$(git -C "$PROJECT_DIR" show "origin/${TARGET_BRANCH}:${BACKLOG_REL}" 2>/dev/null) || {
    log "${YELLOW}[PR-WATCHER] cannot read backlog from origin/${TARGET_BRANCH} — skipping cycle${NC}"
    return 0
  }

  # Get in_progress IDs via helper (status filtering — AC1 migration)
  local _bl_tmp7; _bl_tmp7=$(mktemp)
  printf '%s\n' "$backlog_content" > "$_bl_tmp7"
  local _ip_ids_for_pr
  _ip_ids_for_pr=$(backlog_in_progress_ids "$_bl_tmp7" 2>/dev/null || true)
  rm -f "$_bl_tmp7"

  # For each in_progress story, extract pr_url (non-status field — out of helper scope)
  local story_pr_pairs=""
  if [[ -n "$_ip_ids_for_pr" ]]; then
    while IFS= read -r _pr_sid; do
      [[ -z "$_pr_sid" ]] && continue
      local _pr_url
      _pr_url=$(printf '%s\n' "$backlog_content" | python3 -c "
import sys
content = sys.stdin.read()
sid = '${_pr_sid}'
in_story = False
for line in content.splitlines():
    s = line.strip()
    if s.startswith('- id:'):
        in_story = s.split(':',1)[1].strip() == sid
    elif in_story and s.startswith('pr_url:'):
        val = s.split(':',1)[1].strip().strip('\"').strip(\"'\")
        if val: print(val)
        break
" 2>/dev/null || true)
      [[ -n "$_pr_url" ]] && story_pr_pairs+="${_pr_sid}|${_pr_url}"$'\n'
    done <<< "$_ip_ids_for_pr"
    story_pr_pairs="${story_pr_pairs%$'\n'}"
  fi

  # Clear stale .pr-abandoned.emitted.<sid> flags for stories no longer tracked
  for emitted_flag in "$LOCK_DIR"/.pr-abandoned.emitted.*; do
    [[ -f "$emitted_flag" ]] || continue
    local flag_sid="${emitted_flag##*.pr-abandoned.emitted.}"
    if ! printf '%s\n' "$story_pr_pairs" | grep -q "^${flag_sid}|"; then
      rm -f "$emitted_flag" 2>/dev/null || true
    fi
  done

  [[ -z "$story_pr_pairs" ]] && return 0

  while IFS='|' read -r sid pr_url; do
    [[ -z "$sid" || -z "$pr_url" ]] && continue

    # AC1: parse PR number via regex pull/([0-9]+)
    local pr_num
    pr_num=$(printf '%s' "$pr_url" | grep -oE 'pull/[0-9]+' | head -1 | sed 's|pull/||')
    if [[ -z "$pr_num" ]]; then
      log "${YELLOW}[PR-WATCHER] $sid : pr_url '$pr_url' does not match canonical pull/<N> pattern, skipping story${NC}"
      continue
    fi

    # Query GitHub API
    local gh_output
    gh_output=$(gh pr view "$pr_num" --json mergedAt,state,baseRefName,createdAt 2>/dev/null) || {
      log "${YELLOW}[PR-WATCHER] $sid : gh pr view failed (rate limit or network) — skipping, will retry next cycle${NC}"
      continue
    }

    # Parse response (jq preferred, python3 fallback — mirrors daemon-monitor-top.sh pattern)
    local merged_at state base_ref created_at
    if command -v jq &>/dev/null; then
      merged_at=$(printf '%s' "$gh_output" | jq -r '.mergedAt // empty' 2>/dev/null || true)
      state=$(printf '%s' "$gh_output" | jq -r '.state // empty' 2>/dev/null || true)
      base_ref=$(printf '%s' "$gh_output" | jq -r '.baseRefName // empty' 2>/dev/null || true)
      created_at=$(printf '%s' "$gh_output" | jq -r '.createdAt // empty' 2>/dev/null || true)
    else
      merged_at=$(printf '%s' "$gh_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mergedAt') or '')" 2>/dev/null || true)
      state=$(printf '%s' "$gh_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null || true)
      base_ref=$(printf '%s' "$gh_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('baseRefName',''))" 2>/dev/null || true)
      created_at=$(printf '%s' "$gh_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('createdAt') or '')" 2>/dev/null || true)
    fi

    # AC1 MEDIUM-F5: only reconcile if PR targets staging branch
    local effective_target="${TARGET_BRANCH:-staging}"
    if [[ -n "$base_ref" && "$base_ref" != "$effective_target" ]]; then
      log "${YELLOW}[PR-WATCHER] $sid : PR targets baseRefName='$base_ref' (not $effective_target), skipping reconcile — operator retargeted PR experimentally${NC}"
      continue
    fi

    # AC3: PR closed without merge (abandoned PR pattern)
    if [[ "$state" == "CLOSED" && -z "$merged_at" ]]; then
      local emitted_flag="$LOCK_DIR/.pr-abandoned.emitted.${sid}"
      if [[ ! -f "$emitted_flag" ]]; then
        log "${YELLOW}[PR-WATCHER] $sid : PR closed without merge — manual operator decision required${NC}"
        printf '%s|%s|pr-closed-no-merge\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" \
          >> "$LOCK_DIR/.pr-abandoned.audit" 2>/dev/null || true
        touch "$emitted_flag" 2>/dev/null || true
      fi
      continue
    fi

    # Merge detected: reconcile backlog + clean up (AC2: gated on current-cycle
    # provenance — this is the entry path that starts from a stored pr_url,
    # which can point at a previous cycle's PR if the reset purge didn't clear it)
    if [[ -n "$merged_at" && "$base_ref" == "$effective_target" ]]; then
      if _merged_pr_is_current_cycle "$sid" "$created_at" "$merged_at" "$pr_num"; then
        _reconcile_merged_pr "$sid" "$merged_at" "$pr_num" "$created_at"
      fi
    fi

  done <<< "$story_pr_pairs"
}

# Reads the current delivery cycle's started_at instant for story <sid> from
# origin's backlog. lib/backlog-yaml.sh's Python-fallback field reader only
# matches status/phase_status/pr_status (alphanumeric-token values), not an
# ISO-8601 timestamp, so this is intentionally inline rather than delegated —
# mirrors the pr_url extractor above (same read shape, same block-scan idiom).
_merged_pr_started_at() {   # $1=sid $2=optional pinned backlog snapshot → stdout: started_at or empty
  local sid="$1" pinned_snapshot="${2:-}"
  local tmp owns_tmp=false
  if [[ -n "$pinned_snapshot" ]]; then
    [[ -f "$pinned_snapshot" ]] || return 0
    tmp="$pinned_snapshot"
  else
    tmp=$(mktemp)
    owns_tmp=true
    if ! git -C "$PROJECT_DIR" show "origin/${TARGET_BRANCH}:${BACKLOG_REL}" > "$tmp" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi
  fi
  python3 -c "
import sys
content = open('$tmp').read()
sid = '${sid}'
in_story = False
for line in content.splitlines():
    s = line.strip()
    if s.startswith('- id:'):
        in_story = s.split(':',1)[1].strip() == sid
    elif in_story and s.startswith('started_at:'):
        val = s.split(':',1)[1].strip().strip('\"').strip(\"'\")
        if val:
            print(val)
        break
" 2>/dev/null || true
  $owns_tmp && rm -f "$tmp" 2>/dev/null || true
}

# Shared current-cycle provenance gate (AC1-AC3). A merged PR is authoritative
# for an in_progress story's reconciliation only when GitHub created AND merged
# it strictly after the current delivery cycle's started_at — a reused
# story/<id> branch can retain an earlier cycle's PR, and branch identity alone
# proves which story a PR names, not which cycle created it. Fail-closed: any
# missing/invalid/non-later evidence refuses, never accepts.
_merged_pr_is_current_cycle() {   # $1=sid $2=pr_created_at $3=pr_merged_at $4=pr_number $5=optional pinned backlog snapshot
  local sid="$1" pr_created_at="$2" pr_merged_at="$3" pr_number="${4:-}" pinned_snapshot="${5:-}"
  local started_at
  started_at=$(_merged_pr_started_at "$sid" "$pinned_snapshot")

  local reason
  reason=$(python3 - "$started_at" "$pr_created_at" "$pr_merged_at" <<'PYEOF' 2>/dev/null || true
import re
import sys
from datetime import datetime

def missing(v):
    return v is None or not v.strip() or v.strip() == '-'

def parse(v):
    if missing(v):
        return None
    v = v.strip()
    # Require one unambiguous RFC-3339-style instant. datetime.fromisoformat
    # otherwise accepts date-only/basic/naive forms and would let the daemon
    # invent a timezone for evidence GitHub or the backlog did not provide.
    match = re.fullmatch(
        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?'
        r'(?P<zone>Z|(?P<sign>[+-])(?P<offset_hour>\d{2}):(?P<offset_minute>\d{2}))',
        v,
    )
    if match is None:
        return None
    if match.group('zone') != 'Z':
        offset_hour = int(match.group('offset_hour'))
        offset_minute = int(match.group('offset_minute'))
        # RFC 3339 numeric offsets are bounded clock fields. Its -00:00
        # spelling means that the local offset is unknown, so it cannot serve
        # as the unambiguous chronological evidence this gate requires.
        if offset_hour > 23 or offset_minute > 59 or match.group('zone') == '-00:00':
            return None
    if v.endswith('Z'):
        v = v[:-1] + '+00:00'
    try:
        dt = datetime.fromisoformat(v)
    except Exception:
        return None
    return dt

started_raw = sys.argv[1] if len(sys.argv) > 1 else ''
created_raw = sys.argv[2] if len(sys.argv) > 2 else ''
merged_raw = sys.argv[3] if len(sys.argv) > 3 else ''

if missing(started_raw):
    print('missing_started_at'); sys.exit(0)
started = parse(started_raw)
if started is None:
    print('invalid_started_at'); sys.exit(0)

if missing(created_raw):
    print('missing_pr_created_at'); sys.exit(0)
created = parse(created_raw)
if created is None:
    print('invalid_pr_created_at'); sys.exit(0)
if created < started:
    print('pr_before_cycle'); sys.exit(0)
if created == started:
    print('pr_not_after_cycle'); sys.exit(0)

if missing(merged_raw):
    print('missing_merged_at'); sys.exit(0)
merged = parse(merged_raw)
if merged is None:
    print('invalid_merged_at'); sys.exit(0)
if merged < started:
    print('merge_before_cycle'); sys.exit(0)
if merged == started:
    print('merge_not_after_cycle'); sys.exit(0)

print('ok')
PYEOF
)

  case "$reason" in
    ok)
      return 0
      ;;
    missing_started_at|invalid_started_at|missing_pr_created_at|invalid_pr_created_at| \
    pr_before_cycle|pr_not_after_cycle|missing_merged_at|invalid_merged_at| \
    merge_before_cycle|merge_not_after_cycle)
      ;;
    *)
      # Interpreter failure or unexpected output — fail-closed as the first
      # applicable class when no valid cycle-start instant could be obtained.
      reason="invalid_started_at"
      ;;
  esac

  log "[CYCLE-GUARD] $sid : PR #${pr_number:-?} not current-cycle evidence (reason=$reason) started_at=${started_at:--} created_at=${pr_created_at:--} merged_at=${pr_merged_at:--} — no backlog mutation"
  return 1
}

# Atomic reconciliation when a PR merge is detected for story <sid>.
_reconcile_merged_pr() {
  # pr_number is passed by callers ($3) for the chore-commit message. It defaults
  # to empty so the status reconcile ALWAYS lands even when a caller cannot supply
  # a PR number — the number is cosmetic in the commit subject, never load-bearing.
  # (Was previously read from an ambient global that only 2 of 5 callers set, so the
  # pr-watcher/stale/drift paths crashed under `set -u` with "pr_number: unbound".)
  # pr_created_at ($4) is required for the current-cycle provenance gate below;
  # a caller that omits it gets a refusal (missing_pr_created_at), never a
  # weaker check — the empty default is the intended fail-closed failure mode.
  local sid="$1" merged_at="$2" pr_number="${3:-}" pr_created_at="${4:-}"
  local script_dir
  # The generated child sources lib/backlog-yaml.sh from here. In the daemon this
  # is the admitted asset root (under a descriptor launch `BASH_SOURCE[0]` is
  # `/dev/fd/9`, whose directory holds no library). The BASH_SOURCE-relative
  # sibling lookup stays the fallback for the extracted-function runners, which
  # place `lib/` next to their own runner and define no daemon asset root.
  script_dir="${SCRIPT_DIR:-}"
  if [[ -z "$script_dir" || ! -r "$script_dir/lib/backlog-yaml.sh" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  local reconcile_script
  reconcile_script=$(mktemp "$LOCK_DIR/.pr-watcher-reconcile-XXXXXX" 2>/dev/null) || {
    log "${RED}[PR-WATCHER] reconciliation temporary script creation failed${NC}"
    return 1
  }

  # The authoritative gate and the landed mutation execute under the SAME
  # staging lock. Function bodies are copied from the live daemon into the
  # child script so the mutation boundary cannot drift to a weaker check.
  cat > "$reconcile_script" <<RECONCILE_EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$PROJECT_DIR"
PROJECT_DIR="$PROJECT_DIR"
BACKLOG_REL="$BACKLOG_REL"
TARGET_BRANCH="$TARGET_BRANCH"
SCHEDULER="$SCHEDULER"
LOG_FILE="${LOG_FILE:-/dev/null}"
log() { printf '[%s] %s\n' "\$(date -u +%H:%M:%SZ)" "\$*" >> "\$LOG_FILE"; }
source "$script_dir/lib/backlog-yaml.sh"
RECONCILE_EOF
  declare -f _merged_pr_started_at >> "$reconcile_script"
  declare -f _merged_pr_is_current_cycle >> "$reconcile_script"
  cat >> "$reconcile_script" <<RECONCILE_EOF

snapshot= index_file=
cleanup() { rm -f "\${snapshot:-}" "\${index_file:-}" 2>/dev/null || true; }
trap cleanup EXIT

# Refresh while holding the staging lock, then bind every read and the commit
# parent to the same remote SHA. A cross-device push makes the exact-parent
# push fail; the next scan fetches and revalidates instead of rebasing an old
# provenance verdict onto a new delivery cycle.
git fetch origin "$TARGET_BRANCH" --quiet 2>/dev/null || exit 1
remote_sha=\$(git rev-parse "origin/$TARGET_BRANCH" 2>/dev/null) || exit 1
snapshot=\$(mktemp)
git show "\${remote_sha}:$BACKLOG_REL" > "\$snapshot" 2>/dev/null || exit 1

remote_status=\$(backlog_status "$sid" "\$snapshot" 2>/dev/null || true)
if [[ "\$remote_status" == "done" ]]; then
  exit 0
fi
if [[ "\$remote_status" != "in_progress" ]]; then
  log "[PR-WATCHER] $sid : reconciliation refused because remote status is \${remote_status:-missing}, expected in_progress"
  exit 1
fi

_merged_pr_is_current_cycle "$sid" "$pr_created_at" "$merged_at" "$pr_number" "\$snapshot" || exit 1

"$SCHEDULER" --set-field "$sid" status done "\$snapshot" >/dev/null
"$SCHEDULER" --set-field "$sid" phase_status done "\$snapshot" >/dev/null
"$SCHEDULER" --set-field "$sid" completed_at "$merged_at" "\$snapshot" >/dev/null

index_file=\$(mktemp)
rm -f "\$index_file"
GIT_INDEX_FILE="\$index_file" git read-tree "\$remote_sha"
backlog_blob=\$(git hash-object -w -- "\$snapshot")
GIT_INDEX_FILE="\$index_file" git update-index --add --cacheinfo 100644 "\$backlog_blob" "$BACKLOG_REL"
new_tree=\$(GIT_INDEX_FILE="\$index_file" git write-tree)
new_commit=\$(printf '%s\n' "chore($sid): done [pr-watcher: PR #$pr_number merged $merged_at]" \
  | git commit-tree "\$new_tree" -p "\$remote_sha")

if ! git push origin "\$new_commit:refs/heads/$TARGET_BRANCH" --quiet 2>/dev/null; then
  log "[PR-WATCHER] $sid : exact-parent push lost a race; no reconcile landed, next scan will fetch and revalidate"
  exit 1
fi
RECONCILE_EOF

  chmod +x "$reconcile_script"
  local rc=0
  with_staging_lock bash "$reconcile_script" 2>>"${LOG_FILE:-/dev/null}" || rc=$?
  rm -f "$reconcile_script" 2>/dev/null || true

  if [[ $rc -ne 0 ]]; then
    # AC3: distinct error class via a surviving channel (this daemon log line +
    # marker file), independent of the reconcile script's stderr (also appended
    # to the daemon log above) — rate-limited so a persistent failure
    # doesn't spam every ~35s cycle, but always fires on first occurrence
    # (mirrors the .reconcile-sweep.unmerged.${sid} marker pattern at ~2181).
    local _unlanded_marker="$LOCK_DIR/.reconcile-unlanded.${sid}"
    local _now_ts _last_ts _quiet_for
    _now_ts=$(date +%s)
    _last_ts=0
    [[ -f "$_unlanded_marker" ]] && _last_ts=$(cat "$_unlanded_marker" 2>/dev/null || echo 0)
    _quiet_for=$(( _now_ts - _last_ts ))
    if (( _quiet_for >= 3600 )); then
      log "${RED}[PR-WATCHER] $sid : RECONCILE_UNLANDED — atomic reconcile failed to land backlog write on origin (rc=$rc), leaving in_progress, will retry next cycle (log throttled 1h)${NC}"
      echo "$_now_ts" > "$_unlanded_marker"
    fi
    return 1
  fi
  rm -f "$LOCK_DIR/.reconcile-unlanded.${sid}" 2>/dev/null || true

  # HIGH-F3: cleanup after successful chore-commit
  local worktree_path
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    worktree_path="${GAAI_WORKTREES_BASE}/${sid}-workspace"
  else
    local repo_name
    repo_name=$(basename "${REPO_ROOT:-$PROJECT_DIR}")
    worktree_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." && pwd)/.gaai-worktrees/${repo_name}/${sid}-workspace"
  fi

  local cleanup_failed=false
  if [[ -d "$worktree_path" ]]; then
    git -C "$PROJECT_DIR" worktree remove "$worktree_path" --force 2>/dev/null || cleanup_failed=true
  fi
  # This site runs immediately after chore_commit_field ... status done has
  # already pushed to origin, so the guard resolves landed trivially here.
  _worktree_branch_delete_or_preserve "$sid" "story/$sid" "pr-watcher-reconcile" || true

  if $cleanup_failed; then
    printf '%s|%s|cleanup-pending\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" \
      >> "$LOCK_DIR/.cleanup-pending.audit" 2>/dev/null || true
    log "${YELLOW}[PR-WATCHER] $sid : cleanup partial failure → .cleanup-pending.audit written${NC}"
  fi

  log "${GREEN}[PR-WATCHER] $sid : merged at $merged_at to ${TARGET_BRANCH:-staging}, reconciled to status:done + worktree/branch cleaned (or .cleanup-pending.audit emitted)${NC}"

  # Secondary triage safety-net: fires only if primary (handle_commit_phase) was skipped.
  # Single-fire marker in _run_triage_for_story prevents double-fire. (AC2, AC3)
  if declare -f _run_triage_for_story >/dev/null 2>&1; then
    _run_triage_for_story "$sid" 2>/dev/null || true
  fi

  return 0
}

# ── Status mode ──────────────────────────────────────────────────────────
if $STATUS_MODE; then
  clean_stale_locks

  echo -e "${BOLD}GAAI Delivery Daemon — Status${NC}"
  echo -e "  Branch: ${CYAN}${TARGET_BRANCH}${NC}"
  echo ""

  # Active
  echo -e "${CYAN}Active:${NC}"
  active_list=$(active_stories)
  if [[ -n "$active_list" ]]; then
    echo "$active_list" | while read -r line; do echo "  $line"; done
  else
    echo "  (none)"
  fi
  echo ""

  # Ready
  echo -e "${CYAN}Ready:${NC}"
  ready=$(find_ready_stories 2>/dev/null || true)
  if [[ -n "$ready" ]]; then
    echo "$ready" | while read -r line; do echo "  $line"; done
  else
    echo "  (none)"
  fi
  echo ""

  # Exceeded
  echo -e "${CYAN}Exceeded retries:${NC}"
  exceeded=$(exceeded_stories)
  if [[ -n "$exceeded" ]]; then
    echo "$exceeded" | while read -r line; do echo "  $line"; done
  else
    echo "  (none)"
  fi

  exit 0
fi

# ── Pre-launch: mark in_progress on staging ──────────────────────────────
# This is the cross-device coordination point. After git pull, we re-verify
# the story is still ready (another device may have claimed it). If push
# fails (concurrent push from another VPS), we reset and skip.
pre_launch_mark_in_progress() {
  local story_id="$1"

  log "${BLUE}Marking $story_id in_progress on $TARGET_BRANCH...${NC}"

  # Write a temp script to avoid quoting issues in bash -c
  local plscript
  plscript=$(mktemp)
  cat > "$plscript" <<PLEOF
#!/usr/bin/env bash
set -euo pipefail
cd "$PROJECT_DIR"
BACKLOG_FILE="$BACKLOG"
BACKLOG_REL="$BACKLOG_REL"
LOCK_DIR="$LOCK_DIR"
TARGET_BRANCH="$TARGET_BRANCH"
SCHEDULER="$SCHEDULER"
# shellcheck source=lib/chore-commit.sh
source "$SCRIPT_DIR/lib/chore-commit.sh"

# Step 1: Sync with latest remote
if ! git pull origin "$TARGET_BRANCH" --ff-only --quiet 2>&1; then
  # Preserve any uncommitted work before force-syncing
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git stash push -m "daemon-autosave-\$(date +%s)" --quiet 2>/dev/null || true
  fi
  # Local branch diverged (e.g. previous failed push) — force sync
  git fetch origin "$TARGET_BRANCH" --quiet 2>/dev/null || true
  if ! git rebase "origin/$TARGET_BRANCH" --quiet 2>/dev/null; then
    git rebase --abort --quiet 2>/dev/null || true
    echo "[$(date -u +%H:%M:%SZ)] Push race detected — rebase failed (genuine conflict). Skipping this transition. Operator intervention required." >> "$LOG_FILE" 2>/dev/null || true
    printf '%s|recovery|rebase-failed-in-progress-$story_id\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$REBASE_CONFLICT_MARKER" 2>/dev/null || true
    exit 1
  fi
  echo "[$(date -u +%H:%M:%SZ)] Push race detected — rebased onto origin/$TARGET_BRANCH cleanly, retrying push" >> "$LOG_FILE" 2>/dev/null || true
  rm -f "$REBASE_CONFLICT_MARKER" 2>/dev/null || true
fi

# Step 2: Re-verify story is still ready after pulling latest
# (another device may have already marked it in_progress)
if ! "$SCHEDULER" --ready-ids "$BACKLOG" 2>/dev/null | grep -q "^${story_id}\$"; then
  echo "CLAIMED: $story_id no longer ready (status changed on remote)" >&2
  exit 2
fi

# Step 3: Mark in_progress + set started_at (atomic via chore_commit_multi_field)
_started_at="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
chore_commit_multi_field "$story_id" status in_progress started_at "\$_started_at" \
  "chore($story_id): in_progress [daemon]" || exit \$?
PLEOF
  chmod +x "$plscript"

  local rc=0
  with_staging_lock bash "$plscript" || rc=$?
  rm -f "$plscript"

  case $rc in
    0)
      log "${GREEN}$story_id marked in_progress on $TARGET_BRANCH${NC}"
      ;;
    2)
      log "${YELLOW}$story_id already claimed by another device. Skipping.${NC}"
      return 1
      ;;
    1)
      log "${YELLOW}$story_id rebase conflict during in_progress mark. Skipping.${NC}"
      return 1
      ;;
    3)
      log "${YELLOW}$story_id push conflict (concurrent claim). Skipping.${NC}"
      return 1
      ;;
    6)
      _write_drift_marker "commit" "mark-in-progress-$story_id"
      return 1
      ;;
    *)
      log "${RED}Failed to mark $story_id in_progress (rc=$rc)${NC}"
      return 1
      ;;
  esac
}

# ── Cross-cycle qa-report resolver ─────────────────────────────────────
# Checks whether a prior qa-report exists for <sid> in the worktree at <wt_path>.
# Parses Verdict and replan_required per the replan routing contract.
# Outputs exactly two lines on injection: <absolute-path>\n<phase>
# Outputs nothing on no-injection (absent, unreadable, empty, or PASS verdict).
# Caller exports GAAI_QA_REPORT_PATH + GAAI_QA_INJECT_PHASE conditionally.
_resolve_cross_cycle_qa_report() {
  local sid="$1" wt_path="$2"
  local qa_report="${wt_path}/.gaai/project/contexts/artefacts/qa-reports/${sid}.qa-report.md"

  [[ ! -f "$qa_report" || ! -s "$qa_report" ]] && return 0

  # DEC-200 / E1096S02 AC1: derive from the shared JSON resolver, not Markdown
  # grep — daemon-dispatch.sh (sourced above this call site) supplies
  # _qa_verdict_resolve(). rc=2 (no sidecar — legacy/currentness-rerun case)
  # and rc=1 (invalid-present) both fall through to "no injection": the
  # dispatch-side currentness gate (daemon-dispatch.sh dispatch_3phase_story),
  # not this function, is the one place phase_status is authoritatively reset
  # for a missing/invalid sidecar. This function only ever decides PLAN-prompt
  # injection content for an ALREADY-valid FAIL/ESCALATE route.
  local base_ref="${GAAI_BASE_REF:-origin/${TARGET_BRANCH:-staging}}"
  local out rc
  out=$(_qa_verdict_resolve "$sid" "$wt_path" "$base_ref")
  rc=$?
  [[ "$rc" -ne 0 ]] && return 0

  local verdict route replan
  verdict=$(printf '%s' "$out" | sed -n '1p')
  route=$(printf '%s' "$out" | sed -n '2p')
  replan=$(printf '%s' "$out" | sed -n '3p')
  [[ "$verdict" == "PASS" ]] && return 0

  # DEC-200 D5: ESCALATE routes to remediation_route:"human", not "plan" — but
  # the pre-existing (Markdown-only) behavior mapped ESCALATE to phase="plan"
  # for injection purposes (best-available context for a human/architectural
  # review is the PLAN-style delta framing). Preserve that observable behavior
  # explicitly rather than silently changing it via the route-based mapping.
  local phase="impl"
  if [[ "$verdict" == "ESCALATE" ]]; then
    phase="plan"
  elif [[ "$route" == "plan" ]]; then
    phase="plan"
  fi

  local _replan_val="${replan:-absent}"
  printf '%s\n%s\n%s\n%s\n' "$qa_report" "$phase" "$verdict" "$_replan_val"
}

# Create a per-attempt raw secret through an exclusive no-follow descriptor.
# The token is supplied on stdin, never argv. The private lock directory is
# descriptor-bound before any name is created.
_attempt_secret_create() {
  local sid="$1" token="$2"
  [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ && -n "$token" ]] || return 1
  printf '%s' "$token" | python3 -c '
import os, secrets, stat, sys
parent, sid = sys.argv[1:]
payload = sys.stdin.buffer.read()
if not payload or b"\0" in payload or len(payload) > 65536:
    raise SystemExit(1)
dir_fd = fd = None
name = None
try:
    before = os.lstat(parent)
    dir_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        raise ValueError
    while True:
        name = ".daemon-secret.%s.%s.env" % (sid, secrets.token_hex(16))
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=dir_fd)
            break
        except FileExistsError:
            continue
    os.fchmod(fd, 0o600)
    view = memoryview(payload)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise OSError
        view = view[count:]
    os.fsync(fd)
    os.close(fd); fd = None
    os.fsync(dir_fd)
    print(os.path.join(parent, name))
except (OSError, ValueError):
    if name is not None and dir_fd is not None:
        try: os.unlink(name, dir_fd=dir_fd)
        except OSError: pass
    raise SystemExit(1)
finally:
    if fd is not None: os.close(fd)
    if dir_fd is not None: os.close(dir_fd)
' "$LOCK_DIR" "$sid"
}

# Generate a private, per-attempt launcher. It opens the raw secret once with
# O_NOFOLLOW, validates owner/mode/type/inode, unlinks that exact entry, then
# execs the wrapper with the token in its environment. No shell source or
# shared predictable env file participates in the spawn.
_attempt_launcher_create() {
  local sid="$1" secret_path="$2" wrapper="$3"
  [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] || return 1
  python3 - "$LOCK_DIR" "$sid" "$secret_path" "$wrapper" <<'PY'
import os, secrets, shlex, stat, sys
parent, sid, secret_path, wrapper = sys.argv[1:]
dir_fd = fd = None
name = None
loader = r'''import os, stat, sys
secret_path, wrapper, launcher = sys.argv[1:]
parent, name = os.path.split(secret_path)
dir_fd = fd = None
try:
    parent_before = os.lstat(parent)
    dir_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
    parent_opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(parent_opened.st_mode)
            or parent_opened.st_uid != os.geteuid()
            or parent_opened.st_mode & 0o077
            or (parent_opened.st_dev, parent_opened.st_ino)
               != (parent_before.st_dev, parent_before.st_ino)):
        raise ValueError
    before = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
    opened = os.fstat(fd)
    after = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    identity = (opened.st_dev, opened.st_ino)
    if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077 or identity != (before.st_dev, before.st_ino)
            or identity != (after.st_dev, after.st_ino)):
        raise ValueError
    chunks = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk: break
        chunks.append(chunk)
    payload = b"".join(chunks)
    if not payload or b"\0" in payload or len(payload) > 65536:
        raise ValueError
    token = payload.decode("utf-8")
    wrapper_stat = os.lstat(wrapper)
    if (not stat.S_ISREG(wrapper_stat.st_mode)
            or wrapper_stat.st_uid != os.geteuid()
            or not wrapper_stat.st_mode & stat.S_IXUSR):
        raise ValueError
    current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if identity != (current.st_dev, current.st_ino):
        raise ValueError
    os.unlink(name, dir_fd=dir_fd)
    os.fsync(dir_fd)
    try: os.unlink(launcher)
    except OSError: pass
    env = os.environ.copy()
    env["GAAI_IMPL_AUTH_TOKEN"] = token
    os.execve(wrapper, [wrapper], env)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if fd is not None: os.close(fd)
    if dir_fd is not None: os.close(dir_fd)
'''
try:
    before = os.lstat(parent)
    dir_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        raise ValueError
    while True:
        name = ".daemon-launch.%s.%s.sh" % (sid, secrets.token_hex(16))
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | getattr(os, "O_NOFOLLOW", 0), 0o700, dir_fd=dir_fd)
            break
        except FileExistsError:
            continue
    path = os.path.join(parent, name)
    body = ("#!/bin/sh\nexec python3 -c %s %s %s %s\n" % (
        shlex.quote(loader), shlex.quote(secret_path), shlex.quote(wrapper), shlex.quote(path)
    )).encode("utf-8")
    view = memoryview(body)
    while view:
        count = os.write(fd, view)
        if count <= 0: raise OSError
        view = view[count:]
    os.fchmod(fd, 0o700)
    os.fsync(fd)
    os.close(fd); fd = None
    os.fsync(dir_fd)
    print(path)
except (OSError, ValueError):
    if name is not None and dir_fd is not None:
        try: os.unlink(name, dir_fd=dir_fd)
        except OSError: pass
    raise SystemExit(1)
finally:
    if fd is not None: os.close(fd)
    if dir_fd is not None: os.close(dir_fd)
PY
}

_attempt_file_cleanup() {
  local path="$1"
  python3 - "$path" <<'PY'
import os, stat, sys
path = sys.argv[1]
parent, name = os.path.split(path)
if not (name.startswith(".daemon-secret.") or name.startswith(".daemon-launch.")):
    raise SystemExit(1)
dir_fd = None
try:
    before = os.lstat(parent)
    dir_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(dir_fd)
    if (not stat.S_ISDIR(opened.st_mode) or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
        raise ValueError
    try:
        entry = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if entry.st_uid != os.geteuid():
        raise ValueError
    os.unlink(name, dir_fd=dir_fd)
    os.fsync(dir_fd)
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if dir_fd is not None: os.close(dir_fd)
PY
}

# ── Launch 3phase delivery in dedicated tmux session ────────────────────
# Restores docstring promise "Active deliveries keep running independently
# after daemon stop" for the 3phase pipeline. Without this isolation, daemon's
# `tmux kill-session -t gaai-daemon` on stop kills all in-process node spawns
# + their grandchild claude -p processes (observed empirically E135S04
# 2026-05-06 — QA killed mid-execution at daemon stop).
#
# Pattern: generate a wrapper script that manages the whole 3-phase loop
# + lock file, tmux launches it detached.
launch_3phase_in_tmux() {
  local story_id="$1"
  local trace_id="$2"
  local expected_source="$3"
  local expected_blob="$4"
  local expected_record="$5"
  local wrapper="$LOCK_DIR/${story_id}_3phase_run.sh"

  [[ "$expected_source" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && "$expected_blob" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ \
      && "$expected_record" =~ ^[0-9a-f]{64}$ ]] || return 1

  local wrapper_write_rc=0
  cat > "$wrapper" <<WRAPPER_EOF || wrapper_write_rc=$?
#!/usr/bin/env bash
# Auto-generated by delivery-daemon for $story_id (3phase) — cleaned up on exit
set +e

LOCK_FILE="$LOCK_DIR/$story_id.lock"
HEARTBEAT_FILE="$LOCK_DIR/$story_id.heartbeat"
INTERRUPTED_FILE="$LOCK_DIR/$story_id.interrupted"
umask 077
echo \$\$ > "\$LOCK_FILE"

# ── Dedicated heartbeat (decoupled from claude -p log output) ──────────────
# Touched every 30s for the wrapper's entire lifetime, including during
# pure-bash phases (commit-phase, gh pr merge waits) that emit no claude log.
# The daemon's check_heartbeats reads this file as the primary liveness signal.
date +%s > "\$HEARTBEAT_FILE"
( while :; do sleep 30; date +%s > "\$HEARTBEAT_FILE" 2>/dev/null || exit 0; done ) &
HEARTBEAT_PID=\$!
disown \$HEARTBEAT_PID 2>/dev/null || true

cleanup() {
  kill \$HEARTBEAT_PID 2>/dev/null || true
  # Killing this wrapper-owned process is local containment.  When target
  # authority is lost, preserve the exact lock and last heartbeat files so
  # forward recovery can classify the failed attempt from durable evidence.
  if [[ "\$_DISPATCH_AUTHORITY_FAILED" != "1" ]]; then
    # Backstop reap: SIGKILL any process still rooted in this story's worktree (orphaned
    # test runners / dev-build servers / worker pools an agent left behind). The per-phase
    # sweep in daemon-dispatch handles the common case; this covers a graceful daemon stop
    # where the wrapper exits between/after a phase. Delegates to the dispatch helper (sourced
    # below) for the centralised empty-pattern safety guard; declare -f tolerates an early
    # exit before the source. \`${story_id}-workspace\` is a unique, tightly-scoped match.
    # Only reconcile on clean exit — skip if interrupted.
    if [[ "\$_INTERRUPT_REQUESTED" != "1" \
        && ! -f "\$INTERRUPTED_FILE" ]]; then
      declare -f _reap_worktree_orphans >/dev/null 2>&1 && _reap_worktree_orphans "${story_id}-workspace"
      # Reconcile top-level YAML status from phase_status before releasing lock.
      # Guard: declare -f ensures the function was sourced (not a pre-source exit).
      if declare -f _reconcile_yaml_status_on_exit >/dev/null 2>&1; then
        _reconcile_yaml_status_on_exit "$story_id"
      fi
    fi
    rm -f "\$LOCK_FILE" "\$HEARTBEAT_FILE"
  fi
  # NB: do NOT remove \$INTERRUPTED_FILE — the forward recovery scan reads
  # it at the next daemon start to differentiate graceful daemon-start.sh --stop from
  # crash. The recovery scan removes it after reverting status:refined.
}
trap cleanup EXIT

# ── OSS-3 : SIGTERM/SIGINT graceful drain trap ────────────────────────────
# daemon-start.sh --stop sends SIGTERM to this wrapper PID (not the tmux session) so that
# claude -p children are NOT killed mid-phase. The trap sets a flag and
# touches \$INTERRUPTED_FILE ; the dispatch loop checks the flag at each
# iteration boundary and exits gracefully after the current phase completes.
#
# If daemon-start.sh --stop's STOP_DRAIN_TIMEOUT elapses before the wrapper exits, the
# stop logic escalates to tmux kill-session (which DOES kill claude). The
# .interrupted file is still set, so OSS-5 still classifies this as a graceful
# stop on next start.
_INTERRUPT_REQUESTED=0
_DISPATCH_AUTHORITY_FAILED=0
on_interrupt() {
  _INTERRUPT_REQUESTED=1
  date +%s > "\$INTERRUPTED_FILE" 2>/dev/null || true
  echo "[\$(date '+%H:%M:%S')] $story_id — SIGTERM/SIGINT received, will exit after current phase"
}
trap on_interrupt SIGTERM SIGINT

cd "$PROJECT_DIR" || exit 1

# Inherit daemon's env vars critical to dispatch :
export PROJECT_DIR="$PROJECT_DIR"
# REPO_ROOT = the operator's REAL checkout. MUST be baked in: dispatch's per-story
# worktree-base derivation is \${REPO_ROOT:-\$PROJECT_DIR}/.. — and PROJECT_DIR above is the
# daemon HOME (post home-flip). Without REPO_ROOT the fallback nests worktrees under the home
# (.gaai-worktrees/<repo>/.gaai-worktrees/__daemon-home/<sid>-workspace). Bake the daemon's
# (correct) REPO_ROOT so the wrapper derives the canonical non-nested base.
export REPO_ROOT="$REPO_ROOT"
export GAAI_REPO_ROOT="$REPO_ROOT"
export BACKLOG_FILE="$BACKLOG"
export SCHEDULER="$SCHEDULER"
export LOCK_DIR="$LOCK_DIR"
export LOG_DIR="$LOG_DIR"
export TARGET_BRANCH="$TARGET_BRANCH"
export GAAI_DAEMON_EXECUTOR="${GAAI_DAEMON_EXECUTOR:-claude}"
export GAAI_CODEX_MODEL="${GAAI_CODEX_MODEL:-}"
export GAAI_CODEX_SANDBOX="${GAAI_CODEX_SANDBOX:-}"
export GAAI_CODEX_EPHEMERAL="${GAAI_CODEX_EPHEMERAL:-}"
export GAAI_CODEX_IGNORE_USER_CONFIG="${GAAI_CODEX_IGNORE_USER_CONFIG:-}"
export GAAI_CLAUDE_PROXY_BASE_URL="${GAAI_CLAUDE_PROXY_BASE_URL:-}"
if [[ -n "\${GAAI_CLAUDE_PROXY_BASE_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL="\${GAAI_CLAUDE_PROXY_BASE_URL}"
fi
export GAAI_IMPL_BASE_URL="${GAAI_IMPL_BASE_URL:-}"
export GAAI_IMPL_AUTH_TOKEN="${GAAI_IMPL_AUTH_TOKEN:-}"
export GAAI_IMPL_MODEL="${GAAI_IMPL_MODEL:-}"
export GAAI_IMPL_MODEL_FALLBACK="${GAAI_IMPL_MODEL_FALLBACK:-}"
export GAAI_AUTO_MERGE_POLICY="${GAAI_AUTO_MERGE_POLICY:-staging_only}"
export GAAI_AUTO_MERGE_ADMIN_FALLBACK="${GAAI_AUTO_MERGE_ADMIN_FALLBACK:-false}"
export GAAI_QA_REPORT_PATH="${GAAI_QA_REPORT_PATH:-}"
export GAAI_QA_INJECT_PHASE="${GAAI_QA_INJECT_PHASE:-}"
export GAAI_QA_INJECT_PHASE_SNAPSHOT="${GAAI_QA_INJECT_PHASE:-}"
export GAAI_EXPECTED_TARGET_SOURCE="$expected_source"
export GAAI_EXPECTED_TARGET_BLOB="$expected_blob"
export GAAI_EXPECTED_TARGET_RECORD="$expected_record"
export GAAI_DISPATCH_IDENTITY_GUARD=required

# Source dispatch helpers (function definitions only — no top-level work).
# Plain source, no pipe : pipe creates subshell which loses function defs.
if ! source "$PROJECT_DIR/.gaai/core/scripts/daemon-dispatch.sh"; then
  _DISPATCH_AUTHORITY_FAILED=1
  echo "[ERROR] $story_id — dispatch library unavailable; refusing wrapper launch" >&2
  exit 1
fi

# Source chore-commit helper (Option B' flock+yq — E134S16)
export BACKLOG_REL="$BACKLOG_REL"
# shellcheck source=lib/chore-commit.sh
source "$PROJECT_DIR/.gaai/core/scripts/lib/chore-commit.sh"

# 3phase loop — same logic as in-process version, just runs in own tmux
while true; do
  _ps_before=\$(get_phase_status "$story_id" 2>/dev/null || echo "?")
  CHORE_JOURNAL_OUTCOME=""
  CHORE_JOURNAL_COMMIT=""
  _dispatch_rc=0
  dispatch_3phase_story "$story_id" "$trace_id" || _dispatch_rc=\$?
  _ps=\$(get_phase_status "$story_id" 2>/dev/null || echo "?")
  _receipt_observed=0
  if [[ -n "\${CHORE_JOURNAL_OUTCOME:-}" \
      || -n "\${CHORE_JOURNAL_COMMIT:-}" ]]; then
    _receipt_observed=1
  fi
  # A durable write can publish its exact receipt before a later local-file
  # step fails, or can change a non-phase Story field.  Receipt presence is
  # therefore independently authoritative; local phase inequality is only a
  # second trigger and can never substitute for an exact applied receipt.
  if [[ "\$_receipt_observed" == "1" || "\$_ps" != "\$_ps_before" ]]; then
    if ! _dispatch_rebind_expected_target_identity "$story_id"; then
      _DISPATCH_AUTHORITY_FAILED=1
      echo "[\$(date '+%H:%M:%S')] $story_id — target identity rebind failed after durable phase transition"
      break
    fi
  fi
  # A handler can return non-zero after its lifecycle transition was already
  # durably published.  Rebind that transition first; only then interpret its
  # process result so no successful write bypasses the authority boundary.
  if [[ "\$_dispatch_rc" -ne 0 ]]; then
    # A non-zero return after an observed durable receipt can mean local
    # adoption failed after publication.  Preserve lock/heartbeat evidence for
    # forward recovery instead of authorizing ordinary cleanup from local bytes.
    [[ "\$_dispatch_rc" -eq 3 || "\$_receipt_observed" == "1" ]] \
      && _DISPATCH_AUTHORITY_FAILED=1
    echo "[\$(date '+%H:%M:%S')] $story_id — 3phase dispatch error at phase_status='\${_ps}' — story left in place for retry"
    break
  fi
  # OSS-3 : honour graceful drain request before evaluating terminal states
  # so daemon-start.sh --stop interrupts at the closest phase boundary without losing
  # the current phase_status. INTERRUPTED_FILE is preserved across exit
  # for OSS-5 to read on next daemon start.
  if [[ "\$_INTERRUPT_REQUESTED" == "1" ]]; then
    echo "[\$(date '+%H:%M:%S')] $story_id — interrupted (graceful drain), exiting at phase_status='\$_ps'"
    break
  fi
  # Terminal phase_status values that must exit the wrapper loop.
  # qa_failed is NOT in this list — dispatch_3phase_story's qa_failed case
  # handles the retry-loop inline (re-IMPL with qa-report context) and
  # rewinds phase_status to "planned" before returning. When the retry cap
  # is exhausted, dispatch sets phase_status to "qa_escalated" instead,
  # which IS terminal here. qa_escalated and escalated remain non-terminal
  # for the YAML lifecycle (operator may still flip top-level status to
  # done/failed) but ARE terminal for this wrapper.
  case "\$_ps" in
    done|failed|escalated|qa_escalated|commit_stalled)
      echo "[\$(date '+%H:%M:%S')] $story_id — 3phase loop exit at phase_status='\$_ps'"
      break
      ;;
  esac
done

# Preserve the wrapper's terminal process result for local launch probes and
# post-mortem supervision.  The EXIT trap contains the owned heartbeat process
# but does not erase durable authority evidence or override this status.
if [[ "\$_DISPATCH_AUTHORITY_FAILED" == "1" ]]; then
  exit 3
fi
if [[ "\${_dispatch_rc:-0}" -ne 0 ]]; then
  exit "\$_dispatch_rc"
fi
exit 0
WRAPPER_EOF

  [[ "$wrapper_write_rc" -eq 0 && -s "$wrapper" ]] || return 1
  chmod +x "$wrapper" || return 1

  # Forward critical env vars into tmux. The auth token uses a unique private
  # descriptor-bound file and launcher; it never appears in tmux argv.
  local secrets_file="" attempt_launcher="" launch_command="$wrapper"
  if [[ -n "${GAAI_IMPL_AUTH_TOKEN:-}" ]]; then
    secrets_file=$(_attempt_secret_create "$story_id" "$GAAI_IMPL_AUTH_TOKEN") || return 1
    attempt_launcher=$(_attempt_launcher_create "$story_id" "$secrets_file" "$wrapper") || {
      _attempt_file_cleanup "$secrets_file" || true
      return 1
    }
    launch_command="$attempt_launcher"
  fi
  local tmux_env_args=()
  [[ -n "${GAAI_CLAUDE_PROXY_BASE_URL:-}" ]] && tmux_env_args+=(-e "GAAI_CLAUDE_PROXY_BASE_URL=${GAAI_CLAUDE_PROXY_BASE_URL}")
  [[ -n "${GAAI_IMPL_BASE_URL:-}"   ]] && tmux_env_args+=(-e "GAAI_IMPL_BASE_URL=${GAAI_IMPL_BASE_URL}")
  # GAAI_IMPL_AUTH_TOKEN intentionally is not forwarded via -e.
  [[ -n "${GAAI_IMPL_MODEL:-}"      ]] && tmux_env_args+=(-e "GAAI_IMPL_MODEL=${GAAI_IMPL_MODEL}")
  [[ -n "${GAAI_IMPL_MODEL_FALLBACK:-}" ]] && tmux_env_args+=(-e "GAAI_IMPL_MODEL_FALLBACK=${GAAI_IMPL_MODEL_FALLBACK}")
  [[ -n "${GAAI_AUTO_MERGE_POLICY:-}" ]] && tmux_env_args+=(-e "GAAI_AUTO_MERGE_POLICY=${GAAI_AUTO_MERGE_POLICY}")
  [[ -n "${GAAI_AUTO_MERGE_ADMIN_FALLBACK:-}" ]] && tmux_env_args+=(-e "GAAI_AUTO_MERGE_ADMIN_FALLBACK=${GAAI_AUTO_MERGE_ADMIN_FALLBACK}")
  [[ -n "${GAAI_DAEMON_EXECUTOR:-}" ]] && tmux_env_args+=(-e "GAAI_DAEMON_EXECUTOR=${GAAI_DAEMON_EXECUTOR}")
  [[ -n "${GAAI_CODEX_MODEL:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_MODEL=${GAAI_CODEX_MODEL}")
  [[ -n "${GAAI_CODEX_SANDBOX:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_SANDBOX=${GAAI_CODEX_SANDBOX}")
  [[ -n "${GAAI_CODEX_EPHEMERAL:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_EPHEMERAL=${GAAI_CODEX_EPHEMERAL}")
  [[ -n "${GAAI_CODEX_IGNORE_USER_CONFIG:-}" ]] && tmux_env_args+=(-e "GAAI_CODEX_IGNORE_USER_CONFIG=${GAAI_CODEX_IGNORE_USER_CONFIG}")
  # The delivery wrapper runs in its OWN tmux session and creates the per-story worktree.
  # It MUST inherit the operator's real checkout + the daemon home, or its worktree-base
  # derivation falls back to PROJECT_DIR (= the home when the daemon binary runs from the
  # home worktree) and nests the worktrees under the home. Forward both.
  [[ -n "${GAAI_REPO_ROOT:-}" ]] && tmux_env_args+=(-e "GAAI_REPO_ROOT=${GAAI_REPO_ROOT}")
  [[ -n "${GAAI_DAEMON_HOME:-}" ]] && tmux_env_args+=(-e "GAAI_DAEMON_HOME=${GAAI_DAEMON_HOME}")
  [[ -n "${GAAI_WORKTREES_BASE:-}" ]] && tmux_env_args+=(-e "GAAI_WORKTREES_BASE=${GAAI_WORKTREES_BASE}")

  # ── Cross-cycle qa-report env setup ────────────────────────────────
  local _cc_3p_wt_path
  if [[ -n "${GAAI_WORKTREES_BASE:-}" ]]; then
    _cc_3p_wt_path="${GAAI_WORKTREES_BASE}/${story_id}-workspace"
  else
    _cc_3p_wt_path="$(cd "${REPO_ROOT:-$PROJECT_DIR}/.." 2>/dev/null && pwd)/.gaai-worktrees/$(basename "${REPO_ROOT:-$PROJECT_DIR}")/${story_id}-workspace"
  fi
  local _cc_3p_out
  _cc_3p_out=$(_resolve_cross_cycle_qa_report "$story_id" "$_cc_3p_wt_path" 2>/dev/null || true)
  if [[ -n "$_cc_3p_out" ]]; then
    local _cc_3p_path _cc_3p_phase _cc_3p_verdict _cc_3p_replan
    _cc_3p_path=$(printf '%s' "$_cc_3p_out" | head -1)
    _cc_3p_phase=$(printf '%s' "$_cc_3p_out" | sed -n '2p')
    _cc_3p_verdict=$(printf '%s' "$_cc_3p_out" | sed -n '3p')
    _cc_3p_replan=$(printf '%s' "$_cc_3p_out" | sed -n '4p')
    log "[CROSS-CYCLE-QA-INJECT] ${story_id}: verdict=${_cc_3p_verdict} replan_required=${_cc_3p_replan} phase=${_cc_3p_phase} path=${_cc_3p_path}"
    tmux_env_args+=(-e "GAAI_QA_REPORT_PATH=${_cc_3p_path}" -e "GAAI_QA_INJECT_PHASE=${_cc_3p_phase}")
  else
    unset GAAI_QA_REPORT_PATH GAAI_QA_INJECT_PHASE 2>/dev/null || true
  fi

  if ! tmux new-session -d -s "gaai-deliver-${story_id}" \
      ${tmux_env_args[@]+"${tmux_env_args[@]}"} "$launch_command"; then
    [[ -z "$secrets_file" ]] || _attempt_file_cleanup "$secrets_file" || true
    [[ -z "$attempt_launcher" ]] || _attempt_file_cleanup "$attempt_launcher" || true
    log "${RED}[FORWARD-RECOVERY] story=${story_id} spawn failed before session creation${NC}"
    return 1
  fi

  # Pipe wrapper stdout/stderr to persistent log for post-mortem diagnosis.
  # Non-fatal: log WARN on failure and continue.
  if [[ "${TMUX_PIPE_PANE_AVAILABLE:-false}" == "true" ]]; then
    local _wrapper_log="$LOG_DIR/${story_id}.wrapper.log"
    local _launch_ps
    _launch_ps=$(backlog_phase_status "$story_id" "$BACKLOG" 2>/dev/null || echo "")
    if [[ "${_launch_ps:-}" == "not_started" || -z "${_launch_ps:-}" ]]; then
      : > "$_wrapper_log" 2>/dev/null || true
    fi
    tmux pipe-pane -t "gaai-deliver-${story_id}" -o "cat >> ${_wrapper_log}" 2>/dev/null \
      || log "[WARN] pipe_pane_failed story=${story_id} — wrapper output capture unavailable"
  fi

  # Brief wait for lock file to appear (wrapper writes its PID)
  local i=0
  while [[ $i -lt 10 ]] && [[ ! -f "$LOCK_DIR/${story_id}.lock" ]]; do
    sleep 0.2
    ((i++)) || true
  done

  if [[ ! -f "$LOCK_DIR/${story_id}.lock" ]]; then
    tmux kill-session -t "gaai-deliver-${story_id}" 2>/dev/null || true
    [[ -z "$secrets_file" ]] || _attempt_file_cleanup "$secrets_file" || true
    [[ -z "$attempt_launcher" ]] || _attempt_file_cleanup "$attempt_launcher" || true
    log "${RED}[FORWARD-RECOVERY] story=${story_id} wrapper lock did not appear${NC}"
    return 1
  fi

  log "${GREEN}Launched 3phase: $story_id (tmux: gaai-deliver-${story_id})${NC}"
  return 0
}

# ── Prevent macOS sleep ───────────────────────────────────────────────────
CAFFEINATE_PID=""
if [[ "$PLATFORM" == "Darwin" ]]; then
  caffeinate -dims &
  CAFFEINATE_PID=$!
  log "${GREEN}caffeinate started (PID $CAFFEINATE_PID) — Mac will stay awake${NC}"
fi

# ── Graceful shutdown ─────────────────────────────────────────────────────
shutdown() {
  echo ""
  if [[ -n "$CAFFEINATE_PID" ]]; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
  fi
  log "${YELLOW}Daemon stopped. Active delivery sessions continue independently.${NC}"
  exit 0
}

trap shutdown SIGINT SIGTERM

# ── Crash visibility: turn a silent daemon death into a loud one ──────────
# The main loop runs under `set -euo pipefail`, so any unguarded non-zero
# command (a bare `((counter++))` at 0, a transient git failure, an unbound
# var under `set -u`) terminates the daemon SILENTLY — no log line, no
# notification — leaving stories stuck `in_progress` while in-flight wrappers
# finish independently. That silent-death mode has repeatedly masked real
# outages. The ERR trap records the failing line + command; the EXIT trap
# reports it loudly on ABNORMAL exit only. `shutdown()` exits 0, so a clean
# SIGINT/SIGTERM stop stays quiet. Both traps are observational — they never
# alter control flow (set -e still exits on the same commands as before).
#
# errtrace (set -E) makes the ERR trap fire for fatal failures INSIDE called
# functions / sourced files too — the daemon's real death sites (e.g. `((i++))`
# in launch_3phase_in_tmux, anything in daemon-dispatch.sh). Without it, ERR
# only fires at top level and the capture below is empty for the most common
# crashes. Verified: it does NOT fire for `|| true`-guarded failures (ERR
# firing stays coupled to set -e firing), so no false captures / stale vars,
# and it does not change which commands are fatal.
set -o errtrace
_daemon_err_line=""
_daemon_err_cmd=""
_daemon_err_src=""
_daemon_evidence_fatal=false
# Capture the failing file too (basename via parameter expansion — no fork):
# a fatal command may live in a sourced file where a bare line number would
# misread as a delivery-daemon.sh line.
trap '_daemon_err_line=$LINENO; _daemon_err_cmd=$BASH_COMMAND; _daemon_err_src=${BASH_SOURCE[0]:-?}; _daemon_err_src=${_daemon_err_src##*/}' ERR
_daemon_on_exit() {
  local rc=$?
  [[ "$rc" -eq 0 ]] && return 0
  # The failed evidence call is already the terminal observation. Never turn
  # that failure into a crash marker, OS notification or webhook fallback.
  [[ "${_daemon_evidence_fatal:-false}" == true ]] && return 0
  log "${RED}[DAEMON-CRASH] main process exited abnormally (rc=$rc) at ${_daemon_err_src:-?}:${_daemon_err_line:-?}: '${_daemon_err_cmd:-unknown}'. Delivery HALTED — restart via daemon-start.sh (in-flight wrappers continue independently).${NC}" 2>/dev/null || true
  printf '%s rc=%s src=%s line=%s cmd=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown-time)" \
    "$rc" "${_daemon_err_src:-?}" "${_daemon_err_line:-?}" "${_daemon_err_cmd:-unknown}" \
    > "$LOCK_DIR/.daemon-crash" 2>/dev/null || true
  if declare -f notify_escalation >/dev/null 2>&1; then
    notify_escalation "daemon" "daemon_crash_rc_${rc}" \
      "Main loop died at ${_daemon_err_src:-?}:${_daemon_err_line:-?} (cmd: ${_daemon_err_cmd:-unknown}) — restart with daemon-start.sh" 2>/dev/null || true
  fi
}
trap _daemon_on_exit EXIT

# ── Save config for monitor ──────────────────────────────────────────────
DISPLAY_MODEL="$CLAUDE_MODEL"
if [[ "${GAAI_DAEMON_EXECUTOR:-claude}" == "codex" ]]; then
  DISPLAY_MODEL="${GAAI_CODEX_MODEL:-codex}"
fi
cat > "$LOCK_DIR/.daemon-config" << EOF
BRANCH="$TARGET_BRANCH"
INTERVAL="$POLL_INTERVAL"
CONCURRENT="$MAX_CONCURRENT"
MODEL="$DISPLAY_MODEL"
LAUNCHER="$LAUNCHER"
SKIP_PERMS="$SKIP_PERMISSIONS"
MAX_TURNS="$MAX_TURNS"
HEARTBEAT="$HEARTBEAT_STALE"
TIMEOUT="$DELIVERY_TIMEOUT"
DRY_RUN="$DRY_RUN"
HOST="$(hostname -s 2>/dev/null || hostname)"
CAFFEINATE_PID="${CAFFEINATE_PID:-}"
STARTED="$(date '+%H:%M:%S')"
NOTIFICATION_WEBHOOK="$NOTIFICATION_WEBHOOK"
WEBHOOK_SECRET_SET="$([ -n "$WEBHOOK_SECRET" ] && echo "yes" || echo "no")"
EOF

# ── Banner (2-column) ────────────────────────────────────────────────────
BANNER_WIDTH=58  # inner width between ║ chars
# Left column: 28 chars, separator: │ (1 char), right column: 29 chars
banner_row_2col() {
  local l1="$1" v1="$2" l2="$3" v2="$4"
  local left_pad=$(( 14 - ${#v1} ))
  local right_pad=$(( 15 - ${#v2} ))
  [[ $left_pad -lt 0 ]] && left_pad=0
  [[ $right_pad -lt 0 ]] && right_pad=0
  local lsp rsp
  printf -v lsp '%*s' "$left_pad" ''
  printf -v rsp '%*s' "$right_pad" ''
  echo -e "  ║${NC}${CYAN}  $(printf '%-12s' "$l1")${BOLD}${v1}${NC}${CYAN}${lsp}│  $(printf '%-12s' "$l2")${BOLD}${v2}${NC}${CYAN}${rsp}║"
}

echo -e "${CYAN}${BOLD}"
echo "  ╔$(printf '═%.0s' $(seq 1 $BANNER_WIDTH))╗"
TITLE="GAAI Delivery Daemon"
TITLE_LEN=${#TITLE}
printf "  ║%*s%s%*s║\n" $(( (BANNER_WIDTH - TITLE_LEN) / 2 )) "" "$TITLE" $(( (BANNER_WIDTH - TITLE_LEN + 1) / 2 )) ""
echo "  ╠$(printf '═%.0s' $(seq 1 $BANNER_WIDTH))╣"
banner_row_2col "Branch:"      "$TARGET_BRANCH"      "Model:"       "$CLAUDE_MODEL"
banner_row_2col "Interval:"    "${POLL_INTERVAL}s"    "Launcher:"    "$LAUNCHER"
banner_row_2col "Concurrent:"  "$MAX_CONCURRENT"      "Skip perms:"  "$SKIP_PERMISSIONS"
banner_row_2col "Max turns:"   "$MAX_TURNS"           "Heartbeat:"   "${HEARTBEAT_STALE}s"
banner_row_2col "Timeout:"     "${DELIVERY_TIMEOUT}s" "Dry run:"     "$DRY_RUN"
echo -e "  ${BOLD}╚$(printf '═%.0s' $(seq 1 $BANNER_WIDTH))╝${NC}"
echo ""
echo -e "  ${YELLOW}Ctrl+C to stop (active sessions keep running)${NC}"
echo ""
log "${GREEN}Daemon started on $(hostname) — target: $TARGET_BRANCH${NC}"
if (( EXIT_WHEN_IDLE_THRESHOLD > 0 )); then
  log "${BLUE}Auto-stop enabled — daemon will exit after $EXIT_WHEN_IDLE_THRESHOLD consecutive idle polls (no ready stories + zero in-flight)${NC}"
fi
if [[ "${GAAI_PR_WATCHER_DISABLED:-}" == "1" ]]; then
  log "${YELLOW}[PR-WATCHER] disabled via GAAI_PR_WATCHER_DISABLED env var${NC}"
fi

# ── Load 3-phase dispatch library (E134S02) ──────────────────────────────
# Resolved from the admitted asset root, exactly like every bootstrap library
# above. Under the supported descriptor launch `$0` is `/dev/fd/9`, so a
# `dirname "$0"` here looked for the library in `/dev/fd` — after the ready
# acknowledgement, which is why an early readiness ack cannot stand in for
# evidence that the daemon reached its dispatch loop.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/daemon-dispatch.sh"

# ── Forward recovery scan (one-shot at daemon start) ─────────────────────
clean_stale_locks
_startup_recovery_rc=0
forward_recovery_scan || _startup_recovery_rc=$?
if [[ "$_startup_recovery_rc" -ne 0 ]]; then
  [[ "$_startup_recovery_rc" -eq 4 ]] && _daemon_evidence_fatal=true
  log "${RED}[FORWARD-RECOVERY] startup scan blocked — daemon will not enter dispatch loop${NC}"
  exit 1
fi

# ── Main loop ─────────────────────────────────────────────────────────────
# Counter for consecutive polls where active=0 AND no ready stories. Resets to
# 0 whenever a delivery launches OR an in-flight delivery is observed. When it
# reaches EXIT_WHEN_IDLE_THRESHOLD (and that threshold is > 0), the daemon
# logs an auto-stop marker and exits 0 cleanly.
empty_idle_polls=0
last_recovery_scan_ts=0
_orphan_scan_tick=0
_last_loop_ts=$(date +%s)
# Startup grace: treat a fresh daemon launch the same as a post-suspend resume.
# Rationale: across a daemon restart (operator --restart, after a stop/start
# cycle, or after a host suspend that exceeded the previous daemon's lifetime),
# every in_progress story has a chore-in_progress git commit whose %at is stale
# by wall-clock — but those stories may still be deliverable, awaiting either a
# wrapper resume from phase=implemented/qa_passed/qa_failed/planned or a fresh
# launch. Letting the staleness sweep brute-force them to failed at t=0 is the
# observed dominant false-positive on this axis. Granting the same grace window
# the suspend-jump detector uses lets recovery + the launch loop produce fresh
# chore-in_progress commits within the window, refreshing the staleness clock
# for genuinely-deliverable stories. Genuinely orphaned stale stories are still
# caught after the window expires.
SUSPEND_GRACE_UNTIL=$(( _last_loop_ts + POST_RESUME_GRACE_SEC ))
log "${CYAN}[STARTUP_GRACE] liveness/staleness kills suppressed for ${POST_RESUME_GRACE_SEC}s after daemon start${NC}"

while true; do
  # Suspend/resume detection: a normal iteration spans roughly POLL_INTERVAL
  # plus a few seconds of work. A gap far larger than that means the host was
  # suspended (laptop sleep) or the daemon process was paused. When that
  # happens, grant a grace window during which the liveness detectors stand
  # down — their now-minus-mtime ages are inflated by the freeze, not by real
  # inactivity, so killing on them would terminate healthy in-flight wrappers.
  _loop_now=$(date +%s)
  _loop_gap=$(( _loop_now - _last_loop_ts ))
  if (( _loop_gap > SUSPEND_JUMP_THRESHOLD_SEC )); then
    SUSPEND_GRACE_UNTIL=$(( _loop_now + POST_RESUME_GRACE_SEC ))
    log "${YELLOW}[SUSPEND_DETECTED] poll gap ${_loop_gap}s > ${SUSPEND_JUMP_THRESHOLD_SEC}s (host suspend or daemon pause) — liveness kills suppressed for ${POST_RESUME_GRACE_SEC}s${NC}"
  fi
  _last_loop_ts=$_loop_now

  # Per-cycle home guard: verify before any coordination git-state op (mark
  # in_progress, reconcile, status push). Verify-only — any drift, dirt or
  # unavailable proof skips the cycle with a typed reason and leaves the home
  # byte-for-byte as it was.
  if ! _per_cycle_home_check; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Tick-based cycle orphan-lock scan — runs before clean_stale_locks
  # so dead-PID locks are detected and recovery invoked at cycle time.
  _orphan_scan_tick=$(( _orphan_scan_tick + 1 ))
  if (( _orphan_scan_tick >= ORPHAN_SCAN_INTERVAL_TICKS )); then
    _orphan_scan_rc=0
    cycle_orphan_lock_scan || _orphan_scan_rc=$?
    if [[ "$_orphan_scan_rc" -ne 0 ]]; then
      if [[ "$_orphan_scan_rc" -eq 4 ]]; then
        _daemon_evidence_fatal=true
        log "${RED}[FORWARD-RECOVERY] orphan evidence sink unavailable — stopping daemon${NC}"
        exit 1
      fi
      log "${RED}[FORWARD-RECOVERY] orphan scan blocked — skipping downstream cycle${NC}"
      sleep "$POLL_INTERVAL"
      continue
    fi
    _orphan_scan_tick=0
  fi

  clean_stale_locks
  check_heartbeats || true
  watch_pr_merge_status || true

  if ! active=$(active_count); then
    log "${RED}[FORWARD-RECOVERY] capacity ownership is ambiguous — skipping cycle${NC}"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if (( active >= MAX_CONCURRENT )); then
    empty_idle_polls=0  # not idle — slots full means deliveries are running
    log "${BLUE}Slots full ($active/$MAX_CONCURRENT). Waiting...${NC}"
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Detect agent-hang: wrapper alive (heartbeat fresh) but claude -p stalled
  check_agent_activity_stale || true

  # Track escalated/failed stories for resolution notification (AC5/AC6)
  scan_and_track_escalated_failed || true

  # Fire resolution notifications for stories that transitioned to done (AC1-AC6)
  check_resolution_notifications || true

  # V1.5 promotion: periodic orphan-lock recovery scan (OSS-5 during-life)
  _now_ts=$(date +%s)
  if (( _now_ts - last_recovery_scan_ts >= RECOVERY_SCAN_INTERVAL )); then
    log "${CYAN}[RECOVERY] periodic-scan triggered (interval=${RECOVERY_SCAN_INTERVAL}s)${NC}"
    _periodic_recovery_rc=0
    forward_recovery_scan || _periodic_recovery_rc=$?
    if [[ "$_periodic_recovery_rc" -ne 0 ]]; then
      if [[ "$_periodic_recovery_rc" -eq 4 ]]; then
        _daemon_evidence_fatal=true
        log "${RED}[FORWARD-RECOVERY] periodic evidence sink unavailable — stopping daemon${NC}"
        exit 1
      fi
      log "${RED}[FORWARD-RECOVERY] periodic scan blocked — skipping downstream cycle${NC}"
      last_recovery_scan_ts=$(date +%s)
      sleep "$POLL_INTERVAL"
      continue
    fi
    last_recovery_scan_ts=$(date +%s)
  fi

  # Find stories ready for delivery (via git fetch + scheduler)
  ready_stories=$(find_ready_stories || true)

  if [[ -n "$ready_stories" ]]; then
    if ! ready_stories=$(python3 -c '
import re, sys
values = sys.stdin.read().splitlines()
seen = set()
for value in values:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", value) or value in seen:
        raise SystemExit(1)
    seen.add(value)
print("\n".join(values))
' <<< "$ready_stories"); then
      log "${RED}[FORWARD-RECOVERY] scheduler returned invalid or duplicate Story identity — skipping cycle${NC}"
      sleep "$POLL_INTERVAL"
      continue
    fi
  fi

  if [[ -z "$ready_stories" ]]; then
    if (( active > 0 )); then
      # Not idle — in-flight deliveries still running, more stories may surface
      # once they complete (e.g. dependency chains). Reset counter.
      empty_idle_polls=0
      log "${BLUE}No stories ready (waiting on $active in-flight delivery/ies)...${NC}"
    else
      # Truly idle: zero in-flight + nothing ready. Eligible for auto-stop.
      empty_idle_polls=$(( empty_idle_polls + 1 ))
      if (( EXIT_WHEN_IDLE_THRESHOLD > 0 && empty_idle_polls >= EXIT_WHEN_IDLE_THRESHOLD )); then
        log "${GREEN}Auto-stop fired — idle for $empty_idle_polls consecutive polls (threshold: $EXIT_WHEN_IDLE_THRESHOLD), zero in-flight deliveries.${NC}"
        log "${GREEN}Daemon exiting cleanly. Active tmux delivery sessions (if any) keep running independently.${NC}"
        exit 0
      fi
      if (( EXIT_WHEN_IDLE_THRESHOLD > 0 )); then
        log "${BLUE}No stories ready (idle ${empty_idle_polls}/${EXIT_WHEN_IDLE_THRESHOLD} before auto-stop)...${NC}"
      else
        log "${BLUE}No stories ready. Waiting...${NC}"
      fi
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Reaching this point means at least one story is ready to launch — reset
  # the idle counter so a transient empty window doesn't carry over.
  empty_idle_polls=0

  # Launch deliveries up to available slots
  available_slots=$(( MAX_CONCURRENT - active ))
  launched=0

  while IFS= read -r story_id; do
    [[ -z "$story_id" ]] && continue
    (( launched >= available_slots )) && break

    if is_locked "$story_id"; then
      log "${BLUE}$story_id already in progress (local lock). Skipping.${NC}"
      continue
    fi

    if has_exceeded_retries "$story_id"; then
      log "${RED}$story_id exceeded $MAX_RETRIES retries. Skipping (restart daemon to reset).${NC}"
      continue
    fi

    if $DRY_RUN; then
      log "${YELLOW}[DRY RUN] Would launch: $story_id (retry $(get_retry_count "$story_id")/$MAX_RETRIES)${NC}"
      ((launched++)) || true
      continue
    fi

    retry_count=$(get_retry_count "$story_id")
    if (( retry_count > 0 )); then
      backoff=$(( retry_count * 60 ))
      log "${YELLOW}Ready story: $story_id — retry $retry_count/$MAX_RETRIES — backing off ${backoff}s before launch...${NC}"
      sleep "$backoff"
      log "${YELLOW}$story_id — backoff complete, launching...${NC}"
    else
      log "${GREEN}Ready story: $story_id — launching delivery...${NC}"
    fi

    # Fresh pre-claim admission from the configured target.
    # It happens before any potentially mutating worktree repair. The second classification grants
    # claim authority only after the fresh typed integrity result is known.
    if ! _pre_wt=$(_forward_resolve_worktree "$story_id"); then
      if ! _forward_main_hold "$story_id" integrity_unverified; then
        exit 1
      fi
      continue
    fi
    _pre_plan=false
    _forward_plan_present "$story_id" "$_pre_wt" && _pre_plan=true
    if ! _forward_classify "$story_id" main unknown "$_pre_plan"; then
      if ! _forward_main_hold "$story_id" source_unavailable; then
        exit 1
      fi
      continue
    fi
    if ! _forward_main_record_admitted pre; then
      if ! _forward_evidence "$story_id" blocked invalid_record none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    fi
    _pre_source="$_FORWARD_SOURCE"
    _pre_blob="$_FORWARD_BLOB"
    _pre_record="$_FORWARD_RECORD_DIGEST"
    _pre_source_digest="$_FORWARD_SOURCE_DIGEST"
    rm -f "$_FORWARD_SNAPSHOT"
    if ! _pre_integrity=$(_forward_prepare_worktree "$story_id" \
        "$_pre_source" true); then
      if ! _forward_main_hold "$story_id" integrity_unverified \
          "$_pre_source_digest" "$_pre_record"; then
        exit 1
      fi
      continue
    fi
    if ! _forward_classify "$story_id" main "$_pre_integrity" "$_pre_plan"; then
      if ! _forward_main_hold "$story_id" source_unavailable \
          "$_pre_source_digest" "$_pre_record"; then
        exit 1
      fi
      continue
    fi
    if [[ "$_FORWARD_SOURCE" != "$_pre_source" || "$_FORWARD_BLOB" != "$_pre_blob" \
        || "$_FORWARD_RECORD_DIGEST" != "$_pre_record" \
        || "$_FORWARD_ACTION" != claim_candidate || "$_FORWARD_REASON" != ready ]]; then
      if ! _forward_evidence "$story_id" blocked remote_changed none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    fi
    rm -f "$_FORWARD_SNAPSHOT"

    # The existing claim is the only lifecycle effect in this path.
    _claim_epoch=$(date +%s)
    if ! pre_launch_mark_in_progress "$story_id"; then
      if ! _forward_main_hold "$story_id" projection_failed \
          "$_pre_source_digest" "$_pre_record"; then
        exit 1
      fi
      continue
    fi

    # The claim changes target authority. Pin and admit that new object before
    # probing or repairing the post-claim worktree.
    _post_plan=false
    _forward_plan_present "$story_id" "$_pre_wt" && _post_plan=true
    if ! _forward_classify "$story_id" postclaim unknown "$_post_plan"; then
      if ! _forward_main_hold "$story_id" source_unavailable \
          "$_pre_source_digest" "$_pre_record"; then
        exit 1
      fi
      continue
    fi
    if ! _forward_main_record_admitted post; then
      if ! _forward_evidence "$story_id" blocked invalid_record none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    fi
    _post_source="$_FORWARD_SOURCE"
    _post_blob="$_FORWARD_BLOB"
    _post_record="$_FORWARD_RECORD_DIGEST"
    _post_source_digest="$_FORWARD_SOURCE_DIGEST"
    _post_started="$_FORWARD_STARTED"
    rm -f "$_FORWARD_SNAPSHOT"
    _post_allow_absent=false
    [[ "$_pre_integrity" == absent_new && ! -d "$_pre_wt" ]] \
      && _post_allow_absent=true
    if ! _post_integrity=$(_forward_prepare_worktree "$story_id" \
        "$_post_source" "$_post_allow_absent"); then
      if ! _forward_main_hold "$story_id" integrity_unverified \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if ! _forward_classify "$story_id" postclaim "$_post_integrity" \
        "$_post_plan"; then
      if ! _forward_main_hold "$story_id" source_unavailable \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if [[ "$_FORWARD_SOURCE" != "$_post_source" || "$_FORWARD_BLOB" != "$_post_blob" \
        || "$_FORWARD_RECORD_DIGEST" != "$_post_record" \
        || "$_FORWARD_ACTION" != resume || "$_FORWARD_REASON" != resumable ]]; then
      if ! _forward_evidence "$story_id" blocked remote_changed none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    fi
    if ! python3 - "$_post_started" "$_claim_epoch" <<'PY' >/dev/null 2>&1
import datetime, sys
try:
    started = datetime.datetime.strptime(
        sys.argv[1], "%Y-%m-%dT%H:%M:%SZ"
    ).replace(tzinfo=datetime.timezone.utc).timestamp()
    if started < int(sys.argv[2]):
        raise ValueError
except (OverflowError, ValueError):
    raise SystemExit(1)
PY
    then
      if ! _forward_evidence "$story_id" blocked remote_changed none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    fi

    rm -f "$_FORWARD_SNAPSHOT"

    # Settle retained lifecycle authority before temporary execution checks.
    _pending_rc=0
    _journal_inspect_pending_lifecycle "$story_id" recovery.scan >/dev/null 2>&1 || _pending_rc=$?
    if [[ "$_pending_rc" -eq 0 ]]; then
      if ! _forward_main_hold "$story_id" pending_run \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    elif [[ "$_pending_rc" -ne 2 ]]; then
      if ! _forward_evidence "$story_id" blocked invalid_record none \
          "$_post_source_digest" "$_post_record" none; then
        exit 1
      fi
      continue
    fi
    _story_reconcile_rc=0
    _reconcile_story_file_from_staging "$story_id" "$_pre_wt" "$_post_source" \
      "$_post_allow_absent" \
      || _story_reconcile_rc=$?
    if [[ "$_story_reconcile_rc" -gt 1 ]]; then
      if ! _forward_main_hold "$story_id" source_unavailable \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi

    # Re-pin immediately after reconciliation. Any A-to-B advance invalidates
    # every context, retry and spawn effect from this cycle.
    if ! _forward_revalidate_after_reconcile "$story_id" "$_post_source" \
        "$_post_blob" "$_post_record" postclaim "$_post_allow_absent"; then
      if ! _forward_evidence "$story_id" blocked remote_changed none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      continue
    fi
    _post_integrity="$_FORWARD_FINAL_INTEGRITY"
    if ! _claim_context=$(_forward_context_path "$story_id"); then
      if ! _forward_main_hold "$story_id" context_invalid \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    fi
    _claim_row=$(_forward_bind_context "$_claim_context" "$story_id" \
      "$_FORWARD_SOURCE" "$_FORWARD_BLOB" "$_FORWARD_RECORD_DIGEST" \
      none none none none none none "$_post_integrity" resume resumable none) || {
      if ! _forward_evidence "$story_id" blocked context_invalid none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "$_FORWARD_SNAPSHOT"
      continue
    }
    _claim_context_digest=${_claim_row##*$'\t'}
    _claim_source="$_FORWARD_SOURCE"
    _claim_blob="$_FORWARD_BLOB"
    _claim_record="$_FORWARD_RECORD_DIGEST"
    rm -f "$_FORWARD_SNAPSHOT"

    if ! _forward_active_markers_clear "$story_id"; then
      if ! _forward_main_hold "$story_id" effect_inhibited \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if ! _forward_runner_clear "$story_id"; then
      if ! _forward_main_hold "$story_id" effect_inhibited \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if tmux has-session -t "gaai-deliver-${story_id}" 2>/dev/null; then
      if ! _forward_main_hold "$story_id" runner_live \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if ! _live_active=$(active_count); then
      if ! _forward_main_hold "$story_id" effect_inhibited \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if (( _live_active >= MAX_CONCURRENT )); then
      if ! _forward_main_hold "$story_id" effect_inhibited \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if ! _trace_id=$(node -e \
        "import('node:crypto').then(m=>process.stdout.write(m.randomUUID()))" \
        2>/dev/null || python3 -c \
        "import uuid; print(str(uuid.uuid4()),end='')"); then
      if ! _forward_main_hold "$story_id" effect_inhibited \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi

    # The checks above may perform filesystem and process observations after
    # the first post-reconcile fetch. Re-pin once more at the actual effect
    # boundary so an A-to-B target advance cannot consume A's context, retry
    # budget or spawn authority. Failure preserves the bound context for a
    # later exact-cycle recovery.
    if ! _forward_last_edge_guard "$story_id" "$_claim_source" \
        "$_claim_blob" "$_claim_record" postclaim "$_post_allow_absent"; then
      if ! _forward_evidence "$story_id" blocked remote_changed none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      rm -f "${_FORWARD_SNAPSHOT:-}"
      continue
    fi
    rm -f "$_FORWARD_SNAPSHOT"
    if ! forward_context_remove "$_claim_context" "$_claim_context_digest"; then
      if ! _forward_main_hold "$story_id" context_invalid \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi

    # ── Route: 3phase (sole delivery path post-cutover) ─────────────────────
    if ! increment_retry "$story_id"; then
      if ! _forward_restore_context_row "$_claim_context" "$_claim_row"; then
        if ! _forward_evidence "$story_id" blocked context_invalid none \
            "$_post_source_digest" "$_post_record" none; then
          exit 1
        fi
        exit 1
      fi
      if ! _forward_main_hold "$story_id" effect_inhibited \
          "$_post_source_digest" "$_post_record"; then
        exit 1
      fi
      continue
    fi
    if ! launch_3phase_in_tmux "$story_id" "$_trace_id" "$_claim_source" \
        "$_claim_blob" "$_claim_record"; then
      if ! _forward_evidence "$story_id" failure effect_inhibited none \
          "$_FORWARD_SOURCE_DIGEST" "$_FORWARD_RECORD_DIGEST" none; then
        exit 1
      fi
      continue
    fi
    # Under set -e, a post-increment returns status 1 when its initial value is 0.
    # The counter side effect is still required; only the control-flow status is ignored.
    ((launched++)) || true

  done <<< "$ready_stories"

  if (( launched == 0 )); then
    log "${BLUE}All ready stories already in progress. Waiting...${NC}"
  fi

  # ── Stale active-spawn marker cleanup (AC1) ──────────────────────────────
  # Markers left behind by SIGKILL / daemon crash. mtime alone is insufficient
  # — the marker is touch-ed once at phase start and never updated, so a
  # legitimate 30 min Impl phase on the secondary route looks identical to a
  # crashed wrapper. Skip removal when the wrapper tmux session still exists.
  if [[ -d "$LOCK_DIR" ]]; then
    _stale_now=$(date +%s)
    for _stale_marker in "$LOCK_DIR"/*.plan.active "$LOCK_DIR"/*.impl.active \
                         "$LOCK_DIR"/*.qa.active   "$LOCK_DIR"/*.commit.active; do
      [[ -f "$_stale_marker" ]] || continue
      _stale_basename=$(basename "$_stale_marker" .active)
      _stale_sid="${_stale_basename%.*}"
      # Skip removal when the wrapper tmux session still exists.
      if tmux has-session -t "gaai-deliver-${_stale_sid}" 2>/dev/null; then
        continue
      fi
      # No live wrapper — apply mtime grace (600s).
      if [[ "$(uname)" == "Darwin" ]]; then
        _stale_mtime=$(stat -c %Y "$_stale_marker" 2>/dev/null || stat -f %m "$_stale_marker" 2>/dev/null || echo 0)
      else
        _stale_mtime=$(stat -c %Y "$_stale_marker" 2>/dev/null || echo 0)
      fi
      if [[ $(( _stale_now - _stale_mtime )) -gt 600 ]]; then
        rm -f "$_stale_marker" 2>/dev/null || true
      fi
    done
  fi

  # ── PR watcher: sweep pending cleanup entries ────────────────────────────
  sweep_cleanup_pending || true

  # ── Worktree prune (cycle housekeeping) ──────────────────────────────────
  # Reaps administrative entries left behind by failed/escalated wrappers.
  # `git worktree prune` only removes entries whose directory is gone — it
  # never deletes a live worktree. Cheap, safe, runs once per cycle.
  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true

  # ── Reconciliation sweep: remove worktrees of done+merged stories ─────────
  # Complements watch_pr_merge_status(): that watcher only tracks in_progress
  # stories; by the time a manual merge lands, the story is already done.
  # This sweep detects integrated worktrees post-hoc via git branch --merged.
  reconcile_done_merged_worktrees || true

  # ── Orphaned-worktree reaper: reclaim worktrees of stories no longer in the
  # active backlog (archived-done / escalated / failed / branch-deleted) — the
  # accumulation class reconcile_done_merged_worktrees() cannot see because it
  # only iterates active-backlog `done` ids. Enumerates on-disk worktrees,
  # removes only concluded+clean+non-live ones, throttled internally. (#1365 follow-up)
  reap_orphaned_worktrees || true

  sleep "$POLL_INTERVAL"
done
