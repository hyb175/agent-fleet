#!/usr/bin/env bash
# t-resume.sh — claude session resume survives MULTIPLE reboots.
#   - the saved session id is recorded, respawned as `claude --resume <id>`,
#     re-tagged + gate-file re-armed after restore (so the next auto-save keeps
#     it), and stale per-pane files from the previous boot are purged
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-resume:"
CACHE="$XDG_CACHE_HOME/agent-fleet"
UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$CACHE/panes" "$WORK/r"
touch "$CACHE/hooks-settings.json"

boot_server __boot__ "$WORK"
tx new-session -d -s work -n work -c "$WORK/r"
sleep 0.6
wp="$(tx list-panes -t work -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
tx set-option -p -t "$wp" @fleet-session "$UUID"       # as the status hook would
printf '%s\n' "$UUID" > "$CACHE/panes/$wp.session"
tx kill-session -t __boot__ 2>/dev/null; sleep 0.3

"$REPO/scripts/persist-save.sh"
check "save#1 records the session id" "grep -q '$UUID' '$CACHE/fleet.state'"

# reboot 1 (with stale decoys from the 'previous boot')
tx kill-server; sleep 0.4
printf 'junk\n'      > "$CACHE/panes/%0.status"
printf 'stale-sid\n' > "$CACHE/panes/%1.session"
"$REPO/scripts/persist-restore.sh"
sleep 0.6
check "stale decoys purged on boot" "[[ ! -f '$CACHE/panes/%0.status' && ! -f '$CACHE/panes/%1.session' ]]"
starts="$(tx list-panes -t work -F '#{pane_start_command}')"   # buffered: see t-staleness pipefail note
check "respawned with claude --resume" "grep -q 'claude --resume $UUID' <<<\"\$starts\""
rp="$(tx list-panes -t work -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
check "@fleet-session re-tagged" "[[ \"\$(tx display-message -p -t $rp '#{@fleet-session}')\" == '$UUID' ]]"
check "gate file re-armed" "grep -qx '$UUID' '$CACHE/panes/$rp.session'"

# the ~15s auto-save that used to drop the id
"$REPO/scripts/persist-save.sh"
check "save#2 still records the session id" "grep -q '$UUID' '$CACHE/fleet.state'"

# reboot 2
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
sleep 0.6
starts="$(tx list-panes -t work -F '#{pane_start_command}')"
check "reboot #2 STILL resumes" "grep -q 'claude --resume $UUID' <<<\"\$starts\""

# --- no saved session-id: a known agent relaunches FRESH; a shell stays a shell ---
tx new-session -d -s fresh -n fresh -c "$WORK/r"    # agent kind, but no id captured
fa="$(tx list-panes -t fresh -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
tx set-option -p -t "$fa" @fleet-agent-kind claude
tx new-session -d -s plain -n plain -c "$WORK/r"    # bare shell: no kind, no id
sleep 0.4
"$REPO/scripts/persist-save.sh"
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"; sleep 0.6
fstart="$(tx list-panes -t fresh -F '#{?@fleet-sidenav,1,0}|#{pane_start_command}' | awk -F'|' '$1 != "1" {print $2}')"
pstart="$(tx list-panes -t plain -F '#{?@fleet-sidenav,1,0}|#{pane_start_command}' | awk -F'|' '$1 != "1" {print $2}')"
check "missing-id agent relaunches fresh claude" "grep -q 'claude' <<<\"\$fstart\""
check "fresh launch is NOT a resume" "! grep -q 'claude --resume' <<<\"\$fstart\""
check "fresh agent keeps the hooks overlay" "grep -q -- '--settings' <<<\"\$fstart\""
check "plain shell pane does NOT become an agent" "! grep -q 'claude' <<<\"\$pstart\""
exit $FAIL
