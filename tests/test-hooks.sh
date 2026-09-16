#!/usr/bin/env bash
# test-hooks.sh — offline behavior tests for the cost-control hooks.
#
# Proves two things WITHOUT needing Claude Code:
#   1. TRANSPARENCY (before == after): below every threshold, and for every
#      non-spawn tool, the hooks emit NO deny decision and exit 0 — i.e. an
#      installed system behaves identically to an uninstalled one in normal use.
#   2. GATING: above thresholds, exactly the intended denials fire, and every
#      failure mode (no state, stale state, garbage state, no model field,
#      unknown event) FAILS OPEN.
#
# Run: ./tests/test-hooks.sh   (from the bundle root; jq + bash required)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_MODEL="$ROOT/hooks/guard-subagent-model.sh"
GUARD_BUDGET="$ROOT/hooks/guard-usage-budget.sh"
THROTTLE="$ROOT/hooks/throttle.sh"
STATUSLINE="$ROOT/statusline/usage-statusline.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CC_GUARD_LOG="$TMP/guard.jsonl"
export CC_AGENT_EVENT_LOG="$TMP/events.jsonl"
export CC_USAGE_STATE="$TMP/state.json"
unset CLAUDE_CODE_SUBAGENT_MODEL 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n    got: %s\n' "$1" "${2:-}"; }

# run hook with stdin payload; capture stdout + exit code
run_hook() { # $1=script $2=payload -> sets OUT, CODE
  OUT="$(printf '%s' "$2" | bash "$1" 2>"$TMP/stderr")" ; CODE=$?
}
is_deny()  { printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
is_allow() { [[ $CODE -eq 0 ]] && ! is_deny; }

payload() { # $1=event $2=tool $3=model(optional)
  jq -nc --arg e "$1" --arg t "$2" --arg m "${3:-}" \
    '{hook_event_name:$e, session_id:"test", tool_name:$t,
      tool_input: (if $m == "" then {prompt:"x"} else {prompt:"x", model:$m, subagent_type:"worker"} end)}'
}
state() { # $1=five_pct  $2=age_seconds(default 0)
  local age="${2:-0}"
  jq -nc --arg f "$1" --arg u "$(( $(date +%s) - age ))" \
    '{five_hour_pct: ($f|tonumber), seven_day_pct: 10, updated_at: ($u|tonumber)}' > "$CC_USAGE_STATE"
}

echo "== guard-subagent-model.sh =="

run_hook "$GUARD_MODEL" "$(payload PreToolUse Agent fable)"
is_deny && ok "denies Agent spawn on fable" || bad "denies Agent spawn on fable" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload PreToolUse Task claude-fable-5)"
is_deny && ok "denies Task(alias) spawn on full fable model id" || bad "denies Task spawn on claude-fable-5" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload PreToolUse Agent haiku)"
is_allow && ok "allows Agent spawn on haiku" || bad "allows Agent spawn on haiku" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload PreToolUse Agent opus)"
is_allow && ok "allows Agent spawn on opus (model-guard only blocks CC_BLOCK_MODELS)" || bad "allows opus" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload PreToolUse Agent)"
is_allow && ok "allows no-model spawn by default (fails open)" || bad "allows no-model spawn" "$OUT/$CODE"

OUT="$(payload PreToolUse Agent | CC_REQUIRE_EXPLICIT_MODEL=1 bash "$GUARD_MODEL")" ; CODE=$?
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && ok "denies no-model spawn when CC_REQUIRE_EXPLICIT_MODEL=1" || bad "REQUIRE_EXPLICIT denies" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload PreToolUse Bash)"
is_allow && [[ -z "$OUT" ]] && ok "transparent for non-spawn tools (Bash): no output, exit 0" || bad "Bash transparency" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload TaskCreated TaskCreate)"
is_allow && [[ -z "$OUT" ]] && ok "passes TaskCreated (task list) untouched — never gates todos" || bad "TaskCreated passthrough" "$OUT/$CODE"

