# Usage & cost dashboard

Two ways to see where your tokens go. Start with the quick one.

## Option A — zero infra (30 seconds)

```bash
python3 parse_transcripts.py --hours 5 --by agent
```

Parses your local session transcripts and prints token + weighted-cost totals
grouped by model, session, or subagent. `--by agent` is the one that answers
"which subagent burned my window." No Docker, no telemetry env. Caveat: the
transcript format is internal and can change between Claude Code releases; if a
column goes blank, tweak `extract_usage()` (or use `npx ccusage`, a maintained
equivalent).

## Option B — live Grafana dashboard (drill-down over time)

```bash
mkdir -p ~/.claude/logs/otel && chmod 777 ~/.claude/logs/otel   # one-time, see "Persistence" below
docker compose up -d
```

Then enable telemetry for Claude Code (see `telemetry.env.example` — the
`settings.json` `env` block is the tidy way) and restart Claude Code.

- Grafana: http://localhost:3000 → *Claude Code / Usage & Cost* (anon admin)
- Collector raw metrics: http://localhost:8889/metrics
- Prometheus: http://localhost:9090

### Persistence — what survives what

All four services run `restart: unless-stopped`, so they come back after a
Docker or host restart as long as Docker itself is set to start on login
(Docker Desktop → Settings → General → "Start Docker Desktop when you sign
in"). Data survival per signal:

| Signal | Where it lives | Survives container recreation? | Survives `make sync`? |
|---|---|---|---|
| Metrics (Prometheus) | `prom-data` docker volume | ✅ | ✅ (volume, not bind mount) |
| Traces (Tempo) | `tempo-data` docker volume | ✅ | ✅ |
| **Logs** (per-request events) | `~/.claude/logs/otel/claude-code-logs.json` (host bind mount) | ✅ | ✅ |

Logs are bind-mounted to a **host** path, not stored under `dashboard/`,
because `make sync` does `rsync -a --delete` of the repo's `dashboard/` into
the installed copy at `~/.claude/cost-control/dashboard` — anything written
inside that tree would be wiped on the next sync. The collector container
runs as the image's non-root uid `10001`, so the host directory needs to be
writable by it before first start (`chmod 777` above is the quick path; on a
shared host prefer `chown -R 10001:10001 ~/.claude/logs/otel` instead). The
file is JSON Lines (one OTLP log batch per line), rotated by the collector at
50 MB / 5 backups (`dashboard/otel-collector-config.yaml`, `file` exporter) —
it will not grow unbounded.

**To stop telemetry for good**: `docker compose down` (add `-v` to also drop
the Prometheus/Tempo volumes — this does *not* touch `~/.claude/logs/otel/`,
delete that separately if you want it gone too), then remove or comment out
`CLAUDE_CODE_ENABLE_TELEMETRY` / `OTEL_EXPORTER_OTLP_ENDPOINT` from
`~/.claude/settings.json`'s `env` block and restart Claude Code. Telemetry
enabled with the stack down doesn't error — Claude Code just drops every
OTLP export at the network layer (see "Telemetry on, stack down" below).

**Metrics** (Prometheus) give aggregate burn by model / session / token-type over
time — and, verified against docs, also by **subagent**: the
`claude_code.token.usage` metric carries `agent.name` and `query_source`
attributes. `query_source` is one of `"main"`, `"subagent"`, or `"auxiliary"`, so
splitting main-vs-subagent burn works without traces.

⚠️ **`agent.name` is redacted for your own agents.** Docs (monitoring-usage.md):
"Built-in agent names and agents from official-marketplace plugins appear
verbatim. Other user-defined agent names are replaced with `"custom"`." This
bundle's `worker`/`reviewer` agents therefore collapse into a single `custom`
series — you can see *that* custom subagents burned tokens, not *which one*.
There is **no un-redaction switch for this metric attribute**: as of the
v2.1.226 docs, `OTEL_LOG_TOOL_DETAILS=1` un-redacts `workflow.name`, tool-span
attributes, and log-event fields, but the `agent.name` definition on the token
counter carries no such gate (verified 2026-08-09 — don't burn time hunting one).

Practical splits, best first:

- **By model (the useful proxy):**
  `sum by (model) (rate(claude_code_token_usage_tokens_total[$__rate_interval]))`
  — under this bundle's routing rubric (haiku = explore, sonnet = work,
  opus = review), model ≈ role, and `model` is never redacted.
- **Main vs subagent burn:** group by `query_source`
  (`"main"` / `"subagent"` / `"auxiliary"`).
- **Exact per-agent numbers:** Option A above (`parse_transcripts.py --by agent`
  reads local transcripts — no redaction), the per-spawn `PostToolUse`
  `tool_response` fields (`resolvedModel`, `totalTokens`, `usage{}`), or traces:
  tool-execution spans carry `subagent_type` when `OTEL_LOG_TOOL_DETAILS=1`.

**Traces** (Tempo) add the full call tree — enable
`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` and each subagent/stage becomes a span in
Grafana → Explore → Tempo. (An
`sum by (agent_name) (rate(claude_code_token_usage_tokens_total[$__rate_interval]))`
panel still separates BUILT-IN agents — adjust the label name to what
`:8889/metrics` shows; expect a large `custom` bucket per the redaction above.)

### If panels are empty

OTel→Prometheus rewrites metric names (dots→underscores, a unit suffix, `_total`
for counters). The dashboard assumes `claude_code_token_usage_tokens_total`,
`claude_code_cost_usage_USD_total`, `claude_code_session_count_total`. Your
version may differ. Open http://localhost:8889/metrics (or Grafana Explore →
Metrics browser), find the real names + label keys (`model`, `session_id`,
`type`), and update the panel queries. This is a one-time 5-minute fix and the
top panel of the dashboard repeats these instructions.

