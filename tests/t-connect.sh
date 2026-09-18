#!/usr/bin/env bash
# t-connect.sh — `agent-fleet connect <dir>` feeds the dir back into zoxide,
# so the picker's connect view (ui/internal/picker, discovery and ranking
# tested there) ranks it next time.
# Uses a private zoxide DB (_ZO_DATA_DIR); skips if zoxide isn't installed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-connect:"
command -v zoxide >/dev/null 2>&1 || { echo "  SKIP: zoxide not installed"; exit 0; }
export _ZO_DATA_DIR="$WORK/zo"; mkdir -p "$_ZO_DATA_DIR"

# connect feeds zoxide
boot_server seed "$WORK"
mkdir -p "$WORK/root/fleet_only"
"$REPO/bin/agent-fleet" connect "$WORK/root/fleet_only" >/dev/null 2>&1 || true
check "connect registers the dir in zoxide" "zoxide query -l | grep -q 'root/fleet_only\$'"
exit "$FAIL"
