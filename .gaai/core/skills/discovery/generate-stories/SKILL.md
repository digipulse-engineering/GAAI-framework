---
name: generate-stories
description: Translate a single Epic into clear, actionable User Stories with explicit acceptance criteria. Activate when an Epic is defined and work needs to be prepared for Delivery execution.
license: ELv2
compatibility: Works with any filesystem-based AI coding agent
metadata:
  author: gaai-framework
  version: "1.0"
  category: discovery
  track: discovery
  id: SKILL-GENERATE-STORIES-001
  updated_at: 2026-05-31
  status: stable
inputs:
  - one_epic: contexts/artefacts/epics/{id}.epic.md (the parent Epic file)
  - prd  (optional)
outputs:
  - contexts/artefacts/stories/*.md
  - contexts/backlog/active.backlog.yaml (mandatory — every story must be registered)
---

# Generate Stories

## Purpose / When to Activate

Activate when:
- An Epic is defined
- Adding or refining functionality
- Preparing work items for AI implementation

Stories are the **contract between Discovery and Delivery**. They must be the main execution unit in GAAI.

---

## Process

1. Read the Story template at `contexts/artefacts/stories/_template.story.md`. Read the parent Epic file. Derive story IDs using the parent Epic ID prefix (e.g., Epic E01 produces stories E01S01, E01S02, etc.).

   **CRITICAL — Decision Cross-Reference (MUST execute before writing any story):**
   - **a)** Extract keywords from the Epic scope and each story's intent (e.g., "email", "billing", "booking", "auth", "cron", "queue", "GCal", "GDPR").
   - **b)** Scan the Decision Registry in `contexts/memory/index.md` for DECs whose `domain`, `title`, or `tags` match these keywords. Use `grep` on `contexts/memory/decisions/` if the registry table is insufficient.
   - **c)** For each matching DEC, read the decision file and assess whether it **constrains** the story's implementation (e.g., a DEC may dictate how emails are sent, or how a recurring job is scheduled).
   - **d)** List constraining DECs in the story's `related_decs` frontmatter field. If a DEC imposes a specific implementation pattern (e.g., "all email via queues"), add an explicit AC referencing it (e.g., "AC-N: Email sent via queue per <DEC-id> — no synchronous sendEmail() calls").
   - **e)** If no DECs match, set `related_decs: []` explicitly — never leave the field empty by omission.
   - **Rationale:** In a past project incident, a story created a synchronous helper despite a previously-active DEC explicitly prohibiting that pattern. Subsequent stories reused the helper, accumulating violations that went undetected for weeks because no cross-reference step existed between Epic intent and the active DEC registry.

   **CRITICAL — Collision Guard (MUST execute before writing any file):**
   - **a)** Obtain the next Story ID by invoking
     `.gaai/core/scripts/lib/allocate-id.sh story <epic_prefix>` (where `<epic_prefix>` is
     the parent Epic's ID, e.g. `E220`). This script serialises allocation under an exclusive
     `flock`, accounts for IDs in every backlog file (`active.backlog.yaml`,
     `blocked.backlog.yaml`, archived `done/*.yaml`), existing story artefact files and the
     host-stable reservation ledger, and writes a reservation before returning. **Never compute the next story number
     by scanning the backlog manually** — the allocator is the single authority. If the
     allocator script is absent (fresh install), fall back to the scan-and-verify pattern as a
     degraded mode with a stderr warning.
   - **b)** For each story file to be created, **check if the file already exists** on disk at
     `contexts/artefacts/stories/{id}.story.md`. If the file exists and its `id` frontmatter
     matches a **different** epic or title, **STOP immediately** — this means an ID collision
     between two epics. Surface the conflict to the human and do not proceed.
   - **c)** If the file exists and its content matches the current Epic (same epic ID, same
     intent), treat it as an update — read the existing content first and preserve any human
     edits.
   - **Rationale:** In a past incident, two concurrent sessions assigned the same Epic ID to
     different epics because each did an independent scan-max on its own branch-isolated
     backlog. The allocator fixes this by serialising under `flock` and recording reservations
     in a host-stable ledger visible to all local sessions before any branch merges.

   **CRITICAL — Definition of Ready (DoR) Enforcement (MUST execute after writing each story):**
   - **a)** Read the parent Epic's `mandatory_ac_categories` frontmatter field.
   - **b)** For each declared category (e.g., `i18n`, `copy-quality`, `url-routing`, `icp-targeting`), verify that the story has **at least one AC** that explicitly addresses it.
   - **c)** If a story is missing an AC for a mandatory category: add one. If the requirement is unclear, add a placeholder AC with `[REQUIRES CLARIFICATION]` and flag it to the human.
   - **d)** If the Epic has `mandatory_ac_categories: []` (empty), skip this step.
   - **Rationale:** In a past incident, stories omitted mandatory AC categories (e.g., i18n, copy-quality) despite existing DECs requiring them. The Epic did not declare mandatory AC categories, so the omission went undetected. This step ensures domain-critical requirements cannot be silently skipped.

   **CRITICAL — Custom Skill Contract (MUST execute for any story involving a custom skill):**
   - **a)** Before writing stories, check `.gaai/project/skills/skills-index.yaml` for
     available custom skills. If that file is absent, scan `.gaai/project/skills/` directly
     for files matching `*/SKILL.md` and extract the `name` frontmatter field from each.
     Build a set of valid custom skill names.
   - **b)** If a story's intent requires invoking a custom skill from that set, declare the
     skill name(s) in the story's `required_skills` frontmatter field (YAML list, e.g.
     `required_skills: [my-skill]`). Only reference skill names that exist in the set from
     step (a). Do NOT declare a skill that is not found there — the daemon has no fallback
     resolution for a missing custom skill.
   - **c)** For each entry in `required_skills`, write **at least one AC** in the story body
     that explicitly names that skill's expected **output** — the observable artifact or
     state change the skill produces (not merely "the skill was invoked"). The AC is the
     surface `qa-review` uses to verify the skill's contract was honored.
   - **d)** If no custom skill is needed, omit `required_skills` entirely or set
     `required_skills: []`. The absence of the field does not trigger validation.
   - **Rationale:** Per the contract-carried delivery invariant, a custom skill may only enter
     autonomous Delivery via an explicit story `required_skills` contract — autonomy never
     selects a custom skill on its own. The bound output AC is the only QA-verifiable surface;
     without it, `validate-artefacts` returns BLOCKED. Both this framework and the cloud
     product enforce identical semantics independently.

2. Read parent Epic domain. If Epic has a domain, set it as the story's default. Allow explicit override per story.
3. Write from the user's perspective
4. Focus on behavior, not UI or technology
5. Keep stories small and independent
6. Ensure every story is testable
7. Avoid technical solutions in story body
8. For each story, answer: "What should the user be able to do or experience?"
9. Output using canonical Story template
10. **MANDATORY — Validation gates via isolated sub-agents (MUST pass before backlog registration).**

   Before registering ANY story in the backlog, the Discovery Agent MUST execute both gates in sequence. **Both gates MUST be invoked as isolated sub-agents** (via the Agent tool) — never executed inline by the main Discovery agent, even if the main agent is the one that created the story. The author of a story cannot objectively validate its own work (Core Principle #5 — Independent Evaluation).

   a) **Format gate** — invoke `validate-artefacts` (SKILL-VALIDATE-ARTEFACTS-001) as an **isolated sub-agent**. Provide the generated stories and their parent Epic. If verdict is BLOCKED, fix the flagged issues in the main agent and re-invoke the sub-agent until PASS.

   b) **Independent Review gate** — invoke the **Review Sub-Agent** (SUB-AGENT-REVIEW-001) at the applicable tier. The Review Sub-Agent executes the `review-story-alignment` (SKILL-RSA-001) 3-pass process during Tier 2 review. Provide the stories + Epic + referenced DECs + Discovery Session Brief (if one was compiled). If no Session Brief exists, the reviewer runs in Tier 1 (DEC constraints + DoR + attestation + scope creep). If any story FAILs, the Discovery Agent resolves findings (from Brief + DECs) or escalates to the human, then re-invokes the reviewer. **Maximum 2 review cycles** — after that, all remaining findings escalate to the human.

   **Termination rule (founder-confirmed):** After review cycle 2, if the only remaining findings are MEDIUM (or lower) and each names a specific deterministic fix the reviewer already prescribed, Discovery applies those fixes, re-verifies once (re-run the reviewer or a targeted self-check on the changed lines), and attests on a clean PASS. Only unresolved CRITICAL or HIGH findings — or any finding requiring a non-obvious judgment call — escalate to the human. The 2-cycle ceiling still caps full re-review rounds; the single post-cycle-2 surgical re-verify is not a third adversarial cycle.

   **These gates are sequential: format must PASS before the independent review runs.**

   **No exceptions.** Both gates run for every story creation or modification — regardless of batch size (1 story or 20), origin (full Epic session, bug triage, single amendment), or whether a Session Brief was compiled. For batch reviews (2+ stories), invoke a separate Review Sub-Agent per story to eliminate positional bias (see `review.sub-agent.md` § Positional bias mitigation).

   **A story registered in the backlog as `refined` without both gates passing via sub-agents is a governance violation.** If this step is skipped, the commit message will lack gate evidence (e.g., "validate-artefacts: PASS, review[tier-2]: PASS"), which is detectable in review.

   **Rationale:** (1) In a past incident, Discovery produced 14 stories and registered them as `refined` without running either gate — the gates were not in the skill's step list. (2) Later, Discovery self-validated both gates inline, using the "no Session Brief" skip condition to bypass the alignment gate entirely. In both cases, the main agent marked its own homework — no independent review occurred. This step closes both gaps by mandating sub-agent execution with no skip conditions. (3) Updated 2026-03-30: the alignment gate is now executed by the Review Sub-Agent (SUB-AGENT-REVIEW-001), enforcing Core Principle #5 (Independent Evaluation).

11. **MANDATORY — Epic dependency propagation (MUST execute before backlog registration).**
   - **a)** Read the parent Epic's `## Dependencies` section. If it lists other Epics (e.g., "E39 must be complete before E40 starts"), identify the **terminal stories** of each listed Epic — the stories with the highest IDs or the ones that other stories in that Epic depend on.
   - **b)** Every story in the current Epic MUST include at least one terminal story from each dependent Epic in its `depends_on` list. This ensures the daemon cannot pick up stories from this Epic until the dependent Epic is fully delivered.
   - **c)** If the parent Epic has no Dependencies or lists "None", skip this step.
   - **Rationale (2026-04-05):** E40S02 was picked up by the daemon before E39 was complete because the phasing constraint ("E39 done before E40") was written in Epic prose but not encoded in story-level `depends_on`. The daemon's scheduler reads `depends_on`, not Epic prose. Prose constraints that are not encoded in story dependencies are invisible to the daemon.

