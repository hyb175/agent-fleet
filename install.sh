#!/usr/bin/env bash
# install.sh — symlink the agent-fleet CLI into your PATH.
#
# Usage:
#   ./install.sh                     # symlink into $HOME/.local/bin
#   PREFIX=/usr/local ./install.sh   # symlink into /usr/local/bin

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

mkdir -p "$BIN_DIR"
# Ensure everything is executable (snapshotd is launched directly via its shebang).
chmod +x "$ROOT_DIR/bin/agent-fleet" "$ROOT_DIR"/scripts/*.sh 2>/dev/null || true
ln -sf "$ROOT_DIR/bin/agent-fleet" "$BIN_DIR/agent-fleet"
echo "linked: $BIN_DIR/agent-fleet → $ROOT_DIR/bin/agent-fleet"

# Live-status cache. Status hooks are fleet-scoped: they're applied per-agent
# via `claude --settings`, so your global ~/.claude/settings.json is NOT touched.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
mkdir -p "$CACHE_DIR/panes"
echo "provisioned: $CACHE_DIR/panes (per-agent status cache)"

# Dependency check (non-fatal). Required vs optional are reported differently.
command -v tmux >/dev/null 2>&1 \
  && echo "found: tmux ($(tmux -V))" \
  || echo "MISSING (required): tmux — need 3.2+ for display-popup (the picker)"
command -v fzf >/dev/null 2>&1 \
  || echo "MISSING (required): fzf — powers the picker popup"
# bash 4+ is required (the sidenav uses associative arrays); macOS ships 3.2.
bv="$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
[ "${bv:-0}" -ge 4 ] 2>/dev/null \
  || echo "MISSING (required): bash 4+ — 'env bash' resolves to $bv.x; brew install bash and put it before /bin/bash on PATH"
for dep in claude zoxide git; do
  command -v "$dep" >/dev/null 2>&1 \
    || echo "optional: '$dep' not found — claude=default agent, zoxide=picker connect view, git=branch labels"
done

if ! command -v agent-fleet >/dev/null 2>&1; then
  echo
  echo "note: $BIN_DIR is not on your PATH yet. Add this to your shell rc:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

echo
echo "next steps:"
echo "  agent-fleet attach                 # boot + attach (creates a 'home' workspace)"
echo "  Prefix o                           # open the picker; Tab → connect a repo"
echo "  agent-fleet add                    # add a claude agent to the current workspace"
