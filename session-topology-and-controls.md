# Session topology & controlling the spawn dialog

This answers the original question: *what is that "where should this run — local /
in this session / worktree / cloud" dialog, and how do I control when it fires?*
It's the **background-session / agent-view** control surface, which is distinct
from Agent-tool subagents. All flags below are **version-dependent** (this
reflects the v2.1.19x–v2.1.20x line, mid-2026) — confirm on your build before
relying on any one of them.

## The four execution locations, and what each costs

| Location | What it is | Context cost | Usage cost | Use when |
|---|---|---|---|---|
| **Subagent (in this session)** | Isolated context inside your session; summary returns to the main chat | Cheapest — main context stays lean | Counts (separate stream) | Verbose/parallel sub-work whose *result* you want back inline |
| **Background session** | A **separate full conversation** run by a per-user supervisor process; shows as a row in agent view | Its own context window | Counts **independently** — 10 parallel ≈ 10× burn rate | Parallel PR implementation you'll monitor |
| **Worktree** | File isolation (`.claude/worktrees/<id>/`) so parallel writers don't collide; automatic for background sessions before they edit | n/a (isolation, not context) | n/a | Multiple sessions editing the same repo concurrently |
| **Cloud (Claude Code on the web)** | Runs on Anthropic-managed VMs, off your laptop | Its own | **Still draws down your subscription** — not free | You want work to continue after you shut the laptop |

Key correction to a common assumption: **cloud/background is not cheaper.** It
moves *where* the compute runs, not *whose* budget it spends. Everything above
draws down the same shared Max pool.

## Triggering / controlling it

- **Background the current chat:** `/bg` (or `/background`); or press `←` on an
  empty prompt to background AND open agent view in one step; or start one from
  the shell with `claude --bg "<task>"`. Open the dashboard with `claude agents`.
- **The "Background this session?" dialog** appears only when in-flight work
  can't cleanly carry over (e.g., a running `monitor`). Normally, backgrounding
  carries subagents, background shell commands, workflows, and `/loop` tasks into
  the background session.
- **The "Background work is running" quit dialog** offers *Move to background and
  exit / Exit anyway / Stay*.

## The flags that make the dialog stop surprising you

| Want | Set |
|---|---|
| Don't carry in-flight work into the background session | `CLAUDE_DISABLE_ADOPT=1` — ⚠️ not in docs (claims.json: unverified); verify |
| Turn off agent view entirely | `disableAgentView: true` (settings) or `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` — ✅ confirmed (agent-view.md) |
| Disable background subagents (keep everything in-session) | `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` — ⚠️ referenced by sub-agents.md fork-mode notes; verify on your build |
| Stop `←` from opening agent view | `leftArrowOpensAgents: false` (`/config`) |
| Stop background sessions from auto-creating worktrees / branches / draft PRs | `worktree.bgIsolation: "none"` |
| Bias generated workflows smaller | `workflowSizeGuideline: "small"` in any settings file (v2.1.219+, takes precedence over `/config` and hides that row) — or `/config` → Dynamic workflow size. Default is now `medium` |
| Warn earlier on big workflows | (automatic) `Large workflow` warning fires at >25 scheduled agents or >1.5M projected tokens — ✅ now documented (workflows.md, v2.1.203+). Sessions with **ultracode** on are exempt and see no warning |
| Cap how many subagents run at once | `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (default **20**, v2.1.217+). Spawn #21 fails with `Concurrent subagent limit reached` and Claude is told not to retry. ⚠️ **ultracode sessions are exempt — the limit is not enforced there** |
| Cap how deeply subagents nest | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` — default **3** layers below the main conversation (v2.1.219+; was 1 in v2.1.217–218, 5 before). Set to `1` to disable nesting. At the limit the `Agent` tool is withheld entirely |
| Hard-cap spend in headless runs | `claude -p --max-budget-usd <n>` — subagent spend counts toward the cap; at the cap new spawns are denied **and running background subagents are halted** (v2.1.217+) |

⚠️ **There is no longer any total-per-session subagent cap.** The 200-spawns-per-session
limit was removed in v2.1.224 ("long-running sessions no longer refuse new agents");
only the concurrency and depth limits above still bound fan-out. A long session can
now spawn unbounded subagents over its lifetime — the burn-rate guards, not a
built-in ceiling, are what stop that.

Practical default for "I want a thin brain that dispatches, not a session
explosion": keep agent view on (you want visibility), set
`CLAUDE_DISABLE_ADOPT=1` so backgrounding is predictable, set
`workflowSizeGuideline: "small"` in `~/.claude/settings.json`, and dispatch
implementation work deliberately with `claude --bg --name "pr-<x>"` rather than
letting `←` background things by reflex.

## The "analyze → propose PRs → implement each separately" flow you wanted

1. **Main brain** (Opus on-plan) does read-only repo analysis in **plan mode** and
   writes scoped PR specs to `docs/plans/` — detail lands in files, not the chat.
2. For each spec: `claude --bg --name "pr-<x>" "<scoped prompt that references the
   plan file>"`. Each runs in its own worktree with its own bounded subagent
   fan-out, isolated from the others.
3. Monitor from agent view; merge PRs as their checks go green. The main brain
   never holds the implementation detail — it holds the plan and the status.

This is the topology that gives you multitasking without the context bloat: the
brain stays small because the work — and its verbose context — lives in the
background sessions and the plan files, not in the brain's scrollback.
