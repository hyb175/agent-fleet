#!/usr/bin/env bash
# t-highlight.sh — the rail highlight is per-view (self-derived).
#   - each rail highlights ITS OWN workspace, so several attached clients
#     (e.g. one local, one over ssh) each see their own view highlighted;
#     a focus push for another session must NOT move a rail's highlight
#   - focus-track still records focus.now and SIGUSR1s the rails (wake +
#     spinner visibility), and rails survive the signal
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-highlight:"
boot_server alpha "$WORK"
tx new-session -d -s beta -c "$WORK"
sleep 2.5   # let the daemon publish a snapshot and both rails draw it

alpha_rail="$(tx list-panes -t alpha -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 == "1" {print $1; exit}')"
beta_rail="$(tx list-panes -t beta -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 == "1" {print $1; exit}')"
beta_work="$(tx list-panes -t beta -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
beta_win="$(tx display-message -p -t beta '#{window_id}')"
rails_alive() { tx list-panes -a -F '#{?@fleet-sidenav,1,0}' | grep -c '^1$'; }
n0="$(rails_alive)"
check "two rails up" "[[ '$n0' == '2' ]]"

# Self-highlight: each rail marks its own workspace row (▎ on the name line).
cap_a="$(tx capture-pane -t "$alpha_rail" -p 2>/dev/null)"
cap_b="$(tx capture-pane -t "$beta_rail" -p 2>/dev/null)"
check "alpha's rail highlights alpha" "grep -aq '▎.*alpha' <<<\"\$cap_a\""
check "beta's rail highlights beta" "grep -aq '▎.*beta' <<<\"\$cap_b\""

# Simulate the pane-focus-in hook firing for beta's work pane.
AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  bash "$REPO/scripts/focus-track.sh" "$beta_work" 0 beta "$beta_win"
sleep 1

check "focus.now records the new view" "[[ \"\$(cat '$XDG_CACHE_HOME/agent-fleet/focus.now')\" == 'beta|$beta_win' ]]"
check "rails survive SIGUSR1 (trap installed)" "[[ \"\$(rails_alive)\" == '$n0' ]]"
# The push must NOT move alpha's highlight: another client's (or window's)
# focus is not this rail's view.
cap_a="$(tx capture-pane -t "$alpha_rail" -p 2>/dev/null)"
check "alpha's rail still highlights alpha after the push" "grep -aq '▎.*alpha' <<<\"\$cap_a\""
check "alpha's rail does not highlight beta" "! grep -aq '▎.*beta' <<<\"\$cap_a\""

# rapid double-signal safety
AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  bash "$REPO/scripts/focus-track.sh" "$alpha_rail" 1 alpha "@0"   # rail focus: must be ignored
check "rail focus is ignored (focus.now unchanged)" "[[ \"\$(cat '$XDG_CACHE_HOME/agent-fleet/focus.now')\" == 'beta|$beta_win' ]]"
check "rails still alive" "[[ \"\$(rails_alive)\" == '$n0' ]]"
exit $FAIL
