// Package inbox is the attention queue popup: every agent waiting on you or
// finished, most urgent first, with the context to act without attaching —
// a waiting agent's pane tail (the question), a finished task's diffstat.
// It is the Go twin of scripts/inbox.sh.
//
// Answers are mutations with a guardrail, so they run through
// `agent-fleet answer`: the row carries a fingerprint of the exact capture
// the preview shows, and the verb refuses when the pane has changed since.
// The inbox itself only reads: fleet.snapshot, `tmux capture-pane`, git.
package inbox

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
	"github.com/muesli/termenv"
	"github.com/sahilm/fuzzy"

	"github.com/hyb175/agent-fleet/ui/internal/cache"
	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
	"github.com/hyb175/agent-fleet/ui/internal/tui"
)

// Config is what the popup needs from its environment.
type Config struct {
	Root, AF, Snapshot, CacheDir, Socket, TmuxBin string
	Theme                                         theme.Theme
	Escalate                                      int // seconds in wait before the ! marker (0 = off)
	Width, Height                                 int
}

// Item is one queue row.
type Item struct {
	Pane      string // host-qualified when federated
	State     string
	Group     string // "needs you" | "done"
	Title     string
	Session   string
	Right     string // time in state, "!" appended past the escalation threshold
	Diff, Iso string
	Age       int
	Remote    bool
	Search    string
	Match     []int
}

// Items builds the queue: wait rows then done rows, longest in state first.
func Items(s *snapshot.Snapshot, escalate int) []Item {
	var items []Item
	if s == nil {
		return items
	}
	per := s.AgentsPerWindow()
	agents := append([]snapshot.Agent(nil), s.Agents...)
	snapshot.SortAttention(agents, snapshot.StateWait, snapshot.StateDone)
	for _, a := range agents {
		if a.State != snapshot.StateWait && a.State != snapshot.StateDone {
			continue
		}
		it := Item{
			Pane: a.Pane, State: a.State, Title: a.Title(per), Session: a.Session,
			Diff: a.Diffstat, Iso: a.Isolation, Remote: snapshot.IsRemote(a.Pane),
			Group: "done",
		}
		if a.State == snapshot.StateWait {
			it.Group = "needs you"
		}
		if a.HasAge {
			it.Age = a.Age
			it.Right = snapshot.FormatAge(a.Age)
			if a.State == snapshot.StateWait && escalate > 0 && a.Age >= escalate {
				it.Right += " !"
			}
		}
		it.Search = strings.Join([]string{it.Title, it.Session, a.State, it.Diff, it.Iso}, " ")
		items = append(items, it)
	}
	return items
}

// Filter ranks items by fuzzy match; an empty query keeps order.
func Filter(items []Item, query string) []Item {
	if strings.TrimSpace(query) == "" {
		return items
	}
	src := make([]string, len(items))
	for i, it := range items {
		src[i] = it.Search
	}
	out := []Item{}
	for _, m := range fuzzy.Find(query, src) {
		it := items[m.Index]
		it.Match = m.MatchedIndexes
		out = append(out, it)
	}
	return out
}

// Fingerprint reproduces `agent-fleet answer fp` over a raw capture-pane
// output: trailing blank lines dropped (as `$(…)` does), trailing
// whitespace per line trimmed (`sed 's/[[:space:]]*$//'`), no final newline
// (sed keeps the last line as it came, on GNU and BSD alike), then cksum.
func Fingerprint(capture string) string {
	lines := strings.Split(capture, "\n")
	for len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) == 0 {
		return ""
	}
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t\r\f\v")
	}
	return strconv.FormatUint(uint64(tui.Cksum([]byte(strings.Join(lines, "\n")))), 10)
}

// Tail keeps the last n lines of a capture with runs of blank lines
// collapsed to one, the shape inbox.sh's preview shows.
func Tail(capture string, n int) []string {
	var out []string
	blank := 0
	for _, l := range strings.Split(capture, "\n") {
		l = strings.TrimRight(l, " \t")
		if l == "" {
			blank++
			if blank > 1 {
				continue
			}
		} else {
			blank = 0
		}
		out = append(out, l)
	}
	for len(out) > 0 && out[len(out)-1] == "" {
		out = out[:len(out)-1]
	}
	if len(out) > n {
		out = out[len(out)-n:]
	}
	return out
}

