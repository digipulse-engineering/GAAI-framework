#!/usr/bin/env bash
# ── codex-executor.test.sh ─────────────────────────────────────────────────
# Regression coverage for the GAAI daemon's Codex headless executor.
#
# Run: bash .gaai/core/scripts/tests/codex-executor.test.sh
# Exit 0 = all pass.

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMPDIR_TEST="$(mktemp -d /tmp/gaai-codex-executor-test-XXXXXX)"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

PROJECT_DIR="$REPO_ROOT"
LOCK_DIR="$TMPDIR_TEST/locks"
WORKTREE="$TMPDIR_TEST/worktree"
FAKEBIN="$TMPDIR_TEST/bin"
mkdir -p "$LOCK_DIR" "$WORKTREE/.delivery-logs" "$FAKEBIN"

PROMPT_FILE="$TMPDIR_TEST/prompt.md"
LOG_FILE="$WORKTREE/.delivery-logs/T-CODEX.plan.log"
ARGS_FILE="$TMPDIR_TEST/codex.args"
STDIN_FILE="$TMPDIR_TEST/codex.stdin"
printf 'Write the required GAAI artefact.\n' > "$PROMPT_FILE"

cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GAAI_CODEX_ARGS_FILE"
cat > "$GAAI_CODEX_STDIN_FILE"
printf '{"type":"thread.started","thread_id":"test"}\n'
printf '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n'
SH
chmod +x "$FAKEBIN/codex"

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
cat > "$GAAI_CLAUDE_STDIN_FILE"
printf '{"type":"result","subtype":"success"}\n'
SH
chmod +x "$FAKEBIN/claude"

source "$REPO_ROOT/.gaai/core/scripts/daemon-dispatch.sh"

echo "T1: codex executor builds codex exec command and streams JSONL"
PATH="$FAKEBIN:$PATH" \
GAAI_DAEMON_EXECUTOR=codex \
GAAI_CODEX_MODEL=gpt-test \
GAAI_CODEX_SANDBOX=workspace-write \
GAAI_CODEX_ARGS_FILE="$ARGS_FILE" \
GAAI_CODEX_STDIN_FILE="$STDIN_FILE" \
  _run_claude_with_loop_breaker \
    "T-CODEX" "plan" "$LOG_FILE" "$PROMPT_FILE" "$WORKTREE" >/dev/null 2>&1
T1_RC=$?

if [[ "$T1_RC" -eq 0 ]]; then
  pass "T1a: codex executor returns child exit code 0"
else
  fail "T1a: codex executor returned $T1_RC"
fi

EXPECTED_ARGS="exec --json --sandbox workspace-write --cd $WORKTREE --model gpt-test --ephemeral -"
if [[ "$(cat "$ARGS_FILE" 2>/dev/null)" == "$EXPECTED_ARGS" ]]; then
  pass "T1b: codex exec args are canonical"
else
  fail "T1b: codex exec args mismatch: $(cat "$ARGS_FILE" 2>/dev/null)"
fi

if cmp -s "$PROMPT_FILE" "$STDIN_FILE"; then
  pass "T1c: prompt file is passed to codex exec stdin"
else
  fail "T1c: prompt stdin mismatch"
fi

if grep -q '"type":"turn.completed"' "$LOG_FILE" 2>/dev/null; then
  pass "T1d: codex JSONL stream is written to phase log"
else
  fail "T1d: codex JSONL stream missing from phase log"
fi

echo "T2: unsupported executor is rejected before spawn"
GAAI_DAEMON_EXECUTOR=bogus \
  _run_claude_with_loop_breaker \
    "T-CODEX" "plan" "$LOG_FILE" "$PROMPT_FILE" "$WORKTREE" >/dev/null 2>&1
T2_RC=$?

if [[ "$T2_RC" -eq 2 ]]; then
  pass "T2a: unsupported executor returns usage error"
else
  fail "T2a: unsupported executor returned $T2_RC"
fi

