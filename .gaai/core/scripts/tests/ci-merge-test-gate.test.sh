#!/usr/bin/env bash
# Hermetic coverage for the base-held, hosted-only daemon merge authority.

set -uo pipefail
PASS_COUNT=0
FAIL_COUNT=0
FAIL_LOG=""
pass() { echo "  PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() {
  echo "  FAIL: $1"
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  [[ -n "$FAIL_LOG" ]] && printf '%s\n' "$1" >>"$FAIL_LOG"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$SCRIPT_DIR/../lib/test-gate.sh"

SANDBOX="$(mktemp -d /tmp/gaai-hosted-authority-XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
FAIL_LOG="$SANDBOX/failures.log"
: >"$FAIL_LOG"

FIXTURES="$SANDBOX/fixtures"
STUB_BIN="$SANDBOX/bin"
mkdir -p "$FIXTURES" "$STUB_BIN"
GH_CALL_LOG="$FIXTURES/gh-calls.log"
export FIXTURES GH_CALL_LOG

cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ -n "${GH_API_HANG_SEC:-}" ]]; then
  sleep "$GH_API_HANG_SEC" &
  hang_child_pid=$!
  [[ -n "${GH_API_CHILD_PID_FILE:-}" ]] \
    && printf '%s\n' "$hang_child_pid" >"$GH_API_CHILD_PID_FILE"
  wait "$hang_child_pid"
fi
printf '%s\n' "$*" >>"$GH_CALL_LOG"

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  if [[ "$*" == *"state,headRefOid"* ]]; then
    index=$(cat "$FIXTURES/pr-view-index" 2>/dev/null || echo 0)
    index=$(( index + 1 ))
    printf '%s\n' "$index" >"$FIXTURES/pr-view-index"
    if [[ -f "$FIXTURES/pr-view-${index}.tsv" ]]; then
      cat "$FIXTURES/pr-view-${index}.tsv"
    else
      jq -r '[if .state == "open" then "OPEN" else (.state|ascii_upcase) end,.head.sha] | @tsv' \
        "$FIXTURES/pr.json"
    fi
    exit 0
  fi
  if [[ "$*" == *"--json number"* ]]; then
    echo 7
    exit 0
  fi
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  [[ -f "$FIXTURES/admin-response.txt" ]] && cat "$FIXTURES/admin-response.txt"
  exit "${GH_ADMIN_RC:-0}"
fi

if [[ "$1" != "api" ]]; then
  exit 91
fi
method=GET
url=""
previous=""
slurp=false
for arg in "$@"; do
  if [[ "$previous" == "--method" ]]; then method="$arg"; fi
  [[ "$arg" == repos/* ]] && url="$arg"
  [[ "$arg" == "--slurp" ]] && slurp=true
  previous="$arg"
done
if [[ "$method" == "PUT" && "$url" == */pulls/7/merge ]]; then
  if [[ -n "${EXPECT_LOCK_PATH:-}" ]] \
      && flock -n "$EXPECT_LOCK_PATH" -c true >/dev/null 2>&1; then
    exit 93
  fi
  [[ -f "$FIXTURES/merge-response.json" ]] && cat "$FIXTURES/merge-response.json" || echo true
  exit "${GH_MERGE_RC:-0}"
fi
case "$url" in
  repos/\{owner\}/\{repo\}) file=repository.json ;;
  */commits/*/pulls\?*) file=pulls.json ;;
  */pulls/7)
    index=$(cat "$FIXTURES/pr-api-index" 2>/dev/null || echo 0)
    index=$(( index + 1 ))
    printf '%s\n' "$index" >"$FIXTURES/pr-api-index"
    [[ -f "$FIXTURES/pr-api-${index}.json" ]] && file="pr-api-${index}.json" || file=pr.json
    ;;
  */git/ref/heads/*) file=live-ref.json ;;
  */actions/workflows/7001/runs\?*)
    index=$(cat "$FIXTURES/runs-api-index" 2>/dev/null || echo 0)
    index=$(( index + 1 ))
    printf '%s\n' "$index" >"$FIXTURES/runs-api-index"
    [[ -f "$FIXTURES/runs-api-${index}.json" ]] && file="runs-api-${index}.json" || file=runs.json
    ;;
  */actions/workflows/7001) file=workflow.json ;;
  */actions/runs/9001/attempts/*/jobs\?*) file=jobs.json ;;
  */actions/runs/9001) file=run-detail.json ;;
  *) exit 91 ;;
esac
[[ -f "$FIXTURES/$file" ]] || exit 92
if [[ "$slurp" == "true" ]]; then
  paged_file="${file%.json}-pages.json"
  [[ -f "$FIXTURES/$paged_file" ]] \
    && cat "$FIXTURES/$paged_file" \
    || jq -s '.' "$FIXTURES/$file"
else
  cat "$FIXTURES/$file"
fi
GHEOF
chmod +x "$STUB_BIN/gh"
PATH="$STUB_BIN:$PATH"
export PATH

REMOTE="$SANDBOX/remote.git"
REPO="$SANDBOX/repo"
git init --quiet --bare "$REMOTE"
git init --quiet "$REPO"
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" checkout -q -b staging
mkdir -p "$REPO/.gaai/project/ci" "$REPO/.github/workflows" \
  "$REPO/.gaai/core/scripts/lib" "$REPO/.gaai/core/scripts" "$REPO/scripts"
cat > "$REPO/.gaai/project/ci/premerge-authority.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "repository": {"id": 42, "full_name": "test/repo", "base_ref": "staging"},
  "workflow": {"id": 7001, "path": ".github/workflows/test-gate.yml", "name": "Test Gate", "event": "pull_request"},
  "required_job": "PR Authority",
  "covered_paths": [
    ".gaai/project/ci/premerge-authority.json",
    ".github/workflows/test-gate.yml",
    "scripts/classifier.sh",
    ".gaai/core/scripts/backlog-scheduler.sh",
    ".gaai/core/scripts/daemon-start.sh",
    ".gaai/core/scripts/delivery-daemon.sh",
    ".gaai/core/scripts/daemon-dispatch.sh",
    ".gaai/core/scripts/lib/backlog-journal.sh",
    ".gaai/core/scripts/lib/backlog-yaml.sh",
    ".gaai/core/scripts/lib/chore-commit.sh",
    ".gaai/core/scripts/lib/commit-retry-containment.sh",
    ".gaai/core/scripts/lib/daemon-home.sh",
    ".gaai/core/scripts/lib/home-branch-guard.sh",
    ".gaai/core/scripts/lib/stuck-classifier.sh",
    ".gaai/core/scripts/lib/worktree-integrity.sh",
    ".gaai/core/scripts/lib/test-gate.sh",
    ".gaai/core/scripts/lib/delivery-routing.sh",
    ".gaai/core/scripts/lib/yaml-runtime.sh",
    ".gaai/core/vendor/pyyaml/6.0.3/pyyaml-runtime.pyz",
    ".gaai/core/vendor/pyyaml/6.0.3/PROVENANCE.json",
    "protected.txt",
    "protected-delete.txt",
    "protected-rename.txt",
    "future-protected.txt"
  ]
}
JSON
printf 'workflow\n' > "$REPO/.github/workflows/test-gate.yml"
printf 'classifier\n' > "$REPO/scripts/classifier.sh"
printf 'schedule\n' > "$REPO/.gaai/core/scripts/backlog-scheduler.sh"
printf 'start\n' > "$REPO/.gaai/core/scripts/daemon-start.sh"
printf 'entry\n' > "$REPO/.gaai/core/scripts/delivery-daemon.sh"
printf 'controller\n' > "$REPO/.gaai/core/scripts/lib/test-gate.sh"
printf 'merge\n' > "$REPO/.gaai/core/scripts/daemon-dispatch.sh"
printf 'journal\n' > "$REPO/.gaai/core/scripts/lib/backlog-journal.sh"
printf 'yaml\n' > "$REPO/.gaai/core/scripts/lib/backlog-yaml.sh"
printf 'commit\n' > "$REPO/.gaai/core/scripts/lib/chore-commit.sh"
printf 'containment\n' > "$REPO/.gaai/core/scripts/lib/commit-retry-containment.sh"
printf 'home\n' > "$REPO/.gaai/core/scripts/lib/daemon-home.sh"
printf 'guard\n' > "$REPO/.gaai/core/scripts/lib/home-branch-guard.sh"
printf 'classify\n' > "$REPO/.gaai/core/scripts/lib/stuck-classifier.sh"
printf 'integrity\n' > "$REPO/.gaai/core/scripts/lib/worktree-integrity.sh"
printf 'protected\n' > "$REPO/protected.txt"
printf 'delete-me\n' > "$REPO/protected-delete.txt"
printf 'rename-me\n' > "$REPO/protected-rename.txt"
printf 'base\n' > "$REPO/safe.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin staging
git -C "$REPO" checkout -q -b story/test
printf 'candidate\n' > "$REPO/safe.txt"
git -C "$REPO" add safe.txt
git -C "$REPO" commit -q -m candidate
SAFE_HEAD=$(git -C "$REPO" rev-parse HEAD)

