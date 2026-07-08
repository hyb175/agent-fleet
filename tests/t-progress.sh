#!/usr/bin/env bash
# t-progress.sh — snapshotd drives the terminal progress bar (OSC 9;4).
#   - the ACTIVE window's most-urgent agent state is emitted continuously,
#     DCS-wrapped, via the window's rail tty: working -> indeterminate,
#     wait -> red, idle -> clear
#   - transitions that happen between ticks are picked up (no edge dependency)
#   - AGENT_FLEET_PROGRESS=0 disables emission
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-progress:"
boot_server t "$WORK"
wp="$(tx list-panes -t t -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
rp="$(tx list-panes -t t -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 == "1" {print $1; exit}')"
tx set-option -p -t "$wp" @fleet-agent-kind claude     # make the work pane an agent
PANES="$XDG_CACHE_HOME/agent-fleet/panes"; mkdir -p "$PANES"

RAW="$WORK/raw.log"
tx pipe-pane -t "$rp" -o "cat > $RAW"                  # tap the rail tty (emission target)

# daemon (fast ticks for the test)
AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  AGENT_FLEET_SNAP_INTERVAL=1 nohup "$REPO/scripts/snapshotd.sh" >/dev/null 2>&1 &
dpid=$!

wait_for() {  # <pattern> — up to ~5s
  for _ in $(seq 1 25); do grep -aq "$1" "$RAW" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}

printf 'working\n' > "$PANES/$wp.status"
check "working -> indeterminate bar (9;4;3)" "wait_for $'\x1bPtmux;\x1b\x1b]9;4;3'"
printf 'wait\n' > "$PANES/$wp.status"
check "wait -> red bar (9;4;2;100)" "wait_for $'\x1b\x1b]9;4;2;100'"
printf 'idle\n' > "$PANES/$wp.status"
check "idle -> cleared (9;4;0)" "wait_for $'\x1b\x1b]9;4;0'"

kill "$(cat "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null
# The daemon's cleanup emits a parting clear and releases its lock — wait for
# the release so phase 2's fresh daemon can start and the tap can be truncated
# AFTER the parting sequence has landed.
for _ in $(seq 1 30); do [[ -d "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock" ]] || break; sleep 0.2; done
sleep 0.3

# opt-out: fresh daemon with AGENT_FLEET_PROGRESS=0 must emit nothing new
: > "$RAW"
printf 'working\n' > "$PANES/$wp.status"
AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  AGENT_FLEET_SNAP_INTERVAL=1 AGENT_FLEET_PROGRESS=0 nohup "$REPO/scripts/snapshotd.sh" >/dev/null 2>&1 &
sleep 2.5
n="$(grep -ac $'\x1bPtmux;\x1b\x1b]9;4' "$RAW" 2>/dev/null || true)"
check "AGENT_FLEET_PROGRESS=0 emits nothing (got ${n:-0})" "[[ '${n:-0}' == '0' ]]"
kill "$(cat "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null
tx pipe-pane -t "$rp" 2>/dev/null
exit $FAIL
