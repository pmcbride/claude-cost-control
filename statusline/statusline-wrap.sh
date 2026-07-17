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

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG="${1:-}"
input="$(cat)"

# 1) state for the guards (never break the display if this fails)
printf '%s' "$input" | CC_STATUSLINE_STATE_ONLY=1 "$DIR/usage-statusline.sh" >/dev/null 2>&1 || true

# 2) your display
if [[ -n "$ORIG" ]]; then
  printf '%s' "$input" | bash -c "$ORIG"
else
  printf '%s' "$input" | "$DIR/usage-statusline.sh"
fi
