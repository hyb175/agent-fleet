---
thesis: mobile-experience
phase: discovery
artifact: product-brief
status: draft
date: 2026-07-11
recommendation: build (Phase 1); adjust one fixed assumption (see Risks)
---

# Product brief — mobile glance + unblock for agent-fleet

> Note on template: the workflow passed the template path as `undefined` and no
> `product-brief.md` template exists in the repo. This brief follows the section
> contract the process prescribes (problem, users, success metrics, requirements
> with evidence, non-goals, risks, slices) and the frontmatter/citation
> conventions of the sibling artifacts (`01-product-research.md`,
> `02-market-scan.md`). If a canonical template lands later, re-flow to it.

## Recommendation (one line)
**Build Phase 1** — a LAN-served mobile web glance+unblock surface over the
existing `fleet.snapshot` plus a guarded pane-write path — but **adjust one fixed
assumption**: in-app push cannot be a Phase-1 requirement on iOS without pulling
HTTPS/trusted-cert work forward, so Phase 1 ships glance+unblock without in-app
push and reuses existing desktop notifications (see Risks R1).

## Scope guardrails (fixed by the thesis — not relitigated here)
These were resolved with the sponsor during grilling (00-thesis.md:23-27;
grill/thesis.md:5-27) and are treated as **constraints**, not open questions:

- **Job = glance + unblock.** A lightweight supervision surface: see agent status
  at a glance and, when an agent is in `wait`, tap a quick reply to unblock it.
  NOT a mobile port of the tmux TUI. NOT notify-only. (00-thesis.md:25)
- **Reachability = both, phased.** Phase 1 is same-network (LAN), no cloud, no
  auth infra. Phase 2 bolts on a bring-your-own tunnel (e.g. tailscale) + token
  auth under the same UI. (00-thesis.md:26; grill/thesis.md:11-15)
- **Form = PWA, not native.** App-icon / add-to-home-screen web app served from
  the workstation; native iOS/Android explicitly deprioritized. (00-thesis.md:27;
  grill/thesis.md:17-21)
- **Solo maintainer.** Single-user personal tool; slices must fit a solo builder
  and Phase 1 must be separable from Phase 2. (01-product-research.md:11,53-57)

---

## Problem

**Who has it:** the solo operator / repo owner, who runs the fleet on a
workstation and supervises several Claude agents at once (01-product-research.md:53-54);
and future self-hosting adopters who run the fleet on a workstation but are away
from it (01-product-research.md:55).

**When it bites:** when the operator is away from the desk — commute, couch,
travel — and an agent enters `wait` (needs input) and stalls until they return
(00-thesis.md:17-18,25). Long-running agent work is precisely the moment
supervision matters, and it is when the operator is least likely to be at the
keyboard.

**What it costs:** a stalled agent does no work until unblocked. The operator
either (a) stays chained to the desk to catch `wait` states, or (b) accepts that
away-from-desk time is dead time for the fleet. The whole point of running
several agents in parallel — throughput — is undercut every time one blocks
unseen.

**Why the product doesn't solve it today** (per the dossier):
1. **No web/HTTP surface of any kind exists** — every surface is a terminal UI
   (picker + sidenav rail); there is nothing to add-to-home-screen and no served
   page (01-product-research.md:45).
2. **No programmatic "reply to a waiting agent" path** — the fleet can *navigate
   to* a `wait` agent (`goto`/`select-pane`) but cannot *send text* to it; there
   is no `send-keys` write path anywhere in `scripts/`/`bin/`
   (01-product-research.md:46).
3. **Notifications are desktop-only and hook-only** — `osascript`/`notify-send`
   toasts fire on the host machine, never to a phone, and never at all for
   scrape-tier (hand-started / codespace / non-claude) agents
   (01-product-research.md:33,39,48).
4. **The only remote path today is the rejected one** — SSH + `tmux attach` in a
   phone terminal (Blink/Termius) renders the small-screen-hostile TUI the
   grilling explicitly ruled out (01-product-research.md:34-38; 02-market-scan.md:23-31).

**What already de-risks the build:** the *read* half is well-supported. A single
daemon (`snapshotd.sh`) polls tmux ~1/s and writes `fleet.snapshot`, a
line-oriented file whose `A` records already carry every field a glance needs —
state, workspace, tool label, branch, and the `pane_id` to target for a reply
(01-product-research.md:18,50). The fleet also already computes a most-urgent-first
attention queue (`wait` before `done`) via `Prefix Space` / `next-attention.sh`
(01-product-research.md:21). The *write* half has no precedent and is the risk
(see R2).

---

## Users

Primary and effectively only persona (01-product-research.md:52-57):

- **The solo operator (sponsor).** Technical, comfortable with tmux/CLIs, runs
  the fleet on a workstation, wants to supervise and unblock from the phone while
  away. This brief is written for their job.
