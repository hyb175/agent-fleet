#!/usr/bin/env bash
# t-presize-clients.sh — presize.sh with several clients, a nested client and
# windows spawned while nobody looks. Clients of a chosen size live on
# throwaway sockets of their own (a pane there runs `tmux attach` against the
# server under test); the nested client attaches from a pane of the server itself.
#
# Absence of a resize is read off a test-only window-resized counter (truncated
# just before each trigger), and every absence check sits next to a positive
# control from the same pass: unattached s3 took the triggering client's size.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CSOCKS=()
# shellcheck disable=SC2329 # invoked by the EXIT trap
_cleanup() {
  local s
  for s in ${CSOCKS[@]+"${CSOCKS[@]}"}; do tmux -L "$s" kill-server 2>/dev/null; done
  _lib_cleanup
}
trap _cleanup EXIT

AF="$REPO/bin/agent-fleet"
RESIZED="$WORK/resized"

# client <W> <H> <session> <id> — attach a W×H client from the socket
# "$SOCK-c<id>"; prints the client's name on the server under test.
client() {
  local s="$SOCK-c$4"
  tmux -L "$s" -f /dev/null new-session -d -x "$1" -y "$2" -- env -u TMUX tmux -L "$SOCK" attach -t "$3"
  poll_until 10 "[[ \$(tx list-clients -F '#{client_session}' | grep -cx '$3') -ge 1 ]]"
  tx list-clients -F '#{client_session} #{client_name}' | awk -v s="$3" '$1 == s { print $2; exit }'
}
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
wsize()    { tx list-windows -t "=$1" -F '#{window_width}x#{window_height}' | tr '\n' ' '; }
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
nresized() { grep -cx "$1" "$RESIZED" 2>/dev/null || true; }
# resizes_of <session> — total logged resizes across the session's windows.
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
resizes_of() { local n=0 w; for w in $(tx list-windows -t "=$1" -F '#{window_id}'); do n=$(( n + $(nresized "$w") )); done; echo "$n"; }
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
settled() { ! pgrep -f "$REPO/scripts/presize.sh" >/dev/null; }
# rails_ok <session> — every rail of the session is 30 cols and every window has one.
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
rails_ok() {
  [[ "$(tx list-panes -s -t "=$1" -F '#{@fleet-sidenav}' | grep -cx 1)" == "$(tx list-windows -t "=$1" | wc -l)" ]] &&
    [[ -z "$(tx list-panes -s -t "=$1" -F '#{@fleet-sidenav} #{pane_width}' | awk '$1 == 1 && $2 != 30')" ]]
}

echo "t-presize-clients:"
boot_server s1 "$WORK"
for s in s2 s3; do tx new-session -d -s "$s" -x 80 -y 24 -c "$WORK"; done
for s in s1 s2 s3; do tx new-window -d -t "=$s:" -c "$WORK"; done
poll_until 10 "[[ \$(tx list-panes -a -F '#{@fleet-sidenav}' | grep -cx 1) -eq 6 ]]"
tx set-hook -g window-resized "run-shell 'echo #{window_id} >> $RESIZED'"

sa="$SOCK-ca"; sb="$SOCK-cb"; CSOCKS=("$sa" "$sb")
a="$(client 100 30 s1 a)"; client 90 20 s2 b >/dev/null
tmux -L "$sa" set -g window-size manual
tmux -L "$sb" set -g window-size manual
# B attached last, so its pass is the one that lands: wait for it, not just for quiet.
poll_until 10 "[[ \"\$(wsize s3)\" == '90x19 90x19 ' ]] && settled"

echo "two clients: A's resize moves the unattached session, leaves B's alone"
: > "$RESIZED"
tx set-hook -ga client-resized "run-shell \"echo hook #{client_name} #{client_width} #{hook_client} >> /tmp/claude-1000/hk\""
tmux -L "$sa" resize-window -t 0 -x 120 -y 34
poll_until 10 "[[ \"\$(wsize s3)\" == '120x33 120x33 ' ]] && settled"
check "unattached s3 took A's new size (control)" "[[ \"\$(wsize s3)\" == '120x33 120x33 ' ]]"
check "B's session was not resized" "[[ \$(resizes_of s2) -eq 0 ]]"
check "B's windows keep B's size" "[[ \"\$(wsize s2)\" == '90x19 90x19 ' ]]"
check "default-size follows the client that moved" "[[ \"\$(tx show-options -gv default-size)\" == 120x33 ]]"

