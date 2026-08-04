# Intake — github-actions-ci

- **Date:** 2026-08-04
- **Mode:** gated
- **Outcome:** complete 2026-08-04 — committed `1637455`; reviewer verdict ship, two minors fixed; matrix legs validate on first push
- **Request (verbatim):** Add GitHub Actions CI for agent-fleet: run the full integration suite (tests/run-all.sh) on a matrix of ubuntu-latest and macos-latest (tmux + fzf installed; bash ≥4 via brew on macOS since the rail needs associative arrays), plus a shellcheck job over bin/ and scripts/. Goal: catch broken tests and shell bug classes (quoting, set -e, pipefail) at the PR boundary instead of after pulls on dev machines. The repo is a bash project with tmux-integration tests that run on throwaway sockets and private XDG dirs, already CI-friendly.

## Context from the conversation

- Motivation: three consecutive pulls arrived with broken tests (t-shim twice on NixOS, t-upgrade at the v0.2.0 release bump) — all caught post-pull on dev machines, none pre-merge.
- Project check command: `bash tests/run-all.sh` (17 t-*.sh files, each on a throwaway tmux socket with private XDG cache/config dirs).
- Repo is bash-first; recent bug classes worth mechanical gating: UTF-8 glyph folded into variable name, `set -e` on bare `[[ ]] &&` tails, SIGPIPE under pipefail, tmux quoting layers.
- macOS ships bash 3.2; the rail requires bash ≥ 4 (associative arrays) — CI's macos job must install newer bash via brew and ensure it wins on PATH.
- This is item 1 of a 4-item hardening plan (CI, bash-containment, scrape-tier fixtures, UX leftovers); later items enter their own cycles.

## Constraints

- No repo secrets required; tests never touch a real fleet (isolated sockets).
- Suite runtime locally ≈ 1–2 min; CI budget should stay small.

## Collapsed design + plan (gate 1: user approved PRD and chose to skip phases 2–3 ceremony)

Design, decided 2026-08-04: one workflow `.github/workflows/ci.yml` — `test` job on matrix
`[ubuntu-latest, macos-latest]` (fail-fast off, timeout 15 min, `permissions: contents: read`,
concurrency-cancel superseded runs) installing tmux+fzf+fish (fish keeps t-shim's end-to-end
check meaningful; apt on ubuntu, brew on mac + brew bash≥4 prepended via `$GITHUB_PATH`),
then `bash tests/run-all.sh`; separate `shellcheck` job (ubuntu, preinstalled shellcheck) over
`bin/agent-fleet scripts/*.sh shims/* tests/*.sh`. Baseline survey found 85 findings in scope;
policy: `.shellcheckrc` disables only the source-following notices (SC1090/SC1091 — path
resolution, not a bug class), everything else fixed or carries a per-line justified disable;
SC2086 stays enabled per PRD. README gets the badge. Local verification: shellcheck green,
actionlint green (via nix-shell), full suite green; the matrix legs prove themselves on first
push. Work items: (1) lint-clean the scoped files, (2) workflow + shellcheckrc + badge —
disjoint files, run in parallel. Route: review = correctness on the full diff (one reviewer
floor); test phase = the local verification above (no separate cycle — CI is itself the test
infrastructure); release notes: skipped, internal-only change.
