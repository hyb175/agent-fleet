#!/usr/bin/env bash
# t-hermes.sh — hermes hook-tier support (#15).
#   - `agent-fleet hermes-hooks` installs DATA-ANCHORED entries in
#     ~/.hermes/config.yaml (no fence — hermes re-serializes its config and
#     strips comments), preserves the user's config, removes cleanly, and
#     refuses to merge into a foreign hooks: section
#   - removal survives a PyYAML rewrite (quoting/indent/order changed)
#   - the status hook tags the pane kind hermes and captures the snake_case
#     session_id from hermes' stdin JSON
#   - persist-restore relaunches `hermes --resume <id>`
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-hermes:"
FAKEHOME="$(mktemp -d)"
mkdir -p "$FAKEHOME/.hermes"
printf 'model: gpt-5.2\nworkspace: hyb\n' > "$FAKEHOME/.hermes/config.yaml"
CONF="$FAKEHOME/.hermes/config.yaml"

af() { HOME="$FAKEHOME" "$REPO/bin/agent-fleet" "$@"; }

check "status before install: not installed" "[[ \"\$(af hermes-hooks status)\" == 'not installed' ]]"
af hermes-hooks install >/dev/null
check "install: hooks section present"  "grep -qx 'hooks:' '$CONF'"
check "install: user config preserved"  "grep -q 'model: gpt-5.2' '$CONF'"
check "install: five events"            "[[ \"\$(grep -c 'agent-status-hook.sh' '$CONF')\" == '5' ]]"
check "install: pre_approval_request -> wait" \
  "grep -A1 'pre_approval_request:' '$CONF' | grep -q 'wait'"
check "install: on_session_end -> done" "grep -A1 'on_session_end:' '$CONF' | grep -q 'done'"
check "install: timeouts bounded"       "grep -q 'timeout: 10' '$CONF'"
af hermes-hooks install >/dev/null
check "reinstall: still five entries"   "[[ \"\$(grep -c 'agent-status-hook.sh' '$CONF')\" == '5' ]]"
check "reinstall: still one hooks: key" "[[ \"\$(grep -cx 'hooks:' '$CONF')\" == '1' ]]"
check "status after install: installed" "[[ \"\$(af hermes-hooks status)\" == installed* ]]"
af hermes-hooks remove >/dev/null
check "remove: entries gone"            "! grep -q 'agent-status-hook.sh' '$CONF'"
check "remove: hooks: key gone"         "! grep -qx 'hooks:' '$CONF'"
check "remove: user config preserved"   "grep -q 'model: gpt-5.2' '$CONF'"

# PyYAML rewrite survival: hermes re-serializes config.yaml (comments gone,
# quoting/order changed, a foreign entry sharing OUR event). Removal must
# strip only fleet entries and keep the rest structurally intact.
cat > "$CONF" <<EOF
model: gpt-5.2
hooks:
  on_session_end:
  - command: $REPO/scripts/agent-status-hook.sh done $SOCK hermes
    timeout: 10
  - command: /home/user/my-own-hook.sh
    timeout: 5
  pre_llm_call:
  - command: $REPO/scripts/agent-status-hook.sh working $SOCK hermes
    timeout: 10
workspace: hyb
EOF
af hermes-hooks remove >/dev/null
check "rewrite: fleet entries stripped"     "! grep -q 'agent-status-hook.sh' '$CONF'"
check "rewrite: user's own hook kept"       "grep -q 'my-own-hook.sh' '$CONF'"
check "rewrite: its event key kept"         "grep -q 'on_session_end:' '$CONF'"
check "rewrite: emptied event key dropped"  "! grep -q 'pre_llm_call:' '$CONF'"
check "rewrite: hooks: kept (still has children)" "grep -qx 'hooks:' '$CONF'"
check "rewrite: trailing user key intact"   "grep -q 'workspace: hyb' '$CONF'"

# A user wrapper that passes our hook as an ARGUMENT is not ours — the
# identity anchors on the command's first token.
cat > "$CONF" <<EOF
hooks:
  on_session_end:
  - command: /home/user/wrap.sh $REPO/scripts/agent-status-hook.sh done x hermes
    timeout: 5
