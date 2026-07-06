#!/usr/bin/env bash
# border-tune.sh [window_id]
#
# Make the active-pane indicator exist only where it answers a question. Color
# alone can't say WHICH side of a shared border is active, so windows whose
# work area is split get tmux's border arrows (pointing at the active pane) +
# the accent; unsplit windows (rail + one work pane — focus never moves) get
# neither. Counts real work panes via @fleet-sidenav, so a hidden rail doesn't
# skew it.
#
# Called from the after-split-window hook (that window) and from sidenav-reap
# on every pane exit (all windows — the exited pane may have un-split any of
# them). persist-restore runs it once after a rebuild. Windows rearranged
# outside those paths (join-pane/break-pane by hand) self-heal on the next
# split or pane exit.

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }

ACCENT="fg=#7aa2f7"   # Tokyo Night blue (matches the conf's static fallback)
DIM="fg=#292e42"      # same as pane-border-style: reads as a plain divider

tune() {
  local win="$1" n
  n="$(tx list-panes -t "$win" -F '#{?#{==:#{@fleet-sidenav},1},rail,work}' 2>/dev/null | grep -c '^work$')"
  if (( n >= 2 )); then
    tx set -w -t "$win" pane-border-indicators both 2>/dev/null || true
    tx set -w -t "$win" pane-active-border-style "$ACCENT" 2>/dev/null || true
  else
    tx set -w -t "$win" pane-border-indicators colour 2>/dev/null || true
    tx set -w -t "$win" pane-active-border-style "$DIM" 2>/dev/null || true
  fi
}

if [[ -n "${1:-}" ]]; then
  tune "$1"
else
  while IFS= read -r w; do [[ -n "$w" ]] && tune "$w"; done \
    < <(tx list-windows -a -F '#{window_id}' 2>/dev/null)
fi
exit 0
