#!/usr/bin/env bash
# persist-restore.sh — rebuild the fleet from a restore file (see persist-save.sh).
#
# Recreates sessions, windows (name + exact split layout) and panes in their
# saved cwds, then re-renders the left rail per window. The sidenav auto-hook
# is suppressed during the rebuild (via a throwaway scratch session that absorbs
# the first-window race) so it can't add duplicate rails. Hooked agents are
# relaunched by recorded kind — `claude --resume <id>` / `kimi --session <id>` /
# `opencode --session <id>` when a session id was saved, else a FRESH agent in
# the saved dir. A failed/expired resume drops to a shell; every non-agent pane
# returns as a shell in its dir.
#
# Called by ensure_server on a cold boot and by `agent-fleet restore`. Exits
# non-zero (leaving the caller to create a fresh session) when there's nothing
# to restore. Fields are TAB-separated with every field forced non-empty — see
# persist-save.sh for why (tmux escapes control-char delimiters in -F output;
# read collapses runs of whitespace IFS).

set -uo pipefail

SOCK="${AGENT_FLEET_SOCKET:-agent-fleet}"
ROOT="${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}"
CONF="${AGENT_FLEET_CONF:-$ROOT/conf/agent-fleet.conf}"
export AGENT_FLEET_CONF="$CONF"   # the conf's Prefix r reload expands this at parse time
# Render the palette's tmux side before booting — the conf sources
# $AGENT_FLEET_THEME_CONF (exported by theme.sh) at parse time.
source "$ROOT/scripts/theme.sh"
theme_write_conf
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
STATE="$CACHE/fleet.state"
US=$'\t'   # matches persist-save; every field is non-empty so tab won't collapse
RESTORE_AGENTS="${AGENT_FLEET_RESTORE_AGENTS:-1}"   # relaunch claude with --resume
OVERLAY="$CACHE/hooks-settings.json"                # status-hooks settings overlay

[[ -f "$STATE" ]] || exit 1
tx() { "${TMUX_BIN:-tmux}" -L "$SOCK" "$@"; }

# Concurrent cold boots (several terminal tabs each running `agent-fleet
# attach` after a reboot) must not race the rebuild: the loser used to fail its
# scratch-session creation and boot a stray home session — or attach
# mid-restore and resize the half-built layout. One restorer holds the lock;
# the others wait for it and adopt its outcome.
RLOCK="$CACHE/restore.lock"
if ! mkdir "$RLOCK" 2>/dev/null; then
  hp="$(cat "$RLOCK/pid" 2>/dev/null)"
  lk_m="$(stat -c %Y "$RLOCK" 2>/dev/null || stat -f %m "$RLOCK" 2>/dev/null || echo 0)"
  printf -v now_s '%(%s)T' -1
  live_holder=0
  if [[ -n "$hp" ]] && kill -0 "$hp" 2>/dev/null; then live_holder=1
  elif (( now_s - lk_m < 120 )); then live_holder=1   # pid not written yet — grace
  fi
  if (( live_holder )); then
    for _ in $(seq 1 150); do [[ -d "$RLOCK" ]] || break; sleep 0.2; done
    tx list-sessions >/dev/null 2>&1 && exit 0        # peer restored it
    exit 1
  fi
  rm -rf "$RLOCK" 2>/dev/null; mkdir "$RLOCK" 2>/dev/null || exit 1   # stale takeover
fi
echo $$ > "$RLOCK/pid"
trap 'rm -rf "$RLOCK" 2>/dev/null' EXIT
trap 'rm -rf "$RLOCK" 2>/dev/null; exit 129' INT TERM HUP

