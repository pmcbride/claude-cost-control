#!/usr/bin/env bash
# backport-verify.sh — port a cost-control-verify run from the INSTALLED tree
# ($CC_ROOT) back into the repo (source of truth) as a PR, so `make sync`'s
# rsync --delete of manifest/ doesn't silently revert the verify the next time
# someone runs it. See CLAUDE.md "manifest drift" and README "How the verify
# skill's writes get back into the repo".
#
# Called by the background verify session (dispatched from
# hooks/version-check.sh) AFTER a successful run: safe updates applied,
# tests green in the installed tree. Never merges — opens a PR for review.
#
# Usage:
#   scripts/backport-verify.sh <version> [summary-line]
#
# Env:
#   CC_ROOT               installed tree (default ~/.claude/cost-control)
#   CC_REPO_DIR           repo checkout (default
#                         ~/Claude/Projects/Agents/claude-cost-control)
#   CC_BACKPORT_TRAILER   extra trailer line(s) appended to the commit message,
#                         e.g. "Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"
#   CC_BACKPORT_NO_PUSH   1 = stop after the local commit; skip push + gh pr
#                         create (used by the test suite; no network/gh needed)
#   CC_BACKPORT_REMOTE    remote name to push to (default origin)
#
# Exit codes: 0 = done (backported, or nothing to backport, or repo missing —
# all non-fatal to the caller). Prints `PR_URL=<url>` on stdout when a PR was
# opened, `BACKPORT_SKIPPED=<reason>` otherwise, and `BACKPORT_BRANCH=<name>`
# whenever a branch/commit was made (including in no-push test mode).
set -uo pipefail

VERSION="${1:-}"
SUMMARY="${2:-backport v${VERSION} drift check from the installed tree}"
if [[ -z "$VERSION" ]]; then
  echo "usage: backport-verify.sh <version> [summary-line]" >&2
  exit 1
fi

CC_ROOT="${CC_ROOT:-$HOME/.claude/cost-control}"
REPO_DIR="${CC_REPO_DIR:-$HOME/Claude/Projects/Agents/claude-cost-control}"
REMOTE="${CC_BACKPORT_REMOTE:-origin}"
NO_PUSH="${CC_BACKPORT_NO_PUSH:-0}"
TRAILER="${CC_BACKPORT_TRAILER:-}"

# --- 1. repo checkout must exist and look like this repo ---
if [[ ! -d "$REPO_DIR/.git" ]] || [[ ! -f "$REPO_DIR/Makefile" ]]; then
  echo "BACKPORT_SKIPPED=repo checkout not found at CC_REPO_DIR=$REPO_DIR"
  exit 0
fi
[[ -d "$CC_ROOT/manifest" ]] || { echo "BACKPORT_SKIPPED=no installed tree at CC_ROOT=$CC_ROOT"; exit 0; }

# --- 2. candidate files the verify skill is allowed to patch ---
# (Safe vs HITL — the policy, skills/cost-control-verify/SKILL.md.) Anything
# outside this set is never auto-backported.
CANDIDATES=(
  manifest/claims.json
  manifest/CHANGELOG.md
  README.md
  ADR-claude-code-cost-control.md
  CLAUDE.snippet.md
  HANDOFF-claude-code.md
  session-topology-and-controls.md
  settings.snippet.json
  managed-settings.snippet.json
  REVIEW-2026-07-16-fable.md
  _REVIEW-INDEX.md
  dashboard/README.md
)
while IFS= read -r f; do
  CANDIDATES+=("skills/${f#skills/}")
done < <(cd "$CC_ROOT" 2>/dev/null && find skills -name SKILL.md 2>/dev/null)

# --- 3. diff against the repo's current main (not the worktree yet) ---
CHANGED=()
for f in "${CANDIDATES[@]}"; do
  [[ -f "$CC_ROOT/$f" ]] || continue
  if [[ ! -f "$REPO_DIR/$f" ]] || ! cmp -s "$CC_ROOT/$f" "$REPO_DIR/$f"; then
    CHANGED+=("$f")
  fi
