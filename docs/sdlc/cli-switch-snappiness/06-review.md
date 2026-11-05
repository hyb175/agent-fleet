---
feature: cli-switch-snappiness
phase: review
status: draft
date: 2026-11-05
---

# CLI switch snappiness — Review report

## Scope
- Diff: branch `cli-switch-snappiness` against `master`. Exact commit range reviewed: TBD — not covered by artifacts.
- Files with findings: `scripts/presize.sh`, `conf/agent-fleet.conf`, `tests/t-presize.sh`, `tests/t-presize-clients.sh`, `tests/t-goto-fast.sh`, `tests/t-bash32.sh`.
- Dimensions reviewed: correctness, maintainability, tests. Security was **not reviewed** (see Verification).
- Totals: 20 findings: 1 major, 12 minor, 7 nit. The pipeline stopped at the Test gate. No fixes were attempted, so every finding is open.

## Findings

### F-1: Leftover debug hook writes to a hard-coded developer path — major (confidence high)
- Where: `tests/t-presize-clients.sh:322`
- Issue: `tx set-hook -ga client-resized "run-shell \"echo hook ... >> /tmp/claude-1000/hk\""` is debugging scaffolding left in the test.
- Why it matters: it writes outside the test sandbox into a user-specific `/tmp` path and fails wherever that directory doesn't exist (CI, other users). It also appends a foreground (non `-b`) `run-shell` entry to the same hook the test is measuring, which adds blocking work on every client resize and changes the `show-hooks` output.
- Suggested fix: delete line 322.
- Status: open. Note: `05-testing.md` says the test phase removed this hook (commit 0aec875), and `/tmp/claude-1000` no longer appears in the current file. The review did not re-check this.

### F-2: Goto "pane is active" assertions cannot fail — minor (confidence high)
- Where: `tests/t-goto-fast.sh:25` (and line 48 for the scraped case)
- Issue: `mkpane` creates a new detached window with a single work pane, so `#{pane_active}` for that pane is already 1 before goto runs.
- Why it matters: US-5 (goto skips the done-check fork when the agent is not done) requires the pane to be "the active pane of the session's active window". These checks would still pass if goto never selected the window.
- Suggested fix: also assert `#{window_active}` == 1 for the pane's window, or compare `tx display-message -p -t t: '#{pane_id}'` against `$p`.
- Status: open

### F-3: A failed chained write drops the rest of the batch and skips the retry — minor (confidence medium)
- Where: `scripts/presize.sh:83`
- Issue: all resizes go out in one chained tmux command. If a window or rail pane dies between the read and the write (agents exit often in a fleet), its `resize-window`/`resize-pane -t` fails, and tmux drops the rest of the sequence: later windows, `default-size` if it comes after, and the trailing `list-clients`. `|| exit 0` then exits without a retry pass.
- Why it matters: the remaining windows stay unsized until the next attach or resize, so switching into them still resizes.
- Suggested fix: on write failure, `continue` to the next pass instead of exiting (the loop is already capped at 3). Optionally use targets that tolerate a missing window.
- Status: open

### F-4: The own-tty skip covers only this client's tty, not other clients' ttys — minor (confidence medium)
- Where: `scripts/presize.sh:59`
- Issue: rule D2(b) skips any window holding a pane whose tty is the hook client's own tty, but not windows holding other attached clients' ttys. With a nested client (`env -u TMUX attach` from a fleet pane) plus a main client A: A's pass resizes the nested client's unattached host window. That resizes the nested client, which fires its `client-resized` hook. The nested client's pass then sets every unattached window and `default-size` to the nested (smaller) size.
- Why it matters: A's pre-size is undone. There is no infinite loop, but A's next switch resizes again. The test removes the host session before A resizes, so this path is never exercised.
- Suggested fix: build `busy` from every client's tty in the C records, not only `$ctty`, and skip any window holding any attached client.
- Status: open

### F-5: client() records its socket inside a subshell, so tracking and cleanup do nothing — minor (confidence high)
- Where: `tests/t-presize.sh:35`
- Issue: `c="$(client ...)"` runs `client()` in a command substitution, so `CSOCKS+=` never reaches the parent shell. Every client lands on `"$SOCK-c0"` (the test has to hard-code `cs="$SOCK-c0"` with a comment), and neither `fresh()` nor the EXIT trap kills those servers. They exit only because their attach client dies with the main server.
- Why it matters: the next `fresh()` + `client()` runs `tmux -L $SOCK-c0 new-session` while the old c0 server may still be shutting down. That is the same "server exited" race `kill_server` works around for the main socket.
- Suggested fix: use the explicit-id `client()` from `t-presize-clients.sh` (the caller names the socket and adds it to `CSOCKS`), or register the socket before the command substitution.
- Status: open

