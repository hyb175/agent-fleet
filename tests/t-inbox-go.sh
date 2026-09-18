#!/usr/bin/env bash
# t-inbox-go.sh — the Go inbox, driven through tmux.
#   - AGENT_FLEET_UI=go routes Prefix i to afui inbox
#   - rows: wait above done, grouped, preview shows the pane's question
#   - ^y approves through `agent-fleet answer` with the preview's fingerprint;
#     a pane that changed since is refused and nothing is sent
#   - ^t types a reply; ^a approves every waiting agent after a y
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-inbox-go:"
[[ -x "$REPO/bin/afui" ]] || { echo "  SKIP: bin/afui not built (make ui)"; exit 0; }
export AGENT_FLEET_UI=go
boot_server t "$WORK"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
mkdir -p "$CACHE/panes" "$CACHE/tasks"

reader() {  # <prompt> <outfile> -> pane id of a window blocked on read
  tx new-window -d -P -F '#{pane_id}' -t t: \
    "bash -c 'read -r -p \"$1 \" a; printf %s \"answered:\$a\" > $2; sleep 60'"
}
mark() {  # <pane> <state> <intent>
  tx set-option -p -t "$1" @fleet-agent-kind claude
  printf '%s\n' "$2" > "$CACHE/panes/$1.status"
  printf 'id t-%s\nintent %s\npane %s\nisolation host\n' "${1#%}" "$3" "$1" > "$CACHE/tasks/t-${1#%}"
  printf 't-%s\n' "${1#%}" > "$CACHE/panes/$1.task"
}
ap="$(reader 'Proceed with the fix?' "$WORK/ans1")"; mark "$ap" wait "approve me please"
tp="$(reader 'Reply?' "$WORK/ans2")";               mark "$tp" wait "reply to me"
dp="$(tx new-window -d -P -F '#{pane_id}' -t t: -n donewin 'sleep 60')"; mark "$dp" 'done' "finished thing"
sleep 0.6
wait_for 10 "grep -q '|$ap|' '$CACHE/fleet.snapshot' && grep -q '|$dp|' '$CACHE/fleet.snapshot'"

launch() {  # -> pane id running afui inbox
  tx new-window -d -P -F '#{pane_id}' -t t: -n inbox \
    "env AGENT_FLEET_ROOT='$REPO' AGENT_FLEET_SOCKET='$SOCK' XDG_CACHE_HOME='$XDG_CACHE_HOME' '$REPO/bin/afui' inbox"
}
ib="$(launch)"
wait_for 10 "tx capture-pane -p -t '$ib' | grep -q 'approve me please'"
check "rows list waiting agents by intent" "tx capture-pane -p -t '$ib' | grep -q 'approve me please' && tx capture-pane -p -t '$ib' | grep -q 'reply to me'"
check "done row under its own header" "tx capture-pane -p -t '$ib' | grep -q 'DONE' && tx capture-pane -p -t '$ib' | grep -q 'finished thing'"
check "header counts the queue" "tx capture-pane -p -t '$ib' | grep -q '2 need you · 1 done'"
wait_for 10 "tx capture-pane -p -t '$ib' | grep -q 'Proceed with the fix?'"
check "preview shows the selected pane's question" "tx capture-pane -p -t '$ib' | grep -q 'what it is asking' && tx capture-pane -p -t '$ib' | grep -q 'Proceed with the fix?'"

# ^y on the first (longest-waiting) row approves it.
tx send-keys -t "$ib" C-y
for _ in $(seq 1 25); do [[ -s "$WORK/ans1" ]] && break; sleep 0.2; done
check "^y sends Enter to the waiting pane" "[[ \"\$(cat '$WORK/ans1' 2>/dev/null)\" == 'answered:' ]]"
wait_for 5 "tx capture-pane -p -t '$ib' | grep -q 'sent ✓'"
check "inbox reports the send" "tx capture-pane -p -t '$ib' | grep -q 'sent ✓'"

# Stale guard: move to the reply row, let the preview fingerprint it, then
# change the pane underneath and approve -> refused, nothing sent.
tx send-keys -t "$ib" Down
wait_for 10 "tx capture-pane -p -t '$ib' | grep -q 'Reply?'"
tx send-keys -t "$tp" -l "unexpected input"
for _ in $(seq 1 25); do tx capture-pane -p -t "$tp" | grep -q 'unexpected input' && break; sleep 0.2; done
# The preview (and its fingerprint) is the user's last look: it does not
# follow the snapshot tick, so the CLI's recapture now differs -> refused.
tx send-keys -t "$ib" C-y
wait_for 5 "tx capture-pane -p -t '$ib' | grep -q 'stale'"
if ! tx capture-pane -p -t "$ib" | grep -q 'stale'; then
  tx capture-pane -p -t "$ib" | grep -v '^$' | sed -n '1,8p' | sed 's/^/  [debug] /'
fi
check "approve on a changed pane is refused as stale" "tx capture-pane -p -t '$ib' | grep -q 'stale'"
check "nothing was sent to the changed pane" "[[ ! -s '$WORK/ans2' ]]"

# Refresh the preview (^r reloads), then reply with ^t.
tx send-keys -t "$ib" C-r
sleep 0.8
tx send-keys -t "$ib" C-t
wait_for 5 "tx capture-pane -p -t '$ib' | grep -q '⏎ send'"
tx send-keys -t "$ib" -l "yes please"
tx send-keys -t "$ib" Enter
for _ in $(seq 1 25); do [[ -s "$WORK/ans2" ]] && break; sleep 0.2; done
if [[ ! -s "$WORK/ans2" ]]; then tx capture-pane -p -t "$ib" | grep -v '^$' | sed -n '1,8p' | sed 's/^/  [debug] /'; fi
check "^t reply arrives (after the typed text the pane already had)" "grep -q 'yes please' '$WORK/ans2' 2>/dev/null"

# Batch approve with confirmation.
tx send-keys -t "$ib" Escape
b1="$(reader 'ok1?' "$WORK/b1")"; mark "$b1" wait "batch one"
b2="$(reader 'ok2?' "$WORK/b2")"; mark "$b2" wait "batch two"
sleep 0.6
wait_for 10 "grep -q '|$b1|' '$CACHE/fleet.snapshot' && grep -q '|$b2|' '$CACHE/fleet.snapshot'"
ib="$(launch)"
wait_for 10 "tx capture-pane -p -t '$ib' | grep -q 'batch one'"
# Four waits: the two batch readers plus the two earlier stubs, whose status
# files stay 'wait' (they have no hooks to clear them).
tx send-keys -t "$ib" C-a
wait_for 5 "tx capture-pane -p -t '$ib' | grep -q 'approve ALL'"
check "^a asks before approving all" "tx capture-pane -p -t '$ib' | grep -q 'approve ALL 4 waiting'"
tx send-keys -t "$ib" n
wait_for 5 "tx capture-pane -p -t '$ib' | grep -q 'cancelled'"
check "n cancels" "[[ ! -s '$WORK/b1' && ! -s '$WORK/b2' ]]"
tx send-keys -t "$ib" C-a
wait_for 5 "tx capture-pane -p -t '$ib' | grep -q 'approve ALL'"
tx send-keys -t "$ib" y
for _ in $(seq 1 25); do [[ -s "$WORK/b1" && -s "$WORK/b2" ]] && break; sleep 0.2; done
check "y approves both waiting panes" "[[ -s '$WORK/b1' && -s '$WORK/b2' ]]"

exit "$FAIL"
