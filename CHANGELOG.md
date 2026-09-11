# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Changed
- fix: preserve an interrupted implementation attempt as a commit
- fix: quarantine an unsettleable Story at startup instead of halting
- fix: bound the working-memory file at the size that actually harms
- fix: let the operator's turn ceiling govern the implementation phase
- fix: derive the monitor's worktree root from the home it is given
- fix: reuse a valid plan artefact instead of re-running the agent
- fix: let the operator's turn cap govern the plan phase
- fix: make the wrapper's staging-lock ceiling reachable
- fix: link a file-backed executor credential into the private HOME
- fix: show the monitor the worktree root the lifecycle proved
- fix: let the plan artefact decide the plan phase, not the exit code
- fix: link the operator's agent account state into the private HOME
- fix: re-bind the launch target after the daemon's own claim
- fix: let the recovery scan skip a Story it does not own
-: carry the admitted forge identity to the daemon over the attempt's bound channel
- fix: close every interactive git/gh prompt path under the daemon and type the fetch failure
-: fix real daemon bootstrap after exact-home admission

## [2.49.0] - 2026-09-08

### Changed
- feat: consume a dedicated forge credential instead of the operator config
- fix: reset the private root helper chain so no keychain store is attempted
- fix: provision the private HOME's credential path instead of inheriting it
- ci(test-gate): gate the daemon home suites on a macOS Bash 3.2 lane
- follow-up: fix the usage cheat-sheets PR 3179 left self-contradicting
- follow-up: make the operator command surfaces describe the launcher that exists
- follow-up: fix the daemon launcher's Darwin descriptor identity and prove the loader outcome
- follow-up: remove the unproven Bash 3.2 expansion and pin the floor in a test
- chore: honor external worktree roots
- fix: keep local admission portable across Bash versions
- fix: make delivery daemon mktemp templates portable


## [2.50.0] - 2026-08-21

### Changed
- feat: execute local checks and seal exact-candidate receipts
- fix: contain repeated commit-phase churn
-: stop deterministic hosted-authority retry loops
- feat: add base-held local admission resolver
- fix: recognize symlinked router invocation
- fix: seal the provenance record across every agent spawn
- fix: blocking classification is SOTA-only, not for plan-conformance findings
- fix: settle what the blocked state may do, from the transitions actually made


## [2.49.0] - 2026-08-21

### Changed
- feat: execute local checks and seal exact-candidate receipts
- fix: contain repeated commit-phase churn
-: stop deterministic hosted-authority retry loops
- feat: add base-held local admission resolver
- fix: recognize symlinked router invocation
- fix: seal the provenance record across every agent spawn
- fix: blocking classification is SOTA-only, not for plan-conformance findings
- fix: settle what the blocked state may do, from the transitions actually made
- fix: the evaluator could edit the record clearing it
- fix: repoint repository identity after transfer to digipulse-engineering


## [2.51.0] - 2026-08-20

### Changed
- feat: role-based model routing with provenance-enforced independence
- feat: catch registry rows that break the pointer cap, as they are added
- docs: the remote branch may be deleted by the forge, not by hand
- docs: the post-merge cleanup clause prescribed a flag that breaks an invariant
- fix: record run identity on the handle instead of inferring it
- fix: make generated execution plans carry artefact frontmatter
- fix: keep and poll the handle until a terminal receipt
-: Make hosted CI the sole daemon merge authority


## [2.50.0] - 2026-08-18

### Changed
- feat: catch registry rows that break the pointer cap, as they are added
- docs: the remote branch may be deleted by the forge, not by hand
- docs: the post-merge cleanup clause prescribed a flag that breaks an invariant
- fix: record run identity on the handle instead of inferring it
- fix: make generated execution plans carry artefact frontmatter
- fix: keep and poll the handle until a terminal receipt
-: Make hosted CI the sole daemon merge authority


## [2.49.0] - 2026-08-17

### Changed
- feat: catch registry rows that break the pointer cap, as they are added
- docs: the remote branch may be deleted by the forge, not by hand
- docs: the post-merge cleanup clause prescribed a flag that breaks an invariant
- fix: record run identity on the handle instead of inferring it
- fix: keep and poll the handle until a terminal receipt
- fix: make generated execution plans carry artefact frontmatter


## [2.49.0] - 2026-08-11

### Changed
- feat: block pushing a hermetic test without its executable bit
- fix: gate notes.md context discipline on tier, not just route
- fix: harden the portable pre-merge proof contract
- fix: make premerge-proof.test.sh executable
- fix: make R3 describe the contract producers actually implement
- fix: support safe YAML flow lists
- fix: stop `grep -c ... || echo 0` from emitting two counts
- fix: resolve the worktree deps marker without a project path
- fix: stop daemon-state-machine reaching into the host repo
- fix: make the OSS test corpus pass on Linux and macOS
- chore: raise phase timeouts for Sonnet 5 + bound test-gate unit runs
- fix: renice test-gate subshell via $BASHPID, not $$
- fix: lower CPU priority of test-gate unit runs
- fix: stream test-gate unit output live instead of buffering
- fix: hang-detector was blind to commit-phase activity
- fix: name the entry tier Starter
- fix: correct the amended rule and the core hook after review FAIL
- test: repair 37 pre-existing daemon-state-machine failures (origin/staging fixtures)
- fix: reconcile plan-prompt EXECUTE-NOW block with sanctioned plan-blocked exits
- fix: harden plan/qa phase prompts against conversational bail


## [2.50.0] - 2026-07-23

### Changed
- fix: don't charge a retry for a graceful interrupt during planning
- feat: make plan/qa phase model configurable via GAAI_PLAN_MODEL / GAAI_QA_MODEL


## [2.49.0] - 2026-07-23

