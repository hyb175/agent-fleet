# Owned-worker backend

Optional Python backend that runs one sandboxed worker generation per systemd
user unit and keeps a durable, replayable record of it under
`<root>/owned/<namespace>/<attempt>/`. Ordinary fleet never imports it; the CLI
only runs the entry point as a subprocess.

Requirements (Linux only): python3 >= 3.9 (stdlib only), `systemd --user`,
bubblewrap, git.

Entry point: `backends/owned/agent-fleet-owned-driver ACTION`, where ACTION is
`launch`, `inspect`, `answer` or `stop`. The request is one JSON object on
stdin (protocol version 1, 16 MiB limit); the reply is one JSON object on
stdout. Exit 0 on success, 1 with `{"status":"error","error":...}` otherwise.

- `--fleet-socket NAME_OR_ABSOLUTE_PATH` required
- `--fleet-cache DIR` required; root of the `owned/` tree by default
- `--fleet-state DIR` optional; roots the `owned/` tree here instead, for
  durable XDG state rather than a disposable cache

The root in use is recorded in each claim (`fleet_cache`) and validated the
same way. Units are `aios-owned-<hash>.service`; the on-disk layout, unit and
description names, and error strings are protocol v1 and are kept unchanged.

`process.py` is stdlib-only and copied into each generation as `runner.py`;
the unit executes that copy standalone, so it must never import its siblings.

Tests: `python3 -m unittest discover -s backends/owned/tests -t .` from the repo
root. Real systemd tests need `AIOS_OWNED_HOST_TEST=1`; sandbox tests skip when
bubblewrap cannot run or the runtime is not the Nix store.

Differences from the AIOS copy: location; no `aios` import (the retirement
reader and census helpers are ported into `retirement.py`, which accepts only
`owned` records and has no total-time budget); the `--fleet-state` flag.
