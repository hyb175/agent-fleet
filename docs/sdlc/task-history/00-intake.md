# Intake — task-history (#10)

Date: 2026-09-05. Mode: collapsed (small read-only verb over existing records).

## Request (issue #10, verbatim scope)

- `af task history` (or `af history`): list terminal-state tasks with intent, repo,
  duration, wait-time totals, outcome (merged / abandoned / PR link).
- Data comes entirely from task records; no scraping.
- Optional: simple per-day summary line (n tasks, n merged).

Acceptance: history lists intent/duration/outcome after tasks complete; survives
restarts and reboots; killed-without-outcome agents show as abandoned, not lost.

## Design (collapsed phases 2–3)

- `task_history()` in bin/agent-fleet; verbs `task history` + top-level `history`.
  Pure read over $AF_TASKS_DIR records — no server needed, no new state.
- Outcome from the full state-line walk (not last-state): last of merged/abandoned
  wins; `cleaned` never overrides the underlying outcome; else a recorded `pr`
  state = outcome `pr`; else non-terminal + dead pane = `abandoned~` (inferred —
  same `~` vocabulary as the snapshot's scrape marker). Live non-terminal records
  are current work (rail/ls territory), skipped.
- Liveness discipline = task_ls: pane exists AND @fleet-task matches the id.
  Restore rewrites the record's `pane` line, so this stays valid across reboots.
- Duration = outcome epoch − created; wait total = sum of wait→next-state deltas
  (restore's appended `state idle` closes a reboot-straddling wait honestly).
- Rows grouped per day of completion, newest first, day header `n tasks, n merged`.
- fmt_age grows a day unit (`3d`) — shared with rail/picker/inbox, safe (no test
  pins the hour cap).

## Out of scope

Filters (--days, --repo), PR URL storage (records keep no URL; outcome `pr` +
branch is the pointer), CSV/JSON output.
