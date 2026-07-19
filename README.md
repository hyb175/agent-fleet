# agent-fleet

A tmux-native session manager for running and supervising multiple coding agents — Claude Code first-class, Kimi Code hook-tier, codex/opencode/cursor detected. A workspace is a tmux session; an agent is a tmux window. Everything runs on a dedicated tmux socket, isolated from your daily tmux server and config.

## Two surfaces

**Picker** (`Prefix o`) — fzf popup to jump to an agent, switch workspaces, spawn one in a directory, or connect one in a GitHub Codespace. `Prefix w` opens the workspace switcher.

**Sidenav rail** (`Prefix b`, on by default) — left-edge rail listing workspaces and agents with live status, refreshed in place.

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

**Status glyphs:** `⠋…⠏` working · `●` done/waiting · `○` idle

---

## Quick start

```sh
agent-fleet attach                 # boot + attach (creates 'home' workspace)
```

Inside the fleet (prefix: `Ctrl-a`):

```
Ctrl-a o      open picker → Tab to connect view → pick repo → Enter (spawn workspace)
Ctrl-a C      add Claude agent to current workspace, jump to it
Ctrl-a b      toggle sidenav rail
Ctrl-a o      → Enter on agent row → jump to it
Ctrl-a L      switch to previous workspace
```

---

## Requirements

| Tool | Required | Notes |
| --- | --- | --- |
| `tmux` ≥ 3.2 | yes | `display-popup`, `split-window -f`, per-pane options |
| `bash` ≥ 4 | yes | rail uses associative arrays; macOS ships 3.2 — install newer bash (`brew install bash`) and ensure it precedes `/bin/bash` on `PATH` |
| `fzf` | yes | powers picker |
| `claude` | optional* | default agent command; status hooks attach on launch |
| `git` | optional | branch / ahead-count labels in rail and picker |
| `zoxide` | optional | frecent directories in picker's connect view |
| `osascript` (macOS) / `notify-send` (Linux) | optional | desktop notifications on state changes |

\* Manager works without `claude`, but `agent-fleet add` with defaults launches it. Truecolor + Unicode terminal recommended (Tokyo Night colors and braille spinner degrade on lesser terminals).

**Platform:** Developed on macOS; Linux works but less battle-tested. macOS/Linux differences are handled (notifications fall back from `osascript` to `notify-send`, `stat`/`ps` use portable invocations).

---

## Install

Clone into a persistent directory (the clone is the runtime home):

```sh
git clone https://github.com/hyb175/agent-fleet ~/.local/share/agent-fleet
~/.local/share/agent-fleet/install.sh
```

`install.sh` symlinks `agent-fleet` into `~/.local/bin`, provisions the status cache under `~/.cache/agent-fleet`, and reports missing dependencies. Override prefix with `PREFIX=/usr/local ./install.sh`.

If `~/.local/bin` isn't on `PATH`, add it: `export PATH="$HOME/.local/bin:$PATH"`.

---

## Concepts

| Concept | Maps to | Notes |
| --- | --- | --- |
| workspace | tmux **session** | named for a directory's basename, or a custom name |
| agent | tmux **window** running `claude` | the window tab is the agent |
| tab | native tmux window tab | no extra concept |
| pane | a PTY | agent owns its window; split (`\|` / `-`) for sidecars (shell/log) |
| fleet | tmux server on socket `agent-fleet` | isolated from daily tmux |

