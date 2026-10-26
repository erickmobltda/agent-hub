#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
make_repo "$TMP/repos" svc-b >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling" "github=off"
log_count() { grep -c '^---$' "$CLAUDE_STUB_LOG" 2>/dev/null || echo 0; }
last_args() { awk '/^---$/ { b = "" ; next } { b = b $0 "\n" } END { printf "%s", b }' "$CLAUDE_STUB_LOG"; }
screen_has() { tm capture-pane -p -J -t "$1" | grep -qF "$2"; }

# --- new ---
prompt="fix the 'bug' \$(now)
and test it"
out=$("$AH" new --group dev --repo svc-a --task api --prompt "$prompt" 2>&1); rc=$?
assert_eq 0 "$rc" "new: exit 0"
wt="$TMP/repos/svc-a--api"
check "new: worktree created (sibling)" [ -d "$wt" ]
assert_eq "feat/api" "$(git -C "$wt" branch --show-current)" "new: branch with prefix"
assert_eq "$(git -C "$TMP/repos/svc-a" rev-parse origin/main)" "$(git -C "$wt" rev-parse HEAD)" "new: based on origin/HEAD (main)"
check "new: branch does not track the base branch" sh -c "! git -C '$wt' rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1"
marker="$(git -C "$wt" rev-parse --absolute-git-dir)/agent-hub"
assert_eq "group=dev task=api worktree=$wt" "$(tr '\n' ' ' < "$marker" | sed 's/ $//')" "new: marker in the worktree's git dir"
assert_eq "api" "$(tm list-windows -t =dev -F '#{window_name}')" "new: session=group, window=task"
assert_eq "2" "$(tm list-panes -t =dev:api | wc -l | tr -d ' ')" "new: two panes"
p_api=$(task_pane dev:api)
assert_eq "claude" "$(pane_opt "$p_api" @agent_hub_role)" "new: Claude pane marked"
assert_eq "$wt" "$(pane_opt "$p_api" @agent_worktree)" "new: worktree recorded on the pane"
heights=$(tm list-panes -t =dev:api -F '#{pane_height}' | tr '\n' ' ')
h1=${heights%% *}; h2=$(echo "$heights" | cut -d' ' -f2)
pct=$((h1 * 100 / (h1 + h2 + 1)))
[ "$pct" -ge 65 ] && [ "$pct" -le 75 ] && ok "new: claude pane ~70% ($pct%)" || fail "new: claude pane ~70%" "$heights"
wait_for 5 test -s "$CLAUDE_STUB_LOG"
assert_eq "<--name>
<dev/api>
<$prompt>" "$(last_args)" "new: claude started by the runner with --name and the prompt verbatim"
assert_eq "starting" "$(pane_opt "$p_api" @agent_status)" "new: status starting until Claude reports"
paths=$(tm list-panes -t =dev:api -F '#{pane_current_path}' | sort -u)
assert_eq "$wt" "$paths" "new: both panes in the worktree"

# Collisions and bad input.
out=$("$AH" new --group dev --repo svc-a --task api 2>&1); rc=$?
assert_eq 4 "$rc" "new: duplicate task -> exit 4"
out=$("$AH" new --group dev --repo nope --task x 2>&1); rc=$?
assert_eq 4 "$rc" "new: unknown repo -> exit 4"
out=$("$AH" new --group 'a:b' --repo svc-a --task x 2>&1); rc=$?
assert_eq 1 "$rc" "new: invalid group -> exit 1"

"$AH" new --group dev --repo svc-b --task docs >/dev/null 2>&1
"$AH" new --group ops --repo svc-b --task infra >/dev/null 2>&1
wait_for 5 grep -qx '<ops/infra>' "$CLAUDE_STUB_LOG"
check "new: without a prompt Claude starts with no prompt" grep -qx '<ops/infra>' "$CLAUDE_STUB_LOG"

