#!/usr/bin/env bash
# pick.sh — the fleet's single fzf picker.
#
# Views (Tab cycles; ^a/^s/^z jump directly):
#   fleet    (default) live agents (per-pane) + agentless workspaces. ⏎ jumps.
#   spaces   EVERY workspace (session): state glyph + branch + agent count.
#            ⏎ switches. The quick workspace switch (Prefix w opens here).
#   connect  zoxide dirs. ⏎ spawns/attaches a workspace there.

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

SNAP="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/fleet.snapshot"

# State glyphs, prepared once per popup (the picker is a one-shot render, so the
# spinner frame is fixed at open time). Shared by every view.
prep_glyphs() {
  local now; printf -v now '%(%s)T' -1
  local frame=$(( now % 10 )) spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  printf -v G_wait '\033[38;2;247;118;142m●\033[0m'
  printf -v G_done '\033[38;2;158;206;106m●\033[0m'
  printf -v G_idle '\033[38;2;86;95;137m○\033[0m'
  printf -v G_none '\033[38;2;86;95;137m·\033[0m'
  printf -v G_work '\033[38;2;224;175;104m%s\033[0m' "${spin[frame % 10]}"
}
glyph_of() { case "$1" in
  wait) printf '%s' "$G_wait";; working) printf '%s' "$G_work";;
  done) printf '%s' "$G_done";; idle) printf '%s' "$G_idle";; *) printf '%s' "$G_none";;
esac; }

# The fleet: every jump target — agents (one row per agent PANE, showing the tab
# name so same-workspace agents differ) then agentless workspaces.
list_fleet() {
  [[ -f "$SNAP" ]] || { printf 'NONE\t\033[2m(fleet starting…)\033[0m\n'; return; }
  local line s wid widx wn pane label st roll br glyph agents="" spaces=""
  while IFS= read -r line; do
    case "$line" in
      A\ *)
        IFS='|' read -r s wid widx wn pane label st <<<"${line#A }"
        glyph="$(glyph_of "$st")"
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
  done < "$SNAP"
  printf '%s%s' "$agents" "$spaces"
}

# Spaces: EVERY workspace (session), agentful or not — a quick workspace jump
# (Prefix w), the thing the agent list can't give you for shell-only spaces.
# Subtitle = git branch + agent count, or "shell" when it has no agents.
list_spaces() {
  [[ -f "$SNAP" ]] || { printf 'NONE\t\033[2m(fleet starting…)\033[0m\n'; return; }
  local line s wid widx wn pane label st roll br order=""
  declare -A NAG ROLL BR
  while IFS= read -r line; do
    case "$line" in
      A\ *) IFS='|' read -r s wid widx wn pane label st <<<"${line#A }"; NAG[$s]=$(( ${NAG[$s]:-0} + 1 )) ;;
      S\ *) IFS='|' read -r s roll br <<<"${line#S }"; ROLL[$s]="$roll"; BR[$s]="$br"; order+="$s"$'\n' ;;
    esac
  done < "$SNAP"
  local g cnt sub
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    g="$(glyph_of "${ROLL[$s]:-none}")"
    cnt="${NAG[$s]:-0}"
    if (( cnt > 0 )); then sub="${BR[$s]:-} · ${cnt} agent"; (( cnt != 1 )) && sub+="s"
    else sub="${BR[$s]:-} · shell"; fi
    [[ ${#sub} -gt 40 ]] && sub="…${sub: -39}"
    printf 'SESS:%s\t%s \033[1m%-16s\033[0m \033[2m%s\033[0m\n' "$s" "$g" "$s" "$sub"
  done <<<"$order"
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
      header='[fleet] spaces connect  ·  Tab  ·  ⏎ jump  ·  / filter'
      prompt='› '
      ;;
    spaces)
      entries="$(list_spaces)"
      [[ -z "$entries" ]] && entries=$'NONE\t\033[2m(no workspaces — Tab to connect a repo)\033[0m'
      header='fleet [spaces] connect  ·  Tab  ·  ⏎ switch  ·  / filter'
      prompt='⊞ '
      ;;
    connect)
      entries="$(list_connect)"
      header='fleet spaces [connect]  ·  Tab  ·  ⏎ spawn  ·  / filter'
      prompt='⌕ '
      ;;
  esac

  printf '%s\n' "$entries" | fzf \
    --ansi --no-sort --reverse --cycle --no-scrollbar \
    --delimiter=$'\t' --with-nth=2.. \
    --header="$header" --prompt="$prompt" \
    --bind="tab:become(echo VIEW:next)" \
    --bind="ctrl-a:become(echo VIEW:fleet)" \
    --bind="ctrl-s:become(echo VIEW:spaces)" \
    --bind="ctrl-z:become(echo VIEW:connect)" \
    --color="fg+:green,bg+:-1"
}

next_view() {
  case "$1" in fleet) echo spaces ;; spaces) echo connect ;; *) echo fleet ;; esac
}

main() {
  local view="${1:-fleet}" selection key
  prep_glyphs   # state glyphs, once per popup
  gc   # prune status files for dead panes, once per popup open
  while true; do
    selection="$(run_view "$view")" || exit 0
    [[ -z "$selection" ]] && exit 0
    key="$(echo "$selection" | cut -f1)"
    case "$key" in
      VIEW:fleet)   view="fleet";   continue ;;
      VIEW:spaces)  view="spaces";  continue ;;
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
# Optional arg = initial view (fleet|spaces|connect); Prefix w opens 'spaces'.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
