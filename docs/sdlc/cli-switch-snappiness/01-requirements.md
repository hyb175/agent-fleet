---
feature: cli-switch-snappiness
phase: requirements
status: draft
date: 2026-11-05
---

# CLI switch snappiness — Requirements

Evidence, measurements and constraints: `docs/sdlc/cli-switch-snappiness/00-intake.md` (cited as "intake").

## Downstream route
```yaml
route:
  design: inline
  design_reason: >
    The user already approved the approach (hook-driven resize-window pre-sizing, and not forking
    status.sh when the agent is not done). For EXISTING windows no tmux option can do the
    pre-sizing instead: window-size and aggressive-resize only size windows of sessions a client
    is attached to, and default-size applies only at creation. For NEW windows default-size is
    exactly the right tool, and the user chose it (2026-11-05) over resizing them after creation:
    a window born at the right size never sends its Claude a resize. The change is one conf hook block, one new script, and a guard in
    cmd_goto and focus-track.sh. It adds no dependency, changes no schema or file format,
    moves no trust boundary, and is undone by deleting those lines. Each remaining choice
    has one answer the code forces (listed below).
```

## Approach
A new `scripts/presize.sh` runs via `run-shell -b` from `client-attached` and `client-resized` (client context: `#{client_name}`). Each run does one full pass: it debounces (D4), reads clients, sessions, windows and pane ttys in one chained tmux invocation, then sends `set -g default-size X×Y` plus every needed `resize-window -t W -x X -y Y ; set -wu -t W window-size` (plus a rail re-width if needed) as one chained invocation that ends by re-reading the clients, and exits. New windows need no hook: `default-size` makes tmux create them at the client's size (D7). `cmd_goto` and `focus-track.sh` read `$AF_CACHE_DIR/panes/<pane>.status` with the `read` builtin and fork `status.sh clear-done` only when it says `done`. Reuses `scripts/cache.sh` (`AF_CACHE_DIR`), the `tx` wrapper pattern and `tests/lib.sh`. It changes no global tmux size option other than `default-size`, does not touch remote/federated goto, or reduce other parts of the CLI's startup cost.

