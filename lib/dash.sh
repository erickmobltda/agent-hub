# shellcheck shell=bash
# The dashboard (fzf). One UI in two places: the hub's top pane (--hq: stays open, Enter switches
# the client) and the Ctrl+Q popup (--popup: Enter switches and closes it).
#
# Rows come from rows.awk (kind id target display + hidden fields, see there): a tree of groups
# (Enter, ← and → collapse and expand them) that turns into a flat list while a query is typed,
# because fzf only searches what it shows. Refreshing never blocks typing: `dash --refresh` runs in
# the background (bg-transform), writes both views to files and only asks fzf to reload (from the
# file of the current view, instantly) when they changed.
# Actions that need the terminal run through `execute` and leave their follow-up (refresh, close
# the popup, another key) in a per-dashboard "next" file that `dash --next` hands back to fzf.
# Footer messages (dash_msg) are applied by the refresh too: after a reload through the `load`
# event, since a footer changed while fzf reloads with tracking on would be lost.

# No Ctrl+Z here: users then press it inside Claude, where it suspends Claude Code instead.
DASH_LEGEND="enter open · tab actions · ^r refresh
^n new · ^s send · ^x close · ^o PR · ^g move"

dash_next_file() { printf '%s/dash-%s.next\n' "$(runtime_dir)" "${AGENT_HUB_DASH_INST:-$$}"; }
dash_next_set() { printf '%s\n' "$1" > "$(dash_next_file)"; }
dash_msg_file() { printf '%s/dash-%s.msg\n' "$(runtime_dir)" "${AGENT_HUB_DASH_INST:-$$}"; }
dash_msg() { printf '%s\t%s\n' "$(date +%s)" "$1" > "$(dash_msg_file)"; } # shown for a minute
dash_footer() {
  local f ts msg
  f=$(dash_msg_file)
  [ -s "$f" ] || return 0
  IFS=$TAB read -r ts msg < "$f"
  [ $(( $(date +%s) - ${ts:-0} )) -lt 60 ] && printf '%s\n' "$msg"
  return 0
}
dash_rows_file() { printf '%s/dash-%s.rows\n' "$(runtime_dir)" "${AGENT_HUB_DASH_INST:-$$}"; }

# Writes both views ($f.tree, $f.flat); 0 when the one on screen ($f.view) changed.
dash_views() {
  local f view
  f=$(dash_rows_file)
  view=$(cat "$f.view" 2>/dev/null); [ "$view" = flat ] || view=tree
  rows "${AGENT_HUB_DASH_MODE:-popup}" tree "$f.flat.$$" > "$f.tree.$$" 2>/dev/null
  if cmp -s "$f.$view.$$" "$f.$view"; then
    mv "$f.tree.$$" "$f.tree"; mv "$f.flat.$$" "$f.flat"
    return 1
  fi
  mv "$f.tree.$$" "$f.tree"; mv "$f.flat.$$" "$f.flat"
  return 0
}

# Reloads the view on screen; the reload reads the view when it runs, so a switch to the flat view
# made meanwhile (first key typed) still wins.
DASH_RELOAD='track-current+reload-sync(cat "$AGENT_HUB_DASH_ROWS.$(cat "$AGENT_HUB_DASH_ROWS.view")")+refresh-preview'

# Background refresh: prints the fzf actions to apply. Rows are reloaded only when they changed
# (then the footer comes with the `load` event); the preview (the agent's live screen) always.
dash_refresh() {
  local f foot actions='refresh-preview'
  f=$(dash_rows_file)
  foot=$(dash_footer)
  if dash_views; then
    printf '%s\n' "$foot" > "$f.footer"
    actions=$DASH_RELOAD
  elif [ "$foot" != "$(cat "$f.footer" 2>/dev/null)" ]; then
    printf '%s\n' "$foot" > "$f.footer"
    actions="$actions+change-footer:$foot"
  fi
  printf '%s\n' "$actions"
}

# Collapsed groups, shared by every dashboard: one name per line.
dash_collapse() { # dash_collapse <group> <on|off|toggle>
  local f="$(runtime_dir)/collapsed" on=0
  grep -qxF -- "$1" "$f" 2>/dev/null && on=1
  case "$2" in toggle) [ "$on" = 1 ] && set -- "$1" off || set -- "$1" on ;; esac
  if [ "$2" = on ] && [ "$on" = 0 ]; then printf '%s\n' "$1" >> "$f"
  elif [ "$2" = off ] && [ "$on" = 1 ]; then grep -vxF -- "$1" "$f" > "$f.$$"; mv "$f.$$" "$f"; fi
  dash_views >/dev/null
  printf '%s\n' "$DASH_RELOAD"
}

dash_next() {
  local f a='trigger(ctrl-r)'
  f=$(dash_next_file)
  [ -s "$f" ] && a=$(cat "$f")
  rm -f "$f"
  printf '%s\n' "$a"
}

