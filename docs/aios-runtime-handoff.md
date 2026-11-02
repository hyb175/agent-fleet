# AIOS and agent-fleet runtime ownership handoff

Status: agreed architectural direction; implementation pending. Written 2026-11-01
for an agent working in the agent-fleet repository.

## Objective

Make agent-fleet responsible for running and managing agents, including the
controlled workers AIOS currently supervises through its own driver. AIOS should
delegate agent operations to fleet and consume their results while retaining goal
planning, approvals, coordination, memory, validation and outcome acceptance.

This also supports an AIOS Agents view that discovers existing fleet sessions,
links goals to them and allows ongoing conversation. A goal is an initial
direction, not a one-shot interaction: small goals can run unattended to review,
and the owner must be able to steer any active goal regardless of size.

Reuse the existing worker/runtime machinery where practical. Moving the generic
lifecycle behind fleet does not require rewriting it or replacing standard Claude
Code/Codex sessions with bespoke AI agents.

## Read first and source locations

Fleet baseline inspected: Git commit
`890b468268c93fa32b4199f00f29eb2fc29c8a15`. Recheck the current tree before editing;
other work may have landed since this inspection. Follow [CONTRIBUTING](../CONTRIBUTING.md),
particularly the Bash/macOS rules, fork-free hot paths, view-only Go UI and
append-only snapshot/state format evolution.

Fleet starting points:

- [Current owned-worker extension](owned-protocol.md).
- [Snapshot contract](snapshot-format.md).
- [CLI](../bin/agent-fleet): `cmd_owned`, `cmd_task`, `task_adopt`, `cmd_answer`,
  review/send and pane closure.
- [Native status hook](../scripts/agent-status-hook.sh),
  [snapshot daemon](../scripts/snapshotd.sh), and
  [save](../scripts/persist-save.sh)/[restore](../scripts/persist-restore.sh).
- [Owned transport test](../tests/t-owned.sh),
  [answer tests](../tests/t-answer.sh),
  [adoption tests](../tests/t-adopt.sh) and
  [persistence tests](../tests/t-persist.sh).

The current AIOS implementation/design checkout for this handoff is
`/tmp/my-aios-full-goal-journey`. The AIOS source revision is
`daaffe1132bc1b6757b36929453099dbae6f380e`, bookmark
`agent-collaboration-design`. The usual directory
`/home/hyb175/Projects/my-aios` is another checkout; do not assume it contains this
latest design. Use the recorded revision as the durable reference if the temporary
workspace moves or disappears.

Within that AIOS checkout:

| Source | What to inspect/reuse |
| --- | --- |
| `aios/adapters/owned_process.py` | Contained process descriptors, filesystem boundary, supervised units, bounded runtime and process receipts. |
| `aios/adapters/owned_driver.py` | Durable claims, operation replay, generation preparation, launch/answer/stop, unknown outcomes and fencing. It has late dependencies on AIOS census/retirement helpers; extract their generic contracts rather than importing AIOS wholesale into fleet. |
| `aios/adapters/coding_claude.py` | Standard Claude Code worker profile, identity/output checks and capability canaries. Separate provider runtime requirements from AIOS-specific task-result policy. |
| `aios/adapters/fleet_execution.py` | Current consumer payloads, the `agent-fleet owned` transport, binding and preparation checks. It also contains workflow/admission policy that should remain in AIOS. |
| `aios/adapters/execution_observation.py`, `retirement.py` | Process identity, census, ownership attribution and retirement evidence. |
| `aios/service/execution_config.py` | Installation/namespace registry and capability binding outside restorable service state. |
| `tests/test_owned_process.py`, `test_owned_driver.py`, `test_fleet_execution.py` | Existing regression donors, including ambiguous launches, current-question resume, stop and isolation. |
| `tests/test_coding_claude.py`, `test_execution_observation.py`, `test_execution_recovery.py` | Provider proof, manual/owned coexistence and recovery cases. |
| `docs/sdlc/agent-collaboration/` | Product design, earlier architecture proposal, interactive prototype and design handoff. |

