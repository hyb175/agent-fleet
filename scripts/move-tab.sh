#!/usr/bin/env bash
# move-tab.sh — Prefix M: move the calling tab (window) to another workspace,
# picked from an fzf popup. Bound in conf/agent-fleet.conf:
#   bind M run-shell "tmux set -gq @fleet-move-win '#{window_id}'" \; \
#     display-popup -E -w 60% -h 50% "$AGENT_FLEET_ROOT/scripts/move-tab.sh"
#
# Which tab to move — display-popup does NOT format-expand its command (only
# run-shell does), so the bind can't pass '#{window_id}' as an argument. The
# bind instead stashes the active window id into @fleet-move-win via run-shell
# (which expands the format against the pane the key was pressed in), and this
# script reads it. An explicit arg still wins, for CLI/test use.
#
# Source of truth is live `list-sessions`, NOT the snapshot the main picker
# reads: a move must act on workspaces that exist right now, and it stays
# correct even when the snapshot daemon is behind or stopped.
set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
AF="$ROOT/bin/agent-fleet"

tx() { "${TMUX_BIN:-tmux}" -L "$SOCKET" "$@"; }

# Resolve which tab to move, most-specific first:
#   1. an explicit arg (CLI / tests)
#   2. @fleet-move-win, stashed by the bind's run-shell for this popup
#   3. the attached client's active window (belt-and-suspenders: works even if a
#      stale bind is still loaded and expanded neither of the above)
# A value that's still a raw '#{...}' format is treated as unset — that's what a
# stale/old bind passes when display-popup fails to expand it.
unexpanded() { case "$1" in '#{'*|'%{'*|'') return 0 ;; *) return 1 ;; esac; }

WIN="${1:-}"
unexpanded "$WIN" && WIN="$(tx show-option -gqv @fleet-move-win 2>/dev/null || true)"
unexpanded "$WIN" && WIN="$(tx display-message -p '#{window_id}' 2>/dev/null || true)"
if unexpanded "$WIN"; then
  echo "move-tab: could not resolve the current tab" >&2
  read -r -p "press enter to close…" _ || true
  exit 1
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo "move-tab requires 'fzf' on PATH" >&2
  read -r -p "press enter to close…" _ || true
  exit 1
fi

# The tab and its home workspace. `here` is excluded below — moving a tab into
# the workspace it already lives in is a no-op.
here="$(tx display-message -p -t "$WIN" '#{session_name}' 2>/dev/null || true)"
name="$(tx display-message -p -t "$WIN" '#{window_name}' 2>/dev/null || true)"
if [[ -z "$here" ]]; then
  echo "move-tab: no such tab: $WIN" >&2
  read -r -p "press enter to close…" _ || true
  exit 1
fi

# Destination rows: every workspace except this tab's own. Column 1 is the raw
# session name (hidden from fzf via --with-nth=2..); column 2+ is the display.
rows=""
while IFS='|' read -r s nw; do
  [[ -z "$s" || "$s" == "$here" ]] && continue
  sub="${nw} tab"; [[ "$nw" != 1 ]] && sub="${nw} tabs"
  printf -v row 'SESS:%s\t\033[1m%-18s\033[0m \033[2m%s\033[0m' "$s" "$s" "$sub"
  rows+="$row"$'\n'
done < <(tx list-sessions -F '#{session_name}|#{session_windows}' 2>/dev/null | sort)

if [[ -z "${rows//[$'\n']/}" ]]; then
  printf '\n  no other workspace to move to.\n\n'
  read -r -p "  press enter to close…" _ || true
  exit 0
fi

sel="$(printf '%s' "$rows" | fzf \
  --ansi --no-sort --reverse --cycle --no-scrollbar \
  --delimiter=$'\t' --with-nth=2.. \
  --header="move tab '${name}' from [${here}]  ·  ⏎ move · esc cancel" \
  --prompt='move to ' \
  --color="fg+:green,bg+:-1")" || exit 0

[[ -z "$sel" ]] && exit 0
dest="${sel%%$'\t'*}"; dest="${dest#SESS:}"
[[ -z "$dest" ]] && exit 0

# --focus follows the tab into its new home; move.sh already validates the dest.
"$AF" move "$WIN" --to "$dest" --focus
