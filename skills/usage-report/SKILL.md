---
name: usage-report
description: Explain where Claude Code usage went and whether the cost-control guards could have stopped it — one report that joins the session-report plugin's transcript analysis, this bundle's guard logs (spawn-gate coverage), the live 5-hour window state, and the OTel/Prometheus/Grafana telemetry stack. Use when the user asks "where did my usage go", "what burned my 5-hour window", "which session / project / subagent / prompt cost the most", "why did I hit the limit", "usage report", "cost report", "session report with the guards", "are the guards working", "what did the spawn gate block", "is telemetry / Grafana capturing anything", or wants the cost-control project artifact refreshed with current usage. Prefer this over the bare session-report skill whenever the cost-control bundle is installed (~/.claude/cost-control exists) — it adds the enforcement view the plugin can't see.
argument-hint: "[24h|7d|30d|all] [--publish]"
---

# /usage-report — usage attribution + enforcement, in one pass

Four sources, each answering a question the others can't. The value of this skill is the
**join**: the transcript analysis says *what burned*, the guard logs say *what the guards did
about it*, and the gap between the two is the finding nobody else reports.

| # | Source | Answers | Blind spot |
|---|---|---|---|
| 1 | `~/.claude/.usage-state.json` (written by the statusline) | Where the 5h / 7d windows stand **right now** | No history; stale if no interactive session has rendered a statusline recently |
| 2 | session-report plugin analyzer (reads `~/.claude/projects` transcripts) | Tokens by project, session, subagent type, skill, **prompt**; cache hit and cache breaks | Knows nothing about the guards; the transcript format is internal and can drift |
| 3 | `~/.claude/cost-control/dashboard/gate-coverage.sh` (joins `agent-events.jsonl` × `model-guard.jsonl`) | How many spawns **reached the spawn gate**, how many it denied, which agent types bypass it | Counts spawns, not tokens — multiply through source 2 |
| 4 | OTel → Prometheus/Tempo → Grafana (`~/.claude/cost-control/dashboard/`) | Burn **rate over time**, main-vs-subagent via `query_source`, call trees via traces | Only has data for periods the stack was **running**; `agent.name` is redacted to `"custom"` for user-defined agents |

Cost discipline for this skill itself: run the scripts and read their **summaries**. Never
read raw transcripts or the full analyzer JSON into context — the analyzer output alone is
~200 KB. Pull fields with `jq`/`python3 -c`.

Window: `$ARGUMENTS` if given (`24h`, `7d`, `30d`, `all`), otherwise `7d`. Scratch files go in
the session scratchpad directory, never the user's repo.

## 1 · Now — the live window

```bash
jq '{five_hour_pct, seven_day_pct, context_pct, model,
     age_s: (now - .updated_at | floor)}' ~/.claude/.usage-state.json
~/.claude/cost-control/cost-control.sh status
```

If `age_s` exceeds 900 the guards are **currently disarmed** (fail-open on stale state) — say so
first; it outranks anything historical in this report.

## 2 · What burned — the session-report analyzer

Discover the plugin by glob. Its cache directory carries a content hash that changes on every
plugin update, so never pin a path:

```bash
SR="$(ls -d ~/.claude/plugins/cache/*/session-report/*/skills/session-report 2>/dev/null | tail -1)"
node "$SR/analyze-sessions.mjs" --json --since 7d > "$SCRATCH/session-report.json"   # omit --since for all
```

**Fallback when the plugin isn't installed** (or `node` is missing): the bundle's own
stdlib-only reader gives the per-agent split without the prompt-level detail:

```bash
python3 ~/.claude/cost-control/dashboard/parse_transcripts.py --hours 168 --by agent
```

Total tokens = `overall.input_tokens.total + overall.output_tokens`. Express every figure as
a **% of that total**. Extract, don't dump:

- `by_project`, `by_subagent_type`, `by_skill` — sorted by total, top rows only
- `overall.subagent.total_tokens` as a share of the whole
- `top_prompts[:10]` — `text`, `total_tokens`, `api_calls`, `subagent_calls`, `ts`
- `cache_breaks` — count per project
- `by_day[].sessions[]` — the single largest session

## 3 · What the guards did — gate coverage

```bash
~/.claude/cost-control/dashboard/gate-coverage.sh --since 7d          # table
~/.claude/cost-control/dashboard/gate-coverage.sh --since 7d --json   # for the join
```

It counts `SubagentStart` events per agent type against `PreToolUse` gate decisions per
`subagent_type`. A type with starts but no decisions **never passed through the gate**.

**The join that matters:** take each ungated agent type from this step and look up its tokens
in step 2's `by_subagent_type`. That product — *tokens no guard in this bundle could have
refused* — is the headline enforcement number. `workflow-subagent` is the documented case:
Workflow `agent()` stages bypass `PreToolUse`, so their only controls are the session model and
an explicit `opts.model` + `effort` on every stage.

Also report: total denials in the window (zero denials over a heavy week is a signal, not an
all-clear), and gate rows with an empty `model` (allowed only because
`CC_REQUIRE_EXPLICIT_MODEL` is off — they resolved from frontmatter).

## 4 · Over time — OTel / Prometheus / Grafana

