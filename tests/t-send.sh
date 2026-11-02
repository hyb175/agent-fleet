#!/usr/bin/env bash
# t-send.sh — `agent-fleet send`: journaled delivery with a native consumption
# receipt. A fake hooked claude (a read loop that fires the same hook events
# claude fires: SessionStart, UserPromptSubmit with prompt_id + prompt, Stop)
# stands in for the agent; the real-claude proof lives in docs/runtime-contract.md.
#   - intent is journaled under XDG_STATE_HOME before anything is typed
#   - consumed ⇒ exactly this text, by prompt_id; turn_ended once Stop lands
#   - replaying an --op never types again; same op + other text is a conflict
#   - busy / waiting / stale / remote / no-receipt-channel panes get nothing
#   - text merged with half-typed input is a mismatch, never a delivery
#   - a pane that consumes nothing stays unconfirmed, and stays so on --status
#   - the hash is JSON.stringify-compatible (pinned to a real event's bytes)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-send:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
STATE="$XDG_STATE_HOME/agent-fleet/$SOCK"
mkdir -p "$CACHE/panes"
af() { AGENT_FLEET_SOCKET="$SOCK" "$REPO/bin/agent-fleet" "$@"; }

# The fake agent: one hook event sequence per line read, like claude.
cat > "$WORK/fake-claude" <<'FAKE'
#!/usr/bin/env bash
# fake-claude <hook> <socket> <session> <outfile> [ok|silent] [claude|codex]
HOOK="$1" SOCK="$2" SID="$3" OUT="$4" MODE="${5:-ok}" KIND="${6:-claude}"
IDKEY=prompt_id; [[ "$KIND" == codex ]] && IDKEY=turn_id
printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/x"}' "$SID" | bash "$HOOK" start "$SOCK" "$KIND"
n=0
while IFS= read -r line; do
  n=$((n+1)); printf '%s\n' "$line" >> "$OUT"
  [[ "$MODE" == silent ]] && continue
  esc="${line//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//	/\\t}"
  printf '{"session_id":"%s","cwd":"/x","hook_event_name":"UserPromptSubmit","%s":"p%s","prompt":"%s"}' "$SID" "$IDKEY" "$n" "$esc" \
    | bash "$HOOK" working "$SOCK" "$KIND"
  sleep 0.3
  printf '{"session_id":"%s","cwd":"/x","hook_event_name":"Stop","%s":"p%s"}' "$SID" "$IDKEY" "$n" | bash "$HOOK" done "$SOCK" "$KIND"
done
FAKE
chmod +x "$WORK/fake-claude"
HOOK="$REPO/scripts/agent-status-hook.sh"

boot_server t "$WORK"
stop_daemon() {
  kill "$(cat "$CACHE/snapshotd.lock/pid" 2>/dev/null)" 2>/dev/null || true
  for _ in $(seq 1 30); do [[ -d "$CACHE/snapshotd.lock" ]] || break; sleep 0.2; done
}
spawn() {  # <session> <outfile> [ok|silent] [claude|codex] -> pane id, hook tier proven (.session present)
  local p
  p="$(tx new-window -d -P -F '#{pane_id}' -t t: "$WORK/fake-claude '$HOOK' '$SOCK' '$1' '$2' ${3:-ok} ${4:-claude}")"
  wait_for 10 "[[ -s '$CACHE/panes/$p.session' && \"\$(tx display-message -p -t $p '#{@fleet-agent-kind}')\" == ${4:-claude} ]]"
  printf '%s' "$p"
}
ap="$(spawn sess-a "$WORK/a.out")"
bp="$(spawn sess-b "$WORK/b.out" silent)"
stop_daemon
# No snapshot rows: state comes from the hook-written status files.
printf 'T %s 1\n' "$(date +%s)" > "$CACHE/fleet.snapshot"
check "fake agents proved hook tier (session files)" "[[ -s '$CACHE/panes/$ap.session' && -s '$CACHE/panes/$bp.session' ]]"
check "…and are tagged claude" "[[ \"\$(tx display-message -p -t $ap '#{@fleet-agent-kind}')\" == claude ]]"

