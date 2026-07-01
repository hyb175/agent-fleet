#!/usr/bin/env bash
# pick.sh — the fleet's single fzf picker.
#
# Views (Tab cycles; ^a/^s/^z jump directly):
#   fleet    (default) live agents (per-pane), most-urgent first, + agentless
#            workspaces. ⏎ jumps.
#   spaces   EVERY workspace (session): state glyph + branch + agent count.
#            ⏎ switches. The quick workspace switch (Prefix w opens here).
#   connect  recent folders (zoxide), git repos first w/ branch, noise filtered.
#            ⏎ spawns/attaches a workspace there. (Prefix f opens here.)
#   cloud    GitHub Codespaces (gh cs list). ⏎ connects a workspace + agent over SSH.

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
  local line s wid widx wn pane label st roll br glyph agents="" spaces="" idx=0
  while IFS= read -r line; do
    case "$line" in
      A\ *)
        IFS='|' read -r s wid widx wn pane label st <<<"${line#A }"
        glyph="$(glyph_of "$st")"
        printf -v line 'PANE:%s\t%s \033[1m%-16s\033[0m \033[2m%s:%s · %s\033[0m' "$pane" "$glyph" "$wn" "$s" "$widx" "$st"
        # Prefix a (rank, idx) sort key so the most urgent agents float to the
        # top; idx keeps it stable within a rank. Stripped after sorting, below.
        agents+="$(state_rank "$st")"$'\t'"$idx"$'\t'"$line"$'\n'
        idx=$(( idx + 1 ))
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
  # Sort agents by urgency (wait → working → done → idle), then drop the sort key.
  if [[ -n "$agents" ]]; then
    agents="$(printf '%s' "$agents" | sort -t$'\t' -k1,1n -k2,2n | cut -f3-)"$'\n'
  fi
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

# dir<TAB>branch for every recent git repo. Computed in one shot (used only by
# the cached refresher below), so the connect view never forks per-repo.
_connect_branch_map() {
  local d b
  while IFS= read -r d; do
    case "$d" in */.*) continue ;; esac
    [[ -d "$d" && -e "$d/.git" ]] || continue
    b="$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null)" || b=""
    [[ -n "$b" ]] && printf '%s\t%s\n' "$d" "$b"
  done < <(zoxide query -l 2>/dev/null)
}

# A single connect row. Used for cwd and the no-zoxide fallback (one git call,
# for that one dir only).
_conn_emit() {  # <dir> [is_cwd]
  local d="$1" tag="" b sub
  [[ -n "${2:-}" ]] && tag=" (cwd)"
  if [[ -e "$d/.git" ]]; then
    b="$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    sub="$d$tag"; [[ -n "$b" ]] && sub="$b  ·  $d$tag"
    printf 'CONNECT:%s\t\033[32m◆\033[0m \033[1m%-22s\033[0m \033[2m%s\033[0m\n' "$d" "${d##*/}" "$sub"
  else
    printf 'CONNECT:%s\t\033[2m+\033[0m \033[1m%-22s\033[0m \033[2m%s%s\033[0m\n' "$d" "${d##*/}" "$d" "$tag"
  fi
}

