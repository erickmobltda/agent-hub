# shellcheck shell=bash
# Interactive fzf prompts and flows (they need a terminal). bash 3.2 has no `read -i`, so fzf is
# also the line editor for free text. The user's FZF_DEFAULT_OPTS never apply here.

ui_fzf() {
  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf --layout=reverse --border=rounded --border-label-pos=3 \
    --info=hidden --no-scrollbar --ansi --pointer='▌' --gutter=' ' --with-shell='/bin/bash -c' "$@"
}

# ui_text <var> <title> <prompt> [default] [hint]: one line of free text. 1 = cancelled.
# (Locals start with __ so they never shadow the caller's <var>.)
ui_text() {
  local __var=$1 __title=$2 __prompt=$3 __def=${4:-} __hint=${5:-} __out __rc
  __out=$(: | ui_fzf --print-query --query "$__def" --prompt "$__prompt > " --border-label " $__title " \
    --header "${__hint:-enter: accept · esc: cancel}" --header-first)
  __rc=$?
  [ "$__rc" -le 1 ] || return 1
  printf -v "$__var" '%s' "$(printf '%s\n' "$__out" | sed -n 1p)"
}

# ui_pick <var> <title> <header> <new label> <items file: value<TAB>name[<TAB>detail]>: Enter takes
# the highlighted row; typing searches the names only. With a new label, a last row is always
# "+ <label>: <what you typed>".
ui_pick() {
  local __var=$1 __title=$2 __header=$3 __newlbl=$4 __file=$5 __out __rc __sel __q __gen
  __gen="cat $(printf '%q' "$__file")"
  if [ -n "$__newlbl" ]; then
    __gen="$__gen; printf '__new__\t\033[2m+ %s:\033[0m %s\n' $(printf '%q' "$__newlbl") {q}"
  fi
  __out=$(: | ui_fzf --print-query --delimiter='\t' --with-nth=2.. --nth=1 --accept-nth=1 \
    --border-label " $__title " --header "$__header" --header-first --prompt '> ' \
    --bind "start,change:reload-sync:$__gen")
  __rc=$?
  [ "$__rc" -le 1 ] || return 1
  __q=$(printf '%s\n' "$__out" | sed -n 1p)
  __sel=$(printf '%s\n' "$__out" | sed -n 2p)
  if [ "$__sel" = __new__ ]; then
    [ -n "$__q" ] || ui_text __q "$__title" "$__newlbl" "" "a name: letters, digits, - and _" || return 1
    __sel=$__q
  fi
  [ -n "$__sel" ] || return 1
  printf -v "$__var" '%s' "$__sel"
}

# ui_menu <var> <title> <header> <items: value<TAB>label lines>
ui_menu() {
  local __var=$1 __out
  __out=$(printf '%s\n' "$4" | ui_fzf --no-sort --delimiter='\t' --with-nth=2.. --accept-nth=1 \
    --border-label " $2 " --header "$3" --header-first --prompt '> ') || return 1
  [ -n "$__out" ] || return 1
  printf -v "$__var" '%s' "$__out"
}

namify() { # a valid task or group name from free text, case kept: "PROJ-12 fix login" -> "PROJ-12-fix-login"
  printf '%s' "$1" | sed -e 's/[^A-Za-z0-9_-][^A-Za-z0-9_-]*/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-60
}

# ui_name <var> <title> <default> <hint> <group>: free text. Under it, live, the task and branch
# names it becomes, then the hint.
ui_name() {
  local __var=$1 __out __rc __show
  __show="$(printf '%q' "$(ah_bin)") _name-preview $(printf '%q' "$5") {q} $(printf '%q' "$4")"
  __out=$(: | ui_fzf --print-query --query "$3" --prompt "name > " --border-label " $2 " \
    --bind "start,change:transform-header:$__show")
  __rc=$?
  [ "$__rc" -le 1 ] || return 1
  printf -v "$__var" '%s' "$(printf '%s\n' "$__out" | sed -n 1p)"
}

name_preview() { # name_preview <group> <typed text> [hint]
  local n
  n=$(namify "$2")
  if [ -n "$n" ]; then
    printf '\033[2m→\033[0m \033[1;35m%s/\033[0m\033[1m%s\033[0m  \033[2mbranch\033[0m \033[35m%s%s\033[0m\n' "$1" "$n" "$cfg_branch_prefix" "$n"
  else
    printf '\033[2m→ type a name, e.g. a ticket: PROJ-1234 or "fix login"\033[0m\n'
  fi
  [ -n "${3:-}" ] && printf '%s\n' "$3"
  return 0
}

