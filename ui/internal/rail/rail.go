// Package rail renders the sidenav: two stacked lists (workspaces, agents)
// drawn from fleet.snapshot in a 30-column tmux pane. It is the Go twin of
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
//   - a stale snapshot (daemon gone) is announced, never rendered as live.
package rail

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
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
	Theme    theme.Theme
	Width    int // 0 = take it from the terminal
	Height   int // 0 = unknown, render uncapped
}

// View is the rail's state at one instant, render-ready. It holds no I/O.
type View struct {
	Cfg     Config
	Snap    *snapshot.Snapshot
	Now     int64
	Frame   int
	Visible bool // some client's active window is this rail's window
}

// styles are built once per theme; every selected-row segment carries the
// highlight background explicitly (nested resets would otherwise cut it).
type styles struct {
	fg, dim, accent, wait, working, done, muted                      lipgloss.Style
	hlFg, hlDim, hlAccent, hlWait, hlWorking, hlDone, hlMuted, hlPad lipgloss.Style
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
	return s
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
	w := v.Cfg.Width
	if w <= 0 {
		w = 30
	}
	st := newStyles(v.Cfg.Theme)
	var b strings.Builder
	lines := 0
	line := func(s string) { b.WriteString(s); b.WriteByte('\n'); lines++ }
	pad := func(s string) string { // pad plain-or-styled text to the width
		if d := w - lipgloss.Width(s); d > 0 {
			return s + strings.Repeat(" ", d)
		}
		return s
	}
	header := func(l, r string) {
		p := w - runewidth.StringWidth(l) - runewidth.StringWidth(r) - 1
		if p < 1 {
			p = 1
		}
		line(st.dim.Render(" " + l + strings.Repeat(" ", p) + r))
	}
	row := func(sel bool, glyph, name, sub string) {
		// Name line prefix is " g " (3 cells) or "▎ g " when selected (4);
		// the subtitle prefix is 3 cells either way.
		nameCap := w - 3
		if sel {
			nameCap = w - 4
		}
		name = trunc(name, nameCap)
		sub = trunc(sub, w-3)
		if sel {
			bar := st.hlAccent.Render("▎")
			line(st.hlPad.Render(pad(bar + st.hlPad.Render(" ") + glyph + st.hlPad.Render(" ") + st.hlFg.Render(name))))
			line(st.hlPad.Render(pad(bar + st.hlPad.Render("  ") + st.hlDim.Render(sub))))
		} else {
			line(" " + glyph + " " + st.fg.Render(name))
			line("   " + st.dim.Render(sub))
		}
	}

	header("spaces", "")
	snap := v.Snap
	if snap == nil {
		snap = &snapshot.Snapshot{Interval: 1}
	}
	if snap.Epoch > 0 && snap.Stale(v.Now) {
		line(st.wait.Render(" ⚠ stale — daemon down?"))
	}
	line("")
	if len(snap.Spaces) == 0 {
		line(st.dim.Render(" (no workspaces)"))
	} else {
		for _, sp := range snap.Spaces {
			row(sp.Session == v.Cfg.Session, st.glyph(sp.Rollup, v.Frame, sp.Session == v.Cfg.Session), sp.Session, sp.Branch)
		}
	}
	line("")
	header("agents", "all")
	line("")
	if len(snap.Agents) == 0 {
		line(st.dim.Render(" (no agents)"))
	} else {
		per := snap.AgentsPerWindow()
		total := len(snap.Agents)
		avail := total
		if v.Cfg.Height > 0 {
			// Rows past the pane bottom are invisible anyway: count what is
			// left instead of truncating silently. Two lines per row; three
			// reserved for the footer and the more-row itself.
			avail = (v.Cfg.Height - lines - 3) / 2
			if avail < 1 {
				avail = 1
			}
		}
		shown := 0
		for _, a := range snap.Agents {
			if shown >= avail && total > avail {
				line(st.dim.Render(fmt.Sprintf(" +%d more (prefix+o)", total-shown)))
				break
			}
			shown++
			sel := a.WindowID == v.Cfg.Window
			// Subtitle = workspace · kind, then for wait/done the time in
			// state and the diffstat (how big is the thing waiting on me),
			// then the isolation rung when above host. Same order as sidenav.sh.
			sub := a.Session + " · " + a.Label
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
			row(sel, st.glyph(a.State, v.Frame, sel), a.Title(per), sub)
		}
	}
	line("")
	b.WriteString(st.dim.Render(" prefix+o open · prefix+b hide")) // no trailing newline: an exact-fit frame must not scroll
	return b.String()
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

// --- Bubble Tea program -----------------------------------------------------

type tickMsg time.Time
type wakeMsg struct{}

type model struct {
	view     View
	snapMod  time.Time
	focusMod time.Time
	err      error
}

func (m model) Init() tea.Cmd { return tick(dataEvery) }

func tick(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(t time.Time) tea.Msg { return tickMsg(t) })
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
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.view.Cfg.Width, m.view.Cfg.Height = msg.Width, msg.Height
		return m, nil
	case wakeMsg:
		m.reload(true)
		return m, nil
	case tickMsg:
		m.reload(false)
		m.view.Now = time.Now().Unix()
		if m.view.Animate() {
			m.view.Frame = (m.view.Frame + 1) % 100000
			return m, tick(spinEvery)
		}
		return m, tick(dataEvery)
	case tea.KeyMsg:
		// Parity: the bash rail takes no keys. Ctrl-C still quits so a
		// hand-run rail can be stopped.
		if msg.Type == tea.KeyCtrlC {
			return m, tea.Quit
		}
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

// Run draws the rail until the pane goes away. SIGUSR1 (the focus hook's
// wake) forces a re-read instead of killing the process, which is Go's
// default for that signal.
func Run(cfg Config) error {
	// The bash rail emits truecolor unconditionally; inside tmux termenv
	// would otherwise downgrade the theme to the 256-color cube.
	lipgloss.SetColorProfile(termenv.TrueColor)
	// Fixed, so lipgloss never queries the terminal's background color.
	lipgloss.SetHasDarkBackground(true)
	m := model{view: View{Cfg: cfg, Now: time.Now().Unix()}}
	m.reload(true)
	// Explicit stdin/stdout: with its default input Bubble Tea opens
	// /dev/tty when stdin is not a terminal, and an open() on the tty of a
	// dead pane blocks forever (CONTRIBUTING). The pane's own fds are enough.
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithInput(os.Stdin), tea.WithOutput(os.Stdout))
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGUSR1)
	go func() {
		for range sig {
			p.Send(wakeMsg{})
		}
	}()
	_, err := p.Run()
	signal.Stop(sig)
	return err
}
