---
thesis: mobile-experience
phase: discovery
artifact: market-scan
status: draft
date: 2026-07-11
analyst: market-scan agent
sources_accessed: 2026-07-11
---

# Market scan — mobile supervision for agent-fleet

## Thesis under scan
"Best mobile experience for agent-fleet." Grilled down to a concrete job: **glance + unblock** — from a phone, see agent status at a glance and, when an agent is in `wait`, tap a quick reply to unblock it. Phase 1 = LAN-served mobile web page reading the existing `fleet.snapshot`; Phase 2 = bring-your-own tunnel + token auth, same UI. Form = **PWA, not native**. Riskiest assumptions to test: (a) snapshot-read + `tmux send-keys`-write suffices for glance+unblock, and (b) browser push — especially an iOS PWA — is adequate for the "agent needs you" moment.

## TL;DR of the landscape
The exact job in this thesis — supervise a fleet of local coding agents from a phone, get pinged when one needs you, tap to unblock — went from empty to **crowded in the first half of 2026**. Anthropic itself now ships it (`/remote-control`, research preview), and at least three purpose-built third-party apps (Orca, AgentsRoom, Tactic Remote) target it directly. That reframes the decision from "is this worth building" to "why build our own instead of adopting one of these." The one place agent-fleet's plan is genuinely differentiated — **stay local, no cloud relay, LAN-first, no account** — is also where its chosen delivery mechanism (a LAN PWA with push) hits a hard platform wall on iOS.

---

## Alternatives scanned

### 1. Do-nothing / manual workaround — mobile SSH client + `tmux attach` (Blink, Termius)
The real incumbent, and the FALSE-condition the thesis itself named. The user already runs on a dedicated tmux socket; from a phone they can SSH in and `tmux -L agent-fleet attach`.

- **How it frames the problem:** "you need your terminal, remotely." Not supervision — full interactive access. The multiplexer *is* the mobile UI.
- **Shape:** native iOS/Android terminal apps. **Blink Shell** is the power pick: native **Mosh** (survives IP changes commute→train→desk), true color, custom key mappings, code-server integration; ~$19.99/year, steep learning curve, config via an in-app CLI. [blink.sh, accessed 2026-07-11] [App Store, accessed 2026-07-11] **Termius** is the polished pick: snippets (save+one-tap reuse of commands — this maps directly to "quick reply to unblock"), SFTP, cross-device sync; free tier, ~$10/mo for snippets/SFTP; praised UI, criticized as pricey; **no built-in tmux integration — you manage it manually.** [termius.com, accessed 2026-07-11] [G2 reviews, accessed 2026-07-11]
- **Praise / complaints:** Blink users love Mosh resilience and terminal fidelity; complain about the learning curve and the GPL3-but-paid friction. Termius users love snippets and host management; complain about price and thin theming.
- **Why it's the competition to beat:** it already works today, zero build, and the agent-fleet TUI (rail + picker) runs inside it. **The kill-shot the thesis must answer:** is `tmux attach` in Blink/Termius genuinely too painful for glance+unblock, or just mildly annoying? The tell in favor of building: the agent-fleet TUI is a 30-col rail plus an fzf popup and a full Claude TUI — small-screen-hostile, which the sponsor already flagged. The tell against: Termius snippets make "send a canned reply to a pane" a one-tap operation *without any new surface*.
- **Confidence:** high on capabilities/pricing (vendor + store + G2). The "too painful?" judgment is the sponsor's to make and is not settled by the web.

### 2. Claude Code `/remote-control` (`/rc`) — first-party, the elephant
Anthropic shipped the thesis's exact job as a native feature.

- **How it frames the problem:** "babysit long-running work, approve permissions on the move, get pinged when a task finishes" — verbatim the glance+unblock job. [inventivehq.com, accessed 2026-07-11]
- **Shape:** the session stays on your machine (files, tools, MCP all local); only the conversation and permission prompts traverse Anthropic's cloud via **outbound HTTPS polling — no inbound ports opened.** Access via the Claude mobile app's Code tab, a direct URL, or a QR scan; it's a **thin-client web interface, not a native app.** Auth = Claude account login with short-lived single-purpose credentials. Push notifications fire when a task completes or a decision is needed. [inventivehq.com, accessed 2026-07-11] [codebridge.tech, accessed 2026-07-11]
- **Status / pricing:** **research preview** as of June 2026; requires Claude Code v2.1.51+; included on Pro/Max/Team/Enterprise at no extra cost. [inventivehq.com, accessed 2026-07-11]
- **What it validates:** the local-session-stays-local architecture agent-fleet wants, the outbound-poll transport (no inbound port / no exposed LAN service), and push-on-needs-you as the core interaction. These are strong prior art to borrow.
- **Where it doesn't cover agent-fleet:** it's **per-session**, not fleet-wide — no cross-workspace rail, no "next agent that needs you" triage across many agents, and it routes through **Anthropic's cloud** (the sponsor explicitly wants no cloud, LAN-first). It also only covers `claude`; agent-fleet tracks `codex`/`opencode`/`cursor` and codespace agents too.
- **Biggest implication:** for a solo user already on Claude Max, `/rc` may satisfy "supervise my agent from the couch" for free with zero build — for a single agent. agent-fleet's defensible wedge is **the fleet view** (many agents, many workspaces, one triage queue) and **no-cloud LAN**. Confidence: high (multiple 2026 sources), but note this is a fast-moving preview — re-check before committing.

