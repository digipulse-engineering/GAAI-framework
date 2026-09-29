---
type: workflow
id: WORKFLOW-DELIVERY-LOOP-001
track: delivery
updated_at: 2026-05-01
---

# Delivery Loop Workflow

> **Branch model:** The delivery workflow targets the `staging` branch. AI never interacts with `production`. Promotion staging → production is a human action via GitHub PR.

Each Story is delivered by the daemon spawning three independent `claude -p` processes (Plan → Impl → QA), followed by deterministic bash commit operations. There is no orchestrator agent — the daemon bash state machine is the sole coordinator.

---

## Overview

The daemon (`delivery-daemon.sh`) directly spawns three standalone `claude -p` processes per story. Each phase agent spawns, executes autonomously, writes its artefact to a known path, then dies. The daemon reads the artefact and advances `phase_status`.

```
Daemon (bash)
  ├─ Phase 1 Plan  → claude -p (planning.daemon-prompt.md)  → execution-plan.md  → phase_status: planned
  ├─ Phase 2 Impl  → nested-claude-spawn.js runImpl()        → impl-report.md     → phase_status: implemented
  ├─ Local pre-QA  → seal + reconcile + project checks        → pre_qa receipt      → QA spend admitted
  ├─ Phase 3 QA    → claude -p (qa.daemon-prompt.md)           → qa-report.md        → phase_status: qa_passed
  ├─ Local final   → commit + reconcile + project checks       → final receipt       → publication admitted
  └─ Publish/hold  → exact-SHA PR + pending_review             → external merge      → watcher projects done
```

Each phase has an isolated context window: cumulative-context risk is bounded per phase, not accumulated across the full story lifecycle.

For daemon state machine internals, see `daemon-dispatch.sh`.

---

## Local admission versus merge authority

The target project owns a base-held, closed-world local-admission policy. After implementation the
daemon creates a local seal commit, reconciles the current base and requires a current `pre_qa` PASS
before selecting or spawning semantic QA. After QA evidence and the final delivery commit, it
reconciles and executes the policy again; only that distinct `final` PASS may publish its explicitly
admitted SHA. A failed push is first observed as possibly accepted, while every real retry re-fetches,
reconciles and re-runs final admission. Missing, stale, skipped, timed-out or failed evidence blocks
the downstream model or remote call and routes to implementation or human attention.

Local receipts authorize only the named spend/publication boundary. They never emit QA authority,
authorize acceptance or replace the hosted exact-candidate gate. Hosted CI qualifies or remediates
the exact PR/head/base/run tuple; it never selects merge policy or authorizes merge. Terminal state
belongs only to watcher verification of an externally authorized exact-current merge.

---

## Phase 1 Plan

### Input contract

Env vars set by `handle_plan_phase()` in `daemon-dispatch.sh`:

| Variable | Purpose |
|---|---|
| `$GAAI_STORY_ID` | Story identifier |
| `$GAAI_WORKTREE_PATH` | Absolute worktree root |
| `$GAAI_STORY_PATH` | Path to `{id}.story.md` |
| `$GAAI_PLAN_PATH` | Output path for `execution-plan.md` |
| `$GAAI_EPIC_PATH` | Path to `{epic}.epic.md` |
| `$GAAI_DELIVERY_LOG_FILE` | Per-story log path |
| `$GAAI_WORKSPACE_ID` | Workspace UUID |
| `$GAAI_ORG_ID` | Org UUID |

### Model routing

Before spawning, `handle_plan_phase()` asks the router for the `PLAN_PRODUCER` role
(`.gaai/core/scripts/lib/delivery-routing.sh` → `delivery-router.mjs`). The selected model, its
harness and its reasoning-effort expression are carried into the spawn; the model that produced
the plan is then recorded as a `PLAN` contributor, which bars it from later steps that evaluate
the plan. `GAAI_PLAN_MODEL` remains an operator pin and wins outright. PLAN_PRODUCER evaluates
nothing, so a blocked route degrades to the legacy default rather than stalling.
See [Delivery model routing](../docs/delivery-model-routing.md).

### Prompt source

