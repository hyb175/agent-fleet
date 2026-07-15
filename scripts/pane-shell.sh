#!/usr/bin/env bash
# pane-shell.sh — the fleet's default-command: every SHELL pane starts here.
#
# Prepends the repo's shims dir to PATH before exec'ing your login shell, so a
# hand-typed `claude` (or `claude -r` / `-c`) in any fleet pane resolves to the
# shim and picks up the status hooks — hook-tier status, notifications, the
# progress bar, and the session-id capture that lets persist-restore resume
# hand-started agents after a reboot.
#
# Why here and not the tmux environment: tmux special-cases PATH — pane spawns
# take the server process's PATH and ignore set-environment overrides (verified
# empirically; an arbitrary variable propagates, PATH does not).
#
# Explicit-command panes (fleet-launched agents, restored panes, cs-connect)
# never run this. Your shell rc may reorder PATH; the shim survives as long as
# the rc prepends rather than rebuilds. AGENT_FLEET_SHIM=0 opts out.

set -u

ROOT="${AGENT_FLEET_ROOT:-}"
if [[ "${AGENT_FLEET_SHIM:-1}" == "1" && -n "$ROOT" && -d "$ROOT/shims" ]]; then
  case ":$PATH:" in
    *":$ROOT/shims:"*) ;;
    *) export PATH="$ROOT/shims:$PATH" ;;
  esac
fi
exec "${SHELL:-/bin/sh}" -l