### Changed
- feat: make plan/qa phase model configurable via GAAI_PLAN_MODEL / GAAI_QA_MODEL
- fix: guard empty phase-prompt files so a transient write failure can't silently retry-cap a healthy story
- fix: raise agent-hang threshold to cover commit-phase test-gate
- fix: harden flaky-retry suffix (review follow-up)
- fix: tolerate flaky test flips via runner-native retry
- review: harden HEAD guard — surface missing tip commit as corruption (not silent-clean)
- fix: scope worktree-integrity fsck to the story HEAD (stop cross-worktree false positives)
- fix: pass pr_number as arg to _reconcile_merged_pr (fix unbound-var crash)
- review: generic executor wording in comment + same-turn background-helper nuance
- fix: inject one-shot execution-mode constraint into impl prompt
- fix: surface silent main-loop deaths via ERR/EXIT trap
- fix: guard ((x++)) increments against set -e (poll loop crash)
- fix: make EPOCHREALTIME→ms conversion locale-independent
- chore: LOC cap counts implementation LOC only — coordinated basis decision
- chore: require PR-based staging repairs
- chore: align marketing and cloud beta copy
- fix: forward codex executor into story wrappers
- fix: default routing-log model tag to claude-sonnet-5
- fix: don't escalate when auto-merge fails only at local branch-delete
- fix: branch each story from origin/<branch>, not the stale local ref


## [2.49.0] - 2026-06-29

### Changed
- feat: remove orchestrator agent and its legacy-only sub-agent files
-: 'Remove legacy-orchestrator references from the agents
-: Remove the legacy single-spawn execution path from the
- chore: remove private project refs from OSS-synced framework docs
- chore: remove private project ref (date) from OSS-synced framework doc
- docs: formalize worktree+PR+cleanup doctrine in its canonical home
- fix: support codex executor in bash daemon
- fix: show codex monitor activity
- fix: bake REPO_ROOT into the generated delivery wrapper (worktree nesting)
- fix: forward REPO_ROOT/DAEMON_HOME to the per-story delivery wrapper
- fix: instruct QA to read the ENTIRE decision incl. amendment/reword blocks
- fix: anchor operator state + worktree base to the real checkout, not the home
- fix: operator state (logs/locks) + worktree base anchor to REPO_ROOT, not the home
- fix: stop auto-merge failure commit loop
- fix: address Tier-2 review on allocator remote scan
- fix: allocator scans remote branches for in-flight IDs
- chore: commit pending framework writes to clear working-tree drift


## [2.48.0] - 2026-06-15

### Changed
- fix: add opt-in Claude proxy transport
- fix: reap orphaned worktrees of archived/terminal stories
- feat: add native Codex daemon support


## [2.45.0] - 2026-06-14

### Changed
- feat: concurrent-safe ID allocator + skill/rule wiring
- feat: add native Codex daemon support


## [2.44.0] - 2026-06-14

### Changed
- feat: concurrent-safe ID allocator + skill/rule wiring
- feat: add native Codex daemon support


## [2.47.0] - 2026-06-12

### Changed
- feat: add native Codex daemon support


## [2.46.0] - 2026-06-12

### Changed
- feat: add native Codex daemon support


## [2.45.0] - 2026-06-12

### Changed
- feat: add native Codex daemon support


## [2.44.0] - 2026-06-12

### Changed
- feat: add native Codex daemon support
- fix: reap orphaned worktree processes in the bash delivery daemon
- fix: refuse to start when home checkout drifted off target branch
- fix: raise QA phase turn cap 30→100 + GAAI_QA_MAX_TURNS knob (D1)
- fix: heal done-flip lag — reconcile merged delivery PR in the drift-skip path
- fix: scope PR-merge recovery to delivery branch — stop Discovery-PR false-done
- fix: recovery reconciles merged PR to done instead of re-delivering
- fix: prune null-HEAD worktree in reconcile (corrupt-worktree poison-pill)
- fix: RECOVERY merged-PR guard — stop infinite re-delivery of already-merged stories
- fix: raise file cap 5→10 (coordinated, validate-artefacts + Plan agent)
- fix: regression = new failure vs baseline (stop false-escalation on pre-existing red tests)


## [2.43.0] - 2026-06-01

### Changed
- feat: make commit phase robust to missing node_modules in worktree


## [2.44.0] - 2026-05-31

### Changed
- feat: make commit phase robust to missing node_modules in worktree


## [2.43.0] - 2026-05-31

### Changed
- feat: make commit phase robust to missing node_modules in worktree


## [2.42.0] - 2026-05-31

### Changed
- fix: inline canonical memory-delta schema at the production point
- feat: add stray-delta placement guard + relocate 2 strays it surfaces
- Merge pull request #1018 from Fr-e-d/story/
- chore: drift-check hook excludes memory-deltas/processed/
- fix: grandfather 21 pre-canonical memory-deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- feat: add stray-delta placement guard + relocate 2 strays it surfaces
- Merge pull request #1018 from Fr-e-d/story/
- chore: drift-check hook excludes memory-deltas/processed/
- fix: grandfather 21 pre-canonical memory-deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- fix: grandfather 21 pre-canonical memory-deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- chore: triage 4 NO-OP deltas → processed/ + skip *.draft.md in drift check
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- fix: address QA findings F1+F2 — audit-intake table fix + impl-report (, cycle 2)
- ci: trigger workflow via script touch + update audit-intake
- ci: trigger workflow re-run after delta fix
- fix: grandfather 21 pre-canonical memory-deltas + fix 3 non-conformant deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- ci: trigger workflow via script touch + update audit-intake
- ci: trigger workflow re-run after delta fix
- fix: grandfather 21 pre-canonical memory-deltas + fix 3 non-conformant deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- ci: trigger workflow via script touch + update audit-intake
- ci: trigger workflow re-run after delta fix
- fix: grandfather 21 pre-canonical memory-deltas + fix 3 non-conformant deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- fix: grandfather 21 pre-canonical memory-deltas + fix 3 non-conformant deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file


