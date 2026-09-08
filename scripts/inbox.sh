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
# Inline answers (#7): most waits need one key — approve (Enter into the
# pane), deny (Escape), or a short reply — so the inbox sends them via
# send-keys without attaching. Attach stays the escape hatch for anything
# nontrivial; the inline path is sugar over the same live PTY. Guardrail:
# every row carries a fingerprint of the pane tail from render time, and an
# answer is refused when the pane's state or content changed since — a reply
# must never land in a context the user didn't see.
#
# Modes (fzf re-invokes this script):
#   (none)                       open the popup
#   --rows                       print the row list (also fzf's reload source)
#   --preview <key>              print the context panel for one row
#   --answer approve|deny <key>  send Enter/Escape into the pane (guarded)
#   --answer text <key> <reply>  send a literal reply + Enter (guarded)
#   --ask <key>                  prompt for a reply in the popup, then send

set -uo pipefail

SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
AF="$ROOT/bin/agent-fleet"

# shellcheck source=status.sh
source "$ROOT/scripts/status.sh"   # theme (T_*/AF_THEME_*), fmt_age, cache paths

tx() { "${TMUX_BIN:-tmux}" -L "$SOCKET" "$@"; }

SNAP="$AF_CACHE_DIR/fleet.snapshot"
# Escalation threshold (#17): same default as snapshotd — the inbox marker
# and the re-notification must agree on what "stuck" means.
ESC="${AGENT_FLEET_NOTIFY_ESCALATE:-600}"
[[ "$ESC" =~ ^[0-9]+$ ]] || ESC=600

# Fingerprint of what the user is looking at: the FULL visible pane,
# whitespace-normalized. Full, not a tail — permission dialogs share their
# last lines (options + hint), so a tail hash would false-pass across two
# different questions of the same shape. Claude's wait prompts are static
# (no live timer), so a changed fingerprint means the context moved on.
pane_fp() {  # <pane> -> checksum, empty when uncapturable
  local cap=""
  cap="$(tx capture-pane -p -t "$1" 2>/dev/null)" || { printf ''; return 0; }
  printf '%s' "$cap" | sed -e 's/[[:space:]]*$//' | cksum | awk '{print $1}'
}

# Row key: PANE:<pane>|<state>|<fingerprint>. '|' is safe — pane ids, states
# and checksums never carry it. Only local wait rows get a fingerprint (the
# only rows that accept answers).
rows() {
  [[ -f "$SNAP" ]] || { printf 'NONE\t\033[2m(fleet starting…)\033[0m\n'; return; }
  local line s wn pane st age intent iso glyph sub out="" asort fp
  while IFS= read -r line; do
    [[ "$line" == A\ * ]] || continue
    # iso before the catch-all _: the LAST read var swallows any newer
    # trailing fields, and intent must never absorb them (CONTRIBUTING #7).
    IFS='|' read -r s _ _ wn pane _ st _ age intent iso _ <<<"${line#A }"
    case "$st" in wait|done) ;; *) continue ;; esac
    glyph="$(state_glyph "$st")"
    if [[ -n "$intent" && "$intent" != "-" ]]; then wn="$intent"; fi
    (( ${#wn} > 40 )) && wn="${wn:0:39}…"
    sub="$st"; asort=0
    if [[ "$age" =~ ^[0-9]+$ ]]; then
      fmt_age "$age"; sub="$st $AGE"; asort="$age"
      # Past the escalation threshold (#17): the row that already re-notified
      # wears the same urgency in the queue.
      if [[ "$st" == "wait" ]] && (( ESC > 0 && age >= ESC )); then sub+=" !"; fi
    fi
    # Isolation rung (#11): wt/sbx/ctr when above host.
    [[ -n "${iso:-}" && "$iso" != "-" ]] && sub+=" · $iso"
    fp=""
    if [[ "$st" == "wait" && "$pane" != */* ]]; then fp="$(pane_fp "$pane")"; fi
    printf -v line 'PANE:%s|%s|%s\t%s \033[1m%-40s\033[0m \033[2m%s · %s\033[0m' \
      "$pane" "$st" "$fp" "$glyph" "$wn" "$s" "$sub"
    out+="$(state_rank "$st")"$'\t'"$asort"$'\t'"$line"$'\n'
  done < "$SNAP"
  if [[ -n "$out" ]]; then
    printf '%s' "$out" | sort -t$'\t' -k1,1n -k2,2nr | cut -f3-
  else
    # Zero-state that reads as ALIVE (#18): what the fleet is doing right now,
    # so an empty queue is reassurance, not a dead end.
    local nw=0 ni=0 tot=0
    while IFS= read -r line; do
      [[ "$line" == A\ * ]] || continue
      tot=$(( tot + 1 ))
      case "$line" in
        *'|working|'*) nw=$(( nw + 1 )) ;;
        *'|idle|'*)    ni=$(( ni + 1 )) ;;
      esac
    done < "$SNAP"
    printf 'NONE\t\033[2minbox zero — %s agents: %s working · %s idle · nothing needs you\033[0m\n' \
      "$tot" "$nw" "$ni"
  fi
}

# The guardrail, then the keys. Refusals print WHY and pause so the fzf
# execute() screen doesn't swallow the message.
answer() {  # <approve|deny|text> <key> [reply]
  local how="$1" key="${2#PANE:}" reply="${3:-}"
  local pane state fp now_fp
  IFS='|' read -r pane state fp <<<"$key"
  refuse() { echo "not sent: $1"; sleep 1.5; exit 1; }
  [[ "$pane" == */* ]] && refuse "remote agent — attach to answer (Enter)"
  [[ "$state" == "wait" ]] || refuse "row is '$state', answers are for waiting agents"
  # State per the CURRENT snapshot (≤ a tick old), then content fingerprint.
  local snap_st=""
  snap_st="$(awk -F'|' -v p="$pane" '/^A /{if ($5==p) st=$7} END{print st}' "$SNAP" 2>/dev/null || true)"
  [[ "$snap_st" == "wait" ]] || refuse "agent moved on (now: ${snap_st:-gone}) — reopen the inbox"
  now_fp="$(pane_fp "$pane")"
  [[ -n "$now_fp" && "$now_fp" == "$fp" ]] \
    || refuse "the pane changed since this row rendered (stale) — re-read it first"
  case "$how" in
    approve) tx send-keys -t "$pane" Enter ;;
    deny)    tx send-keys -t "$pane" Escape ;;
    text)    [[ -n "$reply" ]] || refuse "empty reply"
             # tmux strips an unescaped trailing ';' from an argv element (it
             # terminates the command) — escape it so the reply arrives whole.
             [[ "$reply" == *';' ]] && reply="${reply%;}\;"
             tx send-keys -t "$pane" -l -- "$reply" && tx send-keys -t "$pane" Enter ;;
    *)       refuse "unknown answer '$how'" ;;
  esac
  # Give the agent a beat to consume the keys so the reloaded row reflects it.
  sleep 0.4
}

