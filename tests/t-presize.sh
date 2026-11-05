#!/usr/bin/env bash
# t-presize.sh — scripts/presize.sh: one pass brings unviewed windows to the
# client's size and restores the window-size policy, skips windows it must not
# touch, owns default-size, and costs at most two tmux invocations.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clients live on throwaway sockets of their own (a pane there runs `tmux
# attach` against the server under test), so they have a chosen size.
CSOCKS=()
# shellcheck disable=SC2329 # invoked by the EXIT trap
_cleanup() {
  local s
  for s in ${CSOCKS[@]+"${CSOCKS[@]}"}; do tmux -L "$s" kill-server 2>/dev/null; done
  _lib_cleanup
}
trap _cleanup EXIT

PRESIZE="$REPO/scripts/presize.sh"
RESIZED="$WORK/resized"

# fresh — a bare server (no conf: the hooks under test are not registered yet)
# with a test-owned window-resized hook that logs every resize.
fresh() {
  local s
  for s in ${CSOCKS[@]+"${CSOCKS[@]}"}; do tmux -L "$s" kill-server 2>/dev/null; done
  CSOCKS=()
  kill_server
  tmux -L "$SOCK" -f /dev/null new-session -d -s s1 -x 80 -y 24 -c "$WORK"
  tx set-hook -g window-resized "run-shell 'echo #{window_id} >> $RESIZED'"
  : > "$RESIZED"
}

# client <W> <H> <session> — attach a W×H client; sets c to its name. Not run
# in a command substitution, so the socket lands in CSOCKS for cleanup.
client() {
  local s="$SOCK-c${#CSOCKS[@]}"
  CSOCKS+=("$s")
  tmux -L "$s" -f /dev/null new-session -d -x "$1" -y "$2" -- tmux -L "$SOCK" attach -t "$3"
  poll_until 10 "[[ \$(tx list-clients -F '#{client_session}' | grep -cx '$3') -ge 1 ]]"
  c="$(tx list-clients -F '#{client_session} #{client_name}' | awk -v s="$3" '$1 == s { print $2; exit }')"
}

# wsize <session> — "WxH" of every window of the session, space-separated.
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
wsize() { tx list-windows -t "$1" -F '#{window_width}x#{window_height}' | tr '\n' ' '; }
nresized() { grep -cx "$1" "$RESIZED" 2>/dev/null || true; }

echo "t-presize:"

echo "pass resizes an unviewed window and restores window-size"
fresh
tx new-window -d -t s1 -c "$WORK"
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
tx new-window -d -t s2 -c "$WORK"
client 100 30 s1
: > "$RESIZED"
"$PRESIZE" "$c"
check "s2 windows follow the client (100x29)" "[[ \"\$(wsize s2)\" == '100x29 100x29 ' ]]"
check "window-size unset on every window" "[[ -z \"\$(tx show-options -wqv -t s2:0 window-size)\$(tx show-options -wqv -t s2:1 window-size)\" ]]"
check "resize pinned nothing at the global policy" "[[ \"\$(tx show-options -gv window-size)\" == latest ]]"

echo "skips windows of a session another client is attached to, and the window holding the client tty"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
tx new-window -d -t s2 -c "$WORK"
tx new-session -d -s s3 -x 80 -y 24 -c "$WORK"
tx new-session -d -s sh -x 80 -y 24 -c "$WORK" -- sh -c "env -u TMUX tmux -L $SOCK attach -t s1; sleep 300"
poll_until 10 "[[ \$(tx list-clients | wc -l) -ge 1 ]]"
a="$(tx list-clients -F '#{client_name}' | head -1)"
client 90 20 s2 >/dev/null
poll_until 10 "[[ \$(tx list-clients | wc -l) -ge 2 ]]"
s3w="$(tx list-windows -t s3 -F '#{window_id}')"
guarded="$(tx list-windows -t s2 -F '#{window_id}'; tx list-windows -t sh -F '#{window_id}')"
: > "$RESIZED"
"$PRESIZE" "$a"
sleep 1
n=0; for w in $guarded; do n=$(( n + $(nresized "$w") )); done
check "resize hooks on s2 and the client's host window: 0" "[[ $n -eq 0 ]]"
check "unattached s3 was resized (control)" "[[ \$(nresized '$s3w') -eq 1 ]]"

echo "20 windows need resizing -> TMUX_BIN wrapper log has <= 2 invocations"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
for _ in $(seq 19); do tx new-window -d -t s2 -c "$WORK"; done
client 100 30 s1
: > "$RESIZED"
cat > "$WORK/tmux-wrap" <<EOF
#!/bin/sh
echo call >> "$WORK/calls"
exec tmux "\$@"
EOF
chmod +x "$WORK/tmux-wrap"
TMUX_BIN="$WORK/tmux-wrap" "$PRESIZE" "$c"
check "at most 2 tmux invocations" "[[ \$(wc -l < '$WORK/calls') -le 2 ]]"
check "all 20 windows resized" "[[ \"\$(wsize s2 | tr ' ' '\n' | grep -cx '100x29')\" -eq 20 ]]"

