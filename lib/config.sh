# shellcheck shell=bash
# setup and config show|get|set|edit.

config_validate() { # config_validate <key> <value>
  case "$1" in
    repos_roots)
      [ -n "$2" ] || die "$EX_ERR" "repos_roots cannot be empty"
      local IFS=: d
      for d in $2; do
        [ -d "$d" ] || die "$EX_ERR" "repos_roots: not a directory: $d"
        [ -e "$d/.git" ] && die "$EX_ERR" "repos_roots: $d is a repo itself; use the folder that contains your repos"
      done ;;
    branch_prefix)
      case "$2" in *' '*|*'..'*|*'~'*|*'^'*|*':'*) die "$EX_ERR" "branch_prefix: invalid characters: $2" ;; esac ;;
    base_branch)
      case "$2" in *' '*|*'..'*|*'~'*|*'^'*|*':'*) die "$EX_ERR" "base_branch: invalid characters: $2" ;; esac ;;
    worktree_location)
      case "$2" in sibling|subdirectory|/*) ;; *) die "$EX_ERR" "worktree_location must be sibling, subdirectory or an absolute path" ;; esac ;;
    agent_cmd)
      [ -n "$2" ] || die "$EX_ERR" "agent_cmd cannot be empty" ;;
    claude_pane_pct)
      case "$2" in ''|*[!0-9]*) die "$EX_ERR" "claude_pane_pct must be an integer" ;; esac
      [ "$2" -ge 10 ] && [ "$2" -le 90 ] || die "$EX_ERR" "claude_pane_pct must be between 10 and 90" ;;
    hub_key)
      case "$2" in ''|*' '*|prefix:) die "$EX_ERR" "hub_key must be a tmux key (e.g. C-q), prefix:<key> or off" ;; esac ;;
    status_bar)
      case "$2" in on|off) ;; *) die "$EX_ERR" "status_bar must be on or off" ;; esac ;;
    github)
      case "$2" in auto|off) ;; *) die "$EX_ERR" "github must be auto or off" ;; esac ;;
    hq_session)
      case "$2" in ''|*[:.]*) die "$EX_ERR" "hq_session cannot be empty or contain : or ." ;; esac ;;
    *) die "$EX_ERR" "unknown config key: $1 (keys: $CONFIG_KEYS)" ;;
  esac
}

# Folders under ~ (depth <= 3) holding at least 3 git repos. Skips dotdirs, dependency folders
# and the macOS privacy-protected folders (avoids TCC permission prompts).
setup_suggest_roots() {
  find "$HOME" -maxdepth 5 \( -path "$HOME/Library" -o -path "$HOME/.*" -o -path "$HOME/Desktop" \
    -o -path "$HOME/Documents" -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" \
    -o -path "$HOME/Movies" -o -path "$HOME/Music" -o -name node_modules \) -prune \
    -o -name .git -print -prune 2>/dev/null |
    sed 's#/[^/]*/\.git$##' | sort | uniq -c | awk '$1 >= 3 { $1=""; sub(/^ /, ""); print }'
}

ASK_OTHER="✎ type another value"

# ask <var> <question> <value<TAB>label>...
# In a terminal: pick with arrows + Enter (fzf); the last entry lets you type a value.
# Without a terminal (pipes, tests): numbered list, answer with a number or a value.
ask() {
  local var=$1 q=$2 i=1 ans="" opt
  shift 2
  if [ -t 0 ] && [ -t 2 ]; then
    ans=$( { for opt in "$@"; do printf '%s\n' "$opt"; done; printf '__other__\t%s\n' "$ASK_OTHER"; } |
      FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= fzf --height=~12 --layout=reverse --no-sort --info=hidden \
          --delimiter='\t' --with-nth=2 --header="$q" --header-first --prompt='arrows + enter > ' --accept-nth=1) ||
      die "$EX_ERR" "setup aborted"
    if [ "$ans" = __other__ ]; then
      echo "$q" >&2
      IFS= read -e -r -p '> ' ans || die "$EX_ERR" "setup aborted"
    fi
  else
    echo "$q" >&2
    for opt in "$@"; do printf '  %d) %s\n' "$i" "${opt#*$TAB}" >&2; i=$((i + 1)); done
    printf '  number or value: ' >&2
    IFS= read -r ans || die "$EX_ERR" "setup aborted"
    case "$ans" in
      ''|*[!0-9]*) ;;
      *) if [ "$ans" -ge 1 ] && [ "$ans" -lt "$i" ]; then
           i=1; for opt in "$@"; do [ "$i" = "$ans" ] && ans=${opt%%$TAB*}; i=$((i + 1)); done
         fi ;;
    esac
  fi
  [ "$ans" = '""' ] && ans=""
  printf -v "$var" '%s' "$ans"
}

