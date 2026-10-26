#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
make_repo "$TMP/repos" svc-b >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling" "github=off"
screen_has() { tmux -L "$AGENT_HUB_TMUX_SOCKET" capture-pane -p -t "$1" | grep -qF "$2"; }
step() { # step <pane> <text on screen> <keys...>
  local p=$1 txt=$2; shift 2
  wait_for 5 screen_has "$p" "$txt" || { fail "wizard: '$txt' never showed up"; return 1; }
  tm send-keys -t "$p" "$@"
}

# Slugs for the task name: a few meaningful words, English or Portuguese.
. "$ROOT/lib/ui.sh"
assert_eq "fix-login-timeout-api" "$(slugify "Fix the login timeout in the API!")" "slug: english"
assert_eq "corrigir-erro-login-api" "$(slugify "Corrigir o erro de login na API")" "slug: portuguese stop words"
assert_eq "" "$(slugify "")" "slug: empty prompt"

# `agent-hub new` on a terminal: repo -> new group typed -> prompt -> suggested name.
tm new-window -d -t scratch: -n w1 -c "$TMP/repos/svc-b" "'$AH' new; sleep 30"
p=$(tm list-panes -t scratch:w1 -F '#{pane_id}')
step "$p" "new agent · 1/4" -l "svc-a"
sleep 0.3; tm send-keys -t "$p" Enter
step "$p" "new agent · 2/4" -l "web"
step "$p" "+ new group: web" Enter
step "$p" "new agent · 3/4" -l "Fix the login timeout in the API"
tm send-keys -t "$p" Enter
step "$p" "fix-login-timeout-api" Enter
wait_for 8 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =web 2>/dev/null"
assert_eq "fix-login-timeout-api" "$(tm list-windows -t =web -F '#{window_name}' 2>/dev/null)" "wizard: task created in the new group"
check "wizard: worktree from the picked repo" [ -d "$TMP/repos/svc-a--fix-login-timeout-api" ]
wait_for 5 grep -qsx '<Fix the login timeout in the API>' "$CLAUDE_STUB_LOG"
check "wizard: Claude got the prompt" grep -qx '<Fix the login timeout in the API>' "$CLAUDE_STUB_LOG"

# Second run: the repo of the current directory comes first, an existing group is picked with
# arrows, no prompt, and an invalid name is refused before the task is created.
tm new-window -d -t scratch: -n w2 -c "$TMP/repos/svc-b" "'$AH' new; sleep 30"
p=$(tm list-panes -t scratch:w2 -F '#{pane_id}')
step "$p" "new agent · 1/4" Enter
step "$p" "new agent · 2/4" -l "we"
step "$p" "+ new group: we" Down Enter
step "$p" "new agent · 3/4" Enter
step "$p" "new agent · 4/4" -l "bad name"
tm send-keys -t "$p" Enter
step "$p" "use letters, digits, - and _" C-u
tm send-keys -t "$p" -l "spike"; tm send-keys -t "$p" Enter
wait_for 8 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =we 2>/dev/null"
assert_eq "spike" "$(tm list-windows -t =we -F '#{window_name}' 2>/dev/null)" "wizard: invalid name refused, then created"
check "wizard: current directory's repo preselected" [ -d "$TMP/repos/svc-b--spike" ]

# Esc anywhere cancels without creating anything.
tm new-window -d -t scratch: -n w3 -c "$TMP" "'$AH' new; echo EXIT=\$?; sleep 30"
p=$(tm list-panes -t scratch:w3 -F '#{pane_id}')
step "$p" "new agent · 1/4" Escape
wait_for 3 screen_has "$p" "EXIT="
assert_eq "2" "$(ls -d "$TMP"/repos/*--* | wc -l | tr -d ' ')" "wizard: esc creates nothing"

finish
