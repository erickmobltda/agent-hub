---
name: agent-hub
description: agent-hub (Claude Code agents in tmux + git worktrees). Use when the user asks to create, open, message, check, close, move or rename an agent or task, asks how the agents are doing, or wants to configure agent-hub (repos folder, worktree location, branch prefix, agent command, popup key).
---

# agent-hub

You operate agent-hub by **calling the `agent-hub` command** via Bash. Never reimplement its git/tmux logic yourself: no `git worktree`, `tmux new-window`, `kill-window`, etc.

Model: **group = tmux session** (the dashboard calls it a category), **task = window** in it, each with its own git worktree and branch (a task is written `<group>/<task>`). The hub is the `hq` session (configurable): a full-screen dashboard. The user moves around with **Ctrl+Q** (the same dashboard as a popup) and Enter.

Use this skill only when the user asks to manage agents or agent-hub; inside a task, do the task's own work.

`agent-hub` exit codes: `0` ok · `1` error/usage · `2` missing dependency · `3` needs the user's confirmation (pending work, or the agent is waiting for an answer) · `4` not found or already exists. Errors are one line on stderr: show them to the user.

Never run bare `agent-hub` (it opens the hub) and never run `agent-hub open` unless the user asks to go to a task: both switch the user's screen.

## 0. First
- If `agent-hub config show` fails because there is no config, run the **setup** (section 7) first.
- If any command exits with `2`, run `agent-hub doctor` and show the result.

## 1. Create an agent
Typical request: "I want an agent to fix X in repo Y".
1. Find out what is missing and ask with **AskUserQuestion** (clickable options; the user can always type another):
   - **group**: the `group` values of `agent-hub list --format json`, plus "new group". Names: letters, digits, `-`, `_`.
   - **repo**: the directories with a `.git` inside each folder of `agent-hub config get repos_roots` (`:`-separated), e.g. `ls -d <root>/*/.git`.
   - **task name**: the ticket if there is one (`PROJ-1234`), else a short kebab-case slug of the request (`fix-login-timeout`). Letters, digits, `-` and `_`; case is kept.
   Do not ask for what the user already said.
2. Run `agent-hub new --group <G> --repo <R> --task <T> --prompt "<what the agent should do>"` (omit `--prompt` when there is nothing to ask yet).
3. Exit `4`: the task, branch or folder already exists; ask for another name. Otherwise tell the user where it landed (group/task, branch, worktree) from the `created ...` line.

## 2. How are the agents doing?
`agent-hub list --format json`: one object per agent with `group`, `task`, `status`, `since` (epoch of the last change), `repo`, `branch`, `running`, `note` (what a waiting agent waits for) and `pr` (`number`, `state`, `checks`, `url`, or null).
- States: `waiting` (needs an answer: permission, question, plan approval) · `error` (the last turn failed) · `done` (finished, not looked at yet) · `working` · `starting` · `idle` · `stopped` (Claude is not running; opening the task resumes it).
- Summarize per group, **waiting first** with how long, then error, done, working. Mention open/merged PRs and failing checks.
- To see what an agent is doing: `agent-hub peek <G>/<T> -n 30` (its screen as text).

## 3. Message an agent
`agent-hub send <G>/<T> "<message>"` types the message into the agent and presses Enter.
- Exit `3`: the agent is waiting for an answer to a permission or question; Enter would answer it. Tell the user to open it (Ctrl+Q, Enter) instead. Use `--force` only if the user explicitly asks.
- Exit `4`: Claude is not running there; suggest opening the task.

## 4. Close
1. Run `agent-hub close <G>/<T>` (without `--yes`).
2. Exit `3`: it printed the pending work (uncommitted changes, unpushed commits, stash, PR state). **Show it and ask** (AskUserQuestion) whether to discard it. Only with explicit confirmation run `agent-hub close <G>/<T> --yes`. A merged PR (`PR #N is MERGED`) explains commits that look unpushed after a squash merge.
3. The branch is kept by default. Ask whether to delete it: `--delete-branch` (`git branch -d`, only if merged), `--force-delete-branch` (`git branch -D`) **only** if the user explicitly asks to force it.

## 5. Move to another group, rename
- `agent-hub move <G>/<T> --to <G2>` (creates the group if needed; works for stopped tasks too).
- `agent-hub rename <G> <new>` renames a group; `agent-hub rename <G>/<T> <new>` renames a task. Names only: the task's branch and folder keep their names. Exit `4`: the name is taken.

## 6. Configure
`agent-hub config show` · `agent-hub config get <key>` · `agent-hub config set <key> <value>`.
Keys: `repos_roots` (`:`-separated folders that contain repos), `worktree_location` (`sibling` | `subdirectory` | absolute path), `branch_prefix` (may be empty: `config set branch_prefix ""`), `base_branch` (empty = the remote's default), `agent_cmd` (e.g. `claude --model opus`), `claude_pane_pct`, `hub_key` (`C-q`, `prefix:<key>` or `off`), `status_bar` (`on`/`off`), `github` (`auto`/`off`), `hq_session`.
E.g. "change the branch prefix to feat/" → `agent-hub config set branch_prefix feat/`.

## 7. Initial setup
Ask with AskUserQuestion (options + free text):
- **repos folder(s)**: the folder that *contains* the repos, not each repo. Suggest candidates, e.g. folders under `~` with several subdirectories containing `.git` (do not scan the whole disk);
- **branch prefix**: `feature/`, `feat/` or none;
- **worktree location**: `sibling` (`<parent>/<repo>--<task>`), `subdirectory` (`<repo>/.worktrees/<task>`; it must be in the repo's `.gitignore`, and **do not** edit `.gitignore` without permission) or an absolute path (`<path>/<repo>/<task>`).
Then: `agent-hub setup --repos-roots <P> --branch-prefix <B> --worktree-location <L>`.

## Rules
- Never pass `--yes`, `--force` or delete a branch without the user's explicit confirmation in this conversation.
- The user opens any agent with **Ctrl+Q** then Enter; in the dashboard, `?` shows the keys.
