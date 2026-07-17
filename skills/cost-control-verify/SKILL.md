---
name: cost-control-verify
description: Verify and auto-update the usage cost-management config against the CURRENT Claude Code version. Use when the version-check hook reports a SETUP or VERSION DRIFT message, when the user says "cost-control-verify", "verify cost management", "re-verify the cost hooks", "Claude Code updated", or after any `claude update`. Diffs the installed version's docs against manifest/claims.json, writes a CHANGELOG entry, applies safe updates automatically, proposes executable-code patches for review, and bumps the version lock.
---

# cost-control-verify

The self-updating validation layer for the cost-control bundle. Claude Code ships
often and changes hook events, spawn schemas, statusline fields, and config keys
between versions. This skill re-checks every version-dependent claim against the
docs for the version you're actually running, records the delta, and updates the
config so it never silently rots.

Bundle root is `~/.claude/cost-control/` (override with `$CC_ROOT`). Key files:
`manifest/claims.json` (the baseline), `manifest/version.lock` (pinned version),
`manifest/CHANGELOG.md` (history), `tests/` (offline behavior suite), and the
hooks/agents/statusline/output-styles it governs.

## When this runs

- **First install** — version-check hook emits `COST-CONTROL SETUP`. Establish the
  baseline against the current version and run the self-test.
- **After an update** — version-check hook emits `COST-CONTROL VERSION DRIFT
  vX→vY`. Diff and update.
- **On demand** — the user invokes it.

If neither the hook nor the user prompted you and versions match
(`claude --version` == `manifest/version.lock` pinned), say so and stop — don't
burn tokens re-verifying an unchanged version.

## Procedure

1. **Establish scope.** Run `claude --version`; read `version.lock`, `claims.json`,
   and the tail of `CHANGELOG.md`. If pinned == current and no `.drift` flag,
   stop (already verified).

2. **Verify each claim against current docs.** For every claim in `claims.json`,
   fetch its `doc_urls` with the **`code-docs`** skill (it serves live
   code.claude.com docs) and compare the documented behavior/schema to the
   claim's `current_value`. Be frugal: batch claims that share a doc page into
   one fetch; don't re-fetch a page you already pulled this run. Classify each:
   `unchanged` · `changed` (record the new value) · `newly-confirmed` (was
   UNVERIFIED, now in docs) · `still-unverified`.

   **Evidence rule (added after the 2026-07-16 review):** a claim's verdict may
   only change on the strength of a VERBATIM quote from the doc page, kept next
   to the verdict. "REFUTED"/"NOT-IN-DOCS" without a quote from a successfully
   fetched page is not evidence — a truncated or failed fetch proves nothing.
   Never accept a delegate agent's verdict without the quote; if you delegate
   fetching at all, require quotes + URLs back and spot-check one against the
   primary source before acting on any of them.

3. **Write a CHANGELOG entry** at the top (above the `<!-- next entry -->`
   marker): the version verified against, and a bullet per claim that changed,
   became confirmed, or newly diverged. If nothing changed, still log a one-line
   "re-verified vN, no changes" entry so the history shows the check happened.

4. **Apply SAFE updates automatically** (low blast radius):
   - Update each claim's `verdict`/`current_value`/`since_version`/`confidence`
     and `baseline_docs_version`/`baseline_verified_date` in `claims.json`.
   - Patch **prose/config docs**: `ADR-…md`, `README.md`, `CLAUDE.snippet.md`,
     `session-topology-and-controls.md`, `dashboard/README.md`, and doc-only
     values (real paths, flag names, version numbers, threshold values *quoted
     in prose*).
   - Patch **declarative config** where a value is unambiguous (e.g. a renamed
     settings key, a corrected managed-settings path, an added telemetry
     attribute in a Grafana query).

5. **PROPOSE, don't apply, executable-logic changes (HITL).** For any change that
   would alter the *behavior* of an executable guardrail — `hooks/*.sh`,
   `agents/*.md` frontmatter, the spawn event/matcher wiring in
   `settings.snippet.json`, a hook's field-path probes, **or any numeric
   threshold default inside a hook script** (thresholds ARE guardrail behavior;
   only prose mentions of thresholds are auto) — do NOT silently rewrite.
   Present a precise patch (file + anchor + before/after) and the evidence
   (doc quote + URL), then ask the user to confirm before writing. A guardrail
   that fails *wrong* is worse than one that's briefly stale.
   Use the `affects` array on each claim to know exactly which files a changed
   claim touches.

6. **Re-run the tests + self-test** after applying/confirming changes, so the
   baseline reflects verified-working, not just verified-documented.

7. **Bump the lock.** Write `version.lock` `pinned_version` = current,
   `status` = `verified`, and delete `manifest/.drift`.

## Safe vs HITL — the policy

| Change kind | Action |
|---|---|
| Claim verdict / value / version fields in `claims.json` | Auto |
| Prose in ADR / README / CLAUDE.snippet / topology / dashboard docs | Auto |
| Doc-only values: managed-settings paths, flag names, URLs, thresholds *in prose* | Auto |
| Grafana query label/metric-name fix | Auto (note in changelog) |
| Hook block mechanism, event registration, tool matcher, field-path probes | **Propose → confirm** |
| Numeric threshold defaults in `hooks/*.sh` / `statusline/*.sh` | **Propose → confirm** |
| Agent frontmatter model/tool/hook changes | **Propose → confirm** |
| Anything that could make a guardrail deny-wrong or fail-open silently | **Propose → confirm** |

## Self-test (prove it actually fires on this build)

Docs and reality can differ by build. Two layers:

0. **Offline suite first** (no tokens, ~5s): `~/.claude/cost-control/tests/run-all.sh`.
   All green proves the scripts behave (transparent below thresholds, gating
   above, fail-open on breakage) — it does NOT prove Claude Code invokes them.
1. **Spawn gate (live):** in a scratch session, ask Claude to spawn a subagent on
   `fable`. Expect a denial AND a `"action":"deny"` entry in
   `~/.claude/logs/model-guard.jsonl`. The log entry matters: if the
   availableModels managed gate is installed, the spawn can be blocked by the
   allowlist instead — the denial alone doesn't prove the hook fired. No log
   entry + no denial → the spawn event/matcher is wrong for this version →
   HITL patch to `settings.snippet.json` + guards (use `claude --debug` to see
   the event/tool_name the spawn emits).
2. **Statusline usage:** confirm `~/.claude/.usage-state.json` is being written
   with a numeric `five_hour_pct` (means the statusline is receiving
   `rate_limits`). If absent, the statusline schema changed → HITL patch.
3. **Hooks actually registered:** run `/hooks` (or check `claude --debug`
   startup) and confirm the cost-control hooks are listed for PreToolUse,
   UserPromptSubmit, SessionStart, SubagentStart/Stop. User settings files are
   validated STRICTLY — an invalid settings.json kills every hook silently.
4. **Spawn payload (only if the gate self-test failed):** add a temporary logging
   hook that dumps stdin on `PreToolUse`, spawn a subagent, and read the real
   field paths from the dump; update the probes in the guards accordingly.

## Cost note

This skill is itself token-spend, so it's gated to run only on version change or
explicit request — never on every session. Verifying ~15 claims is a handful of
doc fetches; batch them. Do not fan out subagents to do this — a single frugal
pass through `code-docs` is correct, and per the evidence rule above, delegated
verdicts without verbatim quotes must not be trusted anyway.
