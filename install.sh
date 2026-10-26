#!/bin/bash
# Installs agent-hub: symlinks, Claude Code hooks, skill and one line in ~/.tmux.conf.
# Idempotent; every config edit shows a diff, asks, and keeps a backup.
set -u
REPO=$(cd -P "$(dirname "$0")" && pwd)
AGENT_HUB_HOME=$REPO
for f in common install config doctor tmux; do . "$REPO/lib/$f.sh"; done

echo "== doctor"
cmd_doctor --deps || exit

echo "== links"
link "$REPO/bin/agent-hub" "$(bin_dir)/agent-hub"
link "$REPO/skill" "$(skills_dir)/agent-hub"
case ":$PATH:" in *":$(bin_dir):"*) ;; *) warn "$(bin_dir) is not in PATH; add it to your shell profile" ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-install.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo "== Claude Code hooks"
settings=$(claude_settings)
if [ -f "$settings" ]; then
  jq empty "$settings" 2>/dev/null || die "$EX_ERR" "$settings is not valid JSON; fix it first"
  cp "$settings" "$work/settings.in"
else
  echo '{}' > "$work/settings.in"
fi
settings_merge "$(hook_command "$REPO")" < "$work/settings.in" > "$work/settings.json"
apply_with_diff "$settings" "$work/settings.json" "settings.json"

echo "== tmux.conf"
conf=$(tmux_conf)
if [ -f "$conf" ]; then tmux_block_strip < "$conf" > "$work/conf.in"; else : > "$work/conf.in"; fi
tmux_block_append "$REPO" < "$work/conf.in" > "$work/tmux.conf"
if apply_with_diff "$conf" "$work/tmux.conf" "tmux.conf" && t show -gv prefix >/dev/null 2>&1; then
  "$REPO/bin/agent-hub" tmux-init && echo "tmux: popup key and status segment applied to the running server"
fi

config_load || echo "next: agent-hub setup   (then: agent-hub)"
echo "done"
