#!/usr/bin/env bash
# t-task.sh — task records + `agent-fleet task`.
#   - `task "<prompt>"` spawns an interactive agent (prompt as claude's
#     positional arg, status hooks attached) and writes a task record
#   - pane <-> task id resolve both ways; hook transitions append history
#     (no duplicates on a re-fired state); a visit's done->idle ack is logged
#   - the record survives save -> kill-server -> restore, re-linked to the
#     respawned pane's new id
#   - gc prunes the dead pane's pointer file but never the record
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-task:"
CACHE="$XDG_CACHE_HOME/agent-fleet"
AF="$REPO/bin/agent-fleet"
HOOK="$REPO/scripts/agent-status-hook.sh"
UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$WORK/repo"

# Stub claude: stays alive so the pane survives; the suite never runs the real CLI.
stub="$(mktemp -d)"
printf '#!/bin/sh\nexec sleep 300\n' > "$stub/claude"; chmod +x "$stub/claude"
export PATH="$stub:$PATH"

boot_server __boot__ "$WORK"

# --- create: one command -> live agent + record -------------------------------
out="$("$AF" task "Fix the flaky parser test" --repo "$WORK/repo")"; rc=$?
tid="${out%% *}"; pane="${out##* }"
check "task create rc=0, prints '<tid> <pane>'" "[[ $rc -eq 0 && '$tid' == t* && '$pane' == %* ]]"
rec="$CACHE/tasks/$tid"
check "record exists" "[[ -f '$rec' ]]"
check "record carries the intent" "grep -qx 'intent Fix the flaky parser test' '$rec'"
check "record carries the dir" "grep -qx 'dir $WORK/repo' '$rec'"
check "record carries the pane" "grep -qx 'pane $pane' '$rec'"
check "workspace named for the repo" "tx has-session -t '=repo' 2>/dev/null"
check "@fleet-task tagged on the pane" "[[ \"\$(tx display-message -p -t $pane '#{@fleet-task}')\" == '$tid' ]]"
check "pointer file resolves pane->task" "grep -qx '$tid' '$CACHE/panes/$pane.task'"
starts="$(tx list-panes -a -F '#{pane_id} #{pane_start_command}' | grep "^$pane ")"
check "prompt submitted to the agent" "grep -q 'flaky' <<<\"\$starts\""
check "status hooks attached" "grep -q -- '--settings' <<<\"\$starts\""
[[ "$starts" == *flaky* ]] || { echo "--- start command ---"; printf '%s\n' "$starts"; }
check "task show resolves by pane id" "'$AF' task show '$pane' | grep -qx 'id $tid'"

# --- hook transitions append history (once per transition) --------------------
hook() {  # <state> [stdin]
  TMUX_PANE="$pane" AGENT_FLEET_NOTIFY=0 bash "$HOOK" "$1" "$SOCK" claude
}
printf '{"session_id":"%s"}' "$UUID" | hook start
check "session id recorded in the task" "grep -qx 'session $UUID' '$rec'"
hook working  </dev/null
hook working  </dev/null      # re-fire (every PreToolUse): must not duplicate
hook "done"   </dev/null
check "history: one working, then done" \
  "[[ \"\$(grep -c '^state working ' '$rec')\" == 1 && \"\$(tail -1 '$rec')\" == 'state done '* ]]"
check "task ls shows current state" "'$AF' task ls | grep -q '$tid  *done'"

# Visiting a done agent acks it — the flip is logged as an idle transition.
"$REPO/scripts/status.sh" clear-done "$pane"
check "ack logged as idle" "[[ \"\$(tail -1 '$rec')\" == 'state idle '* ]]"

# --- survives a reboot, re-linked to the new pane id ---------------------------
tx kill-session -t __boot__ 2>/dev/null
"$REPO/scripts/persist-save.sh"
check "save records the task id" "grep -q '$tid' '$CACHE/fleet.state'"
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
sleep 0.6
np="$(tx list-panes -a -F '#{pane_id} #{@fleet-task}' 2>/dev/null | awk -v t="$tid" '$2==t{print $1; exit}')"
check "restored pane re-tagged with the task" "[[ -n \"\$np\" ]]"
[[ -n "$np" ]] || { echo "--- panes ---"; tx list-panes -a -F '#{pane_id} #{@fleet-task}'; }
check "record re-linked to the new pane" "grep -qx \"pane \$np\" '$rec'"
check "pointer file re-armed" "grep -qx '$tid' \"$CACHE/panes/\$np.task\""
check "history survived the reboot" "grep -q '^state working ' '$rec'"

# --- plain `add` records too; gc prunes pointers, never records ----------------
p2="$("$AF" add helper --to repo --cmd 'sleep 300')"
t2="$(cat "$CACHE/panes/$p2.task" 2>/dev/null)"
check "add creates a record (intent = name)" "[[ -n '$t2' ]] && grep -qx 'intent helper' '$CACHE/tasks/$t2'"
check "record kind follows the command" "grep -qx 'kind sleep' '$CACHE/tasks/$t2'"
tx kill-pane -t "$p2" 2>/dev/null; sleep 0.3
"$REPO/scripts/status.sh" gc
check "gc drops the dead pane's pointer" "[[ ! -f '$CACHE/panes/$p2.task' ]]"
check "gc keeps the record" "[[ -f '$CACHE/tasks/$t2' ]]"

rm -rf "$stub"
exit "$FAIL"
