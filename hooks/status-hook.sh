#!/bin/bash
# Claude Code hook -> tmux pane options @agent_status / @agent_since / @agent_note.
# Must be fast and silent: always exits 0, no-op outside tmux, and prints nothing (Claude adds
# the stdout of SessionStart/UserPromptSubmit hooks to its context).
# Uses plain `tmux`, which talks to the server named by $TMUX (inherited from the pane).
exec >/dev/null 2>&1

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v jq || exit 0

US=$(printf '\037')
fields=$(jq -r '[.hook_event_name, .tool_name, .notification_type, .source, .reason]
  | map(. // "" | tostring) | join("\u001f")') || exit 0
IFS=$US read -r event tool ntype source reason <<EOF
$fields
EOF
[ -n "$event" ] || event=${1:-}

note=""
case "$event" in
  SessionStart) [ "$source" = compact ] && exit 0; state=idle ;;
  UserPromptSubmit|PostToolUse) state=working ;;
  PreToolUse)
    case "$tool" in AskUserQuestion|ExitPlanMode) state=waiting; note=$tool ;; *) state=working ;; esac ;;
  PermissionRequest) state=waiting; note=${tool:-permission} ;;
  Notification)
    case "$ntype" in permission_prompt|elicitation_dialog|agent_needs_input) state=waiting; note=$ntype ;; *) exit 0 ;; esac ;;
  Stop) state=done ;;
  StopFailure) state=error ;;
  SessionEnd) case "$reason" in clear|resume) exit 0 ;; esac; state=stopped ;;
  *) exit 0 ;;
esac

cur=$(tmux display -p -t "$TMUX_PANE" "#{@agent_status}$US#{@agent_hub_role}") || exit 0
cur_state=${cur%%"$US"*}
role=${cur#*"$US"}
[ "$cur_state" = "$state" ] && exit 0

if [ "$state" = stopped ] && [ -z "$role" ]; then
  # Claude started by hand in some pane: it leaves the hub when it exits.
  tmux set -pu -t "$TMUX_PANE" @agent_status \; set -pu -t "$TMUX_PANE" @agent_since \; \
       set -pu -t "$TMUX_PANE" @agent_note
else
  tmux set -p -t "$TMUX_PANE" @agent_status "$state" \; set -p -t "$TMUX_PANE" @agent_since "$(date +%s)" \; \
       set -p -t "$TMUX_PANE" @agent_note "$note"
fi

# Wake the open dashboards (fzf --listen sockets). Detached so the hook returns now.
for sock in "${AGENT_HUB_RUNTIME:-${TMPDIR:-/tmp}/agent-hub}"/dash-*.sock; do
  [ -S "$sock" ] || continue
  curl -s -m 1 --unix-socket "$sock" -XPOST http://localhost -d 'trigger(ctrl-r)' </dev/null &
done
exit 0
