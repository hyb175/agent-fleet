#!/usr/bin/env bash
# t-staleness.sh — snapshot staleness detection.
#   - threshold scales with the daemon's poll interval (T's second field):
#     12s old at interval=15 is healthy; 90s old is stale
#   - legacy T lines (no interval) still detect staleness
#   - next-attention refuses to jump on a stale snapshot (clean exit 0)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-staleness:"
SNAPDIR="$XDG_CACHE_HOME/agent-fleet"; mkdir -p "$SNAPDIR"
now="$(date +%s)"

# NOTE: capture output BEFORE grepping. `fleet_rows | grep -q` flakes under
# pipefail: grep -q exits on the first match (the banner is the first row),
# the producer takes SIGPIPE writing the remaining rows, and pipefail turns
# the successful match into a failed pipeline.
fleet_rows() {  # render list_fleet against the fabricated snapshot
  AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" bash -c \
    'source "'"$REPO"'/scripts/status.sh"; source "'"$REPO"'/scripts/pick.sh"; prep_glyphs; list_fleet' 2>/dev/null
}

printf 'T %s 15\nA a|@1|1|w|%%5|claude|wait\n' "$(( now - 12 ))" > "$SNAPDIR/fleet.snapshot"
out="$(fleet_rows)"
check "12s @ interval=15 -> healthy" "! grep -q 'snapshot stale' <<<\"\$out\""

printf 'T %s 15\nA a|@1|1|w|%%5|claude|wait\n' "$(( now - 90 ))" > "$SNAPDIR/fleet.snapshot"
out="$(fleet_rows)"
check "90s @ interval=15 -> stale banner" "grep -q 'snapshot stale' <<<\"\$out\""

printf 'T %s\nA a|@1|1|w|%%5|claude|wait\n' "$(( now - 12 ))" > "$SNAPDIR/fleet.snapshot"
out="$(fleet_rows)"
check "legacy T (no interval) -> stale at 12s" "grep -q 'snapshot stale' <<<\"\$out\""

# next-attention: stale -> no jump, exit 0 (socket points nowhere; note() is a no-op)
printf 'T %s\nA a|@1|1|w|%%5|claude|wait\n' "$(( now - 90 ))" > "$SNAPDIR/fleet.snapshot"
AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" AGENT_FLEET_SOCKET="af-nowhere-$$" \
  bash "$REPO/scripts/next-attention.sh" %99 >/dev/null 2>&1
check "next-attention refuses stale snapshot (rc=0)" "[[ $? -eq 0 ]]"
exit $FAIL
