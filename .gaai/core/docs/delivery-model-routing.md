---
type: reference
id: DOC-DELIVERY-MODEL-ROUTING-001
track: delivery
updated_at: 2026-08-19
---

# Delivery model routing

Models are replaceable resources. Roles and policies are stable.

Delivery steps ask for a **role**; the router answers with a model that is
available, capable enough, and — for anything that evaluates work — provably
independent of what it is about to judge. Replacing a model, adding a provider,
or reordering preferences is a config edit. The daemon and the phase handlers
never learn a model name.

---

## The one rule that never bends

> A model must never evaluate work it materially contributed to, regardless of
> context window, session, harness invocation, or reasoning effort.

Everything else in this system — availability states, capability floors,
fallback order — can yield to circumstance. This cannot. An exhausted quota on
one provider is a reason to try the next candidate; it is never a reason to let
an author grade its own work.

**There is exactly one *intended* way to forfeit the guarantee, and it is loud.**
`GAAI_MODEL_ROUTING=0` turns routing off for every phase at once.

`GAAI_QA_MODEL` is *not* a second way, though it once was. It pins the evaluator
and skips candidate ordering — but the independence gate still runs against the
pin. A pin naming a contributor **stops the phase**, and so does a pin that
cannot be checked at all, whether because the spelling resolves to no known
model or because the routing substrate is missing. An unverifiable pin is
indistinguishable from an ineligible one; a gate clears what it can identify and
refuses the rest.

Two further exits exist and are reachable by **misconfiguration** rather than
intent. Both are named here because an invariant that hides its exits is not
absolute, it is merely unexamined:

- **The routing substrate absent** while no pin is set — the phase falls back to
  its legacy model, with a warning, without the guarantee.
- **`GAAI_PROVENANCE_DIR` or `GAAI_PROVENANCE_PATH` pointed at an empty
  location** — the ledger reads as "no contributors" and every candidate clears.

Both are the honest cost of building the guarantee on a record that lives on
disk. `doctor` will not catch either; a routing record that names no contributors
on a story that plainly had one is the signal to look for.

---

## Pieces

| File | Role |
|---|---|
| `.gaai/core/config/delivery-routing.json` | The registry and the policy. All concrete model names live here and nowhere else. |
| `.gaai/core/scripts/lib/delivery-router.mjs` | The engine and its CLI. Names no model, no provider. |
| `.gaai/core/scripts/lib/delivery-provenance.mjs` | The per-story contributor ledger. |
| `.gaai/core/scripts/lib/delivery-routing.sh` | The bash surface `daemon-dispatch.sh` calls. |

Config resolution order: `$GAAI_ROUTING_CONFIG` → `.gaai/project/contexts/config/delivery-routing.json` → the OSS default above. A project can re-point aliases or reorder candidates without editing (and later fighting a sync of) the framework substrate.

---

## Roles

Stable across model generations:

```
PLAN_PRODUCER    PLAN_REVIEWER    IMPL    QA_CODE    QA_REQUIREMENTS    QA_PLAN
ESCALATION_ARBITER
```

### The shipped default

The steps that make decisions are smarter than the one that types the code.

| Step | Leads with | Effort | Why |
|---|---|---|---|
| PLAN — Producer | strongest general model | high | Reads Story and codebase, resolves ambiguity, produces a plan another agent can execute |
| PLAN — Reviewer | deepest-reasoning model | high | Must try to *break* the plan, not restate it. A different model family avoids two agents sharing one blind spot |
| IMPL | efficient coding model | high | Architecture is already settled; the work is inspect / modify / test / correct |
| QA lanes | strongest general model | high | Adversarial reading of the diff. Must not be satisfied by green tests |
| Escalation arbiter | deepest-reasoning model | xhigh | Court of last resort on ESCALATE, not a permanent worker |

Concrete models sit in the config; the table above is the shape, and it survives
a model generation change.

### The fallback table, when the preferred provider is gone

A second provider does not necessarily offer the same shape. Where it has only
two usable models, the strong one does double duty as reviewer and implementer —
which stays safe precisely because QA excludes the implementer:

| Step | Model | Effort |
|---|---|---|
| PLAN — Producer | balanced model | **xhigh** |
| PLAN — Reviewer | frontier model | high |
| IMPL | frontier model | high |
| QA lanes | balanced model | **xhigh** |

