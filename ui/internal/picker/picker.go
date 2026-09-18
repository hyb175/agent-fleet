// Package picker is the fleet's popup: one list with a fuzzy filter and
// three views (fleet, spaces, connect), plus the move-tab destination view.
// It is the Go twin of scripts/pick.sh and scripts/move-tab.sh.
//
// Data comes from fleet.snapshot (fleet, spaces), from zoxide and the
// project roots (connect), or from `tmux list-sessions` at startup (move —
// a move must act on what exists right now, snapshot or not). Every action
// is an `agent-fleet` verb; the picker never drives tmux itself.
//
// Layout: a tab strip naming the views, a bordered search box carrying the
// query and the match count, rows grouped under small section headers while
// the query is empty (a filter flattens them), a right-aligned time column,
// and a footer of key hints.
package picker

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
	"github.com/muesli/termenv"
	"github.com/sahilm/fuzzy"

	"github.com/hyb175/agent-fleet/ui/internal/cache"
	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
)

// ViewKind is which list the popup shows.
type ViewKind int

const (
	Fleet ViewKind = iota
	Spaces
	Connect
	Move
)

func (k ViewKind) String() string {
	return [...]string{"fleet", "spaces", "connect", "move"}[k]
}

// ParseView maps the CLI argument to a view; unknown or empty is Fleet.
func ParseView(s string) ViewKind {
	switch s {
	case "spaces":
		return Spaces
	case "connect":
		return Connect
	case "move":
		return Move
	}
	return Fleet
}

// Item is one selectable row. Key is the action target, as pick.sh spelled
// it: PANE:<pane> · SESS:<session> · CONNECT:<dir> · MOVE:<session>.
type Item struct {
	Key    string
	State  string // agent state or workspace rollup, drives the glyph
	Repo   bool   // connect view: the directory is a git repo
	Group  string // section header the row sits under (empty = none)
	Title  string // bold column
	Meta   string // dim detail after the title (workspace:index, branch, path)
	Diff   string // "+A-D" from the record, colored when rendered ("" = none)
	Iso    string // isolation rung badge ("" = host)
	Right  string // right-aligned column: time in state, agent count, branch
	Search string // what the fuzzy filter matches against
	Match  []int  // rune indexes into Search the current query matched (accented when inside Title)
}

// Config is what the popup needs from its environment.
type Config struct {
	View     ViewKind
	Root     string
	AF       string
	Snapshot string
	Theme    theme.Theme
	Cwd      string
	Roots    []string // AGENT_FLEET_PROJECT_ROOTS, empty = derive
	MoveWin  string   // move view: the window being moved (@N)
	Width    int
	Height   int
}

// --- data ------------------------------------------------------------------

func groupOf(state string) string {
	switch state {
	case snapshot.StateWait:
		return "needs you"
	case snapshot.StateWorking:
		return "working"
	case snapshot.StateDone:
		return "done"
	}
	return "idle"
}

// FleetItems is every jump target: agents most-urgent first (rank, then
// longest wait, then arrival), then workspaces without agents.
func FleetItems(s *snapshot.Snapshot) []Item {
	var items []Item
	if s == nil {
		return items
	}
	per := s.AgentsPerWindow()
	agents := append([]snapshot.Agent(nil), s.Agents...)
	snapshot.SortAttention(agents, snapshot.StateWait)
	for _, a := range agents {
		it := Item{
			Key: "PANE:" + a.Pane, State: a.State, Group: groupOf(a.State),
			Title: a.Title(per), Meta: a.Session + ":" + a.WindowIndex, Iso: a.Isolation,
		}
		if a.State == snapshot.StateWait || a.State == snapshot.StateDone {
			if a.HasAge {
				it.Right = snapshot.FormatAge(a.Age)
			}
			it.Diff = a.Diffstat
		}
		it.Search = strings.Join([]string{it.Title, it.Meta, a.State, it.Diff, it.Iso, a.Label}, " ")
		items = append(items, it)
	}
	for _, sp := range s.Spaces {
		if sp.Rollup != "none" {
			continue // has agents: its rows are above
		}
		items = append(items, Item{
			Key: "SESS:" + sp.Session, State: snapshot.StateIdle, Group: "workspaces",
			Title: sp.Session, Meta: sp.Branch, Search: sp.Session + " " + sp.Branch,
		})
	}
	return items
}

