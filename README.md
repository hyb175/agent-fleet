# tmux-agent-fleet

A tmux-native session manager for running and supervising multiple Claude Code agents. A workspace is a tmux session; an agent is a tmux window running `claude`. Everything runs on a dedicated tmux socket, isolated from your daily tmux server and config.

Two surfaces:

- **Picker** (`Prefix o`) — an fzf popup to jump to an agent, switch workspaces, or spawn one in a directory.
- **Sidenav rail** (`Prefix b`, on by default) — a left-edge rail listing workspaces and agents with live status, refreshed in place.

```
┌────────────┬───────────────────────────────┐
│ spaces     │                               │
│ ● dotfiles │   your agent / shell          │
│   main ↑2  │   (work pane)                 │
│ agents     │                               │
│ ⠹ dotfiles │                               │
│   working  │                               │
│ ● api      │                               │
│   wait     │                               │
└────────────┴───────────────────────────────┘
```

---

## Requirements

| Tool | Required | Notes |
| --- | --- | --- |
| `tmux` ≥ 3.2 | yes | `display-popup` (picker), `split-window -f` (full-height rail), per-pane options |
| `bash` ≥ 4 | yes | the rail uses associative arrays. macOS ships `/bin/bash` 3.2 — install a newer bash (`brew install bash`) and ensure it precedes `/bin/bash` on `PATH` |
| `fzf` | yes | powers the picker popup |
| `claude` (Claude Code CLI) | optional* | the default agent command; status hooks attach to it |
| `git` | optional | branch / ahead-count labels in the rail and picker |
| `zoxide` | optional | frecent directories in the picker's connect view (falls back to `$PWD`) |
| `osascript` (macOS) / `notify-send` (Linux) | optional | desktop notifications on agent state changes |

\* The manager works without `claude`, but `agent-fleet add` with defaults launches it. A truecolor + Unicode-capable terminal is recommended; the Tokyo Night colors and braille spinner degrade (not crash) on lesser terminals.

---

## Install

Clone into a directory that will persist — the clone is the runtime home (`install.sh` only symlinks the CLI onto your `PATH`):

```sh
git clone https://github.com/<your-org>/tmux-agent-fleet ~/.local/share/tmux-agent-fleet
~/.local/share/tmux-agent-fleet/install.sh
```

`install.sh` symlinks `agent-fleet` into `~/.local/bin`, provisions the status cache under `~/.cache/agent-fleet`, and reports missing dependencies. Override the install prefix with `PREFIX=/usr/local ./install.sh`.

If `~/.local/bin` isn't on your `PATH`, add it: `export PATH="$HOME/.local/bin:$PATH"`.

---

## Quick start

```sh
agent-fleet attach                 # boot the fleet + attach (creates a 'home' workspace)
```

Inside the fleet (prefix is `Ctrl-a`):

```
Ctrl-a o      open the picker → Tab to the connect view → pick a repo → Enter   (spawns a workspace)
agent-fleet add               (run in a workspace shell) → adds a claude agent window
Ctrl-a b      toggle the sidenav rail
Ctrl-a o      → Enter on an agent row → jump to it
Ctrl-a L      bounce to the previous workspace
```

---

## Concepts

| Concept | Maps to | Notes |
| --- | --- | --- |
| workspace | a tmux **session** | named from a directory's basename, or a name you pass |
| agent | a tmux **window** running `claude` | the window tab is the agent |
| tab | a native tmux window tab | no extra concept |
| pane | a PTY | an agent owns its window; split (`|` / `-`) for a sidecar shell/log |
| the fleet | a tmux server on socket `agent-fleet` | isolated from your daily tmux |

**Status** is reported by Claude Code hooks (see below), shown as a glyph: `⠋…⠏` (working, animated), `●` red (needs input), `●` green (done), `○` (idle). For agents not launched through the fleet, status falls back to scraping the pane contents.

---

## Commands

