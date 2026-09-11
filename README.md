![Version](https://img.shields.io/badge/version-2.48.0-blue)
![License: ELv2](https://img.shields.io/badge/license-ELv2-green)
![Stack](https://img.shields.io/badge/stack-bash%20%2B%20md%20%2B%20yaml%20%2B%20python%20%2B%20node-orange)

# GAAI — Governed Agentic AI Infrastructure

A `.gaai/` folder you drop into any git project. Markdown, YAML and bash, with a vendored Python runtime and a few Node helpers. No SDK. No package to install. No external services.

**GAAI turns AI coding tools into reliable agentic software delivery systems.**

---

## See It in Action

```
You:        /gaai-discover
Discovery:  "What do you want to build?"
You:        "Add rate limiting — 100 req/min per user, 429 on exceeded."
Discovery:  "Got it. Checking memory for existing middleware patterns..."
            → Generates Epic E03 + Story E03S01 with acceptance criteria
            → Runs validation: artefact complete, criteria testable, no scope drift
            → Adds to backlog: status: refined
Discovery:  "Done. E03S01 is ready. Run /gaai-deliver when you're ready."

You:        /gaai-daemon
            → Launches the Delivery Daemon (polls backlog, delivers in parallel via tmux)
Delivery:   → Reads E03S01 from backlog
            → Loads middleware conventions from memory
            → Planning Sub-Agent: produces execution plan
            → Implementation Sub-Agent: adds rate-limiting middleware
            → QA Sub-Agent: all acceptance criteria PASS
            → Story marked done, PR merged to staging
Delivery:   "E03S01 complete. No further Stories in backlog."
```

Two slash commands. Two **isolated contexts**. Discovery reasons — it never executes. Delivery executes — it never decides scope. They never share a context window — Delivery runs as a separate OS process (`claude -p` via tmux), so system prompts can't contaminate each other. The backlog is the contract between them.

> `/gaai-deliver` delivers a single Story in the current session. `/gaai-daemon` launches a background daemon that polls the backlog and delivers multiple Stories in parallel (each in its own tmux session). [See Delivery Daemon →](#delivery-daemon)

> [Full walkthrough in Quick Start](docs/guides/quick-start.md)

---

## Why GAAI

AI coding tools are fast — but without governance, speed creates drift: agents touch code they shouldn't, forget decisions from prior sessions, and ship features no one can verify against criteria. GAAI adds the missing layer.

**Built for developers who already have product clarity** — solo founders, senior engineers, small teams who know what to build and need an agent that ships it reliably without going off-script. If you've ever said "the agent broke something it wasn't supposed to touch," this is for you.

| vs. | Difference |
|-----|-----------|
| AGENTS.md / cursor rules | Solves one session. GAAI adds cross-session memory, scope authorization, and structured delivery. |
| BMAD-METHOD | Simulates a multi-agent Agile team. GAAI is lighter on Discovery, more rigid on Delivery governance. |
| LangGraph / AutoGen / CrewAI | Code-first orchestration for building AI systems. GAAI governs the use of AI coding tools. Different abstraction level. |
| Spec Kit (GitHub) | Spec-driven pipeline (spec → plan → tasks → implement). GAAI adds governance enforcement, multi-agent delivery with QA gates, structured cross-session memory, and automated daemon delivery. |

---

## How It Works

**Discovery** — you talk to the Discovery Agent in your current session. Clarify what to build. Output: a Story with acceptance criteria in the backlog. Discovery reasons. It does not execute.

**Delivery** — always runs in an **isolated process**. `/gaai-daemon` launches the Delivery Daemon, which runs each Story in its own `claude -p` session via tmux — a completely separate OS process with no Discovery residue and no conversation history bleed. The Delivery Agent orchestrates specialized sub-agents (Planning, Implementation, QA) per Story. Real-time visibility via `tmux attach`. No improvisation. No scope drift. No context contamination.

The delivery workflow is **portable to sub-agent-capable AI coding runtimes**. Claude Code is the reference implementation — the daemon uses `claude -p` because Claude Code was the first coding agent to expose sub-agent primitives (isolated contexts per sub-task, required for Planning → Implementation → QA separation). Discovery and governance work with any AI coding tool.

**The backlog is the contract.** Nothing gets built that isn't in it.

```
your-project/
└── .gaai/
    ├── core/                  ← framework engine (auto-synced from your project)
    │   ├── README.md          ← start here (human + AI onboarding)
    │   ├── GAAI.md            ← full reference
    │   ├── QUICK-REFERENCE.md ← daily cheat sheet
    │   ├── VERSION
    │   ├── agents/            ← Discovery + Delivery + Bootstrap agent specs
    │   ├── skills/            ← execution units
    │   ├── contexts/rules/    ← framework rules
    │   ├── workflows/         ← delivery loop, bootstrap, handoffs
    │   ├── scripts/           ← bash utilities
    │   ├── hooks/             ← git hook dispatcher + core hooks
    │   └── compat/            ← thin adapters per AI tool
    └── project/               ← your project data (never overwritten by updates)
        ├── agents/            ← custom project agents
        ├── skills/            ← custom project skills
        ├── scripts/           ← project-specific scripts
        ├── hooks/             ← project-specific git hooks
        ├── workflows/         ← custom workflow overrides
        └── contexts/
            ├── rules/         ← project rule overrides
            ├── memory/        ← persistent memory (decisions, patterns, context)
            ├── backlog/       ← execution queue (active, blocked, done)
            └── artefacts/     ← stories, epics, plans, reports
```

No SDK. No npm package. No pip install — nothing is fetched when you install. Governance is markdown, YAML and bash: readable by humans and by any AI tool. Delivery also needs `python3` and `node` on PATH, plus the vendored PyYAML runtime shipped in `.gaai/core/vendor/` — the one binary in the tree.

---

## Install (30 seconds)

**Copy the `.gaai/` folder into your project.** That's it.

Download from GitHub, drop `.gaai/` into your project root, and tell your AI tool: *"Read `.gaai/core/README.md` and bootstrap this project."*

<details open>
<summary>Option A — Ask your AI tool to do it</summary>

Paste this into your AI tool's chat:

```
Install the GAAI framework into my current project.

Determine {user-tool} by identifying which AI coding tool is running this
prompt. Valid values: claude-code | cursor | windsurf | other.
If you cannot determine it, ask the user before proceeding.

Then run:
  rm -rf /tmp/gaai
  git clone https://github.com/Fr-e-d/GAAI-framework.git /tmp/gaai
  bash /tmp/gaai/.gaai/core/scripts/install.sh --target . --tool {user-tool} --yes
  rm -rf /tmp/gaai

After install, show the user the next steps exactly as printed by the
installer.
```

The installer copies `.gaai/` and deploys the right adapter for your tool (CLAUDE.md, AGENTS.md, or .cursor/rules/).

</details>

<details>
<summary>Option B — CLI</summary>

```bash
git clone https://github.com/Fr-e-d/GAAI-framework.git /tmp/gaai && \
  bash /tmp/gaai/.gaai/core/scripts/install.sh --wizard && \
  rm -rf /tmp/gaai
```

</details>

---

## Delivery Daemon

`/gaai-deliver` delivers a single Story in the current session. `/gaai-daemon` launches the Delivery Daemon, which delivers Stories autonomously. Requires a git repo with a `staging` branch:

- Polls the backlog for `refined` stories
- Launches parallel Claude Code or Codex sessions in tmux (default: 3 slots, configurable)
- Coordinates across devices via git push
- Monitors health, retries failures, archives completed work
- Runs inside a private tmux server whose socket is digest-bound to the repository, so a second checkout can never join or clobber the lifecycle
- Offers an on-demand monitoring dashboard (tmux split: daemon config + active deliveries)

<img src="assets/daemon-monitor.png" alt="Delivery Daemon monitoring 3 concurrent story deliveries" width="700">

**Setup (one-time):**

```bash
.gaai/core/scripts/daemon-setup.sh
```

Invoke it **directly**. `daemon-setup.sh` and `daemon-start.sh` are executables carrying a
`#!/bin/bash -p` shebang: prefixing either with a plain `bash` interpreter is refused with
`entry_authority_invalid`, because a non-privileged interpreter has already applied `BASH_ENV`
and imported exported functions before the script's first instruction. The only alternative is
an absolute, verified Bash invoked `--noprofile --norc -p <script>`.

`daemon-setup.sh` is also the **only** command that may create or update the dedicated daemon
home worktree. Startup verifies that home and refuses if it is absent, stale, dirty, foreign or
on the wrong branch — it never repairs it, and there is no fallback to your working checkout.

Because the entry rebuilds a closed allowlist of configuration, a shell exporting `GIT_EDITOR`,
`GIT_CONFIG_COUNT`, `PYTHONPATH` and similar cannot start the daemon. That is the contract, not
a defect — start it from a clean environment, e.g.
`env -i PATH=/usr/bin:/bin HOME="$HOME" TERM="$TERM" .gaai/core/scripts/daemon-start.sh`.

**Usage:**

```
/gaai-daemon                        # start daemon (3 slots)
/gaai-daemon --max-concurrent 3     # 3 parallel deliveries
/gaai-daemon --status               # read-only lifecycle status (mutates nothing)
/gaai-daemon --monitor              # attach the monitoring dashboard
/gaai-daemon --stop                 # graceful shutdown
```

> `/gaai-deliver` = one Story, current session. `/gaai-daemon` = background daemon, parallel delivery.

> Requires: git repo, `staging` branch, **Claude Code CLI (`claude` in PATH, default) or Codex CLI (`codex` in PATH, via `GAAI_DAEMON_EXECUTOR=codex`)**, `python3`, `node`, and **tmux — required, not optional** (3.2 is the nominal floor; a real capability probe is the admission authority). There is no Terminal.app or `nohup` fallback: a fallback launcher is how process ownership used to be inferred from ambient state instead of proven.
>
> **Note:** The Delivery Daemon explicitly supports two local headless executors — Claude Code CLI (default) and Codex CLI. An unknown or unavailable executor stops before governed work begins with an actionable error. Discovery and governance work with any AI tool — this requirement applies only to autonomous delivery.
>
> **Tested on:** macOS (Apple Silicon), enforced on every candidate — the daemon home
> suites run on a hosted macOS runner under `/bin/bash`, which on that platform is the
> Bash 3.2 floor the daemon entry point targets. Linux (Ubuntu) is exercised by the
> hosted corpus on the same candidates. WSL is **not** claimed — no WSL run exists.
> Native Windows (Git Bash / MSYS2 / Cygwin) is unsupported: the daemon refuses to
> start there. Issues and feedback welcome.

---

## Works With

**Deep integration** — slash commands, auto-loaded context, SKILL.md auto-discovery:

| Tool | Adapter |
|------|---------|
| Claude Code | `CLAUDE.md` + `.claude/commands/` |

**AGENTS.md compatible** — full GAAI capability via manual activation prompts:

| Tool | Adapter |
|------|---------|
| OpenCode | `AGENTS.md` |
| Codex CLI | `AGENTS.md` |
| Gemini CLI | `AGENTS.md` |
| Antigravity | `AGENTS.md` |
| Cursor | `.cursor/rules/*.mdc` |
| Windsurf | `AGENTS.md` |
| Any other | Read `.gaai/core/README.md` directly |

One canonical source (`.gaai/`). Thin adapters per tool. No duplication. Discovery, governance, and manual delivery work with any AI coding tool. The delivery workflow is portable to sub-agent-capable AI coding runtimes — Claude Code is the reference implementation today.

> [Full compatibility details](docs/reference/tool-compatibility.md)

---

## Honest Trade-offs

- Discovery is conversational and intentionally lightweight. It helps you structure what you know — it does not replace deep product research or collaborative brainstorming across a team.
- Trivial tasks still need a backlog item. You can make it a one-liner, but the gate is always there.
- “No package to install” is literal, not a claim of zero dependencies. Nothing is fetched — PyYAML is vendored in-tree — but `git`, `python3`, `node` and `tmux` must already be on PATH for the Delivery Daemon, and the vendored runtime is a binary zipapp rather than readable source.
- The framework relies on the agent following the files. There is no programmatic enforcement.
- The repo was recently published under ELv2. Community is just getting started.

---

## Documentation

- [Quick Start](docs/guides/quick-start.md) — first working Story in 30 minutes
- [What is GAAI?](docs/01-what-is-gaai.md) — the problem in full
- [Core Concepts](docs/02-core-concepts.md) — dual track, backlog, memory, skills, artefacts
- [Vibe Coder Guide](docs/guides/vibe-coder-guide.md) — fast daily workflow
- [Senior Engineer Guide](docs/guides/senior-engineer-guide.md) — governance, rules, CI
- [Skills Index](.gaai/core/skills/README.skills.md) — full skill catalog
- [Tool Compatibility](docs/reference/tool-compatibility.md) — Claude Code, OpenCode, Codex CLI, Gemini CLI, Antigravity, Cursor, Windsurf
- [Design Decisions](docs/architecture/design-decisions.md) — why GAAI is structured the way it is (ADRs + research basis)

---

**source-available under the Elastic License 2.0 (ELv2)** — see [LICENSE](LICENSE) for the full terms.

---

## Support This Project

If you find this framework valuable, please consider showing your support:

- **[Sponsor on GitHub](https://github.com/sponsors/Fr-e-d)**

---

Created by [Frédéric Geens](https://www.linkedin.com/in/fr%C3%A9d%C3%A9ric-geens-04162233/)