## [2.42.0] - 2026-05-31

### Changed
- fix: grandfather 21 pre-canonical memory-deltas + fix 3 non-conformant deltas (F24,)
- feat: codify adversarial review loop termination rule (audit F23)
- chore: stop leaking GAAI_IMPL_AUTH_TOKEN via tmux -e (ps-visible) — source 0600 env-file
- fix: handle_commit_phase recovers from pruned worktree (c2)


## [2.41.0] - 2026-05-29

### Changed
- feat: Discovery claim protocol — gaai-claim.sh staging-lock wrapper + backlog/staging write-coordination rule
- fix: make --strict-mcp-config opt-out via GAAI_NESTED_KEEP_MCP for Cloud variant
- fix: inject --strict-mcp-config on non-Anthropic shims to unblock GLM Impl
- fix: refine pr_watcher_tracked — exclude merged PRs + restrict to active statuses
- fix: correct pr_watcher_tracked count — was always 0
- fix: auto-resolve story-owned add/add conflicts on notes + memory-deltas + plans
- chore: activate + scaffold E170 (gaai_admin → gaai_org_admin + gaai_ws_admin)


## [2.40.0] - 2026-05-28

### Changed
- feat: memory-index-compact skill + writer-skill instruction tightening + strategic-frame.md changelog archive
- fix: reconcile-sweep uses pr_status authority + rate-limits unmerged log
- fix: cap-respect in _recovery_relaunch to prevent over-dispatch
- fix: export SCHEDULER in PR-watcher + sweep liveness check
- fix: require liveness signal (tmux OR marker) before display
- fix: infer in-flight phase from phase_status when marker absent
- fix: skip epic rows from --ready-ids and --next
- fix: commit-through accumulated wrapper drift in option-A fallback
- fix: persist pr_url to staging before auto-merge deletes branch
- chore: remove upstream-project narrative refs from skills + agents
- fix: pre-flight skip _reconcile_story_file_from_staging on missing worktree
- fix: add --delete-branch to gh pr merge calls
- fix: cycle counter read-after-delete — reuse counter at escalation, reorder at reconcile


## [2.39.0] - 2026-05-24

### Changed
- fix: observability — log format fields + marker honor metric computation
- feat: cross-cycle qa-report injection routed by replan signal

## [2.38.0] - 2026-05-23

### Changed
- feat: cross-cycle qa-report injection routed by replan signal
- fix: grant startup grace to liveness + staleness detectors
- fix: hang detector tracks max mtime across plan/impl/qa logs (not just impl)

## [2.37.0] - 2026-05-23

### Changed
- chore: Header integration + legacy retirement + daemon wiring
- feat: wire workspace-scope auth header + retire legacy binding mechanisms

## [2.36.0] - 2026-05-23

### Changed
- chore: Header integration + legacy retirement + daemon wiring
- feat: wire workspace-scope auth header + retire legacy binding mechanisms
- fix: extend suspend-grace to check_stale_in_progress

## [2.35.0] - 2026-05-23

### Changed
- feat: wire workspace-scope auth header + retire legacy binding mechanisms
- fix: suspend/resume robustness — suppress liveness kills after host wake

## [2.34.0] - 2026-05-19

### Changed
- feat: self-commit .github/ marker + log to eliminate dirty-tree pause
- fix: stop monitor terminal stealing keyboard focus on restart
- fix: workspace-scope check detects GAAI MCP server presence (not bare .mcp.json existence)
- chore: plan done
- fix: wire notify_escalation_inline on handle_qa_phase ESCALATE path
- fix: unblock retry-loop + wire escalation notification
- fix: auto-merge staging-restricted policy check evaluates TARGET_BRANCH, not story HEAD
- fix: remove 'local' outside function (line 633)
- fix: auto-resolve PR conflicts post-create

## [2.33.0] - 2026-05-15

### Changed
- fix: periodic orphan-lock detection during polling (recovery hardening)
- feat: flip auto-merge policy env default off → staging-restricted
- Revert "feat: extract blueprint + tool-adapter + capability provider packages + LLM Routing"

## [2.33.0] - 2026-05-14

### Changed
- feat: flip auto-merge policy env default off → staging-restricted
- Revert "feat: extract blueprint + tool-adapter + capability provider packages + LLM Routing"
- fix: add flock to fallback path — serialize concurrent wrapper close-outs
- chore: done [manual recovery] — daemon-staleness with state corruption
- fix: phase-aware in-loop staleness check — resume recoverable phases via _recovery_relaunch
- fix: durable + robust YAML serialization symmetry (ghost in-progress state)

## [2.32.0] - 2026-05-13

### Changed
- feat: migrate 10 inline regex read-sites to backlog helper

## [2.31.0] - 2026-05-13

### Changed
- feat: source backlog helper in daemon + 2 wrappers
- feat: backlog helper + 3 low-fan-out consumer migrations (yq migration)

## [2.30.0] - 2026-05-13

### Changed
- feat: yq helper lib + 3 low-fan-out consumer migrations

## [2.29.0] - 2026-05-13

### Changed
- feat: yq helper lib + 3 low-fan-out consumer migrations

## [2.28.0] - 2026-05-13

### Changed
- feat: implement QA-retry-loop in OSS bash daemon
- chore: Backlog YAML helper introduction + low-fan-out consumers

## [2.27.0] - 2026-05-13

### Changed
- feat: yq helper lib + 3 low-fan-out consumer migrations

## [2.26.0] - 2026-05-13

