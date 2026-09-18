package picker

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
)

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

func keys(items []Item) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.Key
	}
	return out
}

func TestFleetItemsMatchPickerOrder(t *testing.T) {
	items := FleetItems(load(t, "mixed.snapshot"))
	want, err := os.ReadFile("../../../tests/fixtures/snapshot/mixed.picker-order")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, it := range items {
		if p, ok := strings.CutPrefix(it.Key, "PANE:"); ok {
			got = append(got, p)
		}
	}
	if strings.Join(got, "\n") != strings.TrimSpace(string(want)) {
		t.Fatalf("agent order %v", got)
	}
	last := items[len(items)-1]
	if last.Key != "SESS:notes" || last.Meta != "notes" || last.Group != "workspaces" {
		t.Fatalf("agentless workspace must trail the agents: %+v", last)
	}
	// Row parts: title from intent, meta = sess:widx, right = time in state, diff and iso as badges.
	if it := items[0]; it.Title != "migrate the auth table" || it.Meta != "api:1" || it.Right != "15m" || it.Diff != "+120-8" || it.Iso != "sbx" || it.Group != "needs you" {
		t.Fatalf("first row: %+v", it)
	}
	if it := items[1]; it.Title != "fix the flaky spec.1" || it.Meta != "webapp:2" || it.Right != "4m" || it.Diff != "+31-2" || it.Iso != "" {
		t.Fatalf("second row: %+v", it)
	}
	if it := items[2]; it.Group != "working" || it.Right != "" || it.Diff != "" || it.Iso != "wt" {
		t.Fatalf("working row carries no age or diff, keeps its rung: %+v", it)
	}
}

func TestSpacesItems(t *testing.T) {
	items := SpacesItems(load(t, "mixed.snapshot"))
	if len(items) != 3 {
		t.Fatalf("spaces: %d", len(items))
	}
	if items[0].Meta != "main" || items[0].Right != "3 agents" || items[1].Meta != "feature/login ↑2" || items[2].Right != "shell" {
		t.Fatalf("rows: %+v %+v %+v", items[0], items[1], items[2])
	}
	if items[2].State != snapshot.StateIdle {
		t.Fatalf("no-agent rollup renders idle, got %q", items[2].State)
	}
}

func TestConnectDirsDiscovery(t *testing.T) {
	root := t.TempDir()
	mk := func(rel string, repo bool) string {
		d := filepath.Join(root, rel)
		os.MkdirAll(d, 0o755)
		if repo {
			os.MkdirAll(filepath.Join(d, ".git"), 0o755)
		}
		return d
	}
	seen := mk("proj/seen", true)
	fresh := mk("proj/fresh-clone", true) // never visited: only discoverable through the root
	plain := mk("proj/notes", false)
	mk("proj/.hidden", false)
	nested := mk("proj/seen/sub", false) // inside a repo: not a project
	gone := filepath.Join(root, "proj", "deleted")
	dirs := ConnectDirs([]string{seen, gone, filepath.Join(root, "x/.cache/y"), seen}, nil, IsDir, IsRepo)
	got := strings.Join(dirs, "\n")
	for _, want := range []string{seen, fresh, plain} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %s in\n%s", want, got)
		}
	}
	for _, no := range []string{gone, ".hidden", ".cache", nested} {
		if strings.Contains(got, no) {
			t.Errorf("must not list %s:\n%s", no, got)
		}
	}
	if dirs[0] != seen || strings.Count(got, seen) != 1 {
		t.Errorf("zoxide order first, deduped: %v", dirs)
	}
	// Explicit roots replace derivation.
	other := mk("elsewhere", false)
	mk("elsewhere/a", true)
	dirs = ConnectDirs(nil, []string{other}, IsDir, IsRepo)
	if len(dirs) != 1 || filepath.Base(dirs[0]) != "a" {
		t.Errorf("explicit root children only: %v", dirs)
	}
}