run_hook "$GUARD_MODEL" "$(payload SubagentStart '')"
is_allow && ok "SubagentStart: observe-only, exit 0 (cannot block per docs)" || bad "SubagentStart observe" "$OUT/$CODE"

run_hook "$GUARD_MODEL" '{not even json'
is_allow && ok "fails open on garbage payload" || bad "garbage payload fail-open" "$OUT/$CODE"

# --- CLAUDE_CODE_SUBAGENT_MODEL precedence (REVERSED in v2.1.251) -------------
# sub-agents.md#choose-a-model: per-spawn model > frontmatter > env var > session.
# "Before v2.1.251, CLAUDE_CODE_SUBAGENT_MODEL came first in this order and
# overrode both the per-invocation parameter and the frontmatter."
OUT="$(payload PreToolUse Agent haiku | CLAUDE_CODE_SUBAGENT_MODEL=fable bash "$GUARD_MODEL")" ; CODE=$?
[[ $CODE -eq 0 && -z "$OUT" ]] \
  && ok "env var does NOT override an explicit model (v2.1.251+: it is a default)" || bad "env-as-default: explicit model must win" "$OUT/$CODE"

OUT="$(payload PreToolUse Agent '' | CLAUDE_CODE_SUBAGENT_MODEL=fable bash "$GUARD_MODEL")" ; CODE=$?
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && ok "env var applies as the default when no explicit model was passed" || bad "env-as-default: no-model spawn" "$OUT/$CODE"

OUT="$(payload PreToolUse Agent haiku | CLAUDE_CODE_SUBAGENT_MODEL=fable CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 bash "$GUARD_MODEL")" ; CODE=$?
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && ok "_FORCE=1 restores the pre-v2.1.251 override (denies despite explicit haiku)" || bad "_FORCE override deny" "$OUT/$CODE"

OUT="$(payload PreToolUse Agent haiku | CLAUDE_CODE_SUBAGENT_MODEL=fable CLAUDE_CODE_SUBAGENT_MODEL_FORCE=0 bash "$GUARD_MODEL")" ; CODE=$?
[[ $CODE -eq 0 && -z "$OUT" ]] \
  && ok "_FORCE=0 is off (explicit model still wins)" || bad "_FORCE=0 must be off" "$OUT/$CODE"

OUT="$(payload PreToolUse Agent haiku | CLAUDE_CODE_SUBAGENT_MODEL=inherit bash "$GUARD_MODEL")" ; CODE=$?
[[ $CODE -eq 0 && -z "$OUT" ]] \
  && ok "env var 'inherit' == unset (v2.1.196+)" || bad "inherit == unset" "$OUT/$CODE"

echo "== guard-usage-budget.sh =="

rm -f "$CC_USAGE_STATE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent sonnet)"
is_allow && ok "no state file -> allow (fails open)" || bad "no-state fail-open" "$OUT/$CODE"

state 50
for t in Agent Bash WebFetch mcp__pkm__capture_decision; do
  run_hook "$GUARD_BUDGET" "$(payload PreToolUse "$t" sonnet)"
  is_allow && [[ -z "$OUT" ]] && ok "50%: transparent for $t (before==after)" || bad "50% transparency $t" "$OUT/$CODE"
done

state 75
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent fable)"
is_deny && ok "75% (WARN): denies fable spawn" || bad "WARN denies fable spawn" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent opus)"
is_allow && ok "75% (WARN): allows opus spawn (reviewer not degraded below SOFT)" || bad "WARN allows opus" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent sonnet)"
is_allow && ok "75% (WARN): allows sonnet spawn" || bad "WARN allows sonnet" "$OUT/$CODE"

state 85
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent haiku)"
is_deny && ok "85% (SOFT): denies ALL new spawns (even haiku)" || bad "SOFT denies spawns" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Bash)"
is_allow && ok "85% (SOFT): still allows Bash (cheap continuation)" || bad "SOFT allows Bash" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse WebFetch)"
is_allow && ok "85% (SOFT): still allows WebFetch (heavy gate is HARD)" || bad "SOFT allows WebFetch" "$OUT/$CODE"

