#!/usr/bin/env bash
# sidenav-toggle.sh <window_id> <current_pane_id> [toggle|ensure]
#
#   toggle (default, Prefix b): if any rail exists in the window, remove ALL of
#                               them (hide); otherwise create one clean rail.
#                               So hide-then-show is a reliable layout repair.
#   ensure (tmux hooks):        when @fleet-sidenav-auto is "on", guarantee
#                               exactly one rail at the right width (self-heals
#                               width drift and stray duplicates). Never hides.
#   show:                       forced — always (re)create exactly one rail,
#                               ignoring @fleet-sidenav-auto. Used by relayout.
#
# The rail spans the full window height on the left edge and leaves focus on the
# work pane. Every path ends with a client redraw to clear stale cells from odd
# re-renders.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
WIDTH="${AGENT_FLEET_SIDENAV_WIDTH:-30}"

win="${1:?usage: sidenav-toggle.sh <window_id> <pane_id> [toggle|ensure]}"
cur="${2:-}"
mode="${3:-toggle}"

tx() { "${TMUX_BIN:-tmux}" -L "$SOCKET" "$@"; }

# Ensure the snapshot daemon (single writer the rail/picker read) is running.
# Cheap pid check on the common path; only launch when absent.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
ensure_daemon() {
  local pf="$CACHE/snapshotd.lock/pid" p
  p="$(cat "$pf" 2>/dev/null || true)"
  # Comm check: a recycled pid (unclean shutdown) must not pass for the daemon.
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null \
    && ps -p "$p" -o command= 2>/dev/null | grep -q snapshotd && return 0
  AGENT_FLEET_SOCKET="$SOCKET" AGENT_FLEET_ROOT="$ROOT" \
    nohup "$ROOT/scripts/snapshotd.sh" >/dev/null 2>&1 &
}
ensure_daemon

# All rail panes currently in this window (there should be at most one).
rails() { tx list-panes -t "$win" -F '#{pane_id} #{@fleet-sidenav}' 2>/dev/null | awk '$2=="1"{print $1}'; }

# Force a redraw of the client so a resize/kill never leaves stale cells.
redraw() { tx refresh-client 2>/dev/null || true; }

create_rail() {
  local newp
  # -f spans the FULL window height on the left edge regardless of the existing
  # layout — a true side rail, not a sub-split.
  # `exec env …` replaces the launching shell so the pane process IS the rail
  # (no fish wrapper to leak/orphan), and kill-pane signals it directly.
  newp="$(tx split-window -h -b -f -d -l "$WIDTH" -t "$win" -P -F '#{pane_id}' \
          "exec env AGENT_FLEET_SOCKET='$SOCKET' AGENT_FLEET_ROOT='$ROOT' AGENT_FLEET_RAIL_WIN='$win' '$ROOT/scripts/sidenav.sh'")"
  tx set -p -t "$newp" @fleet-sidenav 1
  tx set -p -t "$newp" remain-on-exit off
  redraw   # split -l already set the width; just paint cleanly
}

# Collect rail panes portably (no mapfile, so this stays bash-3.2 safe and the
# bash-4 requirement surfaces from the rail with a clear message, not here).
existing=()
while IFS= read -r p; do [[ -n "$p" ]] && existing+=("$p"); done < <(rails)

if [[ "$mode" == "ensure" ]]; then
  [[ "$(tx show-option -gqv @fleet-sidenav-auto 2>/dev/null)" == "on" ]] || exit 0
  if (( ${#existing[@]} > 0 )); then
    # Already present: only act if something is actually wrong, so a plain attach
    # doesn't needlessly resize the neighbor (Claude) pane or force a redraw.
    changed=0
    cur_w="$(tx display-message -p -t "${existing[0]}" '#{pane_width}' 2>/dev/null || echo 0)"
    if [[ "$cur_w" != "$WIDTH" ]]; then
      tx resize-pane -x "$WIDTH" -t "${existing[0]}" 2>/dev/null && changed=1
    fi
    for p in "${existing[@]:1}"; do tx kill-pane -t "$p" 2>/dev/null && changed=1; done
    [[ "$changed" == 1 ]] && redraw
    exit 0
  fi
  create_rail
  exit 0
fi

if [[ "$mode" == "show" ]]; then
  # Forced: remove any (stale) rails and create exactly one. Used by relayout.
  # Length guard: bash 3.2 + set -u errors on expanding an empty array, and
  # this script is meant to run on 3.2 (the bash-4 gate lives in the rail).
  if (( ${#existing[@]} > 0 )); then
    for p in "${existing[@]}"; do tx kill-pane -t "$p" 2>/dev/null || true; done
  fi
  create_rail
  exit 0
fi

# toggle
if (( ${#existing[@]} > 0 )); then
  for p in "${existing[@]}"; do tx kill-pane -t "$p" 2>/dev/null || true; done
  redraw
  exit 0
fi
create_rail
