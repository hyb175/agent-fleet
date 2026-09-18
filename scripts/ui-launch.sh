#!/usr/bin/env bash
# ui-launch.sh <rail|pick|inbox|move> [args…] — exec afui for a surface.
#
# The keybinds, the ensure hooks, reload, persist-restore and `agent-fleet
# pick` all come through here, so a missing binary fails the same way
# everywhere: a message where the surface would be, and a rail pane that
# stays put (an exiting rail pane collapses the layout and the ensure hook
# would respawn it in a loop).

set -u
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
surface="${1:?usage: ui-launch.sh <rail|pick|inbox|move> [args]}"; shift
case "$surface" in
  rail|pick|inbox|move) ;;
  *) echo "ui-launch: unknown surface '$surface'" >&2; exit 2 ;;
esac

if [[ -x "$ROOT/bin/afui" ]]; then
  exec "$ROOT/bin/afui" "$surface" "$@"
fi
echo "agent-fleet: $ROOT/bin/afui is missing — no $surface without it" >&2
echo "  build it: make ui (Go 1.24+)   or install a tagged release: agent-fleet upgrade" >&2
if [[ "$surface" == rail ]]; then
  while :; do sleep 3600; done
fi
if [[ -t 0 ]]; then read -r -n1 -p "press any key to close" _; fi
exit 1
