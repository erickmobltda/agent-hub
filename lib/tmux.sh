# shellcheck shell=bash
# tmux integration, applied to the running server by `agent-hub tmux-init` (from the one line
# install.sh adds to ~/.tmux.conf): the popup key, the status segment and the tmux-resurrect
# hook. Global options touched: only @agent_hub_* ones, status-right (one segment appended) and,
# when unset, @resurrect-hook-post-restore-all. Must stay silent: run-shell displays any output.

# Agents in <state> anywhere, counted by tmux itself while drawing the status line (no process).
status_count() {
  printf '#{n:#{S:#{W:#{P:#{?#{&&:#{==:#{@agent_status},%s},#{!=:#{@agent_hub_role},orchestrator}},x,}}}}}' "$1"
}

status_format() {
  local s c
  for s in 'waiting ◐ yellow' 'error ✗ red' 'done ✓ cyan' 'working ● green'; do
    set -- $s
    c=$(status_count "$1")
    printf '#{?#{!=:%s,0},#[fg=%s]%s%s#[default] ,}' "$c" "$3" "$2" "$c"
  done
}

STATUS_SEG=' #{E:@agent_hub_status}'

hub_key_spec() { # "table key" for hub_key, nothing when off
  case "$cfg_hub_key" in
    off|'') ;;
    prefix:*) printf 'prefix %s\n' "${cfg_hub_key#prefix:}" ;;
    *) printf 'root %s\n' "$cfg_hub_key" ;;
  esac
}

binding_is_ours() { case "$1" in *agent-hub*|*@agent_hub*) return 0 ;; esac; return 1; }

tmux_unbind_ours() { # tmux_unbind_ours <table> <key>
  local cur
  cur=$(t list-keys -T "$1" "$2" 2>/dev/null)
  binding_is_ours "$cur" && t unbind -T "$1" "$2"
  return 0
}

tmux_bind_hub_key() {
  local spec prev table key cur
  spec=$(hub_key_spec)
  prev=$(t show -gqv @agent_hub_key)
  if [ -n "$prev" ] && [ "$prev" != "$spec" ]; then
    tmux_unbind_ours "${prev%% *}" "${prev#* }"
    t set -gu @agent_hub_key
  fi
  [ -n "$spec" ] || return 0
  table=${spec%% *}; key=${spec#* }
  if [ "$table" = root ]; then
    # The prefix key itself in the root table would make tmux unusable.
    case "$key" in "$(t show -gv prefix)"|"$(t show -gv prefix2)") return 0 ;; esac
  fi
  cur=$(t list-keys -T "$table" "$key" 2>/dev/null)
  [ -z "$cur" ] || binding_is_ours "$cur" || return 0 # someone else's binding: leave it
  t bind -T "$table" "$key" display-popup -E -w 90% -h 85% -d '#{pane_current_path}' -T ' agent-hub ' \
    "$(ah_bin)" dash --popup || return 0
  t set -g @agent_hub_key "$spec"
}

# status_right_without_ours <value>: drops our segment and the v1 `#(… status-bar)` one.
status_right_without_ours() {
  printf '%s' "${1//"$STATUS_SEG"/}" | sed -E 's/#\([^)]*agent-hub[^)]*status-bar\)//g'
}

tmux_status_apply() {
  local sr new
  t set -g @agent_hub_status "$(status_format)"
  sr=$(t show -gv status-right 2>/dev/null)
  new=$(status_right_without_ours "$sr")
  [ "$cfg_status_bar" = on ] && new="$new$STATUS_SEG"
  [ "$new" = "$sr" ] || t set -g status-right "$new"
}

resurrect_hook_cmd() { printf '%s heal >/dev/null 2>&1\n' "$(printf '%q' "$(ah_bin)")"; }

tmux_resurrect_hook() { # repair the hub after each tmux-resurrect restore, unless taken
  local cur want
  want=$(resurrect_hook_cmd)
  cur=$(t show -gqv @resurrect-hook-post-restore-all)
  [ -z "$cur" ] && t set -g @resurrect-hook-post-restore-all "$want"
  return 0
}

cmd_tmux_init() {
  config_load || true
  t show -gv prefix >/dev/null 2>&1 || return 0 # no tmux server
  tmux_bind_hub_key
  tmux_status_apply
  tmux_resurrect_hook
  return 0
}

cmd_tmux_uninit() {
  local spec sr new
  config_load || true
  t show -gv prefix >/dev/null 2>&1 || return 0
  spec=$(t show -gqv @agent_hub_key)
  [ -n "$spec" ] && tmux_unbind_ours "${spec%% *}" "${spec#* }"
  tmux_unbind_ours root C-q # v1 binding
  t set -gu @agent_hub_key
  sr=$(t show -gv status-right 2>/dev/null)
  new=$(status_right_without_ours "$sr")
  [ "$new" = "$sr" ] || t set -g status-right "$new"
  t set -gu @agent_hub_status
  [ "$(t show -gqv @resurrect-hook-post-restore-all)" = "$(resurrect_hook_cmd)" ] &&
    t set -gu @resurrect-hook-post-restore-all
  return 0
}
