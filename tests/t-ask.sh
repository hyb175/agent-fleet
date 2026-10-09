#!/usr/bin/env bash
# t-ask.sh — ask-human: an agent pushes its question into the inbox.
#   - the verb writes the question sidecar, flips the pane to wait, appends
#     question + state lines to the task record, and notifies
#   - snapshotd carries the question as the A-record's trailing field,
#     | scrubbed; question-less rows read '-'
#   - the status hook retires the question when the agent leaves wait
#   - gc prunes sidecars of dead panes; flatten/cap/usage guards hold
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-ask:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"

FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
NLOG="$WORK/notify.log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$NLOG" > "$FAKEBIN/terminal-notifier"
cp "$FAKEBIN/terminal-notifier" "$FAKEBIN/notify-send"
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"

af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }

mkdir -p "$WORK/a"
out="$(af task "migrate the db" --repo "$WORK/a")"
T="${out%% *}"; P="${out##* }"
REC="$CACHE/tasks/$T"
sleep 0.4

# --- the verb ----------------------------------------------------------------
# TMUX= on every call: the suite may itself run inside someone's tmux, and
# ask-human refuses foreign sockets (tested below) — an empty TMUX with a
# TMUX_PANE is exactly the container shape, which must work.
TMUX='' TMUX_PANE="$P" af ask-human "Drop the legacy|users table? One-way door." >/dev/null
check "question sidecar written (literal text kept)" \
  "[[ \"\$(cat '$CACHE/panes/$P.question')\" == 'Drop the legacy|users table? One-way door.' ]]"
check "pane flipped to wait" "grep -qx wait '$CACHE/panes/$P.status'"
check "record keeps the question" "grep -q '^question Drop the legacy|users table' '$REC'"
check "record gains state wait" "grep '^state ' '$REC' | tail -1 | grep -q '^state wait '"
check "notification carries the ask" "grep -q 'asks: Drop the legacy' '$NLOG'"

# Re-ask while already waiting: no duplicate state line.
TMUX='' TMUX_PANE="$P" af ask-human "second thoughts?" >/dev/null
check "no duplicate adjacent wait state" "[[ \"\$(grep -c '^state wait ' '$REC')\" == 1 ]]"

# Snapshot: trailing field carries the question, | scrubbed.
poll_until 10 "grep -q 'second thoughts?' '$CACHE/fleet.snapshot'"
check "snapshot carries the question" \
  "awk -F'|' -v p='$P' '/^A /{if (\$5==p && \$14==\"second thoughts?\") ok=1} END{exit !ok}' '$CACHE/fleet.snapshot'"
TMUX='' TMUX_PANE="$P" af ask-human "pipes | in | questions" >/dev/null
poll_until 10 "grep -q 'pipes ¦ in ¦ questions' '$CACHE/fleet.snapshot'"
check "| scrubbed in the snapshot field" "grep -q '|pipes ¦ in ¦ questions\$' '$CACHE/fleet.snapshot'"

# --- the hook lifecycle around the ask ---------------------------------------
# The asking turn ENDS right after the post: Stop (done) must not bury the
# question — the sidecar pins the pane in wait. Mid-turn tool events must not
# retire it either; only a prompt submission (the answer arriving) does.
hookP() {  # <state> ; event JSON on stdin
  TMUX_PANE="$P" AF_TASK_PRESPAWNED=1 AGENT_FLEET_NOTIFY=0 XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/scripts/agent-status-hook.sh" "$1" "$SOCK" claude
}
printf '{"hook_event_name":"Stop","session_id":"q-1"}' | hookP 'done'
check "Stop after asking: pane STAYS wait" "grep -qx wait '$CACHE/panes/$P.status'"
check "question survives the asking turn's end" "[[ -e '$CACHE/panes/$P.question' ]]"
printf '{"hook_event_name":"PreToolUse","session_id":"q-1"}' | hookP working
check "mid-turn tool use does not retire the question" "[[ -e '$CACHE/panes/$P.question' ]]"
printf '{"hook_event_name":"Stop","session_id":"q-1"}' | hookP 'done'
check "a later Stop still defers to the live question" "grep -qx wait '$CACHE/panes/$P.status'"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"q-1"}' | hookP working
check "the answer arriving retires the question" "[[ ! -e '$CACHE/panes/$P.question' ]]"
poll_until 10 "awk -F'|' -v p='$P' '/^A /{if (\$5==p && \$14==\"-\") ok=1} END{exit !ok}' '$CACHE/fleet.snapshot'"
check "snapshot question field back to -" \
  "awk -F'|' -v p='$P' '/^A /{if (\$5==p && \$14==\"-\") ok=1} END{exit !ok}' '$CACHE/fleet.snapshot'"
printf '{"hook_event_name":"Stop","session_id":"q-1"}' | hookP 'done'
check "Stop with no live question writes done normally" "grep -qx done '$CACHE/panes/$P.status'"

# --- guards -------------------------------------------------------------------
check "empty question refused" "! af ask-human 2>/dev/null"
check "outside a pane refused" "! TMUX_PANE= af ask-human 'hi' 2>/dev/null"
check "foreign tmux socket refused" \
  "! TMUX=/tmp/tmux-0/other,1,0 TMUX_PANE='$P' af ask-human 'hi' 2>/dev/null"
TMUX='' TMUX_PANE="$P" af ask-human unquoted words still arrive whole >/dev/null
check "unquoted words joined, not truncated" \
  "grep -qx 'unquoted words still arrive whole' '$CACHE/panes/$P.question'"
esc_q="$(printf 'paint\033]0;pwned\007me')"
TMUX='' TMUX_PANE="$P" af ask-human "$esc_q" >/dev/null
check "control bytes stripped before the TUI" "grep -qx 'paint]0;pwnedme' '$CACHE/panes/$P.question'"
TMUX='' TMUX_PANE="$P" af ask-human "same question" >/dev/null
TMUX='' TMUX_PANE="$P" af ask-human "same question" >/dev/null
check "identical re-ask does not grow the record" \
  "[[ \"\$(grep -c '^question same question\$' '$REC')\" == 1 ]]"
long="$(printf 'x%.0s' $(seq 1 400))"
TMUX='' TMUX_PANE="$P" af ask-human "$long" >/dev/null
check "question capped at 300" "(( $(wc -c < "$CACHE/panes/$P.question") < 320 ))"
nl_q="$(printf 'line1\nline2')"
TMUX='' TMUX_PANE="$P" af ask-human "$nl_q" >/dev/null
check "newlines flattened" "grep -qx 'line1 line2' '$CACHE/panes/$P.question'"

# gc prunes a dead pane's sidecar.
printf 'orphan?\n' > "$CACHE/panes/%999.question"
bash "$REPO/scripts/status.sh" gc >/dev/null 2>&1
check "gc prunes dead-pane questions" "[[ ! -e '$CACHE/panes/%999.question' ]]"

rm -rf "$FAKEBIN"
exit "$FAIL"
