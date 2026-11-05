# Fleet Desktop: design

A Rust desktop application that shows and drives a running fleet: every agent's
live terminal, the attention queue, and the event stream, arranged in views the
user builds and edits in place. It is a client of the fleet, not a second fleet.
State, guards and lifecycle stay in `agent-fleet`; the app renders them.

Status: design, 2026-11-04. Nothing here is built yet. The proofs marked
**done** were run on tmux 3.6a (Linux) while writing this document. The UI is
native GPUI from the first milestone (D1); an earlier draft used a Tauri webview.

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
- macOS first, as the primary desktop; Linux from the same code, second.

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
│ app (GPUI)                       │ core (no UI types)                        │
│  views / tiles / customize UI    │  fleet-core                               │
│  terminal element per tile   ◄───┤   snapshot reader (file watch + poll)     │
│   paints term's grid             │   events tail  (agent-fleet events)       │
│  rail, inbox, events widgets     │   verb runner  (agent-fleet <verb>, k=v)  │
│                                  │   capabilities gate                       │
│                                  │  fleet-tmux                               │
│                                  │   one control-mode client per workspace   │
│                                  │   %output → per-pane byte channel         │
│                                  │   keys → send-keys -H, resize → refresh-c │
│                                  │  term                                     │
│                                  │   alacritty_terminal Term per tile        │
│                                  │   key/mouse encoding from the Term's modes│
│                                  │  views                                    │
│                                  │   TOML load/save (toml_edit), hot reload  │
└──────────────┬───────────────────┴───────────────┬───────────────────────────┘
               │ read                              │ exec / control mode
     $AF_CACHE_DIR/fleet.snapshot          agent-fleet …   tmux -L agent-fleet -C
```

**Process model.** One process, no IPC between UI and core. Each control client
runs on a reader thread that parses lines and feeds `%output` bytes into its
panes' `Term`s; the GPUI view of a tile is notified once per frame at most and
paints the `Term`'s grid directly. The UI sends intents to the core
(`focus tile`, `keys`, `answer approve`, `save view`) as plain method calls.

**Crates** (a `desktop/` Cargo workspace next to `ui/`):

| crate | does | depends on |
| --- | --- | --- |
| `fleet-core` | snapshot parser, events cursor loop, verb runner and `key=value` status parser, capabilities | std, `notify` |
| `fleet-tmux` | control-mode client: line protocol, `%output` octal unescape, `%begin/%end` command replies, `%layout-change`, `%exit`; seeding, keys, resize | std |
| `term` | a `Term` per tile, seeded and fed by `fleet-tmux`; keys, mouse and paste encoded from the `Term`'s mode flags; selection and scrollback | `alacritty_terminal` |
| `views` | view and settings schema, validation, `toml_edit` round trip | `serde`, `toml_edit` |
| `app` | GPUI window, tile grid, terminal element, rail, inbox, palette, Customize editor, notifications | `gpui-kit` (re-exports a pinned `gpui`), `notify-rust` |

The library crates use std threads and channels, no async runtime; `app` runs
their blocking calls on GPUI's background executor. They have no GPUI types,
so they test with plain `cargo test` and stay usable by a future CLI or TUI.

The terminal element starts from `gpui-terminal` (0.1, MIT/Apache-2.0, built on
`alacritty_terminal`, takes any byte streams instead of a PTY), vendored into
`app` and extended with what it lacks: selection, scrollback navigation, mouse
reporting and bracketed paste. Zed's own `terminal` and `terminal_view` crates
are the reference for those but are GPL-3.0, so their code is not copied.

---

## 4. The fleet contract the app uses

Everything the app knows or changes goes through a primitive that already exists,
except the small additions in section 8.

| Need | Primitive | Notes |
| --- | --- | --- |
| Paths, feature flags | `agent-fleet capabilities` | Run at start. Features absent from it are hidden, not greyed: no `send_receipts` for a kind means no "message" action on its tiles. |
| Workspaces, agents, states, questions, diffstats | `fleet.snapshot` (`docs/snapshot-format.md`) | File watch plus 1 s poll. Same staleness rule as every reader: `now - epoch > interval*3 + 7` shows a banner and disables actions. The Rust parser runs against `tests/fixtures/snapshot/`, shared with the Go suite, including `extra-field.snapshot`. |
| What changed, in order | `agent-fleet events --since <cursor>` | Run when the `events` file that `capabilities` names changes (file watch, 100 ms debounce), not on a timer: one call costs about 30 ms of CPU (12.1), so a 500 ms loop would idle at 6% of a core. Drives toasts (`question`, `state wait`, `turn_end`, `delivery`). `status=expired` (exit 6) resyncs from the snapshot and restarts at the returned cursor. |
| Focus an agent | tile focus + `agent-fleet seen` (F1) | Not `goto`: `goto` switches the user's tmux client, which the app must never hijack. |
| Spawn | `agent-fleet task "<prompt>" --repo … --name …` | Prints `<task-id> <pane-id>`; the new agent opens where the user chose (focused tile, new tile, background). |
| Answer a waiting agent | `agent-fleet answer <pane> fp`, then `answer <pane> approve\|deny\|text … --fp <sum>` | The fingerprint is taken when the question card renders, so an answer to a screen that changed since is refused (`stale`) instead of landing on the wrong prompt. |
| Message an idle agent | `agent-fleet send <pane> "<text>" --op <uuid>` | Status line is parsed as is: `consumed`, `turn_ended`, `busy`, `mismatch`, `unconfirmed`, `refused reason=…`. A `busy` result offers "queue until idle"; the queue lives in the app and retries with the same `--op`. |
| Interrupt | `agent-fleet interrupt <pane>` | Shown as `sent`, never as "stopped" (no native receipt exists). |
| Kill | `agent-fleet kill <target> --wait` | The tile shows `stopped` only on `status=stopped`; `unknown` keeps a warning with the survivors. |
| Lifecycle, review | `task done\|drop\|clean`, `review <id> --diff-only` | Review widget renders the diff text. |
| Workspace and tab edits | `rename-workspace`, `rename-tab`, `move` | Context menu actions. |
| Open an editor | `agent-fleet editor <task-id\|%pane>` (F5) | Prints `<editor-id> <pane-id>`; the tile binds to the editor id (5.4). |
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
- **Seeding.** A tile that starts showing a pane first feeds its `Term` the
  current screen: `capture-pane -p -e -J -S -<scrollback> -t %N` (with `-a`
  when `#{alternate_on}` is set), then cursor position from `#{cursor_x}` and
  `#{cursor_y}`, then the mouse and keypad modes tmux reports
  (`#{mouse_any_flag}`, `#{mouse_sgr_flag}`, `#{keypad_cursor_flag}`, …)
  replayed as DECSET sequences, so the `Term`'s mode flags, and with them the
  key and mouse encoding, match what the agent expects (P4). Live `%output` is
  buffered from the moment the capture is requested and applied after it.
