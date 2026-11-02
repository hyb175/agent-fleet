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
out="$(af send "$bp" "$msg" --op op1 --wait 10)"; rc=$?
check "same op, other pane: target conflict naming the original pane (rc=$rc): $out" \
  "[[ $rc -eq 2 ]] && grep -q 'status=refused pane=$ap reason=target_conflict' <<<\"\$out\""
check "…nothing typed into the other pane" "[[ ! -s '$WORK/b.out' ]]"

# --- concurrent retries with one op: exactly one paste, both see the receipt ---
af send "$ap" "race me" --op op11 --wait 10 > "$WORK/r1.out" & r1=$!
af send "$ap" "race me" --op op11 --wait 10 > "$WORK/r2.out" & r2=$!
wait "$r1"; rc1=$?; wait "$r2"; rc2=$?
check "both racers report the delivery (rc=$rc1/$rc2): $(cat "$WORK/r1.out" "$WORK/r2.out" | tr '\n' ' ')" \
  "[[ $rc1 -eq 0 && $rc2 -eq 0 ]] && grep -q 'prompt_id=p2' '$WORK/r1.out' && grep -q 'prompt_id=p2' '$WORK/r2.out'"
check "…and the agent received the text exactly once" "[[ \$(grep -c '^race me$' '$WORK/a.out') -eq 1 ]]"
check "…one claim holder wrote the record once" "[[ \$(grep -c '^consumed ' '$STATE/deliveries/op11') -eq 1 ]]"
wait_for 5 "grep -q '^e [0-9]* p2$' '$CACHE/panes/$ap.turns'"

# --- a human typing into the session: refused before anything is pasted ---
hw="$(tx new-window -P -F '#{window_id}' -t t: 'cat')"      # current window: keystrokes land here
hc="$(tx new-window -d -P -F '#{pane_id}' -t t: "env -u TMUX tmux -L '$SOCK' attach -t t")"
wait_for 5 "[[ \$(tx list-clients -t t | wc -l) -ge 1 ]]"
# attaching stamps the activity clock too; let that age out so the refusal below proves the keystroke
wait_for 5 "(( \$(date +%s) - \$(tx display-message -p -t $ap '#{session_activity}') >= 2 ))"
tx send-keys -t "$hc" 'z'; sleep 0.3
out="$(af send "$ap" "over a human" --op op12 --wait 2)"; rc=$?
check "keystrokes from a client refuse the send (rc=$rc): $out" "[[ $rc -eq 1 ]] && grep -q 'status=refused pane=$ap reason=human_active' <<<\"\$out\""
check "…nothing journaled, nothing typed" "[[ ! -e '$STATE/deliveries/op12' && \$(wc -l < '$WORK/a.out') -eq 2 ]]"
out="$(af send "$ap" "over a human" --op op12 --wait 2 --idle 0)"; rc=$?
check "--idle 0 waives the gate (rc=$rc): $out" "[[ $rc -eq 0 ]] && grep -q 'prompt_id=p3' <<<\"\$out\""
tx kill-window -t "$hc"; tx kill-window -t "$hw"
wait_for 5 "grep -q '^e [0-9]* p3$' '$CACHE/panes/$ap.turns'"

# --- mismatch: half-typed human input (older than --idle, so the activity
# gate cannot see it) merges with the delivery ---
sleep 2.1
tx send-keys -t "$ap" -l -- 'half typed '
sleep 0.3
out="$(af send "$ap" "Reply BETA" --op op2 --wait 2)"; rc=$?
check "merged prompt is a mismatch, not a delivery (rc=$rc): $out" "[[ $rc -eq 5 ]] && grep -q 'status=mismatch' <<<\"\$out\""
check "the agent saw the merged text" "[[ \"\$(tail -1 '$WORK/a.out')\" == 'half typed Reply BETA' ]]"
out="$(af send --status op2)"; rc=$?
check "--status keeps mismatch (rc=$rc)" "[[ $rc -eq 5 ]]"
# mismatch is reported at the UserPromptSubmit receipt; let that turn's Stop
# land before the status-file manipulation below.
wait_for 5 "grep -q '^e [0-9]* p4$' '$CACHE/panes/$ap.turns'"