- **Future self-hosting adopters** (secondary, presumed): same shape, small
  technical audience — no community signal exists, so requirements are drawn from
  the sponsor's thesis, not from a user base (01-product-research.md:56-57).

No public issue tracker, forum, reviews, or pricing surface exists
(01-product-research.md:57) — treat any user demand beyond the sponsor's stated
job as an assumption.

---

## Success metrics

Leading indicators the sponsor can actually observe for a single-user tool
(vanity metrics like install counts are meaningless here):

- **M1 — Time-to-unblock while away drops.** Median wall-clock from an agent
  entering `wait` to receiving input, measured for away-from-desk episodes,
  falls versus the SSH-attach baseline. This is the core value: a stalled agent
  resumes sooner. (Job def: 00-thesis.md:25)
- **M2 — Away-from-desk unblocks actually happen on the phone.** Count of `wait`
  states resolved via the mobile surface (vs. left until the operator returns to
  the desk). A surface that ships but is never used to unblock has failed the
  "act, not just watch" test (02-market-scan.md:79,99).
- **M3 — Glance replaces the SSH-attach workaround.** The operator reaches for
  the mobile surface instead of Blink/Termius + `tmux attach` for status checks —
  i.e. the rejected experience is abandoned. (Baseline: 01-product-research.md:34-38)
- **M4 — No unsafe or mistaken injections.** Zero incidents of a reply landing in
  the wrong pane or corrupting an agent's input. Injecting text into a live
  Claude TUI is unproven and safety-sensitive (R2); a correctness regression here
  is worse than no feature. (01-product-research.md:46)
- **M5 (Phase 2 gate) — reachable off-network without a cloud relay.** The
  operator can glance+unblock from outside the LAN over their own tunnel, with
  token auth, and no session/conversation data traverses a third party's cloud —
  the differentiator the market scan identifies (02-market-scan.md:84).

**Assumption (labeled):** the research provides no telemetry or instrumentation
in the product today, so M1–M4 must be measured by the sponsor manually
(self-observation / lightweight logging) unless a measurement path is built.
Treat "how we measure" as an open question, not a solved one.

---

## Product requirements

Prioritized MoSCoW. Each requirement is product-level (what the user must be able
to accomplish) and cites its evidence. Implementation shape (HTTP framing, service
worker specifics, tmux command choice) is deliberately left to the engineering
pipeline.

### Must — Phase 1 (LAN)
- **PR-1 — Glance at fleet status from the phone.** From a phone on the same
  network, the operator can open a served surface and see, at a glance, every
  agent's state (`working` / `wait` / `done` / `idle`), its workspace, tool
  label, and branch — legibly on a small screen. *Evidence:* the glance job
  (00-thesis.md:25); all needed fields already in `fleet.snapshot` `A`/`S` records
  (01-product-research.md:50); table-stakes "state at a glance across multiple
  agents" (02-market-scan.md:77).
- **PR-2 — Surface the attention queue first.** The surface presents agents that
  need attention most-urgent-first (`wait` before `done`), matching the fleet's
  existing triage, so the operator sees "what needs me" without scanning.
  *Evidence:* existing `Prefix Space` triage / most-urgent-first queue
  (01-product-research.md:21); fleet-wide triage is agent-fleet's differentiator
  vs. per-session `/rc` (02-market-scan.md:85).
- **PR-3 — Reply to a `wait` agent from the phone.** When an agent is in `wait`,
  the operator can send a reply from the phone that reaches that specific agent
  and unblocks it. *Evidence:* the unblock job (00-thesis.md:25); no such path
  exists today (01-product-research.md:46); "act from the phone, not just watch"
  is table stakes and notify-without-act is the proven anti-pattern
  (02-market-scan.md:79,99).
- **PR-4 — Reply targets the correct agent safely.** A reply is delivered to the
  intended pane and only that pane; the surface guards against stale targets
  (a `pane_id` that has moved/closed) and against injection that could corrupt a
  live TUI's input. *Evidence:* injection is unproven in-product and its safety is
  untested for a remote injector (01-product-research.md:46); snapshot readers must
  honor a staleness guard (01-product-research.md:50). Ties to M4.
- **PR-5 — Trust only fresh state.** The surface detects and visibly flags stale
  snapshot data rather than presenting frozen state as live, using the snapshot's
  freshness/interval signal. *Evidence:* `T <epoch> <interval>` freshness convention
  and the staleness rule existing consumers already apply
  (01-product-research.md:50,62).
- **PR-6 — Install as an app icon / fullscreen (PWA), no app store.** The surface
  is add-to-home-screen installable and runs fullscreen. *Evidence:* fixed form
  decision (00-thesis.md:27; grill/thesis.md:17-21).

