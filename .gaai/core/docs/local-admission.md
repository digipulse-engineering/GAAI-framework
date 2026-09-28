# Local admission and lifecycle applicability

Local admission executes the target project's base-held selector policy before semantic QA
(`pre_qa`) and again before publication (`final`). Only a current final PASS sets
`publication_admitted: true`. Local admission never grants merge authority or replaces hosted CI.

By default, any changed binding invalidates execution evidence. A project may explicitly opt in
to preserving selected passing executions when another Story's lifecycle bookkeeping advances
the base during that same invocation. This is one forward reconciliation, with unchanged candidate
HEAD and a clean worktree. A new attempt, a different Story or the final boundary after pre-QA always
executes its own checks; no persisted receipt is an execution cache.

## Project opt-in

Create `.gaai/project/ci/local-admission-applicability.json` through the project's human-reviewed
trust-policy process. The closed schema is:

```json
{
  "schema_version": "1.0.0",
  "repository": {
    "project_id": "example/project",
    "remote": "https://example.invalid/example/project.git",
    "base_ref": "staging"
  },
  "backlog_path": ".gaai/project/contexts/backlog/active.backlog.yaml",
  "rows_key": "items",
  "identity_key": "id",
  "lifecycle_fields": ["status", "phase_status"],
  "reusable_command_ids": ["unit"],
  "trust_registry_path": ".gaai/project/ci/premerge-authority.json"
}
```

Repository identity must exactly match the selector policy. Paths and identifiers are literal;
wildcards, traversal, symlinks, submodules, unknown keys, duplicate keys and unresolved command IDs
are rejected. Fields designate existing scalar values, not write permissions. Choose reusable
commands only when the project has established their independence from these lifecycle changes.

The existing project trust-registry format contains `schema_version`, `repository` (`id`,
`full_name`, `base_ref`), `workflow` (`id`, `path`, `name`, `event`), `required_job` and
`covered_paths`. It must cover itself, the selector, authority workflow, applicability policy and
these admission files in `.gaai/core/scripts/lib/`: `local-admission.sh`,
`local-admission-resolver.mjs`, `local-admission-executor.mjs`, `local-admission-applicability.mjs`.
Existing controller coverage must remain in place.

The opt-in, selector and trust registry must be byte-identical regular Git blobs in the original
base, new base and candidate. An implementation PR cannot enable itself: both opt-in and coverage
must already have landed through human review before a later candidate can use them. Removal of
the opt-in restores ordinary stale rejection; retain the trust coverage when disabling reuse.
No process restart, deployment or historical PASS follows from adding the policy.

The admission implementation, watcher and complete verifier closure must also be regular blobs
with identical identities in both bases and the candidate. Live proof checks these against the
executing implementation. A candidate upgrading any member therefore cannot authorize itself for
reuse. Human-reviewed landing establishes compatibility before a later candidate opts in.

## Proof and supported grammar

The proof checks a strict fast-forward base advance and its complete immutable Git delta. Only
the declared backlog may change, without a mode change. The trusted, attested YAML runtime parses
one document, rejecting anchors, aliases, directives, explicit tags, merge keys, duplicate keys
and duplicate Story IDs. Mapping keys must be strings. Ordered existing row IDs, keys and all
non-lifecycle structure must remain unchanged, including the admitted Story's entire row.

Only scalar-value replacement in listed fields of other rows is supported. Key insertion/removal,
row insertion/removal/reordering, collection-valued lifecycle fields, comments and formatting
outside approved scalar spans are rejected. The source bytes outside those spans are compared as
well as parsed structure. This intentionally conservative grammar may reject benign bookkeeping;
it never infers that arbitrary metadata is irrelevant.

Candidate, dependency, risk, environment, policy/selector, ordered commands and selected surfaces
must match. Every initial result must be complete and passed with exit code zero and no signal.
Descriptor, configuration, materialized argv, timeout, output policy and environment pass-through
identities must match for each reused execution. A listed command whose actual argv changes
(for example a `{base_sha}` argument) executes again on the fresh plan. Every unlisted command
also executes fresh. Failed, cancelled and timed-out refreshes remain non-authorizing.

A base backlog update can add a governance surface to the candidate's endpoint diff. If that
surface or its command was absent initially, reconciliation rejects the changed selection. A
governed candidate that already includes code and project implementation evidence can retain
the same code/governance selection and qualify. Applicability never widens the selected command
set or ignores a newly selected surface.

