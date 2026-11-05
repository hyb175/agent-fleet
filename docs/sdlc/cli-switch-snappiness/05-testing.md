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
| T-9 | US-5 AC-1..AC-3, US-6 AC-2 | scenario (cli) | S-3: t-goto-fast.sh | yes |
| T-10 | US-6 AC-1 | unit | t-focus.sh working-pane trace (WI-5) | yes |
| T-11 | NFR bash 3.2 | unit | t-bash32.sh presize case (WI-6) | yes |
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
- `tests/t-presize.sh`, `tests/t-focus.sh`, `tests/t-bash32.sh`: audited, unchanged.
- Not re-tested: the audit found every criterion mapped; no other holes.

## Results
- Date: 2026-11-05
- Command: `cd /home/hyb175/Projects/agent-fleet && bash tests/run-all.sh && nix-shell -p shellcheck --run 'shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh'`
- Outcome: run-all exit 0, "all tests passed"; shellcheck exit 0, no output. No failures.

## Gaps
- US-5 AC-3 "under 1 s": the test compares `$SECONDS` deltas, so it asserts `< 2` (integer seconds) against a 2 s capture-pane stub. A foreground ack would take >= 2 s and fail; a 1-2 s regression would pass. Acceptable.
- Speed p50 (56 -> 40 ms) is recorded by the speed-recording step, not gated here.
- Per-session `status` overrides (D1) are untested by design (ponytail ceiling).

## UI validation
Not applicable: the plan has no seam:ui scenarios (all are seam:cli); no browser UI.
