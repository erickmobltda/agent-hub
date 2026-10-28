# agent-hub — task list

## v2: self-healing hub, Ctrl+Q switcher, tasks that survive restarts

Plan: ~/.claude/plans/quero-que-vc-revise-tidy-lobster.md · branch `feat/hub-v2` · baseline tag `v1`

- [x] 0. Baseline commit + `v1` tag on main (hook command hardened with `|| true`), worktree created
- [ ] 0b. Live `~/.claude/settings.json` hardening — blocked for Claude (self-modification); user runs `./install.sh`
- [x] 1. Test harness: stub claude v2 / stub gh, nested client, fzf socket helpers, `bash -n` + awk gate
- [x] 2. Hook v2 (states, SessionStart/SessionEnd reasons, silent stdout) + settings merge v2 (9 events, matchers, `|| true`)
- [x] 3. Config v2 (new keys, self-documenting file, comment-preserving `set`, `edit`)
- [x] 4. Markers + `lib/rows.awk` + `list` (tsv/json) + status format
- [x] 5. Runner (`agent-hub run`) + `new` / `open` / `send` / `peek`
- [x] 6. `close` / `move` v2
- [x] 7. Adoption of restored / orphan v1 tasks
- [x] 8. `ensure_hq` (self-healing) + `heal` + `agent-hub` with no args
- [x] 9. Dashboard v2 (hub pane + popup, keys, Tab menu, preview, refresh)
- [x] 10. `tmux-init` + `agent-hub.tmux` + install/uninstall (one tmux.conf line) + popup e2e tests
- [x] 11. New-agent wizard + close/send/move flows
- [x] 12. GitHub PR status cache + open PR
- [x] 13. doctor v2
- [x] 14. Docs: README, SKILL.md, SPEC.md
- [x] 15a. Full test run: 292 checks, ALL PASSED
- [x] 15b. Merge to main (fast-forward)
- [ ] 15c. User runs `./install.sh` (settings.json + tmux.conf diffs), then the manual end-to-end check

## v1 (done)

- [x] doctor, config/setup, status hook, new/list/close/move, dash + status-bar, hq + skill, install/uninstall, tests, docs
- [x] Setup UX: fzf picker (arrows + Enter + free-text option), "folder that contains repos", ~ expansion
- [x] All user-facing text in English

## v2.1: agent-deck-style hub (plan: same file, approved 2026-10-26)

- [x] rows.awk: `+ new session` row, header summary; in the popup a first `⌂ hub` row (Ctrl+Q, Enter goes to the hub)
- [x] agents.sh: `rename` (group/task), delete a plain session; repo list without task worktrees
- [x] ui.sh: wizard category → repo → name (namify + live preview), rename/delete flows
- [x] dash.sh: split layout + labels, letter keys, `/` search + Esc, context footer, header summary, q, help; borderless dialogs sized to the client
- [x] hq.sh/run.sh: hub without orchestrator
- [x] preview on the right down to ~100 columns (fzf's `<N(...)` threshold measures the preview, not the terminal)
- [x] tests (dash, popup, hq, wizard, agents, gh): 370 checks pass + docs (README, SKILL, SPEC §18)
- [x] merge to main (local fast-forward)
- [x] user's hub is dashboard-only
- [x] publish: public repo erickmobltda/agent-hub, `main` = v1 baseline (9f53ffc), PR #1 from `feat/hub-v2`