# --- parse the state file ---------------------------------------------------
declare -A WLAYOUT WNAME WACTIVE   # key: session US widx
declare -A PANES                   # key: session US widx -> "pidx US rail US cwd\n"...
declare -A SEEN
sess_order=(); attached=""
while IFS="$US" read -r kind f2 f3 f4 f5 f6 f7 f8 f9 _; do
  case "$kind" in
    A) attached="$f2" ;;
    W) WLAYOUT["$f2$US$f3"]="$f5"; WNAME["$f2$US$f3"]="$f6"; WACTIVE["$f2$US$f3"]="$f4"
       [[ -z "${SEEN[$f2]:-}" ]] && { SEEN[$f2]=1; sess_order+=("$f2"); } ;;
    # pidx, sidenav, session, cwd, agent kind (f9 empty in pre-kind state
    # files — resolved to claude at relaunch below)
    P) PANES["$f2$US$f3"]+="$f4$US$f5$US$f7$US$f8$US${f9:--}"$'\n' ;;
  esac
done < "$STATE"
(( ${#sess_order[@]} )) || exit 1

# A fresh server reuses pane ids from %0, so every per-pane state file from the
# previous boot is stale — and a stale .session gate file would permanently
# block the hook from capturing the new claude session id (gc only prunes files
# for DEAD panes; recycled ids look live). Purge before any id is reused.
rm -f "$CACHE/panes/"*.status "$CACHE/panes/"*.ackdone "$CACHE/panes/"*.session 2>/dev/null || true

# --- start the server (loads conf: hooks + rail-auto), then suppress the auto
#     rail. The scratch session takes the first-window auto-rail so our rebuilt
#     windows stay under our control; it's removed at the end. --------------
"${TMUX_BIN:-tmux}" -L "$SOCK" -f "$CONF" new-session -d -s "__af_restore__" -x 220 -y 50 2>/dev/null || exit 1
# Remember the user's effective auto-rail setting (conf + local.conf just
# loaded) so we can put it back afterwards instead of clobbering an opt-out.
prev_auto="$(tx show-option -gqv @fleet-sidenav-auto 2>/dev/null)"
tx set-option -g @fleet-sidenav-auto off 2>/dev/null || true
tx set-environment -g AGENT_FLEET_ROOT "$ROOT" 2>/dev/null || true
tx set-environment -g AGENT_FLEET_SOCKET "$SOCK" 2>/dev/null || true

rail_cmd="exec env AGENT_FLEET_SOCKET='$SOCK' AGENT_FLEET_ROOT='$ROOT' '$ROOT/scripts/sidenav.sh'"

for s in "${sess_order[@]}"; do
  # The scratch name is reserved; a real session that somehow carries it can't
  # be rebuilt — say so instead of silently dropping it.
  [[ "$s" == "__af_restore__" ]] && { echo "persist-restore: skipping reserved session name __af_restore__" >&2; continue; }

  # window indexes for this session, sorted numerically
  widxs=()
  for key in "${!WLAYOUT[@]}"; do [[ "$key" == "$s$US"* ]] && widxs+=("${key#*"$US"}"); done
  widxs_sorted=(); while IFS= read -r x; do [[ -n "$x" ]] && widxs_sorted+=("$x"); done \
    < <(printf '%s\n' "${widxs[@]}" | sort -n)

  first=1; active_win=""
  for widx in "${widxs_sorted[@]}"; do
    wk="$s$US$widx"
    layout="${WLAYOUT[$wk]}"; wname="${WNAME[$wk]}"; wact="${WACTIVE[$wk]:-0}"

    # panes sorted by pane index; parallel arrays: cwd, agent session, rail
    # flag, agent kind
    cwds=(); sids=(); rails=(); kinds=(); while IFS="$US" read -r pidx prail psid pcwd pkind; do
      [[ -z "$pidx" ]] && continue
      cwds+=("$pcwd"); sids+=("$psid"); rails+=("$prail"); kinds+=("${pkind:--}")
    done < <(printf '%s' "${PANES[$wk]:-}" | sort -t"$US" -k1,1n)
    (( ${#cwds[@]} )) || continue

    # create the window with pane 1, then split to the saved pane count
    if (( first )); then
      # Size the detached session from the saved layout ("csum,WxH,…"): at the
      # default 80x24, repeated splits run out of rows and ~6+-pane windows
      # silently lose panes before select-layout can reproduce the geometry.
      dims="${layout#*,}"; dims="${dims%%,*}"
      dim_w="${dims%x*}"; dim_h="${dims#*x}"
      [[ "$dim_w" =~ ^[0-9]+$ && "$dim_h" =~ ^[0-9]+$ ]] || { dim_w=220; dim_h=50; }
      win_id="$(tx new-session -d -P -F '#{window_id}' -s "$s" -n "$wname" -c "${cwds[0]}" -x "$dim_w" -y "$dim_h" 2>/dev/null)"
      first=0
    else
      win_id="$(tx new-window -d -P -F '#{window_id}' -t "$s:" -n "$wname" -c "${cwds[0]}" 2>/dev/null)"
    fi
    [[ -n "$win_id" ]] || continue
    i=1
    while (( i < ${#cwds[@]} )); do
      tx split-window -d -t "$win_id" -c "${cwds[$i]}" 2>/dev/null || true
      # Rebalance after every split: repeatedly splitting the same active pane
      # halves it into oblivion (50 rows → 5 splits max); tiled keeps capacity
      # proportional to the window area. The exact saved layout is applied below.
      tx select-layout -t "$win_id" tiled 2>/dev/null || true
      i=$(( i + 1 ))
    done

    # reproduce the exact geometry (rail slot included)
    tx select-layout -t "$win_id" "$layout" 2>/dev/null || true

    # Re-render the rail into the pane that WAS the rail — identified by the
    # saved P-record flag, not by geometry. Panes were created in sorted
    # saved-index order and tmux lists them in index order, so position k maps
    # 1:1. The old geometry match (left=0, width==30, full height) silently
    # failed whenever a client attached mid-restore and scaled the layout,
    # leaving a bare shell (cwd = wherever the rail was spawned from, usually
    # the fleet repo) sitting where the rail should be — and without the
    # @fleet-sidenav flag, the ensure hook could never self-heal it.
    pane_ids=(); while IFS= read -r p; do [[ -n "$p" ]] && pane_ids+=("$p"); done \
      < <(tx list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null)
    railp=""
    for (( k = 0; k < ${#rails[@]} && k < ${#pane_ids[@]}; k++ )); do
      [[ "${rails[$k]}" == "1" ]] && { railp="${pane_ids[$k]}"; break; }
    done
    if [[ -n "$railp" ]]; then
      tx respawn-pane -k -t "$railp" "$rail_cmd" 2>/dev/null || true
      tx set-option -p -t "$railp" @fleet-sidenav 1 2>/dev/null || true
      tx set-option -p -t "$railp" remain-on-exit off 2>/dev/null || true
    fi

    # Relaunch agents into live work panes, matched by cwd (fallback: any unused
    # work pane). Resume by saved id, or start fresh when the id is missing; a
    # failed/expired resume drops to a shell so the pane survives.
    if [[ "$RESTORE_AGENTS" == "1" ]]; then
      work_ids=(); work_cwds=()
      while IFS='|' read -r pid pr pcwd2; do
        [[ "$pr" == "1" ]] && continue
        work_ids+=("$pid"); work_cwds+=("$pcwd2")
      done < <(tx list-panes -t "$win_id" -F '#{pane_id}|#{?@fleet-sidenav,1,0}|#{pane_current_path}' 2>/dev/null)
      used=" "; j=0
      while (( j < ${#sids[@]} )); do
        sid="${sids[$j]}"; scwd="${cwds[$j]}"; skind="${kinds[$j]:--}"; j=$(( j + 1 ))
        has_sid=1; [[ "$sid" == "-" || -z "$sid" ]] && has_sid=0
        # A pane with no saved session-id is only relaunched when it WAS an agent
        # (kind claude/kimi/codex) — then it starts fresh (below). A plain shell
        # pane (kind '-' and no id) stays a shell.
        if (( ! has_sid )); then
          case "$skind" in claude|kimi|codex) : ;; *) continue ;; esac
        fi
        # Pre-kind state files carry no kind; every hooked agent then was claude.
        [[ "$skind" == "-" || -z "$skind" ]] && skind="claude"
        chosen=""; k=0
        while (( k < ${#work_ids[@]} )); do
          [[ "${work_cwds[$k]}" == "$scwd" && "$used" != *" ${work_ids[$k]} "* ]] && { chosen="${work_ids[$k]}"; break; }
          k=$(( k + 1 ))
        done
        if [[ -z "$chosen" ]]; then
          k=0; while (( k < ${#work_ids[@]} )); do
            [[ "$used" != *" ${work_ids[$k]} "* ]] && { chosen="${work_ids[$k]}"; break; }; k=$(( k + 1 ))
          done
        fi
        [[ -z "$chosen" ]] && continue
        used+="$chosen "
        # Relaunch command by kind: resume the saved session when we have an id,
        # otherwise start the agent FRESH in the saved dir (better than a shell).
        # kimi/codex hooks are install-wide, so their fresh form takes no flag.
        case "$skind" in
          kimi)     (( has_sid )) && rc="kimi --session $sid" || rc="kimi" ;;
          codex)    (( has_sid )) && rc="codex resume $sid"   || rc="codex" ;;
          opencode) (( has_sid )) && rc="opencode --session $sid" || rc="opencode" ;;
          *)     (( has_sid )) && rc="claude --resume $sid" || rc="claude"
                 [[ -f "$OVERLAY" ]] && rc="$rc --settings $OVERLAY" ;;
        esac
        tx set-option -p -t "$chosen" @fleet-agent-kind "$skind" 2>/dev/null || true
        tx set-option -w -t "$chosen" @fleet-agent "$skind" 2>/dev/null || true
        if (( has_sid )); then
          # Re-arm persistence for the NEXT reboot: without these, the next
          # auto-save (~15s away) records '-' for this pane and the resumed
          # session id is lost. --resume keeps the same session id, so the gate
          # file is correct, not stale.
          tx set-option -p -t "$chosen" @fleet-session "$sid" 2>/dev/null || true
          mkdir -p "$CACHE/panes" 2>/dev/null || true
          printf '%s\n' "$sid" > "$CACHE/panes/$chosen.session" 2>/dev/null || true
          # A failed resume (deleted/expired session) drops to a shell; clearing
          # the gate + option lets a manually-started claude capture its new id
          # instead of every future save retrying the dead sid.
          fb="rm -f $(printf '%q' "$CACHE/panes/$chosen.session") 2>/dev/null; $(printf '%q' "${TMUX_BIN:-tmux}") -L $(printf '%q' "$SOCK") set-option -p -u @fleet-session 2>/dev/null; exec bash -i"
        else
          # Fresh agent: no id yet. Leave @fleet-session unset (clear any stale
          # gate) so the hook captures the new session's id on its first event.
          tx set-option -p -t "$chosen" -u @fleet-session 2>/dev/null || true
          rm -f "$CACHE/panes/$chosen.session" 2>/dev/null || true
          fb="exec bash -i"
        fi
        tx respawn-pane -k -t "$chosen" "bash -lc '$rc || { $fb; }'" 2>/dev/null || true
      done
    fi

    # leave focus on a work (non-rail) pane
    workp="$(tx list-panes -t "$win_id" -F '#{pane_id} #{@fleet-sidenav}' 2>/dev/null \
            | awk '$2!="1"{print $1; exit}')"
    [[ -n "$workp" ]] && tx select-pane -t "$workp" 2>/dev/null || true

    [[ "$wact" == "1" ]] && active_win="$win_id"
  done
  [[ -n "$active_win" ]] && tx select-window -t "$active_win" 2>/dev/null || true
done

# restored split windows need their active-pane indicators tuned
"$ROOT/scripts/border-tune.sh" 2>/dev/null || true

# tidy up: drop the scratch session, put the user's auto-rail setting back
tx kill-session -t "__af_restore__" 2>/dev/null || true
tx set-option -g @fleet-sidenav-auto "${prev_auto:-on}" 2>/dev/null || true

# best-effort: make the previously-attached session most-recent so a bare
# `attach-session` lands there.
[[ -n "$attached" ]] && tx has-session -t "$attached" 2>/dev/null \
  && tx switch-client -t "$attached" 2>/dev/null || true

exit 0
