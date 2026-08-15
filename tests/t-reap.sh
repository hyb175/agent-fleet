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

nwin()  { tx list-windows -t t 2>/dev/null | wc -l | tr -d ' '; }
npane() { tx list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
# the first non-rail pane of a window
workpane() { tx list-panes -t "$1" -F '#{pane_id} #{?@fleet-sidenav,1,0}' 2>/dev/null | awk '$2!="1"{print $1; exit}'; }
# a second window, rail attached, ready to be emptied
new_win() {
  tx new-window -t t: -c "$WORK"
  wait_for 15 "[[ -n \"\$(tx list-panes -t t:2 -F '#{@fleet-sidenav}' 2>/dev/null | grep -x 1)\" ]] && [[ -n \"\$(workpane t:2)\" ]]"
}

# --- natural exit: the work pane's program ends ---
new_win
base="$(nwin)"
tx respawn-pane -k -t "$(workpane t:2)" true    # exits immediately -> pane-exited
wait_for 15 "[[ \"\$(nwin)\" == '$((base - 1))' ]]"
check "rail-only window reaped on pane exit (got $(nwin), want $((base - 1)))" "[[ \"\$(nwin)\" == '$((base - 1))' ]]"

# --- forced destruction: kill-pane fires after-kill-pane, NOT pane-exited ---
new_win
base="$(nwin)"
tx kill-pane -t "$(workpane t:2)"
wait_for 15 "[[ \"\$(nwin)\" == '$((base - 1))' ]]"
check "rail-only window reaped on kill-pane (got $(nwin), want $((base - 1)))" "[[ \"\$(nwin)\" == '$((base - 1))' ]]"

# --- a surviving work pane keeps its window ---
new_win
tx split-window -t t:2 -c "$WORK"
wait_for 15 "[[ \"\$(npane t:2)\" -ge 3 ]]"
before="$(npane t:2)"
tx kill-pane -t "$(workpane t:2)"
wait_for 15 "[[ \"\$(npane t:2)\" == '$((before - 1))' ]]"
check "window with another work pane survives" "[[ -n \"\$(tx list-windows -t t -F '#{window_index}' | grep -x 2)\" ]]"
check "only the killed pane went (got $(npane t:2), want $((before - 1)))" "[[ \"\$(npane t:2)\" == '$((before - 1))' ]]"

# --- the CLI path: agent-fleet kill %id ---
base="$(nwin)"
AGENT_FLEET_SOCKET="$SOCK" "$REPO/bin/agent-fleet" kill "$(workpane t:2)" >/dev/null 2>&1
wait_for 15 "[[ \"\$(nwin)\" == '$((base - 1))' ]]"
check "rail-only window reaped after 'agent-fleet kill' (got $(nwin), want $((base - 1)))" "[[ \"\$(nwin)\" == '$((base - 1))' ]]"

exit "$FAIL"