### Should — Phase 1
- **PR-7 — One-tap canned replies.** The operator can send common unblock replies
  (e.g. "yes", "continue", "approve") in one tap, not just free text. *Evidence:*
  one-tap snippets/saved-prompts is the cheapest high-value form of "tap to
  unblock," proven by Termius snippets and AgentsRoom saved prompts
  (02-market-scan.md:81,95).
- **PR-8 — Learn that an agent needs you while away.** The operator is alerted to
  a new `wait` (and optionally `done`) state without keeping the surface open —
  filtered to needs-you states only, to avoid notification fatigue. *Evidence:*
  push-on-needs-you is table stakes (02-market-scan.md:78); failures-only /
  needs-you-only filtering avoids fatigue (02-market-scan.md:96); the fleet's hook
  model already distinguishes `wait`/`done` (01-product-research.md:23,25).
  **See R1:** the *delivery mechanism* for PR-8 in Phase 1 is constrained — see
  Risks; in-app web push is NOT assumed for Phase 1.

### Could — Phase 1
- **PR-9 — Acknowledge / clear a `done` agent from the phone.** Mirror the desktop
  behavior where visiting a `done` agent marks it seen and drops it from the queue.
  *Evidence:* existing `done` acknowledgement behavior (01-product-research.md:22).
- **PR-10 — Cover scrape-tier agents too.** Include hand-started / codespace /
  non-claude agents in the glance (they exist in the snapshot). *Evidence:* multi-tool
  + codespace agents in one view is a differentiator (02-market-scan.md:86); note
  those agents have no hook and thus weaker state/notification precision
  (01-product-research.md:24,33).

### Must — Phase 2 (off-network), separable from Phase 1
- **PR-11 — Reach the fleet off-network over a bring-your-own tunnel, no cloud
  relay.** The same UI works from outside the LAN via the operator's own tunnel
  (e.g. tailscale); no session/conversation data traverses a third party's cloud.
  *Evidence:* fixed phased reachability (00-thesis.md:26; grill/thesis.md:11-15);
  no-cloud/LAN-first is the open differentiator (02-market-scan.md:84).
- **PR-12 — Token auth gates access.** Off-network access requires a token; there
  is no auth surface in the product today, so this is net-new. *Evidence:* fixed
  Phase-2 scope (00-thesis.md:26); no auth surface exists (01-product-research.md:47).
- **PR-13 — Transport swaps under a stable UI.** Moving from LAN to tunnel does not
  require a UI rewrite. *Evidence:* fixed "transport swaps underneath a stable UI"
  (00-thesis.md:26).

---

## Non-goals

Explicitly out of scope (fixed by thesis or de-scoped here):

- **A mobile port of the tmux TUI / full terminal on the phone.** Rejected as
  small-screen-hostile; the market's purpose-built entrants corroborate the call
  (00-thesis.md:31; 02-market-scan.md:100).
- **A native iOS/Android app.** Deprioritized in favor of PWA (00-thesis.md:27,31).
- **Any cloud/relay-hosted or multi-user path.** LAN-first, no account; the
  no-cloud stance is the differentiator, not a limitation to fix later
  (00-thesis.md:31; 02-market-scan.md:84).
- **Editing code on the phone.** The phone is a thin supervision surface, not an
  editor (00-thesis.md:31; 02-market-scan.md:80).
- **Cloud push infrastructure of our own.** Phase 1 does not build a push service;
  see R1 for the constrained delivery path.
- **Building our own competitor to `/rc`/Orca/AgentsRoom on their terms.** The
  wedge is fleet-wide triage + no-cloud LAN, not feature parity with cloud-relay
  native apps (02-market-scan.md:39-40,84-86).

---

## Risks & riskiest assumptions

Ordered by how load-bearing and how likely-wrong. Each has a cheap test.

- **R1 (riskiest — a fixed plan assumption is contradicted by a platform rule).**
  The thesis assumes Phase 1 is a LAN PWA with browser push and "no auth infra"
  (00-thesis.md:26-27,30). But iOS web push **requires** the PWA installed to the
  Home Screen AND a **secure context**, and a bare `http://192.168.x.x` is not a
  secure context — so it can register no service worker and receive no push;
  getting iOS push on the LAN forces HTTPS + a device-trusted cert (mkcert /
  `*.ts.net`) into Phase 1, i.e. Phase-2-shaped work
  (02-market-scan.md:104-118). Web push is also blocked in the EU under the DMA
  (02-market-scan.md:107). **Adjustment:** do **not** make in-app push a Phase-1
  requirement. Phase 1 ships glance+unblock and satisfies PR-8 by reusing the
  fleet's **existing desktop `notify-send`/`osascript` notifications**, optionally
  bridged to the phone out-of-band (ntfy/Pushover), decoupling notify from the web
  surface exactly as GitHub Mobile does (02-market-scan.md:113). In-app web push
  becomes a Phase-2 concern that rides on the trusted-cert/tunnel work.
  **Cheapest test:** none needed to *confirm* — this is a documented platform rule,
  not a code discovery (02-market-scan.md:111). Test only *which device* is the
  target: ask the sponsor whether the phone is iOS or Android (Android/Chrome is
  far more forgiving). One question, no build.
