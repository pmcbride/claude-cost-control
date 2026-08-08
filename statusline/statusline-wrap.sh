#!/usr/bin/env bash
# statusline-wrap.sh — keep YOUR existing statusline, still power the guards.
#
# The usage-budget hook reads a state file that usage-statusline.sh writes from
# the statusline stdin JSON. If you replace the bundle's statusline with your
# own, that state goes stale and the budget bands silently disarm. This wrapper
# gives you both: it feeds stdin to the bundle's statusline in STATE-ONLY mode
# (writes the state file, renders nothing), then runs YOUR original statusline
# command for the actual display.
#
# install.sh wires this automatically when it detects a pre-existing statusLine:
#   "command": "~/.claude/cost-control/statusline/statusline-wrap.sh '<your original command>'"
#
# $1 = your original statusLine command string (run via bash -c, so args work).
# With no $1 it falls back to rendering the bundle's own statusline.
#
# [cc-off] MARKER: the bundle's own statusline renders a [cc-off] marker while
# /cost-control is off, but that render block is skipped in STATE_ONLY mode — so
# a wrapped custom statusline would never show it, and you'd have no at-a-glance
# way to tell the guards are disarmed. This wrapper therefore appends the marker
# to YOUR output itself, but ONLY while the disable flag is present. When
# cost-control is ON (the normal case) your command is streamed straight through,
# byte-for-byte unchanged — the buffering path below is never taken.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG="${1:-}"
input="$(cat)"

# 1) state for the guards (never break the display if this fails)
printf '%s' "$input" | CC_STATUSLINE_STATE_ONLY=1 "$DIR/usage-statusline.sh" >/dev/null 2>&1 || true

# 2) your display
if [[ -z "$ORIG" ]]; then
  printf '%s' "$input" | "$DIR/usage-statusline.sh"   # no custom command -> bundle's own (renders [cc-off] itself)
  exit 0
fi

# Flag resolution mirrors usage-statusline.sh / the guards exactly.
DISABLE_FLAG="${CC_DISABLE_FLAG:-${CC_ROOT:-$HOME/.claude/cost-control}/.disabled}"

if [[ ! -f "$DISABLE_FLAG" ]]; then
  printf '%s' "$input" | bash -c "$ORIG"              # guards ARMED: untouched passthrough
  exit 0
fi

# Guards DISARMED: buffer your output and append the marker.
#
# Deliberately IGNORE your command's exit status. Command substitution has
# already captured whatever it printed, and showing that is the correct
# fail-open posture — a statusline ending in a bare `git`/`grep`/`test` exits
# nonzero routinely while printing a perfectly good line. Never re-run $ORIG to
# "retry": statuslines render on every UI refresh, so a rerun would double any
# side effect your command has (file writes, network calls, rate-limited APIs)
# and would display the SECOND run's output, which can differ from the render
# that actually happened.
#
# This branch is NOT byte-identical to the armed one: command substitution
# strips trailing newlines, so a statusline ending in `echo` loses its final \n
# here. Harmless (Claude Code trims the statusline anyway) — but the header's
# "byte-for-byte" promise describes the ARMED path, not this one.
# ${out:+$out } supplies the separating space only when there IS output, so a
# command that prints nothing renders "[cc-off]", not " [cc-off]".
out="$(printf '%s' "$input" | bash -c "$ORIG")" || true
if [[ "${CC_STATUSLINE_NOCOLOR:-0}" == "1" ]]; then
  printf '%s%s' "${out:+$out }" '[cc-off]'
else
  printf '%s%s' "${out:+$out }" $'\033[33m[cc-off]\033[0m'
fi