Daemon reads `.gaai/core/agents/sub-agents/planning.daemon-prompt.md` and passes it as the `claude -p` system prompt. Story file content at `$GAAI_STORY_PATH` is included in the prompt body.

### Output contract

- Writes: `$GAAI_PLAN_PATH` (`.gaai/project/contexts/artefacts/plans/{id}.execution-plan.md`)
- Phase transition: `phase_status: not_started → planned` (via `backlog-scheduler.sh --set-phase-status`)
- Daemon verifies file exists before advancing `phase_status`.

### Audit emit

`_emit_plan_routing_record` writes one record to `runtime-routing.jsonl`:

```
trace_id, story_id, phase=plan, provider=primary,
model=$CLAUDE_MODEL_PRIMARY, duration_ms, fallback_reason, impl_model_tag, pipeline=3phase
```

---

## Phase 2 Impl

### Input contract

Env vars consumed by `daemon-prompt-construct.sh` + `nested-claude-spawn.js`:

| Variable | Purpose |
|---|---|
| `$GAAI_STORY_ID` | Story identifier |
| `$GAAI_STORY_PATH` | Path to `{id}.story.md` |
| `$GAAI_PLAN_PATH` | Path to `{id}.execution-plan.md` |
| `$GAAI_EPIC_PATH` | Path to `{epic}.epic.md` |
| `$GAAI_WORKSPACE_PATH` | Worktree root (alias for `$GAAI_WORKTREE_PATH` in impl context) |
| `$GAAI_WORKTREE_PATH` | Absolute worktree root |
| `$GAAI_WORKSPACE_ID` | Workspace UUID |
| `$GAAI_ORG_ID` | Org UUID |
| `$SECONDARY_ROUTE` | `"true"|"false"` (routing decision set by `daemon-dispatch.sh`) |
| `$PROJECT_DIR` | Repository root |

### Prompt construction

<!-- BEGIN R1-R6-CANONICAL-REF -->
The R1-R6 context discipline preamble and NOTES.md bootstrap template live in
`daemon-prompt-construct.sh`. This helper is the single source of truth for impl prompt
construction, used by the 3-phase daemon path.

**Edits to R1-R6 or the NOTES.md template MUST be made in `daemon-prompt-construct.sh`,
NOT here.** Any copy of R1-R6 text in this workflow file is a drift hazard.

To understand the full impl prompt: read `.gaai/core/scripts/daemon-prompt-construct.sh`.
<!-- END R1-R6-CANONICAL-REF -->

### Routing

Impl phase invokes `nested-claude-spawn.js runImpl()` via CLI. Routing is resolved by `resolveMode()` (deterministic pure function inside the module). Modes: `primary` (explicit tag or absent-with-no-env) or `secondary` (explicit tag or absent-with-env-configured). `SECONDARY_ROUTE=true` causes `daemon-prompt-construct.sh` to prepend the R1-R6 context discipline preamble.

For routing matrix, see `contexts/memory/architecture/impl-phase-spawn-pattern.md`.

### Mandatory CLI pattern

```bash
result_json=$(node .gaai/core/adapters/claude-code/nested-claude-spawn.js \
  --prompt-file "$IMPL_PROMPT_FILE" \
  --report-path "$IMPL_REPORT_PATH" \
  --story-id "$GAAI_STORY_ID" \
  [--impl-model-tag primary|secondary|absent])
```

`--log-file` is NOT passed; the module reads `$GAAI_DELIVERY_LOG_FILE` from env.

### Model routing

`handle_impl_phase()` asks the router for the `IMPL` role and passes the pick down as
`GAAI_IMPL_PRIMARY_MODEL` (claude harness) or `GAAI_CODEX_MODEL` (codex harness). The
secondary-provider route is an explicit per-story opt-in with its own governed env contract and
is left alone. On success the implementer is recorded as a `CODE` contributor — by registry alias,
or by concrete model under an `external:` alias when it is off-registry — which bars it from every
QA lane that evaluates the implementation.

### Output contract