state 95
run_hook "$GUARD_BUDGET" "$(payload PreToolUse WebFetch)"
is_deny && ok "95% (HARD): denies WebFetch fan-out" || bad "HARD denies WebFetch" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse mcp__slack__slack_send_message)"
is_deny && ok "95% (HARD): denies MCP calls" || bad "HARD denies MCP" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Bash)"
is_allow && ok "95% (HARD): still allows Bash" || bad "HARD allows Bash" "$OUT/$CODE"
OUT="$(payload PreToolUse mcp__pkm__capture_decision | CC_BUDGET_EXEMPT_RE='mcp__pkm.*' bash "$GUARD_BUDGET")"; CODE=$?
[[ $CODE -eq 0 ]] && ! printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && ok "95% (HARD): exemption regex lets cheap capture MCP through" || bad "HARD exemption" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload TaskCreated TaskCreate)"
is_allow && ok "95%: TaskCreated (task list) never gated" || bad "TaskCreated never gated" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload SubagentStart '')"
is_allow && ok "95%: non-PreToolUse events never gated" || bad "lifecycle events never gated" "$OUT/$CODE"
OUT="$(payload PreToolUse Agent fable | CC_BUDGET_DISABLE=1 bash "$GUARD_BUDGET")"; CODE=$?
[[ $CODE -eq 0 && -z "$OUT" ]] && ok "95%: CC_BUDGET_DISABLE=1 bypasses the gate" || bad "manual override" "$OUT/$CODE"

state 95 2000
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent haiku)"
is_allow && ok "stale state (>15min) -> allow (fails open)" || bad "stale fail-open" "$OUT/$CODE"

printf '{"five_hour_pct":"garbage","updated_at":"soon"}' > "$CC_USAGE_STATE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent haiku)"
is_allow && ok "garbage state -> allow (fails open)" || bad "garbage state fail-open" "$OUT/$CODE"

echo "== throttle.sh =="

state 50
run_hook "$THROTTLE" '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
[[ -z "$OUT" && $CODE -eq 0 ]] && ok "50%: injects nothing (zero token overhead below WARN)" || bad "50% no injection" "$OUT/$CODE"

state 75
run_hook "$THROTTLE" '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("elevated")' >/dev/null 2>&1 \
  && ok "75%: injects WARN nudge" || bad "75% WARN nudge" "$OUT/$CODE"

state 85
run_hook "$THROTTLE" '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("CRITICAL")' >/dev/null 2>&1 \
  && ok "85%: injects CRIT nudge (aligned with SOFT gate at 80)" || bad "85% CRIT nudge" "$OUT/$CODE"

# 7d worse than 5h -> nudge uses the worst window
jq -nc --arg u "$(date +%s)" '{five_hour_pct:10, seven_day_pct:85, updated_at:($u|tonumber)}' > "$CC_USAGE_STATE"
run_hook "$THROTTLE" '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("CRITICAL")' >/dev/null 2>&1 \
  && ok "7d=85/5h=10: nudges on the worst window" || bad "worst-window nudge" "$OUT/$CODE"

echo "== /cost-control toggle (master kill switch) =="

TOGGLE="$ROOT/cost-control.sh"
export CC_DISABLE_FLAG="$TMP/.disabled"
state 95

CC_ROOT="$TMP" bash "$TOGGLE" off >/dev/null
[[ -f "$CC_DISABLE_FLAG" ]] && ok "cost-control.sh off writes the flag file" || bad "off writes flag" ""

