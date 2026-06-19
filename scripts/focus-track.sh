#!/usr/bin/env bash
# focus-track.sh — record the focus history for "jump back" (Prefix Tab).
#
# Invoked by the pane-focus-in hook with the focused pane id and its sidenav
# flag. Keeps two one-line files: focus.cur (where you are) and focus.prev
# (where you were). Rail panes are never recorded, so "back" always lands on a
# real agent/shell. Pure bash + builtins — one cheap fork per manual focus
# change (focus changes are user-paced, not per-render).

set -u

pane="${1:-}"; is_rail="${2:-}"
[[ -z "$pane" ]] && exit 0
[[ "$is_rail" == "1" ]] && exit 0     # never record the sidenav as "previous"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
mkdir -p "$CACHE" 2>/dev/null || exit 0
cur="$CACHE/focus.cur"; prev="$CACHE/focus.prev"

c=""; [[ -f "$cur" ]] && read -r c < "$cur" 2>/dev/null
[[ "$pane" == "$c" ]] && exit 0       # focus didn't actually move; nothing to do

[[ -n "$c" ]] && printf '%s\n' "$c" > "$prev" 2>/dev/null
printf '%s\n' "$pane" > "$cur" 2>/dev/null