Decisions (each would have been an ADR):
- **D1 Target size**: `client_width × (client_height − status lines)`. Status lines come from the global `status` option (`off`=0, `on`=1, `2..5`). `ponytail:` per-session `status` overrides are ignored; read the target session's option if anyone sets one.
- **D2 What gets skipped**: (a) every window in a session another client is attached to. tmux already sizes those to that client; resizing one anyway makes tmux snap it straight back (the `set -wu` recalculates from the attached client), so that client's Claudes take two resizes and two late repaints for nothing. (b) any window containing a pane whose tty is the client's own tty: a client running inside a fleet pane would otherwise resize itself, re-fire `client-resized`, and loop. (c) windows already at the target size.
- **D3 Restore the policy**: every `resize-window` is followed by `set -wu window-size`. `resize-window` pins the window to `manual`; unsetting gives it back to the global `latest` (intake, "Proved in a scratch server").
- **D4 Bursts, without a lock**: each run writes a token unique to it (`$$` plus `$RANDOM`) to `$AF_CACHE_DIR/presize.token`, sleeps 150 ms, and exits unless the file still holds its own token, so only the newest of a burst proceeds. Because every run does the same full pass over all windows, the survivor covers everything the runs it superseded would have done. If the write's trailing re-read shows a different target size than the pass used, the run does another pass, at most 3. Nothing is held: a run killed at any point leaves only a token file that the next hook overwrites, so presize can never wedge, and no wakeup is lost because the newest hook always runs. The 150 ms sleep is the only settle delay, fixed, and it delays only hidden windows; the client never waits on it.
- **D5 Fork budget**: 2 tmux invocations per pass, however many windows there are: one chained read (clients, sessions, windows, pane ttys) and one chained write that ends with the clients re-read D4 uses. A pass with nothing to resize skips the write (1 invocation). Plus the debounce `sleep`. macOS forks cost about 15 ms each (intake).
- **D6 Policy guard**: if the global `window-size` is not `latest` (the tmux default; the conf does not set it), presize does nothing.
- **D7 New windows are born at size**: every pass also sets the global `default-size` to its target size (D1), in the same chained write. tmux creates windows of sessions no client is attached to, and new detached sessions, at `default-size` (proved on tmux 3.6a: with `default-size 300x60`, `new-window -d` into an unattached session and `new-session -d` both made 300x60 windows), so a background spawn never gets a resize at all and needs no hook of its own. Precisely (review, 2026-11-05): `default-size` governs new detached sessions, and new windows when no client is attached; with a client attached, tmux's own `latest` policy already gives a window born in an unattached session the most recently active client's size, which presize keeps equal to `default-size`. A window created in a session a client is attached to is sized by tmux to that client, as today. The target client is always the hook's own client. The conf does not set `default-size` today; presize owns it from now on, and after the last client detaches it keeps the last client's size, which is the size the next attach most likely has.
- **D8 Rail width**: when a resized window has a rail (`@fleet-sidenav=1`), the same batch runs `resize-pane -x ${AGENT_FLEET_SIDENAV_WIDTH:-30}` on it. This is only needed if tmux spreads the width change across panes; the US-1 rail test decides whether it stays.
- **D9 goto**: a status file that says `done` gets `clear-done` synchronously, as today. A status file with any other state gets no fork. No status file (agent read by screen scraping) gets `clear-done` in the background with stdout and stderr sent to `/dev/null`, launched before `select-window`, because `go_to_session` may exec `attach` and nothing after it would run.
- **D10 focus-track.sh**: the same check as D9's hooked branch. It only forks `status.sh` when the file says `done`.
- **D11 Reload safety**: hooks are registered so that sourcing the conf replaces entries instead of appending them (no `set-hook -a`). Each array index is fixed, or the commands are chained in one entry.

## Problem
Switching between agent panes in the CLI sometimes lags for up to about a second. There are two measured causes (intake, Evidence):
1. **Window resize at switch time (the big one).** Under tmux's default `window-size latest` / `aggressive-resize off`, tmux sizes a window from the clients attached to a session that contains it. Switching into a workspace last seen at another size resizes all its windows at that moment. Claude starts repainting 355–644 ms late after about 1 resize in 4, and once took 1.2 s. tmux shows the old frame until then. The live fleet had windows at 188x52 and 342x58. Windows spawned into a workspace no client is viewing start at tmux's `default-size` 80x24 (no client to size them from), so the first visit always resizes them. That gap is not covered by the attach/resize hooks the user approved; setting `default-size` from the same hooks closes it (D7, US-4).
2. **Fork cost on the switch path.** `agent-fleet goto` runs a p50 of 56 ms, and 17 ms of that is `scripts/status.sh clear-done` (`bin/agent-fleet:886`), even when the agent is not done. The `pane-focus-in` hook (`scripts/focus-track.sh:44-46`) makes the same fork on every focus change into a hooked agent pane. It runs without `-b`, so it is on the switch path for every switch method, not only goto. This fork is not named in the approved fix, but the approved rule ("only when actually done") covers it (US-6).

## Goals
- With one client attached, switching into any workspace (goto, picker, rail click, Prefix L / 1..9, Prefix Space, Prefix Tab) resizes no window.
- `agent-fleet goto` on an agent that is not done forks no `status.sh`. On the intake setup, p50 drops from 56 ms to 40 ms or less.
- A focus change into a hooked agent that is not done forks no `status.sh`.
- Pre-sizing never delays a client: all of it runs in the background.