- **Keys.** GPUI key and mouse events are encoded by `term` against the tile's
  `Term` modes and go out as `send-keys -H -t %N <hex …>`, batched per frame.
  **Paste** goes through `load-buffer` +
  `paste-buffer -p -d`, which lets tmux bracket the paste only if the pane asked
  for bracketed paste, the same transport `send` uses.
- **Resize.** A tile's pixel size divided by the font's cell metrics is sent as
  `refresh-client -C @<window>:<cols>x<rows>`, and the `Term` resized to match
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

### 5.4 Editors in tiles

A terminal tile can show an editor (Neovim, or whatever `$AGENT_FLEET_EDITOR`
names) next to the agent whose work it edits. "Open editor here" on an agent
tile runs `agent-fleet editor <task-id>` (F5), which opens the editor in a new
tab in that task's workspace and directory (its worktree on a `wt` rung) and
prints the editor's id; the new tile binds to that id. A second call for the
same task returns the live editor instead of opening another.

F5 is needed because `add --cmd nvim` does not fit: it tags the pane as an agent
of kind `nvim`, so the rail lists it as idle, and `persist-restore.sh` relaunches
only known agent kinds, so after a cold boot the editor comes back as a shell
and its record points at the old pane id. An editor pane carries
`@fleet-editor` instead of `@fleet-agent-kind`, so the rail, the snapshot's agent
rows and `send` ignore it, and restore relaunches its recorded command in its
directory and re-links the record, as it does for agents.

Neovim then runs exactly as it does under tmux in Ghostty today: `TERM` is
tmux's, and `%output` carries the pane's own bytes, so the tile's `Term` parses
what Neovim wrote. What the tile must do on top of an agent tile (all M2):

- **Mouse** reporting in SGR mode, with Shift-drag selecting text instead.
- **Cursor shape** (DECSCUSR): block in normal mode, bar in insert.
- **Focus events**: tmux sends focus only to the active pane of the session's
  current window, and tiles show panes of different windows; switching the
  window from the app would also move a terminal attached to that session. So
  when tile focus changes and the `Term` shows mode 1004 set, the app sends
  `\e[O` / `\e[I` itself through `send-keys -H` (P8), and `autoread` and
  `FocusLost` work.
