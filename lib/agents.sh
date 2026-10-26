# shellcheck shell=bash
# new / list / close / move (SPEC §10, §11).

valid_name() { # group and task names are tmux targets: no ':' '.' or spaces
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
}

# resolve_repo <name|path>  -> absolute path of a repo under repos_roots
resolve_repo() {
  local r=$1 IFS=: root found="" n=0
  case "$r" in
    /*) found=$r; n=1 ;;
    *) for root in $cfg_repos_roots; do
         if [ -e "$root/$r/.git" ]; then found="$root/$r"; n=$((n + 1)); fi
       done ;;
  esac
  [ "$n" -gt 1 ] && die "$EX_NOTFOUND" "repo '$r' is ambiguous across repos_roots; pass the full path"
  [ -n "$found" ] && git -C "$found" rev-parse --git-dir >/dev/null 2>&1 ||
    die "$EX_NOTFOUND" "repo not found in repos_roots: $r"
  (cd -P "$found" && pwd)
}

worktree_path() { # worktree_path <repo_path> <task>
  local repo=$1 task=$2
  case "$cfg_worktree_location" in
    sibling) printf '%s/%s--%s\n' "$(dirname "$repo")" "$(basename "$repo")" "$task" ;;
    subdirectory) printf '%s/.worktrees/%s\n' "$repo" "$task" ;;
    *) printf '%s/%s/%s\n' "${cfg_worktree_location%/}" "$(basename "$repo")" "$task" ;;
  esac
}

# window_id <group> <task> -> @id, or exit 4
window_id() {
  local id
  id=$(t list-windows -t "=$1" -F "#{window_name}$TAB#{window_id}" 2>/dev/null | awk -F'\t' -v n="$2" '$1 == n { print $2; exit }')
  [ -n "$id" ] || die "$EX_NOTFOUND" "task not found: $1/$2"
  printf '%s\n' "$id"
}

split_target() { # split_target G/T -> sets tg_group tg_task
  case "$1" in */*) ;; *) die "$EX_ERR" "expected <group>/<task>, got: $1" ;; esac
  tg_group=${1%%/*}
  tg_task=${1#*/}
}

cmd_new() {
  local group="" repo="" task="" prompt="" has_prompt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) group=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --task) task=${2:-}; shift 2 ;;
      --prompt) prompt=${2:-}; has_prompt=1; shift 2 ;;
      *) die "$EX_ERR" "new: unknown option $1" ;;
    esac
  done
  [ -n "$group" ] && [ -n "$repo" ] && [ -n "$task" ] || die "$EX_ERR" "usage: new --group G --repo R --task T [--prompt P]"
  valid_name "$group" || die "$EX_ERR" "invalid group name (use letters, digits, - and _): $group"
  valid_name "$task" || die "$EX_ERR" "invalid task name (use letters, digits, - and _): $task"
  config_require
  [ "$group" != "$cfg_hq_session" ] || die "$EX_ERR" "group cannot be the hub session ($cfg_hq_session)"

  local repo_path wt branch base=$cfg_base_branch
  repo_path=$(resolve_repo "$repo") || exit
  wt=$(worktree_path "$repo_path" "$task")
  branch="$cfg_branch_prefix$task"

  if t has-session -t "=$group" 2>/dev/null &&
     t list-windows -t "=$group" -F '#{window_name}' | grep -qxF "$task"; then
    die "$EX_NOTFOUND" "task '$task' already exists in group '$group'; choose another name"
  fi
  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" &&
    die "$EX_NOTFOUND" "branch already exists: $branch"
  [ -e "$wt" ] && die "$EX_NOTFOUND" "worktree path already exists: $wt"

  git -C "$repo_path" fetch -q origin "$base" || die "$EX_ERR" "git fetch origin $base failed"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo_path" worktree add -q -b "$branch" "$wt" "origin/$base" >/dev/null ||
    die "$EX_ERR" "git worktree add failed"

  local pane
  if t has-session -t "=$group" 2>/dev/null; then
    pane=$(t new-window -d -P -F '#{pane_id}' -t "=$group:" -n "$task" -c "$wt")
  else
    pane=$(t new-session -d -P -F '#{pane_id}' -s "$group" -n "$task" -c "$wt")
  fi
  [ -n "$pane" ] || die "$EX_ERR" "could not create tmux window"
  t set -t "=$group:" @agent_hub 1
  t set -w -t "$pane" automatic-rename off
  t split-window -d -v -t "$pane" -l "$((100 - cfg_claude_pane_pct))%" -c "$wt"
  t set -p -t "$pane" @agent_hub_role claude
  t set -p -t "$pane" @agent_status "$([ "$has_prompt" = 1 ] && echo working || echo done)" \; \
    set -p -t "$pane" @agent_since "$(date +%s)"

  if [ "$has_prompt" = 1 ]; then
    t send-keys -t "$pane" -l "claude $(printf '%q' "$prompt")"
  else
    t send-keys -t "$pane" -l "claude"
  fi
  t send-keys -t "$pane" Enter
  printf 'created %s/%s repo=%s branch=%s worktree=%s\n' "$group" "$task" "$repo_path" "$branch" "$wt"
}

