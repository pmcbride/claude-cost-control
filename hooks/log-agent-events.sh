#!/usr/bin/env bash
# log-agent-events.sh — quiet, non-blocking audit logger for agent lifecycle.
#
# Register on SubagentStart / SubagentStop (see settings.snippet.json). It
# appends one JSON line per event to ~/.claude/logs/agent-events.jsonl and
# ALWAYS exits 0 — it never blocks, never prints to the chat, never slows a
# turn. This gives you an after-the-fact trail to answer "which subagent burned
# the window" together with the OTEL dashboard or a transcript scan.
#
# (TaskCreated/TaskCompleted are the task-LIST events, not agent lifecycle —
# registering there just adds a subprocess per todo operation for little signal.)
#
# It is deliberately dumb: capture the payload, timestamp it, move on.

set -uo pipefail
LOG="${CC_AGENT_EVENT_LOG:-$HOME/.claude/logs/agent-events.jsonl}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$input" | jq -c --arg ts "$(date -u +%FT%TZ)" \
    '{ts:$ts, event:(.hook_event_name // "unknown"), session:(.session_id // null),
      agent_id:(.agent_id // null), agent_type:(.agent_type // null),
      tool:(.tool_name // null), payload:.}' >> "$LOG" 2>/dev/null || true
else
  printf '{"ts":"%s","raw":%s}\n' "$(date -u +%FT%TZ)" "$(printf '%s' "$input" | tr -d '\n')" >> "$LOG" 2>/dev/null || true
fi
exit 0
