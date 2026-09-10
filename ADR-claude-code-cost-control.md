---
title: Claude Code Cost-Control Architecture
type: ADR / PRD
status: proposed
date: 2026-07-14
revised: 2026-08-09 (v3.2 — re-verified against v2.1.226; nested-spawn ambiguity resolved)
supersedes: my-claude-extensions (reference only)
verified-against: code.claude.com/docs (2026-08-09, raw-markdown fetch, Claude Code v2.1.226)
---

# Claude Code Cost-Control Architecture

## tl;dr

The 5-hour usage limit is a *different budget* from the context window, and
subagents/parallelism trade the second for the first — they cost more usage, not
less. This design keeps the coherence benefits of orchestration while capping the
cost, using four layers: (1) a **usage-aware statusline** that reads the live
5-hour % Claude Code already hands it; (2) **frontmatter-pinned model routing**
plus a **PreToolUse deny-hook** as the hard floor (never the global env
override); (3) a **PreToolUse budget circuit-breaker** that stops new fan-out as
usage approaches the wall; (4) a **terse output-style** and a **STATUS.md
"project brain"** pattern to keep both output and context lean. Everything is
subscription-native — no external polling, no per-token API billing.

---

## 0. Revision note (v2 — incorporating hub-and-spoke research)

This version folds in a second research pass. Net changes from v1:

