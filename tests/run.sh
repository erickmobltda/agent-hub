#!/bin/bash
# Runs every tests/test_*.sh (or the ones given as args). Pure bash, no bats.
cd -P "$(dirname "$0")" || exit 1
status=0
echo "== syntax"
for f in ../bin/agent-hub ../lib/*.sh ../hooks/*.sh ../install.sh ../uninstall.sh ../agent-hub.tmux; do
  bash -n "$f" || { echo "  FAIL bash -n $f"; status=1; }
done
awk -f ../lib/rows.awk </dev/null >/dev/null || { echo "  FAIL awk lib/rows.awk"; status=1; }
[ "$status" = 0 ] && echo "  ok   bash -n and awk"
files=${*:-test_*.sh}
for f in $files; do
  echo "== $f"
  bash "$f" || status=1
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  shellcheck -x ../bin/agent-hub ../lib/*.sh ../hooks/*.sh ../install.sh ../uninstall.sh || status=1
else
  echo "== shellcheck not installed (optional), skipped"
fi
[ "$status" = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit "$status"
