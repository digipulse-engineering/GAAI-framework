---
type: rules
category: base
id: RULES-BASE-001
tags:
  - universal
  - conversational
  - governance
created_at: 2026-03-15
updated_at: 2026-05-08
---

# GAAI Base Rules (Universal)

These rules apply **at all times** — in structured GAAI flows AND in conversational mode.
They are loaded at session startup via the tool adapter.

For flow-specific rules (agent responsibilities, context isolation, branch rules, cron, capability readiness), see `orchestration.rules.md`.

---

## Core Governance Rules

1. **Backlog-first.** Every execution unit must be in the backlog. No work without a backlog entry.
2. **Skill-first.** Every agent action must reference a skill. Read the skill file before invoking it. **Never produce artefacts or execute processes from cached knowledge** — the skill file is the single source of truth for process steps, not just output format. Format familiarity does not substitute for reading. Every artefact must declare `skills_invoked` in its frontmatter to attest which skill files were read. An artefact without `skills_invoked` fails validation.
3. **Memory is the source.** GAAI memory (`contexts/memory/`) is the authoritative source for project context, decisions, and patterns. Load relevant memory before any planning or artefact production. Never rely on internal/cached knowledge about the project — read the files. Memory retrieval discipline:
   - Retrieval MUST start from `contexts/memory/index.md` — this is the authoritative registry
   - Retrieval MUST be selective (by category / tags) — never auto-load entire folders
   - Only the Discovery Agent (or Bootstrap Agent during initialization) may trigger `memory-ingest`
   - Delivery may only write memory via `decision-extraction` after QA PASS (governed exception)
4. **Artefacts document — they do not authorize.** Only the backlog authorizes execution.
5. **Independent evaluation.** An agent must never be the sole evaluator of its own consequential outputs. Every consequential output — recommendations, proposals, Session Briefs, stories, epics — must be independently evaluated by a separate agent instance before reaching the human or the backlog. Self-assessment (Critical Self-Assessment, Brief Self-Assessment) is retained as draft preparation but is never the authoritative quality gate.
   - **Minimum:** Spawn a sub-agent in an isolated context window with an adversarial prompt. The reviewer must NOT receive the conversation history (prevents confirmation bias) or the generator's self-assessment (prevents anchoring).
   - **Better:** Use model diversity — route evaluation to a different model than the generator. Self-preference bias is perplexity-driven (in the model weights, not the context), so same-model isolation reduces but does not eliminate bias.
   - **Proportionality:** Mechanical checks (format validation, collision guards) do not require independent evaluation. The trigger is the presence of **consequential choices** — decisions between alternatives (D-), trade-offs (T-), scope changes, or recommendations that constrain future decisions.
   - **Implementation:** The Review Sub-Agent (SUB-AGENT-REVIEW-001) enforces this principle. See `agents/sub-agents/review.sub-agent.md` for the tiered architecture (Tier 1: governance sanity, Tier 2: adversarial substance review) and `orchestration.rules.md` § Independent Review Gate for the mandatory gates.

   **Why this is a core principle (research foundation):**
   - Self-preference bias is quantified and perplexity-driven — LLMs systematically prefer outputs familiar to their own distribution, regardless of quality (Wataoka et al., arXiv:2410.21819, 2024)
   - Generator/evaluator separation is foundational to Constitutional AI (Anthropic, 2022), LLM-as-Judge (Zheng et al., NeurIPS 2023), and Chain-of-Verification (Meta, ACL 2024)
   - 12 distinct evaluation biases are documented, many amplified when judge = generator (CALM framework, Li et al., NeurIPS 2024)
   - Multi-agent debate with heterogeneous agents consistently outperforms self-evaluation (Du et al., ICML 2024; DMAD, ICLR 2025)
   - Cascaded evaluation (light first, adversarial when needed) reduces cost by 40% without quality loss (Trust or Escalate, ICLR 2025 Oral)

6. **Artefacts are never overwritten blindly.** Before writing any artefact file (story, epic, decision), check if the file already exists on disk. If it exists and belongs to a different entity (different epic, different intent), **STOP and escalate** — this is an ID collision. Never silently overwrite an existing artefact. This rule is absolute and applies even in conversational mode.

---

## Default Collaboration Stance

Adopt a critical partner stance by default in conversational and non-governed collaboration — direct user requests, recommendations, exploration, analysis, ad-hoc tasks, and reversible, low-blast-radius code-level interventions that do not produce or amend governed artefacts, change public contracts, affect data integrity, touch secrets, security, infrastructure, billing, or externally-visible behavior.

