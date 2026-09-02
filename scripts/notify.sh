#!/usr/bin/env bash
# notify.sh <socket> <pane> <message> [intent] — desktop notification that
# ROUTES attention: clicking it jumps to the pane that fired it, where the
# platform allows (terminal-notifier's -execute on macOS; notify-send's
# action button on Linux daemons that support one). Falls back to a plain
# notification (osascript / actionless notify-send) everywhere else.
#
# The body leads with the task intent when the pane has one — "what needs me",
# not just which pane. Called by agent-status-hook.sh on state changes and by
# snapshotd for the one-per-episode wait escalation. Always exits 0; a failed
# notification must never bleed into an agent's lifecycle.

set -u

socket="${1:-agent-fleet}"
pane="${2:-}"
msg="${3:-}"
intent="${4:-}"

[[ -z "$pane" || -z "$msg" ]] && exit 0
[[ "${AGENT_FLEET_NOTIFY:-1}" == "1" ]] || exit 0

HERE="${BASH_SOURCE[0]%/*}"
AF="$HERE/../bin/agent-fleet"

# Scoped cache for the intent lookup (arg socket, not env — same discipline
# as the status hook).
# shellcheck source=cache.sh
AGENT_FLEET_SOCKET="$socket" source "$HERE/cache.sh" 2>/dev/null || exit 0

label="$pane"
if command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1; then
  l="$("${TMUX_BIN:-tmux}" -L "$socket" display-message -p -t "$pane" '#S/#W' 2>/dev/null || true)"
  [[ -n "$l" ]] && label="$l"
fi

# Intent from the task record when the caller didn't pass one.
if [[ -z "$intent" && -r "$AF_CACHE_DIR/panes/$pane.task" ]]; then
  tid=""
  { read -r tid < "$AF_CACHE_DIR/panes/$pane.task"; } 2>/dev/null || true
  if [[ -n "$tid" && -r "$AF_CACHE_DIR/tasks/$tid" ]]; then
    while IFS= read -r line; do
      case "$line" in "intent "*) intent="${line#intent }"; break ;; esac
    done < "$AF_CACHE_DIR/tasks/$tid"
  fi
fi

body="${intent:+$intent — }$label $msg"
# The body can land inside a double-quoted AppleScript literal: strip the two
# characters that can break out of it (intents and window names are user-typed).
body="${body//\\/}"; body="${body//\"/}"

jump="env AGENT_FLEET_SOCKET='$socket' '$AF' goto '$pane'"

if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "agent-fleet" -message "$body" -execute "$jump" >/dev/null 2>&1 || true
elif command -v osascript >/dev/null 2>&1; then
  # No click action on this route — plain banner.
  osascript -e "display notification \"${body}\" with title \"agent-fleet\"" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  if notify-send --help 2>/dev/null | grep -q -- '--action'; then
    # -A blocks until the notification is acted on or expires, so the whole
    # exchange runs detached; a clicked action prints its name, which is the
    # cue to jump. A server without action support just never prints.
    (
      choice="$(notify-send -A "jump=Jump to agent" "agent-fleet" "$body" 2>/dev/null || true)"
      if [[ -n "$choice" ]]; then eval "$jump" >/dev/null 2>&1 || true; fi
    ) >/dev/null 2>&1 &
  else
    notify-send "agent-fleet" "$body" >/dev/null 2>&1 || true
  fi
fi
exit 0