- Writes: `$IMPL_REPORT_PATH` (`.gaai/project/contexts/artefacts/impl-reports/{id}.impl-report.md`)
- Phase transition: `phase_status: planned → implemented`
- `nested-claude-spawn.js` always exits 0; outcome determined by `result.success` in returned JSON.

### Audit emit

`nested-claude-spawn.js _emitLog()` writes one (or two on fallback) records to `runtime-routing.jsonl`:

```
trace_id, story_id, phase=impl, provider=primary|secondary,
model=$CLAUDE_MODEL_*, duration_ms, fallback_reason, pipeline=3phase
```

After the call, `STORY_TRACE_ID` is overwritten with `result.trace_id` unconditionally.

---

## Phase 3 QA

### Input contract

Env vars set by `handle_qa_phase()` in `daemon-dispatch.sh`:

| Variable | Purpose |
|---|---|
| `$GAAI_STORY_ID` | Story identifier |
| `$GAAI_WORKTREE_PATH` | Absolute worktree root |
| `$GAAI_STORY_PATH` | Path to `{id}.story.md` |
| `$GAAI_PLAN_PATH` | Path to `{id}.execution-plan.md` |
| `$GAAI_IMPL_REPORT_PATH` | Path to `{id}.impl-report.md` |
| `$GAAI_QA_REPORT_PATH` | Output path for `qa-report.md` |
| `$GAAI_QA_SCHEMA_PATH` | Path to `.gaai/core/schemas/qa-verdict.v1.schema.json` (DEC-200) |
| `$GAAI_QA_VERDICT_PATH` | Output path for the JSON sidecar `{id}.qa-verdict.json` (DEC-200) |
| `$GAAI_QA_EXPECTED_SURFACES_PATH` | Path to a daemon-materialized JSON array — the exact surface set the JSON sidecar's `changed_surface_inventory` must equal one-to-one (DEC-200) |
| `$GAAI_QA_ADMISSION_EVIDENCE_PATH` | Path to the daemon's verified account of the pre-QA local admission on this exact candidate (`consumable`, `reason`, proven commands) — outside the worktree, evidence only, never authority |
| `$GAAI_EPIC_PATH` | Path to `{epic}.epic.md` |
| `$GAAI_BASE_REF` | Git ref for diff comparison |
| `$GAAI_DELIVERY_LOG_FILE` | Per-story log path |
| `$GAAI_MEMORY_DELTA_PATH` | Output path for memory-delta (optional) |
| `$GAAI_WORKSPACE_ID` | Workspace UUID |
| `$GAAI_ORG_ID` | Org UUID |

### Prompt source

Daemon reads `.gaai/core/agents/sub-agents/qa.daemon-prompt.md` and passes it as the `claude -p` system prompt. Story, execution-plan, and impl-report are included in the prompt body. The prompt requires the QA agent to evaluate and record `state_of_the_art_conformance` before `plan_conformance` (DEC-200 D1).

### Verdict format

QA agent writes `phase_status:` as the first YAML frontmatter field in `$GAAI_QA_REPORT_PATH`. Daemon reads this field to determine disposition:

- `qa_passed` → advance to commit phase
- `qa_failed` → retry impl (up to `MAX_RETRIES=3` total cycles); if exhausted → `failed`
- `qa_escalated` → mark `escalated`, surface to human

### Two-axis JSON handoff (authoritative for routing)

Per **DEC-200**, the QA agent writes a JSON sidecar to `$GAAI_QA_VERDICT_PATH`
(`{id}.qa-verdict.json`) conforming to `$GAAI_QA_SCHEMA_PATH`, carrying two independent axes
(`plan_conformance`, `state_of_the_art_conformance`), a changed-surface inventory, structured
findings/evidence, a machine-derived aggregate `verdict`, and `remediation_route` /
`replan_required`. `daemon-dispatch.sh:_qa_verdict_resolve()` is the **one shared resolver** —
both `handle_qa_phase()` (live, post-spawn) and `delivery-daemon.sh:_resolve_cross_cycle_qa_report()`
(cross-cycle, pre-spawn relaunch) call it; it shells out to
`.gaai/core/scripts/lib/qa-verdict.mjs validate`, which independently re-derives the aggregate and
route from the axes/findings and rejects the handoff if the sidecar's own `verdict` /
`remediation_route` / `replan_required` disagree with that derivation — a model-supplied aggregate
or route is never consumed as-is.

