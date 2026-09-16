#!/usr/bin/env bash
# gate-coverage.sh — how many subagent spawns actually reached the spawn gate?
#
# Joins two logs this bundle already writes:
#   agent-events.jsonl  (log-agent-events.sh)    one SubagentStart row per spawn,
#                                                 whatever surface it came from
#   model-guard.jsonl   (guard-subagent-model.sh) one row per PreToolUse Agent|Task
#                                                 decision (allow / deny)
# Spawns that produce a SubagentStart but no gate decision never passed through
# PreToolUse, so no guard in this bundle could have refused them. The documented
# case is Workflow `agent()` stages ("Workflow-internal stage spawns may bypass
# PreToolUse" — README, Honest limitations); this script measures it instead of
# asserting it.
#
# Usage:
#   gate-coverage.sh [--since 7d|24h|<ISO timestamp>] [--json]
#
# Matching is by COUNT per agent type, not per spawn: the gate row carries no
# agent_id, so individual spawns can't be paired. `ungated` is therefore
# max(starts - decisions, 0) per type — a lower bound when a type's gate rows
# outnumber its starts (retries, or a spawn whose SubagentStart was lost).
#
# Fail-soft like every component here: a missing/unreadable log or absent jq
# prints a note and exits 0. Garbage lines are skipped, not fatal.
set -uo pipefail

EVENTS="${CC_AGENT_EVENT_LOG:-$HOME/.claude/logs/agent-events.jsonl}"
GUARD="${CC_GUARD_LOG:-$HOME/.claude/logs/model-guard.jsonl}"
SINCE="7d"; JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:-7d}"; shift 2 ;;
    --json)  JSON=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "gate-coverage: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "gate-coverage: jq not found — nothing to report"; exit 0; }
for f in "$EVENTS" "$GUARD"; do
  [[ -r "$f" ]] || { echo "gate-coverage: log not readable: $f — nothing to report"; exit 0; }
done

# Cutoff as an ISO-8601 UTC string; both logs write ts as ...Z, so a plain
# string compare orders correctly. Relative windows are computed in jq (no
# BSD-vs-GNU `date` split).
case "$SINCE" in
  *d) CUT="$(jq -nr --arg n "${SINCE%d}" '(now - ($n|tonumber)*86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')" ;;
  *h) CUT="$(jq -nr --arg n "${SINCE%h}" '(now - ($n|tonumber)*3600)  | strftime("%Y-%m-%dT%H:%M:%SZ")')" ;;
  *)  CUT="$SINCE" ;;
esac
[[ -n "$CUT" ]] || { echo "gate-coverage: could not parse --since '$SINCE'" >&2; exit 2; }

STARTS="$(jq -R -c --arg cut "$CUT" 'fromjson? // empty
  | select(.event == "SubagentStart" and (.ts // "") >= $cut)
  | (.agent_type // "") | if . == "" then "(unnamed)" else . end' "$EVENTS" | jq -s -c 'group_by(.) | map({key: .[0], value: length}) | from_entries')"
GATED="$(jq -R -c --arg cut "$CUT" 'fromjson? // empty
  | select(.event == "PreToolUse" and (.ts // "") >= $cut)
  | {t: ((.subagent_type // "") | if . == "" then "(unnamed)" else . end), a: (.action // "?")}' "$GUARD" | jq -s -c '
  group_by(.t) | map({key: .[0].t, value: {decisions: length, deny: (map(select(.a == "deny")) | length)}}) | from_entries')"

REPORT="$(jq -n -c --arg cut "$CUT" --argjson s "${STARTS:-{\}}" --argjson g "${GATED:-{\}}" '
  (($s | keys) + ($g | keys) | unique) as $types
  | [ $types[] | . as $t
      | ($s[$t] // 0) as $st | ($g[$t].decisions // 0) as $gd
      | { agent_type: $t, starts: $st, decisions: $gd, deny: ($g[$t].deny // 0),
          ungated: ([($st - $gd), 0] | max) } ]
  | sort_by(-.ungated, -.starts) as $rows
  | ($rows | map(.starts)    | add // 0) as $S
  | ($rows | map(.ungated)   | add // 0) as $U
  | { since: $cut,
      spawns: $S,
      decisions: ($rows | map(.decisions) | add // 0),
      deny: ($rows | map(.deny) | add // 0),
      ungated: $U,
      ungated_pct: (if $S > 0 then (($U * 1000 / $S) | round) / 10 else 0 end),
      by_agent_type: $rows }')"

if [[ $JSON -eq 1 ]]; then
  printf '%s\n' "$REPORT"
  exit 0
fi

jq -r '
  "Gate coverage since \(.since)",
  "  spawns (SubagentStart)   \(.spawns)",
  "  gate decisions           \(.decisions)  (deny \(.deny))",
  "  ungated spawns           \(.ungated)  (\(.ungated_pct)% of spawns never reached PreToolUse)",
  "",
  "  \("agent_type" | .[0:32] | . + (" " * (32 - length)))  starts  gated  deny  ungated",
  ( .by_agent_type[]
    | "  \(.agent_type | .[0:32] | . + (" " * (32 - length)))  \(.starts | tostring | (" " * (6 - length)) + .)  \(.decisions | tostring | (" " * (5 - length)) + .)  \(.deny | tostring | (" " * (4 - length)) + .)  \(.ungated | tostring | (" " * (7 - length)) + .)" ),
  (if (.by_agent_type | map(select(.agent_type == "workflow-subagent" and .ungated > 0)) | length) > 0
   then "", "note: workflow-subagent stages never reach PreToolUse. Their only controls are the",
            "      session model and an explicit opts.model/effort on every agent() call."
   else empty end)
' <<<"$REPORT"
