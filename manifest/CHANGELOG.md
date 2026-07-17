# Cost-control validation changelog

Append-only. Each entry is one run of the `cost-control-verify` skill: the
Claude Code version it verified against, what changed vs the previous baseline,
and which files were patched. Newest at top. Never edit past entries.

---

## 2026-07-16 — external review pass (docs fetched live; version unpinned)

Full independent re-verification of every claim against live code.claude.com
docs (hooks.md, sub-agents.md, tools-reference.md, model-config.md, settings.md,
statusline.md, agent-view.md), cross-checked with Context7. Review record:
`REVIEW-2026-07-16-fable.md`. This pass REVERSED the 2026-07-14 baseline's
central spawn-gating finding and fixed the wiring accordingly:

- **CORRECTED — spawn gating (was backwards).** A subagent spawn IS a
  `PreToolUse` call on the `Agent` tool (renamed from `Task` in v2.1.63; alias
  kept) and PreToolUse is the ONLY hook surface that can block it.
  `SubagentStart` fires on spawn but CANNOT block (docs: "shows stderr to user
  only"; payload has no model). `TaskCreated` is the task-LIST event
  (`TaskCreate` tool) — the previous registration there would have blocked
  todo-item creation at ≥80% usage, not spawns. → Guards now: PreToolUse only
  (matcher `Agent|Task`); SubagentStart/Stop demoted to audit logging;
  TaskCreated/TaskCompleted deregistered. `spawn-gating-event` verdict
  CHANGED→CONFIRMED with corrected content.
- **UPGRADED — subagent-model-precedence** PARTIAL→CONFIRMED
  (model-config.md env table + sub-agents.md 4-step resolution order;
  inherit==unset v2.1.196).
- **NEW CLAIM — agent-frontmatter-hooks** CONFIRMED (sub-agents.md frontmatter
  table + "Define hooks for subagents"); plugin agents ignore frontmatter hooks.
- **DOWNGRADED — nested-spawn-hooks** CONFIRMED→PARTIAL: docs are ambiguous on
  whether settings.json PreToolUse fires inside subagents; frontmatter
  replication covers nested spawns either way (not load-bearing).
- **UPGRADED — session-controls** PARTIAL→CONFIRMED with the real
  `claude agents --json` schema (`startedAt`, `state` ∈
  working|blocked|done|failed|stopped). Watchdog sort key fixed
  (`started_at`→`startedAt`) and a state-staleness check added.
- **available-models-gate**: enforcement against subagent frontmatter, the
  Agent tool model param, AND `CLAUDE_CODE_SUBAGENT_MODEL` is explicitly
  documented; managed settings parse tolerantly, user files strictly.
- **Threshold ladder rationalized** (escalation must be monotonic):
  statusline amber 70 / red 90; throttle warn 70 / crit 80 (= SOFT);
  budget warn 70 / soft 80 / hard 90 (was 92); watchdog 94 (was 90 — it kills
  sessions and must fire LAST). Budget WARN band now blocks `fable` only
  (was fable+opus — it was silently degrading the opus reviewer);
  added `CC_BUDGET_EXEMPT_RE` for cheap always-allow MCP tools.
- **Statusline colors fixed**: output is captured (never a tty), so the old
  `-t 1` check disabled ANSI permanently; now gated on CC_STATUSLINE_NOCOLOR.
- **NEW — offline test suite** `tests/` (behavior transparency below
  thresholds, gating above, fail-open on every breakage mode, merge safety +
  idempotency, sandboxed end-to-end install, hook-latency budget).
  `install.sh` now runs it as step 5.

## 2026-07-14 — baseline established (docs v2.1.183)

First verification pass. Verified the version-dependent claims in `claims.json`
against `code.claude.com/docs` (latest documented version **2.1.183**, June 19
2026). Notable results vs the design's original assumptions (which cited
v2.1.196/198/203 — *ahead of* the current docs, hence unconfirmable):

- **CHANGED — spawn gating.** Subagent spawning is not a `PreToolUse` tool call
  in current docs; it surfaces as `TaskCreated`/`SubagentStart`. Guards were
  re-registered on `PreToolUse` **and** `TaskCreated`/`SubagentStart` with
  event-aware blocking (JSON deny on PreToolUse, exit-2 on lifecycle events).
  *[Superseded 2026-07-16: this finding was backwards — see the entry above.]*
- **CHANGED — tool rename.** Spawn tool is `Agent` (was `Task`, v2.1.63). Guards
  already match both; probes updated.
- **CONFIRMED — nested-spawn hook gap.** settings.json PreToolUse doesn't fire in
  subagent context → gate replicated in agent frontmatter (kept).
  *[Downgraded to PARTIAL 2026-07-16 — docs ambiguous; replication kept.]*
- **CONFIRMED — availableModels hard gate** with real per-OS managed-settings
  paths (added to `managed-settings.snippet.json`).
- **CONFIRMED + bonus — telemetry** carries `agent.name` and `query_source`
  attributes → subagent drill-down is available from METRICS, not only traces.
- **CONFIRMED — watchdog CLI** (`claude agents --json`, `claude stop <id>`).
- **UNVERIFIED (kept, flagged)** — `CLAUDE_CODE_SUBAGENT_MODEL` (on model-config
  but not env-vars), built-in `Explore`=haiku, `CLAUDE_DISABLE_ADOPT`,
  `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, the 1.5M-token workflow warning. These
  don't break anything — the design degrades safely — but are marked
  verify-on-update.

Baseline pinned. `version.lock` will trip the verify skill again on the next
version change.

<!-- next entry goes ABOVE this line -->
