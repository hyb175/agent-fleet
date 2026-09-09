#!/usr/bin/env bash
# t-review.sh — the review flow: diff a done task, approve to merge/PR,
# or send notes back into the live agent session.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-review:"
FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"

af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }

REPODIR="$WORK/myrepo"; mkdir -p "$REPODIR"
git -C "$REPODIR" init -q -b main
git -C "$REPODIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

out="$(af task "add a feature" --repo "$REPODIR" --isolated)"
T1="${out%% *}"; P1="${out##* }"
sleep 0.4
REC="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T1"
WT="$(awk '$1=="worktree"{print $2; exit}' "$REC")"
echo feature > "$WT/feature.txt"
git -C "$WT" -c user.email=t@t -c user.name=t add feature.txt
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm feature

# --- diff ---------------------------------------------------------------------
# shellcheck disable=SC2034 # read inside the eval'd check() conditions below
d="$(af review "$T1" --diff-only)"
check "diff shows the committed task work" "grep -q 'feature.txt' <<<\"\$d\""

# Un-isolated task: review refuses with guidance.
out2="$(af task "plain one" --repo "$REPODIR")"
T2="${out2%% *}"
msg="$(af review "$T2" --diff-only 2>&1)" && rc=0 || rc=$?
check "worktree-less task refused" "[[ $rc -ne 0 ]] && grep -q 'no live worktree' <<<\"\$msg\""

# --- send back ----------------------------------------------------------------
msg="$(af review "$T1" --send "please add tests;" 2>&1)"
sleep 0.5
# shellcheck disable=SC2034 # cap read inside the eval'd check() condition below
cap="$(tx capture-pane -p -t "$P1")"
check "send-back reports the pane" "grep -q 'sent to' <<<\"\$msg\""
check "notes reached the live pane (trailing ; intact)" "grep -q 'please add tests;' <<<\"\$cap\""

# --send without notes: a clear error, not a silent set -e death.
msg="$(af review "$T1" --send 2>&1)" && rc=0 || rc=$?
check "--send without notes errors loudly" "[[ $rc -ne 0 ]] && grep -q 'needs notes' <<<\"\$msg\""

# Dead session: send-back refuses (no new agent spawned).
tx kill-pane -t "$P1" 2>/dev/null; sleep 0.3
msg="$(af review "$T1" --send "more notes" 2>&1)" && rc=0 || rc=$?
check "send-back to a dead session refused" "[[ $rc -ne 0 ]] && grep -q 'agent session is gone' <<<\"\$msg\""

# --- merge --------------------------------------------------------------------
af review "$T1" --merge >/dev/null 2>&1
# Captured, not piped: grep -q on a live git-log pipe SIGPIPEs under pipefail
# (capture-then-grep — this exact check flaked on the slower macOS runner).
# shellcheck disable=SC2034 # mlog read inside the eval'd check() condition below
mlog="$(git -C "$REPODIR" log --oneline -3)"
check "merge landed on main" "grep -q 'feature' <<<\"\$mlog\""
check "task marked merged" "grep -q '^state merged ' '$REC'"
# shellcheck disable=SC2034 # shown read inside the eval'd check() condition below
shown="$(af task show "$T1")"
check "clean hint printed on mark" "grep -q 'worktree' <<<\"\$shown\""

# Merged task now cleans (branch merged, agent dead).
af task clean "$T1" >/dev/null
check "post-merge clean reclaims the worktree" "[[ ! -e '$WT' ]]"

# --- PR path degrades without origin/gh --------------------------------------
out3="$(af task "pr probe" --repo "$REPODIR" --isolated)"
T3="${out3%% *}"; P3="${out3##* }"
tx kill-pane -t "$P3" 2>/dev/null
# shellcheck disable=SC2034 # msg read inside the eval'd check() condition below
msg="$(af review "$T3" --pr 2>&1)" && rc=0 || rc=$?
check "--pr without origin fails gracefully" "[[ $rc -ne 0 ]] && grep -q 'origin' <<<\"\$msg\""
check "failed PR does NOT mark merged" "! grep -q '^state merged ' '$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T3'"

# --- PR success: records NON-terminal 'pr', never 'merged' -------------------
BARE="$WORK/origin.git"
git init -q --bare "$BARE"
git -C "$REPODIR" remote add origin "$BARE"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "https://example.test/pr/1"
EOF
chmod +x "$FAKEBIN/gh"
REC3="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T3"
# shellcheck disable=SC2034 # msg read inside the eval'd check() conditions below
msg="$(af review "$T3" --pr 2>&1)" && rc=0 || rc=$?
check "--pr with origin+gh succeeds" "[[ $rc -eq 0 ]]"
check "PR guidance printed" "grep -q 'when it merges' <<<\"\$msg\""
check "state pr recorded" "grep -q '^state pr ' '$REC3'"
check "open PR is NOT marked merged" "! grep -q '^state merged ' '$REC3'"
# An open-PR task must not fail the bulk sweep (non-terminal -> skipped).
af task clean >/dev/null 2>&1 && rc=0 || rc=$?
check "bulk clean tolerates an open-PR task" "[[ $rc -eq 0 ]]"

