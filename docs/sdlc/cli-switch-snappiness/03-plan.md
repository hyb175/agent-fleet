---
feature: cli-switch-snappiness
phase: plan
status: draft
date: 2026-11-05
---

# CLI switch snappiness — Implementation plan

## Strategy
The pre-size script is the risky, foundational part (tmux output parsing, skip rules, fork budget), so it lands first as a script run directly by tests, with no hooks. The two fork guards (goto, focus-track) are independent one-file changes and ride in wave 1. Debounce lands next (WI-2), and only then are the hooks wired (WI-3), so no hook ever fires an undebounced script. Multi-client, nested-client and spawn scenarios come last (WI-7) because they need the real hooks. Test files are split per wave so no two same-wave items share a file.

## Work items
```yaml
items:
  - id: WI-1
    title: presize.sh single pass (read, skip rules, resize, default-size, rail)
    description: >
      New scripts/presize.sh taking the hook's client name. Sources cache.sh, defines the tx wrapper.
      Exits 0 unless global window-size is `latest` (D6). One chained tmux read (list-clients, sessions,
      windows, pane ttys) then one chained write: `set -g default-size XxY` (D7), and per window to resize
      `resize-window -t W -x X -y Y ; set -wu -t W window-size` (D3) plus `resize-pane -x
      ${AGENT_FLEET_SIDENAV_WIDTH:-30}` on windows with @fleet-sidenav=1 (D8). Target = client size minus
      global status lines (D1). Skip windows in sessions another client is attached to, windows containing a
      pane on the client's own tty, and windows already at target (D2). Nothing to resize means no write
      (D5). bash 3.2 safe (no mapfile, guarded empty arrays). No debounce yet. No hooks yet.
    files: [scripts/presize.sh, tests/t-presize.sh]
    precedent: scripts/border-tune.sh:17-45
    precedent_delta: >
      Same shape (set -uo pipefail, `tx` wrapper on TMUX_BIN, list-windows -a, tx set -w, exit 0). Differs:
      border-tune forks tmux once per window; presize must batch the whole pass into 2 invocations, take a
      client argument, read cache.sh (as scripts/focus-track.sh:25 does), and own default-size.
    depends_on: []
    parallelizable: true
    size: M
    proof: unit
    tests:
      - "tests/t-presize.sh 'pass resizes an unviewed window and restores window-size' (catches a missing set -wu: show-options -wqv window-size must print nothing)"
      - "tests/t-presize.sh 'skips windows of a session another client is attached to, and the window holding the client tty' (catches resizing them: resized-hook count must stay 0)"
      - "tests/t-presize.sh '20 windows need resizing -> TMUX_BIN wrapper log has <= 2 invocations' (catches a per-window fork loop)"
      - "tests/t-presize.sh 'window-size largest -> nothing resized, default-size untouched' (catches a missing D6 guard)"
      - "tests/t-presize.sh 'rail pane_width is 30 after resize and default-size equals the target (client size minus status lines, i.e. the size of the client current window: 80x23 for an 80x24 client under status on)' (catches rail drift, missing D7, and an off-by-status-line default-size)"
    scenarios: []
    verify: bash tests/t-presize.sh
  - id: WI-4
    title: goto skips status.sh unless the agent is done
    description: >
      In cmd_goto (bin/agent-fleet:886) read $AF_CACHE_DIR/panes/<pane>.status with the `read` builtin.
      `done` -> run status.sh clear-done synchronously as today. Any other state -> no fork. No status
      file (scraped agent) -> run clear-done in the background with stdout/stderr to /dev/null, launched
      before select-window because go_to_session may exec attach (D9). New test file drives the CLI
      against a conf-loaded server with TMUX set to it, so go_to_session takes the headless in_fleet_tmux
      branch (bin/agent-fleet:619) instead of exec attach; the `bash -x` trace is the assertion for no
      fork; the scraped case uses a TMUX_BIN wrapper that sleeps 2 s on capture-pane.
    files: [bin/agent-fleet, tests/t-goto-fast.sh]
    precedent: scripts/status.sh:106
    precedent_delta: >
      Donor reads a status file with `{ read -r st < f || true; }` guarding the no-trailing-newline EOF
      return. Copy that guard (cmd_goto's caller may run under set -e). Differs: three-way branch
      (done / other / absent) and the background launch for the absent case. Test wrapper shape from
      tests/t-focus.sh:12-15.
    depends_on: []
    parallelizable: true
    size: S
    proof: scenario
    tests: []
    scenarios: [S-3]
    verify: bash tests/t-goto-fast.sh
  - id: WI-5
    title: focus-track.sh forks status.sh only when the file says done
    description: >
      Replace the `-f` test at scripts/focus-track.sh:44 with a `read` of the status file; fork
      status.sh clear-done only when it reads `done` (D10). Add cases to t-focus.sh.
    files: [scripts/focus-track.sh, tests/t-focus.sh]
    precedent: scripts/status.sh:106
    precedent_delta: >
      Same read-with-`|| true` idiom. Differs: result is compared to `done` instead of echoed, and the
      script has no set -e but does use `set -u`, so the variable must be initialised.
    depends_on: []
    parallelizable: true
    size: S
    proof: unit
    tests:
      - "tests/t-focus.sh 'working pane: bash -x trace has no status.sh, file still working, focus.now written' (catches the fork still happening)"
      - "tests/t-focus.sh existing 'focus-in acks a done agent to idle' stays green (catches the guard swallowing the done case)"
    scenarios: []
    verify: bash tests/t-focus.sh
  - id: WI-2
    title: presize.sh debounce and re-read loop
    description: >
      Add D4: write a unique token ($$ + $RANDOM) to $AF_CACHE_DIR/presize.token, sleep 0.15, exit unless
      the file still holds the run's own token. After the write, the trailing client re-read is compared
      with the size used; if different, repeat the pass, at most 3 passes. No lock; a stale token left by a
      killed run must not block later runs.
    files: [scripts/presize.sh, tests/t-presize.sh]
    precedent: none
    precedent_delta: >
      No debounce, token file or burst coalescing exists in bin/ scripts/ or conf/ (grepped RANDOM, token,
      debounce, settle). First of its kind here; closest style reference is the cache-file idiom in
      scripts/focus-track.sh:33-37.
    depends_on: [WI-1]
    parallelizable: true
    size: M
    proof: unit
    tests:
      - "tests/t-presize.sh '10 concurrent runs -> exactly one reaches the write' (catches a missing token compare: wrapper log would show 10 writes)"
      - "tests/t-presize.sh 'stale token from a killed run does not block the next run' (catches a lock-style implementation that wedges)"
      - "tests/t-presize.sh 'client size changes between read and write -> second pass applies the new size, at most 3 passes' (catches stopping after one pass or looping forever)"
    scenarios: []
    verify: bash tests/t-presize.sh
  - id: WI-6
    title: presize.sh runs clean under /bin/bash 3.2
    description: Add a t-bash32.sh case that runs presize.sh under /bin/bash against a conf-loaded server and asserts empty stderr and a resized window. Fix any bashism it finds in presize.sh.
    files: [tests/t-bash32.sh, scripts/presize.sh]
    precedent: tests/t-bash32.sh:24-27
    precedent_delta: >
      Same `err="$("$B" script … 2>&1)"` plus empty-stderr check. Differs: presize needs a live server
      with a second window to resize, not TMUX_BIN=/nonexistent.
    depends_on: [WI-2]
    parallelizable: true
    size: S
    proof: unit
    tests:
      - "tests/t-bash32.sh 'presize.sh runs clean under /bin/bash' (catches mapfile, printf %(%s)T, or an unguarded empty array under set -u)"
    scenarios: []
    verify: bash tests/t-bash32.sh
  - id: WI-3
    title: Register presize hooks in the conf and prove attach/resize pre-sizing
    description: >
      In conf/agent-fleet.conf, make client-attached carry both the existing sidenav-toggle ensure and
      `run-shell -b presize.sh '#{client_name}'`, and add client-resized running presize.sh. Registered so
      re-sourcing the conf replaces rather than appends (D11): fixed array indices, no `set-hook -a`.
      Extend t-presize.sh with S-1: attach pre-sizes unviewed windows, switch-client changes no window
      size (20-switch probe), terminal resize and a 10-resize burst converge, show-hooks identical after a
      double source, window-size largest gives resize count 0, and the foreground work added is zero
      (hooks are -b).
    files: [conf/agent-fleet.conf, tests/t-presize.sh]
    precedent: conf/agent-fleet.conf:176-178
    precedent_delta: >
      Donor registers client-attached with a plain `set-hook -g` (index-less, replaces). Needs two
      commands on client-attached without `-a`, so use [0]/[1] indices (or chain), keep the sidenav ensure
      foreground as today, and make the presize entry `run-shell -b` as at conf/agent-fleet.conf:186.
    depends_on: [WI-2]
    parallelizable: true
    size: M
    proof: scenario
    tests: []
    scenarios: [S-1]
    verify: bash tests/t-presize.sh && bash tests/t-mouse.sh
  - id: WI-7
    title: Multi-client, nested-client and background-spawn scenarios
    description: >
      New tests/t-presize-clients.sh for S-2: second throwaway socket hosting clients of chosen sizes (own
      trap cleanup), two-client no-fight, nested client no feedback loop, default-size follows the client,
      `agent-fleet add` (no --focus, TMUX unset) and `--new-workspace` born at size with a 30-col rail,
      three back-to-back adds, and a window added to another client's session that a later resize of A
      leaves alone (window-resized count 0, with an unattached s3 window taking A's new size in the same
      pass as the positive control). No TMUX_BIN wrapper in this file. Fix presize.sh where a scenario
      exposes a gap.
    files: [tests/t-presize-clients.sh, scripts/presize.sh]
    precedent: tests/t-mouse.sh:19-23
    precedent_delta: >
      Donor attaches a client from a pane of a second session on the SAME server. S-2 needs a client of
      a chosen size on a separate socket (`new-session -x W -y H`) so two clients differ, plus a nested
      case that does reuse the same-server pattern; add own cleanup trap since _lib_cleanup does not
      know the second socket.
    depends_on: [WI-3]
    parallelizable: true
    size: M
    proof: scenario
    tests: []
    scenarios: [S-2]
    verify: bash tests/t-presize-clients.sh && bash tests/run-all.sh
```

