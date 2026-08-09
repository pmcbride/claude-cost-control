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
  # The single most important fact here is FRESHNESS: guards fail open, so state
  # older than CC_STATE_MAX_AGE means they are silently DISARMED. Say so.
  local line updated max_age now age agetxt
  if command -v jq >/dev/null 2>&1 && [[ -f "$STATE_FILE" ]]; then
    line="$(jq -r '"  5h usage: \(.five_hour_pct // "n/a")%   7d: \(.seven_day_pct // "n/a")%"' "$STATE_FILE" 2>/dev/null)" || line="  usage state unreadable"
    updated="$(jq -r '.updated_at // 0' "$STATE_FILE" 2>/dev/null)" || updated=0
    max_age="${CC_STATE_MAX_AGE:-900}"
    if [[ "$updated" =~ ^[0-9]+$ ]] && (( updated > 0 )); then
      now="$(date +%s)"; age=$(( now - updated )); (( age < 0 )) && age=0
      if   (( age < 120 ));  then agetxt="${age}s ago"
      elif (( age < 7200 )); then agetxt="$(( age / 60 ))m ago"
      else                        agetxt="$(( age / 3600 ))h ago"; fi
      echo "$line   (state written $agetxt)"
      # same comparison the guards use (guard-usage-budget.sh: age > MAX_AGE -> allow)
      if (( age > max_age )); then
        echo "  ⚠ state older than ${max_age}s — usage guards are DISARMED (fail-open) until a statusline refresh rewrites it"
      fi
    else
      echo "$line   (state timestamp unreadable — guards treat it as stale and DISARM, fail-open)"
    fi
  else
    echo "  no usage state file yet (statusline hasn't run — usage guards are disarmed, fail-open)"
  fi
}

recent_denies() {
  local n=0 c
  for f in "$GUARD_LOG" "$MODEL_LOG"; do
    # grep -c PRINTS 0 and EXITS 1 when nothing matches, so `|| echo 0` would
    # append a second 0 and wedge the arithmetic ("0\n0") on the healthy path.
    # Capture the count, then default it — never fold a fallback into $(( )).
    [[ -f "$f" ]] || continue
    c="$(grep -c '"action":"deny"' "$f" 2>/dev/null || true)"
    n=$(( n + ${c:-0} ))
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
