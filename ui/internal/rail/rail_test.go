package rail

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
)

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string { return ansi.ReplaceAllString(s, "") }

func load(t *testing.T, name string) *snapshot.Snapshot {
	t.Helper()
	f, err := os.Open("../../../tests/fixtures/snapshot/" + name)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s, err := snapshot.Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func view(t *testing.T, fixture string, win, sess string, h int) View {
	t.Helper()
	lipgloss.SetColorProfile(termenv.TrueColor)
	th, err := theme.Load("../../..", "tokyo-night")
	if err != nil {
		t.Fatal(err)
	}
	s := load(t, fixture)
	return View{Cfg: Config{Window: win, Session: sess, Theme: th, Width: 30, Height: h}, Snap: s, Now: s.Epoch + 1, Visible: true}
}

func TestParityLayout(t *testing.T) {
	out := plain(Render(view(t, "mixed.snapshot", "@2", "webapp", 0)))
	lines := strings.Split(out, "\n")
	want := []string{
		" spaces",
		"",
		" ✓ api",
		"   main",
		"▎ ◆ webapp", // selected workspace: bar on both lines
		"▎  feature/login ↑2",
		" · notes",
		"   notes",
		"",
		" agents                    all",
		"",
		" ⠋ review the login flow",
		"   webapp · claude",
		"▎ ◆ fix the flaky spec.1", // shared window: .pidx suffix, selected (window @2)
		"▎  webapp · claude · 4m",
		"▎ ○ fix-tests.2",
		"▎  webapp · codex~",
		" ◆ migrate the auth table",
		"   api · claude · 15m",
		" ✓ write the changelog",
		"   api · claude · 2h",
		" ✓ scratch",
		"   api · opencode · 30s",
		"",
		" prefix+o open · prefix+b hide",
	}
	for i, w := range want {
		if i >= len(lines) {
			t.Fatalf("line %d missing; got %d lines:\n%s", i, len(lines), out)
		}
		if strings.TrimRight(lines[i], " ") != w {
			t.Errorf("line %d\n got  %q\n want %q", i, strings.TrimRight(lines[i], " "), w)
		}
	}
	if len(lines) != len(want) {
		t.Errorf("got %d lines, want %d:\n%s", len(lines), len(want), out)
	}
	for _, l := range strings.Split(Render(view(t, "mixed.snapshot", "@2", "webapp", 0)), "\n") {
		if lipgloss.Width(l) > 30 {
			t.Errorf("line wider than the rail: %q", plain(l))
		}
	}
	// Selected rows are padded to the full width so the highlight bg spans the pane.
	for _, l := range strings.Split(Render(view(t, "mixed.snapshot", "@2", "webapp", 0)), "\n") {
		if strings.Contains(l, "▎") && lipgloss.Width(l) != 30 {
			t.Errorf("selected row not padded to width: %q (%d)", plain(l), lipgloss.Width(l))
		}
	}
}

func TestHighlightIsSelfDerived(t *testing.T) {
	a := plain(Render(view(t, "mixed.snapshot", "@5", "api", 0)))
	if !strings.Contains(a, "▎ ✓ api") || strings.Contains(a, "▎ ◆ webapp") {
		t.Fatalf("api rail must highlight api only:\n%s", a)
	}
	if !strings.Contains(a, "▎ ◆ migrate the auth table") || strings.Contains(a, "▎ ◆ fix the flaky spec") {
		t.Fatalf("api rail must highlight window @5 only:\n%s", a)
	}
}

func TestOverflowCountsTheRest(t *testing.T) {
	out := plain(Render(view(t, "mixed.snapshot", "@9", "none", 16)))
	// 16 rows: header, blank, 3 spaces rows (6), blank, header, blank = 11 lines
	// before agents; (16-11-3)/2 = 1 agent row, then "+5 more".
	if !strings.Contains(out, "review the login flow") || !strings.Contains(out, " +5 more (prefix+o)") {
		t.Fatalf("overflow:\n%s", out)
	}
	if strings.Contains(out, "fix the flaky spec") {
		t.Fatalf("second agent must be hidden behind the more-row:\n%s", out)
	}
}

func TestStaleBanner(t *testing.T) {
	v := view(t, "stale.snapshot", "@1", "webapp", 0)
	v.Now = 1789500000
	out := plain(Render(v))
	if !strings.Contains(out, "⚠ stale — daemon down?") {
		t.Fatalf("expected stale banner:\n%s", out)
	}
	v.Now = v.Snap.Epoch + 2
	if strings.Contains(plain(Render(v)), "stale") {
		t.Fatal("fresh snapshot must not show the banner")
	}
}

func TestEmptyStates(t *testing.T) {
	out := plain(Render(view(t, "empty.snapshot", "@0", "home", 0)))
	if !strings.Contains(out, "(no workspaces)") || !strings.Contains(out, "(no agents)") {
		t.Fatalf("empty states:\n%s", out)
	}
	if strings.Contains(out, "stale") {
		t.Fatal("empty fleet at a fresh T is not stale")
	}
}

func TestCJKTruncatesByCellWidth(t *testing.T) {
	v := view(t, "pipe-name.snapshot", "@1", "webapp", 0)
	v.Snap.Agents[0].Intent = "認証テーブルを移行してから統合テストを実行する"
	for _, l := range strings.Split(Render(v), "\n") {
		if w := lipgloss.Width(l); w > 30 {
			t.Fatalf("line wider than the rail (%d): %q", w, plain(l))
		}
	}
	if !strings.Contains(plain(Render(v)), "…") {
		t.Fatal("a long CJK title must be truncated with …")
	}
}

func TestAnimateNeedsVisibleAndWorking(t *testing.T) {
	v := view(t, "mixed.snapshot", "@2", "webapp", 0)
	if !v.Animate() {
		t.Fatal("visible + a working agent must animate")
	}
	v.Visible = false
	if v.Animate() {
		t.Fatal("hidden rail must not animate")
	}
	v = view(t, "remote-down.snapshot", "@1", "webapp", 0)
	if v.Animate() {
		t.Fatal("no working agent must not animate")
	}
}
