---
thesis: mobile-experience
phase: product-research
status: draft
date: 2026-07-11
---

# agent-fleet — Product research dossier

## Product snapshot
agent-fleet is a tmux-native session manager for running and supervising multiple Claude Code agents (README.md:3). Its own model: a **workspace** is a tmux session, an **agent** is a tmux window running `claude`, and the whole thing lives on a dedicated tmux socket (`agent-fleet`) isolated from your daily tmux (README.md:83-89). It presents exactly two surfaces, both terminal UIs: a **picker** (an `fzf` `display-popup`, `Prefix o`) to jump between agents/workspaces or spawn/connect one, and a **sidenav rail** (a full-height tmux pane, `Prefix b`, on by default) that lists workspaces and agents with live status (README.md:5-8). It is a solo, single-user tool for personal use, developed and exercised on macOS with Linux "less battle-tested" (README.md:44; 00-thesis.md:16). Version is `0.1.0` (`agent-fleet --version`). There is no CHANGELOG file; release history is the git log (confirmed: `ls CHANGELOG*` → none). Everything a user does today happens at the workstation, in front of the terminal running the fleet.

## Capability inventory (thesis-relevant)
The thesis is a phone-based **glance + unblock** surface (00-thesis.md:25): read agent status at a glance, and when an agent is in `wait`, inject a quick reply to unblock it — Phase 1 served over LAN as a PWA (grill/thesis.md:23-26). This inventory maps what the fleet already exposes that such a surface could build on.

| Capability | How users reach it | Evidence |
|---|---|---|
| **Central status snapshot** — a single daemon (`snapshotd.sh`, one per fleet) polls tmux ~1/s and writes `fleet.snapshot`; all rails + the picker READ that file instead of each polling tmux | Automatic (starts on attach and when rails are created; single-instance; exits when the fleet stops) | README.md:160; snapshotd.sh header |
| **Per-agent lifecycle state** — `working` (animated), `wait` (needs input, red), `done` (finished a turn, green), `idle` | Shown as a glyph in the rail/picker; carried in the snapshot's `A` records | README.md:26,91; snapshotd.sh:13 |
| **Rollup state + branch per workspace** | Snapshot `S` records: `<session>\|<rollup_state>\|<branch>` | snapshotd.sh:13,99 |
| **Attention queue / triage** — build a queue of agents that need you, `wait` first then `done`, most-urgent-first | `Prefix Space` (triage jump); the picker's fleet view lists agents most-urgent-first | README.md:133,124; next-attention.sh:1-8 |
| **`done` acknowledgement** — visiting a `done` agent marks it seen; it drops to `idle` and leaves the queue until new output | Opening via picker / `Prefix Space` / `Prefix Tab` / rail click | README.md:158 |
| **Status via Claude hooks (precise)** — `agent-fleet add`/`Prefix C` launch `claude --settings <overlay>`; hooks (`UserPromptSubmit`,`PreToolUse`→working; `Notification`→wait; `Stop`→done) write per-pane state files | Automatic for fleet-launched claude agents | README.md:148-154; agent-status-hook.sh:1-31 |
| **Status via pane scrape (approximate)** — hand-started / non-claude / codespace agents get state from `capture-pane` text | Automatic fallback; recognizes `claude codex opencode agent(cursor)` (extend via `AGENT_FLEET_AGENT_CMDS`) | README.md:156,197; snapshotd.sh:80 |
| **Desktop notification on state change** — fires on entering `wait`/`done` for **hooked** agents (`osascript` macOS / `notify-send` Linux); message `<session>/<window> needs your input`/`finished` | Automatic; on by default, `AGENT_FLEET_NOTIFY=0` silences | README.md:208; agent-status-hook.sh:46-66 |
| **Focus a specific agent pane** — the primitive behind "go to that agent" | `agent-fleet goto <pane_id>` (used by picker; `select-pane`/`switch-client`) | README.md:103; bin/agent-fleet:305-321 |
| **Reach an agent in the cloud (Codespaces)** — run an agent inside a GitHub Codespace over SSH; the fleet stays local as the supervisor | `Prefix g` / picker cloud view; `agent-fleet cs connect`; `agent-fleet add --codespace` | README.md:164-203; cs-connect.sh:1-27 |
| **Persistence across reboot** — layout saved to `fleet.state`; hooked claude agents resume via `claude --resume` | Auto on attach after reboot; `agent-fleet save`/`restore` | README.md:212-235 |

## The current journey
**How a user checks on and unblocks an agent while away from the desk, today:**