Note where the effort sits. The balanced model is a capability class below the
floor those seats require, and it takes them **only** because it runs there at
raised effort. Which means:

### Effort is a function of (role, model), not of the role alone

A model that sits below a seat's floor may take that seat only where the
operator has declared it — by name, in that role's `overrides`, with a reason
and the raised effort that justifies the exception:

```json
"QA_CODE": {
  "minimum_capability": "FRONTIER",
  "overrides": {
    "<a STRONG model>": { "effort": "xhigh", "capability_waiver": "why this is acceptable here" }
  }
}
```

Bounded deliberately, because this is the one mechanism that can weaken a floor:

- The waiver reaches **one class** below the floor, never two. It can express
  "this model plus more thinking is good enough here"; it cannot express
  "anything will do".
- It applies to **the role that declares it** and no other.
- The selected decision carries `capability_waived` with the reason, so the
  exception is in the audit trail rather than in someone's memory.
- A seat override can **raise** effort, never lower one a trigger already asked
  for — a high-risk delivery stays at `xhigh` whatever the seat says.
- Remove the declaration and the hard floor is back, with no code change.

The floor exists to prevent a *silent* downgrade. A declared, reasoned,
effort-compensated, role-scoped exception is the opposite of silent — and the
test suite asserts exactly that: in every outage scenario, any below-floor model
in a seat must carry a waiver and be running at raised effort.

### QA independence rule

**The QA model may be the one that produced the PLAN. It must never be the one
that wrote the code.**

Judging whether *someone else's* code matches your plan is a different act from
judging your own code. The failure that rule cannot catch — that the plan itself
was wrong — is exactly what `QA_REQUIREMENTS` covers, where the Story is
normative and the PLAN is explicitly not treated as ground truth; and that lane
is independent of the implementer too. So the coverage holds.

This is also what makes the pipeline servable. A producer and a reviewer on the
plan plus an implementer on the code spend three models; a lane excluding all of
them needs a **fourth**. That is arithmetic, not luck — see the resilience
report below.

Each role declares an **ordered candidate list**, a **minimum capability**, and
which artefact kinds it **evaluates**. There is no scoring engine: V1 walks the
list in order and takes the first candidate that clears every gate.

```
for candidate in ordered_candidates(role):
    model available?                     no  -> skip
    harness AVAILABLE?                   no  -> skip
    capability >= minimum_capability?    no  -> skip
    contributed to what this step evaluates?  yes -> skip     # absolute
    select, execute, stop
otherwise -> BLOCKED_NO_ELIGIBLE_MODEL
```

### Capability floors

`WORKER < STRONG < FRONTIER`. When only sub-floor models remain the router does
**not** quietly downgrade — it returns `BLOCKED_NO_ELIGIBLE_MODEL` with
`blocked_class: CAPABILITY_FLOOR`, which is the signal to escalate.

### What each lane evaluates

| Role | Excluded contributors | Why |
|---|---|---|
| `PLAN_REVIEWER` | PLAN | It is judging the plan. |
| `QA_CODE` | CODE | Judges the diff, the repo, and test evidence. A model that wrote the PLAN but not the code is still eligible. |
| `QA_REQUIREMENTS` | CODE | The Story and its acceptance criteria are the normative source; the PLAN is not treated as ground truth. |
| `QA_PLAN` | CODE | Judges the approved PLAN against the implementation. The plan's author may serve here; the implementer never may. |
| `ESCALATION_ARBITER` | QA | Arbitrates an ESCALATE, so it must not have produced the findings it is weighing. |
| `PLAN_PRODUCER`, `IMPL` | — | They produce; they evaluate nothing. |

---

## Provenance

Every artefact records the models that materially contributed to it, in a
per-story ledger. Tracked kinds: `PLAN`, `PLAN_REVIEW`, `CODE`, `QA`.

The ledger has to satisfy two properties that pull in opposite directions, and
it was wrong twice before it held both:

- **Durable** — the record must outlive the worktree, or the audit trail dies
  with the story it describes.
- **Untamperable** — it certifies that the QA agent did not write the code it is
  judging, and that agent runs *inside the worktree* with permissions skipped.

Beside the daemon locks: durable, no — the state is transient and reaped. Inside
the worktree: tamper-resistant, no — the evaluator could delete the very entry
clearing it.