Before answering, silently frame each request: understand the user's real objective, verify assumptions, identify missing information, risks, alternatives, and success criteria. **Do not surface this framing to the user as questions or as a visible checklist** — it is internal preparation, not output.

Ask the user for clarification only when it is truly necessary to avoid a materially wrong or unsafe result — including actions with significant blast radius: destructive, irreversible, externally-visible, secret-touching, security-sensitive, data-integrity-impacting, infrastructure-impacting, billing-impacting, or contract-changing. Otherwise, proceed with the best reasonable assumptions, state only the material assumptions or uncertainties that affect usefulness, correctness, safety, or reversibility of the answer, and produce a directly usable answer.

The critical partner stance includes the obligation to disagree when warranted: if your silent framing reveals that the request is misframed or that compliance would lead to a wrong outcome, say so briefly rather than silently complying — then proceed, push back, or escalate based on the user's response.

This stance does **not** soften concision, precision, or safety obligations elsewhere in this file.

It does **not** apply to governed flows or durable artefacts — see § Conflict & Escalation Protocol below.

It authorizes assumption-based progress only within conversational, reversible, non-governed work; it never authorizes execution that another rule, backlog state, skill requirement, safety rule, or governance flow forbids.

---

## Language Rule

Agents address the human in the human's language. All artefacts, backlog entries, commit messages, and governance files are written in English regardless of conversation language.

---

## Recommendation Validation

When any agent proposes a recommendation that implies a **choice between viable alternatives** (architecture, library, pattern, service), the agent must validate against industry standards and best practices BEFORE presenting the recommendation. If the recommendation diverges from an established standard, this must be signaled explicitly with justification.

This rule does NOT apply to: obvious choices with no viable alternative, bug fixes, minor refactoring, or conventions already established in `patterns/conventions.md`. Proportionality governs — do not slow down routine work with unnecessary research.

---

## Backlog State Lifecycle

Backlog items MUST follow this lifecycle:

```
draft → refined → in_progress → done | failed
```

Auxiliary states: `deferred`, `blocked`, `cancelled`, `superseded`, `escalated`.

- `draft` — Story created but not yet validated or acceptance-criteria complete
- `refined` — Story is validated, acceptance criteria are present and unambiguous, ready for Delivery
- `in_progress` — Delivery is actively executing the Story
- `done` — for Delivery code/content, the configured-target watcher verified and projected an
  externally authorized exact-current merge; QA or acceptance-criteria PASS alone is non-terminal
- `failed` — Story failed and cannot be retried without human intervention
- `deferred` — Story is intentionally held back by a business gate (phase gate, data threshold, go-live prerequisite) — not a technical dependency

### Transition Rules

- Only Discovery may move items from `draft` to `refined`
- Only Discovery may set `deferred` status (business decision, not technical)
- Delivery may only consume items in `refined` or `in_progress`
- Delivery must update status to `in_progress` when execution begins. For Delivery code/content,
  QA PASS keeps `status: in_progress`, `phase_status: qa_passed` and, after exact publication,
  `pr_status: pending_review`; only the configured-target watcher may project `done` after an
  externally authorized exact-current merge.
- Failed executions must be marked `failed` with artefact notes
- No agent may skip states (e.g., `draft` directly to `in_progress` is forbidden)

---

## Backlog Archiving Rules

An item may be archived (moved from `active.backlog.yaml` to `done/`) once its status is `done`, `cancelled`, or `superseded`. Archiving is a **file split, not a deletion**: the archive lives in the same repository, under version control, and is never pruned.

**A dependency id resolves if it names a row in any backlog file — `active.backlog.yaml`, `blocked.backlog.yaml`, or `done/*.yaml`.** An id that names a row in none of them is a broken ref: **zero broken refs allowed**. Note this is an *existence* test, not a *satisfaction* test — resolving proves the referenced item is findable, not that it is complete. Whether a dependency is satisfied is a separate, status-based question the scheduler answers.

Dependencies on `done` items are historical (execution order) but must be preserved for traceability — never cleared or stripped. Archiving an item therefore never invalidates an edge pointing at it, and never requires pulling a dependency closure back into the active backlog.

Two further invariants, both mechanically checkable:

1. An id must appear **at most once** in `active.backlog.yaml`. Per-story tooling is id-keyed and silently takes the first match, so a duplicate desynchronises recorded status from actual delivery.
2. An id must live in **exactly one** backlog file. Do not copy a row into the active backlog to make a reference resolve — the resolution set above already covers it, and a second copy violates the single-source-of-truth rule in `backlog.rules.md`. Move, never duplicate.

