# shellcheck shell=bash
# Helpers shared by install.sh / uninstall.sh (SPEC §12).

MARK_BEGIN="# >>> agent-hub >>>"
MARK_END="# <<< agent-hub <<<"
HOOK_MARK="# agent-hub"
HOOK_EVENTS="UserPromptSubmit PreToolUse PostToolUse PermissionRequest Notification Stop StopFailure SessionEnd"

claude_settings() { printf '%s\n' "${AGENT_HUB_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
tmux_conf() { printf '%s\n' "${AGENT_HUB_TMUX_CONF:-$HOME/.tmux.conf}"; }
bin_dir() { printf '%s\n' "${AGENT_HUB_BIN_DIR:-$HOME/.local/bin}"; }
skills_dir() { printf '%s\n' "${AGENT_HUB_SKILLS_DIR:-$HOME/.claude/skills}"; }

# settings_strip < json : removes every hook entry carrying our marker.
JQ_STRIP='
  def strip: map(.hooks |= map(select((.command // "") | contains($mark) | not)))
             | map(select(.hooks | length > 0));
  if .hooks then .hooks |= (with_entries(.value |= strip) | with_entries(select(.value | length > 0))) else . end'

settings_strip() { jq --arg mark "$HOOK_MARK" "$JQ_STRIP"; }

# settings_merge <hook_command> < json : idempotent (strip, then add ours).
settings_merge() {
  jq --arg mark "$HOOK_MARK" --arg cmd "$1" --arg events "$HOOK_EVENTS" "$JQ_STRIP"' |
    .hooks = (.hooks // {}) |
    reduce ($events | split(" ")[]) as $e (.;
      .hooks[$e] = ((.hooks[$e] // []) + [
        (if $e == "Notification" then {matcher: "permission_prompt|elicitation_dialog|agent_needs_input"} else {} end)
        + {hooks: [{type: "command", command: $cmd, timeout: 5}]}
      ]))'
}

tmux_block_strip() { # stdin -> stdout without our block
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip'
}

# tmux_block_insert <blockfile> : stdin -> stdout, block placed before the tpm `run` line
# (and before the comment lines right above it), or appended.
tmux_block_insert() {
  awk -v f="$1" '
    { line[NR] = $0 }
    !at && /^[[:space:]]*run(-shell)?[[:space:]].*tpm/ { at = NR }
    END {
      if (at) while (at > 1 && line[at - 1] ~ /^[[:space:]]*#/) at--
      else at = NR + 1
      for (i = 1; i <= NR + 1; i++) {
        if (i == at) { while ((getline l < f) > 0) print l; close(f) }
        if (i <= NR) print line[i]
      }
    }'
}

# apply_with_diff <target> <newfile> <label> : shows the diff, asks, backs up, writes.
apply_with_diff() {
  local target=$1 new=$2 label=$3 old
  old=$target
  [ -f "$target" ] || old=/dev/null
  if cmp -s "$old" "$new"; then
    echo "$label: already up to date"
    return 0
  fi
  echo "---- $label: changes to $target"
  diff -u "$old" "$new"
  if [ "${AGENT_HUB_ASSUME_YES:-0}" != 1 ]; then
    [ -t 0 ] || die "$EX_ERR" "$label: needs confirmation; run interactively"
    confirm "Apply these changes to $target?" || { echo "$label: skipped"; return 1; }
  fi
  if [ -f "$target" ]; then
    cp -p "$target" "$target.agent-hub.bak.$(date +%s)"
    echo "$label: backup at $target.agent-hub.bak.*"
  fi
  mkdir -p "$(dirname "$target")"
  cat "$new" > "$target"
  echo "$label: applied"
}

# link <target> <linkpath> : creates/refreshes a symlink, never replaces a real file.
link() {
  if [ -e "$2" ] && [ ! -L "$2" ]; then
    die "$EX_ERR" "$2 exists and is not a symlink; remove it or move it away"
  fi
  mkdir -p "$(dirname "$2")"
  ln -sfn "$1" "$2"
  echo "linked $2 -> $1"
}

# unlink_ours <linkpath> <expected_target>
unlink_ours() {
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
    rm -f "$1"
    echo "removed $1"
  fi
}
