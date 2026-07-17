#!/usr/bin/env bash
# cost-control.sh — master kill switch for the cost-control bundle.
#
#   cost-control.sh on       # (re-)enable all guards, throttle, version nudges
#   cost-control.sh off      # disable them — takes effect on the NEXT tool call,
#                            # no restart needed (hooks stay registered but no-op)
#   cost-control.sh status   # current state + live usage + recent guard activity
#
# Invoked by the /cost-control skill, or run it directly from a terminal.
#
# HOW IT WORKS: a flag file (~/.claude/cost-control/.disabled). Every active
# component checks it first and exits 0 when present:
#   OFF disables:  guard-subagent-model (spawn denials), guard-usage-budget
#                  (usage-band denials), throttle (usage nudges), version-check
#                  (setup/drift messages).
#   OFF keeps:     the statusline (display-only; shows a [cc-off] marker — either
#                  rendered by the bundle's own statusline, or appended by
#                  statusline-wrap.sh if you kept a custom one), and
#                  log-agent-events (passive audit log). Neither restricts
#                  anything nor injects a word into the conversation.
# The managed-settings availableModels gate (if you placed it) is OS-level and
# NOT touched by this switch — remove that file with sudo to lift it.

set -uo pipefail
ROOT="${CC_ROOT:-$HOME/.claude/cost-control}"
FLAG="${CC_DISABLE_FLAG:-$ROOT/.disabled}"
STATE_FILE="${CC_USAGE_STATE:-$HOME/.claude/.usage-state.json}"
GUARD_LOG="${CC_GUARD_LOG:-$HOME/.claude/logs/usage-guard.jsonl}"
MODEL_LOG="$HOME/.claude/logs/model-guard.jsonl"

usage() { sed -n '3,8p' "$0"; exit 2; }

state_summary() {
  if command -v jq >/dev/null 2>&1 && [[ -f "$STATE_FILE" ]]; then
    jq -r '"  5h usage: \(.five_hour_pct // "n/a")%   7d: \(.seven_day_pct // "n/a")%   (state written \((.updated_at // 0)) epoch)"' "$STATE_FILE" 2>/dev/null || true
  else
    echo "  no usage state file yet (statusline hasn't run)"
  fi
}

recent_denies() {
  local n=0
  for f in "$GUARD_LOG" "$MODEL_LOG"; do
    [[ -f "$f" ]] && n=$(( n + $(grep -c '"action":"deny"' "$f" 2>/dev/null || echo 0) ))
  done
  echo "  total denials logged: $n  (see ~/.claude/logs/*-guard.jsonl)"
}

case "${1:-status}" in
  off)
    mkdir -p "$(dirname "$FLAG")" 2>/dev/null || true
    printf '{"disabled_at":"%s","by":"cost-control off"}\n' "$(date -u +%FT%TZ)" > "$FLAG"
    echo "cost-control: OFF (flag: $FLAG)"
    echo "  disabled: spawn guard, usage-budget guard, throttle nudges, version-check messages"
    echo "  still on: statusline display (with [cc-off] marker), passive agent-event log"
    echo "  NOT affected: managed-settings availableModels gate (OS-level, if installed)"
    echo "  takes effect on the next tool call — no restart needed"
    ;;
  on)
    if [[ -f "$FLAG" ]]; then rm -f "$FLAG" && echo "cost-control: ON (flag removed)"; else echo "cost-control: already ON"; fi
    echo "  active: spawn guard (PreToolUse Agent|Task), usage-budget bands 70/80/90, throttle 70/80, version-check"
    state_summary
    ;;
  status)
    if [[ -f "$FLAG" ]]; then
      echo "cost-control: OFF  ($(cat "$FLAG" 2>/dev/null || echo 'flag present'))"
      echo "  re-enable with: /cost-control on"
    else
      echo "cost-control: ON"
      echo "  bands: warn 70% (deny fable spawns + terse nudge) · soft 80% (deny all spawns) · hard 90% (deny heavy fan-out) · watchdog 94%"
    fi
    state_summary
    recent_denies
    ;;
  -h|--help|help) usage ;;
  *) echo "unknown argument: $1"; usage ;;
esac
exit 0
