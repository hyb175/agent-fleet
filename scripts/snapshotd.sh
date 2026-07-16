#!/usr/bin/env bash
# snapshotd.sh — the fleet's single snapshot writer (one per server).
#
# Polls tmux once per interval, resolves each agent's state and each workspace's
# branch (reusing the file caches in status.sh), and writes the result to
# fleet.snapshot atomically. The rails and the picker READ that file instead of
# each polling tmux — removing the N-rail redundancy that saturated the server.
#
# Snapshot format (one record per line):
#   T <epoch> <interval>                                       freshness
#   C <client>|<session>|<window_id>                           active view, ONE PER
#                                                              CLIENT ("-" headless)
#   S <session>|<rollup_state>|<branch>                        one per workspace
#   A <session>|<window_id>|<window_index>|<window_name>|<pane_id>|<label>|<state>|<pane_index>

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

tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }

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

cleanup() {
  # Don't leave a stale loading bar on any terminal after the fleet stops.
  local t
  for t in "${!PROG_TTYS[@]}"; do
    printf '\033Ptmux;\033\033]9;4;0\007\033\\' > "$t" 2>/dev/null || true
  done
  rm -rf "$LOCK" "$SNAP" 2>/dev/null
  exit 0
}
trap cleanup INT TERM HUP

# --- terminal progress bar (OSC 9;4, DCS-wrapped for tmux) ------------------
# Claude Code doesn't emit these under tmux, so the daemon synthesizes them
# from agent states: the bar mirrors the ACTIVE window's most-urgent agent
# (indeterminate = working, red = needs input, clear = done/idle/none).
# Emitting from here — continuously, not edge-triggered on hook events — is
# what makes it reliable: transitions that happen while a window is hidden
# (tmux forwards passthrough only from visible panes) self-heal within a
# tick of you switching there, and scrape-tier agents (hand-started,
# codespace) are covered because the daemon resolves their states too.
# Written via the active window's rail tty (any visible pane forwards).
PROGRESS_ON="${AGENT_FLEET_PROGRESS:-1}"
# Per-tty state: with several clients attached the daemon drives one bar per
# active window's tty, so each terminal mirrors ITS OWN view (tmux forwards a
# pane's passthrough only to the clients where that pane is visible).
declare -A PROG_LAST=() PROG_AGE=() PROG_TTYS=()
progress_emit() {  # <state> <tty>
  [[ "$PROGRESS_ON" == "1" ]] || return 0
  local st="$1" tty="$2" seq
  [[ -n "$tty" && -w "$tty" ]] || return 0
  case "$st" in
    working) seq=$'\033Ptmux;\033\033]9;4;3\007\033\\' ;;      # indeterminate
    wait)    seq=$'\033Ptmux;\033\033]9;4;2;100\007\033\\' ;;  # full red: needs you
    *)       seq=$'\033Ptmux;\033\033]9;4;0\007\033\\' ;;      # clear
  esac
  # Dedupe per tick, but re-assert every few ticks so a missed write (e.g.
  # terminal reattach, pane invisible at write time) can't leave the bar stale.
  PROG_AGE[$tty]=$(( ${PROG_AGE[$tty]:-0} + 1 ))
  if [[ "$st" != "${PROG_LAST[$tty]:-}" ]] || (( ${PROG_AGE[$tty]} >= 5 )); then
    printf '%s' "$seq" > "$tty" 2>/dev/null || true
    PROG_LAST[$tty]="$st"; PROG_AGE[$tty]=0; PROG_TTYS[$tty]=1
  fi
}

