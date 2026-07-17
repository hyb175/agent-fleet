#!/usr/bin/env bash
# t-shim.sh — the claude PATH shim.
#   - hand-started `claude` (and `claude -r`) gets the hooks overlay added
#   - meta/non-interactive/explicit-settings/non-tmux invocations pass through
#   - the shim resolves the REAL claude (never itself)
#   - ensure_server_env injects the shims dir into the server PATH exactly
#     once, and new panes inherit it
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-shim:"
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/argv"
EOF
chmod +x "$FAKEBIN/claude"
OVERLAY_DIR="$XDG_CACHE_HOME/agent-fleet"; mkdir -p "$OVERLAY_DIR"
printf '{}\n' > "$OVERLAY_DIR/hooks-settings.json"
OVERLAY="$OVERLAY_DIR/hooks-settings.json"

run_shim() {  # [env VAR=...] -- args...
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
  rm -f "$WORK/argv"
  # $BASH's dir keeps `env bash` resolvable where bash isn't in /usr/bin:/bin (NixOS).
  env "${envs[@]}" PATH="$REPO/shims:$FAKEBIN:$(dirname "$BASH"):/usr/bin:/bin" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    bash "$REPO/shims/claude" "$@"
  cat "$WORK/argv" 2>/dev/null | tr '\n' ' '
}

got="$(run_shim TMUX_PANE=%9 -- )"
check "bare claude gets the overlay (got: $got)" "[[ '$got' == '--settings $OVERLAY ' ]]"
got="$(run_shim TMUX_PANE=%9 -- -r)"
check "claude -r gets the overlay + flag" "[[ '$got' == '--settings $OVERLAY -r ' ]]"
got="$(run_shim TMUX_PANE=%9 -- --resume abc123)"
check "claude --resume <id> gets the overlay" "[[ '$got' == '--settings $OVERLAY --resume abc123 ' ]]"
got="$(run_shim TMUX_PANE=%9 -- -p "hi there")"
check "print mode passes through untouched" "[[ '$got' == '-p hi there ' ]]"
got="$(run_shim TMUX_PANE=%9 -- --settings /tmp/mine.json)"
check "explicit --settings passes through (fleet-launched)" "[[ '$got' == '--settings /tmp/mine.json ' ]]"
got="$(run_shim TMUX_PANE= -- )"
check "outside a tmux pane: no overlay" "[[ '$got' == ' ' || -z '${got// /}' ]]"

# pane-shell launcher. Run with an explicit shim-free PATH so the assertions are
# deterministic even when the suite runs from inside a fleet pane (whose ambient
# PATH already carries the shim).
#
# Non-fish shells inherit our pre-exec PATH prepend. fish is special-cased: a
# plain prepend loses to fish rebuilding PATH from its own config, so pane-shell
# re-prepends AFTER config via --init-command (-C) instead.
BASE_PATH="/usr/bin:/bin"
cat > "$FAKEBIN/fakeshell" <<EOF
#!/usr/bin/env bash
printf '%s' "\$PATH" > "$WORK/shell_path"
EOF
chmod +x "$FAKEBIN/fakeshell"
env AGENT_FLEET_ROOT="$REPO" SHELL="$FAKEBIN/fakeshell" PATH="$BASE_PATH" bash "$REPO/scripts/pane-shell.sh"
check "non-fish shell inherits the shim prepend" "[[ \"\$(cat '$WORK/shell_path')\" == '$REPO/shims:'* ]]"
env AGENT_FLEET_ROOT="$REPO" SHELL="$FAKEBIN/fakeshell" PATH="$REPO/shims:$BASE_PATH" bash "$REPO/scripts/pane-shell.sh"
n="$(grep -o "$REPO/shims" "$WORK/shell_path" | grep -c . || true)"
check "no double-prepend (got $n)" "[[ '${n:-0}' == '1' ]]"
env AGENT_FLEET_ROOT="$REPO" SHELL="$FAKEBIN/fakeshell" AGENT_FLEET_SHIM=0 PATH="$BASE_PATH" bash "$REPO/scripts/pane-shell.sh"
check "AGENT_FLEET_SHIM=0 opts out" "[[ \"\$(cat '$WORK/shell_path')\" != '$REPO/shims:'* ]]"

# fish: pane-shell must hand it `-C "set -gx PATH <shim> $PATH"` (a pre-exec
# prepend would be undone by fish's config rebuild). Capture fish's argv.
cat > "$FAKEBIN/fish" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/fish_argv"
EOF
chmod +x "$FAKEBIN/fish"
env AGENT_FLEET_ROOT="$REPO" SHELL="$FAKEBIN/fish" PATH="$BASE_PATH" bash "$REPO/scripts/pane-shell.sh"
check "fish gets --init-command (-C)" "grep -qxF -- '-C' '$WORK/fish_argv'"
check "fish -C re-prepends the shim ahead of \$PATH" "grep -qF \"set -gx PATH '$REPO/shims' \\\$PATH\" '$WORK/fish_argv'"

# conf wires it as default-command; a real (command-less) pane runs it end to
# end. The property that matters: `claude` typed in that pane resolves to the
# SHIM (the login shell may legitimately prepend its own dirs; the shim only
# has to stay ahead of the real claude).
boot_server t "$WORK"
check "default-command is pane-shell" "[[ \"\$(tx show -gv default-command)\" == '$REPO/scripts/pane-shell.sh' ]]"
np="$(tx new-window -d -P -F '#{pane_id}' -t t:)"
sleep 2
tx send-keys -t "$np" "command -v claude > $WORK/which_claude" Enter
ok=0
for _ in $(seq 1 25); do
  [[ -s "$WORK/which_claude" ]] && { ok=1; break; }
  sleep 0.3
done
check "hand-typed claude resolves to the shim" "[[ $ok -eq 1 && \"\$(cat '$WORK/which_claude')\" == '$REPO/shims/claude' ]]"
rm -rf "$FAKEBIN"
exit $FAIL
