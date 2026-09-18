// Package tui holds the rendering vocabulary the fleet's popups share: the
// palette mapped from the theme, state glyphs, and the small text helpers.
// The rule it encodes, from the rail and the status bar: state colors on
// glyphs and section headers only, muted for every secondary, accent for
// selection and matches, the highlight color as the selected-row ground.
package tui

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"

	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
)

// Spinner frames, shared with the bash renderers.
var Spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// Palette is the theme rendered into lipgloss styles.
type Palette struct {
	Dim, Bold, Accent, Border, Tab, TabOn, Key, Wait, Working, Done, Muted lipgloss.Style
	HlRow, HlBold, HlDim, HlBar, HlAccent                                  lipgloss.Style
	hl                                                                     lipgloss.Color
}

// NewPalette maps the nine theme slots onto the roles above.
func NewPalette(t theme.Theme) Palette {
	c := func(s string) lipgloss.Color { return lipgloss.Color(s) }
	hl := c(t.HL)
	return Palette{
		Dim:      lipgloss.NewStyle().Foreground(c(t.Muted)),
		Bold:     lipgloss.NewStyle().Foreground(c(t.FG)).Bold(true),
		Accent:   lipgloss.NewStyle().Foreground(c(t.Accent)),
		Border:   lipgloss.NewStyle().Foreground(c(t.HL)),
		Tab:      lipgloss.NewStyle().Foreground(c(t.Muted)).Padding(0, 1),
		TabOn:    lipgloss.NewStyle().Foreground(c(t.BG)).Background(c(t.Accent)).Bold(true).Padding(0, 1),
		Key:      lipgloss.NewStyle().Foreground(c(t.FG)),
		Wait:     lipgloss.NewStyle().Foreground(c(t.Wait)),
		Working:  lipgloss.NewStyle().Foreground(c(t.Working)),
		Done:     lipgloss.NewStyle().Foreground(c(t.Done)),
		Muted:    lipgloss.NewStyle().Foreground(c(t.Muted)),
		HlRow:    lipgloss.NewStyle().Background(hl),
		HlBold:   lipgloss.NewStyle().Foreground(c(t.FG)).Bold(true).Background(hl),
		HlDim:    lipgloss.NewStyle().Foreground(c(t.Muted)).Background(hl),
		HlBar:    lipgloss.NewStyle().Foreground(c(t.Accent)).Background(hl),
		HlAccent: lipgloss.NewStyle().Foreground(c(t.Accent)).Bold(true).Background(hl),
		hl:       hl,
	}
}

// StateStyle is the color a state's glyph and section header use.
func (p Palette) StateStyle(state string) lipgloss.Style {
	switch state {
	case snapshot.StateWait:
		return p.Wait
	case snapshot.StateWorking:
		return p.Working
	case snapshot.StateDone:
		return p.Done
	}
	return p.Muted
}

// Glyph renders a state's glyph; sel paints it on the selected-row ground.
func (p Palette) Glyph(state string, frame int, sel bool) string {
	st := p.StateStyle(state)
	if sel {
		st = st.Background(p.hl)
	}
	switch state {
	case snapshot.StateWait:
		return st.Render("◆")
	case snapshot.StateWorking:
		return st.Render(Spinner[frame%len(Spinner)])
	case snapshot.StateDone:
		return st.Render("✓")
	case snapshot.StateIdle:
		return st.Render("○")
	}
	return st.Render("·")
}

// OnHl paints any style onto the selected-row ground.
func (p Palette) OnHl(st lipgloss.Style) lipgloss.Style { return st.Background(p.hl) }

var ansiSeq = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// Plain strips SGR styling.
func Plain(s string) string { return ansiSeq.ReplaceAllString(s, "") }

// Trunc caps a plain string at n terminal cells, ending in … when cut.
func Trunc(s string, n int) string {
	if n < 1 {
		return ""
	}
	if runewidth.StringWidth(s) <= n {
		return s
	}
	return runewidth.Truncate(s, n, "…")
}

// PadRight pads styled-or-plain text to w cells.
func PadRight(s string, w int) string {
	if d := w - lipgloss.Width(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

// Highlight renders text with the matched rune positions in hit, the way
// fzf marks its hits; positions beyond the text are ignored.
func Highlight(text string, match []int, base, hit lipgloss.Style) string {
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

// Diff spaces "+A-D" into "+A −D".
func Diff(d string) string {
	plus, minus, ok := strings.Cut(d, "-")
	if !ok || !strings.HasPrefix(plus, "+") {
		return d
	}
	return plus + " −" + minus
}

// Box draws a one-line rounded box of width w around body (styled text),
// with the count pinned to the right edge and the body yielding first.
func (p Palette) Box(w int, body, count string) string {
	inner := w - 4
	room := inner - runewidth.StringWidth(Plain(count)) - 1
	if room < 1 {
		room = 1
	}
	if lipgloss.Width(body) > room {
		body = Trunc(Plain(body), room)
	}
	gap := inner - lipgloss.Width(body) - runewidth.StringWidth(Plain(count))
	if gap < 1 {
		gap = 1
	}
	mid := PadRight(" "+body+strings.Repeat(" ", gap)+count+" ", w-2)
	return p.Border.Render("╭"+strings.Repeat("─", w-2)+"╮") + "\n" +
		p.Border.Render("│") + mid + p.Border.Render("│") + "\n" +
		p.Border.Render("╰"+strings.Repeat("─", w-2)+"╯")
}

// Hints renders a footer of "key what" pairs separated by dots. Pairs that
// do not fit are dropped whole — never cut inside a styled run.
func (p Palette) Hints(w int, pairs ...string) string {
	sep := p.Dim.Render("  ·  ")
	out, width := "", 1
	for i := 0; i+1 < len(pairs); i += 2 {
		part := p.Key.Render(pairs[i]) + " " + p.Dim.Render(pairs[i+1])
		add := runewidth.StringWidth(pairs[i]) + 1 + runewidth.StringWidth(pairs[i+1])
		if out != "" {
			add += 5
		}
		if width+add > w {
			break
		}
		if out != "" {
			out += sep
		}
		out += part
		width += add
	}
	return " " + out
}
