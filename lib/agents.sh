# shellcheck shell=bash
# Tasks: new / open / send / peek / close / move / list, task markers and adoption.
#
# A task is a git worktree with a marker file in its private git dir
# (<repo>/.git/worktrees/<id>/agent-hub: group=, task=, worktree=), shown as the tmux window
# <task> in the session <group>. git deletes the marker together with the worktree.

US=$(printf '\037') # field separator for `read` (tabs collapse when they are IFS)

roots_lines() { printf '%s\n' "$cfg_repos_roots" | tr ':' '\n'; }

# resolve_repo <name|path>  -> absolute path of a repo under repos_roots
resolve_repo() {
  local r=$1 root found="" n=0
  case "$r" in
    /*) found=$r; n=1 ;;
    *) while IFS= read -r root; do
         [ -n "$root" ] || continue
         if [ -e "$root/$r/.git" ]; then found="$root/$r"; n=$((n + 1)); fi
       done <<EOF
$(roots_lines)
EOF
       ;;
  esac
  [ "$n" -gt 1 ] && die "$EX_NOTFOUND" "repo '$r' is ambiguous across repos_roots; pass the full path"
  [ -n "$found" ] && git -C "$found" rev-parse --git-dir >/dev/null 2>&1 ||
    die "$EX_NOTFOUND" "repo not found in repos_roots: $r"
  (cd -P "$found" && pwd)
}

repo_list() { # name<TAB>path of every repo under repos_roots, most recently used first
  local root d
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    ls -td "$root"/*/.git 2>/dev/null | while IFS= read -r d; do
      d=${d%/.git}
      printf '%s\t%s\n' "${d##*/}" "$d"
    done
  done <<EOF
$(roots_lines)
EOF
}

current_repo() { # main repo of the current directory, also from inside one of its worktrees
  local d=$PWD l
  while [ -n "$d" ] && [ "$d" != / ]; do
    if [ -d "$d/.git" ]; then printf '%s\n' "$d"; return 0; fi
    if [ -f "$d/.git" ]; then
      IFS= read -r l < "$d/.git"; l=${l#gitdir: }
      case "$l" in */.git/worktrees/*) printf '%s\n' "${l%/.git/worktrees/*}" ;; *) printf '%s\n' "$d" ;; esac
      return 0
    fi
    d=${d%/*}
  done
  return 1
}

worktree_path() { # worktree_path <repo_path> <task>
  local repo=$1 task=$2
  case "$cfg_worktree_location" in
    sibling) printf '%s/%s--%s\n' "${repo%/*}" "${repo##*/}" "$task" ;;
    subdirectory) printf '%s/.worktrees/%s\n' "$repo" "$task" ;;
    *) printf '%s/%s/%s\n' "${cfg_worktree_location%/}" "${repo##*/}" "$task" ;;
  esac
}

# --- markers -----------------------------------------------------------------------------

marker_files() {
  local root f
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for f in "$root"/*/.git/worktrees/*/agent-hub; do [ -f "$f" ] && printf '%s\n' "$f"; done
  done <<EOF
$(roots_lines)
EOF
}

marker_read() { # marker_read <file>: sets mk_group mk_task mk_worktree
  local line
  mk_group="" mk_task="" mk_worktree=""
  while IFS= read -r line; do
    case "$line" in
      group=*) mk_group=${line#group=} ;;
      task=*) mk_task=${line#task=} ;;
      worktree=*) mk_worktree=${line#worktree=} ;;
    esac
  done < "$1"
}

marker_find() { # marker_find <group> <task>: prints the marker file
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    marker_read "$f"
    if [ "$mk_group" = "$1" ] && [ "$mk_task" = "$2" ]; then printf '%s\n' "$f"; return 0; fi
  done <<EOF
$(marker_files)
EOF
  return 1
}