expand_home() { # ~/x -> $HOME/x, for each ':'-separated part
  printf '%s\n' "$1" | awk -v h="$HOME" 'BEGIN { RS = ":"; ORS = "" }
    { sub(/\n$/, ""); if ($0 == "~") $0 = h; else if (substr($0, 1, 2) == "~/") $0 = h substr($0, 2)
      printf "%s%s", (NR > 1 ? ":" : ""), $0 }'
}

cmd_setup() {
  config_load || true
  local roots="" prefix="" loc="" have_prefix=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repos-roots) roots=${2:-}; shift 2 ;;
      --branch-prefix) prefix=${2:-}; have_prefix=1; shift 2 ;;
      --worktree-location) loc=${2:-}; shift 2 ;;
      *) die "$EX_ERR" "setup: unknown option $1" ;;
    esac
  done

  if [ -z "$roots" ]; then
    local sugg="" d
    while IFS= read -r d; do
      [ -n "$d" ] && sugg="$sugg$d$TAB$d$(printf '\n')"
    done <<EOF
$(setup_suggest_roots)
EOF
    local IFS='
'
    # shellcheck disable=SC2086
    ask roots "Folder that CONTAINS your repos (e.g. ~/code), not each repo's folder. More than one? separate with ':'" $sugg
    unset IFS
  fi
  [ "$have_prefix" = 1 ] || ask prefix "Branch prefix" \
    "feature/${TAB}feature/  (e.g. feature/my-task)" "feat/${TAB}feat/  (e.g. feat/my-task)" "\"\"${TAB}(none)  (e.g. my-task)"
  [ -n "$loc" ] || ask loc "Where to create worktrees (or type an absolute path: <path>/<repo>/<task>)" \
    "sibling${TAB}sibling       next to the repo: <parent>/<repo>--<task>" \
    "subdirectory${TAB}subdirectory  inside the repo: <repo>/.worktrees/<task> (must be in .gitignore)"
  roots=$(expand_home "$roots")
  loc=$(expand_home "$loc")

  config_validate repos_roots "$roots"
  config_validate branch_prefix "$prefix"
  config_validate worktree_location "$loc"
  cfg_repos_roots=$roots
  cfg_branch_prefix=$prefix
  cfg_worktree_location=$loc
  config_set_line repos_roots "$roots"
  config_set_line branch_prefix "$prefix"
  config_set_line worktree_location "$loc"
  [ "$loc" = subdirectory ] && warn "subdirectory: add .worktrees/ to each repo's .gitignore (agent-hub does not edit it)"
  echo "saved $(config_file)"
}

# Settings that live in tmux are applied to the running server right away.
config_apply_tmux() {
  case "$1" in hub_key|status_bar|hq_session) ;; *) return 0 ;; esac
  t list-sessions >/dev/null 2>&1 && cmd_tmux_init
  return 0
}

cmd_config() {
  local sub=${1:-show} k v
  [ $# -gt 0 ] && shift
  case "$sub" in
    show)
      config_load || die "$EX_ERR" "config not found ($(config_file)); run: agent-hub setup"
      for k in $CONFIG_KEYS; do eval "v=\${cfg_$k}"; printf '%s=%s\n' "$k" "$v"; done ;;
    get)
      [ $# -eq 1 ] || die "$EX_ERR" "usage: config get <key>"
      is_config_key "$1" || die "$EX_ERR" "unknown config key: $1"
      config_load || true
      eval "printf '%s\n' \"\${cfg_$1}\"" ;;
    set)
      [ $# -eq 2 ] || die "$EX_ERR" "usage: config set <key> <value>"
      config_validate "$1" "$2"
      config_load || true
      printf -v "cfg_$1" '%s' "$2"
      config_set_line "$1" "$2"
      config_apply_tmux "$1"
      echo "$1=$2" ;;
    edit)
      local f
      f=$(config_file)
      config_load || true
      [ -f "$f" ] || { mkdir -p "$(dirname "$f")"; config_template > "$f"; }
      ${VISUAL:-${EDITOR:-vi}} "$f" || die "$EX_ERR" "editor failed"
      config_load || true
      for k in $CONFIG_KEYS; do
        eval "v=\${cfg_$k}"
        case "$k" in repos_roots|worktree_location) [ -n "$v" ] || continue ;; esac
        ( config_validate "$k" "$v" ) || die "$EX_ERR" "fix $f and run 'agent-hub config edit' again"
      done
      config_apply_tmux hub_key
      echo "saved $f" ;;
    *) die "$EX_ERR" "usage: config show | get <key> | set <key> <value> | edit" ;;
  esac
}
