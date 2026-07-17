#!/usr/bin/env bash
# t-status.sh — status.sh unit tests: the two-tier state system.
#   - hooked tier reads files with AND without trailing newlines (the read/
#     clobber bug that silently disabled the tier)
#   - clear_done round-trips done -> idle
#   - unhooked panes fall through to the scrape tier
#   - scraped done/ack lifecycle: done -> visit -> idle -> activity re-arms
#   - cache_bg spawns ONE refresher for staggered callers during a slow command
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-status:"

AGENT_FLEET_ROOT="$REPO" bash -c '
  source "'"$REPO"'/scripts/status.sh"
  AF_CACHE="'"$WORK"'/panes"; mkdir -p "$AF_CACHE"
  fail=0
  ck() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }

  # --- hooked tier (scrape stubbed to a sentinel: seeing it = tier lost) ---
  cache_bg() { echo "SCRAPE-TIER"; }
  printf "%s\n" working > "$AF_CACHE/%1.status"     # new-style (with \n)
  printf "%s"   done    > "$AF_CACHE/%2.status"     # legacy (no \n)
  ck "hooked file with newline reads"        "[[ \"\$(state_for_pane %1 claude)\" == working ]]"
  ck "legacy file without newline reads"     "[[ \"\$(state_for_pane %2 claude)\" == done ]]"
  clear_done %2
  ck "clear_done flips done -> idle"         "[[ \"\$(state_for_pane %2 claude)\" == idle ]]"
  ck "no file falls through to scrape tier"  "[[ \"\$(state_for_pane %3 claude)\" == SCRAPE-TIER ]]"

  # --- scraped ack lifecycle (controllable scrape) ---
  RAW="'"$WORK"'/raw"
  cache_bg() { shift 2; "$@"; }
  _state_capture() { cat "$RAW"; }
  pane="%77"; ack="$AF_CACHE/$pane.ackdone"
  echo done    > "$RAW"; ck "scraped unseen done reads done"     "[[ \"\$(state_for_pane $pane claude)\" == done ]]"
  clear_done "$pane";    ck "visit drops the ack marker"          "[[ -e \"$ack\" ]]"
  echo done    > "$RAW"; ck "done after visit reads idle"         "[[ \"\$(state_for_pane $pane claude)\" == idle ]]"
  echo working > "$RAW"; ck "activity re-arms (working, no ack)"  "[[ \"\$(state_for_pane $pane claude)\" == working && ! -e \"$ack\" ]]"
  echo done    > "$RAW"; ck "next finished turn reads done again" "[[ \"\$(state_for_pane $pane claude)\" == done ]]"
  exit $fail
'
rc1=$?

# --- scrape-tier classification (_state_capture) against the CURRENT Claude UI.
#     Stub the tmux capture with canned pane content (ASCII stand-ins for the
#     ❯/… glyphs — the state regexes don't depend on the exact glyph). ---
AGENT_FLEET_ROOT="$REPO" bash -c '
  source "'"$REPO"'/scripts/status.sh"
  CAP="'"$WORK"'/cap"; STUB="'"$WORK"'/faketmux"
  printf "#!/usr/bin/env bash\ncat %q\n" "$CAP" > "$STUB"; chmod +x "$STUB"
  AF_TMUX="$STUB"
  fail=0
  ck() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }

  # fresh agent: only the empty prompt + footer, no turn ever completed.
  printf "%s\n" "> " "----" "  -- INSERT -- auto mode on . <- for agents" > "$CAP"
  ck "fresh agent -> idle"                    "[[ \"\$(_state_capture x)\" == idle ]]"

  # live spinner with a running timer (…-or-... followed by a paren).
  printf "%s\n" "* Frobnicating... (3s . 1.2k tokens)" "> " > "$CAP"
  ck "live spinner timer -> working"          "[[ \"\$(_state_capture x)\" == working ]]"

  # finished a turn (past-tense summary) and asking a free-form question — the
  # regression: this used to fall through to idle because there was no "new task?".
  printf "%s\n" "  Which one?" "* Baked for 2h 4m 23s" "> " "  -- INSERT -- auto mode on" > "$CAP"
  ck "past-tense turn summary -> done"        "[[ \"\$(_state_capture x)\" == done ]]"

  # the intermittent "new task?" footer still counts as done.
  printf "%s\n" "* Cogitated for 1m 56s" "new task? /clear to save 294.6k tokens" "> " > "$CAP"
  ck "new task? footer -> done"               "[[ \"\$(_state_capture x)\" == done ]]"

  # a permission prompt is a distinct "needs you" state.
  printf "%s\n" "  Do you want to proceed?" "  1. Yes" "  2. No" > "$CAP"
  ck "permission prompt -> wait"              "[[ \"\$(_state_capture x)\" == wait ]]"

  exit $fail
'
rc3=$?

# --- cache_bg dedup across a slow refresh (fresh shell: the ack section above
#     stubbed cache_bg, so this must not share that scope) ---
AGENT_FLEET_ROOT="$REPO" bash -c '
  source "'"$REPO"'/scripts/status.sh"
  AF_CACHE2="'"$WORK"'/cache"; mkdir -p "$AF_CACHE2"
  slow() { echo run >> "'"$WORK"'/count"; sleep 1; echo val; }
  cache_bg k 5 slow; sleep 0.15; cache_bg k 5 slow; sleep 0.15; cache_bg k 5 slow
  sleep 1.3
  runs="$(wc -l < "'"$WORK"'/count" 2>/dev/null | tr -d " ")"
  if [[ "${runs:-0}" == 1 ]]; then echo "  PASS: cache_bg: staggered callers -> 1 refresher"; exit 0
  else echo "  FAIL: cache_bg: staggered callers -> 1 refresher (got ${runs:-0})"; exit 1; fi
' >/dev/null 2>&1 && rc2=0 || rc2=1
# re-emit the verdict outside the silenced subshell (its stdout carried stray
# background-job output)
if [[ $rc2 -eq 0 ]]; then echo "  PASS: cache_bg: staggered callers -> 1 refresher"
else echo "  FAIL: cache_bg: staggered callers -> 1 refresher"; fi
exit $(( rc1 || rc2 || rc3 ))
