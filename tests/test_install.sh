#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
export AGENT_HUB_BIN_DIR="$TMP/bin" AGENT_HUB_SKILLS_DIR="$TMP/skills"
write_config "repos_roots=$TMP" "worktree_location=sibling"

cat > "$AGENT_HUB_CLAUDE_SETTINGS" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "osascript -e 'beep'" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/bin/bash /old/agent-hub/hooks/status-hook.sh # agent-hub" } ] }
    ]
  }
}
JSON
# A v1 install: block before tpm, status segment through #(...).
cat > "$AGENT_HUB_TMUX_CONF" <<'CONF'
set -g mouse on
set -g status-right "#{E:@x}"
set -g @plugin 'tmux-plugins/tpm'

# >>> agent-hub >>>
bind -n C-q if -F '#{@agent_hub}' 'switch-client -t "=hq:"' 'send-keys C-q'
set -ga status-right '#(/old/agent-hub/bin/agent-hub status-bar)'
# <<< agent-hub <<<
run '~/.tmux/plugins/tpm/tpm'
CONF
cat > "$TMP/tmux.orig" <<'CONF'
set -g mouse on
set -g status-right "#{E:@x}"
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
CONF
cp "$AGENT_HUB_CLAUDE_SETTINGS" "$TMP/settings.orig"

# Without a terminal and without explicit consent nothing is written.
out=$("$ROOT/install.sh" </dev/null 2>&1); rc=$?
assert_eq 1 "$rc" "install: refuses without confirmation"
check "install: settings untouched when refused" cmp -s "$AGENT_HUB_CLAUDE_SETTINGS" "$TMP/settings.orig"
assert_contains "$out" "+            \"timeout\": 5" "install: shows the diff before asking"

out=$(AGENT_HUB_ASSUME_YES=1 "$ROOT/install.sh" </dev/null 2>&1); rc=$?
assert_eq 0 "$rc" "install: exit 0"
s=$AGENT_HUB_CLAUDE_SETTINGS
assert_eq "Notification PermissionRequest PostToolUse PreToolUse SessionEnd SessionStart Stop StopFailure UserPromptSubmit" \
  "$(jq -r '[.hooks | to_entries[] | select([.value[].hooks[].command] | any(contains("# agent-hub"))) | .key] | sort | join(" ")' "$s")" \
  "install: the 9 hook events"
assert_eq "0" "$(jq '[.hooks[][] | .hooks[] | select(.command | contains("/old/agent-hub"))] | length' "$s")" "install: no hook left pointing at the old copy"
cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")
assert_eq "/bin/bash $ROOT/hooks/status-hook.sh || true # agent-hub" "$cmd" "install: hook command, '|| true' included"
assert_eq "AskUserQuestion|ExitPlanMode" "$(jq -r '.hooks.PreToolUse[0].matcher' "$s")" "install: PreToolUse only for the tools that wait"
assert_eq "permission_prompt|elicitation_dialog|agent_needs_input" "$(jq -r '.hooks.Notification[1].matcher' "$s")" "install: Notification matcher"
assert_eq "osascript -e 'beep'" "$(jq -r '.hooks.Notification[0].hooks[0].command' "$s")" "install: existing hook preserved"
assert_eq "opus" "$(jq -r .model "$s")" "install: other settings preserved"
check "install: settings backup" sh -c "ls '$s'.agent-hub.bak.* >/dev/null 2>&1"
check "install: bin symlink" [ -L "$TMP/bin/agent-hub" ]
check "install: skill linked" [ -f "$TMP/skills/agent-hub/SKILL.md" ]

conf=$AGENT_HUB_TMUX_CONF
assert_eq "1" "$(grep -c '^# >>> agent-hub >>>$' "$conf")" "install: one block"
check "install: the v1 lines are gone" sh -c "! grep -q 'status-bar\\|@agent_hub' '$conf'"
assert_eq "# <<< agent-hub <<<" "$(tail -1 "$conf")" "install: block at the very end (after tpm)"
assert_eq "run-shell '$ROOT/agent-hub.tmux'" "$(grep '^run-shell' "$conf")" "install: one run-shell line"

# Idempotent.
nb=$(ls "$s".agent-hub.bak.* | wc -l)
out=$(AGENT_HUB_ASSUME_YES=1 "$ROOT/install.sh" </dev/null 2>&1)
assert_contains "$out" "settings.json: already up to date" "install twice: settings unchanged"
assert_contains "$out" "tmux.conf: already up to date" "install twice: tmux.conf unchanged"
assert_eq "$nb" "$(ls "$s".agent-hub.bak.* | wc -l)" "install twice: no new backup"

