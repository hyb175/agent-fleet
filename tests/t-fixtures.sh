#!/usr/bin/env bash
# t-fixtures.sh — the daemon's side of the snapshot contract
# (docs/snapshot-format.md): it writes A records with exactly the documented
# field count and sentinels, so the fixtures in tests/fixtures/snapshot
# describe what it really emits. The readers' side (every fixture parses,
# extra trailing fields are ignored, mixed.picker-order) is
# ui/internal/snapshot/snapshot_test.go.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-fixtures:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
SNAPF="$CACHE/fleet.snapshot"
mkdir -p "$CACHE/panes" "$CACHE/tasks"

# Live daemon: A records carry exactly the documented 13 fields, sentinels
# where a value is unknown, and the T record carries the interval.
boot_server t "$WORK"
PANES="$CACHE/panes"
hp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"
tx set-option -p -t "$hp" @fleet-agent-kind claude
printf 'wait\n' > "$PANES/$hp.status"
sp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"
tx set-option -p -t "$sp" @fleet-agent-kind codex
# The conf's own daemon (ensure hook) may already be running; either way one
# writer produces the file. Wait for both agents to appear.
wait_for 10 "grep -q '|$hp|' '$SNAPF' 2>/dev/null && grep -q '|$sp|' '$SNAPF' 2>/dev/null"
check "T record has epoch and interval" "grep -Eq '^T [0-9]+ [0-9]+$' '$SNAPF'"
check "every A record has 13 fields" "[[ -z \"\$(grep '^A ' '$SNAPF' | awk -F'|' 'NF!=13')\" ]]"
check "unknown values are the - sentinel (scrape-tier row)" "grep -Eq '^A [^|]*\\|[^|]*\\|[^|]*\\|[^|]*\\|$sp\\|codex~\\|[a-z]+\\|[0-9]+\\|-\\|-\\|-\\|-\\|-$' '$SNAPF'"
check "no raw | inside a field: field count is stable across rows" "[[ \"\$(grep '^A ' '$SNAPF' | awk -F'|' '{print NF}' | sort -u | wc -l | tr -d ' ')\" == '1' ]]"

exit "$FAIL"
