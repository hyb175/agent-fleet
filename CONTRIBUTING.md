# Contributing

agent-fleet is bash on purpose — it composes with tmux instead of wrapping it.
Bash at this size bites in specific, repeatable ways. Every rule below is a bug
we actually shipped and fixed; CI (shellcheck + the integration suite) enforces
what it can, this file covers what it can't.

## House rules (each one is a scar)

1. **Brace-delimit variables before Unicode glyphs.** On macOS, `"$T_WAIT◆"`
   crashed the rail: the glyph's first (lead) byte got treated as part of the
   variable name — an unbound `T_WAIT<byte>` under `set -u`. Bash names are
   ASCII-only and glibc builds parse this fine, which is exactly why it ships
   from Linux and dies on Macs (BSD-libc ctype on a negative `char` is the
   likely mechanism). Write `"${T_WAIT}◆"` everywhere. (20d2410)

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

5. **Hot paths stay fork-free.** The daemon polls every tick and the status
   bar re-renders every 3s; a command substitution there is a fork per agent
   per tick (~15ms each on macOS). Use `printf -v`, parameter expansion, `read`
   from files, `%(%s)T` for time. Forks belong in `cache_bg` background
   refreshers or one-shot setup. Cheap check: would this line run every tick
   for every agent?

6. **`read` returns 1 at EOF *after* assigning** a final unterminated line.
   `read x < file || x=""` silently clobbers the value; use `|| true`. Files
   written by other tools may lack trailing newlines.

7. **Snapshot/state formats grow at the END, readers absorb extras.** The last
   `read` variable swallows remaining fields, so appending a field only breaks
   the reader whose last variable was load-bearing — grep every
   `IFS='|' read`/`IFS="$US" read` of that record type before appending
   (persist `fleet.state` kind field, A-record `pidx`). `fleet.snapshot` is
   specified in `docs/snapshot-format.md`; a change there updates the
   fixtures in `tests/fixtures/snapshot/`, which `tests/t-fixtures.sh` and the
   Go parser's tests (`ui/internal/snapshot`) both read.

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

11. **Hook-tier scripts are bash 3.2.** `agent-status-hook.sh`, `notify.sh`,
    `cache.sh`, `shims/claude` and `pane-shell.sh` run inside the AGENT's
    process, under whatever `bash` its PATH resolves — a macOS login shell
    puts `/bin/bash` 3.2 first, ahead of brew/nix. No `%(%s)T` (use `af_now`),
    no associative arrays, no `mapfile`, no `${var,,}`; `tests/t-bash32.sh`
    runs them under `/bin/bash`. (A hook aborted with `printf: '(': invalid
    format character` and `ts: unbound variable` on every Stop event.)

## Go (`ui/`)

The rail, picker, inbox and move popup live in one module under `ui/` and
ship as `bin/afui` (`make ui`; `make ui-test` is what CI runs). Dependencies
are Bubble Tea, Lip Gloss, go-runewidth and sahilm/fuzzy; adding one is a
ticket, not a commit. Rules:

- **View-only.** The binary reads `fleet.snapshot`, `focus.now`, the theme
  presets and the cache dir. Anything that changes tmux or task state goes
  through an `agent-fleet` verb — one implementation, covered by the bash
  suite. Read-only `tmux capture-pane` for previews is the exception.
- **No tmux in the hot path.** A rail re-reads the snapshot on mtime change
  and never polls tmux; N rails add no server load.
- **The binary sends no signals and expects none.** Wake-ups are mtime
  polls of `fleet.snapshot` and `focus.now` every 250ms; `focus-track.sh`
  only writes the file. (Go exits on an unhandled SIGUSR1, and a pid-based
  wake once broadcast to every process the user owned.)
- **Never open `/dev/tty`.** Pass `tea.WithInput(os.Stdin)` and
  `tea.WithOutput(os.Stdout)`; Bubble Tea's default opens the tty when stdin
  is not one, and that open() never returns on a dead pane.
- **Space arrives as `tea.KeySpace`, not `KeyRunes`.** Every text input
  (filter, query, reply) handles both, or typed spaces vanish.
- **Width is terminal cells**, via go-runewidth — never `len()` or rune
  counts — so CJK and wide glyphs truncate and pad correctly.
- **Fixed color profile.** `lipgloss.SetColorProfile(termenv.TrueColor)` and
  `SetHasDarkBackground(true)`: inside tmux termenv would downgrade to the
  256-color cube and query the terminal for its background.
- **Snapshot fields by position from the front**, unknown trailing fields
  ignored, missing ones read as `-` (`docs/snapshot-format.md`).
- Version comes from `bin/agent-fleet` via `-ldflags -X main.version`; CI
  fails on drift.

## Shellcheck policy

`.shellcheckrc` globally disables only SC1090/SC1091 (source-path resolution).
Everything else: fix it, or carry a per-line
`# shellcheck disable=SCxxxx # <reason>` — the reason is mandatory. SC2086
(quoting) is never disabled; if the word-splitting is intentional, say so on
the line.

## Tests

`make ui && bash tests/run-all.sh` — every `t-*.sh` is standalone, runs on a
throwaway tmux socket with private XDG cache/config dirs, and must leave no
processes behind; the rail, picker and inbox tests drive `bin/afui` through
tmux, so the runner refuses to start without it. New behavior gets a check;
new bug classes get a rule here.