### Changed
- feat: close plan-block stalls — Discovery gate mirrors Plan caps + wrapper auto-reconcile
- fix: strip scheduler --set-field quotes in Active Deliveries detection
- fix: transactional fallback path — rollback disk on commit/push failure
- fix: regex match quoted status (status: "in_progress") post-scheduler auto-quote
- fix: disable yq path, force fallback path (preserves formatting)
- fix: replace strict line-count drift check with block-scope check
- fix: correct chore_commit_field signature + export env vars in reconcile subshell
- fix: correct function name _chore_commit_field → chore_commit_field
- fix: remove invalid 'local' keyword outside function scope

## [2.23.0] - 2026-05-11

### Changed
- fix: salvage daemon recovery + metadata commit hardening (test suite)
- fix: truncate retry counters at startup (session-scoped contract)
- feat: review-input mandates transitive reads on cited DECs (linked_research + lifecycle)
- fix: bump PLAN/QA max-turns + filter epic IDs in recovery scans
- chore: register cutover as draft + REFINE findings logged
- chore: supersedes — restore secondary as route selector default
- feat: remove secondary route hard-gate + reset 2 ghost stories
- fix: YAML inline-comment stripping in 5 awk extractors
- chore: align scope enumeration + split closing clauses for readability
- chore: add default collaboration stance + scope ambiguity escalation
- feat: graceful drain on stop + docstring naming fix
- fix: tighten watchdog poll granularity
- fix: harden 3-phase pipeline — livelock, heartbeat, status, timeouts
- chore: teach drift hook + sync skill about sibling index-*.md registries
- fix: memory-alignment-check template adds 'artefact_type: memory-delta' + done
- fix: capture git push stderr for diagnostic visibility
- fix: propagate TARGET_BRANCH to 3-phase wrapper subshell + reset /S02a to QA-ready
- fix: tolerate plan filename variation — auto-rename .plan.md to canonical .execution-plan.md
- fix: prevent higher-tier + secondary route landmine
- fix: heartbeat checks 3-phase per-phase logs (was killing wrappers)
- fix: detect_active_stories emits 3-phase stories post primary path
- fix: wrapper must source dispatch.sh without pipe (function defs)
- feat: launch 3-phase pipeline in dedicated tmux session
- feat: — tier-aware default route selector = primary for tier-2
- feat: hard-gate tier-2 stories on secondary route
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K
- feat: admin-fallback for auto-merge on free-tier
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics
- chore: commit pending wrapper phase_status updates (+)

## [2.25.0] - 2026-05-11

### Changed
- fix: salvage daemon recovery + metadata commit hardening (test suite)
- fix: truncate retry counters at startup (session-scoped contract)
- feat: review-input mandates transitive reads on cited DECs (linked_research + lifecycle)
- fix: bump PLAN/QA max-turns + filter epic IDs in recovery scans

## [2.24.0] - 2026-05-09

### Changed
- feat: review-input mandates transitive reads on cited DECs (linked_research + lifecycle)
- fix: bump PLAN/QA max-turns + filter epic IDs in recovery scans
- chore: register cutover as draft + REFINE findings logged

## [2.23.0] - 2026-05-09

### Changed
- chore: supersedes — restore secondary as route selector default
- feat: remove secondary route hard-gate + reset 2 ghost stories
- fix: YAML inline-comment stripping in 5 awk extractors
- chore: align scope enumeration + split closing clauses for readability
- chore: add default collaboration stance + scope ambiguity escalation
- feat: graceful drain on stop + docstring naming fix
- fix: tighten watchdog poll granularity
- fix: harden 3-phase pipeline — livelock, heartbeat, status, timeouts
- chore: teach drift hook + sync skill about sibling index-*.md registries
- fix: memory-alignment-check template adds 'artefact_type: memory-delta' + done
- fix: capture git push stderr for diagnostic visibility
- fix: propagate TARGET_BRANCH to 3-phase wrapper subshell + reset /S02a to QA-ready
- fix: tolerate plan filename variation — auto-rename .plan.md to canonical .execution-plan.md
- fix: prevent higher-tier + secondary route landmine
- fix: heartbeat checks 3-phase per-phase logs (was killing wrappers)
- fix: detect_active_stories emits 3-phase stories post primary path
- fix: wrapper must source dispatch.sh without pipe (function defs)
- feat: launch 3-phase pipeline in dedicated tmux session
- feat: — tier-aware default route selector = primary for tier-2
- feat: hard-gate tier-2 stories on secondary route
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K
- feat: admin-fallback for auto-merge on free-tier
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.26.0] - 2026-05-08

### Changed
- feat: remove secondary route hard-gate + reset 2 ghost stories

## [2.25.0] - 2026-05-08

### Changed
- feat: remove secondary route hard-gate + reset 2 ghost stories
- fix: YAML inline-comment stripping in 5 awk extractors
- fix: YAML inline-comment stripping in 5 extractors + reset
- chore: align scope enumeration + split closing clauses for readability

## [2.24.0] - 2026-05-08

### Changed
- chore: add default collaboration stance + scope ambiguity escalation
- feat: graceful drain on stop + docstring naming fix

## [2.24.0] - 2026-05-08

### Changed
- feat: graceful drain on stop + docstring naming fix
- fix: tighten watchdog poll granularity
- fix: harden 3-phase pipeline — livelock, heartbeat, status, timeouts
- chore: teach drift hook + sync skill about sibling index-*.md registries

## [2.23.0] - 2026-05-08

