#!/usr/bin/env bash
# cs-connect.sh <codespace> [cmd...] — launch an agent inside a GitHub Codespace.
#
# Used as an agent window's command by `agent-fleet add --codespace`. It reaches
# the codespace's sshd (the devcontainers "sshd" feature, port 2222) by forwarding
# that port to a free local port with `gh codespace ports forward`, then SSHing in
# and running the agent so the remote process is this pane's foreground program.
#
# Why not `gh codespace ssh`? That uses GitHub's built-in SSH mechanism, which the
# container image must support; minimal images fail it ("failed to start SSH
# server"). The devcontainers sshd feature is a separate server on port 2222,
# reached over a forwarded port — which is what this wrapper drives.
#
# Status: the fleet's Claude hooks can't cross SSH (they'd fire inside the
# codespace, where $TMUX_PANE doesn't exist), so a codespace agent is tracked by
# the scrape tier in status.sh (capture-pane on the local pane, which shows the
# remote TUI). `agent-fleet add` tags the pane @fleet-agent-kind, so it still
# lists and scrapes.
#
# Env:
#   AGENT_FLEET_CS_SSH_PORT   sshd port inside the container   (default 2222)
#   AGENT_FLEET_CS_USER       ssh user                         (default dev)
#   AGENT_FLEET_CS_DIR        remote dir to cd into            (default: sole /workspaces/*)
#
# On any failure it prints the cause and drops to an interactive shell rather than
# exiting — a pane that dies would trip the reap hook and silently close the
# window.

set -uo pipefail

