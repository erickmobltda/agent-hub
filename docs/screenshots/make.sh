#!/bin/bash
# Regenerates the README screenshots (docs/images/*.png) from a demo: its own tmux server, a
# temporary HOME with fake repos, a fake claude (each task shows a prepared screen) and a fake gh
# (each repo's PRs come from a file). Nothing of yours is read or changed.
# Needs macOS (sips), Google Chrome (headless, draws the PNGs; or set CHROME), python3, and for
# the icons MesloLGS Nerd Font Mono (without it: Menlo, and the icons show as boxes).
# usage: docs/screenshots/make.sh
set -u
HERE=$(cd -P "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
AH=$ROOT/bin/agent-hub
OUT=$ROOT/docs/images
CHROME=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
[ -x "$CHROME" ] || { echo "make.sh: Google Chrome not found; set CHROME" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/ahshots.XXXXXX"); W=$(cd -P "$W" && pwd)
RT=$(mktemp -d /tmp/ahshots-rt.XXXXXX) # short: unix socket paths are limited to 104 bytes
export HOME=$W/home SHELL=/bin/bash TERM=xterm-256color
export AGENT_HUB_TMUX_SOCKET=ahshots$$ AGENT_HUB_CONFIG=$W/config AGENT_HUB_RUNTIME=$RT
export AGENT_HUB_CLAUDE_SETTINGS=$W/settings.json AGENT_HUB_TMUX_CONF=$W/tmux.conf
export AGENT_HUB_STUCK_AFTER=999999 # the fake agents print once and then stay quiet
export DEMO_SCREENS=$W/screens DEMO_PRS=$W/prs PATH=$W/bin:$PATH
unset TMUX TMUX_PANE FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE VISUAL EDITOR
CLIENTS=ahshots-client$$ # popups exist only on a client: one runs inside this second server

tm() { tmux -L "$AGENT_HUB_TMUX_SOCKET" "$@"; }
hm() { tmux -L "$CLIENTS" "$@"; }
cleanup() { hm kill-server 2>/dev/null; tm kill-server 2>/dev/null; rm -rf "$W" "$RT"; }
trap cleanup EXIT

wait_until() { # wait_until <command...>: up to 5 seconds
  local n=0
  while [ $n -lt 50 ]; do "$@" && return 0; sleep 0.1; n=$((n + 1)); done
  echo "make.sh: timed out waiting for: $*" >&2
  return 1
}
sock() { ls "$RT"/dash-"$1"-*.sock 2>/dev/null | head -1; } # sock <hq|popup>: a dashboard's fzf
fzf_post() { curl -s -m 2 --unix-socket "$1" -XPOST http://localhost -d "$2" >/dev/null; }
row_of() { # row_of <socket> <id>: the 1-based row of that item
  curl -s -m 2 --unix-socket "$1" "http://localhost?limit=200" |
    jq -r --arg id "$2" '[.matches[].text | split("\t")[1]] | index($id) // empty | . + 1'
}
has_row() { [ -n "$(row_of "$1" "$2")" ]; }
goto() { # goto <socket> <id>: puts the cursor on that row
  wait_until has_row "$1" "$2" && fzf_post "$1" "pos($(row_of "$1" "$2"))" && sleep 0.8
}
has_sock() { [ -n "$(sock "$1")" ]; }
has_client() { [ -n "$(tm list-clients -F '#{client_name}')" ]; }
has_prs() { ls "$RT"/gh/*.tsv >/dev/null 2>&1; }
on_client() { hm capture-pane -p -t "$CPANE" | grep -qF -- "$1"; }
keys() { tm send-keys -K -c "$CLIENT" "$@"; sleep 0.6; } # typed by the user of the client

render() { # render <name> <capture> <window title>: docs/images/<name>.png
  python3 -I "$HERE/ansi2html.py" "$2" "$W/$1.html" "$3"
  local flags=(--headless=new --disable-gpu --hide-scrollbars --user-data-dir="$W/chrome"
    --force-device-scale-factor=2 --default-background-color=00000000) size
  size=$("$CHROME" "${flags[@]}" --dump-dom "file://$W/$1.html" 2>/dev/null | sed -n 's:.*<title>\([0-9]*x[0-9]*\)</title>.*:\1:p')
  [ -n "$size" ] || { echo "make.sh: could not measure $1" >&2; return 1; }
  "$CHROME" "${flags[@]}" --window-size="${size/x/,}" --screenshot="$W/$1.png" "file://$W/$1.html" >/dev/null 2>&1
  sips --resampleWidth 1760 "$W/$1.png" --out "$OUT/$1.png" >/dev/null # 2x for GitHub's ~880px column
  echo "docs/images/$1.png"
}

# --- the demo world ---
mkdir -p "$HOME/code" "$HOME/notes" "$HOME/dotfiles" "$W/bin" "$OUT"
python3 -I "$HERE/gen.py" "$W"
cat > "$W/bin/claude" <<'EOF'
#!/bin/bash
# Shows the prepared screen of its task (--name group/task) and sets its terminal title.
name=""
while [ $# -gt 0 ]; do [ "$1" = --name ] && name=$2; shift; done
f="$DEMO_SCREENS/${name//\//__}"
printf '\033[H\033[2J'
[ -f "$f.title" ] && printf '\033]2;%s\033\\' "$(cat "$f.title")"
[ -f "$f.ans" ] && cat "$f.ans"
exec sleep 100000
EOF
cat > "$W/bin/gh" <<'EOF'
#!/bin/bash
# Logged in; the PRs of the repo it runs in come from $DEMO_PRS/<repo>.json.
case "${1:-} ${2:-}" in
  "auth token") echo token ;;
  "pr list") cat "$DEMO_PRS/$(basename "$PWD").json" 2>/dev/null || echo '[]' ;;
esac
EOF
for s in open pbcopy idea; do printf '#!/bin/bash\nexit 0\n' > "$W/bin/$s"; done
chmod +x "$W"/bin/*
printf '%s\n' "PS1='\\[\\e[34m\\]\\W\\[\\e[0m\\] \\[\\e[35m\\]❯\\[\\e[0m\\] '" > "$W/bashrc"

repo() { # repo <name> <file...>: one commit, and a bare origin
  local r=$1; shift
  git init -q --bare -b main "$W/remotes/$r.git"
  git init -q -b main "$HOME/code/$r"
  ( cd "$HOME/code/$r" && git config user.email dev@acme.dev && git config user.name Dev &&
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "// $f" > "$f"; done &&
    git add -A && git commit -qm initial && git remote add origin "$W/remotes/$r.git" &&
    git push -q -u origin main && git remote set-head origin main )
}
repo payments-api src/webhooks/refund.ts src/payouts/worker.ts src/money/round.ts
repo mobile-app src/settings/SettingsScreen.tsx src/auth/logout.ts
repo infra Dockerfile ci/build.yml
printf 'repos_roots=%s\nworktree_location=%s\nbranch_prefix=feat/\nbase_branch=main\ngithub=auto\nicons=nerd\n' \
  "$HOME/code" "$HOME/code/.worktrees" > "$AGENT_HUB_CONFIG"

tm -f /dev/null new-session -d -s notes -x 196 -y 56 -c "$HOME/notes" \; \
  set -g default-command "/bin/bash --noprofile --rcfile $W/bashrc" \; set -g default-terminal screen-256color \; \
  set -g default-size 196x56 \; set -g status-style "bg=colour235,fg=colour250" \; \
  set -g status-left "#[fg=colour183,bold] #S #[default] " \; set -g status-left-length 30 \; set -g status-right "" \; \
  set -g window-status-current-style "fg=colour117,bold" \; \
  set -g pane-border-style "fg=colour238" \; set -g pane-active-border-style "fg=colour183"
tm new-session -d -s dotfiles -c "$HOME/dotfiles"
"$AH" tmux-init
for t in payments/payments-api/PAY-412-refund-webhook payments/payments-api/PAY-398-retry-queue \
         payments/payments-api/PAY-377-currency-rounding mobile/mobile-app/MOB-88-dark-mode \
         mobile/mobile-app/MOB-91-crash-on-logout platform/infra/upgrade-node-22 platform/infra/terraform-drift; do
  IFS=/ read -r g r k <<<"$t"
  "$AH" new --group "$g" --repo "$r" --task "$k" >/dev/null 2>&1 || { echo "make.sh: new $t failed" >&2; exit 1; }
done
now=$(date +%s)
state() { # state <group:task> <status> <seconds ago> [why it waits]
  local p
  p=$(tm list-panes -t "=$1" -F '#{pane_id}' | head -1)
  tm set -p -t "$p" @agent_status "$2" \; set -p -t "$p" @agent_since $((now - $3)) \; set -p -t "$p" @agent_note "${4:-}"
}
state payments:PAY-412-refund-webhook waiting 240 Bash
state payments:PAY-398-retry-queue working 72
state payments:PAY-377-currency-rounding done 1080
state mobile:MOB-88-dark-mode working 221
state mobile:MOB-91-crash-on-logout error 3700
state platform:upgrade-node-22 idle 10800
tm kill-window -t =platform:terraform-drift # its window is gone: stopped
wt=$HOME/code/.worktrees/payments-api/PAY-398-retry-queue # work the close menu warns about
mkdir -p "$wt/src/queue"; echo "export const retry = 1" > "$wt/src/queue/retry.ts"; echo "// changed" >> "$wt/src/payouts/worker.ts"
for w in payments:PAY-412-refund-webhook payments:PAY-398-retry-queue payments:PAY-377-currency-rounding mobile:MOB-88-dark-mode; do
  tm send-keys -t "=$w.1" "clear; git status -sb" Enter
done
"$AH" hq >/dev/null 2>&1
wait_until has_sock hq || exit 1
HQ=$(sock hq)
fzf_post "$HQ" 'trigger(ctrl-r)' # loads the PRs (a background gh refresh) and pokes the dashboard
wait_until has_prs; sleep 1.5

# --- the hub, full screen ---
tm resize-window -t =hq: -x 196 -y 36; sleep 1
goto "$HQ" t:payments/PAY-412-refund-webhook
tm capture-pane -p -e -N -t "$(tm list-panes -t =hq -F '#{pane_id}')" > "$W/hub.ans"
render hub "$W/hub.ans" agent-hub

# --- dialogs and the popup, seen by a client ---
hm -f /dev/null new-session -d -s c -x 196 -y 38 "env TERM=screen-256color tmux -L $AGENT_HUB_TMUX_SOCKET attach -t =hq"
wait_until has_client || exit 1
CLIENT=$(tm list-clients -F '#{client_name}' | head -1)
CPANE=$(hm list-panes -t c -F '#{pane_id}')
tm resize-window -A -t =hq:; sleep 1
quiet() { rm -f "$RT"/dash-*.msg; fzf_post "$HQ" 'trigger(ctrl-r)'; sleep 1; } # no message left in the header

goto "$HQ" t:payments/PAY-412-refund-webhook
keys n; wait_until on_client "1/3 category" && keys Enter
wait_until on_client "2/3 repository" && keys Enter
wait_until on_client "3/3 name" && keys -l "PAY-415 partial refunds"
wait_until on_client "PAY-415-partial-refunds"; sleep 0.5
hm capture-pane -p -e -N -t "$CPANE" > "$W/new-session.ans"
render new-session "$W/new-session.ans" agent-hub
keys Escape; quiet

goto "$HQ" t:payments/PAY-398-retry-queue
keys d; wait_until on_client "close payments/PAY-398-retry-queue"; sleep 0.6
hm capture-pane -p -e -N -t "$CPANE" > "$W/close.ans"
render close "$W/close.ans" agent-hub
keys Escape; quiet

tm switch-client -c "$CLIENT" -t =payments:PAY-398-retry-queue; tm resize-window -A -t =payments:PAY-398-retry-queue; sleep 1
keys C-q; wait_until has_sock popup
goto "$(sock popup)" t:payments/PAY-377-currency-rounding
hm capture-pane -p -e -N -t "$CPANE" > "$W/popup.ans"
render popup "$W/popup.ans" "payments · PAY-398-retry-queue"
keys Escape
