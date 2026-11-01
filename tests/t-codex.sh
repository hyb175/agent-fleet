#!/usr/bin/env bash
# t-codex.sh — codex hook-tier support.
#   - `agent-fleet codex-hooks` installs [[hooks.<Event>]] groups in
#     ~/.codex/config.toml idempotently, preserves the user's config, and
#     removes exactly its own entries — codex re-serializes the file and
#     appends its trust table and TUI state after our block, and a user may
#     add handlers of their own; both survive remove
#   - the status hook tags the pane kind codex and captures the session id
#   - persist-restore relaunches the pane with `codex resume <id>`
#   - a scrape-tier codex (hooks never fired) is saved under its detected kind
#     and resumes the newest thread codex recorded for that dir
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-codex:"
FAKEHOME="$(mktemp -d)"
mkdir -p "$FAKEHOME/.codex"
printf 'model = "gpt-5.2-codex"' > "$FAKEHOME/.codex/config.toml"   # no trailing newline on purpose
CONF="$FAKEHOME/.codex/config.toml"

af() { HOME="$FAKEHOME" "$REPO/bin/agent-fleet" "$@"; }

check "status before install: not installed" "[[ \"\$(af codex-hooks status)\" == 'not installed' ]]"
af codex-hooks install >/dev/null
check "install: hooks present" "grep -qF 'agent-status-hook.sh' '$CONF'"
check "install: no fence markers (codex rewrites its config)" "! grep -q 'agent-fleet hooks >>>' '$CONF'"
check "status after install: installed" "[[ \"\$(af codex-hooks status)\" == installed* ]]"
check "install: user config preserved" "grep -q 'gpt-5.2-codex' '$CONF'"
check "install: five event groups" "[[ \"\$(grep -c '^\[\[hooks\.[A-Za-z]*\]\]$' '$CONF')\" == '5' ]]"
check "install: nested handler tables" "[[ \"\$(grep -c '^\[\[hooks\.[A-Za-z]*\.hooks\]\]$' '$CONF')\" == '5' ]]"
check "install: PermissionRequest -> wait" "grep -A3 'hooks.PermissionRequest.hooks' '$CONF' | grep -q 'wait'"
check "install: codex kind in commands" "grep -q \"codex\\\"\" '$CONF'"
af codex-hooks install >/dev/null
check "reinstall: still exactly one block" "[[ \"\$(grep -c '^\[\[hooks\.Stop\]\]$' '$CONF')\" == '1' ]]"
af codex-hooks remove >/dev/null
check "remove: block gone" "! grep -q 'agent-status-hook.sh\|^\[\[hooks' '$CONF'"
check "remove: user config preserved" "grep -q 'gpt-5.2-codex' '$CONF'"
check "status after remove: not installed" "[[ \"\$(af codex-hooks status)\" == 'not installed' ]]"

# What codex does to the file after install: it re-serializes config.toml and
# appends its own tables at the END (trust hashes, TUI state) — in the fenced
# era that landed INSIDE the fence and remove took them with it. Plus a user
# handler added to OUR Stop group, and a user group whose command merely
# mentions the hook path as an argument. Remove keeps every one of them.
af codex-hooks install >/dev/null
{ printf '[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "/usr/bin/mine done"\n\n'
  printf '[hooks.state]\n\n[hooks.state."%s:stop:0:0"]\ntrusted_hash = "sha256:abc"\n\n[tui]\nscreen_reader_detection_done = true\n\n' "$CONF"
  printf '[[hooks.PreToolUse]]\n[[hooks.PreToolUse.hooks]]\ntype = "command"\ncommand = "/usr/bin/mine agent-status-hook.sh"\n'
} >> "$CONF"
af codex-hooks remove >/dev/null
check "remove keeps codex trust table" "grep -q 'trusted_hash' '$CONF' && grep -q '^\[hooks.state\]$' '$CONF'"
check "remove keeps codex TUI state" "grep -q '^\[tui\]$' '$CONF'"
check "remove drops every fleet handler" "! grep -qF \"'$REPO/scripts/agent-status-hook.sh'\" '$CONF'"
check "user handler in the fleet Stop group survives, with its group" "grep -q '/usr/bin/mine done' '$CONF' && [[ \"\$(grep -c '^\[\[hooks\.Stop\]\]$' '$CONF')\" == '1' ]]"
check "user group naming the hook as an ARGUMENT survives" "grep -q 'mine agent-status-hook.sh' '$CONF' && [[ \"\$(grep -c '^\[\[hooks\.PreToolUse\]\]$' '$CONF')\" == '1' ]]"
af codex-hooks install >/dev/null
check "reinstall over a codex-rewritten config: one Stop group of ours + user" "[[ \"\$(grep -c '^\[\[hooks\.Stop\]\]$' '$CONF')\" == '2' ]] && grep -q 'trusted_hash' '$CONF'"
rm -f "$CONF"
check "install without config errors" "! af codex-hooks install 2>/dev/null"

# --- hook kind-tagging + save/restore round trip -----------------------------
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
UUID="abababab-cdcd-efef-1212-343434343434"
mkdir -p "$WORK/x"

boot_server __boot__ "$WORK"
tx new-session -d -s xwork -n xwork -c "$WORK/x"
sleep 0.6
wp="$(tx list-panes -t xwork -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"

# Simulate codex's UserPromptSubmit hook firing in that pane (snake_case JSON).
printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s"}' "$UUID" "$WORK/x" \
  | TMUX_PANE="$wp" AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" working "$SOCK" codex
