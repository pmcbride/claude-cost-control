# cost-control bundle — review index (for a fresh reviewer)

This folder (`claude/cost-control/…` in the project) is the complete Claude Code
usage cost-management bundle. It's here so a fresh chat can review the whole set.

## What it is
A system to stop runaway 5-hour usage on a Max plan. Premise: context-window and
plan-usage are two different budgets; subagents/parallelism spend *more* usage to
save context. Layers: usage-aware statusline, guard hooks (deny fable/unspecified
spawns; block new fan-out as the 5h window fills), a UserPromptSubmit self-throttle,
a terse output-style, a managed-settings hard gate, a STATUS.md "project brain"
pattern, an optional telemetry dashboard, an offline test suite, and a
self-updating validation layer that re-verifies version-dependent claims whenever
Claude Code updates.

Read `ADR-claude-code-cost-control.md` for the full design + verified findings,
`README.md` for install/usage, and `REVIEW-2026-07-16-fable.md` for the last
independent review (which corrected the spawn-surface wiring — see ADR §0c).
Claims re-verified against live docs **2026-07-16**.

## Review history
- **2026-07-14** — baseline pass (docs v2.1.183). Concluded spawns were NOT a
  PreToolUse call → registered guards on TaskCreated/SubagentStart. **Wrong.**
- **2026-07-16** — independent re-verification with verbatim doc citations
  (`REVIEW-2026-07-16-fable.md`). Spawns ARE PreToolUse `Agent|Task` (the only
  blocking surface); SubagentStart can't block; TaskCreated is the task-list
  event. Wiring, thresholds, watchdog, statusline, claims, and skill updated;
  `tests/` added. All 63 offline tests pass.

## What to scrutinize (suggested review focus)
- **Guard correctness** (`hooks/guard-subagent-model.sh`, `hooks/guard-usage-budget.sh`):
  registered on PreToolUse `Agent|Task` / `*` only; SubagentStart is log-only;
  nothing on TaskCreated. Do they still fail OPEN safely? Do the `tool_input`
  probes match your build (`claude --debug`)?
- **The version-dependent claims** (`manifest/claims.json`): verdicts carry doc
  citations; `spawn-tool-input-schema` (UNVERIFIED) and `nested-spawn-hooks`
  (PARTIAL/ambiguous) are the two to test live.
- **Settings merge safety** (`install.sh` + `tests/test-merge.sh`): preserves an
  existing config, order-preserving hook dedup, strict-validation footgun on
  manual merges documented?
- **Self-updating skill** (`skills/cost-control-verify/SKILL.md`): safe-auto vs
  HITL split (thresholds in executable files are HITL); the evidence rule
  (verbatim quotes only).
- **Thresholds**: monotonic ladder 70 (nudge/amber/fable-deny) → 80 (no new
  spawns + CRIT nudge) → 90 (no heavy fan-out/red) → 94 (watchdog kills).
- **Tests** (`tests/`): do they actually prove before/after parity and bound the
  overhead? What's still only provable live?

## File map
- `ADR-…md` — design/decision record + verified findings (§7) + limitations (§6) + v3.1 correction (§0c)
- `REVIEW-2026-07-16-fable.md` — the review that drove v3.1
- `README.md`, `HANDOFF-claude-code.md`, `session-topology-and-controls.md`
- `install.sh` — idempotent installer (backs up + merges + runs tests)
- `settings.snippet.json`, `managed-settings.snippet.json`, `CLAUDE.snippet.md`
- `statusline/usage-statusline.sh`
- `hooks/` — guard-subagent-model, guard-usage-budget, throttle, watchdog-usage, version-check, log-agent-events
- `tests/` — run-all, test-hooks, test-merge, test-install, test-performance (+ README: what it proves)
- `agents/` — explore (haiku), worker (sonnet), reviewer (opus), each with a frontmatter-replicated gate
- `output-styles/terse.md`
- `manifest/` — claims.json (baseline), CHANGELOG.md, version.lock.example
- `skills/cost-control-verify/SKILL.md` — the self-updating validator
- `project-templates/` — STATUS.template.md + best-practices
- `dashboard/` — OTel Collector + Prometheus + Tempo + Grafana + parse_transcripts.py
