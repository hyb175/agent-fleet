#!/usr/bin/env bash
# t-prompt.sh — prompted names never touch sh.
#   - a typed $(...) is NOT executed (it becomes a literal, sanitized name)
#   - apostrophes in names and directories work end to end
# Exercises the same command shape the Prefix C / Prefix W bindings run,
# via the @fleet-prompt option + `agent-fleet _prompt` round-trip.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
AF="$REPO/bin/agent-fleet"

echo "t-prompt:"
mkdir -p "$WORK/don's dir"
boot_server tgt "$WORK/don's dir"
wp="$(tx list-panes -t tgt -F '#{pane_id} #{?@fleet-sidenav,1,0}' | awk '$2 != "1" {print $1; exit}')"

# injection attempt
CANARY="$WORK/pwned"
rm -f "$CANARY"
tx set -g @fleet-prompt "\$(touch $CANARY)"
tx run-shell -t "$wp" "'$AF' add --new-workspace \"\$('$AF' _prompt)\" --cmd bash --dir #{q:pane_current_path} >/dev/null"
sleep 0.5
check "typed \$(...) is NOT executed" "[[ ! -e '$CANARY' ]]"
made="$(tx list-sessions -F '#{session_name}' | grep -v '^tgt$' | head -1)"
check "workspace created with literal sanitized name (got: $made)" "[[ -n '$made' && '$made' == *touch* ]]"

# apostrophe name + apostrophe cwd (menu path uses #{q:pane_current_path})
tx set -g @fleet-prompt "don's work"
tx run-shell -t "$wp" "'$AF' add --new-workspace \"\$('$AF' _prompt)\" --cmd bash --dir #{q:pane_current_path} >/dev/null"
sleep 0.5
check "apostrophe workspace name works" "tx has-session -t \"=don's_work\" 2>/dev/null"
cwd="$(tx list-panes -t "don's_work" -F '#{?@fleet-sidenav,1,0}|#{pane_current_path}' | awk -F'|' '$1=="0"{print $2; exit}')"
check "agent landed in the apostrophe dir (got: $cwd)" "[[ \"\$cwd\" == *\"don's dir\" ]]"
exit $FAIL
