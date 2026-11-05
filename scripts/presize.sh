#!/usr/bin/env bash
# presize.sh <client_name>
#
# Bring every window the client is not looking at to the client's size, so a
# later switch into it triggers no resize (and no late repaint from the agent).
# One pass is two tmux invocations however many windows there are: one chained
# read (clients, windows, pane ttys, policy), one chained write. Also sets the
# global default-size, so windows born into sessions nobody is attached to
# start at the client's size.
#
# Skipped: windows of a session another client is attached to (tmux already
# sizes them to that client), windows holding a pane on the client's own tty (a
# client running inside a fleet pane would resize itself and re-fire its own
# resize hook), and windows already at the target. Does nothing unless the
# global window-size policy is `latest`.

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }

# shellcheck source=cache.sh
source "$(dirname "${BASH_SOURCE[0]}")/cache.sh"

client="${1:-}"
[[ -n "$client" ]] || exit 0
rail="${AGENT_FLEET_SIDENAV_WIDTH:-30}"
T=$'\t'

# Record types: O global options, C client, W window, P pane.
snap="$(tx \
  display-message -p "O${T}#{window-size}${T}#{status}${T}#{default-size}" \; \
  list-clients -F "C${T}#{client_name}${T}#{client_tty}${T}#{client_session}${T}#{client_width}${T}#{client_height}" \; \
  list-windows -a -F "W${T}#{session_name}${T}#{window_id}${T}#{window_width}${T}#{window_height}" \; \
  list-panes -a -F "P${T}#{window_id}${T}#{pane_tty}${T}#{@fleet-sidenav}" 2>/dev/null)" || exit 0

policy="" status="" cur="" ctty="" cw=0 ch=0
others=$'\n'; wins=(); busy=$'\n'; rails=$'\n'
while IFS="$T" read -r kind a b c d e; do
  case "$kind" in
    O) policy="$a"; status="$b"; cur="$c" ;;
    C) if [[ "$a" == "$client" ]]; then ctty="$b"; cw="$d"; ch="$e"
       else others="$others$c"$'\n'; fi ;;
    W) wins+=("$a$T$b$T$c$T$d") ;;
    P) [[ -n "$b" && "$b" == "$ctty" ]] && busy="$busy$a"$'\n'
       [[ "$c" == 1 ]] && rails="$rails$a"$'\n' ;;
  esac
done <<< "$snap"

[[ "$policy" == latest && -n "$ctty" ]] || exit 0

case "$status" in off) lines=0 ;; on) lines=1 ;; *) lines="$status" ;; esac
w="$cw"; h=$(( ch - lines ))
(( w > 0 && h > 0 )) || exit 0

cmd=(set -g default-size "${w}x${h}"); n=0
for rec in ${wins[@]+"${wins[@]}"}; do
  IFS="$T" read -r sess win ww wh <<< "$rec"
  [[ "$others" == *$'\n'"$sess"$'\n'* ]] && continue
  [[ "$busy" == *$'\n'"$win"$'\n'* ]] && continue
  [[ "$ww" == "$w" && "$wh" == "$h" ]] && continue
  cmd+=(';' resize-window -t "$win" -x "$w" -y "$h" ';' set -wu -t "$win" window-size)
  [[ "$rails" == *$'\n'"$win"$'\n'* ]] && cmd+=(';' resize-pane -t "$win" -x "$rail")
  n=$(( n + 1 ))
done

# Nothing to resize and default-size already right: no write at all.
(( n > 0 )) || [[ "$cur" != "${w}x${h}" ]] && tx "${cmd[@]}" >/dev/null 2>&1
exit 0
