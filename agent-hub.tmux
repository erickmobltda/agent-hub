#!/usr/bin/env bash
# tmux entry point, run from ~/.tmux.conf by install.sh's one line (it also works as a tpm plugin):
# binds the agent-hub popup key and adds the status segment. Silent: run-shell shows any output.
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$dir/bin/agent-hub" tmux-init >/dev/null 2>&1
exit 0
