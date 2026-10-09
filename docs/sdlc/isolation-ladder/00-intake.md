# Intake — isolation-ladder (#11)

Date: 2026-09-05. Mode: collapsed (design here; single implement+test+review cycle).

## Request (issue #11, verbatim scope)

- Per-repo/per-task isolation setting: `host | sandbox | worktree | container`,
  stored in fleet config (per-repo overrides in `local.conf` or a repo-level file).
- `sandbox` rung: launch the agent with Claude Code's sandboxed-bash configuration
  (settings overlay already exists for hooks — extend it), scoped to the task's
  worktree.
- `af task` respects the repo's default isolation; `--isolation <rung>` overrides.
- Document the ladder and its guarantees in the README.

Acceptance: repo configured `sandbox` spawns agents with sandboxed bash without
touching global Claude settings; isolation visible in task record and rail/picker
detail; clean fallback with a visible note when the platform lacks sandbox deps.

## Design (collapsed phases 2–3)

Ladder (each rung includes the previous ones' guarantees):
`host` (nothing) < `worktree` (git isolation, #4) < `sandbox` (worktree + OS
bash sandbox) < `container` (#12/#13, refused for now with a pointer).

Resolution precedence, per task:
1. `--isolation <rung>` flag (also `--isolated` = worktree, `--no-isolated` =
   host — legacy spellings kept).
2. `AGENT_FLEET_ISOLATION` env (legacy `AGENT_FLEET_TASK_ISOLATED=1` = worktree).
3. Repo-level file `<repo>/.agent-fleet`, line `isolation <rung>` (shareable,
   checked in).
4. Global default file `~/.config/agent-fleet/isolation` (one word).
5. Builtin default `host` (today's behavior with no env set).

Sandbox mechanics (per Claude Code docs research, 2026-09-05 — settings-reference
+ sandboxing pages): per-worktree overlay file = hooks block + `"sandbox":
{enabled, failIfUnavailable: true, autoAllowBashIfSandboxed: true, filesystem:
{allowWrite: [<worktree>]}}`. `--settings` merges over the user's global config
without touching it. Linux deps: bubblewrap AND socat; macOS Seatbelt built-in.
failIfUnavailable TRUE on purpose: if the sandbox breaks past our pre-check
(e.g. Ubuntu 24.04 AppArmor userns restriction), claude refuses to start —
visible in the pane — instead of running unsandboxed while the record says
sandbox. Record carries `sandboxfile <path>` so persist-restore relaunches with
the same overlay (falling back to the hooks overlay if the cache was purged).
Non-claude agent kinds (codex/kimi/opencode) get worktree behavior + a visible
"sandbox is claude-only" note — never a silent no-op.

Fallback: missing platform dep (Linux: bubblewrap; macOS: built-in Seatbelt) →
degrade to `worktree` with a note on stderr, and the RECORD carries the rung
that actually ran (honesty over intent).

Record: `isolation <rung>` line appended at spawn (fields are key-value; old
readers ignore unknown keys). Snapshot A-record grows field 11 `iso` (fields
grow at END, CONTRIBUTING #7); snapshotd reads it from the record in the same
builtin-only walk as intent. Rail/picker show a short suffix (` · sbx` / ` · wt`
/ ` · ctr`) only when the rung is above host.

README: ladder table + what each rung does and does not guarantee.

## Out of scope

Container rung implementation (#12/#13), sandbox for non-claude agent kinds,
per-repo entries in the global config (the repo-level file covers per-repo).
