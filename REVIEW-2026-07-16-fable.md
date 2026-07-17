# Cost-control bundle review — 2026-07-16 (v2, self-verified)

Reviewed per `_REVIEW-INDEX.md`. **v2 note:** v1 of this review delegated doc verification to a research subagent whose answers were wrong on three points (spawn tool_name, agent-frontmatter hooks, availableModels enforcement). Every claim below was re-verified directly against live code.claude.com docs on 2026-07-16 — hooks.md, sub-agents.md, tools-reference.md, model-config.md, settings.md, statusline.md, agent-view.md — cross-checked with Context7 (`/websites/code_claude`). The install.sh jq merge was tested empirically against a populated user config.

**Post-review note:** every fix recommended below was implemented, tested (offline suite in `tests/`), and recorded in `manifest/CHANGELOG.md` (2026-07-16 entry). This document is preserved as the review record.

## tl;dr

The bundle's PreToolUse leg (matcher `Agent|Task`) is the **correct and only blocking surface** for subagent spawns on current docs — but the `TaskCreated` registration polices the wrong feature entirely (the task list, not spawns) and will block todo-item creation at ≥80% usage, `SubagentStart` is documented as unable to block, and the watchdog's session-picker sorts on a field name the CLI doesn't emit. claims.json's `spawn-gating-event` narrative is backwards on current docs.

## Corrections from v1 (retracted findings)

1. **RETRACTED: "spawn tool_name is `Subagent`; the scripts' case lists miss it."** Wrong. sub-agents.md: *"In version 2.1.63, the Task tool was renamed to Agent. Existing `Task(...)` references … still work as aliases."* tools-reference.md: *"`Agent` — Spawns a subagent with its own context window."* The bundle's matcher `"Agent|Task|Agents|Dispatch"` (exact-string list per hooks.md matcher rules — letters + `|` = exact match) and the scripts' case lists are correct.
2. **RETRACTED: "agent-frontmatter `hooks:` is not in docs."** Wrong. sub-agents.md "Supported frontmatter fields" lists `hooks` — *"Lifecycle hooks scoped to this subagent"* — and "Define hooks for subagents" documents the exact pattern the bundle uses (PreToolUse in frontmatter, fires while that subagent is active). Caveat that does hold: **plugin** subagents ignore frontmatter `hooks`/`mcpServers`/`permissionMode`; the bundle installs to `~/.claude/agents/`, so it's unaffected.
3. **RETRACTED: "availableModels enforcement vs CLAUDE_CODE_SUBAGENT_MODEL is undocumented."** Wrong. model-config.md "Restrict model selection": the allowlist applies to *"the `model` field in subagent frontmatter, the Agent tool's `model` parameter, `CLAUDE_CODE_SUBAGENT_MODEL`"*. The bundle's CONFIRMED verdict was right. Aliases (`"sonnet"`, `"haiku"`) are valid entries. Note the fallback semantics: an excluded value is *skipped* and the subagent runs on the inherited model.

## 1. Guard hooks — fail-open ✅, spawn-surface coverage ⚠️ (corrected)

**Fail-open: verified** (from the scripts): missing jq → allow, missing/unparseable/stale state → allow, unresolvable model with default `CC_REQUIRE_EXPLICIT_MODEL=0` → allow. No path wedges the session.

**The real spawn surface (per current hooks.md):**

