#!/usr/bin/env bash
# t-mouse.sh — the rail's border is not a resize handle.
#
# Dragging the rail↔work border used to resize the rail (tmux's stock
# MouseDrag1Border), and that border is exactly where a text selection in the
# work pane starts — so the rail kept ending up lopsided by accident. The conf
# guards the drag with @fleet-sidenav; every other border still resizes.
#
# Real mouse input needs a real client, so one tmux pane plays the terminal: a
# second session's pane runs `tmux attach` and the SGR mouse bytes go in with
# send-keys -H. Each sequence is ONE write — escape-time is 0, so a split write
# would read the leading ESC as a bare Escape key.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-mouse:"
boot_server t "$WORK"

# The pty: a wide host session, so the work area stays big enough to resize.
tx new-session -d -s h -x 200 -y 50 -c "$WORK"
cpane="$(tx new-window -d -P -F '#{pane_id}' -t h: -- env -u TMUX tmux -L "$SOCK" attach -t t)"
# The client sizes t's window and fires client-attached -> the rail is ensured.
poll_until 10 "[[ \"\$(tx list-panes -t t -F '#{@fleet-sidenav} #{pane_width}' | awk '\$1==1{print \$2}')\" == 30 ]]"

# Panes of t as "<sidenav> <pane_right> <pane_width>", rail first (pane_left 0).
panes() { tx list-panes -t t -F '#{?@fleet-sidenav,rail,work} #{pane_right} #{pane_width}'; }
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings
railw()  { panes | awk '$1=="rail"{print $3; exit}'; }
# A border's 1-based mouse column is the left/upper pane's right edge + 2.
col_of() { panes | awk -v k="$1" '$1==k{print $2 + 2; exit}'; }

# Press / drag / release, one write each, at row 10.
drag() {  # <from-col> <to-col>
  local c hex
  for c in "0;$1;10M" "32;$2;10M" "0;$2;10m"; do
    read -ra hex < <(printf '\033[<%s' "$c" | od -An -tx1)
    tx send-keys -t "$cpane" -H "${hex[@]}"
    sleep 0.3
  done
  sleep 0.5
}

# --- the rail's border ignores the drag ------------------------------------
rail_border="$(col_of rail)"
check "rail border is column 31 (a 30-col rail + its border)" "[[ '$rail_border' == 31 ]]"
drag "$rail_border" "$(( rail_border + 6 ))"
check "dragging the rail border does not resize it" "[[ \"\$(railw)\" == 30 ]]"

# --- ...and every other border still does (so the check above isn't vacuous) --
tx split-window -h -d -t t -c "$WORK" -- sleep 300
poll_until 10 "(( \$(panes | grep -c '^work') == 2 ))"
work_border="$(col_of work)"
before="$(panes | awk '$1=="work"{print $3; exit}')"
drag "$work_border" "$(( work_border + 6 ))"
after="$(panes | awk '$1=="work"{print $3; exit}')"
check "dragging a work-pane border still resizes ($before -> $after)" "(( after > before ))"
check "and the rail is still 30 cols" "[[ \"\$(railw)\" == 30 ]]"

exit "$FAIL"
