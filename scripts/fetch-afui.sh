#!/usr/bin/env bash
# fetch-afui.sh <root> <ref> — put the native UI binary at <root>/bin/afui.
#
# Shared by install.sh (remote mode) and `agent-fleet upgrade`, so the two
# cannot disagree about where the binary comes from:
#   ref is a vX.Y.Z tag  -> download afui-<os>-<arch> from that GitHub release
#                           and verify it against the release's SHA256SUMS
#   any other ref        -> build from <root>/ui when a Go toolchain is on PATH
#                           (a dev checkout, or an install pinned to a branch)
# Exit codes: 0 installed · 3 nothing to install here (no asset for this
# platform/ref, no Go) — the caller degrades to the bash renderers · 1 a real
# failure (download error, checksum mismatch; nothing is left behind).
#
# AGENT_FLEET_RELEASE_BASE overrides the release URL (tests point it at a
# file:// directory).

set -uo pipefail

root="${1:?usage: fetch-afui.sh <root> <ref>}"
ref="${2:?usage: fetch-afui.sh <root> <ref>}"
base="${AGENT_FLEET_RELEASE_BASE:-https://github.com/hyb175/agent-fleet/releases/download}"
dest="$root/bin/afui"

say() { printf '%s\n' "$*"; }

# Platform -> asset name, the same names release.yml produces.
os="$(uname -s 2>/dev/null)"; arch="$(uname -m 2>/dev/null)"
case "$os" in Darwin) os=darwin ;; Linux) os=linux ;; *) os="" ;; esac
case "$arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) arch="" ;; esac

sha256() {  # <file> -> hex digest, portable
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

install_file() {  # <tmpfile>
  mkdir -p "$root/bin" || return 1
  chmod +x "$1" && mv -f "$1" "$dest"
}

if [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  if [[ -z "$os" || -z "$arch" ]]; then
    say "afui: no release binary for $(uname -s)/$(uname -m) — bash renderers stay active"
    exit 3
  fi
  command -v curl >/dev/null 2>&1 || { say "afui: curl is required to download the binary"; exit 3; }
  asset="afui-$os-$arch"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if ! curl -fsSL --max-time 60 "$base/$ref/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
    say "afui: release $ref publishes no binaries — bash renderers stay active"
    exit 3
  fi
  want="$(awk -v a="$asset" '$2==a || $2=="*"a {print $1}' "$tmp/SHA256SUMS")"
  if [[ -z "$want" ]]; then
    say "afui: release $ref has no $asset — bash renderers stay active"
    exit 3
  fi
  if ! curl -fsSL --max-time 300 "$base/$ref/$asset" -o "$tmp/afui" 2>/dev/null; then
    say "afui: download of $asset failed" >&2
    exit 1
  fi
  got="$(sha256 "$tmp/afui")"
  if [[ "$got" != "$want" ]]; then
    say "afui: checksum mismatch for $asset (got $got, release says $want) — not installed" >&2
    exit 1
  fi
  install_file "$tmp/afui" || { say "afui: could not write $dest" >&2; exit 1; }
  say "afui: installed $asset ($ref) → $dest"
  exit 0
fi

# Not a release: build from source when we can.
if [[ -f "$root/ui/go.mod" ]] && command -v go >/dev/null 2>&1; then
  ver="$(sed -n 's/^AGENT_FLEET_VERSION="\(.*\)"/\1/p' "$root/bin/agent-fleet" 2>/dev/null)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if (cd "$root/ui" && go build -trimpath -ldflags "-s -w -X main.version=${ver:-dev}" -o "$tmp/afui" ./cmd/afui) 2>"$tmp/err"; then
    install_file "$tmp/afui" || { say "afui: could not write $dest" >&2; exit 1; }
    say "afui: built from $root/ui → $dest"
    exit 0
  fi
  say "afui: go build failed: $(head -1 "$tmp/err")" >&2
  exit 1
fi
say "afui: $ref is not a release and no Go toolchain is on PATH — bash renderers stay active (make ui, or install a tagged release)"
exit 3