// Preview is the context panel for one row.
type Preview struct {
	Pane  string
	Lines []string
	FP    string // fingerprint of the capture shown, wait rows only
}

// --- Bubble Tea program -----------------------------------------------------

type tickMsg time.Time
type itemsMsg struct {
	items       []Item
	stale       bool
	note        string
	nw, ni, tot int
	refetch     string // also re-read the selected row's preview: "*" whatever it is (^r), a pane id only if that row is selected (after answering it)
}
type previewMsg Preview
type doneMsg struct {
	kind string // "answer" | "jump"
	pane string // the row acted on ("*" for all)
	err  error
	out  string
}

type mode int

const (
	browse     mode = iota
	typing          // ^t reply
	confirming      // ^a approve all
)

type model struct {
	cfg     Config
	items   []Item
	shown   []Item
	query   string
	cursor  int
	offset  int
	frame   int
	stale   bool
	note    string
	zero    string // inbox-zero line (counts of the rest of the fleet)
	preview Preview
	mode    mode
	reply   string
	snapMod time.Time
	p       tui.Palette
}

func (m model) Init() tea.Cmd { return tea.Batch(m.load(), tick()) }

func tick() tea.Cmd {
	return tea.Tick(200*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) load() tea.Cmd { return m.loadWith("") }

// loadWith re-reads the snapshot; refetch also refreshes the preview.
func (m model) loadWith(refetch string) tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg {
		f, err := os.Open(cfg.Snapshot)
		if err != nil {
			return itemsMsg{note: "fleet starting…"}
		}
		defer f.Close()
		s, err := snapshot.Parse(f)
		if err != nil {
			return itemsMsg{note: "snapshot unreadable"}
		}
		msg := itemsMsg{items: Items(s, cfg.Escalate), stale: s.Stale(time.Now().Unix()), tot: len(s.Agents), refetch: refetch}
		for _, a := range s.Agents {
			switch a.State {
			case snapshot.StateWorking:
				msg.nw++
			case snapshot.StateIdle:
				msg.ni++
			}
		}
		return msg
	}
}

func (m model) tmux(args ...string) ([]byte, error) {
	return exec.Command(m.cfg.TmuxBin, append([]string{"-L", m.cfg.Socket}, args...)...).Output()
}

// fetchPreview builds the context panel for a row off the render loop.
func (m model) fetchPreview(it Item) tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg {
		if it.Remote {
			return previewMsg{Pane: it.Pane, Lines: []string{"remote agent on " + snapshot.Host(it.Pane) + " — press Enter to hop over for context"}}
		}
		if it.State == snapshot.StateDone {
			if lines := diffstat(cfg, it.Pane); lines != nil {
				return previewMsg{Pane: it.Pane, Lines: lines}
			}
		}
		out, err := exec.Command(cfg.TmuxBin, "-L", cfg.Socket, "capture-pane", "-p", "-t", it.Pane).Output()
		if err != nil {
			return previewMsg{Pane: it.Pane, Lines: []string{"pane gone — the row will drop on the next tick"}}
		}
		cap := string(out)
		pv := previewMsg{Pane: it.Pane, Lines: Tail(cap, 18)}
		if it.State == snapshot.StateWait {
			pv.FP = Fingerprint(cap)
		}
		return pv
	}
}