cs="${1:-}"
shift || true
cmd=( "$@" )
# read -ra, not a one-element array: AGENT_FLEET_CMD may be multi-word
# ("claude --verbose"), and %q-encoding a single element would ship it to the
# remote as one binary named "claude --verbose".
[[ ${#cmd[@]} -eq 0 ]] && read -ra cmd <<< "${AGENT_FLEET_CMD:-claude}"

REMOTE_PORT="${AGENT_FLEET_CS_SSH_PORT:-2222}"
SSH_USER="${AGENT_FLEET_CS_USER:-dev}"

red='\033[38;2;247;118;142m'; blue='\033[38;2;122;162;247m'
dim='\033[2m'; bold='\033[1m'; rst='\033[0m'

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-fleet"

fwd_pid=""; fwd_log=""; port_lock=""
cleanup() {
  [[ -n "$fwd_pid" ]] && kill "$fwd_pid" 2>/dev/null
  [[ -n "$fwd_log" ]] && rm -f "$fwd_log" 2>/dev/null
  # Only remove the lock if it is still OURS — after a takeover race another
  # connect may own a lock dir of the same name, and blindly removing it would
  # cascade the collision to a third connect.
  [[ -n "$port_lock" && "$(cat "$port_lock/pid" 2>/dev/null)" == "$$" ]] \
    && rm -rf "$port_lock" 2>/dev/null
}
trap cleanup EXIT
# Signals skip the EXIT trap by default; release the port lock and forward on
# an ordinary kill too. (kill -9 can't be caught — the dead-holder takeover in
# the port scan reclaims those locks.)
trap 'cleanup; trap - EXIT; exit 129' INT TERM HUP

drop_to_shell() {
  cleanup; trap - EXIT          # exec replaces us, so release the forward first
  printf '\n%b%s%b\n' "$red" "$1" "$rst" >&2
  printf '%bDropping to a shell in this pane. Ctrl-D to close.%b\n' "$dim" "$rst" >&2
  exec "${SHELL:-bash}" -i
}

# Can we open a TCP connection to 127.0.0.1:<port>? (i.e. is something listening)
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 2>/dev/null; return 0; }; return 1; }

[[ -n "$cs" ]] || drop_to_shell "cs-connect: no codespace name given"
command -v gh  >/dev/null 2>&1 || drop_to_shell "cs-connect: 'gh' (GitHub CLI) not found on PATH"
command -v ssh >/dev/null 2>&1 || drop_to_shell "cs-connect: 'ssh' not found on PATH"

# A free local port, RESERVED via an atomic per-port lock. The listener check
# alone races: the forward binds seconds after the scan, so two connects
# launched back-to-back would pick the same port — and the loser's readiness
# poll would see the winner's listener and SSH into the wrong codespace.
mkdir -p "$CACHE_DIR/ports" 2>/dev/null || true
local_port=""
for (( p = REMOTE_PORT; p < REMOTE_PORT + 64; p++ )); do
  port_open "$p" && continue
  lk="$CACHE_DIR/ports/$p.lock"
  if mkdir "$lk" 2>/dev/null; then
    echo $$ > "$lk/pid"
  else
    hp="$(cat "$lk/pid" 2>/dev/null)"
    if [[ -n "$hp" ]] && kill -0 "$hp" 2>/dev/null; then
      continue                     # live holder — try the next port
    fi
    if [[ -z "$hp" ]]; then
      # No pid yet: the holder may be between its mkdir and pid write. Give a
      # fresh dir grace instead of treating it as dead (that misread was a
      # takeover hole that let two connects share a port).
      lk_m="$(stat -c %Y "$lk" 2>/dev/null || stat -f %m "$lk" 2>/dev/null || echo 0)"
      printf -v now_s '%(%s)T' -1
      (( now_s - lk_m < 5 )) && continue
    fi
    # Dead/orphaned lock: take over via atomic rename — of N racers exactly one
    # wins the mv; rm+re-mkdir raced (B's rm could delete A's fresh lock).
    mv "$lk" "$lk.reap.$$" 2>/dev/null || continue
    rm -rf "$lk.reap.$$" 2>/dev/null
    mkdir "$lk" 2>/dev/null || continue
    echo $$ > "$lk/pid"
  fi
  port_lock="$lk"; local_port="$p"; break
done
[[ -n "$local_port" ]] || drop_to_shell "cs-connect: no free local port in ${REMOTE_PORT}–$(( REMOTE_PORT + 63 ))"

# Default remote dir: the codespace's own repo checkout under /workspaces. The
# /workspaces root often holds several repos, so a glob is wrong — resolve the
# repo from the codespace and target its checkout. --dir (AGENT_FLEET_CS_DIR)
# overrides; both fall back to /workspaces, then the login dir.
remote_dir="${AGENT_FLEET_CS_DIR:-}"
if [[ -z "$remote_dir" ]]; then
  repo="$(gh codespace list --json name,repository \
            -q ".[] | select(.name==\"$cs\") | .repository" 2>/dev/null)"
  [[ -n "$repo" ]] && remote_dir="/workspaces/${repo##*/}"
fi

# Build the remote command. Run it through a LOGIN shell (bash -lc) so the agent
# is on PATH — codespaces commonly install CLIs under ~/.local/bin, which a
# non-login ssh shell does not pick up. exec so the agent is the foreground
# process (a clean exit closes the window, like a local agent).
# %q per argument: the remote login shell re-parses the string, so a flat
# "${cmd[*]}" would word-split quoted arguments (e.g. --append-system-prompt
# "be terse" arriving as two words).
printf -v cmd_str '%q ' "${cmd[@]}"
if [[ -n "$remote_dir" ]]; then
  inner="cd ${remote_dir} 2>/dev/null || cd /workspaces 2>/dev/null || true; exec ${cmd_str}"
else
  inner="cd /workspaces 2>/dev/null || true; exec ${cmd_str}"
fi
inner="${inner//\'/\'\\\'\'}"     # escape single quotes for the remote login shell
remote="bash -lc '${inner}'"

printf '%b⇅ forwarding %s→localhost:%s, connecting to %b%s%b%b…%b\n' \
  "$blue" "$REMOTE_PORT" "$local_port" "$bold" "$cs" "$rst" "$blue" "$rst"
printf '%b(cold start may take ~30–60s)%b\n\n' "$dim" "$rst"

# gh ports forward syntax is <remote-port>:<local-port>. Background it (logging to
# a temp so failures are reportable); the trap tears it down when the agent exits.
fwd_log="$(mktemp -t af-cs-fwd.XXXXXX 2>/dev/null || echo "/tmp/af-cs-fwd.$$")"
gh codespace ports forward "${REMOTE_PORT}:${local_port}" -c "$cs" >"$fwd_log" 2>&1 &
fwd_pid=$!

# Wait until the local end accepts a connection (or the forward dies / we time out).
ready=""
for _ in $(seq 1 120); do          # ~60s at 0.5s/iter
  kill -0 "$fwd_pid" 2>/dev/null || break
  port_open "$local_port" && { ready=1; break; }
  sleep 0.5
done
[[ -n "$ready" ]] || drop_to_shell "cs-connect: port-forward to '$cs' never came up (codespace stopped? open it once in the browser). gh: $(tail -1 "$fwd_log" 2>/dev/null)"

# Connect. Throwaway host key — the forwarded localhost endpoint is per-session.
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -p "$local_port" -t "${SSH_USER}@localhost" "$remote"
rc=$?
[[ $rc -eq 0 ]] && exit 0

drop_to_shell "cs-connect: ssh to '$cs' ended (exit $rc). user='${SSH_USER}', container sshd port=${REMOTE_PORT} — override via AGENT_FLEET_CS_USER / AGENT_FLEET_CS_SSH_PORT."