echo "T3: Plan prompt is self-contained after template expansion (AC1, AC3)"
PLAN_TEMPLATE="$REPO_ROOT/.gaai/core/agents/sub-agents/planning.daemon-prompt.md"
PLAN_PROMPT="$TMPDIR_TEST/plan-prompt.md"
FIX_STORY_ID="T-CTXFIX"
FIX_WORKTREE="/tmp/gaai-fixture-worktree"
FIX_STORY_PATH="/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/stories/T-CTXFIX.story.md"
FIX_PLAN_PATH="/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/plans/T-CTXFIX.execution-plan.md"
FIX_EPIC_PATH="/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/epics/E999.epic.md"
_expand_daemon_prompt_template "$PLAN_TEMPLATE" "$PLAN_PROMPT" \
  "GAAI_STORY_ID=$FIX_STORY_ID" "GAAI_WORKTREE_PATH=$FIX_WORKTREE" \
  "GAAI_STORY_PATH=$FIX_STORY_PATH" "GAAI_PLAN_PATH=$FIX_PLAN_PATH" \
  "GAAI_EPIC_PATH=$FIX_EPIC_PATH"

if grep -qE '\$GAAI_[A-Z_]+' "$PLAN_PROMPT"; then
  fail "T3a: Plan prompt still contains unexpanded \$GAAI_ tokens: $(grep -oE '\$GAAI_[A-Z_]+' "$PLAN_PROMPT" | sort -u | tr '\n' ' ')"
else
  pass "T3a: Plan prompt has zero unexpanded \$GAAI_ tokens"
fi
if grep -qF "$FIX_STORY_PATH" "$PLAN_PROMPT" && grep -qF "$FIX_PLAN_PATH" "$PLAN_PROMPT" && grep -qF "$FIX_WORKTREE" "$PLAN_PROMPT"; then
  pass "T3b: Plan prompt carries resolved path values"
else
  fail "T3b: Plan prompt missing one or more resolved path values"
fi

# executor-invariance: same prompt file, both executors, byte-identical stdin
CLAUDE_CAPTURE="$TMPDIR_TEST/claude-stdin-plan.txt"
CODEX_CAPTURE="$TMPDIR_TEST/codex-stdin-plan.txt"
PATH="$FAKEBIN:$PATH" GAAI_DAEMON_EXECUTOR=claude GAAI_CLAUDE_STDIN_FILE="$CLAUDE_CAPTURE" \
  _run_claude_with_loop_breaker "T-CTXFIX" "plan" "$LOG_FILE" "$PLAN_PROMPT" "$WORKTREE" >/dev/null 2>&1
PATH="$FAKEBIN:$PATH" GAAI_DAEMON_EXECUTOR=codex GAAI_CODEX_ARGS_FILE="$ARGS_FILE" GAAI_CODEX_STDIN_FILE="$CODEX_CAPTURE" \
  _run_claude_with_loop_breaker "T-CTXFIX" "plan" "$LOG_FILE" "$PLAN_PROMPT" "$WORKTREE" >/dev/null 2>&1
if cmp -s "$CLAUDE_CAPTURE" "$CODEX_CAPTURE"; then
  pass "T3c: prompt bytes are executor-invariant (claude stdin == codex stdin)"
else
  fail "T3c: executor-invariance broken — claude and codex received different prompt bytes"
fi

echo "T4: QA prompt is self-contained after template expansion (AC2, AC3)"
QA_TEMPLATE="$REPO_ROOT/.gaai/core/agents/sub-agents/qa.daemon-prompt.md"
QA_PROMPT="$TMPDIR_TEST/qa-prompt.md"
FIX_QA_SCHEMA_PATH="$REPO_ROOT/.gaai/core/schemas/qa-verdict.v1.schema.json"
FIX_QA_VERDICT_PATH="/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/qa-reports/T-CTXFIX.qa-verdict.json"
FIX_QA_EXPECTED_SURFACES_PATH="/tmp/gaai-fixture-worktree/expected-surfaces.json"
FIX_QA_ADMISSION_EVIDENCE_PATH="/tmp/gaai-fixture-locks/.qa-admission-evidence-T-CTXFIX.json"
_expand_daemon_prompt_template "$QA_TEMPLATE" "$QA_PROMPT" \
  "GAAI_STORY_PATH=$FIX_STORY_PATH" "GAAI_PLAN_PATH=$FIX_PLAN_PATH" \
  "GAAI_IMPL_REPORT_PATH=/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/impl-reports/T-CTXFIX.impl-report.md" \
  "GAAI_QA_REPORT_PATH=/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/qa-reports/T-CTXFIX.qa-report.md" \
  "GAAI_QA_SCHEMA_PATH=$FIX_QA_SCHEMA_PATH" \
  "GAAI_QA_VERDICT_PATH=$FIX_QA_VERDICT_PATH" \
  "GAAI_QA_EXPECTED_SURFACES_PATH=$FIX_QA_EXPECTED_SURFACES_PATH" \
  "GAAI_QA_ADMISSION_EVIDENCE_PATH=$FIX_QA_ADMISSION_EVIDENCE_PATH" \
  "GAAI_EPIC_PATH=$FIX_EPIC_PATH" \
  "GAAI_BASE_REF=origin/staging" \
  "GAAI_WORKTREE_PATH=$FIX_WORKTREE" \
  "GAAI_MEMORY_DELTA_PATH=/tmp/gaai-fixture-worktree/.gaai/project/contexts/artefacts/memory-deltas/T-CTXFIX.memory-delta.md"

