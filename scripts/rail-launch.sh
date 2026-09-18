#!/usr/bin/env bash
# rail-launch.sh — the rail's start command (sidenav-toggle, persist-restore).
# Renderer selection lives in ui-launch.sh; this stays as the stable name the
# launchers and t-persist know.
set -u
exec "${AGENT_FLEET_ROOT:?AGENT_FLEET_ROOT not set}/scripts/ui-launch.sh" rail
