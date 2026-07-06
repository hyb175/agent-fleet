#!/usr/bin/env bash
# t-connect.sh — the connect view's candidate list.
#   - dirs zoxide has never seen (fresh clones, untouched siblings) are
#     DISCOVERED via project roots: auto-derived from known repos' parents,
#     or explicit AGENT_FLEET_PROJECT_ROOTS
#   - frecent entries rank before discovered ones; repos before plain dirs
#   - hidden-component children are filtered; a repo is never used as a root
#   - `agent-fleet connect <dir>` feeds the dir back into zoxide
# Uses a private zoxide DB (_ZO_DATA_DIR); skips if zoxide isn't installed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-connect:"
command -v zoxide >/dev/null 2>&1 || { echo "  SKIP: zoxide not installed"; exit 0; }
export _ZO_DATA_DIR="$WORK/zo"; mkdir -p "$_ZO_DATA_DIR"

# Layout: root/ with a visited repo, an unvisited repo, a plain dir, a hidden
# child, and a repo-with-subdir (must not become a root).
mkdir -p "$WORK/root/visited_repo/.git" "$WORK/root/unvisited_repo/.git" \
         "$WORK/root/plain_dir" "$WORK/root/.hidden" \
         "$WORK/root/visited_repo/subdir"
zoxide add "$WORK/root/visited_repo"

rows() {  # emit the connect keys in order (cwd row excluded)
  AGENT_FLEET_ROOT="$REPO" XDG_CACHE_HOME="$XDG_CACHE_HOME" bash -c \
    'cd /; source "'"$REPO"'/scripts/status.sh"; source "'"$REPO"'/scripts/pick.sh"; prep_glyphs; list_connect' \
    2>/dev/null | cut -f1 | grep -v "^CONNECT:/$"
}

# auto-derived root (parent of visited_repo)
out="$(rows)"
check "frecent repo listed" "grep -q 'CONNECT:$WORK/root/visited_repo\$' <<<'$out'"
check "unvisited sibling repo DISCOVERED" "grep -q 'CONNECT:$WORK/root/unvisited_repo\$' <<<'$out'"
check "unvisited plain dir discovered" "grep -q 'CONNECT:$WORK/root/plain_dir\$' <<<'$out'"
check "hidden child filtered" "! grep -q '.hidden' <<<'$out'"
check "repo subdir NOT treated as project" "! grep -q 'visited_repo/subdir' <<<'$out'"
check "frecent repo ranks above discovered repo" \
  "[[ \$(grep -nxF 'CONNECT:$WORK/root/visited_repo' <<<'$out' | cut -d: -f1) -lt \$(grep -nxF 'CONNECT:$WORK/root/unvisited_repo' <<<'$out' | cut -d: -f1) ]]"

# explicit roots override
mkdir -p "$WORK/other/proj_x/.git"
out="$(AGENT_FLEET_PROJECT_ROOTS="$WORK/other" rows)"
check "explicit AGENT_FLEET_PROJECT_ROOTS scanned" "grep -q 'CONNECT:$WORK/other/proj_x\$' <<<'$out'"
check "explicit roots replace auto-derived" "! grep -q 'unvisited_repo' <<<'$out'"

# connect feeds zoxide
boot_server seed "$WORK"
mkdir -p "$WORK/root/fleet_only"
"$REPO/bin/agent-fleet" connect "$WORK/root/fleet_only" >/dev/null 2>&1 || true
check "connect registers the dir in zoxide" "zoxide query -l | grep -q 'root/fleet_only\$'"
exit $FAIL
