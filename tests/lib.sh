# shellcheck shell=bash
# Test helpers: isolated tmux server, temporary HOME/config/repos, stub claude, gh and open.
# Pure bash; nothing in the real environment is read or touched.

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AH="$ROOT/bin/agent-hub"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-test.XXXXXX")
TMP=$(cd -P "$TMP" && pwd)
# Unix socket paths are limited to 104 bytes on macOS, so the runtime dir stays short.
RUN=$(mktemp -d /tmp/ahrt.XXXXXX)

export AGENT_HUB_TMUX_SOCKET="ahtest$$"
export AGENT_HUB_CONFIG="$TMP/config"
export AGENT_HUB_CLAUDE_SETTINGS="$TMP/settings.json"
export AGENT_HUB_TMUX_CONF="$TMP/tmux.conf"
export AGENT_HUB_RUNTIME="$RUN"
export HOME="$TMP/home" SHELL=/bin/bash
export CLAUDE_STUB_LOG="$TMP/claude.log" GH_STUB_LOG="$TMP/gh.log" OPEN_STUB_LOG="$TMP/open.log"
mkdir -p "$HOME"
unset TMUX TMUX_PANE CLAUDECODE FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE GH_STUB_JSON GH_STUB_URL VISUAL EDITOR

# Stubs: tests must never start the real claude, call GitHub or open a browser.
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/claude" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "9.9.9 (stub)"; exit 0; }
{ echo "---"; for a in "$@"; do printf '<%s>\n' "$a"; done; } >> "${CLAUDE_STUB_LOG:-/dev/null}"
for a in "$@"; do
  [ "$a" = --continue ] && [ "${CLAUDE_STUB_NO_CONVO:-0}" = 1 ] && { echo "No conversation found to continue"; exit 1; }
done
echo "claude stub running"
while IFS= read -r line; do
  echo "got:$line"
  if [ "$line" = SUSPEND ]; then # what Claude Code does on Ctrl+Z: suspend itself, wait for fg
    cont=""; trap 'cont=1' CONT
    kill -TSTP $$
    while [ -z "$cont" ]; do sleep 0.1; done
    echo "stub resumed"
  fi
done
EOF
cat > "$TMP/stubbin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "${GH_STUB_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "auth token") [ "${GH_STUB_AUTH:-1}" = 1 ] && { echo tok; exit 0; }; exit 1 ;;
  "pr list") [ -n "${GH_STUB_JSON:-}" ] && cat "$GH_STUB_JSON"; exit 0 ;;
  "pr view") [ -n "${GH_STUB_URL:-}" ] && { echo "$GH_STUB_URL"; exit 0; }; echo "no pull requests found" >&2; exit 1 ;;
  "--version "*) echo "gh version 0.0.0 (stub)" ;;
esac
exit 0
EOF
cat > "$TMP/stubbin/open" <<'EOF'
#!/bin/bash
echo "$*" >> "${OPEN_STUB_LOG:-/dev/null}"
EOF
chmod +x "$TMP/stubbin/claude" "$TMP/stubbin/gh" "$TMP/stubbin/open"
export PATH="$TMP/stubbin:$PATH"

FAILS=0
TESTS=0

tm() { tmux -L "$AGENT_HUB_TMUX_SOCKET" "$@"; }

cleanup() {
  tm kill-server >/dev/null 2>&1
  rm -rf "$TMP" "$RUN"
}
trap cleanup EXIT

