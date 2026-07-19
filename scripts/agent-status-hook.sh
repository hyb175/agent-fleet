#!/usr/bin/env bash
# agent-status-hook.sh <state> [socket] [kind]
#
# Wired into agent CLIs' lifecycle hooks — claude via the per-launch
# `--settings` overlay, kimi via the install-wide `[[hooks]]` block that
# `agent-fleet kimi-hooks` writes. Writes the agent's lifecycle state to a
# per-pane file the picker and sidenav read. Keyed on $TMUX_PANE (stable
# across `renumber-windows on`).
#
#   <state>  one of: working | wait | done
#   [socket] fleet tmux socket (for the notification label lookup)
#   [kind]   agent kind (claude|kimi|…) — tags the pane so hand-started
#            agents get labeled and persist-restore relaunches the right CLI
#
# Both CLIs pass event JSON on stdin with the same snake_case session_id key.
# Always exits 0 (non-blocking) so a status write never interferes with the
# agent.

set -u

state="${1:-}"
socket="${2:-${AGENT_FLEET_SOCKET:-agent-fleet}}"
kind="${3:-}"
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

# Capture the agent's session id once, from the event JSON on stdin, so a
# restored fleet can resume it (`claude --resume <id>` / `kimi --session <id>`).
# Gated on a per-pane file so we only read stdin on the first event (session id
# is stable for the pane's lifetime). Stored as a pane option too, so
# persist-save can read it via a format string.
sf="$cache/${pane}.session"
if [[ ! -f "$sf" ]]; then
  sid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -1)"
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" > "$sf" 2>/dev/null || true
    command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1 && "${TMUX_BIN:-tmux}" -L "$socket" set-option -p -t "$pane" @fleet-session "$sid" 2>/dev/null || true
  fi
  # Tag the pane's agent kind (hand-started agents have none yet) so the rail
  # labels it without ps-scraping and persist-restore relaunches the right CLI.
  if [[ -n "$kind" ]] && command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1; then
    cur_kind="$("${TMUX_BIN:-tmux}" -L "$socket" display-message -p -t "$pane" '#{@fleet-agent-kind}' 2>/dev/null || true)"
    [[ -z "$cur_kind" ]] && "${TMUX_BIN:-tmux}" -L "$socket" set-option -p -t "$pane" @fleet-agent-kind "$kind" 2>/dev/null || true
  fi
fi

# (The terminal progress bar is NOT emitted here: hooks fire only on
# transitions and tmux forwards passthrough only from visible panes, which
# made a hook-driven bar unreliable. snapshotd emits it continuously instead.)

# Edge-triggered macOS notification on entering an attention state.
# On by default; set AGENT_FLEET_NOTIFY=0 to silence.
if [[ "${AGENT_FLEET_NOTIFY:-1}" == "1" && "$state" != "$prev" ]]; then
  case "$state" in
    wait|done)
      label="$pane"
      if command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1; then
        l="$("${TMUX_BIN:-tmux}" -L "$socket" display-message -p -t "$pane" '#S/#W' 2>/dev/null || true)"
        [[ -n "$l" ]] && label="$l"
      fi
      if [[ "$state" == "wait" ]]; then msg="needs your input"; else msg="finished"; fi
      # The label lands inside a double-quoted AppleScript literal: strip the
      # two characters that can break out of it (window names are user-typed).
      label="${label//\\/}"; label="${label//\"/}"
      if command -v osascript >/dev/null 2>&1; then          # macOS
        osascript -e "display notification \"${label} ${msg}\" with title \"agent-fleet\"" >/dev/null 2>&1 || true
      elif command -v notify-send >/dev/null 2>&1; then       # Linux
        notify-send "agent-fleet" "${label} ${msg}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
fi

exit 0
