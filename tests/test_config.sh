#!/bin/bash
. "$(dirname "$0")/lib.sh"

mkdir -p "$TMP/repos"

# Parse: comments, blanks, unknown keys, '=' inside values, empty values; never executed.
cat > "$AGENT_HUB_CONFIG" <<CFG
# comment

repos_roots=$TMP/repos
branch_prefix=
unknown=\$(touch $TMP/pwned)
worktree_location=sibling
hq_session=hub=x
CFG
assert_eq "$TMP/repos" "$("$AH" config get repos_roots)" "parse: simple value"
assert_eq "" "$("$AH" config get branch_prefix)" "parse: empty value"
assert_eq "" "$("$AH" config get base_branch)" "parse: base_branch defaults to auto (empty)"
assert_eq "claude" "$("$AH" config get agent_cmd)" "parse: default agent_cmd"
assert_eq "C-q" "$("$AH" config get hub_key)" "parse: default hub_key"
assert_eq "70" "$("$AH" config get claude_pane_pct)" "parse: default claude_pane_pct"
assert_eq "hub=x" "$("$AH" config get hq_session)" "parse: '=' inside value"
check "config is never executed" [ ! -e "$TMP/pwned" ]

out=$("$AH" config get nope 2>&1); rc=$?
assert_eq 1 "$rc" "get unknown key fails"

# set rewrites only its line: comments and unknown lines stay.
"$AH" config set branch_prefix feat/ >/dev/null
assert_eq "feat/" "$("$AH" config get branch_prefix)" "set persists"
assert_eq "sibling" "$("$AH" config get worktree_location)" "set keeps other keys"
check "set keeps comments" grep -qxF '# comment' "$AGENT_HUB_CONFIG"
"$AH" config set agent_cmd "claude --model opus" >/dev/null
assert_eq "claude --model opus" "$("$AH" config get agent_cmd)" "set appends a missing key"
assert_eq 1 "$(grep -c '^branch_prefix=' "$AGENT_HUB_CONFIG")" "set never duplicates a key"
for bad in "claude_pane_pct 5" "worktree_location relative/path" "status_bar maybe" "github yes" "hub_key prefix:" "hub_key" "agent_cmd" "icons fancy"; do
  # shellcheck disable=SC2086
  out=$("$AH" config set $bad "" 2>&1); rc=$?
  [ "$rc" = 1 ] && ok "set validates: $bad" || fail "set validates: $bad" "rc=$rc $out"
done
"$AH" config set hub_key prefix:a >/dev/null && ok "set hub_key prefix:a" || fail "set hub_key prefix:a"

# A new config is self-documenting.
rm -f "$AGENT_HUB_CONFIG"
"$AH" setup --repos-roots "$TMP/repos" --branch-prefix "" --worktree-location subdirectory </dev/null >/dev/null 2>&1
assert_eq "subdirectory" "$("$AH" config get worktree_location)" "setup with flags"
assert_eq "" "$("$AH" config get branch_prefix)" "setup accepts empty prefix"
check "new config documents its keys" grep -q '^# Folder(s) that CONTAIN your git repos' "$AGENT_HUB_CONFIG"
assert_eq 11 "$(grep -c '^[a-z_]*=' "$AGENT_HUB_CONFIG")" "new config lists every key"

# config edit: opens $EDITOR, then validates.
printf '#!/bin/bash\nsed -i "" "s/^claude_pane_pct=.*/claude_pane_pct=60/" "$1"\n' > "$TMP/ed.sh"; chmod +x "$TMP/ed.sh"
EDITOR="$TMP/ed.sh" "$AH" config edit >/dev/null 2>&1
assert_eq 60 "$("$AH" config get claude_pane_pct)" "edit saves"
printf '#!/bin/bash\nsed -i "" "s/^claude_pane_pct=.*/claude_pane_pct=999/" "$1"\n' > "$TMP/ed.sh"
out=$(EDITOR="$TMP/ed.sh" "$AH" config edit 2>&1); rc=$?
assert_eq 1 "$rc" "edit reports an invalid value"

# Interactive setup without a terminal: option numbers and free text.
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

mkdir -p "$TMP/home/src"
"$AH" setup --repos-roots "~/src" --branch-prefix x --worktree-location sibling >/dev/null 2>&1
assert_eq "$TMP/home/src" "$("$AH" config get repos_roots)" "setup expands ~"

# Real terminal: fzf picker driven with arrows + Enter inside the isolated tmux.
start_tmux
for r in a b c; do mkdir -p "$TMP/home/code/$r/.git"; done
rm -f "$AGENT_HUB_CONFIG"
tm new-window -d -t scratch: -n setup "'$AH' setup; sleep 5"
step() { wait_for 5 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t scratch:setup | grep -q '$1'"; tm send-keys -t scratch:setup "${@:2}"; }
step "CONTAINS" Enter
step "Branch prefix" Down Enter
step "worktrees" Down Down Enter
wait_for 5 sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET capture-pane -p -t scratch:setup | grep -q 'arrows + enter'"
tm send-keys -t scratch:setup -l "~/wt"
tm send-keys -t scratch:setup Enter
wait_for 5 sh -c "grep -q '^worktree_location=/' '$AGENT_HUB_CONFIG' 2>/dev/null"
assert_eq "$TMP/home/code" "$("$AH" config get repos_roots)" "fzf: suggested root picked with Enter"
assert_eq "feat/" "$("$AH" config get branch_prefix)" "fzf: arrow down picks 2nd option"
assert_eq "$TMP/home/wt" "$("$AH" config get worktree_location)" "fzf: free text option + ~ expansion"

# Keys that live in tmux apply to the running server at once.
"$AH" config set hub_key M-q >/dev/null
assert_contains "$(tm list-keys -T root M-q)" "agent-hub" "config set hub_key binds the new key live"
check "and unbinds the previous one" [ -z "$(tm list-keys -T root C-q 2>/dev/null)" ]
"$AH" config set status_bar off >/dev/null
assert_not_contains "$(tm show -gv status-right)" "@agent_hub_status" "status_bar off removes the segment live"

finish
