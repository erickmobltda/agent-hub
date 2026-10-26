#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
mkdir -p "$TMP/repos"
write_config "repos_roots=$TMP/repos" "worktree_location=sibling" "hq_session=hub" "github=off"
roles() { tm list-panes -s -t =hub -F '#{@agent_hub_role}' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//'; }
role_pane() { tm list-panes -s -t =hub -F '#{@agent_hub_role} #{pane_id}' | awk -v r="$1" '$1 == r { print $2; exit }'; }
orch_starts() { grep -c '^<hub>$' "$CLAUDE_STUB_LOG" 2>/dev/null || echo 0; }

# Fresh hub.
out=$("$AH" hq 2>&1); rc=$?
assert_eq 0 "$rc" "hq: exit 0 without a terminal"
assert_eq "dashboard orchestrator" "$(roles)" "hq: dashboard and orchestrator panes"
heights=$(tm list-panes -t =hub: -F '#{pane_height}' | tr '\n' ' ')
h1=${heights%% *}; h2=$(echo "$heights" | cut -d' ' -f2)
pct=$((h1 * 100 / (h1 + h2 + 1)))
[ "$pct" -ge 60 ] && [ "$pct" -le 70 ] && ok "hq: dashboard ~65% ($pct%)" || fail "hq: dashboard ~65%" "$heights"
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1" && ok "hq: dashboard running" || fail "hq: dashboard running"
wait_for 5 grep -qx '<hub>' "$CLAUDE_STUB_LOG"
check "hq: orchestrator gets its role as a system prompt (no first turn)" grep -qx '<--append-system-prompt>' "$CLAUDE_STUB_LOG"
orch=$(role_pane orchestrator)
assert_eq "$TMP/repos" "$(tm display -p -t "$orch" '#{pane_current_path}')" "hq: orchestrator cwd = first repos_root"
"$AH" hq >/dev/null 2>&1
assert_eq "2" "$(tm list-panes -s -t =hub | wc -l | tr -d ' ')" "hq: idempotent"

# The hub pane survives Ctrl-C and even fzf dying.
dash=$(role_pane dashboard)
sock=$(dash_sock hq)
tm send-keys -t "$dash" C-c; sleep 0.5
check "hq: Ctrl-C leaves the dashboard open" [ -S "$sock" ]
pkill -f "fzf.*$(basename "$sock")" 2>/dev/null
wait_for 5 sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
check "hq: the dashboard comes back when fzf dies" sh -c "ls '$AGENT_HUB_RUNTIME'/dash-hq-*.sock >/dev/null 2>&1"
assert_eq "$dash" "$(role_pane dashboard)" "hq: same pane"

# Missing pieces are re-created.
tm kill-pane -t "$(role_pane orchestrator)"
"$AH" hq >/dev/null 2>&1
assert_eq "dashboard orchestrator" "$(roles)" "hq: missing orchestrator re-added"
tm kill-pane -t "$(role_pane dashboard)"
"$AH" hq >/dev/null 2>&1
assert_eq "dashboard orchestrator" "$(roles)" "hq: missing dashboard re-added"
check "hq: dashboard back on top" [ "$(tm list-panes -t =hub: -F '#{@agent_hub_role}' | head -1)" = dashboard ]

# An orchestrator that exited (pane back at a shell) is restarted.
orch=$(role_pane orchestrator); n=$(orch_starts)
tm send-keys -t "$orch" C-d
wait_for 5 sh -c "[ \"\$(tmux -L $AGENT_HUB_TMUX_SOCKET show -pqv -t $orch @agent_status)\" = stopped ]"
"$AH" hq >/dev/null 2>&1
wait_for 5 sh -c "[ \$(grep -c '^<hub>\$' '$CLAUDE_STUB_LOG') -gt $n ]"
check "hq: stopped orchestrator restarted" [ "$(orch_starts)" -gt "$n" ]

# A tmux-resurrect restore: same session and window names, plain shells, no options.
tm kill-session -t =hub
tm new-session -d -s hub -n hub -c "$TMP" "/bin/bash --noprofile --norc"
tm split-window -t =hub:hub -c "$TMP" "/bin/bash --noprofile --norc"
tm new-window -d -t =hub: -n busy "sleep 300"
client=$(start_client hub)
check "restore: client attached to the restored hub" [ "$(client_session "$client")" = hub ]
old=$(tm list-windows -t =hub -F '#{window_id} #{window_name}' | awk '$2 == "hub" { print $1 }')
"$AH" hq >/dev/null 2>&1
assert_eq "dashboard orchestrator" "$(roles)" "restore: hub rebuilt"
check "restore: the stale window is gone" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =hub -F '#{window_id}' | grep -qx '$old'"
check "restore: a busy window is kept" sh -c "tmux -L $AGENT_HUB_TMUX_SOCKET list-windows -t =hub -F '#{window_name}' | grep -qx busy"
assert_eq "hub" "$(client_session "$client")" "restore: the client stays attached"

# heal (the tmux-resurrect hook): repairs a hub that exists, never creates one.
tm kill-pane -t "$(role_pane orchestrator)"; tm kill-pane -t "$(role_pane dashboard)" 2>/dev/null
"$AH" heal; rc=$?
assert_eq 0 "$rc" "heal: exit 0"
assert_eq "dashboard orchestrator" "$(roles)" "heal: hub repaired"
tm kill-session -t =hub
"$AH" heal >/dev/null 2>&1
check "heal: no hub is created" sh -c "! tmux -L $AGENT_HUB_TMUX_SOCKET has-session -t =hub 2>/dev/null"

finish