# Base branch: the remote default (master), no origin at all, and fetch failing.
git init -q -b master "$TMP/repos/old"; (cd "$TMP/repos/old" && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm m)
git init -q --bare -b master "$TMP/remotes/old.git"
(cd "$TMP/repos/old" && git remote add origin "$TMP/remotes/old.git" && git push -q -u origin master && git remote set-head origin master)
"$AH" new --group dev --repo old --task m1 >/dev/null 2>&1
assert_eq "$(git -C "$TMP/repos/old" rev-parse origin/master)" "$(git -C "$TMP/repos/old--m1" rev-parse HEAD)" "base: origin/HEAD -> master"
git init -q -b main "$TMP/repos/local"; (cd "$TMP/repos/local" && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm m)
out=$("$AH" new --group dev --repo local --task l1 2>&1); rc=$?
assert_eq 0 "$rc" "base: repo without origin works"
assert_contains "$out" "no origin remote" "base: warns it starts from the local branch"
git -C "$TMP/repos/old" remote set-url origin "$TMP/remotes/missing.git"
out=$("$AH" new --group dev --repo old --task m2 2>&1); rc=$?
assert_eq 0 "$rc" "base: fetch failure falls back to the last origin/<base>"
assert_contains "$out" "fetch origin master failed" "base: and says so"
for t in m1 l1 m2; do "$AH" close "dev/$t" --yes >/dev/null 2>&1; done

# --- list ---
p_docs=$(task_pane dev:docs); p_infra=$(task_pane ops:infra)
tm set -p -t "$p_api" @agent_status working
tm set -p -t "$p_docs" @agent_status done
tm set -p -t "$p_infra" @agent_status waiting
tm new-session -d -s hq; tm set -p -t =hq: @agent_status waiting
tm new-window -d -t scratch: -n solo -c "$TMP"; tm set -p -t scratch:solo @agent_status idle
rows=$("$AH" list | cut -f1-4 | tr '\t' ' ' | tr '\n' ';')
assert_eq "t ops infra waiting;t dev docs done;t dev api working;p scratch solo idle;" "$rows" \
  "list: hub excluded, urgent group first, waiting>done>working, hand-started Claude last"
assert_eq "svc-b feat/infra" "$("$AH" list | awk -F'\t' '$3 == "infra" { print $6, $7 }')" "list: repo and branch of a task"
json=$("$AH" list --format json)
assert_eq "4" "$(printf '%s' "$json" | jq length)" "list json: 4 agents"
assert_eq "svc-a feat/api task true" "$(printf '%s' "$json" | jq -r '.[] | select(.task=="api") | "\(.repo) \(.branch) \(.kind) \(.running)"')" "list json: repo, branch, kind"
tm kill-window -t scratch:solo

# --- open: Claude stopped (runner left a shell) -> restarted with --continue ---
tm send-keys -t "$p_docs" C-d
wait_for 5 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET show -pqv -t $p_docs @agent_status)\" = stopped ]"
assert_eq "stopped" "$(pane_opt "$p_docs" @agent_status)" "runner: Claude exit -> stopped"
wait_for 5 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -t $p_docs '#{pane_current_command}')\" = bash ]"
assert_eq "bash" "$(tm display -p -t "$p_docs" '#{pane_current_command}')" "runner: leaves a shell in the pane"
n=$(log_count)
"$AH" open dev/docs --no-switch >/dev/null 2>&1
wait_for 5 sh -c "[ \$(grep -c '^---\$' '$CLAUDE_STUB_LOG') -gt $n ]"
assert_contains "$(last_args)" "<--continue>" "open: restarts Claude with --continue"
assert_eq "$p_docs" "$(task_pane dev:docs)" "open: same pane, respawned"
n=$(log_count)
"$AH" open dev/api --no-switch >/dev/null 2>&1
sleep 0.5
assert_eq "$n" "$(log_count)" "open: a running Claude is left alone"
tm set -p -t "$p_docs" @agent_status done
"$AH" open dev/docs --no-switch >/dev/null 2>&1
assert_eq "idle" "$(pane_opt "$p_docs" @agent_status)" "open: done -> idle (seen)"

