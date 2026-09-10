#!/usr/bin/env bash
# usage-statusline.sh — usage-aware Claude Code status line.
#
# Renders (left→right): model · effort · context% · 5h usage% · 7d usage% · $cost
# and — as a SIDE EFFECT — writes a small JSON state file that the usage-budget
# PreToolUse hook reads to decide whether to allow new heavy work.
#
# Everything it displays comes straight from the JSON Claude Code pipes to a
# statusLine command on stdin. No API calls, no polling, no background process —
# so it is neither noisy nor a resource drain. It runs on Claude Code's own
# refresh cadence (settings.json statusLine.refreshInterval).
#
# Verified fields (code.claude.com/docs/en/statusline, 2026-07-16):
# model.display_name, effort.level, context_window.used_percentage,
# exceeds_200k_tokens, cost.total_cost_usd, output_style.name, agent.name, and
# rate_limits.{five_hour,seven_day}.used_percentage (+ .resets_at epoch seconds).
# rate_limits appears only for Claude.ai subscribers (Pro/Max) after the first
# API response in the session — the script degrades gracefully when absent.
#
# COLORS: Claude Code supports ANSI escape codes in statusline output, and it
# CAPTURES the script's stdout (it is never a tty) — so color is gated only on
# CC_STATUSLINE_NOCOLOR, never on -t/isatty.
#
# Install: chmod +x, then point settings.json statusLine.command at this file.

set -euo pipefail

# ---- state file the budget guardrail reads (override with CC_USAGE_STATE) ----
STATE_FILE="${CC_USAGE_STATE:-$HOME/.claude/.usage-state.json}"

# ---- thresholds (only affect COLOR here; the hard gate lives in the hook) ----
# Aligned with the escalation ladder: amber when the throttle nudge starts (70),
# red when the budget gate's HARD band starts denying heavy work (90).
WARN_PCT="${CC_USAGE_WARN_PCT:-70}"    # amber at/above this 5h %
CRIT_PCT="${CC_USAGE_CRIT_PCT:-90}"    # red   at/above this 5h %

# ---- colors (disable by exporting CC_STATUSLINE_NOCOLOR=1) ----
if [[ "${CC_STATUSLINE_NOCOLOR:-0}" == "1" ]]; then
  DIM=""; RED=""; YEL=""; GRN=""; CYA=""; RST=""
else
  DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYA=$'\033[36m'; RST=$'\033[0m'
fi

input="$(cat)"

