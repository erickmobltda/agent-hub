#!/bin/bash
# Installs agent-hub: symlinks, Claude Code hooks, skill and a marked block in ~/.tmux.conf.
# Idempotent; every config edit shows a diff, asks, and keeps a backup.
set -u
REPO=$(cd -P "$(dirname "$0")" && pwd)
. "$REPO/lib/common.sh"
. "$REPO/lib/doctor.sh"
. "$REPO/lib/install.sh"

echo "== doctor"
cmd_doctor || exit

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
# `|| true`: a broken hook must never exit 2 (exit 2 on PreToolUse blocks the tool).
hook_cmd="/bin/bash $(printf '%q' "$REPO/hooks/status-hook.sh") || true $HOOK_MARK"
settings_merge "$hook_cmd" < "$work/settings.in" > "$work/settings.json"
apply_with_diff "$settings" "$work/settings.json" "settings.json"

echo "== tmux.conf"
config_load || true
conf=$(tmux_conf)
cat > "$work/block" <<EOF
$MARK_BEGIN
# Managed by agent-hub install.sh; removed by uninstall.sh.
# Ctrl+Q: from an agent-hub group session, jump to the hub; elsewhere pass C-q through.
bind -n C-q if -F '#{@agent_hub}' 'switch-client -t "=$cfg_hq_session:"' 'send-keys C-q'
set -ga status-right '#($(printf '%q' "$REPO/bin/agent-hub") status-bar)'
$MARK_END
EOF
if [ -f "$conf" ]; then tmux_block_strip < "$conf" > "$work/conf.in"; else : > "$work/conf.in"; fi
tmux_block_insert "$work/block" < "$work/conf.in" > "$work/tmux.conf"
if apply_with_diff "$conf" "$work/tmux.conf" "tmux.conf"; then
  echo "reload tmux with: tmux source-file $conf"
fi

config_load || echo "next: agent-hub setup   (then: agent-hub hq)"
echo "done"
