#!/usr/bin/env bash
# sidenav-relayout.sh <window_id> <current_pane_id>
#
# Re-tile the window's WORK panes sensibly while keeping the full-height rail.
# tmux layouts treat the rail as just another tile, so this lays out the work
# panes alone (rail removed), then re-attaches the rail.
#
# Layout is chosen from the current split:
#   work panes share a row    -> even-horizontal
#   work panes share a column -> even-vertical
#   mixed                     -> tiled
#   (one or zero work panes)  -> nothing to balance

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
win="${1:?usage: sidenav-relayout.sh <window_id> <pane_id>}"
cur="${2:-}"

tx() { tmux -L "$SOCKET" "$@"; }

# Positions of the work (non-rail) panes, sampled before any change.
tops="$(tx list-panes -t "$win" -F '#{@fleet-sidenav}|#{pane_top}'  2>/dev/null | awk -F'|' '$1!="1"{print $2}')"
lefts="$(tx list-panes -t "$win" -F '#{@fleet-sidenav}|#{pane_left}' 2>/dev/null | awk -F'|' '$1!="1"{print $2}')"
n="$(grep -c . <<<"$tops" 2>/dev/null || echo 0)"

layout=""
if (( n >= 2 )); then
  if   (( $(sort -u <<<"$tops"  | grep -c .) == 1 )); then layout="even-horizontal"
  elif (( $(sort -u <<<"$lefts" | grep -c .) == 1 )); then layout="even-vertical"
  else                                                     layout="tiled"
  fi
fi

# Active work pane to restore focus to.
active="$cur"
[[ -n "$active" ]] || active="$(tx display-message -p -t "$win" '#{pane_id}' 2>/dev/null || true)"

# Remove rails (so the layout applies to work panes only), remembering presence.
had_rail=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  tx kill-pane -t "$p" 2>/dev/null && had_rail=1
done < <(tx list-panes -t "$win" -F '#{pane_id} #{@fleet-sidenav}' 2>/dev/null | awk '$2==1{print $1}')

[[ -n "$layout" ]] && tx select-layout -t "$win" "$layout" 2>/dev/null || true

# Re-attach the rail only if there was one.
(( had_rail )) && "$ROOT/scripts/sidenav-toggle.sh" "$win" "$active" show

tx select-pane -t "$active" 2>/dev/null || true
tx refresh-client 2>/dev/null || true
