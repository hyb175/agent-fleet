#!/usr/bin/env bash
# t-isolation.sh — isolation ladder.
#   - rung resolution: --isolation flag > AGENT_FLEET_ISOLATION env > repo
#     .agent-fleet file > global config file > host; unknown rungs note + host
#   - sandbox rung: per-worktree settings overlay (hooks + sandbox superset,
#     writes scoped to the worktree, failIfUnavailable), record carries
#     isolation + sandboxfile, snapshot A-record grows the iso field
#   - degrades are VISIBLE and honest: non-claude agent -> worktree with a
#     note; container -> sandbox with a note; the record holds what ran
#   - persist-restore relaunches a sandbox task with its own overlay
# OS-sandbox deps are stubbed on PATH (bwrap/socat/sandbox-exec), so the
# available path is deterministic on both CI platforms.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-isolation:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"

REPODIR="$WORK/myrepo"
mkdir -p "$REPODIR"
git -C "$REPODIR" init -q -b main
git -C "$REPODIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Fake agent + stubbed sandbox deps: claude sleeps (panes stay alive); bwrap/
# socat/sandbox-exec exist so sandbox_available is true on Linux AND macOS.
FAKEBIN="$(mktemp -d)"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/fakedex"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/bwrap"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/socat"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/sandbox-exec"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/docker"    # daemon "down": container degrades here
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"

af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }
rec_of() { awk -v k="$1" '$1==k{sub("^"k" ",""); print; exit}' "$CACHE/tasks/$2"; }

# --- resolution precedence ---------------------------------------------------
out="$(af task "default rung probe" --repo "$REPODIR")"; T="${out%% *}"
check "no config anywhere: host" "[[ \"\$(rec_of isolation $T)\" == 'host' ]]"
check "host rung: no worktree"   "! grep -q '^worktree ' '$CACHE/tasks/$T'"

echo 'isolation worktree' > "$REPODIR/.agent-fleet"
out="$(af task "repo file probe" --repo "$REPODIR")"; T="${out%% *}"
check "repo .agent-fleet sets the rung" "[[ \"\$(rec_of isolation $T)\" == 'worktree' ]]"
check "worktree rung created a worktree" "grep -q '^worktree ' '$CACHE/tasks/$T'"

mkdir -p "$XDG_CONFIG_HOME/agent-fleet"
echo 'worktree' > "$XDG_CONFIG_HOME/agent-fleet/isolation"
rm -f "$REPODIR/.agent-fleet"
out="$(af task "global file probe" --repo "$REPODIR")"; T="${out%% *}"
check "global config file sets the rung" "[[ \"\$(rec_of isolation $T)\" == 'worktree' ]]"

echo 'isolation worktree' > "$REPODIR/.agent-fleet"
out="$(AGENT_FLEET_ISOLATION=host af task "env probe" --repo "$REPODIR")"; T="${out%% *}"
check "env beats the repo file" "[[ \"\$(rec_of isolation $T)\" == 'host' ]]"

out="$(AGENT_FLEET_ISOLATION=host af task "flag probe" --repo "$REPODIR" --isolation worktree)"; T="${out%% *}"
check "--isolation beats the env" "[[ \"\$(rec_of isolation $T)\" == 'worktree' ]]"

out="$(af task "legacy flag probe" --repo "$REPODIR" --no-isolated)"; T="${out%% *}"
check "--no-isolated still means host" "[[ \"\$(rec_of isolation $T)\" == 'host' ]]"
rm -f "$REPODIR/.agent-fleet" "$XDG_CONFIG_HOME/agent-fleet/isolation"

out="$(AGENT_FLEET_TASK_ISOLATED=1 af task "legacy env probe" --repo "$REPODIR")"; T="${out%% *}"
check "AGENT_FLEET_TASK_ISOLATED=1 still means worktree" "[[ \"\$(rec_of isolation $T)\" == 'worktree' ]]"

out="$(af task "bogus rung probe" --repo "$REPODIR" --isolation banana 2>"$WORK/bogus.err")"; T="${out%% *}"
check "unknown rung: note + host" \
  "grep -q 'unknown isolation' '$WORK/bogus.err' && [[ \"\$(rec_of isolation $T)\" == 'host' ]]"