ok() { TESTS=$((TESTS + 1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq() { # assert_eq <expected> <actual> <name>
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3" "expected [$1] got [$2]"; fi
}
assert_contains() { # assert_contains <haystack> <needle> <name>
  case "$1" in *"$2"*) ok "$3" ;; *) fail "$3" "[$2] not in [$1]" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "$3" "[$2] found in [$1]" ;; *) ok "$3" ;; esac
}
check() { # check <name> <command...>: ok when the command succeeds
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

finish() {
  [ "$FAILS" = 0 ] && exit 0
  exit 1
}

# Starts the isolated tmux server with a placeholder session. Panes run a bare bash so user rc
# files cannot put the real claude ahead of the stub in PATH; TERM=screen exists on macOS.
start_tmux() {
  tm -f /dev/null new-session -d -s scratch -x 200 -y 50 \; \
    set -g default-command "/bin/bash --noprofile --norc" \; set -g default-terminal screen 2>/dev/null
}

# start_client <session>: a real tmux client attached to <session>, run from a pane of the
# "harness" session (a nested client, so popups and switch-client can be tested). Prints its name.
start_client() {
  local before c n=0
  before=$(tm list-clients -F '#{client_name}' 2>/dev/null)
  tm has-session -t =harness 2>/dev/null || tm new-session -d -s harness -x 220 -y 60
  tm new-window -d -t harness: /bin/bash -c "env -u TMUX tmux -L $AGENT_HUB_TMUX_SOCKET attach -t '=$1'"
  while [ "$n" -lt 50 ]; do
    c=$(tm list-clients -F '#{client_name}' 2>/dev/null | grep -vxF "$before" | head -1)
    [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

client_session() { tm display -p -c "$1" '#{client_session}'; }
client_pane() { tm display -p -c "$1" '#{pane_id}'; }
# client_screen <client>: what the client shows, popups included (the harness pane it runs in).
client_screen() {
  local pid
  pid=$(tm display -p -c "$1" '#{client_pid}')
  tm capture-pane -p -t "$(tm list-panes -a -F '#{pane_pid} #{pane_id}' | awk -v p="$pid" '$1 == p { print $2; exit }')"
}
client_has() { client_screen "$1" | grep -qF -- "$2"; } # client_has <client> <text>
client_keys() { local c=$1; shift; tm send-keys -K -c "$c" "$@"; } # typed by the user of <client>

# wait_for <seconds> <command...>: polls until the command succeeds.
wait_for() {
  local n=$(($1 * 10)); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}

# make_repo <root> <name>: repo with one commit on main and a local bare "origin".
make_repo() {
  local root=$1 name=$2
  mkdir -p "$root"
  git init -q --bare -b main "$TMP/remotes/$name.git"
  git init -q -b main "$root/$name"
  (
    cd "$root/$name" &&
    git config user.email t@t && git config user.name t &&
    echo hi > README && git add README && git commit -qm init &&
    git remote add origin "$TMP/remotes/$name.git" &&
    git push -q -u origin main &&
    git remote set-head origin main
  )
}

write_config() { # write_config key=value ...
  : > "$AGENT_HUB_CONFIG"
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$AGENT_HUB_CONFIG"; done
}

# Fakes a hook event for a pane, as Claude Code would run it inside that pane.
fire_hook() { # fire_hook <pane> <json>
  local sock
  sock=$(tm display -p '#{socket_path}')
  printf '%s' "$2" | TMUX_PANE="$1" TMUX="$sock,0,0" bash "$ROOT/hooks/status-hook.sh"
}

pane_opt() { tm show -pqv -t "$1" "$2"; } # pane_opt <pane> <@option>

# The Claude pane of a task window (the first pane).
task_pane() { tm list-panes -t "=$1" -F '#{pane_id}' 2>/dev/null | head -1; }

strip_ansi() { sed "s/$(printf '\033')\\[[0-9;]*m//g"; }

# fzf dashboards, driven through their --listen socket.
dash_sock() { ls "$AGENT_HUB_RUNTIME"/dash-"$1"-*.sock 2>/dev/null | head -1; }
fzf_get() { curl -s -m 2 --unix-socket "$1" "http://localhost?limit=${2:-100}"; }
fzf_post() { curl -s -m 2 --unix-socket "$1" -XPOST http://localhost -d "$2"; }
fzf_lines() { fzf_get "$1" | jq -r '.matches[].text' | strip_ansi; }
fzf_current() { fzf_get "$1" | jq -r '.current.text // ""' | strip_ansi; }