# --- consumed: exact text, prompt_id, journal under XDG_STATE_HOME ---
msg='hello "quoted" back\slash and a tab	here;'
out="$(af send "$ap" "$msg" --op op1 --wait 10)"; rc=$?
check "send consumed (rc=$rc): $out" "[[ $rc -eq 0 ]] && grep -q 'status=\(consumed\|turn_ended\) pane=$ap prompt_id=p1' <<<\"\$out\""
check "the agent received exactly the text" "[[ \"\$(cat '$WORK/a.out')\" == \"\$msg\" ]]"
check "journal lives in XDG_STATE_HOME, not the cache" "[[ -f '$STATE/deliveries/op1' && ! -e '$CACHE/deliveries' ]]"
check "journal records recipient identity (session, pid) before the effect" \
  "grep -q '^session sess-a$' '$STATE/deliveries/op1' && grep -q '^pid [0-9]' '$STATE/deliveries/op1' && grep -q '^submitted ' '$STATE/deliveries/op1'"
wait_for 5 "grep -q '^e [0-9]* p1$' '$CACHE/panes/$ap.turns'"
out="$(af send --status op1)"; rc=$?
check "--status: turn ended (rc=$rc): $out" "[[ $rc -eq 0 ]] && grep -q 'status=turn_ended' <<<\"\$out\""

# --- idempotency ---
out="$(af send "$ap" "$msg" --op op1 --wait 10)"; rc=$?
check "replayed op reports the outcome (rc=$rc)" "[[ $rc -eq 0 ]] && grep -q 'status=turn_ended' <<<\"\$out\""
check "…and typed nothing again" "[[ \$(wc -l < '$WORK/a.out') -eq 1 ]]"
out="$(af send "$ap" "something else" --op op1 --wait 10)"; rc=$?
check "same op, other text: payload conflict (rc=$rc)" "[[ $rc -eq 2 ]] && grep -q 'reason=payload_conflict' <<<\"\$out\""
check "…nothing typed" "[[ \$(wc -l < '$WORK/a.out') -eq 1 ]]"

# --- mismatch: half-typed human input merges with the delivery ---
tx send-keys -t "$ap" -l -- 'half typed '
sleep 0.3
out="$(af send "$ap" "Reply BETA" --op op2 --wait 2)"; rc=$?
check "merged prompt is a mismatch, not a delivery (rc=$rc): $out" "[[ $rc -eq 5 ]] && grep -q 'status=mismatch' <<<\"\$out\""
check "the agent saw the merged text" "[[ \"\$(tail -1 '$WORK/a.out')\" == 'half typed Reply BETA' ]]"
out="$(af send --status op2)"; rc=$?
check "--status keeps mismatch (rc=$rc)" "[[ $rc -eq 5 ]]"
# mismatch is reported at the UserPromptSubmit receipt; let that turn's Stop
# land before the status-file manipulation below.
wait_for 5 "grep -q '^e [0-9]* p2$' '$CACHE/panes/$ap.turns'"

# --- busy / waiting: nothing sent. The snapshot (a tick stale) says done;
# the hook-written status file says working — the fresher file wins.
printf 'T %s 1\nA ws|@1|1|a|%s|claude|done|1|-|x\n' "$(date +%s)" "$ap" > "$CACHE/fleet.snapshot"
printf 'working\n' > "$CACHE/panes/$ap.status"
out="$(af send "$ap" "while busy" --op op3)"; rc=$?
check "busy agent: status=busy, rc 3 (got $rc): $out" "[[ $rc -eq 3 ]] && grep -q 'status=busy' <<<\"\$out\""
check "…no journal, nothing typed" "[[ ! -e '$STATE/deliveries/op3' && \$(wc -l < '$WORK/a.out') -eq 2 ]]"
printf 'T %s 1\n' "$(date +%s)" > "$CACHE/fleet.snapshot"
printf 'wait\n' > "$CACHE/panes/$ap.status"
out="$(af send "$ap" "while waiting" --op op4)"; rc=$?
check "waiting agent refused → use answer (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'reason=waiting_on_input' <<<\"\$out\""
printf 'done\n' > "$CACHE/panes/$ap.status"

# --- stale fingerprint ---
fp="$(af answer "$ap" fp)"
tx send-keys -t "$ap" -l -- 'x'; sleep 0.3
out="$(af send "$ap" "after change" --op op5 --fp "$fp")"; rc=$?
check "stale fp refused (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'reason=stale' <<<\"\$out\""
tx send-keys -t "$ap" C-u