done

if [[ ${#CHANGED[@]} -eq 0 ]]; then
  echo "BACKPORT_SKIPPED=no drift between installed tree and repo main for v${VERSION}"
  exit 0
fi

BRANCH="docs/verify-v${VERSION}"
WORKTREE_DIR="$REPO_DIR/.claude/worktrees/docs-verify-v${VERSION}"

# --- 4. already backported / in flight? ---
if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH" \
   || git -C "$REPO_DIR" ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  echo "BACKPORT_SKIPPED=branch $BRANCH already exists locally or on $REMOTE"
  exit 0
fi
[[ -d "$WORKTREE_DIR" ]] && { echo "BACKPORT_SKIPPED=worktree $WORKTREE_DIR already exists"; exit 0; }

git -C "$REPO_DIR" fetch "$REMOTE" main --quiet 2>/dev/null || true
git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WORKTREE_DIR" "$REMOTE/main" --quiet 2>/dev/null \
  || git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WORKTREE_DIR" main --quiet \
  || { echo "BACKPORT_SKIPPED=git worktree add failed"; exit 0; }

# --- 5. copy exactly the changed files into the worktree ---
for f in "${CHANGED[@]}"; do
  mkdir -p "$(dirname "$WORKTREE_DIR/$f")"
  cp "$CC_ROOT/$f" "$WORKTREE_DIR/$f"
done

# --- 6. tests must pass in the worktree before committing ---
if ! ( cd "$WORKTREE_DIR" && ./tests/run-all.sh --quick >/tmp/backport-verify-tests-v${VERSION}.log 2>&1 ); then
  echo "BACKPORT_SKIPPED=tests failed in worktree, see /tmp/backport-verify-tests-v${VERSION}.log"
  git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  git -C "$REPO_DIR" branch -D "$BRANCH" 2>/dev/null || true
  exit 0
fi

# --- 7. commit exactly the changed files ---
git -C "$WORKTREE_DIR" add -- "${CHANGED[@]}"
if git -C "$WORKTREE_DIR" diff --cached --quiet; then
  echo "BACKPORT_SKIPPED=no staged diff after copy (files were byte-identical to worktree base)"
  git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  git -C "$REPO_DIR" branch -D "$BRANCH" 2>/dev/null || true
  exit 0
fi

MSG="docs(verify): ${SUMMARY}"
if [[ -n "$TRAILER" ]]; then
  git -C "$WORKTREE_DIR" commit -q -m "$MSG" -m "$TRAILER"
else
  git -C "$WORKTREE_DIR" commit -q -m "$MSG"
fi
echo "BACKPORT_BRANCH=$BRANCH"

if [[ "$NO_PUSH" == "1" ]]; then
  echo "BACKPORT_SKIPPED=CC_BACKPORT_NO_PUSH=1, stopped after local commit at $WORKTREE_DIR"
  exit 0
fi

# --- 8. push + open PR (never merge) ---
git -C "$WORKTREE_DIR" push -u "$REMOTE" "$BRANCH" --quiet || {
  echo "BACKPORT_SKIPPED=push failed for $BRANCH"
  exit 0
}

PR_BODY="Backports the cost-control-verify run for v${VERSION} from the installed
tree (~/.claude/cost-control) into the repo, so \`make sync\`'s
\`rsync --delete\` of manifest/ doesn't revert it.

Files: $(printf '%s, ' "${CHANGED[@]}" | sed 's/, $//')

Opened automatically by scripts/backport-verify.sh from the background
verify session. Never auto-merged — please review before merging."

PR_URL="$(cd "$WORKTREE_DIR" && gh pr create --title "$MSG" --body "$PR_BODY" --head "$BRANCH" --base main 2>/dev/null)"
if [[ -n "$PR_URL" ]]; then
  echo "PR_URL=$PR_URL"
else
  echo "BACKPORT_SKIPPED=gh pr create failed or gh unavailable; branch $BRANCH is pushed, open the PR manually"
fi
exit 0
