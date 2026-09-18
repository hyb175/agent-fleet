#!/usr/bin/env bash
# notify.sh <socket> <pane> <message> [intent] — a notification that ROUTES
# attention to the pane that fired it. Two routes (AGENT_FLEET_NOTIFY_VIA):
#   terminal  the attached terminals show it themselves: an OSC 777 / OSC 9
#             notification, DCS-wrapped through tmux (allow-passthrough) to
#             every attached client's active pane. Reaches an ssh client's
#             laptop, needs no helper binary; clicking focuses the terminal.
#   desktop   terminal-notifier (clicking jumps to the pane) / osascript on
#             macOS, notify-send (with a Jump action where supported) on Linux.
#   auto      (default) terminal when a client whose terminal is known to
#             render these is attached, else desktop.
#
# The body leads with the task intent when the pane has one — "what needs me",
# not just which pane. Called by agent-status-hook.sh on state changes and by
# snapshotd for the one-per-episode wait escalation. Always exits 0; a failed
# notification must never bleed into an agent's lifecycle. Hook tier: bash 3.2.

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
  l="$("${TMUX_BIN:-tmux}" -L "$socket" display-message -p -t "$pane" '#S/#W' </dev/null 2>/dev/null || true)"
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
# The body can land inside a double-quoted AppleScript literal or an escape
# sequence: strip the characters that break out of either (intents and window
# names are user-typed).
body="${body//\\/}"; body="${body//\"/}"; body="${body//[[:cntrl:]]/}"

# --- terminal route ---------------------------------------------------------
# One tmux call: each attached client's tty, terminal, and the tty of the pane
# it is looking at. Passthrough only leaves tmux from a visible pane, so the
# sequence goes to that pane's tty, not the notifying pane's.
DCS=$'\033Ptmux;\033'; ST=$'\033\\'   # tmux passthrough wrapper: DCS tmux; <ESC-doubled payload> ST
osc_seq() {  # <termtype> <termname> -> the wrapped notification, or nothing
  case "$(printf '%s %s' "$1" "$2" | tr '[:upper:]' '[:lower:]')" in
    *iterm*)                           printf '%s\033]9;%s\007%s' "$DCS" "agent-fleet: $body" "$ST" ;;
    *ghostty*|*wezterm*|*foot*|*rxvt*) printf '%s\033]777;notify;agent-fleet;%s\007%s' "$DCS" "$body" "$ST" ;;
  esac
}
tty_fire() {  # <tty> <bytes> — never block the hook: a pane whose master is gone hangs open()
  ( printf '%s' "$2" > "$1" ) 2>/dev/null & local w=$!
  ( sleep 2; kill "$w" 2>/dev/null ) >/dev/null 2>&1 &
}
via="${AGENT_FLEET_NOTIFY_VIA:-auto}"
if [[ "$via" != "desktop" ]] && command -v "${TMUX_BIN:-tmux}" >/dev/null 2>&1; then
  sent=""
  while IFS='|' read -r ctermtype ctermname ptty; do
    [[ -n "$ptty" && -w "$ptty" ]] || continue
    case " $sent " in *" $ptty "*) continue ;; esac
    seq="$(osc_seq "$ctermtype" "$ctermname")"
    if [[ -z "$seq" && "$via" == "terminal" ]]; then
      seq="$(printf '%s\033]777;notify;agent-fleet;%s\007%s' "$DCS" "$body" "$ST")"
    fi
    [[ -n "$seq" ]] || continue
    tty_fire "$ptty" "$seq"; sent="$sent $ptty"
  done < <("${TMUX_BIN:-tmux}" -L "$socket" list-clients -F '#{client_termtype}|#{client_termname}|#{pane_tty}' </dev/null 2>/dev/null || true)
  [[ -n "$sent" ]] && exit 0
  [[ "$via" == "terminal" ]] && exit 0   # asked for terminal only; nobody attached to show it
fi

# --- desktop route ----------------------------------------------------------

# %q, not hand-rolled quotes: socket and the checkout path are user-
# controlled, and this string runs under sh (-execute) or eval (action path).
printf -v jump 'env AGENT_FLEET_SOCKET=%q %q goto %q' "$socket" "$AF" "$pane"

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
