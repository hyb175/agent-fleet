#!/usr/bin/env bash
# t-staleness.sh — snapshot staleness on the bash side.
#   - next-attention refuses to jump on a stale snapshot (clean exit 0)
# The renderers' stale banner (threshold = interval*3+7, legacy T lines) is
# covered by ui/internal/snapshot and ui/internal/rail tests.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-staleness:"
now="$(date +%s)"

# next-attention: stale -> no jump, exit 0 (socket points nowhere; note() is a
# no-op). The fabricated snapshot has to sit under THAT bogus socket's own
# scoped dir now, or next-attention would just see no snapshot at all and exit
# 0 via the wrong path — the check would still pass, but for the wrong reason.
NOWHERE_SOCK="af-nowhere-$$"
mkdir -p "$XDG_CACHE_HOME/agent-fleet/$NOWHERE_SOCK"
printf 'T %s\nA a|@1|1|w|%%5|claude|wait\n' "$(( now - 90 ))" \
  > "$XDG_CACHE_HOME/agent-fleet/$NOWHERE_SOCK/fleet.snapshot"
AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" AGENT_FLEET_SOCKET="$NOWHERE_SOCK" \
  bash "$REPO/scripts/next-attention.sh" %99 >/dev/null 2>&1
check "next-attention refuses stale snapshot (rc=0)" "[[ $? -eq 0 ]]"
exit "$FAIL"