# Raw agent rows: group task status since pane window_id path
list_raw() {
  local hq=${cfg_hq_session:-hq}
  t list-panes -a -F "#{session_name}$TAB#{window_name}$TAB#{@agent_status}$TAB#{@agent_since}$TAB#{pane_id}$TAB#{window_id}$TAB#{pane_current_path}" 2>/dev/null |
    awk -F'\t' -v hq="$hq" '$3 != "" && $1 != hq'
}

# Sorted rows: group task status since repo branch pane window_id path
#   groups with waiting first; inside: waiting > done > working, oldest first.
list_rows() {
  local g task st since pane wid path common repo branch
  list_raw | while IFS="$TAB" read -r g task st since pane wid path; do
    common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    case "$common" in */.git) repo=$(basename "$(dirname "$common")") ;; '') repo="-" ;; *) repo=$(basename "$common" .git) ;; esac
    branch=$(git -C "$path" branch --show-current 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$g" "$task" "$st" "${since:-0}" "$repo" "${branch:--}" "$pane" "$wid" "$path"
  done | awk -F'\t' '
    { rows[NR] = $0; if ($3 == "waiting") hasw[$1] = 1 }
    END {
      for (i = 1; i <= NR; i++) {
        split(rows[i], f, "\t")
        r = (f[3] == "waiting") ? 0 : (f[3] == "done") ? 1 : 2
        printf "%d\t%s\t%d\t%010d\t%s\n", (f[1] in hasw) ? 0 : 1, f[1], r, f[4], rows[i]
      }
    }' | sort -t "$TAB" -k1,1n -k2,2 -k3,3n -k4,4n | cut -f5-
}

cmd_list() {
  local fmt=tsv
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) fmt=${2:-}; shift 2 ;;
      *) die "$EX_ERR" "list: unknown option $1" ;;
    esac
  done
  config_load || true
  case "$fmt" in
    tsv) list_rows ;;
    json) list_rows | jq -R -s 'split("\n") | map(select(. != "") | split("\t") |
            {group: .[0], task: .[1], status: .[2], since: (.[3] | tonumber), repo: .[4],
             branch: .[5], pane: .[6], window: .[7], worktree: .[8]})' ;;
    *) die "$EX_ERR" "list: format must be tsv or json" ;;
  esac
}

# Claude pane of a window (marked at creation), falling back to the first pane.
claude_pane() {
  local p
  p=$(t list-panes -t "$1" -F "#{@agent_hub_role}$TAB#{pane_id}" | awk -F'\t' '$1 == "claude" { print $2; exit }')
  [ -n "$p" ] || p=$(t list-panes -t "$1" -F '#{pane_id}' | head -1)
  printf '%s\n' "$p"
}