### 3. Orca (stablyai/orca) — direct competitor, fleet-native, mobile-first
The closest match to agent-fleet's *whole* premise, not just the mobile slice.

- **How it frames the problem:** "the ADE for working with a fleet of parallel agents… run any coding agent with your own subscription… available on desktop and mobile." Runs Claude Code, Codex, OpenCode, Pi, Grok, 20+ CLIs side-by-side, each in its own git worktree. [github.com/stablyai/orca, accessed 2026-07-11]
- **Mobile shape:** "Monitor and steer your agents from your phone — get notified when an agent finishes and send follow-ups from anywhere." Native iOS (App Store/TestFlight) + Android (APK). Connection architecture (LAN vs cloud relay vs tunnel) is **not disclosed** in the README; the mobile docs at onorca.dev/docs/mobile presumably specify it. [github.com/stablyai/orca README, accessed 2026-07-11]
- **Positioning:** MIT-licensed, free, open source, ~12.5k+ GitHub stars, YC-backed as of July 2026. [vibecodinghub.org, accessed 2026-07-11] [github.com/stablyai/orca, accessed 2026-07-11]
- **Overlap with agent-fleet:** parallel multi-agent fleet, bring-your-own subscription, phone monitor + notify + follow-up, multi-CLI support. This is the "someone already built the whole thing, mobile included, and open-sourced it" competitor.
- **Divergence:** Orca is a worktree-based ADE (its own desktop app + native mobile app); agent-fleet is tmux-native (sessions/windows on a private socket, TUI-first, no worktree model). Orca's mobile is **native**, contradicting agent-fleet's PWA choice — a signal worth weighing: a well-resourced competitor chose native for mobile fleet supervision. Confidence: capabilities high (repo + reviews); connection architecture unverified (README silent) — mark single-source until onorca.dev/docs/mobile is read.

### 4. AgentsRoom — direct competitor, explicit local-first + relay architecture
Most transparent about the exact architecture agent-fleet's Phase 2 is reaching for.

- **How it frames the problem:** sync desktop agent sessions (Claude, Codex, OpenCode, Antigravity CLI, Aider) to your phone in real time; start agents, type commands, send saved prompts, check progress from anywhere. [agentsroom.dev/mobile-app, accessed 2026-07-11]
- **Shape / architecture:** **local-first with an encrypted cloud relay** — agents run locally; the phone connects through a relay that forwards **opaque encrypted blobs only** (X25519 ECDH key exchange, XSalsa20-Poly1305). Native app (Expo/React Native), iOS + Android. Capabilities: launch agents, full terminal interaction, one-tap saved prompts, dev-server preview via built-in secure tunnel, token-usage/status bars, and **"push notifications alert you when an agent finishes or needs attention."** Desktop app must stay running; the phone is purely a remote interface. [agentsroom.dev/mobile-app, accessed 2026-07-11]
- **Why it matters for the thesis:** it's a working, shipped implementation of "local agents + encrypted relay + native mobile + push-on-needs-you." The saved-prompts one-tap feature is exactly agent-fleet's "tap a quick reply to unblock." The encrypted-relay pattern is a concrete design agent-fleet's Phase 2 (bring-your-own tunnel) could borrow or contrast against. Confidence: high (vendor page, architecture explicitly stated).

### 5. Tactic Remote — adjacent, multi-agent supervision framing
- **How it frames the problem:** turns "mobile AI coding" from a single remote session into a workflow to "choose, compare, and supervise agents from anywhere." Explicitly multi-agent, phone-driven. [tacticremote.com, accessed 2026-07-11]
- **Shape:** productized mobile supervision layer over Claude/Codex/AMP. Details thinner than the above; included as evidence the multi-agent-from-phone category has multiple entrants, not to be leaned on. Confidence: low (single marketing source) — treat as category signal only.

### 6. Adjacent baseline — CI / long-running-job mobile supervision (GitHub Mobile)
The mature analogue for "long job runs elsewhere, tell me on my phone, let me act."

