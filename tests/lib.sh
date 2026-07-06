# tests/lib.sh — shared harness for the agent-fleet integration tests.
#
# Every test runs on a THROWAWAY tmux socket and a private XDG cache, so the
# suite never touches a real fleet. Source this at the top of a t-*.sh:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides: REPO, SOCK, WORK (scratch dir), tx, check, FAIL, and an EXIT trap
# that kills the test server and removes the scratch state.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="af-test-$$"
export AGENT_FLEET_ROOT="$REPO"
export AGENT_FLEET_SOCKET="$SOCK"
export XDG_CACHE_HOME="$(mktemp -d)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"

tx() { tmux -L "$SOCK" "$@"; }

FAIL=0
check() {  # <label> <condition to eval>
  if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; FAIL=1; fi
}

# Boot a conf-loaded server with the fleet env pushed (most tests want this).
boot_server() {  # [session] [dir]
  tmux -L "$SOCK" -f "$REPO/conf/agent-fleet.conf" new-session -d -s "${1:-t}" -c "${2:-$WORK}"
  tx set-environment -g AGENT_FLEET_ROOT "$REPO"
  tx set-environment -g AGENT_FLEET_SOCKET "$SOCK"
  sleep 0.3
}

_lib_cleanup() {
  tx kill-server 2>/dev/null
  rm -rf "$XDG_CACHE_HOME" "$WORK" 2>/dev/null
  rm -f "/private/tmp/tmux-$(id -u)/$SOCK" 2>/dev/null
}
trap _lib_cleanup EXIT
