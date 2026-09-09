#!/usr/bin/env bash
# t-worktree.sh — worktree-per-task isolation + cleanup lifecycle.
#   - --isolated creates branch af/task/<slug> + a worktree; the agent starts
#     there; the record carries worktree/branch/repo; collisions get suffixes
#   - non-git dirs degrade to the shared checkout
#   - done/drop mark terminal states; clean refuses dirty/unmerged without
#     --force, honors --dry-run/--keep-branch, and ls surfaces orphans
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-worktree:"
WTROOT="$XDG_STATE_HOME/agent-fleet/worktrees"

# A git repo with an identity (commits need one) and one commit.
REPODIR="$WORK/myrepo"
mkdir -p "$REPODIR"
git -C "$REPODIR" init -q -b main
git -C "$REPODIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Fake agent binary so `task` spawns something inert.
FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"

af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }

# --- #4: creation ------------------------------------------------------------
out="$(af task "fix the parser" --repo "$REPODIR" --isolated)"
T1="${out%% *}"; P1="${out##* }"
sleep 0.4
REC="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T1"
check "task created ($T1)" "[[ '$T1' == t* ]]"
check "record carries branch"   "grep -qx 'branch af/task/fix-the-parser' '$REC'"
check "record carries worktree" "grep -q '^worktree $WTROOT/' '$REC'"
check "record carries repo"     "grep -qx 'repo $REPODIR' '$REC'"
WT1="$(awk '$1=="worktree"{print $2; exit}' "$REC")"
check "worktree exists" "[[ -d '$WT1' ]]"
check "worktree is on the task branch" "[[ \"\$(git -C '$WT1' symbolic-ref --short HEAD)\" == 'af/task/fix-the-parser' ]]"
check "agent pane cwd is the worktree" \
  "[[ \"\$(tx display-message -p -t $P1 '#{pane_current_path}')\" == '$WT1' ]]"
check "workspace named for the REPO, not the slug" "tx has-session -t =myrepo 2>/dev/null"

# Same-slug second task: suffixed branch + worktree, no collision.
out2="$(af task "fix the parser" --repo "$REPODIR" --isolated)"
T2="${out2%% *}"
REC2="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T2"
check "collision suffixes the branch" "grep -qx 'branch af/task/fix-the-parser-2' '$REC2'"
WT2="$(awk '$1=="worktree"{print $2; exit}' "$REC2")"
check "two tasks, two worktrees" "[[ -d '$WT2' && '$WT2' != '$WT1' ]]"

# Isolation proof: a file written in worktree 1 is invisible in worktree 2.
echo probe > "$WT1/probe.txt"
check "worktrees are isolated" "[[ ! -e '$WT2/probe.txt' ]]"

# Non-git dir degrades.
mkdir -p "$WORK/plaindir"
out3="$(af task "no repo here" --repo "$WORK/plaindir" --isolated 2>"$WORK/deg.err")"
T3="${out3%% *}"
check "non-git degrades with a note" "grep -q 'shared checkout' '$WORK/deg.err'"
check "degraded task has no worktree line" "! grep -q '^worktree ' '$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T3'"

# --- #5: lifecycle -----------------------------------------------------------
# Terminal marking.
af task "done" "$T1" >/dev/null
check "done appends state merged" "grep -q '^state merged ' '$REC'"

# Kill the agent first — the liveness guard is exercised separately below;
# here we want the UNMERGED guard to be the one that fires.
tx kill-pane -t "$P1" 2>/dev/null; sleep 0.3

# Unmerged branch: clean refuses without --force (T1 has a commit main lacks).
git -C "$WT1" -c user.email=t@t -c user.name=t add probe.txt
git -C "$WT1" -c user.email=t@t -c user.name=t commit -qm probe
out="$(af task clean "$T1" 2>&1)" && rc=0 || rc=$?
check "unmerged branch refused (rc)" "[[ $rc -ne 0 ]]"
check "unmerged branch refused (msg)" "grep -q 'not merged into' <<<\"\$out\""
check "worktree survived the refusal" "[[ -d '$WT1' ]]"

