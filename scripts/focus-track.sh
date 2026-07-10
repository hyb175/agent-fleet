#!/usr/bin/env bash
# focus-track.sh — record focus history + push the "current view" to the rails.
#
# Invoked by the pane-focus-in hook with the focused pane id, its sidenav flag,
# and (format-expanded by tmux, so no extra forks) its session and window id.
#
# Two jobs:
#   1. focus.cur / focus.prev — one-line files powering Prefix Tab jump-back.
#   2. focus.now ("session|window_id") + SIGUSR1 to every rail — the rail's
#      highlight follows THIS, not the daemon's polled C record, so switching
#      agents/workspaces re-highlights instantly instead of lagging up to a
#      daemon tick + a rail refresh (~3s).
#
# Rail panes are never recorded, so "back" always lands on a real agent/shell
# (clicking the rail focuses its target a beat later, which fires its own event).

set -u

pane="${1:-}"; is_rail="${2:-}"; sess="${3:-}"; win="${4:-}"
[[ -z "$pane" ]] && exit 0
[[ "$is_rail" == "1" ]] && exit 0     # never record the sidenav as "previous"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
mkdir -p "$CACHE" 2>/dev/null || exit 0
cur="$CACHE/focus.cur"; prev="$CACHE/focus.prev"

c=""; [[ -f "$cur" ]] && read -r c < "$cur" 2>/dev/null
[[ "$pane" == "$c" ]] && exit 0       # focus didn't actually move; nothing to do

[[ -n "$c" ]] && printf '%s\n' "$c" > "$prev" 2>/dev/null
printf '%s\n' "$pane" > "$cur" 2>/dev/null

# Push the new current view and wake the rails to repaint the highlight now.
# pane_pid is authoritative for live rails (never signal from stale pid files —
# a recycled pid's default SIGUSR1 disposition is terminate).
if [[ -n "$sess" && -n "$win" ]]; then
  printf '%s|%s\n' "$sess" "$win" > "$CACHE/focus.now" 2>/dev/null
  SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
  while IFS='|' read -r ppid prail; do
    [[ "$prail" == "1" && -n "$ppid" ]] && kill -USR1 "$ppid" 2>/dev/null
  done < <("${TMUX_BIN:-tmux}" -L "$SOCKET" list-panes -a \
             -F '#{pane_pid}|#{?@fleet-sidenav,1,0}' 2>/dev/null)
fi
exit 0
