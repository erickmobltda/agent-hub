#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
export AGENT_HUB_BIN_DIR="$TMP/bin" AGENT_HUB_SKILLS_DIR="$TMP/skills"
write_config "repos_roots=$TMP" "worktree_location=sibling"

cat > "$AGENT_HUB_CLAUDE_SETTINGS" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "osascript -e 'beep'" } ] }
    ]
  }
}
EOF
cat > "$AGENT_HUB_TMUX_CONF" <<'EOF'
set -g mouse on
set -g status-right "#{E:@x}"
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
EOF
cp "$AGENT_HUB_CLAUDE_SETTINGS" "$TMP/settings.orig"
cp "$AGENT_HUB_TMUX_CONF" "$TMP/tmux.orig"

# Without a terminal and without explicit consent nothing is written.
out=$("$ROOT/install.sh" </dev/null 2>&1); rc=$?
assert_eq 1 "$rc" "install: refuses without confirmation"
cmp -s "$AGENT_HUB_CLAUDE_SETTINGS" "$TMP/settings.orig" && ok "install: settings untouched when refused" || fail "install: settings untouched when refused"
assert_contains "$out" "+            \"timeout\": 5" "install: shows the diff before asking"

out=$(AGENT_HUB_ASSUME_YES=1 "$ROOT/install.sh" </dev/null 2>&1); rc=$?
assert_eq 0 "$rc" "install: exit 0"
s=$AGENT_HUB_CLAUDE_SETTINGS
assert_eq "8" "$(jq '[.hooks[][] | .hooks[] | select(.command | contains("# agent-hub"))] | length' "$s")" "install: 8 hook entries"
assert_eq "osascript -e 'beep'" "$(jq -r '.hooks.Notification[0].hooks[0].command' "$s")" "install: existing hook preserved"
assert_eq "opus" "$(jq -r .model "$s")" "install: other settings preserved"
assert_eq "permission_prompt|elicitation_dialog|agent_needs_input" "$(jq -r '.hooks.Notification[1].matcher' "$s")" "install: Notification matcher"
ls "$s".agent-hub.bak.* >/dev/null 2>&1 && ok "install: settings backup" || fail "install: settings backup"
[ -L "$TMP/bin/agent-hub" ] && ok "install: bin symlink" || fail "install: bin symlink"
[ -f "$TMP/skills/agent-hub/SKILL.md" ] && ok "install: skill linked" || fail "install: skill linked"

assert_eq "1" "$(grep -c '^# >>> agent-hub >>>$' "$AGENT_HUB_TMUX_CONF")" "install: one tmux block"
assert_eq "# <<< agent-hub <<<" "$(grep -B1 "^run '~/.tmux/plugins/tpm/tpm'" "$AGENT_HUB_TMUX_CONF" | head -1)" "install: block right before tpm run"
got=$(printf 'set -g x 1\n# keep tpm last\nrun ~/.tmux/plugins/tpm/tpm\n' |
  bash -c ". '$ROOT/lib/common.sh'; . '$ROOT/lib/install.sh'; printf 'BLOCK\n' > '$TMP/b'; tmux_block_insert '$TMP/b'" | tr '\n' '|')
assert_eq "set -g x 1|BLOCK|# keep tpm last|run ~/.tmux/plugins/tpm/tpm|" "$got" "install: block goes above the tpm comment"

# Idempotent.
nb=$(ls "$s".agent-hub.bak.* | wc -l)
out=$(AGENT_HUB_ASSUME_YES=1 "$ROOT/install.sh" </dev/null 2>&1)
assert_contains "$out" "settings.json: already up to date" "install twice: settings unchanged"
assert_contains "$out" "tmux.conf: already up to date" "install twice: tmux.conf unchanged"
assert_eq "$nb" "$(ls "$s".agent-hub.bak.* | wc -l)" "install twice: no new backup"

# The installed hook command works as Claude Code would run it.
pane=$(tm display -p -t scratch '#{pane_id}')
cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")
printf '{"hook_event_name":"Stop"}' | TMUX_PANE="$pane" TMUX="$(tm display -p '#{socket_path}'),0,0" /bin/sh -c "$cmd"
assert_eq "done" "$(tm show -pqv -t "$pane" @agent_status)" "install: hook command from settings works"

# The tmux block parses and binds C-q in the root table.
sed -n '/^# >>> agent-hub >>>$/,/^# <<< agent-hub <<<$/p' "$AGENT_HUB_TMUX_CONF" > "$TMP/block.conf"
tm source-file "$TMP/block.conf"; rc=$?
assert_eq 0 "$rc" "tmux block: sources cleanly"
assert_contains "$(tm list-keys -T root C-q)" "if-shell -F" "tmux block: C-q bound in root table"
assert_contains "$(tm show -gv status-right)" "status-bar" "tmux block: status-right segment appended"

# Uninstall restores both files.
out=$(AGENT_HUB_ASSUME_YES=1 "$ROOT/uninstall.sh" </dev/null 2>&1); rc=$?
assert_eq 0 "$rc" "uninstall: exit 0"
assert_eq "$(jq -S . "$TMP/settings.orig")" "$(jq -S . "$s")" "uninstall: settings restored"
cmp -s "$AGENT_HUB_TMUX_CONF" "$TMP/tmux.orig" && ok "uninstall: tmux.conf restored" || fail "uninstall: tmux.conf restored" "$(diff "$TMP/tmux.orig" "$AGENT_HUB_TMUX_CONF")"
[ ! -e "$TMP/bin/agent-hub" ] && [ ! -e "$TMP/skills/agent-hub" ] && ok "uninstall: links removed" || fail "uninstall: links removed"
[ -f "$AGENT_HUB_CONFIG" ] && ok "uninstall: config kept" || fail "uninstall: config kept"

finish