echo "window-size largest -> nothing resized, default-size untouched"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
client 100 30 s1
tx set -g window-size largest
before="$(tx show-options -gv default-size)"
: > "$RESIZED"
"$PRESIZE" "$c"
sleep 1
check "s2 keeps its size" "[[ \"\$(wsize s2)\" == '80x24 ' ]]"
check "default-size untouched" "[[ \"\$(tx show-options -gv default-size)\" == '$before' ]]"

echo "rail pane_width is 30 after resize and default-size equals the target"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
tx split-window -hb -l 30 -t s2 -c "$WORK"
rail="$(tx list-panes -t s2 -F '#{pane_id}' | head -1)"
tx set -p -t "$rail" @fleet-sidenav 1
client 80 24 s1
: > "$RESIZED"
"$PRESIZE" "$c"
check "s2 window is 80x23" "[[ \"\$(wsize s2)\" == '80x23 ' ]]"
check "rail pane is 30 wide" "[[ \"\$(tx display-message -p -t '$rail' '#{pane_width}')\" -eq 30 ]]"
check "default-size is 80x23" "[[ \"\$(tx show-options -gv default-size)\" == 80x23 ]]"
tx resize-window -t s2 -x 120 -y 40; tx set -wu -t s2 window-size
AGENT_FLEET_SIDENAV_WIDTH=24 "$PRESIZE" "$c"
check "AGENT_FLEET_SIDENAV_WIDTH=24 gives a 24-col rail" "[[ \"\$(tx display-message -p -t '$rail' '#{pane_width}')\" -eq 24 ]]"

echo "10 concurrent runs -> exactly one reaches the write"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
client 100 30 s1
cat > "$WORK/tmux-wrap" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/calls"
exec tmux "\$@"
EOF
chmod +x "$WORK/tmux-wrap"
rm -f "$WORK/calls"
# Start all ten together: each waits for the go file, so their tokens land well
# inside one 150 ms debounce however slowly the runner forks.
rm -f "$WORK/go"
for _ in $(seq 10); do ( until [[ -e "$WORK/go" ]]; do sleep 0.01; done; TMUX_BIN="$WORK/tmux-wrap" exec "$PRESIZE" "$c" ) & done
sleep 0.5; touch "$WORK/go"
wait
check "one write among the wrapper calls" "[[ \$(grep -c resize-window '$WORK/calls') -eq 1 ]]"
check "the losers forked nothing (read + write only)" "[[ \$(wc -l < '$WORK/calls') -eq 2 ]]"
check "s2 resized" "[[ \"\$(wsize s2)\" == '100x29 ' ]]"

echo "stale token from a killed run does not block the next run"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
client 100 30 s1
( source "$REPO/scripts/cache.sh"; mkdir -p "$AF_CACHE_DIR"; echo "99999-12345" > "$AF_CACHE_DIR/presize.token" )
"$PRESIZE" "$c"
check "s2 resized despite the stale token" "[[ \"\$(wsize s2)\" == '100x29 ' ]]"

echo "client size changes between read and write -> next pass applies the new size, at most 3 passes"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
client 100 30 s1
cs="${CSOCKS[0]}"
# Before each write while flips remain, the wrapper resizes the client's outer
# window and waits for the client to report the new width.
cat > "$WORK/tmux-wrap" <<EOF
#!/bin/sh
case "\$*" in
  *"set -g default-size"*)
    f=\$(cat "$WORK/flips")
    if [ "\$f" -gt 0 ]; then
      echo \$((f - 1)) > "$WORK/flips"
      w=\$((120 - (f % 2) * 10))
      tmux -L $cs resize-window -t 0 -x \$w -y 30
      i=0
      while [ \$i -lt 50 ] && [ "\$(tmux -L $SOCK list-clients -F '#{client_width}')" != \$w ]; do sleep 0.1; i=\$((i + 1)); done
    fi ;;
esac
echo "\$*" >> "$WORK/calls"
exec tmux "\$@"
EOF
chmod +x "$WORK/tmux-wrap"
tmux -L "$cs" set -g window-size manual
echo 1 > "$WORK/flips"; rm -f "$WORK/calls"
TMUX_BIN="$WORK/tmux-wrap" "$PRESIZE" "$c"
check "second pass applied the new width (110x29)" "[[ \"\$(wsize s2)\" == '110x29 ' ]]"
check "two reads, two writes" "[[ \$(grep -c 'show -gqv window-size' '$WORK/calls') -eq 2 && \$(grep -c 'set -g default-size' '$WORK/calls') -eq 2 ]]"
# s2 is at the target now, so knock it off size or the first pass has nothing to write.
tx resize-window -t s2 -x 80 -y 24; tx set -wu -t s2 window-size
echo 98 > "$WORK/flips"; rm -f "$WORK/calls"
TMUX_BIN="$WORK/tmux-wrap" "$PRESIZE" "$c"
check "client never settles -> stops at 3 passes" "[[ \$(grep -c 'show -gqv window-size' '$WORK/calls') -eq 3 ]]"