**The JSON aggregate — not the Markdown `## Verdict:` line — drives `phase_status` routing.**
Markdown is still parsed for the "qa-report missing" presence check and for a disagreement guard
(a JSON `verdict` that disagrees with the parsed Markdown line is fail-closed exactly as before);
it can therefore still *invalidate* a cycle, but it no longer *selects* the routing branch. This
closes the gap left open in E1096S01, which was validation-only.

**Currentness gate (DEC-200 D7 / AC2).** Every dispatch of a story at `phase_status: qa_passed` or
`qa_failed` (live and every cross-cycle relaunch — this is the one choke point neither executor
choice nor restart timing can bypass) checks whether the current worktree's `.qa-verdict.json`
sidecar exists. If it does not — a legacy/in-flight story from before the two-axis contract shipped,
or any other non-terminal state missing the sidecar — the daemon resets `phase_status` to
`implemented` and emits `QA_CURRENTNESS_RERUN`, so QA reruns under the current contract *this same
cycle*. Historical, completed (terminal) one-verdict reports are never reinterpreted or retro-fitted
with a synthesized PASS — the gate only ever touches non-terminal stories still in flight.

### Model routing

The single QA agent covers all three lanes at once — implementation, Story acceptance criteria,
and conformity to the governed PLAN — so its independence requirement is the union of the three
lanes' exclusions, which is exactly the `QA_PLAN` role. This step evaluates, so it fails closed:
a `PROVENANCE`, `CAPABILITY_FLOOR` or `CONFIG` block is structural and marks the story failed for
a human, while an `AVAILABILITY` block leaves the phase alone so the next cycle retries after the
harness backoff expires. No branch exists that lets a plan or code contributor grade its own work.

### Output contract

- Writes: `$GAAI_QA_REPORT_PATH` (`.gaai/project/contexts/artefacts/qa-reports/{id}.qa-report.md`)
- Writes: `$GAAI_QA_VERDICT_PATH` (`.gaai/project/contexts/artefacts/qa-reports/{id}.qa-verdict.json`)
- Optional: `$GAAI_MEMORY_DELTA_PATH` if QA agent identifies memory-worthy decisions
- Phase transition: `phase_status: implemented → qa_passed | qa_failed | qa_escalated`

### Audit emit

`_emit_qa_routing_record` writes one record to `runtime-routing.jsonl`:

```
trace_id, story_id, phase=qa, provider=primary,
model=$CLAUDE_MODEL_PRIMARY, duration_ms, fallback_reason, impl_model_tag, pipeline=3phase
```

