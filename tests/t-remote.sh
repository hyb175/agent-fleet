#!/usr/bin/env bash
# t-remote.sh — federation: mirroring a remote fleet, and jumping into it.
#   - remote-poll qualifies ids with the host and drops C records
#   - unreachable host / dead remote daemon / dead poller all read as down
#   - snapshotd concatenates the mirror into fleet.snapshot; a down host
#     collapses to one (unreachable) workspace row
#   - a "<host>/<id>" target opens an ssh tab instead of a bogus local session
# The ssh seam (AGENT_FLEET_SSH_CMD) keeps the suite off the network.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-remote:"
CACHE="$XDG_CACHE_HOME/agent-fleet"
mkdir -p "$CACHE" "$WORK/bin"

# A stub ssh: prints the remote's clock, then whatever we've staged as that
# host's fleet.snapshot. Ignores its args, exactly like the real thing's output
# contract (host + command are all remote-poll depends on).
cat > "$WORK/bin/ssh-stub" <<STUB
#!/usr/bin/env bash
[[ -f "$WORK/remote-clock" ]] || exit 1
cat "$WORK/remote-clock"
cat "$WORK/remote-snap" 2>/dev/null
STUB
chmod +x "$WORK/bin/ssh-stub"

# One poll, then stop. SIGKILL on purpose: the poller's TERM trap removes its
# mirror (a stopped poller must not leave rows behind), which is exactly the
# artifact under test here.
poll_once() {
  rm -f "$CACHE/remote/devbox.snapshot"
  AGENT_FLEET_SSH_CMD="$WORK/bin/ssh-stub" AGENT_FLEET_REMOTE_INTERVAL=30 \
    "$REPO/scripts/remote-poll.sh" devbox >/dev/null 2>&1 &
  local p=$!
  wait_for 10 "[[ -f '$CACHE/remote/devbox.snapshot' ]]"
  kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
}

# --- a healthy remote ---------------------------------------------------------
printf -v now '%(%s)T' -1
echo "$now" > "$WORK/remote-clock"
{ printf 'T %s 1\n' "$now"
  printf 'S api|wait|main\n'
  printf 'A api|@3|1|claude|%%8|claude|wait|1\n'
  printf 'C @3\n'
} > "$WORK/remote-snap"
poll_once
mirror="$CACHE/remote/devbox.snapshot"
check "mirror written" "[[ -f '$mirror' ]]"
check "header says ok" "grep -q '^RT [0-9]* ok\$' '$mirror'"
check "session id qualified" "grep -qx 'S devbox/api|wait|main' '$mirror'"
check "agent session+window+pane qualified" \
  "grep -qx 'A devbox/api|devbox/@3|1|claude|devbox/%8|claude|wait|1' '$mirror'"
check "C records dropped (would fake local rail visibility)" "! grep -q '^C ' '$mirror'"
check "remote T record not mirrored" "! grep -q '^T ' '$mirror'"

# --- the remote's own daemon died: reachable, but its data is frozen ----------
{ printf 'T %s 1\n' "$(( now - 600 ))"; printf 'S api|wait|main\n'; } > "$WORK/remote-snap"
poll_once
check "stale remote daemon reads as down" "grep -q '^RT [0-9]* down\$' '$mirror'"
check "no agent rows survive a down host" "! grep -q '^A ' '$mirror'"

# --- unreachable host ---------------------------------------------------------
rm -f "$WORK/remote-clock"
poll_once
check "unreachable host reads as down" "grep -q '^RT [0-9]* down\$' '$mirror'"

# --- snapshotd merges the mirror ----------------------------------------------
boot_server t "$WORK"
AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
  "$REPO/scripts/snapshotd.sh" >/dev/null 2>&1 &
snapd=$!
SNAP="$CACHE/fleet.snapshot"
wait_for 10 "[[ -s '$SNAP' ]]"
check "a down host collapses to one row" \
  "grep -qx 'S devbox|none|(unreachable)' '$SNAP'"

# A live mirror flows through verbatim.
printf -v now '%(%s)T' -1
echo "$now" > "$WORK/remote-clock"
{ printf 'T %s 1\n' "$now"
  printf 'S api|wait|main\n'
  printf 'A api|@3|1|claude|%%8|claude|wait|1\n'
} > "$WORK/remote-snap"
poll_once
wait_for 10 "grep -q 'devbox/api' '$SNAP'"
check "remote agent row reaches the snapshot" \
  "grep -qx 'A devbox/api|devbox/@3|1|claude|devbox/%8|claude|wait|1' '$SNAP'"
check "local rows still present" "grep -q '^S t|' '$SNAP'"

# A poller that died leaves its last mirror behind, still marked ok; the merge
# judges it by the fetched-at stamp, so it must not serve it as live data.
{ printf 'RT %s ok\n' "$(( now - 600 ))"; tail -n +2 "$mirror"; } > "$mirror.old" \
  && mv "$mirror.old" "$mirror"
wait_for 10 "grep -qx 'S devbox|none|(unreachable)' '$SNAP'"
check "dead poller's mirror is not served as live" \
  "grep -qx 'S devbox|none|(unreachable)' '$SNAP' && ! grep -q 'devbox/api' '$SNAP'"

kill "$snapd" 2>/dev/null; wait "$snapd" 2>/dev/null

# --- jumping into a federated target ------------------------------------------
# Without the dispatch, `connect devbox/api` sanitizes to a LOCAL session named
# devbox_api in $HOME — the bug this replaces.
af() { AGENT_FLEET_REMOTES=devbox AGENT_FLEET_SSH_CMD="$WORK/bin/hang-ssh" \
       AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }
printf '#!/usr/bin/env bash\nsleep 30\n' > "$WORK/bin/hang-ssh"; chmod +x "$WORK/bin/hang-ssh"

af connect devbox/api >/dev/null 2>&1
sleep 0.5
check "no bogus local session created" "! tx has-session -t '=devbox_api' 2>/dev/null"
check "ssh tab opened, named for the host" \
  "tx list-windows -a -F '#{window_name}' | grep -qx devbox"
# The command is %q-quoted for tmux, so compare with the escaping stripped.
unq() { local s; s="$(tx list-panes -a -F '#{pane_start_command}' | grep -- "$1" | head -1)"; printf '%s' "${s//\\/}"; }
cmdline="$(unq hang-ssh)"
check "workspace target attaches on the remote (got: $cmdline)" \
  "[[ \"\$cmdline\" == *'-t devbox bash -lc'* && \"\$cmdline\" == *'agent-fleet attach api'* ]]"

af goto devbox/%8 >/dev/null 2>&1
sleep 0.5
cmdline="$(unq goto)"
check "pane target resolves to goto on the remote (got: $cmdline)" \
  "[[ \"\$cmdline\" == *'agent-fleet goto %8'* ]]"

# An unconfigured prefix is NOT a remote: it stays a plain local workspace name.
AGENT_FLEET_REMOTES=devbox AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" \
  "$REPO/bin/agent-fleet" connect other/api >/dev/null 2>&1
sleep 0.3
check "unconfigured prefix stays local" "tx has-session -t '=other_api' 2>/dev/null"

exit $FAIL
