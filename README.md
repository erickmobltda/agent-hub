# agent-hub

Run many Claude Code agents in parallel inside **your own tmux**, one git worktree and branch per task, and jump between them and your other sessions with **one key**.

- **Ctrl+Q** anywhere opens a popup with every agent and session: what each agent is doing, how long it has been waiting, its PR and CI status, and a live view of its screen. Type to filter, Enter to jump.
- **The hub** (`agent-hub`) is a tmux session with the same dashboard and an orchestrator Claude you can just talk to: "open an agent to fix the login timeout in svc-auth", "how are the agents doing?", "close fix-login".
- **Tasks survive tmux restarts**, with or without tmux-resurrect: the hub repairs itself and Enter brings a stopped agent back with its conversation (`claude --continue`).

Pure bash 3.2 plus tools you already have: tmux ≥ 3.3, fzf ≥ 0.73, git, jq, curl, Claude Code, and optionally gh. No binary, no daemon, no database.

```
╭─ agent-hub ─────────────────────────────────────╮
│ ⌂ idle     hub                                  │  ← popup only: the orchestrator
│▌◐ waiting  dev/backend-api  svc-a  #42 ●  5m    │  ← waiting for you: first
│ ✓ done     ops/infra        infra  #40 ✓  1h    │
│ ● working  dev/docs         svc-c         2m    │
│ ◌ stopped  bugs/transcript  api           2d    │  ← Enter resumes it
│ ▪ session  0        1 window  ~/code/agent-hub  │  ← your other sessions
╰─────────────────────────────────────────────────╯
  (preview on the right: repo, branch, PR, and the agent's screen)
```

## Install

```sh
git clone <this repo> && cd agent-hub
./install.sh          # shows each change, asks, and backs files up
agent-hub setup       # where your repos are, branch prefix, where worktrees go
agent-hub             # open the hub
```

`install.sh`:
1. Checks the dependencies (`agent-hub doctor --deps`). If something is missing or too old it offers `brew install`/`brew upgrade`, or prints the command.
2. Links `~/.local/bin/agent-hub` → `bin/agent-hub` and `~/.claude/skills/agent-hub` → `skill/`.
3. Adds the status hooks to `~/.claude/settings.json`, keeping the hooks you already have.
4. Adds **one line** at the end of `~/.tmux.conf` (between `# >>> agent-hub >>>` markers): `run-shell '<repo>/agent-hub.tmux'`. If tmux is running, it applies it right away.

Each edit shows the diff, asks first and keeps a `*.agent-hub.bak.<epoch>` backup. Running it again changes nothing. `./uninstall.sh` removes all of it, including from the running tmux, but never touches worktrees, branches, sessions or your config.

### What changes in tmux

The line only runs `agent-hub tmux-init`, which:
- binds `hub_key` (default **Ctrl+Q**, no prefix needed) to the popup. It never replaces a key you already bound, and refuses your prefix key;
- appends ` #{E:@agent_hub_status}` to `status-right` once: `◐2 ✓1 ●3` (waiting, done, working), counted by tmux itself with no extra process. Turn it off with `status_bar=off`;
- if tmux-resurrect is installed and `@resurrect-hook-post-restore-all` is unset, uses it to repair the hub after every restore.

Nothing else is changed: no other options, and no other keys. Agent windows only get `automatic-rename off` so they keep their task name.

## Using it

- **`agent-hub`** opens the hub (creating or repairing it). **Ctrl+Q** opens the popup from anywhere; Ctrl+Q or Esc closes it.
- **New agent:** Ctrl+N in the dashboard, or `agent-hub new` in a terminal. Four short steps:
  1. **repo:** the one you are in comes first;
  2. **group:** pick one or type a new name;
  3. **what to do:** the prompt;
  4. **task name:** suggested from the prompt.

  Or ask the orchestrator.

### Dashboard keys

| Key | Action |
|---|---|
| type | filter by task, group, repo, state or PR |
| Enter | open the agent (resumes Claude if it stopped) |
| Ctrl+Z | open it zoomed |
| Tab | menu with every action for the selected row |
| Ctrl+N | new agent |
| Ctrl+S | send a message to the agent without leaving the dashboard |
| Ctrl+X | close the task (see below) |
| Ctrl+O | open its pull request |
| Ctrl+G | move it to another group |
| Ctrl+R | refresh (automatic anyway) |

The list puts first the agents that need you: waiting, then failed, then done but not looked at yet. Opening a `done` agent marks it seen (`idle`).

**Ctrl+X / `agent-hub close`** shows what would be lost and lets you pick:
- what it checks: uncommitted changes, commits not pushed, stash, and the PR state;
- the choices: cancel, close keeping the branch, or close deleting it;
- `git branch -D` is offered only when the PR is merged.

### States

They come from Claude Code hooks; the hook takes about 20 ms, prints nothing and always exits 0.

