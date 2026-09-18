#!/usr/bin/env bash
# focus-track.sh — record focus history + publish the "current view".
#
# Invoked by the pane-focus-in hook with the focused pane id, its sidenav flag,
# and (format-expanded by tmux, so no extra forks) its session and window id.
#
# Two jobs:
#   1. focus.cur / focus.prev — one-line files powering Prefix Tab jump-back.
#   2. focus.now ("session|window_id") — the rails poll its mtime, so the
#      just-focused rail starts its spinner now instead of a daemon tick later.
#      (The highlight itself is self-derived per rail, so it needs no push — a
#      global "current view" would be wrong with several clients attached.)
#
# This script signals nothing: rails learn about focus from the file. Rail
# panes are never recorded, so "back" always lands on a real agent/shell
# (clicking the rail focuses its target a beat later, which fires its own event).

set -u

pane="${1:-}"; is_rail="${2:-}"; sess="${3:-}"; win="${4:-}"
[[ -z "$pane" ]] && exit 0
[[ "$is_rail" == "1" ]] && exit 0     # never record the sidenav as "previous"

# shellcheck source=cache.sh
source "$(dirname "${BASH_SOURCE[0]}")/cache.sh"
CACHE="$AF_CACHE_DIR"
mkdir -p "$CACHE" 2>/dev/null || exit 0
cur="$CACHE/focus.cur"; prev="$CACHE/focus.prev"

c=""; [[ -f "$cur" ]] && read -r c < "$cur" 2>/dev/null
[[ "$pane" == "$c" ]] && exit 0       # focus didn't actually move; nothing to do

[[ -n "$c" ]] && printf '%s\n' "$c" > "$prev" 2>/dev/null
printf '%s\n' "$pane" > "$cur" 2>/dev/null

if [[ -n "$sess" && -n "$win" ]]; then
  printf '%s|%s\n' "$sess" "$win" > "$CACHE/focus.now" 2>/dev/null
fi
exit 0
