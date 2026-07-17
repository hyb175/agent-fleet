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
# never run this. AGENT_FLEET_SHIM=0 opts out.
#
# PATH ordering: a plain pre-exec prepend loses to any login shell that REBUILDS
# PATH from its own config (fish, via fish_user_paths / fish_add_path, is the
# common case — it re-prepends ~/.local/bin ahead of the shim, so the real
# `claude` wins and the hand-typed agent gets no hooks). We handle that per
# shell below: fish re-prepends AFTER its config via --init-command; other
# shells inherit our prepend (which survives as long as their rc prepends).

set -u

ROOT="${AGENT_FLEET_ROOT:-}"
_shell="${SHELL:-/bin/sh}"
_shell_args=(-l)

if [[ "${AGENT_FLEET_SHIM:-1}" == "1" && -n "$ROOT" && -d "$ROOT/shims" ]]; then
  _shim="$ROOT/shims"
  case "${_shell##*/}" in
    fish)
      # --init-command runs after config is read, so this re-prepend wins over
      # the config's PATH rebuild. Session-local (`set -gx`, NOT the persisted
      # fish_add_path), so nothing leaks into the user's fish config.
      _shell_args=(-l -C "set -gx PATH '$_shim' \$PATH")
      ;;
    *)
      case ":$PATH:" in
        *":$_shim:"*) ;;
        *) export PATH="$_shim:$PATH" ;;
      esac
      ;;
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
    "$_tx" -L "$_sock" rename-window -t "$TMUX_PANE" "$(basename "$_shell")" 2>/dev/null || true
  fi
fi

exec "$_shell" "${_shell_args[@]}"
