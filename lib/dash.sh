# shellcheck shell=bash
# dash (fzf dashboard) and status-bar (SPEC §9.1, §9.2).

runtime_dir() { printf '%s\n' "${AGENT_HUB_RUNTIME:-${TMPDIR:-/tmp}/agent-hub}"; }

state_icon() {
  case "$1" in waiting) printf '⏳' ;; done) printf '✅' ;; *) printf '⚙ ' ;; esac
}

elapsed() { # elapsed <epoch>
  local s=$(( $(date +%s) - ${1:-0} ))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh' $((s / 3600))
  else printf '%dd' $((s / 86400)); fi
}

# fzf input: <kind>\t<target>\t<display>  (kind G = group header, A = agent)
dash_lines() {
  local rows g task st since repo branch pane wid path cur="" n w
  rows=$(list_rows)
  [ -n "$rows" ] || { printf 'N\t-\t(no agents yet; ask the orchestrator for one)\n'; return 0; }
  while IFS="$TAB" read -r g task st since repo branch pane wid path; do
    if [ "$g" != "$cur" ]; then
      cur=$g
      n=$(printf '%s\n' "$rows" | awk -F'\t' -v g="$g" '$1 == g' | wc -l | tr -d ' ')
      w=$(printf '%s\n' "$rows" | awk -F'\t' -v g="$g" '$1 == g && $3 == "waiting"' | wc -l | tr -d ' ')
      if [ "$w" -gt 0 ]; then
        printf 'G\t%s\t\033[1m▾ %s (%s) ⏳%s\033[0m\n' "$g" "$g" "$n" "$w"
      else
        printf 'G\t%s\t\033[1m▾ %s (%s)\033[0m\n' "$g" "$g" "$n"
      fi
    fi
    printf 'A\t%s\t  %s %-24s %-16s %s\n' "$pane" "$(state_icon "$st")" "$task" "$repo" "$(elapsed "$since")"
  done <<EOF
$rows
EOF
}

dash_preview() { # dash_preview <kind> <target>
  local lines=${FZF_PREVIEW_LINES:-40}
  case "$1" in
    A) t capture-pane -p -e -t "$2" 2>/dev/null |
         awk '{ buf[NR] = $0; if ($0 ~ /[^ \t]/) last = NR } END { for (i = 1; i <= last; i++) print buf[i] }' |
         tail -n "$lines" ;;
    G) list_rows | awk -F'\t' -v g="$2" '$1 == g { printf "%-8s %-24s %s  %s\n", $3, $2, $5, $6 }' ;;
  esac
}

dash_jump() { # dash_jump <kind> <target> [zoom]
  case "$1" in
    A) local sid wid
       sid=$(t display -p -t "$2" '#{session_id}' 2>/dev/null) || return 0
       wid=$(t display -p -t "$2" '#{window_id}')
       t switch-client -t "$sid" \; select-window -t "$wid" \; select-pane -t "$2"
       if [ "${3:-}" = zoom ] && [ "$(t display -p -t "$2" '#{window_zoomed_flag}')" = 0 ]; then
         t resize-pane -Z -t "$2"
       fi ;;
    G) t switch-client -t "=$2:" ;;
  esac
}

cmd_dash() {
  config_load || true
  case "${1:-}" in
    --lines) dash_lines; return ;;
    --preview) dash_preview "${2:-}" "${3:-}"; return ;;
    --jump) dash_jump "${2:-}" "${3:-}" "${4:-}"; return ;;
  esac

  local dir sock loop_pid
  dir=$(runtime_dir)
  mkdir -p "$dir"
  sock="$dir/dash-$$.sock"
  AGENT_HUB_BIN="$AGENT_HUB_HOME/bin/agent-hub"
  export AGENT_HUB_BIN

  # Light periodic refresh while the dashboard is open (hooks also push reloads).
  (
    while kill -0 $$ 2>/dev/null; do
      sleep 2
      [ -S "$sock" ] && curl -s -m 1 --unix-socket "$sock" -XPOST http://localhost \
        -d 'reload("$AGENT_HUB_BIN" dash --lines)+refresh-preview' >/dev/null 2>&1
    done
  ) &
  loop_pid=$!
  trap 'kill "$loop_pid" 2>/dev/null; rm -f "$sock"' EXIT INT TERM

  dash_lines | fzf --ansi --no-sort --layout=reverse --info=hidden \
    --delimiter='\t' --with-nth=3 --track --id-nth=2 \
    --listen="$sock" --with-shell='/bin/bash -c' \
    --header='enter: go · alt-enter: go+zoom · ctrl-r: reload · ctrl-c: quit' \
    --preview='"$AGENT_HUB_BIN" dash --preview {1} {2}' \
    --preview-window='right,55%,border-left' \
    --bind='enter:execute-silent("$AGENT_HUB_BIN" dash --jump {1} {2})' \
    --bind='double-click:execute-silent("$AGENT_HUB_BIN" dash --jump {1} {2})' \
    --bind='alt-enter:execute-silent("$AGENT_HUB_BIN" dash --jump {1} {2} zoom)' \
    --bind='ctrl-r:reload("$AGENT_HUB_BIN" dash --lines)+refresh-preview' \
    --bind='esc:clear-query'
}

cmd_status_bar() {
  config_load || true
  list_raw | awk -F'\t' '
    { c[$3]++ }
    END {
      out = ""
      if (c["waiting"]) out = out sprintf("⏳%d ", c["waiting"])
      if (c["done"]) out = out sprintf("✅%d ", c["done"])
      if (c["working"]) out = out sprintf("⚙ %d ", c["working"])
      sub(/ $/, "", out)
      if (out != "") printf " %s", out
    }'
}
