#!/usr/bin/env bash
# t-snapshot.sh — snapshotd's A-record enrichments.
#   - scrape-tier agents (no hook status file) get a "~" label suffix;
#     hooked agents stay unmarked
#   - waiting hooked agents carry a trailing age field (status-file mtime)
#     and the task intent, | scrubbed
#   - the window's worst agent state lands in @fleet-win-state (tab glyph)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-snapshot:"
boot_server t "$WORK"
SNAPF="$XDG_CACHE_HOME/agent-fleet/$SOCK/fleet.snapshot"
PANES="$XDG_CACHE_HOME/agent-fleet/$SOCK/panes"; mkdir -p "$PANES"

# Two "agents": both kind-tagged; only one has a hook status file.
hp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"
sp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"
tx set-option -p -t "$hp" @fleet-agent-kind claude
tx set-option -p -t "$sp" @fleet-agent-kind codex
printf 'working\n' > "$PANES/$hp.status"

AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  AGENT_FLEET_SNAP_INTERVAL=1 nohup "$REPO/scripts/snapshotd.sh" >/dev/null 2>&1 &

# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings below
wait_snap() {  # <pattern> — up to ~6s
  for _ in $(seq 1 30); do grep -q "$1" "$SNAPF" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}

check "hooked agent label unmarked"    "wait_snap '|$hp|claude|'"
check "scraped agent label gets ~"     "wait_snap '|$sp|codex~|'"
check "no ~ on the hooked agent"       "! grep -q 'claude~' '$SNAPF'"

# Tab glyph: worst state of the window's agents lands in @fleet-win-state.
# shellcheck disable=SC2329 # called only from inside eval'd check() condition strings below
wait_opt() {  # <glyph> — up to ~6s
  for _ in $(seq 1 30); do
    [[ "$(tx show-option -wqv -t t: @fleet-win-state 2>/dev/null)" == "$1" ]] && return 0
    sleep 0.2
  done
  return 1
}
check "tab glyph: working -> ⠿"        "wait_opt ⠿"

# Wait state: the record grows a numeric trailing age (from the file's mtime,
# backdated here so the age is unambiguously non-zero) and the task intent.
mkdir -p "$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks"
TID="t1-testtask"
printf 'id %s\nintent fix the auth|bug\npane %s\n' "$TID" "$hp" > "$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/$TID"
printf '%s\n' "$TID" > "$PANES/$hp.task"
printf 'wait\n' > "$PANES/$hp.status"
touch -d '@'"$(( $(date +%s) - 240 ))" "$PANES/$hp.status" 2>/dev/null \
  || touch -t "$(date -v-4M '+%Y%m%d%H%M.%S' 2>/dev/null)" "$PANES/$hp.status" 2>/dev/null
check "wait record carries age"        "wait_snap 'claude|wait|[0-9]*|2[0-9][0-9]|'"
check "record carries intent, | scrubbed" "wait_snap '|fix the auth¦bug|-|-|-\$'"
check "tab glyph: wait wins -> ◆"      "wait_opt ◆"

# Done state carries age too (same mtime source).
printf 'done\n' > "$PANES/$hp.status"
touch -d '@'"$(( $(date +%s) - 7200 ))" "$PANES/$hp.status" 2>/dev/null \
  || touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null)" "$PANES/$hp.status" 2>/dev/null
check "done record carries age"        "wait_snap 'claude|done|[0-9]*|7[0-9][0-9][0-9]|'"

kill "$(cat "$XDG_CACHE_HOME/agent-fleet/$SOCK/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null
# The dying daemon's cleanup rm's the snapshot — wait for the lock release
# BEFORE fabricating snapshots, or cleanup deletes them from under the checks.
for _ in $(seq 1 30); do [[ -d "$XDG_CACHE_HOME/agent-fleet/$SOCK/snapshotd.lock" ]] || break; sleep 0.2; done

exit "$FAIL"