// diffstat is the done-task context: the task's whole delta from the
// merge-base with the repo's current branch, plus uncommitted leftovers.
// Returns nil when the pane has no task with a live worktree.
func diffstat(cfg Config, pane string) []string {
	tidB, err := os.ReadFile(filepath.Join(cfg.CacheDir, "panes", pane+".task"))
	if err != nil {
		return nil
	}
	tid := strings.TrimSpace(string(tidB))
	rec, err := os.ReadFile(filepath.Join(cfg.CacheDir, "tasks", tid))
	if err != nil {
		return nil
	}
	var wt, repo, branch string
	for _, l := range strings.Split(string(rec), "\n") {
		k, v, _ := strings.Cut(l, " ")
		switch k {
		case "worktree":
			if wt == "" {
				wt = v
			}
		case "repo":
			if repo == "" {
				repo = v
			}
		case "branch":
			if branch == "" {
				branch = v
			}
		}
	}
	if wt == "" {
		return nil
	}
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		return nil
	}
	git := func(dir string, args ...string) string {
		out, _ := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
		return strings.TrimRight(string(out), "\n")
	}
	var lines []string
	mb := ""
	if repo != "" && branch != "" {
		mb = git(repo, "merge-base", branch, "HEAD")
	}
	if mb != "" {
		base := git(repo, "branch", "--show-current")
		if base == "" {
			base = "base"
		}
		lines = append(lines, "diff vs "+base)
		lines = append(lines, tail(strings.Split(git(wt, "diff", "--stat", mb), "\n"), 20)...)
	} else {
		lines = append(lines, "uncommitted changes")
		lines = append(lines, tail(strings.Split(git(wt, "diff", "--stat", "HEAD"), "\n"), 20)...)
	}
	if unc := git(wt, "status", "--porcelain"); unc != "" {
		u := strings.Split(unc, "\n")
		if len(u) > 5 {
			u = u[:5]
		}
		lines = append(lines, "uncommitted:")
		lines = append(lines, u...)
	}
	return lines
}

func tail(s []string, n int) []string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

// run executes an agent-fleet verb with no tty (its tmux clients must never
// hold this pane's pty) and reports the outcome.
func (m model) run(kind, pane string, args ...string) tea.Cmd {
	af := m.cfg.AF
	return func() tea.Msg {
		out, err := exec.Command(af, args...).CombinedOutput()
		return doneMsg{kind: kind, pane: pane, err: err, out: strings.TrimSpace(string(out))}
	}
}