export GAAI_PREMERGE_AUTHORITY_POLICY_PATH=.gaai/project/ci/premerge-authority.json

reset_nominal() {
  local head_sha="${1:-$SAFE_HEAD}"
  : > "$GH_CALL_LOG"
  rm -f "$FIXTURES"/pr-view-*.tsv "$FIXTURES/pr-view-index" \
    "$FIXTURES"/pr-api-*.json "$FIXTURES/pr-api-index" \
    "$FIXTURES"/runs-api-*.json "$FIXTURES/runs-api-index" \
    "$FIXTURES/pulls-pages.json" "$FIXTURES/runs-pages.json" "$FIXTURES/jobs-pages.json"
  printf 'true\n' > "$FIXTURES/merge-response.json"
  jq -n '{id:42,full_name:"test/repo"}' > "$FIXTURES/repository.json"
  jq -n '[{number:7,state:"open"}]' > "$FIXTURES/pulls.json"
  jq -n --arg head "$head_sha" --arg base "$BASE_SHA" '{
    number:7,state:"open",draft:false,mergeable:true,mergeable_state:"clean",
    head:{ref:"story/test",sha:$head,repo:{id:42,full_name:"test/repo"}},
    base:{ref:"staging",sha:$base,repo:{id:42,full_name:"test/repo"}}
  }' > "$FIXTURES/pr.json"
  jq -n --arg base "$BASE_SHA" '{object:{sha:$base}}' > "$FIXTURES/live-ref.json"
  jq -n '{id:7001,path:".github/workflows/test-gate.yml",name:"Test Gate",state:"active"}' \
    > "$FIXTURES/workflow.json"
  jq -n --arg head "$head_sha" --arg base "$BASE_SHA" '{
    id:9001,run_number:12,run_attempt:1,status:"completed",conclusion:"success",
    event:"pull_request",workflow_id:7001,head_sha:$head,head_branch:"story/test",
    head_repository:{id:42,full_name:"test/repo"},
    pull_requests:[{number:7,head:{sha:$head},base:{sha:$base}}]
  }' > "$FIXTURES/run-detail.json"
  jq -n --slurpfile run "$FIXTURES/run-detail.json" \
    '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
  jq -n '{total_count:1,jobs:[{id:9101,name:"PR Authority",status:"completed",conclusion:"success"}]}' \
    > "$FIXTURES/jobs.json"
}

outcome_once() {
  local head_sha="${1:-$SAFE_HEAD}"
  # Ordinary fixture calls should not depend on scheduler/load timing. The
  # dedicated hung-API case below supplies its own short technical timeout.
  _test_gate_observe_authority_once T "$REPO" "$head_sha" 10 | awk -F '\t' '{print $1}'
}

expect_outcome() {
  local label="$1" expected="$2" actual
  actual=$(outcome_once "${3:-$SAFE_HEAD}")
  [[ "$actual" == "$expected" ]] \
    && pass "$label -> $expected" \
    || fail "$label: expected $expected, got $actual"
}

jq_replace() {
  local file="$1" filter="$2"
  jq "$filter" "$FIXTURES/$file" > "$FIXTURES/$file.tmp" \
    && mv "$FIXTURES/$file.tmp" "$FIXTURES/$file"
}

set_run_conclusion() {
  local conclusion="$1"
  jq --arg conclusion "$conclusion" '.conclusion=$conclusion' \
    "$FIXTURES/run-detail.json" > "$FIXTURES/run-detail.json.tmp"
  mv "$FIXTURES/run-detail.json.tmp" "$FIXTURES/run-detail.json"
  jq -n --slurpfile run "$FIXTURES/run-detail.json" \
    '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
}

set_job_conclusion() {
  local conclusion="$1"
  jq --arg conclusion "$conclusion" '.jobs[0].conclusion=$conclusion' \
    "$FIXTURES/jobs.json" > "$FIXTURES/jobs.json.tmp"
  mv "$FIXTURES/jobs.json.tmp" "$FIXTURES/jobs.json"
}

echo "=== hosted merge authority state machine ==="

reset_nominal
expect_outcome "nominal exact current aggregate" hosted_pass

POLICY_UNDER_TEST="$PROJECT_DIR/.gaai/project/ci/premerge-authority.json"
# The project policy is project state, not part of the public framework tree. The
# public tree ships .gaai/project as a scaffold without a ci/ directory, so it cannot
# be asked about the policy. A project checkout has ci/ and still fails loudly when
# the policy file or a path in it is missing.
if [[ -d "$PROJECT_DIR/.gaai/project/ci" ]]; then
  POLICY_CLOSURE_OK=true
  while IFS= read -r required_path; do
    jq -e --arg path "$required_path" \
      '.covered_paths | index($path) != null' "$POLICY_UNDER_TEST" >/dev/null \
      || POLICY_CLOSURE_OK=false
  done < <(_test_gate_required_controller_paths)
  [[ "$POLICY_CLOSURE_OK" == "true" ]] \
    && pass "project policy covers the controller execution/source closure" \
    || fail "project policy omits a required controller execution/source path"

  JOURNAL_POLICY_PATH=".gaai/core/scripts/lib/backlog-journal.sh"
  if jq -e --arg path "$JOURNAL_POLICY_PATH" \
      '.covered_paths | index($path) != null' "$POLICY_UNDER_TEST" >/dev/null; then
    pass "project policy registers the journal policy as a human-only trust surface"
  else
    fail "project policy omits the journal policy trust surface"
  fi
else
  echo "  SKIP: project policy assertions (no .gaai/project/ci in this checkout)"
fi

