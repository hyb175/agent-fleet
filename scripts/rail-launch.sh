#!/usr/bin/env bash
# rail-launch.sh — the rail's start command (sidenav-toggle, persist-restore).
# The stable name the launchers and t-persist know; ui-launch.sh handles a
# missing binary.
set -u
exec "${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}/scripts/ui-launch.sh" rail