On successful JSON handoff validation, the daemon additionally logs a one-line summary
(story ID, schema version, both axes, aggregate, remediation route, `evaluated_as_of`,
surface/evidence counts, safe sidecar/report locators — no report bodies, credentials or
authority-URL query values) to the phase log/stdout for observability (AC5). This same summary
is also passed to `_emit_qa_routing_record` as `--qa-summary` on every PASS/FAIL/ESCALATE call
site and is part of the `runtime-routing.jsonl` schema as the `qa_summary` field (allowlisted in
`runtime-routing-logger.js`'s `TELEMETRY_FIELDS`) — so the routing record itself, not only the
phase log, carries the two-axis summary for every terminal QA outcome.

---

## Commit Phase

Deterministic bash only — no `claude -p` invocation. Implemented in `handle_commit_phase()` in `daemon-dispatch.sh`.

**Sequence:**

1. Git add + commit delivery artefacts to the story branch.
2. Push the exact locally admitted SHA with the existing retry/reconcile pattern; every changed head
   requires fresh final admission.
3. Create or reuse the PR against the configured target and verify its current head equals that exact
   admitted SHA.
4. Immediately persist `status: in_progress`, `phase_status: qa_passed`,
   `pr_status: pending_review` before any hosted observation.
5. Observe the authoritative greatest-current hosted run/attempt. Queued/running waits; completed
   success qualifies; completed failure alone enters bounded remediation; every other or unavailable
   result is typed BLOCKED without mutation, rerun, republish or push.
6. Hold. The daemon does not enable auto-merge, invoke a provider merge mutation, use admin fallback
   or turn hosted PASS into merge permission.
7. After an external merge action, the configured-target watcher verifies that the exact current
   admitted head landed and projects `done / done / merged` plus `completed_at`.
8. Only after that projection, remove the worktree and local branch through the
   landed-or-preserved guard.

**Normative authority:** the worktree + PR + cleanup invariants are defined in `orchestration.rules.md §Branch Rules → Worktree lifecycle & cleanup`. This sequence is the procedure; the rules file is the authority. The procedure restates only hard safety boundaries (see **Safety boundary** below); it does not define invariants.

**Base-source invariant:** Story and repair branches must be created from `origin/staging` after a fresh fetch, or from a local `staging` ref that has just been verified byte-equal to `origin/staging`. Do not commit or push Delivery code/content directly on `staging`; use a worktree branch, open a PR to `staging`, then squash-merge it.

**Cleanup backstop:** step 8 is the happy-path removal. If it does not run (crash, dirty tree), the
periodic orphan reaper is the eventually-consistent backstop, but it requires the same exact terminal
projection and preserves on unavailable or ambiguous evidence.

**Data-safety refusal:** a dirty or still-active worktree is never force-removed at step 8 or by the reaper — the reaper refuses removal and defers it (skip-and-retry next cycle) rather than risking data loss (see `orchestration.rules.md §Branch Rules`).

**Safety boundary:** Delivery never invokes a provider merge mutation. `production` remains
human-only, and an external merge to the configured Delivery target is not terminal until the
watcher verifies the exact current head.

**Diff-sanity check:** Spawn sub-agent reviewer when `NON_GAAI_DELETIONS > 0` OR `CHANGED_COUNT > 30`. Reviewer verdicts PROCEED or ESCALATE (base.rules.md Rule 5). Reviewer runs in an isolated context window — it receives only Story ACs and the file list, not the daemon's self-assessment.

**Audit emit:** `_emit_commit_routing_record` writes to `runtime-routing.jsonl`:
`trace_id, story_id, phase=commit, pr_url, publication_held, pipeline=3phase`.

---

## Error Semantics

### Phase-level retry policy

`MAX_RETRIES=3` applies per phase cycle independently (defined as a constant in `daemon-dispatch.sh`; cross-reference there for current value).

**QA remediation routes (DEC-200 D5) are independent and bounded.** On a `FAIL` aggregate, the
resolver's `remediation_route` (`plan` or `impl`, precedence `human > plan > impl` when both root
causes exist) is persisted per-story to `${LOCK_DIR}/.qa-route-{id}` by `handle_qa_phase()`'s FAIL
branch, and consumed by `dispatch_3phase_story()`'s `qa_failed)` case, which drives one of two
disjoint, independently-countered reruns:

| Route | Counter file | Max (env var, default) | Rewind target | Exhaustion reason |
|---|---|---|---|---|
| PLAN (`remediation_route:"plan"`) | `${LOCK_DIR}/.qa-replans-{id}` | `GAAI_QA_REPLAN_MAX` (2) | `phase_status: not_started` (full fresh PLAN; `GAAI_QA_INJECT_PHASE=plan` exported so the PLAN prompt gets prior-cycle delta context) | `QA_REPLAN_EXHAUSTED` |
| IMPL (`remediation_route:"impl"`) | `${LOCK_DIR}/.qa-retries-{id}` | `GAAI_QA_RETRY_MAX` (3) | `phase_status: planned` (re-spawn impl only) | `QA_RETRY_EXHAUSTED` |

A replan never consumes or resets the IMPL retry counter, and an IMPL retry never touches the PLAN
counter — the two counters live in separate files and separate code branches. Either counter's
exhaustion escalates the story (`qa_escalated`) rather than silently falling through to the other
route. Any axis result of `ESCALATE` routes to the existing human escalation path directly (never
consumes either counter). Both counter files, plus `.qa-route-{id}`, are removed on terminal
completion (`done|failed|escalated`) alongside the pre-existing `.qa-retries-{id}` cleanup.

