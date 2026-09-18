#!/usr/bin/env bash
# t-fetch-afui.sh — scripts/fetch-afui.sh, the binary path shared by
# install.sh and `agent-fleet upgrade`.
#   - a vX.Y.Z ref downloads afui-<os>-<arch> from the release base and
#     verifies it against SHA256SUMS; a bad checksum installs nothing (rc 1)
#   - a release with nothing for this platform, or a non-release ref, builds
#     from <root>/ui when Go is on PATH; without Go that is rc 3 naming the
#     supported targets
#   - `probe <ref>` answers the same question without touching a tree
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-fetch-afui:"
F="$REPO/scripts/fetch-afui.sh"
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in Darwin) os=darwin ;; Linux) os=linux ;; esac
case "$arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; esac
asset="afui-$os-$arch"
export AGENT_FLEET_RELEASE_BASE="file://$WORK/releases"

# A fake release: the "binary" is a script that prints a version.
REL="$WORK/releases/v9.9.9"; mkdir -p "$REL"
printf '#!/usr/bin/env bash\necho "afui 9.9.9"\n' > "$REL/$asset"
if command -v sha256sum >/dev/null 2>&1; then ( cd "$REL" && sha256sum "$asset" > SHA256SUMS )
else ( cd "$REL" && shasum -a 256 "$asset" > SHA256SUMS ); fi
ROOT="$WORK/root"; mkdir -p "$ROOT/bin"; printf 'AGENT_FLEET_VERSION="9.9.9"\n' > "$ROOT/bin/agent-fleet"

out="$(bash "$F" "$ROOT" v9.9.9 2>&1)"; rc=$?
check "release asset installs (rc=$rc)" "[[ $rc -eq 0 && -x '$ROOT/bin/afui' ]]"
check "installed binary runs" "[[ \"\$('$ROOT/bin/afui')\" == 'afui 9.9.9' ]]"
check "reports what it installed" "grep -q 'installed $asset (v9.9.9)' <<<\"\$out\""
out="$(AGENT_FLEET_ASSUME_NO_GO=1 bash "$F" probe v9.9.9 2>&1)"; rc=$?
check "probe: release with our asset is fine without Go (rc=$rc)" "[[ $rc -eq 0 ]] && grep -q 'has $asset' <<<\"\$out\""

# Corrupt the asset -> checksum mismatch -> nothing installed.
rm -f "$ROOT/bin/afui"; printf '#!/usr/bin/env bash\necho tampered\n' > "$REL/$asset"
out="$(bash "$F" "$ROOT" v9.9.9 2>&1)"; rc=$?
check "checksum mismatch refuses (rc=$rc)" "[[ $rc -eq 1 && ! -e '$ROOT/bin/afui' ]]"
check "…and says so" "grep -q 'checksum mismatch' <<<\"\$out\""

# A release with no asset for this platform: without Go nothing can be done.
mkdir -p "$WORK/releases/v9.9.8"; printf 'deadbeef  afui-plan9-mips\n' > "$WORK/releases/v9.9.8/SHA256SUMS"
out="$(AGENT_FLEET_ASSUME_NO_GO=1 bash "$F" "$ROOT" v9.9.8 2>&1)"; rc=$?
check "missing asset without Go is rc 3 (rc=$rc)" "[[ $rc -eq 3 && ! -e '$ROOT/bin/afui' ]]"
check "…naming the missing asset and the supported targets" "grep -q 'has no $asset' <<<\"\$out\" && grep -q 'darwin/arm64 darwin/amd64 linux/arm64 linux/amd64' <<<\"\$out\""
out="$(AGENT_FLEET_ASSUME_NO_GO=1 bash "$F" probe v9.9.8 2>&1)"; rc=$?
check "probe agrees (rc=$rc)" "[[ $rc -eq 3 ]] && grep -q 'has no $asset' <<<\"\$out\""

# A release that publishes nothing at all, same story.
out="$(AGENT_FLEET_ASSUME_NO_GO=1 bash "$F" "$ROOT" v0.0.1 2>&1)"; rc=$?
check "release without binaries, no Go: rc 3 (rc=$rc)" "[[ $rc -eq 3 ]] && grep -q 'publishes no binaries' <<<\"\$out\""

# Non-release ref, no Go on PATH.
out="$(AGENT_FLEET_ASSUME_NO_GO=1 bash "$F" "$ROOT" master 2>&1)"; rc=$?
check "branch ref without Go is rc 3 (rc=$rc)" "[[ $rc -eq 3 ]] && grep -q 'not a release and no Go' <<<\"\$out\""
out="$(AGENT_FLEET_ASSUME_NO_GO=1 bash "$F" probe master 2>&1)"; rc=$?
check "probe agrees on the branch ref (rc=$rc)" "[[ $rc -eq 3 ]]"

# With Go: a branch ref and a release with nothing for us both build from
# <root>/ui (the real module).
if command -v go >/dev/null 2>&1; then
  out="$(bash "$F" probe v9.9.8 2>&1)"; rc=$?
  check "probe: missing asset but Go present passes (rc=$rc)" "[[ $rc -eq 0 ]] && grep -q 'build from source' <<<\"\$out\""
  # shellcheck disable=SC2034 # read inside the eval'd check() conditions
  out="$(bash "$F" "$ROOT" v9.9.8 2>&1)"; rc=$?
  check "missing asset with Go but no ui/ is rc 3 (rc=$rc)" "[[ $rc -eq 3 ]] && grep -q 'nothing to build' <<<\"\$out\""
  cp -R "$REPO/ui" "$ROOT/ui"
  # shellcheck disable=SC2034 # read inside the eval'd check() condition
  out="$(bash "$F" "$ROOT" v9.9.8 2>&1)"; rc=$?
  check "missing asset with Go builds the binary (rc=$rc)" "[[ $rc -eq 0 && -x '$ROOT/bin/afui' ]] && grep -q 'built from' <<<\"\$out\""
  rm -f "$ROOT/bin/afui"
  bash "$F" "$ROOT" master >/dev/null 2>&1; rc=$?
  check "branch ref with Go builds the binary (rc=$rc)" "[[ $rc -eq 0 && -x '$ROOT/bin/afui' ]]"
  check "built binary carries the tree's version" "[[ \"\$('$ROOT/bin/afui' version)\" == 'afui 9.9.9' ]]"
else
  echo "  (no Go on PATH: build path not exercised)"
fi

exit "$FAIL"