## Non-goals / out of scope
- Fixing Claude's late repaint itself, or adding a forced redraw on switch (Prefix R / `redraw.sh` stays as it is).
- Two clients of different sizes attached at once: a window has one size, so the client whose size did not win still sees a resize when it switches into a shared or re-sized workspace. Same as today.
- Changing the global `window-size` or `aggressive-resize` options. (`default-size` is changed, by D7.)
- Other `bin/agent-fleet` startup costs (sourcing theme/cache/overlay, `server_up`, `list-panes -a | awk`), picker/inbox popup open latency, and afui rendering.
- The remote/federated goto path (`remote_hop`).
- The Fleet Desktop (GPUI) app.
- A switch made before the background pre-size finishes, such as right after attaching. That one switch may still resize.
- Limiting the CPU that hidden Claudes spend repainting after one settled attach or resize (see Repaint burst).

## Users & scenarios
### Fleet user (one human; usually one local client, sometimes a second, e.g. ssh or another display)
- Single client, terminal size fixed: covered by US-1, US-5, US-6.
- Resizes the terminal or moves it to a different display: covered by US-2.
- Second client of a different size attached: covered by US-3.
- Agents spawned in the background (`agent-fleet add` without `--focus`, `agent-fleet task`, orchestrators): covered by US-4.

## User stories
Test setup used below: a conf-loaded server on the `tests/lib.sh` socket. A "client of size W×H" is a `tmux -L $SOCK attach` running in a pane of a session on a **second** throwaway socket created with `-x W -y H`; its cleanup is added to the test. "Settled" means `poll_until 10` holds. "Quiet" means at least 1 s has passed since the triggering event and no `presize.sh` process remains (`pgrep -f presize.sh` finds none), so every background pass has run and exited; every criterion that asserts something did **not** happen is checked once quiet, never by a poll that could succeed before presize runs. "Resize count" for a window is the number of lines naming it in `$WORK/resized` after the triggering event (the test truncates the file immediately before the trigger), appended by a test-only `set-hook -g window-resized 'run-shell -b "echo #{window_id} >> $WORK/resized"'` (the conf sets no `window-resized` hook, so the test owns it); "keeps its size" in the criteria below means its resize count stays 0, which an end-state size check cannot show because tmux recalculates a resized window back to its attached client's size.

### US-1: Windows are pre-sized when a client attaches
As a fleet user, I want every window I am not viewing already at my client's size, so that switching into it never triggers a resize and Claude's late repaint.

**Acceptance criteria**
- Given sessions `s1` and `s2` with 2 windows each, created detached at 80x24, when a client attaches to `s1`, then once settled every window of `s2` has the `window_width`/`window_height` of `s1`'s current window.
- Given that settled state, when `switch-client -c <client> -t =s2` runs, then every `s2` window's size after the switch equals its size before.
- Given a window presize resized, then `show-options -wqv -t <window> window-size` prints nothing.
- Given a presized window with a rail, then the rail's `pane_width` is 30 (or `AGENT_FLEET_SIDENAV_WIDTH` when set).
- Given 20 unviewed windows that need resizing, when one presize run executes with `TMUX_BIN` pointing at a wrapper that logs each call, then the log has 2 tmux invocations or fewer.
- Given the conf, then `show-hooks -g client-attached` contains the existing `sidenav-toggle.sh … ensure` entry and a `run-shell -b` entry for `presize.sh`.
- Given the conf has been sourced twice, then `show-hooks -g` output for `client-attached` and `client-resized` is identical to the output after one source.
- Given global `window-size` is set to `largest`, when a client attaches, then once quiet every window of `s2` has resize count 0.

### US-2: Windows follow a client resize
As a fleet user, I want hidden windows to follow my terminal when I resize it, so that the next switch after a resize is also instant.

**Acceptance criteria**
- Given a settled attached client, when its host pane is resized to a new W2×H2, then once settled every window not skipped under D2 has the size of the client's current window.
- Given a settled attached client, when its host pane is resized 10 times within 1 s and ends at W3×H3, then once settled every such window has the size of the client's current window at W3×H3, and no `presize.sh` process is still running.
- Given `$AF_CACHE_DIR/presize.token` left behind holding a token no live run owns (a run killed mid-sleep), when the client's host pane is resized, then once settled every window not skipped under D2 has the size of the client's current window.

