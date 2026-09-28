// Package rail renders the sidenav: every workspace with its agents nested
// under it, drawn from fleet.snapshot in a 30-column tmux pane. It is the Go twin of
// scripts/sidenav.sh and keeps its invariants:
//
//   - no tmux calls after startup — data comes from fleet.snapshot and
//     focus.now, re-read only when their mtime changes, so N rails add no
//     server load;
//   - the highlight is SELF-derived from the rail's own window and session
//     (correct with several clients attached, where a global "current view"
//     would be wrong);
//   - the spinner animates only while this rail is visible on some client
//     and some agent is working;
//   - a stale snapshot (daemon gone) is announced, never rendered as live;
//   - every mutation (jumping, connecting, going back) is an `agent-fleet`
//     verb; the rail itself never drives tmux.
//
// On top of parity the rail scrolls, takes the mouse (tmux forwards clicks
// and the wheel to a pane that enabled tracking), and has a keyboard focus
// mode (Prefix B selects the pane): j/k move, Enter jumps, w shows waiting
// agents only, / filters by text, z folds a workspace, Esc returns focus.
package rail

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
	"github.com/muesli/termenv"

	"github.com/hyb175/agent-fleet/ui/internal/cache"
	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
)

// Spinner frames, shared with the bash renderers.
var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

const (
	dataEvery = 250 * time.Millisecond // mtime check cadence when idle
	spinEvery = 100 * time.Millisecond // frame cadence while animating
)

// Config is everything the rail needs from its environment.
type Config struct {
	Window   string // this rail's tmux window id (@N): highlights its agents
	Session  string // this rail's session name: highlights its workspace
	Snapshot string // path of fleet.snapshot
	FocusNow string // path of focus.now ("session|window_id")
	AF       string // path of the agent-fleet CLI (the command plane)
	Theme    theme.Theme
	Width    int // 0 = take it from the terminal
	Height   int // 0 = unknown, render uncapped
}

// TargetKind says what a row stands for.
type TargetKind int

const (
	NoTarget TargetKind = iota
	SessionTarget
	AgentTarget
)

// Target is what a rendered line points at; clicks and Enter resolve to it.
type Target struct {
	Kind TargetKind
	ID   string // session name or pane id (host-qualified when federated)
	Row  int    // index into View.Rows
}

// Row is one visible entry of the combined list, in render order.
type Row struct {
	Target Target
	Sess   string // session (for folding)
}

// View is the rail's state at one instant, render-ready. It holds no I/O.
type View struct {
	Cfg     Config
	Snap    *snapshot.Snapshot
	Now     int64
	Frame   int
	Visible bool // some client's active window is this rail's window

	// Interaction state.
	Focus     bool            // keyboard focus mode (a key arrived)
	Cursor    int             // index into Rows(), -1 = none
	Offset    int             // first row shown (scroll position)
	WaitOnly  bool            // w: only agents in wait
	Filter    string          // /: case-insensitive substring on title or subtitle
	Filtering bool            // typing the filter
	Folded    map[string]bool // sessions whose agents are hidden
}

// Rows is the list the cursor moves over, in render order: each workspace,
// then the agents under it that pass the filters (none while it is folded).
// Agents keep snapshot order (the daemon's) within their workspace. An agent
// whose workspace has no S record trails the list rather than vanish.
func (v View) Rows() []Row {
	var rows []Row
	if v.Snap == nil {
		return rows
	}
	per := v.Snap.AgentsPerWindow()
	needle := strings.ToLower(v.Filter)
	shown := func(a snapshot.Agent) bool {
		if v.Folded[a.Session] || (v.WaitOnly && a.State != snapshot.StateWait) {
			return false
		}
		// The workspace name is matched here even though the row no longer
		// prints it — the header above does — so /webapp still finds its agents.
		return needle == "" ||
			strings.Contains(strings.ToLower(a.Session+" "+a.Title(per)+" "+subtitle(a)), needle)
	}
	agent := func(a snapshot.Agent) Row {
		return Row{Target: Target{Kind: AgentTarget, ID: a.Pane}, Sess: a.Session}
	}
	placed := map[string]bool{}
	for _, sp := range v.Snap.Spaces {
		rows = append(rows, Row{Target: Target{Kind: SessionTarget, ID: sp.Session}, Sess: sp.Session})
		placed[sp.Session] = true
		for _, a := range v.Snap.Agents { // ponytail: spaces×agents scan, both are tens
			if a.Session == sp.Session && shown(a) {
				rows = append(rows, agent(a))
			}
		}
	}
	for _, a := range v.Snap.Agents {
		if !placed[a.Session] && shown(a) {
			rows = append(rows, agent(a))
		}
	}
	for i := range rows {
		rows[i].Target.Row = i
	}
	return rows
}

