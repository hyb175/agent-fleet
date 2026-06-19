#!/usr/bin/env bash
# sidenav-reap.sh
#
# Invoked when a pane exits. Closes any window whose only remaining panes are
# sidenav rails (its work area is empty): Ctrl-D on the last work pane closes the
# tab, while exiting one pane of several leaves the rest. If the closed tab was a
# workspace's last, the session is destroyed and detach-on-destroy=off drops you
# onto your last active workspace instead of detaching.
#
# We scan ALL windows rather than trust the hook's window id — in the pane-exited
# context #{window_id} resolves to the *active* window, not the one the pane left.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
tx() { tmux -L "$SOCKET" "$@"; }

# Let tmux finish tearing the exited pane down so it's gone from the listing
# below. The pane-exited hook runs us with run-shell -b, so this doesn't block.
sleep 0.1

# Tally work panes per window with a stable "rail"/"work" token (an empty
# per-pane value would be stripped by $() and hide a survivor). Any window with
# no work pane is an empty shell around a rail — collect it.
empties="$(tx list-panes -a -F '#{window_id} #{?#{==:#{@fleet-sidenav},1},rail,work}' 2>/dev/null \
  | awk '{ w[$1]; if ($2 == "work") keep[$1] = 1 } END { for (k in w) if (!(k in keep)) print k }')" || exit 0
[[ -n "$empties" ]] || exit 0

while read -r win; do
  [[ -n "$win" ]] && tx kill-window -t "$win" 2>/dev/null || true
done <<<"$empties"
