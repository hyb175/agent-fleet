#!/usr/bin/env bash
# t-kimi.sh — kimi hook-tier support.
#   - `agent-fleet kimi-hooks` installs a fenced [[hooks]] block in
#     ~/.kimi/config.toml idempotently, preserves the user's config, and
#     removes cleanly
#   - the status hook's kind argument tags the pane (@fleet-agent-kind) and
#     captures the session id from kimi's snake_case stdin JSON
#   - persist-save records the kind; persist-restore relaunches the pane with
#     `kimi --session <id>` (not `claude --resume`)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-kimi:"
FAKEHOME="$(mktemp -d)"
mkdir -p "$FAKEHOME/.kimi"
printf '[provider]\nname = "moonshot"' > "$FAKEHOME/.kimi/config.toml"   # no trailing newline on purpose
CONF="$FAKEHOME/.kimi/config.toml"

af() { HOME="$FAKEHOME" "$REPO/bin/agent-fleet" "$@"; }

check "status before install: not installed" "[[ \"\$(af kimi-hooks status)\" == 'not installed' ]]"
af kimi-hooks install >/dev/null
check "install: block present" "grep -qxF '# >>> agent-fleet hooks >>>' '$CONF'"
check "install: user config preserved" "grep -q 'name = \"moonshot\"' '$CONF'"
check "install: five hook entries" "[[ \"\$(grep -c '^\[\[hooks\]\]' '$CONF')\" == '5' ]]"
check "install: PermissionRequest -> wait" "grep -q 'PermissionRequest' '$CONF' && grep -A1 'PermissionRequest' '$CONF' | grep -q 'wait'"
af kimi-hooks install >/dev/null
check "reinstall: still exactly one block" "[[ \"\$(grep -cxF '# >>> agent-fleet hooks >>>' '$CONF')\" == '1' ]]"
check "status after install: installed" "[[ \"\$(af kimi-hooks status)\" == installed* ]]"
af kimi-hooks remove >/dev/null
check "remove: block gone" "! grep -qxF '# >>> agent-fleet hooks >>>' '$CONF'"
check "remove: user config preserved" "grep -q 'name = \"moonshot\"' '$CONF'"
rm -f "$CONF"
check "install without config errors" "! af kimi-hooks install 2>/dev/null"

# --- hook kind-tagging + save/restore round trip -----------------------------
CACHE="$XDG_CACHE_HOME/agent-fleet"
UUID="12121212-3434-5656-7878-909090909090"
mkdir -p "$WORK/k"

boot_server __boot__ "$WORK"
tx new-session -d -s kwork -n kwork -c "$WORK/k"
sleep 0.6
wp="$(tx list-panes -t kwork -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"

# Simulate kimi's UserPromptSubmit hook firing in that pane (snake_case JSON).
printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s"}' "$UUID" "$WORK/k" \
  | TMUX_PANE="$wp" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" working "$SOCK" kimi
check "hook writes working state" "grep -qx working '$CACHE/panes/$wp.status'"
check "hook captures kimi session id" "grep -qx '$UUID' '$CACHE/panes/$wp.session'"
check "hook tags @fleet-agent-kind kimi" "[[ \"\$(tx display-message -p -t $wp '#{@fleet-agent-kind}')\" == 'kimi' ]]"

tx kill-session -t __boot__ 2>/dev/null; sleep 0.3
"$REPO/scripts/persist-save.sh"
check "save records kind kimi" "grep -q \"kimi\" '$CACHE/fleet.state'"
check "save records the session id" "grep -q '$UUID' '$CACHE/fleet.state'"

tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
sleep 0.6
starts="$(tx list-panes -t kwork -F '#{pane_start_command}')"
check "restore relaunches kimi --session" "grep -q 'kimi --session $UUID' <<<\"\$starts\""
check "restore does NOT use claude --resume for kimi" "! grep -q 'claude --resume $UUID' <<<\"\$starts\""
rp="$(tx list-panes -t kwork -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
check "restored pane re-tagged kimi" "[[ \"\$(tx display-message -p -t $rp '#{@fleet-agent-kind}')\" == 'kimi' ]]"

rm -rf "$FAKEHOME"
exit $FAIL