# Mechanical drift guard: resolve every statically named shell source in the
# protected entry points/libraries by basename and require it in the runtime
# closure. A future dynamic source is rejected unless its resolver is added to
# this test deliberately; the sole current dynamic source is chore-commit.sh.
SOURCE_CLOSURE_OK=true
SOURCE_CLOSURE=$(mktemp "$SANDBOX/source-closure.XXXXXX")
_test_gate_required_controller_paths >"$SOURCE_CLOSURE"
while IFS= read -r source_line; do
  source_basename=$(sed -nE 's#.*[/]([A-Za-z0-9._-]+\.sh).*#\1#p' <<<"$source_line")
  if [[ -z "$source_basename" && "$source_line" == *'source "$chore_lib"'* ]]; then
    source_basename=chore-commit.sh
  fi
  if [[ -z "$source_basename" ]] \
      || ! grep -qE "/${source_basename}$" "$SOURCE_CLOSURE"; then
    echo "  uncovered source expression: $source_line"
    SOURCE_CLOSURE_OK=false
  fi
done < <(grep -hE '(^|&&[[:space:]]+)[[:space:]]*source[[:space:]]+' \
  "$PROJECT_DIR/.gaai/core/scripts/daemon-start.sh" \
  "$PROJECT_DIR/.gaai/core/scripts/delivery-daemon.sh" \
  "$PROJECT_DIR/.gaai/core/scripts/daemon-dispatch.sh" \
  "$PROJECT_DIR/.gaai/core/scripts/lib/worktree-integrity.sh")
if ! grep -Eq '^SCHEDULER="\$SCRIPT_DIR/backlog-scheduler\.sh"$' \
    "$PROJECT_DIR/.gaai/core/scripts/delivery-daemon.sh" \
    || ! grep -q '^\.gaai/core/scripts/backlog-scheduler\.sh$' "$SOURCE_CLOSURE"; then
  SOURCE_CLOSURE_OK=false
fi
[[ "$SOURCE_CLOSURE_OK" == "true" ]] \
  && pass "mechanical source/invoked-command closure matches the runtime trust policy" \
  || fail "controller source/invoked-command closure drifted"

jq 'del(.covered_paths[] | select(. == ".gaai/core/scripts/delivery-daemon.sh"))' \
  "$REPO/.gaai/project/ci/premerge-authority.json" > "$SANDBOX/incomplete-policy.json"
if _test_gate_policy_validate "$SANDBOX/incomplete-policy.json" >/dev/null 2>&1; then
  fail "policy validator accepted an incomplete controller source closure"
else
  pass "policy validator rejects an incomplete controller source closure"
fi

for self_protected_path in \
  ".gaai/project/ci/premerge-authority.json" \
  ".github/workflows/test-gate.yml"; do
  jq --arg path "$self_protected_path" \
    'del(.covered_paths[] | select(. == $path))' \
    "$REPO/.gaai/project/ci/premerge-authority.json" \
    >"$SANDBOX/incomplete-self-protection-policy.json"
  if _test_gate_policy_validate \
      "$SANDBOX/incomplete-self-protection-policy.json" >/dev/null 2>&1; then
    fail "policy validator accepted missing self-protection for $self_protected_path"
  else
    pass "policy validator requires self-protection for $self_protected_path"
  fi
done

reset_nominal
printf '[]\n' > "$FIXTURES/pulls.json"
expect_outcome "zero PR associations" blocked:pr_missing

reset_nominal
jq -n '[{number:8,state:"closed"}]' > "$FIXTURES/pulls.json"
expect_outcome "closed-only PR associations" blocked:pr_closed

reset_nominal
jq -n '[
  [range(100;200) | {number:.,state:"closed"}],
  [{number:7,state:"open"}]
]' > "$FIXTURES/pulls-pages.json"
expect_outcome "open PR on a later association page" hosted_pass

reset_nominal
jq -n '[
  ([{number:7,state:"open"}] + [range(100;199) | {number:.,state:"closed"}]),
  [{number:8,state:"open"}]
]' > "$FIXTURES/pulls-pages.json"
expect_outcome "open PR ambiguity across association pages" blocked:pr_ambiguous

reset_nominal
jq_replace pulls.json '. + [{number:8,state:"open"}]'
expect_outcome "multiple PR associations" blocked:pr_ambiguous

reset_nominal
jq_replace pulls.json '. + [{number:8,state:"closed"}]'
expect_outcome "historical closed association does not make the open PR ambiguous" hosted_pass

reset_nominal
jq_replace pr.json '.state="closed"'
expect_outcome "closed PR" blocked:pr_closed

reset_nominal
jq_replace pr.json '.draft=true'
expect_outcome "draft PR" blocked:pr_draft

reset_nominal
jq_replace pr.json '.mergeable=false'
expect_outcome "non-merge-ready PR" blocked:pr_not_merge_ready

reset_nominal
jq_replace repository.json '.id=99'
expect_outcome "repository identity mismatch" blocked:repository_mismatch

reset_nominal
jq_replace pr.json '.base.ref="main"'
expect_outcome "policy target base-ref mismatch" blocked:policy_base_ref_mismatch

reset_nominal
jq_replace workflow.json '.name="Other"'
expect_outcome "workflow identity mismatch" blocked:workflow_mismatch

reset_nominal
jq_replace run-detail.json '.event="workflow_dispatch"'
jq -n --slurpfile run "$FIXTURES/run-detail.json" '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
expect_outcome "event mismatch" blocked:event_mismatch

reset_nominal
jq_replace run-detail.json '.head_branch="other"'
jq -n --slurpfile run "$FIXTURES/run-detail.json" '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
expect_outcome "run-to-PR tuple mismatch" blocked:pr_tuple_mismatch

reset_nominal
jq_replace run-detail.json '.pull_requests[0].base.sha="0000000000000000000000000000000000000003"'
jq -n --slurpfile run "$FIXTURES/run-detail.json" '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
expect_outcome "run-to-PR base association mismatch" blocked:pr_tuple_mismatch

reset_nominal
jq_replace run-detail.json '.pull_requests=[]'
jq -n --slurpfile run "$FIXTURES/run-detail.json" '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
expect_outcome "missing run-to-PR association" blocked:pr_tuple_mismatch

reset_nominal
jq_replace pr.json '.head.sha="0000000000000000000000000000000000000001"'
expect_outcome "moved head" blocked:head_changed

reset_nominal
jq_replace live-ref.json '.object.sha="0000000000000000000000000000000000000002"'
expect_outcome "stale live base" blocked:stale_base

reset_nominal
printf '{"total_count":0,"workflow_runs":[]}\n' > "$FIXTURES/runs.json"
expect_outcome "no current run" blocked:run_missing

reset_nominal
jq_replace runs.json '.total_count=2 | .workflow_runs += [.workflow_runs[0] | .id=9002]'
expect_outcome "multiple greatest current runs" blocked:run_ambiguous

reset_nominal
jq_replace run-detail.json '.run_attempt=2'
expect_outcome "newer run attempt supersedes list snapshot" blocked:run_superseded

reset_nominal
jq_replace run-detail.json '.run_attempt=2 | .status="in_progress" | .conclusion=null'
jq -n --slurpfile latest "$FIXTURES/run-detail.json" '
  {total_count:2,workflow_runs:[
    ($latest[0] | .id=9000 | .run_attempt=1 | .status="completed" | .conclusion="success"),
    $latest[0]
  ]}
' > "$FIXTURES/runs.json"
expect_outcome "later pending rerun supersedes older success" blocked:run_pending

reset_nominal
jq_replace run-detail.json '.run_attempt=2 | .status="in_progress" | .conclusion=null'
jq -n --slurpfile latest "$FIXTURES/run-detail.json" '[
  {total_count:2,workflow_runs:[($latest[0] | .run_attempt=1 | .status="completed" | .conclusion="success")]},
  {total_count:2,workflow_runs:[$latest[0]]}
]' > "$FIXTURES/runs-pages.json"
expect_outcome "greatest pending rerun on a later runs page" blocked:run_pending

