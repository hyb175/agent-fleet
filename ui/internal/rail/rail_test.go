package rail

import (
	"os"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
		"   webapp · claude · wt",
		"▎ ◆ fix the flaky spec.1", // shared window: .pidx suffix, selected (window @2)
		"▎  webapp · claude · 4m · +31…",
		"▎ ○ fix-tests.2",
		"▎  webapp · codex~",
		" ◆ migrate the auth table",
		"   api · claude · 15m · +120-…",
		" ✓ write the changelog",
		"   api · claude · 2h · +5-0",
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
	if !strings.Contains(out, "review the login flow") || !strings.Contains(out, " ↓5 more") {
		t.Fatalf("overflow:\n%s", out)
	}
	if strings.Contains(out, "fix the flaky spec") {
		t.Fatalf("second agent must be hidden behind the more-line:\n%s", out)
	}
}

func TestScrollAndCursorKeepRowVisible(t *testing.T) {
	v := view(t, "mixed.snapshot", "@9", "none", 16) // one agent row fits
	v.Scroll(2)
	out := plain(Render(v))
	if !strings.Contains(out, "fix-tests.2") || !strings.Contains(out, " ↑2 ↓3 more") {
		t.Fatalf("wheel scroll:\n%s", out)
	}
	v.Scroll(100)
	if v.Offset != 5 || !strings.Contains(plain(Render(v)), "scratch") {
		t.Fatalf("scroll clamps to the last row, offset=%d", v.Offset)
	}
	v.Offset = 0
	v.Cursor = -1
	for i := 0; i < 3+4; i++ { // 3 spaces rows, then into the agents
		v.Move(1)
	}
	if got := v.Selected(); got.Kind != AgentTarget || got.ID != "%9" {
		t.Fatalf("cursor after 7 moves: %+v", got)
	}
	if v.Offset != 3 {
		t.Fatalf("viewport must follow the cursor, offset=%d", v.Offset)
	}
	if !strings.Contains(plain(Render(v)), "›") || !v.Focus {
		t.Fatal("focus mode must mark the cursor row")
	}
}

func TestFiltersAndFold(t *testing.T) {
	v := view(t, "mixed.snapshot", "@2", "webapp", 0)
	v.WaitOnly = true
	rows := v.Rows()
	if len(rows) != 3+2 {
		t.Fatalf("wait-only: %d rows", len(rows))
	}
	if !strings.Contains(plain(Render(v)), " agents                   wait") {
		t.Fatalf("header must show the filter:\n%s", plain(Render(v)))
	}
	v.WaitOnly = false
	v.Filter = "AUTH"
	if rows := v.Rows(); len(rows) != 3+1 || rows[3].Target.ID != "%9" {
		t.Fatalf("text filter is case-insensitive over the title: %+v", rows)
	}
	v.Filter = "codex"
	if rows := v.Rows(); len(rows) != 3+1 || rows[3].Target.ID != "%7" {
		t.Fatalf("text filter covers the subtitle: %+v", rows)
	}
	v.Filter = "nothing-matches"
	if !strings.Contains(plain(Render(v)), "(none match)") {
		t.Fatal("empty filter result must say so")
	}
	v.Filter = ""
	v.Cursor = 1 // webapp workspace row
	v.ToggleFold()
	out := plain(Render(v))
	if !strings.Contains(out, "▸ webapp") || !strings.Contains(out, "feature/login ↑2 · 3 fol") {
		t.Fatalf("fold marker:\n%s", out)
	}
	if strings.Contains(out, "fix the flaky spec") || !strings.Contains(out, "migrate the auth table") {
		t.Fatalf("folded workspace hides its agents only:\n%s", out)
	}
	v.ToggleFold()
	if len(v.Rows()) != 3+6 {
		t.Fatal("unfold restores every row")
	}
}

func TestClickMapPointsAtRows(t *testing.T) {
	v := view(t, "mixed.snapshot", "@2", "webapp", 0)
	_, lines := RenderMap(v)
	if lines[0].Kind != NoTarget || lines[1].Kind != NoTarget {
		t.Fatal("header and blank carry no target")
	}
	if lines[2].Kind != SessionTarget || lines[2].ID != "api" || lines[3].ID != "api" {
		t.Fatalf("workspace row lines: %+v %+v", lines[2], lines[3])
	}
	if lines[11].Kind != AgentTarget || lines[11].ID != "%3" || lines[12].ID != "%3" {
		t.Fatalf("agent row lines: %+v %+v", lines[11], lines[12])
	}
	if lines[len(lines)-1].Kind != NoTarget {
		t.Fatal("footer carries no target")
	}
}

func TestKeysDriveTheView(t *testing.T) {
	m := model{view: view(t, "mixed.snapshot", "@2", "webapp", 0)}
	m.view.Cursor = -1
	press := func(k string) tea.Cmd {
		var msg tea.KeyMsg
		switch k {
		case "enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		nm, cmd := m.Update(msg)
		m = nm.(model)
		return cmd
	}
	press("j")
	press("j")
	if m.view.Selected().ID != "webapp" || !m.view.Focus {
		t.Fatalf("j j lands on the second workspace: %+v", m.view.Selected())
	}
	if cmd := press("enter"); cmd == nil || m.view.Focus {
		t.Fatal("enter on a row yields a jump command and leaves focus mode")
	}
	press("w")
	if !m.view.WaitOnly {
		t.Fatal("w toggles wait-only")
	}
	press("/au") // one read carrying three keystrokes, as tmux send-keys delivers them
	if !m.view.Filtering || m.view.Filter != "au" {
		t.Fatalf("typing builds the filter: %q filtering=%v", m.view.Filter, m.view.Filtering)
	}
	press("enter")
	if m.view.Filtering || m.view.Filter != "au" {
		t.Fatal("enter keeps the filter and stops typing")
	}
	if cmd := press("esc"); cmd == nil || m.view.Focus {
		t.Fatal("esc runs back and leaves focus mode")
	}
	if m.view.Filter != "au" {
		t.Fatal("esc keeps the filter")
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