# --- open: window lost (tmux restarted) -> task stopped; open re-creates it ---
tm kill-window -t =ops:infra
assert_eq "t ops infra stopped" "$("$AH" list | awk -F'\t' '$3 == "infra" { print $1, $2, $3, $4 }')" "list: task without a window is stopped"
tm set-environment -g CLAUDE_STUB_NO_CONVO 1
n=$(log_count)
"$AH" open ops/infra --no-switch >/dev/null 2>&1
wait_for 5 sh -c "[ \$(grep -c '^---\$' '$CLAUDE_STUB_LOG') -ge $((n + 2)) ]"
assert_eq "2" "$(tm list-panes -t =ops:infra | wc -l | tr -d ' ')" "open: window re-created with both panes"
check "open: no conversation -> starts a new one" sh -c "awk '/^---\$/{n++} n == $((n + 2))' '$CLAUDE_STUB_LOG' | grep -qvF -- '<--continue>'"
tm set-environment -gu CLAUDE_STUB_NO_CONVO
p_infra=$(task_pane ops:infra)

# --- Ctrl+Z: Claude Code suspends itself and waits for `fg`; the runner brings it back ---
tm send-keys -t "$p_api" -l "SUSPEND"; tm send-keys -t "$p_api" Enter
wait_for 5 screen_has "$p_api" "stub resumed"
check "ctrl-z: a suspended Claude is resumed (the pane does not freeze)" screen_has "$p_api" "stub resumed"
tm send-keys -t "$p_api" -l "still-alive"; tm send-keys -t "$p_api" Enter
wait_for 3 screen_has "$p_api" "got:still-alive"
check "ctrl-z: Claude reads input again" screen_has "$p_api" "got:still-alive"

# --- send / peek ---
tm set -p -t "$p_api" @agent_status working
out=$("$AH" send dev/api "hello \"agent\" \$HOME" 2>&1); rc=$?
assert_eq 0 "$rc" "send: exit 0"
wait_for 3 screen_has "$p_api" "hello \"agent\" \$HOME"
check "send: text typed into Claude and submitted" screen_has "$p_api" "hello \"agent\" \$HOME"
assert_contains "$("$AH" peek dev/api -n 5)" 'hello "agent" $HOME' "peek: prints the agent's screen"
tm set -p -t "$p_api" @agent_status waiting
out=$("$AH" send dev/api "1" 2>&1); rc=$?
assert_eq 3 "$rc" "send: refused while the agent waits for an answer"
tm set -p -t "$p_api" @agent_status working

# --- move ---
out=$("$AH" move dev/docs --to ops 2>&1); rc=$?
assert_eq 0 "$rc" "move: exit 0"
assert_eq "docs infra" "$(tm list-windows -t =ops -F '#{window_name}' | sort | tr '\n' ' ' | sed 's/ $//')" "move: window in the target group"
check "move: marker updated" grep -qx 'group=ops' "$(git -C "$TMP/repos/svc-b--docs" rev-parse --absolute-git-dir)/agent-hub"
"$AH" move ops/docs --to newgrp >/dev/null 2>&1
assert_eq "docs" "$(tm list-windows -t =newgrp -F '#{window_name}')" "move: creates the target group without extra windows"
tm kill-window -t =newgrp:docs
"$AH" move newgrp/docs --to dev >/dev/null 2>&1
check "move: a stopped task moves too" grep -qx 'group=dev' "$(git -C "$TMP/repos/svc-b--docs" rev-parse --absolute-git-dir)/agent-hub"
out=$("$AH" move nope/x --to ops 2>&1); rc=$?
assert_eq 4 "$rc" "move: missing task -> exit 4"

