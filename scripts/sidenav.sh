#!/usr/bin/env bash
# sidenav.sh — Herdr-style ambient rail (toggle with Prefix b).
#
# Two stacked lists rendered from the shared snapshot the daemon writes:
#   spaces  — one row per workspace (session): name + git-branch subtitle
#   agents  — one row per agent: tab name + "<workspace> · <state>" subtitle
#
# The rail does NO tmux polling — it only reads fleet.snapshot — so N rails cost
# the server nothing. The spinner animates at TICK only when this rail's window
# is the active one; background rails idle at REFRESH.

set -uo pipefail

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  printf 'agent-fleet: the sidenav needs bash 4+ (macOS ships 3.2).\n  brew install bash, and ensure it precedes /bin/bash on PATH.\n' >&2
  read -r -p 'press enter to close…' _ 2>/dev/null || true
  exit 1
fi

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
REFRESH="${AGENT_FLEET_SIDENAV_REFRESH:-2}"        # idle redraw interval (s)
TICK="${AGENT_FLEET_SIDENAV_TICK:-0.1}"            # spinner frame interval (s)
DATA_EVERY="${AGENT_FLEET_SIDENAV_DATA_EVERY:-12}" # re-read snapshot every N ticks
WIDTH="${AGENT_FLEET_SIDENAV_WIDTH:-30}"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
SNAP="$CACHE/fleet.snapshot"
ROWS_DIR="$CACHE/rows"
mkdir -p "$ROWS_DIR" 2>/dev/null || true
MAPFILE="$ROWS_DIR/${TMUX_PANE:-unknown}.map"

# This rail's own window id (resolved once; used to decide visibility). No tmux
# calls happen in the render loop after this.
RAIL_WIN="${AGENT_FLEET_RAIL_WIN:-$(tmux -L "$SOCKET" display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null || true)}"

C_OFF=$'\033[0m'; C_BOLD=$'\033[1m'
FG=$'\033[38;2;192;202;245m'        # names
C_DIM=$'\033[38;2;86;95;137m'       # subtitles / headers
HL=$'\033[48;2;59;66;97m'           # selected row bg (#3b4261, clearly visible)
ACCENT=$'\033[38;2;122;162;247m'    # selected name + left bar (#7aa2f7)
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

home() { printf '\033[H'; }
trunc() { local s="$1" n="$2"; (( n < 1 )) && { printf ''; return; }; if (( ${#s} > n )); then printf '%s…' "${s:0:n-1}"; else printf '%s' "$s"; fi; }

# --- snapshot (re-read every DATA_EVERY ticks) ---
CUR_SESS=""; CUR_WIN=""; ANIMATE=0
SPACES=(); AGENTS=()
read_snapshot() {
  SPACES=(); AGENTS=(); ANIMATE=0; CUR_SESS=""; CUR_WIN=""
  [[ -f "$SNAP" ]] || return 0
  local line
  while IFS= read -r line; do
    case "$line" in
      C\ *) IFS='|' read -r CUR_SESS CUR_WIN <<<"${line#C }" ;;
      S\ *) SPACES+=("${line#S }") ;;
      A\ *) AGENTS+=("${line#A }"); [[ "$line" == *'|working' ]] && ANIMATE=1 ;;
    esac
  done < "$SNAP"
}

# glyph fg + char for a state (set GLYPH); fork-free.
glyph_for() {  # $1=state $2=frame
  case "$1" in
    wait)    GLYPH=$'\033[38;2;247;118;142m●'"$C_OFF" ;;
    working) GLYPH=$'\033[38;2;224;175;104m'"${SPIN[$2 % ${#SPIN[@]}]}$C_OFF" ;;
    done)    GLYPH=$'\033[38;2;158;206;106m●'"$C_OFF" ;;
    idle)    GLYPH=$'\033[38;2;86;95;137m○'"$C_OFF" ;;
    *)       GLYPH=$'\033[38;2;86;95;137m·'"$C_OFF" ;;
  esac
}

