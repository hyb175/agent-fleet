---
feature: github-actions-ci
phase: implementation
date: 2026-08-04
---

# Implementation log — github-actions-ci

## 2026-08-04 — item 1: lint-clean the scoped shell files

- Implementer agent made `shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh` exit 0 from an 85-finding baseline.
- `.shellcheckrc` (new): global disables SC1090/SC1091 only (source-path resolution, not a bug class).
- ~44 real fixes: quoting (`exit "$FAIL"` ×16, eval-string paths, `${key#*"$US"}`), unused read-fields → `_`, `read -r`, SC2155 export splits in tests/lib.sh, `MAPFILE`→`MAP_FILE` rename in sidenav.sh (builtin-name collision; on-disk map path unchanged), snapshotd.sh `\033\\` → `\033\134` (byte-identical).
- 20 per-line justified disables (SC2015 temp-swap idioms, eval-only-read test vars, SC2329 eval-called helpers, one SC2031). None touch SC2086.
- Fixer's t-shim "hang" was flake-devShell-only (bash's store dir lacks coreutils on the harness's restricted PATH); passes in the system environment — pre-existing environment gap, out of scope here.

## 2026-08-04 — item 2: workflow + badge

- `.github/workflows/ci.yml`: `test` matrix [ubuntu-latest, macos-latest], fail-fast off, 15-min timeout, `permissions: contents: read`, superseded-run cancellation; deps tmux/fzf/fish/zoxide (+ brew bash on mac, prepended via `$GITHUB_PATH`, asserted `BASH_VERSINFO≥4`); runs `bash tests/run-all.sh`. `shellcheck` job on ubuntu over the scoped set. README badge added.
- actionlint clean.

## 2026-08-04 — review fixes

- Added zoxide to both runner install lists (reviewer minor: t-connect silently self-skipped without it).
- Blessed `read -r` on the picker's name prompt with a comment (reviewer minor: only lint fix that changed behavior; new semantics intended).

## Verification (system environment, NixOS)

- `shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh` → exit 0.
- `actionlint` → clean.
- `bash tests/run-all.sh` → all tests passed (t-shim included).
- Matrix legs prove themselves on first push (can't run GitHub runners locally).