### Changed
- fix: memory-alignment-check template adds 'artefact_type: memory-delta' + done
- fix: capture git push stderr for diagnostic visibility
- fix: propagate TARGET_BRANCH to 3-phase wrapper subshell + reset /S02a to QA-ready
- fix: tolerate plan filename variation — auto-rename .plan.md to canonical .execution-plan.md
- fix: prevent higher-tier + secondary route landmine
- fix: heartbeat checks 3-phase per-phase logs (was killing wrappers)
- fix: detect_active_stories emits 3-phase stories post primary path
- fix: wrapper must source dispatch.sh without pipe (function defs)
- feat: launch 3-phase pipeline in dedicated tmux session
- feat: — tier-aware default route selector = primary for tier-2
- feat: hard-gate tier-2 stories on secondary route
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K
- feat: admin-fallback for auto-merge on free-tier
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.23.0] - 2026-05-07

### Changed
- fix: capture git push stderr for diagnostic visibility
- fix: propagate TARGET_BRANCH to 3-phase wrapper subshell + reset /S02a to QA-ready
- fix: tolerate plan filename variation — auto-rename .plan.md to canonical .execution-plan.md
- fix: prevent higher-tier + secondary route landmine
- fix: heartbeat checks 3-phase per-phase logs (was killing wrappers)
- fix: detect_active_stories emits 3-phase stories post primary path
- fix: wrapper must source dispatch.sh without pipe (function defs)
- feat: launch 3-phase pipeline in dedicated tmux session
- feat: — tier-aware default route selector = primary for tier-2
- feat: hard-gate tier-2 stories on secondary route
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K
- feat: admin-fallback for auto-merge on free-tier
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.23.0] - 2026-05-06

### Changed
- fix: prevent higher-tier + secondary route landmine
- fix: heartbeat checks 3-phase per-phase logs (was killing wrappers)
- fix: detect_active_stories emits 3-phase stories post primary path
- fix: wrapper must source dispatch.sh without pipe (function defs)
- feat: launch 3-phase pipeline in dedicated tmux session
- feat: — tier-aware default route selector = primary for tier-2
- feat: hard-gate tier-2 stories on secondary route
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K
- feat: admin-fallback for auto-merge on free-tier
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.23.0] - 2026-05-06

### Changed
- feat: launch 3-phase pipeline in dedicated tmux session
- feat: — tier-aware default route selector = primary for tier-2
- feat: hard-gate tier-2 stories on secondary route
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K
- feat: admin-fallback for auto-merge on free-tier
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.27.0] - 2026-05-06

### Changed
- feat: — tier-aware default route selector = primary for tier-2

## [2.26.0] - 2026-05-06

### Changed
- feat: hard-gate tier-2 stories on secondary route

## [2.25.0] - 2026-05-06

### Changed
- feat: default route selector = secondary
- fix: reset compaction-window env from 229K to 200K

## [2.24.0] - 2026-05-06

### Changed
- feat: admin-fallback for auto-merge on free-tier

## [2.23.0] - 2026-05-06

### Changed
- feat: forward auto-merge policy env to tmux session
- fix: strengthen R1 R3 R6 wording + promote R7 Bash bounding
- fix: strengthen R4 chunked retrieval (mandatory wording + workflow)
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.23.0] - 2026-05-05

### Changed
- fix: generate-stories step 12 mandates phase_status + delivery_pipeline fields
- feat: bump compaction-window env 200K → 229K + opt-in secondary
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.25.0] - 2026-05-05

### Changed
- feat: bump compaction-window env 200K → 229K + opt-in secondary

## [2.24.0] - 2026-05-05

### Changed
- feat: — flip route selector default to primary (pre-PMF cost-reliability)

## [2.23.0] - 2026-05-05

### Changed
- feat: — flip route selector default to primary (pre-PMF cost-reliability)
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.23.0] - 2026-05-04

### Changed
- fix: forward GAAI_IMPL_* env vars to tmux session
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics

## [2.25.0] - 2026-05-04

### Changed
- feat: scoped URL + .mcp.json single source of truth
- fix: revert orchestrator pattern + adopt scope discipline doctrine
- fix: tighten orchestrator triggers — empirically derived

## [2.24.0] - 2026-05-03

### Changed
- feat: impl orchestrator pattern — Task delegation on long stories
- fix: explicit skill-path resolution to prevent guess-loop
- fix: QA base_ref defaults to origin/$TARGET_BRANCH not main
- fix: mandatory HANDOFF section + advance to implemented
- fix: route-aware impl prompt — slim path refs for secondary
- fix: mktemp templates without .md suffix (macOS BSD mktemp)
- fix: pass worktree_path as cwd to all claude -p children
- fix: pre-compute SECONDARY_ROUTE before impl prompt build
- fix: correct misdiagnosis + worktree-scope audit
- fix: pass --dangerously-skip-permissions to plan + qa spawns
- fix: loop breaker + no-heredoc steering across phase prompts

## [2.23.0] - 2026-05-03

### Changed
- feat: show story title alongside id in active deliveries
- fix: rotate per-phase log before retry to avoid cumulative metrics
- fix: clean per-phase metrics rendering during active runs
- fix: detect 3-phase active deliveries via .active markers
- fix: handle_plan_phase computes worktree path + creates worktree
- fix: set -u safe array expansion in 5 routing record emitters
- fix: remove example story ID from daemon-prompt-construct.sh comment
- fix: remove private project refs from generate-stories §12 rationale

## [2.22.0] - 2026-05-01

### Changed
- chore: clarify generate-stories §12 draft→refined lifecycle (/S04 incident)
- fix: sub-agent / spawned model wins in display
- fix: remove --log-file flag from nested-claude-spawn invocation
- fix: filter raw NDJSON lines from top banner
- chore: reconcile stale in_progress + add GLM baseline analyzer
- fix: preamble fires on env-driven default secondary routing
- feat: observe-secondary.sh — live R1-R5 compliance + outcomes
- fix: cap activity line at 280 chars to prevent heredoc flooding
- feat: NOTES.md self-bootstrapping + artefact-first-class path
- feat: upgrade GLM context-discipline preamble per Anthropic guidance
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.22.0] - 2026-04-30

