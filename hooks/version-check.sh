#!/usr/bin/env bash
# version-check.sh — SessionStart hook: the trigger for the self-updating
# validation layer.
#
# On every session start it compares the installed Claude Code version to the
# version pinned when the cost-management config was last verified. It stays
# SILENT when they match (no noise). It speaks only in two cases:
#   * FIRST RUN (no lock file): records the current version as the provisional
#     pin and asks the model to run the `cost-control-verify` skill to establish
#     the baseline against the current docs.
#   * DRIFT (installed != pinned): flags that Claude Code updated and asks the
#     model to run `cost-control-verify` to diff the new version's docs against
#     the baseline and update the hooks/agents/scripts/schemas accordingly.
#
# It injects that request as SessionStart `additionalContext` — the supported way
# for a SessionStart hook to put text in front of the model. It never blocks the
# session and always exits 0.
#
# Install on SessionStart (see settings.snippet.json). Requires jq; degrades to
# a plain-text nudge without it.

set -uo pipefail
ROOT="${CC_ROOT:-$HOME/.claude/cost-control}"
# Master kill switch (/cost-control off) — flag present => stay silent.
DISABLE_FLAG="${CC_DISABLE_FLAG:-$ROOT/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && exit 0
LOCK="${CC_VERSION_LOCK:-$ROOT/manifest/version.lock}"
DRIFT_FLAG="${CC_DRIFT_FLAG:-$ROOT/manifest/.drift}"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true

# --- read installed version (CONFIRMED: `claude --version`) ---
raw="${CC_CLI_VERSION:-$(claude --version 2>/dev/null || true)}"
cur="$(printf '%s' "$raw" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ -z "$cur" ]] && exit 0     # can't determine version -> stay silent

emit() { # emit additionalContext for SessionStart, or plain text if no jq
  local msg="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
  else
    printf '%s\n' "$msg"
  fi
}

write_lock() { # $1=pinned version  $2=status
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$1" --arg s "$2" --arg d "$(date -u +%FT%TZ)" \
      '{pinned_version:$v, status:$s, updated:$d}' > "$LOCK" 2>/dev/null || true
  else
    printf '{"pinned_version":"%s","status":"%s"}\n' "$1" "$2" > "$LOCK" 2>/dev/null || true
  fi
}

# --- first run: no baseline yet ---
if [[ ! -f "$LOCK" ]]; then
  write_lock "$cur" "baseline-pending"
  emit "COST-CONTROL SETUP: the usage cost-management config was just installed and its version baseline is not yet established (Claude Code v${cur}). Run the \`cost-control-verify\` skill now to verify the version-dependent claims in manifest/claims.json against the current docs, record the baseline, and confirm the hooks/agents fire correctly on this build. Do this once, then it stays quiet until Claude Code updates."
  exit 0
fi

pinned="$(jq -r '.pinned_version // empty' "$LOCK" 2>/dev/null || sed -n 's/.*"pinned_version":"\([^"]*\)".*/\1/p' "$LOCK")"
[[ -z "$pinned" ]] && exit 0

if [[ "$cur" == "$pinned" ]]; then
  rm -f "$DRIFT_FLAG" 2>/dev/null || true
  exit 0                       # in sync -> silent
fi

# --- drift detected ---
printf '%s\n' "$cur" > "$DRIFT_FLAG" 2>/dev/null || true
emit "COST-CONTROL VERSION DRIFT: Claude Code updated from v${pinned} (last verified) to v${cur}. The usage cost-management validation layer may be stale — hook events, the subagent-spawn schema, statusline fields, or config keys can change between versions. Run the \`cost-control-verify\` skill to diff the v${cur} docs against manifest/claims.json, write a CHANGELOG entry, apply safe updates (prose/manifest) and propose any executable-code patches for review, then bump the version lock to v${cur}."
exit 0
