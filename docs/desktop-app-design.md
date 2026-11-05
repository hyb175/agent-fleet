# Fleet Desktop: design

A Rust desktop application that shows and drives a running fleet: every agent's
live terminal, the attention queue, and the event stream, arranged in views the
user builds and edits in place. It is a client of the fleet, not a second fleet.
State, guards and lifecycle stay in `agent-fleet`; the app renders them.

Status: design, 2026-11-04. Nothing here is built yet. The proofs marked
**done** were run on tmux 3.6a (Linux) while writing this document.

---

## 1. Goals and non-goals

**Goals**

- One window that shows many agents' terminals side by side, across workspaces,
  each typeable, with the fleet's state, questions and receipts around them.
- A dedicated, in-app workflow to customize the view: layout, what each tile
  shows, style and keys, with a live preview and a file the user can also edit
  by hand (section 7).
- Built only on the published fleet primitives (snapshot, events, CLI verbs,
  capabilities), so the terminal UI, the Go rails and the desktop app stay
  interchangeable views of one fleet.
- Linux and macOS, same as the fleet.

**Non-goals**

- No new agent runtime, state detection or session persistence in the app. The
  fleet's hooks, snapshot daemon and restore already do this.
- No socket API of its own. Agents keep using `agent-fleet`; herdr needs an API
  because herdr is the runtime, the desktop is not.
- No replacement for terminal attach. A Ghostty/WezTerm client on the fleet
  socket keeps working next to the app.
- Remote (federated `host/%N`) terminals are out of scope for v1. They show as
  rows that open over ssh, as the rail does today.

---

## 2. What we take from herdr, and what we do not

