#!/usr/bin/env bash
# guard-subagent-model.sh — PreToolUse gate that blocks expensive/ambiguous
# subagent spawns WITHOUT touching your per-agent model roster.
#
# WHY THIS EXISTS (the core insight):
#   CLAUDE_CODE_SUBAGENT_MODEL is a highest-precedence OVERRIDE, not a default —
#   docs (model-config.md env-var table): "Overrides the per-invocation `model`
#   parameter and the subagent definition's `model` frontmatter." So you can NOT
#   express "default cheap, let frontmatter win" with that env var.
#   This hook gives you the missing piece: frontmatter/per-invocation model stays
#   authoritative, and the hook only DENIES the spawns you never want — it never
#   rewrites a model. Deny-not-rewrite is what preserves your roster.
#
# SPAWN SURFACE (re-verified against code.claude.com docs 2026-08-09, v2.1.226):
#   * A subagent spawn IS a PreToolUse tool call on the `Agent` tool (renamed
#     from `Task` in v2.1.63; `Task` still works as an alias — sub-agents.md).
#     PreToolUse blocks via JSON permissionDecision:"deny" (hooks.md).
#     THIS IS THE ONLY HOOK SURFACE THAT CAN BLOCK A SPAWN.
#   * `SubagentStart` fires when a subagent is spawned but CANNOT block
#     (hooks.md decision-control table: "SessionStart, Setup, SubagentStart |
#     Context only | ... No blocking or decision control") and its payload
#     carries agent_id/agent_type but no model. If this hook is registered
#     there anyway, it only logs.
#   * `TaskCreated` is the TASK LIST event ("when a task is being created via
#     TaskCreate" — hooks.md), NOT a subagent spawn. Do not register this hook
#     there; if it fires there anyway, it passes through untouched.
#   * This hook also gates spawns made BY a subagent: hooks.md now states that
#     "Hooks from settings files, managed policy settings, and plugins also run
#     inside subagents", with agent_id/agent_type set on the input. Nesting
#     defaults to 3 layers (CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH).
#
# WHAT IT BLOCKS (configurable):
#   * a spawn whose resolved model matches CC_BLOCK_MODELS (default: fable)
#   * optionally, a spawn with NO explicit model (CC_REQUIRE_EXPLICIT_MODEL=1)
#
# SAFETY: the Agent tool's tool_input layout IS now published (hooks.md "Tool
# input schemas" -> "##### Agent": prompt, description, subagent_type, model),
# and the primary probes below match it exactly as of v2.1.226. The
# .params.model/.opts.model fallbacks are therefore redundant — kept because
# they cost nothing and would absorb a future rename. The hook still FAILS OPEN
# (allows + logs) whenever it can't positively identify a bad spawn, so it will
# never wedge your session on an unexpected payload. After a `claude update`,
# check ~/.claude/logs/model-guard.jsonl for allow-entries with an empty model
# where you expected a value — that is the signature of a schema change.
#
# Install: register on PreToolUse with matcher "Agent|Task". See
# settings.snippet.json. Offline unit tests: tests/test-hooks.sh.

set -uo pipefail

# Master kill switch (/cost-control off) — flag present => transparent no-op.
DISABLE_FLAG="${CC_DISABLE_FLAG:-${CC_ROOT:-$HOME/.claude/cost-control}/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && exit 0

LOG="${CC_GUARD_LOG:-$HOME/.claude/logs/model-guard.jsonl}"
BLOCK_MODELS="${CC_BLOCK_MODELS:-fable}"                 # space/comma separated substrings
REQUIRE_EXPLICIT="${CC_REQUIRE_EXPLICIT_MODEL:-0}"      # 1 = deny spawns with no model
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0                  # no jq -> allow (fail open)

# Single-pass parse (one jq — keeps spawn-gating overhead ~10ms).
in_line="$(printf '%s' "$input" | jq -r '
  [ (.hook_event_name // ""), (.tool_name // ""),
    ((.tool_input.model // .tool_input.params.model // .tool_input.opts.model) // ""),
    ((.tool_input.subagent_type // .tool_input.agent_type // .agent_type) // "") ]
  | map(tostring) | join("")' 2>/dev/null)" || in_line=""
IFS=$'\x1f' read -r event tool model subagent_type <<< "$in_line"   # \x1f: empty fields survive

# Only the Agent tool call (alias Task) is a spawn we can gate. Everything else
# passes untouched — including TaskCreated (task list, unrelated to spawns).
case "$event" in
  PreToolUse|"") : ;;
  SubagentStart) : ;;   # observe-only below; cannot block per docs
  *) exit 0 ;;
esac
if [[ "$event" == "PreToolUse" || -z "$event" ]]; then
  case "$tool" in
    Agent|Task) : ;;
    *) exit 0 ;;
  esac
fi

# model was resolved in the single-pass parse above: .tool_input.model (the
# Agent tool's per-invocation model parameter) with cheap fallbacks. Empty =>
# "no explicit model" (frontmatter or session model will apply).
# A global override, if set, wins over everything (mirrors documented precedence:
# env var > per-invocation model > frontmatter > session model — sub-agents.md),
# so we evaluate what will actually run, not just what was requested.
[[ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" && "${CLAUDE_CODE_SUBAGENT_MODEL}" != "inherit" ]] && model="${CLAUDE_CODE_SUBAGENT_MODEL}"

log() { printf '%s\n' "$(jq -nc --arg e "$event" --arg t "$tool" --arg m "${model:-}" --arg st "${subagent_type:-}" \
        --arg act "$1" --arg why "$2" --arg ts "$(date -u +%FT%TZ)" \
        '{ts:$ts,event:$e,tool:$t,model:$m,subagent_type:$st,action:$act,reason:$why}')" >> "$LOG" 2>/dev/null || true; }

# SubagentStart cannot block (docs): record what we see and get out of the way.
if [[ "$event" == "SubagentStart" ]]; then
  log "observe" "SubagentStart cannot block per docs; PreToolUse gate is authoritative"
  exit 0
fi

# PreToolUse deny: JSON permissionDecision (exit 0) — the documented mechanism.
deny() {
  log "deny" "$1"
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# normalize block list -> regex alternation
blk_re="$(printf '%s' "$BLOCK_MODELS" | tr ', ' '\n\n' | sed '/^$/d' | paste -sd'|' -)"

if [[ -n "$model" && -n "$blk_re" ]] && printf '%s' "$model" | grep -Eiq "$blk_re"; then
  deny "Blocked subagent model '$model'. Cost-discipline policy: never spawn subagents on $BLOCK_MODELS. Re-dispatch this agent with an explicit cheaper model (haiku=read-only/search, sonnet=general work, opus=critical review only) and an explicit effort."
fi

if [[ -z "$model" && "$REQUIRE_EXPLICIT" == "1" ]]; then
  deny "Subagent spawned with no explicit model — it would inherit the (expensive) session model. Policy requires an explicit model + effort per spawn. Set model to haiku/sonnet/opus per the routing rubric and try again."
fi

log "allow" "${model:-<inherit>}"
exit 0