marker_write() { # marker_write <worktree git dir> <group> <task> <worktree>
  local f="$1/agent-hub"
  printf 'group=%s\ntask=%s\nworktree=%s\n' "$2" "$3" "$4" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# Gives a marker to agent-hub worktrees that have none: v1 tasks, and tasks whose marker was
# lost. Only worktrees exactly where agent-hub puts them (worktree_path) are taken; the group is
# the session of a window named after the task in that worktree (tmux-resurrect restores those),
# else the repo name. Reads files only, no git.
adopt_tasks() {
  [ -n "$cfg_repos_roots" ] && [ -n "$cfg_worktree_location" ] || return 0
  local wins root gd wt repo task group
  wins=$(t list-panes -a -F "#{session_name}$TAB#{window_name}$TAB#{pane_start_path}$TAB#{pane_current_path}" 2>/dev/null)
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for gd in "$root"/*/.git/worktrees/*; do
      [ -f "$gd/gitdir" ] && [ ! -f "$gd/agent-hub" ] || continue
      IFS= read -r wt < "$gd/gitdir"
      wt=${wt%/.git}
      [ -d "$wt" ] || continue
      repo=${gd%/.git/worktrees/*}
      case "$cfg_worktree_location" in
        sibling) task=${wt##*/}; task=${task#"${repo##*/}--"} ;;
        *) task=${wt##*/} ;;
      esac
      valid_name "$task" && [ "$(worktree_path "$repo" "$task")" = "$wt" ] || continue
      group=$(printf '%s\n' "$wins" | awk -F'\t' -v t="$task" -v w="$wt" '$2 == t && ($3 == w || $4 == w) { print $1; exit }')
      valid_name "$group" || group=$(printf '%s' "${repo##*/}" | tr -c 'A-Za-z0-9_-' '-')
      [ "$group" != "$cfg_hq_session" ] || continue
      marker_find "$group" "$task" >/dev/null && continue
      marker_write "$gd" "$group" "$task" "$wt"
    done
  done <<EOF
$(roots_lines)
EOF
}

# --- rows (shared by list and the dashboard) ---------------------------------------------

rows() { # rows <raw|hq|popup>
  local mode=$1 gh=0 stale="" ghdir
  ghdir=$(runtime_dir gh)
  if gh_enabled; then gh=1; stale="$ghdir/stale.$$"; : > "$stale"; fi
  {
    marker_files | sed "s/^/M$TAB/"
    t list-panes -a -F "P$TAB#{session_name}$TAB#{window_name}$TAB#{window_id}$TAB#{pane_id}$TAB#{pane_index}$TAB#{@agent_hub_role}$TAB#{@agent_status}$TAB#{@agent_since}$TAB#{@agent_note}$TAB#{@agent_worktree}$TAB#{pane_current_path}$TAB#{pane_current_command}$TAB#{?#{==:#{pane_title},#{host}},,#{pane_title}}$TAB#{pane_dead}" 2>/dev/null
    t list-sessions -F "S$TAB#{session_name}$TAB#{session_windows}$TAB#{pane_current_path}$TAB#{pane_id}" 2>/dev/null
  } | AH_MODE=$mode AH_HQ=$cfg_hq_session AH_GH=$gh AH_GHDIR=$ghdir AH_STALE=$stale awk -f "$AGENT_HUB_HOME/lib/rows.awk"
  if [ -n "$stale" ]; then
    [ -s "$stale" ] && gh_refresh_bg < "$stale"
    rm -f "$stale"
  fi
}

# --- tasks -------------------------------------------------------------------------------

# claude_pane <window>: the agent pane of a window (role claude, else one with a status, else the
# first), as pane role status command worktree path dead, separated by $US.
claude_pane() {
  t list-panes -t "$1" -F "#{pane_id}$US#{@agent_hub_role}$US#{@agent_status}$US#{pane_current_command}$US#{@agent_worktree}$US#{pane_current_path}$US#{pane_dead}" 2>/dev/null |
    awk -F"$US" '$2 == "claude" { r = $0; exit } $3 != "" && s == "" { s = $0 } f == "" { f = $0 }
      END { print (r != "" ? r : (s != "" ? s : f)) }'
}

# task_resolve <group/task>: sets tk_group tk_task tk_marker tk_wt tk_repo tk_wid tk_pane tk_role
# tk_status tk_cmd tk_dead. Dies with 4 when there is neither a marker nor a window.
task_resolve() {
  case "$1" in */*) ;; *) die "$EX_ERR" "expected <group>/<task>, got: $1" ;; esac
  local wtopt="" path=""
  tk_group=${1%%/*}; tk_task=${1#*/}
  tk_marker="" tk_wt="" tk_repo="" tk_wid="" tk_pane="" tk_role="" tk_status="" tk_cmd="" tk_dead=""
  tk_marker=$(marker_find "$tk_group" "$tk_task")
  if [ -n "$tk_marker" ]; then
    marker_read "$tk_marker"
    tk_wt=$mk_worktree
    tk_repo=${tk_marker%/.git/worktrees/*}
  fi
  tk_wid=$(t list-windows -t "=$tk_group" -F "#{window_name}$TAB#{window_id}" 2>/dev/null |
    awk -F'\t' -v n="$tk_task" '$1 == n { print $2; exit }')
  if [ -z "$tk_wid" ] && [ -n "$tk_wt" ]; then
    tk_wid=$(t list-panes -a -F "#{@agent_worktree}$TAB#{window_id}" 2>/dev/null | awk -F'\t' -v w="$tk_wt" '$1 == w { print $2; exit }')
  fi
  if [ -n "$tk_wid" ]; then
    IFS=$US read -r tk_pane tk_role tk_status tk_cmd wtopt path tk_dead <<EOF
$(claude_pane "$tk_wid")
EOF
    [ -n "$tk_wt" ] || tk_wt=${wtopt:-$path}
  fi
  [ -n "$tk_marker" ] || [ -n "$tk_wid" ] || die "$EX_NOTFOUND" "task not found: $1"
}

# task_launch <group> <task> <worktree> <new|resume> [prompt]: task window (Claude on top, a
# shell below) started through `agent-hub run`; prints the Claude pane id.
task_launch() {
  local g=$1 tk=$2 wt=$3 pane
  local -a cmd
  cmd=("$(ah_bin)" run agent "$g/$tk")
  [ "$4" = resume ] && cmd=("${cmd[@]}" --resume)
  [ $# -ge 5 ] && cmd=("${cmd[@]}" -- "$5")
  if t has-session -t "=$g" 2>/dev/null; then
    pane=$(t new-window -d -P -F '#{pane_id}' -t "=$g:" -n "$tk" -c "$wt" -- "${cmd[@]}")
  else
    pane=$(t new-session -d -P -F '#{pane_id}' -s "$g" -n "$tk" -c "$wt" -- "${cmd[@]}")
  fi
  [ -n "$pane" ] || die "$EX_ERR" "could not create the tmux window for $g/$tk"
  t set -w -t "$pane" automatic-rename off \; set -p -t "$pane" @agent_hub_role claude \; \
    set -p -t "$pane" @agent_worktree "$wt"
  t split-window -d -v -t "$pane" -l "$((100 - cfg_claude_pane_pct))%" -c "$wt"
  printf '%s\n' "$pane"
}

pane_is_idle() { # pane_is_idle <status> <command> <dead>: nothing of ours runs there
  [ "$3" = 1 ] && return 0
  case "$1" in ''|stopped) is_shell "$2" ;; *) return 1 ;; esac
}

pane_switch() { # pane_switch <pane> [1 = zoom]
  if [ "${2:-0}" = 1 ] && [ "$(t display -p -t "$1" '#{window_zoomed_flag}')" = 0 ]; then
    t resize-pane -Z -t "$1"
  fi
  if [ -n "${TMUX:-}" ]; then
    t switch-client -t "$1" 2>/dev/null || { t select-window -t "$1"; t select-pane -t "$1"; }
  elif [ -t 0 ] && [ -t 1 ]; then
    t select-window -t "$1" \; select-pane -t "$1"
    t attach-session -t "$1"
  fi
}

# Ref new worktrees start from: origin/<base> after a fetch that never prompts. Falls back to the
# last fetched origin/<base> when offline, and to a local branch when there is no origin.
base_ref() { # base_ref <repo>
  local repo=$1 base=$cfg_base_branch
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    if [ -z "$base" ]; then
      base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
      base=${base#origin/}
    fi
    if [ -z "$base" ]; then
      if git -C "$repo" show-ref -q --verify refs/remotes/origin/main; then base=main
      elif git -C "$repo" show-ref -q --verify refs/remotes/origin/master; then base=master
      else base=main; fi
    fi
    printf 'agent-hub: fetching origin/%s...\n' "$base" >&2
    if GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch -q origin "$base" </dev/null; then
      printf 'origin/%s\n' "$base"
    elif git -C "$repo" show-ref -q --verify "refs/remotes/origin/$base"; then
      warn "git fetch origin $base failed; starting from the last fetched origin/$base"
      printf 'origin/%s\n' "$base"
    else
      die "$EX_ERR" "git fetch origin $base failed and there is no origin/$base yet"
    fi
  else
    [ -n "$base" ] || base=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)
    git -C "$repo" show-ref -q --verify "refs/heads/$base" || die "$EX_ERR" "base branch '$base' not found in $repo"
    warn "${repo##*/} has no origin remote; starting from the local branch $base"
    printf '%s\n' "$base"
  fi
}

