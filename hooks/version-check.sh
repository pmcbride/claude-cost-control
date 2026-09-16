#!/usr/bin/env bash
# version-check.sh — SessionStart hook: the trigger for the self-updating
# validation layer.
#
# On every session start it compares the installed Claude Code version to the
# version pinned when the cost-management config was last verified. It is
# SILENT when they match. It acts in two cases:
#   * FIRST RUN (no lock file): records the current version as the provisional
#     pin (status baseline-pending) and asks for the `cost-control-verify` skill
#     to establish the baseline against the current docs.
#   * DRIFT (installed != pinned): writes manifest/.drift and asks for
#     `cost-control-verify` to diff the new version's docs against the baseline.
#
# HOW IT ASKS — CC_VERIFY_MODE (added 2026-09-16):
#   background (default) — emit NOTHING into the chat. Instead start ONE detached
#       background Claude Code session (`claude --bg "<prompt>"`, claim
#       background-session-cli) that runs the verify skill non-interactively:
#       safe updates applied, HITL/executable changes written into the CHANGELOG
#       as proposals and NOT applied, lock bumped only when nothing HITL is
#       pending. Rationale: the old inline request landed in whatever chat the
#       user happened to open and derailed it — once per session until someone
#       ran the skill. The statusline shows [cc-verifying vX] / [cc-stale vX]
#       instead, so drift stays visible without costing the foreground chat.
#   inline — the pre-2026-09-16 behaviour: SessionStart `additionalContext`
#       with the SETUP / VERSION DRIFT text, unchanged.
#   off    — only write .drift / the lock; no request at all.
#
# DISPATCH SAFETY:
#   * dedupe: manifest/.verify-dispatched {version, dispatched_at, dispatched_epoch,
#     status, session_id}. No second dispatch for the same version inside
#     CC_VERIFY_REDISPATCH_HOURS (default 12). Cleared when back in sync.
#   * recursion: the dispatched session inherits CC_VERIFY_CHILD=1, and this hook
#     never dispatches while it is set (the child's own SessionStart sees drift).
#   * kill switch: /cost-control off silences this hook entirely (checked first).
#   * fail-silent: no `claude` binary, no jq, or a failed launch → nothing is
#     emitted, .drift is still written, exit 0. The launch itself runs under
#     nohup with stdin </dev/null and output to a log, so the hook returns in
#     milliseconds; the session id `--bg` prints is patched into the marker
#     asynchronously when it can be parsed.
#
# Never blocks the session; always exits 0. Install on SessionStart (see
# settings.snippet.json). Requires jq for background mode; inline mode degrades
# to a plain-text nudge without it.

set -uo pipefail
ROOT="${CC_ROOT:-$HOME/.claude/cost-control}"
# Master kill switch (/cost-control off) — flag present => stay silent.
DISABLE_FLAG="${CC_DISABLE_FLAG:-$ROOT/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && exit 0
LOCK="${CC_VERSION_LOCK:-$ROOT/manifest/version.lock}"
DRIFT_FLAG="${CC_DRIFT_FLAG:-$ROOT/manifest/.drift}"
MARKER="${CC_VERIFY_MARKER:-$ROOT/manifest/.verify-dispatched}"
DISPATCH_LOG="${CC_VERIFY_DISPATCH_LOG:-$HOME/.claude/logs/cost-control-verify-dispatch.log}"
MODE="${CC_VERIFY_MODE:-background}"
REDISPATCH_HOURS="${CC_VERIFY_REDISPATCH_HOURS:-12}"
[[ "$REDISPATCH_HOURS" =~ ^[0-9]+$ ]] || REDISPATCH_HOURS=12
CLAUDE_BIN="${CC_CLAUDE_BIN:-claude}"
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

