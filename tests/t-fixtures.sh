#!/usr/bin/env bash
# t-fixtures.sh — the snapshot contract (docs/snapshot-format.md).
#   - every fixture in tests/fixtures/snapshot renders through the bash
#     readers (picker, inbox, triage jump) without error
#   - a fixture with one extra trailing A field renders identically
#   - the picker's order for mixed.snapshot matches mixed.picker-order, the
#     same file the Go parser's test asserts
#   - the live daemon writes A records with exactly the documented field
#     count and sentinels, so the fixtures describe what it really emits
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-fixtures:"
FIX="$REPO/tests/fixtures/snapshot"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"
SNAPF="$CACHE/fleet.snapshot"
mkdir -p "$CACHE/panes" "$CACHE/tasks"

picker() {  # <fixture> -> list_fleet rows (stderr kept, for the error check)
  cp "$FIX/$1" "$SNAPF"
  AGENT_FLEET_ROOT="$REPO" AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" bash -c \
    'source "'"$REPO"'/scripts/status.sh"; source "'"$REPO"'/scripts/pick.sh"; prep_glyphs; list_fleet' 2>&1
}
inbox_rows() {
  cp "$FIX/$1" "$SNAPF"
  AGENT_FLEET_ROOT="$REPO" AGENT_FLEET_SOCKET="$SOCK" XDG_CACHE_HOME="$XDG_CACHE_HOME" bash "$REPO/scripts/inbox.sh" --rows 2>&1
}

# Fixtures are a fixed clock; readers compare T against now. Rewrite T to now
# on the way in (stale.snapshot is the exception, tested below) so a healthy
# fixture never trips the stale banner.
fresh() {  # <fixture> -> path of a copy whose T is now
  local out="$WORK/${1%.snapshot}.fresh.snapshot"
  awk -v now="$(date +%s)" '/^T /{$2=now} {print}' "$FIX/$1" > "$out"
  printf '%s' "$out"
}
for f in "$FIX"/*.snapshot; do
  name="$(basename "$f")"
  [[ "$name" == stale.snapshot ]] && continue
  cp "$(fresh "$name")" "$FIX/.tmp.$name"
  out="$(picker ".tmp.$name")"; rc=$?
  check "picker renders $name (rc=$rc)" "[[ $rc -eq 0 ]] && ! grep -qi 'error\\|unbound\\|stale' <<<\"\$out\""
  out="$(inbox_rows ".tmp.$name")"; rc=$?
  check "inbox renders $name (rc=$rc)" "[[ $rc -eq 0 ]] && ! grep -qi 'error\\|unbound' <<<\"\$out\""
  rm -f "$FIX/.tmp.$name"
done

# Extra trailing field: identical rendering.
cp "$(fresh mixed.snapshot)" "$FIX/.tmp.a"; cp "$(fresh extra-field.snapshot)" "$FIX/.tmp.b"
# shellcheck disable=SC2034 # read inside the eval'd check() condition
pa="$(picker .tmp.a)"
# shellcheck disable=SC2034
pb="$(picker .tmp.b)"
check "extra trailing A field renders identically in the picker" "[[ \"\$pa\" == \"\$pb\" ]]"
rm -f "$FIX/.tmp.a" "$FIX/.tmp.b"

# Picker order = the shared expectation file.
cp "$(fresh mixed.snapshot)" "$FIX/.tmp.m"
# shellcheck disable=SC2034
order="$(picker .tmp.m | grep '^PANE:' | cut -f1 | sed 's/^PANE://')"
rm -f "$FIX/.tmp.m"
check "picker order matches mixed.picker-order" "[[ \"\$order\" == \"\$(cat '$FIX/mixed.picker-order')\" ]]"

# Stale fixture trips the banner.
cp "$FIX/stale.snapshot" "$SNAPF"
# shellcheck disable=SC2034
st="$(picker stale.snapshot)"
check "stale T renders the stale banner" "grep -q 'stale' <<<\"\$st\""

# Live daemon: A records carry exactly the documented 12 fields, sentinels
# where a value is unknown, and the T record carries the interval.
boot_server t "$WORK"
PANES="$CACHE/panes"
hp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"
tx set-option -p -t "$hp" @fleet-agent-kind claude
printf 'wait\n' > "$PANES/$hp.status"
sp="$(tx split-window -d -P -F '#{pane_id}' -t t: 'sleep 60')"
tx set-option -p -t "$sp" @fleet-agent-kind codex
# The conf's own daemon (ensure hook) may already be running; either way one
# writer produces the file. Wait for both agents to appear.
wait_for 10 "grep -q '|$hp|' '$SNAPF' 2>/dev/null && grep -q '|$sp|' '$SNAPF' 2>/dev/null"
check "T record has epoch and interval" "grep -Eq '^T [0-9]+ [0-9]+$' '$SNAPF'"
check "every A record has 12 fields" "[[ -z \"\$(grep '^A ' '$SNAPF' | awk -F'|' 'NF!=12')\" ]]"
check "unknown values are the - sentinel (scrape-tier row)" "grep -Eq '^A [^|]*\\|[^|]*\\|[^|]*\\|[^|]*\\|$sp\\|codex~\\|[a-z]+\\|[0-9]+\\|-\\|-\\|-\\|-$' '$SNAPF'"
check "no raw | inside a field: field count is stable across rows" "[[ \"\$(grep '^A ' '$SNAPF' | awk -F'|' '{print NF}' | sort -u | wc -l | tr -d ' ')\" == '1' ]]"

exit "$FAIL"
