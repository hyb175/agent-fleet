---
feature: github-actions-ci
phase: review
status: approved
date: 2026-08-04
---

# Review — github-actions-ci

## Route (collapsed cycle — user-approved at gate 1)

- Design/plan collapsed into 00-intake.md.
- Test phase: local verification only (shellcheck, actionlint, full suite) — CI is itself the test infrastructure; matrix legs validate on first push. Not a passed dedicated test phase.
- Review: correctness, one reviewer over the full diff (the floor). Security/maintainability/tests dimensions not separately reviewed — change is CI config + mechanical lint fixes, no new trust boundaries.
- Release notes: skipped, internal-only.

## Reviewer verdict: ship (no blockers/majors)

High-risk classes traced clean: all `_` renames checked for surviving uses; `MAPFILE→MAP_FILE` complete with on-disk path untouched (sidenav-click.sh unaffected); `\033\134` byte-identical; `${key#*"$US"}` semantics identical; macOS bash resolution via `$GITHUB_PATH` correct; badge URL correct; `.shellcheckrc` scope correct; SC2086 never disabled.

## Findings

| # | Sev | Finding | Outcome |
|---|-----|---------|---------|
| 1 | minor | `read -r` on picker name prompt is a behavior change (backslashes now literal) | Accepted as intended; blessed with comment (pick.sh) |
| 2 | minor | zoxide missing on runners — t-connect silently self-skips in CI | Fixed: zoxide added to both install lists |
| 3 | nit | Local shellcheck 0.11.0 vs runner 0.10.0 — first-run delta possible | Accepted; PRD defers pinning, all referenced SCs exist in 0.10.0 |

## Post-fix verification

shellcheck exit 0, actionlint clean, full suite green after both fixes.
