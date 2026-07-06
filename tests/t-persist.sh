#!/usr/bin/env bash
# t-persist.sh — layout persistence round-trips exactly.
#   - sessions / window names / exact split rects / work-pane cwds / one rail
#     per window survive save -> kill-server -> restore
#   - a 7-pane 200x50 window keeps every pane (session sized from the layout,
#     splits rebalanced) and the user's @fleet-sidenav-auto opt-out survives
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-persist:"
mkdir -p "$WORK/a" "$WORK/b"

snapshot() {   # window structure fingerprint: rects + work cwds + rail count
  local s w out=""
  while read -r s w; do
    [[ -z "$s" ]] && continue
    out+="$s:$w [$(tx display-message -p -t "$s:$w" '#{window_name}')]"
    out+=" rects={$(tx list-panes -t "$s:$w" -F '#{pane_left},#{pane_top},#{pane_width},#{pane_height}' | sort | tr '\n' ' ')}"
    out+=" work={$(tx list-panes -t "$s:$w" -F '#{?@fleet-sidenav,1,0}|#{pane_current_path}' | awk -F'|' '$1=="0"{print $2}' | sort | tr '\n' ' ')}"
    out+=" rails=$(tx list-panes -t "$s:$w" -F '#{?@fleet-sidenav,1,0}' | grep -c '^1$')"$'\n'
  done < <(tx list-windows -a -F '#{session_name} #{window_index}' 2>/dev/null | grep -v '^__' | sort)
  printf '%s' "$out"
}

# --- part 1: two sessions, one with a split, rails everywhere ---
boot_server __boot__ "$WORK"
tx new-session -d -s alpha -n alpha -c "$WORK/a"
sleep 0.4
tx split-window -h -t alpha -c "$WORK/b"
tx new-session -d -s beta -n b1 -c "$WORK/b"
tx new-window  -d -t beta: -n b2 -c "$WORK/a"
tx kill-session -t __boot__ 2>/dev/null
sleep 1

before="$(snapshot)"
"$REPO/scripts/persist-save.sh"
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"; rc=$?
sleep 1
after="$(snapshot)"
check "restore rc=0" "[[ $rc -eq 0 ]]"
check "layout round-trips byte-identical" "[[ \"\$before\" == \"\$after\" ]]"
[[ "$before" == "$after" ]] || { echo "--- before ---"; echo "$before"; echo "--- after ---"; echo "$after"; }
tx kill-server 2>/dev/null; sleep 0.3
rm -rf "$XDG_CACHE_HOME"; mkdir -p "$XDG_CACHE_HOME"

# --- part 2: big window + auto-rail opt-out (private HOME for local.conf) ---
FAKEHOME="$(mktemp -d)"
mkdir -p "$FAKEHOME/.config/agent-fleet"
printf 'set -g @fleet-sidenav-auto off\n' > "$FAKEHOME/.config/agent-fleet/local.conf"
export HOME="$FAKEHOME"

tmux -L "$SOCK" -f "$REPO/conf/agent-fleet.conf" new-session -d -s big -n big -c "$WORK/a" -x 200 -y 50
tx set-environment -g AGENT_FLEET_ROOT "$REPO"; tx set-environment -g AGENT_FLEET_SOCKET "$SOCK"
check "local.conf honored at boot (auto=off)" "[[ \"\$(tx show-option -gqv @fleet-sidenav-auto)\" == off ]]"
"$REPO/scripts/sidenav-toggle.sh" "$(tx display-message -p -t big '#{window_id}')" "$(tx display-message -p -t big '#{pane_id}')" show
for _ in 1 2 3 4 5; do tx split-window -d -t big -c "$WORK/a"; tx select-layout -t big tiled; done
sleep 0.5
before_n="$(tx list-panes -t big | wc -l | tr -d ' ')"
before_r="$(tx list-panes -t big -F '#{pane_left},#{pane_top},#{pane_width},#{pane_height}' | sort | tr '\n' ' ')"

"$REPO/scripts/persist-save.sh"
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
sleep 0.8
after_n="$(tx list-panes -t big 2>/dev/null | wc -l | tr -d ' ')"
after_r="$(tx list-panes -t big -F '#{pane_left},#{pane_top},#{pane_width},#{pane_height}' 2>/dev/null | sort | tr '\n' ' ')"
check "big window keeps all $before_n panes" "[[ '$before_n' == '$after_n' ]]"
check "big window rects identical" "[[ '$before_r' == '$after_r' ]]"
check "auto-rail opt-out survives restore" "[[ \"\$(tx show-option -gqv @fleet-sidenav-auto)\" == off ]]"
rm -rf "$FAKEHOME"
exit $FAIL
