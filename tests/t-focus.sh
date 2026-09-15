#!/usr/bin/env bash
# t-focus.sh — the focus hook's rail wake-up signals only real rail pids.
#   - a pane with no process reports pane_pid -1; `kill -USR1 -1` would signal
#     every process the user owns (it once took down a whole GUI session)
#   - 0 / empty / non-numeric pids and non-rail panes are skipped too
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-focus:"

# Stub tmux: list-panes answers with the hazardous rows plus one good rail.
stub="$(mktemp -d)"; export PATH="$stub:$PATH"
cat > "$stub/tmux" <<'STUB'
#!/usr/bin/env bash
case "$*" in *list-panes*) printf '%s\n' '-1|1' '0|1' '|1' 'abc|1' '4242|1' '5151|0' ;; esac
STUB
chmod +x "$stub/tmux"
export TMUX_BIN="$stub/tmux"

# Intercept kill: functions shadow builtins, and export -f carries it into the
# hook's own bash.
log="$stub/kills"
# shellcheck disable=SC2329 # invoked by the hook via export -f, not here
kill() { printf '%s\n' "$*" >> "$log"; }
export -f kill
export log

bash "$REPO/scripts/focus-track.sh" %9 0 sess @1
got="$(cat "$log" 2>/dev/null || true)"
check "only the live rail pid is signalled (got: ${got//$'\n'/ ; })" "[[ \"\$got\" == '-USR1 4242' ]]"
check "focus.now records the view" "[[ \"\$(cat \"\$XDG_CACHE_HOME/agent-fleet/\$SOCK/focus.now\")\" == 'sess|@1' ]]"

exit "$FAIL"
