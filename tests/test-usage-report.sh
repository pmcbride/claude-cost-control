#!/usr/bin/env bash
# test-usage-report.sh — the usage-report skill's deterministic half.
# Proves dashboard/gate-coverage.sh joins agent-events.jsonl against
# model-guard.jsonl correctly (per-type counts, the ungated floor at 0, the
# --since window, garbage-line tolerance) and fails soft like every other
# component. The skill's LLM-driven synthesis isn't testable offline; the
# numbers it synthesizes from are.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GC="$ROOT/dashboard/gate-coverage.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n    %s\n' "$1" "${2:-}"; }

E="$TMP/agent-events.jsonl"; G="$TMP/model-guard.jsonl"
cat > "$E" <<'EOF'
{"ts":"2026-09-01T00:00:00Z","event":"SubagentStart","agent_type":"worker"}
{"ts":"2026-09-10T00:00:00Z","event":"SubagentStart","agent_type":"workflow-subagent"}
{"ts":"2026-09-10T00:00:01Z","event":"SubagentStart","agent_type":"workflow-subagent"}
{"ts":"2026-09-10T00:00:02Z","event":"SubagentStart","agent_type":"workflow-subagent"}
{"ts":"2026-09-10T00:00:03Z","event":"SubagentStart","agent_type":"worker"}
{"ts":"2026-09-10T00:00:04Z","event":"SubagentStart","agent_type":"worker"}
{"ts":"2026-09-10T00:00:05Z","event":"SubagentStop","agent_type":"worker"}
{"ts":"2026-09-10T00:00:06Z","event":"SubagentStart","agent_type":"researcher"}
{"ts":"2026-09-10T00:00:07Z","event":"SubagentStart","agent_type":""}
this line is not json
EOF
cat > "$G" <<'EOF'
{"ts":"2026-09-01T00:00:00Z","event":"PreToolUse","tool":"Agent","subagent_type":"worker","action":"deny"}
{"ts":"2026-09-10T00:00:03Z","event":"PreToolUse","tool":"Agent","subagent_type":"worker","action":"allow"}
{"ts":"2026-09-10T00:00:04Z","event":"PreToolUse","tool":"Agent","subagent_type":"worker","action":"deny"}
{"ts":"2026-09-10T00:00:06Z","event":"PreToolUse","tool":"Agent","subagent_type":"researcher","action":"allow"}
{"ts":"2026-09-10T00:00:06Z","event":"PreToolUse","tool":"Agent","subagent_type":"researcher","action":"allow"}
{garbage
EOF

run() { CC_AGENT_EVENT_LOG="$E" CC_GUARD_LOG="$G" "$GC" "$@"; }

echo "== gate-coverage.sh =="
[[ -x "$GC" ]] && ok "gate-coverage.sh is executable" || bad "gate-coverage.sh is executable" "$(ls -l "$GC" 2>&1)"

OUT="$(run --since 2026-09-05T00:00:00Z --json 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && jq -e . <<<"$OUT" >/dev/null 2>&1 \
  && ok "--json emits valid JSON despite garbage lines in both logs" || bad "--json valid" "rc=$RC out=$OUT"

jq -e '.spawns == 7 and .decisions == 4 and .deny == 1' <<<"$OUT" >/dev/null 2>&1 \
  && ok "--since window excludes rows before the cutoff (7 spawns, 4 decisions, 1 deny)" \
  || bad "window totals" "$(jq -c '{spawns,decisions,deny}' <<<"$OUT" 2>&1)"

jq -e '(.by_agent_type[] | select(.agent_type == "workflow-subagent")) | .starts == 3 and .decisions == 0 and .ungated == 3' <<<"$OUT" >/dev/null 2>&1 \
  && ok "workflow-subagent: 3 starts, 0 decisions -> 3 ungated" \
  || bad "workflow-subagent row" "$(jq -c '.by_agent_type' <<<"$OUT" 2>&1)"

jq -e '(.by_agent_type[] | select(.agent_type == "researcher")) | .starts == 1 and .decisions == 2 and .ungated == 0' <<<"$OUT" >/dev/null 2>&1 \
  && ok "more decisions than starts floors ungated at 0 (never negative)" \
  || bad "ungated floor" "$(jq -c '.by_agent_type[] | select(.agent_type=="researcher")' <<<"$OUT" 2>&1)"

jq -e '(.by_agent_type[] | select(.agent_type == "(unnamed)")) | .starts == 1 and .ungated == 1' <<<"$OUT" >/dev/null 2>&1 \
  && ok "empty agent_type is bucketed as (unnamed), not dropped" \
  || bad "unnamed bucket" "$(jq -c '.by_agent_type' <<<"$OUT" 2>&1)"

jq -e '.ungated == 4 and .ungated_pct == 57.1 and .by_agent_type[0].agent_type == "workflow-subagent"' <<<"$OUT" >/dev/null 2>&1 \
  && ok "totals + percentage correct, rows sorted most-ungated first" \
  || bad "totals/sort" "$(jq -c '{ungated,ungated_pct,first:.by_agent_type[0].agent_type}' <<<"$OUT" 2>&1)"

TXT="$(run --since 2026-09-05T00:00:00Z 2>&1)"
grep -q "workflow-subagent stages never reach PreToolUse" <<<"$TXT" \
  && ok "text mode names the workflow bypass when it is present" || bad "workflow note" "$TXT"

OUT2="$(CC_AGENT_EVENT_LOG="$TMP/missing.jsonl" CC_GUARD_LOG="$G" "$GC" 2>&1)"; RC2=$?
[[ $RC2 -eq 0 && "$OUT2" == *"nothing to report"* ]] \
  && ok "missing log fails soft (exit 0, explains itself)" || bad "missing log fail-soft" "rc=$RC2 out=$OUT2"

run --bogus >/dev/null 2>&1; [[ $? -eq 2 ]] \
  && ok "unknown flag is a usage error (exit 2), not a silent no-op" || bad "unknown flag" "expected exit 2"

echo "== usage-report skill =="
SK="$ROOT/skills/usage-report/SKILL.md"
[[ -f "$SK" ]] && ok "skills/usage-report/SKILL.md exists" || bad "SKILL.md exists" "$SK"
head -5 "$SK" 2>/dev/null | grep -q '^name: usage-report$' \
  && ok "frontmatter name is bare 'usage-report'" || bad "frontmatter name" "$(head -5 "$SK" 2>&1)"
# Installed files must only reference the fixed install path (repo convention).
if grep -nE '(^|[ `(])\.\./|\$REPO|claude-cost-control/(dashboard|hooks|skills)' "$SK" >/dev/null 2>&1; then
  bad "skill references only installed paths" "$(grep -nE '(^|[ `(])\.\./|\$REPO|claude-cost-control/(dashboard|hooks|skills)' "$SK")"
else
  ok "skill references only installed paths (no repo-relative paths)"
fi
# Plugin cache paths carry a content hash and change on update — never pin one.
if grep -nE 'plugins/cache/[^*]*/[0-9a-f]{12}' "$SK" >/dev/null 2>&1; then
  bad "no hardcoded plugin cache hash" "$(grep -nE 'plugins/cache/[^*]*/[0-9a-f]{12}' "$SK")"
else
  ok "no hardcoded plugin cache hash (session-report is discovered by glob)"
fi
grep -q '"custom"' "$SK" 2>/dev/null \
  && ok "skill states the agent.name → \"custom\" redaction caveat" || bad "redaction caveat" ""

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
