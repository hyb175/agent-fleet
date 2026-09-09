#!/usr/bin/env bash
# af-entrypoint.sh — default image entrypoint.
# 1. Init the default-deny firewall (root; requires --cap-add NET_ADMIN).
#    A firewall failure REFUSES to start the agent — the pane shows why and
#    dies, it never silently runs with open egress under a record that says
#    container. AF_FIREWALL=0 skips it — debugging only, never the default.
# 2. Drop to the host user (AF_UID/AF_GID) so files written into the mounted
#    worktree keep the host's ownership, then exec the agent command.
set -uo pipefail

if [[ "${AF_FIREWALL:-1}" == "1" ]]; then
  if ! /usr/local/bin/init-firewall.sh; then
    echo "af-entrypoint: firewall init FAILED — refusing to start (--cap-add NET_ADMIN missing? AF_FIREWALL=0 to debug unrestricted)" >&2
    sleep 5   # the pane closes on exit; give the message a moment to be read
    exit 97
  fi
fi

uid="${AF_UID:-1000}" gid="${AF_GID:-1000}"
if [[ "$(id -u)" == "0" && "$uid" != "0" ]]; then
  # --init-groups needs a passwd entry for the uid; arbitrary host uids
  # (macOS 501, multi-user boxes) have none in this image.
  groups_flag="--clear-groups"
  getent passwd "$uid" >/dev/null 2>&1 && groups_flag="--init-groups"
  # Bounding set cleared too: the image ships setuid su, and a retained
  # CAP_NET_ADMIN would let a root re-entry flush the firewall from inside.
  exec setpriv --reuid "$uid" --regid "$gid" "$groups_flag" \
       --inh-caps=-all --bounding-set -all "$@"
fi
exec "$@"