### Changed
- fix: sub-agent / spawned model wins in display
- fix: remove --log-file flag from nested-claude-spawn invocation
- fix: filter raw NDJSON lines from top banner
- chore: reconcile stale in_progress + add GLM baseline analyzer
- fix: preamble fires on env-driven default secondary routing
- feat: observe-secondary.sh — live R1-R5 compliance + outcomes
- fix: cap activity line at 280 chars to prevent heredoc flooding
- feat: NOTES.md self-bootstrapping + artefact-first-class path
- feat: upgrade GLM context-discipline preamble per Anthropic guidance
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.22.0] - 2026-04-30

### Changed
- fix: filter raw NDJSON lines from top banner
- chore: reconcile stale in_progress + add GLM baseline analyzer
- fix: preamble fires on env-driven default secondary routing
- feat: observe-secondary.sh — live R1-R5 compliance + outcomes
- fix: cap activity line at 280 chars to prevent heredoc flooding
- feat: NOTES.md self-bootstrapping + artefact-first-class path
- feat: upgrade GLM context-discipline preamble per Anthropic guidance
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.22.0] - 2026-04-30

### Changed
- chore: reconcile stale in_progress + add GLM baseline analyzer
- fix: preamble fires on env-driven default secondary routing
- feat: observe-secondary.sh — live R1-R5 compliance + outcomes
- fix: cap activity line at 280 chars to prevent heredoc flooding
- feat: NOTES.md self-bootstrapping + artefact-first-class path
- feat: upgrade GLM context-discipline preamble per Anthropic guidance
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.23.0] - 2026-04-30

### Changed
- feat: observe-secondary.sh — live R1-R5 compliance + outcomes

## [2.22.0] - 2026-04-30

### Changed
- fix: cap activity line at 280 chars to prevent heredoc flooding
- feat: NOTES.md self-bootstrapping + artefact-first-class path
- feat: upgrade GLM context-discipline preamble per Anthropic guidance
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.22.0] - 2026-04-30

### Changed
- feat: NOTES.md self-bootstrapping + artefact-first-class path
- feat: upgrade GLM context-discipline preamble per Anthropic guidance
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.26.0] - 2026-04-30

### Changed
- feat: upgrade GLM context-discipline preamble per Anthropic guidance

## [2.25.0] - 2026-04-30

### Changed
- feat: GLM context-discipline preamble for secondary routing
- fix: surface stdout terminal_reason + jq capture no-match handling

## [2.24.0] - 2026-04-30

### Changed
- fix: clean routing summary in fail-debug analyzer
- feat: severity-weighted tie-breaker — top 5 by severity
- docs: delivery artefacts — micro-delivery-report

## [2.23.0] - 2026-04-30

### Changed
- feat: severity-weighted tie-breaker — top 5 by severity

## [2.22.0] - 2026-04-30

### Changed
- feat: minimal fail-debug analyzer
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.29.0] - 2026-04-30

### Changed
- feat: minimal fail-debug analyzer

## [2.28.0] - 2026-04-30

### Changed
- feat: minimal fail-debug analyzer

## [2.27.0] - 2026-04-30

### Changed
- feat: forensic dump on EXIT_CODE_NON_ZERO catch-all
- fix: persist max-rank phase across tail-window refreshes
- fix: make YAML parser indent-aware

## [2.26.0] - 2026-04-30

### Changed
- feat: add --exit-when-idle auto-stop when backlog drained
- feat: User-skip telemetry — count + skip reason

## [2.25.0] - 2026-04-29

### Changed
- feat: user-skip telemetry — count + skip reason

## [2.24.0] - 2026-04-29

### Changed
- feat: user-skip telemetry — count + skip reason

## [2.23.0] - 2026-04-29

### Changed
- feat: user-skip telemetry — count + skip reason
- fix: restore secondary path — strengthen CLI invocation mandate + remove orphan Task spawn instruction

## [2.22.0] - 2026-04-29

### Changed
- fix: apply Claude Code proxy / gateway compat flags for secondary path
- fix: add Haiku model mapping for secondary path Task sub-agents
- fix: apply Z.AI-recommended compaction-window env=200000
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.24.0] - 2026-04-29

### Changed
- fix: apply Z.AI-recommended API_TIMEOUT_MS=3000000 for secondary path
- feat: streaming progress UX during Q&A
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation

## [2.23.0] - 2026-04-29

### Changed
- feat: streaming progress UX during Q&A — //

## [2.22.0] - 2026-04-29

### Changed
- fix: monotone phase state machine + tighten nested regex + (sub) model annotation
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.23.0] - 2026-04-29

### Changed
- feat: add WORKING fallback phase for active coding without specific marker
- fix: render model id as-is instead of short-label formatting

## [2.22.0] - 2026-04-29

### Changed
- feat: show active model on Phase line + double-space emoji gap
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.22.0] - 2026-04-29

### Changed
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.25.0] - 2026-04-29

### Changed
- feat: abort-safe handler — Stage 4 pre-loop skip option
- feat: ambiguity detector — heuristic + AST signal severity scoring

## [2.24.0] - 2026-04-29

### Changed
- feat: abort-safe-handler skill — Stage 4 pre-loop skip option

## [2.23.0] - 2026-04-29

### Changed
- feat: ambiguity detector skill — heuristic + AST signal severity scoring
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation

## [2.22.0] - 2026-04-29

### Changed
- feat: qa-loop-ui skill — sequential Q&A loop with skip, skip-all, partial-answer preservation
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- chore: add agent_exit phase logging for wrapper audit trail

## [2.22.0] - 2026-04-29

### Changed
- feat: smart-question-generator skill — ranked questions from ambiguity feed
- discovery(E121-E125): Phase D2 — 17 stories Pro multi-user collaboration

## [2.21.0] - 2026-04-28