echo "nested client: no feedback loop"
: > "$RESIZED"
tx new-session -d -s host -x 70 -y 20 -c "$WORK" -- sh -c "env -u TMUX tmux -L $SOCK attach -t s1; sleep 300"
poll_until 10 "[[ \$(tx list-clients | wc -l) -ge 3 ]]"
n="$(tx list-clients -F '#{client_session} #{client_name}' | awk '$1 == "s1" && $2 != "'"$a"'" { print $2; exit }')"
# The host session has a rail too, so the client's size is the host pane's: 39x20.
nsz="$(tx display-message -p -t "$n" '#{client_width}x#{client_height}')"
poll_until 10 "[[ \"\$(wsize s3)\" == '39x19 39x19 ' ]] && settled"
check "unattached s3 took the nested client's size $nsz (control)" "[[ \"\$(wsize s3)\" == '39x19 39x19 ' ]]"
sleep 3
check "nested client's size is stable ($nsz -> now)" "[[ \"\$(tx display-message -p -t '$n' '#{client_width}x#{client_height}')\" == '$nsz' ]]"
check "the host window was not resized" "[[ \$(resizes_of host) -eq 0 ]]"
tx kill-session -t host
poll_until 10 "[[ \$(tx list-clients | wc -l) -eq 2 ]]"

echo "background spawns are born at the client's size"
tmux -L "$sa" resize-window -t 0 -x 110 -y 32
poll_until 10 "[[ \"\$(wsize s3)\" == '110x31 110x31 ' ]] && settled"
# tmux sizes a window born with no client of its own from the most recently
# active one (the "latest" policy), so A is the one typing.
tmux -L "$sa" send-keys -t 0 C-l
sleep 0.5
p1="$(env -u TMUX "$AF" add one --to s3 --cmd 'sleep 300')"
w1="$(tx display-message -p -t "$p1" '#{window_id}')"
check "add (no --focus, TMUX unset): 110x31 with a 30-col rail on return" \
  "[[ \"\$(tx display-message -p -t '$w1' '#{window_width}x#{window_height}')\" == 110x31 ]] && rails_ok s3"
env -u TMUX "$AF" add two --new-workspace s4 --cmd "sleep 300" >/dev/null
check "add --new-workspace: 110x31 with a 30-col rail on return" "[[ \"\$(wsize s4)\" == '110x31 ' ]] && rails_ok s4"
for i in 1 2 3; do env -u TMUX "$AF" add "b$i" --to s3 --cmd 'sleep 300' >/dev/null; done
check "three back-to-back adds are all 110x31 with rails" "[[ \"\$(tx list-windows -t =s3 -F '#{window_width}x#{window_height}' | sort -u)\" == 110x31 ]] && rails_ok s3"

echo "a window added to another client's session is left alone by a later resize of A"
tmux -L "$sb" send-keys -t 0 C-l  # B is the one typing now
sleep 0.5
env -u TMUX "$AF" add three --to s2 --cmd 'sleep 300' >/dev/null
check "it has B's size" "[[ \"\$(tx list-windows -t =s2 -F '#{window_width}x#{window_height}' | sort -u)\" == 90x19 ]]"
poll_until 10 settled
: > "$RESIZED"
tmux -L "$sa" resize-window -t 0 -x 130 -y 36
poll_until 10 "[[ \"\$(tx list-windows -t =s3 -F '#{window_width}x#{window_height}' | sort -u)\" == 130x35 ]] && settled"
check "s3 took A's new size (control)" "[[ \"\$(tx list-windows -t =s3 -F '#{window_width}x#{window_height}' | sort -u)\" == 130x35 ]]"
sleep 1
check "B's session: resize count 0" "[[ \$(resizes_of s2) -eq 0 ]]"

exit "$FAIL"