- **What it does well:** push notifications on workflow success/failure (configurable to failures-only), and **deployment approvals from the phone** — approve/reject a job awaiting review, with push on review requests. [github.blog changelog 2023-01-17, accessed 2026-07-11] [github.blog, accessed 2026-07-11]
- **The documented gap (borrowable lesson):** you can be *notified* that a **workflow run** needs approval but **cannot approve it from the app** — you're bounced to the website. [github.com/community discussion #110751, accessed 2026-07-11] This is the exact failure mode the thesis must avoid: **notify-without-act is the anti-pattern.** The thesis already ruled out notify-only for this reason; GitHub Mobile is the cautionary tale that "notify but can't act" is nearly as frustrating as notify-only, and users file feature requests about it.

### 7. Adjacent tool users repurpose — ttyd / gotty (terminal-over-web)
- **What it is:** serve any terminal (including a `tmux attach`) as a web app over HTTP/WebSocket. gotty defaults to :8080, ttyd to :7681 (C/libwebsockets, faster). Read-only by default; `-w` permits input; `-c` adds basic auth. [github.com/yudai/gotty, accessed 2026-07-11] [github.com/tsl0922/ttyd, accessed 2026-07-11]
- **Relevance:** the cheapest path to *any* mobile web surface today — `ttyd tmux -L agent-fleet attach` gives a browser terminal on the LAN in one command. But it's a **full-terminal** surface (the thesis rejected that as small-screen-hostile) with **no push, no glance UI, no service worker** — it's the raw-transport version of the rejected "port the TUI" direction. Useful as a Phase-0 spike or fallback, not the product.

---

## Table stakes vs differentiators in this space