// SpacesItems is every workspace, agentful or not: the quick workspace jump.
func SpacesItems(s *snapshot.Snapshot) []Item {
	var items []Item
	if s == nil {
		return items
	}
	count := map[string]int{}
	for _, a := range s.Agents {
		count[a.Session]++
	}
	for _, sp := range s.Spaces {
		right := "shell"
		if n := count[sp.Session]; n == 1 {
			right = "1 agent"
		} else if n > 1 {
			right = fmt.Sprintf("%d agents", n)
		}
		st := sp.Rollup
		if st == "none" {
			st = snapshot.StateIdle
		}
		items = append(items, Item{
			Key: "SESS:" + sp.Session, State: st, Title: sp.Session, Meta: sp.Branch, Right: right,
			Search: sp.Session + " " + sp.Branch,
		})
	}
	return items
}

// ConnectDirs lists workspace candidates: zoxide entries in frecency order,
// then children of the project roots zoxide has never seen (a fresh clone
// or an untouched sibling repo is otherwise invisible until its first
// visit). Roots are given, or derived: the parent of every known git repo,
// provided the parent is not itself a repo. Hidden-component paths and
// missing dirs are dropped.
func ConnectDirs(zoxide []string, roots []string, isDir, isRepo func(string) bool) []string {
	seen := map[string]bool{}
	var out []string
	hidden := func(p string) bool {
		for _, part := range strings.Split(p, string(filepath.Separator)) {
			if strings.HasPrefix(part, ".") && part != "." && part != ".." {
				return true
			}
		}
		return false
	}
	for _, d := range zoxide {
		if d == "" || hidden(d) || seen[d] || !isDir(d) {
			continue
		}
		seen[d] = true
		out = append(out, d)
	}
	if len(roots) == 0 {
		rseen := map[string]bool{}
		for _, d := range out {
			if !isRepo(d) {
				continue
			}
			r := filepath.Dir(d)
			if r == "" || r == d || rseen[r] || isRepo(r) || !isDir(r) {
				continue
			}
			rseen[r] = true
			roots = append(roots, r)
		}
		sort.Strings(roots)
	}
	for _, r := range roots {
		entries, err := os.ReadDir(r)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			d := filepath.Join(r, e.Name())
			if seen[d] {
				continue
			}
			seen[d] = true
			out = append(out, d)
		}
	}
	return out
}

// ConnectItems builds the connect rows: cwd first (tagged), then git repos
// with their branch in the right column, then plain directories.
func ConnectItems(cwd string, dirs []string, branch map[string]string, isRepo func(string) bool) []Item {
	home, _ := os.UserHomeDir()
	short := func(p string) string {
		if home != "" && strings.HasPrefix(p, home) {
			return "~" + p[len(home):]
		}
		return p
	}
	row := func(d, group string) Item {
		it := Item{Key: "CONNECT:" + d, Group: group, Title: filepath.Base(d), Meta: short(d)}
		if isRepo(d) {
			it.Repo = true
			it.Right = branch[d]
		}
		it.Search = it.Title + " " + d + " " + it.Right
		return it
	}
	items := []Item{row(cwd, "current")}
	var repos, plain []Item
	for _, d := range dirs {
		if d == cwd {
			continue
		}
		if isRepo(d) {
			repos = append(repos, row(d, "repos"))
		} else {
			plain = append(plain, row(d, "folders"))
		}
	}
	items = append(items, repos...)
	return append(items, plain...)
}

// Session is one live tmux session for the move view.
type Session struct {
	Name    string
	Windows int
}

// MoveItems lists destinations: every workspace except the tab's own.
func MoveItems(sessions []Session, here string) []Item {
	var items []Item
	for _, s := range sessions {
		if s.Name == "" || s.Name == here {
			continue
		}
		right := fmt.Sprintf("%d tabs", s.Windows)
		if s.Windows == 1 {
			right = "1 tab"
		}
		items = append(items, Item{Key: "MOVE:" + s.Name, State: snapshot.StateIdle, Title: s.Name, Right: right, Search: s.Name})
	}
	return items
}