| State | When |
|---|---|
| ◐ `waiting` | permission request, question (`AskUserQuestion`), plan approval, MCP input |
| ✗ `error` | the turn ended with an API error (`StopFailure`) |
| ✓ `done` | Claude finished (`Stop`); you haven't opened it since |
| ● `working` | prompt submitted, tools running |
| ⟳ `starting` | Claude launched, no event yet (a trust prompt can keep it here) |
| ○ `idle` | done and seen, or fresh |
| ◌ `stopped` | Claude exited, or the window is gone (tmux restarted) |

`/clear` and compaction keep the agent listed. A Claude you start by hand in any pane shows up too, under its session, until it exits.

## Configuration

`~/.config/agent-hub/config`: `key=value`, parsed, never executed, documented in the file itself. `agent-hub config edit` opens it in `$EDITOR` and validates it; `agent-hub config set <key> <value>` changes one line and keeps your comments.

| Key | Default | |
|---|---|---|
| `repos_roots` | (setup) | folders that **contain** your repos, `:`-separated |
| `worktree_location` | (setup) | `sibling` (`<parent>/<repo>--<task>`), `subdirectory` (`<repo>/.worktrees/<task>`, keep it in `.gitignore`) or an absolute path (`<path>/<repo>/<task>`) |
| `branch_prefix` | (setup) | e.g. `feat/`; may be empty |
| `base_branch` | empty | where new branches start; empty = the remote's default branch |
| `agent_cmd` | `claude` | e.g. `claude --model opus` (split on spaces) |
| `claude_pane_pct` | `70` | height of the Claude pane; a shell pane in the worktree takes the rest |
| `hub_key` | `C-q` | the popup key: `C-q`, `prefix:<key>` (after your prefix) or `off` |
| `status_bar` | `on` | agent counts in `status-right` |
| `github` | `auto` | PR status through `gh` when it is logged in; `off` to never call it |
| `hq_session` | `hq` | name of the hub session |

`hub_key`, `status_bar` and `hq_session` apply to the running tmux at once.

## How it works

| Concept | Where it lives |
|---|---|
| group | tmux session |
| task | tmux window: Claude on top, a shell below, both in the task's worktree |
| state | pane options `@agent_status`, `@agent_since`, `@agent_note` |
| task identity | `group=` / `task=` / `worktree=` in `<repo>/.git/worktrees/<id>/agent-hub`, deleted by git with the worktree |
| repo, branch, PR | read from the worktree's git files and a local `gh` cache |

- **Starting Claude.** tmux runs it directly through `agent-hub run`, so the prompt reaches Claude exactly as written and the user's shell never parses it. When Claude exits, the pane drops to a shell in the same directory.
- **New tasks.** `new` fetches the base branch first, without ever prompting. Offline, it uses the last fetched copy; with no `origin` remote, the local branch. The task branch never tracks the base branch.
- **After a restart.** If tmux restarts, the tasks are still listed (as `stopped`), and Enter re-creates the window or restarts Claude in the restored one. Worktrees an older agent-hub created at its usual path are adopted the same way.
- **PR status.** The dashboard never waits on GitHub. A background job refreshes the PR cache at most once a minute per repo (`gh pr list --author @me`).
- **Environment.** Agents get tmux's environment from when the server started, not a fresh `.zshrc`. `agent-hub doctor` checks that `claude` is on that PATH.

## CLI

```
agent-hub                          open the hub (creates or repairs it)
agent-hub new [--group G --repo R --task T [--prompt P] [--open]]
agent-hub open G/T [--zoom] [--no-switch]
agent-hub send G/T <message> [--force]
agent-hub peek G/T [-n lines]
agent-hub list [--format tsv|json]
agent-hub close G/T [--yes] [--delete-branch] [--force-delete-branch]
agent-hub move G/T --to G2
agent-hub dash [--popup|--hq]
agent-hub config show | get K | set K V | edit
agent-hub setup [--repos-roots P] [--branch-prefix B] [--worktree-location L]
agent-hub doctor [--deps]
```

Exit codes: `0` ok · `1` error/usage · `2` missing dependency · `3` needs confirmation (pending work, or the agent is waiting for an answer) · `4` not found or already exists. Without a terminal, `close` never asks: with pending work it stops with exit 3 until you pass `--yes`.

## Troubleshooting

- `agent-hub doctor` checks the dependencies and their versions, the hooks, the popup key, and whether tmux can find `claude`.
- **The hub looks empty** after a reboot: run `agent-hub`, or press Ctrl+Q and pick the hub row. Both rebuild it. With tmux-resurrect it heals by itself after the restore.
- **Ctrl+Q does nothing:** another program or key binding owns it. `agent-hub doctor` says which; pick another key with `agent-hub config set hub_key prefix:a`.
- **An agent stays `starting`:** Claude is probably asking whether to trust the folder. Open it and answer.

## Tests

```sh
tests/run.sh                 # everything
tests/run.sh test_hook.sh    # one file
```

Pure bash on an isolated tmux server (`tmux -L ahtest<pid>`), with a temporary HOME, temporary repos with a local bare origin, and stub `claude`, `gh` and `open`. The popup tests attach a real nested tmux client and press Ctrl+Q through it. Every script passes `bash -n` first; `shellcheck` runs when installed.
