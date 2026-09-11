#!/usr/bin/env bash
# daemon-prompt-construct.sh — Canonical impl prompt construction helper
#
# Outputs the impl prompt to stdout.
# Caller captures with: PROMPT_CONTENT=$(bash daemon-prompt-construct.sh)
#
# Required env vars:
#   GAAI_STORY_ID        — story identifier
#   GAAI_STORY_PATH      — absolute path to {id}.story.md
#   GAAI_PLAN_PATH       — absolute path to {id}.execution-plan.md
#   GAAI_EPIC_PATH       — absolute path to {epic_id}.epic.md (may be empty)
#   GAAI_WORKSPACE_PATH  — absolute worktree root (for NOTES_PATH substitution)
#   SECONDARY_ROUTE      — "true" or "false" (default: "false")
#   GAAI_STORY_TIER      — story tier, e.g. "1" or "2" (default: "", treated as < 2)
#   PROJECT_DIR          — repo root (for resolving DEC file paths)

set -euo pipefail

# ── Validate required env vars ─────────────────────────────────────────────
: "${GAAI_STORY_ID:?daemon-prompt-construct.sh: GAAI_STORY_ID is required}"
: "${GAAI_STORY_PATH:?daemon-prompt-construct.sh: GAAI_STORY_PATH is required}"
: "${GAAI_PLAN_PATH:?daemon-prompt-construct.sh: GAAI_PLAN_PATH is required}"
: "${GAAI_WORKSPACE_PATH:?daemon-prompt-construct.sh: GAAI_WORKSPACE_PATH is required}"
: "${PROJECT_DIR:?daemon-prompt-construct.sh: PROJECT_DIR is required}"

SECONDARY_ROUTE="${SECONDARY_ROUTE:-false}"
GAAI_STORY_TIER="${GAAI_STORY_TIER:-}"
NOTES_PATH="${GAAI_WORKSPACE_PATH}/.gaai/project/contexts/artefacts/notes/${GAAI_STORY_ID}.notes.md"
# The bound on the working-memory file. The rule below used to state two of these
# five times apart — a cap, and a larger size at which the file becomes a
# compact-trigger in its own right. Only the second describes a harm; the first
# just made the agent rewrite a file that was doing its job. Keep the stated harm
# threshold as the bound, and let an operator size it to their stories.
NOTES_MAX_CHARS="${GAAI_NOTES_MAX_CHARS:-10000}"
[[ "$NOTES_MAX_CHARS" =~ ^[1-9][0-9]{2,6}$ ]] || NOTES_MAX_CHARS=10000

# ── notes.md context-recovery discipline applies whenever the route is
#    secondary OR the story is Tier 2+, independent of route. The
#    tier-aware default-route coercion routes Tier 2+ absent-tag stories to
#    primary, so gating on SECONDARY_ROUTE alone left the population most
#    likely to need this discipline (long/complex Impl sessions) with none
#    of it. Only Section 1 (this gate) is affected — the input-artefact and
#    prior-QA-findings inline-vs-chunked gates below stay SECONDARY_ROUTE-
#    only: that is a separate, context-budget concern, not this one.
NOTES_DISCIPLINE_TIER_GATED="false"
if [[ "$GAAI_STORY_TIER" =~ ^[0-9]+$ ]] && (( GAAI_STORY_TIER >= 2 )); then
  NOTES_DISCIPLINE_TIER_GATED="true"
fi
NOTES_DISCIPLINE_ENABLED="false"
if [[ "$SECONDARY_ROUTE" == "true" || "$NOTES_DISCIPLINE_TIER_GATED" == "true" ]]; then
  NOTES_DISCIPLINE_ENABLED="true"
fi

# ── Section 1: R1-R6 context discipline preamble ───────────────────────────
# Single heredoc with a pre-computed ${ROUTE_RATIONALE} substitution — NOT
# split across two heredocs joined at runtime. A prior version of this gate
# concatenated a route-specific heredoc with the shared trailing heredoc and
# silently dropped the blank line at the join, producing byte-different
# output from the pre-existing behaviour on the very route (secondary) that
# must stay unchanged. Keeping this as one heredoc makes that class of bug
# structurally impossible: there is no join boundary left to drop a line at.
if [[ "$NOTES_DISCIPLINE_ENABLED" == "true" ]]; then
  if [[ "$SECONDARY_ROUTE" == "true" ]]; then
    ROUTE_RATIONALE="You operate in a long-running agentic session with a 200K context window
