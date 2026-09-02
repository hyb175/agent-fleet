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
  printf 'A ws|@2|2|w2|%%11|claude|wait|1|900|long wait\n'
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

# --- previews ---------------------------------------------------------------
check "remote preview shows the reduced-context note" \
  "inbox --preview 'PANE:devbox/%9|wait' | grep -q 'remote agent on devbox'"

# wait preview = live pane tail.
boot_server t "$WORK"
wp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'bash -c "echo may I run rm -rf scratch?; sleep 60"')"
sleep 0.5
check "wait preview shows the pane question" \
  "inbox --preview 'PANE:$wp|wait' | grep -q 'may I run rm -rf scratch?'"

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
# pipefail (CONTRIBUTING #3).
# shellcheck disable=SC2034 # read inside the eval'd check() condition below
dprev="$(inbox --preview 'PANE:%12|done')"
check "done preview shows the diffstat" "grep -q 'newfile.txt' <<<\"\$dprev\""

exit "$FAIL"