> **Amended 2026-07-28.** Step 4 previously required every dependency to resolve inside `active.backlog.yaml` alone, which forced a `done` item's entire transitive closure to stay unarchived for as long as any non-terminal item depended on it. Three findings drove the amendment: the scheduler already resolves dependencies over the union (archived ids count as satisfied), so the stricter reading protected nothing operationally; the strict form fought the archive's own purpose, since one live item could pin an arbitrarily large closure in the active file indefinitely; and it was being worked around in practice rather than followed. A rule that is unenforceable, unenforced, and generates churn is worse than one that matches the tooling. The traceability the old step 4 protected is preserved by the union plus the never-strip-edges rule. A consumer sweep found no tool that resolves dependencies from the active backlog without also reading the archive.

---

## Conflict & Escalation Protocol

When an agent encounters a conflict between a human instruction and an existing rule:
- Stop immediately. Do not attempt to resolve it silently.
- Surface the conflict explicitly: name the instruction, name the rule, state what they contradict.
- Wait for human resolution. Do not proceed until the conflict is resolved.

In governed flows or on durable project artefacts — including acceptance criteria, scope, DEC, refined stories, Session Briefs, backlog-impacting decisions, or any artefact whose ambiguity could contaminate downstream work — ambiguity must be escalated:
- Stop. Do not interpret intent.
- Escalate for clarification when the ambiguity affects scope, decisions, traceability, or downstream commitments.

**In governed contexts, if in doubt: stop and ask.** In conversational and non-governed collaboration, the § Default Collaboration Stance applies — proceed with the best reasonable assumptions and explicit uncertainty, asking only when a clarification is truly necessary to avoid a materially wrong or unsafe result.

---

## Forbidden Patterns (Universal)

The following are explicitly forbidden in all contexts — structured flows and conversational mode:

- Auto-loading full memory (folders, entire categories)
- Skills accessing memory implicitly (without explicit `memory-retrieve` call)
- Bypassing backlog states (skipping lifecycle transitions)
- Producing artefacts without reading the governing skill file first
- Silently overwriting existing artefacts without checking for ID collisions
- Writing substance into index / registry rows. **Index = pointer.** Every row of `index.md`, `index-*.md`, archive indexes is metadata + ≤30-word topic, ≤200 chars total. Substance lives in the target file (DEC body, `_log.md`, artefact, `git log`). Forbidden in any registry row : Tier 2 cycle trails, finding counts, commit SHAs, §-numbered substance dumps duplicating target body, validation ceremony prose, drift-heal forensic prose. Remediation when drift detected : skill `memory-index-compact` (SKILL-MEMORY-INDEX-COMPACT-001).
- Ad-hoc scan-max epic/story ID allocation when concurrent Discovery sessions are possible.
  Use `.gaai/core/scripts/lib/allocate-id.sh` instead — it serialises allocation under an
  exclusive lock and records reservations in a host-stable ledger (`~/.gaai/reservations/`)
  visible to all local worktrees before any branch merges. Epic and story IDs MUST be obtained
  from this allocator whenever running more than one Discovery session locally.
  (Exception: allocator script absent on a fresh install — fall back to scan-verify with a
  stderr warning, then install the allocator at the next available opportunity.)
  Enforced at publication wherever the remote carries the shared reservation record
  (`refs/gaai/reservations`): the pre-push hook `18-id-reservation-guard.sh` refuses a push that
  adds an Epic or Story id with no reservation there, or one reserved by another host's holder.
  An id chosen before reserving is claimed with `allocate-id.sh reserve <id>`, which fails if
  anyone already holds it; a letter-suffixed split follows its numeric anchor.
  **An id is reserved only when the allocator exits 0.** Never discard its stderr
  (`2>/dev/null`) or ignore its exit status. Exit 3 means the shared record could not be
  updated and NO id was allocated. This is typical of a host that may not push
  `refs/gaai/reservations`, for example an agent session whose credentials push only its own
  branches. Do not fall back to scan-max, and do not get past it with `GAAI_ALLOW_UNCONFIRMED`,
  `GAAI_SCAN_REMOTE=0`, a fake `GAAI_REMOTE` or ledger edits: an id that only one host can see
  is the id another host will reuse. Reserve from a host
  that can push the ref, or through the project's CI relay (`allocate-id.sh --help`), or stop
  and tell the human.

For additional flow-specific forbidden patterns (Delivery memory ingestion, direct human→Delivery interaction), see `orchestration.rules.md` § Forbidden Patterns.

---

## Default Deny

**If a behavior is not explicitly allowed by these rules or by `orchestration.rules.md`, it is forbidden.**
