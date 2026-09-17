// Package theme resolves and loads the fleet palette the way scripts/theme.sh
// does, so the Go surfaces and the bash ones paint the same nine colors.
//
// Resolution: AGENT_FLEET_THEME (one-shot env override), then the persisted
// choice in $XDG_CONFIG_HOME/agent-fleet/theme (written by `agent-fleet
// theme <name>`), then tokyo-night. An unknown or unreadable preset falls
// back to tokyo-night rather than failing: a bad theme must never take the
// rail down.
package theme

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Default is the preset used when nothing else resolves.
const Default = "tokyo-night"

// Theme is the fleet's nine semantic color slots, as "#rrggbb".
type Theme struct {
	Name    string
	BG      string // rail / status-bar background
	Surface string // borders, message background
	HL      string // selected-row background
	FG      string // primary text
	Muted   string // subtitles, headers, idle
	Accent  string // selection, active tab, popup border
	Wait    string // agent needs you
	Working string // agent working
	Done    string // agent finished
}

var (
	assign = regexp.MustCompile(`^AF_THEME_([A-Z]+)="(#[0-9a-fA-F]{6})"`)
	slots  = []string{"BG", "SURFACE", "HL", "FG", "MUTED", "ACCENT", "WAIT", "WORKING", "DONE"}
)

// Name resolves the preset name without touching the presets directory.
func Name(getenv func(string) string) string {
	if n := getenv("AGENT_FLEET_THEME"); n != "" {
		return n
	}
	cfg := getenv("XDG_CONFIG_HOME")
	if cfg == "" {
		home := getenv("HOME")
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		cfg = filepath.Join(home, ".config")
	}
	b, err := os.ReadFile(filepath.Join(cfg, "agent-fleet", "theme"))
	if err != nil {
		return Default
	}
	if n := strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0]); n != "" {
		return n
	}
	return Default
}

// Load parses conf/themes/<name>.sh under root. A missing or incomplete
// preset falls back to Default; if even that is unreadable the error is
// returned and the caller should paint without color.
func Load(root, name string) (Theme, error) {
	if t, err := parse(filepath.Join(root, "conf", "themes", name+".sh")); err == nil {
		t.Name = name
		return t, nil
	}
	t, err := parse(filepath.Join(root, "conf", "themes", Default+".sh"))
	if err != nil {
		return Theme{}, err
	}
	t.Name = Default
	return t, nil
}

// Resolve is Name then Load.
func Resolve(root string, getenv func(string) string) (Theme, error) {
	return Load(root, Name(getenv))
}

func parse(path string) (Theme, error) {
	f, err := os.Open(path)
	if err != nil {
		return Theme{}, err
	}
	defer f.Close()
	got := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := assign.FindStringSubmatch(sc.Text()); m != nil {
			got[m[1]] = strings.ToLower(m[2])
		}
	}
	if err := sc.Err(); err != nil {
		return Theme{}, err
	}
	for _, s := range slots {
		if got[s] == "" {
			return Theme{}, fmt.Errorf("theme %s: missing AF_THEME_%s", path, s)
		}
	}
	return Theme{
		BG: got["BG"], Surface: got["SURFACE"], HL: got["HL"], FG: got["FG"], Muted: got["MUTED"],
		Accent: got["ACCENT"], Wait: got["WAIT"], Working: got["WORKING"], Done: got["DONE"],
	}, nil
}
