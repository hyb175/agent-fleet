#!/usr/bin/env bash
# t-history.sh — task history view (#10).
#   - `task history` (alias `history`) lists finished tasks from records alone:
#     outcome from the state walk (last merged/abandoned wins, cleaned never
#     overrides, pr when nothing terminal landed), duration, wait totals
#   - grouped per day of completion, newest first, with n tasks / n merged
#   - live non-terminal tasks are excluded; dead ones show abandoned~ (never
#     lost), including after a server restart
# Records are fabricated at FIXED epochs and read with TZ=UTC, so every date,
# duration, and count asserted here is deterministic on any machine.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-history:"
af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
TASKS="$CACHE/tasks"

check "no records at all: empty message" "[[ \"\$(af task history)\" == '(no completed tasks)' ]]"

mkrec() {  # <tid> <created> <intent> <dir> <pane>; state lines on stdin
  { printf 'id %s\nintent %s\ndir %s\nkind claude\ncreated %s\npane %s\n' \
      "$1" "$3" "$4" "$2" "$5"
    cat
  } > "$TASKS/$1"
}
mkdir -p "$TASKS"

# Day 1 = 2023-11-14 UTC. Ended epochs all fall 10:46–11:06 UTC — no boundary.
mkrec t100-1 1699956000 'fix parser' /repos/myrepo %90 <<'EOF'
state working 1699956000
state wait 1699956600
state working 1699957200
state merged 1699959600
EOF
mkrec t101-2 1699956100 'dead end idea' /repos/myrepo %91 <<'EOF'
state working 1699956100
state abandoned 1699959300
EOF
mkrec t102-3 1699956200 'open a pr' /repos/other %92 <<'EOF'
state working 1699956200
state pr 1699960000
EOF
mkrec t103-4 1699956300 'merged then cleaned' /repos/myrepo %93 <<'EOF'
state merged 1699959000
state cleaned 1699959100
EOF
mkrec t104-5 1699956400 'killed mid-flight' /repos/myrepo %94 <<'EOF'
state working 1699956400
EOF
# Day 0 = 2023-11-13 UTC; created two days before it merged.
mkrec t105-6 1699700000 'long haul' /repos/myrepo %95 <<'EOF'
state working 1699700000
state merged 1699872800
EOF
# Corrupt epochs must not poison the math: a garbage wait epoch would close
# against 1970 (decades of wait); a garbage merged epoch would file the row
# under 1970-01-01. Both fall back instead.
mkrec t108-9 1699956700 'corrupt wait line' /repos/myrepo %96 <<'EOF'
state wait garbage
state working 1699957200
state merged 1699959600
EOF
mkrec t109-0 1699956800 'corrupt merge epoch' /repos/myrepo %97 <<'EOF'
state working 1699956900
state merged oops
EOF
touch "$TASKS/t999-9.tmp.123"   # crashed-rewrite leftover: must be skipped

out="$(TZ=UTC af task history)"
check "day header counts tasks and merges"  "grep -qx '2023-11-14  7 tasks, 4 merged' <<<\"\$out\""
check "second day gets its own header"      "grep -qx '2023-11-13  1 tasks, 1 merged' <<<\"\$out\""
check "merged: outcome, 1h duration, w:10m" "grep -Eq 't100-1 +merged +1h w:10m +myrepo +fix parser' <<<\"\$out\""
check "abandoned outcome listed"            "grep -Eq 't101-2 +abandoned ' <<<\"\$out\""
check "pr counts as an outcome"             "grep -Eq 't102-3 +pr ' <<<\"\$out\""
check "cleaned never overrides merged"      "grep -Eq 't103-4 +merged ' <<<\"\$out\""
check "killed without outcome: abandoned~"  "grep -Eq 't104-5 +abandoned~ +0s' <<<\"\$out\""
check "durations past a day use the d unit" "grep -Eq 't105-6 +merged +2d' <<<\"\$out\""
check "corrupt wait epoch: no decades total" "grep -Eq 't108-9 +merged +48m -' <<<\"\$out\""
check "corrupt merge epoch: no 1970 header"  "! grep -q '1970-01-01' <<<\"\$out\""
check "corrupt merge epoch: best-signal day" "grep -Eq 't109-0 +merged ' <<<\"\$out\""
check "newest completion first"             "[[ \"\$(sed -n '2p' <<<\"\$out\")\" == *t102-3* ]]"
# shellcheck disable=SC2034 # read inside the eval'd check() condition below
d1r="$(grep -n 't104-5' <<<"$out" | cut -d: -f1)"
# shellcheck disable=SC2034
d2h="$(grep -n '2023-11-13' <<<"$out" | cut -d: -f1)"
check "older day grouped after newer day"   "(( d2h > d1r ))"
check "top-level history alias matches"     "[[ \"\$(TZ=UTC af history)\" == \"\$out\" ]]"
check "unexpected arg refused"              "! af task history --nope 2>/dev/null"

# --- live non-terminal task: current work, not history; dead = abandoned~ ---
boot_server __boot__ "$WORK"
wp="$(tx list-panes -t __boot__ -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
tx set-option -p -t "$wp" @fleet-task t106-7
mkrec t106-7 1699956500 'still running' /repos/myrepo "$wp" <<'EOF'
state working 1699956500
EOF
# Sent-back-after-PR with a LIVE agent = current work; the same record with
# the pane gone = a finished pr (an open PR is still the outcome).
tx new-session -d -s s2 -c "$WORK"
wp2="$(tx list-panes -t s2 -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"
tx set-option -p -t "$wp2" @fleet-task t107-8
mkrec t107-8 1699956600 'pr then sent back' /repos/other "$wp2" <<'EOF'
state working 1699956600
state pr 1699958000
state working 1699958500
EOF
out="$(TZ=UTC af task history)"
check "live non-terminal task excluded" "! grep -q 't106-7' <<<\"\$out\""
check "live agent resumed after pr excluded" "! grep -q 't107-8' <<<\"\$out\""
tx kill-server 2>/dev/null; sleep 0.3
out="$(TZ=UTC af task history)"
check "after restart the record survives as abandoned~" "grep -Eq 't106-7 +abandoned~' <<<\"\$out\""
check "dead resumed-after-pr task settles as pr" "grep -Eq 't107-8 +pr ' <<<\"\$out\""

exit "$FAIL"