## Scenarios
```yaml
scenarios:
  - id: S-1
    seam: cli
    criteria: [US-1 AC-1, US-1 AC-2, US-1 AC-3, US-1 AC-4, US-1 AC-6, US-1 AC-7, US-1 AC-8, US-2 AC-1, US-2 AC-2, NFR no-resize probe]
    # US-2 AC-3 (stale token) is proven by WI-2's unit test 'stale token from a killed run does not block the next run'.
    given: >
      Conf-loaded test server on the tests/lib.sh socket, sessions s1 and s2 (2 windows each, 80x24, rails),
      one client attached from a second throwaway tmux socket. No stubs; a test-only window-resized hook
      counts resizes.
    when: client attaches; later its host pane is resized once, then 10 times in 1 s; 20 switch-client calls cycle 4 sessions; conf sourced twice; global window-size set to largest.
    then: >
      Once settled every unskipped window has the client's size, window-size is unset on each, rails are
      30 cols, no window size changes across any of the 20 switches, show-hooks output is identical after
      a second source, no presize.sh remains after the burst, and under largest nothing is resized.
    spec: tests/t-presize.sh
  - id: S-2
    seam: cli
    criteria: [US-3 AC-1, US-3 AC-2, US-3 AC-3, US-4 AC-1, US-4 AC-2, US-4 AC-3, US-4 AC-4, US-4 AC-5, US-4 AC-6]
    given: >
      Conf-loaded test server; clients A and B of different sizes from a second throwaway socket; a
      nested client whose host pane is on the same server, and an unattached s3. No stubs: absence of a
      resize is observed with the test-only window-resized counter (truncated just before each trigger),
      and every absence check is paired with a positive control from the same pass (a window of the
      unattached s3 took the triggering client's new size), so a pass that never ran fails the test.
    when: A is resized; a client attaches nested; `agent-fleet add` (no --focus, TMUX unset), `add --new-workspace s4` and three back-to-back adds run.
    then: >
      B's windows have resize count 0 while unattached s3 takes A's size; the nested client's host window
      is not resized and client size is stable between 1 s and 4 s; new windows have the client's size as
      soon as `add` returns, rails are 30 cols, and a window added to B's session has B's size and, after
      A is resized again and the run is quiet, resize count 0 while s3 has A's new size.
    spec: tests/t-presize-clients.sh
  - id: S-3
    seam: cli
    criteria: [US-5 AC-1, US-5 AC-2, US-5 AC-3]
    # US-6 AC-2 is covered by the existing tests/t-focus.sh cases under run-all, not by this spec.
    given: >
      Conf-loaded test server with agent panes whose status files read working, wait, idle and done (one
      with a task record), and one scraped pane showing a finished-turn summary. goto runs with TMUX set
      to the test server so it takes the headless branch (no exec attach). Stub: a TMUX_BIN wrapper
      that sleeps 2 s on capture-pane (outside the seam; models a slow tmux).
    when: `bash -x bin/agent-fleet goto <pane>` runs for each; for the scraped pane `goto <pane> | cat` is timed.
    then: >
      Non-done panes show no status.sh in the trace and an unchanged file, and the pane is active; the done
      pane reads idle with one new `state idle` record line; the scraped goto returns in under 1 s and
      <pane>.ackdone appears once settled; existing t-focus.sh cases still pass.
    spec: tests/t-goto-fast.sh
```

