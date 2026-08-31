# Intake — socket-scoped-cache

- **Date:** 2026-08-30
- **Mode:** gated, collapsed (design+plan below)
- **Request:** GitHub issue #14 — socket-scope the state cache so two fleets cannot corrupt each other's records.

## Collapsed design + plan

New sourced lib `scripts/cache.sh`: `AF_CACHE_ROOT` (shared:
`${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet`) and `AF_CACHE_DIR`
(socket-scoped: `$AF_CACHE_ROOT/<sanitized socket name>`). Socket-scoped:
panes/, tasks/, cache/, rows/, remote/, fleet.state, fleet.snapshot,
focus.now, snapshotd.lock, restore.lock, hooks-settings.json (it bakes the
socket into hook commands). Shared (root): theme.conf, connect_branches (a
dir-content cache, socket-independent — stays in the scoped cache/ anyway for
simplicity; only theme.conf must stay shared because the conf sources it by
one exported path).

agent-status-hook.sh derives the scoped dir from its OWN socket ARG (not
env) — the hook is the cross-fleet writer the issue exists to stop.

Migration: one-time, in the CLI before any server interaction, only when
socket == default `agent-fleet`, the scoped dir is absent, and old-layout
files exist at the root — `mv` the known entries into the scoped dir. Doc:
run `agent-fleet reload` (or restart) after upgrading a live fleet.

restore's in-band socket check stays (redundant but harmless, per issue).

Tests: new t-sockets.sh — two sockets side by side: hook writes land in
separate dirs, fleet B's fresh boot doesn't purge fleet A's pane state,
separate snapshots; plus a migration check (fabricated old layout moves
cleanly). Existing suite must stay green (lib.sh's private XDG already
isolates both layouts).

Route: implementer sweep + one correctness reviewer on the diff; release
notes skipped (roadmap issue tracks it).
