#!/usr/bin/env bash
# inbox.sh — the fleet's attention queue (Prefix i).
#
# One popup listing every agent that needs you — wait first, then done, the
# longest-suffering first within each — with the context to act without
# attaching: a waiting agent previews its pane tail (the actual question), a
# finished one previews its task worktree's diffstat. Enter attaches (goto).
# Rows come from fleet.snapshot (no tmux polling on open); previews touch
# tmux/git only for the row under the cursor.
#
# Modes (fzf re-invokes this script):
#   (none)            open the popup
#   --rows            print the row list (also fzf's reload source)
#   --preview <key>   print the context panel for one row

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
AF="$ROOT/bin/agent-fleet"

# shellcheck source=status.sh
source "$ROOT/scripts/status.sh"   # theme (T_*/AF_THEME_*), fmt_age, cache paths

tx() { "${TMUX_BIN:-tmux}" -L "$SOCKET" "$@"; }

SNAP="$AF_CACHE_DIR/fleet.snapshot"

# Row key: PANE:<pane>|<state>. '|' is safe — pane ids and states never carry it.
rows() {
  [[ -f "$SNAP" ]] || { printf 'NONE\t\033[2m(fleet starting…)\033[0m\n'; return; }
  local line s wn pane st age intent glyph sub out="" asort
  while IFS= read -r line; do
    [[ "$line" == A\ * ]] || continue
    IFS='|' read -r s _ _ wn pane _ st _ age intent <<<"${line#A }"
    case "$st" in wait|done) ;; *) continue ;; esac
    glyph="$(state_glyph "$st")"
    if [[ -n "$intent" && "$intent" != "-" ]]; then wn="$intent"; fi
    (( ${#wn} > 40 )) && wn="${wn:0:39}…"
    sub="$st"; asort=0
    if [[ "$age" =~ ^[0-9]+$ ]]; then
      fmt_age "$age"; sub="$st $AGE"; asort="$age"
    fi
    printf -v line 'PANE:%s|%s\t%s \033[1m%-40s\033[0m \033[2m%s · %s\033[0m' \
      "$pane" "$st" "$glyph" "$wn" "$s" "$sub"
    out+="$(state_rank "$st")"$'\t'"$asort"$'\t'"$line"$'\n'
  done < "$SNAP"
  if [[ -n "$out" ]]; then
    printf '%s' "$out" | sort -t$'\t' -k1,1n -k2,2nr | cut -f3-
  else
    printf 'NONE\t\033[2minbox zero — nothing needs you\033[0m\n'
  fi
}

preview() {  # <key: PANE:<pane>|<state>>
  local key="${1#PANE:}" pane state
  pane="${key%%|*}"; state="${key##*|}"
  [[ "$key" == "$1" ]] && { echo "(no context)"; return 0; }
  # Federated rows carry a host-qualified pane id — the PTY lives elsewhere.
  if [[ "$pane" == */* ]]; then
    echo "(remote agent on ${pane%%/*} — press Enter to hop over for context)"
    return 0
  fi
  if [[ "$state" == "done" ]]; then
    # A finished task with a worktree: the diffstat IS the review context.
    local tid="" wt=""
    tid="$(cat "$AF_CACHE_DIR/panes/$pane.task" 2>/dev/null || true)"
    if [[ -n "$tid" && -f "$AF_CACHE_DIR/tasks/$tid" ]]; then
      wt="$(awk '$1=="worktree"{print $2; exit}' "$AF_CACHE_DIR/tasks/$tid" 2>/dev/null || true)"
    fi
    if [[ -n "$wt" && -d "$wt" ]]; then
      printf '\033[1mdiff vs %s\033[0m\n' "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo '?')"
      git -C "$wt" diff --stat HEAD 2>/dev/null | tail -20
      local unc; unc="$(git -C "$wt" status --porcelain 2>/dev/null | head -5)"
      if [[ -n "$unc" ]]; then printf '\033[2muncommitted:\033[0m\n%s\n' "$unc"; fi
      return 0
    fi
  fi
  # wait (and worktree-less done): the pane tail is the question being asked.
  tx capture-pane -p -t "$pane" 2>/dev/null | sed -e 's/[[:space:]]*$//' \
    | awk 'NF{blank=0} !NF{blank++} blank<2' | tail -18 \
    || echo "(pane gone — reopen the inbox)"
}

case "${1:-}" in
  --rows)    rows; exit 0 ;;
  --preview) preview "${2:-}"; exit 0 ;;
esac

if ! command -v fzf >/dev/null 2>&1; then
  echo "agent-fleet inbox requires 'fzf' on PATH" >&2
  read -r -p "press enter to close…" _ || true
  exit 1
fi

sel="$(rows | fzf \
  --ansi --no-sort --reverse --cycle --no-scrollbar \
  --delimiter=$'\t' --with-nth=2.. \
  --header='inbox · ⏎ attach · ^r refresh' \
  --prompt='◆ ' \
  --preview="'$0' --preview {1}" \
  --preview-window=down,55%,border-top \
  --bind="ctrl-r:reload('$0' --rows)" \
  --color="bg+:$AF_THEME_HL,fg+:$AF_THEME_FG,hl:$AF_THEME_ACCENT,hl+:$AF_THEME_ACCENT,pointer:$AF_THEME_ACCENT,prompt:$AF_THEME_ACCENT,info:$AF_THEME_MUTED,header:$AF_THEME_MUTED,border:$AF_THEME_MUTED,gutter:-1")" \
  || exit 0
[[ -z "$sel" ]] && exit 0
key="$(cut -f1 <<<"$sel")"
case "$key" in
  PANE:*) target="${key#PANE:}"; "$AF" goto "${target%%|*}" ;;
esac