- **R2 (riskiest technical unknown — the write half has no precedent).** The
  thesis assumes `tmux send-keys` into a `wait` pane is enough to unblock, but no
  code path exercises it and its safety is untested for a remote injector
  (01-product-research.md:46). **Cheapest test:** a throwaway spike — inject text
  into a live `wait` Claude pane via `send-keys` and observe whether it cleanly
  submits a turn (and whether stale/moved `pane_id` targets mis-fire). This is the
  first thing to validate; it gates PR-3/PR-4 and M4. (Sliced first below.)
- **R3 — the whole thing may be unnecessary if the SSH workaround is "just mildly
  annoying," or if `/rc`/Orca already suffice.** Anthropic's `/rc` and OSS Orca /
  AgentsRoom ship this job (02-market-scan.md:32-56). But each routes through a
  cloud/relay or is per-session, missing agent-fleet's fleet-wide + no-cloud wedge
  (02-market-scan.md:39-40,84-85). **Cheapest test:** the sponsor's own call —
  spend one away-from-desk week using `/rc` (for a single agent) and Termius
  snippets, and judge whether fleet-wide no-cloud triage is missed. If not, this is
  a deprioritize. This is a judgment the web cannot settle (02-market-scan.md:30).
- **R4 — competitors chose native, not PWA.** Two well-resourced direct
  competitors and Anthropic chose native/first-party clients over a self-served PWA
  (02-market-scan.md:119). Contrary evidence, not disqualifying for a solo tool —
  acknowledged, not relitigated (form is fixed). Revisit only if the PWA path
  proves untenable on the target device.

**Assumptions carried as assumptions (research lacks the fact):**
- The sponsor's phone platform (iOS vs Android) is not recorded in research; R1's
  severity depends on it. Open question.
- Whether the operator wants `done` alerts or only `wait` alerts is unstated;
  PR-8 assumes needs-you-only by default. Open question.
- No measurement/telemetry exists for M1–M4; how success is observed is an open
  question, not a built capability.

---

## Feature slices (handoff)

Four slices, each sized for one solo-maintainer cycle, ordered so the riskiest
assumption is validated first. Phase 1 (S1–S3) is fully separable from Phase 2
(S4). An engineering team can take S1 and run the requirements phase without
asking the business anything.

### S1 — `unblock-write-spike` (validate R2 first)
The riskiest unknown, isolated. Prove that a reply can be delivered to a specific
`wait` agent's pane safely and that it cleanly submits a turn, including handling
of stale/moved `pane_id`. No web surface required — can be a CLI-level proof.
Delivers PR-3/PR-4's core mechanism; gates everything downstream and M4.
*Requirements:* PR-3, PR-4. *Evidence:* 01-product-research.md:46,50.

### S2 — `lan-glance` (the read half, high-confidence)
A LAN-served, mobile-legible glance page over `fleet.snapshot`: fleet status
at a glance, attention queue most-urgent-first, staleness flagging, installable as
a PWA. Read-only; no reply yet. Ships the supervision value and M3.
*Requirements:* PR-1, PR-2, PR-5, PR-6; PR-10 optional. *Evidence:*
01-product-research.md:18,21,50,62; 02-market-scan.md:77,85.

### S3 — `tap-to-unblock` (join read + write)
Wire S1's guarded write path into S2's UI: tap a `wait` agent, send free-text or
one-tap canned replies, and (if `done` ack is cheap) clear a `done` agent.
Delivers the full glance+unblock loop and M1/M2. Notifications in this slice reuse
existing desktop notify (per R1); **no in-app web push.**
*Requirements:* PR-3, PR-4, PR-7; PR-8 via existing desktop notify; PR-9 optional.
*Evidence:* 00-thesis.md:25; 01-product-research.md:22,33; 02-market-scan.md:81,113.

### S4 — `tunnel-auth` (Phase 2, separable)
Off-network reach over a bring-your-own tunnel (e.g. tailscale) with token auth,
same UI, no cloud relay. This slice is also where a device-trusted cert / `*.ts.net`
name makes real iOS in-app web push viable (folding R1's blocker into the phase
where it naturally belongs). Gated by M5.
*Requirements:* PR-11, PR-12, PR-13; enables in-app PR-8. *Evidence:*
00-thesis.md:26; 01-product-research.md:47; 02-market-scan.md:84,111,113.

---

## Critique responses
_(none yet — initial synthesis, not a revision)_
