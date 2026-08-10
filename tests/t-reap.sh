#!/usr/bin/env bash
# t-reap.sh — a window whose work area empties is closed, leaving no orphan rail.
#   - the rail-only window is reaped whether the pane EXITED (Ctrl-D) or was
#     DESTROYED (Prefix x, `agent-fleet kill %id`) — tmux fires pane-exited for
#     the first and after-kill-pane for the second, never both
#   - a window that still has a work pane is left alone
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-reap:"
boot_server t "$WORK"
sleep 0.4

nwin()  { tx list-windows -t t 2>/dev/null | wc -l | tr -d ' '; }
npane() { tx list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
# the first non-rail pane of a window
workpane() { tx list-panes -t "$1" -F '#{pane_id} #{?@fleet-sidenav,1,0}' 2>/dev/null | awk '$2!="1"{print $1; exit}'; }

# --- natural exit: the work pane's program ends ---
tx new-window -t t: -c "$WORK"; sleep 1
base="$(nwin)"
wp="$(workpane t:2)"
tx respawn-pane -k -t "$wp" true          # program exits immediately -> pane-exited
sleep 1.5
check "rail-only window reaped on pane exit (got $(nwin), want $((base - 1)))" "[[ \"\$(nwin)\" == '$((base - 1))' ]]"

# --- forced destruction: kill-pane fires after-kill-pane, NOT pane-exited ---
tx new-window -t t: -c "$WORK"; sleep 1
base="$(nwin)"
tx kill-pane -t "$(workpane t:2)"
sleep 1.5
check "rail-only window reaped on kill-pane (got $(nwin), want $((base - 1)))" "[[ \"\$(nwin)\" == '$((base - 1))' ]]"

# --- a surviving work pane keeps its window ---
tx new-window -t t: -c "$WORK"; sleep 1
tx split-window -t t:2 -c "$WORK"; sleep 1
before="$(npane t:2)"
tx kill-pane -t "$(workpane t:2)"
sleep 1.5
check "window with another work pane survives" "[[ -n \"\$(tx list-windows -t t -F '#{window_index}' | grep -x 2)\" ]]"
check "only the killed pane went (got $(npane t:2), want $((before - 1)))" "[[ \"\$(npane t:2)\" == '$((before - 1))' ]]"

# --- the CLI path: agent-fleet kill %id ---
base="$(nwin)"
AGENT_FLEET_SOCKET="$SOCK" "$REPO/bin/agent-fleet" kill "$(workpane t:2)" >/dev/null 2>&1
sleep 1.5
check "rail-only window reaped after 'agent-fleet kill' (got $(nwin), want $((base - 1)))" "[[ \"\$(nwin)\" == '$((base - 1))' ]]"

exit $FAIL
