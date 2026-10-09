# Intake — container-rung (#12)

Date: 2026-09-05. Mode: collapsed. Builds on the isolation ladder (#11).

## Request (issue #12, verbatim scope)

- `container` isolation rung: detection order per repo — `.devcontainer/devcontainer.json`
  if present, else a default hardened image (modeled on Anthropic's reference
  devcontainer: Claude Code + iptables default-deny + allowlist firewall).
- The pane runs the agent interactively inside the container — full PTY,
  identical interaction model to host agents.
- Auth: mount `~/.claude` credentials or pass an OAuth token env var.
- Container lifecycle tied to the task: start on create, stop on terminal state.

Acceptance: devcontainer repo gets its own env, other repos the default image,
both normal-looking fleet agents; attaching shows the real Claude TUI in the
container; default-image egress deny-by-default with documented allowlist.

## Design (collapsed phases 2–3)

Availability: `container_available()` = docker CLI + live daemon. Missing →
visible note + degrade to sandbox (replacing #11's "not built yet" stub), then
the existing sandbox→worktree chain applies.

Detection chain (worktree first — the container mounts it):
1. `<repo>/.devcontainer/devcontainer.json` (or `.devcontainer.json`) AND the
   devcontainer CLI → `devcontainer up` + `devcontainer exec claude …` in the
   pane. The repo's own config owns its guarantees (no firewall promise).
2. Else the default hardened image `af-default`, built on first use from
   `docker/` (visible note): node:22-slim + claude-code + iptables/ipset
   default-deny firewall (allowlist: Anthropic APIs, statsig, sentry, npm
   registry, github). Entrypoint inits the firewall as root, then drops to the
   host uid/gid (`setpriv`) so mounted files keep sane ownership.

Interactive pane = the window command IS `docker run --rm -it …` — the pane
holds the container's PTY directly; kill pane = kill container (--rm reaps).

Mounts (identical host paths inside — the #13 strategy decided now):
- worktree rw; parent repo's `.git` rw (worktree `.git` file points there by
  absolute path; shared object store IS the git handback — commits land on the
  host branch instantly, review flow unchanged).
- `$AF_CACHE_DIR` rw + `$ROOT_DIR/scripts` ro: the hooks overlay path stays
  valid inside, agent-status-hook.sh writes through the mount, host snapshotd
  reads as usual (hook's tmux calls are already command -v-guarded no-ops).
- `~/.claude` rw (token refresh) + `-e CLAUDE_CODE_OAUTH_TOKEN` passthrough;
  `-e HOME` so claude resolves the same paths.
- `-e TMUX_PANE`/`-e AF_TASK_PROMPT` etc. pass through FROM the pane env.

Record: `isolation container` + `container af-<sock>-<tid>` name line.
Lifecycle: task done/drop/clean → `docker stop` the named container (guarded).
`--cap-add NET_ADMIN` only for the default image (its firewall needs it).

Tests: stub-docker (argv-logging fake on PATH) keeps the suite hermetic on both
CI platforms — asserts command construction, mounts, detection order, degrade
notes, record lines, lifecycle stop. No image build in CI. One manual real-
docker smoke locally before ship.

## Out of scope

#13 (session-id capture/restore for container panes, notification edge for
container transitions, review-flow e2e); devcontainer.json parsing without the
CLI; image/volume GC; `--dangerously-skip-permissions` auto-append (documented,
user's call).
