#!/usr/bin/env bash
# remote-poll.sh <host> — mirror one remote fleet's snapshot into the local cache.
#
# Federation keeps a COMPLETE fleet on each host (agents + status hooks +
# snapshotd), because the hooks run inside the agent's own process and write to
# that machine's cache — a split setup loses hook-tier status entirely. Only the
# resulting snapshot travels.
#
# Writes $CACHE/remote/<host>.snapshot:
#
#   RT <fetched_at_local_epoch> <ok|down>      header, always the first line
#   S  <host>/<session>|<rollup>|<branch>      qualified, only when ok
#   A  <host>/<session>|<host>/<window_id>|<widx>|<wname>|<host>/<pane_id>|…
#
# Ids are qualified HERE so the merge in snapshotd is a plain concatenation, and
# so no snapshot consumer needs to change: they treat those fields as opaque
# strings, and '<host>/' can never collide with a local id because the CLI's
# sanitize_name() maps '/' out of session names.
#
# The remote's own clock comes back with the data, so "is that daemon alive?" is
# judged against the clock that wrote the timestamp — skew between the two
# machines can't fake a stale banner. C records are dropped: a remote window id
# could match the local rail's own and falsely mark it visible.
set -uo pipefail

host="${1:?usage: remote-poll.sh <host>}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
OUT_DIR="$CACHE/remote"
OUT="$OUT_DIR/$host.snapshot"
INTERVAL="${AGENT_FLEET_REMOTE_INTERVAL:-3}"
# Seam for tests: a stub stands in for ssh so the suite never touches a network.
SSH_CMD="${AGENT_FLEET_SSH_CMD:-ssh}"
mkdir -p "$OUT_DIR" 2>/dev/null || exit 0

# One multiplexed connection per host keeps a poll to a few ms; BatchMode and a
# short timeout mean an unreachable host fails fast instead of wedging the loop.
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5
          -o ControlMaster=auto -o ControlPersist=60
          -o "ControlPath=$CACHE/ssh-%r@%h:%p")
[[ "$SSH_CMD" == ssh ]] || ssh_opts=()   # a stub takes no ssh flags

# The remote prints its clock, then its snapshot. `cat` failing (no fleet there)
# still yields the clock line, which we report as 'down' rather than an error.
# shellcheck disable=SC2016 # expands on the REMOTE shell — deliberately single-quoted
REMOTE_CMD='date +%s; cat "${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet/fleet.snapshot" 2>/dev/null'

write_out() {  # stdin -> $OUT, atomically (same idiom as snapshotd)
  # shellcheck disable=SC2015 # write-then-swap idiom: mv failing must still clean up the temp
  cat > "$OUT.tmp.$$" 2>/dev/null && mv "$OUT.tmp.$$" "$OUT" 2>/dev/null \
    || rm -f "$OUT.tmp.$$" 2>/dev/null
}

cleanup() { rm -f "$OUT" "$OUT.tmp.$$" 2>/dev/null; exit 0; }
trap cleanup INT TERM HUP

while true; do
  now=""; printf -v now '%(%s)T' -1
  raw="$("$SSH_CMD" "${ssh_opts[@]}" "$host" "$REMOTE_CMD" 2>/dev/null)" || raw=""

  rclock="${raw%%$'\n'*}"                       # first line: the remote's clock
  body="${raw#*$'\n'}"; [[ "$body" == "$raw" ]] && body=""
  if [[ ! "$rclock" =~ ^[0-9]+$ ]]; then
    printf 'RT %s down\n' "$now" | write_out    # unreachable, or not agent-fleet
  else
    # Is the remote daemon still writing? Compare its T against ITS clock, using
    # the same threshold the local consumers use (interval*3+7).
    read -r _t rts riv <<<"$(grep -m1 '^T ' <<<"$body" || true)"
    [[ "$riv" =~ ^[0-9]+$ ]] || riv=1
    if [[ ! "$rts" =~ ^[0-9]+$ ]] || (( rclock - rts > riv * 3 + 7 )); then
      printf 'RT %s down\n' "$now" | write_out  # reachable, but its fleet is not
    else
      { printf 'RT %s ok\n' "$now"
        awk -v h="$host" -F'|' 'BEGIN{OFS="|"}
          /^S /{ sub(/^S /,""); $1 = h "/" $1; print "S " $0; next }
          /^A /{ sub(/^A /,""); $1 = h "/" $1; $2 = h "/" $2; $5 = h "/" $5
                 print "A " $0; next }' <<<"$body"
      } | write_out
    fi
  fi
  sleep "$INTERVAL"
done
