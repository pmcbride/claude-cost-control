#!/usr/bin/env bash
# throttle.sh — UserPromptSubmit self-throttle.
#
# The piece that makes the MODEL get terser and stop fanning out as usage climbs,
# without the model needing to see its own usage (it can't). The harness sees it:
# this hook reads the 5h/7d % that usage-statusline.sh already wrote to the state
# file, and — above thresholds — injects an `additionalContext` directive telling
# Claude to compress and avoid spawns. The model doesn't monitor; the harness
# monitors and tells the model.
#
# Two bands (configurable):
#   >= WARN_PCT (70): be terse, avoid parallel fan-out, route routine work down.
#   >= CRIT_PCT (80): fewest words, NO subagents/workflows, ask before multi-file.
#
# CRIT is deliberately aligned with the budget gate's SOFT band (80): the moment
# the gate starts denying spawns, the model is told to stop attempting them —
# otherwise it burns turns on attempts the gate will refuse.
#
# This hook uses the WORST of the 5h and 7d windows, while the budget gate reads
# 5h only. That is intentional: a 7d-exhausted account gets nudged to slow down
# but is not hard-gated (7d pressure is chronic, not a spike).
#
# This is the SOFT layer (a nudge in-context). The hard layer is
# guard-usage-budget.sh, which actually denies spawns. Run both — the nudge keeps
# output cheap; the gate stops fan-out cold.
#
# FAILS OPEN and always exit 0: a missing/stale state file just means no nudge.
# Note: injected additionalContext is saved to the transcript and replayed on
# --resume, so its value can read stale after a resume — fine for a throttle nudge.
#
# Install on UserPromptSubmit (no matcher needed). See settings.snippet.json.

set -uo pipefail
# Master kill switch (/cost-control off) — flag present => no nudge.
DISABLE_FLAG="${CC_DISABLE_FLAG:-${CC_ROOT:-$HOME/.claude/cost-control}/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && exit 0

STATE_FILE="${CC_USAGE_STATE:-$HOME/.claude/.usage-state.json}"
WARN_PCT="${CC_THROTTLE_WARN_PCT:-70}"
CRIT_PCT="${CC_THROTTLE_CRIT_PCT:-80}"
MAX_AGE="${CC_STATE_MAX_AGE:-900}"

command -v jq >/dev/null 2>&1 || exit 0
[[ "${CC_THROTTLE_DISABLE:-0}" == "1" ]] && exit 0
[[ -f "$STATE_FILE" ]] || exit 0

five="$(jq -r '.five_hour_pct // empty' "$STATE_FILE" 2>/dev/null)"
seven="$(jq -r '.seven_day_pct // 0' "$STATE_FILE" 2>/dev/null)"
updated="$(jq -r '.updated_at // 0' "$STATE_FILE" 2>/dev/null)"
[[ -z "$five" ]] && exit 0
now="$(date +%s)"
[[ "$updated" =~ ^[0-9]+$ ]] || exit 0
(( now - updated > MAX_AGE )) && exit 0

# use the higher of the two windows to decide severity
worst="$five"; awk "BEGIN{exit !($seven > $five)}" 2>/dev/null && worst="$seven"
worst_i="$(printf '%.0f' "$worst" 2>/dev/null || echo 0)"
[[ "$worst_i" =~ ^[0-9]+$ ]] || exit 0

msg=""
if (( worst_i >= CRIT_PCT )); then
  msg="USAGE STATE: plan usage at ${worst_i}% of a rolling window (CRITICAL). Answer in the fewest words that fully convey the information. Do NOT spawn subagents, agent teams, or workflows — the budget gate will deny them anyway. Ask before starting any multi-file or multi-step work. Keep full reasoning only where correctness depends on it."
elif (( worst_i >= WARN_PCT )); then
  msg="USAGE STATE: plan usage at ${worst_i}% of a rolling window (elevated). Be terse — no preamble, no closing summary, no narration. Avoid parallel fan-out; prefer a single agent and serialize. Route routine/mechanical work to Sonnet or Haiku. Preserve step-by-step reasoning on genuinely hard problems."
fi

[[ -z "$msg" ]] && exit 0
jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}'
exit 0