cmd_new() {
  local group="" repo="" task="" prompt="" has_prompt=0 open=0
  if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then ui_new_agent; return; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) group=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --task) task=${2:-}; shift 2 ;;
      --prompt) prompt=${2:-}; has_prompt=1; shift 2 ;;
      --open) open=1; shift ;;
      *) die "$EX_ERR" "new: unknown option $1" ;;
    esac
  done
  [ -n "$group" ] && [ -n "$repo" ] && [ -n "$task" ] ||
    die "$EX_ERR" "usage: new --group G --repo R --task T [--prompt P] [--open]"
  valid_name "$group" || die "$EX_ERR" "invalid group name (use letters, digits, - and _): $group"
  valid_name "$task" || die "$EX_ERR" "invalid task name (use letters, digits, - and _): $task"
  config_require
  [ "$group" != "$cfg_hq_session" ] || die "$EX_ERR" "group cannot be the hub session ($cfg_hq_session)"
  [ -t 0 ] || export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

  local repo_path wt branch ref gitdir pane
  repo_path=$(resolve_repo "$repo") || exit
  wt=$(worktree_path "$repo_path" "$task")
  branch="$cfg_branch_prefix$task"
  if t list-windows -t "=$group" -F '#{window_name}' 2>/dev/null | grep -qxF "$task" ||
     marker_find "$group" "$task" >/dev/null; then
    die "$EX_NOTFOUND" "task '$task' already exists in group '$group'; choose another name"
  fi
  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" &&
    die "$EX_NOTFOUND" "branch already exists: $branch"
  [ -e "$wt" ] && die "$EX_NOTFOUND" "worktree path already exists: $wt"

  ref=$(base_ref "$repo_path") || exit
  mkdir -p "$(dirname "$wt")"
  # --no-track: the task branch must not track the base branch (a plain push would land there).
  git -C "$repo_path" worktree add -q --no-track -b "$branch" "$wt" "$ref" >/dev/null ||
    die "$EX_ERR" "git worktree add failed"
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir) && marker_write "$gitdir" "$group" "$task" "$wt"

  if [ "$has_prompt" = 1 ]; then
    pane=$(task_launch "$group" "$task" "$wt" new "$prompt") || exit
  else
    pane=$(task_launch "$group" "$task" "$wt" new) || exit
  fi
  printf 'created %s/%s repo=%s branch=%s worktree=%s\n' "$group" "$task" "$repo_path" "$branch" "$wt"
  dash_poke
  [ "$open" = 1 ] && pane_switch "$pane"
  return 0
}