### Failure mode taxonomy

Canonical failure mode enums are defined in `daemon-dispatch.sh`. Refer to:

- **Plan phase:** `PLAN_PHASE_FAILED`, `NO_ARTEFACT`, `PARSE_ERROR`, `SCHEDULER_FAILURE`
- **Impl phase:** `PARSE_ERROR` (JSON parse on spawn output), `False|<error_reason>` from `nested-claude-spawn.js`
- **QA phase:** `QA_SPAWN_FAILED`, `QA_NO_ARTEFACT`, `QA_VERDICT_PARSE_ERROR`, `QA_HANDOFF_INVALID` (DEC-200 JSON sidecar missing/malformed/internally-inconsistent, or disagrees with the Markdown verdict — immediate `failed`, no retry), `QA_VERDICT:FAIL`, `QA_VERDICT:ESCALATE`, `QA_SCHEDULER_FAILURE`, `QA_CURRENTNESS_RERUN` (non-terminal `qa_passed`/`qa_failed` story missing the two-axis sidecar — rewinds to `implemented`, not a failure), `QA_REPLAN_EXHAUSTED` (PLAN route's `GAAI_QA_REPLAN_MAX` reruns exhausted — escalates), `QA_RETRY_EXHAUSTED` (IMPL route's `GAAI_QA_RETRY_MAX` reruns exhausted — escalates)
- **Commit phase:** `COMMIT_FAILED`, `PUSH_FAILED`, `PR_CREATE_FAILED`, `AUTO_MERGE_FAILED`, `GH_AUTH_MISSING`, `SCHEDULER_FAILURE`

All constants are defined in `daemon-dispatch.sh`.

### Terminal failure semantics

After `MAX_RETRIES` exhausted at any phase: story transitions to `phase_status: failed`, `status: failed` in backlog. Daemon main loop continues — other ready stories are unaffected. The `failed` state is terminal: no automatic retry. Human intervention required.

### Operator runbook

When a story enters `failed` state:

1. Read `.gaai/project/contexts/backlog/.delivery-logs/{id}.fail-debug.jsonl` (last `phase_status`, error code, stdout/stderr tail)
2. Identify the failure mode from the `fallback_reason` field
3. Fix the root cause (AC gap, dependency missing, etc.)
4. Re-trigger via `backlog-scheduler.sh --set-status {id} refined`

### DEC-200 D8 dual-axis QA observation runbook

Autonomous dual-axis QA (the two-axis handoff, currentness gate and PLAN/IMPL routing described
above) is under an explicit operator observation window, not unconditional trust from day one.

**Observation window:** at least 30 calendar days AND the first 20 completed dual-axis QA reviews,
whichever is longer.

**Stop triggers (either one halts automation immediately):**

1. Any unsupported false PASS or a security miss discovered downstream of a dual-axis PASS.
2. The **second** occurrence, within the window, of a human overturning an evidence-invalid
   state-of-the-art block (i.e. a case where dual-axis QA blocked on `state_of_the_art_conformance`
   evidence grounds and a human reviewer determined the block was wrong).

**On trigger:** the operator stops the daemon, defers every affected Story through the existing
claim/scheduler protocol (`orchestration.rules.md`) rather than force-progressing it, and routes
continuation to a human. Reports and evidence already produced are preserved as-is — never
weakened to advisory-only or silently accepted on a single-verdict basis. This is a manual operator
action; no daemon code auto-halts on these triggers.

**Durable human-reversal record:** every human overturn of a dual-axis QA outcome during the window
is recorded (per existing GAAI memory conventions — an operator/founder process artefact, not a new
code path or schema) with an opaque QA review ID and Story ID; the lifecycle field names `status`,
`phase_status`, `pr_status` and `completed_at`, never their values; a journal digest, projection digest
and governed-evidence digest; and exactly one closed reason:
`unsupported_false_pass`, `security_miss` or `second_evidence_invalid_overturn`. No additional fields,
report or evidence bodies, or secrets are included.
