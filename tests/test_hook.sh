#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
pane=$(tm display -p -t scratch '#{pane_id}')
st() { pane_opt "$pane" @agent_status; }
since() { pane_opt "$pane" @agent_since; }

# No-op outside tmux, and silent.
out=$(printf '{"hook_event_name":"Stop"}' | env -u TMUX_PANE bash "$ROOT/hooks/status-hook.sh"); rc=$?
assert_eq 0 "$rc" "no TMUX_PANE: exit 0"
assert_eq "" "$(st)" "no TMUX_PANE: nothing written"

out=$(fire_hook "$pane" 'not json{'); rc=$?
assert_eq 0 "$rc" "invalid json: exit 0"
assert_eq "" "$(st)" "invalid json: nothing written"

# Every event, with stdout checked: Claude adds SessionStart/UserPromptSubmit output to its context.
ev() { # ev <json> <expected state> <name>
  local out
  out=$(fire_hook "$pane" "$1" 2>&1)
  assert_eq "$2" "$(st)" "$3"
  [ -z "$out" ] || fail "$3: hook printed output" "$out"
}
ev '{"hook_event_name":"SessionStart","source":"startup"}' idle "SessionStart -> idle"
ev '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' working "UserPromptSubmit -> working"
check "agent_since set" [ -n "$(since)" ]
tm set -p -t "$pane" @agent_since 123
ev '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' working "PostToolUse -> working"
assert_eq 123 "$(since)" "same state keeps agent_since"
ev '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' waiting "PermissionRequest -> waiting"
assert_eq "Bash" "$(pane_opt "$pane" @agent_note)" "waiting note = tool"
check "state change updates agent_since" [ "$(since)" != 123 ]
ev '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' working "PostToolUse clears waiting"
assert_eq "" "$(pane_opt "$pane" @agent_note)" "note cleared"
ev '{"hook_event_name":"PreToolUse","tool_name":"Read"}' working "PreToolUse of another tool: unchanged"
ev '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' waiting "PreToolUse AskUserQuestion -> waiting"
ev '{"hook_event_name":"Stop"}' done "Stop -> done"
ev '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' done "idle_prompt ignored"
ev '{"hook_event_name":"Notification","notification_type":"permission_prompt"}' waiting "Notification permission_prompt -> waiting"
ev '{"hook_event_name":"StopFailure","error":"rate_limit"}' error "StopFailure -> error"
ev '{"hook_event_name":"SessionStart","source":"compact"}' error "SessionStart compact ignored"
ev '{"hook_event_name":"SessionEnd","reason":"clear"}' error "SessionEnd clear ignored (/clear)"
ev '{"hook_event_name":"SessionEnd","reason":"resume"}' error "SessionEnd resume ignored"
ev '{"hook_event_name":"PreCompact"}' error "unknown event ignored"

# Exit: an agent-hub pane stays listed as stopped; Claude started by hand disappears.
ev '{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}' "" "SessionEnd of an ad-hoc pane clears it"
assert_eq "" "$(since)" "ad-hoc: since cleared"
tm set -p -t "$pane" @agent_hub_role claude
ev '{"hook_event_name":"SessionStart","source":"startup"}' idle "agent pane: SessionStart -> idle"
ev '{"hook_event_name":"SessionEnd","reason":"other"}' stopped "agent pane: SessionEnd -> stopped"

# The command install.sh registers survives a broken script (exit 2 would block tool calls).
. "$ROOT/lib/common.sh"; . "$ROOT/lib/install.sh"
cmd=$(hook_command "$TMP/fakeroot")
mkdir -p "$TMP/fakeroot/hooks" && printf 'if then fi (\nexit 2\n' > "$TMP/fakeroot/hooks/status-hook.sh"
/bin/bash "$TMP/fakeroot/hooks/status-hook.sh" </dev/null >/dev/null 2>&1; assert_eq 2 "$?" "a broken hook script exits 2"
printf '{"hook_event_name":"Stop"}' | TMUX_PANE="$pane" /bin/sh -c "$cmd" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "settings command exits 0 even with a broken script"

# Speed: well under the 1.5s SessionEnd budget.
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
fire_hook "$pane" '{"hook_event_name":"UserPromptSubmit"}'
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
[ $((end - start)) -lt 500 ] && ok "hook runs in $((end - start))ms" || fail "hook too slow: $((end - start))ms"

# Claude Code runs no hook when the user interrupts a turn: "working" with no output in the window
# for a while is idle (shown so, and the pane option corrected). Output keeps it working.
tm new-window -d -t scratch: -n quiet "sleep 60"
tm new-window -d -t scratch: -n busy "while :; do echo tick; sleep 0.3; done"
q=$(tm list-panes -t scratch:quiet -F '#{pane_id}'); b=$(tm list-panes -t scratch:busy -F '#{pane_id}')
tm set -p -t "$q" @agent_status working \; set -p -t "$b" @agent_status working
sleep 3
out=$(AGENT_HUB_STUCK_AFTER=2 "$AH" list)
assert_eq "idle" "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "quiet" { print $4 }')" "interrupted: working with no output -> idle"
assert_eq "working" "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "busy" { print $4 }')" "interrupted: an agent with output stays working"
assert_eq "idle" "$(pane_opt "$q" @agent_status)" "interrupted: the pane option is corrected (status bar too)"

finish