// Filter ranks items by fuzzy match on Search; an empty query keeps order.
func Filter(items []Item, query string) []Item {
	if strings.TrimSpace(query) == "" {
		return items
	}
	src := make([]string, len(items))
	for i, it := range items {
		src[i] = it.Search
	}
	matches := fuzzy.Find(query, src)
	out := make([]Item, 0, len(matches))
	for _, m := range matches {
		it := items[m.Index]
		it.Match = m.MatchedIndexes
		out = append(out, it)
	}
	return out
}

// IsRepo reports whether dir has a .git entry (a worktree's .git is a file).
func IsRepo(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, ".git"))
	return err == nil
}

// IsDir reports whether path is an existing directory.
func IsDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

// Branches resolves the current branch of each repo concurrently, with a
// short per-repo timeout so one slow disk cannot hold the popup. Replaces
// pick.sh's 60-second cache file.
func Branches(dirs []string, isRepo func(string) bool, timeout time.Duration) map[string]string {
	out := map[string]string{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for _, d := range dirs {
		if !isRepo(d) {
			continue
		}
		wg.Add(1)
		go func(d string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			b, err := exec.CommandContext(ctx, "git", "-C", d, "symbolic-ref", "--quiet", "--short", "HEAD").Output()
			if err != nil {
				return
			}
			mu.Lock()
			out[d] = strings.TrimSpace(string(b))
			mu.Unlock()
		}(d)
	}
	wg.Wait()
	return out
}

// --- Bubble Tea program -----------------------------------------------------

type tickMsg time.Time
type itemsMsg struct {
	view  ViewKind
	items []Item
	stale bool
	note  string
}
type doneMsg struct {
	err error
	out string
}

type model struct {
	cfg     Config
	view    ViewKind
	items   []Item
	shown   []Item
	query   string
	cursor  int
	offset  int // first shown row on screen
	frame   int
	stale   bool
	note    string // one-line message under the search box
	naming  bool   // ^r: typing a workspace name
	name    string
	nameFor string // CONNECT:<dir> the name is for
	snapMod time.Time
	st      styles
}

type styles struct {
	dim, bold, accent, border, tab, tabOn, key, wait, working, done, muted lipgloss.Style
	hlRow, hlBold, hlDim, hlBar, hlAccent                                  lipgloss.Style
}

func newStyles(t theme.Theme) styles {
	c := func(s string) lipgloss.Color { return lipgloss.Color(s) }
	hl := c(t.HL)
	return styles{
		dim:      lipgloss.NewStyle().Foreground(c(t.Muted)),
		bold:     lipgloss.NewStyle().Foreground(c(t.FG)).Bold(true),
		accent:   lipgloss.NewStyle().Foreground(c(t.Accent)),
		border:   lipgloss.NewStyle().Foreground(c(t.HL)),
		tab:      lipgloss.NewStyle().Foreground(c(t.Muted)).Padding(0, 1),
		tabOn:    lipgloss.NewStyle().Foreground(c(t.BG)).Background(c(t.Accent)).Bold(true).Padding(0, 1),
		key:      lipgloss.NewStyle().Foreground(c(t.FG)),
		wait:     lipgloss.NewStyle().Foreground(c(t.Wait)),
		working:  lipgloss.NewStyle().Foreground(c(t.Working)),
		done:     lipgloss.NewStyle().Foreground(c(t.Done)),
		muted:    lipgloss.NewStyle().Foreground(c(t.Muted)),
		hlRow:    lipgloss.NewStyle().Background(hl),
		hlBold:   lipgloss.NewStyle().Foreground(c(t.FG)).Bold(true).Background(hl),
		hlDim:    lipgloss.NewStyle().Foreground(c(t.Muted)).Background(hl),
		hlBar:    lipgloss.NewStyle().Foreground(c(t.Accent)).Background(hl),
		hlAccent: lipgloss.NewStyle().Foreground(c(t.Accent)).Bold(true).Background(hl),
	}
}

var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

func (s styles) glyph(it Item, frame int, sel bool) string {
	bg := func(st lipgloss.Style) lipgloss.Style {
		if sel {
			return st.Background(s.hlRow.GetBackground())
		}
		return st
	}
	if strings.HasPrefix(it.Key, "CONNECT:") {
		if it.Repo {
			return bg(s.done).Render("◆")
		}
		return bg(s.muted).Render("▫")
	}
	switch it.State {
	case snapshot.StateWait:
		return bg(s.wait).Render("◆")
	case snapshot.StateWorking:
		return bg(s.working).Render(spinner[frame%len(spinner)])
	case snapshot.StateDone:
		return bg(s.done).Render("✓")
	case snapshot.StateIdle:
		return bg(s.muted).Render("○")
	}
	return bg(s.muted).Render("·")
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.load(m.view), tick())
}