### Changed
- feat: show pipeline phase per active delivery
- chore: regenerate skills indices + framework sync trace post SKILL-RIN-001

## [2.20.0] - 2026-04-27

### Changed
- feat: SKILL-RIN-001 review-input + anti-girouette research bundle
- feat: daemon HMAC-SHA256 signing of outbound webhook POSTs (X-Hub-Signature-256 + X-Webhook-Source headers, GAAI_DAEMON_WEBHOOK_SECRET env var)

## [2.19.0] - 2026-04-25

### Changed
- feat: daemon HMAC-SHA256 signing of outbound webhook POSTs (X-Hub-Signature-256 + X-Webhook-Source headers, GAAI_DAEMON_WEBHOOK_SECRET env var)
- fix: classify nested claude -p (Implement Agent) as sub-agent
- feat: surface sub-agent activity + fix "Bash null" rendering
- fix: use .gaai-worktrees/ naming to avoid in-project .gaai/ collision
- chore: group delivery worktrees under <parent>/.gaai/<repo>/worktrees/
- feat: — env-driven default (secondary when configured)
- feat: §7c unify non-.gaai deletions into sub-agent reviewer

## [2.19.0] - 2026-04-23

### Changed
- fix: classify nested claude -p (Implement Agent) as sub-agent
- feat: surface sub-agent activity + fix "Bash null" rendering
- fix: use .gaai-worktrees/ naming to avoid in-project .gaai/ collision
- chore: group delivery worktrees under <parent>/.gaai/<repo>/worktrees/
- feat: — env-driven default (secondary when configured)
- feat: §7c unify non-.gaai deletions into sub-agent reviewer

## [2.19.0] - 2026-04-22

### Changed
- feat: surface sub-agent activity + fix "Bash null" rendering
- fix: use .gaai-worktrees/ naming to avoid in-project .gaai/ collision
- chore: group delivery worktrees under <parent>/.gaai/<repo>/worktrees/
- feat: — env-driven default (secondary when configured)
- feat: §7c unify non-.gaai deletions into sub-agent reviewer

## [2.19.0] - 2026-04-22

### Changed
- chore: group delivery worktrees under <parent>/.gaai/<repo>/worktrees/
- feat: — env-driven default (secondary when configured)
- feat: §7c unify non-.gaai deletions into sub-agent reviewer

## [2.19.0] - 2026-04-20

### Changed
- feat: — env-driven default (secondary when configured)
- feat: §7c unify non-.gaai deletions into sub-agent reviewer

## [2.19.0] - 2026-04-20

### Changed
- feat: §7c unify non-.gaai deletions into sub-agent reviewer

## [2.18.0] - 2026-04-20

### Changed
- feat: memory catalog saillance — cloud MCP metadata + OSS installer adapters

## [2.17.0] - 2026-04-15

### Changed
- feat: classify Anthropic rate-limit as transient, revert to refined
- chore: reset 7 stories failed by Anthropic rate-limit → refined
- chore: add Build/Type Integrity step to qa-review skill
- wip: snapshot validate-memory-deltas scaffolding
- docs: extend memory-alignment-check category enum to match operational reality
- fix: context-bootstrap checks canonical memory path project/context.md
- chore: Discovery ingestion pass + architecture governance
- fix: prevent silent daemon orphans + sub-agent reviewer for diff-scope

## [2.17.0] - 2026-04-05

### Changed
- feat: extend memory freshness checks to docs and README

## [2.16.0] - 2026-03-30

### Changed
- fix: adjust bottom pane split to 60%
- fix: increase bottom pane split to 65% for active deliveries visibility
- fix: add Epic dependency propagation rule to generate-stories + validate-artefacts
- chore: update gaai-status command (add done/archive step) + clear daemon log
- fix: update --max-concurrent example to 5 (default is now 3)
- fix: default daemon concurrency is 3 slots, not 1
- fix: clarify /gaai-deliver vs /gaai-daemon — not aliases
- feat: harden Review Sub-Agent against LLM evaluation research findings
- fix: enforce YAML safety rules in delivery daemon (validate after every backlog write)
- fix: add write safety rules to generate-stories skill (never yaml.dump, match native indent)
- fix: add exponential backoff between daemon delivery retries
- fix: sync local VERSION with OSS + recursion guard for version bump commits

## [2.15.0] - 2026-03-26

### Fixed
- fix: revert daemon-setup to auto-set skipDangerousModePermissionPrompt
- fix: daemon-setup asks for confirmation before modifying global settings
- fix: stop auto-modifying global Claude Code settings
- refactor: make /gaai-deliver an alias of /gaai-daemon
- fix: monitor pane layout — 55% split, mouse scroll, clear scrollback
- fix: remove all project-specific references from .gaai/core/
- fix: add Brief Self-Assessment checklist to discovery.agent.md
- **Absolute worktree paths** — resolve once via `git rev-parse --show-toplevel`, use `$WORKTREE_PATH` everywhere
- **Mandatory worktree validation gate** — delivery fails explicitly if worktree missing after creation
- **Remove Tier 1 solo-founder shortcut** — worktree isolation is now unconditional regardless of tier
- **Fail-fast remote guard** — Step 0 checks for `origin` remote before any git operation
- **`GAAI_WORKTREE_BASE` env var** — configurable worktree location for cloud-synced repos (Dropbox/OneDrive)
- **Validation gate fix** — use `-e` (file exists) not `-d` (directory) for worktree `.git` check
- fix: CI advisory mode — don't block merge when no branch protection

## [2.14.0] - 2026-03-23

### Changed
- fix: defer marker+tag until after successful PR merge
- feat: content-review specialist — post-implementation copy quality gate

## [2.13.0] - 2026-03-23

### Changed
- feat: add language rule to base rules — agents match human language, artefacts stay English

