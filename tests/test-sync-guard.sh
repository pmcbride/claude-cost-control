#!/usr/bin/env bash
# test-sync-guard.sh — `make sync` must refuse to rsync manifest/ over an
# un-backported verify entry (the CLAUDE.md "manifest drift" safety net), and
# `make sync FORCE=1` must still let a human override it deliberately.
# Uses a sandboxed CLAUDE_DIR/INSTALL_DIR; REPO_DIR is this checkout (real
# repo layout — `make sync` needs the actual source tree to rsync from).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CLAUDE_DIR="$TMP/claude"
INSTALL_DIR="$CLAUDE_DIR/cost-control"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n    %s\n' "$1" "${2:-}"; }

mkdir -p "$INSTALL_DIR/manifest" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/skills" "$CLAUDE_DIR/output-styles"

echo "== drift present: sync must refuse =="
cat > "$INSTALL_DIR/manifest/CHANGELOG.md" <<'EOF'
# Cost-control validation changelog

## 2099-01-01 — drift check v9.9.9 → v9.9.10 (NOT IN REPO, unbackported)

Fake entry planted by test-sync-guard.sh; must never appear in the repo copy.
EOF

if make -C "$ROOT" sync CLAUDE_DIR="$CLAUDE_DIR" > "$TMP/sync.log" 2>&1; then
  bad "sync refuses on un-backported drift" "make sync exited 0; log: $(tail -5 "$TMP/sync.log")"
else
  grep -qi "REFUSING TO SYNC" "$TMP/sync.log" \
    && ok "sync refuses on un-backported drift, with a clear message" \
    || bad "sync refuses with a clear message" "$(cat "$TMP/sync.log")"
fi
[[ ! -f "$INSTALL_DIR/hooks/version-check.sh" ]] \
  && ok "refusal happened BEFORE rsync (no hooks/ copied over)" \
  || bad "refusal happened before rsync" "hooks/ was populated despite the refusal"

echo
echo "== FORCE=1: sync proceeds anyway =="
if make -C "$ROOT" sync CLAUDE_DIR="$CLAUDE_DIR" FORCE=1 > "$TMP/sync-force.log" 2>&1; then
  ok "sync FORCE=1 overrides the guard and succeeds"
else
  bad "sync FORCE=1 overrides the guard" "$(tail -10 "$TMP/sync-force.log")"
fi
grep -qi "WARNING" "$TMP/sync-force.log" \
  && ok "FORCE=1 still warns about the discarded entry" || bad "FORCE=1 warns" "$(cat "$TMP/sync-force.log")"
[[ -x "$INSTALL_DIR/hooks/version-check.sh" ]] \
  && ok "FORCE=1 actually ran the rsync (hooks/ installed)" || bad "FORCE=1 ran rsync" "$(ls "$INSTALL_DIR" 2>/dev/null)"

echo
echo "== no drift: sync proceeds normally (regression guard) =="
TMP2="$(mktemp -d)"; CLAUDE_DIR2="$TMP2/claude"; INSTALL_DIR2="$CLAUDE_DIR2/cost-control"
mkdir -p "$INSTALL_DIR2/manifest" "$CLAUDE_DIR2/agents" "$CLAUDE_DIR2/skills" "$CLAUDE_DIR2/output-styles"
cp "$ROOT/manifest/CHANGELOG.md" "$INSTALL_DIR2/manifest/CHANGELOG.md"
if make -C "$ROOT" sync CLAUDE_DIR="$CLAUDE_DIR2" > "$TMP2/sync.log" 2>&1; then
  ok "sync proceeds when installed CHANGELOG has no un-backported entry"
else
  bad "sync proceeds without drift" "$(tail -10 "$TMP2/sync.log")"
fi
rm -rf "$TMP2"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