ask() {  # <key> — free-text prompt inside the popup, then send
  local key="$1" reply=""
  printf '\n  reply (empty cancels): '
  IFS= read -r reply || reply=""
  [[ -z "$reply" ]] && exit 0
  answer text "$key" "$reply"
}

review() {  # <key> — route a done row into `af review` (diff + action menu)
  local key="${1#PANE:}" pane state _fp
  IFS='|' read -r pane state _fp <<<"$key"
  refuse() { echo "no review: $1"; sleep 1.5; exit 1; }
  [[ "$pane" == */* ]] && refuse "remote task — review it on ${pane%%/*}"
  [[ "$state" == "done" ]] || refuse "reviews are for done tasks (this row is '$state')"
  # No exec: outcomes (PR URL, refusals, merge errors) must survive until the
  # user has read them — fzf repaints the instant this returns.
  "$AF" review "$pane" || true
  printf '\n  press any key to return to the inbox… '
  IFS= read -r -n1 -s _ || true
}

preview() {  # <key: PANE:<pane>|<state>|<fp>>
  local key="${1#PANE:}" pane state _fp
  IFS='|' read -r pane state _fp <<<"$key"
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
      # The task's WHOLE delta: committed work diffed from the merge-base
      # with the repo's current branch (an agent that commits at the end —
      # the normal done state — would show an empty vs-HEAD stat), plus any
      # uncommitted leftovers.
      local repo="" branch="" mb="" base_label="HEAD"
      repo="$(awk '$1=="repo"{sub(/^repo /,""); print; exit}' "$AF_CACHE_DIR/tasks/$tid" 2>/dev/null || true)"
      branch="$(awk '$1=="branch"{sub(/^branch /,""); print; exit}' "$AF_CACHE_DIR/tasks/$tid" 2>/dev/null || true)"
      if [[ -n "$repo" && -n "$branch" ]]; then
        mb="$(git -C "$repo" merge-base "$branch" HEAD 2>/dev/null || true)"
        base_label="$(git -C "$repo" branch --show-current 2>/dev/null || echo 'base')"
      fi
      if [[ -n "$mb" ]]; then
        printf '\033[1mdiff vs %s\033[0m\n' "$base_label"
        git -C "$wt" diff --stat "$mb" 2>/dev/null | tail -20
      else
        printf '\033[1muncommitted changes\033[0m\n'
        git -C "$wt" diff --stat HEAD 2>/dev/null | tail -20
      fi
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
  --answer)  answer "${2:-}" "${3:-}" "${4:-}"; exit 0 ;;
  --ask)     ask "${2:-}"; exit 0 ;;
  --review)  review "${2:-}"; exit 0 ;;
esac

if ! command -v fzf >/dev/null 2>&1; then
  echo "agent-fleet inbox requires 'fzf' on PATH" >&2
  read -r -p "press enter to close…" _ || true
  exit 1
fi

sel="$(rows | fzf \
  --ansi --no-sort --reverse --cycle --no-scrollbar \
  --delimiter=$'\t' --with-nth=2.. \
  --header='inbox · ⏎ attach · ^y approve · ^n deny · ^t reply · ^v review · ^r refresh' \
  --prompt='◆ ' \
  --preview="'$0' --preview {1}" \
  --preview-window=down,55%,border-top \
  --bind="ctrl-r:reload('$0' --rows)" \
  --bind="ctrl-y:execute('$0' --answer approve {1})+reload('$0' --rows)" \
  --bind="ctrl-n:execute('$0' --answer deny {1})+reload('$0' --rows)" \
  --bind="ctrl-t:execute('$0' --ask {1})+reload('$0' --rows)" \
  --bind="ctrl-v:execute('$0' --review {1})+reload('$0' --rows)" \
  --color="bg+:$AF_THEME_HL,fg+:$AF_THEME_FG,hl:$AF_THEME_ACCENT,hl+:$AF_THEME_ACCENT,pointer:$AF_THEME_ACCENT,prompt:$AF_THEME_ACCENT,info:$AF_THEME_MUTED,header:$AF_THEME_MUTED,border:$AF_THEME_MUTED,gutter:-1")" \
  || exit 0
[[ -z "$sel" ]] && exit 0
key="$(cut -f1 <<<"$sel")"
case "$key" in
  PANE:*) target="${key#PANE:}"; "$AF" goto "${target%%|*}" ;;
esac
