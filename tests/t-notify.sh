#!/usr/bin/env bash
# t-notify.sh — actionable notifications (#8).
#   - notify.sh leads the body with the task intent and wires a click-to-jump
#     (terminal-notifier -execute path, exercised via a stub)
#   - AGENT_FLEET_NOTIFY=0 silences it
#   - snapshotd escalates a long wait at most ONCE per episode
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-notify:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
mkdir -p "$CACHE/panes" "$CACHE/tasks"

# Stub notifier, first on PATH: records every invocation's args, one per line.
STUB="$(mktemp -d)"
NLOG="$WORK/notify.log"
cat > "$STUB/terminal-notifier" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NLOG"
EOF
chmod +x "$STUB/terminal-notifier"
export PATH="$STUB:$PATH"

# Task record so the body carries the intent.
printf 'id t1\nintent review the login flow\npane %%7\n' > "$CACHE/tasks/t1"
printf 't1\n' > "$CACHE/panes/%7.task"

notify() { AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
           bash "$REPO/scripts/notify.sh" "$@"; }

notify "$SOCK" %7 "needs your input"
check "body leads with the task intent" "grep -q 'review the login flow — ' '$NLOG'"
check "click action jumps to the pane" "grep -q 'goto %7' '$NLOG'"
check "message text present" "grep -q 'needs your input' '$NLOG'"

: > "$NLOG"
AGENT_FLEET_NOTIFY=0 notify "$SOCK" %7 "needs your input"
check "AGENT_FLEET_NOTIFY=0 silences" "[[ ! -s '$NLOG' ]]"

# --- escalation: once per wait episode ---------------------------------------
boot_server t "$WORK"
kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
for _ in $(seq 1 30); do [[ -d "$CACHE/snapshotd.lock" ]] || break; sleep 0.2; done

wp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 120')"
tx set-option -p -t "$wp" @fleet-agent-kind claude
printf 'wait\n' > "$CACHE/panes/$wp.status"
touch -d '@'"$(( $(date +%s) - 300 ))" "$CACHE/panes/$wp.status" 2>/dev/null \
  || touch -t "$(date -v-5M '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CACHE/panes/$wp.status" 2>/dev/null

: > "$NLOG"
AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  AGENT_FLEET_SNAP_INTERVAL=1 AGENT_FLEET_NOTIFY_ESCALATE=60 AGENT_FLEET_NOTIFY=1 \
  PATH="$STUB:$PATH" nohup "$REPO/scripts/snapshotd.sh" >/dev/null 2>&1 &

# The pane was ALREADY past the threshold when the daemon started: the first
# tick must seed silently (#17) — a reload/restart never re-fires the backlog
# ("once per wait episode" survives restarts).
sleep 4
n0="$(grep -c 'still waiting' "$NLOG" 2>/dev/null || true)"
check "restart backlog seeds silently (no re-fire)" "[[ '${n0:-0}' -eq 0 ]]"

# A NEW episode crossing the threshold on THIS daemon's watch fires once.
printf 'working\n' > "$CACHE/panes/$wp.status"
sleep 2
printf 'wait\n' > "$CACHE/panes/$wp.status"
touch -d '@'"$(( $(date +%s) - 300 ))" "$CACHE/panes/$wp.status" 2>/dev/null \
  || touch -t "$(date -v-5M '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CACHE/panes/$wp.status" 2>/dev/null
sleep 3
n="$(grep -c 'still waiting' "$NLOG" 2>/dev/null || true)"
check "escalation fired" "[[ '${n:-0}' -ge 1 ]]"
check "escalation fired exactly once" "[[ '${n:-0}' -eq 1 ]]"

# Leaving wait re-arms; the NEXT episode escalates again.
printf 'working\n' > "$CACHE/panes/$wp.status"
sleep 2
printf 'wait\n' > "$CACHE/panes/$wp.status"
touch -d '@'"$(( $(date +%s) - 300 ))" "$CACHE/panes/$wp.status" 2>/dev/null \
  || touch -t "$(date -v-5M '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CACHE/panes/$wp.status" 2>/dev/null
sleep 3
n2="$(grep -c 'still waiting' "$NLOG" 2>/dev/null || true)"
check "a new wait episode escalates once more" "[[ '${n2:-0}' -eq 2 ]]"

kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
rm -rf "$STUB"
exit "$FAIL"