# Connect: recent folders to spawn a workspace in (zoxide frecency). Hidden-
# component paths (…/.ai-workspace/…, caches) and stale dirs are dropped; git
# repos are marked (◆ + branch) and floated above plain dirs; cwd is always
# offered. ⏎ spawns/attaches a workspace there.
list_connect() {
  local cwd="$PWD" dir repos="" dirs="" line b sub
  command -v zoxide >/dev/null 2>&1 || { _conn_emit "$cwd" 1; return; }

  # Branch map: read fork-free from a 60s cache; refresh in the background when
  # stale (one bg job does all the git calls, instead of one per row on open).
  declare -A BR
  local f="$AF_CACHE2/connect_branches" now ts=0 d
  printf -v now '%(%s)T' -1
  [[ -f "$f" ]] && { read -r ts; while IFS=$'\t' read -r d b; do [[ -n "$d" ]] && BR[$d]="$b"; done; } < "$f"
  if (( now - ts >= 60 )) && [[ ! -f "$f.tmp" ]]; then
    ( { printf '%s\n' "$now"; _connect_branch_map; } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; rm -f "$f.tmp" ) >/dev/null 2>&1 &
  fi

  while IFS= read -r dir; do
    [[ -z "$dir" || "$dir" == "$cwd" ]] && continue
    case "$dir" in */.*) continue ;; esac          # drop hidden-component paths
    [[ -d "$dir" ]] || continue                      # drop stale zoxide entries
    if [[ -e "$dir/.git" ]]; then
      sub="$dir"; b="${BR[$dir]:-}"; [[ -n "$b" ]] && sub="$b  ·  $dir"
      printf -v line 'CONNECT:%s\t\033[32m◆\033[0m \033[1m%-22s\033[0m \033[2m%s\033[0m' "$dir" "${dir##*/}" "$sub"
      repos+="$line"$'\n'
    else
      printf -v line 'CONNECT:%s\t\033[2m+\033[0m \033[1m%-22s\033[0m \033[2m%s\033[0m' "$dir" "${dir##*/}" "$dir"
      dirs+="$line"$'\n'
    fi
  done < <(zoxide query -l 2>/dev/null)

  _conn_emit "$cwd" 1                                 # cwd always offered, first
  printf '%s%s' "$repos" "$dirs"                      # repos before plain dirs
}

# Cloud: your GitHub Codespaces. ⏎ creates-or-switches a workspace for the
# codespace and adds a claude agent into it over SSH (agent-fleet cs connect).
# Degrades with a guidance row when gh is absent, the token lacks the codespace
# scope, or there are no codespaces — never a bare empty list.
list_cloud() {
  if ! command -v gh >/dev/null 2>&1; then
    printf 'NONE\t\033[2m(gh CLI not found — install GitHub CLI to use codespaces)\033[0m\n'; return
  fi
  local out rc
  out="$(gh codespace list --json name,repository,state,gitStatus \
          --template '{{range .}}{{.name}}{{"\t"}}{{.repository}}{{"\t"}}{{.gitStatus.ref}}{{"\t"}}{{.state}}{{"\n"}}{{end}}' 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    if grep -qiE 'codespace.*scope|"codespace" scope|admin rights' <<<"$out"; then
      # Actionable: ⏎ runs the scope grant in the popup, then reopens this view.
      printf 'AUTH:codespace\t\033[38;2;224;175;104m↻\033[0m \033[1m%-22s\033[0m \033[2mruns: gh auth refresh -s codespace\033[0m\n' \
        "Grant Codespaces access"
    else
      printf 'NONE\t\033[2m(gh codespace list failed: %s)\033[0m\n' "$(head -1 <<<"$out")"
    fi
    return
  fi
  if [[ -z "${out//[$'\n\t ']/}" ]]; then
    printf 'NONE\t\033[2m(no codespaces — create one on github.com or `gh cs create`)\033[0m\n'; return
  fi
  local name repo ref state glyph
  while IFS=$'\t' read -r name repo ref state; do
    [[ -z "$name" ]] && continue
    # Available codespaces read green (ready); stopped/other read muted.
    case "$state" in
      Available) glyph="$G_done" ;;
      *)         glyph="$G_idle" ;;
    esac
    printf 'CLOUD:%s\t%s \033[1m%-22s\033[0m \033[2m%s · %s\033[0m\n' \
      "$name" "$glyph" "${repo##*/}" "${ref:-?}" "$state"
  done <<<"$out"
}

