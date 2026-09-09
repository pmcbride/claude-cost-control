#!/usr/bin/env bash
# guard-usage-budget.sh — PreToolUse circuit breaker for the 5-hour usage window.
#
# Reads the usage state file written by usage-statusline.sh (which gets the live
# 5-hour % straight from Claude Code's statusline JSON — no API polling). When
# your 5-hour usage climbs past a threshold, this stops NEW heavy/fan-out work
# from starting, while letting already-running work finish and letting cheap
# single-step work continue. That is the "safe wind-down": you don't blow through
# the window, and you can inspect the paused chats and decide to lower the model
# or resume.
#
# REGISTRATION (verified against code.claude.com docs 2026-07-16): register on
# PreToolUse ONLY, matcher "*". PreToolUse is the only hook surface that can
# block a tool call, and a subagent spawn IS a PreToolUse call on the `Agent`
# tool (alias `Task`). Do NOT register this on TaskCreated — that is the task
# LIST event ("created via TaskCreate"), and blocking there rolls back todo
# items, not spawns. If it fires on a non-PreToolUse event anyway, it allows.
#
# WHAT IT GATES, BY BAND (all thresholds configurable):
#   >= WARN_PCT (default 70): deny NEW spawns that request a blocked-expensive
#                             model (default: fable). Cheap spawns still pass.
#   >= SOFT_PCT (default 80): deny ALL new subagent spawns (Agent/Task).
#                             In-flight agents are untouched.
#   >= HARD_PCT (default 90): additionally deny expensive one-shot fan-out tools
#                             (WebFetch/WebSearch/mcp__*), except anything
#                             matching CC_BUDGET_EXEMPT_RE (e.g. cheap capture
#                             MCP calls you always want to allow).
#   Below WARN_PCT: everything passes.
#
# The throttle hook (throttle.sh) nudges the model to stop attempting spawns at
# the SAME threshold the SOFT band starts denying them (80) — so the model isn't
# burning turns on attempts the gate will refuse.
#
# FAILS OPEN: if the state file is missing, stale (> CC_STATE_MAX_AGE s), or
# unparseable, the hook allows the action. It will never wedge your session
# because the statusline hasn't run yet. NOTE the flip side: in headless or
# background sessions where no statusline runs, the state goes stale and this
# gate disarms — pair it with watchdog-usage.sh for unattended coverage.
#
# Offline unit tests: tests/test-hooks.sh.

set -uo pipefail

# Master kill switch (/cost-control off) — flag present => transparent no-op.
DISABLE_FLAG="${CC_DISABLE_FLAG:-${CC_ROOT:-$HOME/.claude/cost-control}/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && exit 0

STATE_FILE="${CC_USAGE_STATE:-$HOME/.claude/.usage-state.json}"
LOG="${CC_GUARD_LOG:-$HOME/.claude/logs/usage-guard.jsonl}"
WARN_PCT="${CC_BUDGET_WARN_PCT:-70}"        # block blocked-expensive-model spawns at/above this
SOFT_PCT="${CC_BUDGET_SOFT_PCT:-80}"        # stop ALL new fan-out at/above this
HARD_PCT="${CC_BUDGET_HARD_PCT:-90}"        # stop most new heavy work at/above this
MAX_AGE="${CC_STATE_MAX_AGE:-900}"          # ignore state older than 15 min
EXPENSIVE_MODELS="${CC_EXPENSIVE_MODELS:-fable}"   # WARN band blocks these; opus is denied at SOFT with everything else
EXEMPT_RE="${CC_BUDGET_EXEMPT_RE:-}"        # tools matching this regex are never denied (e.g. 'mcp__pkm.*')
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0     # no jq -> allow

# Allow an explicit manual override (set when LAUNCHING the session, e.g.
# `CC_BUDGET_DISABLE=1 claude` — hooks inherit the session's environment):
[[ "${CC_BUDGET_DISABLE:-0}" == "1" ]] && exit 0