reset_nominal
cp "$FIXTURES/runs.json" "$FIXTURES/runs-api-1.json"
jq -n --slurpfile old "$FIXTURES/run-detail.json" '{
  total_count:2,
  workflow_runs:[
    $old[0],
    ($old[0] | .run_attempt=2 | .status="in_progress" | .conclusion=null)
  ]
}' > "$FIXTURES/runs-api-2.json"
expect_outcome "rerun appearing after job observation supersedes the success" blocked:run_superseded

for status in queued requested waiting pending in_progress; do
  reset_nominal
  jq --arg status "$status" '.status=$status | .conclusion=null' \
    "$FIXTURES/run-detail.json" > "$FIXTURES/run-detail.json.tmp"
  mv "$FIXTURES/run-detail.json.tmp" "$FIXTURES/run-detail.json"
  jq -n --slurpfile run "$FIXTURES/run-detail.json" '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
  expect_outcome "run status $status" blocked:run_pending
done

for conclusion in failure skipped neutral cancelled timed_out; do
  reset_nominal
  set_run_conclusion "$conclusion"
  expect_outcome "run conclusion $conclusion" "blocked:run_${conclusion/failure/failed}"
done

reset_nominal
printf '{"total_count":0,"jobs":[]}\n' > "$FIXTURES/jobs.json"
expect_outcome "authority job missing" blocked:authority_job_missing

reset_nominal
jq -n '[
  {total_count:2,jobs:[{id:9100,name:"Diagnostic",status:"completed",conclusion:"success"}]},
  {total_count:2,jobs:[{id:9101,name:"PR Authority",status:"completed",conclusion:"success"}]}
]' > "$FIXTURES/jobs-pages.json"
expect_outcome "authority job on a later jobs page" hosted_pass

reset_nominal
jq_replace jobs.json '.total_count=2 | .jobs += [.jobs[0]]'
expect_outcome "authority job duplicate" blocked:authority_job_ambiguous

reset_nominal
jq_replace jobs.json '.jobs[0].status="in_progress" | .jobs[0].conclusion=null'
expect_outcome "authority job non-complete" blocked:authority_job_pending

for conclusion in failure skipped neutral cancelled timed_out; do
  reset_nominal
  set_job_conclusion "$conclusion"
  expect_outcome "authority conclusion $conclusion" \
    "blocked:authority_job_${conclusion/failure/failed}"
done

reset_nominal
printf 'not-json\n' > "$FIXTURES/repository.json"
expect_outcome "malformed GitHub response" blocked:github_unavailable

reset_nominal
jq_replace pr.json '.mergeable="not-a-boolean"'
expect_outcome "malformed PR mergeability type" blocked:github_unavailable

reset_nominal
jq_replace run-detail.json '.pull_requests="not-an-array"'
expect_outcome "malformed run association type" blocked:github_unavailable

reset_nominal
export GH_API_HANG_SEC=10
GH_API_CHILD_PID_FILE="$SANDBOX/hung-api-child.pid"
export GH_API_CHILD_PID_FILE
API_TIMEOUT_STARTED=$(date +%s)
API_TIMEOUT_OUT=$(_test_gate_observe_authority_once T "$REPO" "$SAFE_HEAD" 1 | awk -F '\t' '{print $1}')
API_TIMEOUT_ELAPSED=$(( $(date +%s) - API_TIMEOUT_STARTED ))
HUNG_API_CHILD_PID=$(<"$GH_API_CHILD_PID_FILE")
unset GH_API_HANG_SEC GH_API_CHILD_PID_FILE
HUNG_API_CHILD_GONE=false
if ! kill -0 "$HUNG_API_CHILD_PID" 2>/dev/null; then
  HUNG_API_CHILD_GONE=true
elif ps -o stat= -p "$HUNG_API_CHILD_PID" 2>/dev/null | grep -q '^[[:space:]]*Z'; then
  # A killed orphan can remain briefly as a zombie until the runner's init
  # process reaps it. It cannot execute or consume CPU and is not a live leak.
  HUNG_API_CHILD_GONE=true
fi
[[ "$API_TIMEOUT_OUT" == blocked:github_unavailable && "$API_TIMEOUT_ELAPSED" -lt 5 \
    && "$HUNG_API_CHILD_GONE" == true ]] \
  && pass "hung GitHub API is bounded, fail-closed, and kills its process group" \
  || fail "hung API mismatch (outcome=$API_TIMEOUT_OUT elapsed=${API_TIMEOUT_ELAPSED}s)"

make_trust_head() {
  local kind="$1"
  git -C "$REPO" checkout -q -B "story/trust-${kind}" "$BASE_SHA"
  case "$kind" in
    add) printf 'added\n' > "$REPO/future-protected.txt" ;;
    delete) rm "$REPO/protected-delete.txt" ;;
    rename) git -C "$REPO" mv protected-rename.txt renamed-protected.txt ;;
    journal-change)
      printf 'changed journal policy\n' > "$REPO/.gaai/core/scripts/lib/backlog-journal.sh"
      ;;
    journal-delete)
      rm "$REPO/.gaai/core/scripts/lib/backlog-journal.sh"
      ;;
    journal-rename)
      git -C "$REPO" mv .gaai/core/scripts/lib/backlog-journal.sh \
        .gaai/core/scripts/lib/backlog-journal-renamed.sh
      ;;
    journal-replace)
      rm "$REPO/.gaai/core/scripts/lib/backlog-journal.sh"
      ln -s ../../../../safe.txt "$REPO/.gaai/core/scripts/lib/backlog-journal.sh"
      ;;
    journal-deregister)
      jq --arg path '.gaai/core/scripts/lib/backlog-journal.sh' \
        'del(.covered_paths[] | select(. == $path))' \
        "$REPO/.gaai/project/ci/premerge-authority.json" \
        >"$SANDBOX/deregistered-journal-policy.json"
      mv "$SANDBOX/deregistered-journal-policy.json" \
        "$REPO/.gaai/project/ci/premerge-authority.json"
      ;;
    policy)
      printf '{"candidate":"malformed"}\n' > "$REPO/.gaai/project/ci/premerge-authority.json"
      ;;
  esac
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "trust $kind"
  git -C "$REPO" rev-parse HEAD
}

for kind in add delete rename policy; do
  TRUST_HEAD=$(make_trust_head "$kind")
  reset_nominal "$TRUST_HEAD"
  expect_outcome "trust-path $kind" human_required:trust_surface_changed "$TRUST_HEAD"
done

for kind in journal-change journal-delete journal-rename journal-replace journal-deregister; do
  TRUST_HEAD=$(make_trust_head "$kind")
  reset_nominal "$TRUST_HEAD"
  expect_outcome "$kind cannot self-authorize" \
    human_required:trust_surface_changed "$TRUST_HEAD"
done

TRUST_HEAD=$(git -C "$REPO" rev-parse story/trust-add)
reset_nominal "$TRUST_HEAD"
jq_replace pr.json '.mergeable=false'
expect_outcome "trust change precedes terminal mergeability" human_required:trust_surface_changed "$TRUST_HEAD"

reset_nominal "$TRUST_HEAD"
jq_replace pr.json '.mergeable=null'
expect_outcome "trust change precedes pending mergeability" human_required:trust_surface_changed "$TRUST_HEAD"

