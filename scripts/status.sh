#!/usr/bin/env bash
# status.sh — read and render live agent status.
#
# Sourced by pick.sh (and the sidenav); also usable as a CLI:
#   status.sh state <pane_id>     -> wait|working|done|idle
#   status.sh glyph <pane_id>     -> colored glyph
#   status.sh gc                  -> prune status files for dead panes
#   status.sh summary             -> status-bar wait/working/done counts
#   status.sh clear-done <pane>   -> demote a 'done' agent to idle
#
# Status comes from two tiers:
#   1. a per-pane file written by agent-status-hook.sh (authoritative)
#   2. capture-pane fallback for agents started without the hook
# Ambiguous output falls back to 'idle', never 'wait' — so it never cries wolf.

set -uo pipefail

AF_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/panes"
AF_CACHE2="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/cache"
AF_SOCKET="${AGENT_FLEET_SOCKET:-agent-fleet}"
AF_TMUX="${TMUX_BIN:-tmux}"

mkdir -p "$AF_CACHE2" 2>/dev/null || true

# cache_bg <key> <ttl_seconds> <cmd> [args...]
# Echo the cached value if fresh; otherwise refresh it in the BACKGROUND and
# echo the stale value (or nothing) immediately — nothing on the hot path waits
# on ps/capture-pane/git. The always-running rails keep these warm.
#
# Fork-free on a cache hit: `printf %(%s)T` (no `date`), the timestamp lives on
# the cache file's first line (read via the `read` builtin — no `stat`/`cat`),
# and the key is sanitized with parameter expansion (no `tr`). macOS forks are
# ~15ms each, so avoiding them is what makes the picker fast.
cache_bg() {
  local key="$1" ttl="$2"; shift 2
  local f="$AF_CACHE2/${key//[^A-Za-z0-9._-]/_}"
  local now ts val=""
  printf -v now '%(%s)T' -1
  if [[ -f "$f" ]]; then
    read -r ts val < "$f" 2>/dev/null || true
    if [[ -n "${ts:-}" ]] && (( now - ts < ttl )); then printf '%s' "$val"; return; fi
  fi
  # Stale/miss: refresh in the background, but only ONE refresher per key at a
  # time. The shared-temp existence is the dedup guard, so the 10+ rails sharing
  # this cache don't each spawn a job (which piled up and hammered tmux). The
  # subshell is fully silenced; the stat (to clear a stuck temp from a killed
  # job) only runs in the rare case the temp already exists.
  # mtime: GNU stat first (-c %Y), then BSD (-f %m). GNU-first matters because
  # BSD's -f means --file-system on GNU and wouldn't fail cleanly; macOS rejects
  # -c outright, so it falls through to -f. Works on both this way.
  if [[ ! -f "$f.tmp" ]] || (( now - $(stat -c %Y "$f.tmp" 2>/dev/null || stat -f %m "$f.tmp" 2>/dev/null || echo 0) > 15 )); then
    # Claim the temp SYNCHRONOUSLY, before backgrounding: the command
    # substitution in the subshell runs before its redirection, so a claim
    # made inside the subshell doesn't exist during exactly the window the
    # dedup guard is for — every caller across the slow command's runtime
    # would spawn its own refresher. One redirect, no fork, on the hot path.
    : > "$f.tmp" 2>/dev/null || true
    ( printf '%s %s\n' "$now" "$("$@")" > "$f.tmp" && mv "$f.tmp" "$f"; rm -f "$f.tmp" ) >/dev/null 2>&1 &
  fi
  printf '%s' "$val"
}

# "esc to interrupt" is the only marker Claude Code shows *while generating*, so
# it cleanly separates working from idle. Avoid loose words like "tokens" — they
# also appear in the idle footer and misclassified idle agents as working.
_state_capture() {
  local tail
  tail="$("$AF_TMUX" -L "$AF_SOCKET" capture-pane -t "$1" -p 2>/dev/null | tail -12)"
  # Working: Claude's live spinner is "<glyph> <Gerund>… (Ns · …)" — a gerund
  # ending in "…" followed by a parenthesised live timer. (In auto mode there's
  # no "esc to interrupt".) Matching the "…(" timer avoids the idle footer's
  # "/clear to save N tokens" and the past-tense "Worked for Ns" done summary.
  if   grep -qE "esc to interrupt|…[[:space:]]*\(|\.\.\.[[:space:]]*\(" <<<"$tail"; then echo working
  elif grep -qE "Do you want to proceed|Continue\?|❯ [0-9]\.|[0-9]\. Yes|to select" <<<"$tail"; then echo wait
  # Finished a turn and waiting for your next input: Claude's footer shows
  # "new task?" (only present once a conversation has a completed turn — a fresh
  # agent never shows it). Distinguishes "done & waiting" from a truly idle pane.
  elif grep -qF "new task?" <<<"$tail"; then echo done
  else echo idle
  fi
}