- **PreToolUse on `Agent` (alias `Task`) is the only blocking surface for spawns.** hooks.md exit-code table: *"PreToolUse | Yes | Blocks the tool call"*, with JSON `permissionDecision:"deny"` — exactly what the guards emit. This leg of the bundle is correct.
- **`SubagentStart` cannot block.** hooks.md: *"SubagentStart | No | Shows stderr to user only"*; decision-control table: *"SessionStart, Setup, SubagentStart — Context only … No blocking or decision control."* Its documented payload is `agent_id`/`agent_type` only — **no model field** — so the model probes find nothing there anyway. The exit-2 deny path on SubagentStart is a no-op; keep the event for logging only.
- **HIGH — `TaskCreated` is not a spawn event.** hooks.md: *"TaskCreated | When a task is being created via `TaskCreate`"*; tools-reference.md: *"TaskCreate | Creates a new task in the task list."* It's the todo-list feature. Consequences: (a) guard-usage-budget sets `is_spawn=1` for TaskCreated, so at ≥ SOFT (80%) it exits 2 — which per docs *"Rolls back the task creation"* — i.e. **the bundle blocks Claude's task list, not spawns, exactly when usage is high**; (b) with `CC_REQUIRE_EXPLICIT_MODEL=1`, guard-subagent-model would deny every task-list write (tasks never carry a model); (c) TaskCreated doesn't support matchers (the snippet's `"matcher": "*"` is silently ignored — harmless). **Fix: remove the guards from TaskCreated** (keep `log-agent-events.sh` if task telemetry is wanted) and update the settings.snippet comment.
- **claims.json `spawn-gating-event` is backwards.** Its current_value says *"Subagent spawning is NOT a PreToolUse tool call in current docs; it surfaces as TaskCreated/SubagentStart lifecycle events."* Current docs say the opposite: the spawn IS the Agent tool call (PreToolUse-blockable), SubagentStart is observe-only, TaskCreated is unrelated. The mitigation line "no single uncertain event is load-bearing" is also wrong: PreToolUse is the single load-bearing blocking event. Rewrite this claim.

**MEDIUM — stale-state fail-open disarms the gate in the unattended scenario.** State is written only while a statusline renders; after `MAX_AGE` (15 min) the budget gate silently disarms — precisely the runaway-while-away case that motivated the bundle. Inverse bug: **watchdog-usage.sh has no staleness check at all** — a stale 95% reading keeps stopping sessions after the window resets.

