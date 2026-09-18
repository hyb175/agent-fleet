#!/usr/bin/env bash
# fetch-afui.sh <root> <ref>  — put the native UI binary at <root>/bin/afui.
# fetch-afui.sh probe <ref>   — say whether this machine can get one at all.
#
# Shared by install.sh (remote mode) and `agent-fleet upgrade`, so the two
# cannot disagree about where the binary comes from:
#   ref is a vX.Y.Z tag  -> download afui-<os>-<arch> from that GitHub release
#                           and verify it against the release's SHA256SUMS;
#                           a release with nothing for this platform falls
#                           through to
#   build from <root>/ui  -> when a Go toolchain is on PATH (a dev checkout, an
#                           install pinned to a branch, an unlisted platform)
# Exit codes: 0 installed · 3 no binary is possible here (nothing published for
# this platform and no Go) — the fleet has no rail, picker or inbox without
# one, so callers `probe` first and refuse up front · 1 a real failure
# (download error, checksum mismatch, build error; nothing is left behind).
#
# AGENT_FLEET_RELEASE_BASE overrides the release URL (tests point it at a
# file:// directory).

set -uo pipefail

mode=fetch root=""
if [[ "${1:-}" == probe ]]; then
  mode=probe; ref="${2:?usage: fetch-afui.sh probe <ref>}"
else
  root="${1:?usage: fetch-afui.sh <root> <ref>}"; ref="${2:?usage: fetch-afui.sh <root> <ref>}"
fi
base="${AGENT_FLEET_RELEASE_BASE:-https://github.com/hyb175/agent-fleet/releases/download}"
SUPPORTED="darwin/arm64 darwin/amd64 linux/arm64 linux/amd64"

say() { printf '%s\n' "$*"; }

# Platform -> asset name, the same names release.yml produces.
raw_os="$(uname -s 2>/dev/null)"; raw_arch="$(uname -m 2>/dev/null)"
os=""; arch=""
case "$raw_os" in Darwin) os=darwin ;; Linux) os=linux ;; esac
case "$raw_arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; esac
asset="afui-$os-$arch"

sha256() {  # <file> -> hex digest, portable
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

install_file() {  # <tmpfile>
  mkdir -p "$root/bin" || return 1
  chmod +x "$1" && mv -f "$1" "$root/bin/afui"
}

is_tag()  { [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
have_go() { command -v go >/dev/null 2>&1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The release's checksum for this platform's asset -> want. Returns 1 with
# `why` set when the release has nothing for us.
want=""; why=""
release_sum() {
  is_tag || { why="$ref is not a release"; return 1; }
  [[ -n "$os" && -n "$arch" ]] || { why="release $ref has no binary for $raw_os/$raw_arch"; return 1; }
  command -v curl >/dev/null 2>&1 || { why="curl is required to download the binary"; return 1; }
  if ! curl -fsSL --max-time 60 "$base/$ref/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
    why="release $ref publishes no binaries"; return 1
  fi
  want="$(awk -v a="$asset" '$2==a || $2=="*"a {print $1}' "$tmp/SHA256SUMS")"
  [[ -n "$want" ]] || { why="release $ref has no $asset"; return 1; }
  return 0
}

no_way() {  # nothing on this machine can produce the binary
  say "afui: $why and no Go toolchain is on PATH — the fleet has no rail, picker or inbox without bin/afui"
  say "  release binaries cover: $SUPPORTED · or install Go 1.24+ to build from source"
  exit 3
}

if [[ "$mode" == probe ]]; then
  if release_sum; then say "afui: release $ref has $asset"; exit 0; fi
  if have_go; then say "afui: $why — will build from source"; exit 0; fi
  no_way
fi

if release_sum; then
  if ! curl -fsSL --max-time 300 "$base/$ref/$asset" -o "$tmp/afui" 2>/dev/null; then
    say "afui: download of $asset failed" >&2
    exit 1
  fi
  got="$(sha256 "$tmp/afui")"
  if [[ "$got" != "$want" ]]; then
    say "afui: checksum mismatch for $asset (got $got, release says $want) — not installed" >&2
    exit 1
  fi
  install_file "$tmp/afui" || { say "afui: could not write $root/bin/afui" >&2; exit 1; }
  say "afui: installed $asset ($ref) → $root/bin/afui"
  exit 0
fi

if have_go; then
  [[ -f "$root/ui/go.mod" ]] || { say "afui: $why; $root/ui is missing, nothing to build"; exit 3; }
  ver="$(sed -n 's/^AGENT_FLEET_VERSION="\(.*\)"/\1/p' "$root/bin/agent-fleet" 2>/dev/null)"
  if (cd "$root/ui" && go build -trimpath -ldflags "-s -w -X main.version=${ver:-dev}" -o "$tmp/afui" ./cmd/afui) 2>"$tmp/err"; then
    install_file "$tmp/afui" || { say "afui: could not write $root/bin/afui" >&2; exit 1; }
    say "afui: $why — built from $root/ui → $root/bin/afui"
    exit 0
  fi
  say "afui: go build failed: $(head -1 "$tmp/err")" >&2
  exit 1
fi
no_way