# row <selected> <glyph> <name> <subtitle>
row() {
  local sel="$1" gl="$2" nm sb; nm="$(trunc "$3" $((WIDTH - 3)))"; sb="$(trunc "$4" $((WIDTH - 3)))"
  if [[ "$sel" == 1 ]]; then
    printf '%s%s▎%s %s%s %s%s%s%s\033[K%s\n' "$HL" "$ACCENT" "$C_OFF$HL" "$gl" "$HL" "$C_BOLD$ACCENT" "$nm" "$C_OFF" "$HL" "$C_OFF"
    printf '%s%s▎%s  %s%s%s%s\033[K%s\n' "$HL" "$ACCENT" "$C_OFF$HL" "$C_DIM" "$sb" "$C_OFF" "$HL" "$C_OFF"
  else
    printf ' %s %s%s%s\033[K\n' "$gl" "$C_BOLD$FG" "$nm" "$C_OFF"
    printf '   %s%s%s\033[K\n' "$C_DIM" "$sb" "$C_OFF"
  fi
}
header() {
  local l="$1" r="$2" p
  p=$(( WIDTH - ${#l} - ${#r} - 1 )); (( p < 1 )) && p=1
  printf ' %s%s%*s%s%s\033[K\n' "$C_DIM" "$l" "$p" "" "$r" "$C_OFF"
}
blank() { printf '\033[K\n'; }

draw() {
  local frame="$1"; home
  local line=0; local -a map=()
  local rec s roll br wid widx wn pane label st GLYPH sel

  header "spaces" "";                                        line=$((line+1))
  blank;                                                     line=$((line+1))
  if (( ${#SPACES[@]} == 0 )); then
    printf ' %s(no workspaces)%s\033[K\n' "$C_DIM" "$C_OFF"; line=$((line+1))
  else
    for rec in "${SPACES[@]}"; do
      IFS='|' read -r s roll br <<<"$rec"
      glyph_for "$roll" "$frame"
      sel=0; [[ "$s" == "$CUR_SESS" ]] && sel=1
      map+=("$line SESS:$s" "$((line+1)) SESS:$s")
      row "$sel" "$GLYPH" "$s" "$br"
      line=$((line+2))
    done
  fi

  blank;                                                     line=$((line+1))
  header "agents" "all";                                     line=$((line+1))
  blank;                                                     line=$((line+1))
  if (( ${#AGENTS[@]} == 0 )); then
    printf ' %s(no agents)%s\033[K\n' "$C_DIM" "$C_OFF";     line=$((line+1))
  else
    for rec in "${AGENTS[@]}"; do
      IFS='|' read -r s wid widx wn pane label st <<<"$rec"
      glyph_for "$st" "$frame"
      sel=0; [[ "$wid" == "$CUR_WIN" ]] && sel=1
      map+=("$line PANE:$pane" "$((line+1)) PANE:$pane")
      # Subtitle = which workspace it's in + its state, so same-named tabs in
      # different workspaces are distinguishable (the glyph already shows kind).
      row "$sel" "$GLYPH" "$wn" "$s · $st"
      line=$((line+2))
    done
  fi

  blank;                                                     line=$((line+1))
  printf ' %sprefix+o open · prefix+b hide%s\033[K\n' "$C_DIM" "$C_OFF"
  printf '\033[J'

  if ((${#map[@]})); then printf '%s\n' "${map[@]}" > "$MAPFILE" 2>/dev/null || true
  else : > "$MAPFILE" 2>/dev/null || true; fi
}

cleanup() { printf '\033[?2026l\033[?25h\033[?1049l'; rm -f "$MAPFILE" 2>/dev/null; exit 0; }
trap cleanup INT TERM HUP

SYNC_ON=$'\033[?2026h'; SYNC_OFF=$'\033[?2026l'
printf '\033[?2026l\033[?1049h\033[?25l'
clear
frame=0; i=0
while true; do
  (( i % DATA_EVERY == 0 )) && read_snapshot
  printf '%s%s%s' "$SYNC_ON" "$(draw "$frame")" "$SYNC_OFF"
  # Animate only when something is working AND this rail's window is the active
  # one; otherwise idle (so background rails cost nothing).
  if [[ "$ANIMATE" == 1 && "$RAIL_WIN" == "$CUR_WIN" ]]; then
    sleep "$TICK"; frame=$(( (frame + 1) % 100000 )); i=$(( i + 1 ))
  else
    sleep "$REFRESH"; i=0
  fi
done
