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

# tmux names a fresh window after its initial command — i.e. this script.
# Rename to the shell's name (the pre-launcher behavior), but ONLY when the
# window still carries the launcher's own name: that is exactly the
# new-window case, and never a split inside a named agent window
# (automatic-rename is off, so nothing else will fix it up).
if [[ -n "${TMUX_PANE:-}" ]]; then
  _tx="${TMUX_BIN:-tmux}"; _sock="${AGENT_FLEET_SOCKET:-agent-fleet}"
  if [[ "$("$_tx" -L "$_sock" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)" == "pane-shell.sh" ]]; then
    "$_tx" -L "$_sock" rename-window -t "$TMUX_PANE" "$(basename "${SHELL:-sh}")" 2>/dev/null || true
  fi
fi

exec "${SHELL:-/bin/sh}" -l
