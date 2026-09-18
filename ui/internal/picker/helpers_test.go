package picker

import (
	"regexp"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-runewidth"

	"github.com/hyb175/agent-fleet/ui/internal/theme"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plainText(s string) string   { return ansiRe.ReplaceAllString(s, "") }
func runewidthWidth(s string) int { return runewidth.StringWidth(s) }

// tea_key builds a KeyMsg from the same names KeyMsg.String() produces, so
// tests read like the keymap.
type tea_key struct{ s string }

func (k tea_key) msg() tea.KeyMsg {
	switch k.s {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "tab":
		return tea.KeyMsg{Type: tea.KeyTab}
	case "backspace":
		return tea.KeyMsg{Type: tea.KeyBackspace}
	case "ctrl+n":
		return tea.KeyMsg{Type: tea.KeyCtrlN}
	case "ctrl+p":
		return tea.KeyMsg{Type: tea.KeyCtrlP}
	case "ctrl+z":
		return tea.KeyMsg{Type: tea.KeyCtrlZ}
	case "ctrl+f":
		return tea.KeyMsg{Type: tea.KeyCtrlF}
	case "ctrl+s":
		return tea.KeyMsg{Type: tea.KeyCtrlS}
	case "ctrl+a":
		return tea.KeyMsg{Type: tea.KeyCtrlA}
	case "ctrl+r":
		return tea.KeyMsg{Type: tea.KeyCtrlR}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k.s)}
}

func themeForTest() theme.Theme {
	th, err := theme.Load("../../..", "tokyo-night")
	if err != nil {
		panic(err)
	}
	return th
}