12. **MANDATORY — Register in backlog.** After writing all story files, add each story to `contexts/backlog/active.backlog.yaml` with:
   - `id`, `epic`, `title` (from story frontmatter)
   - **`status` per gate state — STRICT**:
     - `status: draft` if EITHER `validate-artefacts` OR Reviewer Tier 2 has not yet returned PASS (cycle 1 or 2) for this specific story. This is the default for any story registered before its own gates have completed.
     - `status: refined` ONLY after BOTH gates have returned PASS. Promote `draft → refined` as a separate backlog write (not bundled with the initial registration).
     - **Never register as `refined` "for now" while still iterating** — the delivery daemon polls `active.backlog.yaml` for `refined` items and dispatches them immediately, snapshotting whatever is in the worktree at dispatch time. Refined-while-iterating creates a race condition where un-reviewed cycle-0 drafts (with potentially CRITICAL-severity factual errors) can be picked up before cycle-1 corrections land.
     - **For batch Discovery (multiple stories drafted together):** register all as `draft` initially. Run gates per story (the sequencing rule of step 10 still applies). Promote each to `refined` individually once its own cycle ends in PASS. Never bulk-promote at the end of a batch.
   - `priority` (derived from Epic priority or explicit input)
   - `artefact` path pointing to the story file
   - `dependencies` (from story frontmatter `depends_on` or Epic execution order)
   - `notes` (source context — e.g., Discovery session date, governing DEC ; include gate trail once available)
   - **Pipeline-schema fields (MANDATORY when `cutover_state.default_pipeline` at the top of `active.backlog.yaml` is `3phase`)**:
     - `phase_status: not_started` — initial value for any new entry. The 3-phase Delivery lifecycle is `refined → planned → implemented → qa_passed → pending_review → externally verified exact-current merge → done`. `pending_review` is carried by `pr_status` while top-level `status` remains `in_progress`; only the configured-target watcher projects terminal `done / done / merged`. The daemon reads `phase_status` on every poll. An entry without `phase_status`, or with `phase_status: ''`, causes the daemon to fail with `3phase dispatch error at phase_status=''` and leaves the entry stuck (the entry may also have its top-level `status` flipped to `in_progress` by the failed dispatch attempt before it errors out).
     - `delivery_pipeline: 3phase` — the per-entry pipeline assignment. Use the value of `cutover_state.default_pipeline` from the top of the backlog (typically `3phase` once the 3-phase pipeline migration has landed in the project ; fallback `legacy` if cutover is reverted). Set explicitly even when matching the default — the field is read per-entry, not inherited from cutover_state at dispatch time.
     - For legacy-pipeline workspaces (`cutover_state.default_pipeline: legacy`) these fields can be omitted (legacy daemon ignores them), but writing them anyway is forward-compatible and recommended.
   - **`impl_model` field — DO NOT SET unless overriding a default**:
     - **Default behavior (recommended)** : leave `impl_model` ABSENT in both story frontmatter and backlog entry. The daemon's tier-aware default coerces routing automatically :
       - Tier 1 absent → secondary (cost-optimal, where secondary-route env vars are configured)
       - Tier 2+ absent → primary (required for the context window margin)
     - **Set `impl_model: secondary` ONLY on Tier 1 stories** where cost optimization is intentional and the secondary model's context budget is comfortably sufficient.
     - **NEVER set `impl_model: secondary` on Tier 2+ stories.** The daemon hard-gate will refuse the Impl phase dispatch and flip `phase_status: failed`. This is a structural failure, not a transient one — empirical evidence has shown that Tier 2 cumulative input crosses the secondary-model context-compact threshold within a small number of events on the secondary route, triggering rapid context-compact cascades and masked fallback.
     - **Set `impl_model: primary` explicitly only on Tier 1 stories** that override the cost-optimal default for a sensitivity reason (security, compliance, accuracy-critical). For Tier 2+, leaving the field absent is preferred (the default coerces automatically — no redundant directive).
     - **Validation gate**: `validate-artefacts` (SKILL-VALIDATE-ARTEFACTS-001) returns BLOCKED on the `tier ≥ 2 + impl_model: secondary` combination. Stories that violate this rule must be either (a) decomposed to Tier 1 sub-stories per the story-scope-discipline pattern, (b) have the `impl_model: secondary` line removed (default coercion to primary), or (c) explicitly set `impl_model: primary`.
     - **Rationale**: a prior Discovery session copied `impl_model: secondary` from a sibling story pattern onto Tier 2 stories without realizing the daemon hard-gate had been added the same day. The daemon refused dispatch, marked `phase_status: failed`, leaving the stories stuck. Both the validation gate above and this skill text (prevention at authoring time) close the loop.

   **A story that exists only as an artefact file but is not in the backlog is invisible to Delivery and will never be executed.** This step is non-negotiable.

   **Rationale (status lifecycle):** A prior Discovery batch had stories rolled back from `in_progress` because they were registered as `refined` while Discovery was still iterating Reviewer cycle-1 corrections. The daemon picked up the un-reviewed drafts and began implementing architecturally wrong code based on factual errors that the Reviewer would have caught. The fix is strict adherence to the `draft → refined` lifecycle defined in `base.rules.md` § Backlog State Lifecycle — this clause makes the timing explicit at skill level.

   **Rationale (pipeline-schema fields):** A Discovery batch registered new stories without `phase_status` + `delivery_pipeline` fields. The daemon picked up the first story at the next poll, marked its top-level `status` to `in_progress`, then errored out at the 3-phase dispatch step (`phase_status=''`), leaving the entry in a stuck state. Root cause : this skill predated the 3-phase pipeline schema (introduced via a foundational backlog migration story when projects flip `cutover_state.default_pipeline` to `3phase`) and never enumerated the new mandatory fields in step 12. Mitigation : the bullet above now mandates both fields whenever `cutover_state.default_pipeline = 3phase`, with an explicit pointer to the failure mode so the skill author understands why the field is non-optional rather than nice-to-have.

   **CRITICAL — Backlog YAML write safety (MUST follow):**
   - **Match native indentation.** Before appending, check the existing format: `grep -m1 "^- id:" <backlog>`. Use the same indent level (typically 0-space: `- id:` with 2-space properties).
   - **Never use `yaml.dump()`** to rewrite the file. It destroys comments, changes quotes, and alters indentation. Use line-by-line append or the scheduler (`backlog-scheduler.sh --set-status`, `--set-field`).
   - **Validate YAML after every write** with the repository-controlled runtime — never an ambient parser and nothing to install: `bash .gaai/core/scripts/lib/yaml-runtime.sh --validate .gaai/project/contexts/backlog/active.backlog.yaml`. If validation fails, fix before committing.
   - **Rationale (2026-04-04):** Mixed indentation from `cat >> heredoc` (2-space items appended to a 0-space file) + `yaml.dump()` reformatting broke the backlog YAML, blocked the daemon, and required manual cleanup. These rules prevent recurrence.