# Single-pass parse of the hook payload (one jq per invocation, keeps the
# per-tool-call overhead in the ~10ms range — see tests/test-performance.sh).
in_line="$(printf '%s' "$input" | jq -r '
  [ (.hook_event_name // ""), (.tool_name // ""),
    ((.tool_input.model // .tool_input.params.model // .tool_input.opts.model) // "") ]
  | map(tostring) | join("")' 2>/dev/null)" || in_line=""
IFS=$'\x1f' read -r event tool model <<< "$in_line"   # \x1f: empty fields survive (tabs would collapse)

case "$event" in PreToolUse|"") : ;; *) exit 0 ;; esac   # only PreToolUse can block; never gate lifecycle events

[[ -f "$STATE_FILE" ]] || exit 0            # no state yet -> allow
st_line="$(jq -r '[ (.five_hour_pct // ""), (.updated_at // "") ] | map(tostring) | join("")' "$STATE_FILE" 2>/dev/null)" || st_line=""
IFS=$'\x1f' read -r five updated <<< "$st_line"
[[ -z "$five" || "$five" == "null" ]] && exit 0   # unknown -> allow

now="$(date +%s)"
[[ "$updated" =~ ^[0-9]+$ ]] || exit 0      # unreadable timestamp -> treat as stale -> allow
(( now - updated > MAX_AGE )) && exit 0     # stale -> allow

# round to int for comparison
five_i="$(printf '%.0f' "$five" 2>/dev/null || printf '%s' "$five")"
[[ "$five_i" =~ ^[0-9]+$ ]] || exit 0

# Model resolution mirrors sub-agents.md#choose-a-model as of v2.1.251:
#   per-spawn model > frontmatter (invisible here) > CLAUDE_CODE_SUBAGENT_MODEL >
#   session model. Docs, verbatim: "Before v2.1.251, CLAUDE_CODE_SUBAGENT_MODEL
#   came first in this order and overrode both the per-invocation parameter and
#   the frontmatter." CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 (v2.1.257+) restores the
#   old unconditional override. Keep in sync with guard-subagent-model.sh.
env_model="${CLAUDE_CODE_SUBAGENT_MODEL:-}"
[[ "$env_model" == "inherit" ]] && env_model=""          # inherit == unset (v2.1.196+)
force="$(printf '%s' "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" | tr '[:upper:]' '[:lower:]')"
case "$force" in ""|0|false|no|off) force=0 ;; *) force=1 ;; esac
if [[ "$force" == "1" ]]; then
  [[ -n "$env_model" ]] && model="$env_model"
elif [[ -z "$model" && -n "$env_model" ]]; then
  model="$env_model"
fi

# Exemption: tools you always want to allow (cheap capture MCPs, etc.)
if [[ -n "$EXEMPT_RE" ]] && printf '%s' "$tool" | grep -Eq "$EXEMPT_RE"; then exit 0; fi

# A spawn is the Agent tool call (alias Task) — the documented spawn surface.
is_spawn=0
case "$tool" in Agent|Task) is_spawn=1;; esac
is_heavy=$is_spawn
case "$tool" in WebFetch|WebSearch|mcp__*) is_heavy=1;; esac
exp_re="$(printf '%s' "$EXPENSIVE_MODELS" | tr ', ' '\n\n' | sed '/^$/d' | paste -sd'|' -)"
is_expensive_model=0
[[ -n "$model" && -n "$exp_re" ]] && printf '%s' "$model" | grep -Eiq "$exp_re" && is_expensive_model=1

log() { jq -nc --arg t "$tool" --arg five "$five_i" --arg act "$1" --arg why "$2" \
        --arg ts "$(date -u +%FT%TZ)" \
        '{ts:$ts,tool:$t,five_hour_pct:($five|tonumber),action:$act,reason:$why}' >> "$LOG" 2>/dev/null || true; }
deny() { log deny "$1"
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0; }

# --- HARD band: stop most new heavy work ---
if (( five_i >= HARD_PCT )) && (( is_heavy == 1 )); then
  deny "5-hour usage at ${five_i}% (HARD limit ${HARD_PCT}%). Winding down: no new subagents, workflows, or fan-out tool calls. Finish or summarize in-flight work, then STOP and let the window recover. If genuinely urgent, the user can relaunch the session with CC_BUDGET_DISABLE=1."
fi

# --- SOFT band: stop new fan-out (spawns), allow cheap continuation ---
if (( five_i >= SOFT_PCT )) && (( is_spawn == 1 )); then
  deny "5-hour usage at ${five_i}% (SOFT limit ${SOFT_PCT}%). Do NOT spawn new subagents/parallel agents — serialize the remaining work in the main thread on a cheap model instead. Spawning multiplies burn rate exactly when you can least afford it."
fi

# --- WARN band: block blocked-expensive-model spawns only ---
if (( five_i >= WARN_PCT )) && (( is_spawn == 1 )) && (( is_expensive_model == 1 )); then
  deny "5-hour usage at ${five_i}% and this spawn requests an expensive model ('${model}'). Above ${WARN_PCT}% only cheap workers are allowed — re-dispatch on sonnet (general) or haiku (read-only) and keep going."
fi

# Log allows only once we're in gating territory (saves a jq + a write on every
# tool call in the common low-usage path; denials are always logged above).
(( five_i >= WARN_PCT )) && log allow "${five_i}%"
exit 0