dash_clean_sockets() { # files of dashboards (and GitHub refreshes) that are gone
  local s pid
  for s in "$(runtime_dir)"/dash-*.sock "$(runtime_dir)"/dash-*.rows*; do
    [ -e "$s" ] || continue
    case "$s" in
      *.sock) pid=${s##*-}; pid=${pid%.sock} ;;
      *) pid=${s##*/dash-}; pid=${pid%%.*} ;;
    esac
    kill -0 "$pid" 2>/dev/null || rm -f "$s"
  done
  for s in "$(runtime_dir)"/gh/*.tmp.*; do
    [ -e "$s" ] || continue
    kill -0 "${s##*.}" 2>/dev/null || rm -f "$s"
  done
}

cmd_dash() {
  config_load || true
  case "${1:-}" in
    --hq) dash_loop ;;
    --popup|'') dash_run popup ;;
    --preview) shift; dash_preview "$@" ;;
    --do) shift; dash_do "$@" ;;
    --next) dash_next ;;
    --footer) dash_footer ;;
    --refresh) dash_refresh ;;
    --lines) rows "${AGENT_HUB_DASH_MODE:-popup}" "${AGENT_HUB_DASH_VIEW:-tree}" ;;
    *) die "$EX_ERR" "usage: dash [--hq|--popup]" ;;
  esac
}

dash_loop() { # the hub pane: fzf never stays closed, Ctrl-C included
  trap : INT
  while :; do
    dash_run hq
    sleep 0.3
  done
}

dash_run() { # dash_run <hq|popup>
  local mode=$1 sock esc border
  dash_clean_sockets
  adopt_tasks
  sock="$(runtime_dir)/dash-$mode-$$.sock"
  rm -f "$sock"
  AGENT_HUB_BIN=$(ah_bin) AGENT_HUB_DASH_MODE=$mode AGENT_HUB_DASH_INST=$$
  AGENT_HUB_DASH_ROWS=$(dash_rows_file)
  export AGENT_HUB_BIN AGENT_HUB_DASH_MODE AGENT_HUB_DASH_INST AGENT_HUB_DASH_ROWS
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
  # In the hub, fzf must not exit; the popup has tmux's own border and closes on esc.
  esc='esc:clear-query,ctrl-c:clear-query'
  border='--border=rounded'
  [ "$mode" = popup ] && { esc='esc:abort'; border='--border=none'; }
  dash_footer > "$AGENT_HUB_DASH_ROWS.footer"
  echo tree > "$AGENT_HUB_DASH_ROWS.view"
  rows "$mode" tree "$AGENT_HUB_DASH_ROWS.flat" | tee "$AGENT_HUB_DASH_ROWS.tree" |
  fzf --ansi --layout=reverse --tiebreak=index --no-multi --highlight-line \
    --delimiter='\t' --with-nth=4 --id-nth=2 --listen="$sock" --with-shell='/bin/bash -c' \
    --prompt='❯ ' --info=inline-right --pointer='▌' \
    --color='header:italic:dim,prompt:magenta:bold,pointer:magenta,info:dim,border:dim,separator:dim' \
    --color='label:magenta:bold,hl:yellow:bold,hl+:yellow:bold,gutter:-1,scrollbar:dim,preview-border:dim' \
    --header="$DASH_LEGEND" --header-first \
    "$border" --border-label=' agent-hub ' --border-label-pos=3 \
    --preview='"$AGENT_HUB_BIN" dash --preview {1} {2} {3} {5} {6} {7} {8} {9} {10} {11} {12} {13} {14} {15}' \
    --preview-window='right,55%,border-left,<110(down,50%,border-top)' \
    --bind='ctrl-r:bg-transform:"$AGENT_HUB_BIN" dash --refresh' \
    --bind='change:transform:v=tree; [ -n {q} ] && v=flat; f=$AGENT_HUB_DASH_ROWS; if [ "$(cat "$f.view")" != "$v" ]; then echo "$v" > "$f.view"; echo "reload-sync(cat \"$f.$v\")+first"; else echo first; fi' \
    --bind='right:transform:[ -z {q} ] && [ {1} = g ] && "$AGENT_HUB_BIN" dash --do expand {1} {2} {3} || echo forward-char' \
    --bind='left:transform:[ -z {q} ] && [ {1} = g ] && "$AGENT_HUB_BIN" dash --do collapse {1} {2} {3} || echo backward-char' \
    --bind='load:untrack-current+transform-footer:cat "$AGENT_HUB_DASH_ROWS.footer" 2>/dev/null' \
    --bind='every(5):bg-transform:[ "${FZF_IDLE_TIME:-0}" -ge 2 ] && "$AGENT_HUB_BIN" dash --refresh' \
    --bind='enter,double-click:transform:"$AGENT_HUB_BIN" dash --do open {1} {2} {3}' \
    --bind='alt-enter:transform:"$AGENT_HUB_BIN" dash --do zoom {1} {2} {3}' \
    --bind='ctrl-o:transform:"$AGENT_HUB_BIN" dash --do pr {1} {2} {3} {9} {10} {14} {16}' \
    --bind='tab:execute("$AGENT_HUB_BIN" dash --do menu {1} {2} {3})+transform:"$AGENT_HUB_BIN" dash --next' \
    --bind='ctrl-n:execute("$AGENT_HUB_BIN" dash --do new {1} {2} {3} {17})+transform:"$AGENT_HUB_BIN" dash --next' \
    --bind='ctrl-s:execute("$AGENT_HUB_BIN" dash --do send {1} {2} {3} {5})+transform:"$AGENT_HUB_BIN" dash --next' \
    --bind='ctrl-x:execute("$AGENT_HUB_BIN" dash --do close {1} {2} {3})+transform:"$AGENT_HUB_BIN" dash --next' \
    --bind='ctrl-g:execute("$AGENT_HUB_BIN" dash --do move {1} {2} {3})+transform:"$AGENT_HUB_BIN" dash --next' \
    --bind="$esc" >/dev/null
  rm -f "$sock" "$(dash_next_file)" "$(dash_msg_file)" "$AGENT_HUB_DASH_ROWS".*
}

elapsed() { # elapsed <epoch>
  [ -n "${1:-}" ] || return 0
  local s=$(( $(date +%s) - $1 ))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf 'now'
  elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh' $((s / 3600))
  else printf '%dd' $((s / 86400)); fi
}

dash_capture() { # dash_capture <pane> <lines>: the pane's screen without trailing blank lines
  t capture-pane -p -e -t "$1" 2>/dev/null |
    awk '{ b[NR] = $0; if ($0 ~ /[^ \t]/) last = NR } END { for (i = 1; i <= last; i++) print b[i] }' | tail -n "$2"
}

# dash_preview <kind> <id> <target> <status> <since> <note> <repo> <branch> <worktree> <pr_num>
#              <pr_state> <pr_checks> <pr_url> <title>
dash_preview() {
  local kind=$1 id=$2 target=$3 st=$4 since=$5 note=$6 repo=$7 br=$8 wt=$9
  local prn=${10:-} prs=${11:-} prc=${12:-} title=${14:-} lines=${FZF_PREVIEW_LINES:-40}
  local B='\033[1m' D='\033[2m' R='\033[0m' pr="" tilde='~'
  case "$kind" in
    g)
      if [ "$target" = "*sessions" ]; then
        printf "${B}sessions${R}  ${D}your tmux sessions without agents · enter, ← and → collapse or expand${R}\n\n"
        t list-sessions -F '#{session_name}  #{session_windows} windows  #{?session_attached,(attached),}' 2>/dev/null
      else
        printf "${B}%s${R}  ${D}group (tmux session) · enter, ← and → collapse or expand · ^n adds an agent here${R}\n\n" "$target"
        rows raw | awk -F'\t' -v g="$target" '$2 == g { printf "  %-9s %-28s %-16s %s\n", $4, $3, $6, $7 }'
      fi
      return ;;
    s)
      printf "${B}%s${R}  ${D}tmux session${R}\n${D}%s${R}\n\n" "$target" "$(t display -p -t "=$target:" '#{window_name} · #{pane_current_path}' 2>/dev/null)"
      dash_capture "=$target:" $((lines - 3))
      return ;;
    h)
      printf "${B}hub${R}  %s %s\n${D}the orchestrator: ask it to create, list, move or close agents${R}\n\n" "$st" "$(elapsed "$since")"
      [ "$target" != - ] && dash_capture "$target" $((lines - 3))
      return ;;
  esac
  case "$note" in
    permission_prompt) note=permission ;; elicitation_dialog|agent_needs_input) note=input ;;
    AskUserQuestion) note=question ;; ExitPlanMode) note="plan approval" ;;
  esac
  if [ -n "$prn" ]; then
    pr="PR #$prn $(printf '%s' "$prs" | tr '[:upper:]' '[:lower:]')"
    case "$prc" in pass) pr="$pr · checks ✓" ;; fail) pr="$pr · checks ✗" ;; pending) pr="$pr · checks running" ;; esac
  fi
  local SC
  case "$st" in
    waiting) SC='\033[1;33m' ;; error) SC='\033[1;31m' ;; done) SC='\033[1;36m' ;;
    working|starting) SC='\033[1;32m' ;; *) SC='\033[90m' ;;
  esac
  printf "\033[1;35m%s${R}  ${SC}%s${R} ${D}%s%s${R}\n" "${id#?:}" "$st" "$(elapsed "$since")" "${note:+ · waiting for $note}"
  printf "\033[34m%s${R} ${D}·${R} \033[35m%s${R}%s\n" "$repo" "${br:-?}" "${pr:+  ·  $pr}"
  printf "${D}%s${R}\n" "${wt/#$HOME/$tilde}"
  [ -n "$title" ] && [ "$st" != stopped ] && printf "${D}“%s”${R}\n" "$title"
  printf "${D}%s${R}\n" '──────────────────────────────'
  if [ "$target" = - ] || [ -z "$target" ] || [ "$st" = stopped ]; then
    printf 'Claude is not running. Enter starts it again with the last conversation (claude --continue).\n\n'
    if [ -d "$wt" ]; then
      git -C "$wt" log --oneline --decorate -n 8 2>/dev/null
      git -C "$wt" status --short 2>/dev/null | head -n 10
    fi
  else
    dash_capture "$target" $((lines - 6))
  fi
}

# dash_do <action> <kind> <id> <target> [extra]: open/zoom/pr print fzf actions (transform); the
# others are interactive (execute) and report through the next file.
dash_do() {
  local action=$1 kind=$2 id=$3 target=$4
  shift 4
  case "$action" in
    expand) dash_collapse "$target" off ;;
    collapse) dash_collapse "$target" on ;;
    open) dash_open "$kind" "$id" "$target" 0 ;;
    zoom) dash_open "$kind" "$id" "$target" 1 ;;
    pr) dash_pr "$kind" "$@" ;;
    menu) dash_menu "$kind" "$id" ;;
    new) ui_new_agent "${1:-}" ;;
    send) ui_send "$kind" "$id" "$target" "${1:-}" ;;
    close) ui_close "$kind" "$id" ;;
    move) ui_move "$kind" "$id" ;;
  esac
  return 0
}

dash_open() { # dash_open <kind> <id> <target> <zoom>
  local kind=$1 id=$2 target=$3 zoom=$4 err=""
  case "$kind" in
    g) dash_collapse "$target" toggle; return ;;
    h) ensure_hq >/dev/null 2>&1; err=$(t switch-client -t "=$cfg_hq_session:" 2>&1) ;;
    s) err=$(t switch-client -t "=$target:" 2>&1) ;;
    p) err=$(pane_switch "$target" "$zoom" 2>&1) ;;
    t) if [ "$zoom" = 1 ]; then err=$(cmd_open "${id#t:}" --zoom 2>&1 >/dev/null)
       else err=$(cmd_open "${id#t:}" 2>&1 >/dev/null); fi ;;
    *) return 0 ;;
  esac
  if [ -n "$err" ]; then
    dash_msg "✗ $(printf '%s' "$err" | tail -1 | sed 's/^agent-hub: //')"
    echo 'trigger(ctrl-r)'
  elif [ "${AGENT_HUB_DASH_MODE:-}" = popup ]; then
    echo abort
  else
    echo 'trigger(ctrl-r)'
  fi
}

dash_pr() { # dash_pr <kind> <branch> <worktree> <url> <repo path>
  local kind=$1 br=$2 wt=$3 url=$4 repo=$5
  echo 'trigger(ctrl-r)'
  case "$kind" in t|p) ;; *) dash_msg "pull requests belong to tasks"; return ;; esac
  if [ -z "$url" ] && [ -n "$br" ] && gh_enabled; then
    url=$(cd "${wt:-$repo}" 2>/dev/null && GH_PROMPT_DISABLED=1 gh pr view "$br" --json url -q .url 2>/dev/null)
  fi
  if [ -n "$url" ] && open_url "$url"; then
    dash_msg "opened $url"
  else
    dash_msg "no pull request found for ${br:-this task}"
  fi
}

dash_menu() { # dash_menu <kind> <id>: the Tab menu; it only triggers the dashboard's own keys
  local kind=$1 id=$2 items choice
  case "$kind" in
    t) items="enter${TAB}open  (starts Claude again if it stopped)
alt-enter${TAB}open zoomed
ctrl-s${TAB}send a message
ctrl-o${TAB}open the pull request
ctrl-g${TAB}move to another group
ctrl-x${TAB}close the task (removes its worktree)" ;;
    p) items="enter${TAB}open
alt-enter${TAB}open zoomed
ctrl-s${TAB}send a message" ;;
    g) items="enter${TAB}collapse or expand  (also ← and →)" ;;
    *) items="enter${TAB}open" ;;
  esac
  items="$items
ctrl-n${TAB}new agent
ctrl-r${TAB}refresh"
  ui_menu choice "${id#?:}" "actions · enter: run · esc: back" "$items" && dash_next_set "trigger($choice)"
}

cmd_status_bar() { # compatibility with the v1 `#(agent-hub status-bar)` segment
  t display -p "$(status_format)" 2>/dev/null
}
