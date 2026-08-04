# Contributing

agent-fleet is bash on purpose — it composes with tmux instead of wrapping it.
Bash at this size bites in specific, repeatable ways. Every rule below is a bug
we actually shipped and fixed; CI (shellcheck + the integration suite) enforces
what it can, this file covers what it can't.

## House rules (each one is a scar)

1. **Brace-delimit variables before Unicode glyphs.** `"$T_WAIT◆"` makes bash
   5 fold the glyph's leading continuation byte into the variable name — an
   unbound `T_WAIT<byte>` that kills the whole render under `set -u`. Write
   `"${T_WAIT}◆"`. (20d2410)

2. **No bare `[[ ]] &&` as the last line of a function or script under
   `set -e`.** A false condition makes the whole thing exit nonzero — or exit,
   period. Wrap in `if …; then …; fi` or add `|| true` deliberately.

3. **Under `pipefail`, never pipe a producer into `grep -q`.** grep exits at
   the first match, the producer takes SIGPIPE mid-write, the pipeline "fails"
   with the row plainly present. Capture first: `out="$(cmd)"; grep -q x <<<"$out"`.

4. **tmux binds are three quoting layers** (tmux parse → sh → the target
   command). Never interpolate user-typed text (`%%`) into a quoted sh string —
   route it through a tmux option and read it back (`@fleet-prompt` + `_prompt`
   verb). `#{q:…}` escapes format expansions, not typed input.

5. **Hot paths stay fork-free.** The rail redraws every tick and the status
   bar every 3s; a command substitution there is a fork on every rail on every
   tick (~15ms each on macOS). Use `printf -v`, parameter expansion, `read`
   from files, `%(%s)T` for time. Forks belong in `cache_bg` background
   refreshers or one-shot setup. Cheap check: would this line run 10×/second
   across 10 rails?

6. **`read` returns 1 at EOF *after* assigning** a final unterminated line.
   `read x < file || x=""` silently clobbers the value; use `|| true`. Files
   written by other tools may lack trailing newlines.

7. **Snapshot/state formats grow at the END, readers absorb extras.** The last
   `read` variable swallows remaining fields, so appending a field only breaks
   the reader whose last variable was load-bearing — grep every
   `IFS='|' read`/`IFS="$US" read` of that record type before appending
   (persist `fleet.state` kind field, A-record `pidx`).

8. **Names: don't shadow bash builtins or their variables** (`MAPFILE`,
   `REPLY`, `GROUPS`…). `MAPFILE` as a var name collided with the `mapfile`
   builtin's default array.

9. **Environment is not persistence.** CLI calls fired by tmux keybinds run in
   the *server's* environment — a shell-profile export never arrives there.
   Durable settings live in files (`~/.config/agent-fleet/*`), env vars are
   one-shot overrides. (theme-stomping bug)

10. **GNU vs BSD userland:** always `stat -c … || stat -f …` (GNU first — BSD's
    `-f` means something else on GNU and doesn't fail cleanly), `sed -i.bak`,
    no `grep -P`. NixOS adds a third shape: `/usr/bin`+`/bin` hold almost
    nothing, so tests building restricted PATHs must include `$(dirname "$BASH")`.

## Shellcheck policy

`.shellcheckrc` globally disables only SC1090/SC1091 (source-path resolution).
Everything else: fix it, or carry a per-line
`# shellcheck disable=SCxxxx # <reason>` — the reason is mandatory. SC2086
(quoting) is never disabled; if the word-splitting is intentional, say so on
the line.

## Tests

`bash tests/run-all.sh` — every `t-*.sh` is standalone, runs on a throwaway
tmux socket with private XDG cache/config dirs, and must leave no processes
behind. New behavior gets a check; new bug classes get a rule here.