# open <group/task>: switches to the task; restarts Claude (claude --continue) when it is not
# running, re-creating the window when tmux lost it.
cmd_open() {
  local target="" zoom=0 switch=1 pane
  while [ $# -gt 0 ]; do
    case "$1" in
      --zoom) zoom=1; shift ;;
      --no-switch) switch=0; shift ;;
      -*) die "$EX_ERR" "open: unknown option $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "$EX_ERR" "usage: open G/T [--zoom] [--no-switch]"
  config_load || true
  adopt_tasks
  task_resolve "$target"
  pane=$tk_pane
  if [ -z "$tk_wid" ]; then
    [ -d "$tk_wt" ] || die "$EX_NOTFOUND" "worktree is gone: $tk_wt (close the task to clean up)"
    pane=$(task_launch "$tk_group" "$tk_task" "$tk_wt" resume) || exit
  elif { [ -n "$tk_marker" ] || [ "$tk_role" = claude ]; } && pane_is_idle "$tk_status" "$tk_cmd" "$tk_dead"; then
    t respawn-pane -k -t "$pane" -c "$tk_wt" -- "$(ah_bin)" run agent "$tk_group/$tk_task" --resume
    t set -p -t "$pane" @agent_hub_role claude \; set -p -t "$pane" @agent_worktree "$tk_wt"
  fi
  [ "$tk_status" = done ] && t set -p -t "$pane" @agent_status idle
  [ "$switch" = 1 ] && pane_switch "$pane" "$zoom"
  dash_poke
  return 0
}

