---
thesis: mobile-experience
phase: thesis
status: draft
date: 2026-07-06
---

# Mobile experience for agent-fleet — Problem statement

## Thesis
"What can we do with the agent-fleet on mobile? Is a mobile app something we could do? I am just looking for the best mobile experience."

## Context
agent-fleet is a tmux-native session manager for supervising multiple Claude Code agents. Every surface is a terminal UI: the picker is an `fzf` popup, the sidenav is a tmux pane, agents are tmux windows running `claude`. It all lives on a dedicated tmux socket. A recent update (`e66e5f5`) added a codespaces feature (`cs-connect.sh`) that SSHes into a remote container and runs an agent through it — the first sign of "reach the fleet from elsewhere." The sponsor wants to supervise/interact with the fleet away from the desk. "Best mobile experience" is deliberately open — grilling required to pin down what mobile actually means here (native app vs. mobile-optimized terminal access vs. notification+glance) and what the user actually does on the phone.

## Who is asking
Sponsor: the repo owner (solo tool, personal use). Users presumed affected: the owner and any future adopters who run the fleet on a workstation but are away from it (commute, couch, travel) and want to check agent status or unblock a waiting agent.

## What would make this true or false
- TRUE / worth building: there's a real recurring moment where the user is away from the workstation and an agent needs attention (a "wait" state), and current options (SSH client + tmux attach on the phone) are painful enough to avoid.
- FALSE / kill: the "away from desk" moment is rare, OR an existing mobile SSH/tmux client (Blink, Termius) already covers it well enough, OR the mobile job is really just notifications (already fired via `notify-send`/`osascript`) and doesn't need a new surface.

## Grilling decisions (2026-07-06)
Three load-bearing branches resolved with the sponsor before research:
1. **Mobile job = glance + unblock.** Supervision, not a full terminal. On the phone the user checks agent status at a glance and, when an agent is in `wait`, taps a quick reply to unblock it. NOT a mobile port of the tmux TUI (rejected: too small-screen-hostile). NOT notify-only (rejected: knowing isn't enough, user wants to act).
2. **Reachability = both, phased.** Phase 1 ships a same-network (LAN) surface — private, no cloud, no auth infra. Phase 2 bolts on an off-network path (bring-your-own tunnel like tailscale + token auth) without a UI rewrite. Transport swaps underneath a stable UI.
3. **Form = best UX, any form → PWA, not native.** The sponsor asked "could we do a mobile app" but cares about experience, not app-store presence. A mobile web page / add-to-homescreen PWA served from the workstation wins: app-like icon + fullscreen, browser push, one codebase, no store friction. Native iOS/Android is explicitly deprioritized for a solo supervision tool. (Research may still sanity-check PWA push limits on iOS.)

## Scope guesses
- In: LAN-served mobile web surface; mobile-legible status glance built on the existing `fleet.snapshot`; tap-to-reply that injects input into a waiting agent's pane; phased tunnel + auth.
- Out: full TUI reimplementation, native app, multi-user/cloud hosting, editing code on the phone.
- Riskiest assumption to test in research: that reading `fleet.snapshot` + writing to a pane (`tmux send-keys`) is enough to power glance+unblock without a deeper control API — and that browser push (esp. iOS PWA) is good enough for the "agent needs you" moment.
