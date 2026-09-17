#!/usr/bin/env bash
# rail-launch.sh — exec the rail renderer for this pane.
#
# One place for the renderer choice, so sidenav-toggle (Prefix b, the ensure
# hooks, reload) and persist-restore cannot disagree. Precedence:
#   AGENT_FLEET_UI env (one-shot; the tmux server env passes it to panes)
#   $XDG_CONFIG_HOME/agent-fleet/ui file (durable: `go` or `bash`)
#   bash
# `go` needs bin/afui (make ui); without it the bash rail runs and says why
# once on stderr, so a missing binary degrades instead of leaving an empty
# pane.

set -u
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"

ui="${AGENT_FLEET_UI:-}"
if [[ -z "$ui" ]]; then
  f="${XDG_CONFIG_HOME:-$HOME/.config}/agent-fleet/ui"
  if [[ -r "$f" ]]; then read -r ui < "$f" 2>/dev/null || true; fi
fi

if [[ "$ui" == "go" ]]; then
  if [[ -x "$ROOT/bin/afui" ]]; then
    exec "$ROOT/bin/afui" rail
  fi
  echo "agent-fleet: AGENT_FLEET_UI=go but $ROOT/bin/afui is missing (make ui) — bash rail" >&2
fi
exec "$ROOT/scripts/sidenav.sh"