An accessible product walkthrough is at
[AIOS agents and goal conversations](https://chatgpt.com/space/page_fe83a1656a808191a05da6781e1a15fe).
It uses sample data. Its earlier architecture text describes the then-current
AIOS-owned runtime. **This handoff adds the subsequent ownership decision:** move
generic runtime/session management behind fleet while preserving those behavioral
requirements. The UI concept is not evidence of a working message transport.

## Current architecture and why it exists

The current managed execution path is:

```text
AIOS approved plan and scheduler
  -> AIOS FleetExecution adapter
  -> agent-fleet owned --driver <AIOS driver> launch|inspect|answer|stop
  -> AIOS OwnedDriver
  -> supervised contained process generation
  -> standard Claude Code CLI
```

The drivers are ordinary process-management code. The coding agent is regular
Claude Code in a controlled headless configuration, with a native session ID and
resume support. It is not currently an ordinary interactive tmux pane managed by
fleet's normal task lifecycle.

The existing `owned` command is a small optional transport. It passes scoped JSON
to a specified executable before ordinary theme/tmux/restore initialization. AIOS
supplies the backend. The backend handles guarantees needed for managed execution;
fleet's ordinary manual behavior remains separate.

Fleet already has provider launching, native sessions, hooks, snapshots, adoption,
worktrees, isolation rungs, fingerprint-guarded answers and save/restore. This work
is not a claim those features are absent. The missing integration is a durable,
machine-facing lifecycle and messaging contract with stronger effect guarantees.
Those guarantees were implemented on the AIOS side; their location can change.

## Intended ownership

| Responsibility | Owner |
| --- | --- |
| Provider launch/resume, native identity and live incarnation | agent-fleet |
| Interactive and controlled worker modes, containment and exact process lifecycle | agent-fleet |
| Safe message/answer/interrupt delivery and operation receipts | agent-fleet |
| Runtime events, transcript/child-session references and capture coverage metadata | agent-fleet |
| Enforcing each accepted run's concrete limits and reporting actual usage | agent-fleet |
| Goals, plans, decisions, approvals and repository/task coordination | AIOS |
| Aggregate goal budgets, scheduling/admission and approval validity | AIOS |
| Goal/session association and interpretation of progress against an outcome | AIOS |
| Original-source archive, memory curation, checkpoints, retrieval and deletion policy | AIOS |
| Validation/check policy, result review and acceptance/integration | AIOS |

Fleet should not need AIOS's workflow database to run or inspect an agent. AIOS
should not reimplement fleet's process/session control. Fleet reports a turn or run
ending; it does not decide that an AIOS goal passed its criteria or can be merged.
AIOS supplies approved constraints and remaining allowances; fleet enforces the
accepted per-run contract and returns evidence rather than inventing a goal budget.

Keep both interactive sessions and controlled automation useful. tmux can remain
the terminal interface while a supervised backend owns a controlled worker's
process tree. Do not discard supervision simply to make a worker appear in a pane.

## Required contracts

### 1. Versioned capabilities and discovery

Expose bounded, structured discovery and capability inspection. Reuse
`fleet.snapshot` for inexpensive UI inventory, preserving appended-field and stale
snapshot behavior. Add richer inspection separately where necessary. Identify
provider, logical session, task, current incarnation, actual isolation and supported
controls. Mark heuristic activity honestly.

Capabilities must be specific to provider, mode, backend and host. An interactive
Codex pane existing is not proof of an AIOS-compatible automated Codex worker. An
idle snapshot is not proof that a prompt input is safe. Unsupported capabilities
must have a clear reason and must not be inferred from a successful help command.

Normal fleet use must remain usable without an unconditional Python/systemd
dependency. An optional Linux controlled backend can use those dependencies and
advertise that requirement. Preserve ordinary behavior on macOS and other supported
hosts; do not pretend a Linux-only proof covers them. Keep Go UI mutations routed
through fleet verbs, as CONTRIBUTING requires.

### 2. Stable identity and durable operations

Separate logical provider session identity from live process/pane identity and
caller assignment identity. Preserve native session continuity across a verified
resume; reject a recycled pane, replaced process or changed provider as the old
recipient. Include boot/process-start identity and a generation/incarnation where
needed.

Accept caller operation IDs with an immutable payload hash and durable outcomes.
Replaying the same operation must not create another worker or send another prompt.
Reusing an operation ID with changed content must fail. An operation ID or namespace
string is not itself authorization over an existing session; bind operations to
verified scoped ownership or an explicit owner-directed session grant.

The current AIOS protocol version 1 already carries `owner_namespace`, `attempt_id`,
`dispatch_id`, `generation`, `operation_id`, and, after preparation, `claim_epoch`
and `preparation_hash`. Preparation currently uses an `inspect` payload containing
`prepare_start`. Inventory that exact behavior before designing a replacement.
Publish an explicit compatibility/versioning policy rather than assuming the
existing four command names describe the entire protocol.

Managed lifecycle/operation journals belong in durable state, not only disposable
cache. Loss of claims or records must not be interpreted as proof that a worker
never ran. Keep the durable ownership/fence registry independent of an older AIOS
database restore. Snapshots and other disposable views can remain cached.

### 3. Real stop, fencing and restore coordination

An acknowledged stop must identify and stop the relevant controlled process tree,
including children, and return fresh evidence of quiescence. A killed pane alone
is insufficient evidence. Missing permissions, raced identity or inaccessible
process state mean unknown, not stopped.

Persist cancellation/retirement fencing so ordinary save/restore, backend restart,
or recovery from an older coordinator database cannot revive cancelled work.
Distinguish response interruption, stopping a controlled run, retiring an attempt
and ending an interactive session. A goal link never implicitly grants all of them.

Retain evidence and workspaces until cleanup is positively allowed. Manual fleet
tasks remain protected from automated cleanup and ownership adoption.

### 4. Required execution profiles and limits

Keep ordinary fleet's existing isolation ladder behavior compatible. Add a strict
automation mode where a requested profile is a requirement: unavailable isolation
or capability rejects the launch rather than degrading to a weaker rung.

Bind the actual profile and runtime implementation identity to the accepted run.
Enforce its runtime ceiling, contain descendants and return trustworthy timing and
termination evidence. Resume/continuation must settle the previous generation and
accept a new explicit allowance; it must not reset the coordinator's aggregate
accounting. Preserve working artifacts across continuation.

Profile/capability hashes may depend on executable paths and code identity. Moving
the existing backend can invalidate those proofs even when behavior is intended to
be equivalent; reverify rather than carrying old certificates forward blindly.

### 5. Ongoing messaging and intervention

Support explicit messages, exact ordinary-question answers and capability-gated
response interruption for a verified session. Keep tool-permission approval a
different operation from chat. Treat startup selectors, permissions, unknown input
state and busy turns distinctly.

AIOS owns its outgoing goal-message queue; fleet owns serialized delivery into the
native session, per-session ordering, operation deduplication and receipts. Fleet
may report busy so AIOS can queue, or accept a durable delivery operation, but the
protocol must make queue ownership explicit. Two layers must not both retry or
dequeue the same effect independently.

Prefer a provider-native input/turn API where its existing-session behavior is
proved. Otherwise, reliable automatic input needs a broker mediating both human
terminal input and coordinator messages. Inspecting a pane immediately before
`send-keys` does not eliminate the race with human typing or a partially edited
prompt. Existing unmediated sessions may require an explicitly reviewed safe
reconnect under that broker, preserving the native conversation. Do not silently
restart a busy session or start a second resumed process on its transcript.

Distinguish saved/queued, submitted, consumed by the native agent and unconfirmed
delivery. A successful paste/Enter operation is not consumption evidence. Use a
correlated native turn/receipt; text similarity and timestamps alone are insufficient.
Persist intent before effects. After a crash or lost response, reconcile the
original operation. Unknown delivery must not trigger an automatic duplicate send.

The existing `answer --fp` and task-linked `review --send` are useful starting
points, not a complete general-message/consumption protocol. Preserve their current
manual uses while adding the structured contract.

### 6. Events and native source references

Expose resumable, bounded runtime events or a journal cursor: session/incarnation
changes, turn start/end, ordinary questions, permission requests, delivery receipts,
interrupt/stop outcomes and usage/termination facts. Scope events to stable
identities, and make lost/expired cursor recovery explicit.

Publish provider-native session/transcript references, parent/child lineage and
coverage/completeness hints. AIOS remains responsible for original-source capture,
goal/project scoping, memory and deletion policy. Terminal scrollback is display
context, not a complete native transcript. Do not add recursive transcript scans
or model calls to inventory.

A busy existing session may finish older work after a new goal was queued. Runtime
events must let AIOS distinguish that turn from consumption of the new instruction.
AIOS keeps the new goal in Waiting for agent until activation is proved; a prior
turn ending must not look like completion of the new goal.

Use existing hooks and snapshots efficiently. Follow the fork-free hot-path rules:
no per-pane provider subprocess on every daemon tick, no per-client process census
and no model invocation for discovery or message routing.

## Suggested delivery plan

1. **Contract and compatibility inventory.** Read the current fleet owned protocol
   and AIOS consumer/donor tests. Specify identities, capabilities, durable effects,
   state locations and schema versions. Identify which behavior is already available
   and which needs an extension. Preserve the explicit external-driver path.
2. **Prove messaging/input ownership early.** Use disposable sessions to demonstrate
   a safe native input boundary or broker. Document whether an existing unmediated
   session supports in-place connection or needs a reviewed reconnect. Do not build
   the interface on an assumed reliable `send-keys` transport.
3. **Fleet-owned controlled runtime.** Extract/package the reusable process and
   driver machinery behind an optional fleet backend. Remove AIOS module imports
   by defining generic retirement/identity/evidence contracts. Keep AIOS approval,
   admission, task-result interpretation and validation policy in AIOS.
4. **Session messaging and events.** Add guarded delivery, receipts, interruption,
   question/permission distinctions and native source references. Preserve existing
   CLI and terminal interaction, and expose controlled workers coherently to fleet
   inspection/UI without weakening ownership checks.
5. **Compatibility and consumer handoff.** Provide an adapter/migration path for
   AIOS with exact protocol examples and feature negotiation. Demonstrate the new
   backend with isolated fixtures before a separately coordinated live cutover.

Suggested operation vocabulary is capabilities/discover/inspect/create/resume,
send/answer/interrupt/stop, operation reconciliation, events and transcript refs.
These names are proposed, not implemented commands. Choose a versioned surface
consistent with fleet's existing verbs and keep requests structured; arbitrary
shell strings or terminal keystrokes are not an automation API.

## Claude and Codex scope

Start by preserving and proving the existing Claude managed-runtime behavior.
Make contracts provider-neutral, then enable each additional provider/mode only
with its own evidence. Fleet already supports interactive Codex sessions and
provider hooks; reuse that support. Do not advertise identical containment,
reliable messaging or transcript completeness without proving those capabilities.

AIOS currently has Claude-specific reasoning, coding-profile and native capture
adapters. Moving lifecycle to fleet helps session reuse, but does not automatically
implement Codex planning, transcript parsing, memory ingestion or managed validation
in AIOS. Return clear provider capabilities so the AIOS agent can stage that work.

## Compatibility, testing and acceptance

| Area | Required evidence |
| --- | --- |
| Existing fleet | Ordinary add/task/adopt/answer/review/save/restore behavior and existing supported hosts remain compatible. |
| Owned v1 | Existing external-driver forwarding, literal JSON, scoped socket/cache, exit statuses and no ordinary startup side effects remain covered. |
| Idempotency | Lost create/send responses, replayed operation IDs, changed-payload rejection and durable unknown outcomes; no duplicate agent or prompt. |
| Identity | Pane reuse, process replacement, boot change, session resume and conflicting claims; no instruction or stop reaches a different recipient. |
| Input | Busy agent, native human typing, partial prompts, multiline text/control characters, ordinary questions, permission prompts and startup menus. |
| Receipts | Submitted differs from consumed; correlated native turn identity; crash after send and before receipt remains unconfirmed rather than being resent. |
| Stop/restore | Descendants stopped, fresh timing/quiescence evidence, cancellation fences survive restart/restore and prior coordinator state. |
| Isolation | Requested strict mode never degrades; unavailable modes reject; actual profile/implementation identity and allowed workspace are verified. |
| Limits | Runtime ceiling, interruption/resume and real usage settlement do not create an unbounded or unaccounted replacement run. |
| Capture | Stable native references and child lineage, declared coverage gaps and no full-history scan on discovery. |
| Coexistence | Automated operations cannot adopt/stop/clean unrelated manual agents; terminal and coordinator input serialize correctly. |
| Resource use | Idle CPU/wakeups and tmux/process reads stay bounded as panes and UI clients increase; normal fleet has no unnecessary backend dependency. |

Reuse donor tests, but distinguish protocol/process fixtures from real provider
proof. Use disposable repositories, sockets, state and sessions; keep current owner
work outside experiments. Capability tests should use synthetic filesystem and
credential canaries rather than reading real credential contents. Follow fleet's
normal test instructions; targeted tests first, and the relevant broader suite
when implementation changes justify it. Documentation-only preparation does not
require launching agents or running the integration suite.

For AIOS migration, preserve old claims, namespace history, generations, operation
outcomes, fences, native session identities and usage evidence. Do not edit its live
driver/configuration in place or silently change its current namespace. Prepare a
versioned opt-in backend and a tested migration/rollback boundary for quiescent
work. An older database/cache must not resurrect writers or erase uncertain effects.

## Deliverables for the AIOS follow-up agent

- Fleet-owned runtime package/entry point and documented protocol/capabilities.
- Compatibility path for the current explicit-driver protocol.
- Identity, ownership/grant, input, receipt, event and native-source schemas.
- Exact behavior for unknown operations, stop, retirement, restore and reconnect.
- Provider/mode/host support matrix with fixture and native evidence distinguished.
- Test receipts and resource-use measurements.
- Versioned backend installation, durable-state layout, migration instructions and
  the precise AIOS adapter/config changes required next.

Do not port the AIOS goal database, planner, memory system, validation workflow or
goal UI into fleet. The intended result is one reusable agent-management layer
that AIOS delegates to, with existing manual fleet use preserved.
