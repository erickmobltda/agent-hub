# shellcheck shell=bash
# Interactive fzf prompts and flows (they need a terminal). bash 3.2 has no `read -i`, so fzf is
# also the line editor for free text. The user's FZF_DEFAULT_OPTS never apply here.

ui_fzf() {
  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf --layout=reverse --border=rounded --border-label-pos=3 \
    --info=hidden --no-scrollbar --ansi --pointer='▌' --with-shell='/bin/bash -c' "$@"
}

# ui_text <var> <title> <prompt> [default] [hint]: one line of free text. 1 = cancelled.
ui_text() {
  local __var=$1 title=$2 prompt=$3 def=${4:-} hint=${5:-} out rc
  out=$(: | ui_fzf --print-query --query "$def" --prompt "$prompt > " --border-label " $title " \
    --header "${hint:-enter: accept · esc: cancel}" --header-first)
  rc=$?
  [ "$rc" -le 1 ] || return 1
  printf -v "$__var" '%s' "$(printf '%s\n' "$out" | sed -n 1p)"
}

# ui_pick <var> <title> <header> <new label> <items file: value<TAB>label>: Enter takes the
# highlighted row. With a new label, the last row is always "+ <label>: <what you typed>".
ui_pick() {
  local __var=$1 title=$2 header=$3 newlbl=$4 file=$5 out rc sel q gen
  gen="cat $(printf '%q' "$file")"
  if [ -n "$newlbl" ]; then
    gen="$gen; printf '__new__\t\033[2m+ %s:\033[0m %s\n' $(printf '%q' "$newlbl") {q}"
  fi
  out=$(: | ui_fzf --print-query --no-sort --delimiter='\t' --with-nth=2.. --accept-nth=1 \
    --border-label " $title " --header "$header" --header-first --prompt '> ' \
    --bind "start,change:reload-sync:$gen")
  rc=$?
  [ "$rc" -le 1 ] || return 1
  q=$(printf '%s\n' "$out" | sed -n 1p)
  sel=$(printf '%s\n' "$out" | sed -n 2p)
  if [ "$sel" = __new__ ]; then
    [ -n "$q" ] || ui_text q "$title" "$newlbl" "" "a name: letters, digits, - and _" || return 1
    sel=$q
  fi
  [ -n "$sel" ] || return 1
  printf -v "$__var" '%s' "$sel"
}

# ui_menu <var> <title> <header> <items: value<TAB>label lines>
ui_menu() {
  local __var=$1 out
  out=$(printf '%s\n' "$4" | ui_fzf --no-sort --delimiter='\t' --with-nth=2.. --accept-nth=1 \
    --border-label " $2 " --header "$3" --header-first --prompt '> ') || return 1
  [ -n "$out" ] || return 1
  printf -v "$__var" '%s' "$out"
}

slugify() { # a task name from a prompt: a few meaningful words, lowercase, '-' between them
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | awk '
    BEGIN {
      n = split("a an the to of in on at for and or with from into is are be it this that " \
                "o os as de do da dos das em no na nos nas para por com e um uma que ao", s, " ")
      for (i = 1; i <= n; i++) stop[s[i]] = 1
    }
    {
      gsub(/[^a-z0-9]+/, " ")
      n = split($0, w, " "); out = ""; c = 0
      for (i = 1; i <= n && c < 5; i++) {
        if (w[i] in stop) continue
        out = out (out == "" ? "" : "-") w[i]; c++
      }
      out = substr(out, 1, 40); sub(/-+$/, "", out)
      print out
    }'
}

groups_list() { # groups that have tasks, then the other sessions (value<TAB>label)
  { rows raw | cut -f2; t list-sessions -F '#{session_name}' 2>/dev/null; } |
    awk -v hq="$cfg_hq_session" '$0 != "" && $0 != hq && !seen[$0]++ { printf "%s\t%s\n", $0, $0 }'
}

# --- flows run from the dashboard (fzf `execute`); they report in its footer (dash_msg) ---

ui_new_agent() {
  local f gf repo group prompt task cur hint out
  config_load || true
  if [ -z "$cfg_repos_roots" ] || [ -z "$cfg_worktree_location" ]; then
    dash_msg "✗ agent-hub is not set up yet: run 'agent-hub setup' in a terminal"
    return 0
  fi
  f=$(mktemp "${TMPDIR:-/tmp}/agent-hub-pick.XXXXXX")
  gf="$f.groups"
  cur=$(current_repo 2>/dev/null)
  repo_list | awk -F'\t' -v c="$cur" -v dim="$(printf '\033[2m')" -v r="$(printf '\033[0m')" '
    { line = $2 "\t" $1 "  " dim $2 r } $2 == c { top = line; next } { rest[++n] = line }
    END { if (top != "") print top; for (i = 1; i <= n; i++) print rest[i] }' > "$f"
  if ! ui_pick repo "new agent · 1/4" "repository · type to filter" "" "$f"; then
    rm -f "$f" "$gf"; dash_msg "new agent cancelled"; return 0
  fi
  groups_list > "$gf"
  hint="group (a tmux session) · pick one, or type a new name"
  while :; do
    ui_pick group "new agent · 2/4" "$hint" "new group" "$gf" || { rm -f "$f" "$gf"; dash_msg "new agent cancelled"; return 0; }
    valid_name "$group" && [ "$group" != "$cfg_hq_session" ] && break
    hint="✗ '$group' can't be a group: use letters, digits, - and _ (not $cfg_hq_session)"
  done
  rm -f "$f" "$gf"
  ui_text prompt "new agent · 3/4" "prompt" "" "What should the agent do? enter with nothing typed: start it without a prompt" ||
    { dash_msg "new agent cancelled"; return 0; }
  task=$(slugify "$prompt")
  hint="task name (the window and the branch ${cfg_branch_prefix}<task>) · letters, digits, - and _"
  while :; do
    ui_text task "new agent · 4/4" "task" "$task" "$hint" || { dash_msg "new agent cancelled"; return 0; }
    if ! valid_name "$task"; then hint="✗ use letters, digits, - and _"; continue; fi
    marker_find "$group" "$task" >/dev/null && { hint="✗ $group/$task already exists"; continue; }
    break
  done
  printf '\n  creating %s/%s in %s...\n' "$group" "$task" "${repo##*/}"
  if [ -n "$prompt" ]; then
    out=$(cmd_new --group "$group" --repo "$repo" --task "$task" --prompt "$prompt" 2>&1)
  else
    out=$(cmd_new --group "$group" --repo "$repo" --task "$task" 2>&1)
  fi || { dash_msg "✗ $(printf '%s\n' "$out" | tail -1 | sed 's/^agent-hub: //')"; return 0; }
  if [ "${AGENT_HUB_DASH_MODE:-}" = popup ]; then
    cmd_open "$group/$task" >/dev/null 2>&1
    dash_next_set "abort"
  else
    dash_msg "✓ created $group/$task (enter opens it)"
  fi
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