git -C "$REPO" checkout -q -B story/trust-diff-driver "$BASE_SHA"
printf '*.txt diff=mask\n' >"$REPO/.gitattributes"
printf 'masked protected rewrite\n' >"$REPO/protected.txt"
git -C "$REPO" add .gitattributes protected.txt
git -C "$REPO" commit -q -m 'candidate diff driver must not mask trust changes'
DIFF_DRIVER_HEAD=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" config diff.mask.textconv true
if git -C "$REPO" diff --quiet "$BASE_SHA" "$DIFF_DRIVER_HEAD" -- protected.txt; then
  pass "textconv adversarial fixture masks an ordinary protected-path diff"
else
  fail "textconv adversarial fixture did not mask the ordinary diff"
fi
reset_nominal "$DIFF_DRIVER_HEAD"
expect_outcome "candidate Git diff drivers cannot mask protected changes" \
  human_required:trust_surface_changed "$DIFF_DRIVER_HEAD"
git -C "$REPO" config --unset diff.mask.textconv

TRUST_HEAD=$(git -C "$REPO" rev-parse story/trust-add)
reset_nominal "$TRUST_HEAD"
jq_replace repository.json '.id=99'
expect_outcome "repository mismatch precedes trust change" blocked:repository_mismatch "$TRUST_HEAD"

reset_nominal
jq '.mergeable=null' "$FIXTURES/pr.json" > "$FIXTURES/pr-api-1.json"
cp "$FIXTURES/pr.json" "$FIXTURES/pr-api-2.json"
export GAAI_CI_TEST_GATE_TIMEOUT_SEC=3 GAAI_CI_TEST_GATE_MATERIALIZE_SEC=3 \
  GAAI_CI_TEST_GATE_POLL_INTERVAL_SEC=1 GAAI_CI_TEST_GATE_API_TIMEOUT_SEC=10 \
  GAAI_CI_TEST_GATE_API_RETRIES=1
POLL_OUT=$(_test_gate_poll_hosted_authority T "$REPO" "$SAFE_HEAD" | awk -F '\t' '{print $1}')
PR_API_READS=$(grep -c 'api --method GET repos/{owner}/{repo}/pulls/7' "$GH_CALL_LOG" || true)
[[ "$POLL_OUT" == hosted_pass && "$PR_API_READS" -eq 2 ]] \
  && pass "unknown mergeability is polled until GitHub computes it" \
  || fail "pending mergeability polling mismatch (outcome=$POLL_OUT reads=$PR_API_READS)"

reset_nominal
jq_replace pr.json '.mergeable=false'
POLL_OUT=$(_test_gate_poll_hosted_authority T "$REPO" "$SAFE_HEAD" | awk -F '\t' '{print $1}')
PR_API_READS=$(grep -c 'api --method GET repos/{owner}/{repo}/pulls/7' "$GH_CALL_LOG" || true)
[[ "$POLL_OUT" == blocked:pr_not_merge_ready && "$PR_API_READS" -eq 1 ]] \
  && pass "definitively unmergeable PR is terminal without needless polling" \
  || fail "terminal mergeability mismatch (outcome=$POLL_OUT reads=$PR_API_READS)"

reset_nominal
jq_replace pr.json '.base.ref="main"'
POLL_OUT=$(_test_gate_poll_hosted_authority T "$REPO" "$SAFE_HEAD" | awk -F '\t' '{print $1}')
PR_API_READS=$(grep -c 'api --method GET repos/{owner}/{repo}/pulls/7' "$GH_CALL_LOG" || true)
[[ "$POLL_OUT" == blocked:policy_base_ref_mismatch && "$PR_API_READS" -eq 1 ]] \
  && pass "policy base-ref mismatch returns immediately from the hosted poll" \
  || fail "terminal policy poll mismatch (outcome=$POLL_OUT reads=$PR_API_READS)"

echo "=== controller-first and final mutation binding ==="

LOCAL_GATE_CALLED=0
_run_deterministic_test_gate() { LOCAL_GATE_CALLED=1; return 0; }
reset_nominal "$TRUST_HEAD"
QA_REPORT="$SANDBOX/qa.md"
: > "$QA_REPORT"
export GAAI_CI_TEST_GATE_TIMEOUT_SEC=3 GAAI_CI_TEST_GATE_MATERIALIZE_SEC=1 \
  GAAI_CI_TEST_GATE_POLL_INTERVAL_SEC=1 GAAI_CI_TEST_GATE_API_TIMEOUT_SEC=10
_run_merge_test_gate T "$REPO" "$QA_REPORT" https://github.com/test/repo/pull/7 "$TRUST_HEAD" \
  >"$SANDBOX/human-route.log" 2>&1
RC=$?
[[ "$RC" -eq 2 && "$TEST_GATE_OUTCOME" == human_required:trust_surface_changed ]] \
  && pass "trust surface routes human-required before auto-merge" \
  || fail "human-required route/result mismatch (rc=$RC outcome=$TEST_GATE_OUTCOME log=$(tail -3 "$SANDBOX/human-route.log" | tr '\n' ' '))"
[[ "$LOCAL_GATE_CALLED" -eq 0 ]] \
  && pass "human-required outcome never calls local gate" \
  || fail "human-required outcome called local gate"

reset_nominal
printf 'not-json\n' > "$FIXTURES/repository.json"
_run_merge_test_gate T "$REPO" "$QA_REPORT" https://github.com/test/repo/pull/7 "$SAFE_HEAD" \
  >/dev/null 2>&1
RC=$?
[[ "$RC" -eq 1 && "$TEST_GATE_OUTCOME" == blocked:github_unavailable ]] \
  && pass "unavailable GitHub fails closed" \
  || fail "unavailable route/result mismatch (rc=$RC outcome=$TEST_GATE_OUTCOME)"
[[ "$LOCAL_GATE_CALLED" -eq 0 ]] \
  && pass "GitHub-unavailable outcome never calls local gate" \
  || fail "GitHub-unavailable outcome called local gate"

final_recheck() {
  _test_gate_recheck_pr_tuple 7 42 test/repo staging "$BASE_SHA" story/test "$SAFE_HEAD" \
    7001 9001 12 1 9101
}

reset_nominal
TEST_GATE_AUTH_WORKTREE_PATH="$REPO"
export TEST_GATE_AUTH_WORKTREE_PATH
FINAL_OUT=$(final_recheck)
[[ "$?" -eq 0 && "$FINAL_OUT" == hosted_pass ]] \
  && pass "final recheck accepts unchanged live tuple" \
  || fail "final recheck nominal mismatch: $FINAL_OUT"

reset_nominal
jq_replace live-ref.json '.object.sha="0000000000000000000000000000000000000002"'
FINAL_OUT=$(final_recheck)
[[ "$?" -eq 1 && "$FINAL_OUT" == blocked:stale_base ]] \
  && pass "final recheck blocks stale base" \
  || fail "final stale-base mismatch: $FINAL_OUT"

reset_nominal
jq_replace pr.json '.head.sha="0000000000000000000000000000000000000003"'
FINAL_OUT=$(final_recheck)
[[ "$?" -eq 1 && "$FINAL_OUT" == blocked:head_changed ]] \
  && pass "final recheck blocks moved head" \
  || fail "final moved-head mismatch: $FINAL_OUT"

reset_nominal
jq_replace pr.json '.head.repo.id="malformed"'
FINAL_OUT=$(final_recheck)
[[ "$?" -eq 1 && "$FINAL_OUT" == blocked:github_unavailable ]] \
  && pass "final recheck classifies malformed tuple evidence as unavailable" \
  || fail "final malformed-tuple mismatch: $FINAL_OUT"

