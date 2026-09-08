#!/usr/bin/env bash
# t-adopt.sh — task adoption (#16).
#   - `task adopt %pane "intent"` creates a record for an existing pane
#     (pointer + @fleet-task + intent); refuses a pane that already has one;
#     intent defaults to the window name
#   - hook auto-adopt: a hooked agent event for a recordless pane creates a
#     minimal record (kind from the hook arg, dir from payload cwd, intent
#     from the window name) and the SAME event's transition lands in it
#   - AF_TASK_PRESPAWNED guard: `af task` spawns produce exactly ONE record
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-adopt:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"

FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"

af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }

boot_server __boot__ "$WORK"
check "Prefix ? cheatsheet bound (#18)" "tx list-keys 2>/dev/null | grep -q 'agent-fleet keys'"
mkdir -p "$WORK/a"
tx new-session -d -s aw -n legacy-agent -c "$WORK/a"
sleep 0.5
wp="$(tx list-panes -t aw -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"

# --- explicit adopt ----------------------------------------------------------
out="$(af task adopt "$wp" "old faithful")"
T="${out##*-> }"; T="${T%% *}"
check "adopt prints the task id" "[[ '$T' == t* ]]"
check "record exists with the intent" "grep -qx 'intent old faithful' '$CACHE/tasks/$T'"
check "pointer file armed" "[[ \"\$(cat '$CACHE/panes/$wp.task')\" == '$T' ]]"
check "@fleet-task tagged" "[[ \"\$(tx display-message -p -t $wp '#{@fleet-task}')\" == '$T' ]]"
check "task ls lists it" "af task ls | grep -q 'old faithful'"
check "re-adopt refused" "! af task adopt '$wp' again 2>/dev/null"

# Intent defaults to the window name.
tx new-window -t aw -n named-tab -c "$WORK/a"
sleep 0.3
wp2="$(tx list-panes -t aw:named-tab -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
out="$(af task adopt "$wp2")"
T2="${out##*-> }"; T2="${T2%% *}"
check "intent defaults to window name" "grep -qx 'intent named-tab' '$CACHE/tasks/$T2'"

# Adopted task flows into history once terminal.
af task drop "$T2" >/dev/null
# shellcheck disable=SC2034 # read inside the eval'd check() condition below
hist="$(TZ=UTC af history)"
check "adopted task reaches history" "grep -q 'named-tab' <<<\"\$hist\""

# --- hook auto-adopt ---------------------------------------------------------
tx new-window -t aw -n hand-started -c "$WORK/a"
sleep 0.3
wp3="$(tx list-panes -t aw:hand-started -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"auto-1","cwd":"%s"}' "$WORK/a" \
  | TMUX_PANE="$wp3" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" working "$SOCK" claude
T3="$(cat "$CACHE/panes/$wp3.task" 2>/dev/null || true)"
check "hook auto-adopted the pane" "[[ -n '$T3' && -f '$CACHE/tasks/$T3' ]]"
check "auto record: kind from hook arg" "grep -qx 'kind claude' '$CACHE/tasks/$T3'"
check "auto record: dir from payload cwd" "grep -qx 'dir $WORK/a' '$CACHE/tasks/$T3'"
check "auto record: intent from window name" "grep -qx 'intent hand-started' '$CACHE/tasks/$T3'"
check "the SAME event's transition landed" "grep -q '^state working ' '$CACHE/tasks/$T3'"
check "@fleet-task tagged by the hook" "[[ \"\$(tx display-message -p -t $wp3 '#{@fleet-task}')\" == '$T3' ]]"

# Second event: still one record, no duplicate.
printf '{"hook_event_name":"Stop","session_id":"auto-1"}' \
  | TMUX_PANE="$wp3" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" 'done' "$SOCK" claude
# shellcheck disable=SC2034 # n/np read inside eval'd check() conditions
n="$(grep -lx "pane $wp3" "$CACHE/tasks"/t* 2>/dev/null | wc -l)"
check "second event: still one record" "(( n == 1 ))"

# --- prespawn guard: af task creates exactly one record ----------------------
out="$(af task "spawned task" --repo "$WORK/a")"
TP="${out%% *}"; PP="${out##* }"
sleep 0.5
# Fire a hook event as the spawned agent would — the window env carries
# AF_TASK_PRESPAWNED, which the hook sees via the pane environment. Simulate
# with the var set (tmux -e puts it in the window env for real spawns).
printf '{"hook_event_name":"UserPromptSubmit","session_id":"pre-1","cwd":"%s"}' "$WORK/a" \
  | TMUX_PANE="$PP" AF_TASK_PRESPAWNED=1 AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" working "$SOCK" claude
# shellcheck disable=SC2034
np="$(grep -lx "pane $PP" "$CACHE/tasks"/t* 2>/dev/null | wc -l)"
check "prespawned pane: exactly one record" "(( np == 1 ))"
check "the one record is cmd_add's" "[[ \"\$(cat '$CACHE/panes/$PP.task')\" == '$TP' ]]"

# And tmux -e really delivers the guard into real spawns' environment.
af add probe --to aw --cmd "printenv AF_TASK_PRESPAWNED > $WORK/guard.out; sleep 60" >/dev/null
poll_until 10 "grep -qx 1 '$WORK/guard.out'"
check "window env carries the guard for real spawns" "grep -qx 1 '$WORK/guard.out'"

rm -rf "$FAKEBIN"
exit "$FAIL"