**Status** is shown as a glyph. Hook-launched agents (`agent-fleet add`, `Prefix C`) report it directly; hand-started agents are detected via pane scrape (`claude`, `codex`, `opencode`, `kimi`, cursor's `agent`).

Status sources:
- `UserPromptSubmit`, `PreToolUse` hooks → **working** (animated spinner)
- `Notification` hook → **wait** (needs input, red)
- `Stop` hook → **done** (green)
- Hand-started agents → scraped from on-screen text

**Visiting a done agent clears it:** opening via picker, `Prefix Space`, `Prefix Tab`, or rail click marks it seen, drops it to idle, and leaves the attention queue. Returns to done on new output.

---

## Commands

| Command | Description |
| --- | --- |
| `agent-fleet attach [workspace]` | Boot the fleet and attach (or switch, if inside). Default when run with no subcommand. |
| `agent-fleet connect <dir\|name> [workspace-name]` (alias `c`) | Create or switch to workspace. Defaults to `$PWD`; optional name overrides the directory's basename. Names are sanitized: `:`, `.`, space, `/`, `\|` → `_`. |
| `agent-fleet add [name] [--to <ws>] [--new-workspace <name>] [--cmd <cmd>] [--dir <dir>] [--codespace <name>] [--focus]` | Add agent window. Defaults: command `$AGENT_FLEET_CMD` (claude), target current/first workspace, name after workspace. Launches with fleet status hooks. `--new-workspace` puts it in its own workspace. `--codespace` / `--cs` runs it in a GitHub Codespace over SSH (no hooks). `--focus` jumps to it (used by `Prefix C`). |
| `agent-fleet cs <list\|stop\|connect> [name]` | GitHub Codespaces: `list` shows yours; `stop <name>` stops one; `connect <name>` opens a shell workspace in the codespace over SSH. |
| `agent-fleet goto <pane_id>` | Focus a specific agent pane (used by picker). |
| `agent-fleet back` | Jump to previously focused pane (bound to `Prefix Tab`). Toggles between two. |
| `agent-fleet rename-workspace [<old>] <new>` | Rename workspace; agents named after it follow the rename. |
| `agent-fleet rename-tab [<session:window>] <new>` | Rename tab (window). |
| `agent-fleet kill <target>` (alias `rm`) | Kill workspace (`<name>`), window (`<ws>:<window>`), or pane (`%id`). |
| `agent-fleet list` (alias `ls`) | List workspaces and windows. |
| `agent-fleet pick` | Open picker popup (or attach from bare shell). |
| `agent-fleet hooks-file` | Print path to generated Claude settings overlay (hooks only). |
| `agent-fleet kimi-hooks [install\|remove\|status]` | Manage the fleet status-hooks block in `~/.kimi/config.toml` (kimi has no per-launch overlay; hooks are install-wide, fenced, and removable). |
| `agent-fleet reload` | Respawn snapshot daemon and rails (pick up code after `git pull`). |
| `agent-fleet save` | Snapshot layout to disk (also auto-saved on timer and on `stop`). |
| `agent-fleet restore` | Rebuild saved layout on stopped fleet (attach does this on cold boot). |
| `agent-fleet stop` | Save layout, then kill fleet server. |
| `agent-fleet --version` | Print version. |

---

## Keybindings

Prefix is `Ctrl-a`. Fleet runs on its own socket, so no collision with daily tmux.

| Key | Action |
| --- | --- |
| `Prefix o` | Open picker popup (fleet/spaces/connect/cloud; `Tab` cycles, `^f`/`^s`/`^z`/`^x` jump). Fleet view lists agents most-urgent-first. |
| `Prefix w` | Quick workspace switch — picker to spaces view |
| `Prefix g` | Picker to cloud view (GitHub Codespaces) |
| `Prefix f` | Picker to connect view — search recent folders + unvisited siblings (git repos first, with branch). `Enter` spawns shell workspace, `^a` spawns with claude agent, `^r` names it. |
| `Prefix b` | Toggle sidenav rail in current window |
| `Prefix c` | New plain shell window (tmux default) |
| `Prefix C` | Add Claude agent — menu picks new tab or brand-new workspace (prompts name); starts in current dir, jumps to it |
| `Prefix R` | Force repaint focused pane (fixes stale Claude frame) |
| `Prefix Tab` | Jump back to previously focused agent (across windows/workspaces); toggle between two |
| `Prefix Space` | Triage jump — go to next agent needing input (`wait`, then `done`), cycling queue. Most urgent first if not already on one. |
| `Prefix L` | Switch to previous workspace |
| `Prefix &` | Close current tab (even with multiple panes) |
| `Prefix W` | Rename current workspace |
| `Prefix T` | Rename current tab |
| `Prefix r` | Reload fleet config |
| `Prefix \|` / `Prefix -` | Split horizontally / vertically (keep cwd) |
| `Prefix h/j/k/l` | Move between panes |
| `Prefix 1`–`9` | Jump to window 1–9 (tmux built-in) |
| Left-click rail row | Focus that agent / workspace |

---

## Status detection

Agents launched via `agent-fleet add` run as `claude --settings <overlay>`, where the overlay registers four Claude Code hooks:
- `UserPromptSubmit`, `PreToolUse` → **working**
- `Notification` → **wait** (needs input)
- `Stop` → **done**

The overlay (hooks only) is generated under `~/.cache/agent-fleet/hooks-settings.json` and applied per-agent — your global `~/.claude/settings.json` is untouched. Each hook writes state to a per-pane file the rail and picker read.

**Hand-typed `claude` gets the hooks too.** Shell panes start through a launcher (`default-command`) that puts the repo's `shims/` dir on `PATH`, so `claude`, `claude -r`, `claude --resume`, `claude -c` all resolve to a shim that attaches fleet status hooks. Hand-started claude agents therefore get hook-tier status, notifications, progress bar, and resume-after-reboot. Non-interactive invocations (`-p`, `--help`, `--version`) and commands that already carry `--settings` pass through untouched; set `AGENT_FLEET_SHIM=0` to opt out.

**Kimi Code gets hook-tier status too.** Run `agent-fleet kimi-hooks` once: kimi loads hooks only from its global `~/.kimi/config.toml` (no per-launch overlay flag exists), so the fleet writes a fenced, managed `[[hooks]]` block there — idempotent, removable with `kimi-hooks remove`, and a no-op outside fleet panes. Kimi's event map is even sharper than claude's: `UserPromptSubmit`/`PreToolUse`/`PermissionResult` → **working**, `PermissionRequest` → **wait**, `Stop` → **done**. Once installed, every `kimi` in a fleet pane — `add --cmd kimi` or hand-typed — reports status, notifies, drives the progress bar, and resumes after reboot. No PATH shim needed.

Agents started by hand (just running in a shell): `claude`, `codex`, `opencode`, `kimi`, and cursor's `agent` (shown as `cursor`) are detected out of the box; extend with `AGENT_FLEET_AGENT_CMDS`. The rail labels each row with its workspace and kind. Tools without hooks (codex, opencode, cursor) remain on scrape tier (status is approximate; they read `idle` while working).

A single background daemon (`snapshotd.sh`, one per fleet) polls tmux and resolves states/branches once per second, writing `fleet.snapshot`. Rails and picker read that snapshot instead of polling tmux themselves, so the number of rails doesn't add tmux load. Daemon starts automatically, is single-instance, exits when the fleet stops.

---

## Codespaces

An agent can run inside a [GitHub Codespace](https://docs.github.com/codespaces) instead of locally. The fleet stays local — rail and picker supervise the agent — while the agent process executes in the cloud over SSH.

### Setup

**Prerequisite:** GitHub CLI (`gh`), authenticated, with `codespace` token scope:

```sh
gh auth refresh -h github.com -s codespace
```

Without the scope, `gh codespace list` returns HTTP 403; the picker's cloud view shows a **Grant Codespaces access** row that runs this for you.

**The codespace needs sshd.** agent-fleet forwards the container's ssh port and connects with plain `ssh`. The devcontainers `sshd` feature provides a server on **port 2222**. Add to `.devcontainer/devcontainer.json`:

```jsonc
"features": { "ghcr.io/devcontainers/features/sshd:1": { "version": "latest" } }
```

Then rebuild:

```sh
gh codespace rebuild -c <name>
```

Login user is `dev` by default; set `AGENT_FLEET_CS_USER` if yours differs. Set `AGENT_FLEET_CS_SSH_PORT` if sshd isn't on 2222.

### Two ways to start

**Picker** — `Prefix g` opens cloud view (or `Prefix o` then `Tab`/`^x`). Lists codespaces (repo · ref · state); `Enter` opens a shell workspace, `^r` to name it.

**CLI** — `agent-fleet cs connect <name>` opens shell workspace. `agent-fleet add --codespace <name> [--cmd claude]` adds a codespace agent into current workspace.

### Details

A codespace connection is a **remote-shell workspace**, not a proxied agent: the fleet doesn't mirror remote agents into the local rail (that would mean one SSH per agent, scrape-only status). To run several agents in one codespace, start a multiplexer inside (tmux or agent-fleet itself).

A codespace agent runs through `scripts/cs-connect.sh`: it forwards sshd port to a free local port with `gh codespace ports forward`, `ssh`es in as `AGENT_FLEET_CS_USER`, and runs the command through a login shell in the repo checkout. Each agent gets its own local port, so several can run concurrently. The forward tears down on agent exit; connection failure drops to a shell with the cause.

**Status for tracked codespace agents is scrape-based** (not hook-based, since hooks can't attach across SSH). Consequences:
- Updates lag up to 1–2s (not instant).
- No desktop notification on state change.
- Rail's branch column shows local launch dir, not codespace's ref. Workspace is labeled with codespace name.
- Stopped codespace won't accept forward — start once (e.g. open in browser) before connecting. First connect is slow; agent reads `idle` until TUI paints.

---

## Notifications

When a **hooked** agent (claude, or kimi after `kimi-hooks`) changes to **wait** or **done**, a desktop notification fires (`osascript` on macOS, `notify-send` on Linux). Notifications come from the hook, so scrape-tier agents (codex/opencode/cursor, codespace) don't produce them. On by default; set `AGENT_FLEET_NOTIFY=0` to silence.

The fleet also drives a **terminal progress bar** (OSC 9;4 — rendered by Ghostty 1.2+, iTerm2, WezTerm at top): indeterminate while the window's agent works, red when it needs input, cleared when done. Claude Code doesn't emit these under tmux, so the daemon synthesizes them from the **active window's most-urgent agent state**, making it reliable across switches and covering scrape-tier agents too. Set `AGENT_FLEET_PROGRESS=0` (daemon restart to change) to disable.

---

## Persistence (survives reboot)

tmux is in-memory, so a reboot ends the fleet server. agent-fleet saves the layout to `~/.cache/agent-fleet/fleet.state` and rebuilds it on the next attach:

**What's restored** — sessions, tabs (names + order), exact split layout per window, every pane's working directory. Hooked agents come back **resumed**: the fleet records each agent's session id and kind, and relaunches `claude --resume <id>` or `kimi --session <id>`, so the conversation continues. This covers `agent-fleet add` / `Prefix C` launches *and* hand-typed `claude` / `claude -r` in fleet panes (hooked via the PATH shim) *and* hand-typed `kimi` (hooked install-wide via `kimi-hooks`). Rails are re-rendered per window.

**What's not** — other running programs and unhooked agents (no hook, no session id) come back as shells in the right dir. Codespace workspace comes back as a local shell (reconnect with `Prefix g`). Failed resumes also fall back to shells. Set `AGENT_FLEET_RESTORE_AGENTS=0` to restore everything as shells.

**When it saves** — every `AGENT_FLEET_SAVE_INTERVAL` daemon poll ticks (default 15, ≈15s), on `agent-fleet stop`, on `agent-fleet save`.

**When it restores** — automatically on `agent-fleet attach` after the fleet is stopped (e.g. after reboot); manually via `agent-fleet restore`.

To boot the fleet at login, run `agent-fleet attach` from your shell profile or a launchd/systemd unit — it rebuilds the saved layout or starts a fresh `home` workspace if nothing is saved.

---

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENT_FLEET_CONF` | `<repo>/conf/agent-fleet.conf` | Base tmux config passed to every `tmux -f` |
| `AGENT_FLEET_SOCKET` | `agent-fleet` | tmux socket name (server isolation) |
| `AGENT_FLEET_CMD` | `claude` | Default command for `add`; hooks attach only when the command is `claude` |
| `AGENT_FLEET_AGENT_CMDS` | `claude codex opencode agent kimi` | Commands recognized as agents when scraping hand-started panes (space-separated). Cursor's `agent` shown as `cursor`. |
| `AGENT_FLEET_CS_CMD` | `bash` | Default command for codespace connections; set to `claude`, `fish`, etc. |
| `AGENT_FLEET_CS_USER` | `dev` | SSH login user for codespace agents |
| `AGENT_FLEET_CS_SSH_PORT` | `2222` | sshd port inside codespace container |
| `AGENT_FLEET_CS_DIR` | `/workspaces/<repo>` | Remote dir codespace agent `cd`s into before running |
| `AGENT_FLEET_HOME_SESSION` | `home` | Placeholder session created when fleet first boots |
| `AGENT_FLEET_NOTIFY` | `1` | Desktop notifications on state change (`0` disables) |
| `AGENT_FLEET_PROGRESS` | `1` | Terminal progress bar (OSC 9;4) (`0` disables; read at daemon start) |
| `AGENT_FLEET_SHIM` | `1` | Put claude shim on shell panes' `PATH` (hooks + resume for hand-typed `claude`); `0` opts out |
| `AGENT_FLEET_PROJECT_ROOTS` | auto | Colon-separated dirs whose children the connect view lists (default: parent of every known git repo, unless the parent is itself a repo) |
| `AGENT_FLEET_SIDENAV_WIDTH` | `30` | Rail width in columns |
| `AGENT_FLEET_SIDENAV_REFRESH` | `2` | Rail idle redraw interval (seconds) |
| `AGENT_FLEET_SIDENAV_TICK` | `0.1` | Rail spinner frame interval (seconds) |
| `AGENT_FLEET_SNAP_INTERVAL` | `1` | Snapshot daemon poll interval (seconds) |
| `AGENT_FLEET_SAVE_INTERVAL` | `15` | Layout auto-save cadence, in daemon poll ticks (≈ seconds) |
| `AGENT_FLEET_RESTORE_AGENTS` | `1` | Relaunch hooked agents with their saved session on restore (`0` = shells) |
| `AGENT_FLEET_GIT_TTL` | `30` | How long cached git branch stays fresh (seconds) |
| `TMUX_BIN` | `tmux` | tmux binary used by CLI and scripts |

Runtime state lives under `${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet` (hooks overlay, per-pane status, rail row maps). No separate override for cache location.

### tmux options

| Option | Default | Purpose |
| --- | --- | --- |
| `@fleet-sidenav-auto` | `on` | Auto-open rail on new windows/sessions and on attach. Set `off` to opt out; `Prefix b` still toggles. |

### Personal layer

If `~/.config/agent-fleet/local.conf` exists, the base config sources it last. Drop personal keybinds, theme, or `set -g @fleet-sidenav-auto off` there without editing the repo:

```tmux
# ~/.config/agent-fleet/local.conf
set -g @fleet-sidenav-auto off
set -g status-style "bg=#222436,fg=#c8d3f5"
```

---

## Uninstall

```sh
rm ~/.local/bin/agent-fleet              # symlink
rm -rf ~/.local/share/agent-fleet        # clone
rm -rf ~/.cache/agent-fleet              # runtime state
```

---

## Troubleshooting

- **`Prefix o` does nothing / picker won't open** — needs tmux ≥ 3.2 (`display-popup`). Check `tmux -V`.
- **Rail shows "needs bash 4+" message** — `env bash` resolved to macOS's `/bin/bash` 3.2. Install newer bash and ensure it precedes `/bin/bash` on `PATH`.
- **Config changes don't take effect** — tmux reads config at server start. Reload with `Prefix r`, or `agent-fleet stop && agent-fleet attach`.
- **Agent status never updates** — for accurate status, launch agents with `agent-fleet add` (wires hooks). Hand-started `claude` uses scrape fallback (less precise).

---

## Testing

```sh
tests/run-all.sh
```

Runs the integration suite: status tiers and done-acknowledgement flow, layout persistence round-trips, multi-reboot claude resume, kimi hooks install/remove + kimi resume round-trip, CLI target matching, prompt-input safety, snapshot staleness, codespace port-lock protocol. Every `tests/t-*.sh` is standalone.

---

## License

MIT. See [LICENSE](./LICENSE).
