---
feature: cli-switch-snappiness
phase: test
status: draft
date: 2026-11-05
---

# CLI switch snappiness — Test plan & results

## Scope
US-1 to US-6 and the no-resize probe, D6 guard, fork budget, bash 3.2 case. Closest existing suites reused: `tests/t-mouse.sh` (same-server client harness), `tests/t-focus.sh` (stub + trace shape), `tests/t-task.sh` (task-record idiom).

## Test plan
| ID | Acceptance criterion / risk | Level | Approach | Automated |
|----|-----------------------------|-------|----------|-----------|
| T-1 | US-1 AC-1, AC-2, AC-3, AC-4 | scenario (cli) | S-1: attach, 20-switch probe, window-size unset, rails 30 | yes |
| T-2 | US-1 AC-5 (fork budget) | unit | t-presize.sh: 20 windows, wrapper log <= 2 calls (WI-1) | yes |
| T-3 | US-1 AC-6, AC-7 | scenario (cli) | S-1: hooks present, show-hooks identical after re-source | yes |
| T-4 | US-1 AC-8 (D6) | unit + scenario | t-presize.sh: largest -> nothing resized, default-size untouched; S-1 resize count 0 | yes |
| T-5 | US-2 AC-1, AC-2 | scenario (cli) | S-1: resize, 10-resize burst, no presize.sh left | yes |
| T-6 | US-2 AC-3 (stale token) | unit | t-presize.sh (WI-2) | yes |
| T-7 | D4 burst/3-pass cap | unit | 10 concurrent runs -> one write; moving client -> 2 passes; never settles -> 3 | yes |
| T-8 | US-3 AC-1..AC-3, US-4 AC-1..AC-6 | scenario (cli) | S-2: t-presize-clients.sh | yes |
| T-9 | US-5 AC-1..AC-3 | scenario (cli) | S-3: t-goto-fast.sh (active pane checked as `#{pane_active}#{window_active}` == 11; scraped case timed with `EPOCHREALTIME`, < 1000 ms) | yes |
| T-10 | US-6 AC-1, AC-2 | unit | t-focus.sh: working-pane trace (WI-5, AC-1) and the existing done-ack and no-signal cases (AC-2), run by run-all | yes |
| T-11 | NFR bash 3.2 | unit | t-bash32.sh presize case (WI-6), on a bare server so the conf's own hook cannot do the resize in its place | written; **SKIPPED here** (NixOS has no `/bin/bash`). Runs for real only on CI's macOS job, whose `/bin/bash` is 3.2; Ubuntu's `/bin/bash` is 5. Unverified until that CI run. |
| T-12 | NFR checks (shellcheck) | static | shellcheck over bin, scripts, shims, tests, docker | yes |

## Scenario results
| ID | Seam | Spec | Result |
|----|------|------|--------|
| S-1 | cli | tests/t-presize.sh | pass |
| S-2 | cli | tests/t-presize-clients.sh | pass |
| S-3 | cli | tests/t-goto-fast.sh | pass |

## New/changed tests
- `tests/t-goto-fast.sh` (S-3, written in the implement wave): added a task record to the `done` case and a check that it gains exactly one `state idle` line (US-5 AC-2 had no coverage of the record).
- `tests/t-presize-clients.sh` (S-2): removed a leftover debug hook (`set-hook -ga client-resized` appending to a file under `/tmp`) that wrote outside the test's work dir.
- After the Test gate and review (orchestrator, 2026-11-05):
  - `tests/t-goto-fast.sh`: US-5 AC-1 now asserts the pane's window is active too (`#{pane_active}` alone was 1 for a single-pane window goto never selected); the scraped case asserts < 1000 ms with `EPOCHREALTIME` instead of integer `SECONDS` < 2.
  - `tests/t-presize-clients.sh`: US-4 AC-2 and AC-4 now truncate the resize log before the adds, check each back-to-back window's size as soon as its own `add` returns, and assert, once quiet, a resize count of 0 for every spawned window (w1, the three back-to-back windows, s4's window).
  - `tests/t-presize.sh`: `client()` no longer runs in a command substitution, so its socket lands in `CSOCKS` and is cleaned up; `nresized` matches whole lines (`grep -cx`); the 10 concurrent runs start behind a shared go file, so the "one write" assertion no longer depends on fork timing; reads are counted by `show -gqv window-size`; an `AGENT_FLEET_SIDENAV_WIDTH=24` run checks the rail override (US-1 AC-4); the never-settles case first knocks s2 off size so its first pass has work.
  - `tests/t-bash32.sh`: the presize case runs on a bare server and kills its client socket from the EXIT trap.

## Results
- Date: 2026-11-05
- Command: `cd /home/hyb175/Projects/agent-fleet && bash tests/run-all.sh && nix-shell -p shellcheck --run 'shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh'`
- Outcome (test phase): run-all exit 0, "all tests passed"; shellcheck exit 0, no output. No failures.
- Outcome (after the review fixes): shellcheck exit 0. Touched files: t-presize 30 pass / 0 fail, t-presize-clients 17 / 0, t-goto-fast 15 / 0, t-focus 5 / 0, t-bash32 skipped (no `/bin/bash`). Full run-all: see the closing note below.

## Gaps
- NFR bash 3.2 (T-11): not executed on this host; see T-11. Covered by CI's macOS job after merge.
- US-1 AC-8 (`largest` on attach) is exercised by a direct run and by a hook-driven resize, not by a hook-driven attach. Both hooks call the same script, whose D6 guard is the first thing it checks, so the attach path adds nothing the resize path does not already prove.
- Speed p50 (56 -> 40 ms) is recorded by the speed-recording step, not gated here.
- `settled()` matches any `presize.sh` process from this checkout, including a live fleet's; on a dev machine a concurrent live resize can only delay a quiet check, not fail one.
- Per-session `status` overrides (D1) are untested by design (ponytail ceiling).

## UI validation
Not applicable: the plan has no seam:ui scenarios (all are seam:cli); no browser UI.
