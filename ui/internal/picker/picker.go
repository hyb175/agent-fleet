// Package picker is the fleet's popup: one list with a fuzzy filter and
// three views (fleet, spaces, connect), plus the move-tab destination view.
// It is the Go twin of scripts/pick.sh and scripts/move-tab.sh.
//
// Data comes from fleet.snapshot (fleet, spaces), from zoxide and the
// project roots (connect), or from `tmux list-sessions` at startup (move —
// a move must act on what exists right now, snapshot or not). Every action
// is an `agent-fleet` verb; the picker never drives tmux itself.
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
	Title  string
	Sub    string
	Search string // what the fuzzy filter matches against
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
		title := a.Title(per)
		sub := a.State
		attention := a.State == snapshot.StateWait || a.State == snapshot.StateDone
		if attention && a.HasAge {
			sub += " " + snapshot.FormatAge(a.Age)
		}
		if attention && a.Diffstat != "" {
			sub += " · " + a.Diffstat
		}
		if a.Isolation != "" {
			sub += " · " + a.Isolation
		}
		sub = a.Session + ":" + a.WindowIndex + " · " + sub
		items = append(items, Item{Key: "PANE:" + a.Pane, State: a.State, Title: title, Sub: sub, Search: title + " " + sub})
	}
	for _, sp := range s.Spaces {
		if sp.Rollup != "none" {
			continue // has agents: its rows are above
		}
		items = append(items, Item{Key: "SESS:" + sp.Session, State: snapshot.StateIdle, Title: sp.Session, Sub: sp.Branch, Search: sp.Session + " " + sp.Branch})
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
		sub := sp.Branch + " · shell"
		if n := count[sp.Session]; n == 1 {
			sub = sp.Branch + " · 1 agent"
		} else if n > 1 {
			sub = fmt.Sprintf("%s · %d agents", sp.Branch, n)
		}
		st := sp.Rollup
		if st == "none" {
			st = snapshot.StateIdle
		}
		items = append(items, Item{Key: "SESS:" + sp.Session, State: st, Title: sp.Session, Sub: sub, Search: sp.Session + " " + sub})
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
// with their branch, then plain directories.
func ConnectItems(cwd string, dirs []string, branch map[string]string, isRepo func(string) bool) []Item {
	row := func(d string, tag bool) Item {
		name := filepath.Base(d)
		suffix := ""
		if tag {
			suffix = " (cwd)"
		}
		if isRepo(d) {
			sub := d + suffix
			if b := branch[d]; b != "" {
				sub = b + "  ·  " + d + suffix
			}
			return Item{Key: "CONNECT:" + d, Repo: true, Title: name, Sub: sub, Search: name + " " + sub}
		}
		return Item{Key: "CONNECT:" + d, Title: name, Sub: d + suffix, Search: name + " " + d}
	}
	items := []Item{row(cwd, true)}
	var repos, plain []Item
	for _, d := range dirs {
		if d == cwd {
			continue
		}
		if isRepo(d) {
			repos = append(repos, row(d, false))
		} else {
			plain = append(plain, row(d, false))
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
		sub := fmt.Sprintf("%d tabs", s.Windows)
		if s.Windows == 1 {
			sub = "1 tab"
		}
		items = append(items, Item{Key: "MOVE:" + s.Name, State: snapshot.StateIdle, Title: s.Name, Sub: sub, Search: s.Name})
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
		out = append(out, items[m.Index])
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
	offset  int
	stale   bool
	note    string // one-line message under the header
	naming  bool   // ^r: typing a workspace name
	name    string
	nameFor string // CONNECT:<dir> the name is for
	snapMod time.Time
	st      styles
	quit    bool
}

type styles struct {
	dim, bold, accent, prompt, hlRow, hlBold, hlDim, wait, working, done, muted lipgloss.Style
}

func newStyles(t theme.Theme) styles {
	c := func(s string) lipgloss.Color { return lipgloss.Color(s) }
	hl := c(t.HL)
	return styles{
		dim:     lipgloss.NewStyle().Foreground(c(t.Muted)),
		bold:    lipgloss.NewStyle().Foreground(c(t.FG)).Bold(true),
		accent:  lipgloss.NewStyle().Foreground(c(t.Accent)),
		prompt:  lipgloss.NewStyle().Foreground(c(t.Accent)).Bold(true),
		hlRow:   lipgloss.NewStyle().Background(hl),
		hlBold:  lipgloss.NewStyle().Foreground(c(t.FG)).Bold(true).Background(hl),
		hlDim:   lipgloss.NewStyle().Foreground(c(t.Muted)).Background(hl),
		wait:    lipgloss.NewStyle().Foreground(c(t.Wait)),
		working: lipgloss.NewStyle().Foreground(c(t.Working)),
		done:    lipgloss.NewStyle().Foreground(c(t.Done)),
		muted:   lipgloss.NewStyle().Foreground(c(t.Muted)),
	}
}

func (s styles) glyph(it Item, frame int) string {
	if strings.HasPrefix(it.Key, "CONNECT:") {
		if it.Repo {
			return s.done.Render("◆")
		}
		return s.dim.Render("+")
	}
	switch it.State {
	case snapshot.StateWait:
		return s.wait.Render("◆")
	case snapshot.StateWorking:
		return s.working.Render([]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}[frame%10])
	case snapshot.StateDone:
		return s.done.Render("✓")
	case snapshot.StateIdle:
		return s.muted.Render("○")
	}
	return s.muted.Render("·")
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.load(m.view), tick())
}

func tick() tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
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
				return itemsMsg{view: view, note: "(fleet starting…)"}
			}
			var items []Item
			if view == Fleet {
				items = FleetItems(s)
			} else {
				items = SpacesItems(s)
			}
			note := ""
			if len(items) == 0 {
				note = "(no workspaces — Tab to connect a repo)"
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

func (m model) listHeight() int {
	h := m.cfg.Height - 4 // header, prompt, note/blank, footer
	if m.stale {
		h--
	}
	if h < 1 {
		h = 1
	}
	return h
}

func (m *model) clamp() {
	h := m.listHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	} else if m.cursor >= m.offset+h {
		m.offset = m.cursor - h + 1
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
			top := 3 // header, prompt, note lines
			if m.stale {
				top++
			}
			if i := msg.Y - top + m.offset; i >= 0 && i < len(m.shown) {
				m.cursor = i
				return m.act(m.shown[i])
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

var prompts = map[ViewKind]string{Fleet: "› ", Spaces: "⊞ ", Connect: "⌕ ", Move: "move to "}

func (m model) header() string {
	switch m.view {
	case Fleet:
		return "[fleet] spaces connect  ·  Tab  ·  ⏎ jump · ^v review  ·  type to filter"
	case Spaces:
		return "fleet [spaces] connect  ·  Tab  ·  ⏎ switch  ·  type to filter"
	case Connect:
		return "fleet spaces [connect]  ·  Tab  ·  ⏎ shell · ^a +agent · ^r name"
	}
	return "move tab  ·  ⏎ move · esc cancel"
}

func (m model) View() string {
	w := m.cfg.Width
	if w <= 0 {
		w = 80
	}
	trunc := func(s string, n int) string {
		if n < 1 {
			return ""
		}
		if runewidth.StringWidth(s) <= n {
			return s
		}
		return runewidth.Truncate(s, n, "…")
	}
	var b strings.Builder
	b.WriteString(m.st.dim.Render(trunc(m.header(), w)) + "\n")
	if m.naming {
		b.WriteString(m.st.prompt.Render("  workspace name: ") + m.name + m.st.accent.Render("▏") + "\n")
	} else {
		b.WriteString(m.st.prompt.Render(prompts[m.view]) + m.query + m.st.accent.Render("▏") + "\n")
	}
	if m.stale {
		b.WriteString(m.st.wait.Render("⚠ snapshot stale — daemon down?") + "\n")
	}
	if m.note != "" {
		b.WriteString(m.st.dim.Render(trunc(m.note, w)) + "\n")
	} else {
		b.WriteString("\n")
	}
	titleW := 16
	if m.view == Connect {
		titleW = 22
	}
	h := m.listHeight()
	end := m.offset + h
	if end > len(m.shown) {
		end = len(m.shown)
	}
	for i := m.offset; i < end; i++ {
		it := m.shown[i]
		glyph := m.st.glyph(it, 0)
		title := runewidth.FillRight(trunc(it.Title, titleW), titleW)
		sub := trunc(it.Sub, w-titleW-6)
		if i == m.cursor {
			line := m.st.hlRow.Render("› ") + glyph + m.st.hlRow.Render(" ") + m.st.hlBold.Render(title) + m.st.hlRow.Render(" ") + m.st.hlDim.Render(sub)
			if d := w - lipgloss.Width(line); d > 0 {
				line += m.st.hlRow.Render(strings.Repeat(" ", d))
			}
			b.WriteString(line + "\n")
		} else {
			b.WriteString("  " + glyph + " " + m.st.bold.Render(title) + " " + m.st.dim.Render(sub) + "\n")
		}
	}
	for i := end - m.offset; i < h; i++ {
		b.WriteString("\n")
	}
	b.WriteString(m.st.dim.Render(fmt.Sprintf("  %d/%d", len(m.shown), len(m.items))))
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