13. **MANDATORY — Commit & push to staging (ATOMIC).** After all story files are written and registered in the backlog, commit all generated/modified files **and push to `staging` in the same step**. Commit without push is a violation — Delivery cannot pick up stories that exist only locally.
    - Stage: story files (`contexts/artefacts/stories/*.story.md`), backlog (`contexts/backlog/active.backlog.yaml`), and any other modified GAAI context files (memory, decisions, etc.)
    - Commit message format: `chore(discovery): generate stories {id_range} for Epic {epic_id}`
      - Example: `chore(discovery): generate stories E01S01–E01S05 for Epic E01`
    - Push to `staging` branch **immediately after commit — never wait for human to request the push**
    - **Rationale:** In a past incident, Discovery committed a story but did not push. The human had to explicitly request the push. The commit and push are a single atomic operation — separating them defeats the purpose of this step.

---

## Outputs

Template: `contexts/artefacts/stories/_template.story.md`

Produces files at `contexts/artefacts/stories/{id}.story.md`:

```
As a {user role},
I want {goal},
so that {benefit/value}.

Acceptance Criteria:
- [ ] Given {context}, when {action}, then {expected result}
```

---

## Quality Checks

- Written from the user's perspective
- Acceptance criteria are explicit and testable
- No technical implementation detail in story body
- Each story maps to a single Epic
- Stories are independent and deliverable individually
- Each story file's frontmatter `id` and `related_backlog_id` match the parent Epic's ID prefix
- **Every generated story has a corresponding entry in `active.backlog.yaml`** — verify by counting story files vs backlog entries for this Epic. Mismatch = FAIL.
- **No existing story file was overwritten with a different Epic's content** — verify each written file's `epic` frontmatter matches the intended Epic. Mismatch = CRITICAL FAILURE.
- **Every story has a `related_decs` field in frontmatter** — either a non-empty list of constraining DECs, or an explicit empty list `[]`. Missing field = FAIL. Stories touching email, billing, booking, auth, or infrastructure domains with `related_decs: []` should be double-checked — these domains have the highest DEC density.

---

## Non-Goals

This skill must NOT:
- Define architecture or implementation approach
- Generate Epics (use `generate-epics`)
- Produce stories without a parent Epic

**Stories are the contract. Ambiguous stories produce ambiguous software.**