1. **Notification (partial).** If the waiting agent was launched via `agent-fleet add`/`Prefix C` (hooked), a *desktop* notification fires on the workstation — `osascript` (macOS) or `notify-send` (Linux) — reading e.g. "`dotfiles/code-review needs your input`" (agent-status-hook.sh:56-63). This is a **desktop** notification on the machine the fleet runs on; there is no push to a phone. If the agent was hand-started, non-claude, or a codespace agent, **no notification fires at all** — those run on the scrape tier, and notifications come only from the hook (README.md:208).
2. **To glance at status remotely, the only path is a remote terminal.** The user must open an SSH client on the phone (e.g. Blink/Termius — the alternatives the thesis names, 00-thesis.md:21), SSH to the workstation, and `tmux -L agent-fleet attach` to the fleet's socket. They then see the rail/picker rendered in a tiny terminal.
3. **To unblock, they must type into the pane by hand.** The fleet has no "reply to this agent" action. The most targeted thing it offers is *navigation* to the waiting agent (`Prefix Space` → `agent-fleet goto <pane_id>` → `select-pane`, next-attention.sh:73; bin/agent-fleet:321). Once focused, the user types their reply directly into Claude's TUI. On a phone-sized terminal this means driving Claude's full-screen Ink TUI through an on-screen keyboard.

**Friction / dead ends for the thesis's goal:**
- The rail/picker are full-screen tmux/fzf TUIs (README.md:5-8) — the grilling explicitly rejected porting them to mobile as "too small-screen-hostile" (00-thesis.md:25). The only remote path today *is* that rejected experience.
- Notifications are desktop-only and hook-only: away from the desk you may not learn an agent is waiting at all, and scrape-tier agents never notify (README.md:208).
- Unblocking requires full TUI keyboard interaction; there is no lightweight reply affordance.

## The gap
The thesis wants a **LAN-served mobile web (PWA) glance+unblock surface** built on `fleet.snapshot` + a pane-write path (00-thesis.md:30-32). Relative to that, the product today has:

1. **No web/HTTP surface of any kind.** Every surface is a terminal UI. Evidence of absence: a grep for `http|server|listen|port N|web|browser|pwa|localhost|POST|GET` across README.md, `scripts/`, `bin/`, `conf/` returns only tmux "server" references, GitHub/Codespaces SSH forwarding, and the sidebar mockup — no HTTP listener, no served page. The two documented surfaces are exhaustively "Picker" and "Sidenav rail" (README.md:5-8). There is nothing to add-to-homescreen.
2. **No programmatic "reply to a waiting agent" / input-injection path.** The fleet can *navigate to* a `wait` agent (`goto`/`select-pane`) but cannot *send text* to it. Evidence of absence: `grep send-keys` across `scripts/` and `bin/` returns nothing (the only `send-keys` in the repo is `send-keys -M` for copy-mode mouse scroll in `conf/agent-fleet.conf:86`). "Unblock" today = focus the pane and type. The thesis's riskiest assumption — that `tmux send-keys` into a `wait` pane suffices to unblock — is therefore **unproven in-product**: no code path exercises it, and its safety (e.g. the "prompt-input safety" concern the test suite already tracks, README.md:310) is untested for a remote injector.
3. **No off-desk reachability layer.** The only "reach the fleet from elsewhere" primitive is Codespaces, and it works the *opposite* direction: the fleet reaches *out* to a cloud container over SSH (the fleet stays the local supervisor, README.md:166; cs-connect.sh:5-7). There is no path for a remote client to reach *into* the fleet. Phase 2 (tunnel + token auth, grill/thesis.md:15) has no existing analog; there is no auth surface anywhere in the product.
4. **No mobile/phone push.** Notifications are `osascript`/`notify-send` desktop toasts on the host (agent-status-hook.sh:60-63). No browser/web push exists. (External check for the thesis's push-viability concern: iOS Safari web push works **only** for a PWA added to the Home Screen, iOS 16.4+, and is disabled for standalone PWAs in the EU under the DMA — so a Home-Screen PWA is required and adequate outside the EU, but a plain LAN tab would get *no* push. See Sources.)

**What the snapshot format already gives a builder (load-bearing for the gap):** the snapshot is line-oriented, one record per line (snapshotd.sh:9-13): `T <epoch> <interval>` (freshness), `C <session>|<window_id>` (active view), `S <session>|<rollup_state>|<branch>` (per workspace), `A <session>|<window_id>|<window_index>|<window_name>|<pane_id>|<label>|<state>` (per agent). Consumers already scale a staleness threshold off `T`'s interval field (next-attention.sh:47-53) — a web surface would need the same guard. `|` is the delimiter; user-controlled window names have `|` swapped to `¦` before writing (snapshotd.sh:84,98). Every field a "glance" needs (state, workspace, tool label, branch, pane id to target for a reply) is already present. This substantially de-risks the *read* half of the thesis; the *write* half has no precedent.

## Users in evidence
The product acknowledges essentially one persona, drawn from its own docs and the thesis framing:
- **The solo operator / repo owner** — runs the fleet on a workstation, supervises several Claude agents at once, and is the sponsor (00-thesis.md:16-17). What they ask for is stated directly in the thesis: to supervise/interact with the fleet *away from the desk* (commute, couch, travel) and specifically to **unblock a `wait` agent** from the phone (00-thesis.md:17-18,25).
- **Future adopters who run the fleet on a workstation but are away from it** — named as presumed-affected users (00-thesis.md:17). The README's "Reports welcome" (README.md:44) and "extend with `AGENT_FLEET_AGENT_CMDS`" (README.md:156) posture suggests a small, technical, self-hosting audience comfortable with tmux and CLIs.

There is no public issue tracker, discussion forum, reviews, or marketing/pricing surface in evidence (it is a personal MIT-licensed repo, README.md:314) — so "what users ask for" comes from the sponsor's thesis, not a community. The Codespaces feature (git `292b412 feat: codespaces`, and its follow-ups) is the product's own first move toward "reach the fleet from elsewhere" (00-thesis.md:14), evidencing that remote reach is an active direction the owner is already building toward.

## Documentation gaps
Questions the product surface (README, `--help`, changelog) could not answer, each worth filing:
1. **The `fleet.snapshot` record schema is undocumented for consumers.** The README says the file exists and what it's for (README.md:160) but never states the T/C/S/A line format, field order, or the `|`→`¦` escaping rule. A third party building a reader (exactly the thesis's job) has no documented contract — only the daemon's header comment.
2. **No documented staleness contract for snapshot readers.** The `T <epoch> <interval>` freshness convention and the "×3+7" staleness rule (next-attention.sh:50) are convention, not documented API — a new reader could trust frozen data.
3. **No CHANGELOG.** Release history is only reconstructable from git log; there is no user-facing record of when Codespaces/persistence/triage landed.
4. **The `wait` → unblock interaction is under-documented as a *remote* concern.** Docs describe reaching a `wait` agent (`Prefix Space`) but never how input is delivered — implicitly "you type" — leaving the injection contract (and its safety) undefined for any non-interactive client.