DAEMON="$SCRIPT_DIR/../daemon-dispatch.sh"
BACKLOG_FILE="$SANDBOX/backlog.yaml"
SCHEDULER=/usr/bin/false
PROJECT_DIR="$PROJECT_DIR"
LOCK_DIR="$SANDBOX/locks"
mkdir -p "$LOCK_DIR"
# shellcheck source=../daemon-dispatch.sh
source "$DAEMON"

merge_put_count() {
  grep -c '^api --method PUT .*pulls/7/merge' "$GH_CALL_LOG" 2>/dev/null || true
}

set_durable_sequence() {
  rm -f "$FIXTURES"/pr-view-*.tsv "$FIXTURES/pr-view-index"
  local index=0 state
  for state in "$@"; do
    index=$(( index + 1 ))
    printf '%s\t%s\n' "$state" "$SAFE_HEAD" > "$FIXTURES/pr-view-${index}.tsv"
  done
}

prepare_merge() {
  reset_nominal
  TEST_GATE_AUTH_PR_NUMBER=7
  TEST_GATE_AUTH_REPOSITORY_ID=42
  TEST_GATE_AUTH_REPOSITORY_NAME=test/repo
  TEST_GATE_AUTH_BASE_REF=staging
  TEST_GATE_AUTH_BASE_SHA="$BASE_SHA"
  TEST_GATE_AUTH_HEAD_REF=story/test
  TEST_GATE_AUTH_HEAD_SHA="$SAFE_HEAD"
  TEST_GATE_AUTH_WORKFLOW_ID=7001
  TEST_GATE_AUTH_RUN_ID=9001
  TEST_GATE_AUTH_RUN_NUMBER=12
  TEST_GATE_AUTH_RUN_ATTEMPT=1
  TEST_GATE_AUTH_JOB_ID=9101
  TEST_GATE_AUTH_WORKTREE_PATH="$REPO"
  export TEST_GATE_AUTH_PR_NUMBER TEST_GATE_AUTH_REPOSITORY_ID TEST_GATE_AUTH_REPOSITORY_NAME \
    TEST_GATE_AUTH_BASE_REF TEST_GATE_AUTH_BASE_SHA TEST_GATE_AUTH_HEAD_REF TEST_GATE_AUTH_HEAD_SHA \
    TEST_GATE_AUTH_WORKFLOW_ID TEST_GATE_AUTH_RUN_ID TEST_GATE_AUTH_RUN_NUMBER \
    TEST_GATE_AUTH_RUN_ATTEMPT TEST_GATE_AUTH_JOB_ID TEST_GATE_AUTH_WORKTREE_PATH
  export GAAI_MERGE_AUTHORITY_MERGE_RETRIES=3 GAAI_MERGE_AUTHORITY_RETRY_SLEEP_SEC=0 \
    GAAI_MERGE_AUTHORITY_LOCK_TIMEOUT_SEC=2 GAAI_MERGE_AUTHORITY_LOCK_POLL_SEC=1
  unset GAAI_AUTO_MERGE_ADMIN_FALLBACK GH_MERGE_RC GH_ADMIN_RC
  EXPECT_LOCK_PATH="$LOCK_DIR/.merge-authority.lock"
  export EXPECT_LOCK_PATH
}

prepare_merge
IFS='|' read -r AUTO_MERGE_APPLIED AUTO_MERGE_REASON \
  <<<"$(_resolve_auto_merge_policy false false)"
[[ "$AUTO_MERGE_APPLIED" == "false" && "$AUTO_MERGE_REASON" == story_override \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "auto_merge:false Story override cannot call merge API" \
  || fail "auto_merge:false route mismatch (applied=$AUTO_MERGE_APPLIED reason=$AUTO_MERGE_REASON puts=$(merge_put_count))"
IFS='|' read -r AUTO_MERGE_APPLIED AUTO_MERGE_REASON \
  <<<"$(_resolve_auto_merge_policy true false true)"
[[ "$AUTO_MERGE_APPLIED" == "false" && "$AUTO_MERGE_REASON" == trust_surface_changed ]] \
  && pass "human-required authority overrides an enabled merge policy" \
  || fail "human-required merge override mismatch (applied=$AUTO_MERGE_APPLIED reason=$AUTO_MERGE_REASON)"

prepare_merge
set_durable_sequence OPEN MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 0 && "$MERGE_EXACT_OUTCOME" == merged && "$(merge_put_count)" -eq 1 \
    && $(grep -c -- "-f sha=$SAFE_HEAD" "$GH_CALL_LOG") -eq 1 ]] \
  && pass "real merge path locks, rechecks, and mutates the exact authorized SHA" \
  || fail "nominal exact merge mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
set_durable_sequence OPEN OPEN MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 0 && "$MERGE_EXACT_OUTCOME" == merged && "$(merge_put_count)" -eq 1 ]] \
  && pass "durable-state lag succeeds on the next iteration without a second mutation" \
  || fail "durable lag handling mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
jq '.mergeable=null' "$FIXTURES/pr.json" > "$FIXTURES/pr-api-1.json"
cp "$FIXTURES/pr.json" "$FIXTURES/pr-api-2.json"
set_durable_sequence OPEN OPEN MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 0 && "$MERGE_EXACT_OUTCOME" == merged && "$(merge_put_count)" -eq 1 ]] \
  && pass "final recheck polls unknown mergeability before issuing one mutation" \
  || fail "final pending-mergeability mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
jq_replace pr.json '.mergeable=false'
set_durable_sequence OPEN
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 4 && "$MERGE_EXACT_OUTCOME" == blocked:pr_not_merge_ready \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "final recheck treats false mergeability as terminal without mutation" \
  || fail "final terminal-mergeability mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
set_durable_sequence MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 0 && "$MERGE_EXACT_OUTCOME" == merged && "$(merge_put_count)" -eq 0 ]] \
  && pass "already-merged exact head is idempotent before REST recheck" \
  || fail "already-merged idempotence mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
TEST_GATE_AUTH_HEAD_SHA=0000000000000000000000000000000000000001
export TEST_GATE_AUTH_HEAD_SHA
set_durable_sequence OPEN
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 4 && "$MERGE_EXACT_OUTCOME" == blocked:pr_tuple_mismatch \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "mutation argument must equal the hosted-authority head binding" \
  || fail "authority-head binding mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
set_durable_sequence OPEN
jq_replace live-ref.json '.object.sha="0000000000000000000000000000000000000002"'
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 3 && "$MERGE_EXACT_OUTCOME" == blocked:stale_base \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "final stale-base reason propagates without mutation" \
  || fail "stale-base propagation mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
set_durable_sequence OPEN
jq_replace run-detail.json '.run_attempt=2 | .status="in_progress" | .conclusion=null'
jq -n --slurpfile run "$FIXTURES/run-detail.json" \
  '{total_count:1,workflow_runs:$run}' > "$FIXTURES/runs.json"
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 4 && "$MERGE_EXACT_OUTCOME" == blocked:run_pending \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "final locked recheck rejects a rerun created after initial authorization" \
  || fail "final rerun recheck mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
set_durable_sequence OPEN
jq_replace repository.json '.id=99'
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 4 && "$MERGE_EXACT_OUTCOME" == blocked:repository_mismatch \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "concrete final-recheck reason propagates to the caller" \
  || fail "concrete final reason mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
