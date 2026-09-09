#!/usr/bin/env bash
# t-inbox.sh — the attention inbox (Prefix i).
#   - rows: wait/done only, wait ranked above done, longest-in-state first,
#     titled by intent, remote rows passed through
#   - preview: wait shows the pane tail (the question); done with a worktree
#     shows the diffstat; remote shows the reduced-context note
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-inbox:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
SNAPF="$CACHE/fleet.snapshot"
mkdir -p "$CACHE/panes" "$CACHE/tasks"

inbox() { AGENT_FLEET_ROOT="$REPO" AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
          bash "$REPO/scripts/inbox.sh" "$@"; }

# --- rows from a fabricated snapshot ----------------------------------------
{ printf 'T %s 1\n' "$(date +%s)"
  printf 'A ws|@1|1|w1|%%10|claude|wait|1|60|short wait\n'
  printf 'A ws|@2|2|w2|%%11|claude|wait|1|900|long wait|-|+31-2\n'
  printf 'A ws|@3|3|w3|%%12|claude|done|1|300|finished thing\n'
  printf 'A ws|@4|4|w4|%%13|claude|working|1|-|busy thing\n'
  printf 'A devbox/ws|devbox/@1|1|rw|devbox/%%9|claude|wait|1|30|remote thing\n'
} > "$SNAPF"
# shellcheck disable=SC2034 # rows read inside the eval'd check() conditions below
rows="$(inbox --rows)"
check "wait+done rows only (3+1 remote)" "[[ \"\$(grep -c 'PANE:' <<<\"\$rows\")\" == '4' ]]"
check "working agents excluded" "! grep -q 'busy thing' <<<\"\$rows\""
check "rows titled by intent" "grep -q 'long wait' <<<\"\$rows\""
check "longest wait first" \
  "[[ \"\$(grep -n 'long wait' <<<\"\$rows\" | cut -d: -f1)\" -lt \"\$(grep -n 'short wait' <<<\"\$rows\" | cut -d: -f1)\" ]]"
check "wait ranks above done" \
  "[[ \"\$(grep -n 'short wait' <<<\"\$rows\" | cut -d: -f1)\" -lt \"\$(grep -n 'finished thing' <<<\"\$rows\" | cut -d: -f1)\" ]]"
# Escalation marker: past the threshold the row wears '!'; fresh waits do not.
check "escalated wait wears the ! marker" "grep -q 'wait 15m !' <<<\"\$rows\""
check "fresh wait unmarked"               "! grep -q 'wait 1m !' <<<\"\$rows\""
check "diffstat shown on the row"   "grep -q '· +31-2' <<<\"\$rows\""

# Zero-state reads as alive: totals from the snapshot, not a dead end.
{
  printf 'A ws|@4|4|w4|%%13|claude|working|1|-|busy thing\n'
  printf 'A ws|@5|5|w5|%%14|claude|idle|1|-|resting\n'
} > "$SNAPF"
# shellcheck disable=SC2034
zrows="$(inbox --rows)"
check "inbox zero shows fleet totals" "grep -q '2 agents: 1 working · 1 idle' <<<\"\$zrows\""
{
  printf 'A ws|@1|1|w1|%%10|claude|wait|1|60|short wait\n'
  printf 'A ws|@2|2|w2|%%11|claude|wait|1|900|long wait|-|+31-2\n'
  printf 'A ws|@3|3|w3|%%12|claude|done|1|300|finished thing\n'
  printf 'A ws|@4|4|w4|%%13|claude|working|1|-|busy thing\n'
  printf 'A devbox/ws|devbox/@1|1|rw|devbox/%%9|claude|wait|1|30|remote thing\n'
} > "$SNAPF"

# --- previews ---------------------------------------------------------------
# shellcheck disable=SC2034 # rprev read inside the eval'd check() condition below
rprev="$(inbox --preview 'PANE:devbox/%9|wait')"
check "remote preview shows the reduced-context note" \
  "grep -q 'remote agent on devbox' <<<\"\$rprev\""