So the **authoritative copy lives in daemon state**, where no phase agent can
reach it, and the **commit phase publishes a copy** into
`.gaai/project/contexts/artefacts/routing/{story}.provenance.json` once every
agent has exited. Durable because it is committed; trustworthy because its only
writer was the daemon. A file an agent leaves at the published path is
overwritten, not merged.

Harness availability goes the other way — it is daemon state, shared across
stories, meaningless once the outage clears — so it stays out of the commit.

### The record is tamper-evident, not tamper-proof

Placing the authority copy outside the worktree stops the codex harness reaching
it — that one runs under `--sandbox workspace-write`. It does **not** stop the
claude harness, which runs as the same OS user with `--dangerously-skip-permissions`
and no filesystem jail: against that, a location is not a boundary. Believing
otherwise was the original mistake, and moving the file only changed the path.

The boundary that does exist is the daemon's own memory. The daemon blocks on the
phase agent, so a value held across the spawn is unreachable by the child. The
daemon therefore **seals** the record — a digest, held only in memory — before
handing control to any agent, and verifies it the moment the agent exits, before
its own writes legitimately change the file. A mismatch fails the phase.

The seal spans **every** phase boundary, not only QA, because the attack that
matters is not the evaluator erasing its own trace. It is the implementer erasing
its CODE entry, so that QA routing sees no contributor and seats the implementer
as its own judge. That only bites when the implementer is also a QA candidate —
which happens the moment the cheap coding model is unavailable and IMPL falls back
onto one.

**What this does not close, stated because an invariant that hides its limits is
not absolute:** this detects rather than prevents, so a tampered record costs a
failed story rather than a laundered verdict — acceptable. But detection cannot
distinguish *altered* from *broken*: an agent that corrupts the record in a way
that also looks like infrastructure failure gets the same outcome as a disk error.
And a record altered before the daemon process started — across a crash-recovery
boundary — was never sealed by that process and cannot be checked against
anything.

Two entries are the **same contributor** when they name the same registry alias
*or* the same concrete model. Matching on the concrete model as well is what
keeps the invariant intact when two aliases are pointed at one underlying model
by a config edit, or when the same model is reachable through two harnesses.

A different context window, run, session, harness invocation, or effort level is
**not** a different author.

Contributions accumulate and never replace each other. If a model produces an
artefact and another later modifies it, both are contributors.

A contribution is recorded once the artefact exists, not at selection time — a
model that was picked and then died produced nothing, and retiring it from later
evaluation roles for free would only shrink the eligible pool.

Contributors outside the registry (a story pinned to a secondary provider, say)
are recorded by concrete model under an `external:` alias. The exclusion still
holds, and still holds if that model is added to the registry later.

### PLAN remediation

If B rejects A's plan and A remediates using B's feedback, B has shaped the plan
it would be validating. So the final verification goes to a third model:

```
A -> PLAN v1        (contributor: PLAN)
B -> FAIL + feedback (contributor: PLAN_REVIEW)
A -> PLAN v2
C -> final verification    # excludes PLAN and PLAN_REVIEW contributors
```

The engine expresses this as `--pass final_verification`, which widens the
exclusion set with `PLAN_REVIEW`. It is policy, not configuration — the config
cannot switch it off.

---

## Availability

Harness state is tracked independently of the models on it:

```
AVAILABLE    QUOTA_EXHAUSTED    UNAVAILABLE
```

Resolution order: an env pin (`GAAI_HARNESS_STATUS_<HARNESS>`) → a recorded
status file, where `QUOTA_EXHAUSTED` expires on its TTL so a spent quota heals
itself → a PATH probe for the harness binary.

The daemon parks a harness automatically when a failed phase shows it is
unusable. Only structured evidence counts: a phase log carries everything the
agent said, read and ran, and an agent working on rate limiting writes "429"
and "rate_limit" all day without the provider refusing a single request. Free
text inside assistant, user or tool-result content is never read. What is,
cheapest and most reliable first, all of it configuration (`quota_detection`):

1. **How the session ended** — the final `result` event. A session that ended
   on one of its own ceilings (max turns, max spend) was being answered right
   up to the cap: it is not out of budget, and that verdict outranks anything
   the log said on the way there. It neither parks the harness nor counts
   toward the breaker.
2. **The provider's last verdict** — the most recent `rate_limit_event`, when
   its status is not one under which the provider still serves. It carries the
   reset time, so it beats every message-based hint.
