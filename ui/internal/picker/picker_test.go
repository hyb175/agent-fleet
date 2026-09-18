package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

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
	if last.Key != "SESS:notes" || last.Sub != "notes" {
		t.Fatalf("agentless workspace must trail the agents: %+v", last)
	}
	// Row text as pick.sh renders it: title from intent, sub = sess:widx · state age · diffstat · iso.
	if items[0].Title != "migrate the auth table" || items[0].Sub != "api:1 · wait 15m · +120-8 · sbx" {
		t.Fatalf("first row: %+v", items[0])
	}
	if items[1].Title != "fix the flaky spec.1" || items[1].Sub != "webapp:2 · wait 4m · +31-2" {
		t.Fatalf("second row: %+v", items[1])
	}
}

func TestSpacesItems(t *testing.T) {
	items := SpacesItems(load(t, "mixed.snapshot"))
	if len(items) != 3 {
		t.Fatalf("spaces: %d", len(items))
	}
	if items[0].Sub != "main · 3 agents" || items[1].Sub != "feature/login ↑2 · 3 agents" || items[2].Sub != "notes · shell" {
		t.Fatalf("subtitles: %q %q %q", items[0].Sub, items[1].Sub, items[2].Sub)
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
	if len(items) != 3 || items[0].Key != "CONNECT:"+cwd || !strings.HasSuffix(items[0].Sub, "(cwd)") {
		t.Fatalf("cwd first and tagged: %+v", items)
	}
	if items[1].Key != "CONNECT:"+repo || !items[1].Repo || items[1].Sub != "main  ·  "+repo {
		t.Fatalf("repos before plain dirs, with branch: %+v", items[1])
	}
	if items[2].Key != "CONNECT:"+plain || items[2].Repo {
		t.Fatalf("plain dir last: %+v", items[2])
	}
}

func TestMoveItemsExcludeHome(t *testing.T) {
	items := MoveItems([]Session{{"api", 3}, {"webapp", 1}, {"notes", 2}}, "webapp")
	if len(items) != 2 || items[0].Key != "MOVE:api" || items[0].Sub != "3 tabs" || items[1].Sub != "2 tabs" {
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
