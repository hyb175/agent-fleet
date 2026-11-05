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

# client <W> <H> <session> — attach a W×H client; prints its name.
client() {
  local s="$SOCK-c${#CSOCKS[@]}" n
  CSOCKS+=("$s")
  tmux -L "$s" -f /dev/null new-session -d -x "$1" -y "$2" -- tmux -L "$SOCK" attach -t "$3"
  poll_until 10 "[[ \$(tx list-clients -F '#{client_session}' | grep -cx '$3') -ge 1 ]]"
  tx list-clients -F '#{client_session} #{client_name}' | awk -v s="$3" '$1 == s { print $2; exit }'
}

# wsize <session> — "WxH" of every window of the session, space-separated.
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
wsize() { tx list-windows -t "$1" -F '#{window_width}x#{window_height}' | tr '\n' ' '; }
nresized() { grep -c "$1" "$RESIZED" 2>/dev/null || true; }

echo "t-presize:"

echo "pass resizes an unviewed window and restores window-size"
fresh
tx new-window -d -t s1 -c "$WORK"
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
tx new-window -d -t s2 -c "$WORK"
c="$(client 100 30 s1)"
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
c="$(client 100 30 s1)"
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
c="$(client 100 30 s1)"
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
c="$(client 80 24 s1)"
: > "$RESIZED"
"$PRESIZE" "$c"
check "s2 window is 80x23" "[[ \"\$(wsize s2)\" == '80x23 ' ]]"
check "rail pane is 30 wide" "[[ \"\$(tx display-message -p -t '$rail' '#{pane_width}')\" -eq 30 ]]"
check "default-size is 80x23" "[[ \"\$(tx show-options -gv default-size)\" == 80x23 ]]"

echo "10 concurrent runs -> exactly one reaches the write"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
c="$(client 100 30 s1)"
cat > "$WORK/tmux-wrap" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/calls"
exec tmux "\$@"
EOF
chmod +x "$WORK/tmux-wrap"
rm -f "$WORK/calls"
for _ in $(seq 10); do TMUX_BIN="$WORK/tmux-wrap" "$PRESIZE" "$c" & done; 
wait
check "one write among the wrapper calls" "[[ \$(grep -c resize-window '$WORK/calls') -eq 1 ]]"
check "the losers forked nothing (read + write only)" "[[ \$(wc -l < '$WORK/calls') -eq 2 ]]"
check "s2 resized" "[[ \"\$(wsize s2)\" == '100x29 ' ]]"

echo "stale token from a killed run does not block the next run"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
c="$(client 100 30 s1)"
( source "$REPO/scripts/cache.sh"; mkdir -p "$AF_CACHE_DIR"; echo "99999-12345" > "$AF_CACHE_DIR/presize.token" )
"$PRESIZE" "$c"
check "s2 resized despite the stale token" "[[ \"\$(wsize s2)\" == '100x29 ' ]]"

echo "client size changes between read and write -> next pass applies the new size, at most 3 passes"
fresh
tx new-session -d -s s2 -x 80 -y 24 -c "$WORK"
c="$(client 100 30 s1)"
cs="$SOCK-c0"  # client() runs in a subshell, so CSOCKS is not updated
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
check "two reads, two writes" "[[ \$(grep -c display-message '$WORK/calls') -eq 2 && \$(grep -c 'set -g default-size' '$WORK/calls') -eq 2 ]]"
echo 98 > "$WORK/flips"; rm -f "$WORK/calls"
TMUX_BIN="$WORK/tmux-wrap" "$PRESIZE" "$c"
check "client never settles -> stops at 3 passes" "[[ \$(grep -c display-message '$WORK/calls') -eq 3 ]]"

exit "$FAIL"