# state_for_pane <pane_id> [current_command]
state_for_pane() {
  local pane="$1" cmd="${2:-}" f="$AF_CACHE/$1.status" st=""
  # `|| true`, NOT `|| st=""`: on a file without a trailing newline, read
  # assigns the value and THEN returns 1 (EOF) — clobbering st here silently
  # disabled the entire hooked tier.
  [[ -f "$f" ]] && { read -r st < "$f" 2>/dev/null || true; }
  [[ -n "$st" ]] && { echo "$st"; return; }    # hooked agent: instant + accurate
  case "$cmd" in
    fish|zsh|bash|sh|tmux|"") echo "idle"; return ;;   # plain shell
  esac
  # Non-hooked agent: capture-pane is slow, so cache it (2s) + refresh in bg.
  st="$(cache_bg "st_$pane" 2 _state_capture "$pane")"
  st="${st:-idle}"
  # "done" acknowledgement — the scraped twin of the hooked clear-done flow.
  # Visiting a finished agent drops a .ackdone marker (see clear_done); while it's
  # present a scraped 'done' reads 'idle' (you've seen it). Any non-done state
  # means new activity, so the marker is cleared and the next finished turn
  # surfaces again. This is what keeps the triage queue (Prefix Space) draining.
  local ack="$AF_CACHE/$pane.ackdone"
  if [[ -e "$ack" ]]; then
    if [[ "$st" == "done" ]]; then st="idle"; else rm -f "$ack" 2>/dev/null; fi
  fi
  echo "$st"
}

# Foreground commands treated as agents when scraping non-hooked panes.
# Space-separated; override with AGENT_FLEET_AGENT_CMDS to add other CLIs.
# (Cursor's CLI binary is literally `agent`.)
_AGENT_CMDS="${AGENT_FLEET_AGENT_CMDS:-claude codex opencode agent}"

# Some CLIs ship under a generic binary name; show a friendlier kind in the rail.
_agent_kind_label() { case "$1" in agent) printf 'cursor' ;; *) printf '%s' "$1" ;; esac; }

_agent_kind_ps() {  # <pane_tty> -> agent kind (claude|codex|opencode|cursor|…) or empty
  local comm k
  while read -r comm; do
    comm="${comm##*/}"
    for k in $_AGENT_CMDS; do
      [[ "$comm" == "$k" ]] && { _agent_kind_label "$k"; return; }
    done
  done < <(ps -t "${1#/dev/}" -o comm= 2>/dev/null)
}

# pane_agent_kind <pane_kind_tag> <pane_current_command> <pane_tty> <is_sidenav>
# Echo the agent kind if THIS PANE is an agent — either explicitly tagged
# (launched via `agent-fleet add`) or a Claude CLI detected running in the pane.
pane_agent_kind() {
  local kind="$1" cmd="$2" tty="$3" sidenav="$4"
  [[ "$sidenav" == "1" ]] && return            # the rail itself
  [[ -n "$kind" ]] && { printf '%s' "$kind"; return; }
  case "$cmd" in
    fish|zsh|bash|sh|tmux|"") return ;;        # plain workspace shell
  esac
  cache_bg "ak_$tty" 5 _agent_kind_ps "$tty"   # ps is slow: cache (5s) + bg refresh
}

state_rank() {
  case "$1" in
    wait)    echo 0 ;;
    working) echo 1 ;;
    done)    echo 2 ;;
    idle)    echo 3 ;;
    *)       echo 4 ;;
  esac
}

# Shared glyph vocabulary (used by the sidenav AND the picker, so they match).
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)        # braille spinner, 1 cell each

# state_fg <state> -> ANSI fg color (Tokyo Night truecolor).
state_fg() {
  case "$1" in
    wait)    printf '\033[38;2;247;118;142m' ;;   # red    #f7768e
    working) printf '\033[38;2;224;175;104m' ;;   # yellow #e0af68
    done)    printf '\033[38;2;158;206;106m' ;;   # green  #9ece6a
    *)       printf '\033[38;2;86;95;137m'   ;;   # muted  #565f89
  esac
}

# glyph_char <state> [frame] -> 1-cell glyph; working uses the braille spinner.
glyph_char() {
  case "$1" in
    working)   printf '%s' "${SPIN[$(( ${2:-0} % ${#SPIN[@]} ))]}" ;;
    wait|done) printf '●' ;;
    idle)      printf '○' ;;
    *)         printf '·' ;;
  esac
}