// subtitle = kind, then for wait/done the time in state and the diffstat
// (how big is the thing waiting on me), then the isolation rung when above
// host, then the race attempt (⑂k/N). The workspace is the header the row
// sits under, so it is not repeated here — that leaves the tail you decide
// on (age, diffstat, rung) whole instead of truncated.
func subtitle(a snapshot.Agent) string {
	sub := a.Label
	attention := a.State == snapshot.StateWait || a.State == snapshot.StateDone
	if attention && a.HasAge {
		sub += " · " + snapshot.FormatAge(a.Age)
	}
	if attention && a.Diffstat != "" {
		sub += " · " + a.Diffstat
	}
	if a.Isolation != "" {
		sub += " · " + a.Isolation
	}
	if a.Race != "" {
		sub += " · ⑂" + a.Race
	}
	return sub
}

// styles are built once per theme; every selected-row segment carries the
// highlight background explicitly (nested resets would otherwise cut it).
type styles struct {
	fg, dim, accent, wait, working, done, muted                      lipgloss.Style
	hlFg, hlDim, hlAccent, hlWait, hlWorking, hlDone, hlMuted, hlPad lipgloss.Style
	cursor, hdr                                                      lipgloss.Style
	nameWait, nameDone                                               lipgloss.Style
}

func newStyles(t theme.Theme) styles {
	hl := lipgloss.Color(t.HL)
	s := styles{
		fg:      lipgloss.NewStyle().Foreground(lipgloss.Color(t.FG)).Bold(true),
		dim:     lipgloss.NewStyle().Foreground(lipgloss.Color(t.Muted)),
		accent:  lipgloss.NewStyle().Foreground(lipgloss.Color(t.Accent)),
		wait:    lipgloss.NewStyle().Foreground(lipgloss.Color(t.Wait)),
		working: lipgloss.NewStyle().Foreground(lipgloss.Color(t.Working)),
		done:    lipgloss.NewStyle().Foreground(lipgloss.Color(t.Done)),
		muted:   lipgloss.NewStyle().Foreground(lipgloss.Color(t.Muted)),
	}
	s.hlFg = lipgloss.NewStyle().Foreground(lipgloss.Color(t.Accent)).Bold(true).Background(hl)
	s.hlDim = s.dim.Background(hl)
	s.hlAccent = s.accent.Background(hl)
	s.hlWait = s.wait.Background(hl)
	s.hlWorking = s.working.Background(hl)
	s.hlDone = s.done.Background(hl)
	s.hlMuted = s.muted.Background(hl)
	s.hlPad = lipgloss.NewStyle().Background(hl)
	s.cursor = lipgloss.NewStyle().Foreground(lipgloss.Color(t.Accent)).Bold(true)
	s.hdr = s.dim.Bold(true) // section label: same muted hue as its rule, heavier
	s.nameWait, s.nameDone = s.wait.Bold(true), s.done.Bold(true)
	return s
}

// stateStyle is a state's color, for its glyph and its counts.
func (s styles) stateStyle(state string) lipgloss.Style {
	switch state {
	case snapshot.StateWait:
		return s.wait
	case snapshot.StateWorking:
		return s.working
	case snapshot.StateDone:
		return s.done
	}
	return s.muted
}

// name styles a row's NAME by its state. Attention that lives in a single
// glyph cell is a cue you have to hunt for, and in a 79-row rail the rows
// that need nothing from you should recede: wait and done say so in their own
// color, working keeps the plain foreground (its spinner already carries the
// hue), idle and agentless workspaces go muted.
func (s styles) name(state string) lipgloss.Style {
	switch state {
	case snapshot.StateWait:
		return s.nameWait
	case snapshot.StateDone:
		return s.nameDone
	case snapshot.StateWorking:
		return s.fg
	}
	return s.dim // idle, or a workspace with no agents
}