- **Clipboard**: Neovim's OSC 52 yank lands in a tmux buffer once the fleet sets
  `set-clipboard on` (F6); control mode reports `%paste-buffer-changed` (P8),
  and the app copies `show-buffer` to the system pasteboard. Cmd-V pastes
  through `paste-buffer -p` like any paste.
- **Styles**: curly and colored underlines (SGR `4:3`, `58`) for diagnostics.
- **Keys**: `Ctrl-a Ctrl-a` sends Neovim's `Ctrl-a`, as with the tmux prefix now.
  On macOS, `option_as_meta` in `desktop.toml` (default on) sends Option as
  Alt; Cmd chords stay with the app.

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
open editor here, review, rename, move, kill).

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
  desktop.toml           settings: default view, leader, notifications, font, option_as_meta
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
| `{ editor = "selection" }` | the editor opened for the selected agent's task, or `empty` when it has none; with a `follow` tile beside it, this is the agent-plus-Neovim layout | yes |
| `{ task = "<editor-id>" }` | that editor, as for any task id | yes |
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
just stop taking keys. The editor's forms, dropdowns, lists and tabs are
`gpui-kit` components; tile dragging uses GPUI's own drag and drop, the same
mechanism Zed's tabs and panes use.

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
| F5 | `agent-fleet editor <task-id\|%pane>`: opens `$AGENT_FLEET_EDITOR` (else `$VISUAL`, `$EDITOR`, `nvim`) in a new tab in the task's workspace and dir, tagged `@fleet-editor`; writes a record with `kind editor`, `cmd <command>`, `for <task-id>`; returns the live one if it exists. `persist-restore.sh` relaunches `cmd` in `dir` and re-links the record | an editor beside an agent that is not mistaken for an agent and survives a cold boot (5.4) |
| F6 | `set -s set-clipboard on` in the fleet's tmux conf | tmux's default `external` ignores an app's OSC 52, so a Neovim yank in a tile never reaches the app; `on` still forwards it to an attached terminal as before (P8) |

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
- `term`: recorded `%output` transcripts (including a claude redraw) fed into a
  `Term`, asserting grid text and cursor; key and mouse encoding per mode flag
  against fixed byte strings.
- `views`: schema round trip (load → save → byte-identical for an unchanged
  file, comments kept), validation cases, binding resolution and the
  sticky/hold rules on synthetic snapshots.
- End to end: `#[gpui::test]` with GPUI's headless test context drives the
  Customize flow on a scratch fleet: duplicate a preset, add a tile, bind it,
  save, reload, assert the file and the tile tree. Simulated keystrokes and
  drags, no window server.
- CI: a `desktop` job on Linux and macOS running `cargo test` for the whole
  workspace, end-to-end tests included.

---

## 11. Milestones

| | Scope | Done when |
| --- | --- | --- |
| M0 | Remaining proofs: P3, P4, P5, P7 | each recorded in this doc with versions, like the runtime contract's proofs |
| M1 | Read-only: rail, one terminal tile (no input), inbox, events toasts, staleness | a cold-booted fleet displays in the app with every state glyph correct against the snapshot fixtures |
| M2 | Interactive: keys, paste, mouse, selection, scrollback, resize with size ownership, answer, send, interrupt, kill, spawn, palette; editor tiles with cursor shape, focus events, OSC 52 clipboard and curly underlines; F1, F4, F5, F6 | the agent-fleet flows in `t-send.sh` pass when driven from the app, and a Neovim tile yanks to the macOS pasteboard and comes back after a cold boot |
| M3 | Views and the Customize workflow; presets; F2, F3 | the headless customize test passes, and a hand-edited view reloads live |
| M4 | Notifications, onboarding, packaging: a signed, notarized `.app` first (macOS shows notifications only for a bundled app identity), then a Nix flake output and `.deb`/AppImage | the `.app` from CI installs and runs on a clean Mac; Linux artifacts run on NixOS |

---

## 12. Proofs

