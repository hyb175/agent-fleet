#!/usr/bin/env bash
# t-cs-ports.sh — cs-connect port-reservation protocol (stubbed gh).
#   - two parallel connects reserve DIFFERENT local ports
#   - a fresh pid-less lock (holder mid-creation) is respected, not stolen
#   - a dead-pid lock is taken over
#   - SIGTERM releases the lock (EXIT trap doesn't fire on signals by default)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-cs-ports:"
STUB="$(mktemp -d)"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "codespace list") echo "owner/repo"; exit 0 ;;
  *) sleep 30 ;;
esac
EOF
chmod +x "$STUB/gh"
PORTS="$XDG_CACHE_HOME/agent-fleet/ports"
run_cs() {  # <name> <outfile>
  PATH="$STUB:$PATH" XDG_CACHE_HOME="$XDG_CACHE_HOME" SHELL=/usr/bin/true \
    timeout 4 bash "$REPO/scripts/cs-connect.sh" "$1" bash > "$2" 2>&1
}
got_port() { tr -d '\033' < "$1" | grep -o 'localhost:[0-9]*' | head -1; }

# parallel distinct ports + TERM release
run_cs one "$WORK/o1" & a=$!
sleep 0.5
run_cs two "$WORK/o2" & b=$!
sleep 2
p1="$(got_port "$WORK/o1")"; p2="$(got_port "$WORK/o2")"
check "parallel connects get distinct ports ($p1/$p2)" "[[ -n '$p1' && -n '$p2' && '$p1' != '$p2' ]]"
wait "$a" "$b" 2>/dev/null
check "locks released after SIGTERM" "[[ -z \"\$(ls '$PORTS' 2>/dev/null)\" ]]"

# The lock cases must target the FIRST port the scan actually reaches — probe
# it (an unlocked run's choice) instead of assuming 2222 is listener-free.
run_cs probe "$WORK/op"
base="$(got_port "$WORK/op")"; base="${base#localhost:}"
rm -rf "$PORTS"
check "probe found the scan's first port ($base)" "[[ -n '$base' ]]"

# nascent pid-less lock respected
mkdir -p "$PORTS/$base.lock"
run_cs three "$WORK/o3"
check "fresh pid-less lock respected -> next port ($(got_port "$WORK/o3"))" "[[ \"\$(got_port '$WORK/o3')\" != 'localhost:$base' && -n \"\$(got_port '$WORK/o3')\" ]]"
rm -rf "$PORTS"

# dead-pid lock taken over
mkdir -p "$PORTS/$base.lock"; echo 999999 > "$PORTS/$base.lock/pid"
run_cs four "$WORK/o4"
check "dead-pid lock taken over ($(got_port "$WORK/o4"))" "[[ \"\$(got_port '$WORK/o4')\" == 'localhost:$base' ]]"

rm -rf "$STUB"
exit $FAIL