3. **The last error the harness raised**, and the terminal result when it is
   itself an error — a structured `code`/`type`/status field listed in `codes`
   first, then the provider's own message matched case-insensitively against
   `signatures`. Deliberately narrow: a generic 5xx or a timeout is not a quota
   signal, and mis-parking a harness costs real capacity.
4. **A consecutive-failure circuit breaker**, which is what makes the first
   three optional.

That last layer is the point. A provider can reword its error, ship it
localised, or fail in a way nobody anticipated — and a harness that keeps
failing is unusable whether or not we can explain why. After a configured run of
consecutive failed phases the harness is parked regardless of cause, and any
success clears the count so unrelated stories never accumulate into a park.

Not every harness emits a structured code today: one CLI's exec stream carries
only `{type, message}` with human prose, which is exactly why the message layer
exists and why the breaker is the one that has to hold. The code path costs
nothing and wins the day it becomes available.

When the provider states when it will resume, that beats the flat backoff. A
one-hour default park against a reset a day and a half out would wake the
harness dozens of times, each waking costing a real phase spawn to fail exactly
the same way. Parks are clamped to a minute at the low end and a week at the
high end, so a misparse can neither churn nor silently retire a provider.

```bash
# after a FAILED phase; exit 0 = parked, 1 = left in rotation
delivery-router.mjs harness-observe --harness codex --log <phase-log>

# after a SUCCESSFUL phase; clears the failure count
delivery-router.mjs harness-success --harness codex
```

Every park expires. Nothing in this system retires a provider permanently, and a
total outage degrades rather than deadlocks: roles that evaluate nothing fall
back to their legacy model and the pipeline keeps moving, while roles that
evaluate block as `AVAILABILITY` — retryable, not a failed story.

> Match the signatures against a real failure, not against remembered phrasing.
> The first version of this detection looked for `usage limit reached` while the
> provider actually says *"You've hit your usage limit"* — so a spent quota went
> undetected and every phase kept spawning against a dead harness. The captured
> wording is now a test fixture.
>
> And match them only against what the harness raised, never against what the
> model wrote. The second version ran the signatures over the whole log tail and
> parked a healthy harness for an hour: the story under review was about rate
> limiting, so the agent's own transcript contained every signature word, while
> the session had actually ended on its turn cap. That transcript is now a test
> fixture too.

### Harness features

A harness declares what it can carry (`features` in the config). A step that
will be handed an MCP server config asks for `--require-feature mcp`, and
candidates on a harness that does not declare it are skipped.

This exists because routing must not quietly cost an agent its tools. The
daemon's `codex exec` invocation passes no `--mcp-config`, so `codex` does not
declare `mcp`; a plan or QA phase that needs the GAAI toolset therefore stays on
a harness that can carry it, instead of running tool-blind on a nominally better
model. Add `"mcp"` to the harness's `features` once its spawn carries a server
config.

### Three ways a candidate can be passed over

| Kind | Examples | Action |
|---|---|---|
| Availability | quota exhausted, rate limited, outage, harness missing, technical failure | try the next candidate |
| Eligibility | the candidate contributed to what is being evaluated | try the next candidate — **absolute**, never relaxed |
| Capability | could not complete the task, unresolved ambiguity, insufficient result | try the next eligible candidate, raising effort where appropriate |

---

## Reasoning effort

Default `high`. `xhigh` only when more thinking is the actual remedy:

- the Delivery is marked HIGH_RISK
- the previous eligible model failed on capability rather than infrastructure
- a reviewer returned ESCALATE
- critical ambiguity remains unresolved
- the task is unusually complex or long-horizon

Each harness declares in config how effort is expressed — extra argv or
environment variables — so the engine never learns a CLI flag. Today that is
`--effort <level>` on the Claude CLI and a `-c model_reasoning_effort=<level>`
config override on Codex. A level the model does not declare is clamped rather
than sent blind.

Setting it explicitly on every routed call matters more than it looks: the Codex
CLI's own default reasoning level is `low`, so a call that says nothing about
effort silently runs shallow.

Raising effort does not change model identity for provenance.

---

## Verdict aggregation

Deterministic, with no model invoked to reinterpret verdicts:

```
any required lane FAIL        -> FAIL
else any lane ESCALATE        -> ESCALATE
else all required lanes PASS  -> PASS
```

A required lane that did not report is `ESCALATE`, never an implicit pass — an
unevaluated lane is unknown, and unknown is what a human is for.

---

## CLI

