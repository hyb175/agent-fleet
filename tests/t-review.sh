#!/usr/bin/env bash
# t-review.sh — the review flow (#9): diff a done task, approve to merge/PR,
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
# (CONTRIBUTING #3 — this exact check flaked on the slower macOS runner).
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

rm -rf "$FAKEBIN"
exit "$FAIL"