# state_glyph <state> [frame] -> complete colored glyph (color + char + reset).
state_glyph() {
  printf '%s%s\033[0m' "$(state_fg "$1")" "$(glyph_char "$1" "${2:-0}")"
}

gc() {
  [[ -d "$AF_CACHE" ]] || return 0
  local live f base
  live="$("$AF_TMUX" -L "$AF_SOCKET" list-panes -a -F '#{pane_id}' 2>/dev/null || true)"
  [[ -z "$live" ]] && return 0
  for f in "$AF_CACHE"/*.status "$AF_CACHE"/*.ackdone "$AF_CACHE"/*.session; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"; base="${base%.*}"   # strip .status / .ackdone / .session
    grep -qx "$base" <<<"$live" || rm -f "$f"
  done
}

# clear_done <pane> — acknowledge a finished agent (called when you visit it via
# goto / a rail click). Hooked agents store state in a file, so flip done→idle
# there. Scraped agents have no file; if the pane is currently 'done', drop a
# .ackdone marker that state_for_pane honors until the agent shows activity again.
clear_done() {
  local f="$AF_CACHE/$1.status"
  if [[ -f "$f" ]]; then
    [[ "$(cat "$f" 2>/dev/null || true)" == "done" ]] && printf 'idle\n' > "$f"
  elif [[ "$(_state_capture "$1")" == "done" ]]; then
    mkdir -p "$AF_CACHE" 2>/dev/null || true
    : > "$AF_CACHE/$1.ackdone" 2>/dev/null || true
  fi
  return 0
}

AF_GIT_TTL="${AGENT_FLEET_GIT_TTL:-30}"   # seconds a cached branch stays fresh

# The blocking computation: short branch (+ "↑N" ahead), or empty if not a repo.
# `rev-list --count @{u}..HEAD` is slow on big repos, which is why git_branch
# only runs this in the background via cache_bg.
_git_branch_raw() {
  local dir="$1" b ahead
  b="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || b="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" || { printf ''; return; }
  ahead="$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  if [[ "${ahead:-0}" -gt 0 ]]; then printf '%s ↑%s' "$b" "$ahead"; else printf '%s' "$b"; fi
}

# git_branch <dir> — non-blocking (cached + background-refreshed). Empty if not a
# repo (or while cold); callers fall back to the dir path.
git_branch() {
  [[ -n "$1" ]] || { printf ''; return; }
  cache_bg "br_$1" "$AF_GIT_TTL" _git_branch_raw "$1"
}

# summary — compact fleet agent counts for the status bar, e.g. "⚠2 ⏳1 ✓3".
# Emits tmux #[fg=...] directives (Tokyo Night) so the status line colors it.
summary() {
  local w=0 g=0 d=0 label st pane cmd tty kind sidenav
  while IFS='|' read -r pane cmd tty kind sidenav; do
    [[ -z "$pane" ]] && continue
    label="$(pane_agent_kind "$kind" "$cmd" "$tty" "$sidenav")"
    [[ -n "$label" ]] || continue
    st="$(state_for_pane "$pane" "$cmd")"
    case "$st" in
      wait)    w=$((w + 1)) ;;
      working) g=$((g + 1)) ;;
      done)    d=$((d + 1)) ;;
    esac
  done < <("$AF_TMUX" -L "$AF_SOCKET" list-panes -a \
            -F '#{pane_id}|#{pane_current_command}|#{pane_tty}|#{@fleet-agent-kind}|#{@fleet-sidenav}' 2>/dev/null)
  # Match the rail/picker glyphs: ● red wait, braille working, ● green done.
  # The working frame advances each status refresh (a slow spin).
  local out="" frame=$(( $(date +%s) % 10 ))
  (( w > 0 )) && out+="#[fg=#f7768e]●${w} "
  (( g > 0 )) && out+="#[fg=#e0af68]$(glyph_char working "$frame")${g} "
  (( d > 0 )) && out+="#[fg=#9ece6a]●${d} "
  [[ -n "$out" ]] && printf '%s#[default]' "$out"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    state)      state_for_pane "$@" ;;
    glyph)      state_glyph "$(state_for_pane "$@")" ;;
    gc)         gc ;;
    summary)    summary ;;
    clear-done) clear_done "$@" ;;
    *) echo "usage: status.sh {state|glyph|gc|summary|clear-done} [pane]" >&2; exit 2 ;;
  esac
fi
