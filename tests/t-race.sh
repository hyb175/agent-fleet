#!/usr/bin/env bash
# t-race.sh — best-of-N task races.
#   - `task race N "<prompt>"` spawns N worktree tasks (own branch + pane
#     each) tagged `race <rid> k/N`; the snapshot's A record carries k/N
#   - `review --race` lists every attempt with its commits ahead and diff size
#   - `--pick k` merges that attempt into the repo, marks it merged and
#     reclaims it; the others are abandoned, their panes closed, their
#     worktrees and branches gone
#   - `task history` shows the race as ONE entry, `⑂N attempts`, merged
#   - refusals: N outside 2–9, a non-git dir, picking an unknown attempt,
#     deciding twice
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-race:"
FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }
dump() { local l; while IFS= read -r l; do printf '  [%s] %s\n' "$1" "$l"; done; }  # show a verb's output in the log
G=(-c user.email=t@t -c user.name=t)

REPODIR="$WORK/myrepo"; mkdir -p "$REPODIR"
git -C "$REPODIR" init -q -b main
git -C "$REPODIR" "${G[@]}" commit -q --allow-empty -m init
TASKS="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks"

# --- refusals -----------------------------------------------------------------
msg="$(af task race 1 "one way" --repo "$REPODIR" 2>&1)" && rc=0 || rc=$?
check "N=1 refused (rc=$rc)" "[[ $rc -eq 2 ]] && grep -q '2–9' <<<\"\$msg\""
mkdir -p "$WORK/plain"
msg="$(af task race 2 "no repo" --repo "$WORK/plain" 2>&1)" && rc=0 || rc=$?
check "non-git dir refused (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'needs a git repo' <<<\"\$msg\""

# --- spawn ------------------------------------------------------------------------
out="$(af task race 3 "try three ways" --repo "$REPODIR" 2>"$WORK/race.err")"; rc=$?
dump race <<<"$out"
RID="$(sed -n 's/^race \(r[0-9]*-[0-9]*\) .*/\1/p' <<<"$out")"
check "race spawned (rc=$rc) with an id ($RID)" "[[ $rc -eq 0 && -n '$RID' ]]"
check "host rung raised to worktree with a note" "grep -q 'worktree rung' '$WORK/race.err'"
T1="$(awk '$1=="1"{print $2}' <<<"$out")"; T2="$(awk '$1=="2"{print $2}' <<<"$out")"; T3="$(awk '$1=="3"{print $2}' <<<"$out")"
P1="$(awk '$1=="1"{print $3}' <<<"$out")"; P2="$(awk '$1=="2"{print $3}' <<<"$out")"; P3="$(awk '$1=="3"{print $3}' <<<"$out")"
check "three task records" "[[ -f '$TASKS/$T1' && -f '$TASKS/$T2' && -f '$TASKS/$T3' ]]"
check "records carry race <rid> k/N" "grep -qx 'race $RID 1/3' '$TASKS/$T1' && grep -qx 'race $RID 2/3' '$TASKS/$T2' && grep -qx 'race $RID 3/3' '$TASKS/$T3'"
check "distinct branches per attempt" "grep -qx 'branch af/task/try-three-ways-1' '$TASKS/$T1' && grep -qx 'branch af/task/try-three-ways-3' '$TASKS/$T3'"
WT1="$(awk '$1=="worktree"{print $2; exit}' "$TASKS/$T1")"; WT2="$(awk '$1=="worktree"{print $2; exit}' "$TASKS/$T2")"; WT3="$(awk '$1=="worktree"{print $2; exit}' "$TASKS/$T3")"
check "three worktrees exist" "[[ -d '$WT1' && -d '$WT2' && -d '$WT3' ]]"
check "three live panes" "tx list-panes -a -F '#{pane_id}' | grep -qx -- '$P1' && tx list-panes -a -F '#{pane_id}' | grep -qx -- '$P3'"
SNAPF="$XDG_CACHE_HOME/agent-fleet/$SOCK/fleet.snapshot"
wait_for 10 "grep -q '|$P2|' '$SNAPF' 2>/dev/null"
check "snapshot A record badges the attempt (field 13 = 2/3)" "grep '|$P2|' '$SNAPF' | awk -F'|' '{print \$13}' | grep -qx '2/3'"
check "task ls shows the badge" "af task ls | grep -F -- \"$T2\" | grep -q '⑂2/3'"