# wait preview = live pane tail.
boot_server t "$WORK"
# The conf auto-spawns a snapshotd that would overwrite our fabricated
# snapshots mid-test; this suite drives the snapshot by hand. Kill it and
# wait for the lock (its cleanup also rm's the snapshot — re-fabricate after).
kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
for _ in $(seq 1 30); do [[ -d "$CACHE/snapshotd.lock" ]] || break; sleep 0.2; done
wp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'bash -c "echo may I run rm -rf scratch?; sleep 60"')"
sleep 0.5
# shellcheck disable=SC2034 # wprev read inside the eval'd check() condition below
wprev="$(inbox --preview "PANE:$wp|wait")"
check "wait preview shows the pane question" \
  "grep -q 'may I run rm -rf scratch?' <<<\"\$wprev\""

# done preview = worktree diffstat when the task has one.
REPODIR="$WORK/repo"; mkdir -p "$REPODIR"
git -C "$REPODIR" init -q -b main
git -C "$REPODIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPODIR" worktree add -q -b af/task/probe "$WORK/wt" >/dev/null 2>&1
echo change > "$WORK/wt/newfile.txt"
git -C "$WORK/wt" add newfile.txt
TID="t9-done"
printf 'id %s\nintent finished thing\npane %%12\nworktree %s\nbranch af/task/probe\nrepo %s\n' \
  "$TID" "$WORK/wt" "$REPODIR" > "$CACHE/tasks/$TID"
printf '%s\n' "$TID" > "$CACHE/panes/%12.task"
# Captured, not piped: grep -q's early exit would SIGPIPE the preview under
# pipefail (capture-then-grep — CONTRIBUTING).
# shellcheck disable=SC2034 # read inside the eval'd check() condition below
dprev="$(inbox --preview 'PANE:%12|done')"
check "done preview shows the diffstat" "grep -q 'newfile.txt' <<<\"\$dprev\""

# The normal done flow COMMITS its work — the diffstat must still show it
# (diff vs merge-base with the repo branch, not vs the worktree's own HEAD).
git -C "$WORK/wt" -c user.email=t@t -c user.name=t commit -qm probe
# shellcheck disable=SC2034
dprev2="$(inbox --preview 'PANE:%12|done')"
check "committed task work still previews" "grep -q 'newfile.txt' <<<\"\$dprev2\""

# --- inline answers -----------------------------------------------------
# A pane genuinely blocked on read(1): approve sends Enter, text sends a reply.
ap="$(tx split-window -d -P -F '#{pane_id}' -t t: \
  "bash -c 'read -r -p \"Proceed? \" a; printf %s \"answered:\$a\" > '$WORK'/ans1; sleep 60'")"
tp="$(tx split-window -d -P -F '#{pane_id}' -t t: \
  "bash -c 'read -r -p \"Reply? \" a; printf %s \"answered:\$a\" > '$WORK'/ans2; sleep 60'")"
sleep 0.6
{ printf 'T %s 1\n' "$(date +%s)"
  printf 'A ws|@1|1|appr|%s|claude|wait|1|60|approve me\n' "$ap"
  printf 'A ws|@2|2|text|%s|claude|wait|1|60|reply to me\n' "$tp"
} > "$SNAPF"
akey="$(inbox --rows | grep 'approve me' | cut -f1)"
tkey="$(inbox --rows | grep 'reply to me' | cut -f1)"
check "wait row key carries a fingerprint" "[[ '$akey' == PANE:$ap\|wait\|[0-9]* ]]"

inbox --answer approve "$akey" >/dev/null
for _ in $(seq 1 20); do [[ -s "$WORK/ans1" ]] && break; sleep 0.2; done
check "approve keyed the waiting pane" "[[ \"\$(cat '$WORK/ans1' 2>/dev/null)\" == 'answered:' ]]"

inbox --answer text "$tkey" "yes please;" >/dev/null
for _ in $(seq 1 20); do [[ -s "$WORK/ans2" ]] && break; sleep 0.2; done
check "free-text reply arrives whole (incl. trailing ;)" "[[ \"\$(cat '$WORK/ans2' 2>/dev/null)\" == 'answered:yes please;' ]]"

# Staleness guardrail: content changed under the row -> refused, nothing sent.
sp2="$(tx split-window -d -P -F '#{pane_id}' -t t: \
  "bash -c 'read -r -p \"Sure? \" a; printf %s \"answered:\$a\" > '$WORK'/ans3; sleep 60'")"
sleep 0.6
printf 'T %s 1\nA ws|@3|3|st|%s|claude|wait|1|60|stale probe\n' "$(date +%s)" "$sp2" > "$SNAPF"
skey="$(inbox --rows | grep 'stale probe' | cut -f1)"
tx send-keys -t "$sp2" -l "unexpected input"    # changes the pane content (no Enter)
for _ in $(seq 1 25); do
  tx capture-pane -p -t "$sp2" | grep -q 'unexpected input' && break; sleep 0.2
