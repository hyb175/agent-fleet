#!/usr/bin/env bash
# t-container.sh — container rung (#12).
#   - default image: window command is `docker run --rm -it` with the worktree,
#     parent .git, fleet cache, scripts, and ~/.claude mounted at IDENTICAL
#     host paths; env passthrough; NET_ADMIN for the firewall; host uid/gid
#   - record carries isolation container + the container name; the pane is
#     kind-tagged claude (not docker) so restore knows what it holds
#   - devcontainer detection: repo devcontainer.json + CLI -> devcontainer
#     up/exec (no NET_ADMIN, no af-default)
#   - lifecycle: task done stops the named container
#   - restore leaves container tasks as shells (no silent host relaunch) until
#     container re-link (#13)
# All docker/devcontainer calls hit an argv-logging stub — hermetic on both CI
# platforms, no images, no daemon.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-container:"
CACHE="$XDG_CACHE_HOME/agent-fleet/$SOCK"

REPODIR="$WORK/crepo"
mkdir -p "$REPODIR"
git -C "$REPODIR" init -q -b main
git -C "$REPODIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

FAKEBIN="$(mktemp -d)"
DLOG="$WORK/docker.log"
# Stub docker: log argv; `info`/`image inspect` succeed (daemon "up", image
# "built"); `run` sleeps so the pane stays alive; everything else no-ops.
cat > "$FAKEBIN/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DLOG"
case "\$1" in
  run)  sleep 300 ;;
  ps)   echo cafe123 ;;
  *)    exit 0 ;;
esac
EOF
cat > "$FAKEBIN/devcontainer" <<EOF
#!/usr/bin/env bash
printf 'devcontainer %s\n' "\$*" >> "$DLOG"
case "\$1" in
  exec) sleep 300 ;;
  *)    exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"

af() { AGENT_FLEET_SOCKET="$SOCK" AGENT_FLEET_ROOT="$REPO" "$REPO/bin/agent-fleet" "$@"; }
rec_of() { awk -v k="$1" '$1==k{sub("^"k" ",""); print; exit}' "$CACHE/tasks/$2"; }

# --- default image path ------------------------------------------------------
out="$(af task "container job" --repo "$REPODIR" --isolation container)"
T="${out%% *}"; P="${out##* }"
check "record: isolation container" "[[ \"\$(rec_of isolation $T)\" == 'container' ]]"
# shellcheck disable=SC2034 # CN/WT read inside eval'd check() conditions
CN="$(rec_of container "$T")"
check "record: container name (af-<sock>-…)" "[[ \"\$CN\" == af-$SOCK-* ]]"
# shellcheck disable=SC2034
WT="$(rec_of worktree "$T")"
check "container rung still gets a worktree" "[[ -n \"\$WT\" ]]"
# shellcheck disable=SC2034 # read inside eval'd check() conditions
starts="$(tx display-message -p -t "$P" '#{pane_start_command}')"
check "pane runs docker run --rm -it"  "grep -q 'docker run --rm -it' <<<\"\$starts\""
check "container is named"             "grep -qF \"\$CN\" <<<\"\$starts\""
check "worktree mounted at same path"  "grep -qF -- \"\$WT:\$WT\" <<<\"\$starts\""
check "parent .git mounted (handback)" "grep -qF \"$REPODIR/.git:$REPODIR/.git\" <<<\"\$starts\""
check "fleet cache mounted (hooks)"    "grep -qF \"$CACHE:$CACHE\" <<<\"\$starts\""
check "scripts mounted ro"             "grep -qF \"$REPO/scripts:$REPO/scripts:ro\" <<<\"\$starts\""
check "TMUX_PANE passes through"       "grep -q -- '-e TMUX_PANE' <<<\"\$starts\""
check "host uid rides in"              "grep -q -- \"-e AF_UID=$(id -u)\" <<<\"\$starts\""
check "firewall gets NET_ADMIN"        "grep -q -- '--cap-add NET_ADMIN' <<<\"\$starts\""
check "default image, content-keyed tag" "grep -q ' af-default:v' <<<\"\$starts\""
check "docker run uses --init (zombie reaping)" "grep -q -- '--init' <<<\"\$starts\""
check "claude runs with the hooks overlay" "grep -q \"claude --settings\" <<<\"\$starts\""
check "pane kind-tagged claude, not docker" \
  "[[ \"\$(tx display-message -p -t $P '#{@fleet-agent-kind}')\" == 'claude' ]]"

