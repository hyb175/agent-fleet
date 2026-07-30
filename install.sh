#!/usr/bin/env bash
# install.sh — install the agent-fleet CLI, two ways, one script:
#
#   Remote (no clone needed):
#     curl -fsSL https://raw.githubusercontent.com/hyb175/agent-fleet/master/install.sh | bash
#   Local (from a checkout):
#     ./install.sh
#
# Remote mode downloads the source tarball to $XDG_DATA_HOME/agent-fleet and
# symlinks the CLI into your PATH. Local mode symlinks straight from the
# checkout (edits are live — the dev setup). Either way the CLI resolves its
# own root via the symlink, so scripts/ and conf/ are found automatically.
#
# Env knobs:
#   PREFIX=/usr/local           install the symlink under <PREFIX>/bin (default: ~/.local)
#   AGENT_FLEET_REF=v0.1.0      pin a tag/branch/sha to fetch (remote mode; default: master)
#   AGENT_FLEET_UNINSTALL=1     remove the symlink (and the managed data dir)

set -euo pipefail

REPO="hyb175/agent-fleet"
REF="${AGENT_FLEET_REF:-master}"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/agent-fleet"

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- uninstall -------------------------------------------------------------
if [[ "${AGENT_FLEET_UNINSTALL:-}" == 1 ]]; then
  # Prefer the CLI's own uninstall (it also stops the fleet + clears the state
  # cache, and refuses to delete a dev checkout). Fall back to a basic removal
  # if the CLI isn't on PATH.
  if command -v agent-fleet >/dev/null 2>&1; then
    exec agent-fleet uninstall -y
  fi
  link="$BIN_DIR/agent-fleet"
  [[ -L "$link" ]] && { rm -f "$link"; say "removed: $link"; }
  # Only remove the data dir we manage (remote installs). A dev checkout is
  # never inside DATA_DIR, so this can't delete someone's working tree.
  [[ -d "$DATA_DIR" ]] && { rm -rf "$DATA_DIR"; say "removed: $DATA_DIR"; }
  say "uninstalled. (per-agent status cache under \$XDG_CACHE_HOME/agent-fleet left intact)"
  exit 0
fi

# --- resolve the source tree (local checkout vs remote download) -----------
# Local mode iff this script sits next to a bin/agent-fleet (a real checkout).
# Piped through `curl | bash`, BASH_SOURCE is not a readable file -> remote.
ROOT_DIR=""
MODE="remote"
self="${BASH_SOURCE[0]:-}"
if [[ -n "$self" && -f "$self" ]]; then
  d="$(cd "$(dirname "$self")" && pwd)"
  if [[ -f "$d/bin/agent-fleet" ]]; then ROOT_DIR="$d"; MODE="local"; fi
fi

if [[ "$MODE" == remote ]]; then
  command -v curl >/dev/null 2>&1 || die "curl is required for the remote install"
  command -v tar  >/dev/null 2>&1 || die "tar is required for the remote install"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  url="https://codeload.github.com/$REPO/tar.gz/$REF"
  say "downloading $REPO@$REF …"
  curl -fsSL "$url" | tar -xzf - -C "$tmp" || die "download/extract failed from $url"
  src="$(find "$tmp" -maxdepth 1 -type d -name 'agent-fleet-*' | head -1)"
  [[ -n "$src" && -f "$src/bin/agent-fleet" ]] || die "tarball did not contain bin/agent-fleet"
  # Atomic swap so a re-run (update) never leaves a half-written tree in place.
  mkdir -p "$(dirname "$DATA_DIR")"
  rm -rf "$DATA_DIR.new"
  mv "$src" "$DATA_DIR.new"
  rm -rf "$DATA_DIR"
  mv "$DATA_DIR.new" "$DATA_DIR"
  ROOT_DIR="$DATA_DIR"
  # Make the extracted tree runnable (tarballs usually preserve git's exec bits,
  # but don't count on it). Only in remote mode: a local checkout already carries
  # the tracked bits, and chmod-ing it would churn the working tree (e.g. flip
  # the sourced-only theme.sh to +x).
  chmod +x "$ROOT_DIR/bin/agent-fleet" "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/shims/* 2>/dev/null || true
  say "installed tree: $DATA_DIR"
else
  say "using local checkout: $ROOT_DIR"
fi

# --- link the CLI ----------------------------------------------------------
mkdir -p "$BIN_DIR"
ln -sf "$ROOT_DIR/bin/agent-fleet" "$BIN_DIR/agent-fleet"
say "linked: $BIN_DIR/agent-fleet → $ROOT_DIR/bin/agent-fleet"

# Live-status cache. Status hooks are fleet-scoped (applied per-agent via
# `claude --settings`), so your global ~/.claude/settings.json is untouched.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"
mkdir -p "$CACHE_DIR/panes"
say "provisioned: $CACHE_DIR/panes (per-agent status cache)"

# --- dependency check (non-fatal) ------------------------------------------
command -v tmux >/dev/null 2>&1 \
  && say "found: tmux ($(tmux -V))" \
  || say "MISSING (required): tmux — need 3.2+ for display-popup (the picker)"
command -v fzf >/dev/null 2>&1 \
  || say "MISSING (required): fzf — powers the picker popup"
# bash 4+ is required (the sidenav uses associative arrays); macOS ships 3.2.
bv="$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
[ "${bv:-0}" -ge 4 ] 2>/dev/null \
  || say "MISSING (required): bash 4+ — 'env bash' resolves to $bv.x; brew install bash and put it before /bin/bash on PATH"
for dep in claude zoxide git; do
  command -v "$dep" >/dev/null 2>&1 \
    || say "optional: '$dep' not found — claude=default agent, zoxide=picker connect view, git=branch labels"
done

if ! command -v agent-fleet >/dev/null 2>&1; then
  say ""
  say "note: $BIN_DIR is not on your PATH yet. Add this to your shell rc:"
  say "  export PATH=\"$BIN_DIR:\$PATH\""
fi

say ""
say "next steps:"
say "  agent-fleet attach                 # boot + attach (creates a 'home' workspace)"
say "  Prefix o                           # open the picker; Tab → connect a repo"
say "  agent-fleet add                    # add a claude agent to the current workspace"