```bash
node .gaai/core/scripts/lib/delivery-router.mjs doctor
```

Validates the config, prints live harness state, and — the part worth running
after every registry edit — **simulates the nominal pipeline with every provider
healthy, then once per provider with that provider removed**:

```
--- all_available ---     PLAN_PRODUCER -> …  PLAN_REVIEWER -> …  IMPL -> …  QA_* -> …
--- without_<provider> -- … or "BLOCKED <class>"
```

Structural shortages are invisible while everything is healthy: they surface the
first time a provider is down, on a real story, at whatever hour that happens.
The simulation moves that discovery to config time. A scenario with any blocked
role is reported as a warning, and the test suite asserts that losing any single
provider still serves the whole pipeline.

```bash
# Which model may run this step? exit 0 = selected, 3 = blocked
delivery-router.mjs select --role QA_CODE --story {story-id} --format sh

# Record what actually contributed
delivery-router.mjs record --story {story-id} --artifact CODE --model-id claude_worker

# Who is barred from evaluating what
delivery-router.mjs contributors --story {story-id}

# Park a provider whose quota is spent (TTL from config)
delivery-router.mjs harness-status set --harness codex --status QUOTA_EXHAUSTED

# Aggregate lane verdicts
delivery-router.mjs aggregate --lane QA_CODE=PASS --lane QA_REQUIREMENTS=FAIL
```

---

## Daemon integration

| Phase | Role asked for | On `BLOCKED_NO_ELIGIBLE_MODEL` |
|---|---|---|
| `handle_plan_phase` | `PLAN_PRODUCER` | Produces nothing to evaluate — degrade to the legacy default model and continue. |
| `handle_impl_phase` | `IMPL` (skipped on the secondary-provider route, which is its own governed opt-in) | Same — degrade and continue. |
| `handle_qa_phase` | `QA_PLAN` | Fail closed. `PROVENANCE` / `CAPABILITY_FLOOR` / `CONFIG` are structural and mark the story failed for a human; `AVAILABILITY` leaves the phase alone so the next cycle retries after the backoff. |

QA runs as a single agent today, and that agent covers all three lanes at once:
it judges the implementation, the Story acceptance criteria, and conformity to
the governed PLAN. Its independence requirement is therefore the union of the
three lanes' exclusions — which is exactly `QA_PLAN`. When the lanes are split
into separate spawns, each simply asks the router for its own role; no engine
change is required.

The router may place a single phase on a harness other than the daemon-wide
executor (plan on one, impl on another). `GAAI_PHASE_HARNESS` carries that
per-call choice into the executor switch.

---

## Environment

| Variable | Effect |
|---|---|
| `GAAI_MODEL_ROUTING=0` | Disables routed selection; phases keep their legacy fixed model. Forfeits the independence guarantee. |
| `GAAI_ROUTING_CONFIG` | Path to a routing config, highest precedence. |
| `GAAI_PROVENANCE_DIR` / `GAAI_PROVENANCE_PATH` | Override where ledgers live. By default they are bound into the story's worktree artefact tree so they are committed. |
| `GAAI_HARNESS_STATUS_DIR` | Where harness state files live. |
| `GAAI_HARNESS_STATUS_<HARNESS>` | Pins a harness state (`AVAILABLE`, `QUOTA_EXHAUSTED`, `UNAVAILABLE`). |
| `GAAI_MODEL_DISABLE` | Comma-separated registry aliases to take out of service. |
| `GAAI_PHASE_HARNESS` | Per-call harness for one phase spawn; set by the phase handlers from the routed pick. |
| `GAAI_PLAN_MODEL`, `GAAI_QA_MODEL` | Operator pins that skip candidate ordering for that phase. A QA pin is still checked against provenance: a pin naming a contributor — under any spelling the registry knows, or any spelling it does not — stops the phase. |

---

## Deliberately not in V1

Dynamic multi-factor scoring, cost/latency optimisation, predictive model
reliability, contamination-cost optimisation, reserving models for future QA
lanes, provider-diversity scoring, whole-pipeline global optimisation.

The durable architecture is roles, capabilities, availability, provenance,
eligibility, and ordered fallbacks — not today's model names.

---

## Tests

```bash
bash .gaai/core/scripts/tests/delivery-router.test.sh          # engine behaviour
bash .gaai/core/scripts/tests/delivery-routing-shim.test.sh    # bash ↔ Node handoff
```
