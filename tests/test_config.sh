#!/bin/bash
. "$(dirname "$0")/lib.sh"

mkdir -p "$TMP/repos"

# Parse: comments, blanks, unknown keys, '=' inside values, empty values; never executed.
cat > "$AGENT_HUB_CONFIG" <<EOF
# comment

repos_roots=$TMP/repos
branch_prefix=
unknown=\$(touch $TMP/pwned)
worktree_location=sibling
hq_session=hub=x
EOF
assert_eq "$TMP/repos" "$("$AH" config get repos_roots)" "parse: simple value"
assert_eq "" "$("$AH" config get branch_prefix)" "parse: empty value"
assert_eq "main" "$("$AH" config get base_branch)" "parse: default base_branch"
assert_eq "70" "$("$AH" config get claude_pane_pct)" "parse: default claude_pane_pct"
assert_eq "hub=x" "$("$AH" config get hq_session)" "parse: '=' inside value"
[ -e "$TMP/pwned" ] && fail "config is never executed" || ok "config is never executed"

out=$("$AH" config get nope 2>&1); rc=$?
assert_eq 1 "$rc" "get unknown key fails"

"$AH" config set branch_prefix feat/ >/dev/null
assert_eq "feat/" "$("$AH" config get branch_prefix)" "set persists"
assert_eq "sibling" "$("$AH" config get worktree_location)" "set keeps other keys"
out=$("$AH" config set claude_pane_pct 5 2>&1); rc=$?
assert_eq 1 "$rc" "set validates range"
out=$("$AH" config set worktree_location relative/path 2>&1); rc=$?
assert_eq 1 "$rc" "set validates worktree_location"

# Non-interactive setup (orchestrator path).
rm -f "$AGENT_HUB_CONFIG"
"$AH" setup --repos-roots "$TMP/repos" --branch-prefix "" --worktree-location subdirectory </dev/null >/dev/null 2>&1
assert_eq "subdirectory" "$("$AH" config get worktree_location)" "setup with flags"
assert_eq "" "$("$AH" config get branch_prefix)" "setup accepts empty prefix"

# Interactive setup: option numbers and free text.
rm -f "$AGENT_HUB_CONFIG"
printf '%s\n2\n1\n' "$TMP/repos" | "$AH" setup >/dev/null 2>&1
assert_eq "feat/" "$("$AH" config get branch_prefix)" "interactive: numbered option"
assert_eq "sibling" "$("$AH" config get worktree_location)" "interactive: option label trimmed"

out=$("$AH" setup --repos-roots /nonexistent --branch-prefix x --worktree-location sibling 2>&1); rc=$?
assert_eq 1 "$rc" "setup rejects missing repos dir"

mkdir -p "$TMP/repos/myrepo/.git"
out=$("$AH" setup --repos-roots "$TMP/repos/myrepo" --branch-prefix x --worktree-location sibling 2>&1); rc=$?
assert_eq 1 "$rc" "setup rejects a repo as repos_root"
assert_contains "$out" "contains your repos" "setup explains repos_root"

# ~ expansion (HOME pointed at a temp dir; the real ~ is never touched).
mkdir -p "$TMP/home/src"
HOME="$TMP/home" "$AH" setup --repos-roots "~/src" --branch-prefix x --worktree-location sibling >/dev/null 2>&1
assert_eq "$TMP/home/src" "$("$AH" config get repos_roots)" "setup expands ~"

# Real terminal: fzf picker driven with arrows + Enter inside the isolated tmux.
start_tmux
for r in a b c; do mkdir -p "$TMP/home/code/$r/.git"; done
rm -f "$AGENT_HUB_CONFIG"
tm new-window -d -t scratch: -n setup "HOME='$TMP/home' '$AH' setup; sleep 5"
step() { wait_for 5 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t scratch:setup | grep -q '$1'"; tm send-keys -t scratch:setup "${@:2}"; }
step "CONTAINS" Enter
step "Branch prefix" Down Enter
step "worktrees" Down Down Enter
# fzf closed -> free-text prompt (readline) is waiting.
wait_for 5 sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t scratch:setup | grep -q 'arrows + enter'"
tm send-keys -t scratch:setup -l "~/wt"
tm send-keys -t scratch:setup Enter
wait_for 5 sh -c "grep -q '^worktree_location=/' '$AGENT_HUB_CONFIG' 2>/dev/null"
assert_eq "$TMP/home/code" "$("$AH" config get repos_roots)" "fzf: suggested root picked with Enter"
assert_eq "feat/" "$("$AH" config get branch_prefix)" "fzf: arrow down picks 2nd option"
assert_eq "$TMP/home/wt" "$("$AH" config get worktree_location)" "fzf: free text option + ~ expansion"

finish
