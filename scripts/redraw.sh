#!/usr/bin/env bash
# redraw.sh — force a pane's app to fully repaint (fixes a stale Claude frame).
#
# tmux restores its cached grid when you switch to a pane, but an alt-screen TUI
# like Claude Code (Ink) only repaints on its own render cycle, so you can land
# on a stale frame (cursor home, old text below). A SIGWINCH with no size change
# is a no-op for Ink, so we trigger a REAL 1-column resize round-trip: the width
# genuinely changes (the neighbouring rail lends a column), the app reflows and
# repaints, then we restore the width. Run backgrounded (run-shell -b) so the
# inter-step sleep doesn't block the tmux server.
#
# Needs a neighbour pane to take the column (i.e. the rail open). A lone pane
# can't be resized, so it's left as-is.

set -u

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
pane="${1:-}"; is_rail="${2:-}"
[[ "$is_rail" == "1" || -z "$pane" ]] && exit 0
tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }

w="$(tx display-message -p -t "$pane" '#{pane_width}' 2>/dev/null || echo 0)"
[[ "${w:-0}" -gt 2 ]] || exit 0

tx resize-pane -t "$pane" -x "$((w - 1))" 2>/dev/null
sleep 0.1
tx resize-pane -t "$pane" -x "$w" 2>/dev/null
exit 0
