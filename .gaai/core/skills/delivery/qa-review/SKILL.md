---
name: qa-review
description: Validate that implemented code fully satisfies Story acceptance criteria, respects rules, and introduces no regressions. This is the hard quality gate — no pass means no delivery. Activate after implementation is complete.
license: ELv2
compatibility: Works with any filesystem-based AI coding agent
metadata:
  author: gaai-framework
  version: "1.0"
  category: delivery
  track: delivery
  id: SKILL-QA-REVIEW-001
  updated_at: 2026-04-15
  status: stable
inputs:
  - contexts/artefacts/stories/**
  - contexts/artefacts/plans/**
  - codebase  (working tree)
  - contexts/rules/**
  - contexts/memory/**  (optional — past bugs, regressions, risks)
  - pre-QA admission evidence  (optional — the daemon's verified account of the deterministic local admission on this candidate)
outputs:
  - qa_report  (PASS | FAIL)
---

# QA Review

## Purpose / When to Activate

Activate after implementation is complete. This is a **hard quality gate**.

**No pass → no delivery.**

---

## Process

### 1. Story Compliance Check
- Parse Story YAML frontmatter
- Extract acceptance criteria
- Validate each criterion is demonstrably satisfied in code
- **Required Skills AC verification**: if the story frontmatter contains `required_skills`,
  for each entry X, identify its co-declared bound output AC. Verify that the bound output
  AC is satisfied by inspecting the actual output or changed artefacts (file contents,
  generated output, behaviour). Do NOT verify by checking invocation traces or logs — the
  test is output-based only. If the bound output AC cannot be evaluated from output alone
  (ambiguous) → FAIL with escalation note. If the bound output AC is unmet → FAIL
  immediately with: `FAIL: bound output AC for required_skills entry "${X}" is not
  satisfied — [AC text] not met in output. Inspect [relevant file/output].`
- Any criterion unclear or unmet → FAIL immediately

### 2. Scope Integrity Check
- Only files within Story scope were modified
- No feature creep introduced
- No unrelated refactors included
- Unexpected changes → FAIL, recorded as a `findings[]` entry (`classification: blocking`,
  `root_cause: plan | implementation`) that fails `plan_conformance` on its own. This is a
  different mechanism from the `changed_surface_inventory` `blocking` classification used in
  Step 7 — do NOT mark the affected surface `blocking` in the inventory or attach an
  `evidence[]` entry for a pure scope/plan violation; there is no primary authority to cite for
  it, and doing so produces an unsatisfiable handoff rejection (see `qa.daemon-prompt.md`
  Two-Axis Review step 1 for the worked example).

### 3. Rule Enforcement
- Confirm compliance with each applicable rule
- Surface violations explicitly
- Any broken rule → FAIL

### 4. Regression Scan

**Scope first — consume the pre-QA admission instead of repeating it.** When the delivery runtime
hands you a verified account of the deterministic local admission that passed on this exact
candidate (in the daemon: `$GAAI_QA_ADMISSION_EVIDENCE_PATH`) and it reports `consumable: true`,
the commands it lists are proven regression evidence for this candidate. Cite them; do not re-run
them, do not run any other command the admission policy declares (its selector policy is the
regression authority for what the diff affects), and do not run a broader sweep. Limit your own
execution to the Story's own suites — the test files the diff adds or changes and those the Story
or PLAN names as its verification. When a command you would run is identical to a policy command:
a selected, passed one is cited and never re-run, whoever names it; an unselected one is not run as
a whole — run the Story's own test files within it by a targeted invocation, and record a finding
if you judge the whole lane necessary; a Step 5 command not already proven always runs. The
account's `declared_commands` is the policy's full command set; an entry not among the proven
`commands` is an unselected one. When the account is absent, unreadable or `consumable: false`,
perform the full scan below and state why. The admission never decides a verdict on its own; Steps 1-3 and 5-8 apply
unchanged.
- **Broken tests → FAIL — but only a *new* breakage is a regression.** A regression is a test that fails on this change yet passed on the pre-change baseline. Before failing on a red test, establish whether it is pre-existing: re-run it on the base branch / the story's fork-point, or consult known-failing context. A test already red on the baseline and unrelated to this story's changed surface is **not** a regression — record it as pre-existing and do **not** FAIL/ESCALATE on it. A failure this story caused, or in a test that exercises the surface this story changed, **is** a regression → FAIL. Do not weaken this by labelling a genuinely new failure "pre-existing" — verify, don't assume.
- Behavior drift → FAIL
- Known risk patterns from memory → FAIL
- **Long-running commands:** start them with output redirected to a file and wait with one
  blocking wait per call sized just under the executor's per-call time ceiling (about nine minutes
  where that ceiling is ten); if the executor cuts a wait short, size the next one to fit. Never
  poll with repeated short sleeps — each costs a turn and can exhaust the phase's budget before a
  verdict is written.
- **Large command output:** redirect test-runner output to a file (e.g. `/tmp/test-output.txt`)
  and inspect via `grep`/`tail`/`rg`. **NEVER use the Read tool on a file expected to exceed
  ~256KB** — it has a hard 256KB ceiling that burns a turn and returns no content. On an
  accidental oversized Read, switch immediately to `grep -E "FAIL|✕|Error" <file>` to extract
  failures rather than retrying the Read.

### 5. Build / Type / Lint Integrity

Test runners that transpile (vitest, jest, ts-jest, swc, esbuild, babel) execute code WITHOUT type checking — a green test suite does not prove the code compiles. Static-type or linter errors in test files, fixtures, and adjacent modules will pass tests locally and only surface at deploy time.

Pre-QA admission evidence does not replace this step. Only a command identical to a selected,
passed admission command counts as already run; every other static-analysis command below runs.

Identify and run the project's full static-analysis gate for every workspace package whose files were modified (directly or via type/dep propagation):
- TypeScript: `tsc --noEmit` (or `pnpm typecheck` / equivalent script)
- For Cloudflare Workers projects: regenerate runtime types first (`wrangler types`) — drift between `worker-configuration.d.ts` and `wrangler.jsonc` masks real errors
- Lint (if the project enforces it as a gate): `eslint`, `ruff`, `clippy`, etc.
- Other ecosystems: `cargo check`, `mypy`, `go vet`, etc.

If the project documents the exact command in `contexts/memory/patterns/conventions.md` or a delivery rules file, use that command verbatim — do not improvise.

Any error → FAIL. "Test files only" is not a mitigation: test files are part of the typecheck graph and break the deploy gate.

**Large output:** redirect `tsc --noEmit` / lint output to a file and inspect via `grep`/`tail`.
Do NOT Read files expected to exceed ~256KB — the Read-tool hard ceiling is 256KB; a failed
Read burns a turn with no content returned. To summarize a large output file: `grep -E "error
TS|Error|warning" /tmp/tsc-output.txt | tail -100`.

### 6. Quality Checks
- Error-prone operations lack error handling → FAIL
- External input enters functions without validation → FAIL
- Identifiers are ambiguous or non-descriptive → FAIL
- A function or module handles more than one responsibility without decomposition → FAIL
- Dead code or unreachable branches present → FAIL
- Tests were disabled or skipped to make the suite pass → FAIL

### 7. Currentness & Evidence Review (DEC-200)

Independent of Steps 1-6, evaluate and record `state_of_the_art_conformance` — do this
BEFORE finalizing `plan_conformance`, to avoid anchoring on "tests passed" (DEC-200 D1).
This step's `changed_surface_inventory` `blocking` classification (and its `evidence[]`
obligation) is scoped to currentness/materiality only — a Step 2 scope violation never
belongs here, see Step 2's note above.

- **Materiality floor.** A functionally correct implementation that passes every business
  test is still `FAIL` on this axis when any changed surface is `blocking`: a named primary
  authority identifies it as `deprecated | unsupported | materially_obsolete | unsafe |
  officially_discouraged | demonstrably_fragile`. A newer-but-still-supported alternative,
  stylistic preference, unofficial blog opinion or reviewer taste is `non_blocking` and does
  NOT breach the floor. `materially_obsolete` applies only when primary authority identifies
  the current replacement/migration and continued use materially impairs security,
  reliability, interoperability or supported maintenance — even if not formally deprecated
  yet. Business tests never override this floor.
- **Evidence discipline.** Primary authority only: an official standard/regulator
  publication, official vendor/runtime/framework documentation or advisory, official
  maintainer release/security notes, or a governed authority record pointing to such
  material. Live retrieval is preferred; a governed record is the fallback. Live locators
  must be absolute HTTPS with no user-info and no secret-shaped query parameter; governed
  locators must be safe repo-relative (no leading `/`, no `..`). A governed record's
  `authority_domain` (`security | fast_moving | stable | unknown`) is pre-authored by the
  record — never chosen at review time to make the evidence pass. `security`/`fast_moving`
  records are fresh for 30 days, `stable` for 90 days, measured to the review timestamp; a
  `security` or `unsafe`-materiality claim requires an `authority_domain: security` record.
  A missing or literal `unknown` domain defaults to `fast_moving` and the validator emits
  `authority_domain_defaulted` for that surface — an observable, valid fallback, not a defect.
- **Fail-closed on missing capability.** No live retrieval AND no fresh governed record for
  a surface → that axis is `ESCALATE` for this review, never an inferred `PASS`. This holds
  identically for every supported executor (DEC-190 D6) — divergence between executors is
  acceptable only when one lacks retrieval capability the other has.
- **Not-applicable is narrow.** `not_applicable` is valid only for a surface mechanically
  identified as a test fixture, generated metadata or preserved historical record with a
  concrete, stated reason that it has no runtime, dependency, operational, interoperability,
  reliability or security effect. If you cannot make that case concretely, classify and
  evidence the surface normally — do not use N/A as an escape hatch.
- **Root cause.** Every blocking finding carries `root_cause: plan | implementation`. An
  inability to reach a conclusion is `ESCALATE`, not a guess.

This step's structured output (inventory, findings, evidence, both axis verdicts, the
machine-derivable aggregate/route) is written to the JSON sidecar per
`qa.daemon-prompt.md` — this skill step defines the review discipline; the daemon prompt
defines the file/env-var contract.

### 8. Memory Alignment (PASS only)

On PASS verdict, the skill MUST invoke `memory-alignment-check` (SKILL-MEMORY-ALIGNMENT-CHECK-001) before returning. QA MUST NOT improvise the delta — `memory-alignment-check` owns it.

The delta MUST match this exact skeleton (authoritative source: `memory-alignment-check/SKILL.md` Outputs). Do NOT invent alternative section headers (e.g. `## Summary`, `## New facts delivered by this story`, `## Implementation Footprint`, `## No memory updates required`) and do NOT change the frontmatter field names — any deviation FAILs the `validate-memory-deltas` CI gate:

```
---
artefact_type: memory-delta
skill: memory-alignment-check
story_id: {id}
generated_at: YYYY-MM-DD
verdict: ALIGNED | DRIFT_DETECTED | NEW_KNOWLEDGE_FOUND | DRIFT_AND_NEW_KNOWLEDGE
---

## Confirmed Entries
# (list, or leave the section present with no items)

## Contradicted Entries
# (list, or leave the section present with no items)

## New Knowledge Candidates
# (list, or leave the section present with no items)
```

A "nothing changed" delta is still expressed in this schema (`verdict: ALIGNED`, the three sections present with no items) — NOT as free prose. The full field-level schema lives in `memory-alignment-check/SKILL.md` Outputs. The delta is written exclusively to `contexts/artefacts/memory-deltas/{id}.memory-delta.md` (canonical path — never under `contexts/memory/`).

---

## Outputs

**If PASS:**
```
status: PASS
validated_stories:
  - E01S01
notes:
  - All acceptance criteria satisfied
  - No rule violations
  - No regressions detected
```

**If FAIL:**
```
status: FAIL
blocking_issues:
  - Story E01S01: acceptance criterion #2 not satisfied
  - Rule code-style violated in services/api/user.ts
  - Unexpected file modified: services/payments/
recommended_actions:
  - Fix acceptance behavior
  - Revert out-of-scope change
  - Apply code rule formatting
```

---

## Hard Rules

This skill must NEVER:
- Modify code
- Reinterpret Stories
- Negotiate acceptance criteria
- Approve partial conformance
- MUST NOT write or modify `contexts/artefacts/memory-deltas/{id}.memory-delta.md` directly. The delta is written exclusively by `memory-alignment-check` (invoked at Step 8). Free-form delta variants are a governance violation.

**If it's not explicitly validated → it's broken. If it's broken → it doesn't ship.**