**MEDIUM — watchdog victim-picker is broken against the documented CLI schema.** agent-view.md documents `claude agents --json` entries as having `id`, `cwd`, `kind`, **`startedAt`** (camelCase), and `state` ∈ {`working`, `blocked`, `done`, `failed`, `stopped`} (`status`/`waitingFor` exist only while the process is alive). The watchdog sorts by `.started_at // .created_at // 0` — neither field exists, so every session sorts equal and "stop the newest first" degrades to arbitrary order. Its state list `["working","running"]` is half-surplus (`running` isn't a state) but `working` matches, so filtering works. Fix the sort key to `.startedAt`. (`claude agents --json` and `claude stop <id>` themselves: CONFIRMED, agent-view.md CLI table.)

**LOW —** guard-subagent-model's no-jq path echoes the tool payload to stdout before exit 0 (pointless; delete). Budget guard skips the staleness check when `updated_at` is non-numeric.

## 2. claims.json — audit (corrected)

- **`spawn-gating-event`** — verdict text is wrong on current docs (see above). Rewrite: spawn = PreToolUse `Agent`/`Task` (blockable); SubagentStart = observe/inject-context only; TaskCreated = task list, remove.
- **`spawn-tool-input-schema` (UNVERIFIED)** — still fair. The hooks.md PreToolUse per-tool `tool_input` table doesn't document the Agent tool's fields; the Agent SDK docs show `block.input.subagent_type` on Agent tool_use blocks and sub-agents.md confirms a per-invocation `model` parameter exists, so `.tool_input.model` / `.tool_input.subagent_type` are very likely right — but confirm with `claude --debug` as the claim already says. It **is load-bearing** under defaults (wrong paths → `model=""` → allow, silently), so keep `CC_REQUIRE_EXPLICIT_MODEL=1` or the managed gate as backstop.
- **`subagent-model-precedence`** — can be upgraded to CONFIRMED: model-config.md env-var table documents `CLAUDE_CODE_SUBAGENT_MODEL` (*"Overrides the per-invocation `model` parameter and the subagent definition's `model` frontmatter. Set to `inherit` to use normal model resolution"*), and sub-agents.md gives the full 4-step resolution order with the env var first; `inherit`==unset as of v2.1.196.
- **`available-models-gate`** — CONFIRMED stands (see retraction #3). Managed paths confirmed (settings.md): macOS `/Library/Application Support/ClaudeCode/`, Linux/WSL `/etc/claude-code/`, Windows `C:\Program Files\ClaudeCode\`, plus `managed-settings.d/` drop-ins merged alphabetically. Nuances to fold in: managed settings **parse tolerantly** (invalid entries stripped with a warning, listed by `/doctor`) — so the snippet's `//` keys are safe-with-noise, matching its comment; the "does NOT merge" wording in the snippet is imprecise (managed overrides per-key at highest precedence; `managed-settings.d` fragments do merge; permission rules merge across scopes). Also per settings.md, `availableModels` appears settable in any scope, not only managed — worth a note for solo-Max ergonomics (a user-settings allowlist would be self-serve, though also self-removable).
- **`nested-spawn-hooks` (CONFIRMED-high)** — should be **downgraded to PARTIAL**. No current doc states that settings.json PreToolUse hooks skip subagent-originated tool calls; hooks.md common fields say `agent_id` is *"present only when the hook fires inside a subagent call"*, implying at least some hooks do fire inside subagents, while sub-agents.md frames frontmatter hooks as the way to run hooks *"only while that subagent is active."* Ambiguous — verify with `--debug`. The frontmatter replication is documented, harmless, and correct either way.
- **`statusline-rate-limits`** — CONFIRMED verbatim (statusline.md Available data): `rate_limits.{five_hour,seven_day}.used_percentage` + `.resets_at` (epoch seconds), `cost.total_cost_usd`, `context_window.used_percentage`, `exceeds_200k_tokens`, `effort.level`, `output_style.name`, `agent.name`; `rate_limits` present only for Pro/Max subscribers after the first API response. The doc even recommends the `// empty` jq guard the scripts use.
- `explore-agent-model`, `session-controls` unverified env vars, 1.5M workflow warning: agreed non-load-bearing. Bonus confirmations: built-in subagents ship `Explore`/`Plan`/`general-purpose`; subagents background-by-default as of v2.1.198; nested subagents as of v2.1.172 with fixed depth limit 5.

## 3. install.sh jq merge — tested, mostly safe ✅

Empirical (populated config): preserves unrelated keys (`model`, `permissions`, user `env` vars), preserves user hook groups on shared and non-shared events, idempotent on re-run, aborts untouched on invalid/empty settings.json. The `stripc` pass removes `//` keys from the snippet before merging — important, because settings.md says user/project/local settings are **strict**: *"a file that fails validation is rejected as a whole and reported."*

- **MEDIUM — the manual-merge path is a validation footgun.** The snippet header and `--no-settings` invite pasting the snippet into `~/.claude/settings.json` by hand — `//` keys included. If those fail user-settings validation, the whole file is rejected and every hook dies silently. Either state "delete the `//` keys when merging by hand" in the snippet header, or verify unknown-key behavior for user settings and document it.
- **MEDIUM — header overclaims "never clobbers."** `$base * $snip` replaces an existing `statusLine` and `outputStyle` (backup + NOTE exist, but say it up front).
- **LOW —** `unique_by(tojson)` sorts hook groups, reordering user's existing PreToolUse entries; `2>/dev/null` hides the real jq error; `--force` actually means "skip the backup"; `head()` shadows coreutils.

## 4. Verify skill — split right, two leaks ✅⚠️

The safe-auto vs HITL boundary is correct. Leaks: (a) "thresholds" sits in the Auto lane — a threshold edit in `guard-usage-budget.sh` is guardrail behavior; restrict Auto to prose mentions. (b) Self-test can't distinguish hook-denied from allowlist-denied once managed settings are placed — assert on a `model-guard.jsonl` deny entry. Add a self-test that hooks registered at all (`/doctor` per settings.md lists stripped managed entries; strict rejection applies to user files).

## 5. Thresholds — individually sane, mutually incoherent ⚠️

Current: statusline 70/85 · throttle 70/90 · budget 70/80/92 · watchdog 90. Problems: the watchdog (kills sessions) fires **below** budget HARD (92, merely denies new work) — escalation should be nudge < deny-spawns < deny-heavy < kill; throttle CRIT (90) trails the spawn gate (80) by ten points, so in 80–90 the model attempts spawns and burns turns on denials with no "stop spawning" nudge — align throttle CRIT with SOFT; throttle gates on max(5h,7d) but the budget guard reads 5h only — a 7d-exhausted account is nudged but never gated; WARN denies opus spawns at ≥70, silently degrading the bundle's own opus reviewer (make WARN fable-only, opus at SOFT); HARD denies all `mcp__*`, killing cheap capture calls (PKM) at end-of-session. FWIW statusline.md's own example uses green <70 / yellow 70–89 / red 90+.

## Cross-cutting

- **Fable contradiction:** the rubric permits fable as a watched lead session; managed-settings excludes it at every layer including `/model` (model-config.md: allowlist applies to main session model). Placing the gate makes the rubric's legitimate use impossible. Pick one.
- **Statusline color feature is dead code:** statusline.md confirms ANSI colors are supported and that *"Claude Code captures your script's output instead of connecting it directly to the terminal"* — stdout is never a tty, so the script's `[[ ! -t 1 ]]` disables colors unconditionally. Gate on `CC_STATUSLINE_NOCOLOR` only.
- **Layering (mild over-engineering):** with the surface now confirmed, the authoritative layers are PreToolUse `Agent|Task` (hook floor) + availableModels (hard gate). TaskCreated should be dropped from guarding; SubagentStart demoted to logging; frontmatter replication kept (documented, covers the ambiguous nested case).

## Verdict table

| Area | Verdict |
|---|---|
| Fail-open discipline | ✅ solid; watchdog lacks staleness check |
| Spawn-surface blocking | ⚠️ PreToolUse leg correct (only blocking surface); remove guards from TaskCreated (task-list collision); SubagentStart observe-only |
| claims.json | ⚠️ spawn-gating-event backwards; nested-spawn → PARTIAL; precedence & rate-limits claims upgradeable to CONFIRMED |
| install.sh merge | ✅ safe + idempotent (tested); manual-merge `//`-key footgun; "never clobbers" overclaims |
| Verify-skill split | ✅ right; move threshold edits to HITL |
| Thresholds | ⚠️ reorder: watchdog above HARD; align throttle CRIT with SOFT |
| Watchdog | ⚠️ sort key `.started_at` → `.startedAt`; add staleness check |

### Doc citations index
- hooks.md — event list; exit-code table (PreToolUse Yes / SubagentStart No / TaskCreated "rolls back the task creation"); matcher rules (exact-string vs regex); common input fields (`agent_id` "inside a subagent call"); TaskCreated = "via TaskCreate"
- sub-agents.md — Task→Agent rename v2.1.63; frontmatter field table incl. `hooks`; "Define hooks for subagents"; model resolution order; nested subagents v2.1.172, depth 5; plugin agents ignore frontmatter hooks
- tools-reference.md — `Agent` spawns subagents; `TaskCreate` creates task-list tasks; hook matchers use bare tool names
- model-config.md — availableModels scope list (subagent frontmatter, Agent tool model param, CLAUDE_CODE_SUBAGENT_MODEL); env-var table entry for CLAUDE_CODE_SUBAGENT_MODEL; enforceAvailableModels v2.1.175
- settings.md — managed paths + managed-settings.d; tolerant managed parsing vs strict user/project/local validation; precedence
- statusline.md — full stdin schema incl. rate_limits; ANSI color support; output captured (not a tty); example thresholds
- agent-view.md — `claude agents --json` schema (`startedAt`, `state` values); `claude stop <id>`
