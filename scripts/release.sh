#!/usr/bin/env bash
# release.sh — cut a release so the version var and the git tag never drift
# (agent-fleet upgrade compares AGENT_FLEET_VERSION against the newest vX.Y.Z
# tag, so they must move together).
#
# Usage: scripts/release.sh <version>     e.g. scripts/release.sh 0.2.0
#
# Bumps AGENT_FLEET_VERSION in bin/agent-fleet and version in flake.nix, commits
# "release: vX.Y.Z", and tags it. Never pushes — prints the push command.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ver="${1:?usage: release.sh <version>  (e.g. 0.2.0)}"
ver="${ver#v}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be X.Y.Z" >&2; exit 2; }

[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean — commit or stash first" >&2; exit 1; }
br="$(git branch --show-current)"
[[ "$br" == master ]] || { echo "error: not on master (on '$br')" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$ver" >/dev/null 2>&1 && { echo "error: tag v$ver already exists" >&2; exit 1; }

# BSD/GNU-portable in-place edit (macOS sed needs the backup suffix).
sed -i.bak -E "s/^AGENT_FLEET_VERSION=\"[^\"]*\"/AGENT_FLEET_VERSION=\"$ver\"/" bin/agent-fleet && rm -f bin/agent-fleet.bak
sed -i.bak -E "s/version = \"[0-9]+\.[0-9]+\.[0-9]+\";/version = \"$ver\";/"        flake.nix       && rm -f flake.nix.bak

# Sanity: the bump actually landed.
grep -q "AGENT_FLEET_VERSION=\"$ver\"" bin/agent-fleet || { echo "error: version bump did not apply to bin/agent-fleet" >&2; exit 1; }

git add bin/agent-fleet flake.nix
git commit -q -m "release: v$ver"
git tag "v$ver"

echo "committed + tagged v$ver."
echo "push with:  git push && git push origin v$ver"
