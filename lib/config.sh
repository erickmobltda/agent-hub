# shellcheck shell=bash
# setup and config get|set|show (SPEC §5).

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
      [ -n "$2" ] || die "$EX_ERR" "base_branch cannot be empty" ;;
    worktree_location)
      case "$2" in sibling|subdirectory|/*) ;; *) die "$EX_ERR" "worktree_location must be sibling, subdirectory or an absolute path" ;; esac ;;
    claude_pane_pct)
      case "$2" in ''|*[!0-9]*) die "$EX_ERR" "claude_pane_pct must be an integer" ;; esac
      [ "$2" -ge 10 ] && [ "$2" -le 90 ] || die "$EX_ERR" "claude_pane_pct must be between 10 and 90" ;;
    hq_session)
      case "$2" in ''|*[:.]*) die "$EX_ERR" "hq_session cannot be empty or contain : or ." ;; esac ;;
    *) die "$EX_ERR" "unknown config key: $1 (keys: $CONFIG_KEYS)" ;;
  esac
}

# Folders under ~ (depth <= 3) holding at least 3 git repos. Skips dotdirs and
# the macOS privacy-protected folders (avoids TCC permission prompts).
setup_suggest_roots() {
  find "$HOME" -maxdepth 5 \( -path "$HOME/Library" -o -path "$HOME/.*" -o -path "$HOME/Desktop" \
    -o -path "$HOME/Documents" -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" \
    -o -path "$HOME/Movies" -o -path "$HOME/Music" \) -prune \
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
      fzf --height=~12 --layout=reverse --no-sort --info=hidden --delimiter='\t' --with-nth=2 \
          --header="$q" --header-first --prompt='arrows + enter > ' --accept-nth=1) ||
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
  config_save
  [ "$loc" = subdirectory ] && warn "subdirectory: add .worktrees/ to each repo's .gitignore (agent-hub does not edit it)"
  echo "saved $(config_file)"
}

cmd_config() {
  local sub=${1:-show}
  [ $# -gt 0 ] && shift
  case "$sub" in
    show)
      config_load || die "$EX_ERR" "config not found ($(config_file)); run: agent-hub setup"
      local k v
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
      config_save
      echo "$1=$2" ;;
    *) die "$EX_ERR" "usage: config get|set|show" ;;
  esac
}
