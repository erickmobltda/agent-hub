#!/bin/bash
. "$(dirname "$0")/lib.sh"
write_config "repos_roots=$TMP" "worktree_location=sibling"

out=$("$AH" doctor --deps </dev/null 2>&1); rc=$?
assert_eq 0 "$rc" "doctor passes with all deps"
assert_contains "$out" "ok      tmux" "doctor reports tmux"
assert_contains "$out" "ok      fzf" "doctor reports fzf"
assert_contains "$out" "ok      gh version 0.0.0 (stub)" "doctor reports gh when logged in"

# A PATH with only what doctor needs: jq missing (macOS ships /usr/bin/jq, so PATH is built by hand).
mkdir -p "$TMP/fakebin"
for b in tmux fzf git curl dirname readlink grep head cut sed awk bash cat tr find date mkdir; do
  ln -s "$(command -v "$b")" "$TMP/fakebin/$b"
done
ln -s "$TMP/stubbin/claude" "$TMP/fakebin/claude"
out=$(PATH="$TMP/fakebin" "$AH" doctor </dev/null 2>&1); rc=$?
assert_eq 2 "$rc" "doctor exits 2 when jq is missing"
assert_contains "$out" "MISSING jq" "doctor names the missing dep"
assert_contains "$out" "brew install jq" "doctor prints the install command"
assert_contains "$out" "ok      tmux" "doctor still checks the other deps"
assert_contains "$out" "gh not found (optional" "doctor: gh is optional"

# Versions agent-hub needs.
printf '#!/bin/bash\necho "0.60.0 (brew)"\n' > "$TMP/fakebin/fzf-old"; chmod +x "$TMP/fakebin/fzf-old"
rm "$TMP/fakebin/fzf"; ln -s "$TMP/fakebin/fzf-old" "$TMP/fakebin/fzf"
ln -s "$(command -v jq)" "$TMP/fakebin/jq"
out=$(PATH="$TMP/fakebin" "$AH" doctor --deps </dev/null 2>&1); rc=$?
assert_eq 2 "$rc" "doctor: fzf too old -> exit 2"
assert_contains "$out" "fzf 0.60.0 is too old: agent-hub needs 0.73+" "doctor explains the fzf version"
printf '#!/bin/bash\n[ "$1" = -V ] && echo "tmux 3.2a"\n' > "$TMP/fakebin/tmux-old"; chmod +x "$TMP/fakebin/tmux-old"
rm "$TMP/fakebin/tmux"; ln -s "$TMP/fakebin/tmux-old" "$TMP/fakebin/tmux"
out=$(PATH="$TMP/fakebin" "$AH" doctor --deps </dev/null 2>&1)
assert_contains "$out" "tmux 3.2 is too old: agent-hub needs 3.3+" "doctor explains the tmux version"

# Integration: hooks.
echo '{"disableAllHooks": true}' > "$AGENT_HUB_CLAUDE_SETTINGS"
out=$("$AH" doctor </dev/null 2>&1)
assert_contains "$out" "status hooks missing for:" "doctor: hooks not installed"
assert_contains "$out" "disables user hooks" "doctor warns when hooks are disabled"
. "$ROOT/lib/common.sh"; . "$ROOT/lib/install.sh"
echo '{}' | settings_merge "/bin/bash /elsewhere/hooks/status-hook.sh || true # agent-hub" > "$AGENT_HUB_CLAUDE_SETTINGS"
assert_contains "$("$AH" doctor </dev/null 2>&1)" "run another copy of agent-hub" "doctor: hooks of another checkout"
echo '{}' | settings_merge "/bin/bash $ROOT/hooks/status-hook.sh # agent-hub" > "$AGENT_HUB_CLAUDE_SETTINGS"
assert_contains "$("$AH" doctor </dev/null 2>&1)" "lack '|| true'" "doctor: hooks without || true"
echo '{}' | settings_merge "$(hook_command "$ROOT")" > "$AGENT_HUB_CLAUDE_SETTINGS"
assert_contains "$("$AH" doctor </dev/null 2>&1)" "ok      status hooks installed" "doctor: hooks ok"

# Integration: tmux.
assert_contains "$("$AH" doctor </dev/null 2>&1)" "tmux is not running" "doctor: no tmux server"
start_tmux
assert_contains "$("$AH" doctor </dev/null 2>&1)" "popup key not bound" "doctor: popup key missing"
"$AH" tmux-init
assert_contains "$("$AH" doctor </dev/null 2>&1)" "ok      popup key: C-q" "doctor: popup key ok"
tm unbind -n C-q; tm set -gu @agent_hub_key; tm bind -n C-q display-message theirs
assert_contains "$("$AH" doctor </dev/null 2>&1)" "C-q is already bound to something else" "doctor: key taken"
assert_contains "$("$AH" doctor </dev/null 2>&1)" "ok      tmux finds claude" "doctor: claude in tmux's PATH"
tm set-environment -g PATH /usr/bin:/bin
assert_contains "$("$AH" doctor </dev/null 2>&1)" "'claude' is not in tmux's PATH" "doctor: claude missing from tmux's PATH"

finish