# Snapshot shows the ctr badge.
poll_until 10 "grep -q '|ctr' '$CACHE/fleet.snapshot'"
check "snapshot iso=ctr" "awk -F'|' -v p='$P' '/^A /{if (\$5==p && \$11==\"ctr\") ok=1} END{exit !ok}' '$CACHE/fleet.snapshot'"

# --- lifecycle: terminal mark stops the container ---------------------------
af task 'done' "$T" >/dev/null
check "task done stopped the container" "grep -q \"stop -t 2 \$CN\" '$DLOG'"

# --- devcontainer detection --------------------------------------------------
mkdir -p "$REPODIR/.devcontainer"
echo '{"image":"whatever"}' > "$REPODIR/.devcontainer/devcontainer.json"
out="$(af task "devcontainer job" --repo "$REPODIR" --isolation container)"
T2="${out%% *}"; P2="${out##* }"
# shellcheck disable=SC2034
starts2="$(tx display-message -p -t "$P2" '#{pane_start_command}')"
check "devcontainer: up + exec used"   "grep -q 'devcontainer up' <<<\"\$starts2\" && grep -q 'devcontainer exec' <<<\"\$starts2\""
check "devcontainer: cache mounted"    "grep -qF \"source=$CACHE,target=$CACHE\" <<<\"\$starts2\""
check "devcontainer: parent .git mounted (handback)" "grep -qF \"source=$REPODIR/.git,target=$REPODIR/.git\" <<<\"\$starts2\""
check "devcontainer: OAuth token passes through" "grep -q 'CLAUDE_CODE_OAUTH_TOKEN' <<<\"\$starts2\""
check "devcontainer: no af-default"    "! grep -q 'af-default' <<<\"\$starts2\""
check "devcontainer: no NET_ADMIN (its config owns guarantees)" "! grep -q 'NET_ADMIN' <<<\"\$starts2\""
check "devcontainer: record still container" "[[ \"\$(rec_of isolation $T2)\" == 'container' ]]"
# shellcheck disable=SC2034
WT2DIR="$(rec_of dir "$T2")"
check "devcontainer: containerdir recorded" "[[ \"\$(rec_of containerdir $T2)\" == \"\$WT2DIR\" ]]"
af task 'done' "$T2" >/dev/null
check "devcontainer: done stops via workspace label" \
  "grep -q 'ps -q --filter label=devcontainer.local_folder=' '$DLOG' && grep -q 'stop -t 2 cafe123' '$DLOG'"
rm -rf "$REPODIR/.devcontainer"

# --- restore honesty: no silent host relaunch --------------------------------
"$REPO/scripts/persist-save.sh"
tx kill-server; sleep 0.4
"$REPO/scripts/persist-restore.sh"; sleep 0.8
# Every agent pane in this test is a container task — NOTHING may come back
# as a host claude (any 'claude' in a relaunch command = the honesty guard
# failed and an unboxed agent replaced a containerized one).
# shellcheck disable=SC2034
allstarts="$(tx list-panes -a -F '#{pane_start_command}')"
check "restore leaves container tasks as shells" "! grep -q 'claude' <<<\"\$allstarts\""
check "restore re-linked the record to its shell pane" \
  "tx list-panes -a -F '#{pane_id}' | grep -qx \"\$(rec_of pane $T2)\""
check "restore logged the discontinuity (state idle)" \
  "grep '^state ' '$CACHE/tasks/$T2' | tail -1 | grep -q '^state idle '"

rm -rf "$FAKEBIN"
exit "$FAIL"