// summary counts the states worth a glyph — needs you, running, finished — in
// the row vocabulary, zero counts dropped. session "" counts the whole fleet.
// Returns the plain form (what the width math measures) and the styled form
// (what gets drawn).
func (s styles) summary(agents []snapshot.Agent, session string) (string, string) {
	n := map[string]int{}
	for _, a := range agents {
		if session == "" || a.Session == session {
			n[a.State]++
		}
	}
	var plain, styled string
	for _, g := range []struct{ state, glyph string }{
		{snapshot.StateWait, "◆"},
		{snapshot.StateWorking, "⠿"}, // static: a header can't spin
		{snapshot.StateDone, "✓"},
	} {
		c := n[g.state]
		if c == 0 {
			continue
		}
		seg := fmt.Sprintf("%s%d", g.glyph, c)
		if plain != "" {
			plain, styled = plain+" ", styled+" "
		}
		plain, styled = plain+seg, styled+s.stateStyle(g.state).Render(seg)
	}
	return plain, styled
}

func (s styles) glyph(state string, frame int, sel bool) string {
	pick := func(n, h lipgloss.Style) lipgloss.Style {
		if sel {
			return h
		}
		return n
	}
	switch state {
	case snapshot.StateWait:
		return pick(s.wait, s.hlWait).Render("◆")
	case snapshot.StateWorking:
		return pick(s.working, s.hlWorking).Render(spinner[frame%len(spinner)])
	case snapshot.StateDone:
		return pick(s.done, s.hlDone).Render("✓")
	case snapshot.StateIdle:
		return pick(s.muted, s.hlMuted).Render("○")
	}
	return pick(s.muted, s.hlMuted).Render("·")
}

// trunc caps a plain string at n terminal cells, ending in … when cut.
func trunc(s string, n int) string {
	if n < 1 {
		return ""
	}
	if runewidth.StringWidth(s) <= n {
		return s
	}
	return runewidth.Truncate(s, n, "…")
}

// Render draws the rail. Pure: same View, same string.
func Render(v View) string {
	s, _ := RenderMap(v)
	return s
}