# --- diffstat, context line + atomic finish ---------
out4="$(af task "atomic finish probe" --repo "$REPODIR" --isolated)"
T4="${out4%% *}"; P4="${out4##* }"
sleep 0.4
REC4="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$T4"
WT4="$(awk '$1=="worktree"{print $2; exit}' "$REC4")"
echo more > "$WT4/more.txt"
git -C "$WT4" -c user.email=t@t -c user.name=t add more.txt
git -C "$WT4" -c user.email=t@t -c user.name=t commit -qm more

# A done transition records the diffstat; working transitions never do.
hook4() {  # <state> <stdin-json>
  printf '%s' "$2" | TMUX_PANE="$P4" AF_TASK_PRESPAWNED=1 AGENT_FLEET_NOTIFY=0 \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" bash "$REPO/scripts/agent-status-hook.sh" "$1" "$SOCK" claude
}
hook4 'done' '{"hook_event_name":"Stop","session_id":"x"}'
check "done transition records a diffstat" "grep -Eq '^diffstat \+1-0 ' '$REC4'"
hook4 working '{"hook_event_name":"UserPromptSubmit","session_id":"x"}'
check "working transition records NO diffstat" "[[ \"\$(grep -c '^diffstat ' '$REC4')\" == 1 ]]"

# Committed-away delta: the next attention transition tombstones the number
# (a stale +N-N must never render as current).
git -C "$REPODIR" -c user.email=t@t -c user.name=t merge -q --no-edit af/task/atomic-finish-probe 2>/dev/null || true
hook4 'done' '{"hook_event_name":"Stop","session_id":"x"}'
check "clean diff tombstones the diffstat" "grep '^diffstat ' '$REC4' | tail -1 | grep -q '^diffstat - '"
git -C "$REPODIR" reset -q --hard HEAD~1 2>/dev/null || true   # undo probe merge for the finish below

# Atomic finish refuses BEFORE killing anything when the worktree is dirty.
echo scratch > "$WT4/scratch.tmp"
af review "$T4" --merge --clean >/dev/null 2>&1 && rc=0 || rc=$?
check "dirty worktree: finish refused" "[[ $rc -ne 0 ]]"
# shellcheck disable=SC2034 # panes_now read inside the eval'd check() condition below
panes_now="$(tx list-panes -a -F '#{pane_id}' 2>/dev/null)"
check "dirty worktree: agent pane still alive" "grep -qx -- '$P4' <<<\"\$panes_now\""
rm -f "$WT4/scratch.tmp"

# --clean without --merge is a usage error.
af review "$T4" --clean 2>/dev/null && rc=0 || rc=$?
check "--clean without --merge refused" "[[ $rc -eq 2 ]]"

# Atomic finish: context line, merge, pane closed, worktree reclaimed.
# shellcheck disable=SC2034 # ctx read inside the eval'd check() conditions below
ctx="$(af review "$T4" --merge --clean 2>&1)" && rc=0 || rc=$?
check "atomic finish exits clean" "[[ $rc -eq 0 ]]"
check "context line: id and branch" "grep -q \"review $T4 · af/task/atomic-finish-probe\" <<<\"\$ctx\""
check "context line: commits ahead" "grep -q '\[1 ahead\]' <<<\"\$ctx\""
check "context line: intent shown" "grep -q 'intent: atomic finish probe' <<<\"\$ctx\""
# shellcheck disable=SC2034
mlog2="$(git -C "$REPODIR" log --oneline -3)"
check "atomic finish merged the work" "grep -q 'more' <<<\"\$mlog2\""
check "atomic finish reclaimed the worktree" "[[ ! -e \"\$WT4\" ]]"
# shellcheck disable=SC2034 # panes_left read inside the eval'd check() condition below
panes_left="$(tx list-panes -a -F '#{pane_id}' 2>/dev/null)"
check "atomic finish closed the pane" "! grep -qx -- '$P4' <<<\"\$panes_left\""
check "record settles cleaned" "grep -q '^state cleaned ' '$REC4'"

# --- cross-task conflict warning ------------------------------
outa="$(af task "conflict a" --repo "$REPODIR" --isolated)"; TA="${outa%% *}"
outb="$(af task "conflict b" --repo "$REPODIR" --isolated)"; TB="${outb%% *}"
sleep 0.4
WTA="$(awk '$1=="worktree"{print $2; exit}' "$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$TA")"
WTB="$(awk '$1=="worktree"{print $2; exit}' "$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$TB")"
echo a > "$WTA/shared.txt"; echo also-a > "$WTA/only-a.txt"
echo b > "$WTB/shared.txt"
# shellcheck disable=SC2034 # ls_out read inside the eval'd check() conditions below
ls_out="$(af task ls)"
check "overlapping live tasks warn in task ls" \
  "grep -Eq \"conflict risk: ($TA <-> $TB|$TB <-> $TA): shared.txt\" <<<\"\$ls_out\""
check "disjoint file does not warn" "! grep -q 'only-a.txt' <<<\"\$ls_out\""
# shellcheck disable=SC2034
rv_out="$(af review "$TA" --merge --clean 2>&1 || true)"
check "review context carries the warning" "grep -q 'conflict risk:' <<<\"\$rv_out\""
rm -f "$WTA/shared.txt" "$WTA/only-a.txt" "$WTB/shared.txt"
# shellcheck disable=SC2034
ls_quiet="$(af task ls)"
check "clean worktrees stay quiet" "! grep -q 'conflict risk' <<<\"\$ls_quiet\""

rm -rf "$FAKEBIN"
exit "$FAIL"
