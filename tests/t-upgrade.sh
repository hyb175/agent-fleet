#!/usr/bin/env bash
# t-upgrade.sh — self-upgrade of a managed install.
#   - --check compares the installed version to the newest tag (injected)
#   - upgrade -y swaps in the new tree and keeps the old one as .prev
#   - --rollback restores .prev
#   - a dev checkout is detected and NOT modified (prints the git hint)
# Network is stubbed: AGENT_FLEET_TAGS_URL feeds the tag list, AGENT_FLEET_TARBALL
# feeds the download — so the test is fully offline and deterministic.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-upgrade:"

# --- build a "managed install" at $WORK/data/agent-fleet, pinned to 0.1.0 ---
# Pin the fixture's version explicitly so the test is independent of the repo's
# current release (a `release.sh` bump must not break it).
data="$WORK/data/agent-fleet"
mkdir -p "$data"
cp -r "$REPO/bin" "$REPO/conf" "$REPO/scripts" "$REPO/shims" "$data/"   # no .git -> managed
sed -i.bak -E 's/^AGENT_FLEET_VERSION="[^"]*"/AGENT_FLEET_VERSION="0.1.0"/' "$data/bin/agent-fleet"
rm -f "$data/bin/agent-fleet.bak"
MANAGED="$data/bin/agent-fleet"

# --- injected tag lists (GitHub /tags-shaped JSON) ---
newer="$WORK/tags-newer.json"; printf '[{"name":"v0.2.0"},{"name":"v0.1.0"}]\n' > "$newer"
same="$WORK/tags-same.json";   printf '[{"name":"v0.1.0"}]\n' > "$same"

# --- build the "v0.2.0" tarball the upgrade will fetch ---
mkdir -p "$WORK/new/agent-fleet-0.2.0"
cp -r "$REPO/bin" "$REPO/conf" "$REPO/scripts" "$REPO/shims" "$WORK/new/agent-fleet-0.2.0/"
sed -i.bak -E 's/^AGENT_FLEET_VERSION="[^"]*"/AGENT_FLEET_VERSION="0.2.0"/' "$WORK/new/agent-fleet-0.2.0/bin/agent-fleet"
rm -f "$WORK/new/agent-fleet-0.2.0/bin/agent-fleet.bak"
( cd "$WORK/new" && tar -czf "$WORK/new.tgz" agent-fleet-0.2.0 )

# helper: run the managed CLI with the stubs + a throwaway data home
run() { env XDG_DATA_HOME="$WORK/data" AGENT_FLEET_SOCKET="$SOCK" "$MANAGED" "$@"; }

# --- --check: newer tag available ---
out="$(AGENT_FLEET_TAGS_URL="file://$newer" run upgrade --check 2>&1)"
check "check reports installed 0.1.0"        "grep -q 'installed: 0.1.0' <<<\"\$out\""
check "check reports latest 0.2.0"           "grep -q 'latest:    0.2.0' <<<\"\$out\""
check "check says update available"          "grep -q 'update available' <<<\"\$out\""

# --- --check: no newer tag -> up to date ---
out="$(AGENT_FLEET_TAGS_URL="file://$same" run upgrade --check 2>&1)"
check "check says up to date when equal"     "grep -q 'up to date' <<<\"\$out\""

# --- upgrade -y: swap to 0.2.0, keep .prev at 0.1.0 ---
out="$(AGENT_FLEET_TAGS_URL="file://$newer" AGENT_FLEET_TARBALL="file://$WORK/new.tgz" run upgrade -y 2>&1)"
check "upgrade reports 0.1.0 -> 0.2.0"       "grep -q 'upgraded 0.1.0 → 0.2.0' <<<\"\$out\""
check "current is now 0.2.0"                 "[[ \"\$($MANAGED --version 2>/dev/null)\" == 'agent-fleet 0.2.0' ]]"
check ".prev backup exists"                  "[[ -d '$data.prev' ]]"
check ".prev holds the old 0.1.0"            "[[ \"\$($data.prev/bin/agent-fleet --version 2>/dev/null)\" == 'agent-fleet 0.1.0' ]]"

# --- already up to date: installed 0.2.0, latest 0.2.0 ---
printf '[{"name":"v0.2.0"}]\n' > "$WORK/tags-020.json"
out="$(AGENT_FLEET_TAGS_URL="file://$WORK/tags-020.json" run upgrade -y 2>&1)"
check "no-op when already current"           "grep -q 'already up to date (0.2.0)' <<<\"\$out\""

# --- rollback: restore 0.1.0 ---
out="$(run upgrade --rollback 2>&1)"
check "rollback restores 0.1.0"              "[[ \"\$($MANAGED --version 2>/dev/null)\" == 'agent-fleet 0.1.0' ]]"
check ".prev now holds 0.2.0"                "[[ \"\$($data.prev/bin/agent-fleet --version 2>/dev/null)\" == 'agent-fleet 0.2.0' ]]"

# --- dev checkout: never modified, prints the git hint ---
out="$(env XDG_DATA_HOME="$WORK/data" AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_TAGS_URL="file://$newer" \
        "$REPO/bin/agent-fleet" upgrade --check 2>&1)"
check "dev checkout detected"                "grep -q 'dev checkout' <<<\"\$out\""
check "dev checkout suggests git pull"       "grep -q 'git -C' <<<\"\$out\""

exit $FAIL
