# cost-control test suite

Offline, no Claude Code required — just `bash` + `jq`. Run before restarting
Claude Code after any install or edit:

```bash
./tests/run-all.sh          # everything (~30s incl. the latency benchmark)
./tests/run-all.sh --quick  # skip the benchmark (~5s) — what install.sh runs
```

## What "before == after" means here, concretely

The user-visible worry with a hook bundle is that installing it changes normal
behavior or adds cost. The suite pins down both:

**Behavior parity (test-hooks.sh).** Below every threshold, and for every
non-spawn tool, the guards emit *nothing* and exit 0 — by the hooks contract
that means Claude Code proceeds exactly as if no hook existed. The tests drive
each hook with synthetic payloads (the same JSON shapes the docs specify) at
50/75/85/95% usage and assert the full decision matrix:

| usage | Agent spawn (fable) | Agent spawn (sonnet/haiku) | Agent spawn (opus) | Bash | WebFetch / mcp__* | TaskCreate (todos) |
|---|---|---|---|---|---|---|
| <70% | allow | allow | allow | allow | allow | allow |
| 70–79% | **deny** | allow | allow | allow | allow | allow |
| 80–89% | **deny** | **deny** | **deny** | allow | allow | allow |
| ≥90% | **deny** | **deny** | **deny** | allow | **deny** (unless `CC_BUDGET_EXEMPT_RE`) | allow |

Plus every fail-open path: no state file, stale state (>15 min), garbage state,
garbage payload, missing jq semantics, unknown events, `CC_BUDGET_DISABLE=1`.

**Usage parity (by construction + asserted).** The guards are pure shell — they
consume zero tokens. `test-hooks.sh` asserts the below-70% case emits zero
bytes, so the prompt Claude Code sends to the model is byte-identical before
and after install. The only token-bearing additions, all bounded and asserted:

- throttle nudge: ~70 words per user prompt, only at ≥70% usage
- deny reasons: ~50 words, only when a spawn/fan-out is refused — each denial
  *replaces* an entire subagent run, so the net usage effect is negative
- version-check message: once per install / Claude Code update
- the `cost-control-verify` skill: token-spend by design, gated to version
  changes or explicit request

**Performance (test-performance.sh).** Benchmarks each hook 100× and fails if
the average exceeds `BUDGET_MS_PER_CALL` (default 25ms). Typical results are
~10–25ms per call — one `bash`+`jq` subprocess — against tool calls that take
hundreds of ms to minutes. The budget guard runs on every tool call (matcher
`*`); the model guard only on spawns; the throttle once per user prompt; the
statusline on its refresh cadence.

**Merge safety (test-merge.sh).** The exact jq program install.sh uses, against
a populated user config: preserves unrelated keys/hooks/env, keeps the user's
hook-group order, strips `//` keys (user settings validate strictly), is
idempotent, and fails closed on an invalid existing file.

**Install (test-install.sh).** Full `install.sh` run into a sandboxed
`CLAUDE_CONFIG_DIR`: files land, config survives, re-install is a no-op,
CLAUDE.md isn't duplicated.

## What this suite can NOT prove (live checks, one-time)

Offline tests prove the scripts behave; they can't prove Claude Code *invokes*
them, or that the Agent tool's `tool_input` field names match the probes on
your build. That's the `cost-control-verify` skill's live self-test (run it on
first session):

1. spawn a `fable` subagent → expect a denial **and** a `"action":"deny"` line
   in `~/.claude/logs/model-guard.jsonl` (the log line proves the *hook* fired,
   not the managed-settings allowlist)
2. confirm `~/.claude/.usage-state.json` gets a numeric `five_hour_pct`
3. `/hooks` shows the cost-control hooks registered
