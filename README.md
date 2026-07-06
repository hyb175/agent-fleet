# agent-fleet

A tmux-native session manager for running and supervising multiple Claude Code agents. A workspace is a tmux session; an agent is a tmux window running `claude`. Everything runs on a dedicated tmux socket, isolated from your daily tmux server and config.

Two surfaces:

- **Picker** (`Prefix o`) — an fzf popup to jump to an agent, switch workspaces, spawn one in a directory, or connect one in a GitHub Codespace. `Prefix w` opens it straight to the workspace switcher.
- **Sidenav rail** (`Prefix b`, on by default) — a left-edge rail listing workspaces and agents with live status, refreshed in place.

```
┌──────────────────┬─────────────────────────┐
│ spaces           │                         │
│ ● dotfiles       │   your agent / shell    │
│   main ↑2        │   (the work pane)       │
│                  │                         │
│ agents      all  │                         │
│ ⠹ code-review    │                         │
│   webapp · claude│                         │
│ ● api-fix        │                         │
│   webapp · codex │                         │
│ ○ notes          │                         │
│   home · cursor  │                         │
└──────────────────┴─────────────────────────┘
```

`⠋…⠏` working · `●` done / needs input · `○` idle — each agent row shows its tab, then `workspace · tool`.

---

## Requirements

| Tool | Required | Notes |
| --- | --- | --- |
| `tmux` ≥ 3.2 | yes | `display-popup` (picker), `split-window -f` (full-height rail), per-pane options |
| `bash` ≥ 4 | yes | the rail uses associative arrays. macOS ships `/bin/bash` 3.2 — install a newer bash (`brew install bash`) and ensure it precedes `/bin/bash` on `PATH` |
| `fzf` | yes | powers the picker popup |
| `claude` (Claude Code CLI) | optional* | the default agent command; the status hooks attach to claude launches |
| `git` | optional | branch / ahead-count labels in the rail and picker |
| `zoxide` | optional | frecent directories in the picker's connect view (project-root discovery and `$PWD` work without it) |
| `osascript` (macOS) / `notify-send` (Linux) | optional | desktop notifications on agent state changes |

\* The manager works without `claude`, but `agent-fleet add` with defaults launches it. A truecolor + Unicode-capable terminal is recommended; the Tokyo Night colors and braille spinner degrade (not crash) on lesser terminals.

**Platform:** developed and exercised on macOS. The macOS/Linux differences are handled — desktop notifications fall back from `osascript` to `notify-send`, and `stat`/`ps` use portable invocations — so Linux should work, but it's less battle-tested. Reports welcome.

---

## Install

Clone into a directory that will persist — the clone is the runtime home (`install.sh` only symlinks the CLI onto your `PATH`):