func TestConnectItemsOrderAndTags(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	os.MkdirAll(filepath.Join(repo, ".git"), 0o755)
	plain := filepath.Join(root, "plain")
	os.MkdirAll(plain, 0o755)
	cwd := filepath.Join(root, "cwd")
	os.MkdirAll(cwd, 0o755)
	items := ConnectItems(cwd, []string{plain, repo}, map[string]string{repo: "main"}, IsRepo)
	if len(items) != 3 || items[0].Key != "CONNECT:"+cwd || items[0].Group != "current" {
		t.Fatalf("cwd first, under its own header: %+v", items)
	}
	if items[1].Key != "CONNECT:"+repo || !items[1].Repo || items[1].Right != "main" || items[1].Group != "repos" {
		t.Fatalf("repos before plain dirs, branch in the right column: %+v", items[1])
	}
	if items[2].Key != "CONNECT:"+plain || items[2].Repo || items[2].Group != "folders" || items[2].Right != "" {
		t.Fatalf("plain dir last: %+v", items[2])
	}
}

func TestMoveItemsExcludeHome(t *testing.T) {
	items := MoveItems([]Session{{"api", 3}, {"webapp", 1}, {"notes", 2}}, "webapp")
	if len(items) != 2 || items[0].Key != "MOVE:api" || items[0].Right != "3 tabs" || items[1].Right != "2 tabs" {
		t.Fatalf("%+v", items)
	}
	if len(MoveItems([]Session{{"only", 1}}, "only")) != 0 {
		t.Fatal("the tab's own workspace is not a destination")
	}
}

func TestFilterIsFuzzyAndKeepsOrderWhenEmpty(t *testing.T) {
	items := FleetItems(load(t, "mixed.snapshot"))
	if got := Filter(items, ""); len(got) != len(items) || got[0].Key != items[0].Key {
		t.Fatal("empty query keeps order")
	}
	got := Filter(items, "chlog") // subsequence of "changelog"
	if len(got) == 0 || got[0].Key != "PANE:%10" {
		t.Fatalf("fuzzy match on the title: %v", keys(got))
	}
	if got := Filter(items, "webapp"); len(got) != 3 {
		t.Fatalf("match on the subtitle (session): %v", keys(got))
	}
	if got := Filter(items, "zzzz"); len(got) != 0 {
		t.Fatal("no match yields no rows")
	}
}

func TestViewSwitchAndKeys(t *testing.T) {
	m := model{cfg: Config{Width: 80, Height: 20}, view: Fleet, st: newStyles(themeForTest())}
	m.items = FleetItems(load(t, "mixed.snapshot"))
	m.refilter()
	press := func(k string) {
		var msg tea_key
		msg = tea_key{k}
		nm, _ := m.Update(msg.msg())
		m = nm.(model)
	}
	press("j") // plain letters filter, they do not move
	if m.query != "j" {
		t.Fatalf("typing filters: %q", m.query)
	}
	press("backspace")
	press("ctrl+n")
	press("ctrl+n")
	if m.cursor != 2 {
		t.Fatalf("ctrl+n moves: %d", m.cursor)
	}
	press("ctrl+p")
	press("ctrl+p")
	press("ctrl+p")
	if m.cursor != len(m.shown)-1 {
		t.Fatalf("moving above the top cycles to the bottom: %d", m.cursor)
	}
	press("tab")
	if m.view != Spaces || m.query != "" || m.cursor != 0 {
		t.Fatalf("tab cycles to spaces and resets: view=%v query=%q cursor=%d", m.view, m.query, m.cursor)
	}
	press("ctrl+z")
	if m.view != Connect {
		t.Fatal("ctrl+z jumps to connect")
	}
	press("tab")
	if m.view != Fleet {
		t.Fatal("connect wraps to fleet")
	}
}

