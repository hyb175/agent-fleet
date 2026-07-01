#!/usr/bin/env bash
# agent-status-hook.sh <state> [socket]
#
# Wired into fleet-launched Claude agents via `claude --settings`. Writes the
# agent's lifecycle state to a per-pane file the picker and sidenav read.
# Keyed on $TMUX_PANE (stable across `renumber-windows on`).
#
#   <state>  one of: working | wait | done
#   [socket] fleet tmux socket (for the notification label lookup)
#
# Claude passes event JSON on stdin; we don't need it. Always exits 0
# (non-blocking) so a status write never interferes with the agent.

set -u

state="${1:-}"
socket="${2:-${AGENT_FLEET_SOCKET:-agent-fleet}}"
pane="${TMUX_PANE:-}"

# Nothing to do if we don't know the state or which pane we're in.
[[ -z "$state" || -z "$pane" ]] && exit 0

cache="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/panes"
mkdir -p "$cache" 2>/dev/null || exit 0
f="$cache/${pane}.status"

prev=""
[[ -f "$f" ]] && prev="$(cat "$f" 2>/dev/null || true)"
# Trailing newline matters: status.sh reads this with `read`, which returns
# nonzero at EOF-without-newline even after assigning the value.
printf '%s\n' "$state" > "$f"

# Capture Claude's session id once, from the event JSON on stdin, so a restored
# fleet can `claude --resume <id>`. Gated on a per-pane file so we only read stdin
# on the first event (session id is stable for the pane's lifetime). Stored as a
# pane option too, so persist-save can read it via a format string.
sf="$cache/${pane}.session"
if [[ ! -f "$sf" ]]; then
  sid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -1)"
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" > "$sf" 2>/dev/null || true
    command -v tmux >/dev/null 2>&1 && tmux -L "$socket" set-option -p -t "$pane" @fleet-session "$sid" 2>/dev/null || true
  fi
fi

# Edge-triggered macOS notification on entering an attention state.
# On by default; set AGENT_FLEET_NOTIFY=0 to silence.
if [[ "${AGENT_FLEET_NOTIFY:-1}" == "1" && "$state" != "$prev" ]]; then
  case "$state" in
    wait|done)
      label="$pane"
      if command -v tmux >/dev/null 2>&1; then
        l="$(tmux -L "$socket" display-message -p -t "$pane" '#S/#W' 2>/dev/null || true)"
        [[ -n "$l" ]] && label="$l"
      fi
      if [[ "$state" == "wait" ]]; then msg="needs your input"; else msg="finished"; fi
      if command -v osascript >/dev/null 2>&1; then          # macOS
        osascript -e "display notification \"${label} ${msg}\" with title \"agent-fleet\"" >/dev/null 2>&1 || true
      elif command -v notify-send >/dev/null 2>&1; then       # Linux
        notify-send "agent-fleet" "${label} ${msg}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
fi

exit 0
