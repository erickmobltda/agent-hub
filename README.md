# agent-hub

A hub for Claude Code agents on tmux. Each agent runs in its own window, with its own git worktree and branch. Agents are grouped into sessions ("groups"), and the `hq` session shows an fzf dashboard with each agent's state, plus an orchestrator Claude that creates, moves and closes agents on request.

Only bash 3.2 + tmux + fzf + git + jq + curl + official Claude Code hooks/skills. No database, no daemon, no state file: **tmux is the source of truth**.

| Concept | In tmux |
|---|---|
| group / epic | session |
| agent / task | window (Claude 70% on top, shell 30% below, both in the worktree) |
| state | pane option `@agent_status` (`working` / `waiting` / `done`) + `@agent_since` |
| repo, branch | derived via git from the pane's directory |

## Install

```sh
./install.sh
```

1. Runs `doctor`: tmux, fzf, git, jq, curl, claude. If something is missing it offers `brew install` or prints the command.
2. Creates the symlinks `~/.local/bin/agent-hub` → `bin/agent-hub` and `~/.claude/skills/agent-hub` → `skill/`.
3. Adds the status hooks to `~/.claude/settings.json`: **shows the diff, asks, and makes a backup** (`*.agent-hub.bak.<epoch>`). Existing hooks are preserved and reinstalling never duplicates anything.
4. Adds a block between `# >>> agent-hub >>>` and `# <<< agent-hub <<<` to `~/.tmux.conf`, before the tpm lines. Also shows the diff, asks and backs up.
5. If tmux is already running, apply just the two new lines (they only add, nothing you configured is touched):
   ```sh
   tmux bind -n C-q if -F '#{@agent_hub}' 'switch-client -t "=hq:"' 'send-keys C-q'
   tmux set -ga status-right '#(<repo>/bin/agent-hub status-bar)'
   ```
   Otherwise, nothing to do: tmux reads the file on start.

Then run `agent-hub setup` (or ask the orchestrator) and `agent-hub hq`.

To uninstall, run `./uninstall.sh`. It removes only agent-hub's hooks, the `.tmux.conf` block and the symlinks (with diff, confirmation and backup). It never touches worktrees, branches, sessions or the config. To roll back a file completely, restore its `*.agent-hub.bak.<epoch>` backup.

## Usage

- `agent-hub setup` asks three questions; pick with arrows + Enter, or choose "✎ type another value".
- `agent-hub hq` creates or enters the hub session: dashboard on top (list + preview of the selected agent) and the orchestrator Claude below. The orchestrator starts as `claude /agent-hub`, so any work request you type there becomes a new agent instead of being done in the hub.
- Ask the orchestrator things like: "open an agent to fix the login timeout in repo svc-auth", "how are the agents doing?", "close task fix-login", "move task X to group Y" or "change the branch prefix to feat/".
- In the dashboard:
  - **Enter** or **double click**: jump to the agent.
  - **alt-enter**: jump and zoom.
  - **ctrl-r**: reload.
  - Arrows, mouse and typing filter the list.
  - **ctrl-c** quits. In hq the dashboard restarts by itself.
- **Ctrl+Q**, from inside any agent window, goes back to hq. In sessions that are not agent-hub's, C-q is passed through to the program as usual.
- Status bar: `⏳2 ✅1 ⚙ 3` (waiting / done / working), appended to your `status-right`.

### Configuration (`~/.config/agent-hub/config`, `key=value`, never executed)

| Key | Description | Default |
|---|---|---|
| `repos_roots` | folders that contain your repos, `:`-separated | (setup) |
| `branch_prefix` | branch prefix, may be empty | (setup) |
| `base_branch` | base branch | `main` |
| `worktree_location` | `sibling` (`<parent>/<repo>--<task>`), `subdirectory` (`<repo>/.worktrees/<task>`, must be in `.gitignore`) or an absolute path (`<path>/<repo>/<task>`) | (setup) |
| `claude_pane_pct` | height % of the Claude pane | `70` |
| `hq_session` | hub session name | `hq` |

Read or change with `agent-hub config show|get <k>|set <k> <v>`. If you change `hq_session`, run `./install.sh` again to update the Ctrl+Q binding.

### CLI (used by the orchestrator)

```
agent-hub doctor
agent-hub setup [--repos-roots P] [--branch-prefix B] [--worktree-location L]
agent-hub config get|set|show
agent-hub new --group G --repo R --task T [--prompt P]
agent-hub list [--format tsv|json]
agent-hub close G/T [--yes] [--delete-branch] [--force-delete-branch]
agent-hub move G/T --to G2
agent-hub dash | hq | status-bar
```

Exit codes: `0` ok · `1` error/usage · `2` missing dependency · `3` pending work (needs confirmation) · `4` not found or conflict.

`close` without `--yes` refuses (exit 3) if there are uncommitted changes, unpushed commits or stash entries for the branch. The branch is kept by default: `--delete-branch` uses `git branch -d`, and only `--force-delete-branch` uses `-D`.

## States (Claude Code hooks)

| Event | State |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | working |
| `PreToolUse` of `AskUserQuestion` / `ExitPlanMode`, `PermissionRequest`, `Notification` (`permission_prompt`, `elicitation_dialog`, `agent_needs_input`) | waiting |
| `Stop`, `StopFailure` | done |
| `SessionEnd` | cleared (the agent disappears from the dashboard) |

The hook (`hooks/status-hook.sh`) runs in ~20ms, always exits 0 and does nothing outside tmux.

## Known limitations

- **Interrupting with Esc fires no hook**, so the agent stays `working` until the next prompt.
- The Claude Code docs **do not explicitly say** hooks inherit `$TMUX_PANE`. It works because the hook is a child process of Claude, which runs in the pane. Validated by manual testing, not by the docs.
- User options are lost if the tmux server dies. State comes back on the next hook event.
- The status bar segment uses `set -ga status-right`. If your `.tmux.conf` does not redefine `status-right` before the block, each `source-file` appends the segment again.
- `idle_prompt` is ignored on purpose: an idle agent stays `done`.

## tmux-resurrect / continuum

- resurrect restores sessions, windows, panes and directories, but **not** user options. Group, task, repo and branch come back because they are derived. State comes back empty until the next hook, and the agent reappears in the dashboard as soon as Claude fires an event.
- To reopen Claude automatically: `set -g @resurrect-processes '"~claude->claude --continue"'`. **Unconfirmed**: still need to test what name the Claude process shows up as on macOS. Per the CLI docs, `claude -c` continues the most recent conversation in the current directory.

## Tests

```sh
tests/run.sh               # all
tests/run.sh test_hook.sh  # one
```

Tests are pure bash and run on an isolated tmux server (`tmux -L agent-hub-test-<pid>`), with temporary git repos and a local bare remote (no network). A fake `claude` is put on PATH and nothing in your real environment is touched. `shellcheck` runs if installed.