# --- close ---
echo dirty > "$wt/new.txt"
out=$("$AH" close dev/api 2>&1); rc=$?
assert_eq 3 "$rc" "close: blocks on uncommitted changes"
assert_contains "$out" "uncommitted changes" "close: reports uncommitted"
check "close: worktree kept when blocked" [ -d "$wt" ]
(cd "$wt" && git add -A && git -c user.email=t@t -c user.name=t commit -qm wip)
out=$("$AH" close dev/api 2>&1); rc=$?
assert_eq 3 "$rc" "close: blocks on unpushed commits"
assert_contains "$out" "not pushed" "close: reports unpushed"
(cd "$wt" && git reset -q --hard origin/main && echo s > s.txt && git add s.txt && git stash -q)
out=$("$AH" close dev/api 2>&1); rc=$?
assert_eq 3 "$rc" "close: blocks on stash"
assert_contains "$out" "stash entries" "close: reports stash"
# Run from the task's own shell pane: the window dies last, so the branch is still deleted.
shell_pane=$(tm list-panes -t =dev:api -F '#{pane_id}' | tail -1)
tm send-keys -t "$shell_pane" "'$AH' close dev/api --yes --delete-branch" Enter
wait_for 8 sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =dev -F '#{window_name}' 2>/dev/null | grep -qx api"
check "close: window killed" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =dev -F '#{window_name}' 2>/dev/null | grep -qx api"
check "close: worktree removed" [ ! -e "$wt" ]
check "close: branch deleted, even from inside the task" sh -c "! git -C '$TMP/repos/svc-a' show-ref --quiet refs/heads/feat/api"
assert_eq "" "$("$AH" list | awk -F'\t' '$3 == "api"')" "close: task gone from the list"

# Closing the last task of a session keeps its viewer in tmux (switched to the hub).
"$AH" new --group solo --repo svc-a --task one >/dev/null 2>&1
client=$(start_client solo)
check "client attached" [ -n "$client" ]
out=$("$AH" close solo/one 2>&1); rc=$?
assert_eq 0 "$rc" "close clean: exit 0 without --yes"
assert_contains "$out" "branch kept: feat/one" "close: branch kept by default"
wait_for 3 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET display -p -c '$client' '#{client_session}')\" = hq ]"
assert_eq "hq" "$(client_session "$client")" "close: the client moved to the hub instead of detaching"

# A task whose window is gone can be closed too.
tm kill-window -t =ops:infra
out=$("$AH" close ops/infra 2>&1); rc=$?
assert_eq 0 "$rc" "close: stopped task"
check "close: stopped task's worktree removed" [ ! -e "$TMP/repos/svc-b--infra" ]

# --- adoption: agent-hub worktrees without a marker (v1 tasks, lost markers) ---
git -C "$TMP/repos/svc-a" worktree add -q -b feat/old "$TMP/repos/svc-a--old" origin/main
tm new-session -d -s bugs -n old -c "$TMP/repos/svc-a--old"
git -C "$TMP/repos/svc-a" worktree add -q -b feat/orphan "$TMP/repos/svc-a--orphan" origin/main
git -C "$TMP/repos/svc-a" worktree add -q -b feat/foreign "$TMP/elsewhere/foreign" origin/main
out=$("$AH" list)
assert_eq "t bugs old stopped" "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "old" { print $1, $2, $3, $4 }')" "adopt: restored window -> its session is the group"
assert_eq "t svc-a orphan stopped" "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "orphan" { print $1, $2, $3, $4 }')" "adopt: orphan worktree -> repo name is the group"
assert_eq "" "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "foreign"')" "adopt: a worktree elsewhere is not a task"
n=$(log_count)
"$AH" open bugs/old --no-switch >/dev/null 2>&1
wait_for 5 sh -c "[ \$(grep -c '^---\$' '$CLAUDE_STUB_LOG') -gt $n ]"
assert_contains "$(last_args)" "<--continue>" "adopt: open resumes Claude in the restored window"
assert_eq "1" "$(tm list-windows -t =bugs | wc -l | tr -d ' ')" "adopt: reuses the restored window"

finish
