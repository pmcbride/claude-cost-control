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
docker compose up -d
```

Then enable telemetry for Claude Code (see `telemetry.env.example` — the
`settings.json` `env` block is the tidy way) and restart Claude Code.

- Grafana: http://localhost:3000 → *Claude Code / Usage & Cost* (anon admin)
- Collector raw metrics: http://localhost:8889/metrics
- Prometheus: http://localhost:9090

**Metrics** (Prometheus) give aggregate burn by model / session / token-type over
time — and, verified against docs, also by **subagent**: the
`claude_code.token.usage` metric carries `agent.name` and `query_source`
(`"subagent"` vs `"main"`) attributes, so you can `sum by (agent_name)` or split
main-vs-subagent burn without traces. **Traces** (Tempo) add the full call tree —
enable `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` and each subagent/stage becomes a
span in Grafana → Explore → Tempo. (Add a panel:
`sum by (agent_name) (rate(claude_code_token_usage_tokens_total[$__rate_interval]))`
— adjust the label name to what `:8889/metrics` shows.)

### If panels are empty

OTel→Prometheus rewrites metric names (dots→underscores, a unit suffix, `_total`
for counters). The dashboard assumes `claude_code_token_usage_tokens_total`,
`claude_code_cost_usage_USD_total`, `claude_code_session_count_total`. Your
version may differ. Open http://localhost:8889/metrics (or Grafana Explore →
Metrics browser), find the real names + label keys (`model`, `session_id`,
`type`), and update the panel queries. This is a one-time 5-minute fix and the
top panel of the dashboard repeats these instructions.

## What each answers

| Question | Tool |
|---|---|
| Am I about to blow the 5-hour window? | statusline (live `5h %`) |
| Which model/session/subagent burned it? | `parse_transcripts.py --by agent`, or Grafana table |
| Burn rate over time, by model/type | Grafana timeseries |
| Exact call tree of a fan-out | Tempo traces (enhanced telemetry) |
