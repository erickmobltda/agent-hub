#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling" "github=off"
for t in dev/api dev/docs ops/infra; do "$AH" new --group "${t%/*}" --repo svc-a --task "${t#*/}" >/dev/null 2>&1; done
p_api=$(task_pane dev:api); p_docs=$(task_pane dev:docs); p_infra=$(task_pane ops:infra)
now=$(date +%s)
tm set -p -t "$p_api" @agent_status working \; set -p -t "$p_api" @agent_since $((now - 120))
tm set -p -t "$p_docs" @agent_status waiting \; set -p -t "$p_docs" @agent_since $((now - 300)) \; set -p -t "$p_docs" @agent_note Bash
tm set -p -t "$p_infra" @agent_status done \; set -p -t "$p_infra" @agent_since $((now - 7200))
lines() { AGENT_HUB_DASH_MODE=$1 "$AH" dash --lines; }

# Rows: kind, id, display; the most urgent group first; sessions last; hub row only in the popup.
assert_eq "t:dev/docs t:dev/api t:ops/infra s:scratch" "$(lines hq | cut -f2 | tr '\n' ' ' | sed 's/ $//')" "rows: order and ids (hub)"
assert_eq "h: t:dev/docs" "$(lines popup | cut -f2 | head -2 | tr '\n' ' ' | sed 's/ $//')" "rows: hub row first in the popup"
row=$(lines hq | awk -F'\t' '$2 == "t:dev/docs" { print $4 }' | strip_ansi)
assert_eq "◐ waiting  dev/docs   svc-a    5m · Bash" "$(printf '%s' "$row" | sed 's/  *$//')" "rows: waiting row shows age and what it waits for"
assert_eq "$p_api" "$(lines hq | awk -F'\t' '$2 == "t:dev/api" { print $3 }')" "rows: target of a live task is its Claude pane"
assert_contains "$(lines hq | awk -F'\t' '$1 == "s" { print $4 }' | strip_ansi)" "▪ session  scratch" "rows: plain sessions listed"

# PR badge read from the cache (no network in the list).
gh_dir="$AGENT_HUB_RUNTIME/gh"; mkdir -p "$gh_dir"
printf '#ts %s\nfeat/api\t42\tOPEN\tpass\thttps://x/pr/42\nfeat/docs\t7\tMERGED\t\thttps://x/pr/7\n' "$now" > "$gh_dir/$(printf '%s' "$TMP/repos/svc-a" | tr '/' '_').tsv"
"$AH" config set github auto >/dev/null
assert_contains "$(lines hq | awk -F'\t' '$2 == "t:dev/api" { print $4 }' | strip_ansi)" "#42 ✓" "rows: PR number and checks"
assert_contains "$(lines hq | awk -F'\t' '$2 == "t:dev/docs" { print $4 }' | strip_ansi)" "#7 merged" "rows: merged PR"
"$AH" config set github off >/dev/null

# Preview: task header + the live screen.
tm send-keys -t "$p_api" "echo PREVIEW-MARKER" Enter
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $p_api | grep -q PREVIEW-MARKER"
prev=$("$AH" dash --preview t t:dev/api "$p_api" working "$now" "" svc-a feat/api "$TMP/repos/svc-a--api" 42 OPEN pass "" "" | strip_ansi)
assert_contains "$prev" "dev/api  working" "preview: header"
assert_contains "$prev" "svc-a · feat/api  ·  PR #42 open · checks ✓" "preview: repo, branch and PR"
assert_contains "$prev" "PREVIEW-MARKER" "preview: live screen of the Claude pane"
assert_contains "$("$AH" dash --preview t t:x/y - stopped "" "" svc-a feat/y "$TMP/repos/svc-a" | strip_ansi)" "Enter starts it again" "preview: a stopped task explains Enter"

# A real fzf (hub mode) in the isolated server, driven through its socket and keys.
: > "$AGENT_HUB_RUNTIME/dash-popup-999999.sock"
tm new-window -d -t scratch: -n dash -c "$TMP" "'$AH' dash --hq"
dpane=$(tm list-panes -t scratch:dash -F '#{pane_id}')
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
sock=$(dash_sock hq)
check "dash: fzf listening on a unix socket" [ -S "$sock" ]
check "dash: stale socket of a dead dashboard removed" [ ! -e "$AGENT_HUB_RUNTIME/dash-popup-999999.sock" ]
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -e '.totalCount == 4' >/dev/null"
assert_eq "4" "$(fzf_get "$sock" | jq '.totalCount')" "dash: 3 tasks + 1 session"