build() {
  local now; printf -v now '%(%s)T' -1
  # T carries the poll interval so consumers can scale their staleness
  # threshold — a hardcoded cutoff false-alarms when the interval is raised.
  local out="T $now $INTERVAL"$'\n'
  # Active view PER CLIENT — one C record each, so every attached terminal
  # (e.g. one local, one over ssh) gets its own highlight and progress bar
  # instead of everyone following the first client. NOTE: `display-message -c`
  # only sets the client for #{client_*} formats, so the session->active-window
  # map is built separately from list-windows (one call for all sessions).
  local -A SESS_WIN=() AWIN=()
  local s w cname csess clients
  while IFS='|' read -r s w; do
    [[ -n "$s" ]] && SESS_WIN[$s]="$w"
  done < <(tx list-windows -a -F '#{window_active}|#{session_name}|#{window_id}' 2>/dev/null \
           | awk -F'|' '$1=="1"{print $2"|"$3}')
  clients="$(tx list-clients -F '#{client_name}|#{client_session}' 2>/dev/null)"
  if [[ -n "$clients" ]]; then
    while IFS='|' read -r cname csess; do
      [[ -n "$cname" && -n "$csess" ]] || continue
      w="${SESS_WIN[$csess]:-}"
      out+="C $cname|$csess|$w"$'\n'
      [[ -n "$w" ]] && AWIN[$w]=1
    done <<<"$clients"
  else
    # Headless (no attached client): fall back to the server's current view so
    # consumers still see a C record and the bar keeps being exercised.
    local cur; cur="$(tx display-message -p '#{session_name}|#{window_id}' 2>/dev/null || echo '|')"
    out+="C -|$cur"$'\n'
    w="${cur##*|}"; [[ -n "$w" ]] && AWIN[$w]=1
  fi

  local snap
  snap="$(tx list-panes -a \
    -F '#{session_name}|#{window_id}|#{window_name}|#{window_index}|#{pane_id}|#{pane_current_command}|#{pane_tty}|#{@fleet-agent-kind}|#{@fleet-sidenav}|#{pane_current_path}|#{pane_index}' \
    2>/dev/null)"

  declare -A BEST ROLL
  local agents="" wid wn widx pane cmd tty kind sid path label st r pidx
  local -A W_RAIL_TTY=() W_ANY_TTY=() W_BEST=() W_STATE=()
  while IFS='|' read -r s wid wn widx pane cmd tty kind sid path pidx; do
    [[ -z "$pane" ]] && continue
    # Track each ACTIVE window's ttys for the progress bar (rail preferred —
    # it's present in every window and always visible with it).
    if [[ -n "${AWIN[$wid]:-}" ]]; then
      [[ -z "${W_ANY_TTY[$wid]:-}" ]] && W_ANY_TTY[$wid]="$tty"
      [[ "$sid" == "1" && -z "${W_RAIL_TTY[$wid]:-}" ]] && W_RAIL_TTY[$wid]="$tty"
    fi
    [[ "$sid" == "1" ]] && continue
    label="$(pane_agent_kind "$kind" "$cmd" "$tty" "$sid")"
    [[ -n "$label" ]] || continue
    st="$(state_for_pane "$pane" "$cmd")"
    # '|' is this file's field delimiter; window names are user-controlled
    # (rename-window), so swap it for a lookalike in display fields. Session
    # names are already sanitized at creation by the CLI.
    wn="${wn//|/¦}"
    # Trailing pane_index lets renderers disambiguate multiple agents sharing
    # one window ("name.2"); readers of older 7-field rows parse it as empty.
    agents+="A $s|$wid|$widx|$wn|$pane|$label|$st|$pidx"$'\n'
    r="$(state_rank "$st")"
    if [[ -z "${BEST[$s]:-}" ]] || (( r < BEST[$s] )); then BEST[$s]="$r"; ROLL[$s]="$st"; fi
    # Most-urgent agent state per active window drives that window's bar.
    if [[ -n "${AWIN[$wid]:-}" ]] && (( r < ${W_BEST[$wid]:-9} )); then
      W_BEST[$wid]="$r"; W_STATE[$wid]="$st"
    fi
  done <<<"$snap"

  # One bar per active window, deduped by tty (two clients viewing the same
  # window share a rail): each terminal mirrors the state of ITS current view.
  local -A seen_tty=()
  for w in "${!AWIN[@]}"; do
    tty="${W_RAIL_TTY[$w]:-${W_ANY_TTY[$w]:-}}"
    [[ -n "$tty" && -z "${seen_tty[$tty]:-}" ]] || continue
    seen_tty[$tty]=1
    progress_emit "${W_STATE[$w]:-none}" "$tty"
  done

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
