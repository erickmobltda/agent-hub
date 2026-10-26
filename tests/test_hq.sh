#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
mkdir -p "$TMP/repos"
write_config "repos_roots=$TMP/repos" "worktree_location=sibling" "hq_session=hub"

out=$("$AH" hq 2>&1); rc=$?
assert_eq 0 "$rc" "hq: exit 0 without a terminal"
assert_eq "2" "$(tm list-panes -t =hub: | wc -l | tr -d ' ')" "hq: two panes"
heights=$(tm list-panes -t =hub: -F '#{pane_height}' | tr '\n' ' ')
h1=${heights%% *}; h2=$(echo "$heights" | cut -d' ' -f2)
pct=$((h1 * 100 / (h1 + h2 + 1)))
[ "$pct" -ge 60 ] && [ "$pct" -le 70 ] && ok "hq: dashboard ~65% ($pct%)" || fail "hq: dashboard ~65%" "$heights"
wait_for 5 sh -c "ls \"$AGENT_HUB_RUNTIME\"/dash-*.sock >/dev/null 2>&1" && ok "hq: dashboard running" || fail "hq: dashboard running"
wait_for 5 test -s "$CLAUDE_STUB_LOG"
assert_eq "/agent-hub" "$(cat "$CLAUDE_STUB_LOG")" "hq: orchestrator starts with /agent-hub skill"
orch=$(tm list-panes -t =hub: -F '#{@agent_hub_role} #{pane_current_path}' | grep orchestrator)
assert_eq "orchestrator $TMP/repos" "$orch" "hq: orchestrator cwd = first repos_root"

"$AH" hq >/dev/null 2>&1
assert_eq "2" "$(tm list-panes -t =hub: | wc -l | tr -d ' ')" "hq: idempotent"

finish
