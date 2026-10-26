# shellcheck shell=bash
# The hub session: dashboard on top (~65%), orchestrator Claude below. It repairs itself: after a
# tmux-resurrect restore its panes come back as plain shells, so every entry point checks them.

hq_cwd() {
  local c=${cfg_repos_roots%%:*}
  [ -d "$c" ] || c=$HOME
  printf '%s\n' "$c"
}

hq_add_orchestrator() { # hq_add_orchestrator <dashboard pane>: splits the orchestrator below it
  local orch
  orch=$(t split-window -d -P -F '#{pane_id}' -v -t "$1" -l 35% -c "$(hq_cwd)" -- "$(ah_bin)" run orchestrator hub) || return 1
  t set -p -t "$orch" @agent_hub_role orchestrator
}

hq_build() { # hq_build <session|window>: a fresh hub window; prints its dashboard pane
  local top
  if [ "$1" = session ]; then
    top=$(t new-session -d -P -F '#{pane_id}' -s "$cfg_hq_session" -n hub -c "$(hq_cwd)" -- "$(ah_bin)" dash --hq) || return 1
  else
    top=$(t new-window -d -P -F '#{pane_id}' -t "=$cfg_hq_session:" -n hub -c "$(hq_cwd)" -- "$(ah_bin)" dash --hq) || return 1
  fi
  t set -w -t "$top" automatic-rename off \; set -p -t "$top" @agent_hub_role dashboard
  hq_add_orchestrator "$top"
  printf '%s\n' "$top"
}

# Creates the hub, or repairs it: a missing dashboard or orchestrator pane is re-created, an
# orchestrator back at its shell is restarted, and when neither pane exists (a tmux restore) a new
# hub window replaces the windows that only hold idle shells. The session (and its clients) stay.
ensure_hq() {
  local hq=$cfg_hq_session panes dash orch line top w
  lock_take hq 50 || return 0
  if ! t has-session -t "=$hq" 2>/dev/null; then
    hq_build session >/dev/null
    lock_drop hq
    return 0
  fi
  panes=$(t list-panes -s -t "=$hq" -F "#{window_id}$US#{pane_id}$US#{@agent_hub_role}$US#{@agent_status}$US#{pane_current_command}$US#{pane_dead}")
  dash=$(printf '%s\n' "$panes" | awk -F"$US" '$3 == "dashboard" && $6 != "1" { print $2; exit }')
  line=$(printf '%s\n' "$panes" | awk -F"$US" '$3 == "orchestrator" { print; exit }')
  orch=""
  [ -n "$line" ] && orch=$(printf '%s' "$line" | cut -d"$US" -f2)

  if [ -z "$dash" ] && [ -z "$orch" ]; then
    top=$(hq_build window)
    # Windows whose panes are all dead or idle shells are leftovers of the broken hub.
    for w in $(printf '%s\n' "$panes" | cut -d"$US" -f1 | sort -u); do
      printf '%s\n' "$panes" | awk -F"$US" -v w="$w" '$1 == w' | {
        busy=0
        while IFS=$US read -r _ _ _ st cmd dead; do
          pane_is_idle "$st" "$cmd" "$dead" || busy=1
        done
        [ "$busy" = 0 ]
      } && t kill-window -t "$w"
    done
    t select-window -t "$top"
  elif [ -z "$dash" ]; then
    top=$(t split-window -d -b -P -F '#{pane_id}' -v -t "$orch" -l 65% -c "$(hq_cwd)" -- "$(ah_bin)" dash --hq)
    t set -p -t "$top" @agent_hub_role dashboard
  elif [ -z "$orch" ]; then
    hq_add_orchestrator "$dash"
  else
    IFS=$US read -r _ _ _ st cmd dead <<EOF
$line
EOF
    if pane_is_idle "$st" "$cmd" "$dead"; then
      t respawn-pane -k -t "$orch" -c "$(hq_cwd)" -- "$(ah_bin)" run orchestrator hub
    fi
  fi
  lock_drop hq
}

# `agent-hub` (or `agent-hub hq`): open the hub, creating or repairing it first.
cmd_hub() {
  config_load || true
  ensure_hq
  adopt_tasks
  if [ -n "${TMUX:-}" ]; then
    t switch-client -t "=$cfg_hq_session:"
  elif [ -t 0 ] && [ -t 1 ]; then
    t attach-session -t "=$cfg_hq_session:"
  else
    echo "session $cfg_hq_session ready (attach with: tmux attach -t $cfg_hq_session)"
  fi
}

# Run by tmux-resurrect after a restore (see tmux-init): fix the hub if it came back, adopt tasks.
cmd_heal() {
  config_load || return 0
  adopt_tasks
  t has-session -t "=$cfg_hq_session" 2>/dev/null && ensure_hq
  return 0
}
