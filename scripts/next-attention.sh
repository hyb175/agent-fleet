#!/usr/bin/env bash
# next-attention.sh [current_pane_id]
#
# Jump to the next agent that needs you. Builds a queue from the fleet snapshot,
# ordered by urgency — wait (blocked on your input) first, then done (finished a
# turn, awaiting your next prompt) — and focuses the next one after the current
# pane, wrapping around. If you're not on a queued agent, jumps to the most
# urgent. working/idle agents are skipped (they don't need you).
#
# Bound to a prefix key (Prefix Space); the keybind passes #{pane_id} as current.

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
SNAP="$CACHE/fleet.snapshot"
AF="$ROOT/bin/agent-fleet"

cur="${1:-}"

tx() { tmux -L "$SOCK" "$@"; }
note() { tx display-message "$1" 2>/dev/null || true; }

[[ -f "$SNAP" ]] || { note "fleet: no snapshot yet"; exit 0; }

# Attention queue: all wait panes first, then all done panes (snapshot order
# within each tier). Each entry: "<pane_id>|<session>|<window_name>".
waits=(); dones=(); snap_ts=""
while IFS= read -r line; do
  case "$line" in
    T\ *) snap_ts="${line#T }"; continue ;;
    A\ *) ;;
    *) continue ;;
  esac
  IFS='|' read -r s wid widx wn pane label st <<<"${line#A }"
  [[ -z "$pane" ]] && continue
  case "$st" in
    wait) waits+=("$pane|$s|$wn") ;;
    done) dones+=("$pane|$s|$wn") ;;
  esac
done < "$SNAP"

# Don't jump on frozen data: a crashed daemon leaves the snapshot behind, and
# the states in it stop meaning anything.
printf -v now_ts '%(%s)T' -1
if [[ "$snap_ts" =~ ^[0-9]+$ ]] && (( now_ts - snap_ts > 10 )); then
  note "fleet: snapshot stale (daemon down?) — not jumping"
  exit 0
fi

# Concatenate guardedly — empty "${arr[@]}" trips set -u on older bash.
queue=()
(( ${#waits[@]} )) && queue+=("${waits[@]}")
(( ${#dones[@]} )) && queue+=("${dones[@]}")
n=${#queue[@]}
(( n == 0 )) && { note "fleet: no agents need you"; exit 0; }

# Position of the current pane in the queue → target the next (wrap). Current
# pane not queued → target the first (most urgent).
target=0
for i in "${!queue[@]}"; do
  [[ "${queue[$i]%%|*}" == "$cur" ]] && { target=$(( (i + 1) % n )); break; }
done

entry="${queue[$target]}"
pane="${entry%%|*}"; rest="${entry#*|}"; sess="${rest%%|*}"; wn="${rest##*|}"
tier="wait"; (( target >= ${#waits[@]} )) && tier="done"

"$AF" goto "$pane" 2>/dev/null || { note "fleet: that agent is gone"; exit 0; }
note "→ $tier · $sess/$wn   ($n need you)"
