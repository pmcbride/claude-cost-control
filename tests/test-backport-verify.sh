#!/usr/bin/env bash
# test-backport-verify.sh — scripts/backport-verify.sh in isolation: a fake
# origin + repo checkout (never the real one), CC_BACKPORT_NO_PUSH=1 so it
# never touches a real remote or shells out to `gh`. Proves: it diffs only
# the verify-patchable files, opens a worktree/branch (not the main
# checkout), commits exactly the changed files, is idempotent on rerun, and
# no-ops cleanly when the repo checkout or the drift is missing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/backport-verify.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n    %s\n' "$1" "${2:-}"; }

# --- fake origin + repo checkout (a minimal but real git repo) ---
ORIGIN="$TMP/origin.git"; REPO="$TMP/repo"
git init --bare -q "$ORIGIN"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
mkdir -p "$REPO/manifest" "$REPO/tests" "$REPO/skills/cost-control-verify"
echo "# fake Makefile" > "$REPO/Makefile"
echo "unchanged readme" > "$REPO/README.md"
echo '{"claims":"v1"}' > "$REPO/manifest/claims.json"
printf '# changelog\n\n## old entry\n' > "$REPO/manifest/CHANGELOG.md"
echo "unchanged skill" > "$REPO/skills/cost-control-verify/SKILL.md"
cat > "$REPO/tests/run-all.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REPO/tests/run-all.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
git -C "$REPO" branch -M main
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q -u origin main

# --- fake installed tree: claims.json + CHANGELOG.md changed, README.md not ---
INSTALL="$TMP/install"
mkdir -p "$INSTALL/manifest" "$INSTALL/skills/cost-control-verify"
echo "unchanged readme" > "$INSTALL/README.md"
echo '{"claims":"v2-patched-by-verify"}' > "$INSTALL/manifest/claims.json"
printf '# changelog\n\n## new entry v9.9.9\n' > "$INSTALL/manifest/CHANGELOG.md"
echo "unchanged skill" > "$INSTALL/skills/cost-control-verify/SKILL.md"

run() { CC_ROOT="$INSTALL" CC_REPO_DIR="$REPO" CC_BACKPORT_NO_PUSH=1 CC_BACKPORT_REMOTE=origin \
        bash "$SCRIPT" "$@"; }

echo "== missing repo checkout: clean no-op =="
out="$(CC_ROOT="$INSTALL" CC_REPO_DIR="$TMP/does-not-exist" CC_BACKPORT_NO_PUSH=1 bash "$SCRIPT" 1.2.3 2>&1)"
echo "$out" | grep -q '^BACKPORT_SKIPPED=repo checkout not found' \
  && ok "no-ops with a clear reason when CC_REPO_DIR is missing" || bad "missing-repo no-op" "$out"

echo
echo "== no drift: clean no-op =="
INSTALL_NODRIFT="$TMP/install-nodrift"
mkdir -p "$INSTALL_NODRIFT/manifest"
cp "$REPO/README.md" "$INSTALL_NODRIFT/"
cp "$REPO/manifest/claims.json" "$INSTALL_NODRIFT/manifest/"
cp "$REPO/manifest/CHANGELOG.md" "$INSTALL_NODRIFT/manifest/"
out="$(CC_ROOT="$INSTALL_NODRIFT" CC_REPO_DIR="$REPO" CC_BACKPORT_NO_PUSH=1 bash "$SCRIPT" 1.2.3 2>&1)"
echo "$out" | grep -q '^BACKPORT_SKIPPED=no drift' \
  && ok "no-ops cleanly when installed tree matches repo main" || bad "no-drift no-op" "$out"
[[ ! -d "$REPO/.claude/worktrees/docs-verify-v1.2.3" ]] \
  && ok "no worktree left behind for the no-drift case" || bad "no worktree for no-drift" ""

echo
echo "== real drift: opens worktree, copies only changed files, commits =="
out="$(run 9.9.9 "test summary" 2>&1)"
echo "$out" | grep -q '^BACKPORT_BRANCH=docs/verify-v9.9.9$' \
  && ok "branch docs/verify-v9.9.9 created" || bad "branch created" "$out"
echo "$out" | grep -q 'CC_BACKPORT_NO_PUSH=1' \
  && ok "stops before push/gh with CC_BACKPORT_NO_PUSH=1" || bad "stops before push" "$out"

WT="$REPO/.claude/worktrees/docs-verify-v9.9.9"
[[ -d "$WT" ]] && ok "worktree directory exists" || bad "worktree exists" "$(ls "$REPO/.claude/worktrees" 2>/dev/null)"
[[ ! -d "$REPO/.git/worktrees" ]] || git -C "$REPO" status --short | grep -q . \
  && true # main checkout may show untracked worktrees/ dir metadata only; not asserted further

diff -q "$INSTALL/manifest/claims.json" "$WT/manifest/claims.json" >/dev/null 2>&1 \
  && ok "manifest/claims.json copied verbatim from the installed tree" \
  || bad "claims.json copied" "$(cat "$WT/manifest/claims.json" 2>/dev/null)"
diff -q "$INSTALL/manifest/CHANGELOG.md" "$WT/manifest/CHANGELOG.md" >/dev/null 2>&1 \
  && ok "manifest/CHANGELOG.md copied verbatim from the installed tree" \
  || bad "CHANGELOG.md copied" ""
grep -q "unchanged readme" "$WT/README.md" 2>/dev/null \
  && ok "README.md (unchanged) left at the repo's original content" || bad "README.md untouched" "$(cat "$WT/README.md" 2>/dev/null)"

git -C "$WT" show --stat HEAD 2>/dev/null | grep -q 'manifest/claims.json' \
  && ok "commit touches manifest/claims.json" || bad "commit touches claims.json" "$(git -C "$WT" show --stat HEAD 2>/dev/null)"
git -C "$WT" show --stat HEAD 2>/dev/null | grep -q 'README.md' \
  && bad "commit wrongly includes unchanged README.md" "$(git -C "$WT" show --stat HEAD 2>/dev/null)" \
  || ok "commit does NOT include the unchanged README.md"
git -C "$WT" log -1 --format=%s 2>/dev/null | grep -q 'docs(verify): test summary' \
  && ok "commit message matches the requested summary" || bad "commit message" "$(git -C "$WT" log -1 --format=%s 2>/dev/null)"

git -C "$REPO" rev-parse --verify main >/dev/null 2>&1
[[ "$(git -C "$REPO" rev-parse main)" != "$(git -C "$WT" rev-parse HEAD)" ]] \
  && ok "repo's main checkout was never touched (worktree only)" || bad "main checkout untouched" ""

echo
echo "== rerun for the same version: idempotent no-op =="
out2="$(run 9.9.9 "test summary" 2>&1)"
echo "$out2" | grep -q '^BACKPORT_SKIPPED=branch docs/verify-v9.9.9 already exists' \
  && ok "rerun is a no-op (branch already exists)" || bad "idempotent rerun" "$out2"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