### US-3: Pre-sizing never fights another client
As a fleet user with two clients attached, I want one client's pre-size to leave the other client's workspace alone, so that the two do not resize each other's view.

**Acceptance criteria**
- Given client A attached to `s1` and client B (a different size) attached to `s2`, both settled, when A's host pane is resized, then once quiet every window of `s2` (current and non-current) has resize count 0, and every window of an unattached `s3` has A's size.
- Given a client whose host pane is on the **same** server (the `t-mouse.sh` harness), when it attaches, then the window containing that host pane is not resized, and the client's `client_width`/`client_height` is unchanged between 1 s and 4 s after attach (no feedback loop).
- Given the existing suite, then `tests/t-mouse.sh` and every other test that attaches a client still pass.

### US-4: Background-spawned windows are born at the client's size
As a fleet user, I want agents spawned into other workspaces to start at my client's size, so that my first visit to them does not resize and they never repaint for a resize.

**Acceptance criteria**
- Given a client attached to `s1` and quiet, then `show-options -gv default-size` prints the size of `s1`'s current window.
- Given that state, when `agent-fleet add` (no `--focus`, `TMUX` unset) creates a window in an unattached `s2`, then immediately after `add` returns that window has the size of `s1`'s current window, and once quiet its resize count since creation is 0.
- Given that state, when `agent-fleet add --new-workspace s4` (no `--focus`, `TMUX` unset) runs, then immediately after it returns `s4`'s window has the size of the client's current window, and once quiet its rail is 30 cols.
- Given a quiet client attached to `s1`, when 3 `agent-fleet add` calls (no `--focus`, `TMUX` unset) create windows in unattached sessions back to back, then each has the size of `s1`'s current window as soon as its `add` returns.
- Given a client whose host pane is resized to W2×H2, once quiet, when a background `agent-fleet add` creates a window in an unattached session, then it is born at the size of the client's current window at W2×H2.
- Given client A attached to `s1` and client B of a different size attached to `s2`, both quiet, when `agent-fleet add` (no `--focus`) creates a window in `s2`, then that window has B's size; and when A's host pane is then resized and the run is quiet, that window's resize count since A's resize is 0, while a window of an unattached `s3` has A's new size (proof that the pass ran).

### US-5: goto skips the done-check fork when the agent is not done
As a fleet user, I want `agent-fleet goto` to spend nothing on acknowledging an agent that has nothing to acknowledge, so that the switch is faster.

**Acceptance criteria**
- Given a pane whose status file reads `working` (repeat for `wait` and `idle`), when `bash -x bin/agent-fleet goto <pane>` runs, then the trace contains no execution of `scripts/status.sh`, the status file content is unchanged, and the pane is the active pane of the session's active window.
- Given a pane whose status file reads `done` and has a task record, when `goto` returns, then the status file reads `idle` and the record gained exactly one `state idle <epoch>` line.
- Given a scraped pane (no status file) whose screen shows a finished-turn summary, and `TMUX_BIN` wrapping tmux so that `capture-pane` sleeps 2 s, when `agent-fleet goto <pane> | cat` runs, then it returns in under 1 s, and once settled `$AF_CACHE_DIR/panes/<pane>.ackdone` exists.

### US-6: The focus hook skips the done-check fork when the agent is not done
As a fleet user, I want every switch method (tab click, Prefix 1..9, Prefix L) to stop paying for the done-check, so that the speedup is not limited to goto.

**Acceptance criteria**
- Given a status file reading `working` for pane `%11`, when `scripts/focus-track.sh %11 0 sess @3` runs under `bash -x`, then the trace contains no execution of `status.sh`, the file still reads `working`, and `focus.now` reads `sess|@3`.
- Given the existing `t-focus.sh` cases (a `done` pane acks to `idle` with no tmux call, and nothing is signalled), then they still pass.

