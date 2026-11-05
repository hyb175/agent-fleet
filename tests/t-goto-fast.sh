#!/usr/bin/env bash
# t-goto-fast.sh — goto forks status.sh only when the agent is done.
#   - non-done hooked agents: no status.sh in the bash -x trace, file untouched
#   - done: cleared synchronously to idle
#   - scraped (no status file): ack runs in the background, so a slow
#     capture-pane does not hold the switch
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-goto-fast:"

boot_server t
C="$XDG_CACHE_HOME/agent-fleet/$SOCK/panes"; mkdir -p "$C"
# TMUX at the test server so go_to_session takes the headless branch, not exec attach.
TMUX="$(tx display-message -p '#{socket_path}'),0,0"; export TMUX

mkpane() { tx new-window -d -P -F '#{pane_id}' -t t: "$@"; }
go() { bash -x "$REPO/bin/agent-fleet" goto "$1" 2>&1; }

for s in working wait idle; do
  p="$(mkpane sleep 300)"; printf '%s\n' "$s" > "$C/$p.status"
  out="$(go "$p")"
  check "$s: no status.sh in the trace" "[[ \"\$out\" != *status.sh* ]]"
  check "$s: file unchanged" "[[ \"\$(cat '$C/$p.status')\" == '$s' ]]"
  check "$s: pane is active in the active window" "[[ \"\$(tx display-message -p -t '$p' '#{pane_active}#{window_active}')\" == 11 ]]"
done

p="$(mkpane sleep 300)"; printf 'done' > "$C/$p.status"   # no trailing newline: the read || true guard
mkdir -p "$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks"
rec="$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks/T1"; printf 'state working 1\nstate done 2\n' > "$rec"; printf 'T1\n' > "$C/$p.task"
# shellcheck disable=SC2034 # read inside the eval'd check() conditions
out="$(go "$p")"
check "done: status.sh clear-done ran" "[[ \"\$out\" == *'status.sh clear-done'* ]]"
check "done: file reads idle" "[[ \"\$(cat '$C/$p.status')\" == idle ]]"
check "done: record gained exactly one state idle line" "[[ \"\$(grep -c '^state idle ' '$rec')\" == 1 && \"\$(tail -1 '$rec')\" == 'state idle '* ]]"

# Scraped pane: finished-turn summary on screen, no status file, slow capture-pane.
stub="$(mktemp -d)"
printf '#!/usr/bin/env bash\n[[ " $* " == *" capture-pane "* ]] && sleep 2\nexec tmux "$@"\n' > "$stub/tmux"; chmod +x "$stub/tmux"
mkdir -p "$stub/bin"; printf '#!/bin/sh\nsleep 300\n' > "$stub/bin/claude"; chmod +x "$stub/bin/claude"
# Blank rows first: the scrape reads the last 12 lines, so the text must sit at the bottom.
p="$(mkpane "yes '' | head -40; echo 'Worked for 3s'; echo 'new task?'; exec $stub/bin/claude")"
poll_until 5 "tx capture-pane -t $p -p | grep -q 'new task'"
t0="${EPOCHREALTIME/./}"
TMUX_BIN="$stub/tmux" bash "$REPO/bin/agent-fleet" goto "$p" 2>&1 | cat >/dev/null
ms=$(( (${EPOCHREALTIME/./} - t0) / 1000 ))
check "scraped goto returns in under 1 s despite the 2 s capture-pane (${ms} ms)" "(( ms < 1000 ))"
check "scraped: pane is active in the active window" "[[ \"\$(tx display-message -p -t '$p' '#{pane_active}#{window_active}')\" == 11 ]]"
poll_until 8 "[[ -e '$C/$p.ackdone' ]]"
check "scraped: ackdone appears once settled" "[[ -e '$C/$p.ackdone' ]]"
rm -rf "$stub"

exit "$FAIL"