# --- S-1: the conf's hooks drive presize.sh end to end -----------------------
echo "S-1: conf hooks pre-size on attach and on resize, switches change nothing"
for s in ${CSOCKS[@]+"${CSOCKS[@]}"}; do tmux -L "$s" kill-server 2>/dev/null; done
CSOCKS=()
kill_server
boot_server s1 "$WORK"
for s in s1 s2 s3 s4; do
  [[ $s == s1 ]] || tx new-session -d -s "$s" -x 80 -y 24 -c "$WORK"
  tx new-window -d -t "$s" -c "$WORK"
done
# Rails exist on every window before the client attaches.
poll_until 10 "[[ \$(tx list-panes -a -F '#{@fleet-sidenav}' | grep -cx 1) -eq 8 ]]"
tx set-hook -g window-resized "run-shell 'echo #{window_id} >> $RESIZED'"
: > "$RESIZED"

# unviewed <W>x<H> — true when every window outside s1 is that size, with no
# window-size override left behind.
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
unviewed() {
  [[ -z "$(tx list-windows -a -F '#{session_name} #{window_width}x#{window_height}' | awk -v t="$1" '$1 != "s1" && $2 != t')" ]] &&
    [[ -z "$(for w in $(tx list-windows -a -F '#{session_name} #{window_id}' | awk '$1 != "s1" {print $2}'); do tx show-options -wqv -t "$w" window-size; done)" ]]
}
sizes() { tx list-windows -a -F '#{window_id} #{window_width}x#{window_height}'; }
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
settled() { ! pgrep -f "$PRESIZE" >/dev/null; }

client 100 30 s1
cs="${CSOCKS[0]}"
tmux -L "$cs" set -g window-size manual
poll_until 10 "unviewed 100x29"
check "attach: every unviewed window is 100x29, window-size unset" "unviewed 100x29"
check "attach: rails are 30 cols" "[[ -z \"\$(tx list-panes -a -F '#{session_name} #{@fleet-sidenav} #{pane_width}' | awk '\$1 != \"s1\" && \$2 == 1 && \$3 != 30')\" ]]"

echo "20 switch-client calls change no window size"
poll_until 10 settled
sleep 0.5
before="$(sizes)"; changed=0
for i in $(seq 0 19); do
  tx switch-client -c "$c" -t "=s$(( i % 4 + 1 ))"
  [[ "$(sizes)" == "$before" ]] || changed=$(( changed + 1 ))
done
tx switch-client -c "$c" -t =s1
sleep 0.5
check "no window changed size across 20 switches" "[[ $changed -eq 0 && \"\$(sizes)\" == \"$before\" ]]"

echo "terminal resize and a 10-resize burst converge"
tmux -L "$cs" resize-window -t 0 -x 120 -y 34
poll_until 10 "unviewed 120x33"
check "resize: unviewed windows follow to 120x33" "unviewed 120x33"
for i in $(seq 10); do
  tmux -L "$cs" resize-window -t 0 -x $(( 100 + i )) -y 34
  sleep 0.1
done
poll_until 10 "unviewed 110x33 && settled"
check "burst: unviewed windows end at 110x33" "unviewed 110x33"
check "burst: no presize.sh left running" "settled"

echo "sourcing the conf twice leaves the hooks as they were"
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
hooks() { tx show-hooks -g client-attached; tx show-hooks -g client-resized; }
# shellcheck disable=SC2034 # read inside the eval'd check() condition
once="$(hooks)"
tx source-file "$REPO/conf/agent-fleet.conf"
tx source-file "$REPO/conf/agent-fleet.conf"
check "show-hooks identical after two more sources" "[[ \"\$(hooks)\" == \"\$once\" ]]"
check "client-attached: sidenav ensure and a backgrounded presize" "[[ \$(tx show-hooks -g client-attached | grep -c 'sidenav-toggle.sh.* ensure') -eq 1 && \$(tx show-hooks -g client-attached | grep -c 'run-shell -b .*presize.sh') -eq 1 ]]"
check "client-resized: one backgrounded presize" "[[ \$(tx show-hooks -g client-resized | grep -c 'run-shell -b .*presize.sh') -eq 1 ]]"

echo "window-size largest -> unviewed windows are not resized"
tx set -g window-size largest
: > "$RESIZED"
tmux -L "$cs" resize-window -t 0 -x 140 -y 40
poll_until 10 "[[ \$(tx list-clients -F '#{client_width}') == 140 ]]"
sleep 1
n=0; for w in $(tx list-windows -a -F '#{session_name} #{window_id}' | awk '$1 != "s1" {print $2}'); do n=$(( n + $(nresized "$w") )); done
check "resize count 0 on every unviewed window" "[[ $n -eq 0 ]]"

exit "$FAIL"