# A hook event reaches the dashboard at once (push), and the cursor keeps its row across reloads.
fzf_post "$sock" 'pos(3)'
wait_for 2 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q ops/infra"
fire_hook "$p_infra" '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}'
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' 'http://localhost?limit=9' | jq -r '.matches[].text' | grep -q 'waiting  ops/infra'"
assert_contains "$(fzf_lines "$sock")" "waiting  ops/infra" "dash: refreshes after a hook event"
assert_contains "$(fzf_current "$sock")" "ops/infra" "dash: the cursor stays on the same task after the reload"
fzf_post "$sock" 'change-query(docs)'
wait_for 2 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q dev/docs"
assert_contains "$(fzf_current "$sock")" "dev/docs" "dash: typing focuses the best match"
fzf_post "$sock" 'clear-query'

# Typing while refreshes keep coming (hook events from busy agents) loses no key.
fzf_post "$sock" 'clear-query'
( for i in $(seq 1 40); do curl -s -m 1 --unix-socket "$sock" -XPOST http://localhost -d 'trigger(ctrl-r)' >/dev/null; sleep 0.02; done ) &
for c in o p s / i n f r a; do tm send-keys -t "$dpane" -l "$c"; sleep 0.05; done
wait
sleep 0.5
assert_eq "ops/infra" "$(fzf_get "$sock" | jq -r .query)" "dash: no key lost while refreshes keep coming"
fzf_post "$sock" 'clear-query'

# Enter (hub mode): the client switches to the task; the dashboard stays open.
client=$(start_client scratch)
tm select-window -t scratch:dash
fzf_post "$sock" 'change-query(api)'
wait_for 2 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q dev/api"
tm send-keys -t "$dpane" Enter
wait_for 3 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{pane_id}')\" = '$p_api' ]"
assert_eq "$p_api" "$(client_pane "$client")" "dash: enter switches the client to the agent"
check "dash: the hub dashboard stays open" [ -S "$sock" ]
tm switch-client -c "$client" -t scratch:dash
fzf_post "$sock" 'clear-query'

# Tab menu -> "move" (it triggers ctrl-g) -> a new group typed in the picker.
fzf_post "$sock" 'change-query(docs)'
wait_for 2 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q dev/docs"
tm send-keys -t "$dpane" Tab
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'move to another group'"
tm send-keys -t "$dpane" -l "move"; sleep 0.3; tm send-keys -t "$dpane" Enter
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'move to which group'"
tm send-keys -t "$dpane" -l "web"; sleep 0.5; tm send-keys -t "$dpane" Enter
wait_for 5 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =web 2>/dev/null"
assert_eq "docs" "$(tm list-windows -t =web -F '#{window_name}' 2>/dev/null)" "dash: tab menu -> move -> new group"
wait_for 5 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'moved docs: dev -> web'"
assert_contains "$(tm capture-pane -p -t "$dpane")" "moved docs: dev -> web" "dash: the footer reports the move"

# Ctrl-C inside an action's prompt only cancels that prompt.
tm send-keys -t "$dpane" C-n
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'new agent'"
tm send-keys -t "$dpane" C-c
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'new agent cancelled'"
check "dash: ctrl-c in a prompt cancels it, the dashboard stays" [ -S "$sock" ]
assert_contains "$(tm capture-pane -p -t "$dpane")" "new agent cancelled" "dash: the footer says what happened"

# Ctrl-X: the close menu, defaulting to cancel; "keep" closes and keeps the branch.
fzf_post "$sock" 'change-query(api)'
wait_for 2 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .current.text | grep -q dev/api"
tm send-keys -t "$dpane" C-x
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'nothing to lose'"
assert_contains "$(tm capture-pane -p -t "$dpane")" "close, keep branch feat/api" "dash: ctrl-x shows the close menu"
tm send-keys -t "$dpane" Down Enter
wait_for 5 sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =dev -F '#{window_name}' 2>/dev/null | grep -qx api"
check "dash: task closed from the menu" [ ! -e "$TMP/repos/svc-a--api" ]
check "dash: its branch kept" git -C "$TMP/repos/svc-a" show-ref --quiet refs/heads/feat/api

# Closing fzf removes its socket.
tm kill-window -t scratch:dash
wait_for 3 sh -c "[ ! -e '$sock' ]"
check "dash: socket removed with the dashboard" [ ! -e "$sock" ]

finish
