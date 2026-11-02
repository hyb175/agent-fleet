# Agent runtime contract

What agent-fleet guarantees to a machine caller (AIOS today) about running,
inspecting, messaging and stopping agents — and what it does not. Written
against [the ownership handoff](aios-runtime-handoff.md); this file is the
contract and compatibility inventory that handoff asked for first, plus the
input-delivery proof. Stages are listed at the end with their status.

Ownership in one line: fleet runs agents and reports facts; AIOS decides what
the facts mean for a goal.

---

## Identities

Three identities are kept apart. A caller that confuses them sends a message
to the wrong recipient.

| Identity | Interactive pane (manual or AIOS-linked) | Controlled worker (owned backend) |
| --- | --- | --- |
| **Logical provider session** | claude: `session_id` from the hook event; codex: rollout thread uuid. Stored in `panes/<pane>.session`, pane option `@fleet-session`, task record `session`. Survives restore (`claude --resume`, `codex resume`). | `session_id` the caller assigned (`--session-id` on the first generation, `--resume` after). |
| **Live incarnation** | `(socket, pane_id)` plus the session id the pane currently holds; `pane_pid` is journaled as evidence. Pane ids are reused after a server restart and the per-boot purge clears every per-pane file. | `(unit, boot_id, invocation_id)`; a terminal receipt is bound to all three. |
| **Caller assignment** | task id `t<epoch>-<pane#>` (manual); delivery op id (`send --op`). | `owner_namespace / attempt_id / dispatch_id / generation`, `operation_id`. |

A delivery journal records the pane and its session id before the first
keystroke. If the pane holds a different session id when the outcome is read,
the status is `unconfirmed reason=recipient_changed`, never `consumed`, even
when a matching receipt exists.

## Where state lives

| Location | Lifetime | Holds |
| --- | --- | --- |
| `$XDG_CACHE_HOME/agent-fleet/<socket>/` (`AF_CACHE_DIR`) | disposable; `panes/*` purged on every cold boot | `fleet.snapshot`, `panes/<pane>.{status,session,task,question,turns}`, `tasks/<tid>` records, `fleet.state` layout, overlays |
| `$XDG_STATE_HOME/agent-fleet/<socket>/` (`AF_STATE_DIR`) | durable | `deliveries/<op>` send journals; the bundled owned backend's `owned/<ns>/<attempt>/` ledgers when launched with `--backend fleet` |
| `$XDG_STATE_HOME/agent-fleet/worktrees/` | durable | task worktrees |
| `<cache>/owned/<ns>/<attempt>/` | disposable | the **external** (AIOS-hosted) v1 driver's ledgers — unchanged, AIOS owns that layout |

Loss of a journal is never read as "nothing was sent": `send --status` on an
unknown op answers `refused reason=unknown_op`, and the caller keeps its own
intent.

## Capabilities (provider × mode × host)

`agent-fleet capabilities` prints the live view as `key=value` lines. The
static matrix, with what each cell's evidence is:

| Provider / mode | Discover + state | Answer (`answer`) | Message with receipt (`send`) | Resume after restart | Controlled run (`owned`) |
| --- | --- | --- | --- | --- | --- |
| claude, interactive, hooked (shim, `add`, `task`) | yes, hook tier | yes, fingerprint-guarded, blind | **yes** — proved on Linux, claude 2.1.316 (below); macOS uses the same hook path, not re-run | yes (`--resume`) | no |
| claude, controlled | n/a (no pane) | per-generation `answer` action | per-generation turn via `-p --resume` | n/a (generations) | **Linux only**: bundled backend, or external driver |
| codex, interactive, hooked | yes | blind | **yes** — proved on Linux, codex-cli 0.165.0 (C1 below); `turn_id` plays the role of `prompt_id` | yes (rollout lookup) | no |
| opencode / kimi / hermes, hooked | yes | blind | no | yes / yes / yes | no |
| any, scrape tier (`~` label) | heuristic | blind | no | kind only | no |
| federated (`host/…`) | read-only mirror | refused | refused | n/a | n/a |

"Blind" means keystrokes land and nothing confirms consumption; that is the
pre-existing manual behaviour and it stays manual. A help screen listing a flag
is not evidence; every "yes" above is backed by a test or a recorded run.

Normal fleet needs bash, tmux and git. Python, systemd and bubblewrap are
required only by `owned --backend fleet`, which exits 2 with the reason on any
other host instead of degrading.

---

## Owned protocol v1 (inventory, unchanged)