## Downstream route
```yaml
route:
  test: full
  review: [correctness, maintainability, tests]
  review_reason: "security dropped: no input parsing from outside, authz, secrets or serialization changes; presize reads tmux output and writes one cache file"
  release_notes: true
  extra:
    - id: speed-recording
      after: test
      goal: "Measure agent-fleet goto p50 on the intake setup as in 00-intake.md and record it in the cycle (target 40 ms or less, 56 ms before); not gated in CI."
  rationale: "Default route plus a recorded speed measurement the requirements ask for; security dropped, nothing moves a trust boundary."
```

## Out-of-plan risks
- Factoring candidates: the `tx() { "${TMUX_BIN:-tmux}" -L … }` wrapper already exists in 9 scripts (e.g. scripts/border-tune.sh:20, scripts/redraw.sh:20); presize.sh is a 10th copy. The "read status file, compare to done" check now lives in status.sh:106, goto and focus-track.sh (WI-4, WI-5); a shared helper in cache.sh would serve both. Not done here to keep the diff small.
- scripts/agent-status-hook.sh:221 forks `status.sh clear-done` too; not on the switch path, left alone.
- Design gap (resolved in plan): the design does not say how the goto test avoids `go_to_session`'s `exec attach` (bin/agent-fleet:625). S-3 runs goto with TMUX pointing at the test server, which takes the headless branch at bin/agent-fleet:619 and returns 0 with no client.
- Wave packing: WI-2, WI-3, WI-6 and WI-7 all touch presize.sh or t-presize.sh or the conf, so they are serialized across waves on purpose (W1: WI-1, WI-4, WI-5; W2: WI-2; W3: WI-3, WI-6; W4: WI-7). WI-3 and WI-6 share no file.
- The 150 ms debounce and 1 s "quiet" waits make t-presize.sh slow; keep its fixtures small.
