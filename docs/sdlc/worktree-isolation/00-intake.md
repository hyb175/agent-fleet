# Intake — worktree-isolation

- **Date:** 2026-08-31
- **Mode:** gated, collapsed (design+plan below)
- **Request:** GitHub issues #4 (worktree-per-task isolation) + #5 (worktree cleanup lifecycle), approved as one effort, two commits.

## Collapsed design

**#4 — creation.** `af task "<prompt>" --isolated` (env default
`AGENT_FLEET_TASK_ISOLATED=1`; per-repo config deferred until a per-repo
config exists). When the target dir is a git repo: create branch
`af/task/<slug>` (numeric suffix on collision) and a worktree at
`${XDG_STATE_HOME:-~/.local/state}/agent-fleet/worktrees/<repo-basename>-<4-char
path hash>/<slug>`; agent starts in the worktree; task record gains
`worktree <path>` + `branch <name>` lines. Non-git dir: warn to stderr,
degrade to shared checkout (issue requires graceful). Rail/picker branch
labels need no work — git_branch() resolves inside a worktree. Kill leaves
the worktree (that's #5's job).

**#5 — lifecycle.** New subverbs:
- `af task done <id|%pane>` / `af task drop <id|%pane>` — append terminal
  `state merged|abandoned <epoch>` history; print a cleanup hint. (Issue #9's
  review flow will call these later.)
- `af task clean [<id|%pane>] [--dry-run] [--force] [--keep-branch]` — no arg
  sweeps every terminal task with a recorded worktree. Safety: `git worktree
  remove` without `--force` (git itself refuses dirty trees) + a
  branch-merged check (`git merge-base --is-ancestor`) before `git branch -d`;
  `--force` upgrades to `worktree remove --force` + `branch -D`. Never
  touches non-terminal tasks. Appends `state cleaned` on success.
- `af task ls` grows a worktree column: branch plus `*` (dirty) / `^`
  (unmerged) markers, and lists orphaned worktrees (dirs under the worktree
  root with no matching record) at the end.

Route: implement inline, tests in new t-worktree.sh (isolation, degrade,
record fields, done/drop/clean safety incl. dirty-refusal + force,
dry-run, orphan listing), one correctness reviewer over both commits,
release notes skipped (issues track it).
