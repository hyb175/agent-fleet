#!/usr/bin/env bash
# sidenav-reap.sh <window_id>
#
# Invoked when a pane exits. If the only panes left in the window are sidenav
# rails, the work area is empty. Rather than kill the tab — which would also drop
# the whole workspace when it's the last tab, yanking you elsewhere — respawn a
# fresh shell beside the rail so the workspace persists. Close a tab on purpose
# with Prefix & (kill-window).

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
WIDTH="${AGENT_FLEET_SIDENAV_WIDTH:-30}"
win="${1:-}"
[[ -n "$win" ]] || exit 0

# Let tmux finish tearing the exited pane down before we touch the layout — the
# pane-exited hook fires mid-teardown and a split issued then gets dropped. The
# hook runs us with run-shell -b, so this sleep doesn't block the server.
sleep 0.1

tx() { tmux -L "$SOCKET" "$@"; }

# Per-pane @fleet-sidenav: "1" for a rail, empty for everything else.
panes="$(tx list-panes -t "$win" -F '#{pane_id} #{@fleet-sidenav}' 2>/dev/null)" || exit 0
[[ -n "$panes" ]] || exit 0          # window already gone (e.g. Prefix & killed it)

# Is any work pane still alive? If so, nothing to do. Otherwise grab a rail.
work=0; rail=""
while read -r pid flag; do
  [[ -z "$pid" ]] && continue
  if [[ "$flag" == "1" ]]; then [[ -z "$rail" ]] && rail="$pid"
  else work=$((work + 1)); fi
done <<<"$panes"
(( work > 0 )) && exit 0
[[ -n "$rail" ]] || exit 0

# Only the rail remains: respawn a shell next to it, in the workspace's dir, then
# restore the rail width (the split halves the now-full-window rail).
dir="$(tx display-message -p -t "$rail" '#{pane_current_path}' 2>/dev/null || true)"
args=(split-window -h -t "$rail")
[[ -n "$dir" ]] && args+=(-c "$dir")
tx "${args[@]}" 2>/dev/null || exit 0
tx resize-pane -t "$rail" -x "$WIDTH" 2>/dev/null || true
tx refresh-client 2>/dev/null || true