Transport: `agent-fleet owned --driver <abs exe> <action>` execs the driver as
`<exe> --fleet-socket <socket> --fleet-cache <cache> <action>` with the JSON
request on stdin; stdout, stderr and the exit status pass through. No tmux or
cache side effects happen before the exec ([t-owned](../tests/t-owned.sh)).
`--backend fleet` runs the bundled copy the same way plus
`--fleet-state <AF_STATE_DIR>`.

Actions: `launch | inspect | answer | stop`. Every payload carries
`protocol_version: 1`, `owner_namespace`, `attempt_id`, `dispatch_id`,
`generation`, `operation_id` (each `[A-Za-z0-9_-]{1,128}`), and after
preparation `claim_epoch` (32 hex) and `preparation_hash`.

| Action | Extra payload | Effect |
| --- | --- | --- |
| `inspect` + `prepare_start:{action, payload}` | the future launch/answer payload without epoch/hash | writes the claim (first time), ledgers the generation as `prepared`, returns `status: prepared` and a `preparation_witness`. Not a start. |
| `launch` | `descriptor` (ProcessDescriptor), `session_id` | first generation: prepares the state dir, marks `armed`, `systemd-run`s the unit. Replays return the recorded response; a changed payload under the same id is `operation payload conflict`. |
| `answer` | `descriptor`, `session_id`, `previous_generation`, `answer`, `question_id`, `observation_revision` | a new generation resuming the same session; requires the predecessor quiescent with that exact question unconsumed. |
| `stop` | optional `invocation_id`, or `abandoned_start:{action,payload}` | writes `fence.json` before any effect; with the invocation id stops the unit; with an abandoned start proves `never_started`. |
| `inspect` | — | fresh observation (never cached): `running | quiescent | uncertain | never_started`, `receipt`, `result`, `question_id`, `current_generation`, `fenced`, `observation_revision`, `output_paths`. |

Response rule: the five identity keys echo the request; `status: error` with
`error` text and exit 1 on refusal. `uncertain` is a durable outcome, not a
retry hint. Missing permissions, raced identity or an unreadable unit mean
`uncertain`, never `quiescent`.

Ledger (per attempt): `lock`, `claim.json` (identity, `claim_epoch`,
`generations{}` with `phase prepared|armed`), `state.json`
(`current_generation`, `consumed_questions`), `operations/<op>.json`
(`payload_hash`, `payload`, `stage`, `response`), `fence.json`, optional
`retired.json`, `generations/<g>/generation.json` and `host/` (descriptor,
sealed runner, `start.json`, `terminal.json`, `stdout`, `stderr`), workspace
dirs `task/ home/ tmp/ objects/`.

Versioning policy:

- `protocol_version` is an integer; a driver rejects versions it does not
  implement. v1 is frozen: no new required payload keys, no changed meaning.
- Response fields may be **added**; callers ignore unknown keys. Removing or
  retyping a field needs a new version.
- New actions ship only under a new version, negotiated by the caller sending
  that version. The four v1 names are the whole v1 surface.
- The bundled backend is protocol v1 with a different root (`--fleet-state`).
  Unit names (`aios-owned-<hash>.service`) and descriptions
  (`AIOS owned <digest>`) are kept so AIOS's process census keeps matching.
  Profile/runner hashes change with the file location: AIOS must re-run its
  capability probe against the new binary, as the handoff anticipates.

---

## Message delivery (`send`) — the proved input boundary

### What was proved

Host: NixOS, Linux 6.12, tmux 3.6, Claude Code 2.1.316, 2026-11-01. Disposable
cwd, disposable tmux socket, fresh session ids. Scripts and raw event logs:
`scratchpad/proof1.sh`, `proof2.sh` (not committed; the results are what
matters and are reproduced by the checks named).