// RenderMap draws the rail and returns, per output line, what that line
// points at (NoTarget for headers and blanks) — the click map.
func RenderMap(v View) (string, []Target) {
	w := v.Cfg.Width
	if w <= 0 {
		w = 30
	}
	st := newStyles(v.Cfg.Theme)
	var b strings.Builder
	var lines []Target
	line := func(s string, t Target) { b.WriteString(s); b.WriteByte('\n'); lines = append(lines, t) }
	none := Target{}
	pad := func(s string) string { // pad plain-or-styled text to the width
		if d := w - lipgloss.Width(s); d > 0 {
			return s + strings.Repeat(" ", d)
		}
		return s
	}
	// Section headers are labeled rules — "─ spaces ─────" — so the two lists
	// read as two regions instead of one column of rows that happens to have a
	// word in it. Muted, not the dimmer HL the inbox uses for the same rule:
	// HL against the rail background is under 1.1:1 in some presets (cobalt2,
	// tomorrow-night), and a separator has to hold in every theme.
	// rs is r pre-styled (same display width); "" means style r as dim.
	header := func(l, r, rs string) {
		right := ""
		if room := w - runewidth.StringWidth(l) - 7; r != "" && room >= 1 {
			if runewidth.StringWidth(r) > room {
				if rs != "" {
					r = "" // a styled slot is atomic: drop it rather than cut it
				} else {
					// A long filter is truncated, never allowed past the pane
					// edge: a wrapped header would shove the list down a line.
					r = trunc(r, room)
				}
			}
			if r != "" {
				if rs == "" {
					rs = st.dim.Render(r)
				}
				right = " " + r + " ─" // plain twin, for the width math
			}
		}
		fill := w - 3 - runewidth.StringWidth(l) - runewidth.StringWidth(right)
		if fill < 1 {
			fill = 1
		}
		out := st.dim.Render("─ ") + st.hdr.Render(l) + st.dim.Render(" "+strings.Repeat("─", fill))
		if right != "" {
			out += st.dim.Render(" ") + rs + st.dim.Render(" ─")
		}
		line(out, none)
	}
	// g1/g2 are the tree guides an agent row carries on its name and subtitle
	// lines ("├ "/"│ ", or "└ "/"  " for the last under its workspace), two
	// cells each, dim, in the same column on both lines; a workspace row
	// passes "" and touches the left edge, which is what makes it read as the
	// header. Prefixes: " g1 G " / " g2   " (3 cells + guide), one more when
	// selected for the ▎ bar. In focus mode the cursor row swaps its leading
	// cell for ›.
	row := func(t Target, sel bool, g1, g2, state, name, sub string) {
		cursor := v.Focus && t.Kind != NoTarget && v.Cursor == t.Row
		glyph := st.glyph(state, v.Frame, sel)
		cap := w - 3 - runewidth.StringWidth(g1)
		if sel {
			cap--
		}
		name, sub = trunc(name, cap), trunc(sub, cap)
		if sel {
			bar := "▎"
			if cursor {
				bar = "›"
			}
			barS := st.hlAccent.Render(bar) + st.hlPad.Render(" ")
			line(st.hlPad.Render(pad(barS+st.hlDim.Render(g1)+glyph+st.hlPad.Render(" ")+st.hlFg.Render(name))), t)
			line(st.hlPad.Render(pad(barS+st.hlDim.Render(g2)+st.hlPad.Render("  ")+st.hlDim.Render(sub))), t)
		} else {
			lead := " "
			if cursor {
				lead = st.cursor.Render("›")
			}
			line(lead+st.dim.Render(g1)+glyph+" "+st.name(state).Render(name), t)
			line(" "+st.dim.Render(g2)+"  "+st.dim.Render(sub), t)
		}
	}

	snap := v.Snap
	if snap == nil {
		snap = &snapshot.Snapshot{Interval: 1}
	}
	// One rule over one list. Its right slot is the filter state while one is
	// active, otherwise the fleet's counts: the status bar has those too, but
	// 400 columns away on a wide screen, and this is where you already look.
	right, rightS := st.summary(snap.Agents, "")
	if v.WaitOnly || v.Filter != "" || v.Filtering {
		right, rightS = "all", ""
		if v.WaitOnly {
			right = "wait"
		}
		if v.Filter != "" || v.Filtering {
			right += " /" + v.Filter
			if v.Filtering {
				right += "▏"
			}
		}
	}
	header("fleet", right, rightS)
	if snap.Epoch > 0 && snap.Stale(v.Now) {
		line(st.wait.Render(" ⚠ stale — daemon down?"), none)
	}
	rows := v.Rows()
	if len(snap.Spaces) == 0 {
		line(st.dim.Render(" (no workspaces)"), none)
	}
	bySess := make(map[string]snapshot.Space, len(snap.Spaces))
	for _, sp := range snap.Spaces {
		bySess[sp.Session] = sp
	}
	byPane := make(map[string]snapshot.Agent, len(snap.Agents))
	folded := map[string]int{}
	for _, a := range snap.Agents {
		byPane[a.Pane] = a
		if v.Folded[a.Session] {
			folded[a.Session]++
		}
	}
	per := snap.AgentsPerWindow()
	// Rows past the pane bottom are invisible anyway: show a window of them
	// and say how many sit above and below (fits/budget mirror this).
	total := len(rows)
	budget := 0
	if v.Cfg.Height > 0 {
		budget = v.Cfg.Height - len(lines) - 3
	}
	offset := v.Offset
	if offset > total-1 {
		offset = total - 1
	}
	if offset < 0 {
		offset = 0
	}
	// Scrolled past the end: pull back so the last page is full.
	for offset > 0 && fits(rows, offset-1, budget) == total {
		offset--
	}
	end := fits(rows, offset, budget)
	for i := offset; i < end; i++ {
		r := rows[i]
		if r.Target.Kind == SessionTarget {
			if i > offset {
				line("", none) // a breath between workspace groups
			}
			sp := bySess[r.Target.ID]
			name, sub := sp.Session, sp.Branch
			if v.Folded[sp.Session] {
				// Folded: the marker's total is the number worth the cells —
				// and the row's glyph still carries the worst state — so the
				// per-state counts stand down rather than truncate it away.
				name = "▸ " + name
				sub += fmt.Sprintf(" · %d folded", folded[sp.Session])
			} else if cnt, _ := st.summary(snap.Agents, sp.Session); cnt != "" {
				// The rollup glyph says which state is worst, not how much of
				// it there is. Dim like the rest of the subtitle — the counts
				// answer "how much", the glyph still leads. The branch tail
				// yields first when the row is tight: which workspace needs
				// you outranks which branch it happens to sit on.
				sub = trunc(sub, w-6-runewidth.StringWidth(cnt)) + " · " + cnt
			}
			row(r.Target, sp.Session == v.Cfg.Session, "", "", sp.Rollup, name, sub)
			continue
		}
		g1, g2 := "├ ", "│ "
		if i+1 == total || rows[i+1].Target.Kind == SessionTarget {
			g1, g2 = "└ ", "  "
		}
		a := byPane[r.Target.ID]
		// Tab number: under its workspace's header the number is the one tmux
		// shows there, so Prefix N is a glance away once you are in it.
		name := a.Title(per)
		if a.WindowIndex != "" {
			name = a.WindowIndex + ":" + name
		}
		row(r.Target, a.WindowID == v.Cfg.Window, g1, g2, a.State, name, subtitle(a))
	}
	if offset > 0 || end < total {
		more := ""
		if offset > 0 {
			more += fmt.Sprintf(" ↑%d", offset)
		}
		if end < total {
			more += fmt.Sprintf(" ↓%d", total-end)
		}
		line(st.dim.Render(more+" more"), none)
	}
	if len(snap.Agents) == 0 {
		line(st.dim.Render(" (no agents)"), none)
	} else if len(snap.Agents) > 0 && total == len(snap.Spaces) {
		line(st.dim.Render(" (none match)"), none)
	}
	// The footer is pinned to the bottom row, not left to float wherever the
	// list ended: a 79-row rail holding a 21-row fleet used to put it in the
	// middle of the pane, reading as one more list entry.
	gap := 1
	if v.Cfg.Height > 0 {
		if n := v.Cfg.Height - len(lines) - 1; n > gap {
			gap = n
		}
	}
	for i := 0; i < gap; i++ {
		line("", none)
	}
	foot := " prefix+o open · prefix+b hide"
	if v.Filtering {
		foot = " type to filter · ⏎ keep · esc clear"
	} else if v.Focus {
		foot = " j/k ⏎ jump · w wait · / find · z fold · esc"
	}
	// No trailing newline: an exact-fit frame must not scroll.
	b.WriteString(st.dim.Render(trunc(foot, w)))
	lines = append(lines, none)
	return b.String(), lines
}

