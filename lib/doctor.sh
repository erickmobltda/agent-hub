# shellcheck shell=bash
# doctor: dependency and feature checks (SPEC §4).

doctor_link() {
  case "$1" in
    tmux) echo "https://github.com/tmux/tmux/wiki/Installing" ;;
    fzf) echo "https://github.com/junegunn/fzf#installation" ;;
    git) echo "https://git-scm.com/downloads" ;;
    jq) echo "https://jqlang.org/download/" ;;
    curl) echo "https://curl.se/download.html" ;;
    claude) echo "https://code.claude.com/docs/en/setup" ;;
  esac
}

# Prints the version line, or fails if the tool lacks a feature we use.
doctor_probe() {
  case "$1" in
    tmux)
      local sock="agent-hub-doctor-$$" ok=1
      (
        unset TMUX
        tmux -L "$sock" -f /dev/null new-session -d -s probe 2>/dev/null &&
        tmux -L "$sock" set -p -t probe @agent_hub_probe 1 &&
        tmux -L "$sock" bind -n F12 if -F '#{@agent_hub_probe}' '' '' &&
        tmux -L "$sock" display-message -p '#{pane_current_path}' >/dev/null
      ) >/dev/null 2>&1 || ok=0
      tmux -L "$sock" kill-server >/dev/null 2>&1
      [ "$ok" = 1 ] || { echo "tmux lacks set -p / bind -n / if -F"; return 1; }
      tmux -V ;;
    fzf)
      fzf --help 2>&1 | grep -q 'listen=SOCKET_PATH' || { echo "fzf lacks --listen=SOCKET_PATH"; return 1; }
      echo "fzf $(fzf --version)" ;;
    git)
      git worktree -h 2>&1 | grep -q 'git worktree add' || { echo "git lacks worktree"; return 1; }
      git --version ;;
    jq) jq --version ;;
    curl)
      curl --version 2>/dev/null | grep -q 'UnixSockets' || { echo "curl lacks UnixSockets"; return 1; }
      curl --version | head -1 | cut -d' ' -f1-2 ;;
    claude) printf 'claude %s\n' "$(claude --version 2>/dev/null)" ;;
  esac
}

doctor_hooks_policy() {
  local f
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" \
           "${AGENT_HUB_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; do
    [ -f "$f" ] || continue
    if jq -e '(.allowManagedHooksOnly == true) or (.disableAllHooks == true)' "$f" >/dev/null 2>&1; then
      warn "WARN $f disables user hooks (allowManagedHooksOnly/disableAllHooks): status will not update"
    fi
  done
}

cmd_doctor() {
  local dep out missing="" has_brew=0
  command -v brew >/dev/null 2>&1 && has_brew=1
  for dep in tmux fzf git jq curl claude; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      echo "MISSING $dep"
      missing="$missing $dep"
      continue
    fi
    if out=$(doctor_probe "$dep"); then
      echo "ok      $out"
    else
      echo "BROKEN  $dep: $out"
      missing="$missing $dep"
    fi
  done
  echo "info    $(bash --version | head -1)"
  [ "$has_brew" = 1 ] && echo "info    brew $(brew --version 2>/dev/null | head -1)" || echo "info    brew not found (optional)"

  local still=""
  for dep in $missing; do
    if [ "$dep" = claude ] || [ "$has_brew" = 0 ]; then
      echo "install $dep: see $(doctor_link "$dep")"
      [ "$dep" != claude ] && echo "        suggested: brew install $dep (Homebrew: https://brew.sh)"
      still="$still $dep"
    elif [ -t 0 ] && confirm "Install $dep with 'brew install $dep'?"; then
      brew install "$dep" || still="$still $dep"
    else
      echo "install $dep: brew install $dep"
      still="$still $dep"
    fi
  done

  command -v jq >/dev/null 2>&1 && doctor_hooks_policy
  [ -z "$still" ] || die "$EX_DEPS" "missing required dependencies:$still"
  return 0
}
