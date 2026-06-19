#!/usr/bin/env bash
# redraw.sh — nudge a pane's app to repaint after a tmux switch.
#
# tmux restores its cached grid when you switch to a pane, but an alt-screen TUI
# like Claude Code only repaints on its own render cycle — so you can land on a
# stale/garbled frame (cursor home, old text below). Sending SIGWINCH to the
# pane's FOREGROUND process group makes the app re-measure and redraw, with no
# resize and no flicker. Fired on pane-focus-in (auto) and via Prefix R (manual).

set -u

is_rail="${2:-}"; tty="${3:-}"
[[ "$is_rail" == "1" ]] && exit 0     # the rail repaints itself; never nudge it
[[ -z "$tty" ]] && exit 0

# The foreground process group of the pane's tty is the one the kernel would
# SIGWINCH on a real resize (STAT contains '+').
pgid="$(ps -t "${tty#/dev/}" -o pgid=,stat= 2>/dev/null | awk '$2 ~ /\+/ {print $1; exit}')"
[[ -n "$pgid" ]] && kill -WINCH "-$pgid" 2>/dev/null
exit 0