### F-6: Client-harness helpers duplicated across the two presize tests, with different signatures — minor (confidence high)
- Where: `tests/t-presize-clients.sh:282`
- Issue: `_cleanup`/`CSOCKS`, `client()`, `wsize()`, `nresized()` and `settled()` are defined twice with different shapes. `client()` takes 3 args in one file and 4 in the other. `nresized` uses `grep -c` in `t-presize.sh` and `grep -cx` here. `t-bash32.sh` has a third inline copy of the attach recipe.
- Why it matters: the copies have already drifted. One has the subshell bug (F-5) that the other avoids.
- Suggested fix: move a single client/cleanup helper (explicit socket id, registered in the trap) into `tests/lib.sh` and use it from all three tests.
- Status: open

### F-7: The bash 3.2 presize case races the conf's own presize hook — minor (confidence medium)
- Where: `tests/t-bash32.sh:50`
- Issue: `boot_server` loads the conf, so the client attach fires `client-attached[1]` and runs presize in the background under the modern `env bash`. That run can resize s2 before the `/bin/bash` run does, or instead of it (through the debounce token). Separately, the throwaway client socket is killed inline rather than in a trap, which the requirements ask for.
- Why it matters: the "resized the unviewed window" check passes even if the 3.2 run never reaches its write path, so the claim that the write half works under bash 3.2 is not reliably proven.
- Suggested fix: start a bare server for this case (`tmux -L $SOCK -f /dev/null new-session ...`, as `t-presize.sh`'s `fresh()` does), and kill the client socket from an EXIT trap.
- Status: open

### F-8: "Exactly one run reaches the write" depends on spawn timing — minor (confidence medium)
- Where: `tests/t-presize.sh:133`
- Issue: ten runs are launched in a loop. If the time between the first and last launch exceeds the 150 ms debounce (bash startup plus sourcing `cache.sh` on a loaded macOS runner), an early run reads its own token back and also does a pass. That is correct under D4 (the token debounce), but it fails `grep -c resize-window == 1` and `wc -l == 2`.
- Why it matters: the test can fail on a slow runner with no bug in presize.
- Suggested fix: assert at most one pass per 150 ms window, or start all runs behind a barrier (e.g. each waits on a FIFO that is released at once).
- Status: open

### F-9: settled() matches any presize.sh process from the repo path, including the live fleet's — minor (confidence medium)
- Where: `tests/t-presize-clients.sh:298`
- Issue: `pgrep -f "$REPO/scripts/presize.sh"` also matches presize runs started by the developer's live fleet (which runs from this checkout) and by any test running at the same time.
- Why it matters: "quiet" checks can stall or fail at random, and a test-server run that has not started yet looks the same as someone else's run.
- Suggested fix: have the test pass a recognisable marker (e.g. run presize through a socket-named wrapper, or pass `$SOCK` in argv), or wait on the token file's mtime instead of `pgrep`.
- Status: open

### F-10: Scraped-goto time limit loosened from 1 s to 2 s — minor (confidence high)
- Where: `tests/t-goto-fast.sh:47`
- Issue: US-5 requires goto on a scraped pane to return in under 1 s. The check `(( SECONDS - start < 2 ))` uses integer `SECONDS` and passes for anything up to about 2 s.
- Why it matters: a regression where goto partly waits again (about 1.5 s) would not be caught.
- Suggested fix: time with `date +%s%N` or `EPOCHREALTIME` (bash 5) and assert < 1000 ms.
- Status: open. `05-testing.md` lists this under Gaps as accepted.

### F-11: US-5 "done" case: the task record append is not tested — minor (confidence high)
- Where: `tests/t-goto-fast.sh:28`
- Issue: the criterion requires the task record to gain exactly one `state idle <epoch>` line. The test creates no `.task` pointer or record and checks only the status file.
- Why it matters: goto could stop appending to the task record and the test would not notice.
- Suggested fix: create `tasks/<tid>` plus `panes/<pane>.task` as `t-bash32.sh` does, and assert `grep -c '^state idle [0-9]'` == 1.
- Status: open. Note: `05-testing.md` says the test phase added this, and the current file has a check at line 35 (`done: record gained exactly one state idle line`). The review did not re-check this.

### F-12: US-4 "resize count since creation is 0 once quiet" is not asserted — minor (confidence high)
- Where: `tests/t-presize-clients.sh:352`
- Issue: US-4 is about background-spawned windows being created at the client's size. The background-spawn section checks size and rail when `add` returns, but never truncates the resized log before `add` and never checks, once quiet, that the new window got no resize.
- Why it matters: that check is the criterion's actual guarantee that the window never repaints for a resize.
- Suggested fix: truncate `$RESIZED` before the add, `poll_until` settled, `sleep 1`, then assert `nresized $w1` == 0 (and the same for the s4 window).
- Status: open

### F-13: US-1 gaps: AGENT_FLEET_SIDENAV_WIDTH override, and `largest` on attach — minor (confidence high)
- Where: `tests/t-presize.sh:109`
- Issue: US-1 is about windows being pre-sized when a client attaches. Its rail-width criterion includes "or `AGENT_FLEET_SIDENAV_WIDTH` when set", but only the default 30 is tested. The "`window-size largest`, when a client attaches" criterion is exercised only through a direct call (unit) and a resize triggered by the hook (S-1), never through an attach triggered by the hook.
- Why it matters: two US-1 criteria are not tested the way they are written.
- Suggested fix: add a direct run with `AGENT_FLEET_SIDENAV_WIDTH=24` asserting a 24-col rail, and an attach under `largest` asserting resize count 0 once quiet.
- Status: open

### F-14: Tab-IFS read collapses empty fields and shifts columns — nit (confidence medium)
- Where: `scripts/presize.sh:53`
- Issue: tab is an IFS whitespace character, so `read` merges consecutive tabs, and an empty field shifts the later ones.
- Why it matters: an empty `pane_tty` (dead pane) moves `pane_id` into the tty slot and loses the rail flag. An empty `client_tty` (control-mode client) moves its session into the tty slot and its width into the session slot, so that client's session is not skipped.
- Suggested fix: put a non-whitespace placeholder in each format (e.g. `#{?pane_tty,#{pane_tty},-}`), or use a non-whitespace separator such as `|` or the unit separator `\x1f`.
- Status: open

### F-15: Policy and status are read from the default target window/session, not the global options — nit (confidence low)
- Where: `scripts/presize.sh:46`
- Issue: `display-message -p '#{window-size}'` resolves the effective option for whatever window tmux picks as the default target. D6 (do nothing unless global `window-size` is `latest`) asks for the global value. `#{status}` has the same problem for the session.
- Why it matters: a per-window `window-size` override on that window (e.g. a user's manual `resize-window`) would silently turn presize off, or on.
- Suggested fix: read the global values in the same chain, e.g. `show -gv window-size ; show -gv status ; show -gv default-size`, and parse them by position.
- Status: open

### F-16: Retry check is an unanchored substring match — nit (confidence medium)
- Where: `scripts/presize.sh:84`
- Issue: `[[ "$back" == *"${client}${T}${cw}${T}${ch}"* ]]` has nothing after the height.
- Why it matters: `ch=30` also matches a re-read height of 300-309, so the retry pass is skipped.
- Suggested fix: anchor with newlines: `[[ $'\n'"$back"$'\n' == *$'\n'"$client$T$cw$T$ch"$'\n'* ]]`.
- Status: open

### F-17: Unconditional `mkdir -p` forks on every hook — nit (confidence high)
- Where: `scripts/presize.sh:38`
- Issue: every run, including runs that lose the debounce, forks `mkdir` before writing the token.
- Why it matters: it falls outside the D5 limit (at most 2 tmux calls per pass), but every terminal-drag event pays for it.
- Suggested fix: `[[ -d "$AF_CACHE_DIR" ]] || mkdir -p "$AF_CACHE_DIR"`.
- Status: open

### F-18: nresized in t-presize.sh matches window-id prefixes — nit (confidence high)
- Where: `tests/t-presize.sh:46`
- Issue: `grep -c "$1"` without `-x` counts `@1` lines when asked for `@1x`, and counts `@10`..`@19` when asked for `@1`. `t-presize-clients.sh` uses `-x`.
- Why it matters: with 20+ windows on a server, resize counts can be inflated or credited to the wrong window.
- Suggested fix: use `grep -cx`.
- Status: open

### F-19: US-4 background-spawn test relies on a "latest client" priming step — nit (confidence low)
- Where: `tests/t-presize-clients.sh:348`
- Issue: the test sends `C-l` to A so that tmux's `latest` policy sizes new windows in unattached sessions from A. With clients attached, `new-window` takes the most recently active client's size, not `default-size`. So the `--to s3` adds test tmux's own sizing, not D7 (set `default-size` so new windows are created at the client's size), which only governs `--new-workspace` (`new-session -d`).
- Why it matters: this holds for one client, but the test comment and D7's rationale overstate what `default-size` does, and the priming step hides the two-client case.
- Suggested fix: note in D7 and in the test that `default-size` covers new detached sessions (and windows when no client is attached), and keep the s4 check as the D7 proof.
- Status: open

### F-20: No pass after a client detaches or switches sessions — nit (confidence low)
- Where: `conf/agent-fleet.conf:182`
- Issue: presize runs only on `client-attached` and `client-resized`.
- Why it matters: when a second client of a different size detaches, its session's windows keep that size, and the remaining client's first switch into them resizes. The non-goal about two differently sized clients arguably covers this, but nothing handles this case.
- Suggested fix: optionally add a `client-detached[N]` (and/or `client-session-changed`) entry running presize for a remaining client, or document this as accepted.
- Status: open

## Verification
- Route chosen by the plan:
  - Dimensions reviewed: correctness, maintainability, tests.
  - **Security: not reviewed (dropped by the route).** Reason given: "no input parsing from outside, authz, secrets or serialization changes; presize reads tmux output and writes one cache file". No security finding means nobody looked, not that the code was cleared.
  - Test phase: `full`. `05-testing.md` reports `bash tests/run-all.sh` exit 0 ("all tests passed") and shellcheck exit 0. The pipeline still stopped at the Test gate. Why: TBD — not covered by artifacts.
  - Extra phase `speed-recording` (measure `agent-fleet goto` p50 on the intake setup, target 40 ms or less from 56 ms, not gated in CI): result TBD — not covered by artifacts. It is scheduled after the Test gate, so do not read it as passed.
- Reviewers cut 0 lower-ranked findings. All 20 they reported are listed above.
- How findings were confirmed (adversarial refutation, reproduction, or none): TBD — not covered by artifacts. Each finding carries only the reviewer's own confidence (high / medium / low).
- Verified: TBD — not covered by artifacts.
- Refuted: TBD — not covered by artifacts.
- Never checked: TBD — not covered by artifacts.

### Never checked
TBD — not covered by artifacts. The sources do not say whether any finding was fact-checked, so treat all 20 as unverified until a fact-check result is recorded. The low-confidence ones are F-15 (nit), F-19 (nit) and F-20 (nit).

## Verdict
fix-then-ship (derived from the open severities; the sources give no verdict). It depends on:
- F-1 (major): confirm the debug hook is gone from the tree that ships. The test phase reports removing it.
- The minor correctness findings in `scripts/presize.sh`: F-3 (one failed write abandons the batch and the retry) and F-4 (a nested client undoes the main client's pre-size).
- The test-reliability minors that can fail at random or pass without proving anything: F-2, F-5, F-7, F-8, F-9.
- The coverage gaps F-10 to F-13 and all nits: fix, or record each as accepted.
- The skipped security review and the unrecorded speed-recording result are not cleared by this review.

## Resolution (orchestrator, 2026-11-05)
The pipeline stopped at the Test gate, so its automatic fix stage never ran. The orchestrator worked through every finding by hand after the gate:

| Finding | Status | Where |
|---|---|---|
| F-1 debug hook | fixed (removed by the test phase; `grep` for `/tmp/claude` finds nothing) | 0aec875 |
| F-2 pane-active check | fixed: asserts `#{pane_active}#{window_active}` == 11 | 93a809f |
| F-3 failed chained write | fixed: a failed write takes another pass (`|| continue`, still capped at 3) | 59e6c5a |
| F-4 other clients' ttys | fixed: windows holding any attached client's tty are skipped | 59e6c5a |
| F-5 client() in a subshell | fixed: `client()` sets `c` instead of printing, so its socket reaches `CSOCKS` | 93a809f |
| F-6 duplicated client harness | accepted: factoring candidate, left for a later cleanup | — |
| F-7 bash 3.2 case races the conf hook | fixed: bare server, client socket killed from the EXIT trap | 93a809f |
| F-8 concurrency test timing | fixed: the ten runs start behind a shared go file | 93a809f |
| F-9 `settled()` matches a live fleet's runs | accepted: can only delay a quiet check on a dev machine; recorded in 05-testing.md Gaps | — |
| F-10 1 s limit loosened | fixed: `EPOCHREALTIME`, < 1000 ms | 93a809f |
| F-11 task record append | fixed (by the test phase) | 0aec875 |
| F-12 spawned-window resize count | fixed: count 0 once quiet for every spawned window | 93a809f |
| F-13 sidenav override, `largest` on attach | override fixed (24-col check); `largest`-on-attach accepted with reason in 05-testing.md | 93a809f |
| F-14 tab IFS collapses empty fields | fixed: unit separator `\x1f` | 59e6c5a |
| F-15 policy read from a default target | fixed: `show -gqv window-size/status/default-size` | 59e6c5a |
| F-16 unanchored retry match | fixed: newline-anchored | 59e6c5a |
| F-17 unconditional `mkdir -p` | fixed: `[[ -d ]] ||` | 59e6c5a |
| F-18 `nresized` prefix match | fixed: `grep -cx` | 93a809f |
| F-19 D7 overstates default-size | fixed in 01-requirements.md D7 | docs |
| F-20 no pass on detach | accepted: two differently sized clients are a non-goal | — |

After the fixes: shellcheck exit 0, `bash tests/run-all.sh` exit 0 ("all tests passed").

Verdict after resolution: **ship**, pending CI (the bash 3.2 case runs only on CI's macOS job).
