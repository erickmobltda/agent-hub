#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
write_config "repos_roots=$TMP" "worktree_location=sibling"

assert_eq "" "$("$AH" status-bar)" "status-bar: empty without agents"
assert_contains "$("$AH" dash --lines)" "no agents yet" "dash: placeholder without agents"

# Fake agents: panes with @agent_status (no git needed).
mk() { # mk <group> <task> <status> <since>
  local p
  if tm has-session -t "=$1" 2>/dev/null; then p=$(tm new-window -d -P -F '#{pane_id}' -t "=$1:" -n "$2" -c "$TMP")
  else p=$(tm new-session -d -P -F '#{pane_id}' -s "$1" -n "$2" -c "$TMP"); fi
  tm set -p -t "$p" @agent_status "$3" \; set -p -t "$p" @agent_since "$4"
  echo "$p"
}
now=$(date +%s)
p1=$(mk dev api working $((now - 120)))
p2=$(mk dev docs waiting $((now - 300)))
p3=$(mk ops infra done $((now - 7200)))
mk hq orch waiting "$now" >/dev/null

assert_eq " ⏳1 ✅1 ⚙ 1" "$("$AH" status-bar)" "status-bar: counts by state, hq excluded"

lines=$("$AH" dash --lines)
display=$(printf '%s\n' "$lines" | cut -f3 | sed $'s/\033\\[[0-9;]*m//g' | sed 's/  */ /g')
expected=$(printf '%s\n' "▾ dev (2) ⏳1" " ⏳ docs - 5m" " ⚙ api - 2m" "▾ ops (1)" " ✅ infra - 2h")
assert_eq "$expected" "$display" "dash: grouped, waiting first, elapsed"
assert_eq "G A A G A" "$(printf '%s\n' "$lines" | cut -f1 | tr '\n' ' ' | sed 's/ $//')" "dash: kinds"
assert_eq "$p2" "$(printf '%s\n' "$lines" | sed -n 2p | cut -f2)" "dash: agent target is pane id"

tm send-keys -t "$p1" "echo PREVIEW-MARKER" Enter
wait_for 3 sh -c "\"$AH\" dash --preview A $p1 | grep -q PREVIEW-MARKER"
assert_contains "$("$AH" dash --preview A "$p1")" "PREVIEW-MARKER" "dash: preview captures the pane"
assert_contains "$("$AH" dash --preview G dev)" "docs" "dash: group preview lists agents"

# Real fzf inside the isolated server, driven through its --listen socket.
tm new-window -d -t scratch: -n dash "$AH dash"
sock=""
wait_for 5 sh -c "ls \"$AGENT_HUB_RUNTIME\"/dash-*.sock >/dev/null 2>&1" && sock=$(ls "$AGENT_HUB_RUNTIME"/dash-*.sock | head -1)
[ -S "$sock" ] && ok "dash: fzf listening on unix socket" || fail "dash: fzf listening on unix socket"
state() { curl -s --unix-socket "$sock" "http://localhost?limit=20"; }
assert_eq "5" "$(state | jq '.totalCount')" "dash: fzf shows 5 lines"

# A hook state change must reach the dashboard (push) without user input.
fire_hook "$p3" '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}'
wait_for 3 sh -c "curl -s --unix-socket \"$sock\" http://localhost | grep -q 'ops (1) ⏳1'"
assert_contains "$(state | jq -r '.matches[].text')" "ops (1) ⏳1" "dash: refreshes after hook event"

# Periodic refresh picks up changes made without a hook.
tm set -p -t "$p1" @agent_status done
wait_for 4 sh -c "curl -s --unix-socket \"$sock\" http://localhost | grep -q '✅ api'"
assert_contains "$(state | jq -r '.matches[].text')" "✅ api" "dash: periodic refresh"

# Closing fzf removes the socket and stops the refresh loop.
curl -s --unix-socket "$sock" -XPOST http://localhost -d 'abort' >/dev/null
wait_for 4 sh -c "[ ! -e \"$sock\" ]"
[ ! -e "$sock" ] && ok "dash: socket cleaned on exit" || fail "dash: socket cleaned on exit"

finish
