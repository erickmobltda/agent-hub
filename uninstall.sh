#!/bin/bash
# Removes what install.sh added. Never touches worktrees, branches, sessions or the config file.
set -u
REPO=$(cd -P "$(dirname "$0")" && pwd)
. "$REPO/lib/common.sh"
. "$REPO/lib/install.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-uninstall.XXXXXX")
trap 'rm -rf "$work"' EXIT

settings=$(claude_settings)
if [ -f "$settings" ]; then
  settings_strip < "$settings" > "$work/settings.json" || die "$EX_ERR" "$settings is not valid JSON"
  apply_with_diff "$settings" "$work/settings.json" "settings.json"
fi

conf=$(tmux_conf)
if [ -f "$conf" ]; then
  tmux_block_strip < "$conf" > "$work/tmux.conf"
  apply_with_diff "$conf" "$work/tmux.conf" "tmux.conf"
fi
"$REPO/bin/agent-hub" tmux-uninit && echo "tmux: popup key and status segment removed from the running server"

unlink_ours "$(bin_dir)/agent-hub" "$REPO/bin/agent-hub"
unlink_ours "$(skills_dir)/agent-hub" "$REPO/skill"
echo "done (config kept at $(config_file))"