# Categories for a new session (value<TAB>name<TAB>detail): groups with agents, then the other tmux
# sessions; <first> on top.
category_list() {
  local D R
  D=$(printf '\033[2m'); R=$(printf '\033[0m')
  { rows raw | awk -F'\t' '{ n[$2]++ } END { for (g in n) printf "g\t%s\t%d\n", g, n[g] }' | sort -t "$TAB" -k2,2
    t list-sessions -F "s$TAB#{session_name}$TAB#{session_windows}" 2>/dev/null
  } | awk -F'\t' -v hq="$cfg_hq_session" -v first="${1:-}" -v D="$D" -v R="$R" '
    $2 == "" || $2 == hq || seen[$2]++ { next }
    { v[++n] = $2; d[n] = D ($1 == "g" ? $3 " agent" ($3 == 1 ? "" : "s") : "tmux session") R
      if (length($2) > w) w = length($2); if ($2 == first) top = n }
    END { fmt = "%s\t%-" w "s\t%s\n"  # names padded: the details line up
      if (top) printf fmt, v[top], v[top], d[top]
      for (i = 1; i <= n; i++) if (i != top) printf fmt, v[i], v[i], d[i] }'
}

groups_list() { # groups that have tasks, then the other sessions (value<TAB>label)
  { rows raw | cut -f2; t list-sessions -F '#{session_name}' 2>/dev/null; } |
    awk -v hq="$cfg_hq_session" '$0 != "" && $0 != hq && !seen[$0]++ { printf "%s\t%s\n", $0, $0 }'
}

# --- flows run from the dashboard: in the hub inside a tmux popup (a dialog), in the Ctrl+Q popup
# through fzf `execute`. They report in the dashboard's header (dash_msg). ---

# New session: category -> repo -> name, then it opens. <category> and <repo> are offered first.
ui_new_agent() { # ui_new_agent [category] [repo path]
  local first=${1:-} firstrepo=${2:-} f repo group name task cur hint out
  config_load || true
  if [ -z "$cfg_repos_roots" ] || [ -z "$cfg_worktree_location" ]; then
    dash_msg "✗ agent-hub is not set up yet: run 'agent-hub setup' in a terminal"
    return 0
  fi
  [ "$first" = "*sessions" ] && first=""
  f=$(mktemp "${TMPDIR:-/tmp}/agent-hub-pick.XXXXXX")
  category_list "$first" > "$f"
  hint="pick a category (a tmux session), or type a new name"
  while :; do
    ui_pick group "new session · 1/3 category" "$hint" "new category" "$f" ||
      { rm -f "$f"; dash_msg "new session cancelled"; return 0; }
    group=$(namify "$group")
    valid_name "$group" && [ "$group" != "$cfg_hq_session" ] && break
    hint="✗ '$group' can't be a category: use letters, digits, - and _ (not $cfg_hq_session)"
  done
  cur=${firstrepo:-$(current_repo 2>/dev/null)}
  repo_list | awk -F'\t' -v c="$cur" -v home="$HOME" -v dim="$(printf '\033[2m')" -v r="$(printf '\033[0m')" '
    { v[++n] = $2; nm[n] = $1; if (length($1) > w) w = length($1); if ($2 == c) top = n }
    function out(i,   p) { p = v[i]; if (index(p, home "/") == 1) p = "~" substr(p, length(home) + 1)
      printf "%s\t%-" w "s\t%s%s%s\n", v[i], nm[i], dim, p, r }
    END { if (top) out(top); for (i = 1; i <= n; i++) if (i != top) out(i) }' > "$f"
  if ! ui_pick repo "new session · 2/3 repository" "type to filter" "" "$f"; then
    rm -f "$f"; dash_msg "new session cancelled"; return 0
  fi
  rm -f "$f"
  hint="it names the tmux window and the git branch · esc: cancel"
  name=""
  while :; do
    ui_name name "new session · 3/3 name" "$name" "$hint" "$group" || { dash_msg "new session cancelled"; return 0; }
    task=$(namify "$name")
    if [ -z "$task" ]; then hint="✗ type a name"; continue; fi
    if t list-windows -t "=$group" -F '#{window_name}' 2>/dev/null | grep -qxF "$task" ||
       marker_find "$group" "$task" >/dev/null; then
      hint="✗ $group/$task already exists"; continue
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$cfg_branch_prefix$task"; then
      hint="✗ the branch $cfg_branch_prefix$task already exists in ${repo##*/}"; continue
    fi
    break
  done
  printf '\n  creating %s/%s in %s...\n' "$group" "$task" "${repo##*/}"
  if ! out=$(cmd_new --group "$group" --repo "$repo" --task "$task" 2>&1); then
    dash_msg "✗ $(printf '%s\n' "$out" | tail -1 | sed 's/^agent-hub: //')"
    return 0
  fi
  dash_msg "✓ created $group/$task"
  cmd_open "$group/$task" >/dev/null 2>&1
  [ "${AGENT_HUB_DASH_MODE:-}" = popup ] && dash_next_set "abort"
  return 0
}

