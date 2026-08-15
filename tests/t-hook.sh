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
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings below
st() { cat "$SF" 2>/dev/null | tr -d '\n'; }

rm -f "$SF"

# working -> wait(permission): a real prompt reached mid-turn stays 'wait'.
fire working ""
check "UserPromptSubmit writes working"        "[[ \"\$(st)\" == working ]]"
fire wait "Claude needs your permission to use Bash"
check "permission Notification writes wait"     "[[ \"\$(st)\" == wait ]]"

# the classic bug: turn ends (done), then the idle reminder must NOT clobber it.
fire "done" ""
check "Stop writes done"                        "[[ \"\$(st)\" == done ]]"
fire wait "Claude is waiting for your input"
check "idle reminder after done leaves done"    "[[ \"\$(st)\" == done ]]"

# message-independent fallback: an unknown-message 'wait' from a resting state
# is the idle reminder (Stop already fired); from 'working' it's a real prompt.
printf '%s\n' "done" > "$SF"
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
check "session id captured from event JSON"     "[[ \"\$(cat '$CACHE/${PANE}.session' 2>/dev/null)\" == sess-123 ]]"

# --- SessionStart ('start'): records identity, never touches status ---
# It fires at launch, so an agent that is never prompted still gets a session id
# recorded and can be resumed after a reboot. It also fires on compaction, which
# happens mid-turn — writing a status there would clobber the real one.
SP="%starttest"; SSF="$CACHE/${SP}.status"
start_fire() {  # <source>
  printf '{"session_id":"sess-start","hook_event_name":"SessionStart","source":"%s"}' "$1" \
    | env TMUX_PANE="$SP" AGENT_FLEET_NOTIFY=0 bash "$HOOK" start "$SOCK" claude
}
rm -f "$SSF" "$CACHE/${SP}.session"
start_fire startup
check "SessionStart records the session id" "[[ \"\$(cat '$CACHE/${SP}.session' 2>/dev/null)\" == sess-start ]]"
check "SessionStart writes no status"       "[[ ! -e \"$SSF\" ]]"
printf 'working\n' > "$SSF"
start_fire compact
check "SessionStart on compact leaves status alone" "[[ \"\$(tr -d '\\n' < '$SSF')\" == working ]]"

# The overlay must actually REGISTER SessionStart — without it the hook never
# fires at launch and a never-prompted agent has no id to resume from.
overlay="$(AGENT_FLEET_SOCKET="$SOCK" "$REPO/bin/agent-fleet" hooks-file 2>/dev/null)"
check "overlay is valid JSON" "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$overlay' 2>/dev/null"
check "overlay registers SessionStart -> start" \
  "python3 -c \"import json,sys; d=json.load(open(sys.argv[1])); c=d['hooks']['SessionStart'][0]['hooks'][0]['command']; sys.exit(0 if ' start ' in c else 1)\" '$overlay' 2>/dev/null"

exit "$FAIL"
