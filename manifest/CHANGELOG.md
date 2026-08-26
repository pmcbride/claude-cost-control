# Cost-control validation changelog

Append-only. Each entry is one run of the `cost-control-verify` skill: the
Claude Code version it verified against, what changed vs the previous baseline,
and which files were patched. Newest at top. Never edit past entries.

---

## 2026-08-26 — drift check v2.1.226 → v2.1.233

Triggered by the version-check hook (`.drift` = 2.1.233). Verified against raw
primary-source markdown (`curl` of 15 `code.claude.com/docs/en/*.md` pages +
local grep). **Caveat handled explicitly this pass: the live docs track
v2.1.246, ahead of the installed v2.1.233** — the changelog was read across both
v2.1.227–233 (in-range) and v2.1.234–246 (to keep post-lock doc statements out
of the baseline; those are marked POST-LOCK in `claims.json`). No subagents used.

**No executable guardrail change was required by the version drift. One HITL
patch proposed (install.sh — unrelated to the drift, see below).** The `Agent`
tool_input schema (4 fields byte-for-byte), the `PreToolUse` deny mechanism,
the `Agent|Task` matcher, the statusline `rate_limits` fields, and the
`claude agents --json` fields are all unchanged on v2.1.233. All 16 claims
remain CONFIRMED (6 verbatim-unchanged, 10 annotated with refinements).

**🔧 FOUND + STOPGAPPED — the INSTALLED offline suite is not self-contained
post-PR #5.** `test-install.sh` failed 8/13 when run from the installed tree:
it sandbox-runs `install.sh`, whose `SRC` is the directory containing the
script — here the installed copy itself, which by PR #5 design no longer
carries the `agents/`, `skills/`, `output-styles/` source dirs (the legacy
self-clean removes them from `$DEST`; the true source lives in the
`claude-cost-control` repo). So the sandboxed install dies at
`cp $SRC/output-styles/terse.md` and 7 assertions cascade. Same mechanism =
a real footgun: running `install.sh` from the installed copy (`SRC == DEST`)
copies the source dirs to `~/.claude/` and then `rm -rf`s its own copies. The
ACTIVE copies under `~/.claude/{agents,skills,output-styles}` were correct
throughout (byte-identical to the repo); no guard was ever degraded. STOPGAP
applied: re-seeded the three dirs in the installed tree from the active copies
so the installed suite is self-contained again — the next `make sync` /
`install.sh` will self-clean them and the suite goes red again from this tree.
The durable fix is a repo design decision, **proposed as HITL, not applied**:
either drop `agents/skills/output-styles` from the legacy-clean list and ship
them in the installed bundle, or make `test-install.sh` resolve `SRC` to the
repo checkout (and have `install.sh` abort with a clear message when `SRC`
lacks the source dirs).

