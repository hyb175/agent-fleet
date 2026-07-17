#!/usr/bin/env bash
# t-hook.sh — agent-status-hook.sh: the Notification event is overloaded.
#
# Claude Code fires Notification BOTH for a real permission prompt (genuine
# 'wait') AND for the "waiting for your input" idle reminder ~Ns after a turn
# ends. The idle reminder must NOT overwrite the finished/idle status, or every
# idle agent turns red and the triage queue cries wolf. These tests pin that:
#   - Stop writes 'done'; a following idle Notification leaves 'done' standing
#   - a real permission Notification (mid-turn) writes 'wait'
#   - message text and the prev-state fallback both classify correctly
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-hook:"

HOOK="$REPO/scripts/agent-status-hook.sh"
CACHE="$XDG_CACHE_HOME/agent-fleet/panes"
PANE="%hooktest"
SF="$CACHE/${PANE}.status"

# fire <state> <notification-message-or-empty>  — run the hook exactly as Claude
# Code would: state as argv, event JSON piped on stdin. AGENT_FLEET_NOTIFY=0
# keeps the test from popping a real macOS notification.
fire() {
  local st="$1" msg="${2:-}"
  printf '{"session_id":"sess-123","hook_event_name":"Notification","message":"%s"}' "$msg" \
    | env TMUX_PANE="$PANE" AGENT_FLEET_NOTIFY=0 bash "$HOOK" "$st" "$SOCK"
}
st() { cat "$SF" 2>/dev/null | tr -d '\n'; }

rm -f "$SF"

# working -> wait(permission): a real prompt reached mid-turn stays 'wait'.
fire working ""
check "UserPromptSubmit writes working"        "[[ \"\$(st)\" == working ]]"
fire wait "Claude needs your permission to use Bash"
check "permission Notification writes wait"     "[[ \"\$(st)\" == wait ]]"

# the classic bug: turn ends (done), then the idle reminder must NOT clobber it.
fire done ""
check "Stop writes done"                        "[[ \"\$(st)\" == done ]]"
fire wait "Claude is waiting for your input"
check "idle reminder after done leaves done"    "[[ \"\$(st)\" == done ]]"

# message-independent fallback: an unknown-message 'wait' from a resting state
# is the idle reminder (Stop already fired); from 'working' it's a real prompt.
printf '%s\n' done > "$SF"
fire wait ""
check "unknown-msg wait from done -> suppressed" "[[ \"\$(st)\" == done ]]"
printf '%s\n' working > "$SF"
fire wait ""
check "unknown-msg wait from working -> wait"    "[[ \"\$(st)\" == wait ]]"

# a fresh agent (no status file yet) sitting idle: the idle reminder must not
# create a spurious 'wait' out of nothing.
rm -f "$SF"
fire wait "Claude is waiting for your input"
check "idle reminder on fresh agent writes nothing" "[[ ! -e \"$SF\" ]]"

# session id is captured from the JSON regardless of suppression.
check "session id captured from event JSON"     "[[ \"\$(cat "$CACHE/${PANE}.session" 2>/dev/null)\" == sess-123 ]]"

exit $FAIL
