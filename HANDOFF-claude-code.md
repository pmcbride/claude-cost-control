# Handoff prompt for Claude Code

Copy everything below the line into a Claude Code session started INSIDE the
unzipped `cost-control/` folder. It's written as an instruction to Claude Code.

---

You're installing a **Claude Code usage cost-control system** I built and had
independently reviewed. The bundle is this working directory. Read `README.md`
first (especially "What you'll actually notice day-to-day" and "How the spawn
gate works"), and `_REVIEW-INDEX.md` for the review history. Do NOT spawn
subagents for this install — it's a single-pass job and I'm watching my usage.

**Context:** this fixes runaway 5-hour usage on my Max plan. Context-window and
plan-usage are two different budgets; subagents/parallelism spend MORE usage to
save context. The bundle adds a usage statusline, a PreToolUse spawn guard
(denies fable subagents), a usage-budget circuit breaker (70/80/90 bands), a
throttle nudge, a `/cost-control on|off|status` kill switch, a terse output
style, and a self-updating validation layer. Spawn-surface facts were verified
against live code.claude.com docs on 2026-07-16; my installed version may be
newer — that's what the validation layer is for.

**Do this, in order:**

1. **Inspect before running.** Skim `install.sh` and the scripts in `hooks/`,
   `statusline/`, and `cost-control.sh`. Confirm everything writes only under
   `~/.claude` and backs up what it touches. Flag anything questionable BEFORE
   proceeding. `jq` is required (`brew install jq` if missing).

2. **Prove the bundle offline.** Run `./tests/run-all.sh`. All test files must
   pass (they prove the hooks are transparent below thresholds, gate correctly
   above them, fail open on every breakage mode, and that the settings merge
   preserves an existing config). If anything fails, STOP and show me.

3. **Preview, then install.**
   ```
   ./install.sh --dry-run   # show me the plan first
   ./install.sh             # copy files, merge settings (with backup), append CLAUDE.md, seed version.lock, re-run tests
   ```

4. **CRITICAL — my statusline must not change.** I have a custom statusLine I
   want to keep. install.sh handles this automatically: it detects my existing
   `statusLine.command` and re-points it through
   `statusline/statusline-wrap.sh '<my original command>'`, which silently
   writes the usage-state file the budget guard needs and then runs MY command
   for the display. After installing, VERIFY: show me `statusLine.command` from
   `~/.claude/settings.json` — it must contain BOTH `statusline-wrap.sh` AND my
   original command. If my original command was somehow replaced instead,
   restore it from the `.bak-*` file into the wrapper form yourself. Also
   confirm my `outputStyle` change: the bundle sets `Terse` — tell me it did,
   and that `/config` switches it back if I don't like it.

5. **Establish the baseline for MY build.** Run `claude --version`, then invoke
   the **`cost-control-verify`** skill. It diffs my version's docs against
   `~/.claude/cost-control/manifest/claims.json`, writes a CHANGELOG entry,
   auto-applies safe prose/manifest updates, and PROPOSES (never auto-applies)
   any hook/matcher/threshold change for my review. Evidence rule: it may only
   change a claim verdict on a verbatim doc quote.

6. **Live self-test** (after restarting so hooks load):
   - `/hooks` must list the cost-control hooks (PreToolUse, UserPromptSubmit,
     SessionStart, SubagentStart/Stop).
   - Try to spawn a subagent on `fable` → expect a DENIAL **and** an
     `"action":"deny"` entry in `~/.claude/logs/model-guard.jsonl` (the log line
     proves the hook fired). If not denied: use `claude --debug` to capture the
     spawn's real event/tool_name/tool_input, and propose the guard patch.
   - After one turn, `~/.claude/.usage-state.json` must contain a numeric
     `five_hour_pct` (proves my wrapped statusline is feeding the guards).
   - Run `/cost-control status`, then `/cost-control off`, confirm a fable
     spawn now passes and my statusline shows `[cc-off]`, then
     `/cost-control on`.

7. **Report back:** what installed, exact `statusLine.command` now in settings,
   test results, what the verify skill changed, self-test outcomes, and anything
   still marked UNVERIFIED/PARTIAL in claims.json for my version.

**Do NOT do without asking:** placing the managed-settings `availableModels`
gate (sudo; and read its fable lead-session tradeoff note first — I use fable as
a lead model), starting `watchdog-usage.sh`, or bringing up the `dashboard/`
Docker stack.
