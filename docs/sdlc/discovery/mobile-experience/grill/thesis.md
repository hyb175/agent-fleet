# Thesis grilling — mobile-experience (2026-07-06)

Kill-shots first, one question at a time, before spending research effort.

## Q1 — Mobile job (the kill-shot)
**Q:** When you picture using agent-fleet on your phone, what are you actually doing?
Options: Glance + unblock / Full terminal / Notify only.
**A: Glance + unblock.** Check status at a glance; when an agent is waiting, tap a quick reply to unblock it. Not a full TUI, not notify-only.
**Consequence:** research targets a lightweight supervision surface, not a tmux port and not just a notifier. Rules out the two most expensive/least useful directions up front.

## Q2 — Reachability
**Q:** When an agent is waiting and you want to unblock from your phone, where are you?
Options: Same network / Anywhere off-network / Both, phased.
**A: Both, phased.** Phase 1 LAN web page (private, no auth infra). Phase 2 bring-your-own tunnel (tailscale) + token auth, same UI.
**Consequence:** Phase 1 is a local web server on the workstation reading the fleet state; transport is swappable. Avoids taking on tunnel + auth + always-on complexity before the UX is validated.

## Q3 — App form (the user's explicit "mobile app?" question)
**Q:** Installable app, or best experience regardless of form?
Options: Best UX any form / Must be native / Undecided.
**A: Best UX, any form → PWA.** Add-to-homescreen web app served from the workstation: app icon + fullscreen, browser push, one codebase, no store. Native explicitly deprioritized.
**Consequence:** answers the sponsor's "could we do an app" — yes-ish, as a PWA, not a native store app. Research should sanity-check browser/iOS PWA push viability for the "needs you" moment.

## Surviving constraints passed to researchers
- Job is glance + unblock (supervision + nudges), NOT full terminal, NOT notify-only.
- Phase 1 = LAN-served mobile web page reading existing `fleet.snapshot`; Phase 2 = tunnel + token auth, same UI.
- Form = PWA, not native.
- Riskiest assumption to probe: snapshot-read + `tmux send-keys`-write suffices for glance+unblock; browser push (esp. iOS PWA) is adequate for the wait moment.
