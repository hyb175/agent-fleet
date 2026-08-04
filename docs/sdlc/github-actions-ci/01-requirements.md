---
feature: github-actions-ci
phase: requirements
status: approved
date: 2026-08-04
---

# GitHub Actions CI — Requirements

## Upstream context
No discovery track. Intake: `docs/sdlc/github-actions-ci/00-intake.md` (motivation, check command, macOS bash constraint, runtime budget). This is item 1 of the 4-item hardening plan recorded there; items 2–4 are separate cycles.

## Problem
Three consecutive pulls landed with broken tests (t-shim twice on NixOS, t-upgrade at the v0.2.0 bump), each caught post-pull on a dev machine. The repo has a CI-ready suite — `bash tests/run-all.sh`, 17 `tests/t-*.sh` files, each on a throwaway tmux socket (`af-test-$$`) with private `XDG_CACHE_HOME`/`XDG_CONFIG_HOME` and fake `$HOME`s where needed (tests/lib.sh:11-19; t-kimi, t-codex, t-persist); t-upgrade stubs the network via `AGENT_FLEET_TAGS_URL`/`AGENT_FLEET_TARBALL` `file://` URLs — but nothing runs it before merge. Shell bug classes from recent history (unquoted expansion, `set -e` on bare `[[ ]] &&` tails, SIGPIPE under pipefail) have no mechanical gate; the repo has never been shellcheck'd (only 3 `# shellcheck source=` directives exist, no `.shellcheckrc`).

## Goals
- Every PR against master and every push to master gets a pass/fail verdict for `bash tests/run-all.sh` on ubuntu-latest and macos-latest, plus a shellcheck verdict, before merge. The three motivating incident classes would each have produced a red check.
- A failing run's job log shows which `t-*.sh` failed and its per-`check` FAIL lines without downloading anything.
- Typical full run (all jobs) completes in ≤ 10 minutes wall clock; suite is 1–2 min locally.
- Workflow uses zero repository secrets.

## Non-goals / out of scope
- Release automation (scripts/release.sh, tagging, tarball publishing) — untouched.
- Test coverage measurement of any kind.
- NixOS runner or `nix build`/flake check job (flake.nix exists; explicitly deferred).
- Windows.
- Enabling branch protection / required checks — repo settings, not workflow files (see Assumptions A1).
- Bulk shellcheck cleanup of the existing tree beyond what the chosen gate requires to be green at introduction (see US-3); a full-strictness cleanup is its own future change.
- Shellcheck coverage of `install.sh` and `conf/themes/*.sh` (installer and sourced palette data; add later if wanted).
- Dependency caching (apt/brew) — not required at this suite size; design may add it only if it costs nothing.
- Scheduled (cron) runs, artifact uploads, flake-retry automation.

## Users & scenarios
### PR author (human or agent-driven)
- Covered by US-1, US-3.
### Maintainer (pulls onto NixOS and macOS dev machines; merges PRs)
- Covered by US-2, US-4. The two-OS matrix exists because both OS families are real pull targets (README.md:40: "Developed on macOS; Linux works … less battle-tested").

## User stories

### US-1: Integration suite runs on every PR, both OSes
As a PR author, I want the full suite to run on Linux and macOS when I open or update a PR, so that broken tests surface before merge instead of after pulls on dev machines.

**Acceptance criteria**
- Given a PR targeting master, when it is opened or a new commit is pushed to it, then a workflow run starts containing a test job for each of `ubuntu-latest` and `macos-latest` and a shellcheck job.
- Given either test job, when the suite step runs, then it executes `bash tests/run-all.sh` from the repo root and the job fails iff the script exits non-zero (run-all.sh already continues past failures and exits 1 with a `FAILED: <files>` summary — tests/run-all.sh:15-18).
- Given a test job, when the suite step starts, then `tmux` and `fzf` resolve on `PATH` (installed by a prior step if the runner image lacks them) and their versions have been printed to the job log.
- Given the macos-latest test job, when the suite step starts, then `bash` resolved via `PATH` reports major version ≥ 4, verified by a step that fails the job otherwise (macOS ships 3.2 at `/bin/bash`; `declare -A` is required by scripts/pick.sh:73, scripts/persist-restore.sh:63-65, scripts/snapshotd.sh:71).
- Given a suite failure in any `t-*.sh`, when the job completes, then the job log contains that test's `FAIL:` check lines and the final `FAILED: <files>` summary — no artifact download needed.
- Given one matrix leg fails, when the run completes, then the other leg still reports its own result (no fail-fast cancellation between OSes).

### US-2: Same gate on push to master
As a maintainer, I want the identical jobs to run on every push to master, so that direct pushes are covered and the badge reflects master's real state.

**Acceptance criteria**
- Given a push to master, when the workflow triggers, then the same job set as US-1 runs against the pushed commit.
- Given the workflow file, when inspected, then push triggers are restricted to master (no runs on other branch pushes).

### US-3: Shellcheck gate over all shell sources
As a maintainer, I want shellcheck to run over `bin/agent-fleet`, `scripts/*.sh`, `shims/*`, and `tests/*.sh`, so that the recurring bug classes (quoting, `set -e` tails, pipefail) are caught mechanically at the PR boundary.

