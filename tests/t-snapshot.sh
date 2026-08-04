#!/usr/bin/env bash
# t-snapshot.sh — snapshotd's A-record enrichments.
#   - scrape-tier agents (no hook status file) get a "~" label suffix;
#     hooked agents stay unmarked
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

kill "$(cat "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null
exit "$FAIL"
