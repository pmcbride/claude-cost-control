# claude-cost-control

A generic, project-agnostic toolkit for keeping Claude Code inside its 5-hour
usage window: a usage-aware statusline, model-discipline + spike-guardrail hooks,
a terse output-style, a "project brain" pattern, an offline test suite, and an
optional usage dashboard.

Read `ADR-claude-code-cost-control.md` first — it's the *why* and the design
rationale (options assessed, decisions, verified findings with citations). This
README is the *how* (install + what each file does).

## The one idea

Context window and usage limit are **two different budgets**. Subagents and
parallelism buy context headroom by spending *more* usage. So the goal isn't
"use subagents to save tokens" (that's backwards) — it's: see usage live, never
fan out expensive models by accident, auto-stop new heavy work near the wall, and
keep output + context lean. That's what these files do.

## How the spawn gate works (verified vs code.claude.com docs, 2026-07-16)

A subagent spawn is a **`PreToolUse` call on the `Agent` tool** (renamed from
`Task` in v2.1.63; `Task` still aliases), and PreToolUse is the **only** hook
surface that can block it (JSON `permissionDecision:"deny"`). `SubagentStart`
fires on spawn but cannot block — it's used here for audit logging only.
`TaskCreated` is the task-*list* event (the `TaskCreate` todo tool), unrelated
to spawns — nothing is registered there. The model-guard is additionally
replicated into each example agent's frontmatter (a documented feature:
docs/en/sub-agents "Define hooks for subagents"). As of the v2.1.226 docs,
settings-level hooks are confirmed to fire inside subagents too ("Hooks from
settings files, managed policy settings, and plugins also run inside subagents"),
so the frontmatter copy is now redundancy rather than the sole nested-spawn
gate — except for **plugin** subagents, which ignore frontmatter `hooks:` and are
covered only by the settings-level gate. The optional managed-settings
`availableModels` allowlist is the independent hard backstop, enforced against
subagent frontmatter, the Agent tool's model param, and
`CLAUDE_CODE_SUBAGENT_MODEL` (docs/en/model-config). Note that as of **v2.1.251**
`CLAUDE_CODE_SUBAGENT_MODEL` is a *default*, not an override — an explicit
per-spawn `model` and an agent's frontmatter `model:` both win over it — so a
global `CLAUDE_CODE_SUBAGENT_MODEL=haiku` is now a safe roster-preserving floor.
The old override behavior is opt-in via `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`
(v2.1.257+), which discards the roster entirely.

## What you'll actually notice day-to-day (and the kill switch)

Below 70% of the 5-hour window, **nothing** — the guards emit zero bytes, the
throttle injects nothing, and the only visible additions are the statusline row
and the Terse output style (both cosmetic; swap the style back via `/config` if
you don't like it). **Already have a statusline you like?** install.sh detects
it and preserves it automatically: your command keeps rendering the display,
wrapped by `statusline/statusline-wrap.sh`, which silently writes the usage
state file the budget guard needs (the bundle's statusline runs in state-only
mode underneath). Your status bar looks identical; the guards still work. The always-on inventory: two PreToolUse hooks (one per tool
call, one on spawns — ~10–25ms each), a per-prompt throttle check (silent below
70%), a SessionStart version check (speaks only on first install and after
`claude update`), a passive subagent audit log, and the CLAUDE.md discipline
block (prose guidance the model reads; no enforcement). Above 70% the ladder
engages: fable spawns denied → 80% all new spawns denied + "be terse" nudge →
90% heavy fan-out denied → 94% watchdog (only if you run it) stops background
sessions.

**`/cost-control off`** kills all of it instantly — no restart. It writes a flag
file every active component checks first: spawn guard, budget guard, throttle,
and version-check all become transparent no-ops on the next tool call; the
statusline keeps rendering with a yellow `[cc-off]` marker so you don't forget.
**`/cost-control on`** re-arms the same way; **`/cost-control status`** shows
state + live usage + denial counts. Two things the switch deliberately doesn't
touch: the OS-level managed-settings `availableModels` gate (needs `sudo rm`)
and a `watchdog-usage.sh` you started yourself (Ctrl-C). The CLAUDE.md block and
Terse style are also left alone — they're guidance/cosmetics, not restrictions;
remove them by editing `~/.claude/CLAUDE.md` / `/config` if you want them gone.

## Layout

```
ADR-claude-code-cost-control.md   the design doc (read first)
REVIEW-2026-07-16-fable.md        independent review that corrected the spawn-surface wiring
session-topology-and-controls.md  the local/in-session/worktree/cloud spawn dialog + control flags
settings.snippet.json             merge into ~/.claude/settings.json (install.sh does this safely)
managed-settings.snippet.json     hand-place as managed settings: availableModels hard gate (read its fable tradeoff note)
CLAUDE.snippet.md                 paste into ~/.claude/CLAUDE.md (cost-discipline + cache hygiene + verbosity tiering)
install.sh                        idempotent installer: backup, merge, validate, self-test
cost-control.sh                   master kill switch CLI (backs the /cost-control skill)
statusline/
  usage-statusline.sh             live: model · effort · ctx% · 5h% · 7d% · $  (+ writes state file; CC_STATUSLINE_STATE_ONLY=1 = state only)
  statusline-wrap.sh              keep YOUR statusline for display, still feed the guards' state file
hooks/
  guard-subagent-model.sh         PreToolUse(Agent|Task): DENY fable / unspecified-model spawns (preserves frontmatter)
  guard-usage-budget.sh           PreToolUse(*): DENY new fan-out as the 5h window fills (banded, fails open)
  throttle.sh                     UserPromptSubmit: inject "be terse / stop fanning out" as usage climbs
  watchdog-usage.sh               standalone poller: claude stop runaway background sessions on a burn spike
  version-check.sh                SessionStart: detect Claude Code version drift → trigger the verify skill
  log-agent-events.sh             quiet audit log of subagent lifecycle (SubagentStart/Stop)
tests/
  run-all.sh                      full offline suite (install.sh runs --quick automatically)
  test-hooks.sh                   behavior parity below thresholds + gating matrix + every fail-open path
  test-merge.sh                   settings-merge safety + idempotency
  test-install.sh                 end-to-end sandboxed install
  test-performance.sh             per-hook latency budget + usage-overhead statement
  README.md                       what the suite proves (and what needs the live self-test)
manifest/
  claims.json                     machine-readable baseline of every version-dependent claim (+ what each affects)
  CHANGELOG.md                    append-only history of each verification run
  version.lock.example            format of the pinned-version file the hook maintains
skills/
  cost-control-verify/SKILL.md    self-updating validator: diffs current-version docs vs claims.json, patches the bundle
  cost-control/SKILL.md           /cost-control on|off|status — instant toggle, manual-invoke only
agents/
  explore.md / worker.md / reviewer.md   example haiku/sonnet/opus agents w/ frontmatter-replicated gate (nested spawns)
output-styles/
  terse.md                        terse baseline that protects reasoning + PKM
project-templates/
  STATUS.template.md              per-project "brain" file w/ append-only Realizations log
  STATUS-best-practices.md        how to run it without context bloat; STATUS vs PKM
dashboard/
  docker-compose.yml + configs    OTel Collector + Prometheus + Tempo + Grafana
  grafana/dashboards/…            usage dashboard (tokens/cost/session, drill-down)
  parse_transcripts.py            no-infra local usage report ("which subagent burned it")
  telemetry.env.example           the env to stream telemetry to the stack
  README.md                       dashboard quickstart
```

## Install

**Fastest path:** `./install.sh` — idempotent; backs up and merges your
`settings.json` (it REPLACES `statusLine` and `outputStyle` with the bundle's —
previous values stay in the backup), appends the CLAUDE.md block, copies files,
seeds the version lock, and runs the offline test suite. `--dry-run` to preview,
`--no-settings` to merge yourself (then DELETE the `//` comment keys — settings
files are strict JSON, and a whole-file syntax/schema error shows a Settings
Error dialog interactively but is skipped SILENTLY in `-p` runs, killing every
hook; individually bad entries are merely skipped with a warning since the
v2.1.233-era docs), `--managed` for the hard-gate command. Then restart
Claude Code and run `cost-control-verify`. Installing via Claude Code? Hand it
`HANDOFF-claude-code.md`.

Manual steps (if you prefer):

```bash
mkdir -p ~/.claude/cost-control ~/.claude/output-styles ~/.claude/agents ~/.claude/skills
cp -r statusline hooks manifest tests ~/.claude/cost-control/
chmod +x ~/.claude/cost-control/{statusline,hooks,tests}/*.sh
cp output-styles/terse.md ~/.claude/output-styles/
cp agents/*.md ~/.claude/agents/                       # optional example agents (haiku/sonnet/opus)
cp -r skills/cost-control-verify ~/.claude/skills/     # the self-updating validator skill
~/.claude/cost-control/tests/run-all.sh                # prove behavior before wiring anything in
```

Then merge `settings.snippet.json` into `~/.claude/settings.json` (statusLine,
hooks incl. the SessionStart version-check + UserPromptSubmit throttle,
outputStyle — minus every `//` key), paste `CLAUDE.snippet.md` into
`~/.claude/CLAUDE.md`, and restart Claude Code.

**First-run baseline (do this once).** On the next session start the version-check
hook will emit a `COST-CONTROL SETUP` message — run the **`cost-control-verify`**
skill when it does. It verifies the version-dependent claims against your
installed version's docs, records the baseline in `manifest/`, and runs the LIVE
self-test: spawn a `fable` subagent → expect a denial **and** a deny entry in
`~/.claude/logs/model-guard.jsonl` (the log entry proves the hook fired, not the
allowlist); confirm the statusline writes usage state; confirm `/hooks` lists the
cost-control hooks. After that it stays silent until Claude Code updates, when
it re-triggers automatically.

Drop `STATUS.template.md` into a project as `STATUS.md`. Optional hardening:
hand-place `managed-settings.snippet.json` at your OS managed-settings path
(read its fable tradeoff note first), and run `watchdog-usage.sh` in a terminal
for unattended fan-out. Dashboard is optional and self-contained under
`dashboard/`.

Requires `jq` (statusline + hooks + tests) and, for the dashboard, Docker.

## Which file answers which question

| You wanted… | It's here |
|---|---|
| Live 5-hour usage in the status bar | `statusline/usage-statusline.sh` (native `rate_limits` — no polling) |
| Cheaper subagents *without* overriding frontmatter | frontmatter pinning + `hooks/guard-subagent-model.sh` (deny, don't rewrite) + `CLAUDE.snippet.md` rubric |
| Telemetry dashboard w/ session/subagent drill-down | `dashboard/` (Grafana metrics + Tempo traces + `parse_transcripts.py`) |
| A guardrail that winds down spikes safely | `hooks/guard-usage-budget.sh` (blocks new work) + `hooks/watchdog-usage.sh` (stops runaway background sessions) |
| Responses that get terser as usage climbs | `hooks/throttle.sh` (UserPromptSubmit self-throttle) |
| A hard cap so fable can't be spent by accident | `managed-settings.snippet.json` (`availableModels`) |
| Catch nested/subagent-originated spawns | settings-level `PreToolUse` gate (docs-confirmed to fire inside subagents) + frontmatter-replicated gate in `agents/*.md` as redundancy |
| Control the local/in-session/worktree/cloud dialog | `session-topology-and-controls.md` |
| A validation layer that auto-updates on Claude Code updates | `hooks/version-check.sh` + `skills/cost-control-verify` + `manifest/claims.json` |
| Proof this doesn't change normal behavior or add usage | `tests/` (run `./tests/run-all.sh`) |
| Turn the whole thing off/on without restarting | `/cost-control off` · `on` · `status` (`skills/cost-control` + `cost-control.sh`) |
| A terse default that doesn't hurt reasoning/PKM | `output-styles/terse.md` + verbosity tiering in `CLAUDE.snippet.md` |
| A "project brain" that doesn't bloat + keeps realizations | `project-templates/STATUS.template.md` + best-practices |

## Tuning knobs (env vars)

The escalation ladder is monotonic by design — each control is more drastic
than the one below it, so the thresholds must stay ordered:

```
70%  statusline amber · throttle "be terse" nudge · gate denies fable spawns
80%  throttle "no subagents" nudge · gate denies ALL new spawns   (aligned on purpose)
90%  statusline red · gate denies heavy fan-out (WebFetch/mcp__*)
94%  watchdog stops running background sessions (most destructive → fires last)
```

- Statusline colors: `CC_USAGE_WARN_PCT` (70), `CC_USAGE_CRIT_PCT` (90).
- Throttle: `CC_THROTTLE_WARN_PCT` (70), `CC_THROTTLE_CRIT_PCT` (80).
- Budget gate: `CC_BUDGET_WARN_PCT` (70), `CC_BUDGET_SOFT_PCT` (80),
  `CC_BUDGET_HARD_PCT` (90); `CC_EXPENSIVE_MODELS` ("fable" — opus is
  deliberately NOT here so your opus reviewer survives until SOFT);
  `CC_BUDGET_EXEMPT_RE` (empty — e.g. `mcp__pkm.*` to keep knowledge capture
  alive in the HARD band); `CC_BUDGET_DISABLE=1` at session launch to bypass;
  `CC_STATE_MAX_AGE` (900s fail-open).
- Model guard: `CC_BLOCK_MODELS` ("fable"), `CC_REQUIRE_EXPLICIT_MODEL` (0/1).
- Watchdog: `CC_WATCHDOG_STOP_PCT` (94), `CC_WATCHDOG_INTERVAL` (30s),
  `CC_WATCHDOG_MAX_STOP` (1), `CC_WATCHDOG_DRYRUN`, `CC_WATCHDOG_INCLUDE_BLOCKED`.
- Shared: `CC_USAGE_STATE` (state file path), `CC_*_LOG` (log paths).
- Statusline temp files: `CC_USAGE_TMP_DIR` (default `<state dir>/cache/cost-control`
  — keep it on the state file's filesystem or the atomic rename degrades to a
  copy), `CC_USAGE_TMP_TTL_MIN` (60 — an orphaned temp is reaped once it is this
  old), `CC_USAGE_SWEEP_EVERY_MIN` (60 — how often the sweep may run).

Per-project overrides: put a project `.claude/settings.json` with different
thresholds, or set the env vars in that project's shell.

## Honest limitations

- **Hooks stop *new* work, not in-flight fan-outs.** The watchdog stops runaway
  *background sessions* but can't freeze a mid-flight workflow. Workflow-internal
  stage spawns may bypass PreToolUse — control those with the *session* model +
  per-stage `opts.model`.
- **The budget gate disarms in unattended sessions.** Its state file is written
  by the statusline, so headless/background sessions stop refreshing it and the
  gate fails open after 15 minutes (by design — fail-open beats wedging). The
  watchdog is the unattended-coverage tool; run it when leaving fan-outs alone.
- **The Agent tool's `tool_input` field names are probed, not documented.** The
  guards fail open if the schema differs on your build — that's what the live
  self-test catches on day one. Backstops: `CC_REQUIRE_EXPLICIT_MODEL=1` and the
  managed-settings allowlist.
- **Verified vs verify-locally.** Spawn surface, blocking mechanisms, statusline
  fields, `claude agents --json` schema, model precedence, and the
  availableModels gate were verified against live `code.claude.com/docs`
  (2026-07-16) — citations in `REVIEW-2026-07-16-fable.md` and
  `manifest/claims.json`. Whatever is still marked UNVERIFIED/PARTIAL in
  `claims.json` degrades safely and is re-checked by `cost-control-verify` on
  every Claude Code update.
