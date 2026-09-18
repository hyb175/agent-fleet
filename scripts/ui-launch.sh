#!/usr/bin/env bash
# ui-launch.sh <rail|pick|inbox|move> [args…] — exec the renderer for a surface.
#
# One place for the renderer choice, so the keybinds, the ensure hooks,
# reload, persist-restore and `agent-fleet pick` cannot disagree. Precedence:
#   AGENT_FLEET_UI env (one-shot; the tmux server env passes it to panes)
#   $XDG_CONFIG_HOME/agent-fleet/ui file (durable: `go` or `bash`)
#   bash
# `go` needs bin/afui (make ui) AND a surface the binary implements; anything
# else falls back to the bash script with one line on stderr, so a missing
# binary degrades instead of leaving an empty pane or popup.

set -u
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
surface="${1:?usage: ui-launch.sh <rail|pick|inbox|move> [args]}"; shift

ui="${AGENT_FLEET_UI:-}"
if [[ -z "$ui" ]]; then
  f="${XDG_CONFIG_HOME:-$HOME/.config}/agent-fleet/ui"
  if [[ -r "$f" ]]; then read -r ui < "$f" 2>/dev/null || true; fi
fi

# Surfaces the binary has landed; the rest are still bash until their ticket.
go_has() { case "$1" in rail|pick|move) return 0 ;; *) return 1 ;; esac; }

if [[ "$ui" == "go" ]] && go_has "$surface"; then
  if [[ -x "$ROOT/bin/afui" ]]; then
    exec "$ROOT/bin/afui" "$surface" "$@"
  fi
  echo "agent-fleet: AGENT_FLEET_UI=go but $ROOT/bin/afui is missing (make ui) — bash $surface" >&2
fi
case "$surface" in
  rail)  exec "$ROOT/scripts/sidenav.sh" ;;
  pick)  exec "$ROOT/scripts/pick.sh" "$@" ;;
  inbox) exec "$ROOT/scripts/inbox.sh" "$@" ;;
  move)  exec "$ROOT/scripts/move-tab.sh" "$@" ;;
  *)     echo "ui-launch: unknown surface '$surface'" >&2; exit 2 ;;
esac
