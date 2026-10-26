#!/bin/bash
# Claude Code hook -> tmux pane options @agent_status / @agent_since (SPEC §8).
# Must be fast and never fail: always exits 0, no-op outside tmux.
# Uses plain `tmux`, which talks to the server named by $TMUX (inherited from the pane).

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

fields=$(jq -r '[.hook_event_name // "", .tool_name // "", .notification_type // ""] | join("|")' 2>/dev/null) || exit 0
event=${fields%%|*}; rest=${fields#*|}
tool=${rest%%|*}; ntype=${rest#*|}
[ -n "$event" ] || event=${1:-}

case "$event" in
  UserPromptSubmit|PostToolUse) state=working ;;
  PreToolUse)
    case "$tool" in AskUserQuestion|ExitPlanMode) state=waiting ;; *) state=working ;; esac ;;
  PermissionRequest) state=waiting ;;
  Notification)
    case "$ntype" in permission_prompt|elicitation_dialog|agent_needs_input) state=waiting ;; *) exit 0 ;; esac ;;
  Stop|StopFailure) state=done ;;
  SessionEnd) state="" ;;
  *) exit 0 ;;
esac

cur=$(tmux show -pqv -t "$TMUX_PANE" @agent_status 2>/dev/null)
[ "$cur" = "$state" ] && exit 0

if [ -z "$state" ]; then
  tmux set -pu -t "$TMUX_PANE" @agent_status \; set -pu -t "$TMUX_PANE" @agent_since >/dev/null 2>&1
else
  tmux set -p -t "$TMUX_PANE" @agent_status "$state" \; \
       set -p -t "$TMUX_PANE" @agent_since "$(date +%s)" >/dev/null 2>&1
fi

# Wake any open dashboard (fzf --listen sockets). Detached so the hook returns now.
run_dir=${AGENT_HUB_RUNTIME:-${TMPDIR:-/tmp}/agent-hub}
for sock in "$run_dir"/*.sock; do
  [ -S "$sock" ] || continue
  curl -s -m 1 --unix-socket "$sock" -XPOST http://localhost -d 'reload("$AGENT_HUB_BIN" dash --lines)+refresh-preview' \
    </dev/null >/dev/null 2>&1 &
done
exit 0