# --- composer_busy: text already sitting in the prompt box is refused before
# the paste; the dim placeholder hint is not text. Screens are the bytes real
# claude 2.1.316 / codex 0.165.0 panes produced under capture-pane -e.
cat > "$WORK/screen" <<'FIX'
#!/usr/bin/env bash
case "$1" in
  claude-busy)  printf '\033[38;5;244m\342\224\200\342\224\200\342\224\200\n\033[39m\342\235\257\302\240 half typed\n  second line\n\033[38;5;244m\342\224\200\342\224\200\342\224\200\n\033[39m  \033[38;5;220mauto mode on\033[39m\n' ;;
  claude-empty) printf '\033[38;5;244m\342\224\200\342\224\200\342\224\200\n\033[39m\342\235\257\302\240 \033[2mTry\033[0m \033[2m"how does <filepath> work?"\033[0m\n\033[38;5;244m\342\224\200\342\224\200\342\224\200\n\033[39m  auto mode on\n' ;;
  codex-busy)   printf '\033[1m\342\200\272\033[0m half typed\n  GPT default \302\267 /x\n' ;;
  codex-empty)  printf '\033[1m\342\200\272\033[0m \033[2mAsk Codex to do anything\033[0m\n  GPT default \302\267 /x\n  \033[1m?\033[0m for shortcuts\n' ;;
  claude-dim2)  printf '\342\235\257\302\240 \033[2;38;5;244mTry "x"\033[0m\n\342\224\200\342\224\200\n' ;;   # dim folded into one SGR
  claude-glyph) printf '\342\235\257\302\240 see \342\200\272\n\342\224\200\342\224\200\n' ;;                        # a draft ending in a marker glyph
esac
exec cat
FIX
chmod +x "$WORK/screen"
fixture() {  # <screen> <kind> -> pane id, tagged like a hooked agent
  local p; p="$(tx new-window -d -P -F '#{pane_id}' -t t: "$WORK/screen $1")"
  tx set-option -p -t "$p" @fleet-agent-kind "$2"; printf 'sess-%s\n' "$1" > "$CACHE/panes/$p.session"
  wait_for 5 "tx capture-pane -p -t $p | grep -Eq 'half typed|Try|Ask Codex|see'"; printf '%s' "$p"
}
for k in claude codex; do
  fb="$(fixture "$k-busy" "$k")"; fe="$(fixture "$k-empty" "$k")"
  out="$(af send "$fb" "over a draft" --op "opb-$k" --wait 1)"; rc=$?
  check "$k: typed text in the composer refuses before the paste (rc=$rc): $out" "[[ $rc -eq 1 ]] && grep -q 'reason=composer_busy' <<<\"\$out\" && [[ ! -e '$STATE/deliveries/opb-$k' ]]"
  out="$(af send "$fe" "over a hint" --op "ope-$k" --wait 1)"; rc=$?
  check "$k: the dim placeholder hint is not a draft (rc=$rc): $out" "[[ $rc -eq 4 ]] && grep -q 'status=unconfirmed' <<<\"\$out\" && [[ -f '$STATE/deliveries/ope-$k' ]]"
done
fd="$(fixture claude-dim2 claude)"; fg="$(fixture claude-glyph claude)"
out="$(af send "$fd" "over a hint" --op opd --wait 1)"; rc=$?
check "dim folded into a combined SGR is still the hint (rc=$rc): $out" "[[ $rc -eq 4 ]] && [[ -f '$STATE/deliveries/opd' ]]"
out="$(af send "$fg" "over a draft" --op opg --wait 1)"; rc=$?
check "a draft ending in a marker glyph is still a draft (rc=$rc): $out" "[[ $rc -eq 1 ]] && grep -q 'reason=composer_busy' <<<\"\$out\""

# --- busy / waiting: nothing sent. The snapshot (a tick stale) says done;
# the hook-written status file says working — the fresher file wins.
printf 'T %s 1\nA ws|@1|1|a|%s|claude|done|1|-|x\n' "$(date +%s)" "$ap" > "$CACHE/fleet.snapshot"
printf 'working\n' > "$CACHE/panes/$ap.status"
out="$(af send "$ap" "while busy" --op op3)"; rc=$?
check "busy agent: status=busy, rc 3 (got $rc): $out" "[[ $rc -eq 3 ]] && grep -q 'status=busy' <<<\"\$out\""
check "…no journal, nothing typed" "[[ ! -e '$STATE/deliveries/op3' && \$(wc -l < '$WORK/a.out') -eq 4 ]]"
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
