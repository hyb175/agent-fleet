# Market/UX scan — multi-agent session managers

Scope: UX mechanics transferable to agent-fleet (tmux-native TUI fleet manager; rail sidebar, fzf picker, wait/done inbox popup, task records, isolation ladder, reboot restore, desktop notifications). Surveyed September 2026 via web research (READMEs, docs, changelogs, HN/reddit/forum threads). GUI tools included where the mechanic transfers to a TUI.

---

## Terminal-native peers

### Claude Squad (smtg-ai/claude-squad)
Go TUI over tmux + git worktrees; supports Claude Code, Codex, Gemini, Aider, OpenCode, Amp. ~8.4k stars, AGPL; active but slowing (38 unmerged PRs).

- Two-tab detail pane: `tab` toggles live terminal preview vs diff view for the selected session; scroll the diff without attaching. Review-without-attach is the core loop. — https://github.com/smtg-ai/claude-squad
- Single-key git lifecycle: `s` commit-and-push; `c` "checkout" commits, pauses the session and frees the worktree for your own shell; `r` resumes later. Pause/resume as a first-class state.
- `N` creates a new session with a prompt in one step (no attach); `--autoyes` flag auto-accepts permission prompts fleet-wide.
- Manager-as-lens model: `enter` attaches to the raw tmux session, `ctrl-q` detaches back — it never replaces tmux.
- Avoid: stdin race loses keystrokes on attach (#325); prompts injected before the CLI is ready are silently dropped (#266) — poll for readiness before injecting text. Top user asks: type to a session from the list without attaching (#312), compact list mode (#296). — https://github.com/smtg-ai/claude-squad/issues

### workmux (raine/workmux)
Rust tmux+worktree manager, ~2.4k stars, very active — closest direct competitor.

- Agent status pushed into tmux window names as icons (🤖 working, 💬 waiting, ✅ done); waiting/done icons auto-clear when you focus the window. Zero-UI status in the stock tmux bar. — https://github.com/raine/workmux
- `workmux merge` is atomic: merge (configurable merge/rebase/squash) + close window + remove worktree + delete branch; `--keep` opts out. Kills the cleanup chore.
- Dashboard TUI: live preview of selected agent, diff view with interactive patch staging, and "agent input mode" — type a prompt to any agent from the dashboard without attaching.
- Per-project `.workmux.yaml`: pane layout, files copied/symlinked into new worktrees (gitignored .env), post_create/pre_merge hooks; `workmux setup` auto-installs status hooks into agent configs.

### claude_code_agent_farm (Dicklesworthstone)
Batch-runs 20-50 headless Claude Code agents for bug-sweep workflows; 916 stars, maintained.

- Fleet health table: per-agent status, cycle count, **context % remaining**, runtime, heartbeat age, error count; pane titles carry context warnings (⚠️ ≤20%). — https://github.com/Dicklesworthstone/claude_code_agent_farm
- Self-healing policy: restart on stale heartbeat (>2 min), auto-`/clear` on context exhaustion, idle threshold adaptively 3× median cycle time.
- Shutdown ladder: double-Ctrl+C within 3s force-kills the fleet after graceful attempt; `Ctrl+R` broadcasts `/clear` to all agents.
- Writes machine-readable state JSON for external dashboards + single-file HTML run report at end.
- Avoid: no per-agent triage or diff review at all — pure batch, users must attach to raw tmux to intervene.

### ccmanager (kbwo/ccmanager)
Agent-agnostic TUI across worktrees and **multiple repos** (8 CLIs supported).

- Session-data copy on worktree create: clones Claude Code conversation history into the new worktree so a fork starts warm. — https://github.com/kbwo/ccmanager
- Per-session busy/waiting/idle badges derived from terminal output; multi-project tree with per-project session sets.

### uzi (devflowinc/uzi)
CLI for racing many agents on one prompt via worktree + tmux.

- N-way racing: spawn several agents on one task, compare, `uzi checkpoint` merges the winner to main in one command. — https://github.com/devflowinc/uzi
- Per-agent dev-server port assignment from a configured `portRange`; auto mode keypresses through trust prompts.

### Gas Town (Steve Yegge)
Go orchestrator for 20-30 agents over tmux; 15.9k stars, hosted version via Kilo.

- Supervision delegated to agents: named roles (Mayor coordinates, Witness/Deacon watchdog health, Refinery runs the merge queue). — https://yegge.ai/gastown
- "Beads" git-backed issue tracker as shared external memory so work survives agent restarts — agent-writable task records.

### opencode (anomalyco/opencode, ex-sst)
~160k stars but deliberately single-conversation TUI; maintainers closed session-tabs proposal as not-planned — the fleet niche stays open. — https://github.com/anomalyco/opencode/issues/17838

- Community plugin `opencode-side-panel-sessions` has a clean glyph vocabulary: animated spinner ◐◓◑◒ working, yellow ● idle, blue ◇ awaiting input, gray ✓ done, red ✗ error; pin toggle ☆/★; sections Current / Pinned / All-by-date; titles truncated at 25 chars; event-bus driven with 10s polling fallback. — https://github.com/j-marcon/opencode-side-panel-sessions
- Avoid: TUI and web UI disagreeing about which sessions exist (subagent/archived leakage, #14053); no visibility into spawned subagents (#15223) is the loudest complaint.

### container-use (dagger/container-use)
MCP + `cu` CLI: each agent gets a fresh container + dedicated git branch on a local remote.

- `cu watch` renders fleet state as a live `git log --remotes --oneline --graph` — status as a commit graph, trivially replicable in a tmux pane. — https://dagger.io/blog/agent-container-use/
- Two-speed accept verbs: `cu merge` (take commits) vs `cu apply` (stage changes locally *uncommitted* so you can edit and re-commit). — https://github.com/dagger/container-use
- Trust framing: `cu log`/`cu diff` show "what agents actually did, not just what they claim".

### Claude Code Agent Teams (native)
Lead agent spawns teammates with shared task list + mailbox; split-pane mode renders each teammate in its own tmux pane. Adjacent, not competitor: agent-fleet should supervise/interoperate with teams. — https://code.claude.com/docs/en/agent-teams

### Charm crush
Single-agent TUI, but `crush serve` lets multiple TUI clients join one workspace sharing session list, history, and the **permission queue** — shared permission inbox across devices is the one transferable idea. — https://github.com/charmbracelet/crush

### Briefly noted
- **Forestui** — tmux triplets `edit/claude/term` per worktree; pulls open GitHub issues into the picker as task sources. — https://news.ycombinator.com/item?id=46864999
- **NTM** — broadcast one prompt to all agents of a type; file-reservation conflict detection; criticized for thin docs. — https://vibecoding.app/blog/ntm-review
- **octomux** — unified permission inbox across the fleet; **cmux** — per-agent notifications; **agent-manager** — in-terminal diff review with line comments. — https://github.com/andyrewlee/awesome-agent-orchestrators (meta-list, ~200 tools)

---

## Desktop / GUI managers

### Conductor (conductor.build)
Mac app, parallel agents in worktree workspaces; alive ($22M Series A), Conductor Cloud added July 2026.

- Unread dots on workspaces you haven't viewed since the agent last acted, explicit "mark as unread", pin hot workspaces to top of sidebar — email affordances on the rail. — https://www.conductor.build/changelog
- Checks tab with "forward failing checks": one key pipes failing CI output back into the agent as a message.
- Edit files directly inside the diff view (TUI analog: open `$EDITOR` at the hunk); historical diffs let you browse the diff as of any past turn.
- Lifecycle is one linear path review → PR → merge → archive, with single-keystroke instant archiving.
- Avoid: no sandboxing — agents effectively run with all permissions by default (HN pushback); forced GitHub OAuth resented by users who wanted plain worktree management. — https://news.ycombinator.com/item?id=44594584

### Sculptor (Imbue)
Desktop app (Mac/Linux), parallel Claude Code agents in Docker; now open source.

- Pairing Mode: one click bidirectionally syncs a chosen agent's container work into your local repo/IDE while others keep running. TUI analog: `pair` checks the agent's branch out into the main repo and back. — https://imbue.com/sculptor/
- Proactive merge-conflict flagging across agents' branches, with "hand it to the agent to resolve" as an action.
- Suggestions: background reviewer surfaces issues *before* merge — a pre-review lane in the inbox.
- Avoid: Imbue itself admits multiplexing cognitive overhead is unsolved — adding agents without adding triage affordances is the anti-pattern. — https://news.ycombinator.com/item?id=45427697

### xum (coder/xum, ex-mux)
Coder's AGPL desktop+web multi-agent app (renamed after trademark dispute), ~2k stars.

- Central git-divergence view: one screen with every workspace's ahead/behind/dirty state vs base — fleet-level git status. — https://github.com/coder/xum
- Fork workspace **with conversation history** to explore alternatives in parallel. — https://xum.coder.com/workspaces/fork.md
- Agent-callable `notify` tool: the agent itself fires a notification when blocked; click jumps to the workspace. — https://xum.coder.com/config/notifications.md
- Runtime ladder local/worktree/SSH — SSH as a rung above container; per-workspace token/cost tab; server mode = same app as authenticated web UI.

### Cursor Agents Window / Cloud Agents
Cursor 3.0+ (2026): dedicated window for many agents across local/worktree/cloud/SSH; iOS app.

- Grid layout tiles multiple agent transcripts side-by-side for comparison — natural tmux tiling win. — https://cursor.com/changelog/3-0
- `/best-of-n` fans one task to multiple models, each in its own worktree, compare outcomes.
- Mobile inbox + lock-screen Live Activities; push on finish/needs-input; steer a desktop-local agent from the phone. — https://cursor.com/docs/cloud-agent/web-and-mobile
- Avoid: **no approval queue** — parallel agents silently block on approvals; users beg for a dedicated agents-waiting list (validates agent-fleet's inbox). — https://forum.cursor.com/t/agents-approval-window/170388
- Avoid: parallel mode dumps one big final diff, losing single-agent per-turn review — granular review must survive parallelism. — https://forum.cursor.com/t/parallel-agents-support-per-turn-reviews/152912

### Vibe Kanban (BloopAI)
OSS kanban for coding agents, 28k stars; company shut down April 2026, now local-only community project.

- Kanban columns as lifecycle (To Do / In Progress / In Review / Done): status is position — an optional rail grouping mode. — https://github.com/BloopAI/vibe-kanban
- Multiple attempts per task: a task holds N attempts across agents/models; task identity survives agent failure.
- Inline diff comments are delivered to the agent as follow-up prompts — review and re-prompt in one gesture.
- Per-attempt dev-server script with browser preview.
- MCP server exposes the board so agents can file/queue tasks.
- Avoid: worktree jank is the top issue class — not cleaned after merge (#1764), "ghost runs" when worktree vanishes but UI says running (#1571), renames breaking Claude resume because sessions key on cwd (#2993 — directly relevant to reboot-restore). Redesign backlash: diff hidden behind extra clicks, mandatory worktrees with no opt-out (#2472).

### Crystal (stravu) → Nimbalyst
Electron app, deprecated Feb 2026 in favor of Nimbalyst.

- Four-state badges with "waiting for input" as a distinct color — the triage primitive. — https://nimbalyst.com/crystal/
- AI-generated session names from the initial prompt; session templates spawn N numbered sessions from one prompt; reusable prompt history.
- One-button per-worktree run script — closes the "does it actually run?" gap before review.
- Archived sessions resume with worktree + full transcript restored together.
- Avoid: deprecating a 3k-star tool for a rewrite burned goodwill; successor sprawls (233 open issues, 4 platforms).

---

## Remote / mobile / cloud

### VibeTunnel (amantus-ai/vibetunnel)
Browser proxy to real local terminal sessions, ~4.7k stars.

- Session list distinguishes actively-processing vs idle by watching output churn — same signal available from tmux panes. — https://github.com/amantus-ai/vibetunnel
- Title discipline as a feature: static/filter/dynamic title modes decide who controls the session label.
- Git follow mode: main checkout auto-follows the branch an agent's worktree is on via git hooks.
- Zero-account remoting (BYO Tailscale/ngrok) — repeatedly praised vs hosted rivals.
- Avoid: full-repaint terminal streaming floods phones; single-process daemon stalls freeze all sessions. — https://news.ycombinator.com/item?id=44934196

### Omnara
Mobile/web command center for Claude Code (YC S25); pivoted 2026 to a managed-agent platform, original app lives at remote.omnara.com.

- Relays by parsing `~/.claude/projects` JSONL rather than scraping the terminal — the phone gets a structured chat log, not a scrolled TTY. Structured message log beats pane capture for any inbox. — https://news.ycombinator.com/item?id=44878650
- Bidirectional resume: whichever surface answers first (terminal or phone) resumes the agent.
- Top-level status trio active/finished/**failed** — the "failed" bucket is missing from agent-fleet's wait/done split. — https://www.producthunt.com/products/omnara
- Avoid: centralized relay without E2E ("we could see the messages") drew loud self-hosting demand; OAuth pain. Any remote layer should be E2E or self-hosted by default.

### Happy (slopus/happy)
Open-source E2E-encrypted iOS/Android/web client for Claude Code and Codex.

- Drop-in wrapper: run `happy` instead of `claude`; nothing changes at the desk, phone takes over with one keypress. — https://happy.engineering/
- Notifications only on permission-requests and errors — not every message — with approve-from-phone. — https://happy.engineering/docs/features/
- QR-code pairing, keys never leave devices, dumb relay sees ciphertext only — the trust model users actually accept. — https://github.com/slopus/happy
- Avoid: undocumented $19.99/mo IAP in an "open source" pitch eroded trust. — https://news.ycombinator.com/item?id=44904039

### Terragon (dead)
Cloud background agents; shut down Jan 2026, open-sourced. Lessons: `terry` CLI could pull any cloud task down for local continuation ("list remotely, take over locally"); auto branch-per-task with continuously pushed AI commits made monitoring = watching the branch. A thin wrapper between Claude Code and GitHub died when Anthropic shipped the loop natively — local-first tmux tooling is the defensible spot. — https://github.com/terragon-labs/terragon-oss

### OpenAI Codex cloud tasks
Alive, bundled with ChatGPT plans.

- Task rows are compact: repo · branch · timestamp · **diffstat badge** (`+31−1`) · state. Diffstat is the highest-value glanceable signal — cheap to compute per worktree. — https://learn.chatgpt.com/docs/cloud
- Best-of-N attempts (`--attempts` up to 4), compare candidate diffs, keep one.
- Follow-ups stay in the same task — "finished" is reopenable, one task many turns one branch.
- CLI/cloud symmetry: `codex cloud exec|status|list|apply|diff`; `apply` pulls the cloud diff onto the local checkout without git ceremony.
- Archive is decluttering, not deletion; tasks originate anywhere (PRs, Linear, Slack) into one queue.
- Avoid: 1-30 min tasks mean users batch-and-forget — design for digest, not live streaming.

### Claude Code on the web (claude.ai/code)
Official cloud sessions, monitorable from the Claude mobile app.

- `/tasks` inside the CLI lists cloud/background sessions; press `t` on a row to teleport in — a fleet picker with single-key row actions living inside the agent CLI. — https://code.claude.com/docs/en/claude-code-on-the-web
- Teleport contract: explicit precondition checklist (clean git state → offer stash; same repo; branch pushed) with guided fixes — the steal for reboot-restore/resume failures.
- `claude -p "msg" --cloud <id>` queues one message into a running session from any machine and exits — scriptable fire-and-forget replies.
- Diff badge `+42 -18` per session; inline diff comments are bundled into the next message.
- Answer-later semantics: a waiting agent's question is durable — answering hours later still resumes it. During provisioning, typed input is queued and sent when ready.
- Avoid: restore = transcript, not process state (expired VMs lose running subagents/shells); parallel cloud sessions burn shared rate limits fast.

### GitHub Copilot coding agent (agents panel / mission control)
- Launch-from-anywhere panel over any github.com page; task intake from mobile, chat, VS Code, MCP. — https://github.blog/news-insights/product-news/agents-panel-launch-copilot-coding-agent-tasks-anywhere-on-github/
- Draft-PR-per-task: steering happens through normal PR review comments — triage reuses an existing muscle; session logs are a tab next to "Files changed".
- Avoid/datapoint: dotnet/runtime — only ~30% of agent PRs needed zero iteration; steering rounds are the norm, so the re-prompt loop must be cheap. — https://devblogs.microsoft.com/dotnet/ten-months-with-cca-in-dotnet-runtime/

### Google Jules
- Plan-approval gate with a 5-minute default-proceed timer — anti-babysitting, though risky as a silent default. — https://jules.google/docs/review-plan/
- Activity feed of thoughts + per-step mini-diffs for skimming, expandable full diff pane for review — feed-for-skimming/pane-for-review split maps cleanly to a TUI. — https://jules.google/docs/code/
- GitHub issues as the task queue; "suggested tasks" proactively proposes work.

---

## Pain points (what fleet UX must solve, 2025-26 threads)

1. Review is the throughput ceiling, not agent count — "the natural bottleneck is how fast I can review." — https://news.ycombinator.com/item?id=45489884
2. Human attention caps fleets at ~3 sessions even for motivated users. — https://news.ycombinator.com/item?id=46682551
3. Every session is a stranger — no persistent trust/track record per agent. — https://news.ycombinator.com/item?id=45489884
4. Merge hell between agents; users want conflict *prediction* (overlapping files), not just isolation. — https://news.ycombinator.com/item?id=45489884
5. Waiting kills focus — idle time between wait-states is the hidden cost.
6. The failure mode is a *missed* wait, not a noisy one — stalled sessions blocked on unnoticed questions. — https://touchtap.gumroad.com/l/claude-code-notifier
7. At 5-10 agents users lose track of who's doing what — rails need task titles + state, not session names. — https://towardsdatascience.com/how-to-run-claude-code-agents-in-parallel/
8. Cognitive distance lowers the review bar — diff-first UX, not transcript-first. — https://news.ycombinator.com/item?id=45489884
9. Sustained supervision burns people out — parallelism is not a goal in itself.
10. Industry data: agentic PRs see 5.3x longer review pickup; median review time up 441% — the queue grows faster than it drains. — https://www.flowverify.co/blog/ai-code-review-bottleneck-2026-data

---

## Synthesis — top 10 transferable ideas, ranked by fit for a tmux TUI

1. **Reply-without-attach**: type a prompt to any agent straight from the rail/inbox, with readiness polling so text is never dropped — workmux "agent input mode"; Claude Squad's top user ask (#312).
2. **Atomic finish verbs**: `merge` (merge + kill window + remove worktree + delete branch) and `apply` (stage uncommitted locally for hand-editing) as a two-speed accept pair — workmux + container-use.
3. **Diffstat + context-% as rail columns**: `+31−1` badge per session and context-remaining warnings — Codex cloud task rows + agent_farm health table.
4. **Unread/pin/auto-clear rail semantics**: unread dot until viewed after last agent action, mark-unread, pin-to-top, and wait/done markers that auto-clear on focus — Conductor + workmux.
5. **Inline diff comment → follow-up prompt**: commenting on a hunk in the diff view sends it to the agent as steering; review and re-prompt collapse into one gesture — Vibe Kanban + Claude Code web.
6. **Best-of-N race with warm forks**: spawn N worktree agents on one task record (optionally cloning session history), compare diffs, `checkpoint` the winner — uzi + Cursor /best-of-n + ccmanager session-copy + xum fork.
7. **Failed as a first-class inbox bucket** plus agent-callable notify hook (agent fires "I'm blocked") — Omnara status trio + xum notify tool.
8. **Cross-agent conflict prediction**: warn in the rail when two live worktrees touch overlapping files, with "send conflict to agent to resolve" as an action — Sculptor; pain point #4.
9. **Resume precondition contract**: reboot-restore/teleport failures show an explicit checklist (dirty tree → offer stash, missing worktree, cwd moved) with guided fixes; never a "ghost running" state — Claude Code web teleport + Vibe Kanban's bug class.
10. **Per-worktree run-script pane**: one key spawns the configured dev/build command in a pane bound to that worktree (auto port assignment) — Crystal run button + Vibe Kanban dev server + uzi portRange.

Honorable mentions: forward-failing-CI-output to agent (Conductor); `cu watch`-style commit-graph fleet view in a pane (container-use); structured-JSONL message relay instead of pane scraping for any remote/inbox surface (Omnara); E2E QR-paired phone relay if remote monitoring ever ships (Happy); queued input during slow session spawn (Claude Code web); GitHub issues as picker task sources (Forestui/Jules).

Anti-patterns to avoid (recurring across tools): silent blocking on approvals with no queue (Cursor); one big final diff that loses per-turn review granularity (Cursor); worktree teardown left to the user (Vibe Kanban); cwd-keyed session resume breaking on rename (Vibe Kanban #2993); unsandboxed-by-default agents (Conductor); hosted relay without E2E (Omnara); streaming full repaints to small screens (VibeTunnel); UI state disagreeing with reality about which sessions exist (opencode #14053).
