#!/usr/bin/env bash
# t-bash32.sh — hook-tier scripts run under /bin/bash (3.2 on macOS).
#   - the status hook runs inside the AGENT's process, under whatever `bash`
#     its PATH resolves; a macOS login shell puts /bin/bash 3.2 first, and
#     `printf %(%s)T` (bash 4.2) aborted the record append on every Stop
#   - notify.sh and the claude shim take the same route
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-bash32:"
B=/bin/bash
[[ -x "$B" ]] || { echo "  SKIP: no $B"; exit 0; }
echo "  ($("$B" --version | head -1))"

CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
mkdir -p "$CACHE/panes" "$CACHE/tasks"
PANE="%b32"
printf 'id t32\nintent port the hook\npane %s\nisolation host\n' "$PANE" > "$CACHE/tasks/t32"
printf 't32\n' > "$CACHE/panes/$PANE.task"
printf 'working\n' > "$CACHE/panes/$PANE.status"

# Transition path: appends `state done <epoch>` to the record.
err="$(TMUX_PANE="$PANE" TMUX_BIN=/nonexistent "$B" "$REPO/scripts/agent-status-hook.sh" 'done' "$SOCK" claude 2>&1 </dev/null)"
check "hook runs clean under $B (stderr: ${err:-none})" "[[ -z \"\$err\" ]]"
check "hook wrote the status" "[[ \"\$(cat \"$CACHE/panes/$PANE.status\")\" == done ]]"
check "record got a timestamped transition" "grep -Eq '^state done [0-9]{9,}$' \"$CACHE/tasks/t32\""

# Auto-adopt path: no pointer file -> a record is minted with an epoch tid.
rm -f "$CACHE/panes/$PANE.task"
err="$(TMUX_PANE="$PANE" TMUX_BIN=/nonexistent "$B" "$REPO/scripts/agent-status-hook.sh" working "$SOCK" claude 2>&1 </dev/null)"
check "adopt path runs clean under $B (stderr: ${err:-none})" "[[ -z \"\$err\" ]]"
check "adopt minted an epoch-named record" "ls \"$CACHE/tasks\" | grep -Eq '^t[0-9]{9,}-b32$'"

# notify.sh: stub notifier, same interpreter.
STUB="$(mktemp -d)"; NLOG="$STUB/log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$NLOG" > "$STUB/terminal-notifier"
chmod +x "$STUB/terminal-notifier"
err="$(PATH="$STUB:$PATH" TMUX_BIN=/nonexistent "$B" "$REPO/scripts/notify.sh" "$SOCK" "$PANE" "finished" 2>&1)"
check "notify.sh runs clean under $B (stderr: ${err:-none})" "[[ -z \"\$err\" ]]"
check "notify.sh reached the notifier" "grep -q 'finished' \"$NLOG\""

# claude shim: --version passes straight through to the real binary.
printf '#!/usr/bin/env bash\necho real-claude "$@"\n' > "$STUB/claude"; chmod +x "$STUB/claude"
out="$(PATH="$STUB:$PATH" "$B" "$REPO/shims/claude" --version 2>&1)"
check "shim passes through under $B (got: $out)" "[[ \"\$out\" == 'real-claude --version' ]]"

exit "$FAIL"
