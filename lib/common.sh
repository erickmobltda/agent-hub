# shellcheck shell=bash
# Shared helpers. Compatible with bash 3.2 and BSD userland.

EX_OK=0
EX_ERR=1
EX_DEPS=2
EX_PENDING=3
EX_NOTFOUND=4

TAB=$(printf '\t')

CONFIG_KEYS="repos_roots branch_prefix base_branch worktree_location claude_pane_pct hq_session"

die() { # die <code> <message>
  local code=$1; shift
  printf 'agent-hub: %s\n' "$*" >&2
  exit "$code"
}

warn() { printf 'agent-hub: %s\n' "$*" >&2; }

# tmux wrapper; AGENT_HUB_TMUX_SOCKET points every call to an isolated server (tests).
t() {
  if [ -n "${AGENT_HUB_TMUX_SOCKET:-}" ]; then
    tmux -L "$AGENT_HUB_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

config_file() { printf '%s\n' "${AGENT_HUB_CONFIG:-$HOME/.config/agent-hub/config}"; }

is_config_key() {
  local k
  for k in $CONFIG_KEYS; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# Parses the config line by line (never sourced). Sets cfg_<key> variables.
config_load() {
  cfg_repos_roots=""
  cfg_branch_prefix=""
  cfg_base_branch="main"
  cfg_worktree_location=""
  cfg_claude_pane_pct="70"
  cfg_hq_session="hq"
  local f line key val
  f=$(config_file)
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    is_config_key "$key" || continue
    printf -v "cfg_$key" '%s' "$val"
  done < "$f"
  return 0
}

config_require() {
  config_load || die "$EX_ERR" "config not found ($(config_file)); run: agent-hub setup"
  [ -n "$cfg_repos_roots" ] || die "$EX_ERR" "repos_roots not set; run: agent-hub setup"
  [ -n "$cfg_worktree_location" ] || die "$EX_ERR" "worktree_location not set; run: agent-hub setup"
}

# Writes all cfg_* variables to the config file atomically.
config_save() {
  local f tmp k v
  f=$(config_file)
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  {
    echo "# agent-hub config (key=value, not sourced)"
    for k in $CONFIG_KEYS; do
      eval "v=\${cfg_$k}"
      printf '%s=%s\n' "$k" "$v"
    done
  } > "$tmp" && mv "$tmp" "$f"
}

confirm() { # confirm <question>  -> 0 on yes
  local ans
  printf '%s [y/N] ' "$1" >&2
  read -r ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; esac
  return 1
}