func tick() tea.Cmd {
	return tea.Tick(150*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) readSnapshot() (*snapshot.Snapshot, time.Time) {
	fi, err := os.Stat(m.cfg.Snapshot)
	if err != nil {
		return nil, time.Time{}
	}
	f, err := os.Open(m.cfg.Snapshot)
	if err != nil {
		return nil, fi.ModTime()
	}
	defer f.Close()
	s, err := snapshot.Parse(f)
	if err != nil {
		return nil, fi.ModTime()
	}
	return s, fi.ModTime()
}

// load builds a view's items off the render loop.
func (m model) load(view ViewKind) tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg {
		switch view {
		case Fleet, Spaces:
			s, _ := m.readSnapshot()
			if s == nil {
				return itemsMsg{view: view, note: "fleet starting…"}
			}
			var items []Item
			if view == Fleet {
				items = FleetItems(s)
			} else {
				items = SpacesItems(s)
			}
			note := ""
			if len(items) == 0 {
				note = "no workspaces yet — Tab to connect a repo"
			}
			return itemsMsg{view: view, items: items, stale: s.Stale(time.Now().Unix()), note: note}
		case Connect:
			var zox []string
			if out, err := exec.Command("zoxide", "query", "-l").Output(); err == nil {
				zox = strings.Split(strings.TrimSpace(string(out)), "\n")
			}
			dirs := ConnectDirs(zox, cfg.Roots, IsDir, IsRepo)
			branches := Branches(append([]string{cfg.Cwd}, dirs...), IsRepo, 400*time.Millisecond)
			return itemsMsg{view: view, items: ConnectItems(cfg.Cwd, dirs, branches, IsRepo)}
		case Move:
			sessions, here, err := liveSessions(cfg)
			if err != nil {
				return itemsMsg{view: view, note: "move: " + err.Error()}
			}
			items := MoveItems(sessions, here)
			note := ""
			if len(items) == 0 {
				note = "no other workspace to move to"
			}
			return itemsMsg{view: view, items: items, note: note}
		}
		return itemsMsg{view: view}
	}
}

// liveSessions asks tmux for the session list and the moving tab's home.
// Startup-time reads only; the move itself is `agent-fleet move`.
func liveSessions(cfg Config) ([]Session, string, error) {
	tmuxBin := os.Getenv("TMUX_BIN")
	if tmuxBin == "" {
		tmuxBin = "tmux"
	}
	sock := cache.Socket(os.Getenv)
	out, err := exec.Command(tmuxBin, "-L", sock, "list-sessions", "-F", "#{session_name}|#{session_windows}").Output()
	if err != nil {
		return nil, "", fmt.Errorf("no fleet running")
	}
	var sessions []Session
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		name, n, _ := strings.Cut(line, "|")
		var w int
		fmt.Sscanf(n, "%d", &w)
		if name != "" {
			sessions = append(sessions, Session{Name: name, Windows: w})
		}
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].Name < sessions[j].Name })
	here := ""
	if cfg.MoveWin != "" {
		if h, err := exec.Command(tmuxBin, "-L", sock, "display-message", "-p", "-t", cfg.MoveWin, "#{session_name}").Output(); err == nil {
			here = strings.TrimSpace(string(h))
		}
	}
	return sessions, here, nil
}