cmd_close() {
  local target="" yes=0 del=0 force_del=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --delete-branch) del=1; shift ;;
      --force-delete-branch) force_del=1; shift ;;
      -*) die "$EX_ERR" "close: unknown option $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "$EX_ERR" "usage: close G/T [--yes] [--delete-branch] [--force-delete-branch]"
  split_target "$target"
  config_load || true

  local wid pane path wt common main branch pending="" n upstream
  wid=$(window_id "$tg_group" "$tg_task") || exit
  pane=$(claude_pane "$wid")
  path=$(t display -p -t "$pane" '#{pane_current_path}')
  wt=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || die "$EX_ERR" "not a git worktree: $path"
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  main=$(dirname "$common")
  [ "$(cd -P "$wt" && pwd)" != "$(cd -P "$main" && pwd)" ] || die "$EX_ERR" "refusing to remove the main repo checkout: $wt"
  branch=$(git -C "$wt" branch --show-current)

  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    pending="${pending}uncommitted changes:
$(git -C "$wt" status --short)
"
  fi
  if upstream=$(git -C "$wt" rev-parse --abbrev-ref '@{u}' 2>/dev/null); then :; else upstream="origin/${cfg_base_branch:-main}"; fi
  n=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] && pending="${pending}$n commit(s) not pushed (vs $upstream):
$(git -C "$wt" log --oneline "$upstream..HEAD")
"
  if [ -n "$branch" ]; then
    local stashes
    stashes=$(git -C "$wt" stash list | grep -E "^[^:]+: (WIP on|On) $branch:" || true)
    [ -n "$stashes" ] && pending="${pending}stash entries for $branch:
$stashes
"
  fi

  if [ -n "$pending" ] && [ "$yes" = 0 ]; then
    printf 'pending work in %s/%s (%s):\n%s' "$tg_group" "$tg_task" "$wt" "$pending"
    die "$EX_PENDING" "close blocked: pending work; re-run with --yes to discard"
  fi

  if [ -n "$pending" ]; then
    git -C "$main" worktree remove --force "$wt" || die "$EX_ERR" "git worktree remove failed: $wt"
  else
    git -C "$main" worktree remove "$wt" || die "$EX_ERR" "git worktree remove failed: $wt"
  fi
  t kill-window -t "$wid"
  echo "closed $tg_group/$tg_task (worktree removed: $wt)"

  [ -n "$branch" ] || return 0
  if [ "$force_del" = 1 ]; then
    git -C "$main" branch -D "$branch" >/dev/null && echo "branch deleted (forced): $branch"
  elif [ "$del" = 1 ]; then
    git -C "$main" branch -d "$branch" >/dev/null 2>&1 && echo "branch deleted: $branch" ||
      die "$EX_PENDING" "branch $branch not fully merged; kept (use --force-delete-branch to force)"
  else
    echo "branch kept: $branch"
  fi
}

cmd_move() {
  local target="" to=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to=${2:-}; shift 2 ;;
      -*) die "$EX_ERR" "move: unknown option $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] && [ -n "$to" ] || die "$EX_ERR" "usage: move G/T --to G2"
  split_target "$target"
  valid_name "$to" || die "$EX_ERR" "invalid group name: $to"
  config_load || true
  [ "$to" != "$cfg_hq_session" ] || die "$EX_ERR" "cannot move into the hub session ($cfg_hq_session)"
  [ "$to" != "$tg_group" ] || die "$EX_ERR" "task already in group $to"

  local wid placeholder=""
  wid=$(window_id "$tg_group" "$tg_task") || exit
  if t has-session -t "=$to" 2>/dev/null; then
    t list-windows -t "=$to" -F '#{window_name}' | grep -qxF "$tg_task" &&
      die "$EX_NOTFOUND" "task '$tg_task' already exists in group '$to'"
  else
    placeholder=$(t new-session -d -P -F '#{window_id}' -s "$to")
  fi
  t move-window -s "$wid" -t "=$to:" || die "$EX_ERR" "move-window failed"
  [ -n "$placeholder" ] && t kill-window -t "$placeholder"
  t set -t "=$to:" @agent_hub 1
  echo "moved $tg_task: $tg_group -> $to"
}
