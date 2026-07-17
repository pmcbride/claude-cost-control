#!/usr/bin/env bash
# install.sh — one-command installer for the Claude Code cost-control bundle.
#
# Idempotent and conservative: it BACKS UP anything it touches, deep-MERGES the
# settings snippet into your existing ~/.claude/settings.json, validates the
# result, and aborts (leaving your file untouched) on any failure. Re-running it
# is safe and produces the identical result.
#
# WHAT THE MERGE DOES AND DOESN'T PRESERVE (honest):
#   * PRESERVED: every key of yours the snippet doesn't set (model, permissions,
#     env vars, hooks on other events, your hook groups on shared events — those
#     are concatenated, first-seen order kept, exact duplicates dropped).
#   * REPLACED: `statusLine` and `outputStyle` — the bundle sets its own. Your
#     previous values are in the timestamped backup.
#   * All "//"-comment keys are stripped from the snippet before merging (user
#     settings files are validated strictly; stray keys can invalidate the file).
#
#   ./install.sh                 # full install (files + settings merge + CLAUDE.md)
#   ./install.sh --dry-run       # show what it WOULD do, change nothing
#   ./install.sh --no-settings   # install files only; print the settings to merge yourself
#   ./install.sh --managed       # ALSO print the sudo command to place the managed-settings hard gate
#   ./install.sh --force         # skip the backup of an existing ~/.claude/cost-control dir
#
# After installing: run ./tests/run-all.sh (offline, ~5s) to prove the hooks
# behave (transparent below thresholds, gating above, fail-open on breakage)
# BEFORE restarting Claude Code.
#
# Requires: bash, jq. macOS and Linux.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/cost-control"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

DRY=0; NO_SETTINGS=0; MANAGED=0; FORCE=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1;; --no-settings) NO_SETTINGS=1;; --managed) MANAGED=1;; --force) FORCE=1;;
  -h|--help) sed -n '2,28p' "$0"; exit 0;;
  *) echo "unknown flag: $a" >&2; exit 2;;
esac; done

say() { printf '  %s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }
run() { if [[ $DRY -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)."; exit 1; }

# ---- OS / managed-settings path ----
case "$(uname -s)" in
  Darwin) MANAGED_PATH="/Library/Application Support/ClaudeCode/managed-settings.json";;
  Linux)  MANAGED_PATH="/etc/claude-code/managed-settings.json";;
  *)      MANAGED_PATH="(see managed-settings.snippet.json for your OS)";;
esac

hdr "1. Copy bundle files -> $DEST"
if [[ -d "$DEST" && $FORCE -eq 0 && $DRY -eq 0 ]]; then
  run "cp -a '$DEST' '$DEST.bak-$STAMP'"; say "backed up existing -> $DEST.bak-$STAMP"
fi
run "mkdir -p '$DEST' '$CLAUDE_DIR/output-styles' '$CLAUDE_DIR/agents' '$CLAUDE_DIR/skills'"
run "cp -a '$SRC/statusline' '$SRC/hooks' '$SRC/manifest' '$DEST/'"
[[ -d "$SRC/tests" ]] && run "cp -a '$SRC/tests' '$DEST/'"
run "chmod +x '$DEST/statusline/'*.sh '$DEST/hooks/'*.sh"
[[ -d "$SRC/tests" && $DRY -eq 0 ]] && chmod +x "$DEST/tests/"*.sh 2>/dev/null || true
run "cp -a '$SRC/cost-control.sh' '$DEST/'"
run "chmod +x '$DEST/cost-control.sh'"
run "cp -a '$SRC/output-styles/terse.md' '$CLAUDE_DIR/output-styles/'"
run "cp -a '$SRC/agents/'*.md '$CLAUDE_DIR/agents/'"
run "cp -a '$SRC/skills/cost-control-verify' '$SRC/skills/cost-control' '$CLAUDE_DIR/skills/'"
say "files copied (statusline, hooks, manifest, tests, toggle, terse output-style, example agents, verify + /cost-control skills)"