```sh
git clone https://github.com/hyb175/agent-fleet ~/.local/share/agent-fleet
~/.local/share/agent-fleet/install.sh
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
Ctrl-a C      add a claude agent to the current workspace and jump to it
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

**Status** is shown as a glyph: `⠋…⠏` (working, animated), `●` red (needs input), `●` green (done — finished a turn, waiting for your next prompt), `○` (idle). Hook-launched agents (`agent-fleet add` / `Prefix C`) report it directly; for any other agent, status is scraped from the pane (including `done`, detected from Claude's "new task?" footer), so a finished-and-waiting agent reads `done` rather than `idle` either way.

---

## Commands

| Command | Description |
| --- | --- |
| `agent-fleet attach [workspace]` | Boot the fleet and attach (or switch, if already inside). The default when run with no subcommand. |
| `agent-fleet connect <dir\|name> [workspace-name]` (alias `c`) | Switch to an existing workspace, or create one (named for a directory's basename, or the given name) and go to it. Defaults to `$PWD`. An optional final argument sets the workspace name. Names are sanitized: `:`, `.`, space, `/`, `\|` become `_`. |
| `agent-fleet add [name] [--to <ws>] [--new-workspace <name>] [--cmd <cmd>] [--dir <dir>] [--codespace <name>] [--focus]` | Add an agent window. Defaults: command `$AGENT_FLEET_CMD` (`claude`), target the current/first workspace, name the workspace name. Launches `claude` with the fleet status hooks. `--new-workspace <name>` puts the agent in its own workspace (created or reused) instead of a tab. `--codespace` (alias `--cs`) runs the agent inside a GitHub Codespace over SSH instead (no hooks — see [Codespaces](#codespaces)). `--focus` jumps to the new agent (used by `Prefix C`). |
| `agent-fleet cs <list\|stop\|connect> [name]` | GitHub Codespaces helpers. `list` (alias `ls`) lists your codespaces; `stop <name>` stops one; `connect <name> [workspace-name]` opens a **shell workspace** in the codespace over SSH (see [Codespaces](#codespaces)). |
| `agent-fleet goto <pane_id>` | Focus a specific agent pane (used by the picker). |
| `agent-fleet back` | Jump to the previously focused pane (bound to `Prefix Tab`). |
| `agent-fleet rename-workspace [<old>] <new>` (alias `rename-ws`) | Rename a workspace; agents named after it follow the rename. |
| `agent-fleet rename-tab [<session:window>] <new>` (alias `rename-window`) | Rename a tab (window). |
| `agent-fleet kill <target>` (alias `rm`) | Kill a workspace (`<name>`), window (`<ws>:<window>`), or pane (`%id`). |
| `agent-fleet list` (alias `ls`) | List workspaces and their windows. |
| `agent-fleet pick` | Open the picker popup (or attach, from a bare shell). |
| `agent-fleet hooks-file` | Print the path to the generated Claude settings overlay (hooks only). |
| `agent-fleet save` | Snapshot the layout to disk (also auto-saved on a timer and on `stop`). |
| `agent-fleet restore` | Rebuild the saved layout on a stopped fleet (attach does this automatically on a cold boot). |
| `agent-fleet stop` | Save the layout, then kill the fleet server. |
| `agent-fleet --version` | Print the version. |

---

## Keybindings

Prefix is `Ctrl-a`. (The fleet is on its own socket, so this can't collide with your daily tmux even if both use `C-a`.)

| Key | Action |
| --- | --- |
| `Prefix o` | Open the picker popup (fleet / spaces / connect / cloud; `Tab` cycles, `^a`/`^s`/`^z`/`^x` jump). The fleet view lists agents most-urgent-first |
| `Prefix w` | Quick workspace switch — picker opened straight to the spaces view (every workspace, shell-only included) |
| `Prefix g` | Open the picker straight to the cloud view (your GitHub Codespaces) |
| `Prefix f` | Open the picker straight to the connect view — search recent folders **and unvisited project siblings** (git repos first, with branch) to spawn a workspace (`Alt-⏎` to name it) |
| `Prefix b` | Toggle the sidenav rail in the current window |
| `Prefix c` | New plain shell window in the current directory (tmux default) |
| `Prefix C` | Add a Claude agent (with status hooks) — a menu picks a new tab in this workspace or a brand-new workspace (prompts a name); starts in the current dir and jumps to it |
| `Prefix R` | Force the focused pane to repaint (fixes a stale Claude frame) |
| `Prefix Tab` | Jump back to the previously focused agent (across windows/workspaces; toggles between the two) |
| `Prefix Space` | Triage jump — go to the next agent that needs you (`wait`, then `done`), cycling the queue. Most urgent first if you're not already on one |
| `Prefix L` | Switch to the previous workspace |
| `Prefix &` | Close the current tab in one shot (even with several panes open) |
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

Agents started by hand (just running the CLI in a shell) are detected too — `claude`, `codex`, `opencode`, and Cursor's `agent` (shown as `cursor`) out of the box; extend with `AGENT_FLEET_AGENT_CMDS`. The rail labels each row with its workspace and kind. Status for hand-started agents is scraped from the pane, and the scrape patterns match the Claude CLI, so non-claude tools are listed correctly but their live state is approximate (they may read `idle` while working). The hooks are claude-specific: `agent-fleet add` attaches them when the command is `claude`; any other tool runs on the scrape tier regardless of how it's launched.

**`done` clears when you visit it.** Opening a `done` agent — via the picker, `Prefix Space`, `Prefix Tab`, or a rail click — marks it seen: it drops to `idle` and leaves the attention queue, and returns to `done` only when the agent produces new output. Hooked agents track this in their state file; scraped/codespace agents use a `.ackdone` marker. (Raw `Prefix 1`–`9` window jumps don't count as a visit.)

A single background daemon (`snapshotd.sh`, one per fleet) polls tmux and resolves states/branches once per second, writing `fleet.snapshot`. The rails and the picker read that snapshot instead of each polling tmux, so the number of rails doesn't add tmux load. The daemon starts automatically (on attach, and when rails are created), is single-instance, and exits when the fleet stops.

---

## Codespaces

An agent can run inside a [GitHub Codespace](https://docs.github.com/codespaces) instead of on your machine. The fleet stays local — it's still the rail and picker supervising the agent — while the agent process executes in the cloud over SSH.

**Prerequisite:** the GitHub CLI (`gh`), authenticated, with the `codespace` token scope:

```sh
gh auth refresh -h github.com -s codespace
```

Without the scope, `gh codespace list` returns HTTP 403; the picker's cloud view then shows a **Grant Codespaces access** row that runs this command for you (Enter, inside the popup), or you can run it yourself.

**The codespace needs an sshd inside the container.** agent-fleet forwards the container's ssh port to your machine and connects with plain `ssh` — not `gh codespace ssh`, whose built-in server many images can't start (*"failed to start SSH server"*). The devcontainers `sshd` feature provides a server on **port 2222**. Add it to the repo's `.devcontainer/devcontainer.json` and rebuild:

```jsonc
"features": { "ghcr.io/devcontainers/features/sshd:1": { "version": "latest" } }
```

```sh
gh codespace rebuild -c <name>
```

The login user depends on the image (often `dev` or `vscode`); set `AGENT_FLEET_CS_USER` if yours differs, and `AGENT_FLEET_CS_SSH_PORT` if its sshd isn't on 2222.

Two ways to start one:

- **Picker** — `Prefix g` opens the **cloud** view (or `Prefix o` then `Tab`/`^x`). It lists your codespaces (repo · ref · state); `Enter` opens a **shell workspace** in the codespace (named for it; `Alt-⏎` to name it yourself).
- **CLI** — `agent-fleet cs connect <name> [workspace-name]` opens that shell workspace. `agent-fleet add --codespace <name> [--cmd claude]` instead adds a codespace agent into the current workspace (tracked in the rail — see the status note below).

A codespace connection is a **remote-shell workspace**, not a proxied agent: the fleet doesn't mirror remote agents into the local rail (that would mean one SSH per agent and scrape-only status). To run several agents in one codespace, start a multiplexer — `tmux`, or agent-fleet itself — **inside** the codespace. The shell is `AGENT_FLEET_CS_CMD` (default `bash`).

A codespace agent runs through `scripts/cs-connect.sh`: it forwards the container's sshd port (`AGENT_FLEET_CS_SSH_PORT`, default 2222) to a free local port with `gh codespace ports forward`, `ssh`es in as `AGENT_FLEET_CS_USER` (default `dev`), and runs the command (a shell by default) **through a login shell** (`bash -lc`) in the repo checkout — `--dir` if given, else `/workspaces/<repo>` resolved from the codespace, else `/workspaces`. The login shell matters: codespaces often install CLIs (including `claude`) under `~/.local/bin`, which a plain `ssh` command shell doesn't put on `PATH`. The agent must be installed in the codespace. Each agent gets its own local port, so several codespace agents can run at once. The forward is torn down when the agent exits; if the connection fails, the pane drops to a shell with the cause rather than closing.

**Status for a tracked codespace agent (`add --codespace`) is scrape-based.** The fleet's Claude status hooks attach via a local settings file and key on `$TMUX_PANE`, neither of which exists inside the codespace, so hooks aren't used across SSH. Instead these agents fall back to the same `capture-pane` scrape as hand-started agents (it reads the pane's on-screen text, which shows the remote TUI). Consequences:

- State updates lag by up to the scrape interval (~1–2s) rather than being instant.
- No desktop notification fires on state change (notifications come from the hook, which doesn't run).
- The rail's branch column reflects the local launch directory, not the codespace's git ref. The workspace itself is labeled with the codespace name.
- A stopped codespace won't accept the forward — start it once (e.g. open it in the browser) before connecting. First connect is slow; the agent reads `idle` until its TUI paints.

---

## Notifications

When a **hooked** agent changes to **wait** or **done**, a desktop notification fires (`osascript` on macOS, `notify-send` on Linux). Notifications come from the status hook, so scrape-tier agents (hand-started, non-claude, codespace) don't produce them. On by default; set `AGENT_FLEET_NOTIFY=0` to silence.

---

## Persistence (survives reboot)

tmux is in-memory, so a reboot ends the fleet server. agent-fleet saves the
layout to `~/.cache/agent-fleet/fleet.state` and rebuilds it on the next attach:

- **What's restored** — sessions, tabs (names + order), each window's **exact
  split layout**, and every pane's **working directory**. Hooked Claude agents
  (`agent-fleet add` / `Prefix C`) come back **resumed**: the fleet records each
  agent's Claude session id and relaunches it with `claude --resume`, so the
  conversation continues. The rail is re-rendered per window.
- **What's not** — other running programs, and hand-started Claude (no hook, so
  no session id) come back as shells in the right dir. A codespace workspace
  comes back as a local shell (reconnect with `Prefix g`). A resume that fails
  (deleted/expired session) also falls back to a shell. Set
  `AGENT_FLEET_RESTORE_AGENTS=0` to restore everything as plain shells.
- **When it saves** — every `AGENT_FLEET_SAVE_INTERVAL` daemon poll ticks
  (default 15, ≈15s at the default poll interval), on `agent-fleet stop`, and
  on `agent-fleet save`.
- **When it restores** — automatically the next time you `agent-fleet attach`
  with the fleet stopped (e.g. after a reboot); manually via `agent-fleet restore`.

To boot the fleet automatically at login, run `agent-fleet attach` from your
shell profile or a launchd/systemd unit — it rebuilds the saved layout, or
starts a fresh `home` workspace if there's nothing saved.

---

## Customization

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENT_FLEET_CONF` | `<repo>/conf/agent-fleet.conf` | Base tmux config passed to every `tmux -f` |
| `AGENT_FLEET_SOCKET` | `agent-fleet` | tmux socket name (server isolation) |
| `AGENT_FLEET_CMD` | `claude` | Default command for `add`; the status hooks attach only when the command is `claude` |
| `AGENT_FLEET_AGENT_CMDS` | `claude codex opencode agent` | Commands recognized as agents when scraping hand-started panes (space-separated). Cursor's CLI binary `agent` is shown as `cursor`. |
| `AGENT_FLEET_CS_CMD` | `bash` | Command a codespace connection runs by default (picker + `add --codespace`); set to `claude`, `fish`, etc. `--cmd` overrides per launch |
| `AGENT_FLEET_CS_USER` | `dev` | SSH login user for codespace agents (`--codespace`) |
| `AGENT_FLEET_CS_SSH_PORT` | `2222` | sshd port inside the codespace container (forwarded to a local port) |
| `AGENT_FLEET_CS_DIR` | `/workspaces/<repo>` | Remote dir a codespace agent cds into before running (set by `add --dir`); defaults to the codespace's repo checkout |
| `AGENT_FLEET_HOME_SESSION` | `home` | Placeholder session created when the fleet first boots |
| `AGENT_FLEET_NOTIFY` | `1` | Desktop notifications on state change (`0` disables) |
| `AGENT_FLEET_PROJECT_ROOTS` | auto | Colon-separated dirs whose children the connect view lists even if zoxide has never seen them. Default: derived — the parent of every known git repo (unless the parent is itself a repo) |
| `AGENT_FLEET_SIDENAV_WIDTH` | `30` | Rail width in columns |
| `AGENT_FLEET_SIDENAV_REFRESH` | `2` | Rail idle redraw interval (seconds) |
| `AGENT_FLEET_SIDENAV_TICK` | `0.1` | Rail spinner frame interval (seconds) |
| `AGENT_FLEET_SNAP_INTERVAL` | `1` | Snapshot daemon poll interval (seconds) |
| `AGENT_FLEET_SAVE_INTERVAL` | `15` | Layout auto-save cadence, in daemon poll ticks (≈ seconds at the default 1s `AGENT_FLEET_SNAP_INTERVAL`) |
| `AGENT_FLEET_RESTORE_AGENTS` | `1` | Relaunch hooked Claude agents with `claude --resume` on restore (`0` = restore everything as shells) |
| `AGENT_FLEET_GIT_TTL` | `30` | How long a cached git branch stays fresh (seconds) |
| `TMUX_BIN` | `tmux` | tmux binary used by the CLI and every runtime script |

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
rm -rf ~/.local/share/agent-fleet   # the clone
rm -rf ~/.cache/agent-fleet              # runtime state
```

---

## Troubleshooting

- **`Prefix o` does nothing / picker won't open** — needs tmux ≥ 3.2 (`display-popup`). Check `tmux -V`.
- **The rail pane shows a "needs bash 4+" message** — `env bash` resolved to macOS's `/bin/bash` 3.2. Install a newer bash and ensure it precedes `/bin/bash` on `PATH`.
- **Config changes don't take effect** — tmux reads config at server start. Reload with `Prefix r`, or `agent-fleet stop && agent-fleet attach`.
- **Agent status never updates** — for accurate status, launch agents with `agent-fleet add` (it wires the hooks). Hand-started `claude` uses the less-precise scrape fallback.

---

## Testing

```sh
tests/run-all.sh
```

Runs the integration suite: status tiers and the done-acknowledgement flow, layout persistence round-trips, multi-reboot claude resume, CLI target matching, prompt-input safety, snapshot staleness, and the codespace port-lock protocol. Every test runs on a throwaway tmux socket with a private cache — nothing touches a running fleet. Each `tests/t-*.sh` is standalone.

---

## License

MIT. See [LICENSE](./LICENSE).
