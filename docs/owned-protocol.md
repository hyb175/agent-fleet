# Optional owned-worker backend

`agent-fleet owned --driver /absolute/executable launch|inspect|answer|stop`
passes a JSON request on standard input to the selected executable, with:

```
--fleet-socket <exact socket> --fleet-cache <socket-scoped cache> <action>
```

Standard input/output and exit status pass through unchanged. Arguments are
quoted; JSON is never shell code. The driver must be an explicit, executable,
absolute regular-file path. There is no environment-selected default driver.
This path runs before theme generation, tmux queries, cache migration or layout
restore. Help and rejected invocations have no fleet-state effects.

The optional backend owns protocol versions, durable operation IDs, ownership
checks, process generations, isolation profiles, capture and terminal receipts.
A caller-supplied identifier alone is not proof of authority. The backend must
reject changed-payload replay, retain uncertain launch outcomes, and prove a
prior generation quiescent before continuation. It must never adopt or mutate
ordinary fleet task records. The CLI does not turn a model result into validated
completion or merge authority.

AIOS supplies its own backend and calls it through this command. Its workers
run in separately contained units rather than resumable tmux panes. Existing
manual task/add/answer/kill/save/restore behavior is unchanged; restoring a
manual fleet cannot restart an owned worker. An owned backend is optional and
adds no runtime dependency to the ordinary Bash CLI.

`agent-fleet owned --backend fleet <action>` selects the bundled copy of that
backend ([backends/owned](../backends/owned/README.md)): the same protocol v1,
the same unit names, no AIOS imports, ledgers rooted under the durable
`$XDG_STATE_HOME/agent-fleet/<socket>/` (passed as `--fleet-state`) instead of
the per-boot cache. It needs Linux, python3, `systemd --user` and bubblewrap;
elsewhere the command exits 2 with the reason and runs nothing.
`agent-fleet capabilities` reports `owned_backend_fleet=available|unavailable`.
The full identity, delivery and versioning contract is in
[runtime-contract.md](runtime-contract.md).