flock -x "$EXPECT_LOCK_PATH" -c 'sleep 0.2' &
LOCK_HOLDER=$!
sleep 0.1
set_durable_sequence OPEN MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
wait "$LOCK_HOLDER"
[[ "$RC" -eq 0 && "$MERGE_EXACT_OUTCOME" == merged && "$(merge_put_count)" -eq 1 ]] \
  && pass "real merge mutation waits for the serialized lock" \
  || fail "serialized lock wait mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
export GAAI_MERGE_AUTHORITY_LOCK_TIMEOUT_SEC=1
flock -x "$EXPECT_LOCK_PATH" -c 'sleep 2' &
LOCK_HOLDER=$!
sleep 0.1
set_durable_sequence OPEN MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null 2>&1
RC=$?
[[ "$RC" -eq 4 && "$MERGE_EXACT_OUTCOME" == blocked:github_unavailable \
    && "$(merge_put_count)" -eq 0 ]] \
  && pass "live kernel lock contention reaches the configured fail-closed timeout" \
  || fail "kernel lock timeout mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"
wait "$LOCK_HOLDER"

prepare_merge
rm -f "$EXPECT_LOCK_PATH"
mkdir "$EXPECT_LOCK_PATH"
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null 2>&1
RC=$?
[[ "$RC" -eq 4 && "$MERGE_EXACT_OUTCOME" == blocked:github_unavailable \
    && -d "$EXPECT_LOCK_PATH" && "$(merge_put_count)" -eq 0 ]] \
  && pass "unopenable lock path fails closed without entering mutation" \
  || fail "unopenable lock-path mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"
rmdir "$EXPECT_LOCK_PATH"

prepare_merge
flock -x "$EXPECT_LOCK_PATH" -c 'true'
set_durable_sequence OPEN MERGED
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null
RC=$?
[[ "$RC" -eq 0 && "$MERGE_EXACT_OUTCOME" == merged && "$(merge_put_count)" -eq 1 ]] \
  && pass "kernel releases an orphaned lock automatically when its owner exits" \
  || fail "orphaned kernel lock recovery mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME puts=$(merge_put_count))"

prepare_merge
ORIGINAL_UNLOCKED=$(declare -f _merge_exact_pr_head_unlocked)
CONCURRENT_MARKER="$SANDBOX/merge-active"
CONCURRENT_VIOLATION="$SANDBOX/merge-overlap"
export CONCURRENT_MARKER CONCURRENT_VIOLATION
_merge_exact_pr_head_unlocked() {
  if ! mkdir "$CONCURRENT_MARKER" 2>/dev/null; then
    : >"$CONCURRENT_VIOLATION"
  fi
  sleep 0.2
  rmdir "$CONCURRENT_MARKER" 2>/dev/null || true
  TEST_GATE_FINAL_OUTCOME=merged
  return 0
}
_merge_exact_pr_head_capture A https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null &
MERGER_A=$!
_merge_exact_pr_head_capture B https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null &
MERGER_B=$!
wait "$MERGER_A"; MERGER_A_RC=$?
wait "$MERGER_B"; MERGER_B_RC=$?
unset -f _merge_exact_pr_head_unlocked
eval "$ORIGINAL_UNLOCKED"
[[ "$MERGER_A_RC" -eq 0 && "$MERGER_B_RC" -eq 0 && ! -e "$CONCURRENT_VIOLATION" ]] \
  && pass "two real lock callers cannot overlap their mutation critical sections" \
  || fail "kernel mutual exclusion failed (a=$MERGER_A_RC b=$MERGER_B_RC overlap=$([[ -e "$CONCURRENT_VIOLATION" ]] && echo yes || echo no))"

prepare_merge
rm -f "$EXPECT_LOCK_PATH" "${EXPECT_LOCK_PATH}.owner" "$CONCURRENT_VIOLATION"
export GAAI_MERGE_AUTHORITY_LOCK_TIMEOUT_SEC=10
ORIGINAL_UNLOCKED=$(declare -f _merge_exact_pr_head_unlocked)
ORIGINAL_PATH="$PATH"
SHLOCK_DEAD_OWNER="$SANDBOX/shlock-dead-owner"
export SHLOCK_DEAD_OWNER
# Exercise the portable branch identically on macOS and Linux. Ubuntu exposes
# flock under /usr/bin (and often /bin), while it does not ship shlock; a
# private PATH with an atomic shlock double avoids accidentally testing flock
# or depending on the host package inventory.
SHLOCK_BIN="$SANDBOX/shlock-bin"
mkdir -p "$SHLOCK_BIN"
for shlock_tool in cat date head mkdir mktemp rm rmdir sh sleep; do
  ln -s "$(command -v "$shlock_tool")" "$SHLOCK_BIN/$shlock_tool"
done
cat >"$SHLOCK_BIN/shlock" <<'SHLOCKEOF'
#!/bin/bash
owner_pid=""
lock_file=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -p) owner_pid="$2"; shift 2 ;;
    -f) lock_file="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ "$owner_pid" =~ ^[0-9]+$ && -n "$lock_file" ]] || exit 2
( set -o noclobber; printf '%s\n' "$owner_pid" >"$lock_file" ) 2>/dev/null
SHLOCKEOF
chmod +x "$SHLOCK_BIN/shlock"
PATH="$SHLOCK_BIN"
export PATH
_merge_exact_pr_head_unlocked() {
  if [[ ! "$lock_process_pid" =~ ^[0-9]+$ ]] \
      || ! kill -0 "$lock_process_pid" 2>/dev/null; then
    : >"$SHLOCK_DEAD_OWNER"
  fi
  if ! mkdir "$CONCURRENT_MARKER" 2>/dev/null; then
    : >"$CONCURRENT_VIOLATION"
  fi
  # Hold beyond shlock's lock-file freshness guard. A wrong/dead owner PID can
  # look serialized during a sub-second test yet be reclaimed while live.
  sleep 3
  rmdir "$CONCURRENT_MARKER" 2>/dev/null || true
  TEST_GATE_FINAL_OUTCOME=merged
  return 0
}
_merge_exact_pr_head_capture A https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null &
MERGER_A=$!
_merge_exact_pr_head_capture B https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" >/dev/null &
MERGER_B=$!
wait "$MERGER_A"; MERGER_A_RC=$?
wait "$MERGER_B"; MERGER_B_RC=$?
PATH="$ORIGINAL_PATH"
export PATH
unset -f _merge_exact_pr_head_unlocked
eval "$ORIGINAL_UNLOCKED"
[[ "$MERGER_A_RC" -eq 0 && "$MERGER_B_RC" -eq 0 \
    && ! -e "$CONCURRENT_VIOLATION" && ! -e "$SHLOCK_DEAD_OWNER" \
    && ! -e "$EXPECT_LOCK_PATH" ]] \
  && pass "macOS shlock fallback tracks a live owner, serializes callers, and cleans its process lock" \
  || fail "shlock mutual exclusion failed (a=$MERGER_A_RC b=$MERGER_B_RC overlap=$([[ -e "$CONCURRENT_VIOLATION" ]] && echo yes || echo no) dead_owner=$([[ -e "$SHLOCK_DEAD_OWNER" ]] && echo yes || echo no) lock=$([[ -e "$EXPECT_LOCK_PATH" ]] && echo present || echo clean))"