# Attempt 2 does the work; attempt 1 leaves uncommitted debris; 3 does nothing.
echo winner > "$WT2/answer.txt"
echo scratch > "$WT1/scratch.txt"

# A dirty winner is refused BEFORE any loser is touched.
msg="$(af review --race "$RID" --pick 2 2>&1)" && rc=0 || rc=$?
check "dirty winner: pick refused (rc=$rc)" "[[ $rc -ne 0 ]] && grep -q 'uncommitted changes' <<<\"\$msg\""
check "…losers untouched" "[[ -d '$WT1' && -d '$WT3' ]] && ! grep -q '^state abandoned ' '$TASKS/$T1'"

git -C "$WT2" "${G[@]}" add answer.txt && git -C "$WT2" "${G[@]}" commit -qm "attempt two"

# --- compare ------------------------------------------------------------------
cmp="$(af review --race "$RID" 2>&1 </dev/null)"; rc=$?
dump cmp <<<"$cmp"
check "compare lists all three attempts (rc=$rc)" "[[ $rc -eq 0 ]] && grep -c 'af/task/try-three-ways-' <<<\"\$cmp\" | grep -qx 3"
check "attempt 2 shows 1 ahead" "grep -F -- \"$T2\" <<<\"\$cmp\" | grep -q '1 ahead'"
check "attempt 1 shows uncommitted work" "grep -F -- \"$T1\" <<<\"\$cmp\" | grep -q 'uncommitted'"
check "intent in the header" "grep -q 'intent: try three ways' <<<\"\$cmp\""
msg="$(af review --race "$RID" --pick 9 2>&1)" && rc=0 || rc=$?
check "unknown attempt refused (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q \"no attempt '9'\" <<<\"\$msg\""
check "…and nothing was merged" "! grep -q 'attempt two' <<<\"\$(git -C '$REPODIR' log --oneline)\""

# --- decide -------------------------------------------------------------------
dec="$(af review --race "$RID" --pick 2 2>&1)"; rc=$?
dump pick <<<"$dec"
check "pick exits clean (rc=$rc)" "[[ $rc -eq 0 ]]"
check "winner's commit landed on main" "grep -q 'attempt two' <<<\"\$(git -C '$REPODIR' log --oneline)\""
check "winner marked merged" "grep -q '^state merged ' '$TASKS/$T2'"
check "losers marked abandoned" "grep -q '^state abandoned ' '$TASKS/$T1' && grep -q '^state abandoned ' '$TASKS/$T3'"
check "all three worktrees reclaimed (dirty loser included)" "[[ ! -e '$WT1' && ! -e '$WT2' && ! -e '$WT3' ]]"
check "loser branches gone" "! git -C '$REPODIR' show-ref --verify --quiet refs/heads/af/task/try-three-ways-1 && ! git -C '$REPODIR' show-ref --verify --quiet refs/heads/af/task/try-three-ways-3"
wait_for 5 "! tx list-panes -a -F '#{pane_id}' | grep -qx -- '$P1'"
check "every attempt's pane closed" "! tx list-panes -a -F '#{pane_id}' | grep -qxE -- '$P1|$P2|$P3'"
check "records report cleaned" "grep -q '^state cleaned ' '$TASKS/$T1' && grep -q '^state cleaned ' '$TASKS/$T2'"
# shellcheck disable=SC2034 # read inside the eval'd check() condition
msg="$(af review --race "$RID" --pick 1 2>&1)" && rc=0 || rc=$?
check "deciding twice refused (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'already decided' <<<\"\$msg\""
check "compare after the decision names the winner" "grep -q 'decided: $T2 won' <<<\"\$(af review --race '$RID' </dev/null)\""

# --- history: one entry ---------------------------------------------------------
hist="$(af task history 2>&1)"
dump hist <<<"$hist"
check "history shows the race once" "[[ \"\$(grep -c 'try three ways' <<<\"\$hist\")\" == 1 ]]"
check "…as the merged winner with the attempt count" "grep -F -- \"$T2\" <<<\"\$hist\" | grep -q 'merged' && grep -q '⑂3 attempts' <<<\"\$hist\""
check "…counted as one task, one merged" "grep -q '1 tasks, 1 merged' <<<\"\$hist\""

exit "$FAIL"