The helper uses the selector's existing `max_policy_bytes`, `max_diff_bytes`, `max_result_bytes`
and `max_receipt_bytes` containment limits. Overflow fails closed without truncating evidence into
a PASS. The YAML vendor tuple and interpreter attestation are unchanged.

## Receipts and retained diagnostics

Each gate creates an opaque invocation ID. Executions record their own ID, binding digest and
materialized argv digest. A reconciled receipt preserves the complete original binding/results,
their digest, the current candidate, applicability proof and exact result provenance. Old results
are not rewritten with the new base. The sealer independently re-derives applicability from Git,
validates original and refreshed result vectors, and verifies the proof before composing the receipt.
Receipts contain identifiers, digests, counts and outcomes, never command output or environment values.

Two closed wire variants are supported. Ordinary `1.0.0` keeps its original top-level and result
keys exactly: invocation/execution metadata stays internal and is omitted only from the newly
serialized legacy projection. Composite `2.0.0` adds `invocation_id`, `resolution_inputs`,
`original_execution`, `refreshed_execution`, `applicability` and `provenance`. Both execution
envelopes bind their complete actual result vectors and digests; current results are exact references
by value to the corresponding original or fresh records. Unknown versions, unknown nested keys,
duplicate keys and invalid composites reject, never downgrade to ordinary evidence.

### Terminal verification

Ordinary final receipts retain the existing ancestry and tree rules: the admitted base is an
ancestor of candidate HEAD, and the external squash has that base as its sole parent and exactly
the candidate's complete tree.

A composite can have sibling lineages: original base B0 is an ancestor of unchanged candidate H
and refreshed base B1, while B1 need not be an ancestor of H. Only a fully validated composite uses
the alternate rule. Its external squash must have B1 as its sole parent, the authoritative PR head
must be H, and its entire tree must equal H with exactly the already-proved B0-to-B1 scalar delta
applied. The verifier checks each original raw scalar and interpretation against H, applies the
replacement spans without YAML serialization, and preserves all other bytes, paths, modes, types
and object identities. Unicode offsets remain in one code-point domain until the result is encoded.
Conflicting values, missing fields, omitted or extra changes and alternate serialization reject.

Historical verification reads immutable Git objects and recorded bindings. It re-derives command,
configuration, dependency, risk, selector and delta identities without calling live admission or
requiring the observer's checkout/environment to equal the old execution. Historical environment
digests prove continuity only; they do not claim to recreate past secrets or process facts.
The same descriptor-bound receipt buffer drives parsing, digest validation, proof and settlement.

The watcher materializes its complete helper closure from the current configured-target commit:
the scheduler, executor, applicability and resolver modules, test-gate library, YAML boundary and
the attested YAML vendor tuple. Relative paths are preserved in a private directory, files are
created exclusively and read back from retained descriptors, and unsafe/missing helpers fail closed.
No candidate or ambient module fallback is available. PR identity and chronology, repeated external
observation, target lineage, receipt descriptor revalidation, locking and settlement CAS still apply.
This read-only integration proof grants no merge authority and does not claim integration-tree CI.

Old readers accept newly produced ordinary `1.0.0` but reject composite `2.0.0`. New readers accept
ordinary receipts and only fully verified composites. During rollback, disable new opt-in through
human review, keep trust coverage and preserve a compatible reader for outstanding composite
attempts; an old reader's refusal is safe but is not successful terminalization.

Immediately after sealing, the gate fetches and resolves again. Further movement, a dirty worktree
or an unavailable currentness check blocks without a second reconciliation loop. Original execution
facts and available refreshed results are retained beside receipts in an owner-only file named
`.local-admission-<story>-<boundary>-<invocation>.blocked.json`. Its envelope explicitly says
`current: false`, `publication_admitted: false` and a blocked outcome. The conventional receipt is
atomically replaced with non-authorizing evidence, and the returned current-receipt pointer is empty.
An in-flight marker is removed on exit. Persistence failure itself blocks with
`blocked:evidence_persistence_failed`; it never claims that diagnostics were retained.

The proof's closed rejection reason distinguishes absent opt-in (`opt_in_missing`), changed inputs,
non-fast-forward base, untrusted policy/registry, mixed base delta, YAML ambiguity, non-lifecycle
changes and non-scalar byte changes. YAML runtime availability/integrity errors remain typed.
These details explain `blocked:stale_evidence`; they do not authorize publication or automatic retry.
