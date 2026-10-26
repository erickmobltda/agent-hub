#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
pane=$(tm display -p -t scratch '#{pane_id}')
st() { tm show -pqv -t "$pane" @agent_status; }
since() { tm show -pqv -t "$pane" @agent_since; }

# No-op outside tmux.
printf '{"hook_event_name":"Stop"}' | env -u TMUX_PANE bash "$ROOT/hooks/status-hook.sh"; rc=$?
assert_eq 0 "$rc" "no TMUX_PANE: exit 0"
assert_eq "" "$(st)" "no TMUX_PANE: nothing written"

# Garbage stdin.
fire_hook "$pane" 'not json{'; rc=$?
assert_eq 0 "$rc" "invalid json: exit 0"
assert_eq "" "$(st)" "invalid json: nothing written"

fire_hook "$pane" '{"hook_event_name":"UserPromptSubmit"}'
assert_eq working "$(st)" "UserPromptSubmit -> working"
assert_contains "$(since)" "1" "agent_since set"

tm set -p -t "$pane" @agent_since 123
fire_hook "$pane" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
assert_eq 123 "$(since)" "same state keeps agent_since"

fire_hook "$pane" '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}'
assert_eq waiting "$(st)" "PermissionRequest -> waiting"
assert_not_contains "$(since)" "123" "state change updates agent_since"

fire_hook "$pane" '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
assert_eq working "$(st)" "PostToolUse -> working"

fire_hook "$pane" '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
assert_eq waiting "$(st)" "PreToolUse AskUserQuestion -> waiting"

fire_hook "$pane" '{"hook_event_name":"Stop"}'
assert_eq done "$(st)" "Stop -> done"

fire_hook "$pane" '{"hook_event_name":"Notification","notification_type":"idle_prompt"}'
assert_eq done "$(st)" "idle_prompt ignored"

fire_hook "$pane" '{"hook_event_name":"Notification","notification_type":"permission_prompt"}'
assert_eq waiting "$(st)" "Notification permission_prompt -> waiting"

fire_hook "$pane" '{"hook_event_name":"StopFailure","error":"rate_limit"}'
assert_eq done "$(st)" "StopFailure -> done"

fire_hook "$pane" '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}'
assert_eq "" "$(st)" "SessionEnd clears status"
assert_eq "" "$(since)" "SessionEnd clears since"

# Unknown event is ignored.
fire_hook "$pane" '{"hook_event_name":"PreCompact"}'; rc=$?
assert_eq 0 "$rc" "unknown event: exit 0"
assert_eq "" "$(st)" "unknown event: nothing written"

# Speed: well under the 1.5s SessionEnd budget.
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
fire_hook "$pane" '{"hook_event_name":"UserPromptSubmit"}'
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
[ $((end - start)) -lt 500 ] && ok "hook runs in $((end - start))ms" || fail "hook too slow: $((end - start))ms"

finish
