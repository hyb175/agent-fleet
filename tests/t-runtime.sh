#!/usr/bin/env bash
# t-runtime.sh — the machine-facing runtime surface beyond send:
#   - events: header token, resumable cursor, --pane filter, explicit expiry
#     after the boot rotation; hook events (session/state/prompt/turn_end) land
#   - interrupt: refused unless a hooked claude pane is working; Escape is sent
#     and reported as status=sent (no native receipt), exit 4
#   - kill --wait: the process tree is censused before the kill and the result
#     is stopped only when every process is gone; a survivor makes it unknown
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-runtime:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
mkdir -p "$CACHE/panes"
af() { AGENT_FLEET_SOCKET="$SOCK" "$REPO/bin/agent-fleet" "$@"; }
HOOK="$REPO/scripts/agent-status-hook.sh"
EV="$CACHE/events.log"

boot_server t "$WORK"
stop_daemon() {
  kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
  for _ in $(seq 1 30); do [[ -d "$CACHE/snapshotd.lock" ]] || break; sleep 0.2; done
}
# A pane that reports like a hooked claude: SessionStart, then one prompt turn.
ap="$(tx new-window -d -P -F '#{pane_id}' -t t: "sleep 300")"
sleep 0.5; stop_daemon
printf 'T %s 1\n' "$(date +%s)" > "$CACHE/fleet.snapshot"
hook() { TMUX_PANE="$ap" bash "$HOOK" "$@"; }
printf '{"session_id":"s-1","hook_event_name":"SessionStart"}' | hook start "$SOCK" claude
printf '{"session_id":"s-1","hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"hi"}' | hook working "$SOCK" claude
printf '{"session_id":"s-1","hook_event_name":"Stop","prompt_id":"p1"}' | hook 'done' "$SOCK" claude

# --- events ---
check "event log has a token header" "head -1 '$EV' | grep -q '^# agent-fleet events [0-9]*-[0-9]*$'"
out="$(af events)"
check "hook events landed: session, state working, prompt, state done, turn_end" \
  "grep -q ' $ap session s-1 claude$' <<<\"\$out\" && grep -q ' $ap state working$' <<<\"\$out\" && grep -q ' $ap prompt p1 ' <<<\"\$out\" && grep -q ' $ap state done$' <<<\"\$out\" && grep -q ' $ap turn_end p1$' <<<\"\$out\""
