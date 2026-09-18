#!/usr/bin/env bash
# sidenav-focus.sh <window_id> — give keyboard focus to the window's rail
# (Prefix B): j/k move, Enter jumps, w waiting only, / filters, z folds,
# Esc returns to the work pane.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
win="${1:?usage: sidenav-focus.sh <window_id>}"
tx() { "${TMUX_BIN:-tmux}" -L "$SOCKET" "$@"; }

pane="$(tx list-panes -t "$win" -F '#{pane_id} #{@fleet-sidenav}' 2>/dev/null | awk '$2=="1"{print $1; exit}')"
[[ -n "$pane" ]] || { tx display-message "fleet: no rail in this window (prefix+b)" 2>/dev/null; exit 0; }
tx select-pane -t "$pane" 2>/dev/null || true
