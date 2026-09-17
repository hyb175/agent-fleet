#!/usr/bin/env bash
# t-answer.sh — `agent-fleet answer`: guarded keystrokes into a waiting agent.
#   - approve / text land in a pane genuinely blocked on read(1)
#   - --fp refuses when the pane changed since the caller looked; a state that
#     moved on refuses; federated panes refuse — nothing is sent on refusal
#   - a task id resolves to its record's pane
#   - --all approve confirms first (--yes skips), re-reads status per pane
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-answer:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
SNAPF="$CACHE/fleet.snapshot"
mkdir -p "$CACHE/panes" "$CACHE/tasks"
af() { AGENT_FLEET_SOCKET="$SOCK" "$REPO/bin/agent-fleet" "$@"; }

boot_server t "$WORK"
# This suite drives the snapshot by hand; the conf's auto-spawned daemon
# would overwrite it. Kill it and wait for the lock to clear.
stop_daemon() {
  kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
  for _ in $(seq 1 30); do [[ -d "$CACHE/snapshotd.lock" ]] || break; sleep 0.2; done
}
stop_daemon
reader() {  # <prompt> <outfile> -> pane id of a window blocked on read
  tx new-window -d -P -F '#{pane_id}' -t t: \
    "bash -c 'read -r -p \"$1 \" a; printf %s \"answered:\$a\" > $2; sleep 60'"
}
ap="$(reader 'Proceed?' "$WORK/ans1")"
tp="$(reader 'Reply?'   "$WORK/ans2")"
sp="$(reader 'Sure?'    "$WORK/ans3")"
sleep 0.6
stop_daemon   # new-window re-armed the hook
snap() { { printf 'T %s 1\n' "$(date +%s)"; printf '%s\n' "$@"; } > "$SNAPF"; }
snap "A ws|@1|1|a|$ap|claude|wait|1|60|approve me" \
     "A ws|@2|2|t|$tp|claude|wait|1|60|reply to me" \
     "A ws|@3|3|s|$sp|claude|wait|1|60|stale probe"

# fp is stable across two reads of an unchanged pane, and matches the inbox's row key.
fp1="$(af answer "$ap" fp)"; fp2="$(af answer "$ap" fp)"
check "fp is a checksum" "[[ '$fp1' =~ ^[0-9]+$ ]]"
check "fp stable while the pane is unchanged" "[[ '$fp1' == '$fp2' ]]"
ikey="$(AGENT_FLEET_ROOT="$REPO" AGENT_FLEET_SOCKET="$SOCK" bash "$REPO/scripts/inbox.sh" --rows | grep 'approve me' | cut -f1)"
check "inbox row key carries the same fingerprint" "[[ '$ikey' == 'PANE:$ap|wait|$fp1' ]]"

af answer "$ap" approve --fp "$fp1" >/dev/null; rc=$?
for _ in $(seq 1 20); do [[ -s "$WORK/ans1" ]] && break; sleep 0.2; done
check "approve with a matching fp is sent (rc=$rc)" "[[ $rc -eq 0 && \"\$(cat '$WORK/ans1' 2>/dev/null)\" == 'answered:' ]]"

af answer "$tp" text "yes please;" >/dev/null
for _ in $(seq 1 20); do [[ -s "$WORK/ans2" ]] && break; sleep 0.2; done
check "text reply arrives whole (incl. trailing ;)" "[[ \"\$(cat '$WORK/ans2' 2>/dev/null)\" == 'answered:yes please;' ]]"

# Stale: content changed under the caller's fingerprint -> refused, nothing sent.
sfp="$(af answer "$sp" fp)"
tx send-keys -t "$sp" -l "unexpected input"
for _ in $(seq 1 25); do tx capture-pane -p -t "$sp" | grep -q 'unexpected input' && break; sleep 0.2; done
out="$(af answer "$sp" approve --fp "$sfp" 2>&1)" && rc=0 || rc=$?
check "stale fp refused (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'stale' <<<\"\$out\""
check "nothing sent to the stale pane" "[[ ! -s '$WORK/ans3' ]]"

# State moved on (snapshot says working) -> refused even without --fp.
snap "A ws|@3|3|s|$sp|claude|working|1|-|stale probe"
out="$(af answer "$sp" approve 2>&1)" && rc=0 || rc=$?
check "moved-on state refused" "[[ $rc -eq 1 ]] && grep -q 'moved on' <<<\"\$out\""

# Federated pane -> refused.
# shellcheck disable=SC2034 # read inside the eval'd check() condition
out="$(af answer 'devbox/%9' approve 2>&1)" && rc=0 || rc=$?
check "remote pane refused" "[[ $rc -eq 1 ]] && grep -q 'remote' <<<\"\$out\""

# Task id resolves to the record's pane.
dp="$(reader 'Deny?' "$WORK/ans4")"; sleep 0.6; stop_daemon
printf 'id t-ans\nintent answer by id\npane %s\n' "$dp" > "$CACHE/tasks/t-ans"
printf 't-ans\n' > "$CACHE/panes/$dp.task"
snap "A ws|@4|4|d|$dp|claude|wait|1|60|answer by id"
af answer t-ans text "via task id" >/dev/null; rc=$?
for _ in $(seq 1 20); do [[ -s "$WORK/ans4" ]] && break; sleep 0.2; done
check "task id resolves to its pane (rc=$rc)" "[[ $rc -eq 0 && \"\$(cat '$WORK/ans4' 2>/dev/null)\" == 'answered:via task id' ]]"

# --all: confirm gate, --yes, per-pane status re-read, remote skipped.
b1="$(reader 'ok1?' "$WORK/b1")"; b2="$(reader 'ok2?' "$WORK/b2")"; b3="$(reader 'ok3?' "$WORK/b3")"
sleep 0.6; stop_daemon
printf 'wait\n' > "$CACHE/panes/$b1.status"
printf 'wait\n' > "$CACHE/panes/$b2.status"
printf 'working\n' > "$CACHE/panes/$b3.status"   # snapshot says wait; status says otherwise
snap "A ws|@1|1|b1|$b1|claude|wait|1|60|batch one" \
     "A ws|@2|2|b2|$b2|claude|wait|1|70|batch two" \
     "A ws|@3|3|b3|$b3|claude|wait|1|80|moved on" \
     "A devbox/ws|devbox/@1|1|rw|devbox/%9|claude|wait|1|30|remote thing"
# shellcheck disable=SC2034 # read inside the eval'd check() conditions
cancel="$(af answer --all approve </dev/null 2>&1)"
check "batch without confirmation cancels" "grep -q 'cancelled' <<<\"\$cancel\""
check "cancel sent nothing" "[[ ! -s '$WORK/b1' && ! -s '$WORK/b2' ]]"
# shellcheck disable=SC2034
bout="$(af answer --all approve --yes 2>&1)"
for _ in $(seq 1 20); do [[ -s "$WORK/b1" && -s "$WORK/b2" ]] && break; sleep 0.2; done
check "batch --yes: both waiting panes approved" "[[ -s '$WORK/b1' && -s '$WORK/b2' ]]"
check "batch: moved-on pane untouched" "[[ ! -s '$WORK/b3' ]]"
check "batch: honest tally" "grep -q 'approved 2 · skipped 2' <<<\"\$bout\""

exit "$FAIL"
