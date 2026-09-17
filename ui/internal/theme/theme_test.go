package theme

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const root = "../../.."

func TestEveryShippedPresetHasNineSlots(t *testing.T) {
	files, err := filepath.Glob(filepath.Join(root, "conf", "themes", "*.sh"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no presets: %v", err)
	}
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), ".sh")
		th, err := Load(root, name)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if th.Name != name {
			t.Fatalf("%s loaded as %s (fell back)", name, th.Name)
		}
		for _, v := range []string{th.BG, th.Surface, th.HL, th.FG, th.Muted, th.Accent, th.Wait, th.Working, th.Done} {
			if len(v) != 7 || v[0] != '#' {
				t.Fatalf("%s: bad slot %q", name, v)
			}
		}
	}
}

func TestTokyoNightValues(t *testing.T) {
	th, err := Load(root, "tokyo-night")
	if err != nil {
		t.Fatal(err)
	}
	if th.BG != "#1a1b26" || th.Accent != "#7aa2f7" || th.Wait != "#f7768e" {
		t.Fatalf("tokyo-night: %+v", th)
	}
}

func TestUnknownPresetFallsBack(t *testing.T) {
	th, err := Load(root, "no-such-theme")
	if err != nil || th.Name != Default {
		t.Fatalf("got %+v, %v", th, err)
	}
	if _, err := Load(t.TempDir(), "anything"); err == nil {
		t.Fatal("a root with no presets at all must error")
	}
}

func TestNamePrecedence(t *testing.T) {
	cfg := t.TempDir()
	os.MkdirAll(filepath.Join(cfg, "agent-fleet"), 0o755)
	os.WriteFile(filepath.Join(cfg, "agent-fleet", "theme"), []byte("kanagawa-dragon\n"), 0o644)
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if n := Name(env(map[string]string{"AGENT_FLEET_THEME": "dracula", "XDG_CONFIG_HOME": cfg})); n != "dracula" {
		t.Fatalf("env must win, got %s", n)
	}
	if n := Name(env(map[string]string{"XDG_CONFIG_HOME": cfg})); n != "kanagawa-dragon" {
		t.Fatalf("config file must be second, got %s", n)
	}
	if n := Name(env(map[string]string{"XDG_CONFIG_HOME": t.TempDir()})); n != Default {
		t.Fatalf("no file must default, got %s", n)
	}
}
