# Implementation log: cli-switch-snappiness

## 2026-11-05 — wave 1 (WI-1, WI-4, WI-5)

- WI-1: 8363c0c feat: presize.sh pre-sizes unviewed windows to the client's size in one pass
- WI-4: d7eea26 perf: goto forks status.sh only for done agents, acks scraped ones in the background
- WI-5: 5a6ab39 perf: focus-track forks status.sh only when the pane status reads done

Verification (system environment, NixOS), not passing yet:

- `bash tests/run-all.sh` → exit 1. Suite reports `FAILED: t-pick-go.sh`. Failing checks, verbatim: `FAIL: fleet view lists the agent by name, intent trailing`; `FAIL: row sits under the NEEDS YOU header with its workspace:index`. Other suites pass.
- `shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh` → exit 1. Findings: tests/t-goto-fast.sh:29 SC2034 (`out` unused); tests/t-goto-fast.sh:40 SC2034 (`start` unused); tests/t-presize.sh:11 SC2329 (`_cleanup` never invoked); tests/t-presize.sh:43 SC2329 (`wsize` never invoked); tests/t-presize.sh:68 SC2034 (`b` unused).

## 2026-11-05 — wave 1 (WI-2)

- WI-2: c57b708 feat: presize.sh debounces bursts by token and repeats the pass when the client size moved

Verification (run 2026-11-05, not committed):

- `bash tests/run-all.sh` → exit 0, `all tests passed`.
- `shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh` → exit 0, no findings.

## 2026-11-05 — wave 1 (WI-7)

- WI-7: 53f201d test: presize with two clients, a nested client and background spawns; hooks pass #{hook_client}

Verification (run 2026-11-05, not committed):

- `bash tests/run-all.sh` → exit 0, `all tests passed`.
- `shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh` → exit 1. Findings: tests/t-presize-clients.sh:35 SC2329 (`nresized` never invoked); tests/t-presize-clients.sh:37 SC2329 (`resizes_of` never invoked); tests/t-presize-clients.sh:41 SC2329 (`rails_ok` never invoked); tests/t-presize-clients.sh:54 SC2034 (`b` unused).

## 2026-11-05 — speed-recording (orchestrator)
- Harness: the intake's switch trace (`tests/lib.sh` throwaway fleet with the real conf, 4 workspaces x 3 agents, rails running, a real client attached through `script`), 23 cross-workspace `agent-fleet goto` calls per run, two runs.
- Result on this branch: p50 29 ms both runs (min 27-28, p90 31, max 33-40). Before (master, same harness, intake): p50 56 ms, max 89 ms. Target was 40 ms or less: met.
- `focus-track.sh` alone: 5-13 ms per call (unchanged order; it no longer forks `status.sh` for non-done agents).
- Not measured: macOS, where each saved fork is worth about 3x.
