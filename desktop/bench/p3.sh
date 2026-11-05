#!/usr/bin/env bash
# p3.sh [secs] [binary] — six 100x30 panes repainting agent-like output (26
# coloured lines at 30 fps in synchronized updates) on a scratch tmux server,
# tiled in one Fleet Desktop window that prints its frame timing at the end.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secs="${1:-20}"
bin="${2:-$here/../target/debug/fleet-desktop}"
sock="fleet-p3-$$"
tx() { tmux -L "$sock" -f /dev/null "$@"; }
trap 'tx kill-server 2>/dev/null || true' EXIT

storm="python3 $here/storm.py storm 26 30 $((secs + 20))"
tx new-session -d -s storm -x 100 -y 30 "$storm" \; set -g default-size 100x30
for _ in 1 2 3 4 5; do tx new-window -d -t storm: "$storm"; done
# shellcheck disable=SC2046 # one argument per pane id
AGENT_FLEET_SOCKET="$sock" FLEET_DESKTOP_STATS="$secs" "$bin" $(tx list-panes -s -t storm -F '#{pane_id}')
