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
# Private state too: task worktrees live under $XDG_STATE_HOME/agent-fleet.
# pwd -P like WORK: macOS mktemp yields /var/folders/… which tmux reports
# physically as /private/var/… — unresolved, every cwd comparison fails there.
XDG_STATE_HOME="$(cd "$(mktemp -d)" && pwd -P)"; export XDG_STATE_HOME
# The running fleet exports AGENT_FLEET_THEME into every pane's env; unset it so
# a suite launched from inside a themed fleet still resolves the default.
# Same for the escalation override: the inbox '!' marker tests assume the
# shipped default.
unset AGENT_FLEET_THEME AGENT_FLEET_NOTIFY_ESCALATE
# Restore relaunches are staggered for real machines; tests want speed.
export AGENT_FLEET_RESTORE_STAGGER=0
# Pin the default-shell for test servers: window commands run under it, and a
# login fish rebuilds PATH (93db864) — dropping the fake claude/docker stubs a
# test put ahead of the real binaries. /bin/sh preserves the inherited PATH, so
# stubs stay stubs. Tests about shell behavior (t-shim) pin SHELL per call.
export SHELL=/bin/sh
# Hermetic git: the developer's global config (commit signing, hooks, aliases)
# must not reach the repos the tests build; identity comes per command.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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

# poll_until [timeout_s] "<condition>" — re-eval a condition until true.
# Slow CI runners (macOS especially) outrun fixed sleeps; poll instead of
# napping wherever a check waits on the server/agents to catch up.
poll_until() {
  local t="${1:-10}"; shift
  local cond="$1" i
  for (( i = 0; i < t * 5; i++ )); do
    if eval "$cond" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  eval "$cond" >/dev/null 2>&1
}

# Boot a conf-loaded server with the fleet env pushed (most tests want this).
boot_server() {  # [session] [dir]
  tmux -L "$SOCK" -f "$REPO/conf/agent-fleet.conf" new-session -d -s "${1:-t}" -c "${2:-$WORK}"
  tx set-environment -g AGENT_FLEET_ROOT "$REPO"
  tx set-environment -g AGENT_FLEET_SOCKET "$SOCK"
  sleep 0.3
}

_lib_cleanup() {
  # Pane processes first, then the server: a tmux client a pane started (the
  # rail's startup query, a hook) that is mid-call when kill-server destroys
  # its pty wedges uninterruptibly on macOS and survives until reboot.
  local pids
  pids="$(tx list-panes -a -F '#{pane_pid}' 2>/dev/null | grep -E '^[1-9][0-9]*$' || true)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086 # pids is a validated, space-separated list
    kill -TERM $pids 2>/dev/null || true
    local i alive; for (( i = 0; i < 10; i++ )); do
      alive="$(tx list-panes -a -F '#{pane_dead}' 2>/dev/null || true)"
      [[ "$alive" == *0* ]] || break
      sleep 0.1
    done
  fi
  tx kill-server 2>/dev/null
  rm -rf "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$WORK" 2>/dev/null
  rm -f "/private/tmp/tmux-$(id -u)/$SOCK" 2>/dev/null
}
trap _lib_cleanup EXIT
