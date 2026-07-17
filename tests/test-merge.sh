#!/usr/bin/env bash
# test-merge.sh — proves the install.sh settings merge is safe against an
# existing config: preserves user keys/hooks, is idempotent, strips '//' keys,
# and fails closed (file untouched) on invalid input.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIP="$ROOT/settings.snippet.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n    %s\n' "$1" "${2:-}"; }

MERGE='
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
        .[$e] = ( (($base.hooks[$e]//[]) + ($snip.hooks[$e])) | dedup_keep_order ) ) )'

cat > "$TMP/base.json" <<'EOF'
{
  "statusLine": {"type":"command","command":"~/my-custom-statusline.sh"},
  "outputStyle": "Explanatory",
  "model": "opus",
  "permissions": {"allow": ["Bash(npm run *)"]},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type":"command","command":"~/my-bash-audit.sh"}]},
      {"matcher": "Edit|Write", "hooks": [{"type":"command","command":"~/my-fmt.sh"}]}
    ],
    "Stop": [{"hooks": [{"type":"command","command":"~/my-notify.sh"}]}]
  },
  "env": {"MY_VAR": "keepme"}
}
EOF

echo "== settings merge =="

jq -s "$MERGE" "$TMP/base.json" "$SNIP" > "$TMP/m1.json" 2>"$TMP/err" \
  && ok "merge succeeds against a populated config" || { bad "merge succeeds" "$(cat "$TMP/err")"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

jq -e '.model=="opus" and .permissions.allow[0]=="Bash(npm run *)" and .env.MY_VAR=="keepme"' "$TMP/m1.json" >/dev/null \
  && ok "preserves unrelated user keys (model, permissions, env)" || bad "preserve user keys" "$(jq -c '{model,permissions,env}' "$TMP/m1.json")"

jq -e '.hooks.Stop[0].hooks[0].command=="~/my-notify.sh"' "$TMP/m1.json" >/dev/null \
  && ok "preserves user hooks on events the snippet doesn't touch" || bad "preserve Stop hook" ""

jq -e '[.hooks.PreToolUse[].matcher // ""] | index("Bash") != null and index("Edit|Write") != null' "$TMP/m1.json" >/dev/null \
  && ok "preserves user PreToolUse hook groups alongside the bundle's" || bad "preserve user PreToolUse" "$(jq -c '.hooks.PreToolUse' "$TMP/m1.json")"

jq -e '.hooks.PreToolUse[0].matcher=="Bash" and .hooks.PreToolUse[1].matcher=="Edit|Write"' "$TMP/m1.json" >/dev/null \
  && ok "keeps the user's existing hook-group ORDER (base first, first-seen)" || bad "hook order preserved" "$(jq -c '[.hooks.PreToolUse[].matcher]' "$TMP/m1.json")"

jq -e '.statusLine.command | test("usage-statusline")' "$TMP/m1.json" >/dev/null \
  && ok "replaces statusLine with the bundle's (documented + backed up by install.sh)" || bad "statusLine replaced" ""

jq -e '[paths | .[-1]? | strings | select(startswith("//"))] | length == 0' "$TMP/m1.json" >/dev/null \
  && ok "strips every '//'-comment key (user settings validate strictly)" || bad "// keys stripped" "$(jq -c 'paths|.[-1]?|strings|select(startswith("//"))' "$TMP/m1.json" | head -3)"

jq -s "$MERGE" "$TMP/m1.json" "$SNIP" > "$TMP/m2.json" 2>/dev/null
diff <(jq -S . "$TMP/m1.json") <(jq -S . "$TMP/m2.json") >/dev/null \
  && ok "idempotent: re-running the merge changes nothing" || bad "idempotency" "$(diff <(jq -S . "$TMP/m1.json") <(jq -S . "$TMP/m2.json") | head -5)"

jq -e '.hooks | has("TaskCreated") or has("TaskCompleted") | not' "$TMP/m1.json" >/dev/null \
  && ok "does not register guards on TaskCreated/TaskCompleted (task-list events)" || bad "no TaskCreated registration" "$(jq -c '.hooks|keys' "$TMP/m1.json")"

printf 'not json' > "$TMP/badbase.json"
if jq -s "$MERGE" "$TMP/badbase.json" "$SNIP" >/dev/null 2>&1; then
  bad "invalid existing settings must abort the merge" "merge unexpectedly succeeded"
else
  ok "invalid existing settings -> merge fails -> install.sh leaves the file untouched"
fi

jq empty "$SNIP" 2>/dev/null && ok "settings.snippet.json is valid JSON" || bad "snippet valid JSON" ""

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