**Table stakes (users treat as expected):**
- Agent state at a glance (working / needs-input / done) across multiple agents. [Orca, AgentsRoom, /rc]
- **Push on "needs you / finished"** — every serious entrant has it; its absence reads as broken. [/rc, Orca, AgentsRoom, GitHub Mobile]
- **Act from the phone, not just watch** — approve/reply/unblock inline. The GitHub Mobile gap proves notify-without-act is a known dissatisfier. [github community #110751]
- Session stays local; the phone is a thin remote, not a code editor. [/rc, AgentsRoom]
- One-tap canned replies / snippets for common unblocks. [Termius snippets, AgentsRoom saved prompts]

**Differentiators still available to agent-fleet:**
- **No cloud, no account, LAN-first.** `/rc` routes through Anthropic; AgentsRoom through a relay; Orca's path is undisclosed. A genuinely local-only, no-signup supervision surface is an open lane and matches the sponsor's stated value.
- **Fleet-wide triage from the phone** — "next agent that needs you" across all workspaces (agent-fleet already has `Prefix Space` triage and a most-urgent-first queue in the snapshot). `/rc` is per-session; this is agent-fleet's structural edge.
- **Multi-tool + codespace agents in one view** — the snapshot already tracks claude/codex/opencode/cursor and codespace agents.

**Terminology to speak in requirements** (the language users/competitors already use): "monitor and steer," "get pinged / notified when an agent finishes or needs attention," "approve permissions on the move," "send follow-ups," "snippets / saved prompts," "session stays local / thin client," "worktree" (Orca) vs agent-fleet's "workspace/window."

---

## Prior art worth borrowing
- **Outbound-poll transport, no inbound port** (`/rc`): sidesteps exposing a LAN server and much of the auth surface — relevant to both phases. [inventivehq.com]
- **Encrypted relay forwarding opaque blobs** (AgentsRoom): a concrete, publishable design for Phase 2's "bring-your-own tunnel" if a relay is ever preferred over tailscale. [agentsroom.dev]
- **One-tap saved prompts / snippets** (AgentsRoom, Termius): the cheapest high-value form of "tap to unblock."
- **Failures-only / needs-you-only notification filtering** (GitHub Mobile): avoid notification fatigue; only push `wait`/`done`, which agent-fleet's hook model already distinguishes.

## Approaches that visibly failed / cautionary tales
- **Notify-but-can't-act** (GitHub Mobile workflow-run approvals): notifications ship, the action button doesn't, users get bounced to the website and file feature requests. [github community #110751] The lesson the thesis already internalized — do not ship glance-without-unblock.
- **Full-terminal-on-phone as the primary UX**: the reason Blink/Termius+tmux is a "workaround" not a "solution" for supervision, and why ttyd isn't the product — the sponsor pre-rejected the small-screen TUI. The market's purpose-built entrants (Orca, AgentsRoom, /rc) all chose a *purpose-built supervision UI* over raw terminal, corroborating that call.

---

## Sanity-check: PWA push viability, especially iOS (the riskiest assumption)
The thesis's Phase 1 is a **LAN-served** PWA (e.g. `http://192.168.x.x`) with push. This collides with two hard, documented platform rules:

1. **iOS web push requires the PWA to be installed to the Home Screen and opened from there.** A plain Safari tab has no `PushManager`. Requires iOS 16.4+ (March 2023). No auto-install prompt — the user must "Add to Home Screen" manually. All iOS browsers use WebKit, so this is universal on iOS, not Safari-specific. **Web push is blocked entirely in the EU under DMA-related changes (iOS 17.4+).** [magicbell.com, accessed 2026-07-11] [webscraft.org, accessed 2026-07-11] [mobiloud.com, accessed 2026-07-11]

2. **Service workers and the Push API require a secure context — and a private LAN IP is not one.** Per MDN, `http://localhost`, `http://127.0.0.1`, and `http://*.localhost` are potentially trustworthy; **`http://192.168.x.x` is not.** Both Service Workers and the Push API require a secure context. [MDN Secure Contexts, accessed 2026-07-11] Self-signed certs get the SW registration blocked by browsers unless the cert is explicitly trusted on the device; localhost's exemption does **not** extend to LAN IPs. [deanhume.com, accessed 2026-07-11] [MDN, accessed 2026-07-11]

**Consequence for Phase 1 as written:** a bare `http://<LAN-IP>` PWA on an iPhone **cannot register a service worker, cannot be a real installable PWA, and cannot receive push.** To get iOS push on the LAN you must serve over HTTPS with a **device-trusted certificate** (e.g. a locally-trusted CA / mkcert profile installed on the phone, or a real cert via a tailscale-MagicDNS/`*.ts.net` name), then Add-to-Home-Screen. That pulls a chunk of the sponsor's Phase-2 (trust/cert/tunnel) work forward into Phase 1 the moment iOS push is in scope — the "swap transport under a stable UI, no cloud, no auth infra for Phase 1" plan does **not** hold if push-on-iOS is a Phase-1 requirement. Android/desktop Chrome are far more forgiving (and Chrome allows treating an origin as secure for testing), but iOS is the binding constraint and, on current sponsor hardware assumptions, likely the target device. **This is the assumption most likely to be wrong as stated, and it's cheap to de-risk before building: it's a documented platform rule, not something to discover in code.** Confidence: high (MDN + multiple 2026 iOS-PWA guides converge).

Fallback if HTTPS-on-LAN is too much for Phase 1: ship the glance UI as a plain LAN web page (no push, no install) and rely on agent-fleet's **existing desktop `notify-send`/`osascript` notifications** at the workstation, or forward those to the phone via an existing push bridge (ntfy/Pushover) out of band — decoupling "notify" from the web surface, exactly as GitHub does. This keeps Phase 1 truly no-infra at the cost of no in-PWA push until HTTPS lands.

---

## Contradictions with the product dossier
- The dossier's **Form decision (PWA, LAN-served, push, "no auth infra in Phase 1")** is in tension with the platform reality above: on iOS, in-app push forces HTTPS + a trusted cert + home-screen install into Phase 1, which is closer to the dossier's own Phase-2 scope. Not resolved here — flagged for the sponsor.
- Two well-resourced direct competitors (Orca, AgentsRoom) and Anthropic's own `/rc` chose **native** mobile apps (or a first-party web client), not a self-served PWA. This doesn't invalidate the PWA choice for a solo tool, but it is contrary evidence to "PWA is obviously the best form here" and should be acknowledged rather than assumed.

---

## Sources (all accessed 2026-07-11)
- Blink Shell — https://blink.sh/ ; App Store — https://apps.apple.com/us/app/blink-shell-build-code/id1594898306
- Termius — https://termius.com/ ; pricing https://termius.com/pricing ; G2 reviews https://www.g2.com/products/termius/reviews
- Claude Code /remote-control — https://inventivehq.com/blog/claude-code-from-your-phone-remote ; https://www.codebridge.tech/articles/claude-code-remote-control-what-tech-leaders-need-to-know-before-they-use-it-in-real-engineering-work
- Orca — https://github.com/stablyai/orca ; README https://github.com/stablyai/orca/blob/main/README.md ; https://vibecodinghub.org/blog/orca-review
- AgentsRoom — https://agentsroom.dev/mobile-app
- Tactic Remote — https://tacticremote.com/blog/2026-04-28-mobile-ai-coding-with-claude-codex-amp/
- GitHub Mobile / Actions — https://github.blog/changelog/2023-01-17-push-notifications-for-actions-on-mobile/ ; https://github.com/orgs/community/discussions/110751 ; https://github.com/mobile
- ttyd — https://github.com/tsl0922/ttyd ; gotty — https://github.com/yudai/gotty
- iOS PWA push — https://www.magicbell.com/blog/pwa-ios-limitations-safari-support-complete-guide ; https://www.mobiloud.com/blog/progressive-web-apps-ios ; https://webscraft.org/blog/pwa-pushspovischennya-na-ios-u-2026-scho-realno-pratsyuye?lang=en
- Secure contexts / service workers — https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts ; https://deanhume.com/testing-service-workers-locally-with-self-signed-certificates/