# --- sandbox rung ------------------------------------------------------------
out="$(af task "sandboxed work" --repo "$REPODIR" --isolation sandbox)"; T="${out%% *}"; P="${out##* }"
check "record: isolation sandbox" "[[ \"\$(rec_of isolation $T)\" == 'sandbox' ]]"
check "sandbox includes a worktree" "grep -q '^worktree ' '$CACHE/tasks/$T'"
# shellcheck disable=SC2034 # SBF/WT/starts/allstarts read inside eval'd check() conditions
SBF="$(rec_of sandboxfile "$T")"
# shellcheck disable=SC2034
WT="$(rec_of worktree "$T")"
check "record: sandboxfile recorded" "[[ -f \"\$SBF\" ]]"
check "overlay: sandbox enabled"     "grep -q '\"enabled\": true' \"\$SBF\""
check "overlay: refuses to run unsandboxed" "grep -q '\"failIfUnavailable\": true' \"\$SBF\""
check "overlay: bash auto-allowed"   "grep -q '\"autoAllowBashIfSandboxed\": true' \"\$SBF\""
check "overlay: writes scoped to the worktree" "grep -qF \"\$WT\" \"\$SBF\""
check "overlay: hooks ride along"    "grep -q 'agent-status-hook.sh' \"\$SBF\""
# shellcheck disable=SC2034
starts="$(tx display-message -p -t "$P" '#{pane_start_command}')"
check "agent launched with the sandbox overlay" "grep -qF \"\$SBF\" <<<\"\$starts\""
check "overlay lives in the fleet cache, not ~/.claude" "[[ \"\$SBF\" == \"$CACHE/\"* ]]"

# Snapshot A-record: iso short code in field 11 (fields grow at the END).
poll_until 10 "grep -q 'sbx' '$CACHE/fleet.snapshot'"
check "snapshot carries iso=sbx" \
  "awk -F'|' -v p='$P' '/^A /{if (\$5==p && \$11==\"sbx\") ok=1} END{exit !ok}' '$CACHE/fleet.snapshot'"

# --- visible degrades --------------------------------------------------------
out="$(AGENT_FLEET_CMD=fakedex af task "not claude" --repo "$REPODIR" --isolation sandbox 2>"$WORK/deg1.err")"; T="${out%% *}"
check "non-claude agent: claude-only note" "grep -q 'claude-only' '$WORK/deg1.err'"
check "non-claude agent: record says worktree" "[[ \"\$(rec_of isolation $T)\" == 'worktree' ]]"

out="$(af task "no docker here" --repo "$REPODIR" --isolation container 2>"$WORK/deg2.err")"; T="${out%% *}"
check "container without docker: note" "grep -q 'docker is not available' '$WORK/deg2.err'"
check "container without docker: degrades to sandbox" "[[ \"\$(rec_of isolation $T)\" == 'sandbox' ]]"

# Missing OS deps -> worktree with a note. Linux-only: macOS Seatbelt is
# built-in, so the deps-missing branch is unreachable there in reality too.
# A curated symlink dir (every tool EXCEPT bwrap/socat, plus the fake claude)
# lets the probe run on hosts that DO have bubblewrap installed.
if [[ "$(uname -s)" == "Linux" ]]; then
  LINKDIR="$(mktemp -d)"
  declare -A _seen=()
  for tool in bash sh tmux git awk grep sed sort head tail cut tr cat rm mv \
              mkdir mktemp basename dirname cksum stat uname env sleep; do
    d="$(dirname "$(command -v "$tool" 2>/dev/null || echo /nonexistent/x)")"
    [[ -d "$d" && -z "${_seen[$d]:-}" ]] || continue
    _seen[$d]=1
    ln -s "$d"/* "$LINKDIR"/ 2>/dev/null || true
  done
  rm -f "$LINKDIR/bwrap" "$LINKDIR/socat"
  ln -sf "$FAKEBIN/claude" "$LINKDIR/claude"
  out="$(PATH="$LINKDIR" af task "no sandbox deps" --repo "$REPODIR" --isolation sandbox 2>"$WORK/deg3.err")"; T="${out%% *}"
  check "missing deps: note names bubblewrap + socat" "grep -q 'bubblewrap + socat' '$WORK/deg3.err'"
  check "missing deps: record says worktree" "[[ \"\$(rec_of isolation $T)\" == 'worktree' ]]"
  rm -rf "$LINKDIR"
fi

# --- restore keeps the rung --------------------------------------------------
"$REPO/scripts/persist-save.sh"
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"
poll_until 20 "tx list-panes -a -F '#{pane_start_command}' 2>/dev/null | grep -c 'claude'"
# shellcheck disable=SC2034
allstarts="$(tx list-panes -a -F '#{pane_start_command}')"
check "restore relaunches with the sandbox overlay" "grep -qF \"\$SBF\" <<<\"\$allstarts\""

# Purged cache: restore REGENERATES the overlay from the record rather than
# silently relaunching unsandboxed under a record that still says sandbox.
tx kill-server; sleep 0.4
rm -f "$SBF"
"$REPO/scripts/persist-restore.sh"
poll_until 10 "[[ -f '$SBF' ]]"
check "purged overlay regenerated on restore" "[[ -f \"\$SBF\" ]]"
check "regenerated overlay still scopes the worktree" "grep -qF \"\$WT\" \"\$SBF\""

rm -rf "$FAKEBIN"
exit "$FAIL"
