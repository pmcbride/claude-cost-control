#!/usr/bin/env bash
# test-performance.sh — bounds the runtime overhead the hooks add.
#
# WHAT THE HOOKS COST, BY CONSTRUCTION (the token part needs no measuring):
#   * Tokens/usage: guard scripts are pure shell — they consume ZERO tokens.
#     Below the WARN threshold they emit NOTHING (see test-hooks.sh), so an
#     installed system sends byte-identical prompts to the model. The only
#     token-bearing outputs are (a) the throttle nudge (~70 words, only ≥70%
#     usage), (b) deny reasons (~50 words, only when a spawn is refused — which
#     SAVES a subagent's whole cost), (c) version-check setup/drift messages
#     (once per install/update). Net usage effect at high load is strongly
#     NEGATIVE (denied fan-out >> nudge text).
#   * Wall-clock: one bash+jq subprocess per tool call for the matcher-"*"
#     budget guard, plus one for spawns. This test measures that latency and
#     fails if it exceeds budget — against tool calls that take hundreds of ms
#     to minutes, single-digit-ms hooks are noise.
#
# Run: ./tests/test-performance.sh   [BUDGET_MS_PER_CALL=40 by default]
# The budget is 40ms, not the ~10ms the hooks actually cost: hook latency is
# load-sensitive (each iteration forks bash+jq), and a 25ms budget flaked on a
# busy machine while an idle one measured 8-12ms. 40ms still catches a real
# regression (an extra jq pass or a network call) without failing on noise.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUDGET_MS="${BUDGET_MS_PER_CALL:-40}"
N="${PERF_ITERATIONS:-100}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CC_GUARD_LOG="$TMP/g.jsonl" CC_USAGE_STATE="$TMP/state.json"
PASS=0; FAIL=0

jq -nc --arg u "$(date +%s)" '{five_hour_pct:50, seven_day_pct:10, updated_at:($u|tonumber)}' > "$CC_USAGE_STATE"
PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
SPAWN='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"model":"sonnet","subagent_type":"worker","prompt":"x"}}'

bench() { # $1=label $2=script $3=payload
  local start end ms avg
  start="$(date +%s%N)"
  for _ in $(seq 1 "$N"); do printf '%s' "$3" | bash "$2" >/dev/null 2>&1; done
  end="$(date +%s%N)"
  ms=$(( (end - start) / 1000000 ))
  avg=$(( ms / N ))
  if (( avg <= BUDGET_MS )); then
    PASS=$((PASS+1)); printf '  ✓ %-38s avg %sms/call (n=%s, budget %sms)\n' "$1" "$avg" "$N" "$BUDGET_MS"
  else
    FAIL=$((FAIL+1)); printf '  ✗ %-38s avg %sms/call EXCEEDS budget %sms\n' "$1" "$avg" "$BUDGET_MS"
  fi
}

echo "== hook latency (the only real overhead) =="
bench "guard-usage-budget (every tool call)" "$ROOT/hooks/guard-usage-budget.sh" "$PAYLOAD"
bench "guard-subagent-model (spawns only)"   "$ROOT/hooks/guard-subagent-model.sh" "$SPAWN"
bench "throttle (once per user prompt)"      "$ROOT/hooks/throttle.sh" '{"hook_event_name":"UserPromptSubmit"}'
bench "statusline (refresh cadence)"         "$ROOT/statusline/usage-statusline.sh" '{"model":{"display_name":"x"}}'

echo
echo "== token/usage overhead (verified by construction + test-hooks.sh) =="
echo "  below 70% usage: hooks emit ZERO bytes into the conversation -> no usage delta"
echo "  70-80%:  one ~70-word nudge per user prompt (throttle)"
echo "  >=80%:   spawn denials (~50 words each) REPLACE entire subagent runs -> net savings"
echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
