#!/usr/bin/env bash
# snapshotd.sh — the fleet's single snapshot writer (one per server).
#
# Polls tmux once per interval, resolves each agent's state and each workspace's
# branch (reusing the file caches in status.sh), and writes the result to
# fleet.snapshot atomically. The rails and the picker READ that file instead of
# each polling tmux — removing the N-rail redundancy that saturated the server.
#
# Snapshot format (one record per line):
#   T <epoch>                                                  freshness
#   C <session>|<window_id>                                    active view (highlight)
#   S <session>|<rollup_state>|<branch>                        one per workspace
#   A <session>|<window_id>|<window_index>|<window_name>|<pane_id>|<label>|<state>

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
INTERVAL="${AGENT_FLEET_SNAP_INTERVAL:-1}"

# shellcheck source=status.sh
source "$ROOT/scripts/status.sh"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
SNAP="$CACHE/fleet.snapshot"
LOCK="$CACHE/snapshotd.lock"
mkdir -p "$CACHE" 2>/dev/null || exit 0

tx() { tmux -L "$SOCK" "$@"; }

# Single instance: atomic mkdir lock; take over unless the holder is a LIVE
# snapshotd. kill -0 alone isn't enough — after an unclean shutdown the pid can
# be recycled by an unrelated process, locking every writer out forever.
holder_is_snapshotd() {
  local hp; hp="$(cat "$LOCK/pid" 2>/dev/null)"
  [[ -n "$hp" ]] && kill -0 "$hp" 2>/dev/null \
    && ps -p "$hp" -o command= 2>/dev/null | grep -q snapshotd
}
if ! mkdir "$LOCK" 2>/dev/null; then
  holder_is_snapshotd && exit 0
  rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"

cleanup() { rm -rf "$LOCK" "$SNAP" 2>/dev/null; exit 0; }
trap cleanup INT TERM HUP

build() {
  local now; printf -v now '%(%s)T' -1
  local out="T $now"$'\n'
  # Active view = the attached client's session (#{client_session}) and that
  # session's active window. NOTE: `display-message -c` only sets the client for
  # #{client_*} formats; #{session_name}/#{window_id} still resolve to a stale
  # server "current", so we must read #{client_session} explicitly.
  local client active asess awin
  client="$(tx list-clients -F '#{client_name}' 2>/dev/null | head -1)"
  if [[ -n "$client" ]]; then
    asess="$(tx display-message -c "$client" -p '#{client_session}' 2>/dev/null)"
    awin="$(tx display-message -t "$asess" -p '#{window_id}' 2>/dev/null)"
    active="${asess}|${awin}"
  else
    active="$(tx display-message -p '#{session_name}|#{window_id}' 2>/dev/null || echo '|')"
  fi
  out+="C $active"$'\n'

  local snap
  snap="$(tx list-panes -a \
    -F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{pane_id}|#{pane_current_command}|#{pane_tty}|#{@fleet-agent-kind}|#{@fleet-sidenav}|#{pane_current_path}' \
    2>/dev/null)"

  declare -A BEST ROLL
  local agents="" s wid wn widx pane cmd tty kind sid path label st r
  while IFS='|' read -r s wid wn widx pane cmd tty kind sid path; do
    [[ -z "$pane" ]] && continue
    [[ "$sid" == "1" ]] && continue
    label="$(pane_agent_kind "$kind" "$cmd" "$tty" "$sid")"
    [[ -n "$label" ]] || continue
    st="$(state_for_pane "$pane" "$cmd")"
    # '|' is this file's field delimiter; window names are user-controlled
    # (rename-window), so swap it for a lookalike in display fields. Session
    # names are already sanitized at creation by the CLI.
    wn="${wn//|/¦}"
    agents+="A $s|$wid|$widx|$wn|$pane|$label|$st"$'\n'
    r="$(state_rank "$st")"
    if [[ -z "${BEST[$s]:-}" ]] || (( r < BEST[$s] )); then BEST[$s]="$r"; ROLL[$s]="$st"; fi
  done <<<"$snap"

  # Per-session dir from the session's active pane (consistent, unlike "first
  # pane seen"), so a stray pane in another cwd can't mislabel the branch.
  local sess dir br
  while IFS= read -r sess; do
    [[ -z "$sess" ]] && continue
    dir="$(tx display-message -p -t "$sess" '#{pane_current_path}' 2>/dev/null || echo '')"
    # Non-git workspace: show the dir basename, not the whole path.
    br="$(git_branch "$dir")"; [[ -z "$br" ]] && br="${dir##*/}"
    br="${br//|/¦}"   # display field; '|' is the record delimiter
    out+="S $sess|${ROLL[$sess]:-none}|$br"$'\n'
  done < <(tx list-sessions -F '#{session_name}' 2>/dev/null | sort)

  out+="$agents"
  printf '%s' "$out" > "$SNAP.tmp.$$" 2>/dev/null && mv "$SNAP.tmp.$$" "$SNAP" 2>/dev/null
}

# Persist the session/window/pane layout to disk every SAVE_EVERY ticks, so a
# reboot can be rebuilt by `agent-fleet attach`. Cheap (one fork per interval).
SAVE_EVERY="${AGENT_FLEET_SAVE_INTERVAL:-15}"
ticks=0
while true; do
  tx list-sessions >/dev/null 2>&1 || cleanup   # server gone → exit
  build
  ticks=$(( ticks + 1 ))
  if (( ticks >= SAVE_EVERY )); then
    ticks=0
    AGENT_FLEET_SOCKET="$SOCK" "$ROOT/scripts/persist-save.sh" 2>/dev/null || true
  fi
  sleep "$INTERVAL"
done
