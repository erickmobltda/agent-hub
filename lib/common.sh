# shellcheck shell=bash
# Shared helpers. Compatible with bash 3.2 and BSD userland.

EX_OK=0
EX_ERR=1
EX_DEPS=2
EX_PENDING=3
EX_NOTFOUND=4

TAB=$(printf '\t')

CONFIG_KEYS="repos_roots worktree_location branch_prefix base_branch agent_cmd claude_pane_pct hub_key status_bar github hq_session"

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

ah_bin() { printf '%s\n' "$AGENT_HUB_HOME/bin/agent-hub"; }

config_file() { printf '%s\n' "${AGENT_HUB_CONFIG:-$HOME/.config/agent-hub/config}"; }

# Runtime files (dashboard sockets, locks, GitHub cache). The hook computes the same path.
runtime_dir() { # runtime_dir [subdir]
  local d="${AGENT_HUB_RUNTIME:-${TMPDIR:-/tmp}/agent-hub}"
  [ -n "${1:-}" ] && d="$d/$1"
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$d"
}

is_config_key() {
  local k
  for k in $CONFIG_KEYS; do [ "$k" = "$1" ] && return 0; done
  return 1
}

config_defaults() {
  cfg_repos_roots=""
  cfg_worktree_location=""
  cfg_branch_prefix=""
  cfg_base_branch=""
  cfg_agent_cmd="claude"
  cfg_claude_pane_pct="70"
  cfg_hub_key="C-q"
  cfg_status_bar="on"
  cfg_github="auto"
  cfg_hq_session="hq"
}

# Parses the config line by line (never sourced). Sets cfg_<key> variables.
config_load() {
  config_defaults
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

config_doc() { # one-line description of a key (the comments of the config file)
  case "$1" in
    repos_roots) echo "Folder(s) that CONTAIN your git repos (not a repo itself). Several: separate with ':'." ;;
    worktree_location) echo "Where task worktrees go: sibling (<parent>/<repo>--<task>), subdirectory (<repo>/.worktrees/<task>, keep it in .gitignore) or an absolute path (<path>/<repo>/<task>)." ;;
    branch_prefix) echo "Prefix of each task branch, e.g. feat/ gives feat/<task>. May be empty." ;;
    base_branch) echo "Branch new worktrees start from, fetched from origin. Empty: the remote's default branch." ;;
    agent_cmd) echo "Command that starts each agent, e.g. claude --model opus (split on spaces, no quoting)." ;;
    claude_pane_pct) echo "Height (%) of the Claude pane in a task window; a shell pane takes the rest." ;;
    hub_key) echo "tmux key that opens the agent-hub popup: C-q (no prefix needed), prefix:<key> (after the prefix) or off." ;;
    status_bar) echo "Agent counts at the end of the tmux status bar: on or off." ;;
    github) echo "Pull request status through the gh CLI: auto (when gh is logged in) or off." ;;
    hq_session) echo "Name of the hub tmux session." ;;
  esac
}

config_template() { # a full, documented config file from the current cfg_* values
  local k v
  echo "# agent-hub configuration: one key=value per line. It is parsed, never executed."
  echo "# Change it with 'agent-hub config set <key> <value>' or 'agent-hub config edit'."
  for k in $CONFIG_KEYS; do
    eval "v=\${cfg_$k}"
    printf '\n# %s\n%s=%s\n' "$(config_doc "$k")" "$k" "$v"
  done
}

# config_set_line <key> <value>: rewrites only that key's line (appended when absent), so
# comments and the other lines stay as the user left them. A missing file is created documented.
config_set_line() {
  local f tmp
  f=$(config_file)
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || config_template > "$f"
  tmp="$f.tmp.$$"
  K=$1 V=$2 awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    !done && index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$f" > "$tmp" && mv "$tmp" "$f"
}

valid_name() { # group and task names are tmux targets: no ':' '.' or spaces
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
}

is_shell() { # is_shell <pane_current_command>: login shells show up as -zsh
  case "${1#-}" in bash|zsh|sh|fish|dash|ksh|mksh|tcsh|csh|nu|xonsh|elvish) return 0 ;; esac
  return 1
}

# lock_take <name> [tenths of a second to wait]: mkdir lock; a lock whose holder died is taken over.
lock_take() {
  local d n=0 max=${2:-30} pid
  d="$(runtime_dir)/$1.lock"
  while ! mkdir "$d" 2>/dev/null; do
    pid=$(cat "$d/pid" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$d"; continue; fi
    n=$((n + 1))
    [ "$n" -ge "$max" ] && return 1
    sleep 0.1
  done
  echo $$ > "$d/pid"
}

lock_drop() { rm -rf "$(runtime_dir)/$1.lock"; }

confirm() { # confirm <question>  -> 0 on yes
  local ans
  printf '%s [y/N] ' "$1" >&2
  read -r ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; esac
  return 1
}

# Asks every open dashboard to refresh now (fzf --listen sockets); never blocks.
dash_poke() {
  local sock
  for sock in "${AGENT_HUB_RUNTIME:-${TMPDIR:-/tmp}/agent-hub}"/dash-*.sock; do
    [ -S "$sock" ] || continue
    curl -s -m 1 --unix-socket "$sock" -XPOST http://localhost -d 'trigger(ctrl-r)' </dev/null >/dev/null 2>&1 &
  done
}