## [2.12.0] - 2026-03-23

### Changed
- fix: D2 amended — self-merge on staging PERMITTED
- feat: Mission Brief — tailored context per sub-agent invocation
- fix: prevent -class incidents — 4 hardening measures
- fix: remove French from framework — English-only for OSS reuse

## [2.11.0] - 2026-03-23

### Changed
- feat: scope-filtered Session Brief per sub-agent

## [2.10.0] - 2026-03-22

### Changed
- feat: structured context passing — Session Brief with typed item IDs
- fix: escalation is last resort — resolve with Brief + DECs first

## [2.9.0] - 2026-03-22

### Changed
- feat: SKILL-RSA-001 review-story-alignment — adversarial story review gate
- fix: human validates Session Brief + explicit reviewer invocation template

## [2.8.0] - 2026-03-21

### Changed
- feat: enforce skill attestation — skills_invoked + audit skill (CRS-028)
- feat: lead with 4 commands + add Core Skills section to README.skills.md
- fix: align license declarations to ELv2 and correct factual errors
- fix: Discovery Session Brief — capture ALL session intelligence, not just decisions
- fix: prevent Discovery decision drift — 3 systemic fixes
- fix: add Definition of Ready (DoR) per Epic
- chore: refactor base.rules.md — backlog lifecycle, archiving, memory discipline, forbidden patterns
- docs: mention Discovery Session Brief in README + QUICK-REFERENCE

## [2.7.0] - 2026-03-20

### Changed
- feat: add skill-optimize (CRS-026) + pattern-transfer (CRS-027) — self-improvement loop axes 2 & 3
- fix: add Mandatory Skill Read guard to Discovery Agent

## [2.6.0] - 2026-03-18

### Changed
- fix: never overwrite existing .githooks/ files — append GAAI dispatcher
- fix: remove all project-specific DEC references from framework files
- fix: enforce DECs across Discovery, Delivery, and code — 4-level protection

## [2.5.0] - 2026-03-18

### Changed
- feat: 2-column monitor banner with fixed header
- docs: simplify daemon docs — /gaai-daemon as single entry point

## [2.4.0] - 2026-03-18

### Changed
- feat: route /gaai-daemon through daemon-start.sh with auto-monitor

## [2.3.0] - 2026-03-18

### Changed
- feat: tmux monitor dashboard, cross-OS fixes, dependency checks
- fix: status bar improvements + sync script immediate merge
- fix: prefer tmux over Terminal.app, remove focus-stealing activate
- fix: escape variable names adjacent to unicode in auto-bump log
- fix: anti-collision guards
- fix: capture delivery metadata in daemon wrapper
- fix: audit resolution — align authority boundaries, formalize lifecycle, add tooling
- chore: set --max-concurrent default to 3 and add auto-monitor launch
- chore: consolidate daemon log path + relocate sync artifacts to .github/
- docs: contributions → issues and feedback welcome (ELv2 IP protection)

## [2.2.0] - 2026-03-16

### Added
- Mandatory Memory Check in Discovery Agent — MUST scan memory index before producing any plan or artefact
- Mandatory Memory Check in Delivery Agent — MUST scan memory index before composing context bundles for sub-agents
- Automated CHANGELOG updates on framework sync

### Changed
- Memory retrieval upgraded from optional skill to mandatory workflow step in both agents

---

## [2.1.1] - 2026-03-13

### Changed
- README sections reordered: Install moved after value proposition
- README: merged "The Problem It Solves", "Who This Is For", and "Compared to Other Approaches" into a single "Why GAAI" section
- BMAD-METHOD comparison updated for v6 accuracy

### Added
- "Honest Trade-offs" section in README — 4 limitations stated upfront
- Research basis sections in ADRs 002, 003, 004, 006, 009 (15 verified sources across 5 ADRs)

### Removed
- `docs/hackernews-post.md` — distribution content, not documentation
- 7 niche/duplicate skills pruned from core (47 → 40)

---

## [2.1.0] - 2026-03-04

### Changed
- README.md rewritten for conversion: session example moved to position 2, install condensed to single primary method
- Skill count corrected: 37 → 47 (6 Discovery + 11 Delivery + 30 Cross)
- GAAI.md post-install links fixed: relative paths replaced with absolute GitHub URLs
- Contributor CLAUDE.md moved to `docs/contributing/DEVELOPMENT.md`

### Added
- `.gaai/QUICK-REFERENCE.md` — single-page cheat sheet accessible post-install

### Removed
- 7 duplicate root directories accidentally merged from contrib flat subtree
- `.gaai/core/scaffolding/` eliminated — `.gaai/project/` now ships ready-to-use
- Redundant README sections moved to framework docs

---

## [2.0.0] - 2026-02-28

### Changed
- Restructured `.gaai/` into `core/` (framework) + `project/` (user data via scaffolding)
- License changed from MIT to ELv2 (Elastic License 2.0)
- Install.sh updated for core/project split with scaffolding system
- Added git subtree support for syncing framework updates into consumer projects
- 37 skills across Discovery (6), Delivery (9), and Cross (22) categories
- Added AGENTS.md adapters for OpenCode, Codex CLI, Gemini CLI, Antigravity

---

## [1.0.0] - 2026-02-18

### Added
- `.gaai/` core framework folder
- Three agents: Discovery, Delivery, Bootstrap
- 31 skills across Discovery (6), Delivery (9), and Cross (16) categories
- Context system: rules, memory, backlog, artefacts
- Four workflows: delivery loop, context bootstrap, discovery-to-delivery, emergency rollback
- Six bash utility scripts
- Tool compatibility adapters: Claude Code, Cursor, Windsurf
- Interactive installer (`.gaai/core/scripts/install.sh`) with pre-flight check (`install-check.sh`)
- Full documentation in `docs/`
