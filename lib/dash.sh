# shellcheck shell=bash
# The dashboard: an agent-deck-style screen made with fzf. The same screen runs in the hub (--hq: full
# screen, never exits) and in the Ctrl+Q popup (--popup: opening something or q closes it).
#
# Left (SESSIONS): groups, i.e. tmux sessions, as a tree with their tasks under them; plain tmux
# sessions in "sessions"; a last "+ new session" row. Right (PREVIEW): the selected item. Letters
# are actions (there is no input line); / opens the search, which shows the flat list instead of the
# tree (fzf only searches what it shows), and Esc closes it.
#
# Rows come from rows.awk (kind id target display + hidden fields, see there). Refreshing never
# blocks typing: `dash --refresh` runs in the background (bg-transform), writes both views to files
# and only asks fzf to reload (from the file of the current view, instantly) when they changed.
# In the hub, actions that ask something open a tmux popup (a dialog) over the dashboard; in the
# Ctrl+Q popup they run through fzf `execute` (tmux can't stack popups) and leave their follow-up
# (refresh, close the popup, another key) in a "next" file that `dash --next` hands back to fzf.
# The header shows the counts per state and the last action's message (dash_msg). It is applied by
# the refresh, after a reload through the `load` event: a change made while fzf reloads with
# tracking on would be lost.

DASH_LETTERS='j,k,h,l,n,r,d,m,s,o,q,v,?,/,tab'
# Leaving the search: clear it, give the letters back their actions, hide the input. fzf undoes a
# query change made in the same action chain as hide-input, so that one comes a moment later.
DASH_SEARCH_OFF="clear-query+rebind($DASH_LETTERS)+bg-transform(echo hide-input)"