// Animate reports whether the spinner should run: something is working and
// this rail is visible.
func (v View) Animate() bool {
	if !v.Visible || v.Snap == nil {
		return false
	}
	for _, a := range v.Snap.Agents {
		if a.State == snapshot.StateWorking {
			return true
		}
	}
	return false
}

// --- interaction (pure) ------------------------------------------------------

// budget mirrors RenderMap: the lines left for rows under the rule (and the
// stale banner), three kept for the more-line, the gap and the footer.
// 0 = uncapped.
func (v View) budget() int {
	if v.Cfg.Height <= 0 || v.Snap == nil {
		return 0
	}
	lines := 1
	if v.Snap.Epoch > 0 && v.Snap.Stale(v.Now) {
		lines++
	}
	return v.Cfg.Height - lines - 3
}

// fits returns the end of the window of rows starting at offset that fits in
// budget lines: two per row, plus the blank line a workspace row carries
// above it when it is not the first in view. At least one row always fits.
func fits(rows []Row, offset, budget int) int {
	if budget <= 0 {
		return len(rows)
	}
	used := 0
	for i := offset; i < len(rows); i++ {
		c := 2
		if i > offset && rows[i].Target.Kind == SessionTarget {
			c = 3
		}
		if used+c > budget && i > offset {
			return i
		}
		used += c
	}
	return len(rows)
}

// clamp keeps the cursor on a row and scrolls the list to show it.
func (v *View) clamp() {
	rows := v.Rows()
	if len(rows) == 0 {
		v.Cursor = -1
		v.Offset = 0
		return
	}
	if v.Cursor >= len(rows) {
		v.Cursor = len(rows) - 1
	}
	if v.Cursor < 0 {
		v.Cursor = 0
	}
	if v.Cursor < v.Offset {
		v.Offset = v.Cursor
	}
	for b := v.budget(); b > 0 && v.Cursor >= fits(rows, v.Offset, b); {
		v.Offset++
	}
}

// Move shifts the cursor by d rows.
func (v *View) Move(d int) {
	v.Focus = true
	if v.Cursor < 0 {
		v.Cursor = 0
	} else {
		v.Cursor += d
	}
	v.clamp()
}

// Scroll shifts the viewport by d rows (the wheel).
func (v *View) Scroll(d int) {
	v.Offset += d
	if n := len(v.Rows()); v.Offset > n-1 {
		v.Offset = n - 1
	}
	if v.Offset < 0 {
		v.Offset = 0
	}
}

