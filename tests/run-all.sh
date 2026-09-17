#!/usr/bin/env bash
# run-all.sh — run the agent-fleet integration suite.
#
# Every test runs on its own throwaway tmux socket and private XDG cache — the
# suite never touches a real fleet. Each tests/t-*.sh is also standalone.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=()
for t in "$HERE"/t-*.sh; do
  if ! bash "$t"; then failed+=("$(basename "$t")"); fi
  echo
done

# The rail has two renderers during the transition (scripts/rail-launch.sh).
# Run the rail-facing tests again with the Go one when the binary is built.
if [[ -x "$HERE/../bin/afui" ]]; then
  for t in t-highlight t-reap t-borders t-snapshot; do
    echo "[AGENT_FLEET_UI=go]"
    if ! AGENT_FLEET_UI=go bash "$HERE/$t.sh"; then failed+=("$t.sh (go)"); fi
    echo
  done
fi

if (( ${#failed[@]} )); then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all tests passed"
