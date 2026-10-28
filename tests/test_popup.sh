#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling" "github=off"
"$AH" new --group dev --repo svc-a --task api >/dev/null 2>&1
p_api=$(task_pane dev:api)
"$AH" tmux-init
assert_contains "$(tm list-keys -T root C-q)" "display-popup" "popup: C-q bound in the root table"

client=$(start_client scratch)
check "popup: client attached" [ -n "$client" ]
popup_open() { [ -n "$(dash_sock popup)" ]; }
popup_closed() { [ -z "$(dash_sock popup)" ]; }
current_has() { fzf_current "$sock" | grep -qF -- "$1"; }

# Ctrl+Q opens the popup: a row for the hub, then the same tree as the hub. / searches, Enter
# jumps to the agent and closes it.
client_keys "$client" C-q
wait_for 5 popup_open
sock=$(dash_sock popup)
check "popup: Ctrl+Q opens the dashboard" [ -S "$sock" ]
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -e '.totalCount >= 2' >/dev/null"
assert_eq "h: g:dev" "$(fzf_lines "$sock" | head -2 | cut -f2 | tr '\n' ' ' | sed 's/ $//')" "popup: the hub row first, then the tree"
client_keys "$client" /; client_keys "$client" -l api
wait_for 2 current_has dev/api
client_keys "$client" Enter
wait_for 3 popup_closed
check "popup: closes after Enter" popup_closed
assert_eq "$p_api" "$(client_pane "$client")" "popup: Enter switched the client to the agent"

# Esc closes the search first, then the popup; q and Ctrl+Q close it too.
client_keys "$client" C-q
wait_for 5 popup_open
sock=$(dash_sock popup)
client_keys "$client" /; client_keys "$client" -l api
wait_for 2 sh -c "[ \"\$(curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .query)\" = api ]"
client_keys "$client" Escape
wait_for 3 sh -c "[ -z \"\$(curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .query)\" ]"
check "popup: esc first closes the search" sh -c "[ -S '$sock' ] && [ -z \"\$(curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .query)\" ]"
client_keys "$client" Escape
wait_for 3 popup_closed
check "popup: esc again closes it" popup_closed
client_keys "$client" C-q
wait_for 5 popup_open
client_keys "$client" q
wait_for 3 popup_closed
check "popup: q closes it" popup_closed
client_keys "$client" C-q
wait_for 5 popup_open
client_keys "$client" C-q
wait_for 3 popup_closed
check "popup: Ctrl+Q again closes it" popup_closed
assert_eq "$p_api" "$(client_pane "$client")" "popup: closing it changes nothing"

# Ctrl+Q, Enter: the cursor starts on the hub row, which goes to the hub (created on the spot).
check "popup: no hub yet" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =hq 2>/dev/null"
client_keys "$client" C-q
wait_for 5 popup_open
sock=$(dash_sock popup)
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q '^h	'"
client_keys "$client" Enter
wait_for 5 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{client_session}')\" = hq ]"
assert_eq "hq" "$(client_session "$client")" "popup: Ctrl+Q, Enter goes to the hub"
assert_eq "dashboard" "$(tm list-panes -s -t =hq -F '#{@agent_hub_role}' | tr '\n' ' ' | sed 's/ $//')" "popup: the hub is its dashboard"
wait_for 3 popup_closed
check "popup: closed on the way" popup_closed

# n inside the popup: the questions run in the popup itself (tmux can't stack popups); the new
# task opens and the popup closes.
client_keys "$client" C-q
wait_for 5 popup_open
client_keys "$client" n
wait_for 5 client_has "$client" "new session · 1/3 category"
check "popup: n asks for the category" client_has "$client" "new session · 1/3 category"
client_keys "$client" -l "qa"
wait_for 3 client_has "$client" "+ new category: qa"
client_keys "$client" Enter
wait_for 3 client_has "$client" "new session · 2/3 repository"
client_keys "$client" Enter
wait_for 3 client_has "$client" "new session · 3/3 name"
client_keys "$client" -l "T-1 check"
wait_for 3 client_has "$client" "qa/T-1-check"
client_keys "$client" Enter
wait_for 8 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{client_session}:#{window_name}')\" = qa:T-1-check ]"
assert_eq "qa:T-1-check" "$(tm display -p -c "$client" '#{client_session}:#{window_name}')" "popup: n creates the task and opens it"
wait_for 3 popup_closed
check "popup: and closes" popup_closed

# The popup starts in the directory of the pane it was opened from (the wizard preselects that repo).
tm switch-client -c "$client" -t "$p_api"
client_keys "$client" C-q
wait_for 5 popup_open
pid=$(basename "$(dash_sock popup)" .sock); pid=${pid##*-}
assert_eq "$TMP/repos/svc-a--api" "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" "popup: runs in the current pane's directory"
client_keys "$client" Escape

finish
