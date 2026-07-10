#!/usr/bin/env bash
# t-highlight.sh — the rail highlight is event-driven.
#   - focus-track writes focus.now (session|window) and SIGUSR1s the rails
#   - rails survive the signal (trap installed — default USR1 would kill them)
#   - a background rail repaints with the new highlight within ~1s of the
#     signal (no waiting for the daemon poll / refresh cadence)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-highlight:"
boot_server alpha "$WORK"
tx new-session -d -s beta -c "$WORK"
sleep 1   # let both rails boot and draw

alpha_rail="$(tx list-panes -t alpha -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 == "1" {print $1; exit}')"
beta_work="$(tx list-panes -t beta -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
beta_win="$(tx display-message -p -t beta '#{window_id}')"
rails_alive() { tx list-panes -a -F '#{?@fleet-sidenav,1,0}' | grep -c '^1$'; }
n0="$(rails_alive)"
check "two rails up" "[[ '$n0' == '2' ]]"

# Simulate the pane-focus-in hook firing for beta's work pane.
AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  bash "$REPO/scripts/focus-track.sh" "$beta_work" 0 beta "$beta_win"
sleep 1

check "focus.now records the new view" "[[ \"\$(cat '$XDG_CACHE_HOME/agent-fleet/focus.now')\" == 'beta|$beta_win' ]]"
check "rails survive SIGUSR1 (trap installed)" "[[ \"\$(rails_alive)\" == '$n0' ]]"
# The (background) alpha rail should now highlight beta's row: the selected-row
# marker ▎ appears on the same line as the session name.
cap="$(tx capture-pane -t "$alpha_rail" -p 2>/dev/null)"
check "alpha's rail highlights beta after the push" "grep -aq '▎.*beta' <<<\"\$cap\""

# rapid double-signal safety
AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  bash "$REPO/scripts/focus-track.sh" "$alpha_rail" 1 alpha "@0"   # rail focus: must be ignored
check "rail focus is ignored (focus.now unchanged)" "[[ \"\$(cat '$XDG_CACHE_HOME/agent-fleet/focus.now')\" == 'beta|$beta_win' ]]"
check "rails still alive" "[[ \"\$(rails_alive)\" == '$n0' ]]"
exit $FAIL