run_view() {
  local view="$1" entries header prompt
  case "$view" in
    fleet)
      entries="$(list_fleet)"
      [[ -z "$entries" ]] && entries=$'NONE\t\033[2m(no workspaces — Tab to connect a repo)\033[0m'
      header='[fleet] spaces connect cloud  ·  Tab  ·  ⏎ jump  ·  / filter'
      prompt='› '
      ;;
    spaces)
      entries="$(list_spaces)"
      [[ -z "$entries" ]] && entries=$'NONE\t\033[2m(no workspaces — Tab to connect a repo)\033[0m'
      header='fleet [spaces] connect cloud  ·  Tab  ·  ⏎ switch  ·  / filter'
      prompt='⊞ '
      ;;
    connect)
      entries="$(list_connect)"
      header='fleet spaces [connect] cloud  ·  Tab  ·  ⏎ spawn · M-⏎ name  ·  / filter'
      prompt='⌕ '
      ;;
    cloud)
      entries="$(list_cloud)"
      header='fleet spaces connect [cloud]  ·  Tab  ·  ⏎ connect · M-⏎ name  ·  / filter'
      prompt='☁ '
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
    --bind="ctrl-x:become(echo VIEW:cloud)" \
    --bind="alt-enter:become(printf 'NAME\t%s\n' {1})" \
    --color="fg+:green,bg+:-1"
}

next_view() {
  case "$1" in fleet) echo spaces ;; spaces) echo connect ;; connect) echo cloud ;; *) echo fleet ;; esac
}

main() {
  local view="${1:-fleet}" selection key scope
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
      VIEW:cloud)   view="cloud";   continue ;;
      VIEW:next)    view="$(next_view "$view")"; continue ;;
      NONE)         continue ;;
      PANE:*)       "$AF" goto "${key#PANE:}"; exit 0 ;;
      SESS:*)       "$AF" connect "${key#SESS:}"; exit 0 ;;
      CONNECT:*)    "$AF" connect "${key#CONNECT:}"; exit 0 ;;
      CLOUD:*)      "$AF" cs connect "${key#CLOUD:}"; exit 0 ;;
      NAME)
        # Alt-⏎ on a connect/cloud row: prompt for a workspace name (pre-filled
        # with the default), then create. On any other row, behave like ⏎.
        local target nm def
        target="$(printf '%s' "$selection" | cut -f2)"
        case "$target" in
          CONNECT:*)
            def="${target##*/}"; printf '\n'
            read -e -i "$def" -p "  workspace name: " nm </dev/tty 2>/dev/null || nm=""
            "$AF" connect "${target#CONNECT:}" "${nm:-$def}"; exit 0 ;;
          CLOUD:*)
            def="${target#CLOUD:}"; printf '\n'
            read -e -i "$def" -p "  workspace name: " nm </dev/tty 2>/dev/null || nm=""
            "$AF" cs connect "${target#CLOUD:}" "${nm:-$def}"; exit 0 ;;
          PANE:*)  "$AF" goto "${target#PANE:}"; exit 0 ;;
          SESS:*)  "$AF" connect "${target#SESS:}"; exit 0 ;;
          *)       continue ;;
        esac ;;
      AUTH:*)
        # Grant a missing gh token scope interactively (the popup has a TTY, so
        # gh's one-time-code + browser flow works), then reopen the cloud view.
        scope="${key#AUTH:}"
        clear 2>/dev/null || true
        printf '\n  Granting the \033[1m%s\033[0m scope through gh (a browser will open)…\n\n' "$scope"
        if gh auth refresh -h github.com -s "$scope"; then
          printf '\n  \033[38;2;158;206;106m✓ %s scope granted.\033[0m opening codespaces…\n' "$scope"
          sleep 1
        else
          printf '\n  \033[38;2;247;118;142m✗ gh auth refresh failed.\033[0m press enter to go back…\n'
          read -r _ || true
        fi
        view="cloud"; continue ;;
    esac
  done
}

# Only run the picker when executed directly (so it can be sourced for tests).
# Optional arg = initial view (fleet|spaces|connect|cloud); Prefix w opens 'spaces'.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
