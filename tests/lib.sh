# shellcheck shell=bash
# Test helpers: isolated tmux server, temp config, temp git repos. Pure bash.

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AH="$ROOT/bin/agent-hub"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-test.XXXXXX")
TMP=$(cd -P "$TMP" && pwd)

export AGENT_HUB_TMUX_SOCKET="agent-hub-test-$$"
export AGENT_HUB_CONFIG="$TMP/config"
export AGENT_HUB_CLAUDE_SETTINGS="$TMP/settings.json"
export AGENT_HUB_TMUX_CONF="$TMP/tmux.conf"
export AGENT_HUB_RUNTIME="$TMP/run"
unset TMUX TMUX_PANE

# Stub claude: tests must never start the real one.
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/claude" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "0.0.0 (stub)"; exit 0; }
printf '%s\n' "$*" > "${CLAUDE_STUB_LOG:-/dev/null}"
exec cat
EOF
chmod +x "$TMP/stubbin/claude"
export PATH="$TMP/stubbin:$PATH"

FAILS=0
TESTS=0

tm() { tmux -L "$AGENT_HUB_TMUX_SOCKET" "$@"; }

cleanup() {
  tm kill-server >/dev/null 2>&1
  rm -rf "$TMP"
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

finish() {
  [ "$FAILS" = 0 ] && exit 0
  exit 1
}

export CLAUDE_STUB_LOG="$TMP/claude.log"

# Starts the isolated tmux server with a placeholder session. Panes run a bare
# bash so user rc files cannot put the real claude ahead of the stub in PATH.
start_tmux() {
  tm -f /dev/null new-session -d -s scratch -x 200 -y 50 \; \
    set -g default-command "/bin/bash --noprofile --norc" 2>/dev/null
}

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
    git push -q -u origin main
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