# --- unconfirmed: the agent never reports consumption; never resent ---
out="$(af send "$bp" "into the void" --op op6 --wait 2)"; rc=$?
check "no receipt → unconfirmed, rc 4 (got $rc): $out" "[[ $rc -eq 4 ]] && grep -q 'status=unconfirmed' <<<\"\$out\""
check "…but it WAS typed once" "[[ \"\$(cat '$WORK/b.out')\" == 'into the void' ]]"
out="$(af send "$bp" "into the void" --op op6 --wait 1)"; rc=$?
check "replay of an unconfirmed op stays unconfirmed (rc=$rc)" "[[ $rc -eq 4 ]]"
check "…and is not resent" "[[ \$(wc -l < '$WORK/b.out') -eq 1 ]]"
# A crash between the keystrokes and the 'submitted' line leaves a journal
# that must still read as "maybe typed", never as "safe to resend".
sed -i.bak '/^submitted /d' "$STATE/deliveries/op6" && rm -f "$STATE/deliveries/op6.bak"
out="$(af send "$bp" "into the void" --op op6 --wait 1)"; rc=$?
check "journal without 'submitted' replays as unconfirmed/unknown (rc=$rc): $out" "[[ $rc -eq 4 ]] && grep -q 'status=unconfirmed .*reason=unknown' <<<\"\$out\""
check "…and still types nothing" "[[ \$(wc -l < '$WORK/b.out') -eq 1 ]]"
# …but a receipt that did land after the journal still confirms it.
sha6="$(awk '$1=="sha"{print $2}' "$STATE/deliveries/op6")"
printf 's %s pX %s\n' "$(date +%s)" "$sha6" >> "$CACHE/panes/$bp.turns"
out="$(af send --status op6)"; rc=$?
check "late receipt after a lost 'submitted' confirms consumption (rc=$rc): $out" "[[ $rc -eq 0 ]] && grep -q 'status=consumed .*prompt_id=pX' <<<\"\$out\""

# --- escaping pinned to a real UserPromptSubmit event's bytes ---
# claude 2.1.316 delivered the pasted text  line one⏎line two: Reply with exactly: GAMMA
# as "prompt":"line one\nline two: Reply with exactly: GAMMA" — the journal's
# sha must be the sha256 of that escaped form.
want="$(printf '%s' 'line one\nline two: Reply with exactly: GAMMA' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64)"
af send "$bp" $'line one\nline two: Reply with exactly: GAMMA' --op op7 --wait 1 >/dev/null
check "multi-line text hashes like the native event" "[[ \"\$(awk '\$1==\"sha\"{print \$2}' '$STATE/deliveries/op7')\" == '$want' ]]"

# --- no receipt channel: a plain shell pane, a remote pane ---
sp="$(tx new-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"; stop_daemon
out="$(af send "$sp" "to a shell" --op op8)"; rc=$?
check "untagged pane refused: no_receipt_channel (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'reason=no_receipt_channel' <<<\"\$out\""
out="$(af send 'devbox/%9' "remote" --op op9)"; rc=$?
check "remote pane refused (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'reason=remote' <<<\"\$out\""
out="$(af send --status nope)"; rc=$?
check "unknown op on --status (rc=$rc)" "[[ $rc -eq 1 ]] && grep -q 'reason=unknown_op' <<<\"\$out\""
af send "$ap" $'esc\e[2J' --op op10 >/dev/null 2>&1; rc=$?
check "control characters rejected before any effect (rc=$rc)" "[[ $rc -eq 2 && ! -e '$STATE/deliveries/op10' ]]"

# --- codex: same receipt channel, turn_id instead of prompt_id ---
cp="$(spawn sess-c "$WORK/c.out" ok codex)"; stop_daemon
out="$(af send "$cp" "codex hello" --op opc --wait 10)"; rc=$?
check "codex pane consumed by turn_id (rc=$rc): $out" "[[ $rc -eq 0 ]] && grep -q 'status=\(consumed\|turn_ended\) pane=$cp prompt_id=p1' <<<\"\$out\""
check "codex received the text" "[[ \"\$(cat '$WORK/c.out')\" == 'codex hello' ]]"

# --- capabilities ---
# shellcheck disable=SC2034 # read inside the eval'd check() conditions
caps="$(af capabilities)"
check "capabilities names the receipt channels and journal" "grep -q '^send_receipts=claude:hook codex:hook$' <<<\"\$caps\" && grep -q \"^send_journal=$STATE/deliveries$\" <<<\"\$caps\""
check "capabilities states the owned backend availability" "grep -q '^owned_backend_fleet=\(available\|unavailable\)$' <<<\"\$caps\""

exit "$FAIL"