**Addendum (2026-08-26, same day — HITL resolved, option 1 chosen by Patrick,
shipped as PR #7):** `install.sh` and `make sync` now ship
`agents/skills/output-styles` INSIDE the bundle, replaced wholesale on every
install/sync (`rm -rf` + `cp -a` / `rsync --delete`) so the in-bundle copies
can never drift from the repo — preserving the anti-rot intent of the old
cleanup while keeping the installed tree a complete install source with a
self-contained offline suite. `install.sh` skips the ship step when
`SRC == DEST` (resolved via `pwd -P`), closing the self-delete footgun.
`test-install.sh` now asserts the dirs are present AND that a pre-planted
stale in-bundle copy is replaced. The stopgap re-seed above is superseded.

- **DOCS RESTRUCTURE (affects future verifies, not behavior).** The settings key
  reference moved `settings.md` → `settings-reference.md`, and managed-settings
  delivery/paths moved to a new `managed-settings.md` page (per-OS paths
  unchanged verbatim; the legacy Windows `ProgramData` path is explicitly not
  read). `doc_urls`/`verify_sources` updated on `workflow-size-config`,
  `available-models-gate`, and the top-level list.
- **⚠️ CHANGED — the Large-workflow warning threshold now tracks your chosen
  size guideline.** workflows.md: *"If you choose a size guideline yourself, its
  agent count replaces the 25-agent threshold. The built-in default guideline
  leaves the threshold at 25."* With this install's explicit `medium` (<15), the
  warning fires at **>15 scheduled agents**, not >25. The 1.5M projected-token
  trigger and the ultracode exemption are unchanged.
- **⚠️ KNOWN PLATFORM BUG ON THIS BUILD — stale rate-limit % after an idle
  reset.** Fixed post-lock in v2.1.243: *"the status line rate_limits fields and
  /usage still showing a rate-limit window's pre-reset usage percentage after
  the window reset while the session was idle."* On v2.1.233,
  `five_hour_pct` can read stale-high until the next API response, so
  `throttle.sh`/`guard-usage-budget.sh` may briefly over-throttle right after a
  window reset. Conservative direction; no guard change.
- **CORRECTED — settings-file validation is not flat "reject the whole file".**
  settings.md now splits **Settings Error** (whole file invalid → dialog:
  fix/exit/continue-without; `-p` runs skip the file silently) from **Settings
  Warning** (individual bad entries skipped, rest of the file **stays in
  effect**). The silently-dead-hooks failure mode survives only for whole-file
  JSON/schema errors headless or via continue-without. `README.md` and the
  skill's self-test note reworded; `available-models-gate` claim annotated.
- **REFINED — PostToolUse usage fields are NOT a per-subagent rollup.** hooks.md
  now states `totalTokens`/`usage` *"cover the final request only"* and points to
  telemetry counters filtered to `query_source: "subagent"` for cost rollups.
  Also v2.1.232: non-teammate spawns in interactive sessions now run in the
  **background by default** (fork on by default), so `tool_response` is usually
  `async_launched` with no usage fields at all.
- **NOTED — TaskCreate/TodoWrite tools removed by default on newer models**
  (v2.1.233; `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` restores). `TaskCreated`
  effectively never fires on this install's models; zero wiring impact.
- **NOTED — workflow fan-outs now stagger same-prefix siblings for prompt-cache
  reuse** (v2.1.229, `CLAUDE_CODE_WORKFLOW_PREFIX_STAGGER_MS=0` disables) —
  softens the cold-cache write premium for workflow fan-outs specifically.
- **POST-LOCK heads-ups recorded in claims (apply only after the next update):**
  v2.1.234 removed the "Default teammate model" `/config` setting (teammates use
  the leader's model unless the spawn names one — keep explicit models on
  teammate specs); v2.1.243 adds `promptCacheTtl`/`subagentPromptCacheTtl`
  (API-key/cloud-provider only) and `modelPricing`, plus per-subagent
  model+effort in `/tasks`.

Self-test results on v2.1.233 after the repairs: offline suite fully green —
test-hooks 57/57, test-merge 11/11, test-install 13/13, test-performance 4/4.
Live spawn gate: an `Agent` spawn with `model: fable` was DENIED and logged
(`model-guard.jsonl`: `{"event":"PreToolUse","tool":"Agent","model":"fable",
"action":"deny"}`) — the hook itself fired (no availableModels gate installed,
so the denial is attributable to the hook). Statusline path live:
`~/.claude/.usage-state.json` held numeric `five_hour_pct` (42). All five hook
events (PreToolUse, UserPromptSubmit, SessionStart, SubagentStart/Stop) present
in `settings.json`. Lock bumped to 2.1.233, `.drift` cleared.

## 2026-08-09 — drift check v2.1.212 → v2.1.226

Triggered by the version-check hook (`.drift` flag present). Verified against
**raw primary-source markdown** — `curl` of the twelve `code.claude.com/docs/en/*.md`
pages plus the full changelog across v2.1.213–v2.1.226 — rather than a summarizing
fetch, because the 2026-07-17 run caught a summarizer false-negative. Every verdict
below carries a verbatim quote in `claims.json`. No subagents were used.

**No executable guardrail change was required. Zero HITL patches proposed.** The
`Agent` tool_input schema, the `PreToolUse` deny mechanism, the `Agent|Task`
matcher, the statusline `rate_limits` fields, and the `claude agents --json`
fields the watchdog sorts on are all unchanged on v2.1.226. Two **comment-only**
corrections were made in `hooks/guard-subagent-model.sh` (stale doc quotes in the
header block; no logic, probes, or thresholds touched). Offline suite re-run green
(PASS=11/11 hooks, 4/4 performance, all files) and `~/.claude/.usage-state.json`
holds a live numeric `five_hour_pct`, so the statusline path is confirmed working
end to end.

- **RESOLVED — `nested-spawn-hooks` PARTIAL→CONFIRMED (low→high).** The
  longest-standing ambiguity in the manifest is closed. hooks.md now says it
  outright: *"Hooks from settings files, managed policy settings, and plugins also
  run inside subagents. When a subagent calls a tool, tool events such as
  `PreToolUse` and `PostToolUse` fire the same configured hooks as in the main
  conversation, and the input carries the `agent_id` and `agent_type` common input
  fields."* The settings-level gate covers subagent-originated spawns. The
  frontmatter-replicated guard in `agents/*.md` becomes **redundancy rather than
  the sole nested gate** — kept, since it costs nothing and plugin subagents cut
  the other way (they ignore frontmatter `hooks:` entirely and rely on the
  settings gate).
- **CHANGED — nesting depth, twice, inside this range.** The baseline recorded
  *"a subagent at depth five … the limit is fixed and not configurable"*. Both
  halves are superseded: v2.1.217 disabled nesting by default, then v2.1.219 set
  the default to **3 layers below the main conversation**, configurable via
  **`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`** (set `1` to disable). At the limit the
  `Agent` tool is withheld rather than erroring.
- **NEW CLAIM — `subagent-fanout-caps`.** Four platform ceilings that sit under
  this bundle's guards, none of which existed in this form at the baseline:
  **`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`** (default **20**, v2.1.217+); the depth
  limit above; **`--max-budget-usd`**, which since v2.1.217 denies new spawns *and
  halts running background subagents* at the cap but is **print-mode only**; and
  the removal of the 200-spawn lifetime cap.
- **⚠️ REGRESSION IN COVERAGE — the 200-subagent-per-session cap is GONE**
  (v2.1.224: *"Removed the 200-subagent-per-session spawn cap; long-running
  sessions no longer refuse new agents"*). sub-agents.md confirms: *"There's no
  limit on the total number of subagents Claude can spawn over a session."* A
  long-lived thin-brain session now has **no built-in lifetime ceiling** — only
  concurrency, depth, and this bundle's burn-rate guards bound it. Documented in
  `session-topology-and-controls.md` and `CLAUDE.snippet.md`.
- **⚠️ ULTRACODE IS EXEMPT FROM TWO SAFETY NETS.** sub-agents.md: *"Sessions with
  ultracode active are exempt: the limit isn't enforced there"* (concurrency), and
  workflows.md: *"Sessions with ultracode on don't show the warning"*
  (Large-workflow). Turning on ultracode removes the concurrency cap **and** the
  runaway-workflow warning at the same time. Compounding this, statusline
  `effort.level` reports ultracode as plain `xhigh`, so **no statusline can detect
  that a session is in this state**.
- **UPGRADED — `workflow-size-config` PARTIAL→CONFIRMED (medium→high).** The
  `Large workflow` warning the 2026-07-16 baseline flagged as *"NOT in docs (likely
  internal heuristic)"* is now published and the researched numbers were exactly
  right: *"When a workflow schedules more than 25 agents, or its projected token
  total passes 1.5 million … shows a `Large workflow` warning"* (v2.1.203+).
- **CORRECTED CONFIG FACT — workflow size is now a settings key.**
  `settings.snippet.json` asserted *"Not a settings.json key; set it in-app."*
  That is **false** as of v2.1.219: `workflowSizeGuideline` (`unrestricted|small|
  medium|large`) is settable in any settings file, **takes precedence over
  `/config`**, and hides that `/config` row. The default is now `medium` (was
  `unrestricted` before v2.1.219). Comment rewritten; a commented-out
  `//workflowSizeGuideline: "small"` line added for the user to enable.
- **⚠️ CORRECTED DASHBOARD CLAIM — `agent.name` is redacted for your own agents.**
  monitoring-usage.md: *"Built-in agent names and agents from official-marketplace
  plugins appear verbatim. Other user-defined agent names are replaced with
  `\"custom\"`."* The bundle's `worker`/`reviewer` agents therefore collapse into a
  single `custom` series — the previously-advertised `sum by (agent_name)`
  per-agent breakdown **does not work for them**. `query_source` also has three
  values (`main`/`subagent`/`auxiliary`), not two. `dashboard/README.md` corrected
  with the working alternatives (traces, or the `PostToolUse` `tool_response` cost
  fields).
- **CHANGED — `available-models-gate` (v2.1.222) blocked-alias behavior.** The
  baseline's flat rule ("an excluded subagent value is skipped and the subagent
  runs on the inherited model") is now only the fallback branch: a blocked
  **family alias** now substitutes to *"the newest version of that family the
  allowlist permits"*. A fable-blocking allowlist still behaves as intended (no
  fable version is permitted, so substitution has nothing to land on), but a
  version-pinning allowlist now substitutes where it used to fall back. The
  v2.1.210 "include `sonnet` or the auto-mode classifier gets expensive" caveat
  from the last pass still stands.
- **NEW PRECONDITION — `agent-frontmatter-hooks` (v2.1.218).** Project-level
  agents' frontmatter hooks now require workspace trust for the folder holding the
  agent file; untrusted, *"the subagent still runs, but Claude Code skips its
  frontmatter hooks"* with only a debug-log error. **This install is exempt** —
  *"Hooks from user-level subagents in `~/.claude/agents/` … run without this
  step"* — but a project-scoped copy of these agents would silently lose its guard.
- **NEW FACT — `usage-attribution` (v2.1.222).** `/usage` previously *"attributed
  every subsequent request to that server"* after a single MCP call. Any MCP cost
  share read from `/usage` before v2.1.222 was inflated; re-measure before using
  one as a baseline.
- **RE-VERIFIED UNCHANGED (verbatim re-match, no edits needed):**
  `spawn-gating-event`, `spawn-tool-input-schema` (the four `tool_input` fields are
  byte-for-byte identical; `modelsUsed` added on the `PostToolUse` side),
  `subagent-model-precedence`, `explore-agent-model`, `statusline-rate-limits`,
  `session-controls` (the `--json` fields `watchdog-usage.sh` depends on),
  `output-styles`, `hooks-context-injection`, `claude-version-cmd`.

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