# The installed hook command works as Claude Code would run it.
pane=$(tm display -p -t scratch '#{pane_id}')
printf '{"hook_event_name":"Stop"}' | TMUX_PANE="$pane" TMUX="$(tm display -p '#{socket_path}'),0,0" /bin/sh -c "$cmd"
assert_eq "done" "$(pane_opt "$pane" @agent_status)" "install: hook command from settings works"

# The tmux line: binds the popup and adds the status segment, keeping what was there.
tm set -g status-right '#(/x/continuum_save.sh)#{E:@x} #(/old/agent-hub/bin/agent-hub status-bar)'
tm bind -n C-q if -F '#{@agent_hub}' 'switch-client -t "=hq:"' 'send-keys C-q'
grep '^run-shell' "$conf" > "$TMP/line.conf"
tm source-file "$TMP/line.conf"; rc=$?
assert_eq 0 "$rc" "tmux line: sources cleanly"
wait_for 3 sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET list-keys -T root C-q 2>/dev/null | grep -q display-popup"
assert_contains "$(tm list-keys -T root C-q)" "display-popup" "tmux line: C-q opens the popup (v1 binding replaced)"
assert_contains "$(tm list-keys -T root C-q)" "$ROOT/bin/agent-hub dash --popup" "tmux line: popup runs the dashboard"
assert_eq '#(/x/continuum_save.sh)#{E:@x}  #{E:@agent_hub_status}' "$(tm show -gv status-right)" "tmux line: v1 segment out, ours in, continuum kept"
"$AH" tmux-init; "$AH" tmux-init
assert_eq 1 "$(tm show -gv status-right | grep -o '@agent_hub_status' | wc -l | tr -d ' ')" "tmux-init twice: the segment appears once"
assert_eq 1 "$(tm show -s terminal-features | grep -c 'xterm-ghostty:hyperlinks')" "tmux-init: links reach Ghostty (once)"
assert_eq "$(printf '%q' "$ROOT/bin/agent-hub") heal >/dev/null 2>&1" "$(tm show -gv @resurrect-hook-post-restore-all)" "tmux-init: heals the hub after a tmux-resurrect restore"
tm set -p -t "$pane" @agent_status waiting
assert_contains "$(tm display -p '#{E:@agent_hub_status}')" "◐1" "status: counts agents with no process"

# Keys: off, collisions with the prefix, someone else's binding, a taken resurrect hook.
"$AH" config set hub_key off >/dev/null
check "hub_key=off unbinds the popup" [ -z "$(tm list-keys -T root C-q 2>/dev/null)" ]
"$AH" config set hub_key C-b >/dev/null
check "hub_key = the prefix is refused" [ -z "$(tm list-keys -T root C-b 2>/dev/null)" ]
tm bind -n M-x display-message mine
"$AH" config set hub_key M-x >/dev/null
assert_contains "$(tm list-keys -T root M-x)" "display-message mine" "someone else's binding is never replaced"
"$AH" config set hub_key prefix:a >/dev/null
assert_contains "$(tm list-keys -T prefix a)" "display-popup" "hub_key prefix:a binds in the prefix table"
tm set -g @resurrect-hook-post-restore-all 'echo theirs'
"$AH" tmux-init
assert_eq "echo theirs" "$(tm show -gv @resurrect-hook-post-restore-all)" "a resurrect hook set by the user is kept"
tm set -gu @resurrect-hook-post-restore-all; "$AH" tmux-init

# Uninstall restores both files and cleans the running server.
out=$(AGENT_HUB_ASSUME_YES=1 "$ROOT/uninstall.sh" </dev/null 2>&1); rc=$?
assert_eq 0 "$rc" "uninstall: exit 0"
assert_eq "$(jq -S '.hooks.Stop = null | del(.hooks.Stop)' "$TMP/settings.orig")" "$(jq -S . "$s")" "uninstall: settings back (our hooks gone, others kept)"
check "uninstall: tmux.conf restored" cmp -s "$conf" "$TMP/tmux.orig"
[ -z "$(tm list-keys -T prefix a 2>/dev/null)" ] && ok "uninstall: popup key unbound live" || fail "uninstall: popup key unbound live"
assert_eq '#(/x/continuum_save.sh)#{E:@x} ' "$(tm show -gv status-right)" "uninstall: status segment removed live"
assert_eq "" "$(tm show -gqv @resurrect-hook-post-restore-all)" "uninstall: resurrect hook removed"
assert_eq 0 "$(tm show -s terminal-features | grep -c 'xterm-ghostty:hyperlinks')" "uninstall: the links feature removed"
check "uninstall: links removed" sh -c "[ ! -e '$TMP/bin/agent-hub' ] && [ ! -e '$TMP/skills/agent-hub' ]"
check "uninstall: config kept" [ -f "$AGENT_HUB_CONFIG" ]

finish
