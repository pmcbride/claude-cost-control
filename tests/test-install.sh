#!/usr/bin/env bash
# test-install.sh — end-to-end install into a sandbox CLAUDE_CONFIG_DIR.
# Proves: files land where the settings expect them, an existing user config
# survives the merge, and running install twice is a no-op (idempotent).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"
export CC_INSTALL_NO_SELFTEST=1   # prevent install.sh -> run-all.sh -> this test recursion
mkdir -p "$CLAUDE_CONFIG_DIR"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n    %s\n' "$1" "${2:-}"; }

# pre-existing user config that must survive
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{"model":"opus","statusLine":{"type":"command","command":"~/my-fancy-statusline.sh --compact"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/my-notify.sh"}]}]},"env":{"MY_VAR":"keepme"}}
EOF

# pre-existing in-bundle copy that must be REPLACED WHOLESALE (anti-rot): the
# install ships skills/agents/output-styles inside the bundle, always replacing
# whatever was there so in-bundle copies can never drift from SRC.
mkdir -p "$CLAUDE_CONFIG_DIR/cost-control/skills/cost-control"
echo "stale legacy copy" > "$CLAUDE_CONFIG_DIR/cost-control/skills/cost-control/SKILL.md"

echo "== sandboxed install =="
if "$ROOT/install.sh" > "$TMP/install.log" 2>&1; then
  ok "install.sh exits 0"
else
  bad "install.sh exits 0" "$(tail -5 "$TMP/install.log")"
fi

S="$CLAUDE_CONFIG_DIR/settings.json"
[[ -x "$CLAUDE_CONFIG_DIR/cost-control/hooks/guard-subagent-model.sh" ]] \
  && ok "hooks installed + executable" || bad "hooks installed" "$(ls "$CLAUDE_CONFIG_DIR/cost-control/hooks" 2>/dev/null)"
[[ -f "$CLAUDE_CONFIG_DIR/output-styles/terse.md" && -f "$CLAUDE_CONFIG_DIR/agents/explore.md" ]] \
  && ok "output-style + agents installed" || bad "style/agents installed" ""
jq -e '.model=="opus" and .env.MY_VAR=="keepme" and .hooks.Stop[0].hooks[0].command=="~/my-notify.sh"' "$S" >/dev/null \
  && ok "pre-existing user config survived the merge" || bad "user config survived" "$(jq -c . "$S")"
jq -e '.hooks.PreToolUse | map(.matcher) | index("Agent|Task") != null' "$S" >/dev/null \
  && ok "spawn guard registered on PreToolUse Agent|Task" || bad "spawn guard registered" "$(jq -c '.hooks.PreToolUse' "$S")"
jq -e '.hooks | has("TaskCreated") | not' "$S" >/dev/null \
  && ok "no TaskCreated registration (task-list event)" || bad "no TaskCreated" "$(jq -c '.hooks|keys' "$S")"
grep -qF 'cost-control-discipline' "$CLAUDE_CONFIG_DIR/CLAUDE.md" \
  && ok "CLAUDE.md block appended with marker" || bad "CLAUDE.md appended" ""
[[ -f "$CLAUDE_CONFIG_DIR/skills/cost-control/SKILL.md" && -x "$CLAUDE_CONFIG_DIR/cost-control/cost-control.sh" ]] \
  && ok "/cost-control skill + toggle script installed" || bad "toggle installed" "$(ls "$CLAUDE_CONFIG_DIR/skills" "$CLAUDE_CONFIG_DIR/cost-control" 2>/dev/null | head -8)"
SL_CMD="$(jq -r '.statusLine.command' "$S")"
[[ "$SL_CMD" == *statusline-wrap.sh* && "$SL_CMD" == *my-fancy-statusline.sh* ]] \
  && ok "pre-existing custom statusline PRESERVED via statusline-wrap" || bad "statusline preserved" "$SL_CMD"

# The cost-control-verify skill patches these AT THE INSTALLED PATH. If install
# stops shipping them, that skill silently edits files that don't exist.
VERIFY_TARGETS_OK=1
for doc in README.md ADR-claude-code-cost-control.md CLAUDE.snippet.md \
           session-topology-and-controls.md dashboard/README.md; do
  [[ -f "$CLAUDE_CONFIG_DIR/cost-control/$doc" ]] || { VERIFY_TARGETS_OK=0; MISSING_DOC="$doc"; }
done
[[ $VERIFY_TARGETS_OK -eq 1 ]] \
  && ok "verify-skill doc targets installed (ADR/README/snippet/topology/dashboard)" \
  || bad "verify-skill doc targets installed" "missing: ${MISSING_DOC:-?}"

[[ -d "$CLAUDE_CONFIG_DIR/cost-control/skills" && -d "$CLAUDE_CONFIG_DIR/cost-control/agents" && -d "$CLAUDE_CONFIG_DIR/cost-control/output-styles" ]] \
  && ok "source dirs shipped in the bundle (installed tree is a valid install SRC)" \
  || bad "source dirs shipped in bundle" "$(ls "$CLAUDE_CONFIG_DIR/cost-control" 2>/dev/null)"
if grep -q "stale legacy copy" "$CLAUDE_CONFIG_DIR/cost-control/skills/cost-control/SKILL.md" 2>/dev/null; then
  bad "stale in-bundle copy replaced wholesale" "planted stale content survived the install"
else
  ok "stale in-bundle copy replaced wholesale (no rot)"
fi

cp "$S" "$TMP/after1.json"
"$ROOT/install.sh" > "$TMP/install2.log" 2>&1 || true
diff <(jq -S . "$TMP/after1.json") <(jq -S . "$S") >/dev/null \
  && ok "second install run is a settings no-op (idempotent)" || bad "idempotent reinstall" "$(diff <(jq -S . "$TMP/after1.json") <(jq -S . "$S") | head -5)"
[[ "$(grep -cF 'cost-control-discipline' "$CLAUDE_CONFIG_DIR/CLAUDE.md")" == "2" ]] \
  && ok "CLAUDE.md not duplicated on reinstall" || bad "CLAUDE.md not duplicated" "$(grep -cF 'cost-control-discipline' "$CLAUDE_CONFIG_DIR/CLAUDE.md") markers"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
