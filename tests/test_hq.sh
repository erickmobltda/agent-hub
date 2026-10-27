#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
mkdir -p "$TMP/repos"
write_config "repos_roots=$TMP/repos" "worktree_location=sibling" "hq_session=hub" "github=off"
roles() { tm list-panes -s -t =hub -F '#{@agent_hub_role}' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//'; }
role_pane() { tm list-panes -s -t =hub -F '#{@agent_hub_role} #{pane_id}' | awk -v r="$1" '$1 == r { print $2; exit }'; }

# Fresh hub: one window, the dashboard full screen.
out=$("$AH" hq 2>&1); rc=$?
assert_eq 0 "$rc" "hq: exit 0 without a terminal"
assert_eq "dashboard" "$(roles)" "hq: a single dashboard pane"
assert_eq "1" "$(tm list-panes -s -t =hub | wc -l | tr -d ' ')" "hq: nothing else in the hub"
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1" && ok "hq: dashboard running" || fail "hq: dashboard running"
assert_eq "$TMP/repos" "$(tm display -p -t "$(role_pane dashboard)" '#{pane_current_path}')" "hq: starts in the first repos_root"
check "hq: no Claude runs in the hub" [ ! -s "$CLAUDE_STUB_LOG" ]
"$AH" hq >/dev/null 2>&1
assert_eq "1" "$(tm list-panes -s -t =hub | wc -l | tr -d ' ')" "hq: idempotent"

# The hub pane survives Ctrl-C and even fzf dying.
dash=$(role_pane dashboard)
sock=$(dash_sock hq)
tm send-keys -t "$dash" C-c; sleep 0.5
check "hq: Ctrl-C leaves the dashboard open" [ -S "$sock" ]
pkill -f "fzf.*$(basename "$sock")" 2>/dev/null
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
check "hq: the dashboard comes back when fzf dies" sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
assert_eq "$dash" "$(role_pane dashboard)" "hq: same pane"

# An update of the code on disk restarts the hub's dashboard (no fzf with stale bindings).
cp -R "$ROOT" "$TMP/ahcopy"
tm respawn-pane -k -t "$dash" -- "$TMP/ahcopy/bin/agent-hub" dash --hq
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
old_sock=$(dash_sock hq)
wait_for 3 sh -c "pgrep -f 'listen=$old_sock' >/dev/null"
old_fzf=$(pgrep -f "listen=$old_sock" | head -1)
printf '\n# changed\n' >> "$TMP/ahcopy/lib/dash.sh"
curl -s -m 1 --unix-socket "$old_sock" -XPOST http://localhost -d 'trigger(ctrl-r)' >/dev/null
wait_for 6 sh -c "p=\$(pgrep -f 'listen=$old_sock' | head -1); [ -n \"\$p\" ] && [ \"\$p\" != '$old_fzf' ]"
new_fzf=$(pgrep -f "listen=$old_sock" | head -1)
check "update: the dashboard restarted itself on the new code" sh -c "[ -n '$new_fzf' ] && [ '$new_fzf' != '$old_fzf' ]"
assert_eq "$dash" "$(role_pane dashboard)" "update: same pane"
tm respawn-pane -k -t "$dash" -- "$AH" dash --hq
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"

# A hub from an older agent-hub (dashboard + orchestrator Claude) is left as it is.
orch=$(tm split-window -d -P -F '#{pane_id}' -t "$dash" "sleep 300")
tm set -p -t "$orch" @agent_hub_role orchestrator
"$AH" hq >/dev/null 2>&1
assert_eq "dashboard orchestrator" "$(roles)" "hq: an old orchestrator pane is left alone"
tm kill-pane -t "$orch"

# A missing dashboard is re-created (the session and its other windows stay).
tm new-window -d -t =hub: -n extra "sleep 300"
tm kill-pane -t "$(role_pane dashboard)"
"$AH" hq >/dev/null 2>&1
assert_eq "dashboard" "$(roles)" "hq: missing dashboard re-created"
check "hq: the other window stays" sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =hub -F '#{window_name}' | grep -qx extra"
tm kill-window -t =hub:extra

# A tmux-resurrect restore: same session and window names, plain shells, no options.
tm kill-session -t =hub
tm new-session -d -s hub -n hub -c "$TMP" "/bin/bash --noprofile --norc"
tm split-window -t =hub:hub -c "$TMP" "/bin/bash --noprofile --norc"
tm new-window -d -t =hub: -n busy "sleep 300"
client=$(start_client hub)
check "restore: client attached to the restored hub" [ "$(client_session "$client")" = hub ]
old=$(tm list-windows -t =hub -F '#{window_id} #{window_name}' | awk '$2 == "hub" { print $1 }')
"$AH" hq >/dev/null 2>&1
assert_eq "dashboard" "$(roles)" "restore: hub rebuilt"
check "restore: the stale window is gone" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =hub -F '#{window_id}' | grep -qx '$old'"
check "restore: a busy window is kept" sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =hub -F '#{window_name}' | grep -qx busy"
assert_eq "hub" "$(client_session "$client")" "restore: the client stays attached"

# heal (the tmux-resurrect hook): repairs a hub that exists, never creates one.
tm kill-pane -t "$(role_pane dashboard)"
"$AH" heal; rc=$?
assert_eq 0 "$rc" "heal: exit 0"
assert_eq "dashboard" "$(roles)" "heal: hub repaired"
tm kill-session -t =hub
"$AH" heal >/dev/null 2>&1
check "heal: no hub is created" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =hub 2>/dev/null"

finish