## Gate coverage — did the guards even see it?

```bash
./gate-coverage.sh --since 7d          # add --json for machine-readable
```

Options A and B say *what burned*. Neither says whether the spawn gate had a
chance to stop it. `gate-coverage.sh` joins the two logs the bundle already
writes — `SubagentStart` rows in `~/.claude/logs/agent-events.jsonl` against
`PreToolUse` decisions in `~/.claude/logs/model-guard.jsonl` — per agent type.
A type with starts but no decisions never passed through `PreToolUse`, so no
hook here could have refused it.

The documented case is Workflow `agent()` stages. First measured run
(2026-09-09 → 09-16): **143 `workflow-subagent` spawns, 0 gate decisions** — 74.5%
of all spawns in the window, carrying 36.5% of the week's tokens per the
session-report analyzer. Their only controls are the session model and an
explicit `opts.model` + `effort` on every stage.

Matching is by count per type (gate rows carry no `agent_id`), so `ungated` is a
floor when a type's gate rows outnumber its starts. Fails soft on missing logs.

## Telemetry on, stack down

If `settings.json` sets `CLAUDE_CODE_ENABLE_TELEMETRY=1` with an OTLP endpoint
but `docker compose` isn't running, every session exports to a dead endpoint and
the data is **dropped, not buffered**. Starting the stack later captures from
that point on; it cannot backfill. Options A and gate coverage read local files
and are unaffected — they are the only history for any window the stack was down.

## One report across all of it

The `/usage-report` skill runs the live window check, the session-report
analyzer (or Option A as fallback), gate coverage, and — when the stack is up —
Prometheus queries, then joins them: tokens by ungated agent type is the number
none of the sources produces alone.

## What each answers

| Question | Tool |
|---|---|
| Am I about to blow the 5-hour window? | statusline (live `5h %`) |
| Which model/session/subagent burned it? | `parse_transcripts.py --by agent`, or Grafana table |
| Burn rate over time, by model/type | Grafana timeseries |
| Exact call tree of a fan-out | Tempo traces (enhanced telemetry) |
| Could the spawn gate have stopped it? | `gate-coverage.sh` |
| All of the above, joined | `/usage-report` |
