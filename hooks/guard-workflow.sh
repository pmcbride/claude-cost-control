#!/usr/bin/env bash
# guard-workflow.sh — PreToolUse gate on the `Workflow` tool call itself.
#
# WHY THIS EXISTS: dynamic workflows fan out `agent()` stages from a JS script
# a runtime executes in the background. Those stage spawns are NOT a
# PreToolUse call on the `Agent` tool — workflows.md is explicit that Claude
# Code "picks each workflow agent's model in the same order it uses for
# subagents ... When nothing else assigns one, the agent runs on your
# session's model" (workflows.md:415), and per-stage `agent()` calls never
# themselves cross the Agent-tool PreToolUse surface guard-subagent-model.sh
# and guard-usage-budget.sh gate. Measured 2026-09-09..16 on this install:
# 143 workflow-subagent spawns, 0 PreToolUse gate decisions on them (74.5% of
# spawns, ~36.5% of the week's tokens) — dashboard/gate-coverage.sh.
#
# THE ONLY REACHABLE CHOKE POINT is the `Workflow` tool call that LAUNCHES the
# script. workflows.md confirms this is a normal PreToolUse-gateable call:
# "A `PreToolUse` hook: a hook that returns `allow` for the call approves it"
# (workflows.md:185, "Approve the plan before it runs" — CLI/SDK/`claude -p`
# all route the launch through the same permission evaluation as any other
# tool call). `tool_input` for the `Workflow` tool (agent-sdk/typescript.md
# "### Workflow", v2.1.273) carries `script` (inline JS), `scriptPath` (file
# path, takes precedence over `script`/`name`), `name` (saved/built-in
# workflow name), `args`, `resumeFromRunId`.
#
# WHAT THIS HOOK CANNOT DO: gate individual stages inside an already-launched
# run — that surface still doesn't exist (see README "Honest limitations").
# This is a LAUNCH-TIME FLOOR: refuse the launch outright at high usage, and
# below that, refuse to launch a script whose `agent()` stages are visibly
# unpinned or point at a blocked-expensive model. A `name`-only saved-workflow
# launch or a `resumeFromRunId` resume carries no script text to lint here —
# only the usage-band rule (SOFT+) applies to those.
#
# THE LINT (heuristic, not a JS parser — keep this section in sync with the
# awk body below if you change it):
#   1. Find every top-level `agent(` call: a word-boundary-safe occurrence of
#      the literal token `agent(` (so `myAgent(`/`.agent(` don't trigger, but
#      a comment or prompt STRING that literally contains the substring
#      "agent(" WILL — same false-positive class as any grep-based check;
#      biases toward an unnecessary deny, never a missed unpinned spawn).
#   2. From each trigger, scan forward tracking paren depth AND quote state
#      ('/"/` with backslash-escapes) so parens inside a prompt string or
#      template literal don't desync the depth count. This finds the call's
#      true closing `)`.
#   3. If that span contains no `model[ \t\r\n]*:` token, it's UNPINNED. If it
#      contains one whose value matches CC_BLOCK_MODELS (default fable), it's
#      BLOCKED. Both count toward a deny at the WARN band.
#   Known false positives: a nested object literal inside the SAME call that
#   happens to have its own `model:`-named key (e.g. a JSON schema property)
#   reads as "pinned" even if the actual `agent()` options omit it. A literal
#   "agent(" substring in prose (case 1 above) inflates the call count by one
#   phantom unpinned call. Known false negative: if the call's closing paren
#   can't be found before the read cap (CC_WORKFLOW_SCRIPT_MAX_BYTES,
#   default 64KiB) or before a LITER "agent(" match nested inside the same
#   call's own text, that call is silently skipped rather than mis-scored —
#   fail-open bias, consistent with the rest of this bundle.
#
# BANDS (mirrors guard-usage-budget.sh's ladder — see CLAUDE.md):
#   < WARN_PCT (70, unless CC_WORKFLOW_REQUIRE_STAGE_MODEL=1): allow, ZERO
#     BYTES — an installed system must be byte-identical to an uninstalled
#     one below this line.
#   >= WARN_PCT (70): deny if the lint finds an unpinned or blocked-model
#     stage; a fully-pinned script, or a name-only/resume launch (nothing to
#     lint), still passes.
#   >= SOFT_PCT (80): deny EVERY workflow launch outright — a workflow is a
#     fan-out of potentially dozens-to-hundreds of spawns, the same reason
#     guard-usage-budget.sh denies all new Agent/Task spawns at this band.
#
# FAILS OPEN on: kill switch, missing jq, non-Workflow tool, non-PreToolUse
# event, garbage payload, missing/stale (> CC_STATE_MAX_AGE)/unparseable
# usage state, and an unreadable scriptPath. Preserve every one of these on
# any edit — tests/test-workflow-guard.sh asserts each path.
#
# Install: register on PreToolUse with matcher "Workflow". See
# settings.snippet.json. Offline unit tests: tests/test-workflow-guard.sh.

