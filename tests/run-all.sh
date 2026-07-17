#!/usr/bin/env bash
# run-all.sh — run the full offline test suite. No Claude Code needed; jq + bash.
#   ./tests/run-all.sh            # everything (hooks, merge, install, performance)
#   ./tests/run-all.sh --quick    # skip the performance benchmark
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUICK=0; [[ "${1:-}" == "--quick" ]] && QUICK=1
rc=0
for t in test-hooks.sh test-merge.sh test-install.sh; do
  echo; echo "───── $t ─────"
  bash "$DIR/$t" || rc=1
done
if [[ $QUICK -eq 0 ]]; then
  echo; echo "───── test-performance.sh ─────"
  bash "$DIR/test-performance.sh" || rc=1
fi
echo
if [[ $rc -eq 0 ]]; then echo "ALL TEST FILES PASSED"; else echo "FAILURES — do not install until resolved"; fi
exit $rc
