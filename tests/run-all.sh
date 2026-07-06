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

if (( ${#failed[@]} )); then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all tests passed"