run_hook "$GUARD_MODEL" "$(payload PreToolUse Agent fable)"
is_allow && [[ -z "$OUT" ]] && ok "OFF: fable spawn passes (model guard no-ops)" || bad "OFF model guard" "$OUT/$CODE"
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent haiku)"
is_allow && [[ -z "$OUT" ]] && ok "OFF: spawn at 95% passes (budget guard no-ops)" || bad "OFF budget guard" "$OUT/$CODE"
run_hook "$THROTTLE" '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
[[ -z "$OUT" && $CODE -eq 0 ]] && ok "OFF: no throttle nudge at 95%" || bad "OFF throttle" "$OUT/$CODE"
OUT="$(CC_CLI_VERSION=9.9.9 CC_ROOT="$TMP" bash "$ROOT/hooks/version-check.sh")"; CODE=$?
[[ -z "$OUT" && $CODE -eq 0 ]] && ok "OFF: version-check stays silent" || bad "OFF version-check" "$OUT/$CODE"

CC_ROOT="$TMP" bash "$TOGGLE" on >/dev/null
[[ ! -f "$CC_DISABLE_FLAG" ]] && ok "cost-control.sh on removes the flag file" || bad "on removes flag" ""
run_hook "$GUARD_BUDGET" "$(payload PreToolUse Agent haiku)"
is_deny && ok "ON again: spawn at 95% denied (re-armed, no restart)" || bad "re-arm" "$OUT/$CODE"
OUT="$(CC_ROOT="$TMP" bash "$TOGGLE" status)"   # capture, don't pipe: grep -q + pipefail = SIGPIPE flake
printf '%s' "$OUT" | grep -q "cost-control: ON" && ok "status reports ON" || bad "status" "$OUT"

# status must surface state freshness — stale state means the guards are
# silently disarmed (fail-open), and status is the one place a human looks.
printf '%s' "$OUT" | grep -q "ago)" && ! printf '%s' "$OUT" | grep -q "DISARMED" \
  && ok "status: fresh state shows human-readable age, no disarm warning" || bad "status fresh age" "$OUT"
jq -nc --arg u "$(( $(date +%s) - 4000 ))" \
  '{five_hour_pct:95, seven_day_pct:10, updated_at:($u|tonumber)}' > "$CC_USAGE_STATE"
OUT="$(CC_ROOT="$TMP" bash "$TOGGLE" status)"
printf '%s' "$OUT" | grep -q "DISARMED" \
  && ok "status: stale state (>CC_STATE_MAX_AGE) warns guards are DISARMED" || bad "status stale warn" "$OUT"
state 95   # restore fresh state for the suites below
unset CC_DISABLE_FLAG

echo "== usage-statusline.sh =="

SL_IN='{"model":{"display_name":"Opus 4.6"},"effort":{"level":"high"},"context_window":{"used_percentage":42.4},"exceeds_200k_tokens":false,"cost":{"total_cost_usd":1.23},"output_style":{"name":"Terse"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":'"$(( $(date +%s) + 3600 ))"'},"seven_day":{"used_percentage":41.2,"resets_at":1938857600}}}'
OUT="$(printf '%s' "$SL_IN" | CC_STATUSLINE_NOCOLOR=1 bash "$STATUSLINE")"; CODE=$?
[[ $CODE -eq 0 ]] && printf '%s' "$OUT" | grep -q "5h 24%" && printf '%s' "$OUT" | grep -q "7d 41%" \
  && ok "renders 5h/7d from documented rate_limits fields" || bad "statusline render" "$OUT/$CODE"
jq -e '.five_hour_pct == 24 and .updated_at != null' "$CC_USAGE_STATE" >/dev/null 2>&1 \
  && ok "writes state file the guards read" || bad "state file write" "$(cat "$CC_USAGE_STATE" 2>/dev/null)"
OUT="$(printf '%s' "$SL_IN" | bash "$STATUSLINE")"
printf '%s' "$OUT" | grep -q $'\033' \
  && ok "emits ANSI colors when piped (Claude Code captures stdout; docs confirm ANSI support)" || bad "ANSI when piped" "$OUT"