EOF
af hermes-hooks remove >/dev/null 2>&1 || true
check "wrapper mentioning the hook is NOT stripped" "grep -q 'wrap.sh' '$CONF'"

# hooks: {} (PyYAML's dump of an emptied map) is absence, not foreign config.
printf 'model: gpt-5.2\nhooks: {}\n' > "$CONF"
af hermes-hooks install >/dev/null
check "hooks: {} replaced, not refused" "grep -qx 'hooks:' '$CONF' && ! grep -q 'hooks: {}' '$CONF'"

# Foreign hooks: section -> install refuses rather than merging blind.
cat > "$CONF" <<EOF
model: gpt-5.2
hooks:
  pre_llm_call:
  - command: /home/user/my-own-hook.sh
EOF
check "foreign hooks section: install refuses" "! af hermes-hooks install 2>/dev/null"
# shellcheck disable=SC2034 # read inside the eval'd check() condition below
refusal="$(af hermes-hooks install 2>&1 || true)"   # buffered: see the pipefail house rule
check "refusal prints the entries to add"      "grep -q 'pre_approval_request' <<<\"\$refusal\""

rm -f "$CONF"
check "install without config errors" "! af hermes-hooks install 2>/dev/null"

# --- hook kind-tagging + save/restore round trip -----------------------------
FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/hermes"
chmod +x "$FAKEBIN/hermes"
export PATH="$FAKEBIN:$PATH"

CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
SID="20260905_121212_ab12cd"
mkdir -p "$WORK/h"

boot_server __boot__ "$WORK"
tx new-session -d -s hwork -n hwork -c "$WORK/h"
sleep 0.6
wp="$(tx list-panes -t hwork -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"

# Simulate hermes' pre_llm_call hook firing in that pane (snake_case JSON).
printf '{"hook_event_name":"pre_llm_call","session_id":"%s","cwd":"%s"}' "$SID" "$WORK/h" \
  | TMUX_PANE="$wp" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" working "$SOCK" hermes
check "hook writes working state"      "grep -qx working '$CACHE/panes/$wp.status'"
check "hook captures hermes session id" "grep -qx '$SID' '$CACHE/panes/$wp.session'"
check "hook tags @fleet-agent-kind hermes" \
  "[[ \"\$(tx display-message -p -t $wp '#{@fleet-agent-kind}')\" == 'hermes' ]]"

# hermes' pre_approval_request delivers session_key, NOT session_id (source-
# verified quirk) — the hook must still write wait (prev is working) and must
# not capture the key as an id.
rm -f "$CACHE/panes/$wp.session"
printf '{"hook_event_name":"pre_approval_request","session_key":"junk-key-1","cwd":"%s"}' "$WORK/h" \
  | TMUX_PANE="$wp" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" wait "$SOCK" hermes
check "session_key payload: wait still written" "grep -qx wait '$CACHE/panes/$wp.status'"
check "session_key payload: no id captured"     "[[ ! -f '$CACHE/panes/$wp.session' ]]"

tx kill-session -t __boot__ 2>/dev/null; sleep 0.3
"$REPO/scripts/persist-save.sh"
check "save records kind hermes"   "grep -q 'hermes' '$CACHE/fleet.state'"
check "save records the session id" "grep -q '$SID' '$CACHE/fleet.state'"

tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
poll_until 20 "tx list-panes -t hwork -F '#{pane_start_command}' 2>/dev/null | grep -c 'hermes --resume'"
# shellcheck disable=SC2034 # read inside the eval'd check() conditions below
starts="$(tx list-panes -t hwork -F '#{pane_start_command}')"
check "restore relaunches hermes --resume" "grep -q 'hermes --resume $SID' <<<\"\$starts\""
check "restore does NOT use claude for hermes" "! grep -q 'claude' <<<\"\$starts\""

rm -rf "$FAKEHOME" "$FAKEBIN"
exit "$FAIL"
