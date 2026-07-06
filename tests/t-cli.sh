#!/usr/bin/env bash
# t-cli.sh — CLI sharp edges.
#   - exact-match targets: `connect api` with only api-v2 running creates api;
#     `kill ap` refuses; `add --to api` lands in api (and in its cwd)
#   - `stop` survives a stale daemon pidfile AND never kills a recycled pid
#   - `back` with an empty focus.prev is a clean no-op
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AF="$REPO/bin/agent-fleet"

echo "t-cli:"
mkdir -p "$WORK/apidir"
boot_server api-v2 "$WORK"

# prefix-collision family
"$AF" connect api >/dev/null 2>&1 || true
check "connect api creates api (no prefix hijack)" "tx has-session -t '=api' 2>/dev/null"
check "api-v2 untouched" "tx has-session -t '=api-v2' 2>/dev/null"
"$AF" kill ap >/dev/null 2>&1; rc=$?
check "kill 'ap' refuses" "[[ $rc -ne 0 ]] && tx has-session -t '=api' 2>/dev/null && tx has-session -t '=api-v2' 2>/dev/null"

# add: right session AND right default dir (the =name: display-message fix)
tx kill-session -t api 2>/dev/null
tx new-session -d -s api -c "$WORK/apidir"; sleep 0.3
p="$("$AF" add --to api --cmd bash 2>/dev/null)"
check "add --to api lands in api" "[[ \"\$(tx display-message -p -t \"$p\" '#S')\" == api ]]"
cwd="$(tx display-message -p -t "$p" '#{pane_current_path}')"
check "add dir default = target session cwd (got $cwd)" "[[ '$cwd' == */apidir ]]"

# add --new-workspace (the picker's Alt-a 'spawn with agent' path): fresh
# session named for the repo, agent as its FIRST tab (placeholder removed),
# right cwd
p="$("$AF" add --new-workspace repo-x --cmd bash --dir "$WORK/apidir" 2>/dev/null)"
sleep 0.3
check "new-workspace session created" "tx has-session -t '=repo-x' 2>/dev/null"
check "agent is the only tab" "[[ \"\$(tx list-windows -t repo-x | wc -l | tr -d ' ')\" == 1 ]]"
check "agent cwd is the repo" "[[ \"\$(tx display-message -p -t \"$p\" '#{pane_current_path}')\" == */apidir ]]"

# back with empty prev
mkdir -p "$XDG_CACHE_HOME/agent-fleet"; : > "$XDG_CACHE_HOME/agent-fleet/focus.prev"
"$AF" back; check "back with empty prev is a clean no-op" "[[ $? -eq 0 ]]"

# stop: stale pidfile naming a live NON-daemon process
mkdir -p "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock"
sleep 300 & victim=$!
echo "$victim" > "$XDG_CACHE_HOME/agent-fleet/snapshotd.lock/pid"
out="$("$AF" stop 2>&1)"; rc=$?
check "stop succeeds ('$out')" "[[ $rc -eq 0 && '$out' == *'fleet stopped'* ]]"
check "server down" "! tx list-sessions >/dev/null 2>&1"
check "recycled pid NOT killed" "kill -0 $victim 2>/dev/null"
kill "$victim" 2>/dev/null
exit $FAIL