## Code consulted (exceptions)
The `fleet.snapshot` schema and the input-injection question are load-bearing for the thesis and are **not** answerable from README/`--help`/changelog, so I consulted the minimum needed. Each entry doubles as a documentation gap (see above).

| File | Question it answered | Why the product surface couldn't |
|---|---|---|
| `scripts/snapshotd.sh` (header:9-13, and lines 80-103) | Exact `fleet.snapshot` record format and fields — the substrate the whole thesis reads | README (160) documents the file's existence/purpose but not its schema; there is no docs page or `--help` output for the format |
| `scripts/next-attention.sh` (lines 30-53,73) | How the fleet acts on a `wait` agent today (navigate vs. inject text) and the snapshot-staleness guard a reader must honor | Behavior of `Prefix Space` is described (README.md:133) but not the read/act mechanics needed to assess the write-path gap |
| `scripts/agent-status-hook.sh` (lines 46-66) | Exact notification path/message and hook-only firing — to characterize what mobile push must replace | README.md:208 states hook-only + `osascript`/`notify-send` but not the message content or edge-trigger behavior a push design must match |
| `scripts/cs-connect.sh` (header:1-27) | Direction of the Codespaces "remote reach" (fleet→cloud vs. client→fleet) — to judge whether it's a reachability analog for Phase 2 | README.md:164-203 describes usage but I confirmed the SSH direction/forwarding to establish it is *not* an inbound path |
| `bin/agent-fleet` (lines 305-321) | That `goto`/`select-pane` is the only "act on an agent" primitive (no send-keys) | Confirms absence claimed in "The gap"; help lists `goto` but not that it is focus-only |

Grep-only checks (no logic read) confirming absence: no `send-keys` write path in `scripts/`/`bin/`; no HTTP/web/server surface anywhere; no CHANGELOG file.

## Sources
Product surface (repo `/home/hyb175/Projects/agent-fleet`, at commit `e66e5f5`, accessed 2026-07-11):
- `README.md` (cited by line).
- `bin/agent-fleet --help` / `--version` output (v0.1.0).
- `conf/agent-fleet.conf`.
- `scripts/snapshotd.sh`, `scripts/next-attention.sh`, `scripts/agent-status-hook.sh`, `scripts/cs-connect.sh`, `bin/agent-fleet` — see "Code consulted".
- Git log (release history; no CHANGELOG file exists).
- Thesis inputs: `docs/sdlc/discovery/mobile-experience/00-thesis.md`, `docs/sdlc/discovery/mobile-experience/grill/thesis.md`.

External (web, accessed 2026-07-11) — for the thesis's iOS-PWA-push viability concern only:
- [PWA iOS Limitations and Safari Support (2026) — MagicBell](https://www.magicbell.com/blog/pwa-ios-limitations-safari-support-complete-guide)
- [Sending web push notifications in web apps and browsers — Apple Developer](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)
- [iOS special requirements for web push notifications — Pushpad](https://pushpad.xyz/blog/ios-special-requirements-for-web-push-notifications)

Markers: no claim in this dossier is `[unverified]`; every statement points at a cited source. Absence claims are backed by the grep checks noted in "Code consulted".
