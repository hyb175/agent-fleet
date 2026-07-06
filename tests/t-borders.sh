#!/usr/bin/env bash
# t-borders.sh — the active-pane indicator is contextual.
#   - unsplit window (rail + one work pane): no arrows, dim active border
#   - splitting the work area turns on arrows + accent (after-split hook)
#   - un-splitting (pane exit) turns them back off (reap-chained retune)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-borders:"
boot_server t "$WORK"
sleep 0.4

opt() { tx show -w -t t "$1" 2>/dev/null | awk '{ $1=""; sub(/^ /,""); print }'; }

# baseline: tune-all like a restore would
"$REPO/scripts/border-tune.sh"
check "unsplit: indicators=colour" "[[ \"\$(opt pane-border-indicators)\" == colour ]]"
check "unsplit: active border dim" "[[ \"\$(opt pane-active-border-style)\" == *292e42* ]]"

# split the work area -> after-split-window hook tunes this window
tx split-window -h -t t -c "$WORK" -- sleep 300
sleep 1
check "split: indicators=both (arrows on)" "[[ \"\$(opt pane-border-indicators)\" == both ]]"
check "split: active border accented" "[[ \"\$(opt pane-active-border-style)\" == *7aa2f7* ]]"

# kill the split's process -> pane-exited -> reap retunes all windows
pid="$(tx list-panes -t t -F '#{pane_pid} #{pane_start_command}' | awk '/sleep 300/{print $1; exit}')"
kill "$pid" 2>/dev/null
sleep 1.2
check "unsplit again: indicators=colour" "[[ \"\$(opt pane-border-indicators)\" == colour ]]"
check "unsplit again: active border dim" "[[ \"\$(opt pane-active-border-style)\" == *292e42* ]]"
exit $FAIL
