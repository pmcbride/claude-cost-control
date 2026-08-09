# Cost-control validation changelog

Append-only. Each entry is one run of the `cost-control-verify` skill: the
Claude Code version it verified against, what changed vs the previous baseline,
and which files were patched. Newest at top. Never edit past entries.

---

## 2026-07-17 — first-install baseline, pinned to v2.1.212

Baseline established for the actually-installed build (`claude --version` →
`2.1.212`), superseding the unpinned 2026-07-16 doc fetch. Verified live against
code.claude.com (hooks.md, sub-agents.md, statusline.md, model-config.md) under
the evidence rule: every verdict below is backed by a verbatim quote stored in
`claims.json`. The hooks.md verdicts were additionally spot-checked against the
raw primary source (`curl` of hooks.md) — which caught a summarizer error, see
below. No subagents were used for this pass.

**No executable change was needed. Zero HITL patches proposed — every hook,
matcher, threshold, and field probe in the bundle is correct as shipped on
v2.1.212.** The escalation ladder (70/80/90/94) and the `Agent|Task` PreToolUse
wiring are unaffected by everything found here.

- **UPGRADED — `spawn-tool-input-schema` UNVERIFIED→CONFIRMED (high).** The most
  load-bearing open risk in the bundle is now closed. hooks.md publishes the
  Agent tool-input table (`##### Agent — Spawns a subagent`): `prompt`,
  `description`, `subagent_type`, and **`model`** ("Optional model alias to
  override the default"). The guards' primary probes `.tool_input.model` and
  `.tool_input.subagent_type` are **confirmed correct**, so the documented
  failure mode (wrong paths → `model=''` → silent allow) is retired. The
  `.params.model`/`.opts.model` fallbacks are now redundant but harmless — left
  in place deliberately (they cost nothing and absorb a future rename).
  *Process note:* the doc-fetch summarizer answered "NOT FOUND" for this table;
  a raw-source grep found it at hooks.md line ~1455. The skill's spot-check rule
  is what caught this — do not skip it.
- **UPGRADED — `explore-agent-model` UNVERIFIED→CONFIRMED (high).** sub-agents.md:
  "As of v2.1.198, Explore inherits the main conversation's model instead of
  always running on Haiku", and "define one with `model: haiku` to keep
  exploration on a lower-cost model". The bundle's `agents/explore.md` is exactly
  the documented remedy — and on v2.1.212 it is **load-bearing, not decorative**:
  without it, Explore inherits an Opus/Fable lead session and explores at lead
  cost.
- **NEW FACT — `subagent-model-precedence` (v2.1.211, applies to this install).**
  A per-invocation `model` now survives resume/follow-up; before v2.1.211 resuming
  dropped it and reverted to frontmatter or the main conversation's model. The
  old silent revert-to-lead-model-on-resume cost leak is gone. Verdict stays
  CONFIRMED.
- **NEW CAVEAT — `available-models-gate` (v2.1.210).** Relevant to this machine
  specifically (`permissions.defaultMode: "auto"` + Fable lead): if an
  `availableModels` allowlist excludes Sonnet 5, the auto-mode permission
  classifier stops running on cheap Sonnet 5 and falls back to the session model,
  "or on an Opus model when the session runs on Fable 5" — a silent per-decision
  cost *increase* from a gate meant to save money. **Any allowlist placed here
  must include `sonnet`.** Folded into the still-deferred managed-settings
  decision. Verdict stays CONFIRMED.
- **WORDING DRIFT — `spawn-gating-event` (verdict unchanged: CONFIRMED).** The
  baseline quoted SubagentStart as "Shows stderr to user only"; the v2.1.212
  decision-control table now reads "Context only … No blocking or decision
  control". Same mechanism, new wording — quote refreshed. Also `permissionDecision`
  now takes a 4th value, `defer` (allow/deny/ask/defer); the guards only emit
  `deny`, so no change. `TaskCreated` unchanged ("When a task is being created via
  `TaskCreate`") and additionally documented as taking no matcher.
- **RE-CONFIRMED, unchanged (quotes refreshed to verbatim):**
  `statusline-rate-limits` (the `// empty` jq guard the scripts use is the
  documented recommendation; stdout is captured, never a tty — colors correctly
  gated on `CC_STATUSLINE_NOCOLOR` only), `agent-frontmatter-hooks` (plugin
  subagents still ignore frontmatter `hooks`; the bundle's agents live in
  `~/.claude/agents/`, so they're covered).
- **STILL PARTIAL — `nested-spawn-hooks`.** Whether settings-level PreToolUse
  fires inside a subagent remains ambiguous (`agent_id` "present only when the
  hook fires inside a subagent call" implies yes; no page says so outright). Not
  load-bearing — the frontmatter-replicated gate covers nested spawns either way.
  Depth limit now confirmed verbatim: fixed at five, not configurable.
- **NOT RE-FETCHED this pass** (deliberate token frugality; carrying 2026-07-16
  verdicts forward, recorded in `claims.json:baseline_scope_note`):
  `workflow-size-config`, `telemetry-metrics`, `session-controls`,
  `output-styles`, `hooks-context-injection`, `usage-attribution`,
  `claude-version-cmd` — all prose/dashboard/doc surfaces, no guardrail behavior.
- **OPPORTUNITY (not implemented, no change made).** hooks.md now documents
  `PostToolUse.tool_response` for Agent calls carrying `resolvedModel`
  (v2.1.174+, "the model the subagent actually runs on, which can differ from the
  `model` value in `tool_input`"), `totalTokens`, `totalDurationMs`,
  `totalToolUseCount`, and a `usage{}` breakdown — a documented surface for exact
  per-subagent cost attribution, which the bundle currently only infers. Caveat:
  as of v2.1.198 subagents run in the background by default, so an omitted
  `run_in_background` yields `status: "async_launched"` and **no usage fields**.

Files patched: `manifest/claims.json` (verdicts/quotes/versions + pinned
baseline + scope note), `manifest/CHANGELOG.md` (this entry),
`manifest/version.lock` (2.1.212 / verified). No hook, agent, statusline, or
settings file was touched. Edits were made in the git repo and pushed out with
`make sync`, per the repo-is-source-of-truth rule.

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
