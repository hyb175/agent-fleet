#!/usr/bin/env bash
# t-pick-go.sh — the Go picker and move popup, driven through tmux.
#   - ui-launch.sh execs afui for every surface and reports a missing binary
#   - fleet view: typing filters, Enter jumps (agent-fleet goto) to the agent
#   - connect view: a project-root child that zoxide never saw is listed;
#     Enter connects a workspace there
#   - move: Enter moves the tab into the chosen workspace and follows it
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-pick-go:"
[[ -x "$REPO/bin/afui" ]] || { echo "  SKIP: bin/afui not built (make ui)"; exit 0; }
boot_server t "$WORK"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"

# Launcher routing: shadow exec so the script prints its choice instead of
# running it (functions win over the exec builtin in non-POSIX bash).
# shellcheck disable=SC2329 # called inside the eval'd check() conditions
route() {  # <surface…> -> what ui-launch.sh would exec (ROUTE_ROOT overrides the root)
  AGENT_FLEET_ROOT="${ROUTE_ROOT:-$REPO}" bash -c \
    'exec() { echo "exec $*"; exit 0; }; source "$REPO/scripts/ui-launch.sh" "$@"' _ "$@" 2>&1 </dev/null || true
}
export REPO
check "launcher: pick execs afui pick"            "route pick spaces | grep -q 'afui pick spaces'"
check "launcher: move execs afui move"            "route move | grep -q 'afui move'"
check "launcher: inbox execs afui inbox"          "route inbox | grep -q 'afui inbox'"
check "launcher: unknown surface is refused"      "! route rail-x 2>/dev/null | grep -q exec"
check "launcher: a missing binary is reported, nothing execs" "ROUTE_ROOT='$WORK' route pick | grep -q 'bin/afui is missing' && ! ROUTE_ROOT='$WORK' route pick | grep -q exec"
check "launcher: AGENT_FLEET_UI=bash gets a note and afui anyway" "AGENT_FLEET_UI=bash route pick | grep -q 'bash renderers were removed' && AGENT_FLEET_UI=bash route pick | grep -q 'afui pick'"

# An agent in a second window to jump to.
w2="$(tx new-window -d -P -F '#{window_id}' -t t: -n target 'sleep 60')"
tgt="$(tx list-panes -t "$w2" -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2!="1"{print $1; exit}')"
tx set-option -p -t "$tgt" @fleet-agent-kind claude
mkdir -p "$CACHE/panes" "$CACHE/tasks"
printf 'id tpick\nintent zebra quest\npane %s\nisolation host\n' "$tgt" > "$CACHE/tasks/tpick"
printf 'tpick\n' > "$CACHE/panes/$tgt.task"
printf 'wait\n' > "$CACHE/panes/$tgt.status"
wait_for 10 "grep -q '|$tgt|' '$CACHE/fleet.snapshot' 2>/dev/null"

# The picker runs in its own pane (a popup needs an attached client; a pane
# gives the same tty semantics for keys).
pp="$(tx new-window -d -P -F '#{pane_id}' -t t: -n picker \
  "env AGENT_FLEET_ROOT='$REPO' AGENT_FLEET_SOCKET='$SOCK' XDG_CACHE_HOME='$XDG_CACHE_HOME' '$REPO/bin/afui' pick")"
wait_for 10 "tx capture-pane -p -t '$pp' | grep -q 'zebra quest'"
check "fleet view lists the agent by intent" "tx capture-pane -p -t '$pp' | grep -q 'zebra quest'"
wait_for 5 "tx capture-pane -p -t '$pp' | grep -q 'NEEDS YOU'"
check "row sits under the NEEDS YOU header with its workspace:index" "tx capture-pane -p -t '$pp' | grep -q 'NEEDS YOU' && tx capture-pane -p -t '$pp' | grep -q 'zebra quest.*t:[0-9]'"
tx send-keys -t "$pp" zbq   # fuzzy: z…b…q
wait_for 5 "tx capture-pane -p -t '$pp' | grep -q '1 of '"
check "fuzzy filter narrows to one row" "tx capture-pane -p -t '$pp' | grep -Eq '1 of [0-9]+'"
tx send-keys -t "$pp" Enter
wait_for 10 "[[ \"\$(tx display-message -p -t t '#{pane_id}')\" == '$tgt' ]]"
check "Enter jumps to the agent pane" "[[ \"\$(tx display-message -p -t t '#{pane_id}')\" == '$tgt' ]]"
wait_for 5 "! tx list-panes -a -F '#{pane_id}' | grep -qx '$pp'"
if tx list-panes -a -F '#{pane_id}' | grep -qx "$pp"; then
  echo "  [debug] picker pane still open: cmd=$(tx display-message -p -t "$pp" '#{pane_current_command} dead=#{pane_dead}')"
  tx capture-pane -p -t "$pp" | grep -v '^$' | tail -4 | sed 's/^/  [debug] /'
fi
check "picker closed after acting" "! tx list-panes -a -F '#{pane_id}' | grep -qx '$pp'"

# Connect view: discovery through project roots, then connect.
ROOTS="$WORK/projects"; mkdir -p "$ROOTS/fresh-repo/.git" "$ROOTS/plain"
pc="$(tx new-window -d -P -F '#{pane_id}' -t t: -n connect \
  "env AGENT_FLEET_ROOT='$REPO' AGENT_FLEET_SOCKET='$SOCK' XDG_CACHE_HOME='$XDG_CACHE_HOME' AGENT_FLEET_PROJECT_ROOTS='$ROOTS' '$REPO/bin/afui' pick connect")"
# Real zoxide history may push the root's children below the fold; filter first.
wait_for 10 "tx capture-pane -p -t '$pc' | grep -q 'CURRENT'"
tx send-keys -t "$pc" fresh-repo
wait_for 10 "tx capture-pane -p -t '$pc' | grep -q '▎ ◆  fresh-repo'"
check "connect lists a root child zoxide never saw" "tx capture-pane -p -t '$pc' | grep -q 'fresh-repo'"
check "repo row wears ◆ and ranks first for its own name" "tx capture-pane -p -t '$pc' | grep -q '▎ ◆  fresh-repo'"
tx send-keys -t "$pc" Enter
wait_for 10 "tx has-session -t =fresh-repo 2>/dev/null"
check "Enter connects a workspace for the dir" "tx has-session -t =fresh-repo 2>/dev/null"

# Move: the 'target' window moves into fresh-repo.
pm="$(tx new-window -d -P -F '#{pane_id}' -t t: -n mover \
  "env AGENT_FLEET_ROOT='$REPO' AGENT_FLEET_SOCKET='$SOCK' XDG_CACHE_HOME='$XDG_CACHE_HOME' '$REPO/bin/afui' move '$w2'")"
wait_for 10 "tx capture-pane -p -t '$pm' | grep -q 'fresh-repo'"
check "move view lists the other workspace" "tx capture-pane -p -t '$pm' | grep -q 'fresh-repo'"
check "move view excludes the tab's own workspace" "! tx capture-pane -p -t '$pm' | grep -Eq '^.{0,4}[○·] t '"
tx send-keys -t "$pm" fresh-repo
wait_for 5 "tx capture-pane -p -t '$pm' | grep -q '▎ ○  fresh-repo'"
tx send-keys -t "$pm" Enter
wait_for 10 "[[ \"\$(tx display-message -p -t '$w2' '#{session_name}')\" == fresh-repo ]]"
check "Enter moves the tab into the workspace" "[[ \"\$(tx display-message -p -t '$w2' '#{session_name}')\" == fresh-repo ]]"

exit "$FAIL"
