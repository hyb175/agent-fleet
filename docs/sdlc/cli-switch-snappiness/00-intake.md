# Intake: cli-switch-snappiness

- Date: 2026-11-05
- Mode: autopilot (`/sdlc:feature --auto`)
- Branch: `cli-switch-snappiness` (from `master` at 58f9820); tree clean at start

## Request (verbatim)

> I care mainly about performance. At this stage in the cli, switch agents panes sometimes lags and can take up to a second or so. We need to be careful about the snappiness here

Follow-up, approving the two fixes proposed below: "let's kick it off then, using the sdlc workflow. We shall see how it work out"

Fixes proposed and approved:

1. When a client attaches or resizes, a background hook sizes every window to that client's size, so a later switch never resizes a window. Windows another client is currently viewing are skipped, so two attached clients of different sizes do not fight.
2. `agent-fleet goto` spends about 17 ms in `status.sh clear-done` even when the agent is not done. Run it only when the agent is actually done, or after the switch.

## Evidence (measured 2026-11-05, Linux i9-12900HK, tmux 3.6a, claude 2.1.318)

- `agent-fleet goto` across workspaces on a throwaway fleet with the real conf, rails running and a client attached: p50 56 ms, max 89 ms. The `pane-focus-in` hook (`scripts/focus-track.sh`) takes 5 ms. A `bash -x` trace attributes 17 ms to `scripts/status.sh clear-done <pane>` at `bin/agent-fleet:886` when the pane is not done.
- A forked resume of a long claude session repainted within 20-60 ms after most window resizes, but about 1 resize in 4 started its repaint 355-644 ms late, and once 1.2 s. Until then tmux shows the old screen. Focus in/out events alone caused no repaint.
- The live fleet had windows at two sizes (188x52 in one workspace, 342x58 elsewhere) under `window-size latest` and `aggressive-resize off`: tmux sizes a window from clients attached to a session containing it, so a switch into a workspace last viewed by a differently sized client resizes all its windows at that moment.
- Proved in a scratch server: `resize-window -t <w> -x W -y H` followed by `set -wu -t <w> window-size` (resize-window sets the per-window option to manual; unsetting restores the global `latest`) pre-sizes a hidden session's windows; a later `switch-client` into that session changed no window size.
- macOS forks cost about 15 ms each (comment in `scripts/status.sh`), so every process saved on the switch path is worth roughly 3x there.

## Constraints

- No issue, ticket or phase numbers in code or comments.
- One-line imperative commit subjects in the repo's `type: what changed` style (`git log --oneline`). Commits follow `references/commits.md`: explicit paths, never pushed.
- NixOS: run tools through `nix-shell -p` (shellcheck 0.11.0 matches CI).
- Minimal code: the smallest change in the right place; reuse existing helpers (`scripts/cache.sh`, `tx` wrappers, `tests/lib.sh`).
- Tests use `tests/lib.sh` (throwaway socket and XDG dirs); nothing may touch the live `agent-fleet` socket.
- Hooks must not block the client: anything slow runs with `run-shell -b`.
- The orchestrator runs `env -u AGENT_FLEET_THEME bin/agent-fleet reload` after the cycle, merges to master and watches CI by SHA only on the user's go-ahead.

## Check command

`bash tests/run-all.sh && nix-shell -p shellcheck --run 'shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh'`

Source: `.github/workflows/ci.yml` (the CI test and shellcheck jobs); no repo instruction file states or forbids a command. The suite needs `bin/afui` (present).

## Outcome

2026-11-05: implemented, tested and reviewed on `cli-switch-snappiness`; not merged.
- The autopilot stopped at gates 9 times (requirements x4, plan x2, implement waves x3, test x1); each stop was fixed by the orchestrator and resumed. The user decided the new-window approach (`default-size`) at the fourth requirements stop.
- Review: 20 findings (1 major, 12 minor, 7 nit); 17 fixed, 3 accepted (06-review.md, Resolution).
- `goto` p50 56 ms -> 29 ms on the intake harness. Switches into pre-sized workspaces resize no window (no-resize probe, 20 switches).
- Open: the bash 3.2 case runs only on CI's macOS job.