# Single-pass parse: one jq for every field (keeps refresh overhead low).
# NB: join on \x1f (unit separator), not tabs — bash `read` collapses adjacent
# whitespace delimiters, which would shift fields whenever one is empty.
vals="$(printf '%s' "$input" | jq -r '
  [ (.model.display_name // ""), (.effort.level // ""),
    (.context_window.used_percentage // ""), (.exceeds_200k_tokens // false | tostring),
    (.cost.total_cost_usd // ""),
    (.rate_limits.five_hour.used_percentage // ""), (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""), (.rate_limits.seven_day.resets_at // ""),
    (.agent.name // ""), (.output_style.name // "") ]
  | map(tostring) | join("")' 2>/dev/null)" || vals=""
IFS=$'\x1f' read -r model effort ctx_pct over200k cost five_pct five_reset seven_pct seven_reset agent style <<< "$vals"
model="${model:-?}"

# round a possibly-float percentage to an int; empty stays empty
round() { [[ -z "${1:-}" ]] && return 0; printf '%.0f' "$1" 2>/dev/null || printf '%s' "$1"; }
five_i="$(round "$five_pct")"; seven_i="$(round "$seven_pct")"; ctx_i="$(round "$ctx_pct")"

# color by 5h usage severity
five_color="$GRN"
if [[ -n "$five_i" ]]; then
  if   (( five_i >= CRIT_PCT )); then five_color="$RED"
  elif (( five_i >= WARN_PCT )); then five_color="$YEL"; fi
fi

# One clock read for the whole script — reused by the reset hint, the state
# file's updated_at, and the sweep schedule. $EPOCHSECONDS is a bash-5 builtin
# (no fork); bash 3.2, still the macOS system bash, falls back to `date`.
NOW="${EPOCHSECONDS:-$(date +%s)}"

# minutes until 5h window resets (epoch seconds -> relative)
reset_hint=""
if [[ -n "$five_reset" && "$five_reset" =~ ^[0-9]+$ ]]; then
  mins=$(( (five_reset - NOW) / 60 ))
  (( mins < 0 )) && mins=0
  if (( mins >= 60 )); then reset_hint="${DIM}(~$((mins/60))h$((mins%60))m)${RST}"; else reset_hint="${DIM}(~${mins}m)${RST}"; fi
fi

# ---- STATE-ONLY mode (CC_STATUSLINE_STATE_ONLY=1): write the state file the
# guards read, render nothing. Used by statusline-wrap.sh to keep a user's own
# statusline while still powering the usage-budget bands. ----
if [[ "${CC_STATUSLINE_STATE_ONLY:-0}" != "1" ]]; then

# ---- build the segments ----
seg=()
seg+=("${CYA}${model}${RST}")
[[ -n "$agent"  ]] && seg+=("${DIM}⟩${RST}${agent}")
[[ -n "$effort" ]] && seg+=("${DIM}e:${RST}${effort}")

if [[ -n "$ctx_i" ]]; then
  ctx_lbl="ctx ${ctx_i}%"; [[ "$over200k" == "true" ]] && ctx_lbl="ctx ${ctx_i}%${RED}!${RST}"
  seg+=("${ctx_lbl}")
fi

if [[ -n "$five_i" ]]; then
  seg+=("${five_color}5h ${five_i}%${RST}${reset_hint}")
else
  seg+=("${DIM}5h n/a${RST}")   # rate_limits absent (e.g. non-subscription / API / first response pending)
fi
[[ -n "$seven_i" ]] && seg+=("${DIM}7d ${seven_i}%${RST}")

if [[ -n "$cost" ]]; then
  cost_fmt="$(printf '$%.2f' "$cost" 2>/dev/null || printf '$%s' "$cost")"
  seg+=("${DIM}${cost_fmt}${RST}")
fi
[[ -n "$style" && "$style" != "default" ]] && seg+=("${DIM}[$style]${RST}")
# /cost-control off marker — guards are no-oping; make that visible at a glance
DISABLE_FLAG="${CC_DISABLE_FLAG:-${CC_ROOT:-$HOME/.claude/cost-control}/.disabled}"
[[ -f "$DISABLE_FLAG" ]] && seg+=("${YEL}[cc-off]${RST}")

# join with a dim separator
out=""; sep="${DIM} · ${RST}"
for s in "${seg[@]}"; do out="${out:+$out$sep}$s"; done
printf '%s' "$out"

fi  # end of render (skipped in state-only mode)

# ---- persist state for the guardrail hook (best-effort, never fail the line) ----
# NOTE (fixed 2026-09-08): each value MUST wrap its whole pipeline in parens
# before `// null`. Written as `$fp|select(.!="")|tonumber? // null`, an empty
# $fp makes `select` yield NOTHING, the pipeline is already empty when `//` is
# reached, and jq then emits ZERO results for the entire object — a 0-byte state
# file, losing context_pct and model too. That turned routine now that v2.1.266
# documents "Claude Code drops a window once its resets_at time passes", so an
# absent five_hour is expected, not just a non-subscriber case.
#
# TEMP FILES LIVE IN A CACHE DIR, NOT NEXT TO THE STATE FILE (fixed 2026-09-10).
# The write is a write-to-temp + atomic rename. If the statusline process is
# killed between those two steps the temp is stranded, and nothing ever reaped
# it — 449 `.usage-state.json.XXXX` orphans had piled up in ~/.claude/ over ~8
# weeks. Claude Code re-runs this every `statusLine.refreshInterval` seconds and
# kills a slow one, and under statusline-wrap.sh's STATE_ONLY pass this block is
# essentially the whole script, so the kill lands inside that window often.
#
# Three layers, cheapest first:
#   1. temps go to $CC_USAGE_TMP_DIR — a cache dir UNDER the state file's own
#      directory, so it is the same filesystem and `mv` stays an atomic rename,
#      and so any future orphan pollutes a scratch dir instead of ~/.claude/;
#   2. a trap reaps the temp on normal exit and on catchable signals;
#   3. an hourly sweep prunes temps older than $CC_USAGE_TMP_TTL_MIN — the only
#      layer that covers SIGKILL, which no trap can catch. It also sweeps LEGACY
#      orphans beside the state file, so an existing pile drains itself.
# All of it is best-effort: any failure falls back to the previous behavior
# rather than costing a state write, because a missing state file disarms the
# guards (see "Fail-open" in CLAUDE.md).
STATE_DIR="${STATE_FILE%/*}"; [[ "$STATE_DIR" == "$STATE_FILE" ]] && STATE_DIR="."
STATE_BASE="${STATE_FILE##*/}"
TMP_DIR="${CC_USAGE_TMP_DIR:-$STATE_DIR/cache/cost-control}"
TMP_TTL_MIN="${CC_USAGE_TMP_TTL_MIN:-60}"      # reap orphaned temps older than this
SWEEP_EVERY_MIN="${CC_USAGE_SWEEP_EVERY_MIN:-60}"  # how often the sweep may run

cc_tmp=""
cc_reap_tmp() { [[ -n "$cc_tmp" ]] && rm -f "$cc_tmp" 2>/dev/null; return 0; }
trap cc_reap_tmp EXIT HUP INT TERM

{
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  mkdir -p "$TMP_DIR" 2>/dev/null || TMP_DIR="$STATE_DIR"
  tmp="$(mktemp "${TMP_DIR}/${STATE_BASE}.XXXX" 2>/dev/null)" || tmp=""
  cc_tmp="$tmp"
  if [[ -n "$tmp" ]]; then
    jq -n \
      --arg fp "${five_i:-}" --arg fr "${five_reset:-}" \
      --arg sp "${seven_i:-}" --arg ctx "${ctx_i:-}" \
      --arg model "${model:-}" --arg updated "$NOW" \
      '{five_hour_pct: (($fp|select(.!="")|tonumber?) // null),
        five_hour_resets_at: (($fr|select(.!="")|tonumber?) // null),
        seven_day_pct: (($sp|select(.!="")|tonumber?) // null),
        context_pct: (($ctx|select(.!="")|tonumber?) // null),
        model: $model, updated_at: ($updated|tonumber)}' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    cc_tmp=""   # renamed or removed either way; nothing left for the trap to reap
  fi
} || true

# ---- hourly sweep of orphaned temps (the SIGKILL backstop) ----
# The schedule lives in the STAMP FILE'S NAME (.sweep-after-<epoch>), not its
# mtime, so the common path is a bash glob and integer compare — ZERO forks.
# Checking an mtime instead would mean a `find`/`stat` fork on every render, and
# this runs every `statusLine.refreshInterval` seconds in every open session.
# `-mmin +N` spares a temp a CONCURRENT statusline (another session, same $HOME)
# is writing right now.
{
  due=0
  stamps=("$TMP_DIR"/.sweep-after-*)
  if [[ ! -e "${stamps[0]:-}" ]]; then   # :- guards set -u if nullglob is ever on
    due=1                                   # never swept here
  else
    for st in "${stamps[@]}"; do
      at="${st##*/.sweep-after-}"
      [[ "$at" =~ ^[0-9]+$ ]] && (( NOW >= at )) && due=1
      [[ "$at" =~ ^[0-9]+$ ]] || rm -f "$st" 2>/dev/null   # garbage name: reset
    done
  fi
  if (( due )); then
    rm -f "$TMP_DIR"/.sweep-after-* 2>/dev/null
    : > "$TMP_DIR/.sweep-after-$(( NOW + SWEEP_EVERY_MIN * 60 ))" 2>/dev/null || true
    find "$TMP_DIR" -maxdepth 1 -type f -name "${STATE_BASE}.????" -mmin +"$TMP_TTL_MIN" -delete 2>/dev/null || true
    # legacy location: temps this script wrote beside the state file before the
    # cache dir existed. The 4-char glob cannot match "$STATE_FILE" itself.
    [[ "$TMP_DIR" != "$STATE_DIR" ]] &&
      find "$STATE_DIR" -maxdepth 1 -type f -name "${STATE_BASE}.????" -mmin +"$TMP_TTL_MIN" -delete 2>/dev/null || true
  fi
} || true
