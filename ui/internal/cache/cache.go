// Package cache resolves the fleet's socket-scoped cache directory exactly
// like scripts/cache.sh: two fleets on different tmux sockets must never
// share state, so the socket name (sanitized) is a path component.
package cache

import (
	"os"
	"path/filepath"
	"regexp"
)

// DefaultSocket is the tmux socket name a fleet uses unless AGENT_FLEET_SOCKET says otherwise.
const DefaultSocket = "agent-fleet"

var unsafe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// Root is the shared parent: $XDG_CACHE_HOME/agent-fleet or ~/.cache/agent-fleet.
// Only theme.conf lives here directly; everything else is under Dir.
func Root(getenv func(string) string) string {
	base := getenv("XDG_CACHE_HOME")
	if base == "" {
		home := getenv("HOME")
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, "agent-fleet")
}

// Socket is the fleet's tmux socket name from the environment, defaulted.
func Socket(getenv func(string) string) string {
	if s := getenv("AGENT_FLEET_SOCKET"); s != "" {
		return s
	}
	return DefaultSocket
}

// Sanitize maps a socket name onto the character class cache.sh allows in
// the directory name; anything else becomes "_".
func Sanitize(socket string) string {
	return unsafe.ReplaceAllString(socket, "_")
}

// Dir is this fleet's scoped cache directory: Root/<sanitized socket>.
func Dir(getenv func(string) string) string {
	return filepath.Join(Root(getenv), Sanitize(Socket(getenv)))
}

// Snapshot is the path of the daemon's fleet.snapshot for this fleet.
func Snapshot(getenv func(string) string) string {
	return filepath.Join(Dir(getenv), "fleet.snapshot")
}

// FocusNow is the path of the "session|window_id" file the focus hook writes.
func FocusNow(getenv func(string) string) string {
	return filepath.Join(Dir(getenv), "focus.now")
}
