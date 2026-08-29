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

# Stub claude: records its argv (so prompt-integrity is asserted on what the
# agent actually RECEIVED, after the default-shell parse — not on the command
# string handed to tmux) and stays alive so the pane survives.
stub="$(mktemp -d)"
cat > "$stub/claude" <<SH
#!/bin/sh
printf '%s\n' "\$@" > "$WORK/claude.argv"
exec sleep 300
SH
chmod +x "$stub/claude"
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
check "status hooks attached" "grep -q -- '--settings' <<<\"\$starts\""
wait_for 10 "grep -q 'flaky' '$WORK/claude.argv'"
check "prompt received by the agent verbatim" \
  "grep -qx 'Fix the flaky parser test' '$WORK/claude.argv'"
[[ -f "$WORK/claude.argv" ]] || { echo "--- start command ---"; printf '%s\n' "$starts"; }
check "task show resolves by pane id" "'$AF' task show '$pane' | grep -qx 'id $tid'"

# --- a multi-line prompt survives the default-shell parse ---------------------
# The prompt travels as a window environment variable, so no shell (sh, dash,
# fish as default-shell) ever parses its content.
rm -f "$WORK/claude.argv"
ml_out="$("$AF" task "$(printf 'multi line prompt\nsecond line here')" --repo "$WORK/repo")"
ml_pane="${ml_out##* }"
wait_for 10 "grep -q 'second line here' '$WORK/claude.argv' 2>/dev/null"
# The prompt is the last argv entry (after --settings <path>), so its two lines
# are the file's last two.
check "multi-line prompt arrives intact" \
  "[[ \"\$(tail -2 '$WORK/claude.argv' 2>/dev/null)\" == \$'multi line prompt\nsecond line here' ]]"
check "multi-line agent pane is alive" "tx list-panes -a -F '#{pane_id}' | grep -qx '$ml_pane'"

# `--` forces the create form when the prompt collides with a subcommand.
esc_out="$("$AF" task -- "ls" --repo "$WORK/repo")"
esc_tid="${esc_out%% *}"
check "task -- 'ls' creates instead of listing" \
  "[[ '$esc_tid' == t* ]] && grep -qx 'intent ls' '$CACHE/tasks/$esc_tid'"

# --- hook transitions append history (once per transition) --------------------
hook() {  # <state> [stdin]
  TMUX_PANE="$pane" AGENT_FLEET_NOTIFY=0 bash "$HOOK" "$1" "$SOCK" claude
}
# SessionStart can fire before the parent writes the pane's .task pointer —
# the .session gate then closes with the record still blank, and a later event
# must recover the id.
mv "$CACHE/panes/$pane.task" "$CACHE/panes/$pane.task.hidden"
printf '{"session_id":"%s"}' "$UUID" | hook start
check "gate closed before the pointer: no session line yet" "! grep -q '^session ' '$rec'"
mv "$CACHE/panes/$pane.task.hidden" "$CACHE/panes/$pane.task"
printf '{"session_id":"%s"}' "$UUID" | hook working
check "session id recovered on a later event" "grep -qx 'session $UUID' '$rec'"
hook working  </dev/null      # re-fire (every PreToolUse): must not duplicate
hook "done"   </dev/null
check "session id recorded exactly once" "[[ \"\$(grep -c '^session ' '$rec')\" == 1 ]]"
check "history: one working, then done" \
  "[[ \"\$(grep -c '^state working ' '$rec')\" == 1 && \"\$(tail -1 '$rec')\" == 'state done '* ]]"
# Command substitution, not `| grep -q`: -q closing the pipe early SIGPIPEs
# task ls under pipefail once the listing has more than one row.
check "task ls shows current state" "grep -q '$tid  *done' <<<\"\$('$AF' task ls)\""

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
# The record already ended 'state idle' (the ack) — restore's own idle marker
# must dedupe against it, not stack a second one.
check "restore logs no duplicate idle" "[[ \"\$(grep -c '^state idle ' '$rec')\" == 1 ]]"

# --- plain `add` records too; gc prunes pointers, never records ----------------
p2="$("$AF" add helper --to repo --cmd 'sleep 300')"
t2="$(cat "$CACHE/panes/$p2.task" 2>/dev/null)"
check "add creates a record (intent = name)" "[[ -n '$t2' ]] && grep -qx 'intent helper' '$CACHE/tasks/$t2'"
check "record kind follows the command" "grep -qx 'kind sleep' '$CACHE/tasks/$t2'"
tx kill-pane -t "$p2" 2>/dev/null; sleep 0.3
"$REPO/scripts/status.sh" gc
check "gc drops the dead pane's pointer" "[[ ! -f '$CACHE/panes/$p2.task' ]]"
check "gc keeps the record" "[[ -f '$CACHE/tasks/$t2' ]]"
check "show falls back to a record scan for the dead pane" \
  "grep -qx 'id $t2' <<<\"\$('$AF' task show '$p2')\""
check "ls marks the dead pane's task gone" \
  "grep -q '$t2 .*(gone)' <<<\"\$('$AF' task ls)\""

# A crashed rewrite's leftover temp must not double-list its task.
cp "$CACHE/tasks/$t2" "$CACHE/tasks/$t2.tmp.999"
check "ls skips rewrite temps" \
  "[[ \"\$('$AF' task ls | grep -c \"^$t2 \")\" == 1 ]]"
rm -f "$CACHE/tasks/$t2.tmp.999"

rm -rf "$stub"
exit "$FAIL"