First establish whether there is **any** data, in this order:

```bash
jq -r '.env // {} | with_entries(select(.key | test("OTEL|TELEMETRY")))' ~/.claude/settings.json
curl -sf -m 2 http://localhost:9090/-/ready && echo prometheus-up || echo prometheus-down
```

| Telemetry env | Stack | What to tell the user |
|---|---|---|
| unset | — | Telemetry is off; steps 1–3 are the whole report. Point to `~/.claude/cost-control/dashboard/telemetry.env.example`. |
| set | **down** | ⚠️ Sessions are exporting OTLP to a dead endpoint. That data is **dropped, not buffered** — starting the stack now captures from now on and cannot backfill this window. Say so plainly. Do **not** start Docker unprompted. |
| set | up | Query it (below). |

When the stack is up, query Prometheus directly — faster and cheaper than driving Grafana:

```bash
P=http://localhost:9090/api/v1/query
curl -s "$P" --data-urlencode 'query=sum by (model) (increase(claude_code_token_usage_tokens_total[7d]))'
curl -s "$P" --data-urlencode 'query=sum by (query_source) (increase(claude_code_token_usage_tokens_total[7d]))'
curl -s "$P" --data-urlencode 'query=sum by (model) (increase(claude_code_cost_usage_USD_total[7d]))'
```

- An empty result usually means **metric names differ** on this version (OTel→Prometheus
  rewrites dots, appends unit suffixes and `_total`). Check `http://localhost:8889/metrics` for the
  real names before concluding there's no data.
- `query_source` is `"main"`, `"subagent"`, or `"auxiliary"`. Cross-check its subagent share
  against step 2's `overall.subagent` share — a large disagreement means one of the two
  sources is incomplete for the window, and that is worth saying.
- ⚠️ **`agent.name` is redacted.** Built-in agents and official-marketplace plugin agents
  appear verbatim; other user-defined agent names are replaced with `"custom"`. Since
  v2.1.273 `OTEL_LOG_TOOL_DETAILS=1` puts real agent names on cost and token metrics
  (changelog only; monitoring-usage.md still documents the redaction without the gate), so
  treat per-agent Grafana series as valid only if a live scrape shows real names. Per-agent
  attribution comes from step 2 first.
- Traces (Tempo, needs `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`) give the call tree of a
  specific fan-out — useful for explaining one expensive prompt from step 2, not for totals.

## 5 · Findings

Three to six one-line findings, each a figure plus a sentence naming the subject. Look for:

| Signal | Threshold | Why it matters here |
|---|---|---|
| One project / session / prompt dominating | >25% / >25% / >2% of total | Concentration is where a guard or a restart would have paid |
| Tokens in ungated spawn types | any | Spend the bundle structurally cannot refuse — step 3 × step 2 |
| Subagent type average per call | >1M tokens | Each spawn is effectively its own session |
| Cache hit rate | <85% | Mid-session CLAUDE.md edits are the remaining full-rebuild cause |
| A prompt that reads as unattended ("leaving for a bit", "go", overnight) with high `api_calls` | — | Exactly what `~/.claude/cost-control/hooks/watchdog-usage.sh` exists for; in-session hooks can't freeze in-flight work |
| Zero denials in a heavy window | — | Either the ladder never engaged (5h stayed <70%) or the spend went around the gate — the join tells you which |
| Telemetry on, stack down | — | Silent data loss for step 4 |

Recommendations must name a specific control that already exists in this bundle
(`watchdog-usage.sh`, `CC_REQUIRE_EXPLICIT_MODEL`, per-stage `opts.model`, the managed
`availableModels` gate, a `STATUS.md` restart from `~/.claude/cost-control/project-templates/`) or say plainly that no
control exists for it. Don't recommend a guard that the gate-coverage numbers show wouldn't fire.

## 6 · Output

1. **Interactive HTML** — copy `$SR/template.html` into the scratchpad, replace the
   `<script id="report-data" type="application/json">{}</script>` element with the step 2 JSON
   (escape `</` as `<\/`), and fill the `<!-- AGENT: anomalies -->` and
   `<!-- AGENT: optimizations -->` blocks with step 5, using the template's markup
   (`<div class="take bad|good|info"><div class="fig">…</div><div class="txt">…</div></div>`
   and `<div class="callout">`). Include the gate-coverage headline as a `take bad` row
   whenever ungated tokens exceed 10% of the total.
2. **With `--publish`, or when the user asks to update the project page** — hand off to
   `/project-artifact claude-cost-control`. Pass the report HTML as a supporting file
   (`files: {"session-report.html": "<path>"}`) so the status page can link to the full
   interactive report, and put the findings, gate-coverage table, and telemetry status on its
   *Usage & telemetry* tab.
3. **In chat** — the window state from step 1, the findings table, and the file path or URL.
   Timestamps in the user's local timezone.

## Never

- Start, stop, or reconfigure the Docker stack or `settings.json` telemetry env without being
  asked — report the state and the exact command instead.
- Present Grafana's `custom` series as a specific agent.
- Treat gate-coverage matching as per-spawn: it matches **counts per type** (gate rows carry no
  `agent_id`), so `ungated` is a floor when a type's gate rows outnumber its starts.
