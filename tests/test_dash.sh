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
flat() { AGENT_HUB_DASH_MODE=$1 AGENT_HUB_DASH_VIEW=flat "$AH" dash --lines; }
ids() { cut -f2 | tr '\n' ' ' | sed 's/ $//'; }

# Rows: a tree of groups (the most urgent first), their tasks under them, sessions, then the
# "+ new session" row. The popup shows the same rows; the flat view (search) the same items.
assert_eq "g:dev t:dev/docs t:dev/api g:ops t:ops/infra g:*sessions s:scratch n:" "$(lines hq | ids)" "rows: tree order and ids"
assert_eq "$(lines hq | ids)" "$(lines popup | ids)" "rows: the popup has the same rows (no hub row)"
assert_eq "+ new session  category → repo → name" "$(lines hq | tail -1 | cut -f4 | strip_ansi)" "rows: + new session last"
assert_eq "▾ dev (2) ◐1 ●1" "$(lines hq | awk -F'\t' '$2 == "g:dev" { print $4 }' | strip_ansi)" "rows: group header with counts per state"
assert_eq "  ├─ ◐ docs     svc-a    waiting 5m · Bash" "$(lines hq | awk -F'\t' '$2 == "t:dev/docs" { print $4 }' | strip_ansi | sed 's/  *$//')" "rows: task under its group: state, age, why it waits"
assert_eq "  └─ ● api      svc-a    working 2m" "$(lines hq | awk -F'\t' '$2 == "t:dev/api" { print $4 }' | strip_ansi | sed 's/  *$//')" "rows: last task of a group"
assert_eq "◐ waiting  dev/docs   svc-a    5m · Bash" "$(flat hq | awk -F'\t' '$2 == "t:dev/docs" { print $4 }' | strip_ansi | sed 's/  *$//')" "rows: flat view row"
assert_eq "t:dev/docs t:dev/api t:ops/infra s:scratch n:" "$(flat hq | ids)" "rows: flat view has no headers"
assert_eq "$p_api" "$(lines hq | awk -F'\t' '$2 == "t:dev/api" { print $3 }')" "rows: target of a live task is its Claude pane"
assert_contains "$(lines hq | awk -F'\t' '$1 == "s" { print $4 }' | strip_ansi)" "└─ ▪ scratch" "rows: plain sessions under 'sessions'"
echo ops > "$AGENT_HUB_RUNTIME/collapsed"
assert_eq "g:dev t:dev/docs t:dev/api g:ops g:*sessions s:scratch n:" "$(lines hq | ids)" "rows: a collapsed group hides its tasks"
assert_contains "$(lines hq | awk -F'\t' '$2 == "g:ops" { print $4 }' | strip_ansi)" "▸ ops" "rows: collapsed header"
check "rows: the flat view still has them" sh -c "AGENT_HUB_DASH_MODE=hq AGENT_HUB_DASH_VIEW=flat '$AH' dash --lines | grep -q 't:ops/infra'"
rm -f "$AGENT_HUB_RUNTIME/collapsed"

# Header: agents per state, over every group.
AH_SUMMARY="$TMP/summary" AGENT_HUB_DASH_MODE=hq "$AH" dash --lines >/dev/null
assert_eq "agent-hub   ◐ 1 waiting   ✓ 1 done   ● 1 working" "$(strip_ansi < "$TMP/summary")" "header: agents per state"

# PR badge read from the cache (no network in the list).
gh_dir="$AGENT_HUB_RUNTIME/gh"; mkdir -p "$gh_dir"
printf '#ts %s\nfeat/api\t42\tOPEN\tpass\thttps://x/pr/42\nfeat/docs\t7\tMERGED\t\thttps://x/pr/7\n' "$now" > "$gh_dir/$(printf '%s' "$TMP/repos/svc-a" | tr '/' '_').tsv"
"$AH" config set github auto >/dev/null
assert_contains "$(lines hq | awk -F'\t' '$2 == "t:dev/api" { print $4 }' | strip_ansi)" "#42 ✓" "rows: PR number and checks"
assert_contains "$(lines hq | awk -F'\t' '$2 == "t:dev/docs" { print $4 }' | strip_ansi)" "#7 merged" "rows: merged PR"
"$AH" config set github off >/dev/null

