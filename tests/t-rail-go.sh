#!/usr/bin/env bash
# t-rail-go.sh — the Go rail's interaction, driven through tmux.
#   - the rail pane runs afui via rail-launch.sh
#   - Prefix B (sidenav-focus.sh) selects the rail pane
#   - keys typed into the rail move the cursor and Enter jumps (agent-fleet
#     goto) to the chosen agent's window; Esc returns to the work pane
#   - focus mode shows in the footer; the filter shows in the header
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-rail-go:"
[[ -x "$REPO/bin/afui" ]] || { echo "  SKIP: bin/afui not built (make ui)"; exit 0; }
boot_server t "$WORK"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"

rail_of() { tx list-panes -t "$1" -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2=="1"{print $1; exit}'; }
work_of() { tx list-panes -t "$1" -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2!="1"{print $1; exit}'; }
wait_for 10 "[[ -n \"\$(rail_of t:1)\" ]]"
rail="$(rail_of t:1)"
check "rail pane runs afui" "[[ \"\$(tx display-message -p -t '$rail' '#{pane_current_command}')\" == afui ]]"

# Two agents in a second window; the snapshot lists them under t.
w2="$(tx new-window -d -P -F '#{window_id}' -t t: -n target 'sleep 60')"
tgt="$(work_of "$w2")"
tx set-option -p -t "$tgt" @fleet-agent-kind claude
mkdir -p "$CACHE/panes"; printf 'wait\n' > "$CACHE/panes/$tgt.status"
wait_for 10 "grep -q '|$tgt|' '$CACHE/fleet.snapshot' 2>/dev/null"
sleep 0.6   # let the rail pick up the snapshot

# Prefix B: focus the rail.
AGENT_FLEET_SOCKET="$SOCK" "$REPO/scripts/sidenav-focus.sh" "$(tx display-message -p -t t:1 '#{window_id}')"
check "sidenav-focus selects the rail pane" "[[ \"\$(tx display-message -p -t t:1 '#{pane_id}')\" == '$rail' ]]"

# j moves onto the first row and shows focus mode in the footer.
tx send-keys -t "$rail" j
wait_for 5 "tx capture-pane -p -t '$rail' | grep -q 'j/k'"
check "focus mode footer after a key" "tx capture-pane -p -t '$rail' | grep -q 'j/k ⏎ jump'"
check "cursor marker shown" "tx capture-pane -p -t '$rail' | grep -q '›'"

# / filter: header reflects it; Esc clears it.
tx send-keys -t "$rail" / x y z
wait_for 5 "tx capture-pane -p -t '$rail' | grep -q '/xyz'"
check "filter shows in the header" "tx capture-pane -p -t '$rail' | grep -q 'agents.*/xyz'"
check "no agent matches xyz" "tx capture-pane -p -t '$rail' | grep -q '(none match)'"
tx send-keys -t "$rail" Escape
wait_for 5 "! tx capture-pane -p -t '$rail' | grep -q '/xyz'"
check "Esc while typing clears the filter" "! tx capture-pane -p -t '$rail' | grep -q '/xyz'"

# Jump: G to the last row (the agent in window 2), Enter -> goto.
tx send-keys -t "$rail" G
sleep 0.3
tx send-keys -t "$rail" Enter
wait_for 10 "[[ \"\$(tx display-message -p -t t '#{window_id}')\" == '$w2' ]]"
check "Enter on an agent row jumps to its window" "[[ \"\$(tx display-message -p -t t '#{window_id}')\" == '$w2' ]]"
check "…and selects the agent pane" "[[ \"\$(tx display-message -p -t t '#{pane_id}')\" == '$tgt' ]]"

exit "$FAIL"