cur="$(tail -1 <<<"$out")"
check "last line is the cursor" "[[ '$cur' =~ ^cursor=[0-9]+-[0-9]+:[0-9]+$ ]]"
out="$(af events --since "${cur#cursor=}")"
check "nothing new since the cursor" "[[ \"\$(grep -vc '^cursor=' <<<\"\$out\")\" -eq 0 ]]"
printf '{"session_id":"s-1","hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"again"}' | hook working "$SOCK" claude
out="$(af events --since "${cur#cursor=}")"
check "resuming yields only the new events" "[[ \"\$(grep -vc '^cursor=' <<<\"\$out\")\" -eq 2 ]] && grep -q ' prompt p2 ' <<<\"\$out\""
bp="$(tx new-window -d -P -F '#{pane_id}' -t t: "sleep 300")"; sleep 0.3; stop_daemon
TMUX_PANE="$bp" bash "$HOOK" start "$SOCK" claude <<<'{"session_id":"s-2","hook_event_name":"SessionStart"}'
out="$(af events --pane "$bp")"
check "--pane filters to that pane" "grep -q ' $bp session s-2 ' <<<\"\$out\" && ! grep -q \" $ap \" <<<\"\$out\""
mv "$EV" "$EV.1"   # what a cold boot does
out="$(af events --since "${cur#cursor=}")"; rc=$?
check "rotated log expires the cursor explicitly (rc=$rc)" "[[ $rc -eq 6 ]] && grep -q '^status=expired$' <<<\"\$out\""
out="$(af events --since "bogus-1:0")"; rc=$?
check "foreign token expires too (rc=$rc)" "[[ $rc -eq 6 ]]"
printf '{"session_id":"s-1","hook_event_name":"Stop","prompt_id":"p2"}' | hook 'done' "$SOCK" claude
check "a fresh log gets a new token" "[[ \"\$(head -1 '$EV')\" != \"\$(head -1 '$EV.1')\" ]]"

# --- receipt extraction pinned to real payload shapes ---
# codex-cli 0.165.0's UserPromptSubmit (keys in its real order; prompt last)
# and the same keys reordered: the prompt is found by key, not by position.
cx="$(tx new-window -d -P -F '#{pane_id}' -t t: "sleep 300")"; sleep 0.3; stop_daemon
TMUX_PANE="$cx" bash "$HOOK" start "$SOCK" codex <<<'{"session_id":"01a19b51-401d-7c70-8cd5-06c874f61d0e","transcript_path":"/h/.codex/sessions/2026/11/02/rollout-x.jsonl","cwd":"/w","hook_event_name":"SessionStart","model":"gpt-6.1-sol","permission_mode":"default","source":"startup"}'
TMUX_PANE="$cx" bash "$HOOK" working "$SOCK" codex <<<'{"session_id":"01a19b51-401d-7c70-8cd5-06c874f61d0e","turn_id":"01a19b51-6190-7052-88f0-a7e58c25633f","transcript_path":"/h/.codex/sessions/2026/11/02/rollout-x.jsonl","cwd":"/w","hook_event_name":"UserPromptSubmit","model":"gpt-6.1-sol","permission_mode":"default","prompt":"Reply with exactly: BETA"}'
TMUX_PANE="$cx" bash "$HOOK" working "$SOCK" codex <<<'{"session_id":"01a19b51-401d-7c70-8cd5-06c874f61d0e","turn_id":"t-reordered","prompt":"say \"hi\" \\ there","transcript_path":"/h/x.jsonl","cwd":"/w","hook_event_name":"UserPromptSubmit"}'
sha_b="$(printf '%s' 'Reply with exactly: BETA' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64)"
sha_r="$(printf '%s' 'say \"hi\" \\ there' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64)"
check "codex receipt: turn_id + sha of the real payload's prompt" "grep -q '^s [0-9]* 01a19b51-6190-7052-88f0-a7e58c25633f $sha_b$' '$CACHE/panes/$cx.turns'"
check "prompt found by key when it is not the last field" "grep -q '^s [0-9]* t-reordered $sha_r$' '$CACHE/panes/$cx.turns'"
check "codex SessionStart yields the session file" "[[ \"\$(cat '$CACHE/panes/$cx.session')\" == 01a19b51-401d-7c70-8cd5-06c874f61d0e ]]"

# --- interrupt ---
out="$(af interrupt "$ap")"; rc=$?
check "idle pane refused (rc=$rc): $out" "[[ $rc -eq 1 ]] && grep -q 'reason=not_working' <<<\"\$out\""
printf 'working\n' > "$CACHE/panes/$ap.status"
out="$(af interrupt "$ap")"; rc=$?
check "working claude pane: Escape sent, no receipt claimed (rc=$rc): $out" "[[ $rc -eq 4 ]] && grep -q 'status=sent pane=$ap reason=no_native_receipt' <<<\"\$out\""
check "interrupt is journaled as an event" "grep -q ' $ap interrupt$' '$EV'"
cp="$(tx new-window -d -P -F '#{pane_id}' -t t: "sleep 300")"; sleep 0.3; stop_daemon
tx set-option -p -t "$cp" @fleet-agent-kind codex; printf 'working\n' > "$CACHE/panes/$cp.status"
out="$(af interrupt "$cp")"; rc=$?
check "codex refused: no interrupt capability (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'reason=no_interrupt_capability' <<<\"\$out\""
out="$(af interrupt 'devbox/%3')"; rc=$?
check "remote refused (rc=$rc)" "[[ $rc -eq 1 ]]"

# --- kill --wait ---
kp="$(tx new-window -d -P -F '#{pane_id}' -t t: "bash -c 'sleep 300 & sleep 300 & echo \$\$ > $WORK/tree.pid; wait'")"
wait_for 10 "[[ -s '$WORK/tree.pid' ]]"; sleep 0.3
out="$(af kill "$kp" --wait 5)"; rc=$?
check "tree killed with evidence (rc=$rc): $out" "[[ $rc -eq 0 ]] && grep -q 'status=stopped processes=[3-9]' <<<\"\$out\""
check "killed event names no survivor" "grep -q ' $kp killed none$' '$EV'"
# A descendant that ignores the hangup survives the pane: the kill is unknown.
# (The survivor records its own pid so the cleanup below kills exactly it.)
sp="$(tx new-window -d -P -F '#{pane_id}' -t t: "bash -c 'trap \"\" HUP TERM; echo \$\$ > $WORK/outer.pid; (trap \"\" HUP TERM; echo \$BASHPID > $WORK/survivor.pid; exec sleep 300) & sleep 300'")"
wait_for 10 "[[ -s '$WORK/survivor.pid' && -s '$WORK/outer.pid' ]]"
reap() {  # the HUP-immune tree is this test's own: reap it whatever the checks said
  local o; o="$(cat "$WORK/outer.pid" 2>/dev/null)"
  [[ -n "$o" ]] && { pkill -9 -P "$o" 2>/dev/null; kill -9 "$o" 2>/dev/null; }
  kill -9 "$(cat "$WORK/survivor.pid" 2>/dev/null)" 2>/dev/null
  return 0
}
trap 'reap; _lib_cleanup' EXIT
out="$(af kill "$sp" --wait 1)"; rc=$?
check "survivor makes the kill unknown, not stopped (rc=$rc): $out" "[[ $rc -eq 4 ]] && grep -q 'status=unknown processes=[0-9]* alive=' <<<\"\$out\""
check "…and the survivor is named" "grep -q \"alive=.*\$(cat '$WORK/survivor.pid')\" <<<\"\$out\""
reap
out="$(af kill '%999' --wait 1 2>/dev/null)"; rc=$?
check "a missing target is a failed kill, never stopped (rc=$rc): $out" "[[ $rc -ne 0 ]] && ! grep -q 'status=stopped' <<<\"\$out\""
wn="$(tx new-window -d -P -F '#{window_index}' -t t: 'sleep 300')"
pk="$(af kill "t:$wn" 2>&1)"
check "plain kill is unchanged: $pk" "[[ \"\$pk\" == 'killed window t:$wn' ]]"

exit "$FAIL"
