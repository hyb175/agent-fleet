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

# fresh window -> shell name (poll: pane-shell's rename lands whenever the
# launcher gets scheduled — a fixed nap flaked twice on slow macOS runners)
wid="$(tx new-window -d -P -F '#{window_id}' -t t:)"
want="$(basename "${SHELL:-sh}")"
poll_until 20 "[[ \"\$(tx display-message -p -t '$wid' '#{window_name}')\" == '$want' ]]"
wname="$(tx display-message -p -t "$wid" '#{window_name}')"
check "new window named after the shell (got: $wname)" "[[ '$wname' == '$want' ]]"

# split inside a named window keeps the name
awid="$(tx new-window -d -P -F '#{window_id}' -t t: -n keepme 'sleep 30')"
tx split-window -d -t "$awid"
sleep 1.5   # nothing to poll FOR — the assertion is that the name does NOT change
check "split keeps the window's name" "[[ \"\$(tx display-message -p -t '$awid' '#{window_name}')\" == keepme ]]"

# --- Prefix T / W rename without a page to dismiss -------------------------
# tmux parks a run-shell job's stdout in a view-mode pane, so a rename that
# printed "tab -> 'x'" ended on a page you had to press q to leave. The binds
# drop that stdout. Replay the shipped bind's own run-shell half (the
# command-prompt half needs an attached client; run-shell does not) and assert
# the rename still lands AND the pane stays out of view mode.
bind_run_shell() {  # <key> -> that bind's run-shell command, tmux-unescaped
  local line
  line="$(tx list-keys -T prefix | grep -E "^bind-key +-T prefix $1 +")"
  line="${line#*run-shell \"}"
  line="${line%\" \}}"
  printf '%s\n' "${line//\\\"/\"}"
}
rwid="$(tx new-window -d -P -F '#{window_id}' -t t: -n oldtab 'sleep 30')"
# The rail is a pane too (@fleet-sidenav 1); view mode would land on the work one.
rpane="$(tx list-panes -t "$rwid" -F '#{pane_id} #{@fleet-sidenav}' | awk '$2!="1"{print $1; exit}')"
tx set -g @fleet-prompt newtab
tx run-shell -t "$rpane" "$(bind_run_shell T)"
poll_until 10 "[[ \"\$(tx display-message -p -t '$rwid' '#{window_name}')\" == newtab ]]"
check "Prefix T renames the tab" "[[ \"\$(tx display-message -p -t '$rwid' '#{window_name}')\" == newtab ]]"
check "Prefix T leaves no page to dismiss" "[[ \"\$(tx display-message -p -t '$rpane' '#{pane_in_mode}')\" == 0 ]]"

tx set -g @fleet-prompt renamed-ws
tx run-shell -t "$rpane" "$(bind_run_shell W)"
poll_until 10 "tx has-session -t '=renamed-ws'"
check "Prefix W renames the workspace" "tx has-session -t '=renamed-ws'"
check "Prefix W leaves no page to dismiss" "[[ \"\$(tx display-message -p -t '$rpane' '#{pane_in_mode}')\" == 0 ]]"

exit "$FAIL"