# agent_target <group/task | %pane>: sets ag_pane ag_status ag_label
agent_target() {
  case "$1" in
    %*) ag_pane=$1; ag_label=$1
        ag_status=$(t display -p -t "$1" '#{@agent_status}' 2>/dev/null) || die "$EX_NOTFOUND" "pane not found: $1" ;;
    *) task_resolve "$1"
       ag_pane=$tk_pane; ag_status=$tk_status; ag_label=$1
       [ -n "$ag_pane" ] || die "$EX_NOTFOUND" "$1 is not running; open it first (agent-hub open $1)" ;;
  esac
}

cmd_send() {
  local target="" msg="" has_msg=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) if [ -z "$target" ]; then target=$1; else msg=$1; has_msg=1; fi; shift ;;
    esac
  done
  [ -n "$target" ] && [ "$has_msg" = 1 ] || die "$EX_ERR" "usage: send G/T <message> [--force]"
  [ -n "$msg" ] || die "$EX_ERR" "empty message"
  config_load || true
  agent_target "$target"
  case "$ag_status" in
    ''|stopped) die "$EX_NOTFOUND" "Claude is not running in $ag_label; open it first" ;;
    waiting) [ "$force" = 1 ] ||
      die "$EX_PENDING" "$ag_label is waiting for an answer (permission or question): open it, or pass --force" ;;
  esac
  # Bracketed paste keeps quotes and newlines as text; Enter is a separate key press.
  t set-buffer -b agent-hub-send -- "$msg"
  t paste-buffer -p -d -b agent-hub-send -t "$ag_pane"
  sleep 0.2
  t send-keys -t "$ag_pane" Enter
  echo "sent to $ag_label"
}

