#!/usr/bin/env bash
# pick.sh — the fleet's single fzf picker.
#
# Views (Tab cycles; ^a/^p/^z jump directly):
#   agents   (default) live Claude agents (per-pane), status glyph + "· claude".
#            Enter focuses that agent pane.
#   spaces   workspaces (sessions): rollup glyph + git branch. Enter switches.
#   connect  zoxide dirs. Enter spawns/attaches a workspace there.

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
AF="$ROOT/bin/agent-fleet"

# shellcheck source=status.sh
source "$ROOT/scripts/status.sh"

tx() { tmux -L "$SOCKET" "$@"; }

if ! command -v fzf >/dev/null 2>&1; then
  echo "agent-fleet picker requires 'fzf' on PATH" >&2
  read -r -p "press enter to close…" _ || true
  exit 1
fi

# Row format: <KEY>\t<DISPLAY...>   (KEY hidden from fzf via --with-nth=2..)

# The fleet: every jump target. Reads the snapshot the daemon writes (one tmux
# poll for the whole fleet) — agents (one row per agent PANE, showing the tab
# name so same-workspace agents differ) then agentless workspaces.
list_fleet() {
  local snap="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/fleet.snapshot"
  [[ -f "$snap" ]] || { printf 'NONE\t\033[2m(fleet starting…)\033[0m\n'; return; }
  local now; printf -v now '%(%s)T' -1
  local frame=$(( now % 10 ))
  local G_wait G_work G_done G_idle G_none spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  printf -v G_wait '\033[38;2;247;118;142m●\033[0m'
  printf -v G_done '\033[38;2;158;206;106m●\033[0m'
  printf -v G_idle '\033[38;2;86;95;137m○\033[0m'
  printf -v G_none '\033[38;2;86;95;137m·\033[0m'
  printf -v G_work '\033[38;2;224;175;104m%s\033[0m' "${spin[frame % 10]}"

  local line typ s wid widx wn pane label st roll br glyph agents="" spaces=""
  while IFS= read -r line; do
    case "$line" in
      A\ *)
        IFS='|' read -r s wid widx wn pane label st <<<"${line#A }"
        case "$st" in wait) glyph=$G_wait;; working) glyph=$G_work;; done) glyph=$G_done;; idle) glyph=$G_idle;; *) glyph=$G_none;; esac
        printf -v line 'PANE:%s\t%s \033[1m%-16s\033[0m \033[2m%s:%s · %s\033[0m' "$pane" "$glyph" "$wn" "$s" "$widx" "$st"
        agents+="$line"$'\n'
        ;;
      S\ *)
        IFS='|' read -r s roll br <<<"${line#S }"
        [[ "$roll" == "none" ]] || continue   # has agents → its A rows cover it
        [[ ${#br} -gt 40 ]] && br="…${br: -39}"
        printf -v line 'SESS:%s\t%s \033[1m%-16s\033[0m \033[2m%s\033[0m' "$s" "$G_idle" "$s" "$br"
        spaces+="$line"$'\n'
        ;;
    esac
  done < "$snap"
  printf '%s%s' "$agents" "$spaces"
}

list_connect() {
  if command -v zoxide >/dev/null 2>&1; then
    zoxide query -l 2>/dev/null | while read -r dir; do
      [[ -z "$dir" ]] && continue
      printf 'CONNECT:%s\t\033[32m+\033[0m \033[1m%-22s\033[0m \033[2m%s\033[0m\n' \
        "$dir" "${dir##*/}" "$dir"
    done
  fi
  printf 'CONNECT:%s\t\033[32m+\033[0m \033[1m%-22s\033[0m \033[2m%s (cwd)\033[0m\n' \
    "$PWD" "${PWD##*/}" "$PWD"
}

run_view() {
  local view="$1" entries header prompt
  case "$view" in
    fleet)
      entries="$(list_fleet)"
      [[ -z "$entries" ]] && entries=$'NONE\t\033[2m(no workspaces — Tab to connect a repo)\033[0m'
      header='[fleet] connect  ·  Tab  ·  ⏎ jump  ·  / filter'
      prompt='› '
      ;;
    connect)
      entries="$(list_connect)"
      header='fleet [connect]  ·  Tab  ·  ⏎ spawn  ·  / filter'
      prompt='⌕ '
      ;;
  esac

  printf '%s\n' "$entries" | fzf \
    --ansi --no-sort --reverse --cycle --no-scrollbar \
    --delimiter=$'\t' --with-nth=2.. \
    --header="$header" --prompt="$prompt" \
    --bind="tab:become(echo VIEW:next)" \
    --bind="ctrl-a:become(echo VIEW:fleet)" \
    --bind="ctrl-z:become(echo VIEW:connect)" \
    --color="fg+:green,bg+:-1"
}

next_view() {
  [[ "$1" == "fleet" ]] && echo connect || echo fleet
}

main() {
  local view="fleet" selection key
  gc   # prune status files for dead panes, once per popup open
  while true; do
    selection="$(run_view "$view")" || exit 0
    [[ -z "$selection" ]] && exit 0
    key="$(echo "$selection" | cut -f1)"
    case "$key" in
      VIEW:fleet)   view="fleet";   continue ;;
      VIEW:connect) view="connect"; continue ;;
      VIEW:next)    view="$(next_view "$view")"; continue ;;
      NONE)         continue ;;
      PANE:*)       "$AF" goto "${key#PANE:}"; exit 0 ;;
      SESS:*)       "$AF" connect "${key#SESS:}"; exit 0 ;;
      CONNECT:*)    "$AF" connect "${key#CONNECT:}"; exit 0 ;;
    esac
  done
}

# Only run the picker when executed directly (so it can be sourced for tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
