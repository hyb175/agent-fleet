# fleet.snapshot

`scripts/snapshotd.sh` (one per tmux server) polls tmux once per interval and writes `$AF_CACHE_DIR/fleet.snapshot` atomically (temp file + `mv`). Every renderer reads this file instead of tmux, so the number of open rails and popups adds no tmux load.

Readers: `scripts/sidenav.sh`, `scripts/pick.sh`, `scripts/inbox.sh`, `scripts/next-attention.sh`, `bin/agent-fleet` (`answer`), `scripts/remote-poll.sh` (on the remote side), and `ui/internal/snapshot` (Go). Fixtures both sides parse live in `tests/fixtures/snapshot/`; `tests/t-fixtures.sh` and `ui/internal/snapshot/snapshot_test.go` are the conformance tests.

---

## Records

One record per line. The first character is the record type, then one space, then `|`-separated fields. Unknown record types are skipped.

| Type | Fields | One per |
| --- | --- | --- |
| `T` | `<epoch> <interval>` (space-separated) | file; always first |
| `C` | `<client>\|<session>\|<window_id>` | attached client |
| `S` | `<session>\|<rollup>\|<branch>` | workspace (tmux session) |
| `A` | `<session>\|<window_id>\|<window_index>\|<window_name>\|<pane_id>\|<label>\|<state>\|<pane_index>\|<age>\|<intent>\|<iso>\|<diffstat>` | agent pane |

### T

`epoch` is the daemon's clock when it wrote the file. `interval` is its poll interval in seconds (`AGENT_FLEET_SNAP_INTERVAL`, default 1). Files from before the interval field carry only the epoch; readers default the interval to 1.

### C

The active view per attached client, so each terminal gets its own rail highlight and progress bar. `client` is tmux's `#{client_name}`. With no client attached the daemon writes one record with `client` = `-` and the server's current view, so consumers always see at least one `C`.

### S

`rollup` is the most urgent state (see [State rank](#state-rank)) among the session's agents, or `none` when it has no agents. `branch` is the git branch of the session's active pane; outside git it is the directory basename; for a federated host that is down it is `(unreachable)`.

### A

| Field | Meaning | Sentinel |
| --- | --- | --- |
| `session` | workspace name | never empty |
| `window_id` | tmux `@N` | never empty |
| `window_index` | tmux window number | never empty |
| `window_name` | tab name, user-controlled | never empty |
| `pane_id` | tmux `%N`; the key every action uses | never empty |
| `label` | agent kind (`claude`, `codex`, `opencode`, `kimi`, `hermes`, `cursor`); a `~` suffix marks a scrape-tier agent whose state is heuristic | never empty |
| `state` | `wait` \| `working` \| `done` \| `idle` | never empty |
| `pane_index` | tmux pane number within the window | `-` |
| `age` | seconds the current state has been held, from the status file's mtime; hooked agents in `wait`/`done` only | `-` |
| `intent` | the task record's `intent` line | `-` |
| `iso` | isolation rung short code: `wt`, `sbx`, `ctr` | `-` for host or no task |
| `diffstat` | `+A-D` recorded at the last attention transition | `-` |

---

## Rules every reader follows

**Fields grow at the end.** New fields are appended after `diffstat`. A reader binds fields by position from the front, ignores fields it does not know, and treats a missing trailing field as `-`. A reader whose last variable is load-bearing breaks when a field is appended, so bash readers name every field before a trailing catch-all `_`:

```bash
IFS='|' read -r s wid widx wn pane label st pidx age intent iso ds _ <<<"${line#A }"
```

**`|` never appears inside a field.** Window names and intents are user-typed; the daemon substitutes `¦` (U+00A6) before writing. Session names are sanitized at creation by the CLI. Readers do not unsubstitute.

**Staleness.** A crashed daemon (`kill -9` skips its cleanup) leaves the file behind. A reader treats the snapshot as stale when

```
now - epoch > interval * 3 + 7
```

and then shows the stale warning and refuses to act on it (`next-attention.sh` does not jump; the rail and picker show a banner). The `T` interval is what makes a slow-but-healthy daemon not false-alarm.

**Federated ids.** `scripts/remote-poll.sh` mirrors a remote host's snapshot into `$AF_CACHE_DIR/remote/<host>.snapshot` with every `session`, `window_id` and `pane_id` qualified as `<host>/<id>`. `snapshotd.sh` concatenates the mirrored `S`/`A` records into the local file. A local id never contains `/`, so `pane_id` containing `/` identifies a remote agent; remote agents cannot be focused or answered locally, only opened over ssh. A host that is unreachable, or whose daemon stopped writing, contributes one row `S <host>|none|(unreachable)` and no `A` rows. Remote `C` records are dropped.

The mirror file's own header is `RT <fetched_at_local_epoch> <ok|down>`; it is not part of `fleet.snapshot`.

---

## Derived values renderers agree on

**State rank** (most urgent first): `wait` 0, `working` 1, `done` 2, `idle` 3, anything else 4.

**Attention order**: rank ascending, then longest age first, then arrival order in the file. The picker applies the age tiebreak to `wait` rows only; the inbox applies it to `wait` and `done`. `tests/fixtures/snapshot/mixed.picker-order` is the picker order of `mixed.snapshot`, asserted by both suites.

**Age display**: under 60 s → `45s`; under 3600 s → `4m`; else `2h` (integer division).

**Row title**: the intent when present, else the window name; suffixed `.<pane_index>` in windows holding more than one agent.

**Glyphs**: `◆` wait, braille spinner working, `✓` done, `○` idle. Shapes differ per state so they read without color.

---

## Changing the format

1. Append the field to the `A` (or `S`/`C`) record in `snapshotd.sh` and `remote-poll.sh`'s qualification `awk` if it carries an id.
2. Update the table above and every fixture in `tests/fixtures/snapshot/`, then `extra-field.snapshot` (which must still equal `mixed.snapshot` after parsing).
3. `rg "IFS='\|' read"` and check each reader's last variable is a catch-all.
4. Extend `ui/internal/snapshot` and its tests.