done
out="$(inbox --answer approve "$skey" 2>&1)" && rc=0 || rc=$?
check "stale row refused (rc)" "[[ $rc -ne 0 ]]"
check "stale row refused (msg)" "grep -q 'stale' <<<\"\$out\""
check "nothing was sent to the stale pane" "[[ ! -s '$WORK/ans3' ]]"

# State moved on underneath (snapshot says working now) -> refused.
printf 'T %s 1\nA ws|@3|3|st|%s|claude|working|1|-|stale probe\n' "$(date +%s)" "$sp2" > "$SNAPF"
out="$(inbox --answer approve "$skey" 2>&1)" && rc=0 || rc=$?
check "state-change refused" "[[ $rc -ne 0 ]] && grep -q 'moved on' <<<\"\$out\""

# Remote rows never accept keys.
# shellcheck disable=SC2034 # out read inside the eval'd check() condition below
out="$(inbox --answer approve 'PANE:devbox/%9|wait|123' 2>&1)" && rc=0 || rc=$?
check "remote row refuses inline answers" "[[ $rc -ne 0 ]] && grep -q 'remote' <<<\"\$out\""

# --- batch approve -----------------------------------------------------
# Two waiting readers; one pane whose STATUS FILE says it moved on (the batch
# gate re-reads status at send time); one remote row. ^a = approve all.
# New windows, not splits — the shared test window is out of split space by
# this point ("no space for new pane" would void the whole section).
ba1="$(tx new-window -d -P -F '#{pane_id}' -t t: \
  "bash -c 'read -r -p \"ok1? \" a; printf done1 > '$WORK'/ba1; sleep 60'")"
ba2="$(tx new-window -d -P -F '#{pane_id}' -t t: \
  "bash -c 'read -r -p \"ok2? \" a; printf done2 > '$WORK'/ba2; sleep 60'")"
ba3="$(tx new-window -d -P -F '#{pane_id}' -t t: \
  "bash -c 'read -r -p \"ok3? \" a; printf done3 > '$WORK'/ba3; sleep 60'")"
sleep 0.6
# new-window re-armed the conf's snapshotd hook — kill it again or it
# overwrites the fabricated snapshot below (same dance as after boot).
kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
for _ in $(seq 1 30); do [[ -d "$CACHE/snapshotd.lock" ]] || break; sleep 0.2; done
printf 'wait\n' > "$CACHE/panes/$ba1.status"
printf 'wait\n' > "$CACHE/panes/$ba2.status"
printf 'working\n' > "$CACHE/panes/$ba3.status"   # snapshot will SAY wait; status says otherwise
{
  printf 'T %s 1\n' "$(date +%s)"
  printf 'A ws|@1|1|b1|%s|claude|wait|1|60|batch one\n' "$ba1"
  printf 'A ws|@2|2|b2|%s|claude|wait|1|70|batch two\n' "$ba2"
  printf 'A ws|@3|3|b3|%s|claude|wait|1|80|moved on\n' "$ba3"
  printf 'A devbox/ws|devbox/@1|1|rw|devbox/%%9|claude|wait|1|30|remote thing\n'
} > "$SNAPF"
# No confirmation -> cancelled, nothing fired (the ^a guard).
# shellcheck disable=SC2034 # cancel/bout read inside the eval'd check() conditions below
cancel="$(inbox --answer-all </dev/null 2>&1)"
check "batch without confirmation cancels" "grep -q 'cancelled' <<<\"\$cancel\""
check "cancel sent nothing" "[[ ! -s '$WORK/ba1' && ! -s '$WORK/ba2' ]]"
# shellcheck disable=SC2034
bout="$(printf 'y' | inbox --answer-all 2>&1)"
for _ in $(seq 1 20); do [[ -s "$WORK/ba1" && -s "$WORK/ba2" ]] && break; sleep 0.2; done
check "batch: both waiting panes approved" "[[ -s '$WORK/ba1' && -s '$WORK/ba2' ]]"
check "batch: moved-on pane untouched" "[[ ! -s '$WORK/ba3' ]]"
check "batch: honest tally" "grep -q 'approved 2 · skipped 2' <<<\"\$bout\""

exit "$FAIL"