and aggressive autocompaction. Failure to follow these rules causes session
termination via rapid_refill_breaker (Claude Code internal safety) — observed
empirically at 43% fail rate on this routing path."
  else
    ROUTE_RATIONALE="This is a Tier ${GAAI_STORY_TIER} story: complex Impl sessions on this tier
have been observed to exhaust the MAX_TURNS budget or hit an autocompaction
boundary before producing an impl-report. Failure to follow these rules risks
losing all recoverable state if that happens."
  fi
  cat <<PREAMBLE
=== CONTEXT DISCIPLINE (MANDATORY for this delivery) ===

${ROUTE_RATIONALE}

These rules are derived from Anthropic's "Effective Context Engineering for
AI Agents" guidance. They apply throughout this session.

## R1 — Persistent notes file (MOST IMPORTANT — MANDATORY CADENCE)

Maintain a working-memory file at this exact path :
${NOTES_PATH}

This file is filesystem-persistent and survives autocompaction. It is your
SINGLE SOURCE OF TRUTH for state recovery. The file is committed as a
delivery artefact alongside execution-plan, impl-report, and qa-report.

**EMPIRICAL EVIDENCE** : sessions that wrote NOTES only once across 31 tool
calls hit 3 compacts because there was no canonical state to recover from
post-compact, forcing re-reads that triggered the next compact.