func (m *model) refilter() {
	m.shown = Filter(m.items, m.query)
	if m.cursor >= len(m.shown) {
		m.cursor = len(m.shown) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
	m.clamp()
}

// --- layout -------------------------------------------------------------------

// lineKind tells a screen line's role, for the click map and the viewport.
type lineKind int

const (
	lineChrome lineKind = iota // tabs, box, note, footer
	lineHeader                 // group header
	lineItem                   // a row; idx into shown
)

type line struct {
	kind lineKind
	idx  int
}

// listLines lays the shown rows out with group headers (only while the
// query is empty — a filter flattens the list) and returns every list line
// plus the index of each row's line, so the viewport can keep the cursor
// on screen and a click can map back to a row.
func (m model) listLines() (lines []line, rowLine []int) {
	rowLine = make([]int, len(m.shown))
	last := ""
	for i, it := range m.shown {
		if m.query == "" && it.Group != "" && it.Group != last {
			lines = append(lines, line{kind: lineHeader, idx: i})
			last = it.Group
		}
		rowLine[i] = len(lines)
		lines = append(lines, line{kind: lineItem, idx: i})
	}
	return lines, rowLine
}

// chromeTop is the number of lines above the list: tabs, the three-line
// search box, and the note line.
func (m model) chromeTop() int { return 1 + 3 + 1 }

// listHeight is how many list lines fit: everything but the chrome and the footer.
func (m model) listHeight() int {
	h := m.cfg.Height - m.chromeTop() - 1
	if h < 1 {
		h = 1
	}
	return h
}

// clamp scrolls the viewport (in list lines) so the cursor's line shows.
func (m *model) clamp() {
	_, rowLine := m.listLines()
	if len(rowLine) == 0 {
		m.offset = 0
		return
	}
	cl := rowLine[m.cursor]
	h := m.listHeight()
	if cl < m.offset {
		m.offset = cl
		// Show the group header just above the first visible row.
		if m.query == "" && cl > 0 {
			m.offset = cl - 1
		}
	} else if cl >= m.offset+h {
		m.offset = cl - h + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

func (m model) selected() (Item, bool) {
	if m.cursor < 0 || m.cursor >= len(m.shown) {
		return Item{}, false
	}
	return m.shown[m.cursor], true
}

// run executes an agent-fleet verb and quits the popup when it succeeds; a
// failure stays on screen as the note. The child gets no tty: its tmux
// clients must never hold this pane's pty (a client blocked on a dying pty
// wedges uninterruptibly on macOS), and its output must not paint over the
// popup.
func (m model) run(args ...string) tea.Cmd {
	af := m.cfg.AF
	return func() tea.Msg {
		cmd := exec.Command(af, args...)
		out, err := cmd.CombinedOutput()
		return doneMsg{err: err, out: strings.TrimSpace(string(out))}
	}
}

// act is Enter: jump, switch, connect or move, then close.
func (m model) act(it Item) (tea.Model, tea.Cmd) {
	kind, id, _ := strings.Cut(it.Key, ":")
	switch kind {
	case "PANE":
		return m, m.run("goto", id)
	case "SESS", "CONNECT":
		return m, m.run("connect", id)
	case "MOVE":
		return m, m.run("move", m.cfg.MoveWin, "--to", id, "--focus")
	}
	return m, nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.cfg.Width, m.cfg.Height = msg.Width, msg.Height
		m.clamp()
		return m, nil
	case itemsMsg:
		if msg.view != m.view {
			return m, nil
		}
		// Keep the cursor on the same row across a live refresh.
		key := ""
		if it, ok := m.selected(); ok {
			key = it.Key
		}
		m.items, m.stale, m.note = msg.items, msg.stale, msg.note
		m.refilter()
		for i, it := range m.shown {
			if it.Key == key {
				m.cursor = i
			}
		}
		m.clamp()
		return m, nil
	case tickMsg:
		m.frame++
		if m.view == Fleet || m.view == Spaces {
			if fi, err := os.Stat(m.cfg.Snapshot); err == nil && !fi.ModTime().Equal(m.snapMod) {
				m.snapMod = fi.ModTime()
				return m, tea.Batch(m.load(m.view), tick())
			}
		}
		return m, tick()
	case doneMsg:
		if msg.err != nil {
			m.note = "failed: " + firstLine(msg.out)
			return m, nil
		}
		return m, tea.Quit
	case tea.MouseMsg:
		switch {
		case msg.Button == tea.MouseButtonWheelUp:
			m.move(-1)
		case msg.Button == tea.MouseButtonWheelDown:
			m.move(1)
		case msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress:
			lines, _ := m.listLines()
			if li := msg.Y - m.chromeTop() + m.offset; li >= 0 && li < len(lines) && lines[li].kind == lineItem {
				m.cursor = lines[li].idx
				return m.act(m.shown[m.cursor])
			}
		}
		return m, nil
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m *model) move(d int) {
	if len(m.shown) == 0 {
		return
	}
	m.cursor = (m.cursor + d + len(m.shown)) % len(m.shown) // cycle, as fzf --cycle
	m.clamp()
}

func (m *model) switchView(v ViewKind) tea.Cmd {
	if m.view == Move {
		return nil
	}
	m.view = v
	m.items, m.shown, m.note, m.stale = nil, nil, "", false
	m.cursor, m.offset = 0, 0
	m.query = ""
	return m.load(v)
}

func (m model) key(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if msg.Type == tea.KeyRunes && len(msg.Runes) > 1 {
		var cur tea.Model = m
		var cmd tea.Cmd
		for _, r := range msg.Runes {
			cur, cmd = cur.(model).key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		}
		return cur, cmd
	}
	if m.naming {
		switch msg.Type {
		case tea.KeyEsc:
			m.naming = false
		case tea.KeyEnter:
			name := strings.TrimSpace(m.name)
			dir := strings.TrimPrefix(m.nameFor, "CONNECT:")
			if name == "" {
				name = filepath.Base(dir)
			}
			m.naming = false
			return m, m.run("connect", dir, name)
		case tea.KeyBackspace:
			if r := []rune(m.name); len(r) > 0 {
				m.name = string(r[:len(r)-1])
			}
		case tea.KeyRunes:
			m.name += string(msg.Runes)
		}
		return m, nil
	}
	switch msg.String() {
	case "ctrl+c", "esc":
		return m, tea.Quit
	case "tab":
		next := map[ViewKind]ViewKind{Fleet: Spaces, Spaces: Connect, Connect: Fleet}[m.view]
		return m, m.switchView(next)
	case "ctrl+f":
		return m, m.switchView(Fleet)
	case "ctrl+s":
		return m, m.switchView(Spaces)
	case "ctrl+z":
		return m, m.switchView(Connect)
	case "down", "ctrl+n", "ctrl+j":
		m.move(1)
	case "up", "ctrl+p", "ctrl+k":
		m.move(-1)
	case "enter":
		if it, ok := m.selected(); ok {
			return m.act(it)
		}
	case "ctrl+a":
		// Spawn the workspace WITH a claude agent as its first tab; on any
		// other row behave like Enter.
		if it, ok := m.selected(); ok {
			if d, isDir := strings.CutPrefix(it.Key, "CONNECT:"); isDir {
				return m, m.run("add", "--new-workspace", filepath.Base(d), "--dir", d, "--focus")
			}
			return m.act(it)
		}
	case "ctrl+r":
		if it, ok := m.selected(); ok {
			if d, isDir := strings.CutPrefix(it.Key, "CONNECT:"); isDir {
				m.naming, m.nameFor, m.name = true, it.Key, filepath.Base(d)
				return m, nil
			}
			return m.act(it)
		}
	case "ctrl+v":
		if it, ok := m.selected(); ok {
			if pane, isPane := strings.CutPrefix(it.Key, "PANE:"); isPane {
				if snapshot.IsRemote(pane) {
					m.note = "no review: remote task — review it on " + snapshot.Host(pane)
					return m, nil
				}
				// Review runs in the popup's own tty; outcomes must survive
				// until a keypress, so a shell wrapper waits before returning.
				c := exec.Command("bash", "-c", `"$1" review "$2" || true; printf '\n(any key returns to the picker)'; IFS= read -r -n1 _`, "af", m.cfg.AF, pane)
				return m, tea.ExecProcess(c, func(error) tea.Msg { return itemsMsg{view: -1} })
			}
		}
	case "backspace":
		if r := []rune(m.query); len(r) > 0 {
			m.query = string(r[:len(r)-1])
			m.refilter()
		}
	default:
		if msg.Type == tea.KeyRunes {
			m.query += string(msg.Runes)
			m.cursor = 0
			m.refilter()
		}
	}
	return m, nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	if s == "" {
		return "(no output)"
	}
	return s
}

// --- rendering -----------------------------------------------------------------

func trunc(s string, n int) string {
	if n < 1 {
		return ""
	}
	if runewidth.StringWidth(s) <= n {
		return s
	}
	return runewidth.Truncate(s, n, "…")
}

func padRight(s string, w int) string {
	if d := w - lipgloss.Width(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

// tabs renders the view strip; the move view has no siblings and shows its title instead.
func (m model) tabs(w int) string {
	if m.view == Move {
		return m.st.tabOn.Render("move tab") + " " + m.st.dim.Render("to another workspace")
	}
	var b strings.Builder
	for _, v := range []ViewKind{Fleet, Spaces, Connect} {
		if v == m.view {
			b.WriteString(m.st.tabOn.Render(v.String()))
		} else {
			b.WriteString(m.st.tab.Render(v.String()))
		}
	}
	return trunc(b.String(), w)
}

// searchBox is the bordered query line with the match count on the right.
func (m model) searchBox(w int) string {
	inner := w - 4 // borders and one space each side
	var prompt, text string
	if m.naming {
		prompt = m.st.accent.Render("name ")
		text = m.name
	} else {
		prompt = m.st.accent.Render("› ")
		text = m.query
		if text == "" {
			text = m.st.dim.Render("type to filter")
		}
	}
	count := m.st.dim.Render(fmt.Sprintf("%d of %d", len(m.shown), len(m.items)))
	left := prompt + text + m.st.accent.Render("▏")
	gap := inner - lipgloss.Width(left) - lipgloss.Width(count)
	if gap < 1 {
		gap = 1
	}
	body := " " + left + strings.Repeat(" ", gap) + count + " "
	body = padRight(trunc(body, w-2), w-2)
	top := m.st.border.Render("╭" + strings.Repeat("─", w-2) + "╮")
	mid := m.st.border.Render("│") + body + m.st.border.Render("│")
	bot := m.st.border.Render("╰" + strings.Repeat("─", w-2) + "╯")
	return top + "\n" + mid + "\n" + bot
}

// diff spaces "+A-D" into "+A −D"; muted like the rest of the detail, so
// state colors stay reserved for the glyph.
func diff(d string) string {
	plus, minus, ok := strings.Cut(d, "-")
	if !ok || !strings.HasPrefix(plus, "+") {
		return d
	}
	return plus + " −" + minus
}

// highlight renders text with the matched rune positions in accent, the
// way fzf marks its hits; positions beyond the text are ignored.
func highlight(text string, match []int, base, hit lipgloss.Style) string {
	if len(match) == 0 {
		return base.Render(text)
	}
	set := map[int]bool{}
	for _, i := range match {
		set[i] = true
	}
	var b strings.Builder
	run, hitRun := "", false
	flush := func() {
		if run == "" {
			return
		}
		if hitRun {
			b.WriteString(hit.Render(run))
		} else {
			b.WriteString(base.Render(run))
		}
		run = ""
	}
	for i, r := range []rune(text) {
		if set[i] != hitRun {
			flush()
			hitRun = set[i]
		}
		run += string(r)
	}
	flush()
	return b.String()
}

func (m model) row(it Item, sel bool, w int) string {
	bar, glyph := " ", m.glyphFor(it, sel)
	title, meta, dim, hit := m.st.bold, m.st.dim, m.st.dim, m.st.accent.Bold(true)
	if sel {
		bar = m.st.hlBar.Render("▎")
		title, meta, dim, hit = m.st.hlBold, m.st.hlDim, m.st.hlDim, m.st.hlAccent
	}
	right := ""
	if it.Right != "" {
		if strings.HasPrefix(it.Key, "CONNECT:") {
			right = m.st.accent.Render(it.Right)
			if sel {
				right = m.st.hlBar.Render(it.Right)
			}
		} else {
			right = dim.Render(it.Right)
		}
	}
	titleW := 28
	if m.view == Connect {
		titleW = 24
	}
	shown := trunc(it.Title, titleW)
	titleCell := highlight(shown, it.Match, title, hit) + title.Render(strings.Repeat(" ", titleW-runewidth.StringWidth(shown)))
	left := bar + " " + glyph + "  " + titleCell + "  "
	detail := meta.Render(it.Meta)
	if it.Diff != "" {
		detail += dim.Render(" · " + diff(it.Diff))
	}
	if it.Iso != "" {
		detail += dim.Render(" [" + it.Iso + "]")
	}
	// Right column is pinned to the edge; the detail gets what is left.
	avail := w - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if avail < 0 {
		avail = 0
	}
	if lipgloss.Width(detail) > avail {
		detail = meta.Render(trunc(it.Meta, avail))
	}
	line := left + detail
	gap := w - lipgloss.Width(line) - lipgloss.Width(right) - 1
	if gap < 1 {
		gap = 1
	}
	line += strings.Repeat(" ", gap) + right + " "
	if sel {
		return m.st.hlRow.Render(padRight(line, w))
	}
	return line
}

func (m model) glyphFor(it Item, sel bool) string { return m.st.glyph(it, m.frame, sel) }

func (m model) footer(w int) string {
	hint := func(k, what string) string { return m.st.key.Render(k) + " " + m.st.dim.Render(what) }
	var parts []string
	switch m.view {
	case Fleet:
		parts = []string{hint("⏎", "jump"), hint("^v", "review"), hint("tab", "next view"), hint("esc", "close")}
	case Spaces:
		parts = []string{hint("⏎", "switch"), hint("tab", "next view"), hint("esc", "close")}
	case Connect:
		parts = []string{hint("⏎", "shell"), hint("^a", "+ agent"), hint("^r", "name it"), hint("tab", "next view"), hint("esc", "close")}
	case Move:
		parts = []string{hint("⏎", "move"), hint("esc", "cancel")}
	}
	if m.naming {
		parts = []string{hint("⏎", "create"), hint("esc", "back")}
	}
	return " " + trunc(strings.Join(parts, m.st.dim.Render("  ·  ")), w-1)
}

func (m model) View() string {
	w := m.cfg.Width
	if w <= 0 {
		w = 80
	}
	var b strings.Builder
	b.WriteString(" " + m.tabs(w-1) + "\n")
	b.WriteString(m.searchBox(w) + "\n")
	switch {
	case m.stale:
		b.WriteString(" " + m.st.wait.Render("⚠ snapshot stale — daemon down?") + "\n")
	case m.note != "":
		b.WriteString(" " + m.st.dim.Render(trunc(m.note, w-2)) + "\n")
	default:
		b.WriteString("\n")
	}
	lines, _ := m.listLines()
	h := m.listHeight()
	end := m.offset + h
	if end > len(lines) {
		end = len(lines)
	}
	for _, ln := range lines[m.offset:end] {
		switch ln.kind {
		case lineHeader:
			b.WriteString("   " + m.st.dim.Render(strings.ToUpper(m.shown[ln.idx].Group)) + "\n")
		case lineItem:
			b.WriteString(m.row(m.shown[ln.idx], ln.idx == m.cursor, w) + "\n")
		}
	}
	for i := end - m.offset; i < h; i++ {
		b.WriteString("\n")
	}
	b.WriteString(m.footer(w))
	return b.String()
}

// Load builds the popup's Config from the environment.
func Load(getenv func(string) string, root string, view ViewKind, moveWin string) (Config, error) {
	th, err := theme.Resolve(root, getenv)
	if err != nil {
		return Config{}, err
	}
	cwd, _ := os.Getwd()
	var roots []string
	if r := getenv("AGENT_FLEET_PROJECT_ROOTS"); r != "" {
		for _, p := range strings.Split(r, ":") {
			if p != "" {
				roots = append(roots, p)
			}
		}
	}
	if view == Move && moveWin == "" {
		tmuxBin := getenv("TMUX_BIN")
		if tmuxBin == "" {
			tmuxBin = "tmux"
		}
		// display-popup cannot format-expand its command; the bind stashes
		// the moving window in @fleet-move-win and this reads it back.
		if out, err := exec.Command(tmuxBin, "-L", cache.Socket(getenv), "show-option", "-gqv", "@fleet-move-win").Output(); err == nil {
			moveWin = strings.TrimSpace(string(out))
		}
	}
	return Config{
		View: view, Root: root, AF: filepath.Join(root, "bin", "agent-fleet"),
		Snapshot: cache.Snapshot(getenv), Theme: th, Cwd: cwd, Roots: roots, MoveWin: moveWin,
	}, nil
}

// Run shows the popup until an action closes it or the user cancels.
func Run(cfg Config) error {
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	if cfg.View == Move && cfg.MoveWin == "" {
		return fmt.Errorf("move: could not resolve the current tab")
	}
	m := model{cfg: cfg, view: cfg.View, st: newStyles(cfg.Theme)}
	// The pane's own fds, never /dev/tty (CONTRIBUTING).
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithInput(os.Stdin), tea.WithOutput(os.Stdout), tea.WithMouseCellMotion())
	_, err := p.Run()
	return err
}
