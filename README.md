# agent-hub

Run many Claude Code agents in parallel inside **your own tmux**, one git worktree and branch per task, and jump between them and your other sessions with **one key**.

- **The hub** (`agent-hub`) is a full-screen dashboard: your categories and their agents as a tree on the left, a live preview on the right, and one-letter keys to create, open, rename, move and close them.
- **Ctrl+Q** anywhere opens the same dashboard as a popup: what each agent is doing, how long it has been waiting, its PR and CI status. Enter jumps there; **Ctrl+Q, Enter** takes you back to the hub.
- **Tasks survive tmux restarts**, with or without tmux-resurrect: the hub repairs itself and Enter brings a stopped agent back with its conversation (`claude --continue`).

Pure bash 3.2 plus tools you already have: tmux ≥ 3.3, fzf ≥ 0.73, git, jq, curl, Claude Code, and optionally gh. No binary, no daemon, no database.

```
 agent-hub   ◐ 1 waiting   ✓ 1 done   ● 1 working          │ ─ PREVIEW ─────────────────────────────
─ SESSIONS ────────────────────────────────────────────────│ dev/backend-api  waiting 5m · Bash
▌ ▾ dev (3) ◐1 ✓1 ●1                                       │ svc-a · feat/backend-api · PR #42 open
    ├─ ◐ backend-api  svc-a  #42 ✓  waiting 5m · Bash      │ ~/code/svc-a--backend-api
    ├─ ✓ frontend     svc-a         done 1h                │ ───────────────────────────────────────
    └─ ● docs         svc-a         working 2m             │ (the agent's live screen)
  ▸ ops (1) ○1                                             │
  ▾ sessions (2)                                           │
    ├─ ▪ 0            1 window   ~/code/agent-hub          │
    └─ ▪ notes        2 windows  ~/notes                   │
  + new session  category → repo → name                    │
───────────────────────────────────────────────────────────│
  ⏎ open  s send  r rename  m move  d close  o PR  n new   │
  / search  v layout  ? help  q quit                       │
```

- **Header:** the agents per state, then the result of the last action.
- **Left:** each category (a tmux session) with its tasks; the ones that need you come first. `▸` is folded. Your other tmux sessions are under `sessions`.
- **Right:** a task's repo, branch, PR and worktree, and the agent's screen; for a category, its agents.
- **Footer:** the keys of the selected row.

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

- **`agent-hub`** opens the hub (creating or repairing it). **Ctrl+Q** opens the same dashboard as a popup from anywhere; `q`, Esc or Ctrl+Q closes it. Its first row, `⌂ hub`, is where the cursor starts, so **Ctrl+Q, Enter** goes to the hub. In the hub, `q` takes you back to the session you came from.
- **Layout:** the preview is on the right, and below the list when the terminal is narrower than about 100 columns. `v` puts it below the list (or back on the right) at any width, and the choice is remembered.
- **New session:** `n`, or Enter on `+ new session`. A small dialog asks three things:
  1. **category:** pick one, or type a new name;
  2. **repo:** type to filter. The repo of the selected task, or of your current directory, comes first;
  3. **name:** a ticket like `PROJ-1234`, or a few words. Spaces and other characters become `-` and case is kept. While you type, the dialog shows the window and branch it becomes: `PROJ-1234 fix login` → `PROJ-1234-fix-login`, branch `feat/PROJ-1234-fix-login`.

  It then creates the worktree and branch, starts Claude there and opens it, so you talk to Claude directly. In a terminal, `agent-hub new` asks the same three things.
- **Rename:** `r` on a category or a task. A task keeps its branch and folder, since Claude may be running there.
- **Delete:** `d` on a task closes it (see below). A category goes away with its last task. `d` on a plain tmux session deletes it after a confirmation.

### Dashboard keys

There is no input line: letters are actions, and `/` opens the search.

| Key | Action |
|---|---|
| ↑ ↓ or j k | move |
| Enter | task: open it (resumes Claude if it stopped) · category: fold or unfold · session: switch to it |
| Tab, ← → or h l | fold or unfold the category |
| n | new session; on a category or one of its tasks, that category comes first |
| r | rename a category or a task |
| d | close a task · delete a plain session |
| m | move a task to another category |
| s | send a message to the agent without leaving the dashboard |
| o | open its pull request |
| / | search by task, category, repo, state or PR. The tree becomes a flat list, so tasks of folded categories are found too. Esc goes back to the tree |
| v | preview on the right or below the list (remembered) |
| Alt+Enter | open zoomed |
| ? | these keys, in the preview |
| q | popup: close it · hub: back to the previous session |
| Ctrl+R | refresh (automatic anyway) |

In the hub, the questions open in a dialog over the dashboard; in the popup they run inside it. Inside a category, waiting agents come first, then failed ones, then those done but not looked at yet. Folded categories are remembered, for the hub and the popup. Opening a `done` agent marks it seen (`idle`).

**`d` on a task / `agent-hub close`** shows what would be lost and lets you pick:
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
| category (`--group` in the CLI) | tmux session |
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
agent-hub rename G NEW | rename G/T NEW
agent-hub dash [--popup|--hq]
agent-hub config show | get K | set K V | edit
agent-hub setup [--repos-roots P] [--branch-prefix B] [--worktree-location L]
agent-hub doctor [--deps]
```

Exit codes: `0` ok · `1` error/usage · `2` missing dependency · `3` needs confirmation (pending work, or the agent is waiting for an answer) · `4` not found or already exists. Without a terminal, `close` never asks: with pending work it stops with exit 3 until you pass `--yes`.

## Troubleshooting

- `agent-hub doctor` checks the dependencies and their versions, the hooks, the popup key, and whether tmux can find `claude`.
- **The hub looks empty** after a reboot: run `agent-hub`, or press Ctrl+Q, Enter. Both rebuild it. With tmux-resurrect it heals by itself after the restore.
- **A hub from before v2.1** still has the orchestrator Claude below the dashboard. It is left alone, since it may hold a conversation you want. To rebuild the hub with the dashboard only: `tmux kill-session -t hq && agent-hub`.
- **Ctrl+Q does nothing:** another program or key binding owns it. `agent-hub doctor` says which; pick another key with `agent-hub config set hub_key prefix:a`.
- **An agent stays `starting`:** Claude is probably asking whether to trust the folder. Open it and answer.
- **Ctrl+Z inside Claude** suspends Claude Code (its own shortcut; undo is Ctrl+_). In an agent pane, agent-hub brings it back at once, so nothing freezes. For shell commands use the pane below it. Agents started before this fix keep the old behavior until Claude restarts there: if one freezes, run `pkill -CONT -f 'claude --name'`.

## Tests

```sh
tests/run.sh                 # everything
tests/run.sh test_hook.sh    # one file
```

Pure bash on an isolated tmux server (`tmux -L ahtest<pid>`), with a temporary HOME, temporary repos with a local bare origin, and stub `claude`, `gh` and `open`. The popup tests attach a real nested tmux client and press Ctrl+Q through it. Every script passes `bash -n` first; `shellcheck` runs when installed.