# Reproduce the release/EXIT-trap race deterministically: the rm double installs
# a live successor lock and signals the old holder immediately after its first
# release. Single-fire cleanup must not delete the successor on signal-driven
# exit.
prepare_merge
rm -f "$EXPECT_LOCK_PATH" "${EXPECT_LOCK_PATH}.owner"
SIGNAL_RM_MARKER="$SANDBOX/shlock-release-signalled"
REAL_RM=$(command -v rm)
export SIGNAL_RM_MARKER REAL_RM
sleep 5 &
SHLOCK_SUCCESSOR_PID=$!
export SHLOCK_SUCCESSOR_PID
rm -f "$SHLOCK_BIN/rm"
cat >"$SHLOCK_BIN/rm" <<'RMEOF'
#!/bin/bash
"$REAL_RM" "$@"
for target in "$@"; do
  if [[ "$target" == "$EXPECT_LOCK_PATH" && ! -e "$SIGNAL_RM_MARKER" ]]; then
    printf '%s\n' "$SHLOCK_SUCCESSOR_PID" >"$EXPECT_LOCK_PATH"
    : >"$SIGNAL_RM_MARKER"
    kill -TERM "$PPID"
  fi
done
RMEOF
chmod +x "$SHLOCK_BIN/rm"
PATH="$SHLOCK_BIN"
export PATH
ORIGINAL_UNLOCKED=$(declare -f _merge_exact_pr_head_unlocked)
_merge_exact_pr_head_unlocked() { TEST_GATE_FINAL_OUTCOME=merged; return 0; }
_merge_exact_pr_head_capture SIGNAL https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" \
  >/dev/null 2>&1
SIGNAL_RELEASE_RC=$?
unset -f _merge_exact_pr_head_unlocked
eval "$ORIGINAL_UNLOCKED"
PATH="$ORIGINAL_PATH"
export PATH
SIGNAL_SUCCESSOR_OWNER=$(cat "$EXPECT_LOCK_PATH" 2>/dev/null || true)
if [[ -e "$SIGNAL_RM_MARKER" && "$SIGNAL_SUCCESSOR_OWNER" == "$SHLOCK_SUCCESSOR_PID" \
      && "$SIGNAL_RELEASE_RC" -ne 0 ]]; then
  pass "signal after portable release cannot delete a live successor lock"
else
  fail "portable release signal race mismatch (rc=$SIGNAL_RELEASE_RC owner=$SIGNAL_SUCCESSOR_OWNER successor=$SHLOCK_SUCCESSOR_PID)"
fi
kill "$SHLOCK_SUCCESSOR_PID" 2>/dev/null || true
wait "$SHLOCK_SUCCESSOR_PID" 2>/dev/null || true
"$REAL_RM" -f "$EXPECT_LOCK_PATH" "${EXPECT_LOCK_PATH}.owner" "$SIGNAL_RM_MARKER"

prepare_merge
export GAAI_MERGE_AUTHORITY_MERGE_RETRIES=1 GAAI_AUTO_MERGE_ADMIN_FALLBACK=true \
  GH_MERGE_RC=1 GH_ADMIN_RC=1
set_durable_sequence OPEN OPEN OPEN OPEN
_merge_exact_pr_head_capture T https://github.com/test/repo/pull/7 7 "$SAFE_HEAD" \
  >"$SANDBOX/admin-fallback.log" 2>&1
RC=$?
ADMIN_LOG=$(<"$SANDBOX/admin-fallback.log")
[[ "$RC" -eq 1 && "$MERGE_EXACT_OUTCOME" == AUTO_MERGE_FAILED \
    && "$ADMIN_LOG" == *"admin fallback rejected"* ]] \
  && pass "admin fallback rejection is explicit and durably verified" \
  || fail "admin fallback audit mismatch (rc=$RC outcome=$MERGE_EXACT_OUTCOME log=$ADMIN_LOG)"

unset GAAI_CI_TEST_GATE_TIMEOUT_SEC GAAI_CI_TEST_GATE_MATERIALIZE_SEC \
  GAAI_CI_TEST_GATE_POLL_INTERVAL_SEC GAAI_CI_TEST_GATE_API_TIMEOUT_SEC \
  GAAI_CI_TEST_GATE_API_RETRIES \
  GAAI_MERGE_AUTHORITY_MERGE_RETRIES GAAI_MERGE_AUTHORITY_RETRY_SLEEP_SEC \
  GAAI_MERGE_AUTHORITY_LOCK_TIMEOUT_SEC GAAI_MERGE_AUTHORITY_LOCK_POLL_SEC \
  GAAI_AUTO_MERGE_ADMIN_FALLBACK GH_MERGE_RC GH_ADMIN_RC EXPECT_LOCK_PATH \
  CONCURRENT_MARKER CONCURRENT_VIOLATION

echo ""
echo "=== deterministic-block classification (commit-phase circuit breaker) ==="

# The four policy-identity mismatches are decided the moment the base-held
# policy and live GitHub disagree. Re-observing the same candidate returns the
# same answer, so the commit phase must stall rather than re-push and buy
# another hosted run.
TERMINAL_OUTCOMES=(
  blocked:repository_mismatch blocked:workflow_mismatch
  blocked:event_mismatch blocked:policy_base_ref_mismatch
)
for outcome in "${TERMINAL_OUTCOMES[@]}"; do
  _test_gate_outcome_is_deterministic "$outcome" \
    && pass "${outcome} is non-retryable" \
    || fail "${outcome} must be classified non-retryable"
done

# Everything else stays retryable. Keep this matrix exhaustive over every
# outcome emitted by the controller so a future vocabulary addition cannot
# silently inherit terminal behavior or escape classification coverage.
RETRYABLE_OUTCOMES=(
  blocked:authority_job_ambiguous blocked:authority_job_cancelled \
  blocked:authority_job_failed blocked:authority_job_missing \
  blocked:authority_job_neutral blocked:authority_job_pending \
  blocked:authority_job_skipped blocked:authority_job_timed_out \
  blocked:github_unavailable blocked:head_changed \
  blocked:pr_ambiguous blocked:pr_closed blocked:pr_draft blocked:pr_missing \
  blocked:pr_not_merge_ready blocked:pr_tuple_mismatch \
  blocked:run_ambiguous blocked:run_cancelled blocked:run_failed \
  blocked:run_missing blocked:run_neutral blocked:run_pending \
  blocked:run_skipped blocked:run_superseded blocked:run_timed_out \
  blocked:stale_base hosted_pass human_required:trust_surface_changed ""
)
for outcome in "${RETRYABLE_OUTCOMES[@]}"; do
  _test_gate_outcome_is_deterministic "$outcome" \
    && fail "${outcome:-<empty>} must stay retryable" \
    || pass "${outcome:-<empty>} stays retryable"
done

EMITTED_BLOCKED_OUTCOMES=$(grep -Eo 'blocked:[a-z_]+' "$SCRIPT_DIR/../lib/test-gate.sh" | sort -u)
CLASSIFIED_BLOCKED_OUTCOMES=$(printf '%s\n' \
  "${TERMINAL_OUTCOMES[@]}" "${RETRYABLE_OUTCOMES[@]}" \
  | grep '^blocked:' | sort -u)
if [[ "$EMITTED_BLOCKED_OUTCOMES" == "$CLASSIFIED_BLOCKED_OUTCOMES" ]]; then
  pass "every emitted blocked outcome has an explicit retry classification"
else
  fail "blocked-outcome classification matrix drifted (emitted=$(tr '\n' ',' <<<"$EMITTED_BLOCKED_OUTCOMES") classified=$(tr '\n' ',' <<<"$CLASSIFIED_BLOCKED_OUTCOMES"))"
fi

echo ""
echo "  ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  echo "  Failed assertions:"
  sed 's/^/    - /' "$FAIL_LOG"
fi
[[ "$FAIL_COUNT" -eq 0 ]]