| Command | Description |
| --- | --- |
| `agent-fleet attach [workspace]` | Boot the fleet and attach (or switch, if already inside). The default when run with no subcommand. |
| `agent-fleet connect <dir\|name>` (alias `c`) | Switch to an existing workspace, or create one (named for a directory's basename, or the name verbatim) and go to it. Defaults to `$PWD`. |
| `agent-fleet add [name] [--to <ws>] [--cmd <cmd>] [--dir <dir>]` | Add an agent window. Defaults: command `$AGENT_FLEET_CMD` (`claude`), target the current/first workspace, name the workspace name. Launches `claude` with the fleet status hooks. |
| `agent-fleet goto <pane_id>` | Focus a specific agent pane (used by the picker). |
| `agent-fleet rename-workspace [<old>] <new>` (alias `rename-ws`) | Rename a workspace; agents named after it follow the rename. |
| `agent-fleet rename-tab [<session:window>] <new>` (alias `rename-window`) | Rename a tab (window). |
| `agent-fleet kill <target>` (alias `rm`) | Kill a workspace (`<name>`), window (`<ws>:<window>`), or pane (`%id`). |
| `agent-fleet list` (alias `ls`) | List workspaces and their windows. |
| `agent-fleet pick` | Open the picker popup (or attach, from a bare shell). |
| `agent-fleet hooks-file` | Print the path to the generated Claude settings overlay (hooks only). |
| `agent-fleet stop` | Kill the entire fleet server. |
| `agent-fleet --version` | Print the version. |

---

## Keybindings

Prefix is `Ctrl-a`. (The fleet is on its own socket, so this can't collide with your daily tmux even if both use `C-a`.)

| Key | Action |
| --- | --- |
| `Prefix o` | Open the picker popup (jump / spaces / connect; `Tab` cycles views) |
| `Prefix b` | Toggle the sidenav rail in the current window |
| `Prefix L` | Switch to the previous workspace |
| `Prefix W` | Rename the current workspace |
| `Prefix T` | Rename the current tab |
| `Prefix r` | Reload the fleet config |
| `Prefix \|` / `Prefix -` | Split horizontally / vertically (keeps cwd) |
| `Prefix h/j/k/l` | Move between panes |
| `Prefix 1`–`9` | Jump to window 1–9 (tmux built-in) |
| Left-click a rail row | Focus that agent / workspace |

---

## Status detection

Agents launched via `agent-fleet add` run as `claude --settings <overlay>`, where the overlay registers four Claude Code hooks:

- `UserPromptSubmit`, `PreToolUse` → **working**
- `Notification` → **wait** (needs your input)
- `Stop` → **done**

The overlay (hooks only) is generated under `~/.cache/agent-fleet/hooks-settings.json` and applied per-agent — your global `~/.claude/settings.json` is not modified. Each hook writes the state to a per-pane file the rail and picker read.

Agents started by hand (just running `claude` in a shell) are detected as agents too, but their status comes from scraping the pane (the rail shows them under their workspace name). That fallback matches the current Claude CLI's English prompts and is less precise than the hook path.

A single background daemon (`snapshotd.sh`, one per fleet) polls tmux and resolves states/branches once per second, writing `fleet.snapshot`. The rails and the picker read that snapshot instead of each polling tmux, so the number of rails doesn't add tmux load. The daemon starts automatically (on attach, and when rails are created), is single-instance, and exits when the fleet stops.

---

## Notifications

When an agent changes to **wait** or **done**, a desktop notification fires (`osascript` on macOS, `notify-send` on Linux). On by default; set `AGENT_FLEET_NOTIFY=0` to silence.

---

## Customization

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENT_FLEET_CONF` | `<repo>/conf/agent-fleet.conf` | Base tmux config passed to every `tmux -f` |
| `AGENT_FLEET_SOCKET` | `agent-fleet` | tmux socket name (server isolation) |
| `AGENT_FLEET_CMD` | `claude` | Default command for `add`; status hooks attach to it |
| `AGENT_FLEET_HOME_SESSION` | `home` | Placeholder session created when the fleet first boots |
| `AGENT_FLEET_NOTIFY` | `1` | Desktop notifications on state change (`0` disables) |
| `AGENT_FLEET_SIDENAV_WIDTH` | `30` | Rail width in columns |
| `AGENT_FLEET_SIDENAV_REFRESH` | `2` | Rail idle redraw interval (seconds) |
| `AGENT_FLEET_SIDENAV_TICK` | `0.1` | Rail spinner frame interval (seconds) |
| `AGENT_FLEET_SNAP_INTERVAL` | `1` | Snapshot daemon poll interval (seconds) |
| `AGENT_FLEET_GIT_TTL` | `30` | How long a cached git branch stays fresh (seconds) |
| `TMUX_BIN` | `tmux` | tmux binary to invoke |

Runtime state lives under `${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet` (the hooks overlay, per-pane status, and rail row maps). There is no separate override for the cache location.

### tmux options

| Option | Default | Purpose |
| --- | --- | --- |
| `@fleet-sidenav-auto` | `on` | Auto-open the rail on new windows/sessions and on attach. Set `off` to opt out; `Prefix b` still toggles it. |

### Personal layer

If `~/.config/agent-fleet/local.conf` exists, the base config sources it last — drop personal keybinds, theme, or `set -g @fleet-sidenav-auto off` there without editing the repo:

```tmux
# ~/.config/agent-fleet/local.conf
set -g @fleet-sidenav-auto off
set -g status-style "bg=#222436,fg=#c8d3f5"
```

---

## Uninstall

```sh
rm ~/.local/bin/agent-fleet              # the symlink
rm -rf ~/.local/share/tmux-agent-fleet   # the clone
rm -rf ~/.cache/agent-fleet              # runtime state
```

---

## Troubleshooting

- **`Prefix o` does nothing / picker won't open** — needs tmux ≥ 3.2 (`display-popup`). Check `tmux -V`.
- **The rail pane shows a "needs bash 4+" message** — `env bash` resolved to macOS's `/bin/bash` 3.2. Install a newer bash and ensure it precedes `/bin/bash` on `PATH`.
- **Config changes don't take effect** — tmux reads config at server start. Reload with `Prefix r`, or `agent-fleet stop && agent-fleet attach`.
- **Agent status never updates** — for accurate status, launch agents with `agent-fleet add` (it wires the hooks). Hand-started `claude` uses the less-precise scrape fallback.

---

## License

MIT. See [LICENSE](./LICENSE).
