#!/usr/bin/env bash
# t-progress.sh — the hook synthesizes terminal progress (OSC 9;4).
#   - working -> DCS-wrapped indeterminate bar written to the pane tty
#   - wait    -> red/error bar; done -> clear
#   - AGENT_FLEET_PROGRESS=0 disables emission
#   - no emission when the state didn't change (edge-triggered)
# Verified by tapping the pane's raw output stream with pipe-pane.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-progress:"
boot_server t "$WORK"
wp="$(tx list-panes -t t -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
RAW="$WORK/raw.log"
tx pipe-pane -t "$wp" -o "cat > $RAW"
sleep 0.3

hook() {  # <state> [VAR=VAL ...]
  local st="$1"; shift
  env AGENT_FLEET_NOTIFY=0 "$@" TMUX_PANE="$wp" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" "$st" "$SOCK" </dev/null
}
# `|| true`, not `|| echo 0`: grep -c prints the 0 itself and exits 1.
seq_count() { grep -ac $'\x1bPtmux;\x1b\x1b]9;4' "$RAW" 2>/dev/null || true; }

hook working; sleep 0.4
check "working emits a wrapped 9;4 sequence" "[[ \$(seq_count) -ge 1 ]]"
check "working = indeterminate (9;4;3)" "grep -aq $'\x1b\x1b]9;4;3' '$RAW'"

hook working; sleep 0.4
n_before="$(seq_count)"
check "repeat state does NOT re-emit (edge-triggered)" "[[ \$(seq_count) -eq $n_before ]]"

hook wait; sleep 0.4
check "wait = red/error bar (9;4;2)" "grep -aq $'\x1b\x1b]9;4;2;100' '$RAW'"
hook done; sleep 0.4
check "done clears (9;4;0)" "grep -aq $'\x1b\x1b]9;4;0' '$RAW'"

n_before="$(seq_count)"
hook working AGENT_FLEET_PROGRESS=0; sleep 0.4
check "AGENT_FLEET_PROGRESS=0 disables emission" "[[ \$(seq_count) -eq $n_before ]]"

tx pipe-pane -t "$wp"
exit $FAIL
