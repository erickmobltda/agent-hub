# shellcheck shell=bash
# agent-hub run: what a task pane (or the orchestrator pane) runs. tmux starts it directly, so the
# prompt arrives as an argument without any shell parsing. When Claude exits, the pane keeps a
# login shell in the same directory.

ORCH_PROMPT="You are the agent-hub orchestrator, running in the hub (the hq tmux session). \
Manage agents only through the agent-hub CLI, following the agent-hub skill. When the user asks \
for any work (fix, investigate, implement, review...), create an agent for it with \
'agent-hub new ... --prompt' instead of doing the work yourself. Keep replies short."

run_state() { # run_state <status>: this pane's status, as the dashboard shows it
  [ -n "${TMUX_PANE:-}" ] || return 0
  t set -p -t "$TMUX_PANE" @agent_status "$1" \; set -p -t "$TMUX_PANE" @agent_since "$(date +%s)" \; \
    set -p -t "$TMUX_PANE" @agent_note "" 2>/dev/null
}

# run_fg <command...>: runs it as the foreground job of a minimal interactive bash. Claude Code
# suspends itself on Ctrl+Z and waits for `fg`, which nothing in a task pane would ever send: the
# pane froze (each tmux pane is its own session, so the suspend was even silently dropped). bash
# 3.2 only gets control back from a stopped job when it is interactive, so this one is, without
# reading any rc file, and resumes Claude at once.
RUN_FG='set +o history
"$@"; rc=$?
while [ "$rc" -ge 128 ] && [ -n "$(jobs -s)" ]; do
  printf "\r\n\033[2m[agent-hub] Ctrl+Z suspends Claude Code; resuming it (the pane below is a shell).\033[0m\r\n"
  fg >/dev/null; rc=$?
done
exit "$rc"'

run_fg() { /bin/bash --noprofile --norc -i -c "$RUN_FG" agent-hub "$@"; }

cmd_run() { # run agent|orchestrator <name> [--resume] [-- prompt]
  local kind=${1:-} name=${2:-} resume=0 prompt="" has_prompt=0 rc start
  [ $# -ge 2 ] || die "$EX_ERR" "usage: run agent|orchestrator <name> [--resume] [-- prompt]"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) resume=1; shift ;;
      --) prompt=${2:-}; has_prompt=1; break ;;
      *) die "$EX_ERR" "run: unknown option $1" ;;
    esac
  done
  config_load || true
  # A server started from inside Claude would pass this on and make Claude think it is nested.
  unset CLAUDECODE
  trap : INT

  local -a argv
  IFS=' ' read -r -a argv <<EOF
$cfg_agent_cmd
EOF
  [ "${#argv[@]}" -gt 0 ] || argv=(claude)
  argv=("${argv[@]}" --name "$name")
  [ "$kind" = orchestrator ] && argv=("${argv[@]}" --append-system-prompt "$ORCH_PROMPT")

  run_state starting
  if ! command -v "${argv[0]}" >/dev/null 2>&1; then
    printf 'agent-hub: %s not found in PATH (%s). Run: agent-hub doctor\n' "${argv[0]}" "$PATH"
  elif [ "$resume" = 1 ]; then
    start=$SECONDS
    run_fg "${argv[@]}" --continue
    rc=$?
    if [ "$rc" -ne 0 ] && [ $((SECONDS - start)) -lt 5 ]; then
      printf '\nagent-hub: no conversation to continue here; starting a new one\n'
      run_state starting
      run_fg "${argv[@]}"
    fi
  elif [ "$has_prompt" = 1 ]; then
    run_fg "${argv[@]}" "$prompt"
  else
    run_fg "${argv[@]}"
  fi
  run_state stopped
  printf '\n\033[2m[agent-hub] Claude exited. "claude -c" resumes it here, or press Enter on it in the hub.\033[0m\n'
  exec -l "${SHELL:-/bin/sh}"
}