// Selected is the cursor's target, or NoTarget.
func (v View) Selected() Target {
	rows := v.Rows()
	if v.Cursor < 0 || v.Cursor >= len(rows) {
		return Target{}
	}
	return rows[v.Cursor].Target
}

// ToggleFold folds/unfolds the cursor row's workspace.
func (v *View) ToggleFold() {
	rows := v.Rows()
	if v.Cursor < 0 || v.Cursor >= len(rows) {
		return
	}
	if v.Folded == nil {
		v.Folded = map[string]bool{}
	}
	s := rows[v.Cursor].Sess
	v.Folded[s] = !v.Folded[s]
	v.clamp()
}

// --- Bubble Tea program -----------------------------------------------------

type tickMsg time.Time
type ranMsg struct{ err error }

type model struct {
	view     View
	snapMod  time.Time
	focusMod time.Time
}

func (m model) Init() tea.Cmd { return tick(dataEvery) }

func tick(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(t time.Time) tea.Msg { return tickMsg(t) })
}

// run executes an agent-fleet verb without blocking the render loop.
func (m model) run(args ...string) tea.Cmd {
	af := m.view.Cfg.AF
	return func() tea.Msg {
		cmd := exec.Command(af, args...)
		return ranMsg{cmd.Run()}
	}
}

// jump resolves a target to its verb: agents are `goto`, workspaces `connect`.
func (m model) jump(t Target) tea.Cmd {
	switch t.Kind {
	case AgentTarget:
		return m.run("goto", t.ID)
	case SessionTarget:
		return m.run("connect", t.ID)
	}
	return nil
}

func (m *model) reload(force bool) {
	changed := force
	if fi, err := os.Stat(m.view.Cfg.Snapshot); err == nil && !fi.ModTime().Equal(m.snapMod) {
		m.snapMod = fi.ModTime()
		changed = true
	} else if err != nil && m.view.Snap != nil {
		// Daemon cleanup removes the file on shutdown: render the empty state.
		m.view.Snap = nil
		changed = true
	}
	if fi, err := os.Stat(m.view.Cfg.FocusNow); err == nil && !fi.ModTime().Equal(m.focusMod) {
		m.focusMod = fi.ModTime()
		changed = true
	}
	if !changed {
		return
	}
	if f, err := os.Open(m.view.Cfg.Snapshot); err == nil {
		s, perr := snapshot.Parse(f)
		f.Close()
		if perr == nil {
			m.view.Snap = s
		}
	}
	m.view.Visible = false
	if m.view.Snap != nil {
		for _, c := range m.view.Snap.Clients {
			if c.Window == m.view.Cfg.Window {
				m.view.Visible = true
			}
		}
	}
	// focus.now (written by the pane-focus-in hook) is fresher than the
	// daemon's polled C records: a rail just switched to animates now.
	if b, err := os.ReadFile(m.view.Cfg.FocusNow); err == nil {
		if i := strings.IndexByte(string(b), '|'); i >= 0 && strings.TrimSpace(string(b[i+1:])) == m.view.Cfg.Window {
			m.view.Visible = true
		}
	}
	if m.view.Cursor >= 0 {
		m.view.clamp()
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.view.Cfg.Width, m.view.Cfg.Height = msg.Width, msg.Height
		if m.view.Cursor >= 0 {
			m.view.clamp()
		}
		return m, nil
	case ranMsg:
		return m, nil
	case tickMsg:
		m.reload(false)
		m.view.Now = time.Now().Unix()
		if m.view.Animate() {
			m.view.Frame = (m.view.Frame + 1) % 100000
			return m, tick(spinEvery)
		}
		return m, tick(dataEvery)
	case tea.MouseMsg:
		return m.mouse(msg)
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m model) mouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	switch {
	case msg.Button == tea.MouseButtonWheelUp:
		m.view.Scroll(-1)
	case msg.Button == tea.MouseButtonWheelDown:
		m.view.Scroll(1)
	case msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress:
		// The click map is the current frame's line->target table; a
		// re-render here is one string build, cheaper than caching it.
		_, lines := RenderMap(m.view)
		if msg.Y >= 0 && msg.Y < len(lines) {
			if t := lines[msg.Y]; t.Kind != NoTarget {
				return m, m.jump(t)
			}
		}
	}
	return m, nil
}