cmd_peek() {
  local target="" n=40
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) n=${2:-40}; shift 2 ;;
      -*) die "$EX_ERR" "peek: unknown option $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "$EX_ERR" "usage: peek G/T [-n lines]"
  config_load || true
  agent_target "$target"
  t capture-pane -p -J -t "$ag_pane" |
    awk '{ b[NR] = $0; if ($0 ~ /[^ \t]/) last = NR } END { for (i = 1; i <= last; i++) print b[i] }' | tail -n "$n"
}

# close_check <worktree>: sets cl_main cl_branch cl_pending (empty when nothing would be lost)
close_check() {
  local wt=$1 common n upstream stashes
  cl_pending=""
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    die "$EX_ERR" "not a git worktree: $wt"
  cl_main=$(dirname "$common")
  [ "$(cd -P "$wt" && pwd)" != "$(cd -P "$cl_main" && pwd)" ] ||
    die "$EX_ERR" "refusing to remove the main repo checkout: $wt"
  cl_branch=$(git -C "$wt" branch --show-current)
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    cl_pending="${cl_pending}uncommitted changes:
$(git -C "$wt" status --short)
"
  fi
  if ! upstream=$(git -C "$wt" rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
    upstream=""
    [ -n "$cfg_base_branch" ] && git -C "$wt" show-ref -q --verify "refs/remotes/origin/$cfg_base_branch" &&
      upstream="origin/$cfg_base_branch"
    [ -n "$upstream" ] || upstream=$(git -C "$wt" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
    [ -n "$upstream" ] || upstream=${cfg_base_branch:-main}
  fi
  n=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] && cl_pending="${cl_pending}$n commit(s) not pushed (vs $upstream):
$(git -C "$wt" log --oneline "$upstream..HEAD")
"
  if [ -n "$cl_branch" ]; then
    stashes=$(git -C "$wt" stash list | grep -E "^[^:]+: (WIP on|On) $cl_branch:" || true)
    [ -n "$stashes" ] && cl_pending="${cl_pending}stash entries for $cl_branch:
$stashes
"
  fi
  return 0
}

# Clients looking at a window move to the hub before it is killed (instead of being detached).
clients_to_hub() { # clients_to_hub <window_id>
  local c
  c=$(t list-clients -F "#{client_name}$TAB#{window_id}" 2>/dev/null | awk -F'\t' -v w="$1" '$2 == w { print $1 }')
  [ -n "$c" ] || return 0
  ensure_hq >/dev/null 2>&1
  printf '%s\n' "$c" | while IFS= read -r c; do t switch-client -c "$c" -t "=$cfg_hq_session:" 2>/dev/null; done
}

cmd_close() {
  local target="" yes=0 del=0 force_del=0 flags=0 interactive=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; flags=1; shift ;;
      --delete-branch) del=1; flags=1; shift ;;
      --force-delete-branch) force_del=1; flags=1; shift ;;
      --interactive) interactive=1; shift ;;
      -*) die "$EX_ERR" "close: unknown option $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "$EX_ERR" "usage: close G/T [--yes] [--delete-branch] [--force-delete-branch]"
  config_load || true
  task_resolve "$target"
  [ -n "$tk_wt" ] || die "$EX_ERR" "no worktree known for $target"
  [ "$flags" = 0 ] && [ -t 0 ] && [ -t 1 ] && interactive=1

  local main branch
  if [ -d "$tk_wt" ]; then
    close_check "$tk_wt"
    main=$cl_main; branch=$cl_branch
  else
    [ -n "$tk_repo" ] || die "$EX_ERR" "worktree is gone and its repo is unknown: $tk_wt"
    main=$tk_repo; cl_pending=""
    branch=$(sed -n 's#^ref: refs/heads/##p' "$(dirname "$tk_marker")/HEAD" 2>/dev/null)
  fi
  gh_pr_lookup "$main" "$branch"

  if [ "$interactive" = 1 ]; then
    close_menu "$target" "$branch" || { echo "close cancelled"; return 0; }
  elif [ -n "$cl_pending" ] && [ "$yes" = 0 ]; then
    printf 'pending work in %s (%s):\n%s' "$target" "$tk_wt" "$cl_pending"
    [ -n "$pr_num" ] && printf 'PR #%s is %s\n' "$pr_num" "$pr_state"
    die "$EX_PENDING" "close blocked: pending work; re-run with --yes to discard"
  fi

  if [ -d "$tk_wt" ]; then
    if [ -n "$cl_pending" ]; then
      git -C "$main" worktree remove --force "$tk_wt" || die "$EX_ERR" "git worktree remove failed: $tk_wt"
    else
      git -C "$main" worktree remove "$tk_wt" || die "$EX_ERR" "git worktree remove failed: $tk_wt"
    fi
  else
    git -C "$main" worktree prune
    rm -f "$tk_marker"
  fi
  echo "closed $target (worktree removed: $tk_wt)"
  if [ -n "$branch" ]; then
    if [ "$force_del" = 1 ]; then
      git -C "$main" branch -D "$branch" >/dev/null && echo "branch deleted (forced): $branch"
    elif [ "$del" = 1 ]; then
      if git -C "$main" branch -d "$branch" >/dev/null 2>&1; then echo "branch deleted: $branch"
      else echo "branch $branch is not fully merged; kept (use --force-delete-branch to force)"; fi
    else
      echo "branch kept: $branch"
    fi
  fi
  dash_poke
  # Last: when close runs inside the task's own window, killing it ends this script too.
  if [ -n "$tk_wid" ]; then
    clients_to_hub "$tk_wid"
    t set -t "=$tk_group" detach-on-destroy off 2>/dev/null
    t kill-window -t "$tk_wid"
  fi
  return 0
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
  valid_name "$to" || die "$EX_ERR" "invalid group name: $to"
  config_load || true
  [ "$to" != "$cfg_hq_session" ] || die "$EX_ERR" "cannot move into the hub session ($cfg_hq_session)"
  task_resolve "$target"
  [ "$to" != "$tk_group" ] || die "$EX_ERR" "task already in group $to"
  if t list-windows -t "=$to" -F '#{window_name}' 2>/dev/null | grep -qxF "$tk_task" ||
     marker_find "$to" "$tk_task" >/dev/null; then
    die "$EX_NOTFOUND" "task '$tk_task' already exists in group '$to'"
  fi
  if [ -n "$tk_wid" ]; then
    local placeholder=""
    # Moving a session's last window destroys it; switch its clients elsewhere instead of detaching.
    t set -t "=$tk_group" detach-on-destroy off 2>/dev/null
    t has-session -t "=$to" 2>/dev/null || placeholder=$(t new-session -d -P -F '#{window_id}' -s "$to")
    t move-window -s "$tk_wid" -t "=$to:" || die "$EX_ERR" "move-window failed"
    [ -n "$placeholder" ] && t kill-window -t "$placeholder"
  fi
  [ -n "$tk_marker" ] && marker_write "$(dirname "$tk_marker")" "$to" "$tk_task" "$tk_wt"
  dash_poke
  echo "moved $tk_task: $tk_group -> $to"
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
  adopt_tasks
  case "$fmt" in
    tsv) rows raw ;;
    json) rows raw | jq -R -s 'split("\n") | map(select(. != "") | split("\t") |
            {kind: (if .[0] == "t" then "task" else "adhoc" end), group: .[1], task: .[2], status: .[3],
             since: (.[4] | if . == "" then null else tonumber end), repo: .[5], branch: .[6],
             pane: (.[7] | if . == "" then null else . end), window: (.[8] | if . == "" then null else . end),
             worktree: .[9], running: (.[3] != "stopped"),
             pr: (if .[11] == "" then null else {number: (.[11] | tonumber), state: .[12],
                  checks: (.[13] | if . == "" then null else . end), url: .[14]} end),
             note: .[15]})' ;;
    *) die "$EX_ERR" "list: format must be tsv or json" ;;
  esac
}