ui_rename() { # ui_rename <kind> <id> <target>
  local what new out
  case "$1" in
    g) if [ "$3" = "*sessions" ]; then dash_msg "'sessions' lists your plain tmux sessions; it can't be renamed"; return 0; fi
       what=$3 ;;
    t) what=${2#t:} ;;
    *) dash_msg "only categories and tasks can be renamed here"; return 0 ;;
  esac
  ui_text new "rename $what" "new name" "${what#*/}" "letters, digits, - and _ (anything else becomes -)" ||
    { dash_msg "not renamed"; return 0; }
  new=$(namify "$new")
  if out=$(cmd_rename "$what" "$new" 2>&1); then dash_msg "✓ $out"; else dash_msg "✗ ${out#agent-hub: }"; fi
}

ui_delete() { # ui_delete <kind> <id> <target>
  local n choice out
  case "$1" in
    t) ui_close t "$2" ;;
    s) n=$(t display -p -t "=$3:" '#{session_windows}' 2>/dev/null)
       ui_menu choice "delete session $3" "kills the tmux session $3 ($n window(s)) and whatever runs in it" \
         "cancel${TAB}cancel
delete${TAB}delete session $3" && [ "$choice" = delete ] || { dash_msg "not deleted"; return 0; }
       if out=$(session_delete "$3" 2>&1); then dash_msg "✓ $out"; else dash_msg "✗ ${out#agent-hub: }"; fi ;;
    g) if [ "$3" = "*sessions" ]; then dash_msg "pick one of the sessions to delete it"
       else dash_msg "close the tasks of $3 first (d on each): an empty category goes away"; fi ;;
    *) dash_msg "nothing to delete here" ;;
  esac
}

ui_send() { # ui_send <kind> <id> <target> <status>
  local kind=$1 id=$2 target=$3 st=$4 msg out who
  case "$kind" in t) who=${id#t:} ;; p) who=$target ;; *) dash_msg "pick an agent to message"; return 0 ;; esac
  case "$st" in
    waiting) dash_msg "✗ ${id#?:} is waiting for your answer: open it (enter)"; return 0 ;;
    ''|stopped) dash_msg "✗ ${id#?:} is not running: enter resumes it"; return 0 ;;
  esac
  ui_text msg "message to ${id#?:}" "message" "" "typed into Claude and sent with Enter · esc: cancel" && [ -n "$msg" ] ||
    { dash_msg "nothing sent"; return 0; }
  if out=$(cmd_send "$who" "$msg" 2>&1); then dash_msg "✓ $out"
  else dash_msg "✗ ${out#agent-hub: }"; fi
}

ui_close() { # ui_close <kind> <id>
  local out
  [ "$1" = t ] || { dash_msg "only tasks can be closed here"; return 0; }
  if out=$(cmd_close "${2#t:}" --interactive 2>&1); then
    dash_msg "$(printf '%s\n' "$out" | grep -E '^(closed|close cancelled)' | head -1)$(printf '%s\n' "$out" | grep -E '^branch' | sed 's/^/ · /' | head -1)"
  else
    dash_msg "✗ $(printf '%s\n' "$out" | tail -1 | sed 's/^agent-hub: //')"
  fi
}

ui_move() { # ui_move <kind> <id>
  local gf group out
  [ "$1" = t ] || { dash_msg "only tasks can move to another group"; return 0; }
  gf=$(mktemp "${TMPDIR:-/tmp}/agent-hub-pick.XXXXXX")
  groups_list | awk -F'\t' -v g="${2#t:}" 'BEGIN { sub(/\/.*/, "", g) } $1 != g' > "$gf"
  if ui_pick group "move ${2#t:}" "move to which group? · pick one, or type a new name" "new group" "$gf"; then
    if out=$(cmd_move "${2#t:}" --to "$group" 2>&1); then dash_msg "✓ $out"
    else dash_msg "✗ ${out#agent-hub: }"; fi
  else
    dash_msg "not moved"
  fi
  rm -f "$gf"
}

# close_menu <target> <branch>: what `close` asks on a terminal. Sets yes / del / force_del of
# cmd_close; returns 1 when cancelled.
close_menu() {
  local hdr items choice discard=""
  hdr="close $1: removes its worktree and window"
  if [ -n "$cl_pending" ]; then
    hdr="$hdr
$(printf '%s' "$cl_pending" | head -15)"
    discard="discard that work, "
  else
    hdr="$hdr
nothing to lose: no uncommitted changes, unpushed commits or stash"
  fi
  [ -n "$pr_num" ] && hdr="$hdr
PR #$pr_num is $(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')"
  items="cancel${TAB}cancel"
  if [ -n "$2" ]; then
    items="$items
keep${TAB}${discard}close, keep branch $2
delete${TAB}${discard}close, delete branch $2 (only if merged: git branch -d)"
    [ "$pr_state" = MERGED ] && items="$items
force${TAB}${discard}close, force-delete branch $2 (PR #$pr_num is merged: git branch -D)"
  else
    items="$items
keep${TAB}${discard}close"
  fi
  ui_menu choice "close $1" "$hdr" "$items" || return 1
  case "$choice" in
    keep) yes=1 ;;
    delete) yes=1; del=1 ;;
    force) yes=1; force_del=1 ;;
    *) return 1 ;;
  esac
}
