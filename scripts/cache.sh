#!/usr/bin/env bash
# cache.sh — resolve the fleet's cache root and THIS fleet's cache dir.
# Source me (no side effects beyond the two variables + defining
# cache_migrate_default — nothing runs until you call it).
#
# Two fleets on different tmux sockets used to share one cache directory:
# fleet B's fresh-boot purge (bin/agent-fleet's ensure_server) could delete
# fleet A's live pane state, and B's persist-restore could resume A's saved
# layout onto the wrong socket. Scoping the cache dir per socket stops the
# collision at the filesystem level (persist-restore's own in-band socket
# check stays too, as a second line of defense).
#
# AF_CACHE_ROOT is the shared parent; AF_CACHE_DIR is this socket's scoped
# dir under it. Only theme.conf (rendered from AGENT_FLEET_THEME, which is
# socket-independent) stays at AF_CACHE_ROOT directly — see theme.sh's own
# $cache local, which deliberately does not source this file.

AF_CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
_af_cache_socket="${AGENT_FLEET_SOCKET:-agent-fleet}"
_af_cache_socket="${_af_cache_socket//[^A-Za-z0-9._-]/_}"
AF_CACHE_DIR="$AF_CACHE_ROOT/$_af_cache_socket"

# One-time upgrade path: fleets that ran before socket-scoping kept everything
# directly under AF_CACHE_ROOT. Move the known old-layout entries into the
# DEFAULT socket's new scoped dir so an upgrade doesn't strand a live fleet's
# state. Only fires for the default socket name — a custom socket never had a
# pre-scoping layout, since this code ships after socket scoping does — and
# only when the scoped dir doesn't exist yet, so it never runs twice or clobbers
# a fleet that already booted once under the new layout. theme.conf and
# conf/themes are shared across sockets and are never part of this move.
cache_migrate_default() {
  [[ "$_af_cache_socket" == "agent-fleet" ]] || return 0
  # Per-entry and idempotent — NOT gated on the scoped dir existing: a live
  # pre-scoping fleet's own writers (persist-save, focus-track) create the
  # scoped dir before the server ever stops, and a partial move must be
  # resumable on the next run. An entry already present in the scoped dir is
  # newer than its root twin and is never clobbered. `remote/` is deliberately
  # NOT migrated: its pidfiles/snapshots are ephemeral (pollers respawn in
  # seconds) and a migrated stale pidfile would poison the poller dedupe.
  local entries=(panes tasks cache rows fleet.state fleet.snapshot focus.now hooks-settings.json)
  local e
  for e in "${entries[@]}"; do
    if [[ -e "$AF_CACHE_ROOT/$e" && ! -e "$AF_CACHE_DIR/$e" ]]; then
      mkdir -p "$AF_CACHE_DIR" 2>/dev/null || return 0
      mv "$AF_CACHE_ROOT/$e" "$AF_CACHE_DIR/$e" 2>/dev/null || true
    fi
  done
  return 0
}