# dispatch_verify <kind: setup|drift> <pinned-or-empty>
# Starts the background verify session unless deduped/suppressed. Never emits
# to stdout; every failure is silent.
dispatch_verify() {
  local kind="$1" from="$2" now prev_v prev_e prompt
  [[ "${CC_VERIFY_CHILD:-0}" == "1" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || return 0
  now="$(date +%s)"

  if [[ -f "$MARKER" ]]; then
    prev_v="$(jq -r '.version // empty' "$MARKER" 2>/dev/null)"
    prev_e="$(jq -r '.dispatched_epoch // 0' "$MARKER" 2>/dev/null)"
    [[ "$prev_e" =~ ^[0-9]+$ ]] || prev_e=0
    if [[ "$prev_v" == "$cur" ]] && (( now - prev_e < REDISPATCH_HOURS * 3600 )); then
      return 0                  # already dispatched for this version recently
    fi
  fi

  if [[ "$kind" == "setup" ]]; then
    prompt="Run the \`cost-control-verify\` skill NON-INTERACTIVELY to establish the first baseline for Claude Code v${cur} (manifest/version.lock is status baseline-pending). "
  else
    prompt="Run the \`cost-control-verify\` skill NON-INTERACTIVELY for Claude Code v${cur} (last verified: v${from}; manifest/.drift is set). "
  fi
  prompt+="You are a background session started by hooks/version-check.sh; no human is watching, so never ask questions. Bundle root: ${ROOT}. Rules: (1) If manifest/version.lock already pins ${cur} with a status other than baseline-pending and manifest/.drift is absent, another session already verified this version: stop without changes. If manifest/CHANGELOG.md already has an entry for v${cur} with HITL items still pending, do not re-verify: stop. (2) Apply ONLY the SAFE updates allowed by the skill's Safe-vs-HITL policy. (3) For every HITL / executable-logic change, write the full proposal (file, patch, rationale) into the v${cur} CHANGELOG entry and do NOT apply it. (4) Run the offline tests (tests/run-all.sh). (5) Bump version.lock to ${cur} and remove manifest/.drift ONLY if no HITL item is pending and tests pass; otherwise leave the lock and .drift untouched, say so explicitly in the CHANGELOG entry, and set .status to \"hitl-pending\" in manifest/.verify-dispatched (jq; keep the other fields) so the statusline switches from [cc-verifying] to [cc-stale]. (6) Do not spawn subagents and do not run make sync/install. Finish with a one-paragraph summary."

  # Record the dispatch BEFORE launching, so a concurrent SessionStart dedupes.
  mkdir -p "$(dirname "$MARKER")" "$(dirname "$DISPATCH_LOG")" 2>/dev/null || true
  jq -nc --arg v "$cur" --arg d "$(date -u +%FT%TZ)" --arg e "$now" \
    '{version:$v, dispatched_at:$d, dispatched_epoch:($e|tonumber), status:"dispatched", session_id:null}' \
    > "$MARKER" 2>/dev/null || return 0

  # Fully detached launcher: nohup, stdin </dev/null, stdout/stderr to the log,
  # cwd $ROOT, CC_VERIFY_CHILD=1 exported. It waits for `--bg` (which returns
  # immediately) and patches the printed session id into the marker.
  CC_VERIFY_CHILD=1 CC_VD_BIN="$CLAUDE_BIN" CC_VD_PROMPT="$prompt" CC_VD_MARKER="$MARKER" \
  CC_VD_ROOT="$ROOT" CC_VD_VERSION="$cur" \
  nohup bash -c '
    cd "$CC_VD_ROOT" 2>/dev/null || cd "$HOME" || exit 0
    printf "[%s] dispatch v%s: %s --bg\n" "$(date -u +%FT%TZ)" "$CC_VD_VERSION" "$CC_VD_BIN"
    out="$("$CC_VD_BIN" --bg "$CC_VD_PROMPT" </dev/null 2>&1)"; rc=$?
    printf "%s\n[rc=%s]\n" "$out" "$rc"
    sid="$(printf "%s" "$out" | grep -Eo "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" | head -1)"
    [[ -z "$sid" ]] && sid="$(printf "%s" "$out" | grep -Eo "attach [A-Za-z0-9_.-]+" | head -1 | cut -d" " -f2)"
    if [[ $rc -eq 0 ]]; then st=started; else st=failed; fi
    tmp="$CC_VD_MARKER.tmp.$$"
    jq -c --arg s "$sid" --arg st "$st" --arg v "$CC_VD_VERSION" \
      "if .version == \$v then .status = \$st | .session_id = (if \$s == \"\" then null else \$s end) else . end" \
      "$CC_VD_MARKER" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CC_VD_MARKER" || rm -f "$tmp"
  ' </dev/null >>"$DISPATCH_LOG" 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# --- first run: no baseline yet ---
if [[ ! -f "$LOCK" ]]; then
  write_lock "$cur" "baseline-pending"
  case "$MODE" in
    inline)
      emit "COST-CONTROL SETUP: the usage cost-management config was just installed and its version baseline is not yet established (Claude Code v${cur}). Run the \`cost-control-verify\` skill now to verify the version-dependent claims in manifest/claims.json against the current docs, record the baseline, and confirm the hooks/agents fire correctly on this build. Do this once, then it stays quiet until Claude Code updates." ;;
    off) ;;
    *) dispatch_verify setup "" ;;
  esac
  exit 0
fi

pinned="$(jq -r '.pinned_version // empty' "$LOCK" 2>/dev/null || sed -n 's/.*"pinned_version":"\([^"]*\)".*/\1/p' "$LOCK")"
[[ -z "$pinned" ]] && exit 0

if [[ "$cur" == "$pinned" ]]; then
  rm -f "$DRIFT_FLAG" "$MARKER" 2>/dev/null || true
  exit 0                       # in sync -> silent
fi

# --- drift detected ---
printf '%s\n' "$cur" > "$DRIFT_FLAG" 2>/dev/null || true
case "$MODE" in
  inline)
    emit "COST-CONTROL VERSION DRIFT: Claude Code updated from v${pinned} (last verified) to v${cur}. The usage cost-management validation layer may be stale — hook events, the subagent-spawn schema, statusline fields, or config keys can change between versions. Run the \`cost-control-verify\` skill to diff the v${cur} docs against manifest/claims.json, write a CHANGELOG entry, apply safe updates (prose/manifest) and propose any executable-code patches for review, then bump the version lock to v${cur}." ;;
  off) ;;
  *) dispatch_verify drift "$pinned" ;;
esac
exit 0