## Non-functional requirements
- **Speed**: on the intake setup (Linux i9-12900HK, tmux 3.6a, client attached, rails running), `goto` across workspaces has p50 of 40 ms or less, measured as in the intake. This is recorded in the cycle, not gated in CI. **No-resize probe**: in the US-1 setup with one settled client and 4 sessions, run 20 `switch-client -c <client> -t =<session>` calls cycling through the sessions, recording `list-windows -a -F '#{window_id} #{window_width}x#{window_height}'` before and after each; the count of windows whose size changed across any switch must be 0. It is US-1's second criterion repeated 20 times, and it runs in the suite.
- **Off the client path**: every presize entry point runs under `run-shell -b`. The new hooks add no foreground work to attach or resize, and nothing is added to window creation.
- **Fork budget**: see D5 / US-1.
- **Portability**: `presize.sh` runs clean under `/bin/bash` 3.2 (macOS): no `mapfile`, no `printf %(%s)T`, and empty arrays guarded. `t-bash32.sh` gains a case for it.
- **Checks**: `bash tests/run-all.sh` and `nix-shell -p shellcheck --run 'shellcheck bin/agent-fleet scripts/*.sh shims/* tests/*.sh docker/*.sh'` pass. Tests never touch the live `agent-fleet` socket.
- **Code hygiene**: no issue, ticket or phase numbers in code or comments.

## Dependencies & risks
- **tmux spreads a window resize across panes, so rails may drift.** Mitigation: D8 plus the rail-width criteria in US-1 and US-4.
- **Repaint burst**: an attach or resize sends SIGWINCH to every hidden Claude at once (N repaints of CPU). Dragging the terminal edge would do this repeatedly; D4's 150 ms debounce bounds it to one pre-size per settled size. Not gated: the CPU of N hidden repaints after a settled resize is accepted (non-goal), since today the same repaints happen one workspace at a time, on screen, at switch time.
- **Feedback loop with nested clients** (the test harness, or an `env -u TMUX` attach from a fleet pane). Mitigation: D2(b) and the US-3 criterion.
- **tmux features**: `resize-window`, the `client-resized` hook and `set -wu window-size` need tmux 2.9 or later. The conf already assumes 3.3+ in places, and CI runs 3.6.
- **Test harness**: client-size tests need a second throwaway socket that `_lib_cleanup` does not know about. Each such test kills it in its own trap.

## Assumptions
- **"A window another client is viewing" means any window in a session another client is attached to**, not only that client's current window. If wrong: A's pre-size skips B's non-current windows, and A's switch into B's workspace still resizes (as today). The narrower reading would make B's tab switches resize instead.
- **The most recent attach/resize/active client wins the size of unviewed windows** (matches tmux's `latest`). With two clients attached, `default-size` and unattached windows follow whichever client attached or resized last. If wrong: the other client keeps today's resize-on-switch behavior for unattached workspaces until its next resize. Two differently sized clients are already a non-goal.
- **US-4 (new windows) and US-6 (focus hook) are in scope.** The user chose the `default-size` approach for US-4 on 2026-11-05. US-6 serves the approved rule ("only when actually done"). If the user disagrees with US-6: drop one small change. Nothing else depends on it.
- **Nobody sets `default-size` by hand.** The conf does not set it, and presize now overwrites it on every attach and resize. If wrong: a user's own `default-size` is replaced by their client's size, which is what a fleet user wants for new agents anyway.
- **The default `window-size latest` is what users run.** Any other global policy turns pre-sizing off (D6). If wrong: those users get no resize fix, but no regression either.
- **Background ack for scraped agents** (D9) delays clearing their ✓ badge by one `capture-pane` round-trip. If wrong (something reads the ack synchronously right after goto): that reader sees `done` for under 100 ms. No such reader exists in the repo (`next-attention.sh` reads the snapshot before calling goto).
- **Status lines come from the global `status` option** (D1). If wrong: a session with its own `status` setting gets windows 1–5 rows off, and pays one resize on its first visit, as today.

## Open questions
None blocking.