dash_keys() { # dash_keys <key> <label>...: key chips, like agent-deck's footer
  local out=""
  while [ $# -gt 1 ]; do out="$out$(printf '\033[7m %s \033[0m %s  ' "$1" "$2")"; shift 2; done
  printf '%s' "$out"
}

dash_next_file() { printf '%s/dash-%s.next\n' "$(runtime_dir)" "${AGENT_HUB_DASH_INST:-$$}"; }
dash_next_set() { printf '%s\n' "$1" > "$(dash_next_file)"; }
dash_msg_file() { printf '%s/dash-%s.msg\n' "$(runtime_dir)" "${AGENT_HUB_DASH_INST:-$$}"; }
dash_msg() { # shown for a minute in the dashboard's header; printed when no dashboard runs this
  [ -n "${AGENT_HUB_DASH_INST:-}" ] || { printf '%s\n' "$1"; return 0; }
  printf '%s\t%s\n' "$(date +%s)" "$1" > "$(dash_msg_file)"
}
dash_lastmsg() {
  local f ts msg
  f=$(dash_msg_file)
  [ -s "$f" ] || return 0
  IFS=$TAB read -r ts msg < "$f"
  [ $(( $(date +%s) - ${ts:-0} )) -lt 60 ] && printf '%s\n' "$msg"
  return 0
}
dash_header() { # the summary line (written by rows.awk), then the last message
  local f msg
  f=$(dash_rows_file)
  cat "$f.summary" 2>/dev/null
  msg=$(dash_lastmsg)
  [ -n "$msg" ] && printf '\033[2m%s\033[0m\n' "$msg"
  return 0
}
dash_rows_file() { printf '%s/dash-%s.rows\n' "$(runtime_dir)" "${AGENT_HUB_DASH_INST:-$$}"; }

# Writes both views ($f.tree, $f.flat); 0 when the one on screen ($f.view) changed.
dash_views() {
  local f view
  f=$(dash_rows_file)
  view=$(cat "$f.view" 2>/dev/null); [ "$view" = flat ] || view=tree
  [ -s "$f.view" ] || echo tree > "$f.view"
  AH_SUMMARY="$f.summary" rows "${AGENT_HUB_DASH_MODE:-popup}" tree "$f.flat.$$" > "$f.tree.$$" 2>/dev/null
  if cmp -s "$f.$view.$$" "$f.$view"; then
    mv "$f.tree.$$" "$f.tree"; mv "$f.flat.$$" "$f.flat"
    return 1
  fi
  mv "$f.tree.$$" "$f.tree"; mv "$f.flat.$$" "$f.flat"
  return 0
}

# Reloads the view on screen; the reload reads the view when it runs, so a switch to the flat view
# made meanwhile (first key typed) still wins.
DASH_RELOAD='track-current+reload-sync(cat "$AGENT_HUB_DASH_ROWS.$(cat "$AGENT_HUB_DASH_ROWS.view" 2>/dev/null || echo tree)")+refresh-preview'

# Fingerprint of the code: a dashboard started before an update keeps its old fzf bindings in
# memory while calling the new scripts, so it closes itself instead (the hub's restarts at once).
dash_stamp() { cat "$AGENT_HUB_HOME"/bin/agent-hub "$AGENT_HUB_HOME"/lib/*.sh "$AGENT_HUB_HOME"/lib/rows.awk 2>/dev/null | cksum; }

# Background refresh: prints the fzf actions to apply. Rows are reloaded only when they changed
# (then the header comes with the `load` event); the preview (the agent's live screen) always.
dash_refresh() {
  local f head actions='refresh-preview'
  if [ -n "${AGENT_HUB_DASH_STAMP:-}" ] && [ "$(dash_stamp)" != "$AGENT_HUB_DASH_STAMP" ]; then
    echo abort
    return
  fi
  f=$(dash_rows_file)
  if dash_views; then
    dash_header > "$f.header"
    actions=$DASH_RELOAD
  else
    head=$(dash_header)
    if [ "$head" != "$(cat "$f.header" 2>/dev/null)" ]; then
      printf '%s\n' "$head" > "$f.header"
      actions='refresh-preview+transform-header:cat "$AGENT_HUB_DASH_ROWS.header"'
    fi
  fi
  printf '%s\n' "$actions"
}

# Where the preview goes, shared by every dashboard and kept across restarts (v switches it): side
# by side, falling back to stacked on narrow panes (fzf's threshold measures the preview, not the
# pane: <55 is a pane under ~100 columns), or always stacked.
DASH_PV_RIGHT='right,55%,border-left,<55(down,55%,border-top)'
DASH_PV_DOWN='down,55%,border-top'
dash_layout() { # dash_layout [toggle]: prints the --preview-window value
  local f cur
  f="$(runtime_dir)/layout"
  cur=$(cat "$f" 2>/dev/null)
  if [ "${1:-}" = toggle ]; then
    [ "$cur" = down ] && cur=right || cur=down
    printf '%s\n' "$cur" > "$f"
  fi
  if [ "$cur" = down ]; then printf '%s\n' "$DASH_PV_DOWN"; else printf '%s\n' "$DASH_PV_RIGHT"; fi
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
    --refresh) dash_refresh ;;
    --dialog) shift; dash_dialog "$@" ;;
    --help) dash_help ;;
    --header) dash_header ;;
    --lines) rows "${AGENT_HUB_DASH_MODE:-popup}" "${AGENT_HUB_DASH_VIEW:-tree}" ;;
    *) die "$EX_ERR" "usage: dash [--hq|--popup]" ;;
  esac
}

dash_loop() { # the hub pane: fzf never stays closed (Ctrl-C included) and restarts on new code
  trap : INT
  dash_run hq
  sleep 0.3
  exec "$(ah_bin)" dash --hq
}

dash_run() { # dash_run <hq|popup>
  local mode=$1 sock esc ctrlc ask global
  dash_clean_sockets
  adopt_tasks
  sock="$(runtime_dir)/dash-$mode-$$.sock"
  rm -f "$sock"
  AGENT_HUB_BIN=$(ah_bin) AGENT_HUB_DASH_MODE=$mode AGENT_HUB_DASH_INST=$$
  AGENT_HUB_DASH_ROWS=$(dash_rows_file) AGENT_HUB_DASH_STAMP=$(dash_stamp)
  export AGENT_HUB_BIN AGENT_HUB_DASH_MODE AGENT_HUB_DASH_INST AGENT_HUB_DASH_ROWS AGENT_HUB_DASH_STAMP
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
  # Footer: the keys of the selected row (chosen on focus, without starting agent-hub).
  global=$(dash_keys / search v layout '?' help q quit)
  AH_KEYS_T="$(dash_keys ⏎ open s send r rename m move d close o PR n new)
$global"
  AH_KEYS_G="$(dash_keys ⏎ fold n 'new here' r rename d delete)
$global"
  AH_KEYS_S="$(dash_keys ⏎ switch d delete n new)
$global"
  AH_KEYS_N="$(dash_keys ⏎ 'new session' j/k move)
$global"
  AH_KEYS_H="$(dash_keys ⏎ 'go to the hub' j/k move)
$global"
  AH_KEYS_SEARCH="$(dash_keys ⏎ open esc 'back to the tree')"
  export AH_KEYS_T AH_KEYS_G AH_KEYS_S AH_KEYS_N AH_KEYS_H AH_KEYS_SEARCH
  esc="if [ \"\$FZF_INPUT_STATE\" != hidden ]; then echo '$DASH_SEARCH_OFF'"
  if [ "$mode" = popup ]; then
    esc="$esc; else echo abort; fi"; ctrlc='ctrl-c:abort'
    # tmux can't open a popup from a popup: here questions run inside this one.
    ask() { printf '%s:execute("$AGENT_HUB_BIN" dash --do %s)+transform:"$AGENT_HUB_BIN" dash --next' "$1" "$2"; }
  else
    esc="$esc; fi"; ctrlc="ctrl-c:transform:$esc"
    ask() { printf '%s:transform:"$AGENT_HUB_BIN" dash --dialog %s' "$1" "$2"; }
  fi
  AH_SUMMARY="$AGENT_HUB_DASH_ROWS.summary" rows "$mode" tree "$AGENT_HUB_DASH_ROWS.flat" > "$AGENT_HUB_DASH_ROWS.tree"
  echo tree > "$AGENT_HUB_DASH_ROWS.view"
  dash_header > "$AGENT_HUB_DASH_ROWS.header"
  fzf --ansi --layout=reverse --tiebreak=index --no-multi --highlight-line --no-input \
    --delimiter='\t' --with-nth=4 --id-nth=2 --listen="$sock" --with-shell='/bin/bash -c' \
    --prompt='/ ' --info=inline-right --pointer='▌' --gutter=' ' --border=none \
    --header="$(cat "$AGENT_HUB_DASH_ROWS.header")" --header-first \
    --list-border=top --list-label=' SESSIONS ' --list-label-pos=2 \
    --footer="$AH_KEYS_N" \
    --color='header:-1,prompt:magenta:bold,pointer:magenta,info:dim,border:dim,separator:dim,list-border:dim' \
    --color='list-label:magenta:bold,preview-label:magenta:bold,hl:yellow:bold,hl+:yellow:bold,gutter:-1' \
    --color='scrollbar:dim,preview-border:dim' \
    --preview='"$AGENT_HUB_BIN" dash --preview {1} {2} {3} {5} {6} {7} {8} {9} {10} {11} {12} {13} {14} {15}' \
    --preview-window="$(dash_layout)" \
    --bind='ctrl-r:bg-transform:"$AGENT_HUB_BIN" dash --refresh' \
    --bind='every(5):bg-transform:[ "${FZF_IDLE_TIME:-0}" -ge 2 ] && "$AGENT_HUB_BIN" dash --refresh' \
    --bind='load:untrack-current+transform-header:cat "$AGENT_HUB_DASH_ROWS.header" 2>/dev/null' \
    --bind='focus:transform-footer:if [ "$FZF_INPUT_STATE" != hidden ]; then printf %s "$AH_KEYS_SEARCH"; else case {1} in t|p) printf %s "$AH_KEYS_T" ;; g) printf %s "$AH_KEYS_G" ;; s) printf %s "$AH_KEYS_S" ;; h) printf %s "$AH_KEYS_H" ;; *) printf %s "$AH_KEYS_N" ;; esac; fi' \
    --bind='change:transform:v=tree; [ -n {q} ] && v=flat; f=$AGENT_HUB_DASH_ROWS; if [ "$(cat "$f.view")" != "$v" ]; then echo "$v" > "$f.view"; echo "reload-sync(cat \"$f.$v\")+first"; else echo first; fi' \
    --bind="/:show-input+unbind($DASH_LETTERS)+transform-footer:printf %s \"\$AH_KEYS_SEARCH\"" \
    --bind="esc:transform:$esc" --bind="$ctrlc" \
    --bind='j:down,k:up' \
    --bind='enter,double-click:transform:"$AGENT_HUB_BIN" dash --do open {1} {2} {3}' \
    --bind='alt-enter:transform:"$AGENT_HUB_BIN" dash --do zoom {1} {2} {3}' \
    --bind='tab:transform:[ {1} = g ] && "$AGENT_HUB_BIN" dash --do fold {1} {2} {3}' \
    --bind='h,left:transform:[ -z {q} ] && [ {1} = g ] && "$AGENT_HUB_BIN" dash --do collapse {1} {2} {3} || { [ "$FZF_INPUT_STATE" != hidden ] && echo backward-char; }' \
    --bind='l,right:transform:[ -z {q} ] && [ {1} = g ] && "$AGENT_HUB_BIN" dash --do expand {1} {2} {3} || { [ "$FZF_INPUT_STATE" != hidden ] && echo forward-char; }' \
    --bind='o:transform:"$AGENT_HUB_BIN" dash --do pr {1} {2} {3} {9} {10} {14} {16}' \
    --bind='q:transform:"$AGENT_HUB_BIN" dash --do quit {1} {2} {3}' \
    --bind='v:transform:"$AGENT_HUB_BIN" dash --do layout {1} {2} {3}' \
    --bind='?:preview:"$AGENT_HUB_BIN" dash --help' \
    --bind="$(ask n 'new {1} {2} {3} {17} {16}')" \
    --bind="$(ask r 'rename {1} {2} {3}')" \
    --bind="$(ask d 'delete {1} {2} {3}')" \
    --bind="$(ask m 'move {1} {2} {3}')" \
    --bind="$(ask s 'send {1} {2} {3} {5}')" \
    < "$AGENT_HUB_DASH_ROWS.tree" >/dev/null
  rm -f "$sock" "$(dash_next_file)" "$(dash_msg_file)" "$AGENT_HUB_DASH_ROWS".*
}

# In the hub, questions open in a tmux popup over the dashboard (it waits until it closes). The
# popup has no border: the fzf inside draws the dialog's frame and title. When the row allows no
# question (d on a group...), the flow only leaves its message, without a popup.
dash_dialog() { # dash_dialog <action> <kind> <id> <target> [extra...]
  local h=18 w=80 ch cw ask=0
  case "$1:$2:$4:${5:-}" in
    rename:g:\*sessions:*|send:?:*:waiting|send:?:*:stopped|send:?:*:) ;;
    new:*|rename:[gt]:*|delete:[ts]:*|move:t:*|send:[tp]:*) ask=1 ;;
  esac
  if [ "$ask" = 0 ]; then dash_do "$@"; echo 'trigger(ctrl-r)'; return; fi
  case "$1" in new) h=20 ;; rename|send) h=8 ;; delete) [ "$2" = t ] && h=26 || h=8 ;; esac
  ch=$(t display -p '#{client_height}' 2>/dev/null); cw=$(t display -p '#{client_width}' 2>/dev/null)
  [ "${ch:-0}" -gt 0 ] && [ "$h" -gt "$ch" ] && h=$ch
  [ "${cw:-0}" -gt 0 ] && [ "$w" -gt "$cw" ] && w=$cw
  t display-popup -E -B -w "$w" -h "$h" -d "$PWD" \
    -e AGENT_HUB_DASH_INST="$AGENT_HUB_DASH_INST" -e AGENT_HUB_DASH_MODE=hq \
    -- "$AGENT_HUB_BIN" dash --do "$@" 2>/dev/null
  echo 'trigger(ctrl-r)'
}

dash_help() {
  local K=$'\033[1;35m' D=$'\033[2m' R=$'\033[0m'
  cat <<EOF
${K}agent-hub${R}  ${D}keys${R}

  ${K}⏎${R}           open (a stopped agent resumes) · fold a group · switch to a session
  ${K}j k ↑ ↓${R}     move
  ${K}Tab ← →${R}     fold / unfold a group
  ${K}n${R}           new session (category → repo → name)
  ${K}r${R}           rename a category or a task
  ${K}d${R}           close a task · delete a plain session
  ${K}m${R}           move a task to another category
  ${K}s${R}           send a message to an agent
  ${K}o${R}           open the pull request
  ${K}/${R}           search (Esc: back to the tree)
  ${K}v${R}           preview on the right or below the list (remembered)
  ${K}alt-⏎${R}       open zoomed
  ${K}^r${R}          refresh
  ${K}q${R}           quit (in the hub: back to the previous session)

${D}States: ◐ waiting for you · ✗ error · ✓ done · ● working · ○ idle · ◌ stopped${R}
EOF
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
  # The heading, drawn here: a left-only border has no top line for an fzf label.
  printf '\033[2m─\033[0m \033[1;35mPREVIEW\033[0m \033[2m%s\033[0m\n' "$(printf '%*s' $(( ${FZF_PREVIEW_COLUMNS:-60} - 11 )) '' | tr ' ' '─')"
  lines=$((lines - 1))
  case "$kind" in
    g)
      if [ "$target" = "*sessions" ]; then
        printf "\033[1;34m▪ sessions${R}\n${D}your tmux sessions without agents${R}\n\n"
        t list-sessions -F '#{session_name}'"$TAB"'#{session_windows}'"$TAB"'#{?session_attached,attached,}' 2>/dev/null |
          awk -F'\t' -v hq="$cfg_hq_session" '$1 != hq { printf "  \033[34m▪\033[0m \033[1m%-16s\033[0m \033[2m%s window%s %s\033[0m\n", $1, $2, ($2 == 1 ? "" : "s"), $3 }'
        printf "\n${D}⏎ fold · on a session: ⏎ switch · d delete${R}\n"
      else
        rows raw | awk -F'\t' -v g="$target" '
          BEGIN { E = "\033["; R = E "0m"; split("waiting error done starting working idle stopped", o, " ")
            c["waiting"] = E "1;33m"; c["error"] = E "1;31m"; c["done"] = E "1;36m"; c["starting"] = E "32m"
            c["working"] = E "1;32m"; c["idle"] = E "37m"; c["stopped"] = E "90m"
            i["waiting"] = "◐"; i["error"] = "✗"; i["done"] = "✓"; i["starting"] = "⟳"; i["working"] = "●"; i["idle"] = "○"; i["stopped"] = "◌" }
          $2 == g { n++; k[$4]++; line[n] = sprintf("  %s%s%s %s%-24s%s %s%-14s%s %s%s%s", c[$4], i[$4], R, E "1m", $3, R, E "34m", $6, R, c[$4], $4, R) }
          END {
            printf "%s📁 %s%s\n", E "1;35m", g, R
            s = n " agent" (n == 1 ? "" : "s")
            for (x = 1; x <= 7; x++) if (k[o[x]]) s = s " · " c[o[x]] i[o[x]] " " k[o[x]] " " o[x] R
            printf "%s\n\n%s── agents ──%s\n", s, E "2m", R
            for (x = 1; x <= n; x++) print line[x]
          }'
        printf "\n${D}⏎ fold · n new session here · r rename · d delete (once it has no tasks)${R}\n"
      fi
      return ;;
    h)
      printf "\033[1;35m⌂ hub${R}  ${D}the %s session${R}\n\n" "$cfg_hq_session"
      printf "This dashboard in full screen: categories and agents on the left, the preview on the right.\n\n"
      printf "${D}⏎ goes there; it is created or repaired if needed. From anywhere: Ctrl+Q, ⏎${R}\n"
      return ;;
    n)
      printf "\033[1;35m+ new session${R}\n\n"
      printf "Opens a small dialog:\n\n  ${B}1${R} category  ${D}an existing one, or type a new one${R}\n"
      printf "  ${B}2${R} repo      ${D}type to filter${R}\n  ${B}3${R} name      ${D}a ticket (PROJ-1234) or a few words${R}\n\n"
      printf "${D}It creates a git worktree and branch for it, starts Claude there and opens it.${R}\n"
      return ;;
    s)
      printf "\033[34m▪${R} ${B}%s${R}  ${D}tmux session${R}\n${D}%s${R}\n\n" "$target" "$(t display -p -t "=$target:" '#{window_name} · #{pane_current_path}' 2>/dev/null)"
      dash_capture "=$target:" $((lines - 3))
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

# dash_do <action> <kind> <id> <target> [extra]: open/zoom/fold/pr/quit print fzf actions
# (transform); the others ask something (in a dialog in the hub, inside the popup otherwise).
dash_do() {
  local action=$1 kind=$2 id=$3 target=$4
  shift 4
  case "$action" in
    expand) dash_collapse "$target" off ;;
    collapse) dash_collapse "$target" on ;;
    fold) dash_collapse "$target" toggle ;;
    open) dash_open "$kind" "$id" "$target" 0 ;;
    zoom) dash_open "$kind" "$id" "$target" 1 ;;
    pr) dash_pr "$kind" "$@" ;;
    quit) dash_quit ;;
    layout) printf 'change-preview-window:%s\n' "$(dash_layout toggle)" ;;
    new) ui_new_agent "${1:-}" "${2:-}" ;;
    rename) ui_rename "$kind" "$id" "$target" ;;
    delete) ui_delete "$kind" "$id" "$target" ;;
    send) ui_send "$kind" "$id" "$target" "${1:-}" ;;
    move) ui_move "$kind" "$id" ;;
  esac
  return 0
}

dash_quit() { # popup: close; hub: back to the session the user came from
  if [ "${AGENT_HUB_DASH_MODE:-}" = popup ]; then echo abort; return; fi
  t switch-client -l 2>/dev/null
  return 0
}

dash_open() { # dash_open <kind> <id> <target> <zoom>
  local kind=$1 id=$2 target=$3 zoom=$4 err=""
  case "$kind" in
    g) dash_collapse "$target" toggle; return ;;
    n) if [ "${FZF_INPUT_STATE:-hidden}" != hidden ]; then echo "$DASH_SEARCH_OFF+trigger(n)"
       else echo 'trigger(n)'; fi
       return ;;
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
  elif [ "${FZF_INPUT_STATE:-hidden}" != hidden ]; then
    echo "$DASH_SEARCH_OFF+trigger(ctrl-r)"
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

cmd_status_bar() { # compatibility with the v1 `#(agent-hub status-bar)` segment
  t display -p "$(status_format)" 2>/dev/null
}
