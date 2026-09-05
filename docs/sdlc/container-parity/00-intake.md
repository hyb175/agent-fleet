# Intake — container-parity (#13)

Date: 2026-09-05. Mode: collapsed. Final board item; #12 pre-landed the mount
strategy (cache+scripts+.git+~/.claude at identical host paths), so this cycle
is the remaining parity slices.

## Request (issue #13, remaining scope)

- Status: hooks fire inside the container and must reach host snapshotd — DONE
  in #12 via the cache mount (hook's tmux calls are guarded no-ops inside).
  Remaining: the pieces that USED those tmux calls:
  - session-id capture: the hook can't set @fleet-session inside the container,
    so persist-save sees '-' and restore can't resume.
  - notifications: the hook's notify.sh no-ops inside (no notify-send/osascript).
- Git handback: mount-at-identical-paths strategy landed in #12; verify the
  review flow end-to-end.
- Reboot + restore re-links a restartable containerized task.

Acceptance: container agents' glyphs/notifications/inbox identical to host
agents; diff reviewable via standard review flow; restore re-links without
losing the record.

## Design (collapsed phases 2–3)

- Session mirror (snapshotd): per tick, a pane with a `panes/<pane>.session`
  file but an empty @fleet-session option gets the option set host-side —
  one tmux call per pane ONCE (option non-empty afterwards). persist-save
  then works unchanged.
- Notification edge (snapshotd): per-pane previous-state map; a transition
  into wait/done on a pane whose record says `isolation container` fires
  host-side notify.sh. Gated to container panes only — host agents' hooks
  already notify (double-fire otherwise). First observation of a pane never
  fires (boot spam guard).
- Restore re-link: the #12 shell-guard upgrades to a relaunch. The container
  command builder moves out of cmd_task into `build_container_cmd()` (bin);
  a new internal verb `agent-fleet _container-resume <tid>` rebuilds the
  command from the task record (fresh container name appended to the record;
  `claude --resume <record session>` when captured, fresh claude otherwise)
  and execs it. persist-restore points the respawned pane at that verb instead
  of leaving a shell — logic stays in bin, restore stays dumb. Docker missing
  at boot → visible note + shell (honest degrade, as before).
- `container` record line becomes append-many, LAST wins (a resume names a
  new container) — both awk readers switch from first-match to last-match.
- task_record_get grows TASK_DIR / TASK_SESSION / TASK_CONTAINERDIR fills.

## Out of scope

devcontainer resume (up+exec relaunch works but no session resume promise —
the CLI's container may have been GC'd); notification actions inside
containers; image/volume GC.
