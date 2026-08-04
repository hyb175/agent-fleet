#!/usr/bin/env bash
# t-snapshot.sh — snapshotd's A-record enrichments.
#   - scrape-tier agents (no hook status file) get a "~" label suffix;
#     hooked agents stay unmarked
#   - waiting hooked agents carry a trailing age field (status-file mtime);
#     the picker renders it humanized ("wait 4m")
#   - the window's worst agent state lands in @fleet-win-state (tab glyph)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-snapshot:"
boot_server t "$WORK"
SNAPF="$XDG_CACHE_HOME/agent-fleet/fleet.snapshot"
PANES="$XDG_CACHE_HOME/agent-fleet/panes"; mkdir -p "$PANES"

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
# backdated here so the age is unambiguously non-zero).
printf 'wait\n' > "$PANES/$hp.status"
touch -d '@'"$(( $(date +%s) - 240 ))" "$PANES/$hp.status" 2>/dev/null \
  || touch -t "$(date -v-4M '+%Y%m%d%H%M.%S' 2>/dev/null)" "$PANES/$hp.status" 2>/dev/null
check "wait record carries age"        "wait_snap 'claude|wait|[0-9]*|2[0-9][0-9]\$'"
check "tab glyph: wait wins -> ◆"      "wait_opt ◆"

kill "$(cat "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null
# The dying daemon's cleanup rm's the snapshot — wait for the lock release
# BEFORE fabricating snapshots, or cleanup deletes them from under the checks.
for _ in $(seq 1 30); do [[ -d "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock" ]] || break; sleep 0.2; done

# Picker renders the age humanized, from a fabricated snapshot.
printf 'T %s 1\nA ws|@9|1|api|%%20|claude|wait|1|247\n' "$(date +%s)" > "$SNAPF"
# shellcheck disable=SC2034 # rows read inside the eval'd check() condition below
rows="$(AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" bash -c \
  'source "'"$REPO"'/scripts/status.sh"; source "'"$REPO"'/scripts/pick.sh"; prep_glyphs; list_fleet' 2>/dev/null)"
check "picker shows humanized wait age" "grep -q 'wait 4m' <<<\"\$rows\""

# Rail overflow: 10 agents, 12 usable lines -> a "+N more" row, not silence.
# Reclaim the agent panes' rows first — the 80x24 test window can run out of
# split space for the overflow rail otherwise.
tx kill-pane -t "$hp" 2>/dev/null; tx kill-pane -t "$sp" 2>/dev/null
{ printf 'T %s 1\n' "$(date +%s)"
  for k in $(seq 1 10); do printf 'A ws|@%d|%d|ag%d|%%4%d|claude|idle|1|-\n' "$k" "$k" "$k" "$k"; done
} > "$SNAPF"
op="$(tx split-window -P -F '#{pane_id}' -t t: \
  "env AGENT_FLEET_SIDENAV_MAX_ROWS=12 AGENT_FLEET_ROOT='$REPO' AGENT_FLEET_SOCKET='$SOCK' XDG_CACHE_HOME='$XDG_CACHE_HOME' '$REPO/scripts/sidenav.sh'")"
ok=0
for _ in $(seq 1 25); do
  tx capture-pane -p -t "$op" 2>/dev/null | grep -q 'more (prefix+o)' && { ok=1; break; }
  sleep 0.2
done
check "rail overflow shows +N more" "[[ $ok -eq 1 ]]"
check "overflow count is 9" "tx capture-pane -p -t '$op' | grep -q '+9 more'"
tx kill-pane -t "$op" 2>/dev/null
exit "$FAIL"
