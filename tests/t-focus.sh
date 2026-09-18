#!/usr/bin/env bash
# t-focus.sh — the focus hook writes files and signals nothing.
#   - focus.now records "session|window_id"; rails poll its mtime
#   - no kill, no tmux call: a pid-based wake once did `kill -USR1 -1` (a
#     pane with no process reports pane_pid -1) and signalled every process
#     the user owned
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-focus:"

stub="$(mktemp -d)"; export PATH="$stub:$PATH"
log="$stub/calls"
printf '#!/usr/bin/env bash\necho "tmux $*" >> "%s"\n' "$log" > "$stub/tmux"; chmod +x "$stub/tmux"
export TMUX_BIN="$stub/tmux"
# Functions shadow builtins; export -f carries it into the hook's own bash.
# shellcheck disable=SC2329 # invoked by the hook via export -f, not here
kill() { printf 'kill %s\n' "$*" >> "$log"; }
export -f kill
export log

bash "$REPO/scripts/focus-track.sh" %9 0 sess @1
check "focus.now records the view" "[[ \"\$(cat \"\$XDG_CACHE_HOME/agent-fleet/\$SOCK/focus.now\")\" == 'sess|@1' ]]"
check "no process was signalled and tmux was not asked (log: $(tr '\n' ';' < "$log" 2>/dev/null))" "[[ ! -s '$log' ]]"

exit "$FAIL"
