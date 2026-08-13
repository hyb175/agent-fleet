# agent-fleet

A tmux-native session manager for running and supervising multiple coding agents — Claude Code first-class, Kimi Code and Codex hook-tier, opencode/cursor detected. A workspace is a tmux **session**; an agent is a tmux **window**. Everything runs on a dedicated tmux socket, isolated from your daily tmux server and config.

The CLI is `agent-fleet` (alias `af`).

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Upgrade](#upgrade)
- [Two surfaces](#two-surfaces)
- [Quick start](#quick-start)
- [Running the fleet remotely](#running-the-fleet-remotely)
- [Concepts](#concepts)
- [Commands](#commands)
- [Keybindings](#keybindings)
- [Status detection](#status-detection)
- [Notifications](#notifications)
- [Persistence (survives reboot)](#persistence-survives-reboot)
- [Environment variables](#environment-variables)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Testing](#testing)
- [License](#license)

---

## Requirements

| Tool | Required | Notes |
| --- | --- | --- |
| `tmux` ≥ 3.2 | yes | `display-popup`, `split-window -f`, per-pane options |
| `bash` ≥ 4 | yes | rail uses associative arrays; macOS ships 3.2 — `brew install bash` and put it ahead of `/bin/bash` on `PATH` |
| `fzf` | yes | powers the picker |
| `claude` | optional | default agent command; hooks attach on launch |
| `git` | optional | branch / ahead-count labels |
| `zoxide` | optional | frecent directories in the connect view |
| `osascript` / `notify-send` | optional | desktop notifications (macOS / Linux) |

A truecolor + Unicode terminal is recommended (theme colors and the braille spinner degrade otherwise). Developed on macOS; Linux works (notifications and `stat`/`ps` fall back to portable forms) but is less battle-tested.

---

## Install

**Remote (no clone)** — downloads the release tarball to `~/.local/share/agent-fleet` and symlinks the CLI:

```sh
curl -fsSL https://raw.githubusercontent.com/hyb175/agent-fleet/master/install.sh | bash
```

**Nix flake:**

```sh
nix profile install github:hyb175/agent-fleet
```

**From a clone** (dev — edits are live):

```sh
git clone https://github.com/hyb175/agent-fleet
agent-fleet/install.sh
```

`install.sh` symlinks `agent-fleet` (and `af`) into `~/.local/bin` and provisions the status cache under `~/.cache/agent-fleet`. It auto-detects its mode: piped through `curl` it downloads the tarball; run from a checkout it symlinks in place. `PREFIX=/usr/local` changes the prefix; `AGENT_FLEET_REF=v0.1.0` pins a tag/branch. If `~/.local/bin` isn't on `PATH`, add `export PATH="$HOME/.local/bin:$PATH"`.

---

## Upgrade

For a managed install (the `curl` route), update to the newest release tag:

```sh
agent-fleet upgrade            # confirm, then fetch + swap + reload the running fleet
agent-fleet upgrade --check    # report installed vs latest, change nothing
agent-fleet upgrade --rollback # restore the previous version
```

It only updates when a newer `vX.Y.Z` tag exists (`-y` skips the prompt; `AGENT_FLEET_REF=<tag|sha>` forces a ref). The previous tree is kept as `~/.local/share/agent-fleet.prev` for rollback. A dev checkout or Nix install isn't touched — `upgrade` prints the `git pull` / `nix profile upgrade` command instead.

---

## Two surfaces

**Picker** (`Prefix o`) — fzf popup to jump to an agent, switch workspaces, or spawn one in a directory. `Prefix w` opens the workspace switcher.

**Sidenav rail** (`Prefix b`, on by default) — left-edge rail listing workspaces and agents with live status, refreshed in place.

```
┌──────────────────┬─────────────────────────┐
│ spaces           │                         │
│ ✓ dotfiles       │   your agent / shell    │
│   main ↑2        │   (the work pane)       │
│                  │                         │
│ agents      all  │                         │
│ ⠹ code-review    │                         │
│   webapp · claude│                         │
│ ◆ api-fix        │                         │
│   webapp · codex │                         │
│ ○ notes          │                         │
│   home · cursor  │                         │
└──────────────────┴─────────────────────────┘
```

**Status glyphs:** `◆` waiting on you · `⠋…⠏` working · `✓` done · `○` idle — each state has its own shape, so they read without color vision.

---

## Quick start

```sh
agent-fleet attach                 # boot + attach (creates the 'home' workspace)
```

Inside the fleet (prefix `Ctrl-a`):

```
Ctrl-a o      picker → Tab to connect view → pick a repo → Enter (spawn workspace)
Ctrl-a C      add a Claude agent to the current workspace, jump to it
Ctrl-a b      toggle the sidenav rail
Ctrl-a L      switch to the previous workspace
```

---

## Running the fleet remotely

Put the **whole fleet** on the host that runs the agents, then attach to it:

```sh
ssh devbox            # install agent-fleet there the same way as anywhere else
agent-fleet attach
```

As a one-liner, `ssh -t devbox 'bash -lc "agent-fleet attach"'` — `-t` because tmux needs a TTY, and a login shell because a non-interactive ssh command won't have `~/.local/bin` on `PATH`.

Run the agents and the fleet on the **same** machine. The status hooks execute in the agent's own process and write to that machine's cache, so a split setup (fleet local, agent remote over SSH) loses hook-tier status, notifications, and resume — the reason the earlier Codespaces integration was removed. With the whole fleet on the host, status, rail, persistence, and `--resume` behave exactly as they do locally.

Because agents keep running on the host, closing your laptop doesn't stop them — reattach later and the fleet is where you left it. Any persistent box works (VM, Coder workspace, another Mac); a private network like Tailscale avoids exposing SSH.

**Two differences from a local fleet:**

- **Desktop notifications fire on the host, not your laptop** — `osascript` / `notify-send` run wherever the hook runs. The rail, the picker, and the terminal progress bar still reach you over SSH. `AGENT_FLEET_NOTIFY=0` turns the dead notifications off.
- **Terminal size follows the most recently active client** (tmux `window-size latest`). With two clients of different sizes attached, the windows resize to whoever acted last.

Several people can attach at once — the fleet tracks state per client, so each viewer gets their own rail highlight and progress bar. `tmux -L agent-fleet attach -r` attaches read-only for an observer.

---

## Concepts

| Concept | Maps to | Notes |
| --- | --- | --- |
| workspace | tmux **session** | named for a directory's basename, or a custom name |
| agent | tmux **window** running `claude` | the window tab is the agent |
| tab | native tmux window tab | no extra concept |
| pane | a PTY | agent owns its window; split (`\|` / `-`) for sidecars |
| fleet | tmux server on socket `agent-fleet` | isolated from daily tmux |

**Status** shows as a glyph — hook-launched agents report it directly, hand-started ones are scraped (see [Status detection](#status-detection)). **Visiting a done agent clears it:** opening it via picker, `Prefix Space`, `Prefix Tab`, or rail click marks it seen and drops it to idle; it returns to done on new output.

---

## Commands

| Command | Description |
| --- | --- |
| `agent-fleet attach [workspace]` | Boot and attach (or switch, if inside). Default when run with no subcommand. |
| `agent-fleet connect <dir\|name> [workspace-name]` (alias `c`) | Create or switch to a workspace. Defaults to `$PWD`; a name overrides the directory basename. Names are sanitized (`:`, `.`, space, `/`, `\|` → `_`). |
| `agent-fleet add [name] [--to <ws>] [--new-workspace <name>] [--cmd <cmd>] [--dir <dir>] [--focus]` | Add an agent window. Defaults: command `$AGENT_FLEET_CMD` (claude), current/first workspace, name after the workspace. Launches with fleet status hooks. `--new-workspace` gives it its own workspace; `--focus` jumps to it (used by `Prefix C`). |
| `agent-fleet goto <pane_id>` | Focus a specific agent pane (used by the picker). |
| `agent-fleet back` | Jump to the previously focused pane (`Prefix Tab`); toggles between two. |
| `agent-fleet rename-workspace [<old>] <new>` | Rename a workspace; agents named after it follow. |
| `agent-fleet rename-tab [<session:window>] <new>` | Rename a tab. |
| `agent-fleet move [<target>] --to <ws> [--focus]` (alias `mv`) | Move a tab to another workspace. Target: `%pane`, `<ws>:<window>`, `@window-id`, or the current tab. `--focus` follows it (`Prefix M`). |
| `agent-fleet kill <target>` (alias `rm`) | Kill a workspace (`<name>`), window (`<ws>:<window>`), or pane (`%id`). |
| `agent-fleet list` (alias `ls`) | List workspaces and windows. |
| `agent-fleet pick` | Open the picker (or attach from a bare shell). |
| `agent-fleet hooks-file` | Print the generated Claude settings overlay path. |
| `agent-fleet kimi-hooks [install\|remove\|status]` | Manage the status-hooks block in `~/.kimi/config.toml`. |
| `agent-fleet codex-hooks [install\|remove\|status]` | Same for `~/.codex/config.toml` (codex trust-gates hooks — approve once at startup). |
| `agent-fleet reload` | Re-source the config and respawn the daemon + rails (pick up new code/binds after an upgrade or `git pull`). |
| `agent-fleet theme [name]` | List palettes, or switch live. See [Theming](#theming). |
| `agent-fleet config [path\|edit]` | Show where config lives, or open your overrides (`local.conf`) in `$EDITOR`. |
| `agent-fleet save` / `restore` | Snapshot / rebuild the layout (auto on a timer and on `stop`; restore runs on cold-boot attach). |
| `agent-fleet stop` | Save the layout, then kill the fleet server. |
| `agent-fleet upgrade [--check\|--rollback] [-y]` | Update a managed install. See [Upgrade](#upgrade). |
| `agent-fleet uninstall [-y] [--purge]` | Stop the fleet, unlink the CLI, clear state. Removes a managed install, never a dev checkout; `--purge` also drops the config dir. |
| `agent-fleet --version` | Print the version. |

---

## Keybindings

Prefix is `Ctrl-a`. The fleet runs on its own socket, so no collision with daily tmux.

| Key | Action |
| --- | --- |
| `Prefix o` | Open the picker (fleet/spaces/connect; `Tab` cycles, `^f`/`^s`/`^z` jump). Fleet view lists agents most-urgent-first. |
| `Prefix w` | Quick workspace switch (picker → spaces view) |
| `Prefix f` | Picker → connect view: recent folders + unvisited siblings (git repos first). `Enter` spawns a shell workspace, `^a` with a claude agent, `^r` names it. |
| `Prefix b` | Toggle the sidenav rail |
| `Prefix c` | New plain shell window (tmux default) |
| `Prefix C` | Add a Claude agent — menu picks a new tab or a new workspace; starts in the current dir, jumps to it |
| `Prefix R` | Force-repaint the focused pane (fixes a stale Claude frame) |
| `Prefix Tab` | Jump back to the previously focused agent; toggles between two |
| `Prefix Space` | Triage jump — next agent needing input (`wait`, then `done`), cycling; most urgent first |
| `Prefix L` | Switch to the previous workspace |
| `Prefix M` | Move the current tab to another workspace (fzf popup picks the destination) |
| `Prefix &` | Close the current tab (even with multiple panes) |
| `Prefix W` / `Prefix T` | Rename the current workspace / tab |
| `Prefix r` | Reload the fleet config |
| `Prefix \|` / `Prefix -` | Split horizontally / vertically (keep cwd) |
| `Prefix h/j/k/l` | Move between panes |
| `Prefix 1`–`9` | Jump to window 1–9 (tmux built-in) |
| Left-click rail row | Focus that agent / workspace |

---

## Status detection

**Hook tier (precise).** Agents from `agent-fleet add` / `Prefix C` run `claude --settings <overlay>`. Claude Code hooks map state: `UserPromptSubmit`/`PreToolUse` → **working**, `Notification` → **wait**, `Stop` → **done**. `SessionStart` writes no status — it records the session id at launch so the agent can be resumed after a reboot even if you never prompted it. The overlay (hooks only) is written to `~/.cache/agent-fleet/hooks-settings.json` and applied per-agent — your global `~/.claude/settings.json` is untouched.

**Hand-typed `claude` is hooked too.** Shell panes start through a launcher (`default-command`) that puts the repo's `shims/` on `PATH`, so `claude`, `claude -r`, `claude --resume`, `claude -c` resolve to a shim that attaches the hooks (and resume-after-reboot). Non-interactive calls (`-p`, `--help`, `--version`) and commands already carrying `--settings` pass through; `AGENT_FLEET_SHIM=0` opts out.

**Kimi and Codex** load hooks only from their global config, so `agent-fleet kimi-hooks` / `codex-hooks` write a fenced, removable block there (idempotent, a no-op outside fleet panes). Same event map; codex trust-gates hooks, so approve them once in its startup review.

**Scrape tier (approximate).** Hand-started `claude`, `codex`, `opencode`, `kimi`, and cursor's `agent` (shown `cursor`) are detected without hooks — extend with `AGENT_FLEET_AGENT_CMDS`. Tools without hooks (opencode, cursor) read `idle` while working.

A single daemon (`snapshotd.sh`, one per fleet) polls tmux once a second, resolves states/branches, and writes `fleet.snapshot`. Rails and picker read that snapshot, so the number of rails adds no tmux load.

---

## Notifications

A hooked agent changing to **wait** or **done** fires a desktop notification (`osascript` / `notify-send`). Scrape-tier agents don't notify. `AGENT_FLEET_NOTIFY=0` silences.

The fleet also drives a **terminal progress bar** (OSC 9;4 — Ghostty 1.2+, iTerm2, WezTerm): indeterminate while the active window's agent works, red when it needs input, cleared when done. Claude doesn't emit these under tmux, so the daemon synthesizes them from the active window's most-urgent state. `AGENT_FLEET_PROGRESS=0` disables it (daemon restart to change).

---

## Persistence (survives reboot)

tmux is in-memory, so a reboot ends the fleet. agent-fleet saves the layout to `~/.cache/agent-fleet/fleet.state` and rebuilds it on the next attach.

**Restored** — sessions, tabs (names + order), the exact split layout, each pane's working directory. Hooked agents come back **resumed**: the fleet records each agent's session id and kind and relaunches `claude --resume <id>`, `kimi --session <id>`, or `codex resume <id>`. This covers `add` / `Prefix C`, hand-typed `claude` / `claude -r`, and hand-typed `kimi` / `codex`.

The id is recorded at launch (`SessionStart`), so an agent you opened but never prompted still resumes. If the id is missing anyway, the agent comes back **fresh** in that dir — a new conversation, not a shell.

**Not restored** — other programs and non-agent panes come back as shells in the right dir; a failed/expired resume also falls back to a shell. `AGENT_FLEET_RESTORE_AGENTS=0` restores everything as shells.

**When** — saved every `AGENT_FLEET_SAVE_INTERVAL` daemon ticks (≈15s), on `stop`, and on `save`; restored automatically on `attach` after a stop, or manually via `restore`. To boot at login, run `agent-fleet attach` from your shell profile or a launchd/systemd unit.

---

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENT_FLEET_CONF` | `<repo>/conf/agent-fleet.conf` | Base tmux config passed to every `tmux -f` |
| `AGENT_FLEET_SOCKET` | `agent-fleet` | tmux socket name (server isolation) |
| `AGENT_FLEET_CMD` | `claude` | Default command for `add`; hooks attach only when it's `claude` |
| `AGENT_FLEET_THEME` | unset | One-shot palette override — see [Theming](#theming) |
| `AGENT_FLEET_AGENT_CMDS` | `claude codex opencode agent kimi` | Commands recognized as agents when scraping (space-separated) |
| `AGENT_FLEET_HOME_SESSION` | `home` | Placeholder session created on first boot |
| `AGENT_FLEET_NOTIFY` | `1` | Desktop notifications on state change (`0` disables) |
| `AGENT_FLEET_PROGRESS` | `1` | Terminal progress bar (`0` disables; read at daemon start) |
| `AGENT_FLEET_SHIM` | `1` | Put the claude shim on shell panes' `PATH` (`0` opts out) |
| `AGENT_FLEET_PROJECT_ROOTS` | auto | Colon-separated dirs whose children the connect view lists |
| `AGENT_FLEET_SIDENAV_WIDTH` | `30` | Rail width in columns |
| `AGENT_FLEET_SIDENAV_REFRESH` | `2` | Rail idle redraw interval (seconds) |
| `AGENT_FLEET_SIDENAV_TICK` | `0.1` | Rail spinner frame interval (seconds) |
| `AGENT_FLEET_SNAP_INTERVAL` | `1` | Snapshot daemon poll interval (seconds) |
| `AGENT_FLEET_SAVE_INTERVAL` | `15` | Layout auto-save cadence, in daemon ticks |
| `AGENT_FLEET_RESTORE_AGENTS` | `1` | Relaunch hooked agents on restore (`0` = shells) |
| `AGENT_FLEET_GIT_TTL` | `30` | Cached git-branch freshness (seconds) |
| `TMUX_BIN` | `tmux` | tmux binary used by the CLI and scripts |

Runtime state lives under `${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet`. The tmux option `@fleet-sidenav-auto` (default `on`) auto-opens the rail on new windows/attach; set `off` to opt out (`Prefix b` still toggles).

### Theming

One palette drives everything — status bar, rail, picker, borders, glyphs. Switch live:

```sh
agent-fleet theme                    # list presets (current marked *)
agent-fleet theme catppuccin-mocha   # switch + persist, no restart
```

The choice is stored in `~/.config/agent-fleet/theme`; `AGENT_FLEET_THEME` overrides it for one invocation. `agent-fleet theme` lists every preset. The eight hand-tuned ones:

| Preset | Look |
| --- | --- |
| `tokyo-night` | Default — soft dark blue |
| `catppuccin-mocha` | Warm pastel dark |
| `gruvbox` | Retro warm contrast |
| `nord` | Cool arctic blue |
| `rose-pine` | Muted rose/violet |
| `dracula` | High-contrast purple |
| `everforest` | Green forest, low contrast |
| `kanagawa` | Ink-wash Japanese |

The rest are imported from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) (ayu, sonokai, nightfox, solarized-dark, one-dark, …). Each preset is nine hex slots in `conf/themes/<name>.sh`; copy one, or run `scripts/gen-theme.sh "<Ghostty Theme Name>"` to generate one. Unknown names fall back to `tokyo-night`.

### Personal layer

If `~/.config/agent-fleet/local.conf` exists, the base config sources it last (after the theme) — drop keybinds, style tweaks, or `set -g @fleet-sidenav-auto off` there without editing the repo. `agent-fleet config edit` opens it (scaffolding a template the first time); `agent-fleet config path` shows where every config file lives.

```tmux
# ~/.config/agent-fleet/local.conf
set -g @fleet-sidenav-auto off
set -g status-style "bg=#222436,fg=#c8d3f5"
```

---

## Uninstall

```sh
agent-fleet uninstall            # stop the fleet, unlink the CLI, clear ~/.cache state
agent-fleet uninstall --purge    # also remove ~/.config/agent-fleet (theme + local.conf)
```

Removes a managed install (`~/.local/share/agent-fleet`); a dev checkout is left in place. Confirms first unless `-y`. For a Nix install, use `nix profile remove`.

---

## Troubleshooting

- **`Prefix o` does nothing** — needs tmux ≥ 3.2 (`display-popup`). Check `tmux -V`.
- **Rail shows "needs bash 4+"** — `env bash` resolved to macOS's 3.2. Install newer bash ahead of `/bin/bash` on `PATH`.
- **Config changes don't take effect** — tmux reads config at server start. `Prefix r`, or `agent-fleet reload`.
- **Agent status never updates** — launch via `agent-fleet add` to wire hooks; hand-started `claude` uses the scrape fallback (less precise).

---

## Testing

```sh
tests/run-all.sh
```

Runs the integration suite (status tiers, layout persistence, multi-reboot resume, kimi/codex hooks, CLI matching, snapshot staleness, theme presets). Every `tests/t-*.sh` is standalone.

---

## License

MIT. See [LICENSE](./LICENSE).