# Preview: task header + the live screen; a group lists its agents; help.
tm send-keys -t "$p_api" "echo PREVIEW-MARKER" Enter
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $p_api | grep -q PREVIEW-MARKER"
prev=$("$AH" dash --preview t t:dev/api "$p_api" working "$now" "" svc-a feat/api "$TMP/repos/svc-a--api" 42 OPEN pass "" "" | strip_ansi)
assert_contains "$(printf '%s\n' "$prev" | head -1)" "PREVIEW" "preview: its title on the first line"
assert_contains "$prev" "dev/api  working" "preview: header"
assert_contains "$prev" "svc-a · feat/api  ·  PR #42 open · checks ✓" "preview: repo, branch and PR"
assert_contains "$prev" "PREVIEW-MARKER" "preview: live screen of the Claude pane"
assert_contains "$("$AH" dash --preview t t:x/y - stopped "" "" svc-a feat/y "$TMP/repos/svc-a" | strip_ansi)" "Enter starts it again" "preview: a stopped task explains Enter"
prev=$("$AH" dash --preview g g:dev dev "" "" "" "" "" "" "" "" "" "" "" | strip_ansi)
assert_contains "$prev" "📁 dev" "preview: a group"
assert_contains "$prev" "2 agents · ◐ 1 waiting · ● 1 working" "preview: the group's agents per state"
assert_contains "$prev" "◐ docs" "preview: the group's agents"
assert_contains "$("$AH" dash --preview n n: - "" "" "" "" "" "" "" "" "" "" "" | strip_ansi)" "category" "preview: + new session explains the steps"
assert_contains "$("$AH" dash --help | strip_ansi)" "rename a category or a task" "help: the keys"