func (m model) selected() (Item, bool) {
	if m.cursor < 0 || m.cursor >= len(m.shown) {
		return Item{}, false
	}
	return m.shown[m.cursor], true
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

// --- layout -----------------------------------------------------------------

type lineKind int

const (
	lineHeader lineKind = iota
	lineItem
)

type line struct {
	kind lineKind
	idx  int
}

func (m model) listLines() (lines []line, rowLine []int) {
	rowLine = make([]int, len(m.shown))
	last := ""
	for i, it := range m.shown {
		if m.query == "" && it.Group != last {
			lines = append(lines, line{lineHeader, i})
			last = it.Group
		}
		rowLine[i] = len(lines)
		lines = append(lines, line{lineItem, i})
	}
	return
}

// chromeTop: header line, 3-line search box, note line.
func (m model) chromeTop() int { return 5 }

// previewHeight is the bottom panel: about 45% of the popup, at least 6.
func (m model) previewHeight() int {
	h := (m.cfg.Height - m.chromeTop() - 1) * 45 / 100
	if h < 6 {
		h = 6
	}
	return h
}

func (m model) listHeight() int {
	h := m.cfg.Height - m.chromeTop() - 1 - m.previewHeight() - 1 // footer, panel rule
	if h < 1 {
		h = 1
	}
	return h
}

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

// --- update -----------------------------------------------------------------

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.cfg.Width, m.cfg.Height = msg.Width, msg.Height
		m.clamp()
		return m, nil
	case itemsMsg:
		key := ""
		if it, ok := m.selected(); ok {
			key = it.Pane
		}
		m.items, m.stale = msg.items, msg.stale
		if msg.note != "" {
			m.note = msg.note
		}
		m.zero = ""
		if len(m.items) == 0 && msg.tot > 0 {
			m.zero = fmt.Sprintf("inbox zero — %d agents: %d working · %d idle · nothing needs you", msg.tot, msg.nw, msg.ni)
		}
		m.refilter()
		for i, it := range m.shown {
			if it.Pane == key {
				m.cursor = i
			}
		}
		m.clamp()
		// The preview is the user's last look at the pane, and its
		// fingerprint guards the answer — so it is fetched when the cursor
		// lands on a row, on ^r, and for the row just answered; not on every
		// snapshot tick, and not for a row the cursor moved to meanwhile,
		// which would silently re-bless a prompt nobody has re-read.
		it, ok := m.selected()
		if !ok {
			m.preview = Preview{}
			return m, nil
		}
		if m.preview.Pane != it.Pane || msg.refetch == "*" || msg.refetch == it.Pane {
			return m, m.fetchPreview(it)
		}
		return m, nil
	case previewMsg:
		if it, ok := m.selected(); ok && it.Pane == msg.Pane {
			m.preview = Preview(msg)
		}
		return m, nil
	case tickMsg:
		m.frame++
		if fi, err := os.Stat(m.cfg.Snapshot); err == nil && !fi.ModTime().Equal(m.snapMod) {
			m.snapMod = fi.ModTime()
			return m, tea.Batch(m.load(), tick())
		}
		return m, tick()
	case doneMsg:
		if msg.err != nil {
			m.note = firstLine(msg.out)
			if m.note == "" {
				m.note = "failed: " + msg.err.Error()
			}
			return m, nil
		}
		if msg.kind == "jump" {
			return m, tea.Quit
		}
		m.note = "sent ✓"
		// Let the agent consume the keys, then re-read the row and its preview.
		pane := msg.pane
		return m, tea.Tick(400*time.Millisecond, func(time.Time) tea.Msg { return refreshMsg{pane: pane} })
	case refreshMsg:
		return m, m.loadWith(msg.pane)
	case tea.MouseMsg:
		switch {
		case msg.Button == tea.MouseButtonWheelUp:
			return m.move(-1)
		case msg.Button == tea.MouseButtonWheelDown:
			return m.move(1)
		case msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress:
			lines, _ := m.listLines()
			if li := msg.Y - m.chromeTop() + m.offset; li >= 0 && li < len(lines) && lines[li].kind == lineItem {
				if lines[li].idx == m.cursor {
					return m.jump()
				}
				m.cursor = lines[li].idx
				m.clamp()
				return m, m.fetchPreview(m.shown[m.cursor])
			}
		}
		return m, nil
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

type refreshMsg struct{ pane string }

func (m model) move(d int) (tea.Model, tea.Cmd) {
	if len(m.shown) == 0 {
		return m, nil
	}
	m.cursor = (m.cursor + d + len(m.shown)) % len(m.shown)
	m.clamp()
	return m, m.fetchPreview(m.shown[m.cursor])
}

func (m model) jump() (tea.Model, tea.Cmd) {
	if it, ok := m.selected(); ok {
		return m, m.run("jump", it.Pane, "goto", it.Pane)
	}
	return m, nil
}

// answer sends approve/deny/text for the selected row through the CLI,
// guarded by the fingerprint of the capture the preview is showing.
func (m model) answer(how, reply string) (tea.Model, tea.Cmd) {
	it, ok := m.selected()
	if !ok {
		return m, nil
	}
	if it.State != snapshot.StateWait {
		m.note = "not sent: row is '" + it.State + "', answers are for waiting agents"
		return m, nil
	}
	if it.Remote {
		m.note = "not sent: remote agent — attach to answer (Enter)"
		return m, nil
	}
	if m.preview.Pane != it.Pane || m.preview.FP == "" {
		m.note = "not sent: no fingerprint for this row yet — wait for the preview"
		return m, nil
	}
	args := []string{"answer", it.Pane, how}
	if how == "text" {
		args = append(args, reply)
	}
	args = append(args, "--fp", m.preview.FP)
	return m, m.run("answer", it.Pane, args...)
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
	switch m.mode {
	case typing:
		switch msg.Type {
		case tea.KeyEsc:
			m.mode, m.reply = browse, ""
		case tea.KeyEnter:
			m.mode = browse
			reply := m.reply
			m.reply = ""
			if strings.TrimSpace(reply) == "" {
				return m, nil
			}
			return m.answer("text", reply)
		case tea.KeyBackspace:
			if r := []rune(m.reply); len(r) > 0 {
				m.reply = string(r[:len(r)-1])
			}
		case tea.KeyRunes, tea.KeySpace: // a space arrives as its own key type
			m.reply += string(msg.Runes)
		}
		return m, nil
	case confirming:
		m.mode = browse
		if msg.String() == "y" || msg.String() == "Y" {
			return m, m.run("answer", "*", "answer", "--all", "approve", "--yes")
		}
		m.note = "cancelled"
		return m, nil
	}
	switch msg.String() {
	case "ctrl+c", "esc":
		return m, tea.Quit
	// ^n is deny here (README, inbox.sh), so vertical movement is arrows or ^j/^k.
	case "down", "ctrl+j":
		return m.move(1)
	case "up", "ctrl+k":
		return m.move(-1)
	case "enter":
		return m.jump()
	case "ctrl+y":
		return m.answer("approve", "")
	case "ctrl+n":
		return m.answer("deny", "")
	case "ctrl+t":
		if it, ok := m.selected(); ok && it.State == snapshot.StateWait && !it.Remote {
			m.mode, m.reply = typing, ""
		} else {
			m.note = "not sent: replies are for local waiting agents"
		}
	case "ctrl+a":
		n := 0
		for _, it := range m.items {
			if it.State == snapshot.StateWait && !it.Remote {
				n++
			}
		}
		if n == 0 {
			m.note = "nothing waiting"
			return m, nil
		}
		m.mode = confirming
		m.note = fmt.Sprintf("approve ALL %d waiting agent(s) — including any hidden by your filter? [y/N]", n)
	case "ctrl+v":
		if it, ok := m.selected(); ok {
			if it.State != snapshot.StateDone {
				m.note = "no review: reviews are for done tasks (this row is '" + it.State + "')"
				return m, nil
			}
			if it.Remote {
				m.note = "no review: remote task — review it on " + snapshot.Host(it.Pane)
				return m, nil
			}
			c := exec.Command("bash", "-c", `"$1" review "$2" || true; printf '\n(any key returns to the inbox)'; IFS= read -r -n1 _`, "af", m.cfg.AF, it.Pane)
			return m, tea.ExecProcess(c, func(error) tea.Msg { return refreshMsg{} })
		}
	case "ctrl+r":
		return m, m.loadWith("*")
	case "backspace":
		if r := []rune(m.query); len(r) > 0 {
			m.query = string(r[:len(r)-1])
			m.refilter()
			if it, ok := m.selected(); ok {
				return m, m.fetchPreview(it)
			}
		}
	default:
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			m.query += string(msg.Runes)
			m.cursor = 0
			m.refilter()
			if it, ok := m.selected(); ok {
				return m, m.fetchPreview(it)
			}
		}
	}
	return m, nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// --- view -------------------------------------------------------------------

func (m model) row(it Item, sel bool, w int) string {
	bar := " "
	title, dim, hit := m.p.Bold, m.p.Dim, m.p.Accent.Bold(true)
	if sel {
		bar = m.p.HlBar.Render("▎")
		title, dim, hit = m.p.HlBold, m.p.HlDim, m.p.HlAccent
	}
	glyph := m.p.Glyph(it.State, m.frame, sel)
	titleW := 32
	shown := tui.Trunc(it.Title, titleW)
	cell := tui.Highlight(shown, it.Match, title, hit) + title.Render(strings.Repeat(" ", titleW-runewidth.StringWidth(shown)))
	left := bar + " " + glyph + "  " + cell + "  "
	detail := dim.Render(it.Session)
	if it.Diff != "" {
		detail += dim.Render(" · " + tui.Diff(it.Diff))
	}
	if it.Iso != "" {
		detail += dim.Render(" [" + it.Iso + "]")
	}
	right := ""
	if it.Right != "" {
		st := dim
		if strings.HasSuffix(it.Right, "!") {
			st = m.p.Wait
			if sel {
				st = m.p.OnHl(st)
			}
		}
		right = st.Render(it.Right)
	}
	avail := w - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if avail < 0 {
		avail = 0
	}
	if lipgloss.Width(detail) > avail {
		detail = dim.Render(tui.Trunc(it.Session, avail))
	}
	l := left + detail
	gap := w - lipgloss.Width(l) - lipgloss.Width(right) - 1
	if gap < 1 {
		gap = 1
	}
	l += strings.Repeat(" ", gap) + right + " "
	if sel {
		return m.p.HlRow.Render(tui.PadRight(l, w))
	}
	return l
}

func (m model) View() string {
	w := m.cfg.Width
	if w <= 0 {
		w = 80
	}
	var b strings.Builder
	nw, nd := 0, 0
	for _, it := range m.items {
		if it.State == snapshot.StateWait {
			nw++
		} else {
			nd++
		}
	}
	summary := fmt.Sprintf("%d need you · %d done", nw, nd)
	b.WriteString(" " + m.p.TabOn.Render("inbox") + " " + m.p.Dim.Render(summary) + "\n")
	var body string
	switch m.mode {
	case typing:
		body = m.p.Accent.Render("reply ") + m.reply + m.p.Accent.Render("▏")
	default:
		q := m.query
		if q == "" {
			q = m.p.Dim.Render("type to filter")
		}
		body = m.p.Accent.Render("› ") + q + m.p.Accent.Render("▏")
	}
	b.WriteString(m.p.Box(w, body, m.p.Dim.Render(fmt.Sprintf("%d of %d", len(m.shown), len(m.items)))) + "\n")
	switch {
	case m.stale:
		b.WriteString(" " + m.p.Wait.Render("⚠ snapshot stale — daemon down?") + "\n")
	case m.mode == confirming:
		b.WriteString(" " + m.p.Wait.Render(m.note) + "\n")
	case m.note != "":
		st := m.p.Dim
		if strings.HasPrefix(m.note, "not sent") || strings.HasPrefix(m.note, "no review") || strings.HasPrefix(m.note, "failed") {
			st = m.p.Wait
		} else if strings.HasPrefix(m.note, "sent") {
			st = m.p.Done
		}
		b.WriteString(" " + st.Render(tui.Trunc(m.note, w-2)) + "\n")
	case m.zero != "":
		b.WriteString(" " + m.p.Dim.Render(tui.Trunc(m.zero, w-2)) + "\n")
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
			it := m.shown[ln.idx]
			b.WriteString("   " + m.p.StateStyle(it.State).Render(strings.ToUpper(it.Group)) + "\n")
		case lineItem:
			b.WriteString(m.row(m.shown[ln.idx], ln.idx == m.cursor, w) + "\n")
		}
	}
	for i := end - m.offset; i < h; i++ {
		b.WriteString("\n")
	}
	// Preview panel.
	label := " preview "
	if it, ok := m.selected(); ok {
		switch {
		case it.Remote:
			label = " remote "
		case it.State == snapshot.StateDone:
			label = " what it produced "
		default:
			label = " what it is asking "
		}
	}
	rule := "─" + label + strings.Repeat("─", max(0, w-2-runewidth.StringWidth(label)))
	b.WriteString(m.p.Border.Render(tui.Trunc(rule, w)) + "\n")
	ph := m.previewHeight()
	pv := m.preview.Lines
	if _, ok := m.selected(); !ok {
		pv = nil
	}
	for i := 0; i < ph; i++ {
		if i < len(pv) {
			b.WriteString(" " + tui.Trunc(pv[i], w-2) + "\n")
		} else {
			b.WriteString("\n")
		}
	}
	switch m.mode {
	case typing:
		b.WriteString(m.p.Hints(w, "⏎", "send", "esc", "cancel"))
	case confirming:
		b.WriteString(m.p.Hints(w, "y", "approve all", "any other key", "cancel"))
	default:
		b.WriteString(m.p.Hints(w, "⏎", "attach", "^y", "approve", "^n", "deny", "^t", "reply", "^a", "approve all", "^v", "review", "esc", "close"))
	}
	return b.String()
}

// Load builds the popup's Config from the environment.
func Load(getenv func(string) string, root string) (Config, error) {
	th, err := theme.Resolve(root, getenv)
	if err != nil {
		return Config{}, err
	}
	esc := 600
	if v := getenv("AGENT_FLEET_NOTIFY_ESCALATE"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			esc = n
		}
	}
	tmuxBin := getenv("TMUX_BIN")
	if tmuxBin == "" {
		tmuxBin = "tmux"
	}
	return Config{
		Root: root, AF: filepath.Join(root, "bin", "agent-fleet"), Snapshot: cache.Snapshot(getenv),
		CacheDir: cache.Dir(getenv), Socket: cache.Socket(getenv), TmuxBin: tmuxBin, Theme: th, Escalate: esc,
	}, nil
}

// Run shows the inbox until Enter attaches or the user closes it.
func Run(cfg Config) error {
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	m := model{cfg: cfg, p: tui.NewPalette(cfg.Theme)}
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithInput(os.Stdin), tea.WithOutput(os.Stdout), tea.WithMouseCellMotion())
	_, err := p.Run()
	return err
}