OUT="$(printf '{"model":{"display_name":"X"}}' | CC_STATUSLINE_NOCOLOR=1 bash "$STATUSLINE")"; CODE=$?
[[ $CODE -eq 0 ]] && printf '%s' "$OUT" | grep -q "5h n/a" \
  && ok "degrades gracefully when rate_limits absent (API/non-subscription)" || bad "rate_limits absent" "$OUT/$CODE"

# --- REGRESSION (bug found + fixed 2026-09-08) ------------------------------
# An absent rate_limits window must still produce a VALID state file with the
# other fields intact. The original jq wrote `$fp|select(.!="")|tonumber? // null`
# per value; with an empty $fp the pipeline was already empty when `//` ran, so
# jq emitted ZERO results for the whole object -> a 0-byte state file that also
# lost context_pct and model. v2.1.266 made this routine, not exotic:
# "Claude Code drops a window once its resets_at time passes" (statusline.md).
rm -f "$CC_USAGE_STATE"
printf '{"model":{"display_name":"X"},"context_window":{"used_percentage":42}}' \
  | CC_STATUSLINE_NOCOLOR=1 bash "$STATUSLINE" >/dev/null 2>&1
[[ -s "$CC_USAGE_STATE" ]] \
  && jq -e '.five_hour_pct == null and .context_pct == 42 and .model == "X" and .updated_at != null' \
       "$CC_USAGE_STATE" >/dev/null 2>&1 \
  && ok "rate_limits absent -> state file is still VALID JSON with other fields (not 0 bytes)" \
  || bad "absent-window state file" "bytes=$(wc -c < "$CC_USAGE_STATE" 2>/dev/null) $(cat "$CC_USAGE_STATE" 2>/dev/null)"

printf '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"model":"sonnet"}}' \
  | bash "$GUARD_BUDGET" >/dev/null 2>&1
[[ $? -eq 0 ]] \
  && ok "guard fails open on a null-pct state file (absent window != 0%)" || bad "null-pct fail-open" "$?"

rm -f "$CC_USAGE_STATE"
OUT="$(printf '%s' "$SL_IN" | CC_STATUSLINE_STATE_ONLY=1 bash "$STATUSLINE")"; CODE=$?
[[ $CODE -eq 0 && -z "$OUT" ]] && jq -e '.five_hour_pct == 24' "$CC_USAGE_STATE" >/dev/null 2>&1 \
  && ok "STATE_ONLY mode: renders nothing, still writes state (for wrapped custom statuslines)" || bad "state-only mode" "$OUT/$CODE"

rm -f "$CC_USAGE_STATE"
OUT="$(printf '%s' "$SL_IN" | bash "$ROOT/statusline/statusline-wrap.sh" "printf 'MY-CUSTOM-LINE'")"; CODE=$?
[[ $CODE -eq 0 && "$OUT" == "MY-CUSTOM-LINE" ]] && jq -e '.five_hour_pct == 24' "$CC_USAGE_STATE" >/dev/null 2>&1 \
  && ok "statusline-wrap: user's display untouched AND guard state written" || bad "wrapper" "$OUT/$CODE state=$(cat "$CC_USAGE_STATE" 2>/dev/null)"

# --- [cc-off] marker in a WRAPPED custom statusline (added 2026-07-17) ---
# The bundle's own statusline renders [cc-off] in a block that STATE_ONLY skips,
# so the wrapper must append it, but ONLY while disabled.
WRAP_FLAG="$TMP/wrap.disabled"   # inside $TMP so the EXIT trap always reaps it
OUT="$(printf '%s' "$SL_IN" | CC_DISABLE_FLAG="$WRAP_FLAG" CC_STATUSLINE_NOCOLOR=1 \
       bash "$ROOT/statusline/statusline-wrap.sh" "printf 'MY-CUSTOM-LINE'")"; CODE=$?
[[ $CODE -eq 0 && "$OUT" == "MY-CUSTOM-LINE" ]] \
  && ok "statusline-wrap: guards ARMED -> no [cc-off], display byte-for-byte unchanged" \
  || bad "wrapper armed" "$OUT/$CODE"

