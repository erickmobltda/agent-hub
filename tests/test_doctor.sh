#!/bin/bash
. "$(dirname "$0")/lib.sh"

out=$("$AH" doctor </dev/null 2>&1); rc=$?
assert_eq 0 "$rc" "doctor passes with all deps"
assert_contains "$out" "ok      tmux" "doctor reports tmux"
assert_contains "$out" "ok      fzf" "doctor reports fzf"

# PATH without jq (and without brew): only the tools doctor needs.
# macOS ships /usr/bin/jq, so we cannot just drop Homebrew from PATH.
mkdir -p "$TMP/fakebin"
for b in tmux fzf git curl dirname readlink grep head cut; do ln -s "$(command -v "$b")" "$TMP/fakebin/$b"; done
ln -s "$TMP/stubbin/claude" "$TMP/fakebin/claude"
out=$(PATH="$TMP/fakebin" "$AH" doctor </dev/null 2>&1); rc=$?
assert_eq 2 "$rc" "doctor exits 2 when jq is missing"
assert_contains "$out" "MISSING jq" "doctor names the missing dep"
assert_contains "$out" "brew install jq" "doctor prints install command"
assert_contains "$out" "ok      tmux" "doctor still checks the other deps"

# Hooks policy warning.
echo '{"disableAllHooks": true}' > "$AGENT_HUB_CLAUDE_SETTINGS"
out=$("$AH" doctor </dev/null 2>&1)
assert_contains "$out" "disables user hooks" "doctor warns when hooks are disabled"

finish