**Acceptance criteria**
- Given the shellcheck job, when it runs, then it checks exactly: `bin/agent-fleet`, `scripts/*.sh` (21 files), `shims/*` (1 file), `tests/*.sh` (19 files incl. lib.sh and run-all.sh) — ~42 files total — and fails on findings at or above the configured gate.
- Given the commit that introduces the workflow, when the shellcheck job runs on it, then it passes. The repo has never been shellcheck'd, so design must reconcile the current tree (severity threshold, `.shellcheckrc` excludes, targeted inline disables, or fixes) — the exact mix is a design decision, but CI must not be born red.
- Given the chosen configuration, when a change introduces an unquoted variable expansion (SC2086 class), then the job fails — quoting checks may not be excluded wholesale, since quoting is a named motivating bug class (SC2086 is info-severity, so a bare `--severity=error` gate does not satisfy this).
- Given the shellcheck job, when the workflow runs, then it executes once (single OS), not per matrix leg — findings are OS-independent.

### US-4: Status badge (trivial, in scope)
As a maintainer, I want a CI badge in the README, so master's state is visible at a glance.

**Acceptance criteria**
- Given the README, when viewed after the feature lands, then it shows a workflow status badge near the title linking to the workflow's runs for master.

## Non-functional requirements
- **Runtime budget:** each job carries an explicit `timeout-minutes` ≤ 15 so a hung tmux test fails within budget instead of consuming the 6-hour default (the suite polls with sleeps but has no per-test timeout — e.g. tests/t-shim.sh:92-95). Typical end-to-end run ≤ 10 min.
- **Concurrency:** superseded runs for the same PR/ref are cancelled (budget hygiene; intake says "CI budget should stay small").
- **Security posture:** no `secrets.*` references; workflow `permissions` limited to `contents: read`. Tests never touch a real fleet (isolated sockets, intake Constraints).
- **Portability:** workflow steps must not assume GNU userland on macOS. Repo scripts already carry portable fallbacks (`stat -c %Y || stat -f %m` — scripts/status.sh:54; `sed -i.bak` — tests/t-upgrade.sh:20); CI must not regress this by, e.g., preferring GNU coreutils on the macOS runner beyond the required bash upgrade.
- **Job-name stability:** job names must be stable, human-readable identifiers so they can later be marked as required checks in branch protection without renaming churn.

## Dependencies & risks
- **Runner image drift** (tmux/fzf presence, macos-latest arch/OS bumps): mitigate by explicitly installing tmux and fzf regardless of image manifest and printing tool versions before the suite.
- **t-shim's end-to-end check without fish:** tests/t-shim.sh:84-85 pins `SHELL` to fish only when available; the degraded path depends on the runner login shell not rebuilding `PATH` (the exact NixOS failure class from the intake). If either runner flakes here, design should install fish (cheap on apt and brew) rather than modify the test.
- **Timing-sensitive tests on shared runners:** the suite uses fixed sleeps (e.g. `sleep 2`, 0.3 s polls); slower CI hardware may flake. Accepted risk for v1; recurring flakes feed the later hardening items, not this feature.
- **Shellcheck version drift** across runner images can change findings run-to-run: mitigate by running shellcheck on a single OS (US-3) and letting design pin the shellcheck version if drift bites.
- **t-upgrade curl `file://` fetches** (tests/t-upgrade.sh:39-49): requires the runner curl to allow the file protocol; stock runner curl does. Low risk.

## Assumptions
- **A1 — CI is advisory until branch protection is enabled.** The workflow cannot set repo settings; the maintainer must mark the jobs as required checks for the "block at the PR boundary" goal to fully hold. Blast radius: until then, red CI can still be merged — same exposure as today, minus visibility.
- **A2 — shellcheck gate strictness is a design decision** bounded by US-3 (green at introduction, SC2086 class must fire). Blast radius if too lax: the motivating quoting bugs pass CI; if too strict: legacy findings force either a noisy cleanup commit or blanket disables that rot.
- **A3 — fish is not a required CI dependency**; t-shim's documented degradation is trusted, and installing fish is the fallback if it proves flaky (see risk above). Blast radius: one intermittently failing check on one OS until the fallback is applied.
- **A4 — minimal harness/test edits are in scope only if a test is provably incompatible with stock runner images**, and any such edit must leave local behavior identical. Blast radius: without this escape hatch the feature can dead-end on an environment quirk; with it, risk of scope creep into test rewrites — reviewers should reject test-logic changes.
- **A5 — `pull_request` targets master only**; the repo has a single long-lived branch. Blast radius: none today.
- **A6 — public repo, standard hosted-runner minutes**; the macOS 10× minute multiplier (private repos) is irrelevant. Blast radius: if the repo goes private, the two-OS matrix cost jumps and the budget NFR needs revisiting.
- **A7 — one workflow file** under `.github/workflows/` covers both suite and shellcheck jobs; splitting is design freedom. Blast radius: none.

## Open questions
- [ ] Will the maintainer enable branch protection with these checks required once CI is green (A1)? — repo owner; outside this feature's deliverables but determines whether the goal is enforced or advisory.
