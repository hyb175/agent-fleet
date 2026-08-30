# Intake — task-intent-display

- **Date:** 2026-08-29
- **Mode:** gated, collapsed (small feature; design+plan below)
- **Request:** GitHub issue #3 — Rail/picker: show task intent and time-in-state.

## Issue acceptance criteria (verbatim)

- An agent waiting on input shows elapsed wait time in the rail, updating as the snapshot refreshes.
- Picker's most-urgent-first ordering can use time-in-state as a tiebreaker (longest-waiting first).
- No additional per-second tmux load beyond the existing single snapshotd poll.

## Collapsed design + plan

Wait-age already ships (A-record field 9, rail `· 4m`, picker `wait 4m`) — this
cycle extends it per the issue. snapshotd: (1) age computed for `done` as well
as `wait` (same status-file mtime, still no extra tmux calls); (2) A records
grow field 10 `intent`, resolved builtin-only from `panes/<pane>.task` →
`tasks/<tid>`'s `intent` line, `|`→`¦` scrubbed, `-` when absent. Renderers:
rail row title = intent when present (trunc() already caps it), else window
name; picker fleet-row title likewise (manually capped), subtitle gains
`done 2h`. Picker sort key becomes (rank asc, age desc, idx asc) — longest
wait first within a rank. Readers absorb the new trailing field per
CONTRIBUTING #7. Tests extend t-snapshot (intent in record + scrub, done age,
picker title/tiebreak). Route: one correctness reviewer on the diff; release
notes skipped (roadmap issue tracks it).
