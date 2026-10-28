# shellcheck shell=bash
# doctor: dependencies (and the versions agent-hub needs), then how it is wired into Claude Code
# and tmux. `doctor --deps` stops after the dependencies (install.sh uses it).

doctor_link() {
  case "$1" in
    tmux) echo "https://github.com/tmux/tmux/wiki/Installing" ;;
    fzf) echo "https://github.com/junegunn/fzf#installation" ;;
    git) echo "https://git-scm.com/downloads" ;;
    jq) echo "https://jqlang.org/download/" ;;
    curl) echo "https://curl.se/download.html" ;;
    claude) echo "https://code.claude.com/docs/en/setup" ;;
    gh) echo "https://cli.github.com" ;;
  esac
}

version_ge() { # version_ge <have> <need>: dotted numeric comparison
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0 }'
}

# Prints the version line, or fails with the reason the tool can't be used.
doctor_probe() {
  local v
  case "$1" in
    tmux)
      v=$(tmux -V 2>/dev/null | sed 's/^tmux //; s/^[^0-9]*//; s/[a-z]*$//')
      version_ge "$v" 3.3 || { echo "tmux $v is too old: agent-hub needs 3.3+ (popups)"; return 1; }
      tmux -V ;;
    fzf)
      v=$(fzf --version 2>/dev/null | awk '{ print $1 }')
      version_ge "$v" 0.73 || { echo "fzf $v is too old: agent-hub needs 0.73+"; return 1; }
      echo "fzf $v" ;;
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
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" "$(claude_settings)"; do
    [ -f "$f" ] || continue
    if jq -e '(.allowManagedHooksOnly == true) or (.disableAllHooks == true)' "$f" >/dev/null 2>&1; then
      echo "WARN    $f disables user hooks (allowManagedHooksOnly/disableAllHooks): states will not update"
    fi
  done
}

doctor_hooks() {
  local f events missing="" e cmd
  f=$(claude_settings)
  if [ ! -f "$f" ]; then echo "WARN    no $f: run ./install.sh to add the status hooks"; return; fi
  events=$(jq -r --arg m "$HOOK_MARK" '.hooks // {} | to_entries[]
    | select([.value[]?.hooks[]?.command // ""] | any(contains($m))) | .key' "$f" 2>/dev/null)
  for e in $HOOK_EVENTS; do printf '%s\n' "$events" | grep -qxF "$e" || missing="$missing $e"; done
  cmd=$(jq -r --arg m "$HOOK_MARK" '[.hooks // {} | .[][]?.hooks[]?.command // "" | select(contains($m))][0] // ""' "$f" 2>/dev/null)
  if [ -n "$missing" ]; then
    echo "WARN    status hooks missing for:$missing (run ./install.sh)"
  elif case "$cmd" in *"$AGENT_HUB_HOME/hooks/status-hook.sh"*) false ;; *) true ;; esac; then
    echo "WARN    the status hooks run another copy of agent-hub: $cmd (run ./install.sh from $AGENT_HUB_HOME)"
  elif case "$cmd" in *'|| true'*) false ;; *) true ;; esac; then
    echo "WARN    the status hooks lack '|| true' (a broken hook could block tools): run ./install.sh"
  else
    echo "ok      status hooks installed"
  fi
  doctor_hooks_policy
}

doctor_tmux() {
  local want have cur path first
  if ! t show -gv prefix >/dev/null 2>&1; then
    echo "info    tmux is not running; key binding not checked"
    return
  fi
  want=$(hub_key_spec)
  have=$(t show -gqv @agent_hub_key)
  if [ -z "$want" ]; then
    echo "info    hub_key=off: no popup key (open the hub with: agent-hub)"
  elif [ "$have" = "$want" ]; then
    echo "ok      popup key: $cfg_hub_key"
  else
    cur=$(t list-keys -T "${want%% *}" "${want#* }" 2>/dev/null)
    if [ -n "$cur" ] && ! binding_is_ours "$cur"; then
      echo "WARN    $cfg_hub_key is already bound to something else; pick another key: agent-hub config set hub_key prefix:a"
    elif [ "${want%% *}" = root ] && { [ "${want#* }" = "$(t show -gv prefix)" ] || [ "${want#* }" = "$(t show -gv prefix2)" ]; }; then
      echo "WARN    $cfg_hub_key is your tmux prefix; pick another key: agent-hub config set hub_key prefix:a"
    else
      echo "WARN    popup key not bound: run ./install.sh, then: tmux source-file ~/.tmux.conf"
    fi
  fi
  path=$(t show-environment -g PATH 2>/dev/null | sed 's/^PATH=//')
  first=${cfg_agent_cmd%% *}
  if [ -n "$path" ] && ! PATH=$path command -v "$first" >/dev/null 2>&1; then
    echo "WARN    '$first' is not in tmux's PATH, so agents can't start: restart tmux from a shell where '$first' works"
  else
    echo "ok      tmux finds $first"
  fi
}

cmd_doctor() {
  local dep out missing="" has_brew=0 still=""
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
  if command -v gh >/dev/null 2>&1; then
    if gh auth token >/dev/null 2>&1; then echo "ok      $(gh --version | head -1) (pull request status)"
    else echo "info    gh is not logged in (gh auth login) so no pull request status"; fi
  else
    echo "info    gh not found (optional: pull request status; $(doctor_link gh))"
  fi
  echo "info    $(bash --version | head -1)"

  for dep in $missing; do
    if [ "$dep" = claude ] || [ "$has_brew" = 0 ]; then
      echo "install $dep: see $(doctor_link "$dep")"
      [ "$dep" != claude ] && echo "        suggested: brew install $dep (Homebrew: https://brew.sh)"
      still="$still $dep"
    elif [ -t 0 ] && confirm "Install or upgrade $dep with Homebrew?"; then
      { brew upgrade "$dep" 2>/dev/null || brew install "$dep"; } || still="$still $dep"
    else
      echo "install $dep: brew install $dep (or brew upgrade $dep)"
      still="$still $dep"
    fi
  done
  [ -z "$still" ] || die "$EX_DEPS" "missing required dependencies:$still"
  [ "${1:-}" = --deps ] && return 0

  if config_load; then echo "ok      config $(config_file)"
  else echo "WARN    no config yet: run agent-hub setup"; fi
  command -v jq >/dev/null 2>&1 && doctor_hooks
  doctor_tmux
  return 0
}
