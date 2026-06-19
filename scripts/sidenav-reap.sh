#!/usr/bin/env bash
# sidenav-reap.sh <window_id>
#
# Invoked when a pane exits. If the only panes left in the window are sidenav
# rails, kill the window — so closing your shell/agent (e.g. Ctrl-D) closes the
# tab fully instead of leaving the rail behind keeping it alive.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
win="${1:-}"
[[ -n "$win" ]] || exit 0

tx() { tmux -L "$SOCKET" "$@"; }

# Per-pane @fleet-sidenav: "1" for a rail, empty for everything else.
panes="$(tx list-panes -t "$win" -F '#{@fleet-sidenav}' 2>/dev/null)" || exit 0
[[ -n "$panes" ]] || exit 0          # window already gone

# Kill the window only if every remaining pane is a rail (no non-"1" line).
if ! grep -qv '^1$' <<<"$panes"; then
  tx kill-window -t "$win" 2>/dev/null || true
fi
