#!/usr/bin/env bash
# test-workflow-guard.sh — offline behavior tests for hooks/guard-workflow.sh.
#
# Proves the same two things test-hooks.sh proves for the other guards:
#   1. TRANSPARENCY: below WARN (and not forced), and for any non-Workflow
#      tool, the hook emits NO output and exits 0 — byte-identical to an
#      uninstalled system.
#   2. GATING: the SOFT band denies every launch unconditionally; the WARN
#      band denies only a launch whose script/scriptPath lint finds an
#      unpinned or blocked-model agent() stage; every fail-open path (kill
#      switch, no jq, garbage payload, missing/stale/unparseable state,
#      unreadable scriptPath, non-Workflow tool, non-PreToolUse event)
#      allows.
#
# Run: ./tests/test-workflow-guard.sh   (from the bundle root; jq + bash + awk)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/hooks/guard-workflow.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CC_WORKFLOW_GUARD_LOG="$TMP/wf-guard.jsonl"
export CC_USAGE_STATE="$TMP/state.json"
unset CC_WORKFLOW_REQUIRE_STAGE_MODEL CC_WORKFLOW_SCRIPT_MAX_BYTES CC_DISABLE_FLAG 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n    got: %s\n' "$1" "${2:-}"; }

run_hook() { # $1=payload -> sets OUT, CODE
  OUT="$(printf '%s' "$1" | bash "$GUARD" 2>"$TMP/stderr")" ; CODE=$?
}
is_deny()  { printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
is_allow() { [[ $CODE -eq 0 ]] && ! is_deny; }
is_zero_bytes() { is_allow && [[ -z "$OUT" ]]; }

state() { # $1=five_pct $2=age_seconds(default 0)
  local age="${2:-0}"
  jq -nc --arg f "$1" --arg u "$(( $(date +%s) - age ))" \
    '{five_hour_pct: ($f|tonumber), seven_day_pct: 10, updated_at: ($u|tonumber)}' > "$CC_USAGE_STATE"
}

payload_script() { # $1=event $2=script
  jq -nc --arg e "$1" --arg s "$2" \
    '{hook_event_name:$e, session_id:"test", tool_name:"Workflow", tool_input:{script:$s}}'
}
payload_scriptpath() { # $1=event $2=path
  jq -nc --arg e "$1" --arg p "$2" \
    '{hook_event_name:$e, session_id:"test", tool_name:"Workflow", tool_input:{scriptPath:$p}}'
}
payload_name() { # $1=event $2=name
  jq -nc --arg e "$1" --arg n "$2" \
    '{hook_event_name:$e, session_id:"test", tool_name:"Workflow", tool_input:{name:$n}}'
}
payload_resume() { # $1=event $2=runId
  jq -nc --arg e "$1" --arg r "$2" \
    '{hook_event_name:$e, session_id:"test", tool_name:"Workflow", tool_input:{resumeFromRunId:$r}}'
}
payload_tool() { # $1=event $2=tool
  jq -nc --arg e "$1" --arg t "$2" \
    '{hook_event_name:$e, session_id:"test", tool_name:$t, tool_input:{command:"x"}}'
}

PINNED='const a = await agent("do the thing", { model: "sonnet", effort: "low" })'
UNPINNED='const a = await agent("do the thing", { label: "x" })'
FABLE='const a = await agent("do the thing", { model: "fable" })'
MULTILINE='const a = await agent(
  "do the thing across\nmultiple lines",
  {
    label: "x",
    model: "sonnet",
    effort: "low",
  }
)'
MULTILINE_UNPINNED='const a = await agent(
  "do the thing",
  {
    label: "x",
  }
)'
TWO_STAGE_ONE_UNPINNED="$PINNED
const b = await agent(\"second stage\", { label: \"y\" })"

echo "== fail-open paths =="

run_hook "$(payload_script PreToolUse "$UNPINNED")"
is_zero_bytes && ok "no state file -> allow, zero bytes" || bad "no-state fail-open" "$OUT/$CODE"

state 90
run_hook "not even json"
is_zero_bytes && ok "garbage payload -> allow, zero bytes" || bad "garbage payload fail-open" "$OUT/$CODE"

run_hook "$(payload_tool PreToolUse Bash)"
is_zero_bytes && ok "non-Workflow tool at 90% -> allow, zero bytes" || bad "non-Workflow tool passthrough" "$OUT/$CODE"

run_hook "$(payload_script SubagentStart "$UNPINNED")"
is_zero_bytes && ok "non-PreToolUse event -> allow, zero bytes" || bad "non-PreToolUse passthrough" "$OUT/$CODE"

state 90 2000
run_hook "$(payload_name PreToolUse deep-research)"
is_zero_bytes && ok "stale state (>15min) at 90% -> allow (fails open)" || bad "stale state fail-open" "$OUT/$CODE"

printf '{"five_hour_pct":"garbage","updated_at":"soon"}' > "$CC_USAGE_STATE"
run_hook "$(payload_name PreToolUse deep-research)"
is_zero_bytes && ok "unparseable state -> allow (fails open)" || bad "unparseable state fail-open" "$OUT/$CODE"

rm -f "$CC_USAGE_STATE"
state 90
mkdir -p "$TMP/disabled-root"
touch "$TMP/disabled-root/.disabled"
OUT="$(payload_name PreToolUse deep-research | CC_DISABLE_FLAG="$TMP/disabled-root/.disabled" bash "$GUARD" 2>"$TMP/stderr")"; CODE=$?
is_zero_bytes && ok "kill switch -> allow, zero bytes" || bad "kill switch" "$OUT/$CODE"
rm -f "$TMP/disabled-root/.disabled"

state 75
run_hook "$(payload_scriptpath PreToolUse "$TMP/does-not-exist.js")"
is_allow && ok "unreadable scriptPath at WARN -> allow (fails open)" || bad "unreadable scriptPath fail-open" "$OUT/$CODE"

echo "== transparency below WARN =="

state 50
run_hook "$(payload_script PreToolUse "$UNPINNED")"
is_zero_bytes && ok "50%: unpinned script still allowed, zero bytes (below WARN)" || bad "50% transparency" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$FABLE")"
is_zero_bytes && ok "50%: fable-stage script still allowed, zero bytes (below WARN)" || bad "50% fable transparency" "$OUT/$CODE"

echo "== WARN band (70-79): lint gates the launch =="

state 75
run_hook "$(payload_script PreToolUse "$PINNED")"
is_allow && ok "75%: fully-pinned script allowed" || bad "75% pinned allow" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$UNPINNED")"
is_deny && ok "75%: unpinned agent() stage denied" || bad "75% unpinned deny" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$FABLE")"
is_deny && ok "75%: fable stage denied" || bad "75% fable deny" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$MULTILINE")"
is_allow && ok "75%: multi-line pinned agent() call allowed" || bad "75% multiline pinned" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$MULTILINE_UNPINNED")"
is_deny && ok "75%: multi-line unpinned agent() call denied" || bad "75% multiline unpinned" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$TWO_STAGE_ONE_UNPINNED")"
is_deny && ok "75%: one unpinned stage among several denies the whole launch" || bad "75% mixed stages deny" "$OUT/$CODE"

run_hook "$(payload_name PreToolUse deep-research)"
is_allow && ok "75%: name-only (saved/built-in) workflow allowed (nothing to lint)" || bad "75% name-only allow" "$OUT/$CODE"

run_hook "$(payload_resume PreToolUse run-abc123)"
is_allow && ok "75%: resumeFromRunId launch allowed (nothing to lint)" || bad "75% resume allow" "$OUT/$CODE"

echo "$PINNED" > "$TMP/pinned.js"
run_hook "$(payload_scriptpath PreToolUse "$TMP/pinned.js")"
is_allow && ok "75%: pinned scriptPath allowed" || bad "75% scriptPath pinned allow" "$OUT/$CODE"

echo "$UNPINNED" > "$TMP/unpinned.js"
run_hook "$(payload_scriptpath PreToolUse "$TMP/unpinned.js")"
is_deny && ok "75%: unpinned scriptPath denied" || bad "75% scriptPath unpinned deny" "$OUT/$CODE"

# scriptPath takes precedence over script per docs — pinned file + unpinned
# inline script must still be evaluated from the file, i.e. ALLOW.
OUT="$(jq -nc --arg p "$TMP/pinned.js" --arg s "$UNPINNED" \
  '{hook_event_name:"PreToolUse", tool_name:"Workflow", tool_input:{scriptPath:$p, script:$s}}' | bash "$GUARD")" ; CODE=$?
is_allow && ok "75%: scriptPath takes precedence over script (pinned file wins)" || bad "75% scriptPath precedence" "$OUT/$CODE"

echo "== SOFT band (>=80): deny every launch unconditionally =="

state 80
run_hook "$(payload_script PreToolUse "$PINNED")"
is_deny && ok "80%: denies even a fully-pinned script launch" || bad "80% denies pinned script" "$OUT/$CODE"

run_hook "$(payload_name PreToolUse deep-research)"
is_deny && ok "80%: denies a name-only (saved) workflow launch" || bad "80% denies name-only" "$OUT/$CODE"

run_hook "$(payload_resume PreToolUse run-abc123)"
is_deny && ok "80%: denies a resumeFromRunId relaunch" || bad "80% denies resume" "$OUT/$CODE"

state 95
run_hook "$(payload_script PreToolUse "$PINNED")"
is_deny && ok "95%: still denies (SOFT nests under HARD-equivalent usage)" || bad "95% denies" "$OUT/$CODE"

echo "== CC_WORKFLOW_REQUIRE_STAGE_MODEL=1 forces the lint at any usage % =="

state 20
OUT="$(payload_script PreToolUse "$UNPINNED" | CC_WORKFLOW_REQUIRE_STAGE_MODEL=1 bash "$GUARD")" ; CODE=$?
is_deny && ok "20% + REQUIRE_STAGE_MODEL=1: denies an unpinned stage" || bad "forced lint at 20%" "$OUT/$CODE"

OUT="$(payload_script PreToolUse "$PINNED" | CC_WORKFLOW_REQUIRE_STAGE_MODEL=1 bash "$GUARD")" ; CODE=$?
is_allow && ok "20% + REQUIRE_STAGE_MODEL=1: allows a pinned stage" || bad "forced lint pinned at 20%" "$OUT/$CODE"

run_hook "$(payload_script PreToolUse "$UNPINNED")"
is_zero_bytes && ok "20% default (REQUIRE_STAGE_MODEL unset): unpinned still allowed, zero bytes" || bad "20% default transparency" "$OUT/$CODE"

echo "== CC_BLOCK_MODELS is configurable =="

state 75
CUSTOM='const a = await agent("x", { model: "opus" })'
OUT="$(payload_script PreToolUse "$CUSTOM" | CC_BLOCK_MODELS=opus bash "$GUARD")" ; CODE=$?
is_deny && ok "CC_BLOCK_MODELS=opus denies an opus stage" || bad "CC_BLOCK_MODELS override" "$OUT/$CODE"

echo "== logging =="

logged_lines="$(wc -l < "$CC_WORKFLOW_GUARD_LOG" 2>/dev/null || echo 0)"
[[ "$logged_lines" -gt 0 ]] && ok "workflow-guard.jsonl has $logged_lines row(s)" || bad "log file has rows" "$logged_lines"
tail -1 "$CC_WORKFLOW_GUARD_LOG" | jq -e '.ts and .action and .reason' >/dev/null 2>&1 \
  && ok "log rows are well-formed JSON with ts/action/reason" || bad "log row shape"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
