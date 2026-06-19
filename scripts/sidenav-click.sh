#!/usr/bin/env bash
# sidenav-click.sh <rail_pane_id> <mouse_y>
#
# Invoked by the MouseDown1Pane binding when a sidenav rail is clicked. Maps the
# clicked screen row to a target (an agent pane or a workspace) via the row map
# the rail publishes each frame, then focuses it. Falls back to selecting the
# rail pane if the click didn't land on a row.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
rail="${1:?usage: sidenav-click.sh <rail_pane> <mouse_y>}"
y="${2:-}"

tx() { tmux -L "$SOCKET" "$@"; }

map="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/rows/${rail}.map"
[[ -f "$map" && -n "$y" ]] || { tx select-pane -t "$rail"; exit 0; }

# Look up the clicked row, tolerating an off-by-one in the coordinate origin.
target=""
for cand in "$y" "$((y - 1))" "$((y + 1))"; do
  target="$(awk -v r="$cand" '$1==r {print $2; exit}' "$map")"
  [[ -n "$target" ]] && break
done
[[ -n "$target" ]] || { tx select-pane -t "$rail"; exit 0; }

# Focus the target via the clicking client (explicit, so it works from run-shell).
client="$(tx list-clients -F '#{client_name}' 2>/dev/null | head -1)"
focus_session() { tx switch-client ${client:+-c "$client"} -t "$1"; }

case "$target" in
  PANE:*)
    pane="${target#PANE:}"
    loc="$(tx list-panes -a -F '#{pane_id} #{session_name} #{window_id}' 2>/dev/null \
          | awk -v p="$pane" '$1==p {print $2, $3; exit}')"
    [[ -n "$loc" ]] || exit 0
    "${AGENT_FLEET_ROOT:-}/scripts/status.sh" clear-done "$pane" 2>/dev/null || true
    focus_session "${loc%% *}"
    tx select-window -t "${loc##* }" 2>/dev/null || true
    tx select-pane -t "$pane" 2>/dev/null || true
    ;;
  SESS:*)
    focus_session "${target#SESS:}"
    ;;
esac
