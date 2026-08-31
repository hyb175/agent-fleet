#!/usr/bin/env bash
# t-ttywrite.sh — the progress-bar write can never wedge the daemon.
#
# A pty whose master is gone has no carrier and open() waits for one, forever.
# A FIFO with no reader blocks in open() the same way, so it stands in for that
# terminal here — the real thing can't be staged (tmux holds every pane's
# master, so its ttys always have carrier).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-ttywrite:"

# Source the daemon for its helpers only — no lock, no loop (see snapshotd.sh).
AGENT_FLEET_ROOT="$REPO" source "$REPO/scripts/snapshotd.sh"

check "sourcing does not start a daemon" "[[ ! -d '$XDG_CACHE_HOME/agent-fleet/$SOCK/snapshotd.lock' ]]"

blocking="$WORK/blocking.fifo"
mkfifo "$blocking"

# The write must return immediately even though nothing will ever read.
start=$SECONDS
tty_write "$blocking" $'\033Ptmux;\033\033]9;4;3\007\033\\'
elapsed=$(( SECONDS - start ))
check "write to a reader-less tty returns at once (${elapsed}s)" "(( elapsed <= 1 ))"

stuck="${PROG_PENDING[0]:-}"
check "the write is a tracked child" "[[ -n '$stuck' ]]"
check "and it is genuinely stuck in open()" "kill -0 '$stuck' 2>/dev/null"

progress_reap
check "reap kills it" "! kill -0 '$stuck' 2>/dev/null"
check "reap clears the pending list" "(( \${#PROG_PENDING[@]} == 0 ))"

# A tty that works must still receive the bytes.
readable="$WORK/readable.fifo"
mkfifo "$readable"
( head -c 64 < "$readable" > "$WORK/got" ) & reader=$!
tty_write "$readable" 'hello'
wait_for 5 "[[ -s '$WORK/got' ]]"
kill "$reader" 2>/dev/null; wait "$reader" 2>/dev/null
check "a live tty still gets the bytes" "[[ \"\$(cat '$WORK/got' 2>/dev/null)\" == hello ]]"

# Reaping a completed write is a no-op, not an error.
progress_reap
check "reap after a clean write is harmless" "(( \${#PROG_PENDING[@]} == 0 ))"

exit "$FAIL"
