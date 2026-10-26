# shellcheck shell=bash
# hq: hub session — dashboard on top (~65%), orchestrator Claude below (SPEC §9).

cmd_hq() {
  config_load || true
  local hq=$cfg_hq_session cwd bin top
  cwd=${cfg_repos_roots%%:*}
  [ -d "$cwd" ] || cwd=$HOME
  bin=$(printf '%q' "$AGENT_HUB_HOME/bin/agent-hub")

  if ! t has-session -t "=$hq" 2>/dev/null; then
    top=$(t new-session -d -P -F '#{pane_id}' -s "$hq" -n hub -c "$cwd" \
      "while :; do $bin dash; sleep 1; done") || die "$EX_ERR" "could not create session $hq"
    t set -w -t "$top" automatic-rename off
    local orch
    orch=$(t split-window -d -P -F '#{pane_id}' -v -t "$top" -l 35% -c "$cwd")
    t set -p -t "$orch" @agent_hub_role orchestrator
    # Start with the skill invoked so this Claude acts as the orchestrator from the first message.
    t send-keys -t "$orch" -l "claude /agent-hub"
    t send-keys -t "$orch" Enter
    t select-pane -t "$top"
  fi

  if [ -n "${TMUX:-}" ]; then
    t switch-client -t "=$hq:"
  elif [ -t 1 ]; then
    t attach-session -t "=$hq:"
  else
    echo "session $hq ready (attach with: tmux attach -t $hq)"
  fi
}
