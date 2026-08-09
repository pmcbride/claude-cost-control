# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A bundle of shell hooks, a statusline, agents, skills, and a kill switch that keep Claude Code
inside its 5-hour usage window. Pure `bash` + `jq` — no Python runtime, no network calls at
runtime, zero tokens consumed by the guards themselves.

**This repo is the source of truth. `install.sh` always installs to `~/.claude/cost-control`,
regardless of where the repo is cloned.** Never edit the installed copy — edit here, then
`make sync`. The one exception is documented under *manifest drift* below.

## Commands

```bash
make test          # full offline suite against the REPO copy — run before every commit
make quick-test    # skips the perf benchmark (~5s); what install.sh runs as step 5
make dry-run       # preview install, change nothing
make install       # backup + settings.json merge + CLAUDE.md append + version.lock seed + test
make sync          # fast repo -> ~/.claude/cost-control; never touches settings.json/CLAUDE.md
make status / on / off      # kill switch from the shell
./tests/test-hooks.sh       # one suite directly (same for test-merge / test-install / test-performance)
BUDGET_MS_PER_CALL=40 ./tests/test-performance.sh   # loosen the per-hook latency budget
```

There is **no single-test filter** — the suites are flat bash with `ok`/`bad` counters. To
isolate a case, run the one suite file and read the ✓/✗ lines.

`make test` must be green before any commit; a red suite means the installed guards would
misbehave, and the failure modes are silent (a guard that fails open just stops guarding).

## Architecture

### The data flow that makes it work

The statusline is the sensor, not just a display. `statusline/usage-statusline.sh` receives
Claude Code's statusline JSON on stdin and writes `~/.claude/.usage-state.json`
(`five_hour_pct`, `seven_day_pct`, `model`, `updated_at`). Every guard hook reads that file.
There is no API polling anywhere.

Consequence: **if the statusline stops running, the guards disarm.** That is deliberate
(fail-open), but it means headless/background sessions have no coverage — that gap is what
`hooks/watchdog-usage.sh` exists to fill, as a standalone poller, not a hook.

### Escalation ladder — monotonic, must stay ordered

| % of 5h window | Effect |
|---|---|
| 70 | deny `fable` spawns; throttle emits a terse nudge |
| 80 | deny **all** new subagent spawns |
| 90 | additionally deny heavy fan-out (`WebFetch`/`WebSearch`/`mcp__*`) unless `CC_BUDGET_EXEMPT_RE` matches |
| 94 | watchdog stops running background sessions |

Killing sessions is the most destructive control, so it fires last. Changing any threshold
means re-checking that the others still nest — `tests/test-hooks.sh` asserts the whole
decision matrix at 50/75/85/95%.

### Spawn gating — the load-bearing, easy-to-get-wrong part

A subagent spawn is a **`PreToolUse` call on the `Agent` tool** (renamed from `Task` in
v2.1.63; `Task` still aliases — matcher is `Agent|Task`). `PreToolUse` is the *only* hook
surface that can block it, via `hookSpecificOutput.permissionDecision: "deny"`.

- `SubagentStart` fires on spawn but **cannot block** — registered for audit logging only.
- `TaskCreated` is the task-*list* event (`TaskCreate` tool), unrelated to spawns.
  Registering a guard there blocks todo items, not spawns. It is deliberately not registered.

The guards read `.tool_input.model` and `.tool_input.subagent_type` (documented as of
v2.1.212). The `.params.model` / `.opts.model` fallbacks are redundant but kept to absorb a
future rename. If those paths ever go wrong the model resolves to `''` and the guard
**silently allows** — hence the live self-test in `tests/README.md`.

The gate is **also replicated into `agents/*.md` frontmatter**. As of the v2.1.226 docs this
is redundancy rather than the primary nested-spawn gate: hooks.md now states that "Hooks from
settings files, managed policy settings, and plugins also run inside subagents", so the
settings-level `PreToolUse` gate already covers subagent-originated spawns. Keep the
replication anyway — it costs nothing, and **plugin** subagents cut the other way (they ignore
frontmatter `hooks:` entirely and are covered *only* by the settings-level gate). Note also
that since v2.1.218 project-level frontmatter hooks require workspace trust for the folder
holding the agent file; user-level `~/.claude/agents/` — where this bundle installs — is exempt.