if grep -qE '\$GAAI_[A-Z_]+' "$QA_PROMPT"; then
  fail "T4a: QA prompt still contains unexpanded \$GAAI_ tokens: $(grep -oE '\$GAAI_[A-Z_]+' "$QA_PROMPT" | sort -u | tr '\n' ' ')"
else
  pass "T4a: QA prompt has zero unexpanded \$GAAI_ tokens"
fi
if grep -qF "origin/staging" "$QA_PROMPT"; then
  pass "T4b: QA prompt carries resolved GAAI_BASE_REF value"
else
  fail "T4b: QA prompt missing resolved GAAI_BASE_REF value"
fi
if grep -qF "$FIX_QA_SCHEMA_PATH" "$QA_PROMPT" && grep -qF "$FIX_QA_VERDICT_PATH" "$QA_PROMPT" && grep -qF "$FIX_QA_EXPECTED_SURFACES_PATH" "$QA_PROMPT"; then
  pass "T4c: QA prompt carries resolved GAAI_QA_SCHEMA_PATH/GAAI_QA_VERDICT_PATH/GAAI_QA_EXPECTED_SURFACES_PATH values (DEC-200)"
else
  fail "T4c: QA prompt missing one or more resolved DEC-200 two-axis handoff path values"
fi
if grep -qF "$FIX_QA_ADMISSION_EVIDENCE_PATH" "$QA_PROMPT"; then
  pass "T4d: QA prompt carries resolved GAAI_QA_ADMISSION_EVIDENCE_PATH value"
else
  fail "T4d: QA prompt missing resolved GAAI_QA_ADMISSION_EVIDENCE_PATH value"
fi

# executor-invariance: same QA prompt file, both executors, byte-identical stdin (DEC-200 D6 / DEC-190 D3)
CLAUDE_CAPTURE_QA="$TMPDIR_TEST/claude-stdin-qa.txt"
CODEX_CAPTURE_QA="$TMPDIR_TEST/codex-stdin-qa.txt"
PATH="$FAKEBIN:$PATH" GAAI_DAEMON_EXECUTOR=claude GAAI_CLAUDE_STDIN_FILE="$CLAUDE_CAPTURE_QA" \
  _run_claude_with_loop_breaker "T-CTXFIX" "qa" "$LOG_FILE" "$QA_PROMPT" "$WORKTREE" >/dev/null 2>&1
PATH="$FAKEBIN:$PATH" GAAI_DAEMON_EXECUTOR=codex GAAI_CODEX_ARGS_FILE="$ARGS_FILE" GAAI_CODEX_STDIN_FILE="$CODEX_CAPTURE_QA" \
  _run_claude_with_loop_breaker "T-CTXFIX" "qa" "$LOG_FILE" "$QA_PROMPT" "$WORKTREE" >/dev/null 2>&1
echo "T5: QA prompt contract reaches both executors identically (DEC-200 D6, AC4)"
if cmp -s "$CLAUDE_CAPTURE_QA" "$CODEX_CAPTURE_QA"; then
  pass "T5a: QA prompt bytes are executor-invariant (claude stdin == codex stdin)"
else
  fail "T5a: executor-invariance broken — claude and codex received different QA prompt bytes"
fi

echo
echo "codex-executor tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