# A real fzf (hub mode) in the isolated server, driven through its socket and keys, with a client
# looking at it (in the hub, dialogs are tmux popups). The client runs in a "harness" session.
client=$(start_client scratch)
: > "$AGENT_HUB_RUNTIME/dash-popup-999999.sock"
tm new-window -d -t scratch: -n dash -c "$TMP" "'$AH' dash --hq"
dpane=$(tm list-panes -t scratch:dash -F '#{pane_id}')
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
sock=$(dash_sock hq)
check "dash: fzf listening on a unix socket" [ -S "$sock" ]
check "dash: stale socket of a dead dashboard removed" [ ! -e "$AGENT_HUB_RUNTIME/dash-popup-999999.sock" ]
total_is() { curl -s -m 1 --unix-socket "$sock" http://localhost | jq -e ".totalCount == $1" >/dev/null; }
current_has() { fzf_current "$sock" | grep -qF -- "$1"; }
screen_has() { tm capture-pane -p -t "$dpane" | grep -qF -- "$1"; }
wait_for 3 total_is 9
assert_eq "9" "$(fzf_get "$sock" | jq '.totalCount')" "dash: 3 tasks + 2 sessions + 3 group headers + new session"
tm select-window -t scratch:dash

# A hook event reaches the dashboard at once (push), and the cursor keeps its row across reloads.
fzf_post "$sock" 'pos(5)'
wait_for 2 current_has t:ops/infra
fire_hook "$p_infra" '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}'
wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' 'http://localhost?limit=9' | jq -r '.matches[].text' | grep 't:ops/infra' | grep -q waiting"
check "dash: refreshes after a hook event" sh -c "curl -s -m 1 --unix-socket '$sock' 'http://localhost?limit=9' | jq -r '.matches[].text' | grep 't:ops/infra' | grep -q waiting"
assert_contains "$(fzf_current "$sock")" "t:ops/infra" "dash: the cursor stays on the same task after the reload"
wait_for 3 screen_has "◐ 2 waiting"
check "header: updated with the agents" screen_has "◐ 2 waiting"

# The footer shows the keys of the selected row.
wait_for 3 screen_has "rename"
check "footer: a task's keys" sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $dpane | grep -q 'send.*rename.*move.*close'"
fzf_post "$sock" 'pos(4)'
wait_for 3 screen_has "new here"
check "footer: a group's keys" screen_has "new here"

# Tree: Enter on a group header folds it, again unfolds it; ← → h l and Tab do the same.
wait_for 2 current_has "g:ops"
tm send-keys -t "$dpane" Enter
wait_for 3 total_is 8
assert_eq "8" "$(fzf_get "$sock" | jq '.totalCount')" "tree: enter on a header collapses the group"
assert_contains "$(fzf_current "$sock")" "g:ops" "tree: the cursor stays on the header"
tm send-keys -t "$dpane" Right
wait_for 3 total_is 9
assert_eq "9" "$(fzf_get "$sock" | jq '.totalCount')" "tree: → expands it"
tm send-keys -t "$dpane" h
wait_for 3 total_is 8
assert_eq "8" "$(fzf_get "$sock" | jq '.totalCount')" "tree: h collapses it"
tm send-keys -t "$dpane" Tab
wait_for 3 total_is 9
assert_eq "9" "$(fzf_get "$sock" | jq '.totalCount')" "tree: tab unfolds it"
tm send-keys -t "$dpane" Left
wait_for 3 total_is 8
fzf_post "$sock" 'first'; sleep 0.2
tm send-keys -t "$dpane" j
wait_for 2 current_has t:dev/docs
assert_contains "$(fzf_current "$sock")" "t:dev/docs" "keys: j moves down (no input line to type in)"

# / opens the search: the flat list, so a task of a collapsed group is found; Esc goes back.
tm send-keys -t "$dpane" /
tm send-keys -t "$dpane" -l "infra"
wait_for 3 current_has t:ops/infra
assert_contains "$(fzf_current "$sock")" "t:ops/infra" "search: finds a task of a collapsed group"
check "search: flat lines, no tree" sh -c "! curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r '.matches[].text' | grep -q '├─\|└─'"
tm send-keys -t "$dpane" Escape
wait_for 3 total_is 8
assert_eq '"" 8' "$(fzf_get "$sock" | jq -r '"\"" + .query + "\" " + (.totalCount | tostring)')" "search: esc clears it and brings the tree back"
fzf_post "$sock" 'first'; sleep 0.2
tm send-keys -t "$dpane" j
wait_for 2 current_has t:dev/docs
assert_eq "" "$(fzf_get "$sock" | jq -r .query)" "search: after esc, letters are keys again"
tm send-keys -t "$dpane" Right
wait_for 3 total_is 9

# Typing while refreshes keep coming (hook events from busy agents) loses no key.
tm send-keys -t "$dpane" /
( for i in $(seq 1 40); do curl -s -m 1 --unix-socket "$sock" -XPOST http://localhost -d 'trigger(ctrl-r)' >/dev/null; sleep 0.02; done ) &
for c in o p s / i n f r a; do tm send-keys -t "$dpane" -l "$c"; sleep 0.05; done
wait
sleep 0.5
assert_eq "ops/infra" "$(fzf_get "$sock" | jq -r .query)" "dash: no key lost while refreshes keep coming"
tm send-keys -t "$dpane" Escape
wait_for 3 sh -c "[ -z \"\$(curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .query)\" ]"

# Enter (hub mode): the client switches to the task, the search closes, the dashboard stays.
tm send-keys -t "$dpane" /
tm send-keys -t "$dpane" -l "api"
wait_for 2 current_has dev/api
tm send-keys -t "$dpane" Enter
wait_for 3 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{pane_id}')\" = '$p_api' ]"
assert_eq "$p_api" "$(client_pane "$client")" "dash: enter switches the client to the agent"
check "dash: the hub dashboard stays open" [ -S "$sock" ]
wait_for 3 sh -c "[ -z \"\$(curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r .query)\" ]"
assert_eq "" "$(fzf_get "$sock" | jq -r .query)" "dash: the search is closed after opening"
tm switch-client -c "$client" -t scratch:dash
row() { fzf_lines "$sock" | awk -F'\t' -v id="$1" '$2 == id { print NR; exit }'; } # row <id>: its position
go() { # go <id>: puts the cursor on that row, once it is listed
  wait_for 3 sh -c "curl -s -m 1 --unix-socket '$sock' http://localhost | jq -r '.matches[].text' | cut -f2 | grep -qxF -- '$1'"
  fzf_post "$sock" "pos($(row "$1"))"
  wait_for 2 current_has "$1"
}

# m: the move dialog (a tmux popup over the hub) -> a new group typed in the picker.
go t:dev/docs
tm send-keys -t "$dpane" m
wait_for 3 client_has "$client" "move to which group"
check "dialog: m opens the move dialog over the hub" client_has "$client" "move to which group"
client_keys "$client" -l "web"; sleep 0.5; client_keys "$client" Enter
wait_for 5 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =web 2>/dev/null"
assert_eq "docs" "$(tm list-windows -t =web -F '#{window_name}' 2>/dev/null)" "dialog: move -> new group"
wait_for 5 screen_has "moved docs: dev -> web"
assert_contains "$(tm capture-pane -p -t "$dpane")" "moved docs: dev -> web" "dash: the header reports the move"

# Enter on "+ new session": category -> repo -> name in a dialog, then the task opens.
go n:
tm send-keys -t "$dpane" Enter
wait_for 3 client_has "$client" "new session · 1/3 category"
check "new: enter on + new session opens the dialog" client_has "$client" "new session · 1/3 category"
client_keys "$client" -l "qa"
wait_for 3 client_has "$client" "+ new category: qa"
client_keys "$client" Enter
wait_for 3 client_has "$client" "new session · 2/3 repository"
client_keys "$client" Enter
wait_for 3 client_has "$client" "new session · 3/3 name"
client_keys "$client" -l "PROJ-7 smoke test"
wait_for 3 client_has "$client" "qa/PROJ-7-smoke-test"
check "new: the name preview shows the task it becomes" client_has "$client" "→ qa/PROJ-7-smoke-test"
client_keys "$client" Enter
wait_for 8 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{client_session}:#{window_name}')\" = qa:PROJ-7-smoke-test ]"
assert_eq "qa:PROJ-7-smoke-test" "$(tm display -p -c "$client" '#{client_session}:#{window_name}')" "new: created and opened"
check "new: branch from the name" git -C "$TMP/repos/svc-a" show-ref --quiet refs/heads/feat/PROJ-7-smoke-test
tm switch-client -c "$client" -t scratch:dash

# Ctrl-C inside a dialog only cancels it.
tm send-keys -t "$dpane" n
wait_for 3 client_has "$client" "new session · 1/3 category"
client_keys "$client" C-c
wait_for 3 screen_has "new session cancelled"
check "dash: ctrl-c in a dialog cancels it, the dashboard stays" [ -S "$sock" ]
assert_contains "$(tm capture-pane -p -t "$dpane")" "new session cancelled" "dash: the header says what happened"

# r on a group: rename it (the typed name is made valid).
go g:qa
tm send-keys -t "$dpane" r
wait_for 3 client_has "$client" "rename qa"
client_keys "$client" C-u; client_keys "$client" -l "QA team"; sleep 0.3; client_keys "$client" Enter
wait_for 5 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =QA-team 2>/dev/null"
check "rename: r renames the group" sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =QA-team && ! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =qa 2>/dev/null"
wait_for 3 screen_has "renamed group qa to QA-team"
check "rename: the header says so" screen_has "renamed group qa to QA-team"

# d on a group with tasks only explains (no dialog); on a task it is the close menu.
go g:QA-team
tm send-keys -t "$dpane" d
wait_for 3 screen_has "close the tasks of QA-team first"
check "delete: a group with tasks is not deleted" screen_has "close the tasks of QA-team first"
go t:dev/api
tm send-keys -t "$dpane" d
wait_for 3 client_has "$client" "nothing to lose"
check "delete: d on a task shows the close menu" client_has "$client" "close, keep branch feat/api"
client_keys "$client" Down; client_keys "$client" Enter
wait_for 5 sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =dev -F '#{window_name}' 2>/dev/null | grep -qx api"
check "delete: task closed from the menu" [ ! -e "$TMP/repos/svc-a--api" ]
check "delete: its branch kept" git -C "$TMP/repos/svc-a" show-ref --quiet refs/heads/feat/api

# d on a plain session: confirm, then it is killed.
tm new-session -d -s junk
fzf_post "$sock" 'trigger(ctrl-r)' # a new session shows up with the next refresh (every 5s)
go s:junk
tm send-keys -t "$dpane" d
wait_for 3 client_has "$client" "delete session junk"
client_keys "$client" Down; client_keys "$client" Enter
wait_for 5 sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =junk 2>/dev/null"
check "delete: d deletes a plain session" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =junk 2>/dev/null"

# q in the hub: back to the session the client came from.
tm switch-client -c "$client" -t "=ops:"; tm switch-client -c "$client" -t scratch:dash
tm send-keys -t "$dpane" q
wait_for 3 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{client_session}')\" = ops ]"
assert_eq "ops" "$(client_session "$client")" "q: the hub goes back to the previous session"
check "q: the hub dashboard stays open" [ -S "$sock" ]

# Closing fzf removes its socket.
tm kill-window -t scratch:dash
wait_for 3 sh -c "[ ! -e '$sock' ]"
check "dash: socket removed with the dashboard" [ ! -e "$sock" ]

finish
