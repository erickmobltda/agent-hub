#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "worktree_location=sibling" "github=off"
"$AH" new --group dev --repo svc-a --task api >/dev/null 2>&1
p_api=$(task_pane dev:api)
"$AH" tmux-init
assert_contains "$(tm list-keys -T root C-q)" "display-popup" "popup: C-q bound in the root table"

client=$(start_client scratch)
check "popup: client attached" [ -n "$client" ]
popup_open() { [ -n "$(dash_sock popup)" ]; }

# Ctrl+Q opens the popup; typing filters; Enter jumps to the agent and closes it.
tm send-keys -K -c "$client" C-q
wait_for 5 popup_open
sock=$(dash_sock popup)
check "popup: Ctrl+Q opens the dashboard" [ -S "$sock" ]
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -e '.totalCount >= 2' >/dev/null"
assert_contains "$(fzf_lines "$sock" | head -1)" "⌂ stopped  hub" "popup: the hub is the first row"
fzf_post "$sock" 'change-query(api)'
wait_for 2 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q dev/api"
fzf_post "$sock" 'trigger(enter)'
wait_for 3 sh -c "! ls '$sock' >/dev/null 2>&1"
check "popup: closes after Enter" [ ! -e "$sock" ]
assert_eq "$p_api" "$(client_pane "$client")" "popup: Enter switched the client to the agent"

# Ctrl+Q again closes it (fzf's own Ctrl+Q aborts).
tm send-keys -K -c "$client" C-q
wait_for 5 popup_open
sock=$(dash_sock popup)
tm send-keys -K -c "$client" C-q
wait_for 3 sh -c "! ls '$sock' >/dev/null 2>&1"
check "popup: Ctrl+Q again closes it" [ ! -e "$sock" ]
assert_eq "$p_api" "$(client_pane "$client")" "popup: closing it changes nothing"

# The hub row creates the hub when it doesn't exist yet and goes there.
check "popup: no hub yet" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =hq 2>/dev/null"
tm send-keys -K -c "$client" C-q
wait_for 5 popup_open
sock=$(dash_sock popup)
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -e '.totalCount >= 2' >/dev/null"
fzf_post "$sock" 'first+trigger(enter)'
wait_for 5 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{client_session}')\" = hq ]"
assert_eq "hq" "$(client_session "$client")" "popup: the hub row opens the hub, created on the spot"
assert_eq "dashboard orchestrator" "$(tm list-panes -s -t =hq -F '#{@agent_hub_role}' | sort | tr '\n' ' ' | sed 's/ $//')" "popup: hub has its two panes"

# The popup starts in the directory of the pane it was opened from (the wizard preselects that repo).
tm switch-client -c "$client" -t "$p_api"
tm send-keys -K -c "$client" C-q
wait_for 5 popup_open
pid=$(basename "$(dash_sock popup)" .sock); pid=${pid##*-}
assert_eq "$TMP/repos/svc-a--api" "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" "popup: runs in the current pane's directory"
tm send-keys -K -c "$client" Escape

finish