hdr "2. Merge settings -> $CLAUDE_DIR/settings.json"
if [[ $NO_SETTINGS -eq 1 ]]; then
  say "--no-settings: skipping. Merge $SRC/settings.snippet.json into settings.json yourself."
  say "IMPORTANT: delete every '//'-prefixed key when merging by hand — user settings"
  say "files are validated strictly and an invalid file is rejected as a whole."
else
  BASE="$CLAUDE_DIR/settings.json"
  [[ -f "$BASE" ]] || { [[ $DRY -eq 1 ]] && say "would create empty settings.json" || echo '{}' > "$BASE"; }
  # Preserve a pre-existing custom statusline: remember it, and after the merge
  # re-point statusLine at statusline-wrap.sh, which writes the guards' state
  # file (state-only mode) and then runs the original command for display.
  ORIG_SL="$(jq -r '.statusLine.command // empty' "$BASE" 2>/dev/null || true)"
  WRAP="$CLAUDE_DIR/cost-control/statusline/statusline-wrap.sh"
  KEEP_CMD=""
  case "$ORIG_SL" in
    "") : ;;                                    # no statusline yet -> bundle's
    *usage-statusline.sh*) : ;;                 # already the bundle's -> let snippet win
    *statusline-wrap.sh*) KEEP_CMD="$ORIG_SL";; # already wrapped -> keep verbatim (idempotent)
    *) KEEP_CMD="$WRAP $(printf '%q' "$ORIG_SL")";;  # custom -> wrap it
  esac
  MERGED="$(mktemp)"
  # strip //-comment keys everywhere; deep-merge (snippet wins statusLine/outputStyle);
  # concat hooks per-event, keeping FIRST-SEEN ORDER and dropping exact duplicates
  # (order-preserving dedup — unique_by would re-sort your existing hook groups).
  if ! jq -s '
    def stripc: walk(if type=="object" then with_entries(select(.key|startswith("//")|not)) else . end);
    def dedup_keep_order:
      reduce .[] as $g ({seen:[], out:[]};
        ($g|tojson) as $j
        | if (.seen|index($j)) then . else {seen:(.seen+[$j]), out:(.out+[$g])} end)
      | .out;
    (.[0] // {}) as $base | (.[1]|stripc) as $snip |
    ($base * $snip)
    | .hooks = ( reduce (($snip.hooks//{})|keys[]) as $e
        ( ($base.hooks // {}) ;
          .[$e] = ( (($base.hooks[$e]//[]) + ($snip.hooks[$e])) | dedup_keep_order ) ) )
  ' "$BASE" "$SRC/settings.snippet.json" > "$MERGED" 2>"$MERGED.err"; then
    echo "ERROR: settings merge failed; leaving your settings.json untouched. jq said:"
    sed 's/^/    /' "$MERGED.err" 2>/dev/null || true
    rm -f "$MERGED" "$MERGED.err"; exit 1
  fi
  rm -f "$MERGED.err"
  if [[ -n "$KEEP_CMD" ]]; then
    # re-point statusLine at the wrapper carrying the user's original command
    jq --arg cmd "$KEEP_CMD" '.statusLine.command = $cmd' "$MERGED" > "$MERGED.sl" \
      && mv "$MERGED.sl" "$MERGED" || rm -f "$MERGED.sl"
  fi
  if jq empty "$MERGED" 2>/dev/null; then
    if [[ $DRY -eq 1 ]]; then
      say "[dry-run] merged settings would be:"; sed 's/^/    /' "$MERGED"; rm -f "$MERGED"
    else
      cp -a "$BASE" "$BASE.bak-$STAMP"; mv "$MERGED" "$BASE"
      say "merged (backup: settings.json.bak-$STAMP)"
      if [[ -n "$KEEP_CMD" ]]; then
        say "PRESERVED your statusline: it now runs via statusline-wrap.sh, which also"
        say "  feeds the usage state the budget guard needs. Display is unchanged."
        say "  statusLine.command = $KEEP_CMD"
      else
        say "NOTE: this set statusLine to the bundle's usage statusline."
      fi
      say "NOTE: outputStyle is now 'Terse' (switch back anytime via /config; backup has your old value)."
    fi
  else
    echo "ERROR: merged settings invalid; leaving your settings.json untouched."; rm -f "$MERGED"; exit 1
  fi
fi

hdr "3. Append cost-discipline block -> $CLAUDE_DIR/CLAUDE.md"
CMD="$CLAUDE_DIR/CLAUDE.md"; MARK="<!-- cost-control-discipline -->"
if [[ -f "$CMD" ]] && grep -qF "$MARK" "$CMD" 2>/dev/null; then
  say "already present; skipping"
else
  if [[ $DRY -eq 1 ]]; then say "[dry-run] would append CLAUDE.snippet.md (guarded by marker)"
  else { printf '\n%s\n' "$MARK"; cat "$SRC/CLAUDE.snippet.md"; printf '%s\n' "$MARK"; } >> "$CMD"; say "appended"; fi
fi

hdr "4. Seed the version baseline"
if [[ $DRY -eq 1 ]]; then say "[dry-run] would run version-check.sh to write version.lock"
else CC_ROOT="$DEST" "$DEST/hooks/version-check.sh" >/dev/null 2>&1 || true
     say "version.lock: $(cat "$DEST/manifest/version.lock" 2>/dev/null || echo '(claude --version not found; will seed on first session)')"
fi

hdr "5. Offline self-test"
if [[ $DRY -eq 1 ]]; then say "[dry-run] would run tests/run-all.sh"
elif [[ "${CC_INSTALL_NO_SELFTEST:-0}" == "1" ]]; then say "skipped (CC_INSTALL_NO_SELFTEST=1)"
elif [[ -x "$DEST/tests/run-all.sh" ]]; then
  if "$DEST/tests/run-all.sh" --quick > "$DEST/tests/last-run.log" 2>&1; then
    say "PASSED (details: $DEST/tests/last-run.log)"
  else
    say "WARNING: self-test FAILED — hooks may not behave as designed on this machine."
    say "         Read $DEST/tests/last-run.log before restarting Claude Code."
  fi
else
  say "tests/ not found — skipped"
fi

hdr "6. Managed-settings hard gate (optional, needs sudo)"
if [[ $MANAGED -eq 1 ]]; then
  say "Managed settings parse tolerantly (invalid entries are stripped with a warning;"
  say "check /doctor). Decide the fable question first — see the tradeoff note inside"
  say "managed-settings.snippet.json — then:"
  say "  sudo mkdir -p \"$(dirname "$MANAGED_PATH")\" && sudo cp '$SRC/managed-settings.snippet.json' \"$MANAGED_PATH\""
else
  say "skipped (pass --managed to see the command). Target on this OS: $MANAGED_PATH"
fi

hdr "Done"
cat <<EOF
  Next:
    1) If step 5 warned, fix that first: ./tests/run-all.sh for details.
    2) Restart Claude Code (or run 'claude' fresh) so settings + hooks load.
    3) On first session you'll see a COST-CONTROL SETUP message — run the
       'cost-control-verify' skill to establish the baseline for YOUR installed
       version and run the LIVE self-test (spawn a fable subagent -> expect a
       denial AND a deny entry in ~/.claude/logs/model-guard.jsonl; confirm the
       statusline shows 5h%).
    4) Optional: 'cd dashboard && docker compose up -d' for the usage dashboard;
       run './hooks/watchdog-usage.sh' in a terminal for unattended fan-out.
  Toggle:  /cost-control off | on | status  (instant, no restart — guards no-op
           via a flag file; statusline shows [cc-off] while disabled)
  Revert:  restore settings.json.bak-$STAMP and remove $DEST.
EOF