set -uo pipefail

# Master kill switch (/cost-control off) — flag present => transparent no-op.
DISABLE_FLAG="${CC_DISABLE_FLAG:-${CC_ROOT:-$HOME/.claude/cost-control}/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && exit 0

STATE_FILE="${CC_USAGE_STATE:-$HOME/.claude/.usage-state.json}"
LOG="${CC_WORKFLOW_GUARD_LOG:-$HOME/.claude/logs/workflow-guard.jsonl}"
WARN_PCT="${CC_BUDGET_WARN_PCT:-70}"
SOFT_PCT="${CC_BUDGET_SOFT_PCT:-80}"
MAX_AGE="${CC_STATE_MAX_AGE:-900}"
BLOCK_MODELS="${CC_BLOCK_MODELS:-fable}"
REQUIRE_STAGE_MODEL="${CC_WORKFLOW_REQUIRE_STAGE_MODEL:-0}"     # 1 = lint at ANY usage %
SCRIPT_CAP="${CC_WORKFLOW_SCRIPT_MAX_BYTES:-65536}"             # bound lint cost; see CLAUDE.md perf note
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0     # no jq -> allow (fail open)

# Cheap first pass: only scalar fields, safe to join on one line even though
# scriptPath/name are technically user-controlled strings (paths/names don't
# carry raw newlines in practice). `script`'s raw text is fetched separately,
# ONLY when a lint is actually going to run, so the common allow-fast-path
# (non-Workflow tool, or below WARN with linting not forced) never pays for it.
in_line="$(printf '%s' "$input" | jq -r '
  [ (.hook_event_name // ""), (.tool_name // ""),
    ((.tool_input.scriptPath // "")), ((.tool_input.name // "")),
    ((.tool_input.resumeFromRunId // "")),
    ((.tool_input.script // "") | if . == "" then "0" else "1" end) ]
  | map(tostring) | join("")' 2>/dev/null)" || in_line=""
IFS=$'\x1f' read -r event tool scriptPath wf_name resumeId has_script <<< "$in_line"

case "$event" in PreToolUse|"") : ;; *) exit 0 ;; esac
[[ "$tool" == "Workflow" ]] || exit 0

log() { # $1=action $2=reason $3=pct(or "") $4=source(or "") $5=lint_total(or "") $6=lint_unpinned(or "") $7=lint_blocked(or "")
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg act "$1" --arg why "$2" \
    --arg pct "${3:-}" --arg src "${4:-}" --arg t "${5:-}" --arg u "${6:-}" --arg b "${7:-}" '
    {ts:$ts, tool:"Workflow", action:$act, reason:$why}
    + (if $pct == "" then {} else {five_hour_pct: ($pct|tonumber)} end)
    + (if $src == "" then {} else {source:$src} end)
    + (if $t   == "" then {} else {lint_total:($t|tonumber)} end)
    + (if $u   == "" then {} else {lint_unpinned:($u|tonumber)} end)
    + (if $b   == "" then {} else {lint_blocked:($b|tonumber)} end)' \
    >> "$LOG" 2>/dev/null || true
}
deny() { # $1=reason $2=pct $3=source(or "") $4=lint_total(or "") $5=lint_unpinned(or "") $6=lint_blocked(or "")
  log "deny" "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

[[ -f "$STATE_FILE" ]] || exit 0
st_line="$(jq -r '[ (.five_hour_pct // ""), (.updated_at // "") ] | map(tostring) | join("")' "$STATE_FILE" 2>/dev/null)" || st_line=""
IFS=$'\x1f' read -r five updated <<< "$st_line"
[[ -z "$five" || "$five" == "null" ]] && exit 0

now="$(date +%s)"
[[ "$updated" =~ ^[0-9]+$ ]] || exit 0
(( now - updated > MAX_AGE )) && exit 0

five_i="$(printf '%.0f' "$five" 2>/dev/null || printf '%s' "$five")"
[[ "$five_i" =~ ^[0-9]+$ ]] || exit 0

lint_forced=0
case "$(printf '%s' "$REQUIRE_STAGE_MODEL" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) lint_forced=1 ;;
esac

# --- SOFT band: deny every launch outright, no lint needed ---
if (( five_i >= SOFT_PCT )); then
  deny "5-hour usage at ${five_i}% (SOFT limit ${SOFT_PCT}%). A workflow fans out into many subagent spawns — exactly the fan-out the SOFT band exists to stop. Serialize the remaining work in the main thread on a cheap model, or wait for the window to recover." "$five_i"
fi

lint_now=0
(( five_i >= WARN_PCT )) && lint_now=1
[[ "$lint_forced" == "1" ]] && lint_now=1

if (( lint_now == 0 )); then
  exit 0    # below WARN, not forced -> zero bytes, byte-identical to uninstalled
fi

# --- Resolve script text to lint. scriptPath takes precedence per docs. ---
script_text=""
source="none"
if [[ -n "$scriptPath" ]]; then
  source="scriptPath"
  if [[ -f "$scriptPath" && -r "$scriptPath" ]]; then
    script_text="$(head -c "$SCRIPT_CAP" -- "$scriptPath" 2>/dev/null)" || script_text=""
  else
    log "allow" "scriptPath unreadable ('$scriptPath') — cannot lint, failing open" "$five_i"
    exit 0
  fi
elif [[ "$has_script" == "1" ]]; then
  source="script"
  script_text="$(printf '%s' "$input" | jq -r '.tool_input.script // ""' 2>/dev/null)" || script_text=""
  script_text="${script_text:0:$SCRIPT_CAP}"
elif [[ -n "$resumeId" ]]; then
  log "allow" "resumeFromRunId launch — no script text to lint" "$five_i" "resumeFromRunId"
  exit 0
elif [[ -n "$wf_name" ]]; then
  log "allow" "name-only (saved/built-in) workflow '$wf_name' — no script text to lint at launch" "$five_i" "name"
  exit 0
else
  log "allow" "no script/scriptPath/name/resumeFromRunId resolvable — cannot lint" "$five_i"
  exit 0
fi

if [[ -z "$script_text" ]]; then
  log "allow" "empty script text — nothing to lint" "$five_i" "$source"
  exit 0
fi

# normalize block list -> lowercase regex alternation (mirrors guard-subagent-model.sh)
blk_re="$(printf '%s' "$BLOCK_MODELS" | tr '[:upper:]' '[:lower:]' | tr ', ' '\n\n' | sed '/^$/d' | paste -sd'|' -)"

# Single linear-time pass (see header comment for the algorithm). Uses
# split() on the literal "agent(" token so cost scales with script length,
# not with (script length x call count) — verified up to ~150KB/2000 calls.
lint_out="$(printf '%s' "$script_text" | awk -v RS=$'\x01' -v SQ="'" -v DQ='"' -v BT='`' -v blocked_re="$blk_re" '
  function isword(ch) { return (ch ~ /[A-Za-z0-9_$]/) }
  {
    s = $0
    np = split(s, parts, /agent\(/)
    total=0; unpinned=0; blocked=0
    for (k=1; k<np; k++) {
      pk = parts[k]; lpk = length(pk)
      boundary_ok = (lpk==0) ? 1 : !isword(substr(pk, lpk, 1))
      if (!boundary_ok) continue
      piece = parts[k+1]; m = length(piece)
      j=1; depth=1; instr=""
      while (j<=m && depth>0) {
        c=substr(piece,j,1)
        if (instr!="") {
          if (c=="\\") { j+=2; continue }
          if (c==instr) instr=""
          j++; continue
        }
        if (c==SQ || c==DQ || c==BT) { instr=c; j++; continue }
        if (c=="(") { depth++; j++; continue }
        if (c==")") { depth--; j++; continue }
        j++
      }
      if (depth==0) {
        call_text = tolower(substr(piece,1,j-2))
        total++
        if (call_text !~ /model[ \t\r\n]*:/) unpinned++
        else if (blocked_re!="" && call_text ~ blocked_re) blocked++
      }
    }
    printf "%d %d %d\n", total, unpinned, blocked
  }' 2>/dev/null)"
read -r lint_total lint_unpinned lint_blocked <<< "${lint_out:-0 0 0}"
[[ "$lint_total" =~ ^[0-9]+$ ]] || lint_total=0
[[ "$lint_unpinned" =~ ^[0-9]+$ ]] || lint_unpinned=0
[[ "$lint_blocked" =~ ^[0-9]+$ ]] || lint_blocked=0

if (( lint_unpinned > 0 || lint_blocked > 0 )); then
  deny "5-hour usage at ${five_i}%$( [[ "$lint_forced" == "1" && $five_i -lt $WARN_PCT ]] && printf ' (CC_WORKFLOW_REQUIRE_STAGE_MODEL=1)' || printf " (WARN limit ${WARN_PCT}%%)" ). This workflow launch has ${lint_unpinned} agent() stage(s) with no explicit model and/or ${lint_blocked} stage(s) requesting a blocked model (policy: never ${BLOCK_MODELS}). Add an explicit {model, effort} to every agent() call — haiku for read-only/search, sonnet for general work, opus for critical review only — and relaunch." "$five_i" "$source" "$lint_total" "$lint_unpinned" "$lint_blocked"
fi

log "allow" "lint clean: ${lint_total} agent() call(s), all pinned" "$five_i" "$source" "$lint_total" "$lint_unpinned" "$lint_blocked"
exit 0
