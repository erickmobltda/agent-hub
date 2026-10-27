#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
make_repo "$TMP/repos" svc-b >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling" "github=off"
screen_has() { tmux -L "$AGENT_HUB_TMUX_SOCKET" capture-pane -p -t "$1" | grep -qF -- "$2"; }
step() { # step <pane> <text on screen> <keys...>
  local p=$1 txt=$2; shift 2
  wait_for 5 screen_has "$p" "$txt" || { fail "wizard: '$txt' never showed up"; return 1; }
  tm send-keys -t "$p" "$@"
}
last_args() { awk '/^---$/ { b = "" ; next } { b = b $0 "\n" } END { printf "%s", b }' "$CLAUDE_STUB_LOG"; }

# Names: whatever is typed becomes a valid task name, case kept.
. "$ROOT/lib/ui.sh"
assert_eq "PROJ-1234-fix-login" "$(namify "PROJ-1234 fix login")" "namify: a ticket and words"
assert_eq "a_b-c" "$(namify "  a_b / c!! ")" "namify: other characters become one -, trimmed"
assert_eq "" "$(namify "!!!")" "namify: nothing valid"
long=$(namify "$(printf 'x%.0s' $(seq 1 80))")
assert_eq "60" "${#long}" "namify: at most 60 characters"

# `agent-hub new` on a terminal: category (a new one, typed) -> repo -> name, then it opens.
tm new-window -d -t scratch: -n w1 -c "$TMP/repos/svc-b" "'$AH' new; sleep 30"
p=$(tm list-panes -t scratch:w1 -F '#{pane_id}')
step "$p" "new session · 1/3 category" -l "web"
step "$p" "+ new category: web" Enter
step "$p" "new session · 2/3 repository" -l "svc-a"
sleep 0.3; tm send-keys -t "$p" Enter
step "$p" "new session · 3/3 name" -l "PROJ-1234 fix login"
step "$p" "→ web/PROJ-1234-fix-login" Enter
wait_for 8 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =web 2>/dev/null"
assert_eq "PROJ-1234-fix-login" "$(tm list-windows -t =web -F '#{window_name}' 2>/dev/null)" "wizard: task created in the new category"
check "wizard: worktree from the picked repo" [ -d "$TMP/repos/svc-a--PROJ-1234-fix-login" ]
assert_eq "feat/PROJ-1234-fix-login" "$(git -C "$TMP/repos/svc-a--PROJ-1234-fix-login" branch --show-current)" "wizard: branch named after it"
wait_for 5 grep -qsx '<web/PROJ-1234-fix-login>' "$CLAUDE_STUB_LOG"
assert_eq "<--name>
<web/PROJ-1234-fix-login>" "$(last_args)" "wizard: Claude starts with no prompt"
wait_for 3 screen_has "$p" "created web/PROJ-1234-fix-login"
check "wizard: says what it created" screen_has "$p" "created web/PROJ-1234-fix-login"

# Second run: an existing category, the current directory's repo comes first, and a name already
# taken is refused before anything is created.
tm new-window -d -t scratch: -n w2 -c "$TMP/repos/svc-b" "'$AH' new; sleep 30"
p=$(tm list-panes -t scratch:w2 -F '#{pane_id}')
step "$p" "new session · 1/3 category" -l "web"
step "$p" "1 agent" Enter
step "$p" "new session · 2/3 repository" Enter
step "$p" "new session · 3/3 name" -l "PROJ-1234 fix login"
tm send-keys -t "$p" Enter
step "$p" "already exists" C-u
tm send-keys -t "$p" -l "spike"; tm send-keys -t "$p" Enter
wait_for 8 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =web -F '#{window_name}' | grep -qx spike"
assert_eq "PROJ-1234-fix-login spike" "$(tm list-windows -t =web -F '#{window_name}' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" "wizard: a taken name refused, then created"
check "wizard: current directory's repo preselected" [ -d "$TMP/repos/svc-b--spike" ]

# The repo list only has repos, not the task worktrees next to them.
tm new-window -d -t scratch: -n w3 -c "$TMP" "'$AH' new; echo EXIT=\$?; sleep 30"
p=$(tm list-panes -t scratch:w3 -F '#{pane_id}')
step "$p" "new session · 1/3 category" Enter
wait_for 5 screen_has "$p" "new session · 2/3 repository"
check "wizard: worktrees are not offered as repos" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t $p | grep -q 'svc-a--'"

# Esc anywhere cancels without creating anything, and says so.
tm send-keys -t "$p" Escape
wait_for 3 screen_has "$p" "EXIT="
assert_eq "2" "$(ls -d "$TMP"/repos/*--* | wc -l | tr -d ' ')" "wizard: esc creates nothing"
check "wizard: esc says it was cancelled" screen_has "$p" "new session cancelled"
check "wizard: and exits 0" screen_has "$p" "EXIT=0"

finish