: > "$WRAP_FLAG"   # simulate /cost-control off
OUT="$(printf '%s' "$SL_IN" | CC_DISABLE_FLAG="$WRAP_FLAG" CC_STATUSLINE_NOCOLOR=1 \
       bash "$ROOT/statusline/statusline-wrap.sh" "printf 'MY-CUSTOM-LINE'")"; CODE=$?
[[ $CODE -eq 0 && "$OUT" == "MY-CUSTOM-LINE [cc-off]" ]] \
  && ok "statusline-wrap: guards DISARMED -> [cc-off] appended to the user's own line" \
  || bad "wrapper cc-off" "$OUT/$CODE"

# multi-line custom statuslines must keep their internal newlines
OUT="$(printf '%s' "$SL_IN" | CC_DISABLE_FLAG="$WRAP_FLAG" CC_STATUSLINE_NOCOLOR=1 \
       bash "$ROOT/statusline/statusline-wrap.sh" "printf 'LINE1\nLINE2'")"; CODE=$?
[[ $CODE -eq 0 && "$OUT" == $'LINE1\nLINE2 [cc-off]' ]] \
  && ok "statusline-wrap: multi-line display preserved, marker appended to last line" \
  || bad "wrapper multiline" "$OUT/$CODE"

# A custom statusline that exits NONZERO must still render, keep its marker, and
# run EXACTLY ONCE. Re-running it would double any side effect it has and would
# display the second run's output instead of the render that actually happened.
WRAP_CNT="$TMP/wrap.count"       # inside $TMP so the EXIT trap always reaps it
OUT="$(printf '%s' "$SL_IN" | CC_DISABLE_FLAG="$WRAP_FLAG" CC_STATUSLINE_NOCOLOR=1 \
       bash "$ROOT/statusline/statusline-wrap.sh" \
       "printf x >> '$WRAP_CNT'; printf 'FAILING-LINE'; exit 1")"; CODE=$?
[[ $CODE -eq 0 && "$OUT" == "FAILING-LINE [cc-off]" && "$(wc -c < "$WRAP_CNT" | tr -d ' ')" == "1" ]] \
  && ok "statusline-wrap: nonzero-exit display renders once with marker (no rerun, no doubled side effects)" \
  || bad "wrapper nonzero exit" "$OUT/$CODE runs=$(wc -c < "$WRAP_CNT" | tr -d ' ')"
rm -f "$WRAP_CNT"

# default (no CC_STATUSLINE_NOCOLOR) must emit the ANSI-wrapped marker — this is
# what a real user sees, since nobody sets NOCOLOR unless they've customized it
OUT="$(printf '%s' "$SL_IN" | CC_DISABLE_FLAG="$WRAP_FLAG" \
       bash "$ROOT/statusline/statusline-wrap.sh" "printf 'MY-CUSTOM-LINE'")"; CODE=$?
[[ $CODE -eq 0 && "$OUT" == $'MY-CUSTOM-LINE \033[33m[cc-off]\033[0m' ]] \
  && ok "statusline-wrap: default path emits colored [cc-off]" \
  || bad "wrapper colored marker" "$(printf '%s' "$OUT" | cat -vet)/$CODE"

# state must still be written while disabled (statusline is display-only; the
# flag disarms the GUARDS, not the state feed)
rm -f "$CC_USAGE_STATE"
printf '%s' "$SL_IN" | CC_DISABLE_FLAG="$WRAP_FLAG" bash "$ROOT/statusline/statusline-wrap.sh" "printf 'X'" >/dev/null 2>&1
jq -e '.five_hour_pct == 24' "$CC_USAGE_STATE" >/dev/null 2>&1 \
  && ok "statusline-wrap: still writes guard state while disabled" \
  || bad "wrapper state while off" "$(cat "$CC_USAGE_STATE" 2>/dev/null)"
rm -f "$WRAP_FLAG"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
