---
name: agent-hub
description: agent-hub orchestrator (Claude Code agents in tmux + git worktrees). Use when the user asks to create/open an agent or task, list or check agent status, close a task, move it to another group, or configure agent-hub (branch prefix, repos folder, worktree location).
---

# agent-hub — orchestrator

You operate agent-hub by **calling the `agent-hub` command** via Bash. Do not reimplement git/tmux logic in the conversation: never run `git worktree`, `tmux new-window`, `kill-window`, etc. directly.

Model: **group = tmux session**, **task/agent = window** inside the group, each with its own git worktree and branch. The hub is the `hq` session (configurable).

## Your role in the hub
If this session runs in the hub (`tmux display -p '#S'` equals `agent-hub config get hq_session`, default `hq`), you are **the orchestrator for the whole session**:
- Any request to do work ("let's work on an error in reeltrip", "fix X in Y", "investigate Z") means **create an agent for it** (flow 1). Do **not** read code, run commands in the repo, or do the work yourself; the agent will.
- Pass the user's request as the agent's `--prompt`.
- When invoked with no request (session start), reply in one short line that you're ready and what you can do; nothing else.

Outside the hub (inside a task agent), only use this skill when the user explicitly asks to manage agents.

`agent-hub` exit codes: `0` ok · `1` error/usage · `2` missing dependency · `3` pending work (needs user confirmation) · `4` not found or conflict. Errors are one line on stderr; show them to the user.

## 0. First
- If `agent-hub config show` fails because the config does not exist, run the **setup** (section 6) before anything else.
- If any command exits with `2`, run `agent-hub doctor` and show the result.

## 1. Create an agent
Typical request: "I want an agent to fix X in repo Y".
1. Find out what is missing. Ask with **AskUserQuestion** (clickable options; the user can always type another):
   - **group**: existing sessions (`agent-hub list --format json` → unique `group` values) + "new group". Names: letters, digits, `-`, `_`.
   - **repo**: directories with `.git` inside each folder of `agent-hub config get repos_roots` (`:`-separated), e.g. `ls -d <root>/*/.git`.
   - **task name**: suggest a short kebab-case slug derived from the request (e.g. `fix-login-timeout`).
   Do not ask for what the user already said.
2. Run:
   `agent-hub new --group <G> --repo <R> --task <T> --prompt "<what the agent should do>"`
   (omit `--prompt` if there is nothing to ask the agent yet).
3. Exit `4` = task, branch or folder already exists: ask for another name. Tell the user where it landed (group/task, branch, worktree) using the `created ...` line.

## 2. List / status
`agent-hub list --format json` → summarize per group: who is **waiting** (`waiting`, for how long, from the `since` epoch), **done** (`done`) and **working** (`working`). Put agents waiting for an answer first.

## 3. Close
1. Run `agent-hub close <G>/<T>` (without `--yes`).
2. On exit `3` it printed the pending work (uncommitted changes, unpushed commits, stash). **Show it to the user and ask** (AskUserQuestion) whether to discard it. Only with explicit confirmation run `agent-hub close <G>/<T> --yes`.
3. The branch is kept by default. Ask whether to delete it:
   - `--delete-branch` uses `git branch -d` (only deletes if merged);
   - `--force-delete-branch` (`git branch -D`) **only** if the user explicitly asks to force it.

## 4. Move to another group
`agent-hub move <G>/<T> --to <G2>` (creates the target group if needed).

## 5. Configure
`agent-hub config show` · `agent-hub config get <key>` · `agent-hub config set <key> <value>`.
Keys: `repos_roots` (`:`-separated folders), `branch_prefix` (may be empty: `config set branch_prefix ""`), `base_branch`, `worktree_location` (`sibling` | `subdirectory` | absolute path), `claude_pane_pct`, `hq_session`.
E.g. "change the branch prefix to feat/" → `agent-hub config set branch_prefix feat/`.

## 6. Initial setup
Ask with AskUserQuestion (options + free text):
- **repos folder(s)**: the folder that *contains* the repos, not each repo. Suggest candidates, e.g. folders under `~` with several subdirectories containing `.git` (do not scan the whole disk);
- **branch prefix**: `feature/`, `feat/` or none;
- **worktree location**: `sibling` (`<parent>/<repo>--<task>`), `subdirectory` (`<repo>/.worktrees/<task>`; warn that it must be in the repo's `.gitignore` and **do not** edit `.gitignore` without permission) or an absolute path (`<path>/<repo>/<task>`).
Then: `agent-hub setup --repos-roots <P> --branch-prefix <B> --worktree-location <L>`.

## Rules
- Never pass `--yes` or delete a branch without the user's explicit confirmation in this conversation.
- The user returns to the hub with **Ctrl+Q** from inside a task, and jumps to an agent with Enter in the dashboard (top pane of hq).