# Merge it, then clean succeeds and reclaims worktree + branch.
git -C "$REPODIR" -c user.email=t@t -c user.name=t merge -q af/task/fix-the-parser
check "dry-run prints, removes nothing" \
  "af task clean '$T1' --dry-run | grep -q 'would remove' && [[ -d '$WT1' ]]"
af task clean "$T1" >/dev/null
check "clean removed the worktree" "[[ ! -e '$WT1' ]]"
check "clean deleted the branch" "! git -C '$REPODIR' show-ref --verify --quiet refs/heads/af/task/fix-the-parser"
check "record marked cleaned" "grep -q '^state cleaned ' '$REC'"

# Dirty tree: drop + clean refuses without --force; --force reclaims.
echo dirt > "$WT2/dirt.txt"
af task drop "$T2" >/dev/null
check "drop appends state abandoned" "grep -q '^state abandoned ' '$REC2'"
out="$(af task clean "$T2" 2>&1)" && rc=0 || rc=$?
check "dirty worktree refused without --force" "[[ $rc -ne 0 && -d '$WT2' ]]"
af task clean "$T2" --force >/dev/null 2>&1 || true
check "--force reclaims the dirty worktree" "[[ ! -e '$WT2' ]]"

# --force must delete the branch too (regression: ${force:--d} once expanded
# to a stray '1' argument — branch survived and a branch named '1' was at risk).
check "--force deleted the branch too" "! git -C '$REPODIR' show-ref --verify --quiet refs/heads/af/task/fix-the-parser-2"

# --keep-branch reclaims the worktree but leaves the branch.
out4="$(af task "keep branch probe" --repo "$REPODIR" --isolated)"
T4="${out4%% *}"; P4="${out4##* }"
REC4="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T4"
WT4="$(awk '$1=="worktree"{print $2; exit}' "$REC4")"
tx kill-pane -t "$P4" 2>/dev/null; sleep 0.3
af task "done" "$T4" >/dev/null
af task clean "$T4" --keep-branch >/dev/null
check "--keep-branch removed the worktree" "[[ ! -e '$WT4' ]]"
check "--keep-branch left the branch" "git -C '$REPODIR' show-ref --verify --quiet refs/heads/af/task/keep-branch-probe"

# Env default + per-call opt-out.
out5="$(AGENT_FLEET_TASK_ISOLATED=1 af task "env default probe" --repo "$REPODIR")"
T5="${out5%% *}"
check "AGENT_FLEET_TASK_ISOLATED=1 isolates by default" \
  "grep -q '^worktree ' '$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T5'"
out6="$(AGENT_FLEET_TASK_ISOLATED=1 af task "opt out probe" --repo "$REPODIR" --no-isolated)"
T6="${out6%% *}"
check "--no-isolated overrides the env default" \
  "! grep -q '^worktree ' '$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T6'"

# A live agent's worktree is never swept without --force.
out7="$(af task "live agent probe" --repo "$REPODIR" --isolated)"
T7="${out7%% *}"
af task "done" "$T7" >/dev/null
out="$(af task clean "$T7" 2>&1)" && rc=0 || rc=$?
check "live agent's worktree refused without --force" "[[ $rc -ne 0 ]]"
check "liveness refusal names the pane" "grep -q 'still running' <<<\"\$out\""

# Non-terminal task: clean refuses to touch it.
out="$(af task clean "$T3" 2>&1)" || true
check "non-terminal task is skipped" "grep -q 'not terminal' <<<\"\$out\""

# Orphan: a worktree dir with no record shows up in ls.
mkdir -p "$WTROOT/myrepo-0000/stray"
check "ls lists orphaned worktrees" "af task ls | grep -q 'stray'"

rm -rf "$FAKEBIN"
exit "$FAIL"
