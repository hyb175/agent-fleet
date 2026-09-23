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
		"─ spaces ────────── ◆2 ⠿1 ✓2 ─", // the fleet's counts ride in the rule
		" ✓ api",
		"   main · ◆1 ✓2", // and each workspace's in its subtitle
		"▎ ◆ webapp",      // selected workspace: bar on both lines
		"▎  feature/login ↑2 · ◆1 ⠿1",
		" · notes", // no agents: no counts
		"   notes",
		"",
		"─ agents ─────────────── all ─",
		" ⠋ 1:review the login flow", // this rail's workspace: tab number,
		"   claude · wt",             // and no "webapp ·" saying where you are
		"▎ ◆ 2:fix the flaky spec.1", // shared window: .pidx suffix, selected (window @2)
		"▎  claude · 4m · +31-2",     // the diffstat the prefix used to truncate
		"▎ ○ 2:fix-tests.2",
		"▎  codex~",
		" ◆ migrate the auth table",      // another workspace: no number,
		"   api · claude · 15m · +120-…", // and it says which one
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
	// api's own agents carry their tab number here; webapp's do not.
	if !strings.Contains(a, "▎ ◆ 1:migrate the auth table") || strings.Contains(a, "▎ ◆ fix the flaky spec") {
		t.Fatalf("api rail must highlight window @5 only:\n%s", a)
	}
}

func TestOverflowCountsTheRest(t *testing.T) {
	out := plain(Render(view(t, "mixed.snapshot", "@9", "none", 16)))
	// 16 rows: spaces rule, 3 spaces rows (6), the section gap, agents rule =
	// 9 lines before the agents; (16-9-3)/2 = 2 agent rows, then "↓4 more".
	if !strings.Contains(out, "review the login flow") || !strings.Contains(out, " ↓4 more") {
		t.Fatalf("overflow:\n%s", out)
	}
	if strings.Contains(out, "fix-tests.2") {
		t.Fatalf("third agent must be hidden behind the more-line:\n%s", out)
	}
}

func TestScrollAndCursorKeepRowVisible(t *testing.T) {
	v := view(t, "mixed.snapshot", "@9", "none", 16) // two agent rows fit
	v.Scroll(2)
	out := plain(Render(v))
	if !strings.Contains(out, "fix-tests.2") || !strings.Contains(out, " ↑2 ↓2 more") {
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
	// Cursor on agent row 3 with a two-row window: the last window holding it.
	if v.Offset != 2 {
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
	if !strings.Contains(plain(Render(v)), "─ agents ────────────── wait ─") {
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
	// 0 is the spaces rule, 7 the section gap, 8 the agents rule.
	if lines[0].Kind != NoTarget || lines[7].Kind != NoTarget || lines[8].Kind != NoTarget {
		t.Fatal("section rules and the gap carry no target")
	}
	if lines[1].Kind != SessionTarget || lines[1].ID != "api" || lines[2].ID != "api" {
		t.Fatalf("workspace row lines: %+v %+v", lines[1], lines[2])
	}
	if lines[9].Kind != AgentTarget || lines[9].ID != "%3" || lines[10].ID != "%3" {
		t.Fatalf("agent row lines: %+v %+v", lines[9], lines[10])
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

func TestFooterPinnedToTheBottom(t *testing.T) {
	// A 40-row pane holding a 21-row fleet: the footer belongs on row 40, not
	// wherever the list happened to stop.
	out := plain(Render(view(t, "mixed.snapshot", "@2", "webapp", 40)))
	lines := strings.Split(out, "\n")
	if len(lines) != 40 {
		t.Fatalf("got %d lines, want the pane's 40:\n%s", len(lines), out)
	}
	if !strings.Contains(lines[39], "prefix+o open") {
		t.Fatalf("footer must be the last row, got %q", lines[39])
	}
	if strings.TrimSpace(lines[38]) != "" {
		t.Fatalf("row above the footer must be blank, got %q", lines[38])
	}
	// Uncapped (tests, unknown height) keeps the old shape: blank, then footer.
	u := strings.Split(plain(Render(view(t, "mixed.snapshot", "@2", "webapp", 0))), "\n")
	if !strings.Contains(u[len(u)-1], "prefix+o open") || strings.TrimSpace(u[len(u)-2]) != "" {
		t.Fatalf("uncapped rail must end with one blank then the footer:\n%s", strings.Join(u, "\n"))
	}
}

func TestNameCarriesItsState(t *testing.T) {
	th, err := theme.Load("../../..", "tokyo-night")
	if err != nil {
		t.Fatal(err)
	}
	// A rail whose window and workspace hold nothing, so every row renders in
	// its plain (unhighlighted) form.
	out := Render(view(t, "mixed.snapshot", "@9", "none", 0))
	bold := func(hex string) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(lipgloss.Color(hex)).Bold(true)
	}
	plainFg := func(hex string) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(lipgloss.Color(hex))
	}
	for _, c := range []struct {
		what, name string
		style      lipgloss.Style
	}{
		{"wait", "migrate the auth table", bold(th.Wait)},
		{"done", "write the changelog", bold(th.Done)},
		{"working", "review the login flow", bold(th.FG)},
		{"idle", "fix-tests.2", plainFg(th.Muted)},
	} {
		if !strings.Contains(out, c.style.Render(c.name)) {
			t.Errorf("%s row's name must be painted by its state: %q", c.what, c.name)
		}
	}
}

func TestNarrowRailDropsTheSummary(t *testing.T) {
	v := view(t, "mixed.snapshot", "@2", "webapp", 0)
	v.Cfg.Width = 18
	first := strings.Split(plain(Render(v)), "\n")[0]
	if lipgloss.Width(first) != 18 {
		t.Fatalf("the rule must fill a narrow rail exactly: %q", first)
	}
	if strings.ContainsAny(first, "◆⠿✓") {
		t.Fatalf("a styled slot that cannot fit whole is dropped, not cut: %q", first)
	}
}

func TestFilterStillFindsOwnWorkspaceByName(t *testing.T) {
	// webapp's own rows stop PRINTING "webapp", but typing it must still find
	// them: Rows() matches against the unabbreviated subtitle.
	v := view(t, "mixed.snapshot", "@2", "webapp", 0)
	v.Filter = "webapp"
	if n := len(v.Rows()) - len(v.Snap.Spaces); n != 3 {
		t.Fatalf("filtering by the current workspace's name: %d agent rows, want 3", n)
	}
}
