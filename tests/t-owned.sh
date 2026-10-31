#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AF="$REPO/bin/agent-fleet"

echo 't-owned:'
owned_check() {
  local label="$1"; shift
  if "$@"; then echo "  PASS: $label"; else echo "  FAIL: $label"; FAIL=1; fi
}
# shellcheck disable=SC2329 # invoked through owned_check
focused_help() { [[ "$out" == 'Usage: agent-fleet owned'* ]]; }
# shellcheck disable=SC2329 # invoked through owned_check
fixture_result() { [[ "$out" == *'"status":"fixture"'* ]]; }
# shellcheck disable=SC2329 # invoked through owned_check
manual_unchanged() {
  [[ -f "$XDG_CACHE_HOME/agent-fleet/tasks/manual" && ! -e "$XDG_CACHE_HOME/agent-fleet/$SOCK/tasks" ]]
}
mkdir -p "$WORK/driver dir" "$XDG_CACHE_HOME/agent-fleet/tasks"
printf 'manual sentinel\n' > "$XDG_CACHE_HOME/agent-fleet/tasks/manual"
cat > "$WORK/driver dir/driver" <<'DRIVER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$OWNED_ARGV"
cat > "$OWNED_INPUT"
printf '{"protocol_version":1,"status":"fixture"}\n'
exit "${OWNED_EXIT:-0}"
DRIVER
chmod +x "$WORK/driver dir/driver"
export OWNED_ARGV="$WORK/argv" OWNED_INPUT="$WORK/input"
export TMUX_BIN="$WORK/forbidden-tmux"
cat > "$TMUX_BIN" <<'TMUX'
#!/usr/bin/env bash
printf 'unexpected tmux call\n' >> "$OWNED_TMUX_CALLS"
exit 97
TMUX
chmod +x "$TMUX_BIN"
export OWNED_TMUX_CALLS="$WORK/tmux-calls"

out="$("$AF" owned --help 2>&1)"; rc=$?
owned_check 'owned help succeeds' test "$rc" -eq 0
owned_check 'owned help is focused' focused_help
for action in launch inspect answer stop; do
  # shellcheck disable=SC2016 # shell syntax is intentionally literal JSON data
  out="$(printf '{"operation_id":"literal $() `text`"}\n' | "$AF" owned --driver "$WORK/driver dir/driver" "$action" 2>&1)"; rc=$?
  owned_check "$action succeeds" test "$rc" -eq 0
  owned_check "$action preserves driver result" fixture_result
  printf '%s\n' --fleet-socket "$SOCK" --fleet-cache "$XDG_CACHE_HOME/agent-fleet/$SOCK" "$action" > "$WORK/expected"
  owned_check "$action passes exact scoped identity and action" cmp -s "$OWNED_ARGV" "$WORK/expected"
  # shellcheck disable=SC2016 # shell syntax is intentionally literal JSON data
  printf '{"operation_id":"literal $() `text`"}\n' > "$WORK/expected-input"
  owned_check "$action preserves JSON stdin literally" cmp -s "$OWNED_INPUT" "$WORK/expected-input"
done
OWNED_EXIT=23 "$AF" owned --driver "$WORK/driver dir/driver" inspect </dev/null >/dev/null 2>&1; rc=$?
owned_check 'driver failure status is forwarded' test "$rc" -eq 23
for args in 'launch' '--driver relative inspect' '--driver /nonexistent inspect' '--driver /nonexistent unknown'; do
  # shellcheck disable=SC2086 # intentional splitting of fixed invalid argument fixtures
  "$AF" owned $args </dev/null >/dev/null 2>&1; rc=$?
  owned_check "invalid invocation fails: $args" test "$rc" -eq 2
done
"$AF" owned --driver "$WORK/driver dir/driver" inspect --driver /other </dev/null >/dev/null 2>&1; rc=$?
owned_check 'extra options are rejected before driver' test "$rc" -eq 2
owned_check 'owned path never calls tmux' test ! -e "$OWNED_TMUX_CALLS"
owned_check 'owned path never migrates manual task state' manual_unchanged
exit "$FAIL"
