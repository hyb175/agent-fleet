#!/usr/bin/env bash
# t-codex.sh — codex hook-tier support.
#   - `agent-fleet codex-hooks` installs a fenced [[hooks.<Event>]] block in
#     ~/.codex/config.toml idempotently, preserves the user's config, and
#     removes cleanly
#   - the status hook tags the pane kind codex and captures the session id
#   - persist-restore relaunches the pane with `codex resume <id>`
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-codex:"
FAKEHOME="$(mktemp -d)"
mkdir -p "$FAKEHOME/.codex"
printf 'model = "gpt-5.2-codex"' > "$FAKEHOME/.codex/config.toml"   # no trailing newline on purpose
CONF="$FAKEHOME/.codex/config.toml"

af() { HOME="$FAKEHOME" "$REPO/bin/agent-fleet" "$@"; }

check "status before install: not installed" "[[ \"\$(af codex-hooks status)\" == 'not installed' ]]"
af codex-hooks install >/dev/null
check "install: block present" "grep -qxF '# >>> agent-fleet hooks >>>' '$CONF'"
check "install: user config preserved" "grep -q 'gpt-5.2-codex' '$CONF'"
check "install: five event groups" "[[ \"\$(grep -c '^\[\[hooks\.[A-Za-z]*\]\]$' '$CONF')\" == '5' ]]"
check "install: nested handler tables" "[[ \"\$(grep -c '^\[\[hooks\.[A-Za-z]*\.hooks\]\]$' '$CONF')\" == '5' ]]"
check "install: PermissionRequest -> wait" "grep -A3 'hooks.PermissionRequest.hooks' '$CONF' | grep -q 'wait'"
check "install: codex kind in commands" "grep -q \"codex\\\"\" '$CONF'"
af codex-hooks install >/dev/null
check "reinstall: still exactly one block" "[[ \"\$(grep -cxF '# >>> agent-fleet hooks >>>' '$CONF')\" == '1' ]]"
af codex-hooks remove >/dev/null
check "remove: block gone" "! grep -qxF '# >>> agent-fleet hooks >>>' '$CONF'"
check "remove: user config preserved" "grep -q 'gpt-5.2-codex' '$CONF'"
rm -f "$CONF"
check "install without config errors" "! af codex-hooks install 2>/dev/null"

# --- hook kind-tagging + save/restore round trip -----------------------------
CACHE="$XDG_CACHE_HOME/agent-fleet"
UUID="abababab-cdcd-efef-1212-343434343434"
mkdir -p "$WORK/x"

boot_server __boot__ "$WORK"
tx new-session -d -s xwork -n xwork -c "$WORK/x"
sleep 0.6
wp="$(tx list-panes -t xwork -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"

# Simulate codex's UserPromptSubmit hook firing in that pane (snake_case JSON).
printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s"}' "$UUID" "$WORK/x" \
  | TMUX_PANE="$wp" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" working "$SOCK" codex
check "hook captures codex session id" "grep -qx '$UUID' '$CACHE/panes/$wp.session'"
check "hook tags @fleet-agent-kind codex" "[[ \"\$(tx display-message -p -t $wp '#{@fleet-agent-kind}')\" == 'codex' ]]"

tx kill-session -t __boot__ 2>/dev/null; sleep 0.3
"$REPO/scripts/persist-save.sh"
check "save records kind codex" "grep -q 'codex' '$CACHE/fleet.state'"

tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
sleep 0.6
# shellcheck disable=SC2034 # read inside the eval'd check() conditions below
starts="$(tx list-panes -t xwork -F '#{pane_start_command}')"
check "restore relaunches codex resume" "grep -q 'codex resume $UUID' <<<\"\$starts\""
check "restore does NOT use claude --resume for codex" "! grep -q 'claude --resume $UUID' <<<\"\$starts\""

rm -rf "$FAKEHOME"
exit "$FAIL"