**HARD RULE — MANDATORY NOTES Write/Edit cadence** :
- (a) IMMEDIATELY after every \`compact_boundary\` event (you will see it
  in your context as a recovery prompt) — this is non-negotiable
- (b) After every 5 tool_use calls (count them — this is enforced)
- (c) Before any \`Edit\` or \`Write\` to source code

**Size cap** : keep the NOTES file under ${NOTES_MAX_CHARS} characters. Rewrite
(full overwrite) when sections grow stale ; do NOT let it grow unbounded. Past
that size the file becomes a compact-trigger in its own right, which is the harm
this bound exists to avoid.

Do NOT compact below it as a goal. Every turn spent shrinking a file that is
already within bounds is a turn not spent on the work, and whatever you drop is
state your next attempt will not inherit. Write freely up to the bound; compact
only when you reach it.

A session ending with <3 NOTES Writes per compact_boundary is a rule
violation.

### Initial creation (on your very first action)

If the file does not yet exist, create it with the EXACT bootstrap template
below. Then proceed with the actual work.

\`\`\`markdown
# Working Memory — ${GAAI_STORY_ID}

## ⚠ RULES (re-read these every time you read this file)

R1 : MANDATORY NOTES Write after (a) every compact_boundary,
     (b) every 5 tool_use calls, (c) before every Edit. Cap ≤2K chars.
R2 : Never re-read a file listed under "Files read" — the summary is canonical.
R3 : HARD RULE — every assistant turn between tool_use blocks MUST contain
     a one-sentence "<result>...<next-action>" summary. No silent tool→tool.
R4 : MANDATORY — every Read MUST include offset AND limit. wc -l first.
     Bash verbose → tail -100 / head -100.
R5 : Work on ONE acceptance criterion at a time. Commit before next AC.
R6 : Post-compact recovery sequence is FIXED — Read NOTES first, then
     execution-plan, then summarise AC state, THEN next action. No deviation.
R7 : Bash output >50 lines MUST be bounded (tail/head/grep). Unbounded
     pnpm test / git log / find = #2 cause of compact pressure.

## Current step

<one sentence — update continuously>

## Files read (canonical — do NOT re-read)

- path/to/file.ts (lines X-Y) : <one-line summary of what matters>
- ...

## Decisions made

- <decision + brief rationale>

## Acceptance criteria status

- AC1 : <pending|in-progress|done|blocked>
- AC2 : ...

## Open questions / blockers

- <if any>

## Tool calls made (running log — append-only)

- T1 : Read auth.ts L23-67 → exports validateSession(token), HMAC-SHA256
- T2 : Edit membership.ts L102 → added workspace_id field
- ...
\`\`\`

### R6 — Post-autocompact recovery sequence (HARD RULE — FIXED ORDER)

**EMPIRICAL EVIDENCE** : in 3/3 observed compact recoveries, the agent
fired Read-Read-Read of source files instead of consulting NOTES first,
which re-flooded context and triggered the next compact.

**Whenever a \`compact_boundary\` event appears in your context, your FIRST
action MUST be EXACTLY this sequence — no deviation, no shortcut** :

1. \`Read ${NOTES_PATH}\` with offset=0 limit=200
2. \`Read ${GAAI_WORKSPACE_PATH}/.gaai/project/contexts/artefacts/plans/${GAAI_STORY_ID}.execution-plan.md\` with offset=0 limit=100
3. Emit ONE assistant text turn summarising current AC state + last completed
   step + next intended action (R3 format)
4. ONLY THEN issue the next non-recovery tool call

Any other first-action post-compact (e.g., re-Reading a source file, running
Bash, calling Grep) is a rule violation that wastes the recovery window and
will trigger the next compact within 3-5 turns.

### Append-only retry semantics

If this delivery is a retry (e.g., second nested-claude-spawn for ${GAAI_STORY_ID} after
a prior failure), the existing notes file represents your prior attempt's
findings. PRESERVE all "Files read" and "Decisions made" entries — they
remain valid. Only update "Current step", AC status, and append new tool
calls. Append-tolerant by design.

## R2 — Never re-read

Never re-read a file already listed under "Files read" in your notes file.
The summary IS canonical. If you doubt the summary, re-read the file ONLY
WITH a tighter offset/limit on the specific lines you need (not the whole
file again).

## R3 — Self-summarize after every tool result (HARD RULE)

**HARD RULE — every assistant turn between two \`tool_use\` blocks MUST
contain ONE structured summary sentence.** No silent tool→tool sequences.

Format :
"<file/result> contains <fact>. Now <next intended action>."

Example :
"auth.ts L23-67 exports validateSession(token), HMAC-SHA256 over headers,
no rate limiting. Now editing membership.ts to call it from hasAccess()."

**Why it's enforced** : R3 summaries are what makes R1 NOTES updates possible
(you cannot summarise NOTES without per-result thinking) AND what prevents
R6 violations post-compact (the summary IS the recovery state). A turn
that fires Read → Read → Read with no inter-turn assistant text is a rule
violation that compounds R1, R2, R6 simultaneously.

## R4 — Just-in-time chunked retrieval (MANDATORY — most-violated rule)

**EMPIRICAL EVIDENCE** : 4 unchunked Reads in a single session inflated
context from post-compact 4.7K to 180K within 5 turns, triggering the 3rd
compact and rapid_refill_breaker termination. Single most common cause of
session death on this routing path.

**HARD RULE — every \`Read\` tool call MUST include both \`offset\` AND
\`limit\` parameters.** A Read without \`offset\`+\`limit\` is a rule
violation that will likely terminate this session.

**Required workflow for any file Read :**

1. **Discover size FIRST** via Bash : \`wc -l <file>\`
   - <100 lines : safe to Read whole (still pass offset=0 limit=N)
   - 100-300 lines : Read offset=0 limit=200 first, then decide
   - >300 lines : Grep for the relevant pattern FIRST, then targeted
     Read offset=<line-of-match> limit=200 around the match
2. **Summarize each chunk** in NOTES per R3 BEFORE next Read (no rapid
   sequential Reads)
3. **NEVER** issue \`Read(file_path)\` with no offset/limit on files >100
   lines — this floods the context window and is the #1 cause of death

**Bash verbose output** (tests, builds, logs) : ALWAYS pipe through
\`head -100\` or \`tail -100\` to bound output. \`pnpm test 2>&1 | tail -100\`,
\`grep -n PATTERN file | head -50\`. Never run a command that may produce
>200 lines without bounding.

**Prefer Grep over Read** when looking for a pattern across files. Grep
returns line numbers + matches only — orders of magnitude smaller than
full file content.

## R5 — Single-feature focus

Per Anthropic's harness guidance : work on ONE acceptance criterion at a
time, commit before advancing. Do not parallelize ACs across multiple
files in flight — context bloat is fatal here.

## R7 — Bounded Bash output (MANDATORY)

**EMPIRICAL EVIDENCE** : unbounded Bash output is the #2 cause of compact
pressure after R4 violations. A single \`pnpm test\` without bounding can
emit 2-5K lines of TAP output, which alone fills 30-40 % of a 200K context.

**HARD RULE — every Bash command that may produce >50 lines MUST pipe
through \`tail -100\`, \`head -100\`, or filter via \`grep\`.**

Categories that REQUIRE bounding :

- Test runners : \`pnpm test 2>&1 | tail -100\`, \`vitest run 2>&1 | tail -100\`
- Builds / installs : \`pnpm install 2>&1 | tail -50\`, \`pnpm build 2>&1 | tail -50\`
- Git history : \`git log --oneline -20\`, \`git log --format=... -10\`
- Find / list : \`find . -name '*.ts' | head -50\`, \`ls -la dir | head -30\`
- Greps : \`grep -rn PATTERN | head -30\` (always cap unless you know hits ≤ 10)
- Logs : \`cat .delivery-logs/file.log | tail -100\`

**Forbidden patterns** :
- Running \`pnpm test\` without \`| tail -100\` or \`-- --reporter=basic\`
- Running \`git log\` without \`-n N\` or count limit
- Running \`find\` or \`ls -R\` without head/tail piping
- Reading log files via \`cat\` instead of \`tail\`

If you genuinely need full output (rare), capture to a file and \`grep\`
specific patterns from it — never let it flow into your context.

## Few-shot example — good cycle

You are about to fix a bug in membership validation. Below is the PATTERN
to follow (one example turn) :

> [agent thinks] "Need to understand current validation. Let me check
> if I've already seen this file in my notes."
>
> Read ${NOTES_PATH}
> [observes : "Files read: empty" — first turn]
>
> Glob "**/membership*.ts" → 2 hits
> [agent reply : "Found 2 membership files : api/membership.ts and
> shared/membership-types.ts. Reading the api one first L1-100 to see
> the validation entry point."]
>
> Bash \`wc -l api/membership.ts\` → 287 lines (file >100, chunk required)
> Read api/membership.ts with offset=0 limit=200 → finds validateMembership() at L34
> [agent reply : "validateMembership() at L34 calls hasAccess() which is
> imported from auth.ts. Edit notes file to record this, then read auth.ts
> at the import line."]
>
> Edit ${NOTES_PATH} → append to "Files read" : "api/membership.ts L1-100
> : validateMembership at L34, calls hasAccess from auth.ts"
> Edit ${NOTES_PATH} → update "Current step" : "Reading auth.ts hasAccess()"

Notice the discipline : every tool result triggers (a) one structured
summary in the reply, (b) a notes file update.

=== END CONTEXT DISCIPLINE ===

PREAMBLE
fi

# ── Sections 2-4: input artefact handoff ─────────────────────────────────
# Two strategies based on route :
#  - SECONDARY (e.g. GLM with smaller effective context window): emit PATH
#    references only. Agent reads via Read tool with offset/limit per R4
#    chunked-retrieval rule. Keeps the upfront prompt minimal so the
#    autocompact threshold is not consumed before the agent has even acted.
#    Avoids the "double inlining" trap where the prompt has the full plan
#    AND the agent re-Reads the same file in chunks (observed empirically).
#  - PRIMARY (Sonnet): full inline. Sonnet has more context headroom and
#    benefits from upfront context — matches the prior unconditional
#    behaviour for backwards compatibility.
if [[ ! -f "$GAAI_STORY_PATH" ]]; then
  echo "[daemon-prompt-construct] ERROR: story file not found: $GAAI_STORY_PATH" >&2
  exit 1
fi
if [[ ! -f "$GAAI_PLAN_PATH" ]]; then
  echo "[daemon-prompt-construct] ERROR: plan file not found: $GAAI_PLAN_PATH" >&2
  exit 1
fi

# ── Section 1b: one-shot execution mode constraint ────────────────────────
# The impl agent runs as a single non-interactive executor invocation
# (claude -p direct, nested-claude-spawn.js, or codex exec — all one-shot) :
# when it ends its turn, the process exits — there is no next turn. Newer
# agent harnesses expose background-task affordances (run_in_background,
# monitors, scheduled wake-ups) whose mental model assumes a resumable
# session. Agents that launch the test suite in the background and end the
# turn "waiting for the wake-up" terminate the run before the impl-report
# exists, and the daemon discards the entire attempt as NO_ARTEFACT_PRODUCED
# (observed repeatedly: same story dying 3-4 consecutive attempts with all
# code changes applied but no report). Emitted unconditionally, before the
# input artefacts, so it is read before any execution begins.
cat <<ONESHOT_MODE
=== EXECUTION MODE — SINGLE NON-INTERACTIVE RUN (read before acting) ===

You are running as a one-shot non-interactive invocation: when you end your
turn, the process exits immediately. There is NO next turn, NO wake-up, and
NO background-task notification will ever reach you.

Therefore :
  - Run every verification command (test suite, typecheck, lint) in the
    FOREGROUND and wait for its output within the same tool call.
  - NEVER launch a command in the background to "check on it later", NEVER
    set up a monitor or a scheduled wake-up, and NEVER end your turn while
    any step of your work — including the mandatory handoff artefact — is
    still pending. (Backgrounding a long-lived helper process — e.g. a dev
    server your tests query — and using it within the SAME turn is fine;
    what is forbidden is ending the turn to wait on background work.)
  - Ending your turn with work "waiting on a background task" discards this
    entire run: all applied changes are treated as a failed attempt.

=== END EXECUTION MODE ===

ONESHOT_MODE

if [[ "$SECONDARY_ROUTE" == "true" ]]; then
  cat <<INPUT_REFS
=== INPUT ARTEFACTS — READ THESE FIRST (chunked, per R4) ===

Your initial actions, in this order, are :

  1. Read ${GAAI_STORY_PATH}                           — the validated story
  2. Read ${GAAI_PLAN_PATH}                            — the execution plan from the planning phase
INPUT_REFS
  if [[ -n "${GAAI_EPIC_PATH:-}" && -f "$GAAI_EPIC_PATH" ]]; then
    echo "  3. Read ${GAAI_EPIC_PATH}                            — parent epic (optional context)"
  fi
  cat <<INPUT_REFS_TAIL

Read each in chunks of ≤200 lines (offset/limit) per R4. Summarise each
chunk in your reply BEFORE the next tool call (R3). Append entries to
your notes file (R1) so you never re-read.

DO NOT expect any of the above artefacts to be inlined in this prompt.
The path references above ARE your input — read them via the Read tool.

=== END INPUT ARTEFACTS ===

INPUT_REFS_TAIL
else
  # Primary route — full inline (legacy behaviour, Sonnet-friendly)
  echo "=== STORY: ${GAAI_STORY_ID} ==="
  cat "$GAAI_STORY_PATH"
  echo ""
  echo "=== EXECUTION PLAN ==="
  cat "$GAAI_PLAN_PATH"
  echo ""
  if [[ -n "${GAAI_EPIC_PATH:-}" && -f "$GAAI_EPIC_PATH" ]]; then
    echo "=== EPIC CONTEXT ==="
    cat "$GAAI_EPIC_PATH"
    echo ""
  fi
fi

# ── Section 4b: Prior QA findings (retry-loop re-spawn only) ──────────────
# When the impl phase is re-spawned by the retry-loop after a QA FAIL, the
# dispatcher exports GAAI_QA_REPORT_PATH pointing at the previous QA agent's
# qa-report. Inject those findings here so the IMPL agent fixes the specific
# defects rather than re-implementing from scratch. The qa-report's verdict
# is FAIL (or this code path would not run). Iterations are capped by
# GAAI_QA_RETRY_MAX at the dispatcher level — this section only delivers context.
if [[ -n "${GAAI_QA_REPORT_PATH:-}" && -f "$GAAI_QA_REPORT_PATH" && -s "$GAAI_QA_REPORT_PATH" && "${GAAI_QA_INJECT_PHASE:-impl}" == "impl" ]]; then
  if [[ "$SECONDARY_ROUTE" == "true" ]]; then
    cat <<QA_FINDINGS_REF
=== PRIOR QA FINDINGS — RETRY-LOOP RE-SPAWN ===

This is a re-spawn of the IMPL phase. A previous QA pass produced verdict
FAIL with concrete findings recorded at :

  ${GAAI_QA_REPORT_PATH}

Your task is to ADDRESS those findings (NOT re-implement the story from
scratch). Read the qa-report first, then read the prior impl-report and
plan, locate the defective sites, apply the minimal correction, and update
the impl-report with a "Cycle N corrections" section listing what changed.

Do NOT broaden scope. Do NOT make architectural decisions. The qa-report
identifies specific defects — fix those, run the tests called out in the
acceptance criteria, and exit.

=== END PRIOR QA FINDINGS ===

QA_FINDINGS_REF
  else
    echo "=== PRIOR QA FINDINGS (verdict: FAIL — address these) ==="
    cat "$GAAI_QA_REPORT_PATH"
    echo ""
    echo "(Above qa-report is from a previous QA pass on this story. Your task is to address the specific findings, NOT re-implement from scratch. Read the impl-report + plan + story to triangulate. Apply minimal corrections and update the impl-report with a 'Cycle N corrections' section.)"
    echo ""
  fi
fi

# ── Section 5: DEC reads instruction ─────────────────────────────────────
# Parse related_decs from story YAML frontmatter (--- block).
# Format in frontmatter: related_decs: [DEC-NN, DEC-MM, ...]
# or:
# related_decs:
#   - DEC-NN
#   - DEC-MM
_related_decs=""
_in_frontmatter=0
_frontmatter_done=0
_yaml_block_line=0
_in_related=0
while IFS= read -r _line; do
  _yaml_block_line=$(( _yaml_block_line + 1 ))
  if [[ $_yaml_block_line -eq 1 && "$_line" == "---" ]]; then
    _in_frontmatter=1
    continue
  fi
  if [[ $_in_frontmatter -eq 1 && "$_line" == "---" ]]; then
    _frontmatter_done=1
    break
  fi
  if [[ $_in_frontmatter -eq 1 ]]; then
    # Inline list form: related_decs: [DEC-NN, DEC-MM, ...]
    if echo "$_line" | grep -qE '^related_decs:[[:space:]]*\['; then
      _related_decs=$(echo "$_line" | sed 's/related_decs:[[:space:]]*//' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep -v '^$' || true)
    # Multiline list form: - DEC-XX (after related_decs: line)
    elif echo "$_line" | grep -qE '^related_decs:[[:space:]]*$'; then
      _in_related=1
    elif [[ "${_in_related:-0}" -eq 1 ]]; then
      if echo "$_line" | grep -qE '^[[:space:]]*-[[:space:]]+(DEC-[0-9]+)'; then
        _dec=$(echo "$_line" | sed 's/.*-[[:space:]]*//')
        _related_decs="${_related_decs}${_dec}"$'\n'
      elif echo "$_line" | grep -qE '^[^[:space:]]'; then
        _in_related=0
      fi
    fi
  fi
done < "$GAAI_STORY_PATH"

# ── Skill path resolution preamble ───────────────────────────────────────
# Agents (especially Haiku sub-agents spawned via the Task tool) sometimes
# guess skill file paths from the skill NAME alone and hit File-not-found
# loops on `.gaai/core/skills/<name>.skill.md` — but the actual layout is
# `.gaai/core/skills/<track>/<name>/SKILL.md`. Tell every impl agent to
# resolve via the index file FIRST, not by guessing.
cat <<SKILL_PATHS
=== SKILL FILE PATH RESOLUTION ===

Skill files live at exactly :
  ${GAAI_WORKSPACE_PATH}/.gaai/core/skills/<track>/<skill-name>/SKILL.md

There is ALWAYS a <track> subdirectory (cross / delivery / discovery /
domain). NEVER read at \`.gaai/core/skills/<name>.skill.md\` — that path
does not exist.

If you need to resolve a skill name to its file path, Read this index
first :
  ${GAAI_WORKSPACE_PATH}/.gaai/core/skills/skills-index.yaml

It maps every skill name to its canonical \`path:\` field. Do NOT guess
paths from the skill name alone.

=== END SKILL FILE PATH RESOLUTION ===

SKILL_PATHS

if [[ -n "$_related_decs" ]]; then
  echo "=== MANDATORY DEC READS ==="
  echo "Before implementing, read each of the following decision files to understand the constraints:"
  echo ""
  while IFS= read -r _dec_id; do
    [[ -z "$_dec_id" ]] && continue
    echo "  Read ${PROJECT_DIR}/.gaai/project/contexts/memory/decisions/${_dec_id}.md"
  done <<< "$_related_decs"
  echo ""
  echo "These DECs contain binding constraints for this story. Non-compliance = implementation failure."
  echo ""
fi

# ── Mandatory handoff artefact (impl-report.md) ──────────────────────────
# The implementation phase MUST end with a written impl-report.md artefact
# at the path below. Without it, the daemon classifies the phase as
# NO_ARTEFACT_PRODUCED and triggers a retry / cascade — even if the agent
# has already committed all the code. Empirically observed once (agent
# completed ACs and committed work but skipped the report file because the
# instruction was absent from the impl prompt).
#
# The path is derived from the daemon's impl_report_path argument and is
# always under ${GAAI_WORKSPACE_PATH}/.gaai/project/contexts/artefacts/
# impl-reports/${GAAI_STORY_ID}.impl-report.md.
_impl_report_path="${GAAI_WORKSPACE_PATH}/.gaai/project/contexts/artefacts/impl-reports/${GAAI_STORY_ID}.impl-report.md"
cat <<HANDOFF
=== MANDATORY HANDOFF — impl-report.md ===

After all acceptance criteria are implemented, tested, and committed, you
MUST write the implementation report artefact to exactly this path :

  ${_impl_report_path}

The report MUST contain :
  - YAML frontmatter with artefact_type: impl-report, id: ${GAAI_STORY_ID},
    skills_invoked, related_decs (mirroring the story).
  - "## Summary" — 1-3 sentences on what was delivered.
  - "## Acceptance Criteria" — per-AC delivery summary (file, key change,
    verification step). One sub-section per AC.
  - "## Files Changed" — bullet list of paths with one-line rationale.
  - "## Tests" — counts (passed / failed / skipped) and the command(s) used.
  - "## Commits" — list of git commit SHAs + subjects authored during
    this implementation.
  - "## Open Concerns / Follow-ups" — items intentionally deferred or
    flagged for QA attention. Empty section is fine if none.

This is the ONLY signal the daemon uses to advance phase_status to
'implemented'. Skipping it = phase failure regardless of how much code
you committed. Use the Write tool with the path above as file_path.

Reminder (one-shot mode): run your final test suite in the FOREGROUND and
write this report BEFORE ending your turn. A turn that ends "waiting for a
background test run to finish" exits the process and discards this attempt.

=== END HANDOFF ===

HANDOFF

# ── Section 6: Worktree scope (universal soft gate) ──────────────────────
cat <<WORKTREE_SCOPE
=== WORKTREE SCOPE ===

All Write/Edit operations and Bash commands with side effects (file writes,
deletions, network calls beyond Anthropic API + standard package registries)
MUST stay within ${GAAI_WORKSPACE_PATH}. Reads outside the worktree are
allowed for repo and framework context. The daemon audits the per-phase log
post-completion and writes any out-of-worktree paths to <log>.audit.json
(advisory).

=== END WORKTREE SCOPE ===

WORKTREE_SCOPE