func (m model) key(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Runes that arrive in one read (tmux send-keys, a paste) come as a
	// single KeyMsg; treat them as the keystrokes they are, in order.
	if msg.Type == tea.KeyRunes && len(msg.Runes) > 1 {
		var cur tea.Model = m
		var cmd tea.Cmd
		for _, r := range msg.Runes {
			cur, cmd = cur.(model).key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		}
		return cur, cmd
	}
	v := &m.view
	if v.Filtering {
		switch msg.Type {
		case tea.KeyEsc:
			v.Filter, v.Filtering = "", false
		case tea.KeyEnter:
			v.Filtering = false
		case tea.KeyBackspace:
			if r := []rune(v.Filter); len(r) > 0 {
				v.Filter = string(r[:len(r)-1])
			}
		case tea.KeyRunes, tea.KeySpace: // a space arrives as its own key type
			v.Filter += string(msg.Runes)
		}
		v.clamp()
		return m, nil
	}
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "j", "down":
		v.Move(1)
	case "k", "up":
		v.Move(-1)
	case "g", "home":
		v.Focus = true
		v.Cursor = 0
		v.clamp()
	case "G", "end":
		v.Focus = true
		v.Cursor = len(v.Rows()) - 1
		v.clamp()
	case "enter":
		v.Focus = true
		if t := v.Selected(); t.Kind != NoTarget {
			v.Focus = false
			return m, m.jump(t)
		}
	case "w":
		v.Focus = true
		v.WaitOnly = !v.WaitOnly
		v.clamp()
	case "/":
		v.Focus, v.Filtering = true, true
	case "z":
		v.Focus = true
		v.ToggleFold()
	case "esc", "q":
		// Back to the work pane this focus interrupted. Filters stay: the
		// rail shows them in its header until w or / clears them.
		v.Focus = false
		return m, m.run("back")
	}
	return m, nil
}

func (m model) View() string { return Render(m.view) }

// tmuxFormat asks tmux for one format string about this pane. Startup only.
func tmuxFormat(getenv func(string) string, format string) string {
	pane := getenv("TMUX_PANE")
	if pane == "" {
		return ""
	}
	bin := getenv("TMUX_BIN")
	if bin == "" {
		bin = "tmux"
	}
	out, err := exec.Command(bin, "-L", cache.Socket(getenv), "display-message", "-p", "-t", pane, format).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Load builds the rail's Config from the environment. The launcher passes
// AGENT_FLEET_RAIL_WIN and AGENT_FLEET_RAIL_SESS; a hand-started rail asks
// tmux once for its own window and session.
func Load(getenv func(string) string, root string) (Config, error) {
	th, err := theme.Resolve(root, getenv)
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		Window:   getenv("AGENT_FLEET_RAIL_WIN"),
		Session:  getenv("AGENT_FLEET_RAIL_SESS"),
		Snapshot: cache.Snapshot(getenv),
		FocusNow: cache.FocusNow(getenv),
		AF:       filepath.Join(root, "bin", "agent-fleet"),
		Theme:    th,
	}
	if cfg.Window == "" {
		cfg.Window = tmuxFormat(getenv, "#{window_id}")
	}
	if cfg.Session == "" {
		cfg.Session = tmuxFormat(getenv, "#{session_name}")
	}
	return cfg, nil
}

// Run draws the rail until the pane goes away. Nothing signals it: new data
// and focus changes arrive as mtime changes on fleet.snapshot and focus.now,
// checked every dataEvery.
func Run(cfg Config) error {
	// Inside tmux termenv would downgrade the theme to the 256-color cube and
	// query the terminal for its background; both are fixed here.
	lipgloss.SetColorProfile(termenv.TrueColor)
	// Fixed, so lipgloss never queries the terminal's background color.
	lipgloss.SetHasDarkBackground(true)
	m := model{view: View{Cfg: cfg, Now: time.Now().Unix(), Cursor: -1}}
	m.reload(true)
	// Explicit stdin/stdout: with its default input Bubble Tea opens
	// /dev/tty when stdin is not a terminal, and an open() on the tty of a
	// dead pane blocks forever (CONTRIBUTING). The pane's own fds are enough.
	// Mouse cell motion: tmux forwards clicks and the wheel to a pane that
	// enabled tracking (its default MouseDown1Pane/WheelUpPane bindings).
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithInput(os.Stdin), tea.WithOutput(os.Stdout), tea.WithMouseCellMotion())
	_, err := p.Run()
	return err
}