Nesting defaults to **3 layers** below the main conversation
(`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`), concurrency to **20**
(`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, *not enforced in ultracode sessions*), and since
v2.1.224 there is **no total-per-session spawn cap** at all.

### Deny, never rewrite

`guard-subagent-model.sh` refuses spawns; it never changes a model. `CLAUDE_CODE_SUBAGENT_MODEL`
is a highest-precedence *override* (it beats both per-invocation `model` and frontmatter), so
it cannot express "default cheap, let frontmatter win" — never set it globally. Deny-not-rewrite
is what keeps the per-agent roster in `agents/` authoritative.

### Fail-open is a requirement, not an accident

Missing state, state older than `CC_STATE_MAX_AGE` (900s), unparseable state, garbage payload,
absent `jq`, or an unknown event → the hook allows and exits 0. Preserve this on every edit;
`tests/test-hooks.sh` asserts each path individually. Below 70% the guards must emit **zero
bytes**, so the prompt Claude Code sends is byte-identical to an uninstalled system.

### Kill switch

Flag file `~/.claude/cost-control/.disabled`. Every active component checks it first and
exits 0. OFF disables the two guards, the throttle, and version-check messages; it leaves the
statusline and the passive agent-event log running. It does **not** lift the managed-settings
`availableModels` gate (OS-level, sudo to remove).

### Statusline preservation

`statusline/statusline-wrap.sh` exists so a user's own statusline survives install: it runs
the bundle's statusline with `CC_STATUSLINE_STATE_ONLY=1` (writes state, renders nothing),
then runs the original command for display. `install.sh` wires this automatically, wrapping
any pre-existing `statusLine.command` and staying idempotent if already wrapped.

When guards are ON the wrapper is a **byte-for-byte passthrough** (early exit, no buffering).
Only while the disable flag is present does it buffer and append `[cc-off]` — because the
bundle's own `[cc-off]` marker lives in a render block that STATE_ONLY skips, so a wrapped
custom statusline would otherwise never show it.

### manifest/ — the contract with Claude Code's docs

`manifest/claims.json` records every version-dependent claim, its verbatim doc quote, a
verdict (CONFIRMED / PARTIAL / UNVERIFIED), and what breaks if it changes.
`hooks/version-check.sh` compares `claude --version` against `manifest/version.lock` at
SessionStart and, on drift, asks for the `cost-control-verify` skill.

**Manifest drift is the one place the installed copy leads the repo.** The verify skill
patches `~/.claude/cost-control/manifest/`. Copy those back and commit *before* the next sync
or sync reverts them:

```bash
cp ~/.claude/cost-control/manifest/{claims.json,CHANGELOG.md} manifest/ && git diff
```

`version.lock`, `.drift`, `.disabled`, and `last-run.log` are runtime state — `make sync`
excludes them by design.

## Conventions

- **Never introduce a repo-relative path into an installed file.** Hooks, settings entries,
  and skills all reference `~/.claude/cost-control` as a fixed path.
- `settings.snippet.json` uses `//`-prefixed comment keys. User/project settings are validated
  **strictly** — a stray `//` key rejects the whole file and silently kills every hook. The
  install merge strips them; a hand-merge must too (`tests/test-merge.sh` pins this).
- Every hook's rationale lives in its own header comment, including which doc claim it depends
  on. Keep those in sync when behavior changes.
- `agents/*.md` must carry an explicit `model:` — never `inherit`, never `fable`. `explore.md`
  pins `model: haiku` because the built-in Explore stopped forcing Haiku around v2.1.198, so
  that override is load-bearing.
- Tunables are all `CC_*` env vars (`CC_ROOT`, `CC_BUDGET_{WARN,SOFT,HARD}_PCT`,
  `CC_BLOCK_MODELS`, `CC_STATE_MAX_AGE`, `CC_BUDGET_EXEMPT_RE`, `CC_WATCHDOG_*`, …). Add new
  knobs the same way, with a default that preserves current behavior.
- Requires `jq`. The optional `dashboard/` needs Docker.

## Document map

| File | Role |
|---|---|
| `ADR-claude-code-cost-control.md` | the *why* — read before changing a design decision |
| `README.md` | the *how* — user-facing install and operation |
| `tests/README.md` | the behavior-parity argument + the live checks offline tests can't cover |
| `REVIEW-2026-07-16-fable.md` | the review that corrected the spawn-surface wiring |
| `manifest/CHANGELOG.md` | append-only; one entry per `cost-control-verify` run, newest on top |
