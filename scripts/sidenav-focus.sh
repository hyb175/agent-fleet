#!/usr/bin/env bash
# sidenav-focus.sh <window_id> — give keyboard focus to the window's rail
# (Prefix B). Only the Go rail takes keys (j/k/Enter, w, /, z, Esc); the bash
# rail is display-only, so the key is a no-op there and says why.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
win="${1:?usage: sidenav-focus.sh <window_id>}"
tx() { "${TMUX_BIN:-tmux}" -L "$SOCKET" "$@"; }

read -r pane cmd < <(tx list-panes -t "$win" -F '#{pane_id} #{pane_current_command} #{@fleet-sidenav}' 2>/dev/null \
  | awk '$3=="1"{print $1, $2; exit}') || true
[[ -n "${pane:-}" ]] || { tx display-message "fleet: no rail in this window (prefix+b)" 2>/dev/null; exit 0; }
if [[ "${cmd:-}" != "afui" ]]; then
  tx display-message "fleet: the bash rail takes no keys — AGENT_FLEET_UI=go for focus mode" 2>/dev/null
  exit 0
fi
tx select-pane -t "$pane" 2>/dev/null || true
