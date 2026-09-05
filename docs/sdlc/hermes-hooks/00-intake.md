# Intake — hermes-hooks (#15)

Date: 2026-09-05. Mode: collapsed. Research-first (source-verified against the
local Hermes Agent v0.19.0 git checkout, upstream 9ecacd6b) — findings below
are the design constraints.

## Research findings (source-cited in the research report)

- Hook events validate against VALID_HOOKS (hermes_cli/plugins.py:135-215).
  Map: `on_session_start`→start (does NOT fire on --resume), `pre_llm_call`→
  working (the UserPromptSubmit equivalent), `pre_tool_call`→working,
  `pre_approval_request`→wait (observer only — return ignored),
  `on_session_end`→done (fires at every turn end: the Stop equivalent).
- Schema: top-level `hooks:` in ~/.hermes/config.yaml; entries have exactly
  command (shlex-split, so args ride in the string), optional matcher
  (pre/post_tool_call only), timeout (default 60, max 300).
- Contract: snake_case JSON on stdin with `session_id`; full parent env
  inherited (TMUX_PANE rides through); nonzero exit aborts nothing; only
  pre_tool_call stdout can block — our hook prints nothing.
- Consent: ~/.hermes/shell-hooks-allowlist.json keyed on the exact
  (event, command) pair. Unapproved hooks are silently skipped on non-TTY,
  prompted y/N on TTY. `hermes hooks list` = the status view. Install is
  inert until the user approves — exactly the acceptance criterion.
- Resume: `--resume <id>`, exact id or exact title, NO prefix match. Ids are
  `YYYYMMDD_HHMMSS_<hex>` — charset [0-9a-f_], shell-safe. `--pass-session-id`
  is a system-prompt feature, irrelevant to hooks.
- **No fenced block possible**: config writes go through a PyYAML full dump
  (utils.py:227,269) that strips comments, triggered by ordinary actions
  ("allow permanently", model picker, `hermes update`). No include mechanism.

## Design (collapsed phases 2–3)

- `cmd_hermes_hooks install|remove|status` on `${HERMES_HOME:-~/.hermes}/config.yaml`.
  Identity = the command string (contains agent-status-hook.sh) — the same
  string the allowlist keys on. Install appends a `hooks:` section when none
  exists; refuses with a print-it-yourself block when a foreign `hooks:`
  section is present (merging foreign YAML from bash risks corrupting it).
  Remove = structural awk strip: drop list items whose command mentions the
  hook (plus continuation lines), then childless event keys, then a bare
  `hooks:` — tolerant of PyYAML re-serialization (quoting/indent/order all
  unstable; only the command string is stable).
- Restore: `hermes) rc="hermes --resume $sid"` (fresh `hermes` without id).
- Scrape tier: `hermes` added to the _AGENT_CMDS default.
- Consent documented at install time and in the README; never auto-accepted.

## Out of scope

hooks_auto_accept manipulation (wholesale trust is the user's call),
gateway/API-server session ids (client-supplied, unvalidated upstream —
fleet only consumes ids captured from local hook payloads).
