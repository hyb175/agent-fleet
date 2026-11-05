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
# sizes them to that client), windows holding a pane on any client's tty (a
# client running inside a fleet pane would be resized and re-fire its own
# resize hook), and windows already at the target. Does nothing unless the
# global window-size policy is `latest`.
#
# Bursts (an attach or a drag fires many hooks): each run writes a token unique
# to it, sleeps, and exits unless the file still holds its own, so only the
# newest of a burst does the pass. Nothing is held: a token left by a killed run
# is simply overwritten by the next. The write ends by re-reading the clients; if
# the client's size moved since the read, the pass repeats, at most 3 times.

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }

# shellcheck source=cache.sh
source "$(dirname "${BASH_SOURCE[0]}")/cache.sh"

client="${1:-}"
[[ -n "$client" ]] || exit 0
rail="${AGENT_FLEET_SIDENAV_WIDTH:-30}"
# Unit separator, not tab: tab is IFS whitespace, so an empty field (a dead
# pane's tty) would collapse and shift the columns after it.
T=$'\x1f'

# Fixed width: racing writers overwrite each other whole, never leave a mixed tail.
printf -v token '%07d-%05d' "$$" "$RANDOM"
[[ -d "$AF_CACHE_DIR" ]] || mkdir -p "$AF_CACHE_DIR"
printf '%s' "$token" > "$AF_CACHE_DIR/presize.token"
sleep 0.15
[[ "$(< "$AF_CACHE_DIR/presize.token")" == "$token" ]] || exit 0

# The global policy, status and default-size lines, then records: C client,
# W window, P pane.
for _pass in 1 2 3; do
snap="$(tx \
  show -gqv window-size \; show -gqv status \; show -gqv default-size \; \
  list-clients -F "C${T}#{client_name}${T}#{client_tty}${T}#{client_session}${T}#{client_width}${T}#{client_height}" \; \
  list-windows -a -F "W${T}#{session_name}${T}#{window_id}${T}#{window_width}${T}#{window_height}" \; \
  list-panes -a -F "P${T}#{window_id}${T}#{pane_tty}${T}#{pane_id}${T}#{@fleet-sidenav}" 2>/dev/null)" || exit 0

policy="" status="" cur="" ctty="" cw=0 ch=0
others=$'\n'; ttys=$'\n'; wins=(); busy=$'\n'; rails=$'\n'
{
  read -r policy; read -r status; read -r cur
  while IFS="$T" read -r kind a b c d e; do
    case "$kind" in
      C) [[ -n "$b" ]] && ttys="$ttys$b"$'\n'
         if [[ "$a" == "$client" ]]; then ctty="$b"; cw="$d"; ch="$e"
         else others="$others$c"$'\n'; fi ;;
      W) wins+=("$a$T$b$T$c$T$d") ;;
      P) [[ -n "$b" && "$ttys" == *$'\n'"$b"$'\n'* ]] && busy="$busy$a"$'\n'
         [[ "$d" == 1 ]] && rails="$rails$a|$c"$'\n' ;;
    esac
  done
} <<< "$snap"

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
  if [[ "$rails" == *$'\n'"$win|"* ]]; then r="${rails#*$'\n'"$win|"}"; cmd+=(';' resize-pane -t "${r%%$'\n'*}" -x "$rail"); fi
  n=$(( n + 1 ))
done

# Nothing to resize and default-size already right: no write at all.
(( n > 0 )) || [[ "$cur" != "${w}x${h}" ]] || exit 0
# A window that died since the read fails its resize and tmux drops the rest
# of the chain, so a failed write takes another pass rather than giving up.
back="$(tx "${cmd[@]}" \; list-clients -F "#{client_name}${T}#{client_width}${T}#{client_height}" 2>/dev/null)" || continue
[[ $'\n'"$back"$'\n' == *$'\n'"${client}${T}${cw}${T}${ch}"$'\n'* ]] && exit 0
done
exit 0
