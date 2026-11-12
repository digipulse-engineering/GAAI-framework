---
name: generate-epics
description: Translate product intent or a PRD into a small set of outcome-driven Epics (3–7 max). Activate when starting a new product, adding a significant feature domain, or breaking down a PRD into actionable user outcomes.
license: ELv2
compatibility: Works with any filesystem-based AI coding agent
metadata:
  author: gaai-framework
  version: "1.0"
  category: discovery
  track: discovery
  id: SKILL-GENERATE-EPICS-001
  updated_at: 2026-01-27
  status: stable
inputs:
  - product_intent  (or PRD if available)
outputs:
  - contexts/artefacts/epics/*.md
---

# Generate Epics

## Purpose / When to Activate

Activate when:
- Starting a new product
- Adding a significant feature or domain
- Restructuring product scope
- Breaking down a PRD into actionable outcomes

Works with or without a PRD.

---

## Process

1. Read the Epic template at `contexts/artefacts/epics/_template.epic.md` before writing any Epic file.

   **CRITICAL — ID Collision Guard (MUST execute before assigning any Epic ID):**
   - **a)** Obtain the next Epic ID by invoking `.gaai/core/scripts/lib/allocate-id.sh epic`
     (path relative to the repository root). This script serialises allocation under an
     exclusive `flock`, cross-references every backlog file (`active.backlog.yaml`,
     `blocked.backlog.yaml`, archived `done/*.yaml`), existing epic and story artefact files and
     the host-stable reservation ledger (shared across all local worktrees before any branch
     merges), and
     writes a reservation before returning. **Never compute `max+1` manually** — the allocator
     is the single authority for ID assignment. If the script is absent (bootstrapping a fresh
     install before this allocator was delivered), fall back to the original scan-max pattern
     as a degraded mode with a stderr warning.
   - **b)** For each Epic file to be created, **check if the file already exists** at
     `contexts/artefacts/epics/{id}.epic.md`. If it exists with different content,
     **STOP immediately** — surface the conflict to the human.
   - **c)** Never reuse an Epic ID, even if the previous Epic was deleted or superseded.
   - **Rationale:** In a past incident, two concurrent sessions both assigned the same Epic ID
     to different epics because each did an independent scan-max on its own branch-isolated
     backlog. The allocator fixes this by serialising under `flock` and recording reservations
     in a host-stable ledger visible to all local sessions before any branch merges.

2. Think in **user outcomes**, not features
3. Keep Epics high-level and value-focused
4. Avoid implementation detail
5. Limit to 3–7 Epics maximum
6. For each Epic, answer: "What meaningful user result will this create?"
7. Set domain based on the Epic's primary intent (e.g., engineering, marketing, legal). Leave empty if not applicable.
8. Output using the canonical Epic template

---

## Outputs

Template: `contexts/artefacts/epics/_template.epic.md`

Produces files at `contexts/artefacts/epics/{id}.epic.md`.

Key sections per Epic:
- Purpose: what user outcome this delivers and why it matters
- Scope: high-level description of what is included
- Out of Scope: what is explicitly excluded
- Stories: list of story IDs (descriptive only; authoritative tracking is in the backlog)
- Success Metrics: how to know the Epic delivered value
- Dependencies: other Epics or external factors this depends on

---

## Quality Checks

- Each Epic expresses a user outcome, not a technical feature
- Maximum 7 Epics per initiative
- No implementation detail present
- Each Epic is independently valuable
- **No Epic ID collision** — the assigned ID does not exist in the backlog or on disk with different content

---

## Non-Goals

This skill must NOT:
- Generate Stories (use `generate-stories`)
- Make technical architecture decisions
- Produce more than 7 Epics per initiative

**Epics are the bridge between vision and execution.**