check "hook captures codex session id" "grep -qx '$UUID' '$CACHE/panes/$wp.session'"
check "hook tags @fleet-agent-kind codex" "[[ \"\$(tx display-message -p -t $wp '#{@fleet-agent-kind}')\" == 'codex' ]]"

tx kill-session -t __boot__ 2>/dev/null; sleep 0.3
"$REPO/scripts/persist-save.sh"
check "save records kind codex" "grep -q 'codex' '$CACHE/fleet.state'"

kill_server
"$REPO/scripts/persist-restore.sh"
poll_until 20 "tx list-panes -t xwork -F '#{pane_start_command}' 2>/dev/null | grep -c 'codex resume'"
# shellcheck disable=SC2034 # read inside the eval'd check() conditions below
starts="$(tx list-panes -t xwork -F '#{pane_start_command}')"
check "restore relaunches codex resume" "grep -q 'codex resume $UUID' <<<\"\$starts\""
check "restore does NOT use claude --resume for codex" "! grep -q 'claude --resume $UUID' <<<\"\$starts\""

# --- scrape tier: hand-started codex, hooks never fired ----------------------
# A fake `codex` (the scrape tier keys on the process name) in a new window;
# the daemon labels it codex~ in the snapshot, save borrows that kind, and
# restore picks the newest USER thread codex recorded for that dir — not the
# newer subagent thread there, not the newest thread of another dir.
# The fake must be a real binary file named codex: tmux reports a pane's
# command from argv[0] (a script would read as its interpreter, a shell, and
# shells are skipped) and the scrape reads process names from the file.
cp "$(command -v bash)" "$FAKEHOME/codex"
mkdir -p "$WORK/y"
tx new-window -d -t xwork: -n ywork -c "$WORK/y" "exec $FAKEHOME/codex -c 'sleep 300; true'"   # ; true: no exec-of-last-command
poll_until 30 "grep -q '^A xwork|[^|]*|[^|]*|ywork|[^|]*|codex~|' '$CACHE/fleet.snapshot'"
check "daemon scrapes the fake codex" "grep -q '|ywork|[^|]*|codex~|' '$CACHE/fleet.snapshot'"
"$REPO/scripts/persist-save.sh"
check "save borrows the scraped kind" "awk -F'\t' '\$1==\"P\" && \$8==\"$WORK/y\" && \$9==\"codex\"' '$CACHE/fleet.state' | grep -q ."

# A second scrape-tier codex in the SAME dir: the two panes must not resume
# the same thread (two processes appending one rollout), so the older user
# thread goes to whichever pane is relaunched second.
tx new-window -d -t xwork: -n zwork -c "$WORK/y" "exec $FAKEHOME/codex -c 'sleep 300; true'"
poll_until 30 "grep -q '|zwork|[^|]*|codex~|' '$CACHE/fleet.snapshot'"
"$REPO/scripts/persist-save.sh"

U_USER="11111111-1111-1111-1111-111111111111"
U_USER2="44444444-4444-4444-4444-444444444444"
U_SUB="22222222-2222-2222-2222-222222222222"
U_OTHER="33333333-3333-3333-3333-333333333333"
RD="$FAKEHOME/.codex/sessions/2026/10/25"; mkdir -p "$RD"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","source":"cli"}}\n' "$U_USER2" "$WORK/y" > "$RD/rollout-2026-10-25T21-00-00-$U_USER2.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","source":"cli"}}\n' "$U_USER" "$WORK/y" > "$RD/rollout-2026-10-25T22-00-00-$U_USER.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","source":{"subagent":{"thread_spawn":{}}}}}\n' "$U_SUB" "$WORK/y" > "$RD/rollout-2026-10-25T23-00-00-$U_SUB.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","source":"cli"}}\n' "$U_OTHER" "$WORK/x" > "$RD/rollout-2026-10-26T00-00-00-$U_OTHER.jsonl"
touch -t 202510252100 "$RD/rollout-2026-10-25T21-00-00-$U_USER2.jsonl"
touch -t 202510252200 "$RD/rollout-2026-10-25T22-00-00-$U_USER.jsonl"
touch -t 202510252300 "$RD/rollout-2026-10-25T23-00-00-$U_SUB.jsonl"
touch -t 202510260000 "$RD/rollout-2026-10-26T00-00-00-$U_OTHER.jsonl"

kill_server
HOME="$FAKEHOME" "$REPO/scripts/persist-restore.sh"
poll_until 20 "tx list-panes -s -t xwork -F '#{pane_start_command}' 2>/dev/null | grep -q 'codex resume $U_USER2'"
# shellcheck disable=SC2034 # read inside the eval'd check() conditions below
starts="$(tx list-panes -s -t xwork -F '#{pane_start_command}')"   # -s: every window, not just the active one
check "scrape-tier codex resumes the newest user thread for its dir" "grep -q 'codex resume $U_USER' <<<\"\$starts\""
check "second pane in the same dir gets the next thread, not the same one" "grep -q 'codex resume $U_USER2' <<<\"\$starts\" && [[ \"\$(grep -c 'codex resume $U_USER;' <<<\"\$starts\")\" == '1' ]]"
check "…not the newer subagent thread" "! grep -q '$U_SUB' <<<\"\$starts\""
check "…not another dir's thread" "! grep -q '$U_OTHER' <<<\"\$starts\""

rm -rf "$FAKEHOME"
exit "$FAIL"
