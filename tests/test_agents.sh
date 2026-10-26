#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
make_repo "$TMP/repos" svc-b >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling"

# --- new ---
out=$("$AH" new --group dev --repo svc-a --task api --prompt "fix the 'bug' now" 2>&1); rc=$?
assert_eq 0 "$rc" "new: exit 0"
wt="$TMP/repos/svc-a--api"
[ -d "$wt" ] && ok "new: worktree created (sibling)" || fail "new: worktree created (sibling)" "$out"
assert_eq "feat/api" "$(git -C "$wt" branch --show-current)" "new: branch with prefix"
assert_eq "$(git -C "$TMP/repos/svc-a" rev-parse origin/main)" "$(git -C "$wt" rev-parse HEAD)" "new: based on origin/main"
assert_eq "api" "$(tm list-windows -t =dev -F '#{window_name}')" "new: session=group, window=task"
assert_eq "1" "$(tm show -qv -t =dev: @agent_hub)" "new: session marked @agent_hub"
assert_eq "2" "$(tm list-panes -t =dev:api | wc -l | tr -d ' ')" "new: two panes"
heights=$(tm list-panes -t =dev:api -F '#{pane_height}' | tr '\n' ' ')
h1=${heights%% *}; h2=$(echo "$heights" | cut -d' ' -f2)
pct=$((h1 * 100 / (h1 + h2 + 1)))
[ "$pct" -ge 65 ] && [ "$pct" -le 75 ] && ok "new: claude pane ~70% ($pct%)" || fail "new: claude pane ~70%" "$heights"
assert_eq "working" "$(tm show -pqv -t "$(tm list-panes -t =dev:api -F '#{pane_id}' | head -1)" @agent_status)" "new: initial status working (with prompt)"
wait_for 5 test -s "$CLAUDE_STUB_LOG"
assert_eq "fix the 'bug' now" "$(cat "$CLAUDE_STUB_LOG")" "new: claude started with prompt"
paths=$(tm list-panes -t =dev:api -F '#{pane_current_path}' | sort -u)
assert_eq "$wt" "$paths" "new: both panes in worktree"

# Collisions.
out=$("$AH" new --group dev --repo svc-a --task api 2>&1); rc=$?
assert_eq 4 "$rc" "new: duplicate task -> exit 4"
out=$("$AH" new --group dev --repo nope --task x 2>&1); rc=$?
assert_eq 4 "$rc" "new: unknown repo -> exit 4"
out=$("$AH" new --group 'a:b' --repo svc-a --task x 2>&1); rc=$?
assert_eq 1 "$rc" "new: invalid group -> exit 1"

rm -f "$CLAUDE_STUB_LOG"
"$AH" new --group dev --repo svc-b --task docs >/dev/null 2>&1
"$AH" new --group ops --repo svc-b --task infra >/dev/null 2>&1
assert_eq "done" "$(tm show -pqv -t "$(tm list-panes -t =ops:infra -F '#{pane_id}' | head -1)" @agent_status)" "new: initial status done (no prompt)"

# --- list ---
p_api=$(tm list-panes -t =dev:api -F '#{pane_id}' | head -1)
p_docs=$(tm list-panes -t =dev:docs -F '#{pane_id}' | head -1)
p_infra=$(tm list-panes -t =ops:infra -F '#{pane_id}' | head -1)
tm set -p -t "$p_api" @agent_status working
tm set -p -t "$p_docs" @agent_status done
tm set -p -t "$p_infra" @agent_status waiting
tm new-session -d -s hq; tm set -p -t =hq: @agent_status waiting
tm set -p -t =scratch: @agent_status ""

rows=$("$AH" list | cut -f1-3,5,6 | tr '\t' ' ' | tr '\n' ';')
assert_eq "ops infra waiting svc-b feat/infra;dev docs done svc-b feat/docs;dev api working svc-a feat/api;" "$rows" "list: filter hq, group with waiting first, waiting>done>working"
json=$("$AH" list --format json)
assert_eq "3" "$(printf '%s' "$json" | jq length)" "list json: 3 agents"
assert_eq "svc-a" "$(printf '%s' "$json" | jq -r '.[] | select(.task=="api") | .repo')" "list json: repo derived"

# --- move ---
out=$("$AH" move dev/docs --to ops 2>&1); rc=$?
assert_eq 0 "$rc" "move: exit 0"
assert_eq "docs infra" "$(tm list-windows -t =ops -F '#{window_name}' | sort | tr '\n' ' ' | sed 's/ $//')" "move: window in target group"
"$AH" move ops/docs --to newgrp >/dev/null 2>&1
assert_eq "docs" "$(tm list-windows -t =newgrp -F '#{window_name}')" "move: creates target group without extra windows"
assert_eq "1" "$(tm show -qv -t =newgrp: @agent_hub)" "move: target marked"
out=$("$AH" move nope/x --to ops 2>&1); rc=$?
assert_eq 4 "$rc" "move: missing task -> exit 4"

# --- close ---
echo dirty > "$wt/new.txt"
out=$("$AH" close dev/api 2>&1); rc=$?
assert_eq 3 "$rc" "close: blocks on uncommitted changes"
assert_contains "$out" "uncommitted changes" "close: reports uncommitted"
[ -d "$wt" ] && ok "close: worktree kept when blocked" || fail "close: worktree kept when blocked"
(cd "$wt" && git add -A && git -c user.email=t@t -c user.name=t commit -qm wip)
out=$("$AH" close dev/api 2>&1); rc=$?
assert_eq 3 "$rc" "close: blocks on unpushed commits"
assert_contains "$out" "not pushed" "close: reports unpushed"
(cd "$wt" && git reset -q --hard origin/main && echo s > s.txt && git add s.txt && git stash -q)
out=$("$AH" close dev/api 2>&1); rc=$?
assert_eq 3 "$rc" "close: blocks on stash"
assert_contains "$out" "stash entries" "close: reports stash"
out=$("$AH" close dev/api --yes --delete-branch 2>&1); rc=$?
assert_eq 0 "$rc" "close --yes: exit 0"
[ ! -e "$wt" ] && ok "close: worktree removed" || fail "close: worktree removed" "$out"
tm list-windows -t =dev -F '#{window_name}' 2>/dev/null | grep -qx api && fail "close: window killed" || ok "close: window killed"
git -C "$TMP/repos/svc-a" show-ref --quiet refs/heads/feat/api && fail "close: branch deleted with -d" || ok "close: branch deleted with -d"

# Clean close keeps the branch by default.
out=$("$AH" close ops/infra 2>&1); rc=$?
assert_eq 0 "$rc" "close clean: exit 0 without --yes"
assert_contains "$out" "branch kept: feat/infra" "close: branch kept by default"
git -C "$TMP/repos/svc-b" show-ref --quiet refs/heads/feat/infra && ok "close: branch still exists" || fail "close: branch still exists"

finish
