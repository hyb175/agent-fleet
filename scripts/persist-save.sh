#!/usr/bin/env bash
# persist-save.sh — snapshot the fleet's session/window/pane layout to a restore
# file so `agent-fleet attach` after a reboot can rebuild it.
#
# Records sessions, windows (name / index / exact split layout) and panes (cwd,
# rail flag). Programs are NOT recorded — restore recreates every pane as a
# shell (an agent window comes back as a shell in its dir; you resume claude
# yourself, which needs Claude's own session id).
#
# Called periodically by snapshotd, by `agent-fleet stop`, and by `agent-fleet
# save`. Atomic write; a no-op when the fleet isn't running.
#
# Fields are tab-separated. tmux escapes non-printable delimiters in -F output
# (a raw \x1f comes out as literal "\037"), so tab is the only safe separator —
# and every field is forced non-empty (sidenav -> 0/1, session -> value or "-")
# so `read` (which collapses runs of whitespace-IFS like tab) never merges fields.

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
# shellcheck source=cache.sh
source "$(dirname "${BASH_SOURCE[0]}")/cache.sh"
CACHE="$AF_CACHE_DIR"
STATE="$CACHE/fleet.state"
US=$'\t'

tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }
tx list-sessions >/dev/null 2>&1 || exit 0
mkdir -p "$CACHE" 2>/dev/null || exit 0

tmp="$STATE.tmp.$$"
# shellcheck disable=SC2015 # write-then-swap idiom, not if/then/else: mv failing must still clean up the temp
{
  # Socket this fleet lives on. The cache dir is socket-scoped now (cache.sh),
  # so a stray cross-socket read of this file is already unlikely — this is a
  # second, in-band check: restore still refuses to rebuild a state file saved
  # by a different socket even if it somehow ended up in the wrong place.
  printf 'S%s%s\n' "$US" "$SOCK"

  # Attached session (for best-effort focus on restore).
  att="$(tx list-clients -F '#{client_session}' 2>/dev/null | head -1)"
  [[ -n "$att" ]] && printf 'A%s%s\n' "$US" "$att"

  # One line per window: name / index / active / exact layout (rail included).
  tx list-windows -a \
    -F "W${US}#{session_name}${US}#{window_index}${US}#{window_active}${US}#{window_layout}${US}#{window_name}" \
    2>/dev/null

  # One line per pane: rail (0/1) / active / agent session (or -) / cwd /
  # agent kind (or -) / task id (or -). New fields append at the END so state
  # files from older versions still parse — a missing kind defaults to claude,
  # a missing task id to none.
  # A scrape-tier agent (hand-started, hooks never fired) carries no kind tag;
  # the snapshot's A-record label is its detected kind ("~" = scraped), so an
  # untagged pane borrows it and restore relaunches the agent, not a shell.
  tx list-panes -a \
    -F "P${US}#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{?@fleet-sidenav,1,0}${US}#{pane_active}${US}#{?@fleet-session,#{@fleet-session},-}${US}#{pane_current_path}${US}#{?@fleet-agent-kind,#{@fleet-agent-kind},-}${US}#{?@fleet-task,#{@fleet-task},-}" \
    2>/dev/null \
  | awk -F"$US" -v OFS="$US" -v snap="$CACHE/fleet.snapshot" '
      BEGIN { while ((getline l < snap) > 0) if (substr(l, 1, 2) == "A ") {
                split(substr(l, 3), a, "|"); k = a[6]; sub(/~$/, "", k); kind[a[1] "\t" a[3] "\t" a[8]] = k } }
      $9 == "-" && (($2 "\t" $3 "\t" $4) in kind) { $9 = kind[$2 "\t" $3 "\t" $4] }
      { print }'
} > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
