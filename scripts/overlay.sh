#!/usr/bin/env bash
# overlay.sh — claude --settings overlay generators, shared by the CLI
# (ensure_hook_settings / ensure_sandbox_settings) and persist-restore, which
# REGENERATES a purged sandbox overlay from the task record rather than
# silently relaunching a sandbox-rung task unsandboxed. Sourced, not executed.

# The hooks JSON block — one source of truth. The sandbox overlay is a
# superset of the hooks overlay so a single --settings flag carries both;
# emitting this from one place keeps the two from silently diverging when a
# hook is added (it happened for codex support).
_overlay_hooks_block() {  # <hook-script> <socket>
  local hook="$1" sock="$2"
  cat <<JSON
  "hooks": {
    "SessionStart":     [ { "hooks": [ { "type": "command", "command": "'$hook' start $sock claude" } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "'$hook' working $sock claude" } ] } ],
    "PreToolUse":       [ { "matcher": "*", "hooks": [ { "type": "command", "command": "'$hook' working $sock claude" } ] } ],
    "Notification":     [ { "hooks": [ { "type": "command", "command": "'$hook' wait $sock claude" } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "command": "'$hook' done $sock claude" } ] } ]
  }
JSON
}

overlay_write_hooks() {  # <file> <hook-script> <socket>
  { echo '{'; _overlay_hooks_block "$2" "$3"; echo '}'; } > "$1"
}

# Hooks + Claude Code's native bash sandbox (Seatbelt/bubblewrap), writes
# scoped to one root. failIfUnavailable is deliberate: if the OS sandbox
# breaks past the spawn-time pre-check, claude refuses to start — visible in
# the pane — rather than silently running unsandboxed while the task record
# claims the sandbox rung. Callers guard the root against control characters
# (they would make the JSON unparseable, disabling that very backstop).
overlay_write_sandbox() {  # <file> <hook-script> <socket> <write-root>
  local p="${4//\\/\\\\}"; p="${p//\"/\\\"}"   # JSON-escape: backslash first
  {
    echo '{'
    _overlay_hooks_block "$2" "$3"
    cat <<JSON
  ,
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "autoAllowBashIfSandboxed": true,
    "filesystem": { "allowWrite": [ "$p" ] }
  }
}
JSON
  } > "$1"
}