func TestViewLayout(t *testing.T) {
	m := model{cfg: Config{Width: 78, Height: 22}, view: Fleet, st: newStyles(themeForTest())}
	m.items = FleetItems(load(t, "mixed.snapshot"))
	m.refilter()
	out := plainText(m.View())
	t.Logf("\n%s", out)
	lines := strings.Split(out, "\n")
	if !strings.Contains(lines[0], "fleet") || !strings.Contains(lines[0], "connect") {
		t.Fatalf("tab strip: %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], "╭") || !strings.Contains(lines[2], "7 of 7") || !strings.HasPrefix(lines[3], "╰") {
		t.Fatalf("search box: %q %q %q", lines[1], lines[2], lines[3])
	}
	for _, hdr := range []string{"NEEDS YOU", "WORKING", "DONE", "IDLE", "WORKSPACES"} {
		if !strings.Contains(out, hdr) {
			t.Fatalf("missing group header %s:\n%s", hdr, out)
		}
	}
	// Selected row wears the bar; the time column hugs the right edge.
	sel := ""
	for _, l := range lines {
		if strings.HasPrefix(l, "▎") {
			sel = l
		}
	}
	if !strings.Contains(sel, "migrate the auth table") || !strings.HasSuffix(strings.TrimRight(sel, " "), "15m") {
		t.Fatalf("selected row: %q", sel)
	}
	if !strings.Contains(out, "+120 −8") || !strings.Contains(out, "[sbx]") {
		t.Fatalf("spaced diffstat and rung badge:\n%s", out)
	}
	if !strings.Contains(lines[len(lines)-1], "⏎ jump") {
		t.Fatalf("footer hints: %q", lines[len(lines)-1])
	}
	// A query flattens the groups.
	m.query = "a"
	m.refilter()
	if strings.Contains(plainText(m.View()), "NEEDS YOU") {
		t.Fatal("headers must disappear while filtering")
	}
	for _, l := range strings.Split(plainText(m.View()), "\n") {
		if w := runewidthWidth(l); w > 78 {
			t.Fatalf("line wider than the popup (%d): %q", w, l)
		}
	}
}

func TestMatchHighlightStaysInsideTitle(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor) // go test has no tty; force colors so styling is observable
	m := model{cfg: Config{Width: 78, Height: 22}, view: Fleet, st: newStyles(themeForTest())}
	m.items = FleetItems(load(t, "mixed.snapshot"))
	m.query = "chlog"
	m.refilter()
	if len(m.shown) == 0 || m.shown[0].Key != "PANE:%10" {
		t.Fatalf("filter: %v", keys(m.shown))
	}
	raw := m.row(m.shown[0], false, 78)
	if !strings.Contains(plainText(raw), "write the changelog") || strings.Count(raw, "\x1b[") < 6 {
		t.Fatalf("expected the matched runes styled separately in %q", raw)
	}
	if got := highlight("abc", []int{0, 2, 9}, lipgloss.NewStyle(), lipgloss.NewStyle().Bold(true)); plainText(got) != "abc" {
		t.Fatalf("out-of-range match indexes must be ignored: %q", got)
	}
	// Section headers wear their state's color: NEEDS YOU in the wait color, IDLE muted.
	m.query = ""
	m.refilter()
	th := themeForTest()
	hex := func(h string) string { // "#rrggbb" -> the SGR truecolor parameters lipgloss emits
		var r, g, b int
		fmt.Sscanf(h, "#%02x%02x%02x", &r, &g, &b)
		return fmt.Sprintf("38;2;%d;%d;%d", r, g, b)
	}
	out := m.View()
	if !strings.Contains(out, hex(th.Wait)+"mNEEDS YOU") || !strings.Contains(out, hex(th.Muted)+"mIDLE") {
		t.Fatalf("headers must be state-colored:\n%q", out)
	}
}

func TestSearchBoxKeepsCountInNarrowPopup(t *testing.T) {
	m := model{cfg: Config{Width: 48, Height: 20}, view: Fleet, st: newStyles(themeForTest())}
	m.items = FleetItems(load(t, "mixed.snapshot"))
	m.query = "a very long query that would not fit in the box at all"
	m.refilter()
	lines := strings.Split(plainText(m.View()), "\n")
	if !strings.Contains(lines[2], fmt.Sprintf("%d of %d", len(m.shown), len(m.items))) {
		t.Fatalf("count must survive a long query: %q", lines[2])
	}
	for i, l := range lines[:4] {
		if w := runewidthWidth(l); w != 48 && i > 0 {
			t.Fatalf("box line %d is %d cells wide, want 48: %q", i, w, l)
		}
	}
}
