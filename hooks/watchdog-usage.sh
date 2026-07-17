#!/usr/bin/env bash
# watchdog-usage.sh — external burn-spike circuit breaker that can actually STOP
# runaway background work (the thing hooks can't do — hooks only block NEW work).
#
# Run it as a standalone poller (NOT a Claude Code hook). Every INTERVAL seconds
# it reads the 5h usage % from the statusline's state file and, above STOP_PCT,
# stops the lowest-priority running background sessions so a fan-out can't blow
# through the window while you're away. You then inspect the stopped sessions in
# agent view and resume / downgrade as you like.
#
#   ./watchdog-usage.sh                 # poll every 30s, stop at 94%
#   CC_WATCHDOG_STOP_PCT=90 CC_WATCHDOG_INTERVAL=60 ./watchdog-usage.sh
#   CC_WATCHDOG_DRYRUN=1 ./watchdog-usage.sh     # log what it WOULD stop, stop nothing
#
# STOP_PCT defaults to 94 — deliberately ABOVE the budget gate's HARD band (90).
# Escalation order: nudge (70/80) < deny new spawns (80) < deny heavy work (90)
# < kill running sessions (94). Killing is the most destructive control, so it
# fires last.
#
# CLI surface (verified against code.claude.com/docs/en/agent-view 2026-07-16):
# `claude agents --json` prints active sessions as a JSON array; background
# entries carry `id`, `startedAt`, and `state` (one of working|blocked|done|
# failed|stopped); `pid`/`status` are present only while the process is alive.
# `claude stop <id>` stops one session. The script still probes for the
# subcommands on startup and refuses to run (loudly) if they're absent.
#
# STALENESS: the state file is written by the statusline, i.e. only while an
# interactive session is rendering. The watchdog SKIPS action when the state is
# older than CC_STATE_MAX_AGE (default 900s) — otherwise a stale 95% reading
# would keep killing sessions long after the window reset.
#
# Safety: only ever stops sessions whose state is "working"; never touches
# "blocked" (may be awaiting your input) unless CC_WATCHDOG_INCLUDE_BLOCKED=1.
# Stops the most recently started sessions first (least sunk cost). Keeps
# INTERVAL >= 30s to stay low-CPU.

set -uo pipefail
STATE_FILE="${CC_USAGE_STATE:-$HOME/.claude/.usage-state.json}"
LOG="${CC_WATCHDOG_LOG:-$HOME/.claude/logs/watchdog.jsonl}"
STOP_PCT="${CC_WATCHDOG_STOP_PCT:-94}"
INTERVAL="${CC_WATCHDOG_INTERVAL:-30}"
MAX_AGE="${CC_STATE_MAX_AGE:-900}"
MAX_STOP_PER_TICK="${CC_WATCHDOG_MAX_STOP:-1}"   # stop at most N per poll, gentlest first
DRYRUN="${CC_WATCHDOG_DRYRUN:-0}"
INCLUDE_BLOCKED="${CC_WATCHDOG_INCLUDE_BLOCKED:-0}"
(( INTERVAL < 30 )) && INTERVAL=30
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || { echo "watchdog: jq required" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "watchdog: 'claude' CLI not found on PATH" >&2; exit 1; }

# ---- probe the CLI surface (fail loudly, never silently no-op) ----
if ! claude agents --json >/dev/null 2>&1; then
  echo "watchdog: 'claude agents --json' not available on this build — aborting." >&2
  echo "          Verify with: claude agents --help   (adjust list_sessions() if named differently)" >&2
  exit 1
fi

list_sessions() { claude agents --json 2>/dev/null; }         # -> JSON array of sessions
stop_session()  { claude stop "$1" >/dev/null 2>&1; }         # stop one by id

log() { jq -nc --arg ts "$(date -u +%FT%TZ)" --arg a "$1" --arg d "$2" \
        '{ts:$ts,action:$a,detail:$d}' >> "$LOG" 2>/dev/null || true; }

# read five_hour_pct + updated_at together; emit "" if stale/missing
read_five_fresh() {
  local five updated now
  five="$(jq -r '.five_hour_pct // empty' "$STATE_FILE" 2>/dev/null)"
  updated="$(jq -r '.updated_at // 0' "$STATE_FILE" 2>/dev/null)"
  [[ -z "$five" ]] && return 0
  now="$(date +%s)"
  [[ "$updated" =~ ^[0-9]+$ ]] || return 0
  (( now - updated > MAX_AGE )) && { log stale "state $((now-updated))s old > ${MAX_AGE}s; skipping"; return 0; }
  printf '%s' "$five"
}

echo "watchdog: polling every ${INTERVAL}s; stop threshold ${STOP_PCT}% (dryrun=${DRYRUN})"
log start "stop_pct=${STOP_PCT} interval=${INTERVAL} dryrun=${DRYRUN}"

while true; do
  five="$(read_five_fresh)"; five_i="$(printf '%.0f' "${five:-}" 2>/dev/null || echo -1)"
  if [[ "$five_i" =~ ^[0-9]+$ ]] && (( five_i >= STOP_PCT )); then
    # Documented `--json` schema: id, startedAt, state ∈ working|blocked|done|failed|stopped.
    # Victims: "working" sessions (+ "blocked" only if opted in), newest first.
    states='["working"]'; (( INCLUDE_BLOCKED == 1 )) && states='["working","blocked"]'
    JQ_FILTER='(if type=="array" then . else (.sessions // .agents // []) end)
      | map(select(.id != null))
      | map(select(((.state // .status // "") ) as $s | $st | index($s)))
      | sort_by(.startedAt // .started_at // 0) | reverse | .[].id'
    victims="$(list_sessions | jq -r --argjson st "$states" "$JQ_FILTER" 2>/dev/null | head -n "$MAX_STOP_PER_TICK")"
    if [[ -n "$victims" ]]; then
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if [[ "$DRYRUN" == "1" ]]; then
          echo "watchdog: [dryrun] would stop $id (5h=${five_i}%)"; log dryrun-stop "$id@${five_i}%"
        else
          stop_session "$id" && { echo "watchdog: stopped $id (5h=${five_i}%)"; log stop "$id@${five_i}%"; }
        fi
      done <<< "$victims"
    else
      log tick "over-threshold ${five_i}% but no stoppable sessions"
    fi
  fi
  sleep "$INTERVAL"
done