- **Self-throttling is achievable after all** — not by the model watching its own
  usage (it can't), but by a **UserPromptSubmit hook** that reads the statusline's
  usage state and injects an `additionalContext` directive telling the model to
  compress and stop fanning out as usage climbs (`hooks/throttle.sh`). The harness
  monitors; it tells the model. This is the soft layer under the hard budget gate.
- **Runaway work *can* be cancelled** — an external **watchdog**
  (`hooks/watchdog-usage.sh`) polls `claude agents --json` and `claude stop <id>`
  to wind down the newest running background sessions above a threshold.
- **New hard gate:** `availableModels` in a hand-placed **managed-settings** file
  excludes Fable at *every* layer — including `CLAUDE_CODE_SUBAGENT_MODEL` — and
  works for solo Max users, not just enterprise (`managed-settings.snippet.json`).
  See §6 for the fable lead-session tradeoff this creates.
- **Nested-spawn coverage:** the model-guard is **replicated into agent
  frontmatter** (`agents/*.md`) — a documented feature (sub-agents.md "Define
  hooks for subagents"). As of v2.1.226 this is *redundancy*: hooks.md now
  confirms settings-level hooks fire inside subagents, so the settings gate
  already covers subagent-originated spawns (§0d, §7.11).
- **Prompt-cache economics** added as first-class cost hygiene: subagents build
  cold caches on a 5-min TTL; forks reuse the parent's cache; mid-session
  CLAUDE.md edits invalidate the cache. ⚠️ Narrowed at v2.1.267: mid-session
  model switches and tool-set changes no longer break prefix reuse (tool
  definitions are recorded once, late MCP/plugin tools arrive deferred).
- **Session-topology controls** (`session-topology-and-controls.md`) now document
  the exact flags behind the local/in-session/worktree/cloud spawn dialog.

## 0b. Verification pass + self-updating validation layer (v3)

A live doc pass (2026-07-14, docs v2.1.183) verified every version-dependent
claim; results are recorded machine-readably in `manifest/claims.json` and
narrated in `manifest/CHANGELOG.md`. That pass got the spawn surface **wrong**
(see §0c) but established the right machinery:

- Claims are pinned to a docs version and re-verified on every Claude Code
  update: a `SessionStart` hook (`hooks/version-check.sh`) compares
  `claude --version` to `manifest/version.lock` and, on drift, tells the model
  to run the **`cost-control-verify`** skill — which re-fetches the current
  docs, diffs them against `claims.json`, writes a CHANGELOG entry, auto-applies
  safe updates (prose, manifest values, paths) and **proposes executable-code
  patches for review** (a guardrail that fails *wrong* is worse than stale),
  then bumps the lock. Gated to run only on version change or on request.

## 0c. Review correction (v3.1, 2026-07-16) — the spawn surface, re-verified

An independent review (`REVIEW-2026-07-16-fable.md`) re-checked every claim
directly against live docs and **reversed the v3 spawn-gating finding**:

- **A subagent spawn IS a `PreToolUse` tool call** — on the **`Agent`** tool
  (renamed from `Task` in v2.1.63; `Task(...)` still aliases — sub-agents.md).
  PreToolUse blocks via JSON `permissionDecision:"deny"` and is the **only**
  hook surface that can block a spawn.
- **`SubagentStart` cannot block** (hooks.md exit-code table: "Shows stderr to
  user only"; payload carries `agent_id`/`agent_type`, no model). Demoted to
  audit logging.
- **`TaskCreated` is the task-LIST event** ("when a task is being created via
  `TaskCreate`" — hooks.md). The v3 registration there would have rolled back
  *todo items* at ≥80% usage, not spawns. Deregistered.
- Also fixed in the same pass: watchdog sort key (`startedAt`, per the
  documented `claude agents --json` schema) + state-staleness check; statusline
  ANSI gating (output is captured, never a tty); threshold ladder made monotonic
  (70 nudge < 80 deny-spawns < 90 deny-heavy < 94 kill); budget WARN band
  narrowed to fable so the opus reviewer isn't silently degraded; an offline
  test suite (`tests/`) that install.sh runs automatically.
- **Process lesson, now policy** (in the verify skill): a claim verdict may only
  change on a *verbatim doc quote*; delegated verification without quotes is not
  evidence. The v3 error came from trusting a research pass whose fetches had
  silently truncated.

## 0d. Drift re-verification (v3.2, 2026-08-09) — v2.1.212 → v2.1.226

A `cost-control-verify` run against the installed v2.1.226, using raw-markdown
doc fetches rather than a summarizing fetch (the 2026-07-17 run caught a
summarizer false-negative, so raw fetch + local grep is now the method).
**No executable guardrail change was required** — the `Agent` tool_input schema,
the `PreToolUse` deny mechanism, the `Agent|Task` matcher, the statusline
`rate_limits` fields, and the `claude agents --json` schema are all unchanged.

- **The §0/§7.11 nested-spawn ambiguity is RESOLVED.** hooks.md now states that
  "Hooks from settings files, managed policy settings, and plugins also run
  inside subagents", with `agent_id`/`agent_type` on the input. The frontmatter
  replication is demoted from *the* nested gate to redundancy — kept, because
  **plugin** subagents ignore frontmatter `hooks:` and are covered only by the
  settings-level gate.
- **Two fan-out assumptions in this ADR were superseded.** Nesting depth is no
  longer "fixed at 5, not configurable" — it defaults to **3 layers** and is set
  by `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`. Concurrency is capped at **20**
  (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`) — but **not enforced in ultracode
  sessions**, which also suppress the `Large workflow` warning.
- **A ceiling this design leaned on is gone:** the 200-subagent-per-session cap
  was removed in v2.1.224. Nothing bounds lifetime spawn count now, which makes
  the §4 burn-rate guards the *only* remaining limiter for a long-lived session.
- **A drill-down capability claimed in §5 does not work as written:** telemetry
  redacts `agent.name` for user-defined agents to the literal `"custom"`, so the
  per-agent metric breakdown collapses for this bundle's own agents. Use traces
  or the `PostToolUse` `tool_response` cost fields instead.

Full detail, with verbatim quotes per claim, in `manifest/CHANGELOG.md`
(2026-08-09 entry) and `manifest/claims.json`.

## 1. Context

On 2026-07-11 a session exhausted the 5-hour window in ~4 hours and pushed usage
credits to 106%. `/usage` attribution: 98% subagent-heavy, 59% `workflow-subagent`,
100% of the fan-out on `claude-fable-5`. The same behavior was cheap in June.
Three things stacked: (a) the most expensive model, (b) a workflow fan-out that
inherited that model, (c) a tightened Fable promo allowance. The trigger was not
a pricing change — it was adopting subagents and parallelism, which multiply burn
4–7× (agent teams ~7×, per Anthropic's docs), against a hard rolling window.

The root misconception, worth stating plainly because the whole design follows
from it:

> **Context window and usage limit are two separate budgets.** Subagents keep the
> *orchestrator's context* lean by doing work in an isolated window and returning
> a summary — but every subagent is billable work against the *shared usage
> bucket*. Parallelism doesn't lower total tokens; it raises the burn **rate**,
> which is exactly what trips the 5-hour window. Orchestration is a
> quality/coherence tool, not a savings tool.

## 2. Goals / non-goals

**Goals.** Make usage *visible* in-session without external polling or noise;
make it *impossible* (not just discouraged) to silently fan out expensive models;
*automatically wind down* new heavy work as the window fills, safely, so nothing
blows the cap; keep the setup subscription-only; provide drill-down to answer
"which subagent burned it"; reduce output/context waste without harming reasoning
or PKM capture. Generic and project-agnostic; per-project customization optional.

**Non-goals.** Reducing the *total* token cost of a genuinely large task (that's a
scoping decision, not a config). Killing in-flight subagents mid-run (not
possible via hooks — see §6). Billing-accurate cost accounting (we want relative
burn signal, not an invoice).

## 3. Decision drivers

- Subscription-native; zero per-token API billing.
- Hard enforcement over guidance where it matters (CLAUDE.md ≈70% adherence;
  hooks ≈100% at the harness layer — *when the wiring is verified; hence the
  tests + live self-test*).
- Fail-open: a broken guardrail must never wedge the chat.
- Preserve the curated per-agent model roster — no blunt global overrides.
- Low noise / low compute: the user explicitly does not want a laggy or chatty
  machine (see `tests/test-performance.sh` for the enforced latency budget).

## 4. Options considered

### 4.1 Usage awareness

| Option | Verdict | Why |
|---|---|---|
| **Statusline native `rate_limits`** | **Chosen (primary)** | The statusline stdin JSON includes `rate_limits.five_hour.used_percentage` + `resets_at` and `seven_day` (Pro/Max, after first API response). Live 5-hour % with zero API calls, zero polling, zero background process. |
| OTEL → Grafana dashboard | **Chosen (secondary)** | Best for history, burn-rate-over-time, and drill-down by model/session/subagent. Heavier (Docker); opt-in. |
| `ccusage` / transcript parse | **Chosen (fallback)** | Zero-infra local report; answers "which subagent." Caveat: transcript schema is internal and can drift. |
| Model self-monitors usage mid-turn | **Rejected** | Not possible — the model can't see live usage-limit consumption mid-turn without explicitly calling `/usage`. Any "usage-aware agent" must be *external* (hook/statusline). |

### 4.2 Model control (cheaper subagents *without* clobbering frontmatter)

| Option | Verdict | Why |
|---|---|---|
| `CLAUDE_CODE_SUBAGENT_MODEL` as a global default | **Rejected at decision time; the platform reversed it in v2.1.251** | Originally rejected because it was the **highest-precedence override**: set globally it downgraded opus reviewers and upgraded haiku explorers, discarding the roster, and there was no "soft default" knob. As of **v2.1.251** it *is* that soft default — sub-agents.md: *"Before v2.1.251, `CLAUDE_CODE_SUBAGENT_MODEL` came first in this order and overrode both the per-invocation parameter and the frontmatter."* New order: per-invocation `model` > frontmatter (`inherit` = session model) > this env var > session model. Setting it globally is now safe and roster-preserving. The old semantics moved to **`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`** (v2.1.257+), which ignores every definition's `model:` incl. built-in Explore/Plan and, set alone, pins every subagent to the *main* model. Decision unchanged in practice (frontmatter stays the roster), but the *reason* no longer holds. |
| **Frontmatter-pinned `model:` per agent** | **Chosen (base)** | The only place a per-agent default legitimately lives. Every named agent pins its model; workflow stages set `opts.model`. |
| **PreToolUse deny-hook on `Agent|Task`** | **Chosen (hard floor)** | *Denies* (never rewrites) any spawn resolving to `fable` or, optionally, any spawn with no explicit model. Deny-not-rewrite is what preserves frontmatter. The only hook surface that can block a spawn (§0c). |
| `availableModels` allowlist (managed settings) | **Chosen (backstop)** | Enforced at every model-selection layer incl. subagent frontmatter, the Agent tool's model param, and the env override (model-config.md). Works for solo users via a hand-placed managed-settings file. Cannot express "fable for lead sessions only" — see §6. |
| Tactical per-session env override | **Kept as a tool** | `CLAUDE_CODE_SUBAGENT_MODEL=haiku` for *one* heavy session to force all workers cheap is legitimate. Since v2.1.251 it is also safe as a persisted global (frontmatter and explicit spawns win over it). To get the *old* force-everything behavior for one heavy run, pair it with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` (v2.1.257+) — and only for that run, since it discards the roster wholesale. |

### 4.3 Spike guardrail / auto-wind-down

| Option | Verdict | Why |
|---|---|---|
| **PreToolUse budget hook (banded)** | **Chosen** | Reads the statusline's state file; ≥70% denies fable spawns, ≥80% denies all new spawns, ≥90% denies heavy fan-out (WebFetch/mcp__*, minus an exemption regex). In-flight work finishes; you inspect and resume. This is the "safe wind-down." |
| `Stop` / `SubagentStop` hooks | **Insufficient alone** | They fire *after* work completes — good for logging, useless for prevention. Used here only for the audit trail. |
| First-class auto-cancel-on-spike | **Doesn't exist** | No setting cancels running agents or auto-downgrades the model on a threshold. Must be built; the PreToolUse gate + watchdog is the buildable approximation. |

### 4.4 Terseness

Output-style **chosen** over CLAUDE.md prose or `--append-system-prompt`: it's the
purpose-built mechanism, lives in one file, is toggleable per session via
`/config`, and (with `keep-coding-instructions: true`) trims verbosity without
dropping Claude Code's engineering guidance. CLAUDE.md carries the *cost-discipline
rules* (behavioral policy) while the output-style carries the *verbosity policy* —
different concerns, different files.

## 5. Decision — the four-layer architecture

1. **See it** — `usage-statusline.sh` renders `model · effort · ctx% · 5h% ·
   7d% · $` from the statusline JSON and writes `~/.claude/.usage-state.json` as
   a side effect. No polling.
2. **Route it** — frontmatter pins every agent's model to the `haiku/sonnet/opus`
   rubric; `guard-subagent-model.sh` denies `fable`/unspecified spawns on
   PreToolUse `Agent|Task` as the hard floor. The global env override is never
   persisted.
3. **Cap it** — `guard-usage-budget.sh` reads the state file and denies new
   fan-out / expensive spawns as the 5-hour window fills, in graduated bands
   (70/80/90), failing open on missing/stale state. `watchdog-usage.sh` (94%)
   stops runaway background sessions.
4. **Shrink it** — the `Terse` output-style cuts output waste while protecting
   reasoning; `STATUS.md` + PKM keep the "project brain" thin so context doesn't
   bloat. `log-agent-events.sh` + the dashboard give after-the-fact drill-down.

Model rubric (the load-bearing table):

| Model | Use for |
|---|---|
| `haiku` | read-only exploration, search, lookup, log/diff scanning |
| `sonnet` | **default** — general work, code edits, tool/script execution |
| `opus` | orchestration/lead, or critical adversarial review only |
| `fable` | never for a subagent; only a lead session you're actively watching |

Invariants: subagent model **≤** main-chat model; **never `fable`** for a
subagent; always set explicit `effort` (`low`/`medium` mechanical, `high` hard
reasoning); workflow size = `medium` (<15), now the default and settable via the
`workflowSizeGuideline` settings key; concurrency cap 2–3 by convention (the
platform's own ceiling is 20, and is not enforced in ultracode sessions).

## 6. Consequences & limitations (honest)

- **Hooks cannot stop in-flight work; the watchdog can (background sessions
  only).** The budget gate prevents *new* spawns but can't pause an already-running
  workflow. The external `watchdog-usage.sh` closes part of this gap — it can
  `claude stop` running *background sessions* above a threshold — but it cannot
  surgically pause a mid-flight workflow's internal fan-out; that you still
  interrupt manually. So "safe wind-down" = "no new fuel + stop stray background
  sessions," not "freeze everything instantly."
- **The budget gate disarms in unattended sessions.** Its state file is written
  by the statusline; headless/background sessions stop refreshing it and the
  gate fails open after `CC_STATE_MAX_AGE` (15 min). Deliberate — fail-open
  beats wedging — but it means the watchdog, not the gate, is the unattended
  control. The watchdog itself skips action on stale state (same constant).
- **The managed-settings fable gate is all-or-nothing.** `availableModels`
  cannot distinguish "fable as a watched lead session" (rubric-permitted) from
  "fable as a subagent" (never). Excluding fable blocks both, including
  `/model fable`. The tradeoff and both configurations are documented in
  `managed-settings.snippet.json`; strict is the shipped default.
- **Workflow-internal spawns may bypass `PreToolUse`.** Per the docs, workflow
  subagents run in their own mode; the per-stage spawns likely don't traverse
  your PreToolUse hooks. So the *session model* is the real control for
  workflows — keep workflow sessions on Opus, not Fable, and set `opts.model` per
  stage. The hook protects `Agent`/`Task` spawns; it is not a workflow cap.
- **The Agent tool's `tool_input` layout is probed, not documented.** The
  model-guard probes several field paths and fails open if it can't identify the
  model (claims.json `spawn-tool-input-schema`, UNVERIFIED). Backstops:
  `CC_REQUIRE_EXPLICIT_MODEL=1` and the availableModels gate. The live self-test
  (verify skill) proves it on your build day one.
- **OTEL→Prometheus metric names drift** by version; the dashboard ships with
  best-guess names and a one-time "verify at :8889/metrics" fix documented on the
  dashboard itself.
- **Per-subagent metric attribution** is available via `agent.name` +
  `query_source` telemetry attributes (monitoring-usage.md), plus traces/
  transcripts for deeper drill-down.
- **Guidance vs enforcement.** CLAUDE.md rules are ~70% adhered; the hooks are the
  ~100% layer *once verified on your build*. Keep both — the prose explains *why*
  to the model, the hook makes it *stick*.

## 7. Verified findings (with citations, re-checked 2026-07-16)

| # | Finding | Source |
|---|---|---|
| 1 | ⚠️ **REVERSED v2.1.251** — `CLAUDE_CODE_SUBAGENT_MODEL` is now a **default**, not an override. Resolution order is **param > frontmatter (`inherit` = session model) > env var > session** (docs: *"Before v2.1.251, `CLAUDE_CODE_SUBAGENT_MODEL` came first in this order and overrode both the per-invocation parameter and the frontmatter"*). `inherit`==unset (v2.1.196+). The override semantics moved to `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` (v2.1.257+), which also ignores built-in Explore/Plan `model:` and, set alone, forces the main conversation's model | code.claude.com/docs/en/model-config, /sub-agents |
| 2 | Statusline JSON exposes `rate_limits.{five_hour,seven_day}.used_percentage` + `resets_at`, `cost.total_cost_usd`, `context_window.used_percentage`, `exceeds_200k_tokens`, `effort.level`, `agent.name`; Pro/Max only, after first response; ANSI supported; stdout captured (not a tty). **v2.1.251 adds** `rate_limits.spend_limit.{used_percentage,resets_at}` (Claude apps gateway only; can exceed 100) and a `prompt_cache` object (`warm`, `ttl`, `expires_at`, `hit_ratio`, `misses`, `miss_recache_tokens`, `recache_tokens_if_cold`, + `last_miss_cause`/`miss_causes` in v2.1.260) covering the **main conversation only**, not subagents. **Presence rule tightened:** *"Claude Code drops a window once its `resets_at` time passes"* — absence, not a zero, is the post-reset state, so the `// empty` guard is load-bearing | code.claude.com/docs/en/statusline |
| 3 | Workflow agents inherit the session model unless a stage sets `opts.model`; workflow size = unrestricted/small<5/medium<15/large<50, default `medium`, settable via the `workflowSizeGuideline` settings key (v2.1.219+, overrides `/config`); runtime caps 16 concurrent / 1000 total; `Large workflow` warning at >25 agents or >1.5M projected tokens (v2.1.203+, **suppressed in ultracode sessions**; since the v2.1.233-era docs a chosen size guideline replaces the 25-agent threshold with its own count — `medium` warns at >15) | code.claude.com/docs/en/workflows |
| 4 | **Spawn surface:** a subagent spawn is a PreToolUse call on the `Agent` tool (`Task` alias; renamed v2.1.63); PreToolUse blocks via exit 2 or JSON `permissionDecision:"deny"` and is the only blocking surface **for a spawn**; `SubagentStart` cannot block; `TaskCreated` = task-list event. **New adjacent surface (v2.1.251):** `PreModelSwitch` can block a *model switch* (`permissionDecision` allow/deny/ask or `decision: "block"`; matched on canonical `to_model`), `PostModelSwitch` observes — not registered by this bundle; note Claude Code skips `PreModelSwitch` for its own switches (automatic fallback, resume restore) and runs every hook regardless of matcher when it cannot canonicalize the target | code.claude.com/docs/en/hooks, /sub-agents, /tools-reference |
| 5 | Telemetry: `CLAUDE_CODE_ENABLE_TELEMETRY=1` + OTLP; metrics `claude_code.token.usage`, `.cost.usage`, `.session.count`; `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` emits spans; `query_source` ∈ `main`\|`subagent`\|`auxiliary`. ⚠️ `agent.name` **redacts user-defined agent names to the literal `"custom"`** — only built-in and official-marketplace-plugin agent names appear verbatim, so this bundle's own `worker`/`reviewer` agents are NOT separable by name in metrics | code.claude.com/docs/en/monitoring-usage |
| 6 | Output styles live in `~/.claude/output-styles/*.md`; `keep-coding-instructions: true` retains engineering guidance; activate via `/config` or `"outputStyle"` | code.claude.com/docs/en/output-styles |
| 7 | `/usage` shows per-feature attribution (v2.1.174+); the model cannot see live usage mid-turn without calling it | code.claude.com/docs/en/costs |
| 8 | Agent teams ~7× token multiplier; usage shared across Code/chat/Cowork; background/cloud sessions draw down subscription identically | prior research + code.claude.com/docs/en/costs |
| 9 | UserPromptSubmit hooks inject `additionalContext` into the model's turn — the mechanism for harness-driven self-throttle; SessionStart + SubagentStart also support it | code.claude.com/docs/en/hooks |
| 10 | `availableModels` (+`enforceAvailableModels`, v2.1.175+) enforced at every model-selection layer incl. subagent frontmatter, the Agent tool's model param, and the subagent env override; managed settings parse tolerantly, user files strictly | code.claude.com/docs/en/model-config, /settings |
| 11 | **RESOLVED (v2.1.226 docs):** settings.json PreToolUse DOES fire for subagent-originated tool calls — "Hooks from settings files, managed policy settings, and plugins also run inside subagents… `PreToolUse` and `PostToolUse` fire the same configured hooks as in the main conversation", carrying `agent_id`/`agent_type`. Frontmatter replication is now redundancy, except for plugin subagents (which ignore frontmatter `hooks:` and rely on the settings gate). Since v2.1.218 project-level frontmatter hooks additionally require workspace trust; user-level `~/.claude/agents/` are exempt | code.claude.com/docs/en/hooks, /sub-agents |
| 12 | Subagent frontmatter fields incl. `hooks`, `model` (sonnet/opus/haiku/fable/full-ID/inherit), `effort`, `background`, `isolation: worktree`, `maxTurns`; nested spawns v2.1.172+, **depth default 3 layers and configurable via `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`** (v2.1.219; was 1 in v2.1.217–218, fixed-5 before); background-by-default v2.1.198+; concurrency cap `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` default 20 (v2.1.217+, ultracode exempt); **no total-per-session spawn cap since v2.1.224** | code.claude.com/docs/en/sub-agents |
| 13 | Cache economics: subagents cold-cache 5-min TTL, main convo 1-hr TTL on-plan, forks reuse parent cache; mid-session CLAUDE.md edits invalidate. ⚠️ **Narrowed v2.1.267** — mid-session *model switches* and *tool-set changes* no longer break prefix reuse: `/model` stopped re-sending every tool definition, late MCP/plugin tools arrive as deferred definitions, and subagents / `--system-prompt` sessions record prompt + tool defs once | hub-and-spoke research + prompt-caching docs + /changelog v2.1.267 |
| 14 | Session controls: `claude agents` / `--json` (entries: `id`, `startedAt`, `state` ∈ working\|blocked\|done\|failed\|stopped), `claude stop/attach/logs/respawn/rm`, `/bg`, `disableAgentView`/`CLAUDE_CODE_DISABLE_AGENT_VIEW` | code.claude.com/docs/en/agent-view |
| 15 | **NEW v2.1.267 — `maxEffortLevel`**: caps the session's effort level *"on every provider, including Bedrock, Vertex and Foundry"*; one of `low`/`medium`/`high`/`xhigh`/`max` (`max` = no cap), default unset. Overrides anything higher — `/effort`, the `/model` picker, `--effort`, `CLAUDE_CODE_EFFORT_LEVEL`, and a skill's or subagent's `effort` frontmatter. Scope `Any file`, and **the lowest cap across scopes wins** (a lower scope cannot raise it), so it is enforceable from managed settings. *"A cap below `xhigh` makes ultracode unavailable on the models the cap applies to"* — the only documented lever against ultracode, whose fan-out ignores `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`. Per-model exemption via that model's `modelSettings` entry, effective only within the same settings source. **Not set by this bundle** | code.claude.com/docs/en/settings-reference |

## 8. Rollout

1. `./install.sh` (or the manual steps in README). It copies files, merges
   settings safely, appends CLAUDE.md, seeds the version lock, and runs the
   offline test suite (`tests/run-all.sh --quick`) — all green before Claude
   Code ever loads the hooks.
2. Restart Claude Code; confirm the statusline shows `5h %`.
3. Run the `cost-control-verify` skill when the SETUP message appears: it pins
   the baseline to your installed version and runs the LIVE self-test — spawn a
   `fable` subagent → expect a denial AND a deny entry in
   `~/.claude/logs/model-guard.jsonl`; `/hooks` lists the cost-control hooks.
4. Optional: managed-settings hard gate (read the fable tradeoff note first);
   `watchdog-usage.sh` in a terminal for unattended runs; `dashboard/` via
   Docker.

## 9. Open items / re-verify

- Confirm the `Agent` spawn `tool_input` schema via `claude --debug`; tighten
  `guard-subagent-model.sh` field paths (claims.json `spawn-tool-input-schema`).
- Settle the nested-spawn ambiguity (claims.json `nested-spawn-hooks`) with a
  `--debug` run: does the settings-level PreToolUse hook log with `agent_id` set
  when a subagent calls Bash?
- Confirm exact Prometheus metric names on your version; update dashboard panels.
- Re-verify model pricing, precedence, and any Fable promo terms quarterly —
  these move fast (log re-checks in the project's Realizations log).
