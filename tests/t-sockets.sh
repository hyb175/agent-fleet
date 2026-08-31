#!/usr/bin/env bash
# t-sockets.sh — socket-scoped cache (issue #14).
#   - a socket name sanitizes into a scoped dir under $AF_CACHE_ROOT
#   - the status hook resolves its scoped dir from its OWN socket ARG, not the
#     ambient AGENT_FLEET_SOCKET, so two fleets never write to the same file
#   - a fresh boot on one socket purges only ITS OWN panes/, never another
#     live socket's
#   - cache_migrate_default moves a pre-scoping install's root-level layout
#     into the default socket's scoped dir, and never touches theme.conf
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-sockets:"

# --- sanitization: the scoped dir name strips everything but [A-Za-z0-9._-] --
got="$(AGENT_FLEET_SOCKET='weird:name/here' bash -c \
  "source '$REPO/scripts/cache.sh'; printf '%s' \"\$AF_CACHE_DIR\"")"
check "socket name sanitizes into the scoped dir" \
  "[[ '$got' == '$XDG_CACHE_HOME/agent-fleet/weird_name_here' ]]"

# --- the hook resolves its scoped dir from its OWN socket arg -----------------
HOOK="$REPO/scripts/agent-status-hook.sh"
PANE="%sockettest"
# shellcheck disable=SC2153 # $SOCK is lib.sh's (sourced); not a typo for $SOCKB below
SOCK_A="${SOCK}-a"
SOCK_B="${SOCK}-b"

fire_hook() {  # <socket>
  printf '{}' | env TMUX_PANE="$PANE" AGENT_FLEET_NOTIFY=0 bash "$HOOK" working "$1" claude
}
fire_hook "$SOCK_A"
fire_hook "$SOCK_B"

check "socket A's event lands in socket A's scoped dir" \
  "[[ -f '$XDG_CACHE_HOME/agent-fleet/$SOCK_A/panes/$PANE.status' ]]"
check "socket B's event lands in socket B's scoped dir" \
  "[[ -f '$XDG_CACHE_HOME/agent-fleet/$SOCK_B/panes/$PANE.status' ]]"
check "the two scoped dirs are distinct" \
  "[[ '$XDG_CACHE_HOME/agent-fleet/$SOCK_A' != '$XDG_CACHE_HOME/agent-fleet/$SOCK_B' ]]"
check "no unscoped panes/ fallback at the shared cache root" \
  "[[ ! -e '$XDG_CACHE_HOME/agent-fleet/panes' ]]"

# --- a fresh boot on one socket never purges another live socket's panes/ -----
# Real fleet on socket A (lib's own $SOCK): a live server plus both kinds of
# artifact the old, unscoped layout used to risk — a hooked agent's status file
# and a saved layout.
boot_server t "$WORK"
mkdir -p "$XDG_CACHE_HOME/agent-fleet/$SOCK/panes"
printf 'wait\n' > "$XDG_CACHE_HOME/agent-fleet/$SOCK/panes/%1.status"
"$REPO/scripts/persist-save.sh"
check "socket A has a live status file before B boots" \
  "[[ -f '$XDG_CACHE_HOME/agent-fleet/$SOCK/panes/%1.status' ]]"
check "socket A has a saved fleet.state before B boots" \
  "[[ -f '$XDG_CACHE_HOME/agent-fleet/$SOCK/fleet.state' ]]"

# A second socket that has NEVER run before. A real CLI call there takes
# ensure_server's cold-boot branch — the exact purge that used to run against
# the one shared cache dir and could delete socket A's live state out from
# under it. `task` is the CLI's own non-attaching path to ensure_server (it
# never execs into `tmux attach-session`, unlike bare `attach`), so this
# exercises the real purge rather than a stand-in for it.
# Distinct from the hook test's SOCK_B above: that one already created
# .../agent-fleet/$SOCK-b, which would pre-satisfy the scoped-dir check here.
SOCKB="${SOCK}-boot"
# lib.sh's own EXIT trap only reaps $SOCK — extend it so this second server
# (and its socket file) doesn't outlive the test.
trap '"${TMUX_BIN:-tmux}" -L "$SOCKB" kill-server 2>/dev/null || true; _lib_cleanup' EXIT
claudestub="$(mktemp -d)"
printf '#!/bin/sh\nexec sleep 300\n' > "$claudestub/claude"; chmod +x "$claudestub/claude"
mkdir -p "$WORK/sockb"
PATH="$claudestub:$PATH" AGENT_FLEET_SOCKET="$SOCKB" "$REPO/bin/agent-fleet" \
  task "sockets isolation probe" --repo "$WORK/sockb" >/dev/null 2>&1

check "socket B got its own scoped cache dir" \
  "[[ -d '$XDG_CACHE_HOME/agent-fleet/$SOCKB' ]]"
check "socket A's status file survived socket B's fresh boot" \
  "[[ -f '$XDG_CACHE_HOME/agent-fleet/$SOCK/panes/%1.status' ]]"
check "socket A's fleet.state survived socket B's fresh boot" \
  "[[ -f '$XDG_CACHE_HOME/agent-fleet/$SOCK/fleet.state' ]]"
check "socket B's dir carries none of A's files" \
  "[[ ! -e '$XDG_CACHE_HOME/agent-fleet/$SOCKB/panes/%1.status' ]]"

"${TMUX_BIN:-tmux}" -L "$SOCKB" kill-server 2>/dev/null || true
rm -rf "$claudestub"

# --- migrating a pre-scoping install's layout ---------------------------------
# A fresh XDG root standing in for an existing install that predates
# socket-scoping: everything sat directly under $AF_CACHE_ROOT.
migroot="$(mktemp -d)"
old="$migroot/agent-fleet"
mkdir -p "$old/panes" "$old/tasks"
printf 'wait\n'              > "$old/panes/x.status"
printf 'S\tagent-fleet\n'    > "$old/fleet.state"
printf 'id t1\n'             > "$old/tasks/t1"
printf '# fabricated theme.conf\n' > "$old/theme.conf"

migrate() {  # run cache_migrate_default for the DEFAULT socket against $migroot
  AGENT_FLEET_SOCKET=agent-fleet XDG_CACHE_HOME="$migroot" bash -c \
    "source '$REPO/scripts/cache.sh'; cache_migrate_default"
}
migrate

scoped="$old/agent-fleet"
check "migration moved panes/ into the scoped dir"  "[[ -f '$scoped/panes/x.status' ]]"
check "migration moved fleet.state into the scoped dir" "[[ -f '$scoped/fleet.state' ]]"
check "migration moved tasks/ into the scoped dir"  "[[ -f '$scoped/tasks/t1' ]]"
check "old panes/ is gone (moved, not copied)"      "[[ ! -e '$old/panes' ]]"
check "theme.conf stayed at the shared root"        "[[ -f '$old/theme.conf' ]]"
check "theme.conf was NOT pulled into the scoped dir" "[[ ! -e '$scoped/theme.conf' ]]"

# Idempotent: a second run (the CLI calls this on every startup) must not error
# or re-migrate now that the scoped dir exists.
migrate
check "re-running migration is a harmless no-op" "[[ -f '$scoped/panes/x.status' ]]"

rm -rf "$migroot"
exit "$FAIL"