| | Question | Result |
| --- | --- | --- |
| P1 | Can one control client hold different sizes for two windows? | **done**: `refresh-client -C @0:80x20` and `@1:50x12` held together (tmux 3.6a). |
| P2 | Which panes does `%output` cover? | **done**: every window of the attached session, current or not; nothing from other sessions. |
| P3 | Does the GPUI terminal element keep up with a claude redraw storm across 6 tiles at 60 fps? | open. Zed's terminal, GPUI over `alacritty_terminal`, is the existence proof; this checks our element and our per-frame batching. |
| P4 | After seeding from `capture-pane` plus replayed mode flags, do mouse, keypad and bracketed paste behave as in a real attach, for claude and codex? | open |
| P5 | Do `refresh-client -A '%N:off'` and `-f pause-after=` behave as documented on tmux 3.2 to 3.6? | **partly done**: on 3.6a, `-A %N:off` stopped that pane's `%output` completely and `on` resumed it; `#{client_control_mode}` reads `1` for the app's client. With `-f pause-after=1` and a reader stalled for 2 s on a flooding pane, output switched to `%extended-output %N <age-ms>`, tmux sent `%pause %N`, and its RSS stayed at 6 MB, so a slow app cannot make tmux buffer without bound. Open: versions before 3.6. |
| P6 | What happens when a normal client and the app share a window? | **done**: the control client's size wins until it detaches; hence the rule in 5.2. |
| P7 | Does a `gpui-kit` hello window with one terminal tile build and run on macOS, then from a `nix-shell` on NixOS (Wayland and X11)? | open. macOS first: the build and headless tests on CI's `macos-latest`, the window on a real Mac. Pins the GPUI revision, the Xcode/SDK version, and the Nix native inputs (Vulkan loader, Wayland, xkbcommon, X11, fontconfig). |
| P8 | With Neovim in a pane and only a control client attached, does tmux deliver focus in/out to the pane when the app switches the active pane, and report `%paste-buffer-changed` after an OSC 52 yank? | **done** (tmux 3.6a, Neovim 0.11.5): `select-pane` between two panes of one window fired Neovim's `FocusLost` and `FocusGained`, and so did `send-keys -H 1b 5b 4f` / `1b 5b 49` with no client involved; with `set-clipboard on`, an OSC 52 write created `buffer0` and the control client got `%paste-buffer-changed buffer0`. With tmux's default `external`, which the fleet runs today, no buffer is created (F6). |

### 12.1 Early performance

Measured 2026-11-05 on Linux (i9-12900HK, tmux 3.6a, `alacritty_terminal`
0.26.0), before any app code: a scratch tmux server, one control client per
the design, and a Rust replay of the recorded control stream through the
`fleet-tmux` parse and one `Term` per pane. The agent load is synthetic: six
100x30 panes each repainting 26 colored lines at 30 fps inside synchronized
updates, which is heavier than claude's differential redraw. Flood is six
panes writing log lines flat out.

| Path | Result |
| --- | --- |
| tmux server, agent load | 9.7% of a core with no client, 11.9% with the app's control client: the app costs tmux about 2 points |
| Wire overhead | `%output` is 1.23x the pane bytes (octal escapes) |
| App core, agent load | parse and unescape at 1.5 to 1.8 GB/s; `Term` feed at 173 MB/s; 0.36% of a core in total |
| App core, flood | `Term` feed at 92 MB/s, 2% of a core; tmux itself uses about one core for six flooding panes, client or not |
| Frame walk | reading all six `Term`s' visible cells: 0.03 ms per frame, of a 16.7 ms budget |
| Keystroke to echo | idle p50 0.49 ms, p99 0.95 ms; beside five busy panes p50 0.57 ms, p99 3.6 ms, unchanged when they are muted, so the tail is CPU contention rather than control-mode traffic |
| Seeding a tile | `capture-pane -e -J`: screen only about 1 ms, 2000 lines of history about 5 ms and 204 KB |
| Fleet verbs | `events --since`, `capabilities`: about 30 ms each (bash startup); hence the file-watched `events` above. User actions (`answer`, `send`) pay the same 30 ms once, which is invisible next to their receipts |

So the core and tmux leave nearly the whole frame budget to drawing. What
remains unmeasured is GPUI painting six terminals (P3), on macOS, where
process startup is also slower than on this machine.

---

## 13. Decisions

**D1. GPUI from the start, not a webview.** macOS is GPUI's first and
best-exercised platform (Metal, native key and IME handling), and Zed already
ships a fast terminal on it over `alacritty_terminal`; the busiest thing on
screen is six streaming terminals. Terminal state lands in Rust (`term`), where
the control-mode bytes already are, instead of in JavaScript. On macOS a
webview would be WKWebView, which is fine, so the case rests on those two
points; on Linux it is stronger, since a webview there is WebKitGTK, the least
reliable of the three for WebGL and GPU compositing. The cost is owned
code: the terminal element (from `gpui-terminal`, plus selection, scrollback,
mouse and paste) and the Customize editor (from `gpui-kit` components). GPUI is
pre-1.0, so the workspace pins one `gpui-kit` release (which pins GPUI) and
upgrades it deliberately; only `app` sees GPUI types, so its churn stops there.

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
UI stack: [gpui-kit / gpui-component](https://github.com/longbridge/gpui-component),
[gpui-terminal](https://docs.rs/gpui-terminal),
[gpui](https://github.com/zed-industries/zed/tree/main/crates/gpui).
