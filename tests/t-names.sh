#!/usr/bin/env bash
# t-names.sh — pane/window naming.
#   - a fresh command-less window is named after the shell, not the
#     pane-shell.sh launcher (tmux names windows after the initial command)
#   - a split inside a named window never clobbers that name (the launcher's
#     rename is guarded on the window still carrying the launcher's own name)
#   - same-window agents are disambiguated in the picker: "name.<pane_index>"
#     suffixes appear only when a window holds more than one agent
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-names:"
boot_server t "$WORK"

# fresh window -> shell name
wid="$(tx new-window -d -P -F '#{window_id}' -t t:)"
sleep 1.5
wname="$(tx display-message -p -t "$wid" '#{window_name}')"
want="$(basename "${SHELL:-sh}")"
check "new window named after the shell (got: $wname)" "[[ '$wname' == '$want' ]]"

# split inside a named window keeps the name
awid="$(tx new-window -d -P -F '#{window_id}' -t t: -n keepme 'sleep 30')"
tx split-window -d -t "$awid"
sleep 1.5
check "split keeps the window's name" "[[ \"\$(tx display-message -p -t '$awid' '#{window_name}')\" == keepme ]]"

# picker disambiguation from a fabricated snapshot (8-field A records)
SNAPDIR="$XDG_CACHE_HOME/agent-fleet"; mkdir -p "$SNAPDIR"
now="$(date +%s)"
printf 'T %s 1\nA ws|@9|1|api|%%20|claude|working|1\nA ws|@9|1|api|%%21|claude|idle|2\nA ws|@8|2|solo|%%30|claude|idle|1\n' "$now" \
  > "$SNAPDIR/fleet.snapshot"
rows="$(AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" bash -c \
  'source "'"$REPO"'/scripts/status.sh"; source "'"$REPO"'/scripts/pick.sh"; prep_glyphs; list_fleet' 2>/dev/null)"
check "shared-window agents get .pane suffixes" "grep -q 'api.1' <<<\"\$rows\" && grep -q 'api.2' <<<\"\$rows\""
check "single agent stays unsuffixed" "grep -q 'solo' <<<\"\$rows\" && ! grep -q 'solo.1' <<<\"\$rows\""
exit $FAIL