[herdr](https://github.com/maxjendrall/herdr) is a Rust, terminal-native
multiplexer for coding agents: workspaces, tiled panes, a sidebar with agent
states, notifications, a socket API and CLI.

| herdr idea | In Fleet Desktop |
| --- | --- |
| Two-layer sidebar: workspaces with one aggregate state dot, the selected workspace's agents below | `rail` widget, same two layers. The rollup is the snapshot's `S` record (`wait` > `working` > `done` > `idle`, the fleet's state rank). |
| "Done, unseen" as its own state | Fleet already has it: `done` drops to `idle` when visited. The app marks seen through a new `agent-fleet seen` verb (F1). |
| Terminal mode vs navigate mode behind one prefix | Same split: keys go to the focused terminal; the leader (default `Ctrl-a`, the fleet prefix) enters navigate mode. |
| Tiled panes, split / close / fullscreen / resize mode | Tiles on a grid, edited in Customize mode; `f` fullscreens a tile in navigate mode. |
| Mouse first: click to focus, drag borders, right-click menu | Same, plus drag-and-drop in Customize mode. |
| Nine built-in themes plus per-token overrides | The fleet's 34 presets (`conf/themes/`) plus per-token overrides in the view's style. |
| Onboarding picks the notification style | First run asks once: app toasts, fleet notifications, or both. |
| `session.json` restores layout on restart | Views are files; the open view and per-tile state are saved on exit. |
| `herdr wait` for agents | Fleet's `events --since <cursor>` already serves this. |

**Where we deliberately differ**

- **State is exact, not scraped.** herdr reads the screen per agent every
  300 to 500 ms. Fleet's hooked agents report state and receipts natively; the
  app inherits that and shows scrape-tier agents (`label` ending `~`) as such.
- **Ids are stable.** herdr's pane ids are positional and renumber when items
  close. Fleet's `%N` pane ids and task ids do not, and tiles bind to queries or
  task ids, never to positions (section 7.3).
- **Writes are guarded.** Answers carry a fingerprint, messages carry receipts,
  kills carry process evidence. The app never types an answer or a message
  itself; it calls the verb that holds the guard.

---

## 3. Architecture

```
┌──────────────────────── Fleet Desktop (one process) ─────────────────────────┐
│ webview (TS)                     │ Rust core                                 │
│  views / tiles / customize UI    │  fleet-core                               │
│  xterm.js per terminal tile  ◄───┤   snapshot reader (file watch + poll)     │
│  rail, inbox, events widgets     │   events tail  (agent-fleet events)       │
│                                  │   verb runner  (agent-fleet <verb>, k=v)  │
│                                  │   capabilities gate                       │
│                                  │  fleet-tmux                               │
│                                  │   one control-mode client per workspace   │
│                                  │   %output → per-pane byte channel         │
│                                  │   keys → send-keys -H, resize → refresh-c │
│                                  │  views                                    │
│                                  │   TOML load/save (toml_edit), hot reload  │
└──────────────┬───────────────────┴───────────────┬───────────────────────────┘
               │ read                              │ exec / control mode
     $AF_CACHE_DIR/fleet.snapshot          agent-fleet …   tmux -L agent-fleet -C
```

**Process model.** One app process. The Rust core owns all I/O; the webview only
renders and sends intents (`focus tile`, `keys`, `answer approve`, `save view`).
Terminal bytes travel to the webview over a Tauri channel per tile, not as JSON
events, so a busy agent does not serialize through the event bus.

**Crates** (a `desktop/` Cargo workspace next to `ui/`):

| crate | does | depends on |
| --- | --- | --- |
| `fleet-core` | snapshot parser, events cursor loop, verb runner and `key=value` status parser, capabilities | std, `notify`, `tokio` (process) |
| `fleet-tmux` | control-mode client: line protocol, `%output` octal unescape, `%begin/%end` command replies, `%layout-change`, `%exit`; seeding, keys, resize | `tokio` |
| `views` | view and settings schema, validation, `toml_edit` round trip | `serde`, `toml_edit` |
| `app` | Tauri 2 shell: commands, channels, window menu, notifications, tray | `tauri`, plugins `notification`, `single-instance` |

The webview is plain TypeScript with `xterm.js` (WebGL renderer) and no framework
beyond what the customize editor needs. The Rust core is UI-agnostic, so the
frontend can be replaced without touching the hard parts (see D1).

---

## 4. The fleet contract the app uses

Everything the app knows or changes goes through a primitive that already exists,
except the four small additions in section 8.

| Need | Primitive | Notes |
| --- | --- | --- |
| Paths, feature flags | `agent-fleet capabilities` | Run at start. Features absent from it are hidden, not greyed: no `send_receipts` for a kind means no "message" action on its tiles. |
| Workspaces, agents, states, questions, diffstats | `fleet.snapshot` (`docs/snapshot-format.md`) | File watch plus 1 s poll. Same staleness rule as every reader: `now - epoch > interval*3 + 7` shows a banner and disables actions. The Rust parser runs against `tests/fixtures/snapshot/`, shared with the Go suite, including `extra-field.snapshot`. |
| What changed, in order | `agent-fleet events --since <cursor>` | 500 ms loop. Drives toasts (`question`, `state wait`, `turn_end`, `delivery`). `status=expired` (exit 6) resyncs from the snapshot and restarts at the returned cursor. |
| Focus an agent | tile focus + `agent-fleet seen` (F1) | Not `goto`: `goto` switches the user's tmux client, which the app must never hijack. |
| Spawn | `agent-fleet task "<prompt>" --repo … --name …` | Prints `<task-id> <pane-id>`; the new agent opens where the user chose (focused tile, new tile, background). |
| Answer a waiting agent | `agent-fleet answer <pane> fp`, then `answer <pane> approve\|deny\|text … --fp <sum>` | The fingerprint is taken when the question card renders, so an answer to a screen that changed since is refused (`stale`) instead of landing on the wrong prompt. |
| Message an idle agent | `agent-fleet send <pane> "<text>" --op <uuid>` | Status line is parsed as is: `consumed`, `turn_ended`, `busy`, `mismatch`, `unconfirmed`, `refused reason=…`. A `busy` result offers "queue until idle"; the queue lives in the app and retries with the same `--op`. |
| Interrupt | `agent-fleet interrupt <pane>` | Shown as `sent`, never as "stopped" (no native receipt exists). |
| Kill | `agent-fleet kill <target> --wait` | The tile shows `stopped` only on `status=stopped`; `unknown` keeps a warning with the survivors. |
| Lifecycle, review | `task done\|drop\|clean`, `review <id> --diff-only` | Review widget renders the diff text. |
| Workspace and tab edits | `rename-workspace`, `rename-tab`, `move` | Context menu actions. |
| History | `agent-fleet history` | History widget. |

The verb runner is one function: run `agent-fleet <args>` with a timeout, return
exit code, stdout lines and a map of the last line's `key=value` tokens. Every
caller branches on `status=` and exit code exactly as `docs/runtime-contract.md`
lists them; there is no second interpretation of fleet outcomes in the app.

---

## 5. Terminal tiles

### 5.1 Control mode, one client per workspace

A terminal tile shows one agent pane. The app reads and drives panes through
tmux control mode (`tmux -L <socket> -C attach -t <workspace>`), the approach
iTerm2 uses for its tmux integration:

- **Output.** tmux sends `%output %<pane> <octal-escaped bytes>` for every pane
  of the attached session's windows, current or not, and nothing for other
  sessions (**P2 done**: a client on session `a` received both `a` windows'
  panes and none of session `b`'s). So the app opens one control client per
  workspace that has at least one visible tile, and closes it when the last
  such tile goes away. Panes in that workspace that no tile shows are muted
  with `refresh-client -A '%N:off'` and re-enabled with `on` plus a re-seed
  when they become visible (P5).
- **Seeding.** A tile that starts showing a pane first draws its current
  screen: `capture-pane -p -e -J -S -<scrollback> -t %N` (with `-a` when
  `#{alternate_on}` is set), then cursor position from `#{cursor_x}` and
  `#{cursor_y}`, then the mouse and keypad modes tmux reports
  (`#{mouse_any_flag}`, `#{mouse_sgr_flag}`, `#{keypad_cursor_flag}`, …)
  replayed as DECSET sequences, so xterm.js encodes mouse and keys the way the
  agent expects (P4). Live `%output` is buffered from the moment the capture
  is requested and applied after it.
- **Keys.** xterm.js `onData` bytes go out as `send-keys -H -t %N <hex …>`,
  batched per animation frame. **Paste** goes through `load-buffer` +
  `paste-buffer -p -d`, which lets tmux bracket the paste only if the pane asked
  for bracketed paste, the same transport `send` uses.
- **Resize.** A tile's cell size is sent as `refresh-client -C @<window>:<cols>x<rows>`
  (**P1 done**: two windows of one session held 80x20 and 50x12 at the same
  time from one control client). Fleet agents are one pane per window, so the
  window size is the pane size.

### 5.2 Size ownership: a terminal client wins

**P6 done:** with a normal terminal client attached at 160x50 and the app's
control client requesting 80x20 for the same window, the window became 80x20 and
stayed so while the normal client typed, then returned to 160x49 when the
control client detached. Left alone, the app would shrink the user's terminal
view of any agent it also shows.

Rule: the snapshot's `C` records say which window each attached client is
viewing. If any non-control client is on window W, the app does not send a size
for W; its tile renders tmux's current size, letterboxed and scaled down to fit,
with a small "sized by terminal" marker. When that client moves away, the tile
takes the size back. Control-mode clients are told apart by name (`#{client_control_mode}` when listing clients).

### 5.3 Typing in the app and `send`'s human gate

`send` refuses with `human_active` when the session's `#{session_activity}` is
recent. That clock moves on client keystrokes, attach and switch-client, and does
**not** move on `send-keys` (proved for the runtime contract). App keystrokes go
through `send-keys`, so without a change a human typing in the app would be
invisible to that gate; only the `composer_busy` screen check would catch a
draft. F4 closes this: the app touches `panes/<pane>.typed` (at most every
500 ms while typing), and `send` treats a recent mtime there the same as a recent
`session_activity`.

---

## 6. Interaction model

**Modes.** *Terminal mode* (default): keys go to the focused tile's agent.
*Navigate mode* (leader, default `Ctrl-a`; `Ctrl-a Ctrl-a` sends a literal
`Ctrl-a`): `h j k l` move tile focus, `Space` next attention (same order as
`Prefix Space`), `i` inbox, `o` palette, `f` fullscreen tile, `1`–`9` switch
view, `e` Customize, `Esc` back. Movement stays in navigate mode, mutating
actions return to terminal mode, as in herdr.

**Palette** (`Ctrl-a o`, or `Ctrl-K` / `Cmd-K`): fuzzy over agents in attention
order, workspaces, actions and views. Every action has an id
(`agent.answer.approve`, `view.switch.triage`, …); palette, menus, context menus
and key bindings all call the same ids.

**Mouse.** Click focuses a tile or rail row; wheel scrolls the terminal
scrollback (a tile in scrollback shows a "live ↓" pill); right-click opens the
context menu for the agent under the cursor (answer, message, interrupt,
review, rename, move, kill).

**Tile chrome.** One header line per terminal tile: state glyph (`◆` wait,
spinner working, `✓` done, `○` idle, shapes readable without color), tab name,
workspace, age, diffstat, isolation rung, and, for `wait`, the agent's question
with Approve / Deny / Reply buttons wired to the fingerprinted `answer`.

**Notifications.** Native OS notifications from the events stream: `question`,
`state wait`, and `turn_end` for unfocused agents. Clicking one focuses the tile
bound to that pane, or swaps it into the focused tile if none is. First run asks
whether the app should replace fleet's own notifications (then it tells the user
to set `AGENT_FLEET_NOTIFY=0`) or add to them.

---

## 7. Views and the Customize workflow

The desktop's whole layout is a **view**: a grid of tiles, what each tile is
bound to, a style, and optional key overrides. A view is a TOML file; the in-app
editor is a front end to that file. Hand edits and editor edits are the same
thing.

### 7.1 Files

```
~/.config/agent-fleet/desktop/
  desktop.toml           settings: default view, leader, notifications, font
  views/
    triage.toml          one view per file; the file name is its id
    focus.toml
```

Built-in presets ship read-only inside the app (`agent-fleet-desktop defaults`
prints them). Editing a preset writes a copy into `views/` first.

### 7.2 Schema

```toml
# ~/.config/agent-fleet/desktop/views/triage.toml
name = "Triage"
grid = [12, 8]                     # columns, rows; tiles snap to it

[style]
theme = "follow"                   # follow the fleet's active theme, or a preset name
density = "comfortable"            # or "compact"
font = { family = "JetBrains Mono", size = 13 }
[style.tokens]                     # optional per-token overrides on top of the theme
WAIT = "#ff6188"

[[tile]]
widget = "rail"
at = [0, 0, 3, 8]                  # col, row, width, height

[[tile]]
widget = "terminal"
at = [3, 0, 6, 5]
bind = { attention = 1 }           # the most urgent agent, re-bound as the queue moves
hold = "focused"                   # never swap the agent while this tile has focus

[[tile]]
widget = "inbox"
at = [9, 0, 3, 5]

[[tile]]
widget = "grid"                    # auto-tiles every agent the query matches
at = [3, 5, 9, 3]
bind = { state = ["working"], sort = "age", limit = 4 }
empty = "Nothing running"

[keys]                             # optional, view-local overrides
"leader g" = "view.switch.grid"
```

**Widgets.** `terminal` (one agent), `grid` (several agents, auto-tiled),
`rail` (workspaces and their agents, herdr's two layers), `inbox` (wait and
done queue with question or diffstat preview and inline answers), `events`
(the live stream, filterable by kind), `review` (diff of the bound done task),
`history`, `status` (capabilities, daemon health, staleness).

### 7.3 Bindings

A tile says *which* agents it shows as a rule over snapshot fields, so a view
does not rot as agents come and go.

| Binding | Means | Survives restart |
| --- | --- | --- |
| `{ task = "t1788836253-361" }` | that task's agent (resolved through the task record's `pane`, which restore re-links to the new pane id) | yes |
| `{ attention = n }` | n-th agent in attention order among `wait` and `done` | yes |
| `{ workspace, state, kind, iso, sort, limit, index }` | filter, sort (`attention`, `age`, `name`), then take `index` or the first `limit` | yes |
| `{ follow = "selection" }` | whatever is selected in the rail or palette | yes |
| `{ pane = "%12" }` | that pane only; the editor warns that pane ids reset on cold boot | no |

Rebinding rules, applied on every snapshot change:

1. **Sticky.** A tile keeps its current agent while that agent still matches.
2. **Hold.** With `hold = "focused"` (default for `terminal`), a focused tile
   or one typed into in the last 5 s never swaps; the next match waits in the
   header ("next: api-fix ◆").
3. **Announced.** A swap flashes the header and names the new agent, so a
   human never types into an agent they did not choose.

### 7.4 The Customize workflow

**Entry points:** `Ctrl-a e`, the toolbar's "Customize" button, "Edit view…" in
any tile's context menu (opens with that tile selected), or
`agent-fleet-desktop --customize <view>`.

The app takes a copy of the view file's text on entry; Cancel restores it
exactly, and the editor keeps an undo stack (`Ctrl-z` / `Ctrl-Shift-z`) inside
the session. Agents stay live the whole time: terminals keep streaming, they
just stop taking keys.

```
┌ Customize: Triage ──────────────────────────── [Undo] [Cancel] [Save ▾] ┐
│ Layout │ Style │ Keys                                                   │
├────────┴──────────────────────────────────────────────┬────────────────┤
│ ┌─ rail ──────┐┌─ terminal · attention 1 ─────┐┌ inbox┐│ WIDGETS        │
│ │ ◆ api   2   ││ ◆ api-fix  waiting 4m        ││ ◆ 2  ││  terminal      │
│ │   ◆ 1:fix   ││ (live, dimmed)               ││ ✓ 1  ││  grid          │
│ │ ✓ docs  1   ││                    ◢ resize  ││      ││  rail          │
│ └─────────────┘└──────────────────────────────┘└──────┘│  inbox         │
│                ┌─ grid · working, by age, 4 ──────────┐│  events        │
│                │ ⠋ ui-polish   ⠋ migrate   + 2 more   ││  review …      │
│                └──────────────────────────────────────┘├────────────────┤
│ 12 × 8 grid · drag a widget in, drag edges to resize    │ INSPECTOR      │
│                                                         │ widget terminal│
│                                                         │ show  [attention ▾] n=1
│                                                         │ hold  [focused ▾]
│                                                         │ matches now: 3 │
│                                                         │  ◆ api-fix     │
│                                                         │  ◆ db-index    │
│                                                         │  ✓ docs        │
└─────────────────────────────────────────────────────────┴────────────────┘
```

1. **Start from something.** A gallery of the presets and the user's views,
   each thumbnail rendered from the live snapshot, so "Grid" shows *your*
   working agents, not a stock picture. "Duplicate" makes an editable copy.
2. **Layout tab.** The canvas is the real window with a grid overlay. Drag a
   widget from the palette onto empty cells; drag edges to resize (snaps to the
   grid); drag a tile onto another to swap; `Delete` removes. Overlaps are not
   possible: a drop that would overlap highlights red and is refused.
3. **Bind tiles.** Selecting a tile opens the inspector: widget options and the
   binding as a small form (show: attention / task / filter / follow selection;
   then the fields that kind needs). Under it, **matches now** lists the agents
   the rule selects against the current snapshot, updating live, so the user
   sees the effect before saving. Zero matches shows the tile's `empty` text,
   which is editable there.
4. **Style tab.** Theme picker over the fleet presets with live preview on the
   real tiles, "follow fleet theme" on by default (so `agent-fleet theme X`
   restyles the app). Each of the nine tokens (`BG`, `SURFACE`, `HL`, `FG`,
   `MUTED`, `ACCENT`, `WAIT`, `WORKING`, `DONE`) can be overridden with a color
   picker; a contrast check flags state colors that do not separate from `BG`.
   Density, font family and size apply live.
5. **Keys tab.** Every action id with its bindings, searchable. "Record" takes
   the next chord; a conflict with another binding in the same mode is shown
   inline with "replace" or "cancel". Bindings set here go to the view's
   `[keys]`, or to `desktop.toml` with "apply to all views".
6. **Save.** "Save" writes the view file, "Save as…" a new one, "Set as
   default" also writes `desktop.toml`. The editor writes through `toml_edit`,
   so comments and key order in a hand-edited file survive a save.

**Hand editing.** The app watches `views/` and `desktop.toml`. A valid edit
applies live. An invalid one keeps the last good version on screen and shows
the file, line and reason in a banner. Unknown keys are warnings, not errors, so
a newer view file still loads in an older app.

**Validation**, the same code for the editor and for files: tiles inside the
grid, no overlaps, known widget, binding fields valid for the widget, at least
one tile. Terminal tiles smaller than 20x5 cells render as a compact card
(glyph, name, question) instead of a terminal.

### 7.5 Presets

| Preset | Layout |
| --- | --- |
| Focus | rail + one big terminal following the rail selection |
| Triage | rail + attention-1 terminal + inbox + working grid (the example above) |
| Grid | rail + `grid` of every agent in the selected workspace |
| Review | done tasks list + `review` diff + the task's terminal |

---

## 8. Fleet-side changes

Small, each its own commit with tests, none needed for a read-only first build.

| | Change | Why |
| --- | --- | --- |
| F1 | `agent-fleet seen <id\|%pane>`: the `status.sh clear-done` that `goto` runs, without switching any client | the app marks a visited agent seen without moving the user's terminal |
| F2 | theme presets keep the 16-color ANSI palette (`AF_THEME_ANSI_0`…`_15`, appended; `gen-theme.sh` already reads them upstream and drops them), re-imported for all presets | terminal tiles need an ANSI palette that matches the fleet theme |
| F3 | `agent-fleet theme show`: `name=` plus the active theme's tokens as `key=value` | "follow fleet theme" without parsing shell files or the generated tmux conf |
| F4 | `send`'s `human_active` gate also honours a recent `panes/<pane>.typed` mtime | typing in the app goes through `send-keys`, which tmux's activity clock does not see (5.3) |

Also an optional `agent-fleet desktop` verb that launches the app if it is
installed, mirroring `Prefix g` for `desk`.

---

## 9. Failure modes

| Situation | Behavior |
| --- | --- |
| Snapshot stale (daemon died) | banner, actions disabled, terminals keep streaming (control mode does not depend on the daemon) |
| Fleet server down | "No fleet running" screen with a Start button (`agent-fleet attach` in the background) |
| Control client exits (`%exit`) | tiles of that workspace show "reconnecting", retry with backoff, re-seed on reconnect |
| Pane gone | tile falls back to its binding's next match, or its `empty` text |
| A verb times out | the action shows "unknown", never success; `send` and `answer` results are re-read with `send --status` and a fresh fingerprint |
| Events cursor expired | resync from the snapshot, continue from the new cursor, no duplicate toasts (toasts are keyed by event line) |
| tmux output floods a hidden pane | muted with `refresh-client -A '%N:off'`; visible floods are paced by control mode's `pause-after` flow control (P5) |
| Scrape-tier agent | shown with `~`, no message action unless `capabilities` lists its kind |
| Federated pane | row only, opens over ssh |

---

## 10. Testing

- `fleet-core`: snapshot parsing against `tests/fixtures/snapshot/` (the same
  files the Go suite parses, so the two readers cannot drift); the status-line
  parser against every outcome line in `docs/runtime-contract.md`.
- `fleet-tmux`: the protocol parser against recorded control-mode transcripts
  (the probes in section 5 produce them); an integration test on a scratch
  tmux socket with the fake hooked agent from `tests/t-send.sh`: seed, stream,
  type, resize, mute, reconnect.
- `views`: schema round trip (load → save → byte-identical for an unchanged
  file, comments kept), validation cases, binding resolution and the
  sticky/hold rules on synthetic snapshots.
- End to end: WebDriver (`tauri-driver`) runs the Customize flow on a scratch
  fleet: duplicate a preset, add a tile, bind it, save, reload, assert the file
  and the screen.
- CI: a `desktop` job on Linux and macOS running `cargo test` for the three
  library crates; the WebDriver job on Linux only.

---

## 11. Milestones

| | Scope | Done when |
| --- | --- | --- |
| M0 | Remaining proofs: P3, P4, P5 | each recorded in this doc with versions, like the runtime contract's proofs |
| M1 | Read-only: rail, one terminal tile (no input), inbox, events toasts, staleness | a cold-booted fleet displays in the app with every state glyph correct against the snapshot fixtures |
| M2 | Interactive: keys, paste, mouse, resize with size ownership, answer, send, interrupt, kill, spawn, palette; F1, F4 | the agent-fleet flows in `t-send.sh` pass when driven from the app |
| M3 | Views and the Customize workflow; presets; F2, F3 | the WebDriver customize test passes, and a hand-edited view reloads live |
| M4 | Notifications, onboarding, packaging (Nix flake output, `.app`, `.deb`/AppImage) | installs and runs on both platforms from CI artifacts |

---

## 12. Proofs

| | Question | Result |
| --- | --- | --- |
| P1 | Can one control client hold different sizes for two windows? | **done**: `refresh-client -C @0:80x20` and `@1:50x12` held together (tmux 3.6a). |
| P2 | Which panes does `%output` cover? | **done**: every window of the attached session, current or not; nothing from other sessions. |
| P3 | Does xterm.js (WebGL) in WebKitGTK keep up with a claude redraw storm across 6 tiles? | open. Fallback: the canvas renderer, then D1's alternative frontend. |
| P4 | After seeding from `capture-pane` plus replayed mode flags, do mouse, keypad and bracketed paste behave as in a real attach, for claude and codex? | open |
| P5 | Do `refresh-client -A '%N:off'` and `-f pause-after=` behave as documented on tmux 3.2 to 3.6? | **partly done**: on 3.6a, `-A %N:off` stopped that pane's `%output` completely and `on` resumed it; `#{client_control_mode}` reads `1` for the app's client. Open: `pause-after`, and versions before 3.6. |
| P6 | What happens when a normal client and the app share a window? | **done**: the control client's size wins until it detaches; hence the rule in 5.2. |

---

## 13. Decisions

**D1. Tauri 2 with an xterm.js webview, not a native Rust UI.** xterm.js is the
most exercised terminal renderer available (VS Code), and the Customize editor
is mostly drag-and-drop, forms and color pickers, which the webview has
natively. The Rust core does all fleet and tmux work and has no UI types, so a
native frontend (gpui or egui with `alacritty_terminal`, the Zed approach) can
replace the webview later without touching it. Revisit if P3 fails.

**D2. tmux control mode, not one `tmux attach` per tile.** A PTY per tile
would draw tmux's status line and window chrome, size every client to the
smallest one, and cost a tmux client per agent. Control mode gives per-pane byte
streams and per-window sizes (P1, P2) over one connection per workspace, so
agents from different workspaces sit side by side in one view.

**D3. Every mutation goes through `agent-fleet`.** tmux is used directly only
for terminal I/O: output, keystrokes, paste and resize. Answers, messages,
interrupts and kills keep their guards and receipts in one implementation,
tested by the existing suite.

**D4. Tiles bind to rules and task ids, not positions or pane ids.** Fleets
churn; a layout of pane ids is wrong after the first cold boot.

**D5. A view is a file; the editor writes the file.** One source of truth, hand
edits and the editor never disagree, views are shareable and diffable.

**D6. A terminal client wins window size.** The app adapts its tile instead of
shrinking the user's terminal (P6).

---

## 14. Open questions

- Should a view be able to switch automatically, for example to Triage when the
  first agent enters `wait`? Easy to add as a `[when]` table later; left out
  until a real need shows up.
- Multiple app windows, each with its own view, are allowed by the design; is
  per-monitor default view worth a setting in v1?
- Remote terminals: the same control-mode client works over
  `ssh <host> tmux -L agent-fleet -C attach`. It would make federated agents
  first-class tiles; deferred past v1.

Sources for herdr: [GitHub README](https://github.com/maxjendrall/herdr),
[tecmint overview](https://tecmint.com/herdr-run-ai-coding-agents-in-linux-terminal),
[bitdoze review](https://www.bitdoze.com/herdr-agent-multiplexer/).