| # | Setup | Result | Consequence |
| --- | --- | --- | --- |
| H1 | `claude -p --session-id S … "Reply OK"` then `claude -p --resume S …` | both `result` events carry `session_id: S`, `uuid`, `num_turns`, `is_error`, `permission_denials`; `UserPromptSubmit`, `Stop`, `SessionStart` hooks fire in headless mode too | headless turns are a provider-native, serialized input API with a correlated receipt. The owned backend already relies on it. |
| A1 | interactive pane, `send-keys -l text; Enter` | `UserPromptSubmit{prompt == text, prompt_id P, session_id S}` then `Stop{prompt_id P}` | consumption is observable natively; `prompt_id` ties a turn end to its prompt. |
| A2 | human has typed `half typed ` (no Enter); fleet sends `Reply with exactly: BETA` | consumed prompt is `half typed Reply with exactly: BETA` | the race the handoff warns about is real; checking the pane *before* typing cannot see it. Only the receipt can: the hash differs → `mismatch`. |
| A3 | two-line text via tmux bracketed paste + Enter | one prompt, `"prompt":"line one\nline two: …"` | multi-line is safe through `paste-buffer -p`; `send-keys` alone would submit at the first newline. |
| A4 | send while the agent is mid-turn | Claude Code queued it; **both** prompts reported the same `prompt_id`; two `Stop`s | the provider queues, but the receipt is then ambiguous. Fleet refuses `busy` instead and the caller keeps its queue. |
| B | `claude -p --resume S` **while the interactive process holding S is alive** | exit 0, same `session_id`; the pane's next answer listed every prompt **except** the headless one; transcript has two leaves | in-place connection to an unmediated interactive session through the native API is **not** safe: it forks the conversation and the live agent never sees the message. |
| I1 | Escape during a running claude turn | no `Stop`, no `Notification`; the pane returns to the prompt with the interrupted text back in the composer; the next prompt works normally (I2); Escape while idle does nothing (I3) | an interrupt has **no native receipt**; fleet reports `status=sent` only. The composer may hold the old text afterwards, so a following `send` can legitimately come back `mismatch`. |
| C1 | codex-cli 0.165.0 in a pane, hooks trusted, bracketed paste + Enter (2026-11-02) | `SessionStart{session_id, transcript_path, cwd, source}` at launch; `UserPromptSubmit{session_id, turn_id, transcript_path, cwd, hook_event_name, model, permission_mode, prompt}` then `Stop{turn_id, last_assistant_message}`; a raw `send-keys` burst followed at once by Enter left the text in the composer unsent | codex has the same receipt shape with `turn_id`; the paste-then-Enter transport is required for it and is now used for both providers. `codex-hooks install` now wires `SessionStart` so the session id (and thus `send`'s receipt channel) exists before the first prompt; codex asks to trust the new hook once. The hook finds `prompt` by key, pinned in [t-runtime](../tests/t-runtime.sh) against this payload and a reordered one. |

Conclusions the protocol is built on:

1. For a hooked interactive claude pane the safe path is keystrokes **plus** a
   native consumption receipt. Typing is the effect; the `UserPromptSubmit`
   event with a matching prompt hash is the proof; `Stop` with the same
   `prompt_id` is the turn end.
2. Submitted ≠ consumed. A paste and Enter that produced no receipt is
   `unconfirmed`, and an unconfirmed op is never typed again automatically.
3. A busy agent is reported `busy`; fleet owns no outgoing queue for panes.
4. An existing interactive session cannot be driven headlessly in place. The
   reviewed reconnect is: end the interactive process (`/exit` or Ctrl-D, which
   fires `_release`), then either resume it in a pane (`claude --resume S`,
   what restore does) or drive it headlessly (`-p --resume S`, one process at
   a time). Never both.

### Protocol

```
agent-fleet send <task-id|%pane> "<text>" [--op <id>] [--fp <sum>] [--wait <secs>] [--idle <secs>]
agent-fleet send --status <op>
→ op=<id> status=<s> pane=%N [prompt_id=<P>] [reason=<r>]
```

| status | exit | meaning |
| --- | --- | --- |
| `consumed` | 0 | a `UserPromptSubmit` receipt with this text's hash and `prompt_id` P was appended after the journal was written, and the pane still holds the journaled session |
| `turn_ended` | 0 | …and `Stop{prompt_id P}` arrived |
| `unconfirmed` | 4 | no matching receipt within `--wait`; re-read later with `--status`. Reasons: `recipient_changed` (the pane holds another session), `send_failed` (tmux refused mid-send; text may sit in the input box), `unknown` (the journal never reached `submitted`: the sender died mid-keystroke) |
| `mismatch` | 5 | prompts were consumed after the journal but none is this text: it merged with typing or another prompt went first. Not final: `--status` re-evaluates and a later matching receipt confirms it. Never resent. |
| `busy` | 3 | status file (fresher than the snapshot) says `working`: nothing typed, no journal; the caller queues and retries |
| `refused` | 1 | nothing typed. Reasons: `waiting_on_input` (use `answer`), `human_active` (a client keystroke reached the pane's tmux session less than `--idle` seconds ago, default 2; retry), `no_receipt_channel`, `stale`, `remote`, `no_pane`, `unknown_op` |
| conflict | 2 | `--op` reused with different text (`payload_conflict`) or for a different pane (`target_conflict`, `pane=` names the original); nothing typed |

The journal is claimed atomically (`ln` of a temp file): of two concurrent
sends with the same `--op`, exactly one pastes and the other waits on the
winner's record (read-only, so the record and the events stream get one
`consumed` line) and reports its receipt. A replay of any record younger
than `--wait` that is not yet final waits the same way the original call
did; `--status` never waits. The `human_active` gate reads
`#{session_activity}`, which tmux stamps on client input, `attach` and
`switch-client` (never on `send-keys`/`paste-buffer`, verified on tmux 3.6)
and which equals `#{session_created}` until a client has touched the session;
fleet's own `go`/`focus` navigation therefore counts as a human for `--idle`
seconds. Text left in the composer earlier than `--idle` is still caught
only after the fact, by the hash (`mismatch`).

Journal `AF_STATE_DIR/deliveries/<op>` (key-value lines, written **before**
any keystroke): `op pane session pid kind sha chars created turns_at`, then
appended `submitted <epoch>` | `failed <epoch>`, `consumed <epoch> <prompt_id>`,
`ended <epoch>`. `turns_at` is the byte length of the pane's receipt log at
intent time: only receipts appended after it can be this delivery's, so no
clock comparison is involved and a journal that lost its `submitted` line is
still reconciled. Receipts: `AF_CACHE_DIR/panes/<pane>.turns` with
`s <epoch> <prompt_id> <sha256>` and `e <epoch> <prompt_id>`, written by
`agent-status-hook.sh`. The hash covers the prompt as JSON-escaped inside the
event (`\\ \" \n \t`); `send` escapes identically. Pinned in
[t-send](../tests/t-send.sh) against the bytes of a real event. Every
mis-parse on either side yields a false negative (`unconfirmed`/`mismatch`),
never a false `consumed`.

Guards, in order: hooked claude or codex pane (`@fleet-agent-kind` and a
`.session` file) → status file, then snapshot, not `working`/`wait` →
optional fingerprint → journal → bracketed paste → Enter as its own key →
poll receipts. Text may contain newline and tab; other control
characters are rejected before anything happens (an ESC sequence could drive
the TUI).

Queue ownership: AIOS keeps its outgoing goal-message queue and dequeues an
item only on `consumed`/`turn_ended`. Fleet serializes nothing across calls;
two concurrent `send`s to one pane are the caller's error and at most one can
match its receipt. `busy` and `unconfirmed` are both "do not dequeue".

Turn attribution: a `Stop` whose `prompt_id` is not the delivered one belongs
to older work. AIOS keeps a goal in *waiting for agent* until its own op's
`consumed`, exactly as the handoff requires.

Permission prompts and ordinary questions stay on `answer` (`approve|deny|text`,
`--fp`): a pane in `wait` refuses `send` so a chat message can never approve a
tool. `review --send` and `answer text` keep their manual, blind behaviour.

---

## Events and native source references

`agent-fleet events [--since <token:offset>] [--pane %N]` is the resumable
event stream: `<epoch> <pane> <kind> [fields…]` lines, last line
`cursor=<token>:<offset>`. Kinds: `session <id> <agent>`, `state <s>`,
`prompt <turn-id> <sha>`, `turn_end <turn-id>`, `question`,
`delivery <op> submitted|failed|consumed|turn_ended [turn-id]`, `interrupt`,
`released`, `killed <pids|none>`. Writers append one line each (hook tier,
`send`, `interrupt`, `kill --wait`, `_release`, `ask-human`); nothing polls.
The log lives in the cache and is rotated on every cold boot, which is exactly
when pane ids restart; a cursor from before the rotation answers
`status=expired` (exit 6) with a fresh cursor, and the caller re-discovers from
the snapshot. Durable facts stay in task records and delivery journals; the
stream is for ordering and wake-ups. Hook-tier panes only: scrape-tier panes
produce no events and keep their `~` label.

Turn attribution with the stream: a `turn_end` whose id is not the id a
`delivery … consumed` line carried belongs to older work.

Underlying files, all plain reads, no tmux in the hot path:

- `fleet.snapshot` — the UI inventory; append-only format
  ([snapshot-format](snapshot-format.md)); staleness rule unchanged.
- `panes/<pane>.status` and task record `state <s> <epoch>` lines — lifecycle
  transitions, hook tier only; scrape tier is heuristic and labelled `~`.
- `panes/<pane>.turns` — per-turn `s`/`e` receipts (claude, codex).
- `panes/<pane>.question` — an `ask-human` question; the row's text.
- `events.log` — the stream above.

Native references for a claude pane: session id as above; transcript
`~/.claude/projects/<cwd with "/" → "-">/<session_id>.jsonl`; subagent
transcripts `…/subagents/agent-*.jsonl` (same `sessionId`); hook events also
carry `transcript_path` verbatim. For codex: `~/.codex/sessions/Y/M/D/rollout-<ts>-<uuid>.jsonl`,
first line holds `cwd` and `source.subagent` for child threads. Terminal
scrollback is display context only. Discovery never scans transcripts.

## Interrupt, stop, fencing, restore

Four different things, four different verbs, none implied by another:

| Intent | Verb | Evidence returned |
| --- | --- | --- |
| interrupt the current response | `interrupt <id\|%pane>` (hooked claude in `working`; Escape) | none exists natively (I1): `status=sent reason=no_native_receipt`, exit 4. The `working` gate reads the status file, which can lag a permission prompt by one hook round-trip; an Escape landing in that window cancels the prompt rather than the response. Codex refused (`no_interrupt_capability`) until proved. |
| stop a controlled run | `owned … stop` | fence written before the effect; unit stopped by invocation id; terminal receipt or `uncertain` |
| end an interactive session | `kill <target> --wait [s]` | the pane's process tree (pid + start time, from one `ps`) and any task container are censused **before** the kill and polled after: `status=stopped processes=N` only when every one is gone and no container runs; otherwise `status=unknown alive=<pids>` (exit 4). Without `--wait` the verb is the plain tmux kill it always was. |
| retire an attempt | AIOS, via `retired.json` | the backend's retirement census |

- Owned v1: `stop` writes the fence before any effect; a fenced attempt refuses
  every later start even after cache loss of other files; `never_started` is
  proved, not assumed. Restore never relaunches an owned worker.
- `kill --wait` identifies processes by pid **and** start time, so a pid reused
  after exit never counts as a survivor; a process it cannot see (a container's
  inner tree) is covered only through the task record's container name.
- Delivery journals survive restore; pane ids do not. After a restore every
  `unconfirmed` op stays unconfirmed (`recipient_changed` once the pane holds
  another session). Nothing is replayed.

---

## Stages and status

| Stage | Status | Where |
| --- | --- | --- |
| 1 Contract and compatibility inventory | done | this file; `agent-fleet capabilities` |
| 2 Input-delivery proof | done | tables above; `send` verb; `t-send` |
| 3 Fleet-owned controlled runtime | packaged | `backends/owned/` (protocol v1, `--fleet-state`, no AIOS imports, 110 donor-derived tests, CI job); `owned --backend fleet`. Declared gaps: CI runs no real bubblewrap sandbox (those tests skip off the Nix store) and the retired-attempt census with a populated cgroup has no fixture; the donor's own `_members` call was broken there, so AIOS never exercised it either. |
| 4 Session messaging and events | done | `events` stream with cursor and explicit expiry; `kill --wait` process-census evidence; codex receipts proved and enabled in `send`; `interrupt` verb that claims only what it can see. Open: an interrupt receipt (none exists upstream), codex interrupt evidence, container-inner trees beyond the named container. |
| 5 Compatibility and consumer handoff | partial | see below |

### What AIOS changes to adopt this (stage 5 inputs)

1. **Transport:** keep `agent-fleet owned` as the binary; switch
   `--driver <path>` to `--backend fleet` when fleet's `capabilities` reports
   `owned_backend_fleet=available`. Payloads are unchanged.
2. **Root:** the ledger root becomes `$XDG_STATE_HOME/agent-fleet/<socket>/owned/`
   (`state_dir` in `capabilities`). `fleet_execution._prepared_claim`,
   `_binding` and `_existing_preparation_epoch` read `self.cache/'owned'/…`
   directly; point them at the state root. Descriptor `state_directory` and
   workspace paths are under that root too.
3. **Proof hashes:** the sealed runner is `backends/owned/process.py`; the
   `boundary_sha256` in the coding profile and `ExecutionReadiness` file set
   must be re-pinned by a fresh probe. Do not carry old certificates forward.
4. **Migration:** quiescent attempts only. Old ledgers under the cache stay
   readable by the external driver (rollback = switch the flag back). Do not
   move ledgers between roots; retire old attempts in place.
5. **Messaging:** for linked interactive sessions call `send --op <id>` with a
   durable id and dequeue on exit 0; treat 3 as retry-later, 4 as hold and
   poll `--status`, 5 as human review. Question/permission handling stays on
   `answer` with `--fp`.
