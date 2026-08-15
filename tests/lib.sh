#!/usr/bin/env bash
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
XDG_CACHE_HOME="$(mktemp -d)"; export XDG_CACHE_HOME
# Private config too: theme resolution reads $XDG_CONFIG_HOME/agent-fleet/theme,
# and the machine's real choice must not leak into test assertions.
XDG_CONFIG_HOME="$(mktemp -d)"; export XDG_CONFIG_HOME
# The running fleet exports AGENT_FLEET_THEME into every pane's env; unset it so
# a suite launched from inside a themed fleet still resolves the default.
unset AGENT_FLEET_THEME
WORK="$(cd "$(mktemp -d)" && pwd -P)"

tx() { tmux -L "$SOCK" "$@"; }

FAIL=0
# shellcheck disable=SC2034 # FAIL is read by every t-*.sh's `exit "$FAIL"` after sourcing
check() {  # <label> <condition to eval>
  if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; FAIL=1; fi
}

# Poll <cond> until it holds or <secs> elapse; 0 if it held. Integration timing
# scales with machine load — a fixed sleep that passes on an idle box starts
# failing under load, so wait on the condition and let `check` do the asserting.
wait_for() {  # <secs> <cond>
  local deadline=$(( SECONDS + ${1:-10} )) cond="$2"
  while (( SECONDS < deadline )); do
    eval "$cond" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
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
  rm -rf "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$WORK" 2>/dev/null
  rm -f "/private/tmp/tmux-$(id -u)/$SOCK" 2>/dev/null
}
trap _lib_cleanup EXIT
